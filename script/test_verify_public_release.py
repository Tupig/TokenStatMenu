#!/usr/bin/env python3
"""Offline regression checks for #60; synthetic releases are not publication proof."""

from __future__ import annotations

import contextlib
import copy
import hashlib
import http.client
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import urllib.error
import urllib.request
import zipfile

import release_assets as release
import verify_public_release as public


TAG = "v9.8.7"
COMMIT = "a" * 40
IDENTITY = release.ReleaseIdentity("9.8.7", "42", TAG, COMMIT)
REF_URL = public.API + "/git/ref/tags/" + TAG
RELEASE_URL = public.API + "/releases/tags/" + TAG
ASSETS_URL = public.API + "/releases/7/assets?per_page=100"


def credential_url(scheme, host, path=""):
    """在运行时构造合成凭据负例，不在公开源码中放完整凭据 URL。"""
    credentials = "user" + ":" + "secret" + "@"
    return scheme + "://" + credentials + host + path


class FakeTransport:
    def __init__(self):
        names = release._names(IDENTITY)
        self.payloads = {
            name: ("synthetic-" + name).encode() for name in names.values()
        }
        synthetic_zip = io.BytesIO()
        with zipfile.ZipFile(synthetic_zip, "w") as archive:
            archive.writestr("TokenStatMenu.app/Contents/Info.plist", b"synthetic")
        self.payloads[names["universal"]] = synthetic_zip.getvalue()
        manifest = {
            "version": IDENTITY.version,
            "build": IDENTITY.build,
            "tag": TAG,
            "commit": COMMIT,
            "assets": {
                kind: {
                    "name": name,
                    "bytes": len(self.payloads[name]),
                    "sha256": hashlib.sha256(self.payloads[name]).hexdigest(),
                }
                for kind, name in names.items()
            },
        }
        self.payloads["release-manifest.json"] = json.dumps(manifest).encode()
        self.refresh_sums()
        self.release = {
            "id": 7,
            "tag_name": TAG,
            "draft": False,
            "prerelease": False,
            "published_at": "2000-01-01T00:00:00Z",
            "url": public.API + "/releases/7",
            "html_url": public.WEB + "/releases/tag/" + TAG,
            "assets_url": public.API + "/releases/7/assets",
            "assets": [],
        }
        for asset_id, (name, data) in enumerate(sorted(self.payloads.items()), 1):
            self.release["assets"].append(
                {
                    "id": asset_id,
                    "name": name,
                    "size": len(data),
                    "state": "uploaded",
                    "url": public.API + "/releases/assets/" + str(asset_id),
                    "browser_download_url": public.WEB
                    + "/releases/download/"
                    + TAG
                    + "/"
                    + name,
                }
            )
        self.ref = {
            "ref": "refs/tags/" + TAG,
            "url": public.API + "/git/refs/tags/" + TAG,
            "object": {
                "type": "commit",
                "sha": COMMIT,
                "url": public.API + "/git/commits/" + COMMIT,
            },
        }
        self.calls = []
        self.failure = None
        self.after_download = None
        self.other = {}
        self.listing = None

    def refresh_sums(self):
        self.payloads["SHA256SUMS"] = "".join(
            hashlib.sha256(data).hexdigest() + "  " + name + "\n"
            for name, data in sorted(self.payloads.items())
            if name != "SHA256SUMS"
        ).encode()

    def get(self, url, destination, limit):
        self.calls.append((url, limit))
        if self.failure == url:
            destination.write(b"partial")
            raise OSError("synthetic download failure")
        if url == REF_URL:
            data = json.dumps(self.ref).encode()
        elif url == RELEASE_URL:
            data = json.dumps(self.release).encode()
        elif url == ASSETS_URL:
            data = json.dumps(
                self.release["assets"] if self.listing is None else self.listing
            ).encode()
        elif url in self.other:
            data = json.dumps(self.other[url]).encode()
        else:
            matches = [
                item
                for item in self.release["assets"]
                if item["browser_download_url"] == url
            ]
            if len(matches) != 1:
                raise AssertionError("unexpected synthetic GET")
            data = self.payloads[matches[0]["name"]]
            if self.after_download:
                self.after_download()
        destination.write(data)


