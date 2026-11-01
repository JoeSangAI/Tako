"""The whole Python side, running for real: its HTTP routes on one end, a stand-in for Codex on the other, and this file playing the app.

Each test is a thing an owner would see. No model, no network, no real window; everything lives in a temporary TAKO_HOME.
Run: python3 tests/test_turns.py
"""
import asyncio
import json
import os
import pathlib
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
SERVER = ROOT / "Sources/brain/tako_server.py"


def steps(*items):
    return "@@" + json.dumps(list(items), ensure_ascii=False) + "@@"


class Tako:
    """A running server with a temporary home. `native` answers for the app side, by command name."""

    def __init__(self, config=None):
        self.home = pathlib.Path(tempfile.mkdtemp(prefix="tako-test-"))
        self.output = self.home / "works"
        self.config = {"name": "Alex", "timezone": "Asia/Shanghai", "output_root": str(self.output), **(config or {})}
        (self.home / "config.json").write_text(json.dumps(self.config))
        (self.home / "bin").mkdir()
        self.log = self.home / "codex.log"
        codex = self.home / "bin/codex"
        codex.write_text(f'#!/bin/sh\nexec "{sys.executable}" -B "{ROOT / "tests/fake_codex.py"}" "$@"\n')
        codex.chmod(codex.stat().st_mode | stat.S_IEXEC)
        self.native = {"resolve": lambda c: {"ok": True, "id": 1, "app": "Keynote", "bundle": "com.apple.iWork.Keynote", "title": "稿子", "stuck": True},
                       "beginSteps": lambda c: {"ok": True}, "endSteps": lambda c: {"ok": True}, "look": lambda c: {"ok": True, "title": "稿子", "elements": ""},
                       "step": lambda c: {"ok": True, "did": "点了"}, "windows": lambda c: {"ok": True, "windows": []}, "fill": lambda c: {"ok": True, "message": "已填入"}}
        self.commands = []
        environment = {**os.environ, "TAKO_HOME": str(self.home), "PATH": f"{self.home / 'bin'}{os.pathsep}{os.environ['PATH']}",
                       "FAKE_CODEX_LOG": str(self.log), "FAKE_CODEX_HOME": str(self.home), "PYTHONDONTWRITEBYTECODE": "1"}
        self.errors = open(self.home / "server.err", "w")
        self.process = subprocess.Popen([sys.executable, "-B", str(SERVER), "--port", "0"], stdout=subprocess.PIPE, stderr=self.errors, text=True, env=environment)
        self.url = self.process.stdout.readline().strip()
        self.base, self.token = self.url.split("/?t=")
        self.alive = True
        threading.Thread(target=self._play_the_app, daemon=True).start()

    def close(self):
        self.alive = False
        self.process.terminate()
        self.process.wait(5)
        self.process.stdout.close()
        self.errors.close()
        shutil.rmtree(self.home, ignore_errors=True)

    def call(self, path, body=None, timeout=10):
        request = urllib.request.Request(f"{self.base}{path}{'&' if '?' in path else '?'}t={self.token}", data=None if body is None else json.dumps(body).encode(), method="GET" if body is None else "POST")
        with urllib.request.urlopen(request, timeout=timeout) as reply:
            return json.load(reply)

    def _play_the_app(self):
        while self.alive:
            try:
                command = self.call("/native/next", timeout=25)
            except (OSError, ValueError):
                time.sleep(0.05)
                continue
            if command.get("id"):
                self.commands.append(command)
                threading.Thread(target=self._answer, args=(command,), daemon=True).start()

    def _answer(self, command):
        handler = self.native.get(command["command"], lambda c: {"ok": True})
        try:
            self.call("/native/result", {"id": command["id"], "result": handler(command)})
        except OSError:
            pass

    def stick(self, app="Keynote", bundle="com.apple.iWork.Keynote", title="稿子", window="1"):
        self.call("/stuck", {"app": app, "bundle": bundle, "title": title, "id": window})
        self.until(lambda s: s["app"] == app, "stuck on")

    def state(self):
        return self.call("/state")

    def ask(self, text):
        self.call("/ask", {"text": text})

    def until(self, wanted, what="", timeout=8):
        deadline = time.time() + timeout
        while time.time() < deadline:
            seen = self.state()
            if wanted(seen):
                return seen
            time.sleep(0.03)
        raise AssertionError(f"never happened: {what}\nstate: {json.dumps(self.state(), ensure_ascii=False)[:600]}\nserver: {(self.home / 'server.err').read_text()[-800:]}")

    def said(self, seen=None):
        return [event["text"] for event in (seen or self.state())["events"] if event["role"] == "tako"]

    def idle(self, timeout=8):
        return self.until(lambda s: not s["busy"], "the turn ended", timeout)

    def codex(self, kind=None):
        if not self.log.exists():
            return []
        rows = [json.loads(line) for line in self.log.read_text().splitlines()]
        return [row for row in rows if kind is None or row["kind"] == kind]

    def requests(self, method):
        return [row["params"] for row in self.codex("request") if row["method"] == method]


