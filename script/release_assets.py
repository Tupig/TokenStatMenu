#!/usr/bin/env python3
"""Build and verify the four public release assets, then publish without clobber.

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
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import zipfile

from package_source import PUBLIC_FILES


REPOSITORY = "Tupig/TokenStatMenu"
APP_FILES = {
    "Contents/Info.plist": 0o644,
    "Contents/MacOS/TokenStatMenu": 0o755,
    "Contents/Resources/AppIcon.icns": 0o644,
    "Contents/_CodeSignature/CodeResources": 0o644,
}
APP_DIRECTORIES = {"Contents", "Contents/MacOS", "Contents/Resources", "Contents/_CodeSignature"}
TAG_PATTERN = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")
COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}\Z")
SHA_PATTERN = re.compile(r"[0-9a-f]{64}\Z")


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
    _require(isinstance(identity.tag, str) and TAG_PATTERN.fullmatch(identity.tag) is not None,
             "release tag must be a stable vMAJOR.MINOR.PATCH")
    _require(identity.version == identity.tag[1:], "tag/version mismatch")
    _require(isinstance(identity.build, str) and re.fullmatch(r"[1-9][0-9]*", identity.build) is not None,
             "build must be a positive ASCII integer string")
    _require(isinstance(identity.commit, str) and COMMIT_PATTERN.fullmatch(identity.commit) is not None,
             "invalid source commit")
    return dict(version=identity.version, build=identity.build, tag=identity.tag, commit=identity.commit)


def _git(root: Path, *arguments: str, check: bool = True) -> subprocess.CompletedProcess:
    # Release checks must not inherit an unrelated index, worktree or Git config.
    environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                       GIT_CONFIG_SYSTEM=os.devnull, GIT_TERMINAL_PROMPT="0")
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
    except (ValueError, plistlib.InvalidFileException, TypeError, OverflowError) as error:
        raise ValueError("invalid bundle plist") from error
    _require(isinstance(value, dict), "bundle plist must be a dictionary")
    return value


def release_identity(root: Path, tag: str, expected_commit: str) -> ReleaseIdentity:
    root = _root(root)
    # Validate untrusted tag text before it reaches even an argument-array tool.
    _require(isinstance(tag, str) and TAG_PATTERN.fullmatch(tag) is not None, "invalid release tag")
    _require(isinstance(expected_commit, str) and COMMIT_PATTERN.fullmatch(expected_commit) is not None,
             "invalid expected source commit")
    info = _plist((root / "Resources/Info.plist").read_bytes())
    identity = ReleaseIdentity(info.get("CFBundleShortVersionString"), info.get("CFBundleVersion"),
                               tag, expected_commit)
    _identity_fields(identity)
    head = _git(root, "rev-parse", "--verify", "HEAD").stdout.decode().strip()
    peeled = _git(root, "rev-parse", "--verify", "refs/tags/" + tag + "^{commit}").stdout.decode().strip()
    _require(head == expected_commit == peeled, "tag, HEAD and expected commit must match")
    _require(_git(root, "merge-base", "--is-ancestor", head, "refs/remotes/origin/main",
                  check=False).returncode == 0, "release commit must be in fetched origin/main history")
    _require(not _git(root, "status", "--porcelain", "--untracked-files=normal").stdout,
             "release source/index must be clean, with no untracked files")
    return identity


def _source_files(root: Path, public_files: list[str]) -> dict[str, tuple[bytes, int]]:
    root = _root(root)
    expected = set(public_files)
    _require(len(expected) == len(public_files), "duplicate public source name")
    for name in expected:
        _require(isinstance(name, str) and name and not name.startswith("/")
                 and all(part not in ["", ".", ".."] for part in name.split("/"))
                 and not any(ord(character) < 32 for character in name), "unsafe public source name")
    indexed = set(_git(root, "ls-files", "-z").stdout.decode().split("\0")[:-1])
    _require(indexed == expected, "tracked source set differs from the public allowlist")
    records = _git(root, "ls-tree", "-rz", "--full-tree", "HEAD").stdout.split(b"\0")
    committed = {}
    for record in records:
        if not record:
            continue
        metadata, encoded_name = record.split(b"\t", 1)
        mode, kind, object_id = metadata.decode().split()
        name = encoded_name.decode()
        _require(kind == "blob" and mode in ["100644", "100755"], "source has an unapproved Git file mode")
        committed[name] = (object_id, int(mode, 8))
    _require(set(committed) == expected, "commit source set differs from the public allowlist")
    result = {}
    for name, (object_id, git_mode) in committed.items():
        path = root / name
        # Inspect every component before reading, including directory symlinks.
        current = root
        for part in name.split("/"):
            current = current / part
            _require(not current.is_symlink(), "source contains a symbolic link")
        _require(path.is_file() and stat.S_ISREG(path.stat().st_mode), "source file is not regular")
        mode = stat.S_IMODE(path.stat().st_mode)
        _require(mode == stat.S_IMODE(git_mode), "source filesystem/Git modes differ")
        data = _git(root, "cat-file", "blob", object_id).stdout
        _require(path.read_bytes() == data, "source bytes differ from the release commit")
        result[name] = (data, mode)
    _require(_git(root, "diff", "--quiet", "HEAD", "--", check=False).returncode == 0,
             "source index or worktree differs from the release commit")
    return result


def _zip_files(path: Path, prefix: str, expected: set[str], modes: dict[str, int],
               sizes: dict[str, int] | None = None) -> dict[str, tuple[bytes, int]]:
    _require(not Path(path).is_symlink() and Path(path).is_file(), "archive is not a regular file")
    try:
        with zipfile.ZipFile(path) as archive:
            members = archive.infolist()
            names = [member.filename for member in members]
            required = {prefix + name for name in expected}
            _require(len(names) == len(set(names)) and set(names) == required,
                     "archive has missing, duplicate or unexpected members")
            result = {}
            for member in members:
                name = member.filename[len(prefix):]
                mode = member.external_attr >> 16
                _require(member.create_system == 3 and stat.S_ISREG(mode)
                         and stat.S_IMODE(mode) == modes[name] and not member.is_dir(),
                         "archive has a symbolic link, directory or incorrect mode")
                if sizes is not None:
                    _require(member.file_size == sizes[name], "archive member size differs from source")
                data = archive.read(member)
                _require(len(data) == member.file_size, "archive member is truncated")
                result[name] = (data, modes[name])
            return result
    except (zipfile.BadZipFile, RuntimeError, OSError, EOFError, NotImplementedError) as error:
        raise ValueError("invalid release archive") from error


def validate_source_archive(root: Path, source_zip: Path, public_files: list[str]) -> dict:
    source = _source_files(root, public_files)
    archived = _zip_files(source_zip, "TokenStatMenu/", set(source),
                          {name: mode for name, (_, mode) in source.items()},
                          {name: len(data) for name, (data, _) in source.items()})
    _require(archived == source, "archive source bytes differ from the release commit")
    return archived


def _bundle_content(root: Path, content: dict[str, tuple[bytes, int]], identity: ReleaseIdentity) -> None:
    _identity_fields(identity)
    _require(set(content) == set(APP_FILES), "bundle file set differs")
    source_info = _plist((Path(root) / "Resources/Info.plist").read_bytes())
    info = _plist(content["Contents/Info.plist"][0])
    expected = dict(source_info, TokenStatSourceRevision=identity.commit, TokenStatSourceState="clean")
    _require(info == expected, "bundle plist differs from source identity/provenance")
    _require(info.get("CFBundleShortVersionString") == identity.version
             and info.get("CFBundleVersion") == identity.build, "bundle version/build differs")
    _require(info.get("CFBundleIdentifier") == "com.tupig.TokenStatMenu"
             and info.get("CFBundleExecutable") == "TokenStatMenu"
             and info.get("CFBundleName") == "TokenStatMenu"
             and info.get("CFBundlePackageType") == "APPL"
             and info.get("CFBundleIconFile") == "AppIcon"
             and info.get("LSMinimumSystemVersion") == "13.0"
             and info.get("LSUIElement") is True, "unexpected application identity/platform")
    _require(content["Contents/Resources/AppIcon.icns"][0]
             == (Path(root) / "Resources/AppIcon.icns").read_bytes(), "bundle icon differs from source")
    _require(all(data and mode == APP_FILES[name] for name, (data, mode) in content.items()),
             "bundle has an empty file or incorrect mode")


def validate_app(root: Path, app: Path, identity: ReleaseIdentity, command_runner=subprocess.run) -> dict:
    app = Path(app)
    _require(not app.is_symlink() and app.is_dir(), "application is not a regular bundle directory")
    files, directories = {}, set()
    for path in app.rglob("*"):
        _require(not path.is_symlink(), "application contains a symbolic link")
        name = path.relative_to(app).as_posix()
        mode = path.stat().st_mode
        if stat.S_ISDIR(mode):
            directories.add(name)
        else:
            _require(stat.S_ISREG(mode) and name in APP_FILES, "application contains an unapproved file")
            _require(stat.S_IMODE(mode) == APP_FILES[name], "incorrect application file mode")
            files[name] = (path.read_bytes(), stat.S_IMODE(mode))
    _require(directories == APP_DIRECTORIES and set(files) == set(APP_FILES), "application full tree differs")
    _bundle_content(root, files, identity)
    try:
        arch = command_runner(["lipo", "-archs", str(app / "Contents/MacOS/TokenStatMenu")],
                              text=True, capture_output=True, check=False)
        _require(arch.returncode == 0 and set(arch.stdout.split()) == {"arm64", "x86_64"}
                 and len(arch.stdout.split()) == 2, "application must have exactly arm64 and x86_64")
        signed = command_runner(["codesign", "--verify", "--deep", "--strict", str(app)],
                                text=True, capture_output=True, check=False)
        _require(signed.returncode == 0, "strict application signature verification failed")
    except (OSError, subprocess.SubprocessError) as error:
        raise ValueError("native application validation tool failed") from error
    return files


def _names(identity: ReleaseIdentity) -> dict[str, str]:
    _identity_fields(identity)
    return {kind: f"TokenStatMenu-{identity.version}-{kind}.zip" for kind in ["universal", "source"]}


def _canonical_zip(path: Path, prefix: str, files: dict[str, tuple[bytes, int]]) -> None:
    # Release-only normalization: original payload/modes, fixed ZIP metadata.
    # The generic source exporter retains its existing behavior.
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, (data, mode) in sorted(files.items()):
            item = zipfile.ZipInfo(prefix + name, (2026, 1, 1, 0, 0, 0))
            item.create_system = 3
            item.external_attr = (stat.S_IFREG | mode) << 16
            item.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(item, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)


def _sums(directory: Path, names: list[str]) -> bytes:
    return "".join(hashlib.sha256((directory / name).read_bytes()).hexdigest() + "  " + name + "\n"
                   for name in sorted(names)).encode("ascii")


def package_assets(root: Path, app: Path, source_zip: Path, output_dir: Path,
                   identity: ReleaseIdentity) -> dict:
    fields = _identity_fields(identity)
    output_dir = Path(output_dir)
    _require(not output_dir.is_symlink(), "staging directory is a symbolic link")
    _require(not output_dir.exists() or (output_dir.is_dir() and not any(output_dir.iterdir())),
             "staging directory must be new or empty; existing content is never removed")
    source = validate_source_archive(root, source_zip, PUBLIC_FILES)
    bundle = validate_app(root, app, identity)
    output_dir.mkdir(parents=True, exist_ok=True)
    names = _names(identity)
    _canonical_zip(output_dir / names["source"], "TokenStatMenu/", source)
    _canonical_zip(output_dir / names["universal"], "TokenStatMenu.app/", bundle)
    manifest = dict(fields, assets={})
    for kind, name in names.items():
        data = (output_dir / name).read_bytes()
        manifest["assets"][kind] = dict(name=name, bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
    (output_dir / "release-manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                                                        encoding="utf-8")
    (output_dir / "SHA256SUMS").write_bytes(_sums(output_dir, [*names.values(), "release-manifest.json"]))
    return validate_assets(root, output_dir, identity)


def _unique_json(pairs: list[tuple]) -> dict:
    result = {}
    for key, value in pairs:
        _require(key not in result, "duplicate JSON key")
        result[key] = value
    return result


def validate_assets(root: Path, directory: Path, identity: ReleaseIdentity) -> dict:
    directory = Path(directory)
    fields, names = _identity_fields(identity), _names(identity)
    _require(not directory.is_symlink() and directory.is_dir(), "missing asset directory")
    expected = {*names.values(), "release-manifest.json", "SHA256SUMS"}
    files = list(directory.iterdir())
    _require({path.name for path in files} == expected
             and all(not path.is_symlink() and path.is_file() and stat.S_ISREG(path.stat().st_mode)
                     for path in files), "asset directory must contain exactly four regular files")
    try:
        manifest = json.loads((directory / "release-manifest.json").read_text(encoding="utf-8"),
                              object_pairs_hook=_unique_json)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ValueError("invalid release manifest JSON") from error
    _require(isinstance(manifest, dict) and set(manifest) == {*fields, "assets"}, "unexpected manifest keys")
    _require(all(manifest[key] == value for key, value in fields.items()), "manifest release identity differs")
    assets = manifest["assets"]
    _require(isinstance(assets, dict) and set(assets) == set(names), "unexpected manifest asset keys")
    for kind, name in names.items():
        item = assets[kind]
        _require(isinstance(item, dict) and set(item) == {"name", "bytes", "sha256"}, "unexpected asset fields")
        _require(item["name"] == name and type(item["bytes"]) is int and item["bytes"] > 0
                 and isinstance(item["sha256"], str) and SHA_PATTERN.fullmatch(item["sha256"]) is not None,
                 "invalid asset name, byte count or digest")
        data = (directory / name).read_bytes()
        _require(len(data) == item["bytes"] and hashlib.sha256(data).hexdigest() == item["sha256"],
                 "asset byte count/digest mismatch")
    _require((directory / "SHA256SUMS").read_bytes()
             == _sums(directory, [*names.values(), "release-manifest.json"]), "checksum file differs")
    validate_source_archive(root, directory / names["source"], PUBLIC_FILES)
    bundle = _zip_files(directory / names["universal"], "TokenStatMenu.app/", set(APP_FILES), APP_FILES)
    _bundle_content(root, bundle, identity)
    return manifest


def publish_release(root: Path, directory: Path, identity: ReleaseIdentity, client) -> str:
    """Validate before writes; a conflicting release is never overwritten.

    Failures after upload leave a draft. Failure after publish is a readback
    failure and is never described as a rollback or a successful publication.
    """
    validate_assets(root, directory, identity)
    paths = {path.name: path for path in Path(directory).iterdir()}
    _require(client.resolve_tag(identity.tag) == identity.commit, "remote tag moved or differs")
    remote = client.lookup(identity.tag)
    if remote is not None:
        _require(remote.get("tag") == identity.tag and type(remote.get("draft")) is bool
                 and remote.get("prerelease") is False,
                 "remote release identity is invalid")
        existing = client.list_assets(remote["id"])
        _require(len(existing) == len(set(existing)) and set(existing) <= set(paths), "unexpected remote asset set")
        _require(remote["draft"] or set(existing) == set(paths), "published release has missing assets")
        for name in existing:
            _require(client.download(remote["id"], name) == paths[name].read_bytes(), "conflicting remote asset bytes")
        if not remote["draft"]:
            return "already-published"
    else:
        remote = client.create_draft(identity)
        _require(remote.get("tag") == identity.tag and remote.get("draft") is True
                 and remote.get("prerelease") is False,
                 "new release must be the matching draft")
        existing = []
    for name in sorted(set(paths) - set(existing)):
        client.upload(remote["id"], paths[name])

    def readback(release_id: int) -> None:
        actual = client.list_assets(release_id)
        _require(len(actual) == len(set(actual)) and set(actual) == set(paths), "remote asset set differs")
        for name, path in sorted(paths.items()):
            _require(client.download(release_id, name) == path.read_bytes(), "remote asset readback differs")
        _require(client.resolve_tag(identity.tag) == identity.commit, "remote tag changed during publication")

    readback(remote["id"])
    client.publish(remote["id"])
    final = client.lookup(identity.tag)
    _require(final is not None and final.get("id") == remote["id"] and final.get("tag") == identity.tag
             and final.get("draft") is False and final.get("prerelease") is False,
             "post-publication release readback failed")
    readback(final["id"])
    return "published"


class GitHubClient:
    """Small fixed-repository GitHub CLI adapter; response bodies stay private."""
    def __init__(self, identity: ReleaseIdentity):
        self.identity = identity
        self.base = "repos/" + REPOSITORY
        self.asset_ids: dict[tuple[int, str], int] = {}

    def _command(self, arguments: list[str], phase: str) -> bytes:
        result = subprocess.run(["gh", *arguments], capture_output=True)
        if result.returncode:
            raise RuntimeError("GitHub " + phase + " failed; remote state was preserved")
        return result.stdout

    def _get(self, path: str, *, missing: bool = False):
        result = subprocess.run(["gh", "api", "--hostname", "github.com", "--include", path], capture_output=True)
        # --include exposes the actual HTTP status. Only an explicit 404 is a
        # missing release; authentication, transport and service errors fail.
        match = re.match(rb"HTTP/\S+\s+(\d{3})[^\r\n]*\r?\n", result.stdout)
        if match and match.group(1) == b"404" and missing:
            return None
        if result.returncode or not match or match.group(1) != b"200":
            raise RuntimeError("GitHub read failed; no missing-release assumption was made")
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
            _require(isinstance(digest, str) and COMMIT_PATTERN.fullmatch(digest) is not None,
                     "invalid remote Git object")
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
            _require(isinstance(releases, list) and len(releases) < 100,
                     "remote release list is invalid or incomplete")
            matching = [item for item in releases
                        if isinstance(item, dict) and item.get("tag_name") == tag]
            _require(len(matching) <= 1, "multiple remote releases match the requested tag")
            value = matching[0] if matching else None
            if value is None:
                return None
            # A tag endpoint miss is only recoverable for the intended draft
            # resume path. A published/prerelease match indicates conflicting
            # remote state and must fail closed rather than be guessed at.
            _require(type(value.get("draft")) is bool and value.get("draft") is True
                     and type(value.get("prerelease")) is bool and value.get("prerelease") is False,
                     "tag lookup miss found a non-resumable remote release")
        _require(type(value.get("id")) is int and type(value.get("draft")) is bool
                 and type(value.get("prerelease")) is bool,
                 "invalid remote release metadata")
        return dict(id=value["id"], tag=value.get("tag_name"), draft=value["draft"],
                    prerelease=value["prerelease"])

    def list_assets(self, release_id: int) -> list[str]:
        _require(type(release_id) is int and release_id > 0, "invalid remote release ID")
        value = self._get(self.base + f"/releases/{release_id}/assets?per_page=100")
        # The required set has four files. A full page already proves a conflict;
        # never hide additional pages behind an apparently complete four names.
        _require(isinstance(value, list) and len(value) < 100, "remote asset list is invalid or excessive")
        names = []
        for item in value:
            _require(isinstance(item, dict) and isinstance(item.get("name"), str)
                     and type(item.get("id")) is int and item["id"] > 0, "invalid remote asset metadata")
            names.append(item["name"])
            self.asset_ids[(release_id, item["name"])] = item["id"]
        return names

    def create_draft(self, identity: ReleaseIdentity) -> dict:
        _require(identity == self.identity, "unexpected draft identity")
        notes = (f"TokenStatMenu {identity.version} (build {identity.build}).\n\n"
                 "macOS 13 or later; Universal arm64 and x86_64.\n"
                 "This archive is ad hoc signed for local development. It is not Developer ID signed or notarized.\n"
                 f"Public source commit: {identity.commit}.\n")
        with tempfile.TemporaryDirectory(prefix="tokenstat-release-notes-") as temporary:
            path = Path(temporary) / "notes.md"
            path.write_text(notes, encoding="utf-8")
            self._command(["release", "create", identity.tag, "--repo", "github.com/" + REPOSITORY,
                           "--verify-tag", "--draft", "--title", "TokenStatMenu " + identity.version,
                           "--notes-file", str(path)], "create-draft")
        remote = self.lookup(identity.tag)
        _require(remote is not None, "created draft could not be read back")
        return remote

    def upload(self, release_id: int, path: Path) -> None:
        self._command(["release", "upload", self.identity.tag, str(path), "--repo", "github.com/" + REPOSITORY],
                      "upload")

    def download(self, release_id: int, name: str) -> bytes:
        asset_id = self.asset_ids.get((release_id, name))
        _require(type(asset_id) is int, "remote asset ID was not enumerated")
        return self._command(["api", "--hostname", "github.com", "--header", "Accept: application/octet-stream",
                              self.base + f"/releases/assets/{asset_id}"], "download")

    def publish(self, release_id: int) -> None:
        self._command(["release", "edit", self.identity.tag, "--repo", "github.com/" + REPOSITORY,
                       "--draft=false"], "publish")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["preflight", "package", "verify", "publish"])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--directory", type=Path)
    args = parser.parse_args()
    try:
        identity = release_identity(args.root, args.tag, args.commit)
        if args.operation == "package":
            _require(args.app is not None and args.source is not None and args.directory is not None,
                     "package requires --app, --source and --directory")
            package_assets(args.root, args.app, args.source, args.directory, identity)
        elif args.operation in ["verify", "publish"]:
            _require(args.directory is not None, "verify/publish requires --directory")
            if args.operation == "verify":
                validate_assets(args.root, args.directory, identity)
            else:
                outcome = publish_release(args.root, args.directory, identity, GitHubClient(identity))
                print("Release outcome: " + outcome)
        print("Release " + args.operation + " verified: " + identity.tag + " @ " + identity.commit)
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as error:
        # The messages above are deliberately fixed and contain no raw API data.
        print("Release " + args.operation + " failed: " + type(error).__name__, file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
