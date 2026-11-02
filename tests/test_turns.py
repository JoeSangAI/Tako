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

    def owner_turns(self):
        """The owner's own turns: a greeting's throwaway thread has no folder of its own."""
        return [params for params in self.requests("turn/start") if params.get("cwd")]


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


class OneClock(Base):
    def test_the_models_commands_tell_the_time_the_owner_set(self):
        self.tako.ask("几点了")
        self.tako.until(lambda s: self.tako.said(s), "an answer")
        self.assertEqual(self.tako.codex("clock")[0]["tz"], "Asia/Shanghai")


class PointingAtThings(Base):
    def _replies(self, tool="point_at"):
        return [str(line.get("reply")) for line in map(json.loads, self.tako.log.read_text().splitlines()) if line.get("kind") == "tool_reply"]

    def test_a_ring_nobody_saw_goes_round_again_when_they_get_there(self):
        here = threading.Event()
        self.tako.native["point"] = lambda c: {"ok": True, "seen": here.is_set()}
        self.tako.native["isBack"] = lambda c: {"ok": here.is_set(), "front": here.is_set(), "app": "Google Chrome"}
        self.tako.stick(app="Google Chrome", bundle="com.google.Chrome", title="页面", window="7")
        self.tako.ask(steps({"call": "point_at", "args": {"text": "价格"}}, {"say": "在价格那一行"}))
        self.tako.until(lambda s: self.tako.said(s), "an answer")
        self.assertIn("不在前台", " ".join(self._replies()))
        count = lambda: len([c for c in self.tako.commands if c["command"] == "point"])
        self.assertEqual(count(), 1)
        here.set()
        deadline = time.time() + 4
        while count() < 2 and time.time() < deadline:
            time.sleep(0.05)
        self.assertEqual(count(), 2)

    def test_seen_is_all_it_takes(self):
        self.tako.native["point"] = lambda c: {"ok": True, "seen": True}
        self.tako.ask(steps({"call": "point_at", "args": {"text": "价格"}}, {"say": "好"}))
        self.tako.until(lambda s: self.tako.said(s), "an answer")
        self.assertEqual(self._replies()[0].count("不在前台"), 0)

    def test_the_same_refusal_twice_stops_the_trying(self):
        self.tako.native["point"] = lambda c: {"ok": False, "error": "这段字不在这个窗口里，没有标。"}
        self.tako.ask(steps({"call": "point_at", "args": {"text": "价格"}}, {"call": "point_at", "args": {"text": "价格"}}, {"say": "没找到"}))
        self.tako.until(lambda s: self.tako.said(s), "an answer")
        replies = self._replies()
        self.assertNotIn("不要再试", replies[0])
        self.assertIn("不要再试", replies[1])


class WhereScriptsGo(Base):
    def test_the_name_a_chinese_mac_gives_it(self):
        self.tako.native["script"] = lambda c: {"ok": True, "output": "好"}
        self.tako.stick(app="访达", bundle="com.apple.finder", title="桌面", window="5")
        self.tako.ask(steps({"call": "run_in_app", "args": {"script": 'tell application "Finder" to get name of front window', "app": "访达"}}, {"say": "看了"}))
        self.tako.until(lambda s: self.tako.said(s), "an answer")
        self.assertTrue([c for c in self.tako.commands if c["command"] == "script"])