class PublicReleaseTests(unittest.TestCase):
    def setUp(self):
        # A regression must never accidentally reach the actual network/tools.
        self.network = mock.patch(
            "socket.socket", side_effect=AssertionError("network forbidden")
        )
        self.network.start()
        self.addCleanup(self.network.stop)
        self.native_commands = mock.patch(
            "subprocess.run", side_effect=AssertionError("native execution forbidden")
        )
        self.native_commands.start()
        self.addCleanup(self.native_commands.stop)
        self.temporary = tempfile.TemporaryDirectory(prefix="tokenstat-public-test-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / "reviewed-source"
        self.directory = self.base / "download"
        self.transport = FakeTransport()
        self.identity = self.start_patch("release_identity", return_value=IDENTITY)
        self.validate = self.start_patch("validate_assets", return_value={})

    def start_patch(self, name, **kwargs):
        patch = mock.patch.object(release, name, **kwargs)
        result = patch.start()
        self.addCleanup(patch.stop)
        return result

    def verify(self, **kwargs):
        return public.verify_public_release(
            self.root,
            self.directory,
            kwargs.get("tag", TAG),
            kwargs.get("commit", COMMIT),
            transport=self.transport,
        )

    def assert_no_success(self):
        self.assertFalse((self.directory / "assets").exists())
        if self.directory.exists():
            self.assertEqual(list(self.directory.iterdir()), [])

    def test_success_promotes_exact_set_and_forces_native_validation(self):
        result = self.verify()
        self.assertEqual(result, self.directory / "assets")
        self.assertEqual(
            {path.name for path in result.iterdir()}, set(self.transport.payloads)
        )
        for name, data in self.transport.payloads.items():
            self.assertEqual((result / name).read_bytes(), data)
        self.identity.assert_called_once_with(self.root, TAG, COMMIT)
        self.validate.assert_called_once()
        args, kwargs = self.validate.call_args
        self.assertEqual(args[0], self.root)
        self.assertEqual(args[2], IDENTITY)
        self.assertEqual(kwargs, {"validate_dmg_image": True})
        self.assertTrue(args[1].name.startswith(".incomplete-"))
        self.assertEqual(len(self.transport.calls), 11)
        self.assertEqual(list(self.directory.iterdir()), [result])

    def test_invalid_approved_inputs_fail_before_local_or_remote_reads(self):
        for kwargs in [
            {"tag": ""},
            {"tag": "v1.2.3-rc1"},
            {"tag": "v01.2.3"},
            {"tag": "v1.2.3\n"},
            {"commit": ""},
            {"commit": "a" * 39},
            {"commit": "A" * 40},
            {"commit": "a" * 40 + "\n"},
        ]:
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                self.verify(**kwargs)
        self.identity.assert_not_called()
        self.assertEqual(self.transport.calls, [])

    def test_local_trust_failure_never_uses_manifest_or_network(self):
        self.identity.side_effect = ValueError("unapproved local source")
        with self.assertRaises(ValueError):
            self.verify()
        self.assertEqual(self.transport.calls, [])
        self.assertFalse(self.directory.exists())

    def test_existing_directory_or_symlink_is_never_reused(self):
        self.directory.mkdir()
        marker = self.directory / "keep"
        marker.write_bytes(b"caller content")
        with self.assertRaises(FileExistsError):
            self.verify()
        self.assertEqual(marker.read_bytes(), b"caller content")
        link = self.base / "link"
        link.symlink_to(self.directory, target_is_directory=True)
        with self.assertRaises(FileExistsError):
            public.verify_public_release(
                self.root, link, TAG, COMMIT, transport=self.transport
            )
        self.assertEqual(self.transport.calls, [])

    def test_wrong_public_commit_is_rejected(self):
        self.transport.ref["object"].update(
            sha="b" * 40, url=public.API + "/git/commits/" + "b" * 40
        )
        with self.assertRaises(ValueError):
            self.verify()
        self.assert_no_success()
        self.validate.assert_not_called()

    def test_annotated_tag_peels_to_independently_approved_commit(self):
        digest = "b" * 40
        url = public.API + "/git/tags/" + digest
        commit_object = copy.deepcopy(self.transport.ref["object"])
        self.transport.ref["object"] = {"type": "tag", "sha": digest, "url": url}
        self.transport.other[url] = {"sha": digest, "url": url, "object": commit_object}
        self.verify()
        self.assertIn((url, public.MAX_METADATA_BYTES), self.transport.calls)

    def test_cyclic_annotated_tag_is_rejected(self):
        digest = "b" * 40
        url = public.API + "/git/tags/" + digest
        obj = {"type": "tag", "sha": digest, "url": url}
        self.transport.ref["object"] = obj
        self.transport.other[url] = {"sha": digest, "url": url, "object": obj}
        with self.assertRaises(ValueError):
            self.verify()
        self.assert_no_success()

    def test_malformed_git_object_type_is_a_validation_error(self):
        for kind in [None, [], {}, 42, "tree"]:
            self.transport.ref["object"]["type"] = kind
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                public.resolve_tag(self.transport, TAG)

    def test_wrong_tag_ref_or_object_repository_is_rejected(self):
        original = copy.deepcopy(self.transport.ref)
        for field, value in [
            ("ref", "refs/tags/v0.0.1"),
            ("url", "https://example.invalid/ref"),
        ]:
            self.transport.ref = copy.deepcopy(original)
            self.transport.ref[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                public.resolve_tag(self.transport, TAG)
        self.transport.ref = original
        self.transport.ref["object"]["url"] = (
            "https://api.github.com/repos/Other/Repo/git/commits/" + COMMIT
        )
        with self.assertRaises(ValueError):
            public.resolve_tag(self.transport, TAG)

    def test_unpublished_unstable_or_wrong_release_metadata_is_rejected(self):
        original = copy.deepcopy(self.transport.release)
        changes = [
            ("draft", True),
            ("draft", 0),
            ("draft", None),
            ("prerelease", True),
            ("prerelease", 0),
            ("tag_name", "v0.0.1"),
            ("published_at", None),
            ("published_at", ""),
            ("id", True),
            ("url", public.API + "/releases/8"),
            ("html_url", "https://github.com/Other/Repo/releases/tag/" + TAG),
            ("assets_url", "https://api.github.com/repos/Other/Repo/releases/7/assets"),
        ]
        for field, value in changes:
            self.transport.release = copy.deepcopy(original)
            self.transport.release[field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                public.read_release(self.transport, IDENTITY)

    def test_asset_name_size_state_id_and_url_contract(self):
        original = copy.deepcopy(self.transport.release["assets"])
        changes = [
            ("name", "../escape"),
            ("name", "extra.zip"),
            ("size", 0),
            ("size", -1),
            ("size", True),
            ("size", "42"),
            ("size", public.MAX_ASSET_BYTES + 1),
            ("state", "new"),
            ("id", True),
            ("id", 0),
            (
                "url",
                public.API.replace("Tupig/TokenStatMenu", "Other/Repo")
                + "/releases/assets/1",
            ),
            ("browser_download_url", "http://github.com/download"),
            (
                "browser_download_url",
                public.WEB + "/releases/download/v0.0.1/SHA256SUMS",
            ),
            (
                "browser_download_url",
                credential_url("https", "github.com", "/download"),
            ),
            ("browser_download_url", "https://github.com/Other/Repo/download"),
        ]
        for field, value in changes:
            items = copy.deepcopy(original)
            items[0][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                public.asset_records(items, IDENTITY, 7)

    def test_missing_extra_duplicate_or_unlisted_asset_is_rejected(self):
        items = self.transport.release["assets"]
        for changed in [items[:-1], items + [items[0]], items[:-1] + [items[0]]]:
            with self.subTest(length=len(changed)), self.assertRaises(ValueError):
                public.asset_records(changed, IDENTITY, 7)
        self.transport.listing = copy.deepcopy(items)
        self.transport.listing[0]["size"] += 1
        with self.assertRaises(ValueError):
            self.verify()
        self.assert_no_success()

    def test_each_download_failure_removes_incomplete_assets(self):
        for item in self.transport.release["assets"]:
            with self.subTest(asset=item["name"]):
                self.directory = self.base / ("failure-" + item["name"])
                self.transport.failure = item["browser_download_url"]
                with self.assertRaises(OSError):
                    self.verify()
                self.assert_no_success()
        self.validate.assert_not_called()

    def test_truncated_or_oversized_download_is_not_promoted(self):
        name = "TokenStatMenu.dmg"
        original = self.transport.payloads[name]
        for data in [original[:-1], original + b"extra"]:
            self.transport.payloads[name] = data
            self.directory = self.base / ("size-" + str(len(data)))
            with self.assertRaises(ValueError):
                self.verify()
            self.assert_no_success()

    def test_native_verification_failure_is_not_success(self):
        self.validate.side_effect = ValueError("synthetic native DMG failure")
        with self.assertRaises(ValueError):
            self.verify()
        self.assert_no_success()

    def test_release_or_tag_race_is_not_promoted(self):
        for kind in ["release", "tag"]:
            self.directory = self.base / kind
            transport = FakeTransport()
            self.transport = transport

            def mutate():
                if kind == "release":
                    transport.release["id"] = 8
                else:
                    transport.ref["object"].update(
                        sha="b" * 40, url=public.API + "/git/commits/" + "b" * 40
                    )

            transport.after_download = mutate
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                self.verify()
            self.assert_no_success()

    def exercise_real_asset_verifier(self):
        # Keep the actual manifest/digest/checksum validation. Only source-tree,
        # ZIP decoding and native OS work are stubbed, with no app execution.
        self.validate.side_effect = None
        self.validate.wraps = None
        self.validate.side_effect = ORIGINAL_VALIDATE
        self.start_patch("validate_source_archive", return_value={})
        self.start_patch("_zip_files", return_value={})
        self.start_patch("_bundle_content", return_value=None)
        return self.start_patch("validate_dmg", return_value={})

    def test_actual_asset_verifier_checks_manifest_and_calls_native_dmg(self):
        native = self.exercise_real_asset_verifier()
        self.verify()
        native.assert_called_once()
        self.assertEqual(native.call_args.args[2], IDENTITY)

    def test_manifest_cannot_supply_its_own_commit_trust(self):
        self.exercise_real_asset_verifier()
        name = "release-manifest.json"
        value = json.loads(self.transport.payloads[name])
        value["commit"] = "b" * 40
        self.transport.payloads[name] = json.dumps(value).encode()
        self.transport.refresh_sums()
        with self.assertRaisesRegex(ValueError, "manifest release identity differs"):
            self.verify()
        self.assert_no_success()

    def test_same_size_corruption_fails_actual_digest_check(self):
        self.exercise_real_asset_verifier()
        name = "TokenStatMenu.dmg"
        data = self.transport.payloads[name]
        self.transport.payloads[name] = b"X" + data[1:]
        with self.assertRaisesRegex(ValueError, "digest mismatch"):
            self.verify()
        self.assert_no_success()

    def test_cli_requires_independent_tag_commit_and_destination(self):
        for args in [[], ["--tag", TAG], ["--tag", TAG, "--directory", "unused"]]:
            with self.subTest(args=args), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as caught:
                    public.main(args)
                self.assertEqual(caught.exception.code, 2)

    def test_cli_failure_is_nonzero_and_does_not_echo_remote_error(self):
        stderr, stdout = io.StringIO(), io.StringIO()
        with mock.patch.object(
            public, "verify_public_release", side_effect=OSError("SECRET")
        ):
            with contextlib.redirect_stderr(stderr), contextlib.redirect_stdout(stdout):
                code = public.main(
                    ["--tag", TAG, "--commit", COMMIT, "--directory", "unused"]
                )
        self.assertEqual(code, 1)
        self.assertEqual(stdout.getvalue(), "")
        self.assertNotIn("SECRET", stderr.getvalue())
        self.assertNotIn("verified:", stderr.getvalue())

    def test_duplicate_json_keys_are_rejected(self):
        transport = mock.Mock()
        transport.get.side_effect = lambda url, stream, limit: stream.write(
            b'{"id":7,"id":8}'
        )
        with self.assertRaisesRegex(ValueError, "duplicate JSON"):
            public.get_json(transport, RELEASE_URL)

    def test_real_main_sanitizes_http_protocol_errors_without_traceback(self):
        canary = "REMOTE_SECRET_STATUS"
        errors = [
            http.client.BadStatusLine(canary + "\r\n"),
            http.client.IncompleteRead(canary.encode(), 100),
            http.client.HTTPException(canary),
        ]
        for index, error in enumerate(errors):
            self.directory = self.base / ("http-error-" + str(index))
            stderr, stdout = io.StringIO(), io.StringIO()
            with (
                self.subTest(error=type(error).__name__),
                mock.patch.object(
                    urllib.request.OpenerDirector, "open", side_effect=error
                ) as get,
                contextlib.redirect_stderr(stderr),
                contextlib.redirect_stdout(stdout),
            ):
                code = public.main(
                    [
                        "--root",
                        str(self.root),
                        "--tag",
                        TAG,
                        "--commit",
                        COMMIT,
                        "--directory",
                        str(self.directory),
                    ]
                )
            self.assertEqual(code, 1)
            self.assertEqual(stdout.getvalue(), "")
            self.assertEqual(
                stderr.getvalue(),
                "Public Release verification failed; no verified assets promoted.\n",
            )
            self.assertNotIn(canary, stderr.getvalue())
            self.assertNotIn("Traceback", stderr.getvalue())
            get.assert_called_once()
            self.assert_no_success()
        self.validate.assert_not_called()


ORIGINAL_VALIDATE = release.validate_assets


class TransportTests(unittest.TestCase):
    def setUp(self):
        patch = mock.patch(
            "socket.socket", side_effect=AssertionError("network forbidden")
        )
        patch.start()
        self.addCleanup(patch.stop)

    def response(self, body=b"abc", *, status=200, headers=None, url=None):
        result = mock.MagicMock()
        result.__enter__.return_value = result
        result.status = status
        result.headers = {} if headers is None else headers
        result.geturl.return_value = public.WEB if url is None else url
        stream = io.BytesIO(body)
        result.read.side_effect = stream.read
        return result

    def test_anonymous_get_ignores_proxy_tokens_and_global_opener(self):
        environment = {
            "HTTPS_PROXY": credential_url("http", "proxy.invalid:3128"),
            "http_proxy": credential_url("http", "proxy.invalid:3128"),
            "ALL_PROXY": credential_url("socks5", "proxy.invalid"),
            "GH_TOKEN": "secret",
            "GITHUB_TOKEN": "secret",
        }
        with (
            mock.patch.dict(os.environ, environment),
            mock.patch.object(urllib.request, "_opener", mock.Mock()) as global_opener,
        ):
            transport = public.AnonymousTransport()
            proxies = [
                handler
                for handler in transport.opener.handlers
                if isinstance(handler, urllib.request.ProxyHandler)
            ]
            self.assertTrue(all(handler.proxies == {} for handler in proxies))
            forbidden = (
                urllib.request.HTTPCookieProcessor,
                urllib.request.AbstractBasicAuthHandler,
                urllib.request.AbstractDigestAuthHandler,
            )
            self.assertFalse(
                any(
                    isinstance(handler, forbidden)
                    for handler in transport.opener.handlers
                )
            )
            with mock.patch.object(
                transport.opener, "open", return_value=self.response()
            ) as get:
                stream = io.BytesIO()
                transport.get(public.WEB, stream, 3)
            request = get.call_args.args[0]
            self.assertEqual(request.get_method(), "GET")
            self.assertIsNone(request.data)
            self.assertFalse(
                any(
                    "authorization" in key.lower() or "cookie" in key.lower()
                    for key, _ in request.header_items()
                )
            )
            self.assertEqual(stream.getvalue(), b"abc")
            global_opener.open.assert_not_called()

    def test_unsafe_initial_and_redirect_urls_fail_before_open(self):
        bad_urls = [
            "http://github.com/file",
            "file:///etc/passwd",
            credential_url("https", "github.com", "/file"),
            "https://github.com:443/file",
            "https://github.com.evil.invalid/file",
            "https://example.invalid/file",
            "https://github.com/file#fragment",
            "https://github.com/file\n",
            "https://github.com\\@evil.invalid/file",
            "https://github.com/文",
        ]
        transport = public.AnonymousTransport()
        with mock.patch.object(transport.opener, "open") as get:
            for url in bad_urls:
                with self.subTest(url=url), self.assertRaises(ValueError):
                    transport.get(url, io.BytesIO(), 100)
                request = urllib.request.Request(public.WEB)
                with self.subTest(redirect=url), self.assertRaises(ValueError):
                    public.HTTPSRedirects().redirect_request(
                        request, None, 302, "", {}, url
                    )
            get.assert_not_called()

    def test_https_cdn_redirect_is_get_only_and_api_cannot_redirect_to_cdn(self):
        cdn = "https://release-assets.githubusercontent.com/path?signature=synthetic"
        result = public.HTTPSRedirects().redirect_request(
            urllib.request.Request(public.WEB), None, 302, "", {}, cdn
        )
        self.assertEqual(result.full_url, cdn)
        self.assertEqual(result.get_method(), "GET")
        with self.assertRaises(ValueError):
            public.HTTPSRedirects().redirect_request(
                urllib.request.Request(RELEASE_URL), None, 302, "", {}, cdn
            )

    def test_http_status_length_encoding_and_final_url_fail_closed(self):
        cases = [
            self.response(status=206),
            self.response(status=404),
            self.response(headers={"Content-Length": "4"}),
            self.response(headers={"Content-Length": "-1"}),
            self.response(headers={"Content-Length": "three"}),
            self.response(headers={"Content-Length": "2"}),
            self.response(headers={"Content-Encoding": "gzip"}),
            self.response(url="http://github.com/file"),
            self.response(body=b"abcd"),
        ]
        transport = public.AnonymousTransport()
        for response in cases:
            with mock.patch.object(transport.opener, "open", return_value=response):
                with self.subTest(response=response), self.assertRaises(ValueError):
                    transport.get(public.WEB, io.BytesIO(), 3)

    def test_service_or_auth_errors_do_not_become_missing_or_success(self):
        transport = public.AnonymousTransport()
        for status in [401, 403, 404, 429, 500]:
            error = urllib.error.HTTPError(public.WEB, status, "synthetic", {}, None)
            with (
                contextlib.closing(error),
                mock.patch.object(transport.opener, "open", side_effect=error),
            ):
                with (
                    self.subTest(status=status),
                    self.assertRaises(urllib.error.HTTPError),
                ):
                    transport.get(public.WEB, io.BytesIO(), 3)


if __name__ == "__main__":
    unittest.main()
