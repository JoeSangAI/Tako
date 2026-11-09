"""What stands between a new install and its first answer: finding a Codex that works, installing or updating it, logging in or giving it a key."""
from __future__ import annotations

import collections
import contextlib
import os
import re
import shutil
import signal
import subprocess
import threading
import time
from pathlib import Path

import office
import provider

LOGIN_LINK = re.compile(r"https://auth\.openai\.com/\S+")
COLOR = re.compile(r"\x1b\[[0-9;]*m")
SETTINGS_ERROR = re.compile(r"Error loading configuration: (.+?config\.toml):(\d+):\d+: ")


class Setup:
    """What stands between a new install and its first answer. One step at a time, and the panel only ever shows the next one."""
    # OpenAI's own installer. chatgpt.com doesn't open everywhere (mainland China), and the same script ships with every GitHub release;
    # it fetches Codex itself from GitHub when OpenAI's servers don't answer.
    INSTALL = ('f="$(mktemp)" && { curl -fsSL --max-time 30 https://chatgpt.com/codex/install.sh -o "$f" || '
               'curl -fsSL --max-time 120 https://github.com/openai/codex/releases/latest/download/install.sh -o "$f"; } && sh "$f"; code=$?; rm -f "$f"; exit $code')
    LOGIN_PATIENCE = 600

    def __init__(self, companion):
        self.companion = companion
        self.working = None    # "install", "update" or "login" while it runs
        self.failed = ""
        self.logged_in = None  # None until Codex has answered once
        self.checked = 0.0
        self.broken = ""       # What Codex can't read in its own settings file; no login gets past that.
        self.link = ""         # The page the browser should be on, in case it didn't open.
        self.login = None      # The `codex login` still waiting for the browser
        self.cancelled = False
        self.starting = threading.Lock()
        self.key_refused = False  # The service said no to the owner's own key; only a new key gets past that.
        self.models = []          # What a relay offered when the owner hadn't picked a model yet.
        self.office_refused = False  # The office agent turned a turn away for its login: only opening the app gets past that.
        self.office_seen = (0.0, None, "")  # when its login was last read from disk, for which agent, and what stands in the way
        self.failed_for = ""  # which way of logging in `failed` is about: an office agent's id, or "chatgpt"
        self.choosing = False  # The owner opened 模型设置 from the menu: the first card again, over a model that already works.
        self.seen = set()  # The steps shown since Tako started, each counted once (`_count`).
        self.outdated = False  # A turn was refused because this Codex is older than the model it is set to needs: only an update gets past that.

    def offices(self):
        return [{"id": key, "name": office.AGENTS[key]["name"]} for key in office.installed()]

    def office_problem(self, agent, fresh=False):
        """Read from what the app keeps on disk, at most every half minute: the panel asks every two seconds while a step is open."""
        when, which, problem = self.office_seen
        if fresh or which != agent["id"] or time.time() - when > 30:
            problem = office.problem(agent)
            self.office_seen = (time.time(), agent["id"], problem)
        return problem

    def _count(self, name):
        """Fixed words only (`setup.saw.<step>`, `setup.failed.<what>`, `setup.ok.<way>`): where a new install gets stuck, never what was typed or said."""
        feedback = getattr(self.companion, "feedback", None)
        if feedback:
            feedback.count(f"setup.{name}")

    def state(self):
        seen = self._state()
        step = "settings" if seen.get("choosing") else seen["step"]  # 模型设置 from the menu is not a new install stuck at login
        if not seen["busy"] and step not in self.seen:
            self.seen.add(step)
            self._count(f"saw.{step}")
        return seen

    def _state(self):
        if self.working:
            return {"step": self.working, "busy": True, "error": "", "link": self.link}
        if self.choosing:
            return {"step": "login", "busy": False, "choosing": True, "current": self.current_name(), "error": self.failed, "error_for": self.failed_for,
                    "services": provider.services(), "models": self.models, "offices": self.offices()}
        agent = office.current()
        if agent:
            # No Codex at all: the office agent is the brain, on the login its own app keeps.
            problem = self.office_problem(agent)
            if problem or self.office_refused:
                return {"step": "office", "busy": False, "error": self.failed or problem or office.stale_login(agent).replace("然后再说一次", "然后点“再试一次”"),
                        "office": agent["id"], "name": agent["name"], "offices": self.offices()}
            return {"step": "ready", "busy": False, "error": "", "service": agent["id"]}
        codex = find_codex()
        if (not codex and _installed()) or (codex and self.outdated):
            return {"step": "update", "busy": False, "error": self.failed}
        own_key = provider.current()
        if own_key and not codex:
            # A key needs Codex: it goes on once Codex is in. Only here, after the owner chose a key, is installing a step of its own.
            return {"step": "install", "busy": False, "error": self.failed, "service": own_key.get("preset") or "custom"}
        if own_key:
            # No ChatGPT login needed: the key is the login.
            if self.key_refused or not own_key["key"]:
                return {"step": "key", "busy": False, "error": self.failed or ("这个 key 用不了了，换一个。" if own_key["key"] else ""), "service": own_key.get("preset") or "custom",
                        "services": provider.services(), "models": self.models}
            return {"step": "ready", "busy": False, "error": "", "service": own_key.get("preset") or "custom"}
        if codex and (self.logged_in or self._logged_in()):
            return {"step": "ready", "busy": False, "error": ""}
        if self.broken:
            return {"step": "config", "busy": False, "error": self.broken}
        # The first card: an account (an office agent on this Mac, or ChatGPT, which Codex is installed for when it is picked) or a key.
        return {"step": "login", "busy": False, "error": self.failed, "error_for": self.failed_for, "services": provider.services(), "models": self.models, "offices": self.offices()}

    def current_name(self):
        """What the turns run on now, in the words of the first card."""
        agent = office.current()
        if agent:
            return agent["name"]
        own_key = provider.current()
        if own_key:
            return provider.PRESETS.get(own_key.get("preset"), {}).get("name") or own_key.get("name") or "中转站"
        return "ChatGPT" if find_codex() and self.logged_in else ""

    def choose(self):
        """Only from 模型设置 in the menu: the first card comes back, and what works now keeps working until something else is picked."""
        if not self.working:
            self.choosing, self.failed, self.failed_for, self.models = True, "", "", []

    def close(self):
        self.choosing, self.failed, self.failed_for, self.models = False, "", "", []

    def _logged_in(self):
        # Asked at most every few seconds; a slow answer is not evidence of a missing login, and neither is no answer yet.
        if time.time() - self.checked < 4:
            return self.logged_in is None
        self.checked = time.time()
        codex = find_codex()
        try:
            done = subprocess.run([codex, "login", "status"], stdin=subprocess.DEVNULL, capture_output=True, text=True, errors="replace", timeout=8, env=_with_its_folder(codex))
            self.logged_in = done.returncode == 0
            self.broken = "" if self.logged_in else _unreadable_settings(done.stdout + done.stderr)
        except subprocess.TimeoutExpired:
            self.logged_in = True
        except OSError:
            self.logged_in = False
        return self.logged_in

    def too_old(self):
        """The model said this Codex is too old for it: the update card comes up, and the update clears it."""
        self.outdated = True

    def logged_out(self):
        """The model said so: ask again, so the panel can show the step."""
        self.logged_in, self.checked = False, 0.0
        self.key_refused = bool(provider.current())
        self.office_refused = bool(office.current())

    def use_office(self, agent):
        """An office agent on this Mac as the brain, only from the panel's button. Its login is read first, at no cost, and kept only if it is good."""
        if agent not in office.installed():
            self.failed = "这台 Mac 上没找到它。"
            return False
        found = {**office.AGENTS[agent], "id": agent}
        problem = self.office_problem(found, fresh=True)
        if problem:
            self.failed, self.failed_for = problem, agent
            self._count("failed.office")
            return False
        office.save(agent)
        self._count("ok.office")
        provider.forget()
        self.failed, self.office_refused, self.key_refused, self.choosing = "", False, False, False
        self.companion.submit(self.companion.start_over())
        return True

    def use_key(self, service, key, base_url="", model=""):
        """The owner's own key, only from the panel's button: a service in `provider.PRESETS`, or any address that speaks Responses (`custom`, a relay).
        Checked first, at no cost, so a wrong one says so now; the models the service offers come back for the owner to pick from."""
        key = (key or "").strip()
        self.models = []
        if (service not in provider.PRESETS and service != "custom") or not key:
            self.failed = "选一家，再把 key 粘进来。"
            return False
        problem, self.models = provider.check(service, key, base_url, model)
        if problem:
            self.failed = problem
            self._count("failed.key")
            return False
        provider.save(service, key, base_url, model)
        self._count("ok.key")
        office.forget()
        self.failed, self.key_refused, self.models, self.choosing = "", False, [], False
        with self.starting:
            if not find_codex() and not self.working:  # The key is kept; Codex goes in, and the brain starts once it is there.
                self.working = "install"
                threading.Thread(target=self._run, args=("install",), daemon=True).start()
                return True
        self.companion.submit(self.companion.start_over())
        return True

    def use_login(self):
        """Back to a ChatGPT login: the key Tako kept is gone from this Mac, and so is the choice of an office agent."""
        provider.forget()
        office.forget()
        self.failed, self.key_refused, self.office_refused, self.logged_in, self.checked, self.choosing = "", False, False, None, 0.0, False
        self.companion.submit(self.companion.start_over())

    def next_step(self):
        """Only ever runs because the owner pressed the button."""
        with self.starting:
            if self.choosing and not self.working:
                # ChatGPT picked from 模型设置: a key or an office agent kept from before would win over it, so they go first.
                # A Codex already logged in is used as it is; otherwise the browser login, as on the first day.
                provider.forget()
                office.forget()
                self.choosing, self.failed, self.failed_for, self.key_refused, self.office_refused, self.checked = False, "", "", False, False, 0.0
                if find_codex() and self._logged_in():
                    self.companion.submit(self.companion.start_over())
                    return
            step = self.state()["step"]
            if step == "office":
                # "再试一次": the login is read again, and a good one starts the agent afresh.
                agent = office.current()
                if agent and not self.office_problem(agent, fresh=True):
                    self.failed, self.office_refused = "", False
                    self.companion.submit(self.companion.start_over())
                elif agent:
                    self.failed = ""
            elif step == "config":
                self._set_settings_aside()
            elif step in ("install", "update", "login") and not self.working:
                self.working, self.failed, self.failed_for = step, "", ""
                threading.Thread(target=self._run, args=(step,), daemon=True).start()

    def cancel(self):
        """The owner changed their mind. The script npm puts in front of Codex and Codex itself both go, so nothing is left holding the login's port."""
        process = self.login
        if process and process.poll() is None:
            self.cancelled = True
            with contextlib.suppress(OSError):
                os.killpg(process.pid, signal.SIGKILL)

    def _set_settings_aside(self):
        """Only for the button that says so: the file keeps its contents and its folder, under another name."""
        settings = _codex_home() / "config.toml"
        with contextlib.suppress(OSError):
            settings.rename(settings.with_name(f"config.toml.tako-{time.strftime('%Y%m%d-%H%M%S')}"))
        self.broken, self.failed, self.logged_in, self.checked = "", "", None, 0.0
        self.companion.submit(self.companion.start_over())

    def _log_in(self):
        """Says why when it can't, and shows the page while it waits: Codex prints it long before it ends."""
        codex = find_codex()
        said = collections.deque(maxlen=40)

        def listen(output):
            with output:
                for line in output:
                    line = COLOR.sub("", line).strip()
                    said.append(line)
                    found = LOGIN_LINK.search(line)
                    if found and not self.link:
                        self.link = found[0]

        self.link, self.cancelled = "", False
        self.login = subprocess.Popen([codex, "login"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace",
                                      env=_with_its_folder(codex), start_new_session=True)
        listening = threading.Thread(target=listen, args=(self.login.stdout,), daemon=True)
        listening.start()
        try:
            code = self.login.wait(timeout=self.LOGIN_PATIENCE)
        except subprocess.TimeoutExpired:
            self.cancel()
            self.login.wait()
            self.failed = "等了十分钟，浏览器那边没有完成。再点一次登录。"
            self._count("failed.login.timeout")
            return False
        listening.join(1)
        if self.cancelled:
            return False
        if code:
            self.broken = _unreadable_settings("\n".join(said))
            self.failed = _why_login_failed(said)
            self._count(f"failed.login.{_login_failure_kind(said)}")
            return False
        self.logged_in, self.broken = True, ""
        self._count("ok.chatgpt")
        return True

    def _install(self):
        if subprocess.run(["/bin/sh", "-c", self.INSTALL], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=600, env={**os.environ, "CODEX_NON_INTERACTIVE": "1"}).returncode:
            self.failed = "Codex 没装上，检查网络后再试一次。"
            self._count("failed.install")
            return False
        return True

    def _run(self, step):
        changed = False
        try:
            if step == "login":
                # ChatGPT was picked on a Mac without Codex: it goes in first, then straight on to the browser.
                if not find_codex():
                    self.working = "install"
                    if not self._install():
                        self.failed_for = "chatgpt"
                        return
                    self.working = "login"
                changed = self._log_in()
                if not changed:
                    self.failed_for = "chatgpt"
            else:
                changed = self._install()
                if changed:
                    self.outdated = False
                    _serves.clear()
                    _versions.clear()
        except (OSError, subprocess.SubprocessError):
            self.failed = "这一步没有走通，检查网络后再试一次。"
            self._count(f"failed.{step}")
        finally:
            self.working, self.login, self.link = None, None, ""
            self.checked = 0.0
            self.companion.submit(self.companion.start_over() if changed else self.companion.warm())


def _codex_home():
    return Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")


def _with_its_folder(executable):
    """Codex's own tools, and the node a Codex from npm needs, sit next to it."""
    return {**os.environ, "PATH": f"{Path(executable).parent}{os.pathsep}{os.environ.get('PATH', '')}"}


def _unreadable_settings(said):
    """What to tell the owner when Codex stops at its own settings file. Only that one file: anything else isn't ours to offer to move."""
    found = SETTINGS_ERROR.search(said)
    if not found or os.path.realpath(found[1]) != os.path.realpath(_codex_home() / "config.toml"):
        return ""
    return f"{found[1].replace(str(Path.home()), '~', 1)} 的第 {found[2]} 行 Codex 读不懂。"


def _login_failure_kind(said):
    """The same reasons as `_why_login_failed`, as fixed words for counting."""
    text = "\n".join(line for line in said if line and not LOGIN_LINK.search(line) and not line.startswith("WARNING"))
    for words, kind in (("ChatGPT login is disabled", "disabled"), ("already in use", "port"), ("Token exchange failed", "network"),
                        ("error sending request", "network"), ("not completed", "browser"), ("timed out", "browser"), ("cancelled", "browser")):
        if words in text:
            return kind
    return "silent" if not text else "other"


def _why_login_failed(said):
    """The real reason and the one thing to do. Codex's words stay on this Mac; the login page's address is never repeated."""
    words = [line for line in said if line and not LOGIN_LINK.search(line) and not line.startswith("WARNING")]
    text = "\n".join(words)
    if "ChatGPT login is disabled" in text:
        return "这台电脑的 Codex 设置不允许用 ChatGPT 登录。找管这台电脑的人改掉 forced_login_method，再点登录。"
    if "already in use" in text:
        return "登录要用的本机端口被别的程序占着。退出其他正在登录的 Codex，再点登录。"
    if "Token exchange failed" in text or "error sending request" in text:
        return "Codex 连不上 OpenAI，登录没有完成。检查网络或代理，再点登录。"
    if "not completed" in text or "timed out" in text or "cancelled" in text:
        return "浏览器那边没有完成登录。再点一次登录，在打开的页面里确认。"
    if not words:
        return "登录没有走通，Codex 什么也没说。再点一次登录。"
    return f"登录没有走通，Codex 说：{words[-1].removeprefix('Error logging in: ')[:160]}"


def codex_on_path(executable):
    """Codex's own tools expect to find each other."""
    folder = Path(executable).parent
    if str(folder) != "." and str(folder) not in os.environ.get("PATH", "").split(os.pathsep):
        os.environ["PATH"] = f"{folder}{os.pathsep}{os.environ.get('PATH', '')}"


def _installed():
    """Every Codex on this Mac, in the order it would be used: whatever the login shell knows, then the places installers and version managers put it."""
    home = Path.home()
    newest_first = lambda pattern: sorted(home.glob(pattern), key=lambda path: [int(n) for n in re.findall(r"\d+", str(path.relative_to(home)))], reverse=True)
    places = [home / ".local/bin/codex", home / ".codex/bin/codex", Path("/opt/homebrew/bin/codex"), Path("/usr/local/bin/codex"), home / ".npm-global/bin/codex",
              # A login shell doesn't read .zshrc, so a version manager's PATH never reaches the app.
              *newest_first(".nvm/versions/node/*/bin/codex"), *newest_first(".local/share/fnm/node-versions/*/installation/bin/codex"),
              *newest_first("Library/Application Support/fnm/node-versions/*/installation/bin/codex"), home / ".volta/bin/codex", home / ".asdf/shims/codex",
              home / "Library/pnpm/codex", home / ".local/share/pnpm/codex", home / ".bun/bin/codex",
              # The ChatGPT desktop app carries its own, and shares the login with it.
              Path("/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"), home / "Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"]
    found = [shutil.which("codex"), *(str(path) for path in places if os.access(path, os.X_OK))]
    return list(dict.fromkeys(path for path in found if path))


_serves = {}


def _can_serve(path):
    """Whether this Codex has the app server Tako talks to; asked once per file. A slow answer is not evidence of an old one."""
    try:
        key = (path, os.stat(path).st_mtime)
    except OSError:
        return False
    if key not in _serves:
        try:
            done = subprocess.run([path, "app-server", "--help"], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10, env=_with_its_folder(path))
            _serves[key] = "--listen" in done.stdout + done.stderr
        except subprocess.TimeoutExpired:
            return True
        except OSError:
            _serves[key] = False
    return _serves[key]


_versions = {}


def _version(path):
    """`codex --version` as numbers, asked once per file; () when it won't say."""
    try:
        key = (path, os.stat(path).st_mtime)
    except OSError:
        return ()
    if key not in _versions:
        try:
            done = subprocess.run([path, "--version"], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10, env=_with_its_folder(path))
            found = re.search(r"(\d+(?:\.\d+)+)", done.stdout + done.stderr)
            _versions[key] = tuple(int(n) for n in found[1].split(".")) if found else ()
        except (OSError, subprocess.TimeoutExpired):
            _versions[key] = ()
    return _versions[key]


def find_codex():
    """The newest Codex that can run Tako, the first of them on a tie. An old one on the PATH must not hide the one the ChatGPT app
    or an update just put in: the model Codex is set to may need the newer one. Found fresh each time: it may have just been installed."""
    usable = [path for path in _installed() if _can_serve(path)]
    return max(usable, key=_version) if usable else None
