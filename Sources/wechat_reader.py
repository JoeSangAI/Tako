"""Read one WeChat conversation incrementally, for owners who already have a local decrypted-key setup.

Optional and off by default: Tako never captures keys itself. It only turns on when config.json names a
wxexport-compatible folder (keys.json, work/account-state.json, work/namemap.json and the wxexport package).
Without one, Tako sees WeChat the way it sees any window: by looking at it.

Read-only. Plaintext stays in memory: each read decrypts the active shard, overlays
committed WAL frames, and deserializes it into an in-memory SQLite handle.
"""
from __future__ import annotations

import hashlib
import json
import re
import sqlite3
import struct
import sys
from pathlib import Path

WXEXPORT = None
AES = PAGE = SQLITE_HDR = decrypt_db = mac_key = _bdecode = _render = None


def enable(folder):
    """True when the configured folder really can be read; anything less leaves WeChat to the window."""
    global WXEXPORT, AES, PAGE, SQLITE_HDR, decrypt_db, mac_key, _bdecode, _render
    root = Path(folder).expanduser() if isinstance(folder, str) and folder else None
    if not root or not (root / "keys.json").is_file():
        return False
    sys.path.insert(0, str(root))
    try:
        from Crypto.Cipher import AES as cipher
        from wxexport.crypto import PAGE as page, SQLITE_HDR as header, decrypt_db as whole, mac_key as mac
        from wxexport.export import _bdecode as decode, _render as render
    except ImportError:
        return False
    AES, PAGE, SQLITE_HDR, decrypt_db, mac_key, _bdecode, _render = cipher, page, header, whole, mac, decode, render
    WXEXPORT = root
    return True


SHARD = "message/message_10.db"
SESSION = "session/session.db"
WAL_HEADER, FRAME_HEADER = 32, 24


def account():
    state = json.loads((WXEXPORT / "work/account-state.json").read_text())
    return Path(state["account_dir"]), state["wxid"]


def _decrypt_page(raw, pgno, key, reserve):
    iv = raw[PAGE - reserve:PAGE - reserve + 16]
    if pgno == 1:
        return SQLITE_HDR + AES.new(key, AES.MODE_CBC, iv).decrypt(raw[16:PAGE - reserve]) + b"\x00" * reserve
    return AES.new(key, AES.MODE_CBC, iv).decrypt(raw[:PAGE - reserve]) + b"\x00" * reserve


def _overlay_wal(plain, wal, key, reserve, salt):
    """Apply committed frames of the current WAL generation; returns frame counts."""
    stats = {"frames": 0, "applied": 0, "bad_mac": 0}
    if len(wal) < WAL_HEADER:
        return plain, stats
    salts = wal[16:24]
    mk = mac_key(key, salt)
    import hmac
    pending, committed, size = {}, {}, None
    step = FRAME_HEADER + PAGE
    for at in range(WAL_HEADER, len(wal) - step + 1, step):
        head = wal[at:at + FRAME_HEADER]
        if head[8:16] != salts:
            break
        pgno, after = struct.unpack(">II", head[:8])
        raw = wal[at + FRAME_HEADER:at + step]
        start = 16 if pgno == 1 else 0
        want = hmac.new(mk, raw[start:PAGE - reserve + 16] + struct.pack("<I", pgno), hashlib.sha512).digest()
        stats["frames"] += 1
        if want != raw[PAGE - reserve + 16:PAGE - reserve + 80]:
            stats["bad_mac"] += 1
            break
        pending[pgno] = raw
        if after:
            committed.update(pending)
            pending, size = {}, after
    if size:
        plain = bytearray(plain[:size * PAGE]) + bytearray(max(0, size * PAGE - len(plain)))
        for pgno, raw in committed.items():
            plain[(pgno - 1) * PAGE:pgno * PAGE] = _decrypt_page(raw, pgno, key, reserve)
            stats["applied"] += 1
    return bytes(plain), stats


def open_shard(use_wal=True, shard=SHARD):
    root, _ = account()
    info = json.loads((WXEXPORT / "keys.json").read_text())[shard]
    key, reserve = bytes.fromhex(info["enc_key"]), info.get("reserve", 80)
    path = root / "db_storage" / shard
    data = path.read_bytes()
    plain, stats = decrypt_db(data, key, reserve), {}
    wal = Path(str(path) + "-wal")
    if use_wal and wal.is_file():
        plain, stats = _overlay_wal(plain, wal.read_bytes(), key, reserve, data[:16])
    # A deserialized image must not claim WAL mode: there is no -wal beside it.
    plain = plain[:18] + b"\x01\x01" + plain[20:]
    con = sqlite3.connect(":memory:")
    con.deserialize(plain)
    return con, stats


def session_mark(username):
    """What the session list says about a chat's newest message. A tenth of a second, where the message shard takes seconds."""
    con, _ = open_shard(shard=SESSION)
    try:
        return con.execute("SELECT last_timestamp, sort_timestamp, last_msg_locald_id FROM SessionTable WHERE username = ?", (username,)).fetchone()
    finally:
        con.close()


def my_name():
    _, me = account()
    name = json.loads((WXEXPORT / "work/namemap.json").read_text())["names"].get(me)
    return name if isinstance(name, str) else ""


def find_chats(query):
    names = json.loads((WXEXPORT / "work/namemap.json").read_text())["names"]
    hits = [{"username": u, "name": n} for u, n in names.items() if isinstance(n, str) and query in n]
    # The exact name first, then names that start with it: callers keep only the top few, and "家" alone hits hundreds.
    return sorted(hits, key=lambda chat: (chat["name"].strip() != query, not chat["name"].strip().startswith(query)))


def _table(username):
    return "Msg_" + hashlib.md5(username.encode()).hexdigest()


def read_messages(con, username, after_id=0, limit=200):
    """Newest messages after a local_id, oldest first, with sender resolved."""
    _, me = account()
    names = json.loads((WXEXPORT / "work/namemap.json").read_text())["names"]
    senders = dict(con.execute("SELECT rowid, user_name FROM Name2Id"))
    try:
        rows = con.execute(
            f'SELECT local_id, local_type, real_sender_id, create_time, message_content FROM "{_table(username)}" '
            "WHERE local_id > ? ORDER BY local_id DESC LIMIT ?", (after_id, limit)).fetchall()
    except sqlite3.OperationalError as error:
        if "no such table" in str(error):
            return None
        raise
    out = []
    for local_id, local_type, sender, created, content in reversed(rows):
        text = _bdecode(content)
        who = senders.get(sender, "")
        if not who:
            match = re.match(r"^([0-9A-Za-z_\-@.]+):\n", text)
            who = match.group(1) if match else ""
        out.append({"id": local_id, "time": created, "is_me": who == me,
                    "who": "我" if who == me else names.get(who, who or "对方"),
                    "text": _render((local_type or 0) & 0xFFFFFFFF, text)})
    return out


if __name__ == "__main__":
    import time
    enable(sys.argv.pop(1))
    for use_wal in (False, True):
        started = time.time()
        con, stats = open_shard(use_wal)
        print("wal" if use_wal else "main", f"{time.time() - started:.2f}s", stats)
        for query in sys.argv[1:]:
            for chat in find_chats(query):
                rows = read_messages(con, chat["username"], limit=5)
                newest = rows[-1]["time"] if rows else None
                age = f"{(time.time() - newest) / 60:.1f}min" if newest else "-"
                print(" ", chat["username"][:6] + "…", chat["name"], None if rows is None else len(rows), "newest age", age)
        con.close()