class WhereItWritesWithoutAsking(Base):
    def test_this_folder_is_the_finder_window_it_was_asked_on(self):
        folder = self.tako.home / "十月发票"
        folder.mkdir()
        self.tako.native["about"] = lambda c: {"ok": True, "folder": str(folder), "selected": ["a.pdf", "b.pdf"]}
        self.tako.stick(app="访达", bundle="com.apple.finder", title="十月发票", window="5")
        self.tako.ask("把这些归到一个子文件夹")
        self.tako.until(lambda s: self.tako.said(s), "an answer")
        self.tako.idle()
        turn = self.tako.owner_turns()[-1]
        self.assertIn(os.path.realpath(folder), turn["sandboxPolicy"]["writableRoots"])
        self.assertIn(f"这个文件夹：{folder}", json.dumps(turn, ensure_ascii=False))
        self.assertIn("选中的：a.pdf、b.pdf", json.dumps(turn, ensure_ascii=False))

    def test_a_home_folder_window_gives_no_write_to_the_whole_home(self):
        self.tako.native["about"] = lambda c: {"ok": True, "folder": str(pathlib.Path.home()), "selected": []}
        self.tako.stick(app="访达", bundle="com.apple.finder", title="home", window="5")
        self.tako.ask("看看这里")
        self.tako.until(lambda s: self.tako.said(s), "an answer")
        self.tako.idle()
        self.assertNotIn(str(pathlib.Path.home()), self.tako.owner_turns()[-1]["sandboxPolicy"]["writableRoots"][1:])

    def test_finder_saying_nothing_is_just_a_window(self):
        self.tako.native["about"] = lambda c: {"ok": True}
        self.tako.stick(app="访达", bundle="com.apple.finder", title="十月发票", window="5")
        self.tako.ask("看看")
        self.tako.until(lambda s: self.tako.said(s), "an answer")
        self.tako.idle()
        self.assertNotIn("这个文件夹", json.dumps(self.tako.owner_turns()[-1], ensure_ascii=False))

    def test_where_the_owner_pointed(self):
        folder = self.tako.home / "十月发票"
        folder.mkdir()
        dragged = self.tako.home / "拖来的.txt"
        dragged.write_text("x")
        self.tako.ask(f"发票在 {folder}。填进这个系统")
        self.tako.until(lambda s: self.tako.said(s), "an answer")
        self.tako.idle()
        roots = self.tako.owner_turns()[-1]["sandboxPolicy"]["writableRoots"]
        self.assertEqual(roots[1:], [os.path.realpath(folder)])
        self.tako.call("/ask", {"text": "再看看这个", "files": [str(dragged)]})
        self.tako.until(lambda s: len(self.tako.owner_turns()) >= 2, "the next turn")
        self.tako.idle()
        self.assertEqual(set(self.tako.owner_turns()[-1]["sandboxPolicy"]["writableRoots"][1:]), {os.path.realpath(folder), str(dragged)})

    def test_and_nowhere_else(self):
        self.tako.ask("随便说一句 /不存在的路径")
        self.tako.until(lambda s: self.tako.said(s), "an answer")
        self.assertEqual(len(self.tako.owner_turns()[-1]["sandboxPolicy"]["writableRoots"]), 1)


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
        self.assertEqual([c["command"] for c in self.tako.commands if "Document" in c["command"]], ["closeDocument", "closeDocument", "openDocument"])
        closes = [c for c in self.tako.commands if c["command"] == "closeDocument"]
        self.assertTrue(closes[0].get("held"))  # The copy: only if it was looked at.
        self.assertFalse(closes[1].get("held"))
        self.assertEqual(closes[1]["document"], str(original))

    def test_a_document_that_closes_too_late_comes_back(self):
        card, original = self.propose()
        self.tako.native["closeDocument"] = lambda c: {"ok": True} if c.get("held") else {"ok": False, "closing": True, "app": "/Applications/wps.app", "error": "没能关上"}
        self.tako.call("/decide", {"id": card["id"], "accepted": True})
        self.tako.until(lambda s: "好了" in self.tako.said(s), "the turn to finish")
        self.assertEqual(original.read_text(), "原来的")
        self.assertEqual([c["document"] for c in self.tako.commands if c["command"] == "openDocument"], [str(original)])

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
            if turn.get("sandboxPolicy", {}).get("type") == "readOnly":
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

    def looked_at_big_windows(self, megabytes):
        self.tako.native["look"] = lambda c: {"ok": True, "title": "稿子", "elements": "", "image": "x" * int(megabytes * 1_000_000)}
        self.tako.ask(steps({"call": "look_at_window", "args": {}}, {"say": "看到了"}))
        return self.tako.until(lambda s: not s["busy"] and "看到了" in self.tako.said(s), "the answer")

    def test_a_thread_full_of_screenshots_gets_summarized_though_it_has_few_words(self):
        self.looked_at_big_windows(3.2)
        self.tako.until(lambda s: self.tako.requests("thread/compact/start"), "the summary", 3)
        before = self.tako.requests("thread/compact/start")
        self.tako.ask("再说一句")
        self.tako.until(lambda s: len(self.tako.said(s)) == 2, "the next answer")
        self.assertEqual(self.tako.requests("thread/compact/start"), before, "once summarized, the screenshots are gone and don't count again")

    def test_a_few_screenshots_are_left_alone(self):
        self.looked_at_big_windows(0.2)
        time.sleep(0.2)
        self.assertEqual(self.tako.requests("thread/compact/start"), [])

    def test_a_summary_that_cant_upload_leaves_for_a_light_thread_quietly(self):
        (self.tako.home / "compact_cant_upload").write_text("")
        self.looked_at_big_windows(3.2)
        self.tako.until(lambda s: self.tako.requests("thread/compact/start"), "the summary", 3)
        self.tako.ask("继续")
        seen = self.tako.until(lambda s: len(self.tako.said(s)) == 2, "the next answer")
        self.assertEqual(seen["error"], "")
        started = self.tako.owner_turns()
        self.assertNotEqual(started[0]["threadId"], started[-1]["threadId"], "the next sentence must not wait on the heavy thread")
        self.assertIn("看到了", started[-1]["input"][0]["text"], "what was said in this window comes along")


