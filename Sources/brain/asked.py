"""What the owner asked Tako to do and how each one ended, kept on this Mac for a week so a restart or an update doesn't forget a job (Joe 2026-11-03).
Only the owner's own words, where they said them, the folder and the names of the files made there: never what a window or a chat showed."""
from __future__ import annotations

import contextlib
import json
import os
import time
from pathlib import Path

from settings import ASKED, clock

KEEP_SECONDS, KEEP_AT_MOST, SHOWN, MADE_SHOWN = 7 * 86400, 60, 20, 8


def _load():
    with contextlib.suppress(OSError, ValueError):
        items = json.loads(ASKED.read_text())
        if isinstance(items, list):
            return [item for item in items if isinstance(item, dict) and time.time() - item.get("at", 0) < KEEP_SECONDS]
    return []


def _save(items):
    spare = ASKED.with_name(ASKED.name + ".tmp")
    with contextlib.suppress(OSError):
        ASKED.parent.mkdir(parents=True, exist_ok=True)
        spare.write_text(json.dumps(items[-KEEP_AT_MOST:], ensure_ascii=False))
        os.chmod(spare, 0o600)
        os.replace(spare, ASKED)


def begin(where, words, folder):
    at = time.time()
    _save([*_load(), {"at": at, "where": str(where or "")[:60], "asked": str(words)[:500], "folder": str(folder or ""), "ended": "在做"}])
    return at


def end(key, ended, folder):
    items = _load()
    for item in items:
        if item.get("at") == key:
            item["ended"] = ended
            with contextlib.suppress(OSError):
                item["made"] = sorted(path.name for path in Path(folder).iterdir() if path.is_file() and not path.name.startswith("."))[:MADE_SHOWN] if folder else []
    _save(items)


def memory(owner):
    """For a thread that remembers nothing: the jobs of the last days, so “弄好了吗” has something to go on."""
    lines = []
    for item in _load()[-SHOWN:]:
        made = f"；做出：{'、'.join(item['made'])}" if item.get("made") else ""
        lines.append(f"- {clock(item['at'])} 在「{item.get('where') or '某个窗口'}」，TA说：{item.get('asked', '')}｜作品目录：{item.get('folder') or '无'}{made}｜结局：{item.get('ended', '不明')}")
    if not lines:
        return ""
    return f"（{owner} 最近几天交代过你的事，你重启过所以不记得细节。这只是记忆，不是新要求；有没做完的，TA问起就接着做。）\n" + "\n".join(lines)
