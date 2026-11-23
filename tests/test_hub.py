"""The owner's hub (`hub.py`): one record per entrusted thing, what to bring up comes from there, answers go back.

Run: python3 tests/test_hub.py. A made-up hub on a loopback port speaks the ontology engine's reminders format; the
home and the records are made up too.
"""
import atexit
import datetime
import json
import os
import pathlib
import shutil
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = pathlib.Path(__file__).resolve().parent.parent
if "TAKO_HOME" not in os.environ:
    _home = tempfile.mkdtemp(prefix="tako-test-")
    atexit.register(shutil.rmtree, _home, True)
    pathlib.Path(_home, "config.json").write_text(json.dumps({"name": "Alex"}))
    os.environ["TAKO_HOME"] = _home
sys.path.insert(0, str(ROOT / "Sources/brain"))


class FakeHub:
    """Keeps what it is handed, the way the engine does: a request repeated is the same record."""
    def __init__(self):
        self.posts, self.entrusted, self.closed, self.listed, self.down = [], {}, set(), [], False
        hub = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, status, body):
                data = json.dumps(body, ensure_ascii=False).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                if hub.down:
                    return self.reply(503, {})
                own = [{"id": i, "title": b["text"], "origin": "entrusted", "open": True, "occasions": []}
                       for i, b in hub.entrusted.items() if i not in hub.closed]
                self.reply(200, {"schema": 1, "items": [*own, *(i for i in hub.listed if i["id"] not in hub.closed)]})

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                if hub.down:
                    return self.reply(503, {})
                hub.posts.append(body)
                if body["op"] == "entrust":
                    identity = "e-" + body["request_id"]
                    created = identity not in hub.entrusted
                    hub.entrusted.setdefault(identity, body)
                    return self.reply(201 if created else 200, {"item": {"id": identity, "open": identity not in hub.closed}, "created": created})
                if body["response"] in ("done", "dropped"):
                    hub.closed.add(body["id"])
                self.reply(201, {"id": body["id"], "response": body["response"], "open": body["id"] not in hub.closed})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_port}/api/ontology"

    def responses(self):
        return [(b["id"], b["response"]) for b in self.posts if b["op"] == "respond"]