class TheModelCantBeReached(Base):
    def test_the_panel_says_so_instead_of_showing_the_last_step(self):
        self.tako.ask(steps({"retry": 1}, {"pause": 0.6}, {"say": "回来了"}))
        seen = self.tako.until(lambda s: s["trouble"], "the trouble shown")
        self.assertIn("重试", seen["trouble"])
        self.assertTrue(seen["busy"])
        seen = self.tako.until(lambda s: not s["busy"], "the turn ended")
        self.assertEqual(seen["trouble"], "")
        self.assertIn("回来了", self.tako.said(seen))

    def test_it_clears_as_soon_as_the_model_answers(self):
        self.tako.ask(steps({"retry": 1}, {"pause": 0.3}, {"say": "回来了"}, {"pause": 0.6}))
        self.tako.until(lambda s: s["trouble"], "the trouble shown")
        seen = self.tako.until(lambda s: s["busy"] and not s["trouble"], "progress clearing it")
        self.assertTrue(seen["busy"])
        self.tako.idle()

    def test_a_heavy_thread_stops_retrying_and_the_next_sentence_goes_on_a_light_one(self):
        self.tako.native["look"] = lambda c: {"ok": True, "title": "稿子", "elements": "", "image": "x" * 1_600_000}
        self.tako.ask(steps({"call": "look_at_window", "args": {}}, {"retry": 2}, {"hang": True}))
        seen = self.tako.until(lambda s: not s["busy"], "giving up")
        self.assertIn("继续", seen["error"])
        first = self.tako.owner_turns()[-1]["threadId"]
        self.assertTrue(self.tako.requests("turn/interrupt"), "the old turn must not keep uploading")
        self.tako.ask("继续")
        self.tako.until(lambda s: "好的" in self.tako.said(s), "the next answer")
        self.assertNotEqual(self.tako.owner_turns()[-1]["threadId"], first)

    def test_a_light_thread_keeps_retrying_because_it_is_only_the_network(self):
        self.tako.ask(steps({"retry": 3}, {"pause": 0.3}, {"say": "回来了"}))
        seen = self.tako.until(lambda s: "回来了" in self.tako.said(s), "the answer")
        self.assertEqual(seen["error"], "")


