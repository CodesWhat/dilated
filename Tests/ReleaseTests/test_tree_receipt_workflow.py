from pathlib import Path
import re
import unittest


CI = Path(__file__).resolve().parents[2] / ".github/workflows/ci.yml"
SHA = "684a6b931e7802f1985e2cb4f6ea0c95861988e3"


def job_block(text, job):
    match = re.search(rf"^  {re.escape(job)}:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)", text, re.S | re.M)
    if match is None:
        raise AssertionError(f"job {job} not found")
    return match.group(1)


class TreeReceiptWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.text = CI.read_text()

    def test_actions_are_pinned_to_the_reviewed_sha(self):
        self.assertEqual(self.text.count(f"tree-receipt/verify@{SHA}"), 1)
        self.assertEqual(self.text.count(f"tree-receipt/record@{SHA}"), 1)

    def test_check_job_is_read_only_with_two_commits(self):
        block = job_block(self.text, "tree-receipt-check")
        self.assertIn("fetch-depth: 2", block)
        self.assertIn("persist-credentials: false", block)
        self.assertNotIn("write", block)

    def test_verify_fails_open_on_the_receipt(self):
        block = job_block(self.text, "verify")
        self.assertIn("needs: [changes, tree-receipt-check]", block)
        self.assertIn("!cancelled()", block)
        self.assertIn(
            "(needs.tree-receipt-check.result != 'success' || needs.tree-receipt-check.outputs.reuse != 'true')",
            block,
        )

    def test_record_is_push_only_and_after_verify_succeeds(self):
        block = job_block(self.text, "receipt")
        self.assertIn("if: ${{ always() && github.event_name == 'push' }}", block)
        self.assertIn("statuses: write", block)
        self.assertEqual(block.count("needs.verify.result == 'success'"), 2)
        self.assertEqual(self.text.count("statuses: write"), 1)


if __name__ == "__main__":
    unittest.main()
