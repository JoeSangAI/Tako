"""The local HTTP doors: the panel and the app talk to the Python side through these, and every one needs the token."""
from __future__ import annotations

import base64
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

import wechat_reader as reader
from settings import HAS_WECHAT, HERE, INBOX, RUNTIME

for _kind, _suffix in (("image/heic", ".heic"), ("image/heif", ".heif"), ("image/avif", ".avif"), ("image/webp", ".webp")):
    mimetypes.add_type(_kind, _suffix)


def serve(companion, token, port):
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

        def do_GET(self):
            url = urlparse(self.path)
            query = parse_qs(url.query)
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
                return self.reply(command if command.pop("expires") > time.time() else {})
            self.reply({"error": "not_found"}, code=404)

        def do_POST(self):
            url = urlparse(self.path)
            if not self.allowed(parse_qs(url.query)):
                return self.reply({"error": "forbidden"}, code=403)
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
            if url.path == "/ask" and (str(body.get("text", "")).strip() or body.get("files")):
                companion.ask(str(body.get("text", "")).strip() or "看看这些文件。", [str(f) for f in body.get("files") or []])
                return self.reply({"ok": True})
            if url.path == "/stop":
                companion.submit(companion.stop())
                return self.reply({"ok": True})
            if url.path == "/decide" and body.get("id"):
                companion.decide(str(body["id"]), bool(body.get("accepted")))
                return self.reply({"ok": True})
            if url.path == "/fill":
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
            if url.path == "/current" and isinstance(body.get("titles"), list):
                if not HAS_WECHAT:
                    return self.reply({"ok": True})
                companion.submit(companion.follow_header([str(t) for t in body["titles"]][:6]))
                return self.reply({"ok": True})
            if url.path == "/attach" and body.get("username") and HAS_WECHAT:
                chat = {"username": str(body["username"]), "name": str(body.get("name", ""))}
                companion.submit(companion.attach(chat))
                return self.reply({"ok": True})
            self.reply({"error": "bad_request"}, code=400)

    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server.server_address[1]