class HubScenes(unittest.TestCase):
    def setUp(self):
        import records
        import settings
        from entrusted import Entrusted
        from hub import Hub
        from turns import Job
        self.settings = settings
        self.directory = tempfile.TemporaryDirectory(prefix="tako-hub-")
        self.addCleanup(self.directory.cleanup)
        old = settings.OUTPUT_ROOT
        settings.OUTPUT_ROOT = pathlib.Path(self.directory.name)
        self.addCleanup(setattr, settings, "OUTPUT_ROOT", old)
        self.fake = FakeHub()
        self.addCleanup(self.fake.server.shutdown)
        self.Hub, self.Entrusted = Hub, Entrusted
        self.hand = Entrusted()
        for key in ("deliveries", "hub_deliveries", "reminder_pacing", "quiet_day", "fewer_deliveries"):
            self.hand.ladder.state.pop(key, None)
        self.hand.daily = {}
        self.hand.hub = Hub(self.fake.url, self.directory.name)
        self.job = Job({"username": "desktop", "name": "你", "kind": "desktop"}, [], None)
        self.job.owner_words = "见到林青提醒我样稿的事"
        self.job.record_id = 1
        self.job.asked_at = 0
        self.now = time.time()

    def sync(self, now=None):
        held = [i for i in self.hand.own_pending() if i.get("source") == "owner"]
        outlet = self.hand.hub.exchange(held)
        if outlet is not None:
            self.hand.from_hub(outlet, self.now if now is None else now)
        return outlet

    def tick(self, now=None, **context):
        return self.hand.tick({"matched": [], "fullscreen": False, **context}, self.now if now is None else now)

    def listed(self, identity, title, *occasions, **extra):
        self.fake.listed.append({"id": identity, "title": title, "origin": "ledger", "open": True, "reason": "", "speak": True,
                                 "occasions": list(occasions), **extra})

    def test_what_the_owner_entrusts_is_one_record_there_and_one_in_the_hand(self):
        item = self.hand.change({"action": "keep", "quote": "见到林青提醒我样稿的事", "text": "样稿的事", "place": {"chat": "林青"}}, self.job)
        self.sync(); self.sync()
        handed = [b for b in self.fake.posts if b["op"] == "entrust"]
        self.assertEqual([(b["request_id"], b["text"], b["people"]) for b in handed], [("tako:" + item["id"], "样稿的事", ["林青"])])
        self.assertEqual([i["id"] for i in self.hand.pending()], [item["id"]])  # the hub's copy is this same thing
        self.hand.respond(item["id"], "done")
        self.sync()
        self.assertEqual(self.fake.responses(), [("e-tako:" + item["id"], "done")])

    def test_what_cannot_be_delivered_waits_and_goes_once(self):
        self.fake.down = True
        item = self.hand.change({"action": "keep", "quote": "见到林青提醒我样稿的事", "text": "样稿的事"}, self.job)
        self.assertIsNone(self.sync())
        self.hand.respond(item["id"], "done")
        self.assertIsNone(self.sync())
        self.assertEqual(self.fake.posts, [])
        later = self.Hub(self.fake.url, self.directory.name)  # Tako restarted meanwhile: what waited is still there
        self.assertEqual([b["op"] for b in later.outbox], ["entrust", "respond"])
        self.fake.down = False
        self.assertIsNotNone(later.exchange())
        self.assertIsNotNone(later.exchange())
        self.assertEqual([b["op"] for b in self.fake.posts], ["entrust", "respond"])
        self.assertEqual(self.fake.responses(), [("e-tako:" + item["id"], "done")])

    def test_a_person_from_the_hub_comes_up_in_their_chat_once_a_day_with_the_reason(self):
        person = {"type": "person", "why": "concerns", "people": [{"id": "p1", "name": "林青", "aliases": ["青姐"]}]}
        self.listed("a1", "核对报价", person)
        self.listed("a2", "发样稿", person)
        self.sync()
        state = self.hand.native_state()
        self.assertEqual({i["place"]["names"] for i in state["items"]}, {"林青\n青姐"})
        self.assertIsNone(self.tick()["offer"])  # nothing by itself: the occasion is seeing them
        offer = self.tick(matched=["h:a1", "h:a2"])["offer"]
        self.assertEqual((offer["id"], offer["reason"], offer["text"]), ("h:a1", "place", "打开了林青的聊天，有 2 件：核对报价"))
        self.assertTrue(self.hand.respond("h:a1", "later"))
        self.assertEqual(self.hand.later_line("h:a1"), "好，今天不再提。")
        self.sync()
        self.assertEqual(self.fake.responses(), [("a1", "later")])
        self.assertEqual(self.fake.posts[-1]["occasion"], {"type": "person", "reason": "place"})
        self.hand.visited.clear()
        self.assertIsNone(self.tick(now=self.now + 7200, matched=["h:a1", "h:a2"])["offer"])  # both were said today
        tomorrow = self.now + 86400
        self.sync(tomorrow)
        self.assertEqual(self.tick(now=tomorrow, matched=["h:a1", "h:a2"])["offer"]["id"], "h:a1")

    def test_a_clock_time_rings_and_done_goes_back(self):
        at = datetime.datetime.fromtimestamp(self.now + 60, self.settings.ZONE).isoformat(timespec="seconds")
        self.listed("t1", "给客户回电话", {"type": "time", "at": at, "kind": "appointment", "due": False})
        self.sync()
        self.assertIsNone(self.tick()["offer"])
        offer = self.tick(now=self.now + 61)["offer"]
        self.assertEqual((offer["reason"], offer["text"]), ("due", "到点了：给客户回电话"))
        self.assertTrue(self.hand.respond("h:t1", "done"))
        self.sync(self.now + 62)
        self.assertEqual(self.fake.responses(), [("t1", "done")])
        self.assertEqual(self.hand.pending(), [])  # ended there, gone from the hand

    def test_only_the_longest_stalled_is_asked_about_with_three_answers(self):
        self.listed("s1", "换宽带", {"type": "state", "state": "stalled", "days": 20})
        self.listed("s2", "核对费用", {"type": "state", "state": "stalled", "days": 50})
        self.listed("d1", "交报告", {"type": "time", "at": "2000-01-01", "kind": "target", "due": True}, reason="已过期")
        self.sync()
        asked = self.tick(now=self.now + 10, returned=True)["offer"]   # a day long past is the hub's to show, not pushed here
        self.assertEqual((asked["id"], asked["text"], asked["choice"]), ("h:s2", "停了 50 天：核对费用", "stalled"))
        self.assertTrue(self.hand.respond("h:s2", "today"))
        self.assertEqual(self.hand.later_line("h:s2", "today"), "好，今天做。")
        self.sync(self.now + 11)
        self.assertEqual(self.fake.responses(), [("s2", "later")])
        self.assertIsNone(self.tick(now=self.now + 3600, returned=True)["offer"])

    def test_the_hubs_to_dos_are_never_listed_or_counted(self):
        person = {"type": "person", "why": "concerns", "people": [{"id": "p1", "name": "林青", "aliases": []}]}
        for n in range(4):
            self.listed(f"p{n}", f"事情{n}", person)
        self.fake.listed.append({"id": "mine", "title": "手机上交代的事", "origin": "entrusted", "open": True, "occasions": []})
        self.sync()
        state = self.tick()
        self.assertEqual((state["count"], state["holding"]), (1, True))   # only what the owner entrusted themselves
        native = self.hand.native_state()["items"]
        self.assertEqual(sorted(i["id"] for i in native if not i.get("quiet")), ["h:mine"])
        self.assertEqual(len(native), 5)   # the rest still reach the app, to be matched with the open chat

    def test_what_the_hub_does_not_mark_is_never_said(self):
        person = {"type": "person", "why": "concerns", "people": [{"id": "p1", "name": "林青", "aliases": []}]}
        self.listed("q1", "核对报价", person, speak=False)
        self.fake.listed[-1].pop("speak")
        self.sync()
        self.assertEqual(self.hand.pending(), [])
        self.assertIsNone(self.tick(matched=["h:q1"])["offer"])

    def test_ended_somewhere_else_tako_puts_it_down(self):
        item = self.hand.change({"action": "keep", "quote": "见到林青提醒我样稿的事", "text": "样稿的事"}, self.job)
        self.sync()
        self.fake.closed.add("e-tako:" + item["id"])
        self.hand.hub.twins.clear()  # as after a restart: it asks again and learns it is closed
        self.sync()
        self.assertEqual(self.hand.items[item["id"]]["state"], "done")
        self.assertEqual(self.hand.items[item["id"]]["reason"], "elsewhere")

    def test_a_small_group_about_it_only_points_at_the_count(self):
        person = {"type": "person", "why": "concerns", "people": [{"id": "p1", "name": "林青", "aliases": []}]}
        self.listed("g1", "核对报价", person, project={"id": "x", "name": "纸鸢展", "aliases": ["风筝展"]})
        self.sync()
        item = next(i for i in self.hand.native_state()["items"] if i["id"] == "h:g1")
        self.assertEqual(item["place"], {"chat": "林青", "names": "林青", "project": "纸鸢展\n风筝展"})
        state = self.tick(near=["h:g1"])
        self.assertTrue(state["nudge"])
        self.assertIsNone(state["offer"])           # no bubble in a group
        self.assertNotIn("nudge", self.tick(near=["h:g1"]))   # once while that chat stays open
        self.tick()
        self.assertTrue(self.tick(near=["h:g1"])["nudge"])   # back there later: once more

    def test_only_a_loopback_hub_is_spoken_to(self):
        from hub import endpoint
        self.assertEqual(endpoint("http://127.0.0.1:8766/api/ontology"), "http://127.0.0.1:8766/api/ontology/reminders")
        for url in ("https://example.com/api/ontology", "http://127.0.0.1:1/other", "http://user@127.0.0.1:1/api/ontology", None):
            self.assertIsNone(endpoint(url))
        self.assertFalse(self.Hub(None, self.directory.name).enabled)


if __name__ == "__main__":
    unittest.main()
