"""Getting a friend's Mac past the login step, against a stand-in for `codex login`: no browser, no network, no real account.
Run: python3 tests/test_first_run.py
"""
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Sources/brain"))
sys.path.insert(0, str(ROOT / "Sources/brain/vendor"))
import first_run  # noqa: E402

LINK = "https://auth.openai.com/oauth/authorize?response_type=code&state=abc"
# What the real one prints, to stderr, as seen on 0.163.0: the page first, then it waits.
CODEX = r'''#!/bin/sh
here="$(dirname "$0")"
case "$1 $2" in
  "app-server --help") echo "--listen <URL>"; exit 0 ;;
  "login status")
    [ -f "$here/settings_error" ] && { cat "$here/settings_error" >&2; exit 1; }
    [ -f "$here/logged_in" ] && { echo "Logged in using ChatGPT"; exit 0; }
    echo "Not logged in"; exit 1 ;;
esac
[ -f "$here/settings_error" ] && { cat "$here/settings_error" >&2; exit 1; }
[ -f "$here/fails_with" ] && { cat "$here/fails_with" >&2; exit 1; }
printf 'Starting local login server on http://localhost:1455.\nIf your browser did not open, navigate to this URL to authenticate:\n\n%s\n' "$LINK" >&2
# npm puts a script in front of the real Codex: two processes, like here.
sleep 60 &
echo $! > "$here/child"
echo $$ > "$here/parent"
while [ ! -f "$here/authorized" ]; do sleep 0.05; done
kill %1 2>/dev/null
touch "$here/logged_in"
echo "Successfully logged in"
exit 0
'''


class Companion:
    def __init__(self):
        self.submitted = []

    def submit(self, coroutine):
        self.submitted.append(coroutine.__name__)
        coroutine.close()

    async def warm(self):
        pass

    async def start_over(self):
        pass


def alive(pid_file):
    pid = int(pid_file.read_text())
    # A process that has exited but whose parent hasn't collected it yet holds nothing.
    state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return bool(state) and not state.startswith("Z")


