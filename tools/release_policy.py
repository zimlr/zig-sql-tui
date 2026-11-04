#!/usr/bin/env python3
"""Validate release versions and compare the candidate with published history."""

import argparse
from dataclasses import dataclass
from functools import cmp_to_key
import json
import re
import subprocess
import sys
from pathlib import Path


SEMVER = re.compile(
    r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?\Z",
    re.ASCII,
)


@dataclass(frozen=True)
class Version:
    core: tuple[str, str, str]
    prerelease: tuple[str, ...] | None


def parse_version(tag):
    match = SEMVER.fullmatch(tag)
    if not match:
        raise ValueError(f"Invalid SemVer tag: {tag!r}")
    pre = tuple(match[4].split(".")) if match[4] is not None else None
    if pre and any(part.isdigit() and len(part) > 1 and part[0] == "0" for part in pre):
        raise ValueError(f"Numeric prerelease identifiers cannot have leading zeroes: {tag!r}")
    return Version(tuple(match[i] for i in range(1, 4)), pre)


def compare_number(left, right):
    if len(left) != len(right):
        return (len(left) > len(right)) - (len(left) < len(right))
    return (left > right) - (left < right)


def compare(left, right):
    for a, b in zip(left.core, right.core):
        if a != b:
            return compare_number(a, b)
    if left.prerelease is None or right.prerelease is None:
        return (left.prerelease is None) - (right.prerelease is None)
    for a, b in zip(left.prerelease, right.prerelease):
        if a == b:
            continue
        an, bn = a.isdigit(), b.isdigit()
        if an and bn:
            return compare_number(a, b)
        if an != bn:
            return -1 if an else 1
        return (a > b) - (a < b)
    return (len(left.prerelease) > len(right.prerelease)) - (len(left.prerelease) < len(right.prerelease))


def git(*args):
    return subprocess.run(["git", *args], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def validate(tag, pages, commit):
    candidate = parse_version(tag)
    if not isinstance(pages, list) or not all(isinstance(page, list) for page in pages):
        raise ValueError("Release API response must contain paginated release arrays")
    releases = [release for page in pages for release in page]
    if not all(isinstance(r, dict) and isinstance(r.get("tag_name"), str) and isinstance(r.get("draft"), bool) for r in releases):
        raise ValueError("Release API response contains an invalid release")
    if any(release["tag_name"] == tag for release in releases):
        raise ValueError("A release or draft already uses this tag")
    existing = git("show-ref", "--verify", "--quiet", f"refs/tags/{tag}")
    if existing.returncode == 0:
        raise ValueError("The requested tag already exists")
    if existing.returncode != 1:
        raise ValueError("Could not check the requested tag")
    target = git("rev-parse", "--verify", f"{commit}^{{commit}}")
    if target.returncode != 0:
        raise ValueError("Candidate commit cannot be resolved")
    published = [(parse_version(r["tag_name"]), r["tag_name"]) for r in releases if not r["draft"]]
    if not published:
        if tag != "v1.0.0":
            raise ValueError("The first published release must be v1.0.0")
        return candidate
    latest, latest_tag = max(published, key=cmp_to_key(lambda a, b: compare(a[0], b[0])))
    if sum(compare(version, latest) == 0 for version, _ in published) != 1:
        raise ValueError("Published releases have ambiguous highest SemVer precedence")
    if compare(candidate, latest) <= 0:
        raise ValueError(f"Release must have greater SemVer precedence than {latest_tag}")
    previous = git("rev-parse", "--verify", f"refs/tags/{latest_tag}^{{commit}}")
    if previous.returncode != 0:
        raise ValueError(f"Published release tag is missing or invalid: {latest_tag}")
    ancestor = git("merge-base", "--is-ancestor", previous.stdout.strip(), target.stdout.strip())
    if ancestor.returncode == 1:
        raise ValueError("The latest published release is not an ancestor of the candidate")
    if ancestor.returncode != 0:
        raise ValueError("Could not compare release history")
    diff = git("diff", "--quiet", previous.stdout.strip(), target.stdout.strip(), "--")
    if diff.returncode == 0:
        raise ValueError("No tracked changes since the latest published release")
    if diff.returncode != 1:
        raise ValueError("Could not compare release contents")
    return candidate


def read_pages(path):
    text = path.read_text(encoding="utf-8")
    decoder = json.JSONDecoder()
    pages = []
    position = 0
    while position < len(text):
        while position < len(text) and text[position].isspace():
            position += 1
        if position == len(text):
            break
        page, position = decoder.raw_decode(text, position)
        pages.append(page)
    if not pages:
        raise ValueError("Release API response is empty")
    return pages


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", help="SemVer release tag, including the v prefix")
    parser.add_argument("--releases", required=True, type=Path, help="Paginated GitHub release API response")
    parser.add_argument("--commit", required=True, help="Candidate commit")
    args = parser.parse_args()
    try:
        pages = read_pages(args.releases)
        result = validate(args.version, pages, args.commit)
    except (ValueError, OSError) as exc:
        print(f"Release validation failed: {exc}", file=sys.stderr)
        return 1
    print(f"prerelease={'true' if result.prerelease is not None else 'false'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
