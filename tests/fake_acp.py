"""Stands in for an office agent's command line (WorkBuddy's or Qoder's) in tests: ACP on stdio, no model, nothing leaves the Mac.

It starts the MCP servers a session is given, as the real ones do, so Tako's tools are reached the real way. What a turn does is written
in its own text as @@[...steps...]@@, as for `fake_codex.py`; with no steps it says 好的. Steps:
  {"say": text}                  the answer
  {"call": tool, "args": {...}}  a tool call through MCP; waits for the answer ("args_b64": the same, so no path shows in the owner's words)
  {"permission": tool}           asks the client whether a tool of its own may run, and notes what it was told
  {"search": query}              its own web search, as it reports one
  {"fail": message}              the turn fails with this error
  {"refuse": true}               turns the turn away and says nothing (WorkBuddy, when its login needs refreshing)
  {"hang": true}                 goes quiet until cancelled
  {"pause": seconds}             waits
  {"die": true}                  the process goes away
  {"usage": n}                   reports n tokens used
Everything is written to $FAKE_CODEX_LOG, one JSON object per line.
"""
import base64
import json
import os
import re
import subprocess
import sys
import threading
import time
import uuid

LOG = os.environ.get("FAKE_CODEX_LOG", "")
HOME = os.environ.get("FAKE_CODEX_HOME", "")
writing, noting = threading.Lock(), threading.Lock()
asked, cancels, servers = {}, {}, {}
args = sys.argv[1:]
PLAYS = args[args.index("--plays") + 1] if "--plays" in args else "workbuddy"
SYSTEM = args[args.index("--system-prompt") + 1] if "--system-prompt" in args else ""
KEEP = args[args.index("--keep") + 1:] if "--keep" in args else []
KEEP = [k for k in KEEP if not k.startswith("--")][:1]


def note(kind, **fields):
    if LOG:
        with noting, open(LOG, "a") as out:
            out.write(json.dumps({"kind": kind, "pid": os.getpid(), "agent": True, **fields}, ensure_ascii=False) + "\n")


def send(message):
    with writing:
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", **message}, ensure_ascii=False) + "\n")
        sys.stdout.flush()


def update(session, **fields):
    send({"method": "session/update", "params": {"sessionId": session, "update": fields}})


def ask(method, params):
    ident = str(uuid.uuid4())
    waiting = asked[ident] = {"done": threading.Event(), "reply": None}
    send({"id": ident, "method": method, "params": params})
    waiting["done"].wait()
    return waiting["reply"]


class Mcp:
    """One MCP server the session was given, started as the real agents start them."""

    def __init__(self, config):
        env = {**os.environ, **{e["name"]: e["value"] for e in config.get("env") or []}}
        self.process = subprocess.Popen([config["command"], *config.get("args", [])], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)
        self.lock, self.next = threading.Lock(), 0
        self.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "fake"}})
        self.tools = self.call("tools/list", {}).get("tools", [])

    def call(self, method, params):
        with self.lock:
            self.next += 1
            self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.next, "method": method, "params": params}) + "\n")
            self.process.stdin.flush()
            while True:
                reply = json.loads(self.process.stdout.readline())
                if reply.get("id") == self.next:
                    return reply.get("result") or {}


