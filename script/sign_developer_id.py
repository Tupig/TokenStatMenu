#!/usr/bin/env python3
# fmt: off
"""Explicit, local-only Developer ID signing; never discovers user credentials."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
from xml.parsers.expat import ExpatError

ROOT = Path(__file__).resolve().parents[1]
SECURITY = "/usr/bin/security"
OPENSSL = "/usr/bin/openssl"
CODESIGN = "/usr/bin/codesign"
CI_KEYS = {
    "CI",
    "CONTINUOUS_INTEGRATION",
    "GITHUB_ACTIONS",
    "GITHUB_RUN_ID",
    "BUILD_NUMBER",
    "BUILD_ID",
    "JENKINS_URL",
    "GITLAB_CI",
    "TF_BUILD",
    "TEAMCITY_VERSION",
    "CIRCLECI",
    "TRAVIS",
    "BUILDKITE",
    "CODEBUILD_BUILD_ID",
    "BITBUCKET_BUILD_NUMBER",
    "DRONE",
    "APPVEYOR",
    "XCS",
    "CI_WORKFLOW",
}
GROUP_KEY = "com.apple.security.application-groups"
SANDBOX_KEY = "com.apple.security.app-sandbox"
TEAM_KEY = "com.apple.developer.team-identifier"
IDENTIFIER_KEYS = ("com.apple.application-identifier", "application-identifier")

class SigningError(Exception):
    """A safe-to-display validation failure, without profile or tool output."""

def require(condition: bool, message: str) -> None:
    if not condition:
        raise SigningError(message)

def run_tool(
    command: list[str], data: bytes | None = None
) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(
            command,
            input=data,
            capture_output=True,
            check=True,
            timeout=120,
        )
    except (OSError, subprocess.SubprocessError):
        raise SigningError(
            f"{Path(command[0]).name} failed; no signing fallback is allowed"
        ) from None

def read_plist(path: Path, label: str) -> dict:
    try:
        value = plistlib.loads(path.read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException, ExpatError):
        raise SigningError(f"Cannot read {label} plist") from None
    require(isinstance(value, dict), f"Invalid {label} plist")
    return value

def bundle_ids(root: Path) -> tuple[str, str]:
    """Resolve the source Info.plists, including the widget's Xcode substitution."""
    result = []
    for name in ("Info.plist", "WidgetExtension-Info.plist"):
        identifier = read_plist(root / "Resources" / name, "source Info").get(
            "CFBundleIdentifier"
        )
        if identifier == "$(PRODUCT_BUNDLE_IDENTIFIER)":
            try:
                project = (root / "TokenStatMenu.xcodeproj/project.pbxproj").read_text()
            except (OSError, UnicodeError):
                raise SigningError("Cannot resolve source bundle identifier") from None
            candidates = set()
            for block in re.findall(r"buildSettings\s*=\s*\{(.*?)\};", project, re.S):
                info = re.search(r'INFOPLIST_FILE\s*=\s*"?([^";]+)"?\s*;', block)
                bundle = re.search(
                    r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*"?([^";]+)"?\s*;', block
                )
                if info and bundle and info[1].strip() == f"Resources/{name}":
                    candidates.add(bundle[1].strip())
            require(len(candidates) == 1, "Ambiguous source bundle identifier")
            identifier = candidates.pop()
        require(
            isinstance(identifier, str)
            and re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", identifier)
            is not None,
            "Unresolved source bundle identifier",
        )
        result.append(identifier)
    require(
        result[0] == "com.tupig.TokenStatMenu" and result[1] != result[0],
        "Unexpected source bundle identifiers",
    )
    return result[0], result[1]

def validate_arguments(args: argparse.Namespace, environment: dict[str, str]) -> None:
    # Presence is sufficient: CI=false must not accidentally authorize signing.
    require(
        not any(key in environment for key in CI_KEYS),
        "Developer ID signing is forbidden in CI",
    )
    require(
        re.fullmatch(r"[A-Z0-9]{10}", args.team) is not None,
        "Team must be ten uppercase letters/digits",
    )
    require(
        len(args.group) <= 128
        and re.fullmatch(
            r"(?:group|[A-Z0-9]{10})(?:\.[A-Za-z0-9]+(?:[A-Za-z0-9-]*[A-Za-z0-9])?)+",
            args.group,
        )
        is not None,
        "Invalid App Group",
    )
    prefix = args.group.split(".", 1)[0]
    require(prefix in ("group", args.team), "App Group Team does not match --team")
    sha1 = re.fullmatch(r"[A-Fa-f0-9]{40}", args.identity)
    named = re.fullmatch(
        r"Developer ID Application: [^\r\n]+ \(" + args.team + r"\)", args.identity
    )
    require(
        sha1 is not None or named is not None,
        "Use an explicit Developer ID Application name or certificate SHA1",
    )

