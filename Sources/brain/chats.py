"""Which conversation it is on and what arrives there: sticking to a window, following WeChat, reading it when the owner speaks, and learning from what they send."""
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
from guards import learned_notes, normalized
from prompts import LEARN_PROMPT
from settings import (CONTEXT_MESSAGES, FULL_READ_SECONDS, HAS_WECHAT, MAX_MESSAGE_CHARS, OWNER, POLL_SECONDS, SENT_SETTLE_SECONDS, VOICE, WECHAT,
                      clock, note_metric, voice_notes)


def render(rows):
    def where(message):
        if "file" not in message:
            return ""
        return f"（本机路径：{message['file']}）" if message["file"] else "（这个文件微信还没下到本机）"

    return "\n".join(f"[{clock(m['time'])}] {m['who']}: {m['text'][:MAX_MESSAGE_CHARS]}{where(m)}" for m in rows)


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

    async def _new_chat_lines(self):
        """Only the word WeChat goes out, on a throwaway thread with no tools, and nothing from any chat."""
        try:
            self.greetings.take_chat_lines(await self._reader(greet.CHAT_PROMPT, greet.ask_for(greet.WECHAT_NAME), effort="low", kind="greeting"))
        except Exception:
            return  # No model right now: the lines it has will do, and it asks again later.

    def _park(self):
        if self.chat:
            self.saved[self.chat["username"]] = {"events": self.events}

    async def attach(self, chat):
        """Bind to one conversation. Nothing is read until the owner speaks."""
        self._park()
        self.generation += 1
        if chat.get("kind") != "window":
            chat["greeting"] = self.greetings.in_a_chat()
            if self.greetings.chat_lines_are_old():
                self._later(self._new_chat_lines())
        back = self.saved.get(chat["username"])
        self.chat, self.signature, self.mark = chat, None, None
        self.events = back["events"] if back else []
        self.finished.pop(chat["username"], None)  # They're back: it's in front of them.
        self.status, self.error = "idle", ""  # A running job keeps its own status and stop button, in its own conversation.

    async def _said_since(self, chat, fresh=False):
        """What a WeChat conversation has said that the model hasn't seen, read now because the owner spoke. Empty when there is nothing new, None when it can't be read. A thread of its own (fresh) has seen none of it."""
        if not HAS_WECHAT or not chat or chat.get("kind") == "window":
            return []
        after = 0 if fresh else self.read_up_to.get(chat["username"], 0)
        for wait in (0, 1, 2):  # WeChat may be mid-write.
            await asyncio.sleep(wait)
            with contextlib.suppress(Exception):
                return await asyncio.to_thread(self._read, chat, after, CONTEXT_MESSAGES * 2 if after else CONTEXT_MESSAGES)
        return None

    async def poll_forever(self):
        """Only for learning: after a draft, whether the owner sent it. File stats until something moves, and no model call to look. No draft, no reading."""
        while True:
            await asyncio.sleep(POLL_SECONDS)
            self._settle_drafts()
            chat = self.chat
            draft = self.drafts.get(chat["username"]) if chat else None
            if not draft or not self.watching:
                continue
            try:
                if await asyncio.to_thread(self._chat_changed, chat["username"]):
                    rows = await asyncio.to_thread(self._read, chat, draft["after"], 200)
                    if rows:
                        draft["after"] = rows[-1]["id"]
                        self._saw_sent(draft, rows)
            except Exception:
                self.shard_signature = None  # The session list won't say it again; the next full read picks these up.

    # ---- learning from what the owner actually sends ----
    def _remember_draft(self, draft, chat, filled=False):
        if draft and chat and chat.get("kind") != "window":
            self.drafts[chat["username"]] = {"text": draft, "time": time.time(), "filled": filled, "sent": [], "last": 0.0, "after": self.read_up_to.get(chat["username"], 0)}

    def _saw_sent(self, draft, rows):
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