def run_prompt(ident, session, text):
    found = re.findall(r"@@(\[.*?\])@@", text.split("\n\n")[-1], re.S)
    steps = json.loads(found[-1]) if found else [{"say": "好的"}]
    stop = cancels[session] = threading.Event()
    for step in steps:
        if stop.is_set():
            break
        if "say" in step:
            for piece in (step["say"][: len(step["say"]) // 2], step["say"][len(step["say"]) // 2:]):
                update(session, sessionUpdate="agent_message_chunk", content={"type": "text", "text": piece})
        elif "call" in step:
            mcp = servers.get(session)
            if not mcp:
                note("no_tools", session=session)
                continue
            name = f"mcp__tako__{step['call']}"
            update(session, sessionUpdate="tool_call", toolCallId=str(uuid.uuid4()), title=f"{step['call']} (tako MCP Server)", kind="other",
                   _meta={"qoder": {"toolName": name}})
            arguments = json.loads(base64.b64decode(step["args_b64"])) if "args_b64" in step else step.get("args", {})
            result = mcp.call("tools/call", {"name": step["call"], "arguments": arguments})
            note("tool_reply", tool=step["call"], reply=result)
        elif "permission" in step:
            reply = ask("session/request_permission", {"sessionId": session, "toolCall": {"toolCallId": "x", "title": step["permission"], "_meta": {"codebuddy.ai/toolName": step["permission"]}},
                                                        "options": [{"optionId": "always", "kind": "allow_always", "name": "Always"}, {"optionId": "once", "kind": "allow_once", "name": "Allow"},
                                                                    {"optionId": "no", "kind": "reject_once", "name": "Reject"}]})
            note("permission", tool=step["permission"], reply=reply)
        elif "search" in step:
            update(session, sessionUpdate="tool_call", toolCallId=str(uuid.uuid4()), title="WebSearch", kind="search", rawInput={"query": step["search"]},
                   _meta={"codebuddy.ai/toolName": "WebSearch"})
        elif "fail" in step:
            cancels.pop(session, None)
            return send({"id": ident, "error": {"code": -32000, "message": step["fail"]}})
        elif "refuse" in step:
            cancels.pop(session, None)
            return send({"id": ident, "result": {"stopReason": "refusal"}})
        elif "hang" in step:
            stop.wait()
        elif "pause" in step:
            stop.wait(step["pause"])
        elif "die" in step:
            os._exit(1)
        elif "usage" in step:
            update(session, sessionUpdate="usage_update", used=step["usage"], size=200000)
    cancels.pop(session, None)
    send({"id": ident, "result": {"stopReason": "cancelled" if stop.is_set() else "end_turn"}})


def handle(message):
    method, params, ident = message.get("method"), message.get("params") or {}, message.get("id")
    note("request", method=method, params={k: v for k, v in params.items() if k != "prompt"} if method != "session/prompt" else
         {"sessionId": params.get("sessionId"), "text": "".join(p.get("text", "") for p in params.get("prompt") or []),
          "images": sum(p.get("type") == "image" for p in params.get("prompt") or [])})
    if method == "initialize":
        sessions = {"delete": {}, "close": {}} if PLAYS != "workbuddy" else {}
        send({"id": ident, "result": {"protocolVersion": 1, "agentCapabilities": {"loadSession": True, "sessionCapabilities": sessions, "promptCapabilities": {"image": True}}}})
    elif method == "session/new":
        if HOME and os.path.exists(os.path.join(HOME, "agent_logged_out")):
            return send({"id": ident, "error": {"code": -32000, "message": "Authentication required: Authentication is required."}})
        session = str(uuid.uuid4())
        for config in params.get("mcpServers") or []:
            servers[session] = Mcp(config)
            note("tools", session=session, names=[t["name"] for t in servers[session].tools])
        send({"id": ident, "result": {"sessionId": session}})
    elif method == "session/prompt":
        text = "".join(p.get("text", "") for p in params.get("prompt") or [])
        threading.Thread(target=run_prompt, args=(ident, params["sessionId"], text), daemon=True).start()
    elif method == "session/cancel":
        stop = cancels.get(params.get("sessionId"))
        if stop:
            stop.set()
    elif method in ("session/delete", "session/close"):
        server = servers.pop(params.get("sessionId"), None)
        if server:
            server.process.kill()
        send({"id": ident, "result": {}})
    elif ident is not None:
        send({"id": ident, "error": {"code": -32601, "message": "unknown"}})


def main():
    note("started", plays=PLAYS, keep=KEEP, system=SYSTEM[:200], args=[a for a in args if a != SYSTEM])
    for line in sys.stdin:
        message = json.loads(line)
        if "method" in message:
            threading.Thread(target=handle, args=(message,), daemon=True).start()
        elif message.get("id") in asked:
            waiting = asked.pop(message["id"])
            waiting["reply"] = message.get("result") if "error" not in message else {"rpc_error": message["error"]}
            waiting["done"].set()


if __name__ == "__main__":
    main()
