"""The owner's hub: where their to-dos live when they have one (the ontology engine's reminders door).

Tako is the hand, not the book. With a hub configured (the same loopback `ontology_source` its memory reads), what the
owner entrusts goes there at once as one record, what is worth bringing up comes from there, and what the owner answers
goes back to that same record. Without one, the same things stay in Tako's own records, as before.

Nothing here decides a moment or calls a model. What can't be delivered waits in a small outbox (`hub-outbox.json`) and
goes in order when the hub answers again; a request repeated is the same record there, so nothing is ever said twice.
"""
from __future__ import annotations

import datetime
import json
import os
import threading
import time
from http.client import HTTPException
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

from settings import ZONE

TIMEOUT = 20   # a write to the hub can take several seconds under load; a repeat is the same record
LATE = 1800          # a clock time missed by more than this (Tako was not running) is no longer rung as "now"
RESPONSES = {"done": "done", "cancel": "dropped", "later": "later", "today": "later", "ignored": "ignored"}


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def endpoint(url):
    """The reminders door beside an explicit loopback ontology endpoint, or None."""
    try:
        parts = urlsplit(url)
    except (TypeError, ValueError):
        return None
    if (parts.scheme not in ("http", "https") or parts.hostname not in ("127.0.0.1", "::1")
            or parts.username is not None or parts.password is not None or parts.query or parts.fragment
            or parts.path.rstrip("/") not in ("", "/api/ontology")):
        return None
    return parts._replace(path="/api/ontology/reminders").geturl()


class Hub:
    def __init__(self, url, root):
        self.url = endpoint(url) if url else None
        self.path = Path(root) / "hub-outbox.json"
        self.twins = {}      # Tako's id of something the owner entrusted here -> the hub's id of that same record
        self.closed = set()  # twins the hub says are ended (done somewhere else)
        self.lock = threading.Lock()  # the outbox is filled on the Companion loop and emptied on a worker thread
        try:
            self.outbox = [b for b in json.loads(self.path.read_text()) if isinstance(b, dict)] if self.url else []
        except (OSError, ValueError):
            self.outbox = []

    @property
    def enabled(self):
        return self.url is not None

    def _save(self):
        try:
            temporary = self.path.with_suffix(".tmp")
            temporary.write_text(json.dumps(self.outbox, ensure_ascii=False))
            os.chmod(temporary, 0o600)
            temporary.replace(self.path)
        except OSError:
            pass

    def _open(self, body=None):
        request = Request(self.url, data=None if body is None else json.dumps(body, ensure_ascii=False).encode(),
                          method="GET" if body is None else "POST", headers={"Content-Type": "application/json"})
        with build_opener(ProxyHandler({}), _NoRedirect()).open(request, timeout=TIMEOUT) as response:
            return json.load(response)

    # ---- what Tako hands in (called on the Companion loop: only queues) ----
    def entrusted(self, item):
        """Something the owner entrusted in their own words: one record there, keyed by Tako's id so a repeat is the same one."""
        if not self.enabled or item.get("source") != "owner":
            return
        request = "tako:" + item["id"]
        if any(b.get("request_id") == request for b in self.outbox):
            return
        body = {"op": "entrust", "request_id": request, "text": item["text"], "at": item.get("created") or time.time()}
        if item.get("due") is not None:
            body["due"] = datetime.datetime.fromtimestamp(item["due"], ZONE).isoformat(timespec="seconds")
        if chat := (item.get("place") or {}).get("chat"):
            body["people"] = [chat]
        if item.get("quote"):
            body["quote"] = str(item["quote"])[:2000]
        with self.lock:
            self.outbox.append(body)
            self._save()

    def responded(self, item, action, reason, now):
        """What the owner did when it came up, with why it came up."""
        if not self.enabled or action not in RESPONSES:
            return
        if item.get("from") != "hub" and item.get("source") != "owner":
            return
        response = RESPONSES[action]
        # Put off something that has a day or has stood still: that is "another day", not "in a while".
        if action == "later" and item.get("kind") in ("day", "stalled"):
            response = "another_day"
        occasion = {"type": {"due": "time", "place": "person", "meeting": "person"}.get(reason, "state"), "reason": reason}
        body = {"op": "respond", "request_id": f"tako:{item['id']}:{action}:{int(now * 1000)}", "response": response,
                "at": now, "occasion": occasion}
        body.update({"id": item["hub"]} if item.get("from") == "hub" else {"local": item["id"]})
        with self.lock:
            self.outbox.append(body)
            self._save()

    # ---- the wire (blocking: run in a thread) ----
    def exchange(self, held=()):
        """Deliver what waits, in order, then read what is worth bringing up. Returns the outlet, or None when the hub is away."""
        if not self.enabled:
            return None
        waiting = {b.get("request_id") for b in self.outbox}
        for item in held:  # After a restart, or when one was closed elsewhere: ask again. The same request is the same record.
            if item["id"] not in self.twins and "tako:" + item["id"] not in waiting:
                self.entrusted(item)
        try:
            while self.outbox:
                body = dict(self.outbox[0])
                local = body.pop("local", None)
                if local is not None:
                    if local not in self.twins:  # never reached the hub as a record: nothing there to answer for
                        with self.lock:
                            self.outbox.pop(0)
                        continue
                    body["id"] = self.twins[local]
                try:
                    reply = self._open(body)
                except HTTPError as error:
                    error.close()
                    if error.code >= 500:
                        raise
                    reply = None  # refused as it stands (409, 404, 422): repeating it changes nothing
                if reply and body["op"] == "entrust" and isinstance(reply.get("item"), dict):
                    local = body["request_id"][5:]
                    self.twins[local] = reply["item"].get("id")
                    if reply["item"].get("open") is False:
                        self.closed.add(local)
                with self.lock:
                    self.outbox.pop(0)
                    self._save()
            outlet = self._open()
        except (OSError, ValueError, HTTPException):
            return None
        return outlet if isinstance(outlet, dict) and isinstance(outlet.get("items"), list) else None