class TheOwnerMovesOn(Base):
    def other_window(self):
        self.tako.stick("Safari", "com.apple.Safari", "另一个页面", "2")

    def test_the_work_stays_on_the_window_it_was_asked_on(self):
        self.tako.ask(steps({"pause": 0.4}, {"call": "look_at_window", "args": {}}, {"say": "第一个窗口做完了"}))
        self.tako.until(lambda s: s["busy"], "running")
        self.other_window()
        self.tako.until(lambda s: [c for c in self.tako.commands if c["command"] == "look"], "the look", 4)
        self.assertEqual([c.get("window") for c in self.tako.commands if c["command"] == "look"], ["1"], "not wherever the goo has gone")

    def test_the_result_waits_where_it_was_asked_and_the_panel_here_says_so(self):
        self.tako.ask(steps({"pause": 0.3}, {"say": "第一个窗口做完了"}))
        self.tako.until(lambda s: s["busy"], "running")
        self.other_window()
        seen = self.tako.until(lambda s: s["others"], "told it's still going", 3)
        self.assertEqual(seen["others"][0]["state"], "working")
        self.assertFalse(seen["busy"], "this window isn't busy: its stop button must not stop the other one")
        seen = self.tako.until(lambda s: s["others"] and s["others"][0]["state"] == "done", "told it's done", 3)
        self.assertEqual(self.tako.said(seen), [])
        self.tako.stick()
        seen = self.tako.until(lambda s: "第一个窗口做完了" in self.tako.said(s), "the result back here", 3)
        self.assertEqual(seen["others"], [])

    def test_the_other_window_doesnt_wait_for_it(self):
        self.tako.ask(steps({"hang": True}))
        self.tako.until(lambda s: s["busy"] and self.tako.owner_turns(), "running")
        self.other_window()
        self.tako.ask(steps({"call": "look_at_window", "args": {}}, {"say": "另一个窗口答了"}))
        seen = self.tako.until(lambda s: "另一个窗口答了" in self.tako.said(s), "an answer without waiting", 4)
        self.assertEqual(seen["others"][0]["state"], "working", "the first one is still going")
        first, second = self.tako.owner_turns()
        self.assertNotEqual(first["threadId"], second["threadId"])
        self.assertEqual([c.get("window") for c in self.tako.commands if c["command"] == "look"], ["2"])
        self.assertIn(second["threadId"], [row["threadId"] for row in self.tako.requests("thread/unsubscribe")], "a limb is let go of")

    def test_stop_stops_only_what_the_panel_shows(self):
        self.tako.ask(steps({"hang": True}))
        self.tako.until(lambda s: s["busy"] and self.tako.owner_turns(), "running")
        self.other_window()
        self.tako.ask(steps({"hang": True}))
        self.tako.until(lambda s: s["busy"], "the second running", 3)
        time.sleep(0.2)
        self.tako.call("/stop", {})
        seen = self.tako.until(lambda s: not s["busy"], "this one stopped", 3)
        self.assertEqual(seen["others"][0]["state"], "working", "the other one goes on")
        self.tako.stick()
        self.tako.until(lambda s: s["busy"], "still running back there", 3)
        self.tako.call("/stop", {})
        self.tako.idle(3)

    def test_the_brain_hears_what_a_limb_did(self):
        release = threading.Event()
        self.tako.native["script"] = lambda c: (release.wait(6), {"ok": True, "output": "好"})[1]
        self.tako.ask(steps({"call": "run_in_app", "args": {"script": 'tell application "Keynote" to get name of front document', "app": "Keynote"}}, {"say": "第一件"}))
        self.tako.until(lambda s: s["status"] == "working", "the tool running")
        self.other_window()
        self.tako.ask(steps({"say": "第二件做好了"}))
        self.tako.until(lambda s: "第二件做好了" in self.tako.said(s), "the limb's answer", 4)
        release.set()
        self.tako.stick()
        self.tako.until(lambda s: "第一件" in self.tako.said(s), "the first answer", 4)
        self.tako.ask("刚才那边做了什么")
        self.tako.until(lambda s: not s["busy"] and len(self.tako.said(s)) == 2, "the next answer", 4)
        told = self.tako.owner_turns()[-1]["input"][0]["text"]
        self.assertIn("第二件做好了", told)

    def test_a_card_from_the_other_window_still_reaches_the_owner(self):
        self.tako.native["step"] = lambda c: {"needs": "在 Keynote 里点“删除”"} if not c.get("confirmed") else {"ok": True, "did": "点了"}
        self.tako.ask(steps({"pause": 0.3}, {"call": "operate_window", "args": {"steps": [{"action": "click", "text": "删除"}]}}, {"say": "好了"}))
        self.tako.until(lambda s: s["busy"], "running")
        self.other_window()
        seen = self.tako.until(lambda s: s["pending"], "the card here", 4)
        self.assertNotIn("job", seen["pending"][0])
        self.tako.call("/decide", {"id": seen["pending"][0]["id"], "accepted": True})
        self.tako.until(lambda s: s["others"] and s["others"][0]["state"] == "done", "finished", 4)


