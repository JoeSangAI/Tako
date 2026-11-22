"""The real fold and incremental reader, with an isolated home and no model/API."""
import asyncio
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

HOME = tempfile.TemporaryDirectory(prefix="tako-memory-")
os.environ["TAKO_HOME"] = HOME.name
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Sources/brain"))
import ontology
import records
from entrusted import Entrusted, pace_mode
from ladder import Ladder


def judgment(op="create", actor="model", at=1, **fields):
    return {"op": op, "actor": actor, "event_at": at, "kind": "project", "id": "project:stable", "fields": fields, "source": "trace:1"}


class Fold(unittest.TestCase):
    def test_owner_wins_and_later_owner_can_correct(self):
        rows = [judgment(status="open"), judgment("update", "owner", 2, status="paused"), judgment("update", "model", 3, status="done")]
        self.assertEqual(ontology.fold(rows)["project:stable"]["status"], "paused")
        self.assertIn("status", ontology.fold(rows)["project:stable"]["disagreements"])
        rows.append(judgment("update", "owner", 4, status="done"))
        self.assertEqual(ontology.fold(rows)["project:stable"]["status"], "done")

    def test_later_event_not_append_order_wins_and_ids_stable(self):
        rows = [judgment(status="open"), judgment("update", at=3, status="done"), judgment("update", at=2, status="paused")]
        a = ontology.fold(rows)
        self.assertEqual(a["project:stable"]["status"], "done")
        self.assertEqual(a, ontology.fold(rows))
        self.assertEqual(list(a), ["project:stable"])
        self.assertEqual(ontology.fold([judgment("update", name="orphan")]), {})

    def test_summary_limit_and_priority(self):
        items = {str(n): {"id": str(n), "kind": "subject", "name": "名字" * 200, "at": n} for n in range(40)}
        items["task"] = {"id": "task", "kind": "action", "name": "未完成", "sources": ["trace:8"]}
        text = ontology.summary(items)
        self.assertLessEqual(len(text), 2000)
        self.assertIn('"id":"task"', text)
        self.assertIn('trace:8', text)


