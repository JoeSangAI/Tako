"""The rules that hold whatever a model or a window says. Plain functions with no state, so each can be tested on its own."""
from __future__ import annotations

import difflib
import hashlib
import os
import re
import unicodedata
from pathlib import Path

from settings import OWNER

# Apps with a real scripting interface, by bundle id. Scripts run inside the app, nowhere else.
SCRIPTABLE = {"com.microsoft.Powerpoint": "Microsoft PowerPoint", "com.microsoft.Excel": "Microsoft Excel",
              "com.microsoft.Word": "Microsoft Word", "com.apple.iWork.Keynote": "Keynote",
              "com.apple.iWork.Numbers": "Numbers", "com.apple.iWork.Pages": "Pages", "com.apple.mail": "Mail",
              "com.apple.Safari": "Safari", "com.google.Chrome": "Google Chrome", "com.apple.Notes": "Notes",
              "com.apple.iCal": "Calendar", "com.apple.reminders": "Reminders", "com.apple.finder": "Finder"}
# What these apps call themselves on a Chinese Mac: the owner's window and the model both use these names.
LOCAL_NAMES = {"访达": "Finder", "备忘录": "Notes", "日历": "Calendar", "提醒事项": "Reminders", "邮件": "Mail", "信息": "Messages", "演示": "Keynote", "表格": "Numbers", "文稿": "Pages"}
# A member count ends the title; anything after it is an icon the OCR took for a letter.
COUNT_SUFFIX = re.compile(r"\s*[(（]\s*\d+\s*[)）].*$")


def normalized(name):
    """What is left of a chat name after OCR: no emoji, spaces or member count."""
    text = COUNT_SUFFIX.sub("", unicodedata.normalize("NFKC", name))
    return "".join(ch for ch in text if ch.isalnum()).lower()


def same_chat(want, line):
    """Whether a title read off WeChat is the chat asked for. Forgiving of a misread character, not of a sibling chat: 产品讨论组1 is not 产品讨论组2.
    People call a chat by its short name: 小林 is 小林-市场 助理, because the name stops at a break there, but it is not 小林妈妈."""
    key, seen = normalized(want), normalized(line)
    digits = lambda text: "".join(ch for ch in text if ch.isdigit())
    if seen == key or (digits(seen) == digits(key) and difflib.SequenceMatcher(None, seen, key).ratio() >= 0.9):
        return True
    start, whole = (unicodedata.normalize("NFKC", text).strip().lower() for text in (want, line))
    return bool(start) and whole.startswith(start) and len(whole) > len(start) and not whole[len(start)].isalnum()


def group_by_members(titles, groups):
    """Which unnamed groups a title made of their members' names is: WeChat shows such a group as the others' names joined, and the head count.
    `groups` is (username, members counted, the other members' names). The best-covered ones, or [] when no group's names make up most of the title."""
    for line in titles:
        want = normalized(line)
        if len(want) < 4:
            continue
        count = re.search(r"[(（]\s*(\d+)\s*[)）]", unicodedata.normalize("NFKC", line))
        hits = []
        for room, counted, people in groups:
            if count and int(count.group(1)) != counted:
                continue
            shown = [key for key in {normalized(person) for person in people} if key and key in want]
            covered = sum(map(len, shown))
            # Without the head count a few names fit many groups: then every other member has to be there.
            enough = len(shown) >= min(2, len(people)) if count else len(shown) == len({normalized(person) for person in people})
            if enough and covered >= 0.8 * len(want):
                hits.append((covered, room))
        if hits:
            best = max(covered for covered, _ in hits)
            return [room for covered, room in hits if covered == best]
    return []


def full_chat_name(chat, names, asked=None):
    """The chat a short name means, from the names WeChat has: (name, the others it could equally be). The one the owner is talking about right now wins."""
    if any(normalized(name) == normalized(chat) for name in names):
        return chat, []
    fits = list(dict.fromkeys(name for name in names if same_chat(chat, name)))
    if asked in fits or len(fits) == 1:
        return (asked if asked in fits else fits[0]), []
    return chat, fits


def last_draft(answer):
    found = re.findall(r"```draft[^\n]*\n(.*?)```", answer or "", re.S)
    return found[-1].strip() if found else ""


def learned_notes(answer, draft, sent):
    """What may be kept from a learning turn: habits only. A line that repeats the chat or carries a figure doesn't survive."""
    if not answer or "【无】" in answer:
        return None
    notes = []
    for line in answer.splitlines():
        line = line.strip().lstrip("-•· ").strip()
        if not line or len(line) > 80 or re.search(r"\d", line):
            continue
        if any(line[at:at + 10] in draft or line[at:at + 10] in sent for at in range(max(1, len(line) - 9))):
            continue
        notes.append(f"- {line}")
    return "\n".join(notes[:15]) or None


