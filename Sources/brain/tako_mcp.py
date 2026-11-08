"""Tako's tools as a stdio MCP server, for an office agent that is Tako's brain (`office.py`).

The agent starts this once per session. It knows nothing itself: every list and call goes back to the brain through a socket only the
owner can open, with the token that session was given, and the brain answers as it answers Codex. Standard library only.
"""
import json
import os
import socket
import sys
import threading

SOCKET, TOKEN = os.environ.get("TAKO_TOOLS_SOCKET", ""), os.environ.get("TAKO_TOOLS_TOKEN", "")
writing = threading.Lock()


def send(message):
    with writing:
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", **message}, ensure_ascii=False) + "\n")
        sys.stdout.flush()


def ask(question):
    """One question to the brain; a call can take as long as the owner takes to answer a card."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.connect(SOCKET)
        connection.sendall(json.dumps({"token": TOKEN, **question}, ensure_ascii=False).encode() + b"\n")
        received = bytearray()
        while not received.endswith(b"\n"):
            chunk = connection.recv(1 << 20)
            if not chunk:
                break
            received += chunk
    return json.loads(received or b"{}")


def call(ident, params):
    try:
        answer = ask({"op": "call", "tool": params.get("name"), "arguments": params.get("arguments") or {}})
    except (OSError, ValueError):
        answer = {"content": [{"type": "text", "text": "Tako 那边没有回应。"}], "isError": True}
    if "error" in answer:
        answer = {"content": [{"type": "text", "text": answer["error"]}], "isError": True}
    send({"id": ident, "result": answer})


def main():
    for line in sys.stdin:
        try:
            message = json.loads(line)
        except ValueError:
            continue
        method, ident, params = message.get("method"), message.get("id"), message.get("params") or {}
        if ident is None:
            continue  # notifications: nothing to say back
        if method == "initialize":
            send({"id": ident, "result": {"protocolVersion": params.get("protocolVersion") or "2025-06-18", "capabilities": {"tools": {}},
                                          "serverInfo": {"name": "tako", "version": "1"}}})
        elif method == "tools/list":
            try:
                tools = ask({"op": "list"}).get("tools") or []
            except (OSError, ValueError):
                tools = []
            send({"id": ident, "result": {"tools": tools}})
        elif method == "tools/call":
            threading.Thread(target=call, args=(ident, params), daemon=True).start()
        elif method == "ping":
            send({"id": ident, "result": {}})
        else:
            send({"id": ident, "error": {"code": -32601, "message": "not offered"}})


if __name__ == "__main__":
    main()
