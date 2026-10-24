#!/usr/bin/env python3
"""Anonymous, read-only public Release verification for issue #60.

The caller must independently approve --tag and --commit. A manifest is never
a trust root. --directory must not exist; only its assets/ child is promoted
after all checks (including native, read-only DMG verification) succeed.
This command does not publish, install, launch, or sign an application.
"""

from __future__ import annotations

import argparse
import http.client
import io
import json
import os
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

import release_assets as release


API = "https://api.github.com/repos/" + release.REPOSITORY
WEB = "https://github.com/" + release.REPOSITORY
MAX_METADATA_BYTES = 2 * 1024 * 1024
MAX_ASSET_BYTES = 512 * 1024 * 1024
DOWNLOAD_HOSTS = frozenset(
    {
        "github.com",
        "release-assets.githubusercontent.com",
        "objects.githubusercontent.com",
    }
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def safe_url(url: str, hosts: frozenset[str]) -> None:
    require(
        isinstance(url, str)
        and url.isascii()
        and not any(ord(char) <= 32 or ord(char) == 127 for char in url)
        and "\\" not in url,
        "unsafe public URL",
    )
    parsed = urllib.parse.urlsplit(url)
    require(
        parsed.scheme == "https"
        and parsed.netloc in hosts
        and parsed.hostname in hosts
        and not parsed.username
        and not parsed.password
        and not parsed.fragment,
        "public URL must use an approved HTTPS host without credentials",
    )


class HTTPSRedirects(urllib.request.HTTPRedirectHandler):
    """Validate each hop before urllib can send any redirected request."""

    def redirect_request(self, request, response, code, message, headers, newurl):
        original = urllib.parse.urlsplit(request.full_url).hostname
        hosts = (
            frozenset({"api.github.com"})
            if original == "api.github.com"
            else DOWNLOAD_HOSTS
        )
        safe_url(newurl, hosts)
        return super().redirect_request(
            request, response, code, message, headers, newurl
        )


class AnonymousTransport:
    """Isolated GET-only transport; no global opener, proxy, netrc or tokens.

    The injectable get(url, destination, limit) protocol writes bytes to a
    binary stream. Neither environment proxy credentials nor GitHub CLI
    authentication are consulted. Responses and errors are never logged.
    """

    def __init__(self):
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPSHandler(context=ssl.create_default_context()),
            HTTPSRedirects(),
        )
        self.opener.addheaders = [("User-Agent", "TokenStatMenu-public-verifier")]

    def get(self, url: str, destination, limit: int) -> None:
        safe_url(url, DOWNLOAD_HOSTS | {"api.github.com"})
        request = urllib.request.Request(
            url,
            headers={"Accept": "*/*", "Accept-Encoding": "identity"},
            method="GET",
        )
        with self.opener.open(request, timeout=60) as response:
            require(response.status == 200, "public GET did not return HTTP 200")
            hosts = (
                frozenset({"api.github.com"})
                if urllib.parse.urlsplit(url).hostname == "api.github.com"
                else DOWNLOAD_HOSTS
            )
            safe_url(response.geturl(), hosts)
            size = response.headers.get("Content-Length")
            require(
                size is None
                or (size.isascii() and size.isdigit() and int(size) <= limit),
                "public response is too large or has an invalid length",
            )
            require(
                response.headers.get("Content-Encoding", "identity") == "identity",
                "unexpected public response encoding",
            )
            total = 0
            while True:
                chunk = response.read(min(1024 * 1024, limit - total + 1))
                if not chunk:
                    break
                total += len(chunk)
                require(total <= limit, "public response exceeds size limit")
                destination.write(chunk)
            require(size is None or total == int(size), "truncated public response")


def get_json(transport, url: str):
    stream = io.BytesIO()
    transport.get(url, stream, MAX_METADATA_BYTES)
    data = stream.getvalue()
    require(len(data) <= MAX_METADATA_BYTES, "public metadata exceeds size limit")
    try:
        return json.loads(data, object_pairs_hook=release._unique_json)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ValueError("invalid public metadata JSON") from error


def resolve_tag(transport, tag: str) -> str:
    ref_url = API + "/git/ref/tags/" + tag
    value = get_json(transport, ref_url)
    require(
        isinstance(value, dict)
        and value.get("ref") == "refs/tags/" + tag
        and value.get("url") == API + "/git/refs/tags/" + tag,
        "public tag reference differs",
    )
    seen = set()
    for _ in range(8):
        obj = value.get("object")
        require(isinstance(obj, dict), "invalid public Git object")
        digest, kind = obj.get("sha"), obj.get("type")
        require(
            isinstance(digest, str)
            and release.COMMIT_PATTERN.fullmatch(digest) is not None
            and isinstance(kind, str)
            and kind in {"commit", "tag"},
            "invalid public Git object identity",
        )
        object_url = (
            API + "/git/" + ("commits/" if kind == "commit" else "tags/") + digest
        )
        require(obj.get("url") == object_url, "public Git object repository differs")
        if kind == "commit":
            return digest
        require(digest not in seen, "cyclic public annotated tag")
        seen.add(digest)
        value = get_json(transport, object_url)
        require(
            isinstance(value, dict)
            and value.get("sha") == digest
            and value.get("url") == object_url,
            "public annotated tag differs",
        )
    raise ValueError("public annotated tag nesting is excessive")