def clipped(text, limit=1500):
    """A card never cuts what is being approved without saying so."""
    return text if len(text) <= limit else f"{text[:limit]}\n……（还有 {len(text) - limit} 字没显示）"


def workbench_packet(args, said, today):
    """Only the owner's own words reach the workbench, under the identity of the message they came from."""
    text, kind = str(args.get("text") or "").strip(), args.get("kind")
    source = next((key for key, words in reversed(said) if text and text in words), None)
    if not source:
        raise ValueError(f"这不是 {OWNER} 的原话。工作台只收 TA 自己说的话，请 TA 说一句，或逐字摘 TA 说过的话。")
    digest = hashlib.sha256("|".join((str(kind), str(args.get("item")), text)).encode()).hexdigest()[:12]
    source_id = f"tako-{source}-{digest}"
    if kind == "capture":
        return {"target": "capture", "source_id": source_id, "date": today, "text": text}
    if kind not in ("supplement", "answer", "complete"):
        raise ValueError("kind 只能是 capture、supplement、answer、complete")
    missing = [key for key in ("item", "action", "revision", "date") if args.get(key) in (None, "")]
    if missing:
        raise ValueError(f"缺 {'、'.join(missing)}，先从 /api/desk 读这个事项")
    return {"target": "action", "source_id": source_id, "id": str(args["item"]), "action_id": str(args["action"]), "revision": args["revision"],
            "date": str(args["date"]), "kind": "text" if kind == "supplement" else kind, "text": text}


PATH_START = re.compile(r"(?<![\w/.:~-])(?:~/|/)[^\n，。；：！？、“”‘’\"'（）()<>《》]+")


def pointable(path):
    """A place the owner can point at to have it worked on: anything but a whole home or disk."""
    home, real = str(Path.home()), os.path.realpath(path)
    return real if os.path.exists(real) and real.count("/") > 1 and not (home == real or home.startswith(real + "/")) else None


def named_paths(words):
    """The files and folders the owner names in their own words: what the model's shell may read for them. Only what exists, and never a whole home or disk."""
    named = set()
    for match in PATH_START.finditer(words or ""):
        candidate = os.path.expanduser(match.group().strip())
        # "/a/发票 填进去": the words after a path belong to the sentence. Only the last part can be cut, so a typo never widens to the folder above it.
        folder, _, name = candidate.rstrip("/").rpartition("/")
        for end in range(len(name), 0, -1):
            path = f"{folder}/{name[:end].rstrip()}"
            if os.path.exists(path):
                if real := pointable(path):
                    named.add(real)
                break
    return named


def plain_command(command):
    """The command itself, without the shell wrapper Codex runs it in."""
    return re.sub(r"^\S*(?:ba|z)?sh -l?c\s+", "", str(command or "")).strip("'\"")


SCRIPT_TOKENS = re.compile(r'"(?:[^"\\]|\\.)*"|--[^\n]*|#[^\n]*|\(\*.*?\*\)', re.S)


def script_code(script):
    """The script with comments gone and strings kept aside, so words inside someone's text don't count and quotes can't hide code."""
    strings = []

    def keep(match):
        token = match.group()
        if not token.startswith('"'):
            return " "
        strings.append(token[1:-1])
        return f'"{len(strings) - 1}"'
    return re.sub(r"\s+", " ", SCRIPT_TOKENS.sub(keep, script)).lower(), strings


def unsafe_script(script, app):
    """A script may only talk to the app it was written for, in a form that can be read."""
    code, strings = script_code(script)
    if "«" in code or "¬" in code:
        return "脚本不能用原始事件和续行符"
    for word in ("do shell", "do script", "run script", "load script", "store script", "system events", "osascript",
                 "using terms", "current application", "framework", "open for access"):
        if word in code:
            return f"脚本不能使用 {word}"
    if re.search(r"\bsend\b", code):
        return f"脚本不能发送，发送留给 {OWNER}"
    allowed = {app.lower(), *(bundle.lower() for bundle, name in SCRIPTABLE.items() if name == app)}
    for name in re.finditer(r'\b(?:application|app)\b(?: ?id)? ?(?:"(\d+)")?', code):
        if name.group(1) is None or strings[int(name.group(1))].lower() not in allowed:
            return f"脚本只能操作 {app}，而且要直接写出它的名字"
    return None


