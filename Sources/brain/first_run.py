"""What stands between a new install and its first answer: finding a Codex that works, installing or updating it, logging in."""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import threading
import time
from pathlib import Path


class Setup:
    """What stands between a new install and its first answer. One step at a time, and the panel only ever shows the next one."""
    INSTALL = "curl -fsSL https://chatgpt.com/codex/install.sh | sh"

    def __init__(self, companion):
        self.companion = companion
        self.working = None    # "install", "update" or "login" while it runs
        self.failed = ""
        self.logged_in = False
        self.checked = 0.0

    def state(self):
        if self.working:
            return {"step": self.working, "busy": True, "error": ""}
        if not find_codex():
            return {"step": "update" if _installed() else "install", "busy": False, "error": self.failed}
        if self.logged_in or self._logged_in():
            return {"step": "ready", "busy": False, "error": ""}
        return {"step": "login", "busy": False, "error": self.failed}

    def _logged_in(self):
        # Asked at most every few seconds; a slow answer is not evidence of a missing login.
        if time.time() - self.checked < 4:
            return False
        self.checked = time.time()
        try:
            self.logged_in = subprocess.run([find_codex(), "login", "status"], stdin=subprocess.DEVNULL, capture_output=True, timeout=8).returncode == 0
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
        step = self.state()["step"]
        if step not in ("install", "update", "login") or self.working:
            return
        self.working, self.failed = step, ""
        threading.Thread(target=self._run, args=(step,), daemon=True).start()

    def _run(self, step):
        try:
            command = [find_codex(), "login"] if step == "login" else ["/bin/sh", "-c", self.INSTALL]
            done = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=600, env={**os.environ, "CODEX_NON_INTERACTIVE": "1"})
            if done.returncode:
                self.failed = "没有登录成功，再试一次。" if step == "login" else "Codex 没装上，检查网络后再试一次。"
        except (OSError, subprocess.SubprocessError):
            self.failed = "这一步没有走通，检查网络后再试一次。"
        finally:
            self.working = None
            self.checked = 0.0
            self.companion.submit(self.companion.warm())


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
        # A Codex from npm needs the node next to it.
        env = {**os.environ, "PATH": f"{Path(path).parent}{os.pathsep}{os.environ.get('PATH', '')}"}
        try:
            done = subprocess.run([path, "app-server", "--help"], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10, env=env)
            _serves[key] = "--listen" in done.stdout + done.stderr
        except subprocess.TimeoutExpired:
            return True
        except OSError:
            _serves[key] = False
    return _serves[key]


def find_codex():
    """The first Codex that can run Tako. Found fresh each time: it may have just been installed."""
    return next((path for path in _installed() if _can_serve(path)), None)