class LoginStep(unittest.TestCase):
    def setUp(self):
        self.home = pathlib.Path(tempfile.mkdtemp(prefix="tako-login-"))
        self.addCleanup(shutil.rmtree, self.home, True)
        self.bin = self.home / "bin"
        self.bin.mkdir()
        self.codex = self.bin / "codex"
        self.codex.write_text(CODEX)
        self.codex.chmod(self.codex.stat().st_mode | stat.S_IEXEC)
        self.codex_home = self.home / "codex-home"
        self.codex_home.mkdir()
        self.settings = self.codex_home / "config.toml"
        for name, value in (("CODEX_HOME", self.codex_home), ("LINK", LINK)):
            os.environ[name] = str(value)
            self.addCleanup(os.environ.pop, name, None)
        real = first_run._installed
        first_run._installed = lambda: [str(self.codex)]
        self.addCleanup(setattr, first_run, "_installed", real)
        first_run._serves.clear()
        self.companion = Companion()
        self.setup = first_run.Setup(self.companion)
        self.addCleanup(self.setup.cancel)

    def press(self):
        self.setup.next_step()

    def until(self, wanted, what):
        deadline = time.time() + 5
        while time.time() < deadline:
            self.setup.checked = 0.0  # The panel asks every two seconds; here there's no need to wait for it.
            seen = self.setup.state()
            if wanted(seen):
                return seen
            time.sleep(0.02)
        self.fail(f"never happened: {what}; last {self.setup.state()}")

    def fails_with(self, words):
        (self.bin / "fails_with").write_text(words + "\n")
        self.press()
        return self.until(lambda s: not s["busy"] and s["error"], "the reason")["error"]

    def test_a_codex_already_logged_in_never_shows_the_step(self):
        (self.bin / "logged_in").write_text("")
        self.assertEqual(self.setup.state()["step"], "ready")

    def test_no_answer_yet_is_not_a_missing_login(self):
        # The panel can ask again while the first check is still out. A logged-in owner must not see the login step flash by.
        (self.bin / "logged_in").write_text("")
        self.setup.checked = time.time()
        self.assertEqual(self.setup.state()["step"], "ready")

    def test_logged_out_shows_the_step(self):
        self.assertEqual(self.setup.state()["step"], "login")

    def test_the_page_shows_while_it_waits_and_success_goes_on_by_itself(self):
        self.press()
        seen = self.until(lambda s: s.get("link"), "the page's address")
        self.assertEqual(seen["step"], "login")
        self.assertTrue(seen["busy"])
        self.assertEqual(seen["link"], LINK)
        self.assertEqual(self.companion.submitted, [])
        (self.bin / "authorized").write_text("")
        self.assertEqual(self.until(lambda s: not s["busy"], "the end")["step"], "ready")
        # A server started before the login never heard of it.
        self.until(lambda s: self.companion.submitted, "the server told")
        self.assertEqual(self.companion.submitted, ["start_over"])

    def test_cancel_leaves_nothing_behind_and_it_can_be_tried_again(self):
        self.press()
        self.until(lambda s: s.get("link"), "the page's address")
        deadline = time.time() + 3
        while not (self.bin / "parent").exists() and time.time() < deadline:
            time.sleep(0.02)
        parent, child = self.bin / "parent", self.bin / "child"
        self.assertTrue(alive(parent) and alive(child))
        self.setup.cancel()
        seen = self.until(lambda s: not s["busy"], "the login gone")
        self.assertEqual((seen["step"], seen["error"]), ("login", ""))
        deadline = time.time() + 3
        while (alive(parent) or alive(child)) and time.time() < deadline:
            time.sleep(0.02)
        self.assertFalse(alive(parent) or alive(child), "something is still holding the login's port")
        self.press()
        self.assertEqual(self.until(lambda s: s.get("link"), "a second try")["link"], LINK)

    def test_two_presses_start_one_login(self):
        threads = [threading.Thread(target=self.press) for _ in range(4)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.until(lambda s: s.get("link"), "the page's address")
        found = subprocess.run(["pgrep", "-f", str(self.codex)], capture_output=True, text=True).stdout.split()
        self.assertEqual(len(found), 1)

    def test_says_the_real_reason_and_never_the_generic_one(self):
        for said, wanted in (
                ("Error logging in: Port 127.0.0.1:1455 is already in use", "端口"),
                ("Error logging in: Token exchange failed: error sending request for url", "连不上"),
                ("Error logging in: Login was not completed", "没有完成"),
                ("ChatGPT login is disabled. Use API key login instead.", "forced_login_method"),
                ("env: node: No such file or directory", "env: node: No such file or directory")):
            with self.subTest(said=said):
                error = self.fails_with(said)
                self.assertIn(wanted, error)
                self.assertNotIn("再试一次", error)

    def test_the_login_page_address_is_never_repeated_in_a_reason(self):
        error = first_run._why_login_failed(["Something odd", f"navigate to {LINK}"])
        self.assertIn("Something odd", error)
        self.assertNotIn("auth.openai.com", error)

    def test_a_settings_file_codex_cannot_read_is_named_and_set_aside_only_on_the_button(self):
        self.settings.write_text("model = [unterminated\n")
        (self.bin / "settings_error").write_text(f"Error loading configuration: {self.settings}:1:22: unclosed array, expected `]`\n")
        seen = self.setup.state()
        self.assertEqual(seen["step"], "config")
        self.assertIn("第 1 行", seen["error"])
        self.assertTrue(self.settings.exists())
        (self.bin / "settings_error").unlink()
        self.press()
        self.assertFalse(self.settings.exists())
        kept = list(self.codex_home.glob("config.toml.tako-*"))
        self.assertEqual([path.read_text() for path in kept], ["model = [unterminated\n"])
        self.assertEqual(self.companion.submitted, ["start_over"])
        self.assertEqual(self.until(lambda s: True, "")["step"], "login")

    def test_another_settings_file_is_not_offered_to_be_moved(self):
        other = self.home / "project/.codex/config.toml"
        (self.bin / "settings_error").write_text(f"Error loading configuration: {other}:3:1: nope\n")
        self.assertEqual(self.setup.state()["step"], "login")

    def test_a_login_failing_at_the_settings_file_turns_into_that_step(self):
        self.assertEqual(self.setup.state()["step"], "login")
        self.settings.write_text("x")
        (self.bin / "settings_error").write_text(f"Error loading configuration: {self.settings}:2:5: unknown variant\n")
        self.press()
        self.assertEqual(self.until(lambda s: not s["busy"], "the end")["step"], "config")

    def test_a_codex_from_npm_finds_the_node_next_to_it_even_if_installed_since_the_app_started(self):
        env = first_run._with_its_folder(str(self.codex))
        self.assertTrue(env["PATH"].startswith(f"{self.bin}{os.pathsep}"))


class OnTheRealServer(unittest.TestCase):
    """The panel's doors, against the whole Python side."""

    def setUp(self):
        sys.path.insert(0, str(ROOT / "tests"))
        from test_turns import Tako
        self.tako = Tako()
        self.addCleanup(self.tako.close)

    def until(self, wanted, what):
        deadline = time.time() + 8
        while time.time() < deadline:
            seen = self.tako.call("/setup")
            if wanted(seen):
                return seen
            time.sleep(0.05)
        self.fail(f"never happened: {what}; last {self.tako.call('/setup')}")

    def started(self):
        return sum('"started"' in line for line in self.tako.log.read_text().splitlines())

    def test_logging_in_goes_on_by_itself_with_a_server_that_knows(self):
        (self.tako.home / "logged_out").write_text("")
        self.assertEqual(self.tako.call("/setup")["step"], "login")
        self.assertEqual(self.tako.call("/setup/cancel", {})["step"], "login")  # Nothing to cancel is not an error.
        deadline = time.time() + 8
        while not self.started() and time.time() < deadline:
            time.sleep(0.02)
        before = self.started()
        self.assertEqual(before, 1)
        self.tako.call("/setup/next", {})
        self.until(lambda s: s["step"] == "ready", "the step gone without a restart of Tako")
        deadline = time.time() + 8
        while self.started() == before and time.time() < deadline:
            time.sleep(0.02)
        self.assertEqual(self.started(), before + 1, "the Codex server from before the login is still the one running")


if __name__ == "__main__":
    unittest.main(verbosity=1)