# JavaScript that does more than read the page: it could click, type, submit or send on the owner's behalf.
PAGE_CHANGING = re.compile(r"\.click\(|submit\(|dispatchEvent|\.value\s*=|innerHTML\s*=|innerText\s*=|textContent\s*=|execCommand|\.remove\("
                           r"|fetch\(|XMLHttpRequest|sendBeacon|WebSocket|location\s*=|location\.(?:assign|replace|href\s*=)|\.focus\(|keydown|keypress|\.send\(", re.I)


def risky_script(script):
    """What a script would do that can't be taken back: deleting, closing without saving, or JavaScript that changes a page. Reading a page, closing or quitting with nothing lost goes ahead."""
    code, strings = script_code(script)
    found = re.search(r"\b(delete|erase|remove|empty)\b", code)
    if found:
        return found.group(1)
    if re.search(r"\bsaving no\b", code):
        return "saving no"
    # Each piece of page code is the string right after the word; JavaScript kept anywhere else can't be read here, so it asks.
    for found in re.finditer(r"\bjavascript\b(?:\s+\"(\d+)\")?", code):
        if found.group(1) is None or PAGE_CHANGING.search(strings[int(found.group(1))]):
            return "javascript"
    return None


# A command at the start of a line or after a pipe, ;, &&, $( or a wrapper like sudo, xargs, env: the word itself as an argument doesn't count.
AT_COMMAND = r"(?:^|[;&|(`\n]\s*|\s-\w*c\s+['\"]\s*|\b(?:sudo|xargs|exec|env|time|nohup|command)\s+(?:-\S+\s+|\S+=\S*\s+)*|\s-exec(?:dir)?\s+)"
LASTING = [
    (r"(?:rm|rmdir|unlink|srm|shred|trash)\b", "删除文件"),
    (r"git\s+(?:\S+\s+)*?(?:push|reset\s+--hard|clean\s+-\w*f|branch\s+-D|filter-branch|checkout\s+--\s)", "推送或改写 git"),
    (r"(?:sudo|su|doas)\b", "管理员权限"),
    (r"(?:kill|pkill|killall)\b", "结束进程"),
    (r"(?:launchctl|crontab|systemsetup|networksetup|scutil|pfctl|tccutil|csrutil|spctl|nvram|pmset|diskutil|dd|mkfs\S*|security|profiles)\b", "改这台 Mac 的设置"),
    (r"defaults\s+(?:-\S+\s+)*(?:write|delete|import)\b", "改这台 Mac 的设置"),
    (r"(?:shutdown|reboot|halt)\b", "关机或重启"),
    (r"(?:scp|sftp|rsync|ssh|ftp|mail|sendmail|mutt|gh|lark-cli)\b", "发到别处"),
    (r"(?:osascript|automator|shortcuts\s+run)\b", "操作别的应用"),
]
UPLOADING = re.compile(r"\b(?:curl|wget)\b[^\n|;]*?\s(?:-d\b|--data\S*|-F\b|--form\b|-T\b|--upload-file|-X\s*['\"]?(?:POST|PUT|PATCH|DELETE)|--request\s+['\"]?(?:POST|PUT|PATCH|DELETE)|--json\b)", re.I)


TARGET = r"(?:\"([^\"]+)\"|'([^']+)'|([^\s'\";|&()<>-][^\s'\";|&()<>]*))"


def overwritten_paths(command, cwd=""):
    """Files a command writes over in one go (`>` and `tee` without -a): the ones that already exist get backed up before it runs. Appending loses nothing."""
    text = "\n".join(map(str, command)) if isinstance(command, (list, tuple)) else str(command or "")  # whole: unwrapping loses a closing quote
    names = ["".join(found) for found in re.findall(r"(?<![0-9&>])>\|?\s*" + TARGET, text)]
    names += ["".join(found[1:]) for found in re.findall(r"\btee\s+((?:-\w+\s+)*)" + TARGET, text) if "a" not in found[0]]
    paths = []
    for name in names:
        if name.startswith("/dev/"):
            continue
        path = Path(os.path.expandvars(os.path.expanduser(name)))
        paths.append(str(path if path.is_absolute() else Path(cwd or ".") / path))
    return paths


def lasting_command(command):
    """Why a command that left the sandbox has to wait for the owner: it deletes, sends something off this Mac, or changes the Mac itself. None: they would have said yes, so it just runs."""
    # Codex may hand the command over as its argument list: each argument is read as its own line, so none hides behind a quote.
    text = "\n".join(map(str, command)) if isinstance(command, (list, tuple)) else plain_command(command)
    for pattern, why in LASTING:
        if re.search(AT_COMMAND + pattern, text, re.I):
            return why
    if re.search(r"\bfind\b[^\n|;]*\s-delete\b", text):
        return "删除文件"
    if UPLOADING.search(text):
        return "往网上发送"
    return None