class Base(unittest.TestCase):
    config = None

    def setUp(self):
        self.tako = Tako(self.config)
        self.addCleanup(self.tako.close)
        self.tako.stick()


class AQuestion(Base):
    def test_gets_an_answer(self):
        self.tako.ask("你好")
        seen = self.tako.until(lambda s: self.tako.said(s), "an answer")
        self.assertEqual(self.tako.said(seen), ["好的"])
        self.tako.idle()

    def test_still_gets_answered_when_its_folder_cant_be_made(self):
        # A folder someone refused (the Desktop permission), or a file in the way.
        self.tako.output.write_text("not a folder")
        self.tako.ask("你好")
        seen = self.tako.until(lambda s: self.tako.said(s) or s["error"], "an answer or a reason", 5)
        self.assertEqual(self.tako.said(seen), ["好的"], seen["error"])
        self.tako.idle(3)

    def test_leaves_no_empty_folders_behind(self):
        self.tako.ask("你好")
        self.tako.until(lambda s: self.tako.said(s), "an answer")
        self.tako.idle()
        self.assertEqual([path for path in self.tako.output.rglob("*")], [])

    def test_right_after_sticking_stays_on_that_window(self):
        self.tako.call("/stuck", {"app": "Numbers", "bundle": "com.apple.iWork.Numbers", "title": "表", "id": "2"})
        self.tako.ask("这句是给表格的")
        seen = self.tako.until(lambda s: self.tako.said(s), "an answer")
        self.assertEqual([event["text"] for event in seen["events"] if event["role"] == "owner"], ["这句是给表格的"])
        self.assertEqual(seen["chat"], "表")

    def test_with_no_answer_says_so(self):
        self.tako.ask(steps())
        seen = self.tako.until(lambda s: not s["busy"] and s["error"], "a word about it", 4)
        self.assertIn("没有", seen["error"])


