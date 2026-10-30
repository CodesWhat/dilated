import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EMPTY_LABEL = re.compile(r'Toggle\(\s*""')


def empty_toggle_labels():
    hits = []
    for path in sorted((ROOT / "Sources").rglob("*.swift")):
        text = path.read_text(encoding="utf-8")
        for match in EMPTY_LABEL.finditer(text):
            line = text.count("\n", 0, match.start()) + 1
            hits.append(f"{path.relative_to(ROOT)}:{line}")
    return hits


class AccessibilityLabelTests(unittest.TestCase):
    def test_no_toggle_has_an_empty_label(self):
        hits = empty_toggle_labels()
        self.assertEqual(
            hits,
            [],
            "Toggle with an empty label is unnamed for VoiceOver; "
            "pass the row title and keep .labelsHidden():\n" + "\n".join(hits),
        )

    def test_settings_sidebar_buttons_are_named_by_page(self):
        path = ROOT / "Sources/DilatedUI/Settings/SettingsWindow.swift"
        text = path.read_text(encoding="utf-8")
        start = text.index("ForEach(SettingsPage.allCases)")
        end = text.index(".onMoveCommand", start)
        self.assertIn(
            ".accessibilityLabel(item.rawValue)",
            text[start:end],
            "Settings sidebar buttons must expose the page name as their "
            "accessibility label",
        )


if __name__ == "__main__":
    unittest.main()