@dataclass(frozen=True)
class Authorization:
    profile: bytes
    entitlements: dict
    certificates: dict[str, str]
    certificate_data: dict[str, bytes]

def certificate_identity(
    certificate: bytes, team: str
) -> tuple[str, str] | None:
    require(isinstance(certificate, bytes), "Invalid profile certificate")
    output = run_tool(
        [
            OPENSSL,
            "x509",
            "-inform",
            "DER",
            "-noout",
            "-subject",
            "-nameopt",
            "sep_multiline",
            "-fingerprint",
            "-sha1",
            "-certopt",
            "no_subject,no_issuer",
            "-text",
        ],
        certificate,
    ).stdout.decode("utf-8", errors="replace")
    common = re.findall(r"^\s*CN\s*=\s*(.+)$", output, re.M)
    units = re.findall(r"^\s*OU\s*=\s*(.+)$", output, re.M)
    fingerprint = re.findall(r"^sha1 Fingerprint=([0-9A-Fa-f:]+)$", output, re.M | re.I)
    require(len(fingerprint) == 1, "Invalid profile certificate fingerprint")
    digest = hashlib.sha1(certificate).hexdigest().upper()
    require(
        fingerprint[0].replace(":", "").upper() == digest,
        "Invalid profile certificate fingerprint",
    )
    require(len(common) == 1, "Invalid profile certificate subject")
    if units != [team]:
        return None
    if not re.fullmatch(r"Developer ID Application: .+ \(" + team + r"\)", common[0]):
        return None
    # CN alone does not establish the certificate's Developer ID Application purpose.
    if re.search(r"^\s*1\.2\.840\.113635\.100\.6\.1\.13\s*:", output, re.M) is None:
        return None
    return digest, common[0]

def validate_certificate_validity(certificate: bytes, now: datetime) -> None:
    # Only the unique explicit candidate shared by both profiles reaches this step.
    output = run_tool([
        OPENSSL, "x509", "-inform", "DER", "-noout", "-dates", "-checkend", "0",
    ], certificate).stdout.decode("utf-8", errors="replace")
    dates = []
    for key in ("notBefore", "notAfter"):
        values = re.findall(r"^" + key + r"=(.+)$", output, re.M)
        require(len(values) == 1, "Certificate validity dates are required")
        try:
            dates.append(
                datetime.strptime(values[0], "%b %d %H:%M:%S %Y GMT").replace(
                    tzinfo=timezone.utc
                )
            )
        except ValueError:
            raise SigningError("Invalid certificate validity dates") from None
    require(dates[0] <= now < dates[1], "Certificate is not currently valid")

def authorize_profile(
    path: Path,
    bundle_id: str,
    args: argparse.Namespace,
    sandbox: bool,
    root: Path,
    now: datetime,
) -> Authorization:
    require(
        path.is_file() and not path.is_symlink(),
        "An explicit regular profile file is required",
    )
    try:
        raw = path.read_bytes()
    except OSError:
        raise SigningError("Cannot read explicit profile file") from None
    require(0 < len(raw) <= 10 * 1024 * 1024, "Invalid profile size")
    decoded = run_tool([SECURITY, "cms", "-D", "-i", str(path)]).stdout
    try:
        profile = plistlib.loads(decoded)
        unchanged = path.read_bytes() == raw
    except (OSError, ValueError, plistlib.InvalidFileException, ExpatError):
        raise SigningError("Cannot decode explicit profile") from None
    require(
        unchanged and isinstance(profile, dict), "Invalid or changed explicit profile"
    )
    for key, before in (("CreationDate", True), ("ExpirationDate", False)):
        date = profile.get(key)
        require(isinstance(date, datetime), "Profile validity dates are required")
        date = date.replace(tzinfo=timezone.utc) if date.tzinfo is None else date
        require(date <= now if before else date > now, "Profile is not currently valid")
    require(
        profile.get("TeamIdentifier") == [args.team],
        "Profile Team does not match --team",
    )
    require(profile.get("Platform") == ["OSX"], "A macOS profile is required")
    require(
        profile.get("ProvisionsAllDevices") is True
        and "ProvisionedDevices" not in profile,
        "A Developer ID distribution profile is required",
    )
    authorized = profile.get("Entitlements")
    require(isinstance(authorized, dict), "Profile has no entitlements")
    require(authorized.get(TEAM_KEY) == args.team, "Profile entitlement Team mismatch")
    for key in ("get-task-allow", "com.apple.security.get-task-allow"):
        require(
            key not in authorized or authorized[key] is False,
            "Development profiles are forbidden",
        )
    groups = authorized.get(GROUP_KEY)
    require(
        isinstance(groups, list) and args.group in groups,
        "Profile does not explicitly authorize the App Group",
    )
    identifiers = {key: authorized[key] for key in IDENTIFIER_KEYS if key in authorized}
    require(
        bool(identifiers)
        and all(value == f"{args.team}.{bundle_id}" for value in identifiers.values()),
        "Profile must explicitly authorize this bundle identifier; wildcards are forbidden",
    )
    if "ApplicationIdentifierPrefix" in profile:
        require(
            profile["ApplicationIdentifierPrefix"] == [args.team],
            "Profile identifier prefix mismatch",
        )
    template_name = (
        "WidgetExtension.entitlements" if sandbox else "TokenStatMenu.entitlements"
    )
    resolved = read_plist(root / "Resources" / template_name, "source entitlements")
    require(
        set(resolved) == ({GROUP_KEY, SANDBOX_KEY} if sandbox else {GROUP_KEY}),
        "Unexpected source entitlements; review before signing",
    )
    require(
        resolved.get(GROUP_KEY) == ["$(TOKENSTAT_WIDGET_GROUP)"],
        "Unexpected source App Group template",
    )
    require(
        resolved.get(SANDBOX_KEY, False) is sandbox, "Source sandbox policy mismatch"
    )
    if SANDBOX_KEY in authorized:
        require(authorized[SANDBOX_KEY] is sandbox, "Profile sandbox policy mismatch")
    resolved[GROUP_KEY] = [args.group]
    resolved.update(identifiers)
    resolved[TEAM_KEY] = args.team
    certificates = profile.get("DeveloperCertificates")
    require(
        isinstance(certificates, list) and bool(certificates),
        "Profile has no signing certificates",
    )
    matching = {}
    matching_data = {}
    for certificate in certificates:
        identity = certificate_identity(certificate, args.team)
        if identity and (
            args.identity.upper() == identity[0] or args.identity == identity[1]
        ):
            matching[identity[0]] = identity[1]
            matching_data[identity[0]] = certificate
    require(
        bool(matching),
        "Explicit identity is not a Developer ID certificate authorized by this profile",
    )
    return Authorization(raw, resolved, matching, matching_data)