def held_items(outlet, now, twins=()):
    """The hub's open things as things in the hand: a clock time rings, a person waits for their chat, a day reached or
    something that stood still waits for a free moment. Only the one that stood still longest is carried."""
    today = datetime.datetime.fromtimestamp(now, ZONE).date()
    found, stalled = {}, None
    for entry in outlet.get("items") or []:
        if not isinstance(entry, dict) or not isinstance(entry.get("id"), str) or entry.get("open") is False:
            continue
        if entry.get("snoozed_until") or entry["id"] in twins:
            continue
        # Whether a to-do is worth saying out loud is the hub's judgment, not the hand's: it marks those (`speak`).
        # Unmarked, only what the owner entrusted themselves is carried; the rest stays in the hub's own list.
        if entry.get("origin") != "entrusted" and entry.get("speak") is not True:
            continue
        item = {"id": "h:" + entry["id"], "hub": entry["id"], "from": "hub", "state": "held", "k": "desktop",
                "text": " ".join(str(entry.get("title") or "").split()), "due": None, "created": now, "held_since": now,
                "why": str(entry.get("reason") or ""), "kind": "plain" if entry.get("origin") == "entrusted" else "",
                "own": entry.get("origin") == "entrusted"}
        if not item["text"]:
            continue
        project = entry.get("project")
        if isinstance(project, dict) and project.get("name"):  # the names a group chat about it would carry
            item["project"] = "\n".join(dict.fromkeys(str(n).strip() for n in (project["name"], *(project.get("aliases") or [])) if len(str(n).strip()) >= 2))
        last = entry.get("last_response") or {}
        try:
            if datetime.datetime.fromisoformat(str(last.get("at"))).astimezone(ZONE).date() == today:
                item["said_day"] = today.isoformat()  # answered today on any device: not again today
        except ValueError:
            pass
        for occasion in entry.get("occasions") or []:
            kind = occasion.get("type") if isinstance(occasion, dict) else None
            if kind == "time" and isinstance(occasion.get("at"), str):
                at = occasion["at"]
                try:
                    if len(at) > 10:
                        stamp = datetime.datetime.fromisoformat(at.replace("Z", "+00:00")).timestamp()
                        if stamp > now - LATE:
                            item["due"] = stamp
                        else:
                            item["kind"] = "day"
                    elif datetime.date.fromisoformat(at) <= today:
                        item["kind"] = "day"
                except ValueError:
                    continue
            elif kind == "person" and "place" not in item:
                people = [p for p in occasion.get("people") or [] if isinstance(p, dict) and p.get("name")]
                names = list(dict.fromkeys(str(n).strip() for p in people for n in (p["name"], *(p.get("aliases") or [])) if str(n).strip()))
                if names:
                    item["place"] = {"chat": names[0], "names": "\n".join(names)}
                    if occasion.get("why") == "waiting" and isinstance(occasion.get("days"), int):
                        item["waiting"] = occasion["days"]
            elif kind == "state" and occasion.get("state") == "stalled" and isinstance(occasion.get("days"), int):
                item["stalled"] = occasion["days"]
        if item["due"] is None and "place" not in item and not item["kind"]:
            if "stalled" not in item:
                continue  # a day not reached yet, and nobody to see about it: not for today
            item["kind"] = "stalled"
            if stalled is None or item["stalled"] > stalled["stalled"]:
                stalled = item
            continue
        found[item["id"]] = item
    if stalled:
        found[stalled["id"]] = stalled
    return found


def line(item, reason, siblings=1):
    """What the bubble says for something from the hub, with the reason it is being said now."""
    text = item["text"]
    chat = (item.get("place") or {}).get("chat")
    # The card holds two short lines: the reason first, in a few words, then the thing itself.
    if reason == "due":
        return f"到点了：{text}"
    if reason in ("place", "meeting") and chat:
        if siblings > 1:
            return f"打开了{chat}的聊天，有 {siblings} 件：{text}"
        if item.get("waiting") is not None:
            return f"等{chat} {item['waiting']} 天了：{text}"
        return f"打开了{chat}的聊天：{text}"
    if item.get("kind") == "stalled":
        return f"停了 {item.get('stalled', 0)} 天：{text}"
    return f"{item['why']}：{text}" if item.get("why") else text