class NeedingTheRealPointer(Base):
    DRAG = {"call": "operate_window", "args": {"steps": [{"action": "drag", "x": 1, "y": 1, "x2": 2, "y2": 2}]}}

    def waiting_for_owner(self):
        self.back = threading.Event()
        self.tako.native["step"] = lambda c: {"ok": True, "did": "拖动了"} if self.back.is_set() else {"ok": False, "needsFront": True, "error": "这一步要 Keynote 在前台才能做"}
        self.tako.native["isBack"] = lambda c: {"ok": self.back.is_set()}
        self.tako.ask(steps(self.DRAG, {"say": "别的都做完了，差拖动这一步"}))
        return self.tako.until(lambda s: "别的都做完了，差拖动这一步" in self.tako.said(s) and s["trouble"], "the rest done and the wait shown", 5)

    def test_finishes_the_rest_then_goes_on_when_the_owner_is_back(self):
        seen = self.waiting_for_owner()
        self.assertFalse(seen["busy"], "nothing is running: the owner isn't held up either")
        self.assertIn("切回去", seen["trouble"])
        reply = [r for r in self.tako.codex("tool_reply") if r["tool"] == "operate_window"][0]["reply"]
        self.assertIn("先没做", json.dumps(reply, ensure_ascii=False))
        self.back.set()
        self.tako.until(lambda s: len(self.tako.owner_turns()) == 2, "picked up by itself", 6)
        seen = self.tako.until(lambda s: not s["busy"] and len(self.tako.said(s)) == 2, "and answered", 5)
        self.assertEqual(seen["trouble"], "")
        self.assertNotIn("bringForward", [c["command"] for c in self.tako.commands], "only a button the owner pressed may bring a window forward")

    def test_shows_from_any_other_window(self):
        self.waiting_for_owner()
        self.tako.stick("Safari", "com.apple.Safari", "另一个页面", "2")
        seen = self.tako.until(lambda s: s["others"] and s["others"][0]["state"] == "held", "said here too", 4)
        self.assertIn("切回去", seen["others"][0]["trouble"])
        self.assertEqual(seen["trouble"], "")

    def test_what_the_owner_says_next_replaces_the_wait(self):
        self.waiting_for_owner()
        self.tako.ask("算了，不用拖了")
        seen = self.tako.until(lambda s: not s["busy"] and len(self.tako.said(s)) == 2, "the answer", 5)
        self.assertEqual(seen["trouble"], "")
        self.back.set()
        time.sleep(2.5)
        self.assertEqual(len(self.tako.owner_turns()), 2, "it must not come back to what they called off")

    def test_a_window_that_closed_ends_the_wait(self):
        self.waiting_for_owner()
        self.tako.native["isBack"] = lambda c: {"ok": False, "error": "没找到窗口"}
        self.tako.until(lambda s: not s["trouble"], "the wait over", 5)

    def test_a_window_under_the_owners_other_chrome_window_is_not_passed_off_as_seen(self):
        self.back = threading.Event()
        self.tako.native["look"] = lambda c: {"ok": True, "id": 7, "app": "Google Chrome", "title": "邮件", "lines": "收件人"} if self.back.is_set() else {"ok": False, "needsFront": True, "error": "Google Chrome 的另一个窗口正盖在这个窗口上，它不更新被盖住的窗口，也不给里面的控件，现在看不到真实内容"}
        self.tako.native["isBack"] = lambda c: {"ok": self.back.is_set()}
        self.tako.ask(steps({"call": "look_at_window", "args": {}}, {"say": "差你切回那个窗口"}))
        seen = self.tako.until(lambda s: "差你切回那个窗口" in self.tako.said(s) and s["trouble"], "told, and waiting", 5)
        self.assertFalse(seen["busy"])
        reply = json.dumps([r for r in self.tako.codex("tool_reply") if r["tool"] == "look_at_window"][0]["reply"], ensure_ascii=False)
        self.assertIn("盖在这个窗口上", reply)
        self.assertIn("先没做", reply)
        self.back.set()
        self.tako.until(lambda s: len(self.tako.owner_turns()) == 2, "picked up by itself", 6)

    def test_a_window_on_another_desktop_says_it_can_only_be_looked_at(self):
        self.tako.native["look"] = lambda c: {"ok": True, "id": 7, "app": "Google Chrome", "title": "邮件", "note": "这个窗口不在当前桌面：只看得到画面，里面的东西按不了，要操作得等 用户 切到那个桌面。", "lines": "收件人"}
        self.tako.ask(steps({"call": "look_at_window", "args": {}}, {"say": "好了"}))
        self.tako.until(lambda s: not s["busy"] and self.tako.said(s), "answered", 5)
        reply = json.dumps([r for r in self.tako.codex("tool_reply") if r["tool"] == "look_at_window"][0]["reply"], ensure_ascii=False)
        self.assertIn("不在当前桌面", reply)

    def test_the_panels_own_button_may_bring_the_window_forward(self):
        result = self.tako.call("/fill", {"text": "你好"}, timeout=12)
        self.assertTrue(result["ok"])
        self.assertIn("bringForward", [c["command"] for c in self.tako.commands])


