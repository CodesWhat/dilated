import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
POSITIONAL = re.compile(r"ForEach\(\s*(rows|subviews)\.indices")


def positional_subview_loops():
    hits = []
    for path in sorted((ROOT / "Sources").rglob("*.swift")):
        text = path.read_text(encoding="utf-8")
        for match in POSITIONAL.finditer(text):
            line = text.count("\n", 0, match.start()) + 1
            hits.append(f"{path.relative_to(ROOT)}:{line}")
    return hits


class SettingsIdentityTests(unittest.TestCase):
    def test_subviews_are_not_keyed_by_position(self):
        hits = positional_subview_loops()
        self.assertEqual(
            hits,
            [],
            "ForEach over subviews.indices keys rows by position, so list changes "
            "move state between rows; iterate the subviews themselves:\n" + "\n".join(hits),
        )


if __name__ == "__main__":
    unittest.main()