class Incremental(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=HOME.name)
        self.root = Path(self.temp.name)
        self.folder = self.root / "records"
        self.folder.mkdir()
        self.patch = patch.object(records, "folder", return_value=self.folder)
        self.patch.start()
        self.memory = ontology.Memory(root=self.root)
        self.calls = []

    def tearDown(self):
        self.patch.stop()
        self.temp.cleanup()

    def trace(self, text="状态是暂停", at=1, role="owner"):
        records._append("2026-11-17", records._block({"r": role, "at": at, "k": "desktop"}, body=text))

    async def reader(self, instructions, text, **kwargs):
        self.calls.append((instructions, json.loads(text), kwargs))
        trace = self.calls[-1][1]["traces"][-1]
        return json.dumps([{"op": "create" if not self.memory.items else "update", "kind": "project",
                            **({"id": next(iter(self.memory.items))} if self.memory.items else {}), "actor": "owner",
                            "fields": {"status": trace["text"]}, "source": trace["source"], "quote": trace["text"]}])

    async def test_empty_and_no_new_trace_never_call_reader(self):
        self.assertFalse(await self.memory.refresh(self.reader))
        self.trace()
        self.assertTrue(await self.memory.refresh(self.reader))
        identity = next(iter(self.memory.items))
        self.assertFalse(await self.memory.refresh(self.reader))
        restarted = ontology.Memory(root=self.root)
        self.assertFalse(await restarted.refresh(self.reader))
        self.assertEqual(list(restarted.items), [identity])
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.memory.path.stat().st_mode & 0o777, 0o600)

    async def test_correction_is_owner_row_and_next_context_uses_it(self):
        identity = "project:stable"
        self.memory.append([judgment(name="剪辑项目", status="进行中")])
        words = "剪辑项目的状态不是进行中，而是暂停了。"
        event = {"role": "owner", "at": time.time(), "text": words}
        self.assertEqual(await self.memory.correct(words, event, "desktop", {"kind": "desktop"}), "")
        self.assertEqual(list(self.memory.items), [identity])
        self.assertEqual(self.memory.rows[-1]["actor"], "owner")
        self.assertEqual(self.catches_source(self.memory.rows[-1]["source"]), words)
        self.assertIn('"status":"暂停了"', await self.memory.context())
        restarted = ontology.Memory(root=self.root)
        self.assertIn('"status":"暂停了"', await restarted.context())
        self.assertFalse(self.calls)

    async def test_a_correction_said_without_the_particle_lands_and_plain_talk_stays_plain(self):
        self.memory.append([judgment(name="剪辑项目", status="进行中")])
        for words, value in (("纠正：剪辑项目状态是暂停", "暂停"), ("更正一下，剪辑项目进度改成已完成。", "已完成"),
                             ("剪辑项目状态不是已完成，是暂停", "暂停")):
            event = {"role": "owner", "at": time.time(), "text": words}
            self.assertEqual(await self.memory.correct(words, event, "desktop", {"kind": "desktop"}), "", words)
            self.assertEqual(self.memory.items["project:stable"]["status"], value, words)
            self.assertEqual(self.memory.rows[-1]["actor"], "owner")
            self.assertEqual(self.memory.receipt, f"记下了：剪辑项目的状态是{value}。", "said back in the owner's terms, by name")
        rows = len(self.memory.rows)
        # No field of the memory is named, or nothing marks it as a correction: it is the turn's to understand, never a judgment.
        for words in ("纠正：第三页标题是新品发布", "剪辑项目状态是暂停", "剪辑项目现在什么状态"):
            event = {"role": "owner", "at": time.time(), "text": words}
            self.assertIsNone(await self.memory.correct(words, event, "desktop", {"kind": "desktop"}), words)
        self.assertEqual(len(self.memory.rows), rows)
        self.assertFalse(self.calls)

    def catches_source(self, source):
        name, at = source.split("#owner-")
        return next(text for meta, text in records._parse(Path(name))
                    if meta["r"] == "owner" and meta["at"] == float(at))

    async def test_assistant_cannot_acquire_owner_priority(self):
        self.trace(role="tako")
        await self.memory.refresh(self.reader)
        self.assertEqual(self.memory.rows[0]["actor"], "model")

    async def test_ambiguous_target_and_model_judgment_do_not_change_owner_fields(self):
        self.memory.append([judgment(name="剪辑项目", status="进行中"), {**judgment(name="剪辑项目"), "id": "project:other"}])
        words = "纠正：剪辑项目的状态是暂停。"
        event = {"role": "owner", "at": time.time(), "text": words}
        self.assertIn("唯一", await self.memory.correct(words, event, "desktop", {}))
        self.assertEqual(len(self.memory.rows), 2)
        self.trace(words)
        await self.memory.refresh(self.reader)
        self.assertEqual(self.memory.rows[-2]["actor"], "model")

    async def test_invalid_output_does_not_advance_cursor(self):
        self.trace()
        async def bad(*args, **kwargs):
            return '[{"op":"update","kind":"project","id":"missing"}]'
        with self.assertRaises(ValueError):
            await self.memory.refresh(bad)
        self.assertFalse(self.memory.positions)
        await self.memory.refresh(self.reader)
        self.assertTrue(self.memory.items)

    async def test_long_trace_uses_related_items_and_resumes_after_restart(self):
        self.memory.append([judgment(name="剪辑项目"), {**judgment(name="别的项目"), "id": "project:unrelated"}])
        lead = "剪辑项目" + "字" * ontology.TRACE_LIMIT
        self.trace(lead + "最后一段")
        seen = []
        async def reader(instructions, text, **kwargs):
            seen.append(json.loads(text))
            return "[]"
        self.assertTrue(await self.memory.refresh(reader))
        self.assertEqual(list(seen[0]["ontology"]), ["project:stable"])
        self.assertEqual(len(seen[0]["traces"][0]["text"]), ontology.TRACE_LIMIT)
        self.memory = ontology.Memory(root=self.root)
        self.assertTrue(await self.memory.refresh(reader))
        self.assertEqual(seen[0]["traces"][0]["text"] + seen[1]["traces"][0]["text"], lead + "最后一段")
        self.assertFalse(await ontology.Memory(root=self.root).refresh(reader))

    async def test_old_id_resolves_to_merged_item_after_restart(self):
        self.memory.append([judgment(name="剪辑项目"), {**judgment(name="同一项目"), "id": "project:old"}])
        words = "合并：project:old -> project:stable"
        event = {"role": "owner", "at": time.time(), "text": words}
        self.assertEqual(await self.memory.correct(words, event, "desktop", {}), "")
        memory = ontology.Memory(root=self.root)
        self.assertEqual(list(memory.items), ["project:stable"])
        words = "更正：project:old.status = 暂停"
        event = {"role": "owner", "at": time.time(), "text": words}
        self.assertEqual(await memory.correct(words, event, "desktop", {}), "")
        self.assertEqual(memory.items["project:stable"]["status"], "暂停")
        self.assertEqual(memory.rows[-1]["id"], "project:stable")

    async def test_idle_only(self):
        self.trace()
        self.assertFalse(await self.memory.refresh(self.reader, idle=lambda: False))
        self.assertFalse(self.calls)

    async def test_external_ontology_replaces_local_inference(self):
        class Source:
            async def read(self):
                return ontology.OntologyView({"project:external": {"id": "project:external", "kind": "project", "name": "来源项目", "sources": ["external:1"]}})
        memory = ontology.Memory(source=Source(), root=self.root)
        self.trace()
        self.assertFalse(await memory.refresh(self.reader))
        self.assertIn("project:external", await memory.context())
        self.assertFalse(memory.path.exists())

    async def test_unavailable_external_source_does_not_build_a_second_ontology(self):
        class Source:
            async def read(self):
                raise OSError()
        memory = ontology.Memory(source=Source(), root=self.root)
        self.trace()
        self.assertEqual(await memory.context(), "")
        self.assertFalse(await memory.refresh(self.reader))

    async def test_stopped_workbench_reads_its_snapshot_without_local_inference(self):
        path = self.root / "workbench-export.json"
        item = {"id": "project:external", "kind": "project", "name": "来源项目", "status": "进行中"}
        path.write_text(json.dumps({"items": [item]}, ensure_ascii=False))
        with patch.object(ontology, "CONFIG", {"workbench": {"ontology": {"snapshot": str(path)}}}):
            memory = ontology.Memory(root=self.root)
            self.assertIn('"status":"进行中"', await memory.context())
            self.assertFalse(await memory.refresh(self.reader))
            self.assertFalse(memory.path.exists())
            words = "更正：project:external.status = 已完成"
            event = {"role": "owner", "at": time.time(), "text": words}
            self.assertEqual(await memory.correct(words, event, "desktop", {"kind": "desktop"}), "")
            self.assertIn('"status":"已完成"', await ontology.Memory(root=self.root).context())
            self.assertEqual(json.loads(path.read_text())["items"], [item])
            self.assertFalse(self.calls)

    async def test_workbench_without_ontology_or_with_explicit_disable_keeps_local_memory(self):
        configs = (
            {"workbench": {"url": "http://127.0.0.1:8799"}},
            {"ontology_source": {"url": "http://127.0.0.1:8799"}},
            {"ontology_source": {"enabled": False, "snapshot": str(self.root / "missing")}},
        )
        for config in configs:
            with self.subTest(config=config), patch.object(ontology, "CONFIG", config):
                self.assertFalse(ontology.Memory(root=self.root).external)

    async def test_live_valid_empty_wins_and_non_loopback_never_opens(self):
        path = self.root / "snapshot.json"
        path.write_text('{"items":[]}')
        with patch.object(ontology, "build_opener") as factory:
            opener = factory.return_value
            opener.open.return_value = io.BytesIO(b'{"schema_version":1,"items":[]}')
            source = ontology.FileOntology(self.root / "missing", "http://127.0.0.1:8799")
            self.assertEqual(await source.read(), ontology.OntologyView())
            opener.open.assert_called_once_with("http://127.0.0.1:8799/api/ontology", timeout=0.5)
            opener.open.reset_mock()
            await ontology.FileOntology(path, "http://example.invalid").read()
            opener.open.assert_not_called()

    @unittest.skipUnless(os.environ.get("TAKO_TEST_W3_SNAPSHOT"), "requires an isolated W3 export")
    async def test_w3_export_api_and_stopped_service_use_same_read_only_view(self):
        path = Path(os.environ["TAKO_TEST_W3_SNAPSHOT"])
        exported = path.read_bytes()
        digest = hashlib.sha256(exported).digest()
        payload = json.loads(exported)
        live_payload = {k: payload[k] for k in ("schema_version", "items", "redirects", "summary")}
        with patch.object(ontology, "CONFIG", {"ontology_source": {
                "enabled": True, "snapshot": str(path), "url": "http://127.0.0.1:8799"}}), \
                patch.object(ontology, "build_opener") as factory:
            opener = factory.return_value
            opener.open.return_value = io.BytesIO(json.dumps(live_payload).encode())
            memory = ontology.Memory(root=self.root)
            live = await memory.source.read()
            opener.open.assert_called_once_with("http://127.0.0.1:8799/api/ontology", timeout=0.5)
            opener.open.side_effect = ConnectionRefusedError()
            stopped = await memory.source.read()
            self.assertTrue(live == stopped, "W3 API and export have the same ontology")
            self.assertEqual({row["kind"] for row in stopped.items.values()}, set(ontology.KINDS))
            self.assertTrue(stopped.redirects, "W3 export contains merged identities")
            self.assertTrue(any(stopped.resolve(old) in stopped.items for old in stopped.redirects))
            context = await memory.context()
            self.assertTrue(0 < len(context) <= ontology.LIMIT)
            self.assertFalse(await memory.refresh(self.reader))
            self.assertFalse(memory.path.exists())
            old = next(identity for identity in stopped.redirects if stopped.resolve(identity))
            words = f"更正：{old}.状态 = 暂停"
            event = {"role": "owner", "at": time.time(), "text": words}
            self.assertEqual(await memory.correct(words, event, "desktop", {}), "")
            self.assertTrue(memory.rows[-1]["id"] == stopped.resolve(old))
        self.assertTrue(hashlib.sha256(path.read_bytes()).digest() == digest, "W3 export stayed byte-identical")

    async def test_agent_sessions_require_consent_and_stay_in_place(self):
        path = self.root / "agents/.codex/sessions/session.jsonl"
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps({"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "项目暂停了"}]}}) + "\n")
        os.utime(path, (time.time()-120, time.time()-120))
        before = path.read_bytes()
        self.assertFalse(self.memory.agent_traces()[0])
        (self.root / "ladder.json").write_text('{"memory_access":"connected"}')
        await self.memory.refresh(self.reader)
        self.assertEqual(path.read_bytes(), before)
        self.assertIn(str(path), await self.memory.context())
        self.assertFalse(await self.memory.refresh(self.reader))


class Reminders(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=HOME.name)
        self.root = Path(self.temp.name)
        self.patch = patch.object(records, "folder", return_value=self.root / "records")
        self.patch.start()
        self.hand = Entrusted(Ladder(self.root / "ladder.json"))
        self.now = time.time()

    def tearDown(self):
        self.patch.stop()
        self.temp.cleanup()

    def item(self, n, **extra):
        item = {"id": str(n), "state": "held", "text": "事情", "created": self.now-10000, "held_since": self.now-10000, "place": {"app": "Editor"}, **extra}
        self.hand.items[str(n)] = item
        return item

    def tick(self, **extra):
        return self.hand.tick({"matched": ["1"], **extra}, now=self.now)

    def test_no_seven_second_dismissal_and_leave_returns_to_hand(self):
        self.item(1)
        self.assertIsNotNone(self.tick()["offer"])
        self.now += 8
        self.assertIsNotNone(self.tick()["offer"])
        self.assertEqual(self.hand.items["1"].get("ignored_streak", 0), 0)
        self.assertIsNone(self.tick(matched=[])["offer"])
        self.assertEqual(self.hand.items["1"]["state"], "held")
        self.assertIsNotNone(self.tick()["offer"])
        self.assertIsNone(self.tick(away=True)["offer"])

    def test_full_untouched_place_offer_waits_half_an_hour_even_after_restart(self):
        item = self.item(1, created=self.now - 5 * 3600)
        records.entrust({**item, "action": "keep", "at": self.now})
        self.assertEqual(self.tick()["offer"]["reason"], "place")
        self.now += 2
        shown_at = self.now
        self.assertIsNotNone(self.tick(shown="1")["offer"])
        self.now += 6
        self.assertIsNone(self.tick(matched=[])["offer"])
        self.hand = Entrusted(Ladder(self.root / "ladder.json"))
        self.assertEqual(self.hand.items["1"]["action"], "offered")
        daily = self.hand.daily.copy()
        self.now = shown_at + 1799
        state = self.tick(returned=True)
        self.assertIsNone(state["offer"])
        self.assertEqual(state["count"], 1)
        self.assertEqual(self.hand.daily, daily)
        self.assertEqual(self.hand.items["1"].get("ignored_streak", 0), 0)
        self.tick(matched=[])
        self.now += 1
        self.assertEqual(self.tick()["offer"]["id"], "1")

    def test_leaving_a_soft_offer_can_return_to_the_same_place(self):
        self.item(1)
        self.assertTrue(self.tick(arriving=True)["offer"]["soft"])
        self.now += 1
        self.assertIsNone(self.tick(matched=[])["offer"])
        self.assertFalse(self.hand.daily)
        self.assertIsNotNone(self.tick()["offer"])

    def test_touching_a_full_offer_keeps_the_old_place_rules(self):
        self.item(1)
        self.tick()
        self.now += 2
        self.tick(shown="1")
        self.now += 5
        self.assertIsNone(self.tick(matched=[], touched="1")["offer"])
        self.assertEqual(self.hand.items["1"].get("ignored_streak", 0), 0)
        self.assertEqual(self.tick()["offer"]["id"], "1")

    def test_hovering_to_expand_interrupts_the_untouched_offer_rule(self):
        self.item(1)
        self.assertTrue(self.tick(arriving=True)["offer"]["soft"])
        self.assertFalse(self.tick(touched="1")["offer"]["soft"])
        self.now += 2
        self.tick(shown="1")
        self.assertIsNone(self.tick(matched=[])["offer"])
        self.assertIsNotNone(self.tick()["offer"])

    def test_due_offer_takes_its_turn_while_place_offer_is_waiting(self):
        self.item(1)
        self.item(2, due=self.now + 10)
        self.tick()
        self.now += 2
        self.tick(shown="1")
        self.now += 8
        self.assertEqual(self.tick(matched=[])["offer"]["id"], "2")
        self.assertTrue(self.hand.respond("2", "done"))
        self.assertIsNone(self.tick()["offer"])

    def test_three_ignores_only_hold_and_one_at_a_time(self):
        self.item(1); self.item(2)
        for n in range(3):
            self.assertEqual(self.tick(matched=["1", "2"])["offer"]["id"], "1")
            self.now += 61
            self.assertIsNotNone(self.tick()["offer"])
            self.assertEqual(self.hand.items["1"]["ignored_streak"], n + 1)
            self.tick(matched=[])
            self.now += 86401
        self.assertIsNone(self.tick()["offer"])
        self.assertEqual(len(self.hand.pending()), 2)

    def test_hover_resets_ignore_clock_and_typing_does_not_interrupt(self):
        self.item(1)
        self.assertTrue(self.tick(typing=True)["offer"]["soft"])
        self.assertFalse(self.hand.daily)
        self.assertFalse(self.tick(hovered=True)["offer"]["soft"])
        self.now += 59
        self.tick(hovered=True)
        self.now += 2
        self.tick()
        self.assertEqual(self.hand.items["1"].get("ignored_streak", 0), 0)
        self.tick(typing=True)
        self.now += 11
        self.assertIsNone(self.tick(typing=True)["offer"])
        self.assertEqual(self.hand.items["1"].get("ignored_streak", 0), 0)

    def test_soft_offer_waits_for_pause_and_due_has_first_claim(self):
        self.item(1)
        self.item(2, due=self.now + 3)
        self.assertTrue(self.tick(arriving=True)["offer"]["soft"])
        self.now += 1
        self.assertTrue(self.tick()["offer"]["soft"])
        self.now += 2
        offer = self.tick()["offer"]
        self.assertEqual(offer["id"], "2")
        self.assertFalse(offer["soft"])
        self.assertFalse(self.hand.daily)

    def test_quiet_day_replays_without_suppressing_timed_promises(self):
        self.item(1)
        self.item(2, due=self.now + 3)
        for item in self.hand.pending():
            records.entrust({**item, "action": "keep", "at": self.now})
        self.assertTrue(self.hand.pace("今天别找我。", self.now))
        self.hand = Entrusted(Ladder(self.root / "ladder.json"))
        self.assertIsNone(self.tick()["offer"])
        self.now += 4
        self.assertEqual(self.tick()["offer"]["id"], "2")
        self.hand.respond("2", "done")
        self.assertTrue(self.hand.pace("恢复正常提醒", self.now))
        self.assertEqual(self.tick()["offer"]["id"], "1")

    def test_pace_is_heard_the_ways_an_owner_says_it_and_nothing_else_is(self):
        said = {
            "today": ("今天别找我", "今天别找我了。", "今天别提醒我了", "今天不要打扰我", "Tako，今天先别找我了", "今天就不要再提醒我了吧", "今天别主动提醒我"),
            "fewer": ("以后少提醒我", "以后少提醒一点", "少提醒我一点", "以后少找我", "以后提醒少一点", "提醒太多了", "你提醒得太多了，少一点"),
            "normal": ("恢复正常提醒", "恢复主动提醒", "恢复提醒吧", "可以正常提醒我了", "今天可以找我了"),
        }
        for mode, sentences in said.items():
            for words in sentences:
                self.assertEqual(pace_mode(words), mode, words)
        # A sentence about one thing, about someone else, or with anything more in it is a job like any other.
        for words in ("以后少提醒我喝水", "今天别提醒我开会的事", "别提醒我了", "今天别找他", "提醒我少喝点", "恢复正常",
                      "今天别找我要报价", "以后少提醒我，另外帮我看看这页", "今天别找我了，明天十点提醒我交稿", ""):
            self.assertIsNone(pace_mode(words), words)

    def test_fewer_and_normal_said_naturally_change_the_cap_and_keep_timed_promises(self):
        for n in range(1, 6):
            self.item(n, place={})
        self.item(9, due=self.now + 5)
        self.assertIn("三次", self.hand.pace("你提醒得太多了，少一点", self.now))
        for n in range(1, 4):
            self.assertEqual(self.tick(matched=[], returned=True)["offer"]["id"], str(n))
            self.hand.respond(str(n), "done")
        self.assertIsNone(self.tick(matched=[], returned=True)["offer"], "three a day once the owner asked for fewer")
        self.now += 6
        self.assertEqual(self.tick(matched=[])["offer"]["id"], "9", "what has a time still comes")
        self.hand.respond("9", "done")
        self.assertTrue(self.hand.pace("可以正常提醒我了", self.now))
        self.assertEqual(self.tick(matched=[], returned=True)["offer"]["id"], "4")

    def test_recent_owner_promise_can_be_restored_once(self):
        item = self.item(1)
        item["source"] = "owner"
        records.entrust({**item, "action": "keep", "at": self.now})
        self.assertTrue(self.hand.respond("1", "cancel"))
        self.hand = Entrusted(Ladder(self.root / "ladder.json"))
        self.assertEqual([i["id"] for i in self.hand.native_state()["recently_put_down"]], ["1"])
        self.assertTrue(self.hand.respond("1", "restore"))
        self.assertFalse(self.hand.respond("1", "restore"))
        self.assertEqual(Entrusted(Ladder(self.root / "ladder.json")).items["1"]["state"], "held")

    def test_system_reminder_ignores_survive_restart_without_words(self):
        reminders = [{"id": "reminder-id", "title": "联系人 排期"}]
        self.hand.sources(reminders, [], {"联系人"})
        item = self.hand.pending()[0]
        for _ in range(3):
            self.assertTrue(self.hand.respond(item["id"], "ignored"))
        self.hand = Entrusted(Ladder(self.root / "ladder.json"))
        self.hand.sources(reminders, [], {"联系人"})
        self.assertEqual(self.hand.pending()[0]["ignored_streak"], 3)
        self.assertNotIn(reminders[0]["title"], (self.root / "ladder.json").read_text())
        self.assertIsNone(self.tick(matched=[item["id"]])["offer"])

    def test_system_reminder_exposure_survives_restart_without_words(self):
        reminders = [{"id": "reminder-id", "title": "联系人 排期"}]
        self.hand.sources(reminders, [], {"联系人"})
        identity = self.hand.pending()[0]["id"]
        self.assertEqual(self.tick(matched=[identity])["offer"]["id"], identity)
        self.tick(matched=[identity], shown=identity)
        self.hand = Entrusted(Ladder(self.root / "ladder.json"))
        self.hand.sources(reminders, [], {"联系人"})
        self.assertIsNone(self.tick(matched=[identity])["offer"])
        self.assertNotIn(reminders[0]["title"], (self.root / "ladder.json").read_text())
        self.assertFalse((self.root / "records").exists())

    def test_daily_six_and_restart_replays_limit(self):
        for n in range(7):
            self.item(n)
        for n in range(6):
            self.assertEqual(self.tick(matched=[str(n)])["offer"]["id"], str(n))
            self.hand.respond(str(n), "done")
        self.assertIsNone(self.tick(matched=["6"])["offer"])
        self.assertIsNone(Entrusted(Ladder(self.root / "ladder.json")).tick({"matched":["6"]}, now=self.now)["offer"])
        self.now += 86401
        self.assertIsNotNone(self.tick(matched=["6"])["offer"])

    def test_meeting_recording_fullscreen_are_quiet_even_when_due(self):
        self.item(1, due=self.now-1)
        self.assertIsNone(self.tick(muted=True)["offer"])
        self.assertIsNone(self.tick(fullscreen=True)["offer"])
        self.assertIsNotNone(self.tick()["offer"])
        self.assertIsNone(self.tick(muted=True)["offer"])
        self.assertEqual(self.hand.items["1"].get("ignored_streak", 0), 0)

    def test_overdue_bypasses_quota_and_stays_due_across_quiet_and_restart(self):
        from settings import ZONE
        from datetime import datetime
        today = datetime.fromtimestamp(self.now, ZONE).date().isoformat()
        self.hand.daily = self.hand.ladder.state["deliveries"] = {today: 6}
        self.hand.ladder._save()
        for n in (2, 1):
            item = self.item(n, due=self.now + n, ignored_streak=3)
            records.entrust({**item, "action": "keep", "at": self.now})
        self.now += 5
        self.assertIsNone(self.tick(muted=True)["offer"])
        self.hand = Entrusted(Ladder(self.root / "ladder.json"))
        self.assertEqual(self.tick()["offer"]["id"], "1")
        self.now += 61
        self.assertEqual(self.tick()["offer"]["id"], "1")
        self.assertFalse(self.hand.respond("1", "ignored"))
        self.assertEqual(self.hand.items["1"]["ignored_streak"], 3)
        self.assertIsNone(self.tick(fullscreen=True)["offer"])
        self.assertEqual(self.tick()["offer"]["id"], "1")
        self.hand.respond("1", "done")
        self.assertEqual(self.tick()["offer"]["id"], "2")
        self.assertEqual(self.hand.daily, {today: 6})

    def test_many_items_share_count_and_native_order(self):
        for n in range(14):
            self.item(n, due=self.now+n if n < 2 else None)
        self.assertEqual(self.tick(busy=True)["count"], 14)
        self.assertEqual(len(self.hand.native_state()["items"]), 14)
        self.assertEqual(self.hand.native_state()["items"][0]["id"], "0")


class HeldList(unittest.TestCase):
    def test_fourteen_items_scroll_and_the_completed_section_stays_collapsed_until_opened(self):
        page = (Path(__file__).resolve().parents[1] / "Sources/brain/side.html").read_text()
        block = page[page.index("const empty = document.createElement('div'), emptyLine"):page.index("// The one invitation the desktop panel")]
        self.assertIn("max-height: 220px; overflow-y: auto", page)
        harness = r"""
class Element {
  constructor(tag) { this.tag = tag; this.children = []; this.hidden = false; this.scrollTop = 0; }
  append(...items) { this.children.push(...items); }
  replaceChildren(...items) { this.children = items; }
  querySelector(cls) { for (const c of this.children) { if ('.' + c.className === cls) return c; const v = c.querySelector?.(cls); if (v) return v; } return null; }
}
const log = new Element('log'), held = new Element('held');
const document = { createElement: (tag) => new Element(tag) };
const $ = (id) => id === 'log' ? log : held;
const window = {}, actions = [];
const native = {postMessage: (action) => actions.push(action)};
""" + block + r"""
const data = Array.from({length:14}, (_, n) => ({id:String(n), text:'核对材料', place:{app:'微信', chat:'联系人'}}));
const recent = [{id:'old-id', text:'放下的材料'}];
window.setHeldItems(data, recent, ['12']);
showHeld({kind:'wechat', held_here:['11']});
const [title, scroll] = held.children;
const completed = scroll.children.at(-1);
if (held.hidden || title.textContent !== '待办 14' || scroll.children.length !== 15) throw Error('lost items');
if (completed.tag !== 'details' || completed.open || completed.children[0].textContent !== '已完成') throw Error('completed section was not collapsed');
for (const n of [11, 12]) {
  const line = scroll.children[n].children[0].children[0];
  if (line.tag !== 'div' || line.onclick) throw Error('same chat offered to jump');
}
const [task, done, secondary] = scroll.children[13].children;
const [line, when] = task.children;
const [later, dot, remove] = secondary.children;
if (line.tag !== 'button' || when.textContent !== '微信 · 联系人' || done.textContent !== '✓ 做完了' ||
    later.textContent !== '稍后' || remove.textContent !== '删除') throw Error('wrong to-do controls');
for (const control of [line, done, later, remove]) control.onclick();
if (JSON.stringify(actions) !== JSON.stringify(['look','done','later','cancel'].map(heldAction => ({heldAction, heldID:'13'})))) throw Error('wrong actions');
scroll.scrollTop = 100; completed.open = true;
window.setHeldItems(data, recent, ['12']);
if (held.children[1] !== scroll || scroll.scrollTop !== 100) throw Error('poll reset list');
showHeld({kind:'desktop'});
if (held.children[1].children[11].children[0].children[0].tag !== 'button') throw Error('switching away left stale chat state');
window.setHeldItems(data.slice(0,13), recent);
if (held.children[1].scrollTop !== 100 || !held.children[1].children.at(-1).open ||
    held.children[1].children[12].children[0].children[0].tag !== 'button') throw Error('update lost position or used stale foreground');
window.setHeldItems([], recent);
if (held.hidden || held.children[0].textContent !== '待办 0') throw Error('cannot recover with no pending items');
const restore = held.children[1].children[0].children[1].children[1];
if (restore.textContent !== '恢复') throw Error('wrong restore label');
restore.onclick();
if (actions.at(-1).heldID !== 'old-id' || actions.at(-1).heldAction !== 'restore') throw Error('wrong restore target');

"""
        subprocess.run(["node", "-e", harness], check=True, capture_output=True)


if __name__ == "__main__":
    unittest.main()
