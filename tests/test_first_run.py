"""Getting a friend's Mac past the login step, against a stand-in for `codex login`: no browser, no network, no real account.
Run: python3 tests/test_first_run.py
"""
import json
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
import office  # noqa: E402
import provider  # noqa: E402

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
        # Never this Mac's own key or settings.
        for module, name, value in ((provider, "FILE", self.home / "provider.json"), (provider, "CONFIG", {}), (office, "FILE", self.home / "office.json"), (office, "CONFIG", {})):
            self.addCleanup(setattr, module, name, getattr(module, name))
            setattr(module, name, value)
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


class OwnKey(unittest.TestCase):
    """Someone without ChatGPT gives Tako a DeepSeek or Qwen key instead. The service is never called: `check` stands in for it."""

    def setUp(self):
        LoginStep.setUp(self)
        self.checked = []
        real = provider.check
        def check(service, key, base_url="", model=""):
            self.checked.append((service, key))
            if key == "wrong":
                return "这个 key 不对，或者已经停用了。", []
            if service == "custom" and not model:
                return "选一个模型。", ["claude-sonnet-5-5", "gpt-6.1-sol"]
            return "", []
        provider.check = check
        self.addCleanup(setattr, provider, "check", real)

    def test_a_good_key_is_kept_for_the_owner_alone_and_the_server_starts_again(self):
        self.assertEqual(self.setup.state()["step"], "login")
        self.assertTrue(self.setup.use_key("deepseek", "  sk-good  "))
        self.assertEqual(self.checked, [("deepseek", "sk-good")])
        self.assertEqual(oct(provider.FILE.stat().st_mode & 0o777), "0o600")
        self.assertEqual(self.companion.submitted, ["start_over"])
        seen = self.setup.state()
        self.assertEqual((seen["step"], seen["service"]), ("ready", "deepseek"))  # Not logged in to ChatGPT, and no need to be.
        self.assertEqual(provider.model(), "deepseek-flash")

    def test_a_wrong_key_says_so_and_keeps_nothing(self):
        self.assertFalse(self.setup.use_key("qwen", "wrong"))
        self.assertFalse(provider.FILE.exists())
        self.assertEqual(self.companion.submitted, [])
        self.assertEqual(self.setup.state()["error"], "这个 key 不对，或者已经停用了。")

    def test_only_the_services_it_knows(self):
        self.assertFalse(self.setup.use_key("somewhere", "sk-good"))
        self.assertFalse(self.setup.use_key("deepseek", ""))
        self.assertEqual(self.checked, [])

    def test_a_key_the_service_stops_taking_asks_for_a_new_one(self):
        self.setup.use_key("qwen", "sk-good")
        self.setup.logged_out()  # What a turn does when the model says unauthorized.
        seen = self.setup.state()
        self.assertEqual((seen["step"], seen["service"]), ("key", "qwen"))
        self.assertTrue(self.setup.use_key("qwen", "sk-new"))
        self.assertEqual(self.setup.state()["step"], "ready")

    def test_back_to_chatgpt_forgets_the_key(self):
        self.setup.use_key("deepseek", "sk-good")
        self.setup.use_login()
        self.assertFalse(provider.FILE.exists())
        self.assertEqual(self.setup.state()["step"], "login")

    def test_a_key_kept_in_the_owners_own_env_file(self):
        env = self.home / "keys.env"
        env.write_text('OTHER=x\nexport DEEPSEEK_API_KEY="sk-from-file"\n')
        provider.CONFIG = {"provider": {"preset": "deepseek", "key_file": f"{env}#DEEPSEEK_API_KEY", "model": "deepseek-v4-pro"}}
        found = provider.current()
        self.assertEqual((found["key"], found["model"], found["base_url"]), ("sk-from-file", "deepseek-v4-pro", "https://api.deepseek.com/v1"))
        self.assertEqual(self.setup.state()["step"], "ready")
        env.write_text("OTHER=x\n")
        self.assertEqual(self.setup.state()["step"], "key")  # The line went away: ask for one rather than start a server that can't answer.

    def test_codex_gets_the_service_but_never_the_key_as_an_argument(self):
        self.setup.use_key("qwen", "sk-secret")
        args = provider.codex_args()
        self.assertNotIn("sk-secret", " ".join(args))
        self.assertIn('model_providers.tako.wire_api="responses"', args)
        self.assertIn('model_providers.tako.base_url="https://dashscope.aliyuncs.com/compatible-mode/v1"', args)
        self.assertEqual(provider.codex_env(), {"TAKO_PROVIDER_KEY": "sk-secret"})

    def test_a_relay_lists_its_models_then_runs_the_one_picked(self):
        self.assertFalse(self.setup.use_key("custom", "sk-relay", "relay.example.com"))
        seen = self.setup.state()
        self.assertEqual((seen["error"], seen["models"]), ("选一个模型。", ["claude-sonnet-5-5", "gpt-6.1-sol"]))
        self.assertTrue(self.setup.use_key("custom", "sk-relay", "relay.example.com", "gpt-6.1-sol"))
        found = provider.current()
        self.assertEqual((found["base_url"], found["model"], found["key"]), ("https://relay.example.com/v1", "gpt-6.1-sol", "sk-relay"))
        self.assertEqual(self.setup.state()["service"], "custom")
        self.assertIn('model_providers.tako.base_url="https://relay.example.com/v1"', provider.codex_args())

    def test_whatever_address_people_paste_becomes_the_api_root(self):
        for pasted, root in (("relay.example.com", "https://relay.example.com/v1"), ("https://relay.example.com/", "https://relay.example.com/v1"),
                             ("https://relay.example.com/v1/chat/completions", "https://relay.example.com/v1"), ("https://x.example.com/api/v3", "https://x.example.com/api/v3"),
                             ("http://127.0.0.1:3000/v1/responses", "http://127.0.0.1:3000/v1")):
            self.assertEqual(provider.address(pasted), root)

    def test_without_a_key_nothing_changes(self):
        self.assertEqual(provider.codex_args(), [])
        self.assertEqual(provider.codex_env(), {})
        self.assertEqual(provider.model(), provider.MODEL)


