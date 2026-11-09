"""The panel's conversations, kept on this Mac for a week so a restart or an update doesn't empty them (Joe 2026-11-09: two restarts lost the answer he went back to).
What the panel showed and nothing more: the owner's words and Tako's answers, never a chat's messages or a window's text by themselves. Never logged, never sent anywhere."""
from __future__ import annotations

import contextlib
import json
import os
import time

from settings import CONVERSATIONS

KEEP_SECONDS, KEEP_EVENTS, KEEP_AT_MOST = 7 * 86400, 80, 200


def load():
    """username -> {"chat": {username, name, kind}, "events": [...]}, the ones used in the last week."""
    with contextlib.suppress(OSError, ValueError):
        kept = json.loads(CONVERSATIONS.read_text())
        if isinstance(kept, dict):
            fresh = {}
            for username, item in kept.items():
                if not isinstance(item, dict) or time.time() - float(item.get("at") or 0) > KEEP_SECONDS:
                    continue
                events = [event for event in item.get("events") or [] if isinstance(event, dict)]
                for n, event in enumerate(events):
                    event["id"] = n  # the panel counts what it has shown by these
                fresh[username] = {"chat": {**(item.get("chat") or {}), "username": username}, "events": events}
            return fresh
    return {}


def save(conversations):
    """conversations: username -> (chat, events). Only those with something said, the latest last, written whole and readable by the owner alone."""
    kept = {}
    for username, (chat, events) in conversations.items():
        if events:
            at = max((float(event.get("at") or 0) for event in events), default=0) or time.time()
            kept[username] = {"chat": {"name": (chat or {}).get("name") or "", "kind": (chat or {}).get("kind") or "wechat"}, "at": at, "events": events[-KEEP_EVENTS:]}
    kept = dict(sorted(kept.items(), key=lambda item: item[1]["at"])[-KEEP_AT_MOST:])
    spare = CONVERSATIONS.with_name(CONVERSATIONS.name + ".tmp")
    with contextlib.suppress(OSError):
        CONVERSATIONS.parent.mkdir(parents=True, exist_ok=True)
        with open(os.open(spare, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as out:
            json.dump(kept, out, ensure_ascii=False)
        os.chmod(spare, 0o600)
        os.replace(spare, CONVERSATIONS)
