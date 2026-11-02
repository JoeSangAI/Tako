"""Stands in for `codex` in tests: the same app-server messages, no model, nothing leaves the Mac.

What a turn does is written in its own text as @@[...steps...]@@; with no steps it just says 好的. Steps:
  {"say": text}                 the final answer
  {"call": tool, "args": {...}} a tool call, the way the real server asks for one; waits for the answer
  {"fail": {message, codexErrorInfo}}   the turn fails
  {"hang": true}                goes quiet until interrupted
  {"hear": true}                waits for the owner's next words through turn/steer, then answers with them
  {"retry": n}                  n failed uploads, each announced as an error it will retry
  {"pause": seconds}            waits, with nothing to report
  {"every_turn": true}          first step only: the rest also runs for every later turn that has no steps of its own
  {"die": true}                 the process goes away
  {"usage": n}                  reports n input tokens
Everything received is written to $FAKE_CODEX_LOG, one JSON object per line.
"""
import json
import os
import re
import sys
import threading
import time
import uuid

HOME = os.environ.get("FAKE_CODEX_HOME", "")
LOG = os.environ.get("FAKE_CODEX_LOG", "")
writing, noting = threading.Lock(), threading.Lock()
answers, interrupts, loaded = {}, {}, set()
active, steered = set(), {}


def note(kind, **fields):
    if LOG:
        with noting, open(LOG, "a") as out:
            out.write(json.dumps({"kind": kind, "pid": os.getpid(), **fields}, ensure_ascii=False) + "\n")


def send(message):
    with writing:
        sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")
        sys.stdout.flush()


def event(method, **params):
    send({"method": method, "params": params})


def ask(request_id, method, **params):
    waiting = answers[request_id] = {"done": threading.Event(), "reply": None}
    send({"id": request_id, "method": method, "params": params})
    waiting["done"].wait()
    return waiting["reply"]


every_turn = []


def finish(thread, turn, status="completed", error=None):
    active.discard(turn)
    event("turn/completed", threadId=thread, turn={"id": turn, "status": status, "error": error, "items": []})


def run_turn(thread, turn, text):
    found = re.findall(r"@@(\[.*?\])@@", text.split("\n\n")[-1], re.S)  # Only the sentence itself: a recap may quote earlier ones.
    steps = json.loads(found[-1]) if found else list(every_turn) or [{"say": "好的"}]
    if steps and steps[0].get("every_turn"):  # A model that does the same thing whatever it is told next.
        every_turn[:] = steps = steps[1:]
    stop = interrupts[turn] = threading.Event()
    active.add(turn)
    event("turn/started", threadId=thread, turn={"id": turn, "status": "inProgress", "items": []})
    for step in steps:
        if stop.is_set():
            break
        if "say" in step:
            item = str(uuid.uuid4())
            event("item/agentMessage/delta", threadId=thread, turnId=turn, itemId=item, delta=step["say"])
            event("item/completed", threadId=thread, turnId=turn, item={"type": "agentMessage", "id": item, "text": step["say"]})
        elif "call" in step:
            item, call = str(uuid.uuid4()), str(uuid.uuid4())
            event("item/started", threadId=thread, turnId=turn, item={"type": "dynamicToolCall", "id": item, "tool": step["call"], "arguments": step.get("args", {})})
            reply = {}

            def call_tool():
                reply.update(ask(call, "item/tool/call", threadId=thread, turnId=turn, callId=call, tool=step["call"], arguments=step.get("args", {})))
            asking = threading.Thread(target=call_tool, daemon=True)
            asking.start()
            while asking.is_alive() and not stop.is_set():
                asking.join(0.02)
            note("tool_reply", tool=step["call"], reply=reply, abandoned=stop.is_set())
            event("item/completed", threadId=thread, turnId=turn, item={"type": "dynamicToolCall", "id": item, "tool": step["call"]})
        elif "fail" in step:
            return finish(thread, turn, "failed", step["fail"])
        elif "hang" in step:
            stop.wait()
        elif "hear" in step:
            while turn not in steered and not stop.is_set():
                time.sleep(0.01)
            if turn in steered:
                item = str(uuid.uuid4())
                event("item/completed", threadId=thread, turnId=turn, item={"type": "agentMessage", "id": item, "text": "听到了：" + steered[turn]})
        elif "retry" in step:
            for attempt in range(step["retry"]):
                event("error", threadId=thread, turnId=turn, willRetry=True, error={"message": f"Reconnecting... {attempt + 1}/5", "codexErrorInfo": None})
        elif "pause" in step:
            stop.wait(step["pause"])
        elif "die" in step:
            os._exit(1)
        elif "usage" in step:
            event("thread/tokenUsage/updated", threadId=thread, turnId=turn, tokenUsage={"last": {"inputTokens": step["usage"]}, "total": {"totalTokens": step["usage"]}})
    finish(thread, turn, "interrupted" if stop.is_set() else "completed")