QODER = r'''#!/bin/sh
here="$(dirname "$0")"
[ "$1" = "status" ] || exit 0
[ -f "$here/qoder_logged_in" ] && { echo "Version: 1.1.71"; echo "Username: someone"; exit 0; }
echo "Account: Not logged in"
'''


class OfficeLogin(unittest.TestCase):
    """Someone with WorkBuddy or Qoder and nothing else uses its login: no Codex, no key. Whether it is logged in is read from disk."""

    def setUp(self):
        LoginStep.setUp(self)
        self.login = self.home / "workbuddy-desktop.info"
        qoder = self.bin / "qoderclicn"
        qoder.write_text(QODER)
        qoder.chmod(qoder.stat().st_mode | stat.S_IEXEC)
        for name, value in (("installed", lambda: ["workbuddy", "qoder"]), ("WORKBUDDY_LOGIN", self.login), ("_qoder_cli", lambda: qoder)):
            self.addCleanup(setattr, office, name, getattr(office, name))
            setattr(office, name, value)

    def workbuddy_logged_in(self, days=20):
        self.login.write_text(json.dumps({"auth": {"accessToken": "never read", "expiresAt": (time.time() + days * 86400) * 1000, "refreshExpiresAt": (time.time() + days * 86400) * 1000}}))

    def test_the_login_step_offers_what_is_on_this_mac(self):
        seen = self.setup.state()
        self.assertEqual(seen["step"], "login")
        self.assertEqual([o["id"] for o in seen["offices"]], ["workbuddy", "qoder"])

    def test_without_codex_the_first_card_is_still_the_one_question(self):
        first_run._installed = lambda: []
        seen = self.setup.state()
        self.assertEqual(seen["step"], "login", "no card about Codex before the owner has picked a way in")
        self.assertEqual(seen["offices"][0]["name"], "WorkBuddy")

    def test_an_office_agent_that_says_no_names_itself(self):
        self.assertFalse(self.setup.use_office("qoder"))
        seen = self.setup.state()
        self.assertEqual(seen["error_for"], "qoder", "the error goes on that row")

    def test_a_good_login_is_kept_and_the_brain_starts_again_without_codex(self):
        self.workbuddy_logged_in()
        provider.save("deepseek", "sk-old")
        self.assertTrue(self.setup.use_office("workbuddy"))
        self.assertEqual(self.companion.submitted, ["start_over"])
        self.assertFalse(provider.FILE.exists(), "one brain at a time")
        first_run._installed = lambda: []
        seen = self.setup.state()
        self.assertEqual((seen["step"], seen["service"]), ("ready", "workbuddy"))

    def test_an_expired_login_says_what_to_do_and_keeps_nothing(self):
        self.workbuddy_logged_in(days=-1)
        self.assertFalse(self.setup.use_office("workbuddy"))
        self.assertIn("打开一次 WorkBuddy", self.setup.state()["error"])
        self.assertFalse(office.FILE.exists())
        self.assertEqual(self.companion.submitted, [])

    def test_never_logged_in_says_so(self):
        self.assertFalse(self.setup.use_office("workbuddy"))
        self.assertIn("还没登录", self.setup.state()["error"])
        self.workbuddy_logged_in()
        self.login.with_name(self.login.name + ".logged-out").write_text("")
        self.assertFalse(self.setup.use_office("workbuddy"))

    def test_qoder_asks_its_own_status(self):
        self.assertFalse(self.setup.use_office("qoder"))
        self.assertIn("Qoder 还没登录", self.setup.state()["error"])
        (self.bin / "qoder_logged_in").write_text("")
        self.assertTrue(self.setup.use_office("qoder"))
        self.assertEqual(self.setup.state()["step"], "ready")

    def test_not_on_this_mac_is_not_offered(self):
        self.assertFalse(self.setup.use_office("qwenwork"))
        self.assertFalse(office.FILE.exists())

    def test_a_turn_turned_away_brings_the_step_back_and_trying_again_starts_afresh(self):
        self.workbuddy_logged_in()
        self.setup.use_office("workbuddy")
        self.setup.logged_out()  # what a turn does when the agent says its login won't do
        seen = self.setup.state()
        self.assertEqual(seen["step"], "office")
        self.assertIn("打开一次 WorkBuddy", seen["error"])
        self.setup.next_step()  # 再试一次
        self.assertEqual(self.setup.state()["step"], "ready")
        self.assertEqual(self.companion.submitted, ["start_over", "start_over"])

    def test_back_to_chatgpt_forgets_the_office_agent(self):
        self.workbuddy_logged_in()
        self.setup.use_office("workbuddy")
        self.setup.use_login()
        self.assertFalse(office.FILE.exists())
        self.assertEqual(self.setup.state()["step"], "login")

    def test_a_key_replaces_the_office_agent(self):
        self.workbuddy_logged_in()
        self.setup.use_office("workbuddy")
        provider.check, real = (lambda *a, **k: ("", [])), provider.check
        self.addCleanup(setattr, provider, "check", real)
        self.setup.use_key("deepseek", "sk-good")
        self.assertIsNone(office.current())


