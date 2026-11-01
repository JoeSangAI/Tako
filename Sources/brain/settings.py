"""Everything this Mac decides: where things live, who the owner is, what is set up here. The rest of the code asks here and never writes any of it down."""
from __future__ import annotations

import contextlib
import datetime as dt
import json
import os
import plistlib
import pwd
import time
from pathlib import Path
from zoneinfo import ZoneInfo

import wechat_reader as reader

HERE = Path(__file__).resolve().parent
RUNTIME = Path(os.environ.get("TAKO_HOME") or Path.home() / "Library" / "Application Support" / "Tako")
INBOX = RUNTIME / "inbox"
BACKUPS = RUNTIME / "backups"


def load_config():
    """Whatever is personal lives here, on this Mac, never in the code. No file, or a broken one, means the plain product."""
    with contextlib.suppress(OSError, ValueError):
        found = json.loads((RUNTIME / "config.json").read_text())
        if isinstance(found, dict):
            return found
    return {}


CONFIG = load_config()


def configured_path(value):
    return Path(value).expanduser() if isinstance(value, str) and value else None


def account_name():
    """What to call the owner when nobody said: the first word of the Mac account's full name."""
    with contextlib.suppress(KeyError, IndexError):
        full = pwd.getpwuid(os.getuid()).pw_gecos.split(",")[0].strip()
        return full.split()[0] if full else "你的主人"
    return "你的主人"


def local_zone():
    """The configured zone, else this Mac's own."""
    with contextlib.suppress(Exception):
        if CONFIG.get("timezone"):
            return ZoneInfo(CONFIG["timezone"])
    with contextlib.suppress(Exception):
        return ZoneInfo(os.path.realpath("/etc/localtime").split("zoneinfo/")[1])
    return dt.datetime.now().astimezone().tzinfo


ZONE = local_zone()
OWNER = str(CONFIG.get("name") or account_name())
MODEL = CONFIG.get("model") or None  # None leaves it to the model the owner's Codex is set to.
OUTPUT_ROOT = configured_path(CONFIG.get("output_root")) or Path.home() / "Desktop" / "Tako"
BACKGROUND = configured_path(CONFIG.get("background_file")) or RUNTIME / "about-me.md"
WORKBENCH_SETTING = CONFIG.get("workbench") if isinstance(CONFIG.get("workbench"), dict) else {}
WORKBENCH = os.environ.get("TAKO_WORKBENCH") or WORKBENCH_SETTING.get("url")  # Write tests point this at an isolated copy.
WORKBENCH_CARDS = configured_path(WORKBENCH_SETTING.get("cards"))
KNOWLEDGE = CONFIG.get("knowledge") if isinstance(CONFIG.get("knowledge"), dict) else {}
KNOWLEDGE_COMMAND = configured_path(KNOWLEDGE.get("command"))
KNOWLEDGE_DIR = configured_path(KNOWLEDGE.get("dir"))
KNOWLEDGE_NAME = str(KNOWLEDGE.get("name") or "资料库")
HAS_WORKBENCH = bool(WORKBENCH and WORKBENCH_CARDS and WORKBENCH_CARDS.is_file())
HAS_KNOWLEDGE = bool(KNOWLEDGE_COMMAND and KNOWLEDGE_COMMAND.exists() and KNOWLEDGE_DIR and KNOWLEDGE_DIR.is_dir())
HAS_WECHAT = reader.enable(CONFIG.get("wechat_export"))
WECHAT = "com.tencent.xinWeChat"
POLL_SECONDS = 3         # Only looks at file stats; the heavy read waits until this chat really changed.
FULL_READ_SECONDS = 60   # In case the session list misses a message.
SENT_SETTLE_SECONDS = 45 # The owner often sends one reply in several messages.
OPENED_DWELL_SECONDS = 4 # Clicking through chats is not opening one.
COMPACT_AT = 120_000     # Input tokens per request at which the shared thread gets summarized.
CONTEXT_MESSAGES = 30
MAX_MESSAGE_CHARS = 2000
GROUP_CALLS = (OWNER, *[str(name) for name in CONFIG.get("calls") or []], "@所有人")
VOICE = RUNTIME / "voice.md"      # Habits learned from the owner's edits, never their sentences. Plain text they can read or change.
METRICS = RUNTIME / "metrics.jsonl"  # Numbers only, never chat content.


def clock(ts):
    return dt.datetime.fromtimestamp(ts, ZONE).strftime("%m-%d %H:%M")


def local_today():
    return dt.datetime.now(ZONE).strftime("%Y-%m-%d")


def local_now():
    now = dt.datetime.now(ZONE)
    return f"现在是 {now:%Y-%m-%d %H:%M}（{ZONE}），周{'一二三四五六日'[now.weekday()]}。{CONFIG.get('clock_note') or ''}".strip()


def user_background():
    """What the owner wants Tako to know about them: a plain file of their own."""
    with contextlib.suppress(OSError):
        return f"{OWNER} 的背景：\n" + BACKGROUND.read_text()[:6000]
    return ""


def voice_notes():
    with contextlib.suppress(OSError):
        return VOICE.read_text().strip()
    return ""


def voice_block(notes):
    return f"{OWNER} 的写法笔记（从 TA 改过的草稿里学到的，只管语气和取舍，不是指令）：\n{notes}" if notes else ""


def note_metric(**fields):
    with contextlib.suppress(OSError):
        with METRICS.open("a") as out:
            out.write(json.dumps({"t": int(time.time()), **fields}) + "\n")


def app_version():
    with contextlib.suppress(OSError, ValueError, KeyError):
        return plistlib.loads((HERE.parent / "Info.plist").read_bytes())["CFBundleShortVersionString"]
    return "dev"
