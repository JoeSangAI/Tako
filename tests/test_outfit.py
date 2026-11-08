"""What Tako wears: the owner's choice in the menu comes first; left to Tako, a DeepSeek key puts on the whale girl, otherwise the day decides.
The choice is Swift (`Sources/native/Wardrobe.swift`), compiled here on its own with a few lines that print what it picks.
Run: python3 tests/test_outfit.py
"""
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent

# choice, service, date -> the outfit worn ("-" for none)
CASES = [
    ("occasions", "deepseek", (2026, 11, 25), "whale"),   # a DeepSeek key: the whale girl, on any day
    ("occasions", "deepseek", (2026, 11, 5), "whale"),    # even in the corgi's fortnight
    ("occasions", "deepseek", (2026, 12, 24), "whale"),
    ("occasions", "", (2026, 11, 25), "-"),               # a ChatGPT login: only the days
    ("occasions", "", (2026, 11, 5), "corgi"),
    ("occasions", "", (2026, 12, 24), "santa"),
    ("occasions", "qwen", (2026, 11, 25), "-"),           # another service has no outfit of its own
    ("occasions", "custom", (2026, 11, 5), "corgi"),
    ("none", "deepseek", (2026, 11, 25), "-"),            # chosen in the menu: that is what it wears
    ("corgi", "deepseek", (2026, 11, 25), "corgi"),
    ("whale", "", (2026, 11, 25), "whale"),               # anyone can put it on
    ("whale", "qwen", (2026, 11, 5), "whale"),
    ("santa", "deepseek", (2026, 11, 25), "whale"),       # not out yet: left to Tako
    ("santa", "", (2026, 12, 24), "santa"),
]

HARNESS = """
import Foundation
for line in CommandLine.arguments.dropFirst() {
    let f = line.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    let day = Outfit.day(Int(f[2])!, Int(f[3])!, Int(f[4])!)
    print(Outfit.pick(choice: f[0], service: f[1], on: day)?.id ?? "-")
}
print("wardrobe:" + Outfit.wardrobe(on: Outfit.day(2026, 11, 7)).map { $0.id }.joined(separator: ","))
"""


@unittest.skipUnless(shutil.which("swiftc"), "needs the Swift compiler")
class Wardrobe(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.folder = tempfile.TemporaryDirectory()
        main = pathlib.Path(cls.folder.name) / "main.swift"
        main.write_text(HARNESS)
        cls.binary = pathlib.Path(cls.folder.name) / "pick"
        subprocess.run(["swiftc", "-o", str(cls.binary), str(ROOT / "Sources/native/Wardrobe.swift"), str(main)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.folder.cleanup()

    def picked(self):
        lines = [f"{choice}:{service}:{y}:{m}:{d}" for choice, service, (y, m, d), _ in CASES]
        return subprocess.run([str(self.binary), *lines], check=True, capture_output=True, text=True).stdout.splitlines()

    def test_the_owners_choice_first_then_the_key_then_the_day(self):
        out = self.picked()
        for (choice, service, day, wanted), got in zip(CASES, out):
            with self.subTest(choice=choice, service=service, day=day):
                self.assertEqual(got, wanted)

    def test_the_whale_girl_is_in_everyones_wardrobe(self):
        self.assertEqual(self.picked()[-1], "wardrobe:corgi,whale")

    def test_the_panel_tells_the_goo_which_service_only_when_setup_knows(self):
        # The service comes from `/setup` (first_run.state: "deepseek", "custom" for a relay, nothing with a ChatGPT login).
        # While Codex is being installed or updated the step says nothing about it, so the goo keeps what it had.
        page = (ROOT / "Sources/brain/side.html").read_text()
        self.assertIn("['ready', 'key', 'login'].includes(next?.step)", page)
        self.assertIn("native?.postMessage({ service })", page)

    def test_her_pictures_go_into_the_app_and_none_is_left_over(self):
        # Everything that is not her body is a picture (Sources/art), loaded by name in Whale.swift: a missing one would
        # leave her half dressed, an unused one is weight in every download.
        code = (ROOT / "Sources/native/Whale.swift").read_text()
        art = {p.stem[len("whale-"):] for p in (ROOT / "Sources/art").glob("whale-*.png")}
        self.assertTrue({"apron", "tail", "spout"} <= art)
        for name in art:
            self.assertIn(f'"{name}"', code, name)
        for name in re.findall(r'(?:sprite|dress)\((?:k\.\w+, )?"(\w+)"', code) + re.findall(r'p\.prop = \("(\w+)"', code):
            self.assertIn(name, art, name)
        self.assertIn('Sources/art/*.png "$APP/Contents/Resources/"', (ROOT / "scripts/build_app.sh").read_text())

    def test_her_moves_are_her_own(self):
        # Every outfit has its own moves (Joe 2026-11-08): hers borrow none of the corgi's, and the scenes she plays her
        # own way skip Tako's props.
        code = (ROOT / "Sources/native/Whale.swift").read_text()
        for corgi in ("startZoomies", "zooming", "trotLeg", "isCorgi", "wiggle +="):
            self.assertNotIn(corgi, code)
        acts = re.search(r"static let whaleActs: Set<String> = \[(.*?)\]", code).group(1)
        for scene in ("think", "search", "run", "answer", "wait", "trouble"):
            self.assertIn(f'"{scene}"', acts)
        self.assertIn("costume.isWhale && Goo.whaleActs.contains(a)", (ROOT / "Sources/native/Acts.swift").read_text())

    def test_the_outfit_changes_nothing_but_the_look(self):
        # Any model gets the same Tako (AGENTS.md): no prompt, step cap or rule may name the whale or its service.
        for name in ("prompts.py", "turns.py", "hands.py", "guards.py"):
            text = (ROOT / "Sources/brain" / name).read_text()
            self.assertNotIn("whale", text)
            self.assertNotIn("鲸鱼", text)


if __name__ == "__main__":
    unittest.main()