def handle(message):
    method, params, request_id = message.get("method"), message.get("params") or {}, message.get("id")
    note("request", method=method, params=params)
    if method == "initialize":
        note("clock", tz=os.environ.get("TZ"))
        send({"id": request_id, "result": {"userAgent": "fake"}})
    elif method == "thread/start":
        thread = str(uuid.uuid4())
        loaded.add(thread)
        send({"id": request_id, "result": {"thread": {"id": thread}}})
    elif method == "thread/unsubscribe":
        loaded.discard(params.get("threadId"))
        note("loaded", count=len(loaded))
        send({"id": request_id, "result": {"status": "unsubscribed"}})
    elif method == "turn/start":
        forgotten = os.path.join(HOME, "forget")
        if os.path.exists(forgotten):  # The server lost this thread, as after its own restart.
            with open(forgotten) as file:
                loaded.discard(file.read().strip())
            os.remove(forgotten)
        if params.get("threadId") not in loaded:
            return send({"id": request_id, "error": {"code": -32600, "message": "thread not found"}})
        turn = str(uuid.uuid4())
        send({"id": request_id, "result": {"turn": {"id": turn, "status": "inProgress", "items": []}}})
        text = "".join(part.get("text", "") for part in params.get("input") or [])
        threading.Thread(target=run_turn, args=(params["threadId"], turn, text), daemon=True).start()
    elif method == "turn/interrupt":
        stop = interrupts.get(params.get("turnId"))
        if stop:
            stop.set()
        send({"id": request_id, "result": {}})
    elif method == "turn/steer":
        if params.get("expectedTurnId") not in active:
            return send({"id": request_id, "error": {"code": -32600, "message": "no active turn to steer"}})
        steered[params["expectedTurnId"]] = "".join(part.get("text", "") for part in params.get("input") or [])
        send({"id": request_id, "result": {"turnId": params["expectedTurnId"]}})
    elif method == "thread/compact/start":
        marker = os.path.join(HOME, "compact_fails")
        send({"id": request_id, "error": {"code": -32000, "message": "cannot compact"}} if os.path.exists(marker) else {"id": request_id, "result": {}})
        if os.path.exists(marker):
            return
        turn = str(uuid.uuid4())
        if os.path.exists(os.path.join(HOME, "compact_cant_upload")):  # A summary has to send the whole thread too.
            stop = interrupts[turn] = threading.Event()
            event("turn/started", threadId=params["threadId"], turn={"id": turn, "status": "inProgress", "items": []})
            event("error", threadId=params["threadId"], turnId=turn, willRetry=True, error={"message": "Reconnecting... 1/5", "codexErrorInfo": None})
            stop.wait()
        finish(params["threadId"], turn)
    elif request_id is not None:
        send({"id": request_id, "result": {}})


def main():
    if sys.argv[1:3] == ["login", "status"]:
        sys.exit(1 if os.path.exists(os.path.join(HOME, "logged_out")) else 0)
    if sys.argv[1:3] == ["app-server", "--help"]:
        print("--listen <URL>")
        sys.exit(0)
    if sys.argv[1:2] != ["app-server"]:
        sys.exit(0)
    note("started")
    for line in sys.stdin:
        message = json.loads(line)
        if "method" in message:
            threading.Thread(target=handle, args=(message,), daemon=True).start()
        elif message.get("id") in answers:
            waiting = answers.pop(message["id"])
            waiting["reply"] = message.get("result") if "error" not in message else {"rpc_error": message["error"]}
            waiting["done"].set()
    time.sleep(0.05)


if __name__ == "__main__":
    main()