class WhenTheModelFails(Base):
    def failing(self, info, message="something"):
        self.tako.ask(steps({"fail": {"message": message, "codexErrorInfo": info}}))
        return self.tako.until(lambda s: s["error"], "an error")["error"]

    def test_out_of_quota_says_so(self):
        self.assertIn("额度", self.failing("usageLimitExceeded", "You have hit your usage limit"))

    def test_not_logged_in_says_so(self):
        self.assertIn("登录", self.failing("unauthorized"))

    def test_no_connection_says_so(self):
        self.assertIn("连不上", self.failing({"httpConnectionFailed": {"httpStatusCode": 502}}))

    def test_too_long_says_so(self):
        self.assertIn("太长", self.failing("contextWindowExceeded"))

    def test_never_shows_a_raw_none(self):
        self.tako.ask(steps({"fail": {"message": "boom"}}))
        error = self.tako.until(lambda s: s["error"], "an error")["error"]
        self.assertNotIn("None", error)

    def test_logging_out_brings_the_login_step_back(self):
        self.assertEqual(self.tako.call("/setup")["step"], "ready")
        (self.tako.home / "logged_out").write_text("")
        self.failing("unauthorized")
        self.tako.until(lambda s: self.tako.call("/setup")["step"] == "login", "the login step")

    def test_the_process_dying_recovers_on_the_next_sentence(self):
        self.tako.ask(steps({"die": True}))
        error = self.tako.until(lambda s: s["error"], "an error")["error"]
        self.assertIn("掉线", error)
        self.tako.idle()
        self.tako.ask("还在吗")
        self.tako.until(lambda s: "好的" in self.tako.said(s), "an answer after the restart")
        self.assertEqual(len(self.tako.codex("started")), 2)

    def test_a_thread_that_vanished_keeps_what_was_said(self):
        self.tako.ask("记住暗号是海带")
        self.tako.until(lambda s: self.tako.said(s), "first answer")
        self.tako.idle()
        (self.tako.home / "forget").write_text(self.tako.requests("turn/start")[-1]["threadId"])
        self.tako.ask(steps({"say": "第二句"}))
        self.tako.until(lambda s: "第二句" in self.tako.said(s), "second answer")
        self.assertIn("记住暗号是海带", self.tako.requests("turn/start")[-1]["input"][0]["text"])


class Stop(Base):
    def test_stops_a_quiet_turn(self):
        self.tako.ask(steps({"hang": True}))
        self.tako.until(lambda s: s["busy"], "busy")
        self.tako.call("/stop", {})
        seen = self.tako.idle(3)
        self.assertEqual(seen["error"], "")

    def test_during_a_slow_tool_stays_stopped(self):
        release = threading.Event()
        self.tako.native["script"] = lambda c: (release.wait(6), {"ok": True, "output": "晚了"})[1]
        self.tako.ask(steps({"call": "run_in_app", "args": {"script": 'tell application "Keynote" to get name of front document', "app": "Keynote"}}, {"say": "做完了"}))
        self.tako.until(lambda s: s["status"] == "working", "the tool running")
        self.tako.call("/stop", {})
        self.tako.idle(3)
        release.set()
        time.sleep(0.4)
        self.assertFalse(self.tako.state()["busy"], "a tool finishing late must not bring the busy state back")

    def test_ends_a_run_of_steps(self):
        self.tako.native["step"] = lambda c: (time.sleep(0.15), {"ok": True, "did": "点了"})[1]
        many = [{"action": "click", "x": 1, "y": 1}] * 20
        self.tako.ask(steps({"call": "operate_window", "args": {"steps": many}}))
        self.tako.until(lambda s: sum(c["command"] == "step" for c in self.tako.commands) >= 2, "steps running")
        self.tako.call("/stop", {})
        self.tako.idle(3)
        time.sleep(0.5)
        count = sum(c["command"] == "step" for c in self.tako.commands)
        time.sleep(0.6)
        self.assertEqual(sum(c["command"] == "step" for c in self.tako.commands), count, "steps went on after stop")
        self.assertLess(count, 20)

    def test_answers_a_waiting_card(self):
        self.tako.ask(steps({"call": "run_in_app", "args": {"script": 'tell application "Keynote" to delete slide 1', "app": "Keynote"}}))
        self.tako.until(lambda s: s["pending"], "the card")
        self.tako.call("/stop", {})
        seen = self.tako.idle(3)
        self.assertEqual(seen["pending"], [])


class ATool(Base):
    def test_that_breaks_tells_the_model_instead_of_breaking_the_turn(self):
        self.tako.ask(steps({"call": "operate_window", "args": {"steps": 5}}, {"say": "知道了"}))
        self.tako.until(lambda s: "知道了" in self.tako.said(s), "the turn to go on")
        reply = self.tako.codex("tool_reply")[-1]["reply"]
        self.assertIs(reply.get("success"), False, reply)

    def test_two_at_once_leave_the_status_right(self):
        self.tako.native["windows"] = lambda c: (time.sleep(0.05), {"ok": True, "windows": []})[1]
        self.tako.ask(steps({"call": "list_windows"}, {"call": "list_windows"}, {"say": "看完了"}))
        seen = self.tako.until(lambda s: "看完了" in self.tako.said(s), "the answer")
        self.assertEqual(self.tako.idle()["status"], "idle", seen)


