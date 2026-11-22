"""The ladder of proactivity: one mechanism underneath (the promises of `entrusted.py` and their three
moments: a time, a person, a place), its sources lit up by what the owner already has. No settings page; the next step only.

What may come before the owner on Tako's own initiative is decided here and nowhere else (`Ladder.next`): one
thing at a time, in one order. First what Tako can't work without (a model, then the two switches), each until it is done. Then,
once in a lifetime, the first try: the one thing to know (double click it and say something) with something to say. Then, only
after Tako has helped once, the invitations: the speaking key, sticking to a window, the owner's own to-dos and calendar. At most
one a day, each offered once, gone by itself when not taken up; never while a question under an answer is open. The question under
an answer (`entrust ask`) is part of the answer to a turn the owner started, not an invitation.

1. The first try, once in a lifetime: one line that gets the owner to entrust something and see it come back at the right moment.
2. Asking, at the end of a turn the owner was already in, whether to keep a promise said there. Only numbers are kept here.
3. The system's Reminders and Calendar, read by the app only after the owner's own 好. Their words stay in this process's memory:
   compared here, never logged, recorded or sent to a model. A calendar is only a moment, never a source.
4. The owner's other agents find Tako by its command, `tako` (`place_command`), put where command-line tools are looked for when
   that folder is already there. Nothing is asked and nothing is written into any agent's own folder.

No model is called from here. `ladder.json` holds stages, counts, days and flags, never anyone's words.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import time
from pathlib import Path

from settings import HERE, RUNTIME

FIRST_CHAT = "双击我，说：见到某某，提醒我某事。"
FIRST_TIME = "双击我，说：一分钟后提醒我喝水。"
FIRST_OPEN = "记下了。去打开和TA的聊天看看。"
FIRST_HELD = "你交代的事我拿着，点一下泡泡就能看到。"
FIRST_SECONDS = 86400          # the first try not taken up within a day is let go, never asked again
ASK_QUIET_AFTER = 3            # unanswered asks in a row ...
ASK_QUIET_SECONDS = 7 * 86400  # ... and it doesn't ask for a week
MEETING_LEAD = 600             # a line ten minutes before a meeting, if something is held for someone in it
# The invitations, in their order, after Tako has helped once. What the owner gets, never what it is called.
INVITATIONS = (("speak", "下次按右 ⌥，直接跟我说。"),
               ("summon", "把我拖到窗口上，我帮你看着它。"),
               ("sources", "你自己记的待办和日程里写到谁，见到TA、开会前我也提你一句。"),
               ("memory", "让我看看你在其他助手里聊过的事、日历和提醒事项？以后不用再说一遍。需要的内容会交给你接的模型。"))
MARK = "# installed-by: tako-app"


def _day(now):
    return time.strftime("%Y-%m-%d", time.localtime(now))


def place_command(home=None, python=None):
    """`tako` where command-line tools are looked for (`~/.local/bin`), so any agent or script the owner has finds Tako by name and
    learns the rest from `tako --help`. Only when that folder is already there (someone with command-line tools); never over a `tako`
    that isn't Tako's own (known by its mark); refreshed when the app has moved. Nothing is asked: it reads nothing and sends nothing."""
    home = Path(home or Path.home())
    folder = home / ".local/bin"
    target = folder / "tako"
    script = f'#!/bin/sh\n{MARK}\nexec "{python or sys.executable}" "{HERE / "tako_cli.py"}" "$@"\n'
    try:
        if not folder.is_dir() or target.is_symlink():
            return False
        if target.exists():
            old = target.read_text(errors="replace")
            if MARK not in old:
                return False
            if old == script:
                return True
        temporary = folder / ".tako.tmp"
        temporary.write_text(script)
        temporary.chmod(0o755)
        temporary.replace(target)
        return True
    except OSError:
        return False


class Ladder:
    def __init__(self, path=None):
        self.path = Path(path or RUNTIME / "ladder.json")
        try:
            self.state = json.loads(self.path.read_text())
        except (OSError, ValueError):
            self.state = {}
        if not isinstance(self.state, dict):
            self.state = {}

    def _save(self):
        temporary = self.path.with_suffix(".tmp")
        try:
            with os.fdopen(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as out:
                json.dump(self.state, out)
            temporary.replace(self.path)
        except OSError:
            pass

    # ---- the one next step ----
    def next(self, *, ready, trusted, capture, chat_apps=False, learned=(), used=False, asking=False, now=None, take=False):
        """The one thing that may come before the owner now, or {}. `take`: the app is about to say it (a bubble line), so it counts
        as offered. Setup steps stay until done; the first try once; then, after Tako has helped, at most one invitation a day."""
        now = time.time() if now is None else now
        if not ready:
            return {"id": "model"}
        if not trusted:
            return {"id": "accessibility"}
        if not capture:
            return {"id": "screen"}
        first = self._first()
        if used and (not self.state.get("helped") or first["stage"] == "new"):
            self.state.setdefault("helped", now)   # an owner from before this run: already helped, never a newcomer again
            if first["stage"] == "new":
                first["stage"] = "done"
            self._save()
        if first["stage"] == "asked" and now - first.get("at", now) > FIRST_SECONDS:
            first["stage"] = "done"
            self._save()
        if first["stage"] == "new":
            if not take:
                return {"id": "first"}
            first.update(stage="asked", at=now, way="chat" if chat_apps else "time")
            self._save()
            return {"id": "first", "say": FIRST_CHAT if chat_apps else FIRST_TIME}
        if not self.state.get("helped") or asking:
            return {}
        today = _day(now)
        shown = self.state.setdefault("shown", {})
        if shown.get("memory") == today and not self.state.get("memory_access"):
            return {"id": "memory", "say": INVITATIONS[3][1]}
        if shown.get("sources") == today and self.sources == "":
            return {"id": "sources", "say": INVITATIONS[2][1]}   # seen today and not answered: it stays for today, then it is gone
        if _day(first.get("at", 0)) == today or today in shown.values():
            return {}
        for name, line in INVITATIONS:
            if name in shown or name in learned or (name == "sources" and (self.sources or not chat_apps)) or (name == "memory" and self.state.get("memory_access")):
                continue
            if take and name not in ("sources", "memory"):
                shown[name] = today
                self._save()
            return {"id": name, "say": line}
        return {}

    def seen(self, name, now=None):
        """The panel showed an invitation: that is its day."""
        shown = self.state.setdefault("shown", {})
        if name in ("sources", "memory") and name not in shown:
            shown[name] = _day(time.time() if now is None else now)
            self._save()

    def helped(self, now=None):
        """Tako answered the owner or brought a promise back: from now on it may invite."""
        if not self.state.get("helped"):
            self.state["helped"] = time.time() if now is None else now
            self._save()

    # ---- 1. the first try ----
    def _first(self):
        return self.state.setdefault("first", {"stage": "new"})

    def first_kept(self, item, now=None):
        """Say the first try's next step, or explain the holding bubble on first use."""
        now = time.time() if now is None else now
        first = self._first()
        if item.get("source") != "owner" or item.get("state") != "held":
            return ""
        if first["stage"] == "asked" and now - first.get("at", now) <= FIRST_SECONDS:
            first.update(stage="waiting", id=item["id"])
            self._save()
            return FIRST_OPEN if (item.get("place") or {}).get("chat") and item.get("due") is None else ""
        if first["stage"] == "asked":
            # The first try was not taken up in time: let it go quietly, no lesson afterwards either.
            first["stage"] = "done"
            self.state["holding_explained"] = True
            self._save()
            return ""
        if self.state.get("holding_explained"):
            return ""
        self.state["holding_explained"] = True
        self._save()
        return FIRST_HELD

    def first_offered(self, identity):
        self.helped()
        first = self._first()
        if first["stage"] == "waiting" and first.get("id") == identity:
            first["stage"] = "done"
            self._save()
            return True
        return False

    # ---- 2. asking whether to keep a promise ----
    def _asking(self):
        return self.state.setdefault("asking", {"unanswered": 0, "last": 0.0, "stopped": False})

    def may_ask(self, now=None):
        now = time.time() if now is None else now
        asking = self._asking()
        if asking["stopped"]:
            return False
        return not (asking["unanswered"] >= ASK_QUIET_AFTER and now - asking["last"] < ASK_QUIET_SECONDS)

    def unanswered(self, now=None):
        asking = self._asking()
        asking.update(unanswered=int(asking["unanswered"]) + 1, last=time.time() if now is None else now)
        self._save()

    def answered(self):
        asking = self._asking()
        if asking["unanswered"]:
            asking["unanswered"] = 0
            self._save()

    def stop_asking(self):
        self._asking()["stopped"] = True
        self._save()

    def owner_entrusted(self):
        """The owner entrusting something of their own again ends a 别问了."""
        asking = self._asking()
        if asking["stopped"]:
            asking["stopped"] = False
            self._save()

    # ---- 3. Reminders and Calendar: the owner's 好, then memory only ----
    @property
    def sources(self):
        return self.state.get("sources", "")

    def set_sources(self, access):
        if access in ("connected", "declined"):
            self.state["sources"] = access
            self._save()

    def dismissed(self):
        return set(self.state.get("dismissed") or [])

    def dismiss(self, opaque):
        self.state["dismissed"] = sorted(self.dismissed() | {opaque})[-500:]
        self._save()


