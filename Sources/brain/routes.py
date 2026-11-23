"""The local HTTP doors: the panel and the app talk to the Python side through these, and every one needs the token.

The owner's other agents have doors of their own under /agent/, with a token of their own that opens nothing else (`agents.py`)."""
from __future__ import annotations

import base64
import contextlib
import json
import mimetypes
import os
import queue
import re
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import records
import wechat_reader as reader
from settings import DINGTALK, HAS_WECHAT, HERE, INBOX, RUNTIME

for _kind, _suffix in (("image/heic", ".heic"), ("image/heif", ".heif"), ("image/avif", ".avif"), ("image/webp", ".webp")):
    mimetypes.add_type(_kind, _suffix)


def serve(companion, token, port, agent_token=None):
    page = (HERE / "side.html").read_bytes().replace(b"TOKEN", token.encode())
    renderer = (HERE / "vendor" / "markdown-it.min.js").read_bytes()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass  # URLs carry chat queries; keep them out of logs.

        def reply(self, payload, kind="application/json; charset=utf-8", code=200):
            body = payload if isinstance(payload, bytes) else json.dumps(payload, ensure_ascii=False).encode()
            self.send_response(code)
            self.send_header("Content-Type", kind)
            self.send_header("Cache-Control", "no-store")
            # The panel fetches nothing from outside on its own: an image in an answer can't carry anything away.
            self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:")
            self.end_headers()
            self.wfile.write(body)

        def allowed(self, query):
            return secrets.compare_digest(query.get("t", [""])[0], token)

        def agent(self, url, body):
            """An agent hands over a job, asks how it is going, or stops it. Never a card: those wait for the owner."""
            if not agent_token or not secrets.compare_digest(self.headers.get("Authorization", ""), f"Bearer {agent_token}"):
                return self.reply({"error": "forbidden"}, code=403)
            query = parse_qs(url.query)
            try:
                if url.path == "/agent/entrust" and body is not None:
                    return self.reply(companion.submit(companion.agent_entrust(body)).result(timeout=40))
                if url.path == "/agent/entrustments":
                    return self.reply(companion.submit(companion.agent_entrustments(query.get("id", [""])[0])).result(timeout=10))
                if url.path == "/agent/unentrust" and body is not None:
                    return self.reply(companion.submit(companion.agent_unentrust(str(body.get("id") or ""), str(body.get("from") or "Agent"))).result(timeout=40))
                if url.path == "/agent/ask" and body is not None and str(body.get("text", "")).strip():
                    work = companion.agent_ask(str(body["text"]).strip(), str(body.get("window") or "") or None,
                                               [str(f) for f in body.get("files") or []], str(body.get("from") or "Agent")[:40])
                    return self.reply(companion.submit(work).result(timeout=15))
                if url.path == "/agent/job" and query.get("id"):
                    return self.reply(companion.agent_job(query["id"][0]))
                if url.path == "/agent/stop" and body is not None and body.get("id"):
                    return self.reply(companion.submit(companion.agent_stop(str(body["id"]))).result(timeout=15))
                if url.path == "/agent/history":
                    days = int(query.get("days", ["7"])[0] or 7)
                    return self.reply({"ok": True, **companion.history(query.get("find", [""])[0], days)})
                if url.path == "/agent/windows":
                    return self.reply(companion.submit(companion.native("windows", timeout=8)).result(timeout=10))
            except TimeoutError:
                return self.reply({"ok": False, "error": "Tako 那边没有回应，过一会儿再试"}, code=504)
            self.reply({"error": "bad_request"}, code=400)

        def do_GET(self):
            url = urlparse(self.path)
            query = parse_qs(url.query)
            if url.path.startswith("/agent/"):
                return self.agent(url, None)
            if not self.allowed(query):
                return self.reply({"error": "forbidden"}, code=403)
            if url.path == "/":
                return self.reply(page, "text/html; charset=utf-8")
            if url.path == "/state":
                return self.reply(companion.snapshot(int(query.get("after", ["0"])[0])))
            if url.path == "/chats":
                return self.reply(reader.find_chats(query.get("q", [""])[0])[:12] if HAS_WECHAT else [])
            if url.path == "/feedback":
                return self.reply(companion.feedback.panel())
            if url.path == "/setup":
                return self.reply(companion.setup.state())
            if url.path == "/history":
                return self.reply(companion.history(query.get("find", [""])[0]))
            if url.path == "/desktop/history":
                try:
                    return self.reply(records.conversation_before("desktop", float(query.get("before", ["0"])[0])))
                except (ValueError, OverflowError):
                    return self.reply({"day": "", "events": []})
            if url.path == "/markdown-it.js":
                return self.reply(renderer, "text/javascript; charset=utf-8")
            if url.path == "/file":
                path = str(Path(query.get("path", [""])[0]).expanduser())
                kind = mimetypes.guess_type(path)[0] or ""
                if not kind.startswith("image/") or not companion.shared(path) or not os.path.isfile(path):
                    return self.reply({"error": "forbidden"}, code=403)
                return self.reply(Path(path).read_bytes(), kind)
            if url.path == "/native/next":
                try:
                    command = companion.outbox.get(timeout=20)
                except queue.Empty:
                    return self.reply({})
                # Whoever asked has stopped waiting; a late click must not land on whatever is in front by then.
                return self.reply(command if command.pop("expires") > time.monotonic() else {})
            self.reply({"error": "not_found"}, code=404)

        def do_POST(self):
            url = urlparse(self.path)
            if url.path.startswith("/agent/"):
                try:
                    body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
                except ValueError:
                    body = {}
                return self.agent(url, body if isinstance(body, dict) else {})
            if not self.allowed(parse_qs(url.query)):
                return self.reply({"error": "forbidden"}, code=403)
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
            if url.path == "/native/arrival":
                watcher = getattr(companion, "_back_watch", None)
                if watcher is not None:
                    companion.loop.call_soon_threadsafe(watcher.notify)
                return self.reply({"ok": True})
            if url.path == "/desktop":
                companion.submit(companion.desktop()).result(timeout=10)
                return self.reply({"ok": True})
            if url.path == "/entrusted/look":
                return self.reply(companion.submit(companion.look_entrusted(str(body.get("id") or ""))).result(timeout=10))
            if url.path == "/entrusted/accept":
                return self.reply(companion.submit(companion.accept_asked(str(body.get("id") or ""))).result(timeout=40))
            if url.path in ("/ladder/next", "/ladder/seen", "/ladder/sources", "/ladder/memory"):
                return self.reply(companion.submit(companion.ladder_step(url.path.rsplit("/", 1)[1], body)).result(timeout=40))
            if url.path == "/conversation/open":
                return self.reply(companion.submit(companion.open_recorded_conversation(str(body.get("key") or ""))).result(timeout=10))
            if url.path in ("/entrusted/tick", "/entrusted/respond", "/entrusted/state"):
                async def hand_over():
                    if url.path == "/entrusted/respond":
                        identity, action = str(body.get("id") or ""), str(body.get("action") or "")
                        if action not in ("done", "later", "today", "ignored", "cancel", "restore"):
                            return {"ok": False}
                        ok = companion.entrusted.respond(identity, action)
                        # 稍后 says when it will come back before the hand goes in.
                        companion.hub_soon()
                        return {"ok": ok, **({"say": companion.entrusted.later_line(identity, action)} if ok and action in ("later", "today") else {})}
                    if url.path == "/entrusted/tick":
                        # An answer still showing in the speaking bubble (`replying`) comes first, like a job: the promise waits for it to go.
                        return companion.entrusted.tick({**body, "near": [*(body.get("near") or []), *companion.near_in_group()], "busy": bool(body.get("replying")) or any(j.status in ("thinking", "working") for j in companion.active)})
                    return companion.entrusted.native_state()
                return self.reply(companion.submit(hand_over()).result(timeout=10))
            points = [p for p in body.get("points") or [] if isinstance(p, dict)][:20]
            if url.path == "/ask" and (str(body.get("text", "")).strip() or body.get("files") or points):
                companion.ask(str(body.get("text", "")).strip() or ("看看这些文件。" if body.get("files") else "看看我指的这些。"),
                              [str(f) for f in body.get("files") or []], points)
                return self.reply({"ok": True})
            if url.path == "/stop":
                companion.submit(companion.stop())
                return self.reply({"ok": True})
            if url.path == "/decide" and body.get("id"):
                companion.decide(str(body["id"]), bool(body.get("accepted")))
                return self.reply({"ok": True})
            if url.path == "/fill":
                if not companion.window and not body.get("window") and not body.get("chat"):
                    return self.reply({"ok": False, "error": "这段对话没有窗口，先告诉 Tako 要填到哪个应用或聊天。"})
                if body.get("gen") not in (None, companion.generation):
                    return self.reply({"ok": False, "error": "刚切换了窗口或对话，这份草稿不是写给现在这里的，没有填"})
                future = companion.submit(companion.fill(str(body.get("text", "")), [str(f) for f in body.get("files") or []],
                                                         body.get("window"), body.get("chat")))
                try:
                    return self.reply(future.result(timeout=60))
                except TimeoutError:
                    return self.reply({"ok": False, "error": "填入太久没有结果，先看一眼输入框再决定要不要重试"})
            if url.path == "/offer":
                # The owner dragged or picked these: the panel may show them while they decide whether to send them.
                companion.offered.update(str(path) for path in body.get("paths") or [])
                return self.reply({"ok": True})
            if url.path == "/upload" and len(str(body.get("data", ""))) > 40_000_000:
                return self.reply({"error": "too_large"}, code=413)
            if url.path == "/upload" and body.get("data"):
                INBOX.mkdir(parents=True, exist_ok=True)
                name = re.sub(r"[^\w.\u4e00-\u9fff-]+", "-", str(body.get("name") or "image.png"))[-60:]
                path = INBOX / f"{secrets.token_hex(4)}-{name}"
                path.write_bytes(base64.b64decode(body["data"]))
                return self.reply({"path": str(path)})
            if url.path == "/native/result" and body.get("id"):
                companion.native_done(str(body["id"]), body.get("result") or {})
                return self.reply({"ok": True})
            if url.path == "/stuck" and body.get("bundle"):
                companion.submit(companion.stick({k: str(body.get(k, "")) for k in ("app", "bundle", "title", "id")}))
                return self.reply({"ok": True})
            if url.path == "/folder" and body.get("path"):
                return self.reply(companion.move_folder(str(body["path"]), bool(body.get("move"))))
            if url.path == "/go" and body.get("key"):
                companion.submit(companion.going_to(str(body["key"]), str(body.get("window") or "")))
                return self.reply({"ok": True})
            if url.path == "/watching":
                companion.watching = bool(body.get("on"))
                if not companion.watching and companion.lecture:
                    companion.submit(companion._end_lecture("从窗口上下来了，课也不听了。笔记已经存好。"))
                return self.reply({"ok": True})
            if url.path == "/listen/piece":
                piece = str(body.get("path", ""))
                # Only the app's own pieces: this route deletes what it is given.
                if Path(piece).parent == RUNTIME / "listening" and piece.endswith(".f32"):
                    companion.loop.call_soon_threadsafe(companion.heard, piece)
                return self.reply({"ok": True})
            if url.path == "/listen/ended":
                companion.submit(companion._end_lecture(str(body.get("why") or "")))
                return self.reply({"ok": True})
            if url.path == "/listen/stop":
                companion.submit(companion._end_lecture("不听了。笔记已经存好。"))
                return self.reply({"ok": True})
            if url.path == "/feedback/choose":
                companion.feedback.choose(bool(body.get("on")))
                return self.reply(companion.feedback.panel())
            if url.path == "/setup/next":
                companion.setup.next_step()
                return self.reply(companion.setup.state())
            if url.path == "/setup/cancel":
                companion.setup.cancel()
                return self.reply(companion.setup.state())
            if url.path == "/setup/key":
                companion.setup.use_key(str(body.get("service") or ""), str(body.get("key") or ""), str(body.get("base_url") or ""), str(body.get("model") or ""))
                return self.reply(companion.setup.state())
            if url.path == "/setup/login":
                companion.setup.use_login()
                return self.reply(companion.setup.state())
            if url.path == "/setup/choose":
                companion.setup.choose()
                return self.reply(companion.setup.state())
            if url.path == "/setup/close":
                companion.setup.close()
                return self.reply(companion.setup.state())
            if url.path == "/setup/office":
                companion.setup.use_office(str(body.get("agent") or ""))
                return self.reply(companion.setup.state())
            if url.path == "/current":
                # Which chat a chat app shows: `looking` when it may be changing, then what was read. The reply comes once it is matched, with the answer,
                # so the app can redraw the panel at once and compare promises with the same chat (`Chats.open_now`).
                seq, began = body.get("seq"), time.monotonic()
                if (body.get("looking") and body.get("bundle")) or body.get("left"):
                    async def mark(bundle=str(body.get("bundle") or "")):
                        if body.get("left"):
                            companion.stop_looking(seq)  # The app went from the front before reading: nothing says the chat changed.
                        else:
                            companion.looking(bundle, seq)
                    work = companion.submit(mark())
                elif body.get("bundle") == DINGTALK and isinstance(body.get("chat"), str):
                    work = companion.submit(companion.follow_dingtalk(body["chat"][:80], seq))
                elif isinstance(body.get("titles"), list) and HAS_WECHAT:
                    work = companion.submit(companion.follow_header([str(t) for t in body["titles"]][:12], seq, body.get("settled", True) is not False))
                else:
                    return self.reply({"ok": True})
                with contextlib.suppress(Exception):
                    if work:
                        work.result(timeout=5)
                return self.reply({**companion.open_now(), "ms": int((time.monotonic() - began) * 1000)})
            if url.path == "/attach" and body.get("username") and HAS_WECHAT:
                chat = {"username": str(body["username"]), "name": str(body.get("name", ""))}
                companion.submit(companion.attach(chat))
                return self.reply({"ok": True})
            self.reply({"error": "bad_request"}, code=400)

    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server.server_address[1]
