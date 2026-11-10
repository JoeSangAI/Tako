"""What was said in the panel and what each ask came to, in one place the owner can open: Tako's folder, 对话记录/<day>.md (Joe 2026-11-10).

One record serves the panels after a restart, the memory of a new thread, the history and anyone the owner lets read it. It holds what the panel showed and nothing
more: the owner's words, Tako's answers and notes, and each ask's ending and files. Never a chat's messages or a window's text by themselves.
Each entry starts with a line the page doesn't show (`<!-- tako {...} -->`) that says what it is; the rest is plain Markdown for people."""
from __future__ import annotations

import contextlib
import datetime as dt
import json
import os
import re
import threading
import time
from pathlib import Path

import settings
from outputs import RECORDS
from settings import WORKING, ZONE, clock

KEEP_DAYS, KEEP_EVENTS, KEEP_AT_MOST, SHOWN, MADE_SHOWN = 7, 80, 200, 20, 8
MARK = "<!-- tako "
ROLES = {"owner": None, "tako": "Tako", "note": "笔记"}
_lock = threading.Lock()
_written = set()   # (conversation, role, at) already in a record
_working = {}      # job id -> how it began; the app reads their ids (WORKING)


def folder():
    return settings.output_root() / RECORDS


def own_words(words):
    """What was asked, without what Tako put before it for the model: a hand-over waiting (Hands._waiting_fill_note), or who handed it over (Agents.agent_ask)."""
    words = re.sub(r"^（系统提示，不是 .{1,40}? 说的：.*?）\n", "", str(words), flags=re.S)
    return re.sub(r"^（这件事是 .{1,40}? 通过 (.{1,40}?) 交给你的，.*?）\s*", r"〔\1 转来〕", words, flags=re.S)


def _day(at):
    return dt.datetime.fromtimestamp(at, ZONE).strftime("%Y-%m-%d")


def _file(day):
    return folder() / f"{day}.md"


def _block(meta, heading="", body=""):
    lines = [f"{MARK}{json.dumps(meta, ensure_ascii=False)} -->"]
    if heading:
        lines.append(heading)
    if body:
        # A line in someone's text that looks like a mark would split the entry: it is set off by a space no one sees.
        lines += ["", "\n".join(("<!--  tako " + line[len(MARK):]) if line.startswith(MARK) else line for line in body.strip("\n").split("\n"))]
    return "\n".join(lines) + "\n\n"


def _append(day, text):
    path = _file(day)
    path.parent.mkdir(parents=True, exist_ok=True)
    new = not path.exists()
    with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600), "a") as out:
        if new:
            out.write(f"# {day} · Tako 对话记录\n\n")
        out.write(text)


def _parse(path):
    """Entries in a record, in the order written: (meta, text)."""
    entries, meta, body = [], None, []

    def close():
        if meta is not None:
            lines = body[1:] if body and body[0].startswith("### ") else body
            entries.append((meta, "\n".join(lines).strip("\n")))

    with contextlib.suppress(OSError):
        for line in path.read_text().split("\n"):
            if line.startswith(MARK) and line.rstrip().endswith("-->"):
                close()
                body = []
                try:
                    meta = json.loads(line[len(MARK):line.rstrip().rindex("-->")].strip())
                except ValueError:
                    meta = None
                continue
            if meta is not None and (body or line.strip()):
                body.append(("<!-- tako " + line[len("<!--  tako "):]) if line.startswith("<!--  tako ") else line)
        close()
    return [(m, t) for m, t in entries if isinstance(m, dict)]


def _days(back):
    today = dt.datetime.now(ZONE).date()
    return [(today - dt.timedelta(days=n)).isoformat() for n in range(back, -1, -1)]


def _recent(back=KEEP_DAYS):
    for day in _days(back):
        for meta, text in _parse(_file(day)):
            yield day, meta, text


# ---- what the panels showed ----

