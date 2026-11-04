from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import release_policy as policy

TMP = ROOT / ".zig-cache" / "tmp"


class SemVerTests(unittest.TestCase):
    def test_specification_precedence_order(self):
        tags = ["v1.0.0-alpha", "v1.0.0-alpha.1", "v1.0.0-alpha.beta",
                "v1.0.0-beta", "v1.0.0-beta.2", "v1.0.0-beta.11",
                "v1.0.0-rc.1", "v1.0.0", "v1.0.1", "v1.1.0", "v2.0.0"]
        for left, right in zip(tags, tags[1:]):
            self.assertLess(policy.compare(policy.parse_version(left), policy.parse_version(right)), 0)

    def test_metadata_does_not_affect_precedence(self):
        self.assertEqual(policy.compare(policy.parse_version("v1.2.3+abc"), policy.parse_version("v1.2.3+42")), 0)
        self.assertEqual(policy.compare(policy.parse_version("v1.2.3-alpha+0"), policy.parse_version("v1.2.3-alpha")), 0)

    def test_invalid_versions(self):
        for tag in ("1.0.0", "v01.0.0", "v1.01.0", "v1.0.01", "v1.0", "v1.0.0-01",
                    "v1.0.0-alpha..1", "v1.0.0+", "v1.0.0-", "v1.0.0\n", "v1.0.0-α"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                policy.parse_version(tag)
        for tag in ("v0.0.0", "v1.0.0-0", "v1.0.0-01a", "v1.0.0+001", "v1.0.0--"):
            with self.subTest(tag=tag):
                policy.parse_version(tag)

    def test_large_numbers_are_compared_without_integer_limits(self):
        left = policy.parse_version("v" + "9" * 5000 + ".0.0")
        right = policy.parse_version("v1" + "0" * 5000 + ".0.0")
        self.assertLess(policy.compare(left, right), 0)


class ReleasePolicyTests(unittest.TestCase):
    def setUp(self):
        TMP.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=TMP)
        self.repo = Path(self.temp.name)
        self.run_git("init", "-q")
        (self.repo / "file").write_text("one", encoding="utf-8")
        self.run_git("add", "file")
        self.commit("initial")
        self.patch = patch.object(policy, "git", side_effect=self.git)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        self.addCleanup(self.temp.cleanup)

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def run_git(self, *args):
        result = self.git(*args)
        if result.returncode:
            self.fail(result.stderr)
        return result.stdout.strip()

    def commit(self, message):
        self.run_git("-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                     "commit", "-q", "-m", message)

    def changed_commit(self):
        (self.repo / "file").write_text("two", encoding="utf-8")
        self.run_git("add", "file")
        self.commit("change")

    @staticmethod
    def releases(*tags):
        return [[{"tag_name": tag, "draft": False} for tag in tags]]

    def test_paginated_api_response(self):
        response = self.repo / "releases.json"
        response.write_text('[{"tag_name":"v1.0.0","draft":false}]\n[]\n', encoding="utf-8")
        self.assertEqual(policy.read_pages(response), self.releases("v1.0.0") + [[]])
        response.write_text('', encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "empty"):
            policy.read_pages(response)
        response.write_text('[]\n{', encoding="utf-8")
        with self.assertRaises(ValueError):
            policy.read_pages(response)

    def test_first_release_and_invalid_first_versions(self):
        policy.validate("v1.0.0", [[]], "HEAD")
        for tag in ("v0.1.0", "v1.0.0-rc.1", "v1.0.0+build", "v1.0.1"):
            with self.subTest(tag=tag), self.assertRaisesRegex(ValueError, "first published"):
                policy.validate(tag, [[]], "HEAD")

    def test_existing_tag_and_draft_are_not_overwritten(self):
        self.run_git("tag", "v1.0.0")
        with self.assertRaisesRegex(ValueError, "tag already exists"):
            policy.validate("v1.0.0", [[]], "HEAD")
        with self.assertRaisesRegex(ValueError, "release or draft"):
            policy.validate("v1.0.1", [[{"tag_name": "v1.0.1", "draft": True}]], "HEAD")

    def test_require_new_contents_and_increasing_precedence(self):
        self.run_git("tag", "v1.0.0")
        releases = self.releases("v1.0.0")
        with self.assertRaisesRegex(ValueError, "No tracked changes"):
            policy.validate("v1.0.1", releases, "HEAD")
        self.changed_commit()
        policy.validate("v1.0.1", releases, "HEAD")
        with self.assertRaisesRegex(ValueError, "greater SemVer precedence"):
            policy.validate("v1.0.0+new", releases, "HEAD")
        with self.assertRaisesRegex(ValueError, "greater SemVer precedence"):
            policy.validate("v1.0.0-rc.1", releases, "HEAD")

    def test_prereleases_and_highest_release_across_pages(self):
        self.run_git("tag", "v1.0.0")
        self.changed_commit()
        self.run_git("tag", "v1.1.0-rc.1")
        (self.repo / "file").write_text("three", encoding="utf-8")
        self.run_git("add", "file")
        self.commit("another change")
        pages = self.releases("v1.1.0-rc.1") + self.releases("v1.0.0")
        self.assertIsNotNone(policy.validate("v1.1.0-rc.2", pages, "HEAD").prerelease)
        self.assertIsNone(policy.validate("v1.1.0", pages, "HEAD").prerelease)
        with self.assertRaisesRegex(ValueError, "greater SemVer precedence"):
            policy.validate("v1.0.9", pages, "HEAD")

    def test_missing_invalid_or_ambiguous_published_history_fails_closed(self):
        self.changed_commit()
        for pages in (self.releases("v1.0.0"), self.releases("not-semver"),
                      [[{"tag_name": "v1.0.0"}]], [{}]):
            with self.subTest(pages=pages), self.assertRaises(ValueError):
                policy.validate("v1.0.1", pages, "HEAD")
        self.run_git("tag", "v1.0.0")
        self.run_git("tag", "v1.0.0+other")
        with self.assertRaisesRegex(ValueError, "ambiguous"):
            policy.validate("v1.0.1", self.releases("v1.0.0", "v1.0.0+other"), "HEAD")

    def test_unrelated_release_is_rejected(self):
        tree = self.run_git("rev-parse", "HEAD^{tree}")
        orphan = self.run_git("-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                              "commit-tree", tree, "-m", "unrelated")
        self.run_git("tag", "v1.0.0", orphan)
        self.changed_commit()
        with self.assertRaisesRegex(ValueError, "not an ancestor"):
            policy.validate("v1.0.1", self.releases("v1.0.0"), "HEAD")

    def test_reverted_changes_are_not_a_new_release(self):
        self.run_git("tag", "v1.0.0")
        self.changed_commit()
        (self.repo / "file").write_text("one", encoding="utf-8")
        self.run_git("add", "file")
        self.commit("revert contents")
        with self.assertRaisesRegex(ValueError, "No tracked changes"):
            policy.validate("v1.0.1", self.releases("v1.0.0"), "HEAD")


if __name__ == "__main__":
    unittest.main()
