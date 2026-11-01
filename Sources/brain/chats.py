"""Which conversation it is on and what arrives there: sticking to a window, following WeChat, deciding whether to speak up, and learning from what the owner sends."""
from __future__ import annotations

import asyncio
import contextlib
import difflib
import json
import os
import re
import time
from pathlib import Path

import greetings as greet
import wechat_reader as reader
from guards import addressed, last_draft, learned_notes, normalized
from prompts import LEARN_PROMPT, OPENED, SILENT
from settings import (CONTEXT_MESSAGES, FULL_READ_SECONDS, GROUP_CALLS, HAS_WECHAT, MAX_MESSAGE_CHARS, OPENED_DWELL_SECONDS, OWNER, POLL_SECONDS, SENT_SETTLE_SECONDS, VOICE, WECHAT,
                      clock, note_metric, voice_notes)


def render(rows):
    return "\n".join(f"[{clock(m['time'])}] {m['who']}: {m['text'][:MAX_MESSAGE_CHARS]}" for m in rows)


class Chats:
    # ---- WeChat ----
    def _db_signature(self, shard):
        root, _ = reader.account()
        path = root / "db_storage" / shard
        wal = Path(str(path) + "-wal")
        parts = [os.stat(path)]
        if wal.is_file():
            parts.append(os.stat(wal))
        return tuple((p.st_size, p.st_mtime_ns) for p in parts)

    def _chat_changed(self, username):
        """Reading the message shard means decrypting all of it, so first ask the small session list whether this chat moved."""
        changed = False
        session = self._db_signature(reader.SESSION)
        if session != self.signature:
            self.signature = session
            mark = reader.session_mark(username)
            if mark != self.mark:
                self.mark, changed = mark, True
        shard = self._db_signature(reader.SHARD)
        if shard != self.shard_signature and time.time() - self.read_at >= FULL_READ_SECONDS:
            changed = True
        if changed:
            self.shard_signature, self.read_at = shard, time.time()
        return changed

    def _read(self, chat, after_id, limit):
        con, stats = reader.open_shard()
        try:
            if stats.get("bad_mac"):
                raise RuntimeError("wal_mac_mismatch")
            return reader.read_messages(con, chat["username"], after_id, limit)
        finally:
            con.close()

    # ---- which conversation is open ----
    def _candidates(self, titles):
        """Usernames whose name matches what was read off the window header."""
        if self.index is None:
            names = json.loads((reader.WXEXPORT / "work/namemap.json").read_text())["names"]
            self.index = {}
            for username, name in names.items():
                if isinstance(name, str) and (key := normalized(name)):
                    self.index.setdefault(key, []).append({"username": username, "name": name})
        for title in titles:
            key = normalized(title)
            # One letter or digit is OCR noise; one Chinese character can be a whole name, like the group "家", and only ever matches exactly.
            if len(key) < 2 and not "一" <= key <= "鿿":
                continue
            if key in self.index:
                return key, self.index[key]
            near = [k for k in self.index if abs(len(k) - len(key)) <= 2 and (k[0] == key[0] or k[-1] == key[-1])]
            match = difflib.get_close_matches(key, near, n=1, cutoff=0.82)
            if match:
                return key, self.index[match[0]]
        return None, []

    def _latest(self, chats):
        """Same-named chats exist; the one with the newest message is the live one. Skips chats with no table."""
        con, _ = reader.open_shard()
        try:
            best = None
            for chat in chats:
                rows = reader.read_messages(con, chat["username"], 0, 1)
                if rows and (best is None or rows[-1]["time"] > best[0]):
                    best = (rows[-1]["time"], chat)
            return best[1] if best else None
        finally:
            con.close()

    async def follow_header(self, titles):
        """The newest title always wins; reads take seconds and the owner may click faster than that."""
        self.wanted_titles = titles
        if self.following:
            return
        self.following = True
        try:
            while self.wanted_titles is not None:
                titles, self.wanted_titles = self.wanted_titles, None
                key, chats = await asyncio.to_thread(self._candidates, titles)
                if not chats or key == self.last_header:
                    continue
                chat = chats[0] if len(chats) == 1 else await asyncio.to_thread(self._latest, chats)
                # A newer title arrived while this one was resolving: skip straight to it.
                if self.wanted_titles is not None:
                    continue
                self.last_header = key
                # No readable history still means the owner is looking at this chat: say so instead of showing the old one.
                chat = chat or chats[0]
                if not self.chat or chat["username"] != self.chat["username"]:
                    await self.attach(chat)
        finally:
            self.following = False

    async def stick(self, window):
        """Stuck onto a window. WeChat picks its conversation from the title; any other window is its own session."""
        self.window = window
        if window.get("bundle") == WECHAT and HAS_WECHAT:
            if self.chat and self.chat.get("kind") == "window":
                self._park()
                self.chat, self.events = None, []
                self.last_header = ""
                self.generation += 1
            return
        key = f"window:{window.get('bundle')}:{window.get('id')}"
        name = window.get("title") or window.get("app") or "这个窗口"
        if self.chat and self.chat["username"] == key:
            self.chat["name"] = name
            return
        chat = {"username": key, "name": name, "kind": "window"}
        app = window.get("app") or ""
        if not (self.saved.get(key) or {}).get("events"):
            chat["greeting"] = self.greetings.pick(app)
            if self.greetings.wants_more(app):
                self._later(self._more_greetings(app))
        await self.attach(chat)

    async def _more_greetings(self, app):
        """Only the app's name goes out, on a throwaway thread with no tools. If it comes back in time, a stock line on an empty panel gives way."""
        try:
            self.greetings.take(app, await self._reader(greet.PROMPT, greet.ask_for(app), effort="low", kind="greeting"))
        except Exception:
            return  # No model right now: the stock lines will do, and it asks again later.
        chat = self.chat or {}
        if (self.window or {}).get("app") == app and not self.events and chat.get("greeting") in greet.PLAIN:
            chat["greeting"] = self.greetings.next(app) or chat["greeting"]

    def _park(self):
        if self.chat:
            self.saved[self.chat["username"]] = {"last_id": self.last_id, "unsent": self.unsent, "events": self.events, "history": self.history}

    async def attach(self, chat, replay=0):
        """Bind to one conversation; its recent messages become context, not news."""
        self._park()
        self.generation += 1
        generation = self.generation
        back = self.saved.get(chat["username"])
        self.chat, self.signature, self.mark = chat, None, None
        self.events = back["events"] if back else []
        self.last_id = back["last_id"] if back else 0
        self.unsent = back["unsent"] if back else []
        self.history = back["history"] if back else []
        self.finished.pop(chat["username"], None)  # They're back: it's in front of them.
        self.status, self.error = "reading", ""  # A running job keeps its own status and stop button, in its own conversation.
        if chat.get("kind") == "window":
            self.status = "idle"
            return
        reading_done = lambda: "idle" if self.status == "reading" else self.status
        if back:
            try:
                rows = await asyncio.to_thread(self._read, chat, self.last_id, 200)
            except Exception:
                rows = None
            if generation != self.generation:
                return
            if rows:
                self.unsent = (self.unsent + rows)[-CONTEXT_MESSAGES:]
                self.history = (self.history + rows)[-CONTEXT_MESSAGES:]
                self.last_id = rows[-1]["id"]
            self.polled_at = time.time()
            self.status = reading_done()
            self._later(self._opened(chat, generation))
            return
        try:
            rows = await asyncio.to_thread(self._read, chat, 0, CONTEXT_MESSAGES)
        except Exception:
            rows, self.last_header = None, ""  # WeChat was mid-write; seeing the same title again tries again
        if generation != self.generation:
            return
        if rows is None:
            # No baseline yet, so whatever is read later is history, not news.
            self.missed = True
            self.status, self.error = reading_done(), "这段对话不在当前可读的消息库里"
            return
        cut = len(rows) - replay if replay else len(rows)
        self.unsent, self.last_id = rows[:cut], rows[cut - 1]["id"] if cut > 0 else 0
        self.history = rows[:cut]
        self.polled_at = time.time()
        self.status = reading_done()
        if replay:
            await self._take(rows[cut:])
        else:
            self._later(self._opened(chat, generation))

    async def poll_forever(self):
        while True:
            await asyncio.sleep(POLL_SECONDS)
            self._settle_drafts()
            if not self.chat or self.chat.get("kind") == "window":
                continue
            if not self.watching:
                self.missed = True
                continue
            try:
                changed = await asyncio.to_thread(self._chat_changed, self.chat["username"])
                self.polled_at = time.time()
                if not changed:
                    continue
                generation = self.generation
                rows = await asyncio.to_thread(self._read, self.chat, self.last_id, 200)
                if rows and generation == self.generation:
                    if self.missed:
                        # What came in while it was off the window is context, not news.
                        self.last_id = rows[-1]["id"]
                        self.unsent = (self.unsent + rows)[-CONTEXT_MESSAGES:]
                        self.history = (self.history + rows)[-CONTEXT_MESSAGES:]
                    else:
                        await self._take(rows)
                self.missed = False
                self.error = ""
            except Exception as exc:
                self.shard_signature = None  # The session list won't say it again; the next full read picks these up.
                self.error = f"读取失败：{type(exc).__name__}"

    def _worth_judging(self, rows):
        if rows[-1]["is_me"] or all(row["is_me"] for row in rows):
            return False  # They have already answered.
        if not str(self.chat["username"]).endswith("@chatroom"):
            return True
        return addressed(rows, (*GROUP_CALLS, reader.my_name()))

    async def _take(self, rows):
        self.last_id = rows[-1]["id"]
        self.unsent.extend(rows)
        self.history = (self.history + rows)[-CONTEXT_MESSAGES:]
        self._saw_sent(rows)
        for row in rows:
            if not row["is_me"]:
                self.add("wechat", f"{row['who']}: {row['text'][:200]}")
        if self._worth_judging(rows):
            # A turn the owner started may hold this up, and they may have moved on by then: it judges the chat the message came to.
            await self.turn("这段对话有新消息，判断是否需要开口。", origin="message", where=(self.chat, self.events, self.window), history=self.history)

    # ---- learning from what the owner actually sends ----
    def _remember_draft(self, draft, chat, filled=False):
        if draft and chat and chat.get("kind") != "window":
            self.drafts[chat["username"]] = {"text": draft, "time": time.time(), "filled": filled, "sent": [], "last": 0.0}

    def _saw_sent(self, rows):
        draft = self.drafts.get(self.chat["username"]) if self.chat else None
        if not draft:
            return
        for row in rows:
            if row["is_me"] and row["time"] >= draft["time"] - 5 and not re.fullmatch(r"\[[^\]]{1,10}\]", str(row["text"]).strip()):
                draft["sent"].append(str(row["text"]))
                draft["last"] = time.time()

    def _settle_drafts(self):
        for username, draft in list(self.drafts.items()):
            if draft["sent"] and time.time() - draft["last"] >= SENT_SETTLE_SECONDS:
                del self.drafts[username]
                sent = "\n".join(draft["sent"])
                ratio = difflib.SequenceMatcher(None, draft["text"], sent).ratio()
                note_metric(kind="draft", filled=draft["filled"], ratio=round(ratio, 3), draft_chars=len(draft["text"]), sent_chars=len(sent),
                            seconds=int(draft["last"] - draft["time"]))
                if draft["text"].strip() != sent.strip():
                    self._later(self._learn(draft["text"], sent))
            elif not draft["sent"] and time.time() - draft["time"] > 86400:
                del self.drafts[username]

    async def _learn(self, draft, sent):
        async with self.learning:
            with contextlib.suppress(Exception):
                known = voice_notes() or "（还没有）"
                text = f"已有笔记：\n{known}\n\n助理的草稿：\n{draft}\n\n{OWNER} 实际发出的：\n{sent}"
                notes = learned_notes(await self._reader(LEARN_PROMPT, text, effort="low", kind="learn"), draft, sent)
                if notes:
                    temporary = VOICE.with_suffix(".tmp")
                    temporary.write_text(notes + "\n")
                    temporary.replace(VOICE)

    # ---- speaking up unasked ----
    async def _opened(self, chat, generation):
        """The owner opened a conversation. Almost always this says nothing. It runs beside their turns, so it can't hold up what they ask."""
        await asyncio.sleep(OPENED_DWELL_SECONDS)
        username = str(chat["username"])
        if generation != self.generation or not self.watching or not self.history or username.endswith("@chatroom") or username == "filehelper":
            return
        newest = self.history[-1].get("id")
        # Service accounts and chats where the owner never spoke hold no promise of their to remember.
        if self.turns.locked() or self.nudged.get(username) == newest or not any(row.get("is_me") for row in self.history):
            return
        self.nudged[username] = newest
        events = self.events
        with contextlib.suppress(Exception):
            answer = await self._reader(self._reader_instructions(), "\n\n".join([*self._reader_context(chat, self.history, events), OPENED]), kind="opened")
            if answer and SILENT not in answer and generation == self.generation:
                self.add("tako", answer, events)
                self._remember_draft(last_draft(answer), chat)
