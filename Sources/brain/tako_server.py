"""Tako beside whichever window it is stuck to. It may fill an input or change a document
when the owner asks; it never sends a message.

What the panel showed goes into the records in Tako's folder (`records.py`); everything else lives in memory. What arrives by itself (a new WeChat message) runs read-only and
cannot touch anything; the owner's own words run with a narrow writable folder and approval cards.
Each conversation has a standing thread of its own (or, switched off, they all share one); a limb when that one can't take it now (turns.Brain).
The app itself is driven through the native side (`/native/next`), the only process with the permissions.

This file holds what they share and starts it all. The work is in chats.py, turns.py, hands.py and lecture.py.
"""
from __future__ import annotations

import argparse
import asyncio
import contextlib
import datetime
import os
import platform
import queue
import secrets
import signal
import shutil
import sys
import threading
import time
from pathlib import Path
from urllib.parse import unquote

import outputs
import records
from ontology import Memory
from entrusted import Entrusted
import feedback as fb
import greetings as greet
import wechat_reader as reader
from agents import Agents, open_door
from chats import Chats, named_chat_app
import office
from office import brain_runtime, end_agents
from codex_runtime import RuntimeErrorCode
from first_run import Setup, codex_on_path, find_codex
from guards import same_chat
from hands import Hands
from ladder import place_command
from lecture import Lectures
from prompts import point_label
from routes import serve
from settings import HAS_WECHAT, HAS_WORKBENCH, INBOX, RUNTIME, WECHAT, WORKING, ZONE, app_version, clock, conversation_key, local_today, output_root, set_output_root

SAME_THING_SECONDS = 600


def merge_into(source, target):
    """Moves everything under source into target. A day's record that is in both is joined, the moved one after; any other name taken keeps both."""
    moved = 0
    if not source.is_dir():
        return 0
    target.mkdir(parents=True, exist_ok=True)
    for item in sorted(source.iterdir()):
        there = target / item.name
        if item.name == ".DS_Store":
            item.unlink(missing_ok=True)
            continue
        if not there.exists():
            shutil.move(str(item), str(there))
            moved += 1
        elif item.is_dir() and there.is_dir():
            moved += merge_into(item, there)
        elif item.suffix == ".md" and item.parent.name == outputs.RECORDS:
            with open(there, "a") as out:
                out.write("\n" + item.read_text().split("\n", 1)[-1])
            item.unlink()
            moved += 1
        else:
            shutil.move(str(item), str(there.with_name(f"{there.stem} 2{there.suffix}")))
            moved += 1
    with contextlib.suppress(OSError):
        source.rmdir()
    return moved
from turns import Job, Turns, shown_rows


