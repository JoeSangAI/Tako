"""What stands between a new install and its first answer: finding a Codex that works, installing or updating it, logging in."""
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

LOGIN_LINK = re.compile(r"https://auth\.openai\.com/\S+")
COLOR = re.compile(r"\x1b\[[0-9;]*m")
SETTINGS_ERROR = re.compile(r"Error loading configuration: (.+?config\.toml):(\d+):\d+: ")


class Setup:
    """What stands between a new install and its first answer. One step at a time, and the panel only ever shows the next one."""
    INSTALL = "curl -fsSL https://chatgpt.com/codex/install.sh | sh"
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

    def state(self):
        if self.working:
            return {"step": self.working, "busy": True, "error": "", "link": self.link}
        if not find_codex():
            return {"step": "update" if _installed() else "install", "busy": False, "error": self.failed}
        if self.logged_in or self._logged_in():
            return {"step": "ready", "busy": False, "error": ""}
        if self.broken:
            return {"step": "config", "busy": False, "error": self.broken}
        return {"step": "login", "busy": False, "error": self.failed}

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

    def logged_out(self):
        """The model said so: ask again, so the panel can show the step."""
        self.logged_in, self.checked = False, 0.0

    def next_step(self):
        """Only ever runs because the owner pressed the button."""
        with self.starting:
            step = self.state()["step"]
            if step == "config":
                self._set_settings_aside()
            elif step in ("install", "update", "login") and not self.working:
                self.working, self.failed = step, ""
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
            return False
        listening.join(1)
        if self.cancelled:
            return False
        if code:
            self.broken = _unreadable_settings("\n".join(said))
            self.failed = _why_login_failed(said)
            return False
        self.logged_in, self.broken = True, ""
        return True

    def _run(self, step):
        changed = False
        try:
            if step == "login":
                changed = self._log_in()
            elif subprocess.run(["/bin/sh", "-c", self.INSTALL], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=600, env={**os.environ, "CODEX_NON_INTERACTIVE": "1"}).returncode:
                self.failed = "Codex 没装上，检查网络后再试一次。"
            else:
                changed = True
        except (OSError, subprocess.SubprocessError):
            self.failed = "这一步没有走通，检查网络后再试一次。"
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


def find_codex():
    """The first Codex that can run Tako. Found fresh each time: it may have just been installed."""
    return next((path for path in _installed() if _can_serve(path)), None)