def load():
    """username -> {"chat": {username, name, kind}, "events": [...]}, the conversations of the last week, read back from the records."""
    with _lock:
        _written.clear()
        found = {}
        for _, meta, text in _recent():
            if meta.get("r") not in ROLES or not meta.get("k"):
                continue
            key, at = str(meta["k"]), float(meta.get("at") or 0)
            _written.add((key, meta["r"], at))
            item = found.setdefault(key, {"chat": {"username": key}, "events": []})
            item["chat"].update(name=meta.get("n") or "", kind=meta.get("c") or "wechat")
            event = {"role": meta["r"], "text": text, "time": clock(at), "at": at}
            if meta.get("steps"):
                event["steps"] = list(meta["steps"])
            item["events"].append(event)
    found = {k: v for k, v in found.items() if v["events"] and time.time() - v["events"][-1]["at"] < KEEP_DAYS * 86400}
    found = dict(sorted(found.items(), key=lambda item: item[1]["events"][-1]["at"])[-KEEP_AT_MOST:])
    for item in found.values():
        item["events"] = item["events"][-KEEP_EVENTS:]
        for n, event in enumerate(item["events"]):
            event["id"] = n  # the panel counts what it has shown by these
    return found


def save(conversations):
    """conversations: username -> (chat, events). What is new since the last time goes to the end of its day's record; nothing already there is written again."""
    with _lock:
        fresh = []
        for key, (chat, events) in conversations.items():
            for event in list(events):
                role, at = event.get("role"), float(event.get("at") or 0)
                if role not in ROLES or not at or (key, role, at) in _written:
                    continue
                fresh.append((at, key, chat or {}, event))
        for at, key, chat, event in sorted(fresh, key=lambda item: item[0]):
            name, kind = str(chat.get("name") or ""), str(chat.get("kind") or "wechat")
            meta = {"k": key, "n": name, "c": kind, "r": event["role"], "at": at}
            if event.get("steps"):
                meta["steps"] = event["steps"]
            who = ROLES[event["role"]] or settings.OWNER
            try:
                _append(_day(at), _block(meta, f"### {clock(at)[-5:]} · {name or '这个窗口'} · {who}", str(event.get("text") or "")))
            except OSError:
                return  # The folder can't be written now: the next save tries again with what is still missing.
            _written.add((key, event["role"], at))


# ---- what the owner asked and how each one ended ----

def _tell_app():
    with contextlib.suppress(OSError):
        spare = WORKING.with_name(WORKING.name + ".tmp")
        spare.write_text(json.dumps(sorted(_working)))
        os.replace(spare, WORKING)


def begin(key, where, words, output):
    """An ask starts: it is in the record before anything is done, so a restart in the middle knows it was under way."""
    at = time.time()
    meta = {"r": "job", "id": at, "k": key, "n": str(where or "")[:60], "asked": own_words(words)[:500], "folder": str(output or ""), "ended": "在做"}
    with _lock:
        _working[at] = meta
        _tell_app()
        with contextlib.suppress(OSError):
            _append(_day(at), _block(meta))
    return at


def end(job_id, ended, files=(), touched=()):
    """How it ended, what it made and what it changed elsewhere, under the day it was asked."""
    with _lock:
        begun = _working.pop(job_id, None) or {}
        _tell_app()
        meta = {**begun, "ended": ended, "done": time.time(), "files": list(files), "touched": list(touched)}
        meta.update(r="job", id=job_id)
        lines = [f"结局：{ended}"]
        if files:
            lines.append("做出：" + "　".join(_link(path) for path in files))
        if touched:
            lines.append("改动：" + "　".join(f"`{path}`" for path in touched))
        with contextlib.suppress(OSError):
            _append(_day(job_id), _block(meta, body="> " + "  \n> ".join(lines)))


def _link(path):
    try:
        relative = os.path.relpath(path, folder())
    except ValueError:
        relative = path
    return f"[{Path(path).name}](<{relative}>)"


