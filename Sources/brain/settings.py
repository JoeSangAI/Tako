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
# One clock everywhere: what Tako says, and what the model's own `date` and the commands it runs say. Only what the owner set, and only a zone that exists.
if CONFIG.get("timezone") and isinstance(ZONE, ZoneInfo) and ZONE.key == CONFIG["timezone"]:
    os.environ["TZ"] = ZONE.key
    time.tzset()
OWNER = str(CONFIG.get("name") or account_name())
MODEL = CONFIG.get("model") or None  # The owner's own jobs. None leaves it to the model the owner's Codex is set to.
LIGHT_MODEL = CONFIG.get("light_model") or MODEL  # Throwaway threads: greetings, lecture notes, learning from edits, feedback.
OUTPUT_ROOT = configured_path(CONFIG.get("output_root")) or Path.home() / "Desktop" / "Tako"
BACKGROUND = configured_path(CONFIG.get("background_file")) or RUNTIME / "about-me.md"
WORKBENCH_SETTING = CONFIG.get("workbench") if isinstance(CONFIG.get("workbench"), dict) else {}
WORKBENCH = os.environ.get("TAKO_WORKBENCH") or WORKBENCH_SETTING.get("url")  # Write tests point this at an isolated copy.
WORKBENCH_CARDS = configured_path(WORKBENCH_SETTING.get("cards"))
HAS_WORKBENCH = bool(WORKBENCH and WORKBENCH_CARDS and WORKBENCH_CARDS.is_file())
HAS_WECHAT = reader.enable(CONFIG.get("wechat_export"))
WECHAT = "com.tencent.xinWeChat"
POLL_SECONDS = 3         # While a draft waits to be sent. Only looks at file stats; the heavy read waits until this chat really changed.
FULL_READ_SECONDS = 60   # In case the session list misses a message.
SENT_SETTLE_SECONDS = 45 # The owner often sends one reply in several messages.
COMPACT_AT = 120_000     # Input tokens per request at which the shared thread gets summarized.
COMPACT_PICTURES_AT = 3_000_000  # Bytes of screenshots on the thread. They cost few tokens, but a reconnect uploads every one of them again.
CONTEXT_MESSAGES = 30
MAX_MESSAGE_CHARS = 2000
VOICE = RUNTIME / "voice.md"      # Habits learned from the owner's edits, never their sentences. Plain text they can read or change.
METRICS = RUNTIME / "metrics.jsonl"  # Numbers only, never chat content.
ASKED = RUNTIME / "asked.json"      # What the owner asked and how it ended, a week of it: their words, never a window's.


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
