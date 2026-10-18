#!/usr/bin/env python3
"""Check only publication Markdown links; no network or third-party packages.

Supports inline/reference links, HTML img src, GitHub-style heading suffixes,
and explicit HTML ids. Fenced and inline code are excluded from link parsing.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import html
import posixpath
from pathlib import Path
import re
import tempfile
import unicodedata
from urllib.parse import unquote, urlsplit, urlunsplit


@dataclass(frozen=True)
class Link:
    destination: str
    start: int
    end: int
    line: int


def mask_fences(text: str) -> str:
    result = []
    fence = None
    for line in text.splitlines(keepends=True):
        marker = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", line.rstrip("\r\n"))
        if fence:
            result.append(re.sub(r"[^\r\n]", " ", line))
            if marker and marker[1][0] == fence[0] and len(marker[1]) >= fence[1] and not marker[2].strip():
                fence = None
        elif marker:
            fence = (marker[1][0], len(marker[1]))
            result.append(re.sub(r"[^\r\n]", " ", line))
        else:
            result.append(line)
    return "".join(result)


def mask_inline_code(text: str) -> str:
    # Equal-length backtick runs are paired; length and line numbers survive.
    chars = list(text)
    runs = list(re.finditer(r"`+", text))
    index = 0
    while index < len(runs):
        opening = runs[index]
        closing = next((j for j in range(index + 1, len(runs)) if len(runs[j][0]) == len(opening[0])), None)
        if closing is None:
            index += 1
            continue
        for position in range(opening.start(), runs[closing].end()):
            if chars[position] not in "\r\n":
                chars[position] = " "
        index = closing + 1
    return "".join(chars)


def normalized_label(value: str) -> str:
    return " ".join(value.split()).casefold()


def links_in(text: str) -> tuple[list[Link], list[tuple[int, str]]]:
    masked = mask_inline_code(mask_fences(text))
    links: list[Link] = []
    failures = []
    definitions = {}
    definition_spans = []
    pattern = r"(?m)^ {0,3}\[([^\]\n]+)\]:[ \t]*(?:<([^>\n]+)>|(\S+))"
    for match in re.finditer(pattern, masked):
        group = 2 if match[2] is not None else 3
        definitions.setdefault(normalized_label(match[1]), match[group])
        definition_spans.append((match.start(), match.end()))
        links.append(Link(match[group], match.start(group), match.end(group), text.count("\n", 0, match.start()) + 1))
    for match in re.finditer(r"!?\[([^\]\n]*)\]\(", masked):
        position = match.end()
        while position < len(masked) and masked[position].isspace():
            position += 1
        if position >= len(masked):
            continue
        start = position
        if masked[position] == "<":
            start += 1
            end = masked.find(">", start)
            if end < 0:
                continue
        else:
            depth = 0
            while position < len(masked):
                char = masked[position]
                if char == "\\" and position + 1 < len(masked):
                    position += 2
                    continue
                if char == "(":
                    depth += 1
                elif char == ")":
                    if depth == 0:
                        break
                    depth -= 1
                elif char.isspace() and depth == 0:
                    break
                position += 1
            end = position
        if end > start:
            links.append(Link(text[start:end], start, end, text.count("\n", 0, start) + 1))
    # Definitions themselves are checked above. Explicit unresolved references
    # are errors; bracketed prose without a reference definition is ordinary text.
    for match in re.finditer(r"!?\[([^\]\n]+)\](?:\[([^\]\n]*)\])?", masked):
        if any(a <= match.start() < b for a, b in definition_spans):
            continue
        if masked[match.end():].startswith("("):
            continue
        label = normalized_label(match[2] or match[1])
        if match[2] is not None and label not in definitions:
            failures.append((text.count("\n", 0, match.start()) + 1, "undefined reference link"))
    for match in re.finditer(r"(?is)<img\b[^>]*?\bsrc\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))", masked):
        group = next(i for i in (1, 2, 3) if match[i] is not None)
        links.append(Link(text[match.start(group):match.end(group)], match.start(group), match.end(group), text.count("\n", 0, match.start()) + 1))
    return sorted(set(links), key=lambda link: link.start), failures


def heading_anchors(text: str) -> set[str]:
    masked = mask_fences(text)
    used: set[str] = set()
    lines = masked.splitlines()
    for index, line in enumerate(lines):
        atx = re.match(r"^ {0,3}#{1,6}(?:[ \t]+|$)(.*)$", line)
        if atx:
            title = re.sub(r"[ \t]+#+[ \t]*$", "", atx[1])
        elif index + 1 < len(lines) and line.strip() and re.fullmatch(r" {0,3}(?:=+|-+)[ \t]*", lines[index + 1]):
            title = line.strip()
        else:
            continue
        title = html.unescape(re.sub(r"<[^>]*>", "", title))
        title = re.sub(r"!?\[([^]]*)\]\([^)]*\)", r"\1", title)
        title = re.sub(r"(?<!\w)(_{1,3}|\*{1,3})(.*?)\1(?!\w)", r"\2", title)
        title = title.replace("`", "").lower()
        base = "".join(char for char in title if char in " _-" or unicodedata.category(char)[0] in "LNM").replace(" ", "-")
        slug = base
        suffix = 0
        while slug in used:
            suffix += 1
            slug = f"{base}-{suffix}"
        used.add(slug)
    used.update(html.unescape(match[2]) for match in re.finditer(r"\b(?:id|name)\s*=\s*([\"'])(.*?)\1", masked, re.IGNORECASE))
    return used


def local_parts(destination: str):
    value = html.unescape(re.sub(r"\\([\\()<> #])", r"\1", destination))
    if value.startswith("//"):
        return None
    parts = urlsplit(value)
    return None if parts.scheme or parts.netloc else parts


def rebase_links(text: str, source: str, destination: str) -> str:
    """Rebase copied prose without editing code fences or external URLs."""
    links, _ = links_in(text)
    for link in reversed(links):
        parts = local_parts(link.destination)
        if parts is None:
            continue
        target = posixpath.normpath(posixpath.join(posixpath.dirname(source), parts.path or posixpath.basename(source)))
        path = posixpath.relpath(target, posixpath.dirname(destination) or ".")
        replacement = urlunsplit(("", "", path, parts.query, parts.fragment))
        text = text[:link.start] + replacement + text[link.end:]
    return text


def check_documents(root: Path, names: list[str], allowed: set[str]) -> list[tuple[str, int, str]]:
    root = root.resolve()
    failures = []
    cache = {}
    for name in names:
        path = root / name
        if path.is_symlink() or not path.resolve().is_relative_to(root) or not path.is_file():
            failures.append((name, 0, "missing or unsafe documentation file"))
            continue
        text = path.read_text(encoding="utf-8")
        links, parsing_failures = links_in(text)
        failures.extend((name, line, error) for line, error in parsing_failures)
        for link in links:
            try:
                parts = local_parts(link.destination)
            except ValueError:
                failures.append((name, link.line, "malformed link destination"))
                continue
            if parts is None:
                continue
            local_path = unquote(parts.path)
            target = (path.parent / local_path if local_path else path).resolve()
            if local_path.startswith("/") or not target.is_relative_to(root):
                failures.append((name, link.line, "local link escapes publication root"))
                continue
            if not target.exists():
                failures.append((name, link.line, "missing local link target"))
                continue
            if target.is_dir():
                if parts.fragment:
                    failures.append((name, link.line, "directory link cannot have a heading anchor"))
                continue
            target_name = target.relative_to(root).as_posix()
            if target_name not in allowed:
                failures.append((name, link.line, "link target is not on publication allowlist"))
                continue
            if parts.fragment and target.suffix.lower() == ".md":
                if target not in cache:
                    cache[target] = heading_anchors(target.read_text(encoding="utf-8"))
                if unquote(parts.fragment) not in cache[target]:
                    failures.append((name, link.line, "missing local heading anchor"))
    return failures


def self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="tokenstat-doc-links-fixture-") as temporary:
        root = Path(temporary)
        (root / "docs").mkdir()
        (root / "Assets").mkdir()
        (root / "Assets/icon.png").write_bytes(b"synthetic-file-fixture")
        (root / "docs/Guide.md").write_text("# Repeated\n# Repeated\n# Repeated-1\n# 中文标题\n", encoding="utf-8")
        allowed = {"README.md", "docs/Guide.md", "Assets/icon.png"}
        good = '# Home\n[guide](docs/Guide.md#repeated-1)\n[ref][guide]\n[guide]: docs/Guide.md#中文标题\n<img src="Assets/icon.png">\n`[literal](missing.md)`\n```md\n[ignored](../../outside)\n```\n'
        (root / "README.md").write_text(good, encoding="utf-8")
        assert not check_documents(root, ["README.md", "docs/Guide.md"], allowed)
        assert heading_anchors((root / "docs/Guide.md").read_text()) == {"repeated", "repeated-1", "repeated-1-1", "中文标题"}
        for link, expected in [("missing.md", "missing local link target"), ("docs/Guide.md#absent", "missing local heading anchor"), ("../../outside.md", "local link escapes publication root")]:
            (root / "README.md").write_text(f"[bad]({link})\n", encoding="utf-8")
            assert any(error == expected for _, _, error in check_documents(root, ["README.md"], allowed)), expected
        copied = rebase_links(good, "README.md", "docs/FULL_SOURCE.md")
        assert "[guide](Guide.md#repeated-1)" in copied and '<img src="../Assets/icon.png">' in copied
        assert "[guide]: Guide.md#中文标题" in copied
        assert "```md\n[ignored](../../outside)\n```" in copied
        self_link = "[home](#home) and [web](https://example.test/page#anchor)"
        rebased = rebase_links(self_link, "README.md", "docs/FULL_SOURCE.md")
        assert rebased == "[home](../README.md#home) and [web](https://example.test/page#anchor)"
        assert "`[literal](missing.md)`" in copied
    print("PASS: synthetic Markdown link, reference, HTML image, fence, duplicate-heading, missing-target, missing-anchor and escape fixtures")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true", help="Run synthetic positive/negative fixtures before checking publication docs")
    args = parser.parse_args()
    if args.self_test:
        self_test()
    from package_source import PUBLIC_FILES, ROOT
    names = [name for name in PUBLIC_FILES if name.lower().endswith(".md")]
    failures = check_documents(ROOT, names, set(PUBLIC_FILES))
    for name, line, reason in failures:
        print(f"FAIL {name}:{line}: {reason}")
    if failures:
        return 1
    print(f"PASS: local links and anchors in {len(names)} publication Markdown files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