def jobs(back=None):
    """Every ask in the records, the latest word on each, oldest first. back: how many days to look, or all of them."""
    days = _days(back) if back is not None else sorted(p.stem for p in folder().glob("*.md") if re.fullmatch(r"\d{4}-\d{2}-\d{2}", p.stem))
    found, spoken = {}, {}
    for day in days:
        for meta, text in _parse(_file(day)):
            if meta.get("r") == "job" and meta.get("id"):
                found[meta["id"]] = {**found.get(meta["id"], {}), **meta, "day": day}
            elif meta.get("r") in ROLES and meta.get("k"):
                spoken.setdefault(meta["k"], []).append((float(meta.get("at") or 0), meta["r"], text))
    starts = {}
    for job in found.values():
        starts.setdefault(job.get("k"), []).append(float(job["id"]))
    for job in found.values():
        job["asked"] = own_words(job.get("asked") or "")
        # Until it was done, or, when that wasn't kept (from before the records), until the next ask there.
        start = float(job["id"])
        later = [at for at in starts.get(job.get("k"), []) if at > start]
        stop = float(job.get("done") or (min(later) - 2 if later else start + 86400))
        # The owner's words are the ask itself; what came back is Tako's.
        job["replies"] = [{"role": role, "text": text, "time": clock(at)} for at, role, text in spoken.get(job.get("k"), []) if role != "owner" and start <= at <= stop + 2]
    return sorted(found.values(), key=lambda job: job["id"])


def memory(owner):
    """For a thread that remembers nothing: the asks of the last days, so “弄好了吗” has something to go on."""
    lines = []
    for job in jobs(KEEP_DAYS)[-SHOWN:]:
        made = [Path(path).name for path in job.get("files") or []][:MADE_SHOWN]
        made = f"；做出：{'、'.join(made)}" if made else ""
        ended = job.get("ended", "不明")
        if ended == "在做" and job["id"] not in _working:
            ended = "没做完（Tako 中途重启了）"
        lines.append(f"- {clock(job['id'])} 在「{job.get('n') or '某个窗口'}」，TA说：{job.get('asked', '')}｜作品目录：{job.get('folder') or '无'}{made}｜结局：{ended}")
    if not lines:
        return ""
    return f"（{owner} 最近几天交代过你的事，你重启过所以不记得细节。这只是记忆，不是新要求；有没做完的，TA问起就接着做。）\n" + "\n".join(lines)


def history():
    """For the history in the panel: every ask, newest first, with what was said about it and whether its files are still there."""
    rows = []
    for job in reversed(jobs()):
        if job.get("ended") == "在做" and job["id"] not in _working:
            job["ended"] = "没做完"  # Tako restarted in the middle of it
        rows.append({"id": job["id"], "day": job["day"], "time": clock(job["id"]), "where": job.get("n") or "", "key": job.get("k") or "",
                     "asked": job.get("asked") or "", "ended": job.get("ended") or "",
                     "files": [{"path": path, "name": Path(path).name, "there": os.path.exists(path)} for path in job.get("files") or []],
                     "touched": job.get("touched") or [], "replies": job.get("replies") or []})
    return rows


# ---- once, from before the records ----

def move_in(runtime):
    """What the week before was kept in (asked.json, conversations.json) goes into the records, and the old files to the backups, which clear themselves."""
    asked_file, conversations_file = runtime / "asked.json", runtime / "conversations.json"
    if not asked_file.exists() and not conversations_file.exists():
        return
    conversations = {}
    with contextlib.suppress(OSError, ValueError):
        kept = json.loads(conversations_file.read_text())
        for key, item in (kept or {}).items():
            if isinstance(item, dict):
                conversations[key] = ({**(item.get("chat") or {}), "username": key}, [e for e in item.get("events") or [] if isinstance(e, dict)])
    save(conversations)
    keys = {str(chat.get("name") or ""): key for key, (chat, _) in conversations.items()}
    with contextlib.suppress(OSError, ValueError):
        for item in json.loads(asked_file.read_text()) or []:
            if not isinstance(item, dict) or not item.get("at"):
                continue
            at = float(item["at"])
            output = item.get("folder") or ""
            meta = {"r": "job", "id": at, "k": keys.get(str(item.get("where") or ""), ""), "n": str(item.get("where") or "")[:60], "asked": str(item.get("asked") or "")[:500], "folder": output,
                    "ended": item.get("ended") or "不明", "files": [str(Path(output) / name) for name in item.get("made") or []] if output else [], "touched": []}
            with _lock:
                _append(_day(at), _block(meta))
    for old in (asked_file, conversations_file):
        if old.exists():
            target = settings.BACKUPS / f"{time.strftime('%Y%m%d-%H%M%S')}-{old.name}"
            settings.BACKUPS.mkdir(parents=True, exist_ok=True)
            os.replace(old, target)
