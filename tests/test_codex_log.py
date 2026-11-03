"""What Codex's own log may keep of a turn, against a stand-in that builds its databases the way 0.163.0 does.
Run: python3 tests/test_codex_log.py
"""
import asyncio
import contextlib
import json
import os
import pathlib
import sqlite3
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Sources/brain"))
sys.path.insert(0, str(ROOT / "Sources/brain/vendor"))
os.environ.setdefault("TAKO_HOME", tempfile.mkdtemp())
import codex_runtime  # noqa: E402

CODEX = f"""#!{sys.executable}
import json, os, sqlite3, sys
home = os.environ["CODEX_SQLITE_HOME"]
os.makedirs(home, exist_ok=True)
with open(os.environ["STARTS"], "a") as starts:
    starts.write(json.dumps({{"home": home, "codex_home": os.environ.get("CODEX_HOME"), "empty": not os.listdir(os.environ.get("CODEX_HOME") or "/")}}) + "\\n")
db = sqlite3.connect(os.path.join(home, "logs_2.sqlite"))
db.execute("CREATE TABLE IF NOT EXISTS logs (id INTEGER PRIMARY KEY, feedback_log_body TEXT)")
db.execute("INSERT INTO logs (feedback_log_body) VALUES ('starting up')")
db.commit()
for line in sys.stdin:
    message = json.loads(line)
    if "id" in message:
        print(json.dumps({{"id": message["id"], "result": {{}}}}), flush=True)
"""


class CodexLog(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.folder = pathlib.Path(folder.name)
        self.state = self.folder / "tako" / "codex-state"
        self.codex = self.folder / "codex"
        self.codex.write_text(CODEX)
        self.codex.chmod(self.codex.stat().st_mode | stat.S_IEXEC)
        self.starts = self.folder / "starts"
        real_home = self.folder / "real-home"
        real_home.mkdir()
        (real_home / "sessions").mkdir()
        for patcher in (mock.patch.object(codex_runtime, "CODEX_STATE", self.state), mock.patch.object(codex_runtime, "CONFIG", {}),
                        mock.patch.dict(os.environ, {"STARTS": str(self.starts), "CODEX_HOME": str(real_home)})):
            patcher.start()
            self.addCleanup(patcher.stop)

    def _start(self):
        async def go():
            runtime = codex_runtime.CodexRuntime(str(self.codex))
            await runtime.start()
            await runtime.close()
        asyncio.run(go())
        return [json.loads(line) for line in self.starts.read_text().splitlines()]

    def _rows_after_writing(self):
        with contextlib.closing(sqlite3.connect(self.state / "logs_2.sqlite")) as db, db:
            db.execute("INSERT INTO logs (feedback_log_body) VALUES ('a whole screenshot')")
            return db.execute("SELECT feedback_log_body FROM logs").fetchall()

    def test_a_screenshot_in_a_tool_result_is_not_kept(self):
        self._start()
        self.assertEqual(self._rows_after_writing(), [])

    def test_the_server_keeps_its_log_in_takos_folder_and_only_there(self):
        built, serving = self._start()
        self.assertEqual({built["home"], serving["home"]}, {str(self.state)})
        self.assertEqual(stat.S_IMODE(self.state.stat().st_mode), 0o700)
        self.assertEqual(serving["codex_home"], os.environ["CODEX_HOME"])

    def test_the_database_is_built_without_the_owners_sessions(self):
        built, _ = self._start()
        self.assertNotEqual(built["codex_home"], os.environ["CODEX_HOME"])
        self.assertTrue(built["empty"])

    def test_what_a_crashed_run_left_is_gone_at_the_next_start(self):
        self.state.mkdir(parents=True)
        leftover = self.state / "logs_1.sqlite"
        leftover.write_text("an old screenshot")
        self._start()
        self.assertFalse(leftover.exists())

    def test_an_owner_debugging_can_keep_the_log_until_the_next_start(self):
        with mock.patch.object(codex_runtime, "CONFIG", {"keep_codex_log": True}):
            self._start()
        self.assertEqual([row[0] for row in self._rows_after_writing()], ["starting up", "a whole screenshot"])

    def test_a_failed_build_does_not_stop_the_real_start(self):
        with mock.patch.object(subprocess, "run", side_effect=subprocess.TimeoutExpired("codex", 30)):
            starts = self._start()
        self.assertEqual(len(starts), 1)


if __name__ == "__main__":
    unittest.main()
