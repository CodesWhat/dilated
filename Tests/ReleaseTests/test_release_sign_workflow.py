import re
import unittest
from pathlib import Path

WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/release-sign.yml"


def tag_pattern():
    match = re.search(r'=~ (\^v[^ ]+\$) \]\]', WORKFLOW.read_text())
    assert match, "tag regex not found in release-sign.yml"
    # Bash ERE and Python agree for this pattern.
    return re.compile(match.group(1))


class ReleaseSignWorkflowTests(unittest.TestCase):
    def test_tag_regex_accepts_release_tags(self):
        pattern = tag_pattern()
        for tag in ("v1.0.1", "v1.0.0", "v1.0.0-beta.13", "v2.1.0-rc.1"):
            self.assertTrue(pattern.match(tag), tag)

    def test_tag_regex_rejects_other_tags(self):
        pattern = tag_pattern()
        for tag in ("mas/v1.0.0-build18", "1.0.1", "v1.0", "v1.0.0-", "v1.0.0 x", "refs/tags/v1.0.1"):
            self.assertFalse(pattern.match(tag), tag)

    def test_top_level_permissions_are_empty(self):
        self.assertRegex(WORKFLOW.read_text(), r"(?m)^permissions: \{\}$")

    def test_actions_are_pinned_by_sha(self):
        for ref in re.findall(r"uses: (\S+)", WORKFLOW.read_text()):
            self.assertRegex(ref, r"@[0-9a-f]{40}$", ref)

    def test_run_commit_is_checked_before_provenance(self):
        text = WORKFLOW.read_text()
        check = text.index("Require the run commit to be the tag's commit")
        provenance = text.index("actions/attest-build-provenance@")
        self.assertLess(check, provenance)
        block = text[check:provenance]
        self.assertIn('refs/tags/${RELEASE_TAG}^{commit}', block)
        self.assertIn("RUN_SHA: ${{ github.sha }}", block)
        self.assertNotIn("${{", block.split("run: |", 1)[1])


if __name__ == "__main__":
    unittest.main()