class HandingAFileToAnotherApp(Base):
    """Asked on one app's window, it lands in WeChat. WeChat takes the real pointer, so it waits for the owner to get there, and then nobody has to say anything."""
    WECHAT = "com.tencent.xinWeChat"
    SEND = {"call": "fill_input", "args": {"text": "", "files": ["/tmp/名单.xlsx"], "chat": "小林"}}

    def setUp(self):
        super().setUp()
        self.here = threading.Event()   # the owner is on WeChat
        self.still = threading.Event()  # and has let go of the mouse
        self.opened = threading.Event()  # WeChat is showing the chat
        keynote = {"ok": True, "id": 1, "app": "Keynote", "bundle": "com.apple.iWork.Keynote", "title": "稿子", "stuck": True}
        wechat = {"ok": True, "id": 9, "app": "微信", "bundle": self.WECHAT, "title": "微信", "stuck": False}
        wants_wechat = lambda c: str(c.get("window")) == "9" or "wechat" in str(c.get("window")).lower()
        needs_it = {"ok": False, "needsFront": True, "id": 9, "app": "微信", "error": "这一步要 微信 在前台才能做"}
        self.tako.native.update({
            "resolve": lambda c: wechat if wants_wechat(c) else keynote,
            "isBack": lambda c: {"ok": wants_wechat(c) and self.still.is_set(), "front": wants_wechat(c) and self.here.is_set(), "app": "微信" if wants_wechat(c) else "Keynote"},
            "openChat": lambda c: (self.opened.set(), {"ok": True})[1] if self.still.is_set() else needs_it,
            "titles": lambda c: {"ok": True, "lines": ["小林" if self.opened.is_set() else "别的对话"]},
            "fill": lambda c: {"ok": True, "message": "已填入，没有发送，等 用户 自己发。"} if self.still.is_set() else needs_it,
        })

    def sent(self, command):
        return [c for c in self.tako.commands if c["command"] == command]

    def queued(self, *more):
        self.tako.ask(steps(self.SEND, *(more or [{"say": "切到微信就会放好"}])))
        return self.tako.until(lambda s: not s["busy"] and s["trouble"], "told, and waiting", 6)

    def test_a_chat_means_wechat_whatever_window_it_was_asked_on(self):
        self.here.set()
        self.still.set()
        self.tako.ask(steps(self.SEND, {"say": "好了"}))
        self.tako.idle()
        self.assertEqual([c["window"] for c in self.sent("fill")], ["9"], "never into the document it was asked on")

    def test_says_it_is_queued_so_the_model_stops_trying(self):
        seen = self.queued()
        reply = [r for r in self.tako.codex("tool_reply") if r["tool"] == "fill_input"][0]["reply"]
        self.assertTrue(reply["success"])
        self.assertIn("已排好", json.dumps(reply, ensure_ascii=False))
        self.assertIn("微信", seen["trouble"])
        self.assertNotIn("Keynote", seen["trouble"])

    def test_the_owner_arriving_finishes_it_with_no_model_turn(self):
        self.queued()
        self.assertTrue(all(c["window"] == self.WECHAT for c in self.sent("isBack")), "it watches WeChat, not the window it was asked on")
        self.here.set()
        self.still.set()
        seen = self.tako.until(lambda s: any("没有发送" in text for text in self.tako.said(s)), "placed and said", 6)
        self.assertEqual(seen["trouble"], "")
        self.assertEqual(len(self.sent("fill")), 1, "opening the chat is what had to wait, and it goes in once")
        self.assertEqual(self.sent("fill")[-1]["files"], ["/tmp/名单.xlsx"])
        time.sleep(1)
        self.assertEqual(len(self.tako.owner_turns()), 1, "doing it costs no model call")
        self.assertNotIn("bringForward", [c["command"] for c in self.tako.commands])

    def test_coming_back_to_the_first_window_does_not_wake_the_model(self):
        self.queued()
        time.sleep(1.6)
        self.assertEqual(len(self.tako.owner_turns()), 1)

    def test_asking_again_replaces_it(self):
        self.tako.native["fill"] = lambda c: {"ok": True, "message": "已填入"} if self.still.is_set() else {"ok": False, "needsFront": True, "id": 9, "app": "微信", "error": "要前台"}
        again = {"call": "fill_input", "args": {"text": "第二版", "files": [], "chat": "小林"}}
        self.queued(again, {"say": "好"})
        self.here.set()
        self.still.set()
        self.tako.until(lambda s: not s["trouble"], "done", 6)
        time.sleep(1)
        placed = [c for c in self.sent("fill")][-1]
        self.assertEqual(placed["text"], "第二版")
        self.assertEqual(len(self.sent("fill")), 1, "the latest one, once")

    def test_the_goo_goes_along_while_the_hand_is_still_moving(self):
        self.queued()
        self.here.set()
        self.tako.until(lambda s: self.sent("followTo"), "goes there", 4)
        seen = self.tako.until(lambda s: "停" in s["trouble"], "and says what it is waiting for", 4)
        self.assertEqual(seen["busy"], False)
        time.sleep(1)
        self.assertEqual(len(self.sent("followTo")), 1)
        self.assertEqual(self.sent("followTo")[0]["window"], self.WECHAT)
        self.assertEqual(self.sent("fill"), [], "a moving hand: nothing happens yet")

    def test_a_short_name_is_the_chat_it_is_short_for(self):
        self.here.set()
        self.still.set()
        self.tako.native["titles"] = lambda c: {"ok": True, "lines": ["小林-市场 助理"]}
        self.tako.ask(steps(self.SEND, {"say": "好了"}))
        self.tako.idle()
        self.assertEqual(len(self.sent("fill")), 1, "said 小林, the title reads 小林-市场 助理")
        self.assertEqual(self.sent("openChat"), [], "it is already showing: no searching under the owner's hands")

    def test_a_longer_name_that_only_starts_the_same_is_someone_else(self):
        self.here.set()
        self.still.set()
        self.tako.native["titles"] = lambda c: {"ok": True, "lines": ["小林妈妈"]}
        self.tako.ask(steps(self.SEND, {"say": "没放"}))
        self.tako.idle()
        self.assertEqual(self.sent("fill"), [])
        self.assertIn("不是「小林」", json.dumps(self.tako.codex("tool_reply")[-1]["reply"], ensure_ascii=False))

    def test_the_owner_taking_the_pointer_mid_way_only_makes_it_wait(self):
        taken = iter([{"ok": False, "needsFront": True, "app": "微信", "error": "用户 动了鼠标或切走了窗口，已停下，没有填"}])
        needs = self.tako.native["openChat"]
        self.tako.native["openChat"] = lambda c: next(taken, None) or needs(c) if self.still.is_set() else needs(c)
        self.queued()
        self.here.set()
        self.still.set()
        self.tako.until(lambda s: any("没有发送" in text for text in self.tako.said(s)), "placed on the next try", 6)

    def test_wechat_gone_says_where_the_file_is(self):
        self.queued()
        self.tako.native["isBack"] = lambda c: {"ok": False, "error": "没找到窗口“微信”，它可能没打开"}
        seen = self.tako.until(lambda s: not s["trouble"], "the wait over", 5)
        self.assertTrue(any("名单.xlsx" in text and "没放" in text for text in self.tako.said(seen)))

    def test_a_chat_not_found_says_where_the_file_is(self):
        self.queued()
        self.tako.native["openChat"] = lambda c: {"ok": False, "error": "微信里没搜到“小林”"}
        self.here.set()
        self.still.set()
        seen = self.tako.until(lambda s: not s["trouble"], "the wait over", 5)
        self.assertTrue(any("没搜到" in text and "名单.xlsx" in text for text in self.tako.said(seen)))
        self.assertEqual(self.sent("fill"), [])

    def test_what_the_owner_says_next_keeps_it_and_the_model_hears_it_is_there(self):
        self.queued()
        self.tako.ask("顺便看看标题")
        self.tako.until(lambda s: not s["busy"] and len(self.tako.owner_turns()) == 2, "answered", 5)
        words = json.dumps(self.tako.owner_turns()[-1]["input"], ensure_ascii=False)
        self.assertIn("还排着", words)
        self.assertNotIn("/tmp/名单.xlsx", words, "a path in the instruction would count as the owner's own words")
        self.here.set()
        self.still.set()
        self.tako.until(lambda s: any("没有发送" in text for text in self.tako.said(s)), "still placed", 6)

    def test_the_model_can_call_it_off(self):
        self.queued()
        self.tako.ask(steps({"call": "fill_input", "args": {"cancel": True}}, {"say": "不放了"}))
        self.tako.until(lambda s: not s["busy"] and not s["trouble"] and len(self.tako.owner_turns()) == 2, "called off", 5)
        self.here.set()
        self.still.set()
        time.sleep(1.2)
        self.assertEqual(self.sent("fill"), [])

    def test_the_wait_is_not_shown_as_trouble_while_it_is_still_working(self):
        self.tako.ask(steps(self.SEND, {"pause": 1.2}, {"say": "好"}))
        self.tako.until(lambda s: self.sent("isBack"), "queued", 4)
        seen = self.tako.state()
        self.assertTrue(seen["busy"])
        self.assertEqual(seen["trouble"], "", "the panel reads trouble during a turn as the model being unreachable")


