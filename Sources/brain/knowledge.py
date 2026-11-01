"""The one lookup a tool-less reader can ask for: run by the system, not the model."""
from __future__ import annotations

import json
import re
import subprocess

from settings import KNOWLEDGE_COMMAND, KNOWLEDGE_DIR, KNOWLEDGE_NAME


def passages(text, query, limit=5000):
    """The lines of a file that match the search, with their neighbours, those with results first. A file's first paragraph is rarely the answer."""
    lines = re.sub(r"\A---\n.*?\n---\n", "", text, flags=re.S).splitlines()
    words = [word.lower() for word in query.split() if len(word) >= 2]
    hits = [sum(word in line.lower() for word in words) for line in lines]
    scored = sorted(((count + bool(re.search(r"\d%|\d+万|\d+亿", lines[at])), -at) for at, count in enumerate(hits) if count), reverse=True)
    keep, size = set(), 0
    for _, at in scored:
        if size >= limit:
            break
        for near in (-at - 1, -at, -at + 1):
            if 0 <= near < len(lines) and near not in keep:
                keep.add(near)
                size += min(len(lines[near]), 400)
    return "\n".join(lines[at][:400] for at in sorted(keep))


def knowledge_lookup(query):
    """Run by the system, not the model: a fixed read-only command with no shell and no network, so a message can only change what gets searched."""
    try:
        completed = subprocess.run([str(KNOWLEDGE_COMMAND), "query", "--mode", "knowledge", "--limit", "5", "--", query],
                                   capture_output=True, text=True, timeout=30, check=True)
        results = json.loads(completed.stdout)["local_results"]
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        return f"这次没查到：{KNOWLEDGE_NAME}查询失败。"
    # A file named after what is being asked about beats whatever ranks highest in the full-text search.
    words = [word for word in query.split() if len(word) >= 2]
    named = sorted((path for path in KNOWLEDGE_DIR.rglob("*.md") if any(word in path.stem for word in words)),
                   key=lambda path: -sum(word in path.stem for word in words))[:2]
    paths = [*named, *((KNOWLEDGE_DIR.parent / str(result.get("locator"))) for result in results)]
    found, seen = [], set()
    for path in paths:
        path = path.resolve()
        if path in seen or len(found) >= 4 or not path.is_relative_to(KNOWLEDGE_DIR.resolve()) or not path.is_file():
            continue
        seen.add(path)
        if text := passages(path.read_text(errors="replace"), query):
            found.append(f"《{path.stem}》 文件：{path}\n{text}")
    return "\n\n".join(found) or "这次没查到相关内容。"
