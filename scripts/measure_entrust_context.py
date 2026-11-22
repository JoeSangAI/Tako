#!/usr/bin/env python3
"""Count a fake-Codex thread's instructions and tools against a Git baseline; no model call."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
baseline = sys.argv[1] if len(sys.argv) > 1 else "main"
with tempfile.TemporaryDirectory(prefix="tako-context-") as folder:
    home = Path(folder)
    (home / "config.json").write_text(json.dumps({"name": "主人", "output_root": str(home / "output")}))
    os.environ["TAKO_HOME"] = str(home)
    sys.path.insert(0, str(ROOT / "Sources/brain"))
    import prompts
    previous = home / "baseline_prompts.py"
    previous.write_bytes(subprocess.check_output(["git", "show", f"{baseline}:Sources/brain/prompts.py"], cwd=ROOT))
    spec = importlib.util.spec_from_file_location("baseline_prompts", previous)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    for label, version in ((baseline, module), ("current", prompts)):
        env = {**os.environ, "FAKE_CODEX_HOME": str(home)}
        p = subprocess.Popen([sys.executable, "-B", str(ROOT / "tests/fake_codex.py"), "app-server"],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)
        def send(value):
            p.stdin.write(json.dumps(value, ensure_ascii=False) + "\n")
            p.stdin.flush()
        payload = {"developerInstructions": version.PROMPT, "dynamicTools": version.TOOLS}
        send({"id": 1, "method": "thread/start", "params": payload})
        thread = json.loads(p.stdout.readline())["result"]["thread"]["id"]
        words = "一分钟后提醒我喝水"
        if any(tool["name"] == "entrust" for tool in version.TOOLS):
            steps = [{"call": "entrust", "args": {"action": "keep", "quote": words, "text": "该喝水了", "after": {"amount": 1, "unit": "minutes"}}}, {"say": "知道了。"}]
            words += "@@" + json.dumps(steps, ensure_ascii=False) + "@@"
        send({"id": 2, "method": "turn/start", "params": {"threadId": thread, "input": [{"type": "text", "text": words}]}})
        calls = 0
        while True:
            message = json.loads(p.stdout.readline())
            if message.get("method") == "item/tool/call":
                calls += 1
                send({"id": message["id"], "result": {"success": True, "contentItems": [{"type": "inputText", "text": "已记录"}]}})
            if message.get("method") == "turn/completed":
                break
        p.stdin.close()
        p.wait(timeout=5)
        tools = json.dumps(version.TOOLS, ensure_ascii=False, separators=(",", ":"))
        print(f"{label}: instructions={len(version.PROMPT)} chars, tools={len(tools)} chars, count={len(version.TOOLS)}, fake_calls={calls}")