# ---- 3, the comparing: the app hands over what it read; it stays here ----
def opaque(identity):
    return hashlib.sha256(str(identity).encode()).hexdigest()[:16]


def _norm(text):
    return re.sub(r"\s+", "", str(text or "")).lower()


def names_in(text, names):
    """Chat names that appear in a reminder's or a meeting's words: the longest wins where one name sits inside another
    (小林 inside 小林妈妈 is 小林妈妈). Two characters at least; nothing about meaning, no model."""
    words = _norm(text)
    found = sorted({n for n in names if len(_norm(n)) >= 2 and _norm(n) in words}, key=lambda n: -len(_norm(n)))
    kept = []
    for name in found:
        if not any(_norm(name) in _norm(longer) for longer in kept):
            kept.append(name)
    return kept


def reminder_items(reminders, names, dismissed, held):
    """The owner's own reminders that name someone they chat with: a line when that chat opens. A reminder Tako already holds
    the same words for is not said twice; one ticked off in Reminders is simply no longer given, and so is gone."""
    items = {}
    held_words = {(_norm((i.get("place") or {}).get("chat")), _norm(i.get("text"))) for i in held}
    for reminder in reminders or []:
        if not isinstance(reminder, dict) or reminder.get("completed"):
            continue
        identity = opaque(reminder.get("id") or reminder.get("title"))
        if identity in dismissed:
            continue
        title = " ".join(str(reminder.get("title") or "").split())
        found = names_in(f"{title} {reminder.get('notes') or ''}", names)
        if not title or not found:
            continue
        name = found[0]
        if any(_norm(name) == chat and text and (text in _norm(title) or _norm(title) in text) for chat, text in held_words):
            continue
        items["r:" + identity] = {"id": "r:" + identity, "from": "reminders", "state": "held", "text": f"提醒事项里写着：{title}",
                                  "place": {"chat": name}, "due": None, "created": time.time(), "held_since": time.time(), "k": "desktop"}
    return items


def meeting_line(events, held, now, said):
    """Ten minutes before a meeting, if something held concerns a person in it (its attendees or its title), one line about that.
    Nothing held for anyone there: nothing at all. The name said is the one in what is held, never the invitation's words."""
    for event in sorted((e for e in events or [] if isinstance(e, dict)), key=lambda e: float(e.get("start") or 0)):
        start = float(event.get("start") or 0)
        key = opaque(f"{event.get('id')}|{start}")
        if key in said or not (start - MEETING_LEAD <= now < start):
            continue
        words = " ".join([str(event.get("title") or ""), *map(str, event.get("attendees") or [])])
        for item in held:
            chat = (item.get("place") or {}).get("chat")
            if chat and names_in(words, [chat]):
                return key, item, f"等下要见{chat}。{item['text']}"
    return None


def next_meeting_moment(events, now):
    """When to look again: the next meeting's ten-minutes-before, for the app's one timer."""
    upcoming = [float(e.get("start") or 0) - MEETING_LEAD for e in events or [] if isinstance(e, dict) and float(e.get("start") or 0) > now]
    later = [t for t in upcoming if t > now]
    return min(later) if later else None
