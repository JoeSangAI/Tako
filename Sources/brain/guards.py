"""The rules that hold whatever a model or a window says. Plain functions with no state, so each can be tested on its own."""
from __future__ import annotations

import hashlib
import re
import unicodedata

from settings import OWNER

# Apps with a real scripting interface, by bundle id. Scripts run inside the app, nowhere else.
SCRIPTABLE = {"com.microsoft.Powerpoint": "Microsoft PowerPoint", "com.microsoft.Excel": "Microsoft Excel",
              "com.microsoft.Word": "Microsoft Word", "com.apple.iWork.Keynote": "Keynote",
              "com.apple.iWork.Numbers": "Numbers", "com.apple.iWork.Pages": "Pages", "com.apple.mail": "Mail",
              "com.apple.Safari": "Safari", "com.google.Chrome": "Google Chrome", "com.apple.Notes": "Notes",
              "com.apple.iCal": "Calendar", "com.apple.reminders": "Reminders"}
# A member count ends the title; anything after it is an icon the OCR took for a letter.
COUNT_SUFFIX = re.compile(r"\s*[(（]\s*\d+\s*[)）].*$")


def normalized(name):
    """What is left of a chat name after OCR: no emoji, spaces or member count."""
    text = COUNT_SUFFIX.sub("", unicodedata.normalize("NFKC", name))
    return "".join(ch for ch in text if ch.isalnum()).lower()


def addressed(rows, names):
    """A group is only worth judging when someone in it speaks to the owner."""
    return any(not row["is_me"] and any(name.lower() in str(row["text"]).lower() for name in names if name) for row in rows)


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


def knowledge_query(answer):
    """The one line a tool-less reader writes to ask for a lookup: only ever a search term, never a command."""
    found = re.search(r"^\s*【查】(.+)$", answer or "", re.M)
    return " ".join(found.group(1).split())[:80] if found else None


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


def risky_script(script):
    """What a script would do that can't be taken back, or that runs code inside a web page."""
    found = re.search(r"\b(delete|erase|remove|empty|close|quit|javascript)\b", script_code(script)[0])
    return found.group(1) if found else None
