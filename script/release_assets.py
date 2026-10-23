#!/usr/bin/env python3
"""Build and verify the public release assets, then publish without clobber.

Only the explicit ``publish`` command makes GitHub writes. It receives the
short-lived Actions token through GH_TOKEN; no credential is read or logged.
Native bundle checks run during packaging on macOS. Artifact readback checks
are portable and never extract or execute an application.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import zipfile

from package_source import PUBLIC_FILES


REPOSITORY = "Tupig/TokenStatMenu"
APP_FILES = {
    "Contents/Info.plist": 0o644,
    "Contents/MacOS/TokenStatMenu": 0o755,
    "Contents/Resources/AppIcon.icns": 0o644,
    "Contents/_CodeSignature/CodeResources": 0o644,
}
APP_DIRECTORIES = {
    "Contents",
    "Contents/MacOS",
    "Contents/Resources",
    "Contents/_CodeSignature",
}
# Xcode products carry a PkgInfo stamp. It enters the contract with v1.1.6 so
# the four-file 1.1.5 package that was actually published keeps validating.
APP_FILES_116 = {**APP_FILES, "Contents/PkgInfo": 0o644}
# v1.1.6 is the first release whose app bundle embeds the widget extension.
# Earlier tags keep the four-file shape that was actually published.
WIDGET_APP_FILES = {
    **APP_FILES_116,
    "Contents/PlugIns/TokenStatMenuWidget.appex/Contents/Info.plist": 0o644,
    "Contents/PlugIns/TokenStatMenuWidget.appex/Contents/MacOS/TokenStatMenuWidget": 0o755,
    "Contents/PlugIns/TokenStatMenuWidget.appex/Contents/_CodeSignature/CodeResources": 0o644,
}
WIDGET_APP_DIRECTORIES = APP_DIRECTORIES | {
    "Contents/PlugIns",
    "Contents/PlugIns/TokenStatMenuWidget.appex",
    "Contents/PlugIns/TokenStatMenuWidget.appex/Contents",
    "Contents/PlugIns/TokenStatMenuWidget.appex/Contents/MacOS",
    "Contents/PlugIns/TokenStatMenuWidget.appex/Contents/_CodeSignature",
}
# Xcode adds build-environment facts while processing INFOPLIST_FILE. They are
# not application identity and are never copied into the reviewed source plist.
XCODE_INJECTED_PLIST_KEYS = frozenset(
    {
        "BuildMachineOSBuild",
        "CFBundleSupportedPlatforms",
        "DTCompiler",
        "DTPlatformBuild",
        "DTPlatformName",
        "DTPlatformVersion",
        "DTSDKBuild",
        "DTSDKName",
        "DTXcode",
        "DTXcodeBuild",
    }
)
TAG_PATTERN = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")
COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}\Z")
SHA_PATTERN = re.compile(r"[0-9a-f]{64}\Z")
# Same shape the runtime accepts in WidgetSnapshotStore.configuredGroup.
GROUP_PATTERN = re.compile(r"group\.[A-Za-z0-9.-]{1,120}\Z")


@dataclass(frozen=True)
class ReleaseIdentity:
    version: str
    build: str
    tag: str
    commit: str


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def _identity_fields(identity: ReleaseIdentity) -> dict:
    _require(
        isinstance(identity.tag, str)
        and TAG_PATTERN.fullmatch(identity.tag) is not None,
        "release tag must be a stable vMAJOR.MINOR.PATCH",
    )
    _require(identity.version == identity.tag[1:], "tag/version mismatch")
    _require(
        isinstance(identity.build, str)
        and re.fullmatch(r"[1-9][0-9]*", identity.build) is not None,
        "build must be a positive ASCII integer string",
    )
    _require(
        isinstance(identity.commit, str)
        and COMMIT_PATTERN.fullmatch(identity.commit) is not None,
        "invalid source commit",
    )
    return dict(
        version=identity.version,
        build=identity.build,
        tag=identity.tag,
        commit=identity.commit,
    )


def _git(
    root: Path, *arguments: str, check: bool = True
) -> subprocess.CompletedProcess:
    # Release checks must not inherit an unrelated index, worktree or Git config.
    environment = {
        key: value for key, value in os.environ.items() if not key.startswith("GIT_")
    }
    environment.update(
        GIT_CONFIG_NOSYSTEM="1",
        GIT_CONFIG_GLOBAL=os.devnull,
        GIT_CONFIG_SYSTEM=os.devnull,
        GIT_TERMINAL_PROMPT="0",
    )
    command = ["git", "-c", "core.hooksPath=" + os.devnull, *arguments]
    result = subprocess.run(command, cwd=root, env=environment, capture_output=True)
    if check and result.returncode:
        raise ValueError("required local Git check failed")
    return result


def _root(root: Path) -> Path:
    root = Path(root).resolve()
    _require(root.is_dir(), "missing source directory")
    actual = _git(root, "rev-parse", "--show-toplevel").stdout.decode().strip()
    _require(Path(actual).resolve() == root, "source must be the exact repository root")
    return root


def _plist(data: bytes) -> dict:
    try:
        value = plistlib.loads(data)
    except (
        ValueError,
        plistlib.InvalidFileException,
        TypeError,
        OverflowError,
    ) as error:
        raise ValueError("invalid bundle plist") from error
    _require(isinstance(value, dict), "bundle plist must be a dictionary")
    return value


def release_identity(root: Path, tag: str, expected_commit: str) -> ReleaseIdentity:
    root = _root(root)
    # Validate untrusted tag text before it reaches even an argument-array tool.
    _require(
        isinstance(tag, str) and TAG_PATTERN.fullmatch(tag) is not None,
        "invalid release tag",
    )
    _require(
        isinstance(expected_commit, str)
        and COMMIT_PATTERN.fullmatch(expected_commit) is not None,
        "invalid expected source commit",
    )
    info = _plist((root / "Resources/Info.plist").read_bytes())
    identity = ReleaseIdentity(
        info.get("CFBundleShortVersionString"),
        info.get("CFBundleVersion"),
        tag,
        expected_commit,
    )
    _identity_fields(identity)
    head = _git(root, "rev-parse", "--verify", "HEAD").stdout.decode().strip()
    peeled = (
        _git(root, "rev-parse", "--verify", "refs/tags/" + tag + "^{commit}")
        .stdout.decode()
        .strip()
    )
    _require(
        head == expected_commit == peeled, "tag, HEAD and expected commit must match"
    )
    _require(
        _git(
            root,
            "merge-base",
            "--is-ancestor",
            head,
            "refs/remotes/origin/main",
            check=False,
        ).returncode
        == 0,
        "release commit must be in fetched origin/main history",
    )
    _require(
        not _git(root, "status", "--porcelain", "--untracked-files=normal").stdout,
        "release source/index must be clean, with no untracked files",
    )
    return identity


def _source_files(root: Path, public_files: list[str]) -> dict[str, tuple[bytes, int]]:
    root = _root(root)
    expected = set(public_files)
    _require(len(expected) == len(public_files), "duplicate public source name")
    for name in expected:
        _require(
            isinstance(name, str)
            and name
            and not name.startswith("/")
            and all(part not in ["", ".", ".."] for part in name.split("/"))
            and not any(ord(character) < 32 for character in name),
            "unsafe public source name",
        )
    indexed = set(_git(root, "ls-files", "-z").stdout.decode().split("\0")[:-1])
    _require(
        indexed == expected, "tracked source set differs from the public allowlist"
    )
    records = _git(root, "ls-tree", "-rz", "--full-tree", "HEAD").stdout.split(b"\0")
    committed = {}
    for record in records:
        if not record:
            continue
        metadata, encoded_name = record.split(b"\t", 1)
        mode, kind, object_id = metadata.decode().split()
        name = encoded_name.decode()
        _require(
            kind == "blob" and mode in ["100644", "100755"],
            "source has an unapproved Git file mode",
        )
        committed[name] = (object_id, int(mode, 8))
    _require(
        set(committed) == expected,
        "commit source set differs from the public allowlist",
    )
    result = {}
    for name, (object_id, git_mode) in committed.items():
        path = root / name
        # Inspect every component before reading, including directory symlinks.
        current = root
        for part in name.split("/"):
            current = current / part
            _require(not current.is_symlink(), "source contains a symbolic link")
        _require(
            path.is_file() and stat.S_ISREG(path.stat().st_mode),
            "source file is not regular",
        )
        mode = stat.S_IMODE(path.stat().st_mode)
        _require(mode == stat.S_IMODE(git_mode), "source filesystem/Git modes differ")
        data = _git(root, "cat-file", "blob", object_id).stdout
        _require(
            path.read_bytes() == data, "source bytes differ from the release commit"
        )
        result[name] = (data, mode)
    _require(
        _git(root, "diff", "--quiet", "HEAD", "--", check=False).returncode == 0,
        "source index or worktree differs from the release commit",
    )
    return result


def _zip_files(
    path: Path,
    prefix: str,
    expected: set[str],
    modes: dict[str, int],
    sizes: dict[str, int] | None = None,
) -> dict[str, tuple[bytes, int]]:
    _require(
        not Path(path).is_symlink() and Path(path).is_file(),
        "archive is not a regular file",
    )
    try:
        with zipfile.ZipFile(path) as archive:
            members = archive.infolist()
            names = [member.filename for member in members]
            required = {prefix + name for name in expected}
            _require(
                len(names) == len(set(names)) and set(names) == required,
                "archive has missing, duplicate or unexpected members",
            )
            result = {}
            for member in members:
                name = member.filename[len(prefix) :]
                mode = member.external_attr >> 16
                _require(
                    member.create_system == 3
                    and stat.S_ISREG(mode)
                    and stat.S_IMODE(mode) == modes[name]
                    and not member.is_dir(),
                    "archive has a symbolic link, directory or incorrect mode",
                )
                if sizes is not None:
                    _require(
                        member.file_size == sizes[name],
                        "archive member size differs from source",
                    )
                data = archive.read(member)
                _require(len(data) == member.file_size, "archive member is truncated")
                result[name] = (data, modes[name])
            return result
    except (
        zipfile.BadZipFile,
        RuntimeError,
        OSError,
        EOFError,
        NotImplementedError,
    ) as error:
        raise ValueError("invalid release archive") from error


def validate_source_archive(
    root: Path, source_zip: Path, public_files: list[str]
) -> dict:
    source = _source_files(root, public_files)
    archived = _zip_files(
        source_zip,
        "TokenStatMenu/",
        set(source),
        {name: mode for name, (_, mode) in source.items()},
        {name: len(data) for name, (data, _) in source.items()},
    )
    _require(archived == source, "archive source bytes differ from the release commit")
    return archived


def _bundle_shape(identity: ReleaseIdentity) -> tuple[dict[str, int], set[str]]:
    version = tuple(int(part) for part in identity.version.split("."))
    if version >= (1, 1, 6):
        return WIDGET_APP_FILES, WIDGET_APP_DIRECTORIES
    return APP_FILES, APP_DIRECTORIES


def _bundle_content(
    root: Path, content: dict[str, tuple[bytes, int]], identity: ReleaseIdentity
) -> str | None:
    _identity_fields(identity)
    files, _ = _bundle_shape(identity)
    _require(set(content) == set(files), "bundle file set differs")
    source_info = _plist((Path(root) / "Resources/Info.plist").read_bytes())
    info = _plist(content["Contents/Info.plist"][0])
    expected = dict(
        source_info,
        TokenStatSourceRevision=identity.commit,
        TokenStatSourceState="clean",
    )
    version_parts = tuple(int(part) for part in identity.version.split("."))
    if version_parts < (1, 1, 6):
        # The published four-file package predates the widget group key. A
        # current source plist carries the placeholder, but neither form is
        # application identity for an older tag.
        expected.pop("TokenStatWidgetGroup", None)
    extra = set(info) - set(expected)
    missing = set(expected) - set(info)
    if version_parts < (1, 1, 6):
        extra.discard("TokenStatWidgetGroup")
    _require(extra <= XCODE_INJECTED_PLIST_KEYS, "bundle plist has an unapproved key")
    _require(not missing, "bundle plist is missing a source key")
    for key, value in expected.items():
        # The source plist keeps the build-setting placeholder; a shipped
        # bundle must carry the resolved group instead.
        if key == "TokenStatWidgetGroup":
            continue
        _require(
            info[key] == value,
            "bundle plist differs from source identity/provenance",
        )
    group = None
    if version_parts >= (1, 1, 6):
        group = info.get("TokenStatWidgetGroup")
        _require(
            isinstance(group, str)
            and GROUP_PATTERN.fullmatch(group) is not None
            and ".." not in group,
            "bundle plist has no resolved widget group",
        )
        _require(
            content["Contents/PkgInfo"][0] == b"APPL????",
            "bundle PkgInfo differs",
        )
    _require(
        info.get("CFBundleShortVersionString") == identity.version
        and info.get("CFBundleVersion") == identity.build,
        "bundle version/build differs",
    )
    _require(
        info.get("CFBundleIdentifier") == "com.tupig.TokenStatMenu"
        and info.get("CFBundleExecutable") == "TokenStatMenu"
        and info.get("CFBundleName") == "TokenStatMenu"
        and info.get("CFBundlePackageType") == "APPL"
        and info.get("CFBundleIconFile") == "AppIcon"
        and info.get("LSMinimumSystemVersion") == "13.0"
        and info.get("LSUIElement") is True,
        "unexpected application identity/platform",
    )
    _require(
        content["Contents/Resources/AppIcon.icns"][0]
        == (Path(root) / "Resources/AppIcon.icns").read_bytes(),
        "bundle icon differs from source",
    )
    _require(
        all(data and mode == files[name] for name, (data, mode) in content.items()),
        "bundle has an empty file or incorrect mode",
    )
    return group


def _signed_entitlements(bundle: Path, command_runner, arch: str | None = None) -> dict:
    """Reads the entitlements embedded for one architecture of a signature.

    A universal binary carries an independent signature per slice. Reading the
    default slice only would let a mixed-architecture bundle smuggle a sandbox
    into one slice and out of the other, so callers validate every slice.
    """
    args = ["codesign", "-d", "--entitlements", ":-"]
    if arch:
        args += ["--arch", arch]
    args.append(str(bundle))
    result = command_runner(args, text=True, capture_output=True, check=False)
    _require(result.returncode == 0, "signed entitlements are unreadable")
    return _plist(result.stdout.encode())


# The entitlement surface is closed: anything beyond the sandbox and the App
# Group is rejected, so a future extra permission cannot slip into a release.
_APP_ENTITLEMENTS = frozenset({"com.apple.security.application-groups"})
_EXTENSION_ENTITLEMENTS = frozenset(
    {
        "com.apple.security.app-sandbox",
        "com.apple.security.application-groups",
    }
)


def validate_app(
    root: Path, app: Path, identity: ReleaseIdentity, command_runner=subprocess.run
) -> dict:
    app = Path(app)
    _require(
        not app.is_symlink() and app.is_dir(),
        "application is not a regular bundle directory",
    )
    files, directories = {}, set()
    for path in app.rglob("*"):
        _require(not path.is_symlink(), "application contains a symbolic link")
        name = path.relative_to(app).as_posix()
        mode = path.stat().st_mode
        if stat.S_ISDIR(mode):
            directories.add(name)
        else:
            allowed, _ = _bundle_shape(identity)
            _require(
                stat.S_ISREG(mode) and name in allowed,
                "application contains an unapproved file",
            )
            _require(
                stat.S_IMODE(mode) == allowed[name], "incorrect application file mode"
            )
            files[name] = (path.read_bytes(), stat.S_IMODE(mode))
    allowed_files, allowed_directories = _bundle_shape(identity)
    _require(
        directories == allowed_directories and set(files) == set(allowed_files),
        "application full tree differs",
    )
    group = _bundle_content(root, files, identity)
    widget_info_name = "Contents/PlugIns/TokenStatMenuWidget.appex/Contents/Info.plist"
    widget_binary = (
        app
        / "Contents/PlugIns/TokenStatMenuWidget.appex/Contents/MacOS/TokenStatMenuWidget"
    )
    try:
        if widget_info_name in files:
            widget_info = _plist(files[widget_info_name][0])
            _require(
                widget_info.get("CFBundleShortVersionString") == identity.version
                and widget_info.get("CFBundleVersion") == identity.build,
                "widget extension version/build differs",
            )
            _require(
                widget_info.get("CFBundleIdentifier")
                == "com.tupig.TokenStatMenu.Widget"
                and widget_info.get("CFBundlePackageType") == "XPC!"
                and widget_info.get("CFBundleExecutable") == "TokenStatMenuWidget"
                and widget_info.get("TokenStatWidgetGroup") == group,
                "unexpected widget extension identity/group",
            )
            extension = widget_info.get("NSExtension")
            _require(
                isinstance(extension, dict)
                and extension.get("NSExtensionPointIdentifier")
                == "com.apple.widgetkit-extension",
                "widget extension point differs",
            )
            widget_arch = command_runner(
                ["lipo", "-archs", str(widget_binary)],
                text=True,
                capture_output=True,
                check=False,
            )
            _require(
                widget_arch.returncode == 0
                and set(widget_arch.stdout.split()) == {"arm64", "x86_64"}
                and len(widget_arch.stdout.split()) == 2,
                "widget extension must have exactly arm64 and x86_64",
            )
            for widget_slice in ("arm64", "x86_64"):
                widget_entitlements = _signed_entitlements(
                    app / "Contents/PlugIns/TokenStatMenuWidget.appex",
                    command_runner,
                    arch=widget_slice,
                )
                _require(
                    set(widget_entitlements) == _EXTENSION_ENTITLEMENTS
                    and widget_entitlements.get("com.apple.security.app-sandbox")
                    is True
                    and widget_entitlements.get("com.apple.security.application-groups")
                    == [group],
                    "widget extension entitlements differ",
                )
            for app_slice in ("arm64", "x86_64"):
                app_entitlements = _signed_entitlements(
                    app, command_runner, arch=app_slice
                )
                _require(
                    set(app_entitlements) == _APP_ENTITLEMENTS
                    and app_entitlements.get("com.apple.security.application-groups")
                    == [group],
                    "application entitlements differ",
                )
        arch = command_runner(
            ["lipo", "-archs", str(app / "Contents/MacOS/TokenStatMenu")],
            text=True,
            capture_output=True,
            check=False,
        )
        _require(
            arch.returncode == 0
            and set(arch.stdout.split()) == {"arm64", "x86_64"}
            and len(arch.stdout.split()) == 2,
            "application must have exactly arm64 and x86_64",
        )
        signed = command_runner(
            ["codesign", "--verify", "--deep", "--strict", str(app)],
            text=True,
            capture_output=True,
            check=False,
        )
        _require(
            signed.returncode == 0, "strict application signature verification failed"
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise ValueError("native application validation tool failed") from error
    return files


def _names(identity: ReleaseIdentity) -> dict[str, str]:
    _identity_fields(identity)
    names = {
        kind: f"TokenStatMenu-{identity.version}-{kind}.zip"
        for kind in ["universal", "source"]
    }
    version_parts = tuple(int(part) for part in identity.version.split("."))
    if version_parts >= (1, 1, 5):
        names["dmg"] = f"TokenStatMenu-{identity.version}-universal.dmg"
    return names


def create_dmg(
    root: Path,
    app: Path,
    output_path: Path,
    identity: ReleaseIdentity,
    command_runner=subprocess.run,
) -> dict:
    """Create a Finder-friendly DMG around an already validated App.

    The staging directory is private and disposable. The only link inside the
    image is the conventional `/Applications` alias. No application is
    launched and no caller-owned path is removed.
    """
    _identity_fields(identity)
    _require(
        tuple(int(part) for part in identity.version.split(".")) >= (1, 1, 5),
        "DMG assets start with the 1.1.5 release contract",
    )
    output_path = Path(output_path)
    _require(
        not output_path.exists() and not output_path.is_symlink(),
        "DMG output must be a new regular path",
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    validate_app(root, app, identity, command_runner)
    with tempfile.TemporaryDirectory(
        prefix="tokenstat-dmg-stage-", dir=str(output_path.parent)
    ) as temporary:
        staging = Path(temporary)
        staged_app = staging / "TokenStatMenu.app"
        shutil.copytree(app, staged_app, symlinks=True)
        applications = staging / "Applications"
        applications.symlink_to("/Applications")
        command = [
            "/usr/bin/hdiutil",
            "create",
            "-volname",
            "TokenStatMenu " + identity.version,
            "-srcfolder",
            str(staging),
            "-format",
            "UDZO",
            "-ov",
            str(output_path),
        ]
        try:
            result = command_runner(
                command, text=True, capture_output=True, check=False
            )
        except (OSError, subprocess.SubprocessError) as error:
            raise RuntimeError("DMG creation tool failed") from error
        _require(
            result.returncode == 0
            and output_path.is_file()
            and not output_path.is_symlink(),
            "DMG creation failed",
        )
    data = output_path.read_bytes()
    return {
        "name": output_path.name,
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
    }


def validate_dmg(
    root: Path, dmg_path: Path, identity: ReleaseIdentity, command_runner=subprocess.run
) -> dict:
    """Inspect a DMG through imageinfo and a read-only owned mount."""
    _identity_fields(identity)
    dmg_path = Path(dmg_path)
    _require(
        not dmg_path.is_symlink() and dmg_path.is_file(), "DMG is not a regular file"
    )
    mount = Path(tempfile.mkdtemp(prefix="tokenstat-dmg-mount-"))
    device: str | None = None

    def run_tool(arguments):
        try:
            return command_runner(
                arguments, text=True, capture_output=True, check=False
            )
        except (OSError, subprocess.SubprocessError) as error:
            raise RuntimeError("hdiutil command failed") from error

    try:
        info = run_tool(["/usr/bin/hdiutil", "imageinfo", str(dmg_path)])
        _require(info.returncode == 0, "hdiutil imageinfo failed")
        attach = run_tool(
            [
                "/usr/bin/hdiutil",
                "attach",
                "-readonly",
                "-nobrowse",
                "-mountpoint",
                str(mount),
                str(dmg_path),
            ]
        )
        _require(attach.returncode == 0, "read-only DMG attach failed")
        # `hdiutil attach` may print localized checksum diagnostics before
        # its tabular device rows. Select only the row that explicitly names
        # our disposable mountpoint; never detach an arbitrary first device.
        # macOS commonly renders `/var/...` as its canonical `/private/var/...`
        # spelling in hdiutil output, so compare both spellings of our path.
        mount_texts = {str(mount), os.path.realpath(mount)}
        for line in attach.stdout.splitlines():
            fields = [field.strip() for field in line.split("\t")]
            if (
                fields
                and fields[0].startswith("/dev/")
                and any(field in mount_texts for field in fields[1:])
            ):
                device = fields[0]
                break
        _require(device is not None, "hdiutil attach returned no owned device")
        entries = list(mount.iterdir())
        _require(
            {entry.name for entry in entries} == {"TokenStatMenu.app", "Applications"},
            "DMG root has unexpected members",
        )
        app = mount / "TokenStatMenu.app"
        applications = mount / "Applications"
        _require(
            app.is_dir() and not app.is_symlink(), "DMG App is missing or symbolic"
        )
        _require(
            applications.is_symlink() and os.readlink(applications) == "/Applications",
            "DMG Applications alias is unsafe",
        )
        validate_app(root, app, identity, command_runner)
        data = dmg_path.read_bytes()
        return {
            "name": dmg_path.name,
            "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
        }
    finally:
        detach_error: BaseException | None = None
        if device is not None:
            try:
                detached = run_tool(["/usr/bin/hdiutil", "detach", device])
                _require(detached.returncode == 0, "owned DMG detach failed")
            except BaseException as error:
                detach_error = error
        shutil.rmtree(mount, ignore_errors=True)
        if detach_error is not None:
            # A cleanup failure must remain visible even when inspection also
            # failed; silently swallowing it could leave an owned image mounted.
            raise RuntimeError("owned DMG detach failed") from detach_error


def _canonical_zip(
    path: Path, prefix: str, files: dict[str, tuple[bytes, int]]
) -> None:
    # Release-only normalization: original payload/modes, fixed ZIP metadata.
    # The generic source exporter retains its existing behavior.
    with zipfile.ZipFile(
        path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9
    ) as archive:
        for name, (data, mode) in sorted(files.items()):
            item = zipfile.ZipInfo(prefix + name, (2026, 1, 1, 0, 0, 0))
            item.create_system = 3
            item.external_attr = (stat.S_IFREG | mode) << 16
            item.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(
                item, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9
            )


def _sums(directory: Path, names: list[str]) -> bytes:
    return "".join(
        hashlib.sha256((directory / name).read_bytes()).hexdigest() + "  " + name + "\n"
        for name in sorted(names)
    ).encode("ascii")


def package_assets(
    root: Path, app: Path, source_zip: Path, output_dir: Path, identity: ReleaseIdentity
) -> dict:
    fields = _identity_fields(identity)
    output_dir = Path(output_dir)
    _require(not output_dir.is_symlink(), "staging directory is a symbolic link")
    _require(
        not output_dir.exists()
        or (output_dir.is_dir() and not any(output_dir.iterdir())),
        "staging directory must be new or empty; existing content is never removed",
    )
    source = validate_source_archive(root, source_zip, PUBLIC_FILES)
    bundle = validate_app(root, app, identity)
    output_dir.mkdir(parents=True, exist_ok=True)
    names = _names(identity)
    _canonical_zip(output_dir / names["source"], "TokenStatMenu/", source)
    _canonical_zip(output_dir / names["universal"], "TokenStatMenu.app/", bundle)
    if "dmg" in names:
        create_dmg(root, app, output_dir / names["dmg"], identity)
    manifest = dict(fields, assets={})
    for kind, name in names.items():
        data = (output_dir / name).read_bytes()
        manifest["assets"][kind] = dict(
            name=name, bytes=len(data), sha256=hashlib.sha256(data).hexdigest()
        )
    (output_dir / "release-manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    (output_dir / "SHA256SUMS").write_bytes(
        _sums(output_dir, [*names.values(), "release-manifest.json"])
    )
    return validate_assets(
        root, output_dir, identity, validate_dmg_image=("dmg" in names)
    )


def _unique_json(pairs: list[tuple]) -> dict:
    result = {}
    for key, value in pairs:
        _require(key not in result, "duplicate JSON key")
        result[key] = value
    return result


def validate_assets(
    root: Path,
    directory: Path,
    identity: ReleaseIdentity,
    validate_dmg_image: bool = False,
    command_runner=subprocess.run,
) -> dict:
    directory = Path(directory)
    fields, names = _identity_fields(identity), _names(identity)
    _require(
        not directory.is_symlink() and directory.is_dir(), "missing asset directory"
    )
    expected = {*names.values(), "release-manifest.json", "SHA256SUMS"}
    files = list(directory.iterdir())
    _require(
        {path.name for path in files} == expected
        and all(
            not path.is_symlink()
            and path.is_file()
            and stat.S_ISREG(path.stat().st_mode)
            for path in files
        ),
        "asset directory must contain the exact release asset set",
    )
    try:
        manifest = json.loads(
            (directory / "release-manifest.json").read_text(encoding="utf-8"),
            object_pairs_hook=_unique_json,
        )
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ValueError("invalid release manifest JSON") from error
    _require(
        isinstance(manifest, dict) and set(manifest) == {*fields, "assets"},
        "unexpected manifest keys",
    )
    _require(
        all(manifest[key] == value for key, value in fields.items()),
        "manifest release identity differs",
    )
    assets = manifest["assets"]
    _require(
        isinstance(assets, dict) and set(assets) == set(names),
        "unexpected manifest asset keys",
    )
    for kind, name in names.items():
        item = assets[kind]
        _require(
            isinstance(item, dict) and set(item) == {"name", "bytes", "sha256"},
            "unexpected asset fields",
        )
        _require(
            item["name"] == name
            and type(item["bytes"]) is int
            and item["bytes"] > 0
            and isinstance(item["sha256"], str)
            and SHA_PATTERN.fullmatch(item["sha256"]) is not None,
            "invalid asset name, byte count or digest",
        )
        data = (directory / name).read_bytes()
        _require(
            len(data) == item["bytes"]
            and hashlib.sha256(data).hexdigest() == item["sha256"],
            "asset byte count/digest mismatch",
        )
    _require(
        (directory / "SHA256SUMS").read_bytes()
        == _sums(directory, [*names.values(), "release-manifest.json"]),
        "checksum file differs",
    )
    validate_source_archive(root, directory / names["source"], PUBLIC_FILES)
    files, _ = _bundle_shape(identity)
    bundle = _zip_files(
        directory / names["universal"], "TokenStatMenu.app/", set(files), files
    )
    _bundle_content(root, bundle, identity)
    if "dmg" in names and validate_dmg_image:
        validate_dmg(root, directory / names["dmg"], identity, command_runner)
    return manifest


def publish_release(
    root: Path, directory: Path, identity: ReleaseIdentity, client
) -> str:
    """Validate before writes; a conflicting release is never overwritten.

    Failures after upload leave a draft. Failure after publish is a readback
    failure and is never described as a rollback or a successful publication.
    """
    # Publication must validate the complete release set, including the
    # native DMG image whenever this identity carries the fifth asset.
    validate_assets(root, directory, identity, validate_dmg_image=True)
    paths = {path.name: path for path in Path(directory).iterdir()}
    _require(
        client.resolve_tag(identity.tag) == identity.commit,
        "remote tag moved or differs",
    )
    remote = client.lookup(identity.tag)
    if remote is not None:
        _require(
            remote.get("tag") == identity.tag
            and type(remote.get("draft")) is bool
            and remote.get("prerelease") is False,
            "remote release identity is invalid",
        )
        existing = client.list_assets(remote["id"])
        _require(
            len(existing) == len(set(existing)) and set(existing) <= set(paths),
            "unexpected remote asset set",
        )
        _require(
            remote["draft"] or set(existing) == set(paths),
            "published release has missing assets",
        )
        for name in existing:
            _require(
                client.download(remote["id"], name) == paths[name].read_bytes(),
                "conflicting remote asset bytes",
            )
        if not remote["draft"]:
            return "already-published"
    else:
        remote = client.create_draft(identity)
        _require(
            remote.get("tag") == identity.tag
            and remote.get("draft") is True
            and remote.get("prerelease") is False,
            "new release must be the matching draft",
        )
        existing = []
    for name in sorted(set(paths) - set(existing)):
        client.upload(remote["id"], paths[name])

    def readback(release_id: int) -> None:
        actual = client.list_assets(release_id)
        _require(
            len(actual) == len(set(actual)) and set(actual) == set(paths),
            "remote asset set differs",
        )
        for name, path in sorted(paths.items()):
            _require(
                client.download(release_id, name) == path.read_bytes(),
                "remote asset readback differs",
            )
        _require(
            client.resolve_tag(identity.tag) == identity.commit,
            "remote tag changed during publication",
        )

    readback(remote["id"])
    client.publish(remote["id"])
    final = client.lookup(identity.tag)
    _require(
        final is not None
        and final.get("id") == remote["id"]
        and final.get("tag") == identity.tag
        and final.get("draft") is False
        and final.get("prerelease") is False,
        "post-publication release readback failed",
    )
    readback(final["id"])
    return "published"


class GitHubClient:
    """Small fixed-repository GitHub CLI adapter; response bodies stay private."""

    def __init__(
        self,
        identity: ReleaseIdentity,
        *,
        visibility_retries: int = 2,
        visibility_delay: float = 0.25,
        sleep=time.sleep,
    ):
        _require(
            type(visibility_retries) is int and 0 <= visibility_retries <= 8,
            "visibility retry count must be a bounded integer",
        )
        _require(
            type(visibility_delay) in (int, float)
            and not isinstance(visibility_delay, bool)
            and math.isfinite(visibility_delay)
            and visibility_delay >= 0,
            "visibility retry delay must be finite and non-negative",
        )
        _require(callable(sleep), "visibility retry sleep must be callable")
        self.identity = identity
        self.visibility_retries = visibility_retries
        self.visibility_delay = visibility_delay
        self.sleep = sleep
        self.base = "repos/" + REPOSITORY
        self.asset_ids: dict[tuple[int, str], int] = {}

    def _command(self, arguments: list[str], phase: str) -> bytes:
        result = subprocess.run(["gh", *arguments], capture_output=True)
        if result.returncode:
            raise RuntimeError(
                "GitHub " + phase + " failed; remote state was preserved"
            )
        return result.stdout

    def _get(self, path: str, *, missing: bool = False):
        result = subprocess.run(
            ["gh", "api", "--hostname", "github.com", "--include", path],
            capture_output=True,
        )
        # --include exposes the actual HTTP status. Only an explicit 404 is a
        # missing release; authentication, transport and service errors fail.
        match = re.match(rb"HTTP/\S+\s+(\d{3})[^\r\n]*\r?\n", result.stdout)
        if match and match.group(1) == b"404" and missing:
            return None
        if result.returncode or not match or match.group(1) != b"200":
            raise RuntimeError(
                "GitHub read failed; no missing-release assumption was made"
            )
        try:
            body = re.split(rb"\r?\n\r?\n", result.stdout, maxsplit=1)[1]
            return json.loads(body)
        except (IndexError, UnicodeError, json.JSONDecodeError) as error:
            raise RuntimeError("GitHub returned invalid response data") from error

    def resolve_tag(self, tag: str) -> str:
        _require(tag == self.identity.tag, "unexpected remote tag lookup")
        value = self._get(self.base + "/git/ref/tags/" + tag)
        for _ in range(8):
            obj = value.get("object", {})
            digest = obj.get("sha")
            _require(
                isinstance(digest, str)
                and COMMIT_PATTERN.fullmatch(digest) is not None,
                "invalid remote Git object",
            )
            if obj.get("type") == "commit":
                return digest
            _require(obj.get("type") == "tag", "remote tag does not reference a commit")
            value = self._get(self.base + "/git/tags/" + digest)
        raise ValueError("remote annotated tag nesting is excessive")

    def lookup(self, tag: str) -> dict | None:
        _require(tag == self.identity.tag, "unexpected remote release lookup")
        value = self._get(self.base + "/releases/tags/" + tag, missing=True)
        if value is None:
            releases = self._get(self.base + "/releases?per_page=100")
            _require(
                isinstance(releases, list) and len(releases) < 100,
                "remote release list is invalid or incomplete",
            )
            matching = [
                item
                for item in releases
                if isinstance(item, dict) and item.get("tag_name") == tag
            ]
            _require(
                len(matching) <= 1, "multiple remote releases match the requested tag"
            )
            value = matching[0] if matching else None
            if value is None:
                return None
            # A tag endpoint miss is only recoverable for the intended draft
            # resume path. A published/prerelease match indicates conflicting
            # remote state and must fail closed rather than be guessed at.
            _require(
                type(value.get("draft")) is bool
                and value.get("draft") is True
                and type(value.get("prerelease")) is bool
                and value.get("prerelease") is False,
                "tag lookup miss found a non-resumable remote release",
            )
        _require(
            type(value.get("id")) is int
            and type(value.get("draft")) is bool
            and type(value.get("prerelease")) is bool,
            "invalid remote release metadata",
        )
        return dict(
            id=value["id"],
            tag=value.get("tag_name"),
            draft=value["draft"],
            prerelease=value["prerelease"],
        )

    def list_assets(self, release_id: int) -> list[str]:
        _require(
            type(release_id) is int and release_id > 0, "invalid remote release ID"
        )
        value = self._get(self.base + f"/releases/{release_id}/assets?per_page=100")
        # A full page already proves a conflict; never hide additional pages
        # behind an apparently complete asset list.
        _require(
            isinstance(value, list) and len(value) < 100,
            "remote asset list is invalid or excessive",
        )
        names = []
        for item in value:
            _require(
                isinstance(item, dict)
                and isinstance(item.get("name"), str)
                and type(item.get("id")) is int
                and item["id"] > 0,
                "invalid remote asset metadata",
            )
            names.append(item["name"])
            self.asset_ids[(release_id, item["name"])] = item["id"]
        return names

    def create_draft(self, identity: ReleaseIdentity) -> dict:
        _require(identity == self.identity, "unexpected draft identity")
        notes = (
            f"TokenStatMenu {identity.version} (build {identity.build}).\n\n"
            "macOS 13 or later; Universal arm64 and x86_64.\n"
            "This archive is ad hoc signed for local development. It is not Developer ID signed or notarized.\n"
            f"Public source commit: {identity.commit}.\n"
        )
        with tempfile.TemporaryDirectory(
            prefix="tokenstat-release-notes-"
        ) as temporary:
            path = Path(temporary) / "notes.md"
            path.write_text(notes, encoding="utf-8")
            self._command(
                [
                    "release",
                    "create",
                    identity.tag,
                    "--repo",
                    "github.com/" + REPOSITORY,
                    "--verify-tag",
                    "--draft",
                    "--title",
                    "TokenStatMenu " + identity.version,
                    "--notes-file",
                    str(path),
                ],
                "create-draft",
            )
        remote = None
        for attempt in range(self.visibility_retries + 1):
            remote = self.lookup(identity.tag)
            if remote is not None:
                return remote
            if attempt < self.visibility_retries:
                self.sleep(self.visibility_delay)
        _require(remote is not None, "created draft could not be read back")

    def upload(self, release_id: int, path: Path) -> None:
        self._command(
            [
                "release",
                "upload",
                self.identity.tag,
                str(path),
                "--repo",
                "github.com/" + REPOSITORY,
            ],
            "upload",
        )

    def download(self, release_id: int, name: str) -> bytes:
        asset_id = self.asset_ids.get((release_id, name))
        _require(type(asset_id) is int, "remote asset ID was not enumerated")
        return self._command(
            [
                "api",
                "--hostname",
                "github.com",
                "--header",
                "Accept: application/octet-stream",
                self.base + f"/releases/assets/{asset_id}",
            ],
            "download",
        )

    def publish(self, release_id: int) -> None:
        self._command(
            [
                "release",
                "edit",
                self.identity.tag,
                "--repo",
                "github.com/" + REPOSITORY,
                "--draft=false",
            ],
            "publish",
        )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "operation", choices=["preflight", "package", "verify", "publish"]
    )
    parser.add_argument(
        "--root", type=Path, default=Path(__file__).resolve().parents[1]
    )
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--directory", type=Path)
    args = parser.parse_args()
    try:
        identity = release_identity(args.root, args.tag, args.commit)
        if args.operation == "package":
            _require(
                args.app is not None
                and args.source is not None
                and args.directory is not None,
                "package requires --app, --source and --directory",
            )
            package_assets(args.root, args.app, args.source, args.directory, identity)
        elif args.operation in ["verify", "publish"]:
            _require(args.directory is not None, "verify/publish requires --directory")
            if args.operation == "verify":
                validate_assets(
                    args.root, args.directory, identity, validate_dmg_image=True
                )
            else:
                outcome = publish_release(
                    args.root, args.directory, identity, GitHubClient(identity)
                )
                print("Release outcome: " + outcome)
        print(
            "Release "
            + args.operation
            + " verified: "
            + identity.tag
            + " @ "
            + identity.commit
        )
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as error:
        # The messages above are deliberately fixed and contain no raw API data.
        print(
            "Release " + args.operation + " failed: " + type(error).__name__,
            file=sys.stderr,
        )
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