def asset_records(items, identity, release_id: int) -> dict:
    names = {*release._names(identity).values(), "release-manifest.json", "SHA256SUMS"}
    require(len(names) == 5, "this verifier requires the five-asset DMG contract")
    require(isinstance(items, list) and len(items) == 5, "public asset set differs")
    records, ids = {}, set()
    for item in items:
        require(isinstance(item, dict), "invalid public asset metadata")
        name, asset_id, size = item.get("name"), item.get("id"), item.get("size")
        require(
            isinstance(name, str)
            and name in names
            and name not in records
            and type(asset_id) is int
            and asset_id > 0
            and asset_id not in ids
            and type(size) is int
            and 0 < size <= MAX_ASSET_BYTES
            and item.get("state") == "uploaded",
            "invalid public asset name, ID, state or size",
        )
        browser_url = WEB + "/releases/download/" + identity.tag + "/" + name
        require(
            item.get("url") == API + "/releases/assets/" + str(asset_id)
            and item.get("browser_download_url") == browser_url,
            "public asset URL, tag or repository differs",
        )
        records[name] = (asset_id, size, browser_url)
        ids.add(asset_id)
    require(set(records) == names, "public asset set differs")
    return records


def read_release(transport, identity) -> tuple[int, dict]:
    value = get_json(transport, API + "/releases/tags/" + identity.tag)
    require(isinstance(value, dict), "invalid public Release metadata")
    release_id = value.get("id")
    require(type(release_id) is int and release_id > 0, "invalid public Release ID")
    require(
        value.get("draft") is False
        and value.get("prerelease") is False
        and value.get("tag_name") == identity.tag
        and isinstance(value.get("published_at"), str)
        and bool(value["published_at"])
        and value.get("url") == API + "/releases/" + str(release_id)
        and value.get("html_url") == WEB + "/releases/tag/" + identity.tag
        and value.get("assets_url") == API + "/releases/" + str(release_id) + "/assets",
        "Release is not the approved, published stable Release",
    )
    embedded = asset_records(value.get("assets"), identity, release_id)
    # Do not trust a possibly truncated embedded list to prove no extra assets.
    listed = asset_records(
        get_json(transport, value["assets_url"] + "?per_page=100"), identity, release_id
    )
    require(embedded == listed, "public Release asset listings disagree")
    return release_id, listed


def download_asset(transport, url: str, directory: Path, name: str, size: int) -> None:
    temporary = directory / (name + ".part")
    with temporary.open("xb") as stream:
        transport.get(url, stream, size)
        require(stream.tell() == size, "downloaded asset size differs from GitHub")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, directory / name)


def verify_public_release(
    root: Path, directory: Path, tag: str, commit: str, *, transport=None
) -> Path:
    """Return the verified assets directory; failures never promote assets/."""
    require(
        isinstance(tag, str) and release.TAG_PATTERN.fullmatch(tag) is not None,
        "an independently approved stable tag is required",
    )
    require(
        isinstance(commit, str)
        and release.COMMIT_PATTERN.fullmatch(commit) is not None,
        "an independently approved full commit is required",
    )
    # This reads reviewed source metadata, not the untrusted remote manifest.
    identity = release.release_identity(root, tag, commit)
    require(identity.tag == tag and identity.commit == commit, "local identity differs")
    require("dmg" in release._names(identity), "five-asset DMG contract required")
    directory = Path(directory)
    directory.mkdir(mode=0o700, parents=False, exist_ok=False)
    if transport is None:
        transport = AnonymousTransport()
    require(resolve_tag(transport, tag) == commit, "public tag commit differs")
    before = read_release(transport, identity)
    with tempfile.TemporaryDirectory(prefix=".incomplete-", dir=directory) as temporary:
        staging = Path(temporary)
        for name, (_, size, url) in sorted(before[1].items()):
            download_asset(transport, url, staging, name, size)
        release.validate_assets(root, staging, identity, validate_dmg_image=True)
        require(read_release(transport, identity) == before, "public Release changed")
        require(resolve_tag(transport, tag) == commit, "public tag moved")
        verified = directory / "assets"
        # The parent is exclusively created above; no caller-owned file is replaced.
        staging.rename(verified)
    return verified


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root", type=Path, default=Path(__file__).resolve().parents[1]
    )
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    args = parser.parse_args(argv)
    try:
        result = verify_public_release(args.root, args.directory, args.tag, args.commit)
    except (
        ValueError,
        RuntimeError,
        OSError,
        subprocess.SubprocessError,
        http.client.HTTPException,
    ):
        print(
            "Public Release verification failed; no verified assets promoted.",
            file=sys.stderr,
        )
        return 1
    print("Public Release verified: " + args.tag + " @ " + args.commit)
    print("Verified assets: " + str(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