class CodexOnlyWhenNeeded(unittest.TestCase):
    """No Codex on this Mac: it is installed only once the owner picks a way in that needs it (ChatGPT or a key), and that way goes on by itself."""

    def setUp(self):
        LoginStep.setUp(self)
        self.codex.rename(self.home / "codex.ready")
        here = self.home
        first_run._installed = lambda: [str(here / "bin/codex")] if (here / "bin/codex").exists() else []
        self.setup.INSTALL = f'sleep 0.3; cp "{here}/codex.ready" "{here}/bin/codex"'
        provider.check, real = (lambda *a, **k: ("", [])), provider.check
        self.addCleanup(setattr, provider, "check", real)

    def test_the_first_card_asks_first(self):
        self.assertEqual(self.setup.state()["step"], "login")

    def test_chatgpt_installs_codex_then_goes_straight_to_the_browser(self):
        self.setup.next_step()
        self.until(lambda s: s["busy"] and s["step"] == "install", "installing")
        seen = self.until(lambda s: s.get("link"), "the login page after the install")
        self.assertEqual(seen["step"], "login")
        (self.bin / "authorized").write_text("")
        self.assertEqual(self.until(lambda s: not s["busy"], "the end")["step"], "ready")

    def test_a_key_is_kept_then_codex_goes_in_and_it_is_ready(self):
        self.assertTrue(self.setup.use_key("deepseek", "sk-good"))
        self.assertTrue(provider.FILE.exists(), "the key is kept first")
        self.assertEqual(self.setup.state()["step"], "install")
        seen = self.until(lambda s: not s["busy"], "the install done")
        self.assertEqual((seen["step"], seen.get("service")), ("ready", "deepseek"))
        self.until(lambda s: self.companion.submitted, "the brain started")

    def test_a_failed_install_after_a_key_says_so_and_offers_it_again(self):
        self.setup.INSTALL = "exit 1"
        self.setup.use_key("deepseek", "sk-good")
        seen = self.until(lambda s: not s["busy"], "the install over")
        self.assertEqual(seen["step"], "install")
        self.assertIn("Codex 没装上", seen["error"])

    def until(self, wanted, what):
        return LoginStep.until(self, wanted, what)