def inspect_app(app: Path, ids: tuple[str, str], group: str) -> tuple[Path, Path]:
    require(
        app.suffix == ".app" and app.is_dir() and not app.is_symlink(),
        "An existing .app directory is required",
    )
    resolved = app.resolve()
    for installed in (
        Path("/Applications"),
        Path.home() / "Applications",
        Path("/System"),
        Path("/Library"),
    ):
        require(
            not resolved.is_relative_to(installed.resolve()),
            "Refusing to modify an installed/system application",
        )
    widget = app / "Contents/PlugIns/TokenStatMenuWidget.appex"
    for entry in app.rglob("*"):
        require(
            not entry.is_symlink(), "Symlinks in signing input require manual review"
        )
        if entry.suffix in (".app", ".appex", ".framework", ".xpc", ".dylib", ".so"):
            require(
                entry == widget,
                "Unexpected nested code requires an explicit signing policy",
            )
    for bundle, identifier in zip((app, widget), ids):
        info = read_plist(bundle / "Contents/Info.plist", "built Info")
        require(
            info.get("CFBundleIdentifier") == identifier,
            "Built bundle identifier mismatch",
        )
        require(info.get("TokenStatWidgetGroup") == group, "Built App Group mismatch")
        executable = info.get("CFBundleExecutable")
        require(
            isinstance(executable, str)
            and re.fullmatch(r"[A-Za-z0-9_-]+", executable) is not None,
            "Invalid built executable name",
        )
        require(
            (bundle / "Contents/MacOS" / executable).is_file(),
            "Built executable is missing",
        )
    return app, widget

