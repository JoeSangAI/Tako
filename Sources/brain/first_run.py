"""What stands between a new install and its first answer: finding Codex, installing it, logging in."""
from __future__ import annotations

import os
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
        self.working = None    # "install" or "login" while it runs
        self.failed = ""
        self.logged_in = False
        self.checked = 0.0

    def state(self):
        if self.working:
            return {"step": self.working, "busy": True, "error": ""}
        if not find_codex():
            return {"step": "install", "busy": False, "error": self.failed}
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
        if step not in ("install", "login") or self.working:
            return
        self.working, self.failed = step, ""
        threading.Thread(target=self._run, args=(step,), daemon=True).start()

    def _run(self, step):
        try:
            command = ["/bin/sh", "-c", self.INSTALL] if step == "install" else [find_codex(), "login"]
            done = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=600, env={**os.environ, "CODEX_NON_INTERACTIVE": "1"})
            if done.returncode:
                self.failed = ("Codex 没装上，检查网络后再试一次。" if step == "install" else "没有登录成功，再试一次。")
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


def find_codex():
    """The places Codex's own installers put it, then whatever the login shell knows. Found fresh each time: it may have just been installed."""
    home = Path.home()
    places = [home / ".local/bin/codex", home / ".codex/bin/codex", Path("/opt/homebrew/bin/codex"), Path("/usr/local/bin/codex"), home / ".npm-global/bin/codex",
              # The ChatGPT desktop app carries its own, and shares the login with it.
              Path("/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"), home / "Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"]
    found = shutil.which("codex")
    if found:
        return found
    return next((str(path) for path in places if os.access(path, os.X_OK)), None)
