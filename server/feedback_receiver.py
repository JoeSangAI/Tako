"""Where Tako's anonymous reports land. Accepts two fixed shapes, keeps no address and no exact time, serves nothing back.

    python3 feedback_receiver.py serve /data/feedback.db
    python3 feedback_receiver.py summary /data/feedback.db [days]
"""
import collections
import datetime as dt
import json
import re
import sqlite3
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BODY = 16_000
MAX_ROWS_A_DAY = 20_000
VERSION = re.compile(r"\d+(\.\d+){0,3}")
# Counter names are fixed words from the app, never free text: letters, digits, Chinese, and a few separators.
NAME = re.compile(r"[\w.:|\-一-鿿]{1,120}")
KINDS = {"bug", "rough", "wish", "need"}


def valid(packet):
    """The whole of what this service will ever store. Anything with an extra key is refused, not trimmed."""
    if not isinstance(packet, dict) or not VERSION.fullmatch(str(packet.get("version"))) or not VERSION.fullmatch(str(packet.get("macos"))):
        return False
    if packet.get("type") == "say":
        return (set(packet) == {"type", "kind", "text", "version", "macos"} and packet["kind"] in KINDS
                and isinstance(packet["text"], str) and 0 < len(packet["text"]) <= 1000)
    if packet.get("type") == "stats" and set(packet) == {"type", "version", "macos", "counts", "seconds", "errors", "tags"}:
        for key in ("counts", "seconds", "errors", "tags"):
            table = packet[key]
            if not isinstance(table, dict) or len(table) > 200:
                return False
            if not all(isinstance(name, str) and NAME.fullmatch(name) and type(value) in (int, float) and 0 <= value < 1e7 for name, value in table.items()):
                return False
        return True
    return False


def opened(path):
    db = sqlite3.connect(path, timeout=5)
    db.execute("create table if not exists reports (day text not null, type text not null, version text not null, macos text not null, body text not null)")
    db.execute("create index if not exists reports_day on reports (day)")
    return db


def today():
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")


def store(path, packet):
    """False when today is already implausibly full: a public write-only door shouldn't be able to fill the disk."""
    db = opened(path)
    try:
        with db:
            if db.execute("select count(*) from reports where day = ?", (today(),)).fetchone()[0] >= MAX_ROWS_A_DAY:
                return False
            db.execute("insert into reports values (?, ?, ?, ?, ?)", (today(), packet["type"], packet["version"], packet["macos"], json.dumps(packet, ensure_ascii=False)))
        return True
    finally:
        db.close()


def serve(path, port=8000):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass  # No addresses, no times.

        def answer(self, code):
            self.send_response(code)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_GET(self):
            self.answer(204 if self.path == "/health" else 404)

        def do_POST(self):
            length = self.headers.get("Content-Length", "")
            if self.path != "/v1/report" or not length.isdigit() or int(length) > MAX_BODY:
                return self.answer(400)
            try:
                packet = json.loads(self.rfile.read(int(length)))
            except ValueError:
                return self.answer(400)
            if not valid(packet):
                return self.answer(400)
            self.answer(204 if store(path, packet) else 503)

    opened(path).close()
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()


def summary(path, days=30):
    since = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)).strftime("%Y-%m-%d")
    db = opened(path)
    rows = db.execute("select type, version, macos, body from reports where day >= ?", (since,)).fetchall()
    db.close()
    totals = {key: collections.Counter() for key in ("counts", "errors", "tags")}
    seconds, said, versions = collections.Counter(), collections.defaultdict(list), collections.Counter()
    for kind, version, macos, body in rows:
        packet = json.loads(body)
        versions[f"Tako {version} / macOS {macos}"] += 1
        if kind == "say":
            said[packet["kind"]].append(packet["text"])
            continue
        for key, total in totals.items():
            total.update(packet[key])
        seconds.update(packet["seconds"])
    print(f"最近 {days} 天，{len(rows)} 条上报")
    for title, table in (("版本", versions), ("任务（应用｜任务｜结果）", totals["tags"]), ("错误", totals["errors"]), ("用量", totals["counts"])):
        print(f"\n## {title}")
        for name, count in table.most_common(40):
            spent = f"，平均 {seconds[name] / count:.1f} 秒" if seconds.get(name) else ""
            print(f"{count:>5}  {name}{spent}")
    for kind, title in (("need", "想用 Tako 解决的事"), ("wish", "想用的场景"), ("rough", "不好用"), ("bug", "出了问题")):
        if said[kind]:
            print(f"\n## {title}")
            for text in said[kind]:
                print(f"- {text}")


if __name__ == "__main__":
    command, database = sys.argv[1], sys.argv[2]
    if command == "serve":
        serve(database)
    elif command == "summary":
        summary(database, int(sys.argv[3]) if len(sys.argv) > 3 else 30)
