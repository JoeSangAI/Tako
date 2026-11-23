"""Which conversation it is on and what arrives there: sticking to a window, following the chat open in WeChat or DingTalk, reading it when the owner speaks, and learning from what they send."""
from __future__ import annotations

import asyncio
import contextlib
import difflib
import hashlib
import json
import os
import re
import threading
import time
import records
from pathlib import Path

import greetings as greet
import wechat_reader as reader
from guards import COUNT_SUFFIX, digits, group_by_members, learned_notes, normalized, one_letter_off, same_chat
from prompts import LEARN_PROMPT
from settings import (CONTEXT_MESSAGES, DINGTALK, FULL_READ_SECONDS, HAS_WECHAT, MAX_MESSAGE_CHARS, OWNER, POLL_SECONDS, SENT_SETTLE_SECONDS, VOICE, WECHAT,
                      clock, note_metric, voice_notes)


GOING_SECONDS = 15   # a tap on a line and the goo landing on that window
SETTLE_SECONDS = 3   # the longest a word in a chat app waits to know which chat it was said in
LOOKING_SECONDS = 3  # a chat app said its chat may be changing and never said what it read: by then it is a chat it could not tell
FIRST_READ = threading.RLock()  # the name list, chat list and groups are read the first time once, by whoever comes first
SHOW_LOOKING_SECONDS = 0.5  # unconfirmed this long, the panel says 正在看… instead of the chat before; a quicker answer goes straight from one name to the next


def render(rows):
    def where(message):
        if "file" not in message:
            return ""
        return f"（本机路径：{message['file']}）" if message["file"] else "（这个文件微信还没下到本机）"

    def when(message):  # WeChat's database has the moment; DingTalk only the time line the window shows above it, if any
        return message["time"] if isinstance(message["time"], str) else clock(message["time"])

    return "\n".join(f"[{when(m)}] {m['who']}: {m['text'][:MAX_MESSAGE_CHARS]}{where(m)}" for m in rows)


CHAT_APPS = {"wechat": "微信", "dingtalk": "钉钉"}  # a chat's kind -> what the owner calls the app


def named_chat_app(app):
    name = app.casefold()
    if name in ("微信", "wechat", WECHAT.casefold()):
        return "wechat"
    if name in ("钉钉", "dingtalk", DINGTALK.casefold()):
        return "dingtalk"
    return None


def chat_app(bundle):
    """The chat apps whose conversation follows the chat open in them: WeChat (with its export) and DingTalk (Accessibility)."""
    return "wechat" if bundle == WECHAT and HAS_WECHAT else "dingtalk" if bundle == DINGTALK else None


def dingtalk_chat(name):
    """A DingTalk chat is known by the name its window shows; no list of contacts is read."""
    return f"dingtalk:{normalized(name)}", {"username": f"dingtalk:{normalized(name)}", "name": name.strip(), "kind": "dingtalk"}