def verify_bundle(
    bundle: Path,
    authorization: Authorization,
    team: str,
    fingerprint: str,
    common_name: str,
    temporary: Path,
    index: int,
) -> None:
    bundle_id = read_plist(bundle / "Contents/Info.plist", "signed Info").get("CFBundleIdentifier")
    require(
        isinstance(bundle_id, str)
        and re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id) is not None
        and re.fullmatch(r"[A-Z0-9]{10}", team) is not None,
        "Invalid signed bundle identifier or Team",
    )
    identifiers = [authorization.entitlements[key] for key in IDENTIFIER_KEYS
                   if key in authorization.entitlements]
    require(
        bool(identifiers) and all(value == f"{team}.{bundle_id}" for value in identifiers),
        "Signed bundle identifier differs from profile authorization",
    )
    # Authority display names and a profile's leaf bytes do not establish Apple trust.
    requirement = (
        'anchor apple generic and identifier "' + bundle_id + '"'
        ' and certificate leaf[subject.OU] = "' + team + '"'
        " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    )
    run_tool([
        CODESIGN, "--verify", "--strict", "--test-requirement", requirement, str(bundle),
    ])
    displayed = run_tool([CODESIGN, "--display", "--verbose=4", str(bundle)])
    details = (displayed.stdout + displayed.stderr).decode("utf-8", errors="replace")
    require(
        re.findall(r"^TeamIdentifier=(.+)$", details, re.M) == [team],
        "Signed Team mismatch",
    )
    authorities = re.findall(r"^Authority=(.+)$", details, re.M)
    require(
        authorities
        == [common_name, "Developer ID Certification Authority", "Apple Root CA"],
        "Signed Developer ID authority mismatch",
    )
    require(
        re.search(
            r"^CodeDirectory .*flags=0x[0-9a-f]+\([^\n)]*\bruntime\b[^\n)]*\)",
            details,
            re.M | re.I,
        )
        is not None,
        "Signed hardened runtime is missing",
    )
    require(
        re.search(r"^Timestamp=.+$", details, re.M) is not None,
        "Signed secure timestamp is missing",
    )
    output = run_tool([CODESIGN, "--display", "--entitlements", ":-", str(bundle)])
    try:
        entitlements = plistlib.loads(output.stdout)
    except (ValueError, plistlib.InvalidFileException, ExpatError):
        raise SigningError("Cannot read signed entitlements") from None
    require(
        entitlements == authorization.entitlements,
        "Signed entitlements differ from resolved authorization",
    )
    prefix = temporary / f"signed-{index}-"
    run_tool(
        [CODESIGN, "--display", "--extract-certificates", str(prefix), str(bundle)]
    )
    try:
        leaf = Path(str(prefix) + "0").read_bytes()
    except OSError:
        raise SigningError("Cannot verify signed certificate") from None
    require(
        hashlib.sha1(leaf).hexdigest().upper() == fingerprint,
        "Signed certificate differs from authorized identity",
    )

def execute(
    args: argparse.Namespace,
    root: Path = ROOT,
    environment: dict[str, str] | None = None,
    now: datetime | None = None,
) -> None:
    validate_arguments(args, dict(os.environ) if environment is None else environment)
    ids = bundle_ids(root)
    now = now or datetime.now(timezone.utc)
    profiles = [
        authorize_profile(Path(path), identifier, args, sandbox, root, now)
        for path, identifier, sandbox in zip(
            (args.app_profile, args.widget_profile),
            ids,
            (False, True),
        )
    ]
    common = set(profiles[0].certificates) & set(profiles[1].certificates)
    require(
        len(common) == 1,
        "Profiles must authorize the same unambiguous Developer ID certificate",
    )
    fingerprint = common.pop()
    require(
        profiles[0].certificates[fingerprint] == profiles[1].certificates[fingerprint],
        "Certificate identity mismatch",
    )
    require(
        profiles[0].certificate_data[fingerprint] == profiles[1].certificate_data[fingerprint],
        "Certificate data mismatch",
    )
    validate_certificate_validity(profiles[0].certificate_data[fingerprint], now)
    if args.validate_only:
        return
    bundles = inspect_app(Path(args.app), ids, args.group)
    with tempfile.TemporaryDirectory(prefix="tokenstat-developer-id-") as directory:
        temporary = Path(directory)
        # Validate everything before the first write. No automatic rollback or fallback.
        for index in (1, 0):
            bundle, authorization = bundles[index], profiles[index]
            (bundle / "Contents/embedded.provisionprofile").write_bytes(
                authorization.profile
            )
            (bundle / "Contents/embedded.provisionprofile").chmod(0o644)
            entitlement_file = temporary / f"entitlements-{index}.plist"
            entitlement_file.write_bytes(plistlib.dumps(authorization.entitlements))
            run_tool(
                [
                    CODESIGN,
                    "--force",
                    "--sign",
                    fingerprint,
                    "--options",
                    "runtime",
                    "--timestamp",
                    "--entitlements",
                    str(entitlement_file),
                    str(bundle),
                ]
            )
            verify_bundle(
                bundle,
                authorization,
                args.team,
                fingerprint,
                profiles[0].certificates[fingerprint],
                temporary,
                index,
            )
        run_tool([CODESIGN, "--verify", "--deep", "--strict", str(bundles[0])])

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("app", "team", "group", "identity", "app-profile", "widget-profile"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--validate-only", action="store_true")
    args = parser.parse_args(argv)
    try:
        execute(args)
    except (SigningError, OSError) as error:
        message = (
            str(error)
            if isinstance(error, SigningError)
            else "Cannot access signing input/output"
        )
        print(f"error: {message}", file=sys.stderr)
        return 1
    print(
        "Developer ID authorization validated"
        if args.validate_only
        else "Developer ID signatures verified"
    )
    return 0

if __name__ == "__main__":
    sys.exit(main())