class ACard(Base):
    def propose(self):
        folder = self.tako.output / "稿"
        folder.mkdir(parents=True)
        original = self.tako.home / "方案.pptx"
        edited = folder / "方案.pptx"
        original.write_text("原来的")
        time.sleep(0.02)
        edited.write_text("改过的")
        self.tako.native["closeDocument"] = lambda c: {"ok": True, "app": "/Applications/wps.app"}
        self.tako.native["openDocument"] = lambda c: {"ok": True}
        self.tako.ask(steps({"call": "propose_file_change", "args": {"original": str(original), "edited": str(edited), "summary": "改了标题"}}, {"say": "好了"}))
        return self.tako.until(lambda s: s["pending"], "the card")["pending"][0], original

    def test_apply_backs_up_replaces_and_reopens(self):
        card, original = self.propose()
        self.assertEqual(card["kind"], "change")
        self.tako.call("/decide", {"id": card["id"], "accepted": True})
        self.tako.until(lambda s: "好了" in self.tako.said(s), "the turn to finish")
        self.assertEqual(original.read_text(), "改过的")
        self.assertEqual([path.read_text() for path in (self.tako.home / "backups").iterdir()], ["原来的"])
        self.assertEqual([c["command"] for c in self.tako.commands if "Document" in c["command"]], ["closeDocument", "openDocument"])

    def test_refusing_changes_nothing(self):
        card, original = self.propose()
        self.tako.call("/decide", {"id": card["id"], "accepted": False})
        self.tako.until(lambda s: "好了" in self.tako.said(s), "the turn to finish")
        self.assertEqual(original.read_text(), "原来的")

    def test_a_document_that_wont_close_is_left_alone(self):
        card, original = self.propose()
        self.tako.native["closeDocument"] = lambda c: {"ok": False, "error": "有没保存的改动"}
        self.tako.call("/decide", {"id": card["id"], "accepted": True})
        self.tako.until(lambda s: "好了" in self.tako.said(s), "the turn to finish")
        self.assertEqual(original.read_text(), "原来的")
        self.assertIn("没保存", self.tako.codex("tool_reply")[-1]["reply"]["contentItems"][0]["text"])


class Throwaways(Base):
    def test_a_greeting_thread_gets_no_tools_and_only_the_apps_name(self):
        seen = self.tako.until(lambda s: self.tako.requests("thread/unsubscribe") or len(self.tako.requests("thread/start")) >= 2, "the greeting thread")
        starts = [row for row in self.tako.requests("thread/start") if not row.get("dynamicTools")]
        self.assertTrue(starts, seen)
        self.assertFalse(starts[0]["config"]["features.shell_tool"])
        for turn in self.tako.requests("turn/start"):
            if turn["sandboxPolicy"].get("type") == "readOnly":
                self.assertEqual(turn["input"][0]["text"], "软件：Keynote")

    def test_are_let_go_of_once_read(self):
        self.tako.until(lambda s: self.tako.requests("thread/unsubscribe"), "the thread to be released", 6)
        brain = next(row for row in self.tako.codex("request") if row["method"] == "thread/start" and row["params"].get("dynamicTools"))
        self.assertIsNotNone(brain)


class TheSwitch(Base):
    def test_an_isolated_run_has_nothing_to_switch_and_sends_nothing(self):
        self.assertEqual(self.tako.call("/feedback"), {"can": False, "on": True})