class WaitingOnAnotherWindow(Base):
    def setUp(self):
        super().setUp()
        self.tako.native["look"] = lambda c: {"ok": False, "needsFront": True, "id": 9, "app": "微信", "error": "这一步要 微信 在前台才能做"}
        self.tako.native["isBack"] = lambda c: {"ok": str(c.get("window")) == "9", "front": str(c.get("window")) == "9"}

    def test_watches_the_window_that_needed_it_and_gives_up_rather_than_loop(self):
        self.tako.native["isBack"] = lambda c: {"ok": False}
        self.tako.ask(steps({"call": "look_at_window", "args": {"window": "微信"}}, {"say": "差微信"}))
        seen = self.tako.until(lambda s: not s["busy"] and s["trouble"], "waiting", 5)
        self.assertIn("微信", seen["trouble"])
        self.tako.until(lambda s: [c for c in self.tako.commands if c["command"] == "isBack"], "watching", 5)
        self.assertEqual({str(c["window"]) for c in self.tako.commands if c["command"] == "isBack"}, {"9"})

    def test_a_step_that_keeps_failing_does_not_keep_calling_the_model(self):
        self.tako.ask(steps({"every_turn": True}, {"call": "look_at_window", "args": {"window": "微信"}}, {"say": "差微信"}))
        seen = self.tako.until(lambda s: any("没走通" in text for text in self.tako.said(s)), "gives up", 14)
        self.assertEqual(seen["trouble"], "")
        turns = len(self.tako.owner_turns())
        self.assertLessEqual(turns, 3)
        time.sleep(2.5)
        self.assertEqual(len(self.tako.owner_turns()), turns)