class Chats:
    async def desktop(self):
        self.window, self.watching = None, False
        if (self.chat or {}).get("username") != "desktop":
            if "desktop" not in self.saved:
                back = await asyncio.to_thread(records.conversation, "desktop")
                if back:
                    self.saved["desktop"] = back
            await self.attach({"username": "desktop", "name": "你", "kind": "desktop"})

    async def accept_asked(self, identity):
        """好 tapped under an answer: the promise it asked about is kept, as it was put. No model."""
        if not self.entrusted.accept(identity):
            return {"ok": False}
        self.keep_now()
        teach = self.entrusted.ladder.first_kept(self.entrusted.items[identity])
        await self.native("entrustedSync", **self.entrusted.native_state(), **({"teach": teach} if teach else {}), timeout=30)
        return {"ok": True, "state": self.entrusted.items[identity]["state"]}

    def chat_names(self):
        """Chats the owner has, as Tako already holds them in memory: WeChat's own chat list (when it has been read), the chats they
        talked to Tako in, and the people promises are held for. Nothing is read for this."""
        names = {str(c.get("name") or "") for c in [self.chat or {}, *(s.get("chat") or {} for s in self.saved.values())] if c.get("kind", "wechat") in ("wechat", "dingtalk")}
        names |= {str((i.get("place") or {}).get("chat") or "") for i in self.entrusted.own_pending()}
        if isinstance(self.sessions, dict) and isinstance(self.index, dict):
            names |= {p["name"] for people in self.index.values() for p in people if p["username"] in self.sessions}
        return {n for n in names if len(n.strip()) >= 2}

    async def ladder_step(self, step, body):
        """The ladder's doors (`ladder.py`): the one next step, an invitation the panel showed, what the app read from Reminders and Calendar."""
        ladder = self.entrusted.ladder
        if step == "next":
            # What only the app knows (the two switches, whether a chat app is on this Mac, what the owner has done once) is kept for the panel's next look.
            self.facts = {k: body[k] for k in ("trusted", "capture", "chat_apps", "learned") if k in body}
            return self.next_step(take=bool(body.get("take")), now=body.get("now"))
        if step == "seen":
            ladder.seen(str(body.get("id") or ""), now=body.get("now"))
            return {"ok": True}
        if step == "memory":
            if body.get("access") in ("connected", "declined"):
                ladder.state["memory_access"] = body["access"]
                ladder._save()
                if body["access"] == "connected":
                    self._later(self.native("refreshSystemSources", timeout=3))
            return {"ok": True}
        if step == "sources":
            if body.get("access"):
                ladder.set_sources(str(body["access"]))
            if isinstance(body.get("reminders"), list) or isinstance(body.get("events"), list):
                self.memory.system(body.get("reminders") or [], body.get("events") or [])
                before = [i["id"] for i in self.entrusted.pending()]
                self.entrusted.sources(body.get("reminders") or [], body.get("events") or [], self.chat_names())
                if [i["id"] for i in self.entrusted.pending()] != before:
                    self._later(self.native("entrustedSync", **self.entrusted.native_state(), timeout=30))
            return {"ok": True, "sources": ladder.sources, **self.entrusted.native_state()}
        return {"ok": False}

    def next_step(self, *, take=False, now=None):
        """The one thing that may come before the owner now (`Ladder.next`), from what the brain has and what the app said last."""
        facts = getattr(self, "facts", {})
        now = time.time() if now is None else float(now)
        # Used before this run began (a promise or a record): never a newcomer. Looked at once a run, nothing read for it again.
        if not hasattr(self, "used_before"):
            self.used_before = bool(self.entrusted.items) or any(records.folder().glob("*.md"))
        used = self.used_before
        asking = any(i.get("state") == "asked" and now - i.get("at", 0) < 12 * 3600 for i in self.entrusted.items.values())
        learned = set(facts.get("learned") or [])
        home = self.memory.root / "agents" if os.environ.get("TAKO_HOME") else Path.home()
        if self.memory.external or not (self.entrusted.ladder.sources == "connected" or any((home / p).is_dir() for p in (".codex/sessions", ".claude/projects"))):
            learned.add("memory")
        return self.entrusted.ladder.next(ready=self.setup.state().get("step") == "ready", trusted=bool(facts.get("trusted")),
                                          capture=bool(facts.get("capture")), chat_apps=bool(facts.get("chat_apps")),
                                          learned=learned, used=used, asking=asking, now=now, take=take)

    def panel_step(self):
        """Only an invitation the desktop panel draws itself (to-dos and calendar), and only once the app has said what it knows."""
        if (self.chat or {}).get("kind") != "desktop" or not getattr(self, "facts", None):
            return ""
        step = self.next_step()
        return step["id"] if step.get("id") in ("sources", "memory") else ""

    async def look_entrusted(self, identity):
        """Find where to open a to-do. Looking keeps it pending and does not call a model."""
        item = self.entrusted.get(identity)
        if not item or not self.entrusted.respond(identity, "looked"):
            return {"ok": False}
        key = item.get("k", "desktop")
        if not self._chat_of(key):
            back = await asyncio.to_thread(records.conversation, key)
            if back:
                self.saved[key] = back
        window, chat = "", ""
        place = item.get("place") or {}
        name, app = place.get("chat"), place.get("app", "")
        target = named_chat_app(app)
        if name and (target == "dingtalk" or not app and key.startswith("dingtalk:")):
            window = DINGTALK
        elif name and (target == "wechat" or not app and HAS_WECHAT):
            window, chat = WECHAT, name
        elif key.startswith("window:"):
            window = key.rsplit(":", 1)[1]
            await self.going_to(key, window)
        elif key.startswith("dingtalk:"):
            window = DINGTALK  # Its chat is opened by the owner; the panel follows it there.
        elif key != "desktop" and HAS_WECHAT:
            window, chat = WECHAT, item.get("n", "")
        return {"ok": True, "key": key, "window": window, "chat": chat}

    async def open_recorded_conversation(self, key):
        """Open a recorded conversation in the panel even after the owner went elsewhere."""
        chat = self._chat_of(key)
        if not chat and (self.chat or {}).get("username") == key:
            chat = self.chat
        if not chat:
            back = await asyncio.to_thread(records.conversation, key)
            if not back:
                return {"ok": False}
            self.saved[key] = back
            chat = back["chat"]
        self.window, self.watching = None, False
        await self.attach(chat, greet_here=False)
        return {"ok": True}

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
    #
    # One answer, for WeChat and DingTalk alike.
    # The app says a chat may be changing (`looking`: a click on that window, or the app coming forward), then what it read (`follow_header`,
    # `follow_dingtalk`); `_confirm` alone changes the conversation. Until it is confirmed nothing goes under the chat before: the panel shows
    # neither its name nor its words if it takes long, a word said asks again (`settle_chat`), and a fill reads the header again itself (`is_showing`).
    # Matching a title to a chat is in memory: the name list, and WeChat's own chat list and its groups nobody named, kept and read again in the
    # background, because each read takes seconds.

    def _newest(self, seq):
        """Reads arrive on connections of their own and can cross: only one sent after the last one taken counts. `seq` is [the app's run, its count]."""
        if not isinstance(seq, (list, tuple)) or len(seq) != 2:
            return True
        run, count = str(seq[0]), int(seq[1])
        last_run, last = self.header_seq
        if run == last_run and count <= last:
            return False
        self.header_seq = (run, count)
        return True

    def _index_names(self):
        path = reader.WXEXPORT / "work/namemap.json"
        stamp = os.stat(path).st_mtime_ns
        # The name list is refreshed as people are added and renamed: a chat with someone new has to be found without a restart.
        if self.index is None or stamp != self.index_stamp:
            with FIRST_READ:
                return self._index_again(path, stamp)
        return self.index

    def _index_again(self, path, stamp):
        if self.index is None or stamp != self.index_stamp:
            names, index = json.loads(path.read_text())["names"], {}
            for username, name in names.items():
                if isinstance(name, str) and (key := normalized(name)):
                    index.setdefault(key, []).append({"username": username, "name": name})
            self.index, self.index_stamp = index, stamp  # whole, never half-built for a read meanwhile
        return self.index

    def _kept(self, what, read, stamp_of):
        """WeChat's chat list or its groups nobody named, as last read. The first time it is read here and now; after that a change is read in the background
        and this answers at once with what it has. None when it can't be read."""
        value, stamp = getattr(self, what), getattr(self, f"{what}_stamp")
        try:
            now = stamp_of()
        except Exception:
            return value
        if value is None or stamp is None:
            with FIRST_READ:  # Being read already (`_warm`): wait for it rather than read it twice.
                if getattr(self, what) is None or getattr(self, f"{what}_stamp") is None:
                    try:
                        setattr(self, what, read())
                    except Exception:
                        setattr(self, what, type(value or {})())  # Not again on every title: once more when it changes.
                    setattr(self, f"{what}_stamp", now)
        elif now != stamp and what not in self.refreshing:
            self.refreshing.add(what)

            def again():
                try:
                    setattr(self, what, read())
                    setattr(self, f"{what}_stamp", now)
                except Exception:
                    pass
                finally:
                    self.refreshing.discard(what)
                # A title known only by itself may be a chat the list holds only now: look once more.
                titles = self.header_titles
                if titles and titles is not self.refollowed and (self.chat or {}).get("unreadable") and self.loop:
                    self.refollowed = titles
                    self.loop.call_soon_threadsafe(lambda: self._later(self.follow_header(titles)))
            threading.Thread(target=again, daemon=True).start()
        return getattr(self, what)

    def _warm(self):
        with contextlib.suppress(Exception):
            self._index_names()
            self._sessions()
            self._unnamed_groups()

    def _sessions(self):
        return self._kept("sessions", reader.sessions, lambda: self._db_signature(reader.SESSION))

    def near_in_group(self, limit=20):
        """Stuck on a WeChat group whose members can be read: what is held for someone in it, if the group is small.
        Only ids come out; a group that is big, or can't be read, concerns nothing."""
        room = str((self.chat or {}).get("username") or "")
        held = [i for i in self.entrusted.pending() if (i.get("place") or {}).get("chat")]
        if not HAS_WECHAT or not room.endswith("@chatroom") or not held:
            return []
        people = (self._kept("members", reader.group_members, reader.contact_signature) or {}).get(room) or []
        if not people or len(people) + 1 > limit:
            return []
        there = {normalized(name) for name in people}
        return [i["id"] for i in held if any(normalized(name) in there for name in [i["place"]["chat"], *str(i["place"].get("names") or "").split("\n")] if name)]

    def _unnamed_groups(self):
        return self._kept("groups", reader.unnamed_groups, reader.contact_signature) or []

    def _candidates(self, titles):
        """Chats whose name matches what was read off the window header. Every exact match before any near one: a second guess read right beats a first guess read nearly.
        A near one is a name of at least four letters with exactly one letter misread, dropped or added, the same digits, and no other chat that close;
        a shorter name, or a title of names joined by 、, only ever matches exactly. Anything else is a chat known only by its title (`_by_title`)."""
        index = self._index_names()
        keys = [key for key in map(normalized, titles) if len(key) >= 2 or "一" <= key <= "鿿"]
        for key in keys:
            if key in index:
                return key, index[key]
        listed = self._sessions()
        for line, key in ((line, normalized(line)) for line in titles):
            if len(key) < 4 or "、" in line:
                continue
            near = [k for k in index if abs(len(k) - len(key)) <= 1 and one_letter_off(k, key) and digits(k) == digits(key)]
            if listed:  # Only chats in WeChat's own list can be open.
                near = [k for k in near if any(chat["username"] in listed for chat in index[k])]
            if len(near) == 1:
                return key, index[near[0]]
        # A group nobody named is titled with its other members' names, cut short when long, and its head count.
        # Every line is tried, like the names above: the longest one may be a misread line from under the title.
        lines = [line for line in titles if len(normalized(line)) >= 4]
        groups = self._unnamed_groups() if lines else []
        for title in lines:
            if rooms := group_by_members([title], groups):
                name = COUNT_SUFFIX.sub("", title).strip()
                return normalized(title), [{"username": room, "name": name} for room in rooms]
        return None, []

    @staticmethod
    def _by_title(titles):
        """A chat known only by its title: nothing of its history can be read, but the job asked there is filed under it, not under the chat before."""
        title = next((line for line in titles if len(normalized(line)) >= 2), "")
        if not title:
            return None, None
        return normalized(title), {"username": f"title:{normalized(title)}", "name": COUNT_SUFFIX.sub("", title).strip() or title, "unreadable": True}

    def _pick(self, chats):
        """Same-named chats exist (thousands of names are shared, mostly by people in groups who were never chatted with): the one in WeChat's chat list,
        and of several there the one that moved last. Without the list, the one already open, else the first."""
        if len(chats) == 1:
            return chats[0]
        listed = self._sessions()
        live = [chat for chat in chats if listed and chat["username"] in listed]
        if live:
            return max(live, key=lambda chat: listed[chat["username"]])
        here = (self.chat or {}).get("username")
        return next((chat for chat in chats if chat["username"] == here), chats[0])

    def _latest(self, chats):
        """For reading a chat by name (`read_wechat`), not for following one: the one with the newest message, skipping chats with no table. Decrypts the message shard."""
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

    def which_chat(self, titles):
        """The chat a header read means: (key, chat) or (None, None). The one answer to "which chat is open": the panel follows it, and a fill checks against it,
        so Tako never tells the owner it is in a chat and then refuses to write there."""
        key, chats = self._candidates(titles)
        if not chats:
            return None, None
        return key, self._pick(chats)

    def open_chat(self, titles):
        """What the header means, known or only by its title; None when nothing on it reads as a title."""
        if HAS_WECHAT and reader.WXEXPORT:
            with contextlib.suppress(Exception):
                _, chat = self.which_chat(titles)
                if chat:
                    return chat
        return self._by_title(titles)[1]

    def is_showing(self, want, titles):
        """Whether WeChat's header shows the chat called `want`, decided the way the panel follows it: a title the names know is that chat and no other. Only a title they don't know falls back to the name rule."""
        if HAS_WECHAT and reader.WXEXPORT:
            with contextlib.suppress(Exception):
                _, chat = self.which_chat(titles)
                if chat:
                    return normalized(chat["name"]) == normalized(want)
        return any(same_chat(want, line) for line in titles)

    def looking(self, bundle, seq=None):
        """A click on the chat app's window, or the app coming forward: the chat may be changing. The answer is unconfirmed until the app says what it read;
        if it never does, the chat is one it could not tell, never the one before."""
        if not self._newest(seq) or not chat_app(bundle) or (self.window or {}).get("bundle") != bundle:
            return
        self.looking_since = stamp = time.monotonic()
        if self.loop:
            self.loop.call_later(LOOKING_SECONDS, lambda: self.looking_since == stamp and self._later(self._confirm(None, "looking")))

    def stop_looking(self, seq=None):
        if self._newest(seq):
            self.looking_since = 0

    def unconfirmed(self):
        """Long enough unconfirmed that the panel says so rather than show the chat before. Under half a second it doesn't: a click inside the same chat,
        or a switch read that fast, goes straight from one name to the next with nothing in between."""
        return bool(self.looking_since) and time.monotonic() - self.looking_since >= SHOW_LOOKING_SECONDS

    async def _confirm(self, chat, how="header"):
        """The one place the chat open in a chat app is decided. None: it could not tell, and that is the window's own conversation, said plainly and usable as ever."""
        was_looking, self.looking_since = bool(self.looking_since), 0
        if chat is None:
            chat = self._unknown_here()
            if chat is None:
                return
        # The same title read again without a click (a scroll redraws the strip) leaves a conversation the owner picked in the panel where it is.
        if how == "header" and not was_looking and chat["username"] == self.last_header:
            return
        self.last_header = chat["username"]
        if (self.chat or {}).get("username") != chat["username"]:
            await self.attach(self._chat_of(chat["username"]) or chat)

    def _unknown_here(self):
        window = self.window or {}
        app = chat_app(window.get("bundle"))
        if not app:
            return None
        key = f"window:{window['bundle']}:{window.get('id')}"
        chat = self._chat_of(key) or {"username": key, "name": window.get("app") or CHAT_APPS[app], "kind": "window"}
        chat["unknown"] = True
        return chat

    async def follow_header(self, titles, seq=None, settled=True):
        """What WeChat's header read. The newest read always wins; one still being matched is let go. A read taken while the chat was still drawing (`settled` False)
        is taken only if the names know it: a half-drawn title reads as nonsense, and that waits for the next read."""
        if not self._newest(seq):
            return
        self.wanted_titles = (titles, settled, self.header_seq)
        if self.following:
            while self.following:  # The app is told the answer once this read is matched.
                await asyncio.sleep(0.02)
            return
        self.following = True
        try:
            while self.wanted_titles is not None:
                (titles, settled, reading), self.wanted_titles = self.wanted_titles, None
                chat = await asyncio.to_thread(self.open_chat, titles) if titles else None
                if self.wanted_titles is not None or self.header_seq != reading:
                    continue
                self.header_titles = titles
                if (self.window or {}).get("bundle") != WECHAT:
                    self.read_early[WECHAT] = (time.time(), titles)  # Read before the brain heard it was stuck there: taken when it is.
                    continue
                if not settled and (chat is None or chat.get("unreadable")):
                    continue
                await self._confirm(chat)
        finally:
            self.following = False

    async def follow_dingtalk(self, name, seq=None):
        """DingTalk says which chat is open through Accessibility, in milliseconds: its name is the conversation, like a WeChat title. No name: it could not tell."""
        if not self._newest(seq):
            return
        if (self.window or {}).get("bundle") != DINGTALK:
            self.read_early[DINGTALK] = (time.time(), name)
            return
        await self._confirm(dingtalk_chat(name)[1] if normalized(name) else None)

    def open_now(self):
        """What the app is told after each read: the chat it settled on, for the promises it compares locally, and nothing while that is unconfirmed."""
        chat = self.chat or {}
        known = bool(chat) and not self.looking_since and not chat.get("unknown") and chat.get("kind") not in ("window", "desktop")
        return {"ok": True, "chat": chat.get("name", "") if known else "", "looking": bool(self.looking_since)}

    async def stick(self, window):
        """Stuck onto a window. A chat app picks its conversation from the chat open in it; any other window is its own session."""
        self.window = window
        if app := chat_app(window.get("bundle")):
            if self.chat and self.chat.get("kind") == "window" and not (self.chat.get("unknown") and self.chat["username"].startswith(f"window:{window.get('bundle')}:")):
                self._park()
                self.chat, self.events = None, []
                self.last_header = ""
                self.generation += 1
            if self.chat is None:
                self.looking(window.get("bundle"))  # Which chat is open isn't known yet: not the chat before, and said so if it takes long.
            if app == "wechat" and self.loop:
                self._later(asyncio.to_thread(self._warm))  # Ready before the first title, not read while it waits.
            heard = self.read_early.pop(window.get("bundle"), None)
            if heard and time.time() - heard[0] < GOING_SECONDS:
                await (self.follow_header(heard[1]) if app == "wechat" else self.follow_dingtalk(heard[1]))
            return
        key = f"window:{window.get('bundle')}:{window.get('id')}"
        if (shown := self._shown_on(key, str(window.get("id") or ""))) is not None:
            if (self.chat or {}).get("username") != shown["username"]:
                await self.attach(shown)
            return
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

    def _shown_on(self, key, window_id):
        """Another conversation a window shows instead of its own, or None. The one the owner just tapped a line to go to comes first: that line is what they want to see.
        Otherwise a window a job worked shows that job's conversation, so the owner finds it where it was done, unless the window's own conversation has changed since the job last worked there."""
        going = self.going
        if going and going["window"] == window_id:
            self.going = None
            if time.time() - going["at"] < GOING_SECONDS and (chat := self._chat_of(going["key"])):
                return chat
        worked = self.worked.get(key)
        if worked and self._last_said(worked["username"]) >= self._last_said(key):
            return worked
        return None

    def _chat_of(self, key):
        if self.chat and self.chat["username"] == key:
            return self.chat
        return (self.saved.get(key) or {}).get("chat")

    def _last_said(self, key):
        events = self.events if self.chat and self.chat["username"] == key else (self.saved.get(key) or {}).get("events") or []
        return events[-1].get("at", 0) if events else 0

    async def going_to(self, key, window):
        """The owner tapped the line about a job elsewhere: that is them seeing it, wherever the panel ends up. The window it lands on shows that job."""
        self.finished.pop(key, None)
        self.going = {"key": key, "window": str(window or ""), "at": time.time()}
        # Already on that window, the goo doesn't move and nothing says it landed.
        if self.window and str(self.window.get("id") or "") == self.going["window"] and not chat_app(self.window.get("bundle")):
            await self.stick(self.window)

    async def settle_chat(self):
        """Before a word in a chat app is taken: which chat is open now, read again then and there, so a chat clicked a moment ago is never the chat before. Nothing read leaves a chat already confirmed where it is; with none confirmed, it is one it could not tell, said plainly."""
        app = chat_app((self.window or {}).get("bundle"))
        if not app:
            return
        seen = await self.native("titles", timeout=SETTLE_SECONDS, window=str(self.window.get("id") or ""))
        lines = [str(t) for t in (seen.get("lines") or []) + (seen.get("others") or [])][:12]
        if app == "dingtalk":
            chat = dingtalk_chat(lines[0])[1] if lines and normalized(lines[0]) else None
        else:
            chat = await asyncio.to_thread(self.open_chat, lines) if lines else None
        # DingTalk's Accessibility is exact: no name there is no chat open. WeChat's picture read is not: nothing read now (a pop-up over the strip, say)
        # leaves a chat confirmed since the last click where it is; unconfirmed, it is one it could not tell.
        if chat or app == "dingtalk" or not (self.chat and not self.looking_since and not self.chat.get("unknown")):
            await self._confirm(chat, "asked")

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
            self.saved[self.chat["username"]] = {"events": self.events, "chat": self.chat}

    async def attach(self, chat, greet_here=True):
        """Bind to one conversation. Nothing is read until the owner speaks."""
        self._park()
        self.generation += 1
        if greet_here and chat.get("kind") not in ("window", "desktop"):
            chat["greeting"] = self.greetings.in_a_chat()
            if self.greetings.chat_lines_are_old():
                self._later(self._new_chat_lines())
        back = self.saved.get(chat["username"])
        self.chat, self.signature, self.mark = chat, None, None
        self.events = back["events"] if back else []
        self.finished.pop(chat["username"], None)  # They're back: it's in front of them.
        self.status, self.error = "idle", ""  # A running job keeps its own status and stop button, in its own conversation.

    async def _said_since(self, chat, seen, window=None):
        """What a chat has said that the model hasn't seen, read now because the owner spoke. Empty when there is nothing new, None when it can't be read.
        seen: the newest message of each chat the thread was given (`Brain.read_up_to`); a new thread has seen none of it."""
        if chat and chat.get("kind") == "dingtalk":
            return await self._dingtalk_since(chat, seen, window)
        if not HAS_WECHAT or not chat or chat.get("kind") in ("window", "desktop"):
            return []
        if chat.get("unreadable"):
            return None
        after = seen.get(chat["username"], 0)
        for wait in (0, 1, 2):  # WeChat may be mid-write.
            await asyncio.sleep(wait)
            with contextlib.suppress(Exception):
                return await asyncio.to_thread(self._read, chat, after, CONTEXT_MESSAGES * 2 if after else CONTEXT_MESSAGES)
        return None

    async def _dingtalk_since(self, chat, given, window):
        """DingTalk's messages as its window shows them, through Accessibility, only if it still shows this chat: who said each, and which are the owner's own.
        No history beyond what is on screen. What the model was given last is remembered by a fingerprint, in memory only."""
        seen = await self.native("chatMessages", timeout=5, window=str((window or {}).get("id") or "") or None)
        if not seen.get("ok") or normalized(str(seen.get("chat") or "")) != normalized(chat["name"]):
            return None
        rows = []
        for row in seen.get("rows") or []:
            text = str(row.get("text") or "")
            if not text:
                continue
            mark = hashlib.sha1(f"{row.get('who')}|{row.get('time')}|{text}".encode()).hexdigest()[:16]
            rows.append({"id": mark, "time": str(row.get("time") or ""), "is_me": bool(row.get("me")), "who": "我" if row.get("me") else str(row.get("who") or chat["name"]), "text": text})
        after = given.get(chat["username"])
        marks = [row["id"] for row in rows]
        if after in marks:
            return rows[len(marks) - marks[::-1].index(after):]
        return rows

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
        if draft and chat and chat.get("kind", "wechat") == "wechat":
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
                # The measure of a hand-over is whether it was used: sent as it was, sent changed, or not sent at all.
                self.feedback.count("draft.sent_as_is" if ratio >= 0.95 else "draft.sent_changed" if ratio >= 0.5 else "draft.sent_other")
                # A promise in that draft the owner said 好 to counts from now: what went out is theirs.
                if self.entrusted.draft_sent(username, sent):
                    self._later(self.native("entrustedSync", **self.entrusted.native_state(), timeout=30))
                if draft["text"].strip() != sent.strip():
                    self._later(self._learn(draft["text"], sent))
            elif not draft["sent"] and time.time() - draft["time"] > 86400:
                del self.drafts[username]
                self.feedback.count("draft.unsent")
                self.entrusted.draft_unsent(username)

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