class Summarizing(Base):
    def long_turn(self):
        self.tako.ask(steps({"usage": 130_000}, {"say": "答完了"}))
        self.tako.until(lambda s: "答完了" in self.tako.said(s), "the answer")
        return self.tako.idle()

    def test_a_long_thread_gets_summarized(self):
        self.long_turn()
        self.assertEqual(len(self.tako.requests("thread/compact/start")), 1)

    def test_a_summary_that_fails_is_nobodys_business(self):
        (self.tako.home / "compact_fails").write_text("")
        self.assertEqual(self.long_turn()["error"], "")


class Inside(unittest.IsolatedAsyncioTestCase):
    """What can't be reached from the routes alone: the same server code in this process, with the same stand-in for Codex."""

    @classmethod
    def setUpClass(cls):
        cls.home = pathlib.Path(tempfile.mkdtemp(prefix="tako-test-"))
        (cls.home / "bin").mkdir()
        (cls.home / "config.json").write_text(json.dumps({"name": "Alex", "output_root": str(cls.home / "works")}))
        codex = cls.home / "bin/codex"
        codex.write_text(f'#!/bin/sh\nexec "{sys.executable}" -B "{ROOT / "tests/fake_codex.py"}" "$@"\n')
        codex.chmod(codex.stat().st_mode | stat.S_IEXEC)
        cls.log = cls.home / "codex.log"
        cls.saved = dict(os.environ)
        os.environ.update(TAKO_HOME=str(cls.home), PATH=f"{cls.home / 'bin'}{os.pathsep}{os.environ['PATH']}", FAKE_CODEX_LOG=str(cls.log), FAKE_CODEX_HOME=str(cls.home))
        sys.path.insert(0, str(SERVER.parent))
        cls.server = __import__("tako_server")
        cls.turns, cls.outputs = __import__("turns"), __import__("outputs")

    @classmethod
    def tearDownClass(cls):
        os.environ.clear()
        os.environ.update(cls.saved)
        shutil.rmtree(cls.home, ignore_errors=True)

    async def asyncSetUp(self):
        self.tako = self.server.Companion(None)
        self.tako.loop = asyncio.get_running_loop()
        self.commands = []

        async def native(command, timeout=30, **args):
            self.commands.append(command)
            if command == "listenStop":  # The app hands over the last of what it heard the moment it is told to stop.
                self.tako.heard(self.last_piece)
            return {"ok": True}
        self.tako.native = native
        self.window = {"username": "window:x:1", "name": "稿子", "kind": "window"}
        self.addAsyncCleanup(self.tako.runtime.close)

    def chat(self, name):
        return {"username": f"{name}@chatroom", "name": name}

    async def test_a_message_is_judged_in_the_chat_it_came_to(self):
        a, b = self.chat("甲"), self.chat("乙")
        said_a, said_b = [], []
        a_rows = [{"id": 1, "time": 1_800_000_000, "who": "老王", "is_me": False, "text": "甲群的消息"}]
        self.tako.chat, self.tako.events, self.tako.history = b, said_b, [{"id": 9, "time": 1_800_000_000, "who": "老李", "is_me": False, "text": "乙群的消息"}]
        seen = {}
        original = self.tako._reader

        async def reader(instructions, text, **kw):
            seen["text"] = text
            return "你要回一下"
        self.tako._reader = reader
        await self.tako.turn("判断", origin="message", where=(a, said_a, None), history=a_rows)
        self.tako._reader = original
        self.assertIn("甲群的消息", seen["text"])
        self.assertNotIn("乙群的消息", seen["text"])
        self.assertEqual([e["text"] for e in said_a], ["你要回一下"])
        self.assertEqual(said_b, [])
        self.assertEqual(self.tako.unsent, [], "what was said in 甲 must not land in 乙's memory")
        self.assertEqual(self.tako.saved["甲@chatroom"]["unsent"][0]["text"], "你要回一下")

    async def test_a_glance_that_fails_says_nothing(self):
        async def reader(*a, **kw):
            raise self.turns.TurnFailed({"message": "x", "codexErrorInfo": "usageLimitExceeded"})
        self.tako._reader = reader
        chat = self.chat("甲")
        await self.tako.turn("判断", origin="message", where=(chat, [], None), history=[])
        self.assertEqual(self.tako.error, "")
        self.assertEqual(self.tako.status, "idle")

    async def test_the_process_comes_back_only_once(self):
        await self.tako._alive()
        first = self.tako.runtime
        first.process.kill()
        await first.process.wait()
        for _ in range(100):
            if first.closed:
                break
            await asyncio.sleep(0.01)
        await asyncio.gather(*(self.tako._alive() for _ in range(5)))
        self.assertIsNot(self.tako.runtime, first)
        self.assertFalse(self.tako.runtime.closed)
        started = [json.loads(line) for line in self.log.read_text().splitlines() if '"kind": "started"' in line]
        pids = {row["pid"] for row in started}
        self.assertIn(self.tako.runtime.process.pid, {p for p in pids} | {self.tako.runtime.process.pid})
        alive = subprocess.run(["pgrep", "-P", str(os.getpid()), "-f", "app-server"], capture_output=True, text=True).stdout.split()
        self.assertEqual(len(alive), 1, alive)

    async def test_a_reader_can_never_use_the_owners_turn(self):
        self.tako.thread = "the-brain"
        self.tako.origin = "owner"
        ran = []

        async def run(name, args):
            ran.append(name)
            return self.tako._reply("做了")
        self.tako._run_tool = run
        refused = await self.tako.on_server_request("item/tool/call", {"threadId": "a-throwaway", "tool": "fill_input", "arguments": {}})
        self.assertIs(refused["success"], False)
        self.assertEqual(ran, [])
        self.assertEqual(await self.tako.on_server_request("item/commandExecution/requestApproval", {"threadId": "a-throwaway", "command": "rm"}), {"decision": "decline"})
        self.assertEqual(self.tako.pending, {})
        done = await self.tako.on_server_request("item/tool/call", {"threadId": "the-brain", "tool": "fill_input", "arguments": {}})
        self.assertIs(done["success"], True)

    async def test_the_last_of_a_class_is_kept(self):
        folder = self.home / "listening"
        folder.mkdir(exist_ok=True)
        self.last_piece = str(folder / "last.f32")
        pathlib.Path(self.last_piece).write_bytes(b"x")
        events = []
        self.tako.lecture = {"title": "一节课", "started": time.time(), "heard": [], "notes": [], "noted": 0, "note_time": time.time(), "pending": 0, "missed": 0, "chat": self.window, "events": events}

        async def transcribe(lecture, path):
            lecture["heard"].append("最后一句")
            lecture["pending"] -= 1
        self.tako._transcribe = transcribe

        async def reader(*a, **kw):
            return "一条要点"
        self.tako._reader = reader
        path = await self.tako._end_lecture("下课")
        self.assertIn("最后一句", path.read_text())
        self.assertEqual([e["text"] for e in events], ["一条要点", "下课"], "notes stay where the class was asked for")
        self.assertEqual(self.tako.events, [])

    async def test_a_slow_file_doesnt_stop_everything_else(self):
        folder = self.outputs.make_output_dir(self.window)
        source, copy = self.home / "原.pptx", folder / "副本.pptx"
        source.write_text("原")
        time.sleep(0.02)
        copy.write_text("副")
        original = shutil.copy2
        shutil.copy2 = lambda *a, **kw: (time.sleep(0.4), original(*a, **kw))[1]
        self.addCleanup(setattr, shutil, "copy2", original)
        beats = []

        async def heart():
            while True:
                beats.append(time.time())
                await asyncio.sleep(0.02)
        beating = asyncio.create_task(heart())
        work = asyncio.create_task(self.tako._propose(str(source), str(copy), "改了"))
        while not self.tako.pending:
            await asyncio.sleep(0.01)
        self.tako.decide(next(iter(self.tako.pending)), True)
        await work
        beating.cancel()
        self.assertLess(max(b - a for a, b in zip(beats, beats[1:])), 0.25)
        self.assertEqual(source.read_text(), "副")


if __name__ == "__main__":
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    unittest.main()
