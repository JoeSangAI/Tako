"""The owner's other agents (Claude, Codex and the like) handing Tako a job at a window: the same job as the owner's own words, the floors unchanged.

They come in with a token of their own (`agent.json`, readable by the owner alone) that opens only these doors, never a card: an approval still waits for the owner's own tap, and sending stays refused as always."""
from __future__ import annotations

import json
import asyncio
import os
import secrets
import time
import records
from pathlib import Path

from settings import AGENT_DOOR, OWNER
from turns import Job

KEEP_SECONDS = 3600  # an agent asks how it ended within the hour, or not at all


def open_door(port, token):
    """Written fresh on every start, so the old token goes with the old server."""
    temporary = AGENT_DOOR.with_suffix(".tmp")
    with os.fdopen(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as out:
        json.dump({"url": f"http://127.0.0.1:{port}", "token": token, "pid": os.getpid()}, out)
    temporary.replace(AGENT_DOOR)


class Agents:
    async def agent_entrust(self, body):
        """An agent's own prepared hand-over: the same record and promise, no model thread."""
        text = str(body.get("text") or "").strip()
        if not text:
            return {"ok": False, "error": "请给递回时要说的话"}
        source = str(body.get("from") or "Agent").strip()[:40] or "Agent"
        now = time.time()
        if (self.chat or {}).get("username") == "desktop":
            chat, events = self.chat, self.events
        else:
            chat = {"username": "desktop", "name": "你", "kind": "desktop"}
            if "desktop" not in self.saved:
                self.saved["desktop"] = await asyncio.to_thread(records.conversation, "desktop") or {"chat": chat, "events": []}
            events = self.saved["desktop"]["events"]
        job = Job(chat, events, None)
        job.owner_words, job.asked_at, job.utterances, job.agent_source = text, now, [(text, now)], source
        job.record_id = await asyncio.to_thread(records.begin, "desktop", "你", f"〔{source} 转来〕{text}", "")
        args = {"action": "keep", "quote": text, "text": text, "place": body.get("place") or {}}
        for name in ("due", "after"):
            if name in body:
                args[name] = body[name]
        try:
            item = self.entrusted.change(args, job)
        except ValueError as exc:
            await asyncio.to_thread(records.end, job.record_id, "没拿到")
            return {"ok": False, "error": str(exc)}
        self.add("owner", f"〔{source} 转来〕{text}", events)
        self.keep_now()
        await asyncio.to_thread(records.end, job.record_id, "记下了")
        notice = await self.native("entrustedSync", **self.entrusted.native_state(), timeout=30)
        return {"ok": True, "id": item["id"], "due": item.get("due"), "notification_scheduled": item["id"] in notice.get("scheduled", [])}

    async def agent_entrustments(self, identity=""):
        items = self.entrusted.items
        if identity:
            item = items.get(identity)
            return {"ok": True, "item": item} if item else {"ok": False, "error": "没有这件托付"}
        return {"ok": True, "items": list(items.values())}

    async def agent_unentrust(self, identity, source="Agent"):
        source = str(source or "Agent").strip()[:40] or "Agent"
        item = self.entrusted.items.get(identity)
        if not item or item.get("state") != "held":
            return {"ok": False, "error": "没有这件提醒"}
        if item.get("source") != "agent" or item.get("source_name") != source:
            return {"ok": False, "error": "只能撤回自己转来的托付"}
        self.entrusted.append(item, "cancel", state="cancelled", by=source)
        if (self.entrusted.offering or {}).get("id") == identity:
            self.entrusted.offering = None
        await self.native("entrustedSync", **self.entrusted.native_state(), timeout=30)
        return {"ok": True, "id": identity, "state": "cancelled"}

    async def agent_ask(self, text, window=None, files=(), source="Agent"):
        """Starts the job and answers at once with its id; how it ends is `agent_job`. Without a window named, the one the goo is on."""
        asked_at = time.time()
        files = [str(Path(f).expanduser()) for f in files]
        if missing := [f for f in files if not os.path.exists(f)]:
            return {"ok": False, "error": "这些文件不存在：" + "、".join(missing)}
        if window == "desktop" or (not window and (not self.window or not self.watching)):
            where = None
            chat = {"username": "desktop", "name": "你", "kind": "desktop"}
            if (self.chat or {}).get("username") == "desktop":
                events = self.events
            else:
                if "desktop" not in self.saved:
                    old = await asyncio.to_thread(records.conversation, "desktop")
                    if old:
                        self.saved["desktop"] = old
                back = self.saved.setdefault("desktop", {"chat": chat, "events": []})
                events = back["events"]
        else:
            found = await self.native("resolve", timeout=8, window=window or None)
            if not found.get("ok"):
                return {"ok": False, "error": found.get("error") or "没找到那个窗口"}
            where = {k: str(found.get(k) or "") for k in ("app", "bundle", "title", "id")}
            chat, events = self._conversation_of(where)
        job = Job(chat, events, where)
        job.asked_at = asked_at
        job.agent_source = source
        key = secrets.token_hex(4)
        self._forget_old_agent_jobs()
        self.agent_jobs[key] = {"job": job, "ended": None}
        # The owner sees who handed it over, in the conversation of that window, like anything they said there.
        names = "".join(f"\n[{Path(f).name}](</{f.lstrip('/')}>)" for f in files)
        self.add("owner", f"〔{source} 转来〕{text}{names}", events)
        words = (f"（这件事是 {OWNER} 通过 {source} 交给你的，当作 {OWNER} 亲口说的来做。你的回答会原样交回 {source}；"
                 f"要问的就直接问，{source} 会转达。）\n{text}")
        self._later(self._agent_turn(key, job, words, files))
        return {"ok": True, "id": key, "window": job.name}

    async def _agent_turn(self, key, job, words, files):
        try:
            await self.turn(words, attachments=files, where=(job.chat, job.events, job.window), job=job)
        finally:
            self.agent_jobs[key]["ended"] = time.time()

    def _conversation_of(self, window):
        """The conversation that window already has: the panel shows the job there, and it shares memory with what the owner said there."""
        if self.chat and str((self.window or {}).get("id") or "") == window["id"]:
            return self.chat, self.events
        key = f"window:{window['bundle']}:{window['id']}"
        chat = {"username": key, "name": window["title"] or window["app"] or "那个窗口", "kind": "window"}
        return chat, self.saved.setdefault(key, {"events": [], "chat": chat})["events"]

    def _forget_old_agent_jobs(self):
        for key, record in list(self.agent_jobs.items()):
            if record["ended"] and time.time() - record["ended"] > KEEP_SECONDS:
                del self.agent_jobs[key]

    def agent_job(self, key):
        record = self.agent_jobs.get(key)
        if not record:
            return {"ok": False, "error": "没有这件事：id 不对、超过一小时被忘了，或 Tako 重启过"}
        job = record["job"]
        cards = [card["text"] for card in list(self.pending.values()) if card["job"] is job]
        if not job.ended.is_set():
            state = "needs_owner" if cards else "queued" if job.waiting else "working"
        else:
            state = "stopped" if job.stopping else "failed" if job.failed and not job.answer else "done"
        reply = {"ok": True, "id": key, "state": state, "window": job.name, "steps": job.steps[-12:], "answer": job.answer}
        if job.failed:
            reply["error"] = job.failed
        if job.trouble:
            reply["trouble"] = job.trouble
        if cards:
            reply["cards"] = cards
            reply["note"] = f"等 {OWNER} 在 Tako 面板上点同意或拒绝，agent 点不了"
        if job.left_for_owner and state == "done":
            reply["note"] = f"有一步要等 {OWNER} 到那个窗口才能做，TA 到了会自己做完，不用再派"
        return reply

    async def agent_stop(self, key):
        record = self.agent_jobs.get(key)
        if record and not record["job"].ended.is_set():
            await self._stop(record["job"])
        return self.agent_job(key)