class SpeakingDuringATurn(Base):
    def test_reaches_the_running_turn_at_once(self):
        self.tako.ask(steps({"hear": True}))
        self.tako.until(lambda s: s["busy"] and self.tako.owner_turns(), "the turn running")
        self.wait_for_running()
        self.tako.ask("你怎么卡住了？")
        seen = self.tako.until(lambda s: "听到了：你怎么卡住了？" in self.tako.said(s), "the answer")
        self.assertEqual(len(self.tako.owner_turns()), 1, "no second turn")
        self.assertTrue(self.tako.requests("turn/steer")[0]["expectedTurnId"])
        self.assertEqual(seen["queued"], False)

    def wait_for_running(self):
        time.sleep(0.15)  # Between turn/start returning and the turn being known to the server.

    def test_with_files_waits_and_says_so(self):
        attached = self.tako.home / "a.txt"
        attached.write_text("内容")
        self.tako.ask(steps({"hang": True}))
        self.tako.until(lambda s: s["busy"], "busy")
        self.wait_for_running()
        self.tako.call("/ask", {"text": "看这个", "files": [str(attached)]})
        self.tako.until(lambda s: s["queued"], "shown as waiting")
        self.assertEqual(self.tako.requests("turn/steer"), [])
        self.tako.call("/stop", {})
        self.tako.until(lambda s: "好的" in self.tako.said(s) and not s["queued"], "its own turn after the stop")

    def test_just_as_the_turn_ends_still_gets_a_turn(self):
        self.tako.ask(steps({"say": "这轮完了"}))
        self.tako.until(lambda s: "这轮完了" in self.tako.said(s), "the first answer")
        self.tako.ask("还有一句")
        self.tako.until(lambda s: "好的" in self.tako.said(s), "the second answer")
        self.assertEqual(len(self.tako.owner_turns()), 2)


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

    async def test_retries_dont_count_as_the_turn_moving(self):
        await self.tako._alive()
        self.addAsyncCleanup(self.tako.runtime.close)
        await self.tako._brain()
        thread = self.tako.thread
        job = self.turns.Job("owner", None, [], None)
        job.running = (thread, "t")
        self.tako.runtime._events[thread].append({"method": "error", "params": {"threadId": thread, "willRetry": True, "error": {"message": "x"}}})
        real_event, seen = self.tako.runtime.event, []

        async def event(thread_id, *, timeout=120):
            seen.append(1)
            if len(seen) == 1:
                return await real_event(thread_id, timeout=timeout)
            if len(seen) % 2 == 0:
                raise asyncio.TimeoutError
            return {"method": "error", "params": {"threadId": thread, "willRetry": True, "error": {"message": "x"}}}
        self.tako.runtime.event = event
        with self.assertRaises(asyncio.TimeoutError):  # The real limit is fifteen minutes of quiet; here every other event is a retry.
            await self.tako._finish(job)
        self.assertLess(len(seen), 70, "a retry must not restart the clock")

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
        self.tako.on_thread["the-brain"] = self.turns.Job("owner", None, [], None)
        ran = []

        async def run(name, args, job):
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
        work = asyncio.create_task(self.tako._propose(str(source), str(copy), "改了", self.turns.Job("owner", None, [], None)))
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
