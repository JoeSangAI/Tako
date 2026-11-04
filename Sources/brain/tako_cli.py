#!/usr/bin/env python3
"""`tako`: how the owner's other agents (Claude Code, Codex, scripts) hand Tako a job at a window and hear how it ended.

  tako ask "把这页的数字核对一遍" [--window Keynote] [--file a.pdf] [--no-wait]
  tako job ID [--wait]
  tako stop ID
  tako windows

It reads the door Tako writes when it starts (agent.json in Tako's own folder). Only the standard library, any python3 from 3.8.
Exit codes: 0 done, 1 failed or refused, 3 still going (asked not to wait, or waited long enough), 4 stopped.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

HOME = Path(os.environ.get("TAKO_HOME") or Path.home() / "Library" / "Application Support" / "Tako")


def door():
    try:
        found = json.loads((HOME / "agent.json").read_text())
        return found["url"], found["token"]
    except (OSError, ValueError, KeyError):
        sys.exit("Tako 没在运行，或者还是不认 agent 的旧版本：先打开 Tako。")


def call(path, body=None, timeout=20):
    url, token = door()
    request = urllib.request.Request(url + path, data=None if body is None else json.dumps(body).encode(),
                                     method="GET" if body is None else "POST",
                                     headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as reply:
            return json.load(reply)
    except urllib.error.HTTPError as exc:
        try:
            return json.load(exc)
        except ValueError:
            return {"ok": False, "error": f"Tako 回了 {exc.code}"}
    except OSError:
        sys.exit("连不上 Tako：它可能刚退出或在重启，打开 Tako 再试。")


def who():
    """Who is handing it over, as the owner will see it on the panel."""
    if os.environ.get("CLAUDECODE"):
        return "Claude"
    if any(name.startswith("CODEX_") for name in os.environ):
        return "Codex"
    return "Agent"


def follow(job_id, wait, timeout):
    shown, began = 0, time.time()
    while True:
        state = call(f"/agent/job?id={job_id}")
        if not state.get("ok"):
            return state
        for step in state.get("steps", [])[shown:]:
            print(f"· {step}", file=sys.stderr, flush=True)
        shown = len(state.get("steps", []))
        if state["state"] in ("done", "failed", "stopped") or not wait or time.time() - began > timeout:
            return state
        time.sleep(2)


def show(state, as_json):
    if as_json:
        print(json.dumps(state, ensure_ascii=False, indent=2))
    elif not state.get("ok"):
        print(state.get("error") or "没成功", file=sys.stderr)
    else:
        if state.get("answer"):
            print(state["answer"])
        for key in ("error", "trouble", "note"):
            if state.get(key):
                print(f"[{key}] {state[key]}", file=sys.stderr)
        for card in state.get("cards", []):
            print(f"[等主人确认] {card}", file=sys.stderr)
        if state["state"] == "stopped":
            print(f"[已停] id={state['id']}", file=sys.stderr)
        if state["state"] not in ("done", "failed", "stopped"):
            print(f"[还在做] id={state['id']} 状态={state['state']}，用 `tako job {state['id']} --wait` 接着等", file=sys.stderr)
    if not state.get("ok"):
        return 1
    return {"done": 0, "failed": 1, "stopped": 4}.get(state["state"], 3)


def main():
    parser = argparse.ArgumentParser(prog="tako", description="把一件事交给 Tako，在某个窗口上做完。")
    parser.add_argument("--json", action="store_true", help="原样输出 JSON")
    sub = parser.add_subparsers(dest="command", required=True)
    ask = sub.add_parser("ask", help="交一件事给 Tako")
    ask.add_argument("text", help="要 Tako 做的事，像主人在面板里说话那样写")
    ask.add_argument("--window", "-w", help="在哪个窗口做：应用名、标题里的字或窗口号；不写就是 Tako 现在粘着的窗口")
    ask.add_argument("--file", "-f", action="append", default=[], help="交给它的文件，可以写多次")
    ask.add_argument("--from", dest="source", default=who(), help="面板上显示是谁转来的")
    ask.add_argument("--no-wait", action="store_true", help="交了就回，只给 id")
    ask.add_argument("--timeout", type=int, default=900, help="最多等几秒，默认 900")
    job = sub.add_parser("job", help="看一件事做得怎样")
    job.add_argument("id")
    job.add_argument("--wait", action="store_true")
    job.add_argument("--timeout", type=int, default=900)
    stop = sub.add_parser("stop", help="停掉一件事")
    stop.add_argument("id")
    sub.add_parser("windows", help="列出开着的窗口")
    args = parser.parse_args()

    if args.command == "windows":
        found = call("/agent/windows")
        if args.json or not found.get("ok", True):
            print(json.dumps(found, ensure_ascii=False, indent=2))
        else:
            for row in found.get("windows", []):
                print("\t".join(str(row.get(k, "")) for k in ("id", "app", "title")))
        return 0
    if args.command == "ask":
        started = call("/agent/ask", {"text": args.text, "window": args.window, "files": [str(Path(f).resolve()) for f in args.file], "from": args.source})
        if not started.get("ok"):
            return show(started, args.json)
        print(f"[已交给 Tako] id={started['id']} 窗口={started['window']}", file=sys.stderr, flush=True)
        return show(follow(started["id"], not args.no_wait, args.timeout), args.json)
    if args.command == "job":
        return show(follow(args.id, args.wait, args.timeout), args.json)
    if args.command == "stop":
        return show(call("/agent/stop", {"id": args.id}, timeout=30), args.json)
    return 1


if __name__ == "__main__":
    sys.exit(main())
