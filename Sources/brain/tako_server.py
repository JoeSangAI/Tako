"""Tako beside whichever window it is stuck to. It may fill an input or change a document
when the owner asks; it never sends a message.

What the panel showed is kept on this Mac for a week (`conversations.py`); everything else lives in memory. What arrives by itself (a new WeChat message) runs read-only and
cannot touch anything; the owner's own words run with a narrow writable folder and approval cards.
Every window shares one Codex thread: one brain, a limb on each window.
The app itself is driven through the native side (`/native/next`), the only process with the permissions.

This file holds what they share and starts it all. The work is in chats.py, turns.py, hands.py and lecture.py.
"""
from __future__ import annotations

import argparse
import asyncio
import contextlib
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

import conversations
import feedback as fb
import greetings as greet
import wechat_reader as reader
from agents import Agents, open_door
from chats import Chats
import office
from office import brain_runtime, end_agents
from codex_runtime import RuntimeErrorCode
from first_run import Setup, codex_on_path, find_codex
from hands import Hands
from lecture import Lectures
from prompts import point_label
from routes import serve
from settings import HAS_WECHAT, HAS_WORKBENCH, INBOX, RUNTIME, app_version, clock, conversation_key

SAME_THING_SECONDS = 600
from turns import Turns


class Companion(Chats, Turns, Hands, Lectures, Agents):
    def __init__(self, chat):
        self.loop = None
        self.runtime = brain_runtime(self.on_server_request)
        self.reviving = asyncio.Lock()
        self.setup = Setup(self)
        self.turns = asyncio.Lock()
        self.feedback = fb.Feedback(RUNTIME, app_version(), platform.mac_ver()[0])
        self.greetings = greet.Greetings(RUNTIME)
        self.events = []
        self.status = "idle"
        self.error = ""
        self.chat = chat
        self.thread = None
        self.read_up_to = {}   # chat -> newest message the brain's thread has been given
        self.signature = None
        self.generation = 0
        self.watching = True  # peeled off the window, it stops reading altogether
        self.saved = conversations.load()  # conversations already visited, so returning to one keeps its thread; a week of them outlives a restart
        self.brain_lost = bool(self.saved)  # the thread went away (or the app restarted) with things said: the next window with something said tells it (`_brain`)
        self.keeping = False   # a save of the conversations is on its way
        self.offered = set()   # files the owner dragged or picked, which the panel may preview before they send them
        self.last_header = ""
        self.wanted_titles = None
        self.following = False
        self.index, self.index_stamp = None, None
        self.groups, self.groups_stamp = [], None  # groups nobody named, by their members: what WeChat titles them with (`_unnamed_groups`)
        self.window = None     # the window it is stuck to: app, bundle, title, id
        self.active = []       # every job under way, in the order they started
        self.on_thread = {}    # thread -> the owner's job on it; only these may use tools or ask for anything
        self.settling = False  # the brain's thread is being got ready or summarized: wait for it rather than go round it
        self.limb_news = []    # what limbs did while the brain was busy, for its next turn
        self.finished = {}     # conversation -> its name and window, for jobs that ended while the owner was elsewhere; gone once seen or tapped
        self.going = None      # the line the owner just tapped: its conversation and window, for the window to show when the goo lands (`_shown_on`)
        self.worked = {}       # another window a job's hands worked -> that job's conversation, which the window then shows (Hands._hands_on)
        self.rings = {}        # window -> the latest ring to draw again when the owner gets there
        self.held = {}         # conversation -> a job's last step, waiting for the owner to get to the window it needs; ("fill", conversation) -> a hand-over that finishes by itself
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
        self.told = {}         # what the brain thread has already been given, so it isn't sent again
        self.drafts = {}       # chat -> the draft the owner last saw there and what they then sent; memory only
        self.learning = asyncio.Lock()
        self.compacted = (None, 0)  # thread, and its size when it was last summarized
        self.pictures = 0      # bytes of images on the brain thread since it was last summarized
        self.agent_jobs = {}   # id -> a job one of the owner's other agents handed over, kept an hour after it ends so they can hear how
        self.tasks = set()

    def _later(self, work):
        task = asyncio.create_task(work)
        self.tasks.add(task)
        task.add_done_callback(self.tasks.discard)

    # ---- state shown to the panel ----
    def add(self, role, text, events=None, **extra):
        events = self.events if events is None else events
        events.append({"id": len(events), "role": role, "text": text, "time": clock(time.time()), "at": time.time(), **extra})
        self._keep_soon()

    def _keep_soon(self):
        """Written a second after the last thing said, from the loop, so a burst of steps is one write."""
        if self.keeping or not self.loop:
            return
        self.keeping = True
        self.loop.call_soon_threadsafe(lambda: self._later(self._keep()))

    async def _keep(self):
        await asyncio.sleep(1)
        self.keeping = False
        await asyncio.to_thread(conversations.save, self._every_conversation())

    def _every_conversation(self):
        every = {key: (item.get("chat") or {"name": key}, list(item["events"])) for key, item in list(self.saved.items())}
        if self.chat:
            every[self.chat["username"]] = (self.chat, list(self.events))
        return every

    def keep_now(self):
        """On the way out: what was said in the last second is kept too."""
        with contextlib.suppress(Exception):
            conversations.save(self._every_conversation())

    def snapshot(self, after=0):
        job = self._here()
        status = job.status if job else self.status
        partial = job.partial if job else ""
        return {"chat": self.chat and self.chat["name"], "status": status, "error": self.error,
                "gen": self.generation, "events": self.events[after:],
                "kind": self.chat.get("kind", "wechat") if self.chat else "", "app": (self.window or {}).get("app", ""),
                "greeting": (self.chat or {}).get("greeting", ""),
                "bundle": (self.window or {}).get("bundle", ""),
                "partial": partial, "steps": job.steps if job else [], "busy": status == "thinking" or status == "working",
                "act": job.act if job else "",
                "trouble": self._trouble_here(job), "queued": any(other.waiting for other in self.active if other.events is self.events),
                "others": self._others(),
                "pending": [{k: v for k, v in card.items() if k not in ("future", "job")} for card in list(self.pending.values())],
                "listening": int(time.time() - self.lecture["started"]) if self.lecture else None}

    def shared(self, path):
        """A file the panel may show: it came from the owner, or the conversation itself names it."""
        if path in self.offered or os.path.realpath(path).startswith(os.path.realpath(INBOX) + "/"):
            return True
        groups = [self.events, *(s["events"] for s in self.saved.values())]
        return any(path in event["text"] or path in unquote(event["text"]) for group in groups for event in group)

    # ---- called from HTTP threads ----
    def submit(self, coro):
        return asyncio.run_coroutine_threadsafe(coro, self.loop)

    async def start_over(self):
        """Codex's login or settings just changed under the running server: a new one reads them. `_alive` brings it back."""
        await self.runtime.close()
        await self.warm()

    def ask(self, text, files=(), points=()):
        # On the loop, in the order things arrived: a sentence right after sticking to a window belongs to that window.
        self.submit(self._ask(text, list(files), list(points)))

    async def _ask(self, text, files, points=()):
        await self.settle_chat()
        reply = None if files or points else greet.secret(text)
        if reply:
            self.add("owner", text)
            self.add("tako", reply)
            return
        names = "".join(f"\n[{Path(f).name}](</{f.lstrip('/')}>)" for f in files)
        circled = "　".join(f"{chr(0x2460 + int(p.get('n') or 1) - 1)} {point_label(p)}" for p in points)
        self.add("owner", text + names + (f"\n\n{circled}" if circled else ""))
        self.said = [*self.said, (secrets.token_hex(8), text)][-50:]
        self.feedback.heard((self.window or {}).get("app"), text)
        here = conversation_key(self.chat, self.events)
        # How many words a thing takes is the measure of Tako: the fewer after the first, the better.
        self.feedback.count("said.more" if time.time() - self.last_spoke.get(here, 0) < SAME_THING_SECONDS else "said.first")
        self.last_spoke[here] = time.time()
        self.held.pop(here, None)  # They said something else: that comes first, and it decides what is still wanted.
        self.picked_up.pop(here, None)
        words = self._waiting_fill_note() + text
        if files or points or not await self._steer(words):
            await self.turn(words, attachments=files, where=(self.chat, self.events, self.window), points=points)


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--chat", default="", help="聊天名称的一部分")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--with-app", action="store_true", help="跟着 app 走：标准输入一关就退出")
    args = parser.parse_args()
    RUNTIME.mkdir(parents=True, exist_ok=True)

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
    if HAS_WORKBENCH:
        companion._later(companion.desk_forever())
    token, agent_token = secrets.token_urlsafe(18), secrets.token_urlsafe(18)
    port = serve(companion, token, args.port, agent_token)
    open_door(port, agent_token)
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