class ModelSettings(unittest.TestCase):
    """模型设置 in the menu: the first card again over a model that already works, so the owner can log in or bring a key whenever they like."""

    def setUp(self):
        LoginStep.setUp(self)
        provider.check, real = (lambda *a, **k: ("", [])), provider.check
        self.addCleanup(setattr, provider, "check", real)

    def until(self, wanted, what):
        return LoginStep.until(self, wanted, what)

    def test_a_codex_already_logged_in_can_still_open_the_first_card_and_close_it_unchanged(self):
        (self.bin / "logged_in").write_text("")
        self.assertEqual(self.setup.state()["step"], "ready")
        self.setup.choose()
        seen = self.setup.state()
        self.assertEqual((seen["step"], seen["choosing"], seen["current"]), ("login", True, "ChatGPT"))
        self.assertTrue(seen["services"], "the key choices are on the card")
        self.setup.close()
        self.assertEqual(self.setup.state()["step"], "ready")
        self.assertEqual(self.companion.submitted, [], "closing it restarts nothing")

    def test_a_key_picked_there_replaces_the_chatgpt_login(self):
        (self.bin / "logged_in").write_text("")
        self.setup.choose()
        self.assertTrue(self.setup.use_key("deepseek", "sk-good"))
        seen = self.setup.state()
        self.assertEqual((seen["step"], seen.get("service"), seen.get("choosing")), ("ready", "deepseek", None))

    def test_chatgpt_picked_there_forgets_the_key_and_uses_the_login_codex_has(self):
        (self.bin / "logged_in").write_text("")
        self.setup.use_key("deepseek", "sk-good")
        self.setup.choose()
        self.assertEqual(self.setup.state()["current"], "DeepSeek")
        self.companion.submitted.clear()
        self.setup.next_step()
        self.assertFalse(provider.FILE.exists())
        seen = self.setup.state()
        self.assertEqual((seen["step"], seen.get("service")), ("ready", None))
        self.assertEqual(self.companion.submitted, ["start_over"])

    def test_chatgpt_picked_there_without_a_login_opens_the_browser(self):
        self.setup.use_key("deepseek", "sk-good")
        self.setup.choose()
        self.setup.next_step()
        self.assertFalse(provider.FILE.exists())
        self.until(lambda s: s.get("link"), "the login page")
        (self.bin / "authorized").write_text("")
        self.assertEqual(self.until(lambda s: not s["busy"], "the end")["step"], "ready")


class OnTheRealServer(unittest.TestCase):
    """The panel's doors, against the whole Python side."""

    def setUp(self):
        sys.path.insert(0, str(ROOT / "tests"))
        from test_turns import Tako
        self.Tako = Tako
        self.tako = Tako()
        self.addCleanup(lambda: self.tako.close())

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


    def test_with_a_key_the_server_is_started_for_that_service_and_no_login_is_asked(self):
        self.tako.close()
        self.tako = self.Tako({"provider": {"preset": "deepseek", "key": "sk-test"}})
        (self.tako.home / "logged_out").write_text("")
        self.assertEqual(self.tako.call("/setup")["step"], "ready")
        deadline = time.time() + 8
        while not self.started() and time.time() < deadline:
            time.sleep(0.02)
        first = [json.loads(line) for line in self.tako.log.read_text().splitlines() if '"started"' in line][0]
        self.assertEqual(first["settings"].get("model_provider"), '"tako"')
        self.assertEqual(first["settings"].get("web_search"), '"disabled"')
        self.assertEqual(first["key"], "sk-test")
        self.assertNotIn("sk-test", " ".join(first["args"]))


if __name__ == "__main__":
    unittest.main(verbosity=1)
