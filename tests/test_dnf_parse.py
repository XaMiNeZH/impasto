#!/usr/bin/env python3
"""Parsers and the awww wrapper, without a Fedora machine."""

import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "home" / ".config" / "quickshell" / "scripts"


def load(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class DnfParse(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.packages = load("packages")
        cls.updates = load("updates")

    def test_rpm_installed_rows(self):
        text = "kitty\t0.40.0-1.fc43\tTerminal\t1048576\n"
        rows = self.packages.parse_rpm_installed(text, {"kitty"}, set())
        self.assertEqual(rows[0]["name"], "kitty")
        self.assertEqual(rows[0]["version"], "0.40.0-1.fc43")
        self.assertTrue(rows[0]["explicit"])
        self.assertFalse(rows[0]["aur"])
        self.assertEqual(rows[0]["size"], "1.00 MiB")

    def test_foreign_copr_is_marked(self):
        rows = self.packages.parse_rpm_installed(
            "hyprland\t0.56.0-1\tcompositor\t1\n", None, {"hyprland"})
        self.assertTrue(rows[0]["aur"])

    def test_search_filters_by_name(self):
        text = "kitty\t0.40.0-1.fc43\tA terminal\nnotkitty-docs\t1-1\tnotes\n"
        rows = self.packages.parse_dnf_search(text, "kitty")
        self.assertEqual([row["name"] for row in rows], ["kitty", "notkitty-docs"])

    def test_dnf4_upgrade_line(self):
        rows = self.updates.parse_dnf("kitty.x86_64   0.41.0-1.fc43   updates\n")
        self.assertEqual(rows, [{
            "name": "kitty", "from": "", "to": "0.41.0-1.fc43", "source": "repo",
        }])

    def test_dnf5_upgrade_arrow(self):
        rows = self.updates.parse_dnf("kitty 0.40.0-1.fc43 -> 0.41.0-1.fc43 updates\n")
        self.assertEqual(rows[0]["name"], "kitty")
        self.assertEqual(rows[0]["from"], "0.40.0-1.fc43")
        self.assertEqual(rows[0]["to"], "0.41.0-1.fc43")

    def test_upgrade_headers_are_ignored(self):
        text = "Last metadata expiration check: 1:00 ago\nUpdating:\n"
        self.assertEqual(self.updates.parse_dnf(text), [])


class WallpaperWrapper(unittest.TestCase):
    def test_awww_forwards_to_swww(self):
        text = (ROOT / "lib" / "awww").read_text(encoding="utf-8")
        self.assertIn("exec swww \"$@\"", text)

    def test_awww_daemon_forwards_to_swww_daemon(self):
        text = (ROOT / "lib" / "awww-daemon").read_text(encoding="utf-8")
        self.assertIn("exec swww-daemon \"$@\"", text)


class EmojiFont(unittest.TestCase):
    def test_fedora_color_font_is_a_candidate(self):
        text = (SCRIPTS / "camera.py").read_text(encoding="utf-8")
        self.assertIn("/usr/share/fonts/noto/NotoColorEmoji.ttf", text)
        self.assertIn("/usr/share/fonts/google-noto-color-emoji-fonts/Noto-COLRv1.ttf", text)


if __name__ == "__main__":
    unittest.main()