class Companion(Chats, Turns, Hands, Lectures, Agents):
    def __init__(self, chat):
        self.loop = None
        self.runtime = brain_runtime(self.on_server_request)
        self.reviving = asyncio.Lock()
        self.setup = Setup(self)
        self.feedback = fb.Feedback(RUNTIME, app_version(), platform.mac_ver()[0])
        self.greetings = greet.Greetings(RUNTIME)
        self.events = []
        self.status = "idle"
        self.error = ""
        self.chat = chat
        self.brains = {}       # conversation key -> its standing thread (turns.Brain); "" the one every conversation shares when per_conversation_threads is off
        self.read_up_to = {}   # chat -> newest message any of the owner's turns was given there: a draft is watched from it
        self.signature = None
        self.generation = 0
        self.watching = True  # peeled off the window, it stops reading altogether
        self.saved = records.load()  # conversations already visited, so returning to one keeps its thread; a week of them outlives a restart
        self.entrusted = Entrusted()
        self.memory = Memory()
        self.keeping = False   # a save of the conversations is on its way
        self.offered = set()   # files the owner dragged or picked, which the panel may preview before they send them
        self.last_header = ""   # the conversation the chat app's own header last settled on (`_confirm`)
        self.looking_since = 0  # a chat app said its chat may be changing, and what it reads hasn't come yet: nothing goes under the chat before
        self.header_seq = ("", 0)  # the newest read the app sent: older ones arriving late are let go
        self.read_early = {}    # a chat app's read that came before the brain heard it was stuck there
        self.wanted_titles = None
        self.header_titles, self.refollowed = None, None
        self.following = False
        self.index, self.index_stamp = None, None
        self.groups, self.groups_stamp = None, None  # groups nobody named, by their members: what WeChat titles them with (`_unnamed_groups`)
        self.sessions, self.sessions_stamp = None, None  # WeChat's own chat list and when each moved (`_sessions`)
        self.refreshing = set()  # which of those two is being read again in the background
        self.window = None     # the window it is stuck to: app, bundle, title, id
        self.active = []       # every job under way, in the order they started
        self.joining = {}      # conversation -> lock: words said there join what is under way one at a time (`Turns._join`)
        self.on_thread = {}    # thread -> the owner's job on it; only these may use tools or ask for anything
        self.news, self.news_serial = [], 0  # what a standing thread didn't see happen (done elsewhere, a hand-over placed), told to each once (`_tell_threads`)
        self.finished = {}     # conversation -> its name and window, for jobs that ended while the owner was elsewhere; gone once seen or tapped
        self.going = None      # the line the owner just tapped: its conversation and window, for the window to show when the goo lands (`_shown_on`)
        self.worked = {}       # another window a job's hands worked -> that job's conversation, which the window then shows (Hands._hands_on)
        self.rings = {}        # window -> the latest ring to draw again when the owner gets there
        self.held = {}         # conversation -> a job's last step, waiting for the owner to get to the window it needs; ("fill", conversation, where) -> a hand-over that finishes by itself
        self.placing = asyncio.Lock()  # hand-overs that need the real pointer go in one at a time
        self.picked_up = {}    # conversation -> turns a waiting step has started by itself since the owner last spoke there
        self.last_spoke = {}   # conversation -> when the owner last spoke there: a word soon after another is the same thing still being explained
        self.said = []         # (message identity, the owner's words), newest last; memory only, across all windows
        self.lecture = None    # the class it is listening to: title, what it heard, notes. Memory only until it ends.
        self.ending_lecture = None  # just stopped, with its last piece of sound still on the way
        self.note_loop = None
        self.ear = None        # the process that turns sound into words, only while listening
        self.ear_lock = asyncio.Lock()
        self.transcribing = set()
        self.named = {}        # where a job may write without asking, per conversation: paths the owner said there or handed over
        self.pending = {}      # cards waiting for the owner: approvals and proposed changes
        self.outbox = queue.Queue()  # commands for the native side
        self.waiting = {}      # native commands waiting for their result
        self.mark = None       # what the session list last said about this chat
        self.shard_signature = None
        self.read_at = 0.0
        self.desk = None       # today's items in a few words, refreshed in the background
        self.drafts = {}       # chat -> the draft the owner last saw there and what they then sent; memory only
        self.learning = asyncio.Lock()
        self.agent_jobs = {}   # id -> a job one of the owner's other agents handed over, kept an hour after it ends so they can hear how
        self.tidied = time.time()  # Tako's own leftovers were cleared at the start; again once a day after a job (outputs.tidy_runtime)
        self.tasks = set()

    def _later(self, work):
        task = asyncio.create_task(work)
        self.tasks.add(task)
        task.add_done_callback(self.tasks.discard)

    # ---- state shown to the panel ----
    def add(self, role, text, events=None, **extra):
        events = self.events if events is None else events
        event = {"id": len(events), "role": role, "text": text, "time": clock(time.time()), "at": time.time(), **extra}
        events.append(event)
        self._keep_soon()
        return event

    def _keep_soon(self):
        """Written a second after the last thing said, from the loop, so a burst of steps is one write."""
        if self.keeping or not self.loop:
            return
        self.keeping = True
        self.loop.call_soon_threadsafe(lambda: self._later(self._keep()))

    async def _keep(self):
        await asyncio.sleep(1)
        self.keeping = False
        await asyncio.to_thread(records.save, self._every_conversation())

    def _every_conversation(self):
        every = {key: (item.get("chat") or {"name": key}, list(item["events"])) for key, item in list(self.saved.items())}
        if self.chat:
            every[self.chat["username"]] = (self.chat, list(self.events))
        return every

    def keep_now(self):
        """On the way out: what was said in the last second is kept too."""
        with contextlib.suppress(Exception):
            records.save(self._every_conversation())

    def snapshot(self, after=0):
        job = self._here()
        status = job.status if job else self.status
        partial = job.partial if job else ""
        # A chat app's chat unconfirmed for long: neither the name nor the words of the chat before. Same gen: if it turns out unchanged, nothing redraws.
        looking = self.unconfirmed()
        busy = status == "thinking" or status == "working"
        chat = self.chat or {}
        window = self.window or {}
        here = []
        kind, name = chat.get("kind", "wechat"), chat.get("name")
        if self.watching and not self.looking_since and not chat.get("unknown") and kind in ("wechat", "dingtalk") and name:
            for item in self.entrusted.pending():
                place = item.get("place") or {}
                app, title = place.get("app", ""), place.get("title", "")
                app_kind = named_chat_app(app)
                app_matches = app_kind == kind if app_kind else app.casefold() in (window.get("app") or "").casefold()
                if (place.get("chat") and same_chat(place["chat"], name) and app_matches
                        and title.casefold() in (window.get("title") or "").casefold()):
                    here.append(item["id"])
        return {"chat": None if looking else self.chat and self.chat["name"], "key": "" if looking else (self.chat or {}).get("username", ""), "status": status, "error": self.error,
                "gen": self.generation, "events": [] if looking else self.events[after:], "looking": looking, "unknown": bool((self.chat or {}).get("unknown")),
                "kind": self.chat.get("kind", "wechat") if self.chat else "", "app": (self.window or {}).get("app", ""),
                "greeting": (self.chat or {}).get("greeting", ""),
                "bundle": (self.window or {}).get("bundle", ""),
                "held_here": here,
                "partial": partial, "steps": job.steps if job else [], "busy": busy,
                "act": job.act if job else "",
                # The list lives while the thing is under way; once its answer is out (status idle, the job still tidying up its record)
                # it is in the answer event, and the same read that says not busy says no list (side.html shows it only while busy).
                "trouble": self._trouble_here(job), "items": shown_rows(job.items) if busy and len(job.items) > 1 else [],
                "others": self._others(),
                "pending": [{k: v for k, v in card.items() if k not in ("future", "job")} for card in list(self.pending.values())],
                "listening": int(time.time() - self.lecture["started"]) if self.lecture else None,
                # The ladder (`ladder.py`): an open question under an answer here, the one invitation the desktop panel may show now
                # (`Ladder.next`; the app's own steps are its own), and whether the owner already connected or declined Reminders and Calendar.
                "ladder": {"asking": self.entrusted.asking((self.chat or {}).get("username")), "next": self.panel_step(), "sources": self.entrusted.ladder.sources}}

    def shared(self, path):
        """A file the panel may show: it came from the owner, or the conversation itself names it."""
        if path in self.offered or os.path.realpath(path).startswith(os.path.realpath(INBOX) + "/"):
            return True
        groups = [self.events, *(s["events"] for s in self.saved.values())]
        return any(path in event["text"] or path in unquote(event["text"]) for group in groups for event in group)

    # ---- the history and Tako's folder ----
    def history(self, find="", days=None):
        """Every ask in the records, newest first, with where a tap goes to take it up again. find: only those that said it; days: only the last ones."""
        self.keep_now()  # what was said this second is in it too
        rows = records.history()
        if days:
            since = (datetime.datetime.now(ZONE).date() - datetime.timedelta(days=int(days) - 1)).isoformat()
            rows = [row for row in rows if row["day"] >= since]
        if find := str(find or "").strip().lower():
            rows = [row for row in rows if find in " ".join([row["where"], row["asked"], *(f["name"] for f in row["files"]), *(s["text"] for s in row["replies"])]).lower()]
        for row in rows:
            key = row["key"]
            if key.startswith("window:"):
                row["window"], row["chat"] = key.rsplit(":", 1)[1], ""
            elif key and key != "desktop":
                row["window"], row["chat"] = WECHAT, row["where"]
        return {"root": str(output_root()), "records": str(records.folder()), "today": local_today(), "rows": rows[:500]}

    def move_folder(self, path, move):
        """The owner chose another folder for Tako. What was in the old one comes along if they say so, so there is only ever one."""
        new, old = Path(path).expanduser(), output_root()
        if new.resolve() == old.resolve():
            return {"ok": True, "root": str(new)}
        try:
            new.mkdir(parents=True, exist_ok=True)
            probe = new / ".tako-probe"
            probe.write_text("")
            probe.unlink()
        except OSError:
            return {"ok": False, "error": "这个文件夹写不进去，换一个吧"}
        if new.resolve().is_relative_to(old.resolve()):
            return {"ok": False, "error": "不能放在原来的文件夹里面，换一个吧"}
        self.keep_now()  # what was said up to now goes where it was
        moved = 0
        if move:
            for part in (outputs.RECORDS, outputs.PRODUCTS):
                moved += merge_into(old / part, new / part)
            with contextlib.suppress(OSError):
                (old / ".DS_Store").unlink(missing_ok=True)
                old.rmdir()
        set_output_root(new)
        outputs.move_old_layout(new)
        return {"ok": True, "root": str(new), "moved": moved}

    # ---- called from HTTP threads ----
    def submit(self, coro):
        return asyncio.run_coroutine_threadsafe(coro, self.loop)

    async def start_over(self):
        """Codex's login or settings just changed under the running server: a new one reads them. `_alive` brings it back."""
        await self.runtime.close()
        await self.warm()

    def ask(self, text, files=(), points=()):
        # On the loop, in the order things arrived: a sentence right after sticking to a window belongs to that window.
        self.submit(self._ask(text, list(files), list(points), asked_at=time.time()))

    async def _ask(self, text, files, points=(), asked_at=None):
        asked_at = time.time() if asked_at is None else asked_at
        await self.settle_chat()
        if self.chat is None and not self.window:
            await self.desktop()
        reply = None if files or points else greet.secret(text)
        if reply:
            self.add("owner", text)
            self.add("tako", reply)
            return
        names = "".join(f"\n[{Path(f).name}](</{f.lstrip('/')}>)" for f in files)
        circled = "　".join(f"{chr(0x2460 + int(p.get('n') or 1) - 1)} {point_label(p)}" for p in points)
        # Said while something here is under way and not yet answered: it joins that (`_join`), and the desktop bubble says so (side.html `asideNews`).
        joined = any(job.events is self.events and not job.stopping and not job.answer for job in self.active)
        where = (self.chat, self.events, self.window)
        here = conversation_key(self.chat, self.events)
        event = self.add("owner", text + names + (f"\n\n{circled}" if circled else ""), **({"joined": True} if joined else {}))
        self.said = [*self.said, (secrets.token_hex(8), text)][-50:]
        self.feedback.heard((self.window or {}).get("app"), text)
        # How many words a thing takes is the measure of Tako: the fewer after the first, the better.
        self.feedback.count("said.more" if time.time() - self.last_spoke.get(here, 0) < SAME_THING_SECONDS else "said.first")
        self.last_spoke[here] = time.time()
        self.held.pop(here, None)  # They said something else: that comes first, and it decides what is still wanted.
        self.picked_up.pop(here, None)
        if not files and not points and (pace_reply := self.entrusted.pace(text, asked_at)):
            self.add("tako", pace_reply, where[1])
            self.keep_now()
            self._later(self.native("entrustedSync", **self.entrusted.native_state(), timeout=30))
            return
        words = self._waiting_fill_note() + text
        # One window, one thing: words, files and rings said while something is under way here are more of it (`_join`), never a thing of their own behind it.
        async with self.joining.setdefault(here, asyncio.Lock()):
            correction_error = await self.memory.correct(text, event, here, where[0] or {})
            if correction_error or correction_error == "":
                # Landed or not, the panel says which: the answer that follows comes from the model and proves neither.
                self.add("note", correction_error or self.memory.receipt, where[1])
            if await self._join(words, files, points, asked_at, where[1]):
                return
            job = Job(*where)
            self.active.append(job)  # from now on, what is said here joins this one
        await self.turn(words, attachments=files, where=where, job=job, points=points, asked_at=asked_at)


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--chat", default="", help="聊天名称的一部分")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--with-app", action="store_true", help="跟着 app 走：标准输入一关就退出")
    args = parser.parse_args()
    RUNTIME.mkdir(parents=True, exist_ok=True)
    # Once, from before the records, and Tako's own leftovers. Never holds the start up: whatever can't be done now is tried next time.
    with contextlib.suppress(Exception):
        records.move_in(RUNTIME)
    with contextlib.suppress(Exception):
        outputs.move_old_layout()
    with contextlib.suppress(Exception):
        outputs.tidy_runtime()
    with contextlib.suppress(OSError):
        WORKING.write_text("[]")

    companion = Companion(None)
    companion.loop = asyncio.get_running_loop()
    if args.with_app:
        leaving = threading.Lock()

        def leave(*_):
            """The app quitting (SIGTERM) or gone (stdin closed): whichever comes first, once."""
            if not leaving.acquire(blocking=False):
                return
            companion.setup.cancel()
            companion.keep_now()
            with contextlib.suppress(Exception):  # A day of trying Tako out, sent as it quits if nothing went out today. Never holds the quit up for long.
                companion.feedback.send_due(timeout=3)
            with contextlib.suppress(Exception):  # An office agent keeps a record of every session, and its process doesn't follow ours out: neither outlives the app.
                end_agents()
                office.clear_records(office.current())
            os._exit(0)

        def leave_with_app():
            sys.stdin.buffer.read()
            leave()
        signal.signal(signal.SIGTERM, leave)
        threading.Thread(target=leave_with_app, daemon=True).start()
    else:
        signal.signal(signal.SIGTERM, lambda *_: (companion.keep_now(), os._exit(0)))
    # Pasted images and whatever else was handed over last time do not outlive the app.
    shutil.rmtree(INBOX, ignore_errors=True)
    with contextlib.suppress(OSError, RuntimeErrorCode):  # Not fatal: the next question tries again and says what is wrong.
        if office.current():
            await companion.runtime.start()
        elif find_codex():
            codex_on_path(find_codex())
            await companion.runtime.start()
    companion._later(companion.warm())
    companion._later(companion.feedback_forever())
    companion._later(companion.threads_forever())
    companion._later(companion.memory_forever())
    if HAS_WORKBENCH:
        companion._later(companion.desk_forever())
    token, agent_token = secrets.token_urlsafe(18), secrets.token_urlsafe(18)
    port = serve(companion, token, args.port, agent_token)
    open_door(port, agent_token)
    # Any agent or script the owner has finds Tako by name (`ladder.place_command`). An isolated run only ever writes in a made-up home inside it.
    if not os.environ.get("TAKO_HOME") or Path.home().resolve().is_relative_to(RUNTIME.resolve()):
        await asyncio.to_thread(place_command)
    print(f"http://127.0.0.1:{port}/?t={token}", flush=True)

    if args.chat and HAS_WECHAT:
        candidates = []
        for chat in reader.find_chats(args.chat):
            rows = await asyncio.to_thread(companion._read, chat, 0, 1)
            if rows:
                candidates.append((rows[-1]["time"], chat))
        if not candidates:
            companion.error = "没有找到可读的对话"
        else:
            # Same-named groups exist; the most recently active one is the live conversation.
            await companion.attach(max(candidates, key=lambda c: c[0])[1])
    await companion.poll_forever()


if __name__ == "__main__":
    asyncio.run(main())
