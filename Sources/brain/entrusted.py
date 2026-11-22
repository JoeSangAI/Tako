"""Things the owner entrusted to Tako. Replay the one record; deliver without a model.

The native side compares app/title strings locally. Only matching ids and quiet-state
booleans arrive here; a window's title or contents never do. All methods run on the
Companion loop, including HTTP requests, so a response and a timer cannot race.
"""
from __future__ import annotations

import datetime
import math
import re
import time
import uuid

import records
import ladder as rungs
from settings import ZONE

RELATIVE = re.compile(r"(?:\d+(?:\.\d+)?|[零一二两三四五六七八九十百半几]+)\s*(?:个)?(?:秒|分钟|分|小时|钟头)\s*(?:以?后|之后)|\bin\s+\d+(?:\.\d+)?\s+(?:seconds?|minutes?|hours?)\b", re.I)
CLOCK_TIME = re.compile(r"\d{1,2}[:：]\d{2}|(?:\d+|[一二两三四五六七八九十]+)\s*点")
# How often Tako comes up, said the ways an owner says it. Each pattern is the whole sentence: one with anything more in it
# (以后少提醒我喝水, 今天别找我要报价) is about a thing and stays a job for the turn. Compared here, no model.
_COME = r"(?:主动)?(?:来)?(?:找|提醒|打扰|烦)"
_TO_ME = _COME + "我"
_SOFT = r"(?:了|吧|啦|哈|啊|呀|好吗|行吗|可以吗|好不好)*"
_LESS = r"(?:一?点儿?|一些)"
PACE = (
    ("today", re.compile(rf"(?:今天|今日)(?:先|就)?(?:别|不要|不用)(?:再)?{_TO_ME}{_SOFT}")),
    ("fewer", re.compile(rf"(?:(?:以后|今后|往后)?(?:请)?少{_COME}我?{_LESS}?|(?:以后|今后|往后)?提醒(?:得)?少{_LESS}"
                         rf"|(?:你)?提醒(?:得)?太多了?(?:少{_LESS})?){_SOFT}")),
    ("normal", re.compile(rf"(?:(?:可以)?恢复(?:正常|主动|原来的?|平时的?)?提醒我?|(?:现在|今天)?(?:可以)?(?:照常|正常){_TO_ME}"
                          rf"|(?:现在|今天)?可以(?:再)?{_TO_ME}){_SOFT}")),
)
_CALLED = re.compile(r"^(?:tako|章鱼|小章鱼)[，,：:\s]*", re.I)
SYSTEM_PACING = ("deferred", "deferred_at", "ignored_streak", "place_shown_at")
PLACE_WAIT_SECONDS = 4 * 3600  # Prefer a relevant place first; a morning promise can still surface that afternoon.
PLACE_REPEAT_SECONDS = 30 * 60
HOURS = {1: "一", 2: "两", 4: "四", 8: "八", 16: "十六"}


def pace_mode(words):
    """today, fewer or normal when the whole sentence is about how often Tako comes up; None for everything else."""
    said = re.sub(r"[\s，,。！!～~、]+", "", _CALLED.sub("", str(words or "").strip()))
    return next((mode for mode, pattern in PACE if pattern.fullmatch(said)), None)


def wait_after(deferred):
    """How long a deferred or opened item waits before another occasion: half an hour, doubling, at most a day."""
    return min(86400, 1800 * 2 ** min(6, max(0, deferred - 1)))


def later_line(seconds):
    """What 稍后 says before the hand goes back: the real wait, in plain words."""
    if seconds < 3600:
        return "好，半小时后再说。"
    if seconds >= 86400:
        return "好，明天再说。"
    hours = seconds // 3600
    return f"好，{HOURS.get(hours, str(hours))}小时后再说。"


def with_age(text, created, now):
    """A promise about someone, a day old or more, says how long ago it was made: 你问过他排期 becomes 你 5 天前问过他排期."""
    days = int((now - created) // 86400)
    if days < 1:
        return text
    return f"你 {days} 天前{text[1:]}" if text.startswith("你") and not text.startswith("你们") else f"{text}（{days} 天前）"


def same_words(a, b):
    return bool(a) and "".join(str(a).split()) == "".join(str(b or "").split())


def display_time(timestamp):
    return datetime.datetime.fromtimestamp(timestamp, ZONE).isoformat(timespec="microseconds")


def due_time(value):
    if value in (None, ""):
        return None
    stamp = datetime.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=ZONE)
    return stamp.timestamp()


class Entrusted:
    def __init__(self, ladder=None):
        self.items = records.entrusted()
        self.revision = max((i.get("revision", 0) for i in self.items.values()), default=0)
        self.ladder = ladder or rungs.Ladder()
        # The owner's own Reminders that name someone they chat with, and today's meetings: memory only, never recorded (`ladder.py`).
        self.outside, self.calendar, self.meetings_said = {}, [], set()
        self.offering = None
        self.visited = set()
        self.hand = False
        self.completed = False
        self.daily = dict(self.ladder.state.get("deliveries") or {})
        self.notice_state = ""  # Explain each notification state once per running session.

    def get(self, identity):
        return self.items.get(identity) or self.outside.get(identity)

    def pending(self):
        return [item for item in [*self.items.values(), *self.outside.values()] if item.get("state") == "held"]

    def own_pending(self):
        return [item for item in self.items.values() if item.get("state") == "held"]

    def pace(self, words, now):
        mode = pace_mode(words)
        if not mode:
            return ""
        state = self.ladder.state
        if mode == "today":
            state["quiet_day"] = datetime.datetime.fromtimestamp(now, ZONE).date().isoformat()
            reply = "好，今天只提醒你定了时间的事。"
        elif mode == "fewer":
            state["fewer_deliveries"] = True
            reply = "好，以后这种顺手的提醒一天最多三次。你定了时间的事照常。"
        else:
            state.pop("quiet_day", None)
            state.pop("fewer_deliveries", None)
            reply = "好，恢复正常提醒。"
        if mode != "normal" and (self.offering or {}).get("reason") not in (None, "due"):
            self.offering = None
        self.ladder._save()
        return reply

    def append(self, item, action, **changes):
        if item.get("from") == "reminders":  # the owner's own Reminders: their words are never written down here
            next_item = {**item, **changes, "action": action, "at": time.time()}
            if action in ("done", "looked", "later", "ignored"):
                next_item["outcomes"] = [*item.get("outcomes", []), {"action": action, "at": next_item["at"]}][-8:]
            identity = item["id"][2:]
            pacing = self.ladder.state.setdefault("reminder_pacing", {})
            if action in ("done", "cancel"):
                pacing.pop(identity, None)
                self.ladder.dismiss(identity)
            elif action in ("looked", "later", "ignored"):
                self._save_reminder_pacing(next_item)
            self.outside[item["id"]] = next_item
            return next_item
        next_item = {**item, **changes, "action": action, "at": time.time(), "revision": self.revision + 1}
        delta = {**({k: v for k, v in item.items() if k != "outcomes"} if action == "keep" else {}),
                 **{k: v for k, v in changes.items() if action == "keep" or item.get(k) != v},
                 "id": next_item["id"], "action": action, "at": next_item["at"], "revision": next_item["revision"]}
        records.entrust(delta, text=changes.get("offered_text", next_item.get("text", "")))
        self.revision = next_item["revision"]
        if action in ("done", "looked", "later", "ignored"):
            next_item["outcomes"] = [*item.get("outcomes", []), {k: next_item.get(k) for k in ("action", "reason", "at")}][-8:]
        self.items[next_item["id"]] = next_item
        return next_item

    def _save_reminder_pacing(self, item):
        pacing = self.ladder.state.setdefault("reminder_pacing", {})
        pacing[item["id"][2:]] = {k: item[k] for k in SYSTEM_PACING if k in item}
        while len(pacing) > 500:
            del pacing[next(iter(pacing))]
        self.ladder._save()

    def _observe_place_offer(self, item, offer, context, now):
        identity = offer["id"]
        was_touched = offer.get("touched", False)
        touched = was_touched or context.get("touched") == identity
        offer["touched"] = touched
        if offer.get("soft"):
            return
        was_shown = offer.get("shown", False)
        shown = was_shown or context.get("shown") == identity
        offer["shown"] = shown
        if not (shown and (shown != was_shown or touched != was_touched)):
            return
        shown_at = None if touched else now
        if shown_at == item.get("place_shown_at"):
            return
        if identity in self.outside:
            self.outside[identity] = {**item, "place_shown_at": shown_at}
            self._save_reminder_pacing(self.outside[identity])
        else:
            records.entrust_exposure(identity, shown_at, now)
            self.items[identity] = {**item, "place_shown_at": shown_at}

    def _words(self, args, job, *, draft=False):
        quote = str(args.get("quote") or "").strip()
        if not quote or (not draft and quote not in job.owner_words):
            raise ValueError("托付只认这一轮主人原话（或主人其他 Agent 转来的原话），请逐字给 quote")
        return quote, next(((words, at) for words, at in reversed(job.utterances) if quote in words), (job.owner_words, job.asked_at))

    def _spec(self, args, job, item, words, asked_at):
        """What a promise says, when and where, from the tool's arguments: the same for keeping one and for asking whether to."""
        text = " ".join(str(args.get("text", (item or {}).get("text", ""))).split())
        if not text:
            raise ValueError("递回时要说一句什么？text 不能为空")
        variants = args.get("variants", (item or {}).get("variants", []))
        if not isinstance(variants, list) or len(variants) > 4 or any(not isinstance(v, str) or not v.strip() for v in variants):
            raise ValueError("variants 请给最多四句非空的话")
        variants = [" ".join(v.split()) for v in variants]
        place = args.get("place", (item or {}).get("place"))
        if place is None:
            window = job.window or {}
            place = {"app": window.get("app", ""), "title": window.get("title", "")}
            if job.chat_name:  # A chat in WeChat or DingTalk: the person, not the window's title.
                place = {"app": window.get("app", ""), "chat": job.chat_name}
        if not isinstance(place, dict) or set(place) - {"app", "title", "chat"}:
            raise ValueError("place 只接受 app、title、chat；空对象表示不限定地方")
        place = {k: str(v).strip() for k, v in place.items() if str(v).strip()}
        if "after" in args and "due" in args:
            raise ValueError("相对时长 after 和钟点 due 只能给一个")
        if args.get("due") and RELATIVE.search(words) and not CLOCK_TIME.search(words):
            raise ValueError("主人说的是相对时间，请用 after 给时长，系统按主人说话时刻计算")
        if "after" in args:
            after = args["after"]
            if not isinstance(after, dict) or set(after) != {"amount", "unit"} or after.get("unit") not in ("seconds", "minutes", "hours"):
                raise ValueError("after 要给 amount 和 unit（seconds、minutes 或 hours）")
            amount = after.get("amount")
            if isinstance(amount, bool) or not isinstance(amount, (int, float)) or not math.isfinite(amount) or amount <= 0:
                raise ValueError("相对时长必须是大于零的有限数字")
            due = asked_at + amount * {"seconds": 1, "minutes": 60, "hours": 3600}[after["unit"]]
        else:
            due = due_time(args["due"]) if "due" in args else (item or {}).get("due")
        if ("due" in args or "after" in args) and due is not None and due < asked_at:
            raise ValueError("这个时间早于主人说话的时刻，请重新给未来时间；相对时间用 after")
        if due is not None:
            try:
                if not math.isfinite(due):
                    raise ValueError
                datetime.datetime.fromtimestamp(due, ZONE)
            except (OverflowError, OSError, ValueError):
                raise ValueError("到点时间超出可用范围，请重新给时间") from None
        return text, variants, place, due

    def _base(self, job):
        return {"id": uuid.uuid4().hex, "job": job.record_id, "k": job.key,
                "n": job.name, "c": (job.chat or {}).get("kind", "wechat") if job.chat else "window",
                "source": "agent" if getattr(job, "agent_source", None) else "owner",
                "source_name": getattr(job, "agent_source", None),
                "created": time.time()}

    def change(self, args, job):
        action = args.get("action", "keep")
        if action not in ("keep", "change", "cancel"):
            raise ValueError("托付动作应为 keep、change 或 cancel")
        quote, (words, asked_at) = self._words(args, job)
        item = self.items.get(str(args.get("id") or ""))
        if action == "keep" and item and item.get("state") == "asked":
            # 好, said instead of tapped: the promise it asked about, as it was put.
            if not self.accept(item["id"]):
                raise ValueError("这件已经不用再问了")
            return self.items[item["id"]]
        if action != "keep" and (not item or item.get("state") != "held"):
            raise ValueError("这件托付已经结束，或没有这个 id")
        if action == "cancel":
            result = self.append(item, "cancel", state="cancelled", quote=quote)
        else:
            text, variants, place, due = self._spec(args, job, item, words, asked_at)
            result = self.append(item or self._base(job), action, state="held", text=text, variants=variants, due=due, place=place, quote=quote,
                                 snoozed=False, reason="", held_since=time.time(), latest_job=job.record_id, ignored_streak=0,
                                 **({"place_shown_at": None} if item and item.get("place_shown_at") is not None else {}))
            if not item and result["source"] == "owner":
                self.ladder.owner_entrusted()
        if self.offering and self.offering["id"] == result["id"]:
            self.offering = None
        return result

    # ---- asking whether to keep a promise said in this turn (the ladder's second rung) ----
    def ask(self, args, job, *, watch=False):
        """The model saw a promise in the owner's own words, or in a reply it drafted for them, and asks once at the end of its answer
        whether to keep it. Asking holds nothing: only 好 (a tap, or said) makes it a promise. A draft's promise also waits for the
        draft to be sent, where Tako can see that (`watch`: the WeChat chat it is read from); elsewhere the owner's 好 is the word."""
        if not self.ladder.may_ask():
            raise ValueError("主人说过别问，或最近连着几次没理：这次不问，照常答完就好，答复里也不要问")
        if job.asked:
            raise ValueError("一轮最多问一件，这件不问了")
        draft = bool(args.get("draft"))
        quote, (words, asked_at) = self._words(args, job, draft=draft)
        text, variants, place, due = self._spec(args, job, None, words, asked_at)
        line = " ".join(str(args.get("ask") or "").split())[:40] or ("发出去后，要我记着这件事吗？" if draft else "要我记着这件事吗？")
        for other in self.items.values():
            if other.get("state") in ("held", "asked", "waiting_sent") and (same_words(other.get("text"), text) or same_words(other.get("quote"), quote)):
                raise ValueError("这件已经拿着或问过了，不用再问")
        item = self.append(self._base(job), "ask", state="asked", text=text, variants=variants, due=due, place=place, quote=quote,
                           ask=line, draft=draft, watch=bool(draft and watch), draft_chat=(job.chat or {}).get("username", "") if draft else "",
                           snoozed=False, reason="", latest_job=job.record_id, offered_text=line)
        job.asked = item["id"]
        return item

    def settle_ask(self, job, answer, draft_text):
        """The turn's answer is out: its question goes under it, unless the promise isn't in the draft it said it was in."""
        item = self.items.get(job.asked or "")
        if not item or item.get("state") != "asked":
            return None
        if not answer or (item.get("draft") and "".join(item["quote"].split()) not in "".join(str(draft_text or "").split())):
            self.append(item, "cancel", state="cancelled", reason="no_draft" if answer else "no_answer")
            return None
        return {"id": item["id"], "line": item["ask"]}

    def accept(self, identity):
        item = self.items.get(identity)
        if not item or item.get("state") != "asked":
            return False
        self.ladder.answered()
        if item.get("watch") and not item.get("sent"):
            self.append(item, "keep", state="waiting_sent", held_since=time.time())
        else:
            self.append(item, "keep", state="held", held_since=time.time())
        return True

    def asking(self, key=None):
        return [i["id"] for i in self.items.values() if i.get("state") == "asked" and (key is None or i.get("k") == key)]

    def left_unanswered(self, job):
        """At the end of the owner's next turn in that conversation a question still open was let pass: counted, never refusing."""
        for item in list(self.items.values()):
            if item.get("state") == "asked" and item.get("k") == job.key and item.get("latest_job") != job.record_id:
                self.append(item, "unanswered", state="unanswered")
                self.ladder.unanswered()

    def draft_sent(self, chat, sent):
        """The draft in that chat went out: a promise in it that the owner said 好 to is held now; asked and not yet answered, it is
        held the moment they say 好. Sent without the promise in it: nothing to keep."""
        changed = False
        for item in list(self.items.values()):
            if item.get("draft_chat") != chat or item.get("state") not in ("asked", "waiting_sent"):
                continue
            if "".join(item["quote"].split()) not in "".join(str(sent).split()):
                if item["state"] == "waiting_sent":
                    self.append(item, "cancel", state="cancelled", reason="sent_without")
                    changed = True
                continue
            if item["state"] == "waiting_sent":
                self.append(item, "keep", state="held", held_since=time.time(), sent=True)
                changed = True
            else:
                self.items[item["id"]] = {**item, "sent": True}
        return changed

    def draft_unsent(self, chat):
        for item in list(self.items.values()):
            if item.get("draft_chat") == chat and item.get("state") == "waiting_sent":
                self.append(item, "cancel", state="cancelled", reason="unsent")

    # ---- the system's Reminders and Calendar, in memory (the third rung) ----
    def sources(self, reminders, events, names):
        found = rungs.reminder_items(reminders, names, self.ladder.dismissed(), self.own_pending())
        for identity, item in found.items():
            if identity in self.outside:  # what was said about it (晚点, 没理会) stays while it is there
                found[identity] = {**item, **{k: v for k, v in self.outside[identity].items() if k not in ("text", "place")}}
            else:
                found[identity] = {**item, **self.ladder.state.get("reminder_pacing", {}).get(identity[2:], {})}
        self.outside = found
        self.calendar = [e for e in events or [] if isinstance(e, dict)]
        if self.offering and self.offering["id"] not in self.items and self.offering["id"] not in self.outside:
            self.offering = None

    def respond(self, identity, action):
        """做完了 ends the to-do. Opening it or choosing 稍后 keeps it pending."""
        item = self.get(identity)
        if action == "restore":
            if not item or identity not in {recent["id"] for recent in self.recently_put_down()}:
                return False
            due = item.get("due")
            now = time.time()
            self.append(item, "restored", state="held", due=due if due and due > now else None,
                        ignored_streak=0, deferred=0, deferred_at=now, held_since=now, reason="", place_shown_at=None)
            return True
        if not item or item.get("state") != "held":
            return False
        reason = (self.offering or {}).get("reason") if (self.offering or {}).get("id") == identity else item.get("reason") or ("due" if item.get("due") else "transition")
        if action == "done":
            self.append(item, "done", state="done", reason=reason)
            self.hand = bool(self.pending())
        elif action == "cancel":
            self.append(item, "cancel", state="cancelled", reason=reason)
            self.hand = bool(self.pending())
        elif action == "looked":
            # Taken to it: not ended, and not to be handed over again straight away.
            self.append(item, "looked", due=None, snoozed=True, held_since=time.time(), reason=reason,
                        deferred_at=time.time(), ignored_streak=0, place_shown_at=None)
            self.completed = False
        elif action == "later":
            self.append(item, "later", due=None, snoozed=True, held_since=time.time(), reason=reason,
                        deferred=int(item.get("deferred", 0)) + 1, deferred_at=time.time(), ignored_streak=0, place_shown_at=None)
            self.completed = False
        elif action == "ignored":
            if reason == "due":
                return False
            self.append(item, "ignored", reason=reason, deferred=int(item.get("deferred", 0)) + 1, deferred_at=time.time(),
                        ignored_streak=int(item.get("ignored_streak", 0)) + 1)
        else:
            return False
        if (self.offering or {}).get("id") == identity:
            self.offering = None
        return True

    def tick(self, context, now=None):
        now = time.time() if now is None else now
        matched = set(context.get("matched") or [])
        self.visited.intersection_update(matched)
        muted = bool(context.get("muted"))
        quiet = bool(context.get("fullscreen")) or muted
        # Stuck to a window it keeps to that window: what is timed, in place, and what concerns that window (native only matches there). Everything else waits for the desktop;
        # peeling it off is itself such an occasion.
        attached = bool(context.get("attached"))
        back = bool(context.get("returned") or context.get("peeled"))
        away = bool(context.get("away"))
        pending = self.pending()
        today = datetime.datetime.fromtimestamp(now, ZONE).date().isoformat()
        cap = 3 if self.ladder.state.get("fewer_deliveries") else 6
        ordinary_allowed = self.ladder.state.get("quiet_day") != today and self.daily.get(today, 0) < cap
        due = sorted((i for i in pending if i.get("due") is not None and i["due"] <= now), key=lambda i: i["due"])
        blocked = bool(context.get("busy") or quiet or away)
        if self.offering:
            offer = self.offering
            item = self.get(offer["id"])
            if item and item.get("due") is not None and item["due"] <= now:
                offer["reason"] = "due"  # A promise already shown before a meeting can reach its own time while still out.
            if item and item.get("state") == "held" and offer["reason"] == "place":
                self._observe_place_offer(item, offer, context, now)
                item = self.get(offer["id"])
            # A competing match alone must not replace the thing already out.
            # Native reports which matches actually left the scene; an empty
            # scene also withdraws it for callers without that transition data.
            left = offer["reason"] == "place" and (offer["id"] in (context.get("departed") or []) or not matched)
            if context.get("typing"):
                offer.setdefault("typing_since", now)
            else:
                offer.pop("typing_since", None)
            typing_long = now - offer.get("typing_since", now) >= 10
            if typing_long or blocked or left or not item or item.get("state") != "held" or (offer.get("soft") and due):
                if typing_long and offer.get("soft"):
                    self.visited.add(offer["id"])
                self.offering = None
            elif offer.get("soft"):
                if context.get("hovered") or offer.get("touched") or (not context.get("typing") and now - offer["since"] >= 1.5):
                    self._deliver(item, offer["reason"], offer["line"], today, now, touched=bool(offer.get("touched") or context.get("hovered")))
            elif context.get("hovered"):
                offer["since"] = now  # Passing the pointer over it is attention, never an ignore.
            elif offer["reason"] != "due" and now - offer["since"] >= 60 and not offer.get("counted"):
                # Ignoring is counted once per visit, but never dismisses a visible bubble.
                self.append(item, "ignored", reason=offer["reason"], ignored_streak=int(item.get("ignored_streak", 0)) + 1,
                            deferred=int(item.get("deferred", 0)) + 1, deferred_at=now)
                offer["counted"] = True
        if not self.offering and not blocked and (not due or not context.get("typing")):
            candidates, reason, line = due, "due", None
            ordinary = [i for i in self.pending() if int(i.get("ignored_streak", 0)) < 3] if not due and ordinary_allowed else []
            if not candidates and ordinary and not context.get("typing") and (meeting := rungs.meeting_line(self.calendar, ordinary, now, self.meetings_said)):
                key, item, line = meeting
                self.meetings_said.add(key)
                candidates, reason = [item], "meeting"
            if not candidates and ordinary:
                eligible = lambda i: now >= i.get("deferred_at", 0) + wait_after(i.get("deferred", 0))
                place_waiting = {i["id"] for i in ordinary if i["id"] in matched and i.get("place_shown_at") is not None
                                 and now < i["place_shown_at"] + PLACE_REPEAT_SECONDS}
                candidates = [i for i in ordinary if i.get("due") is None and i["id"] in matched
                              and i["id"] not in self.visited and i["id"] not in place_waiting and eligible(i)]
                reason = "place"
                if not candidates and not attached and (back or self.completed):
                    candidates = [i for i in ordinary if i.get("due") is None and not i.get("from") and i["id"] not in place_waiting
                                  and (not i.get("place") or i.get("snoozed") or now - i["created"] >= PLACE_WAIT_SECONDS)
                                  and now - i.get("held_since", i["created"]) > 2
                                  and eligible(i)
                                  and (back or i.get("latest_job", i.get("job")) != self.completed)]
                    reason = "transition"
            if candidates:
                item = candidates[0]
                variants = item.get("variants") or []
                repeat = int(item.get("deferred", 0))
                if line is None:
                    line = variants[min(repeat - 1, len(variants) - 1)] if repeat and variants else item["text"]
                    if reason == "place" and (item.get("place") or {}).get("chat"):
                        line = with_age(line, item.get("created", now), now)
                soft = reason in ("place", "transition") and (context.get("typing") or context.get("arriving"))
                if soft:
                    self.offering = {"id": item["id"], "reason": reason, "since": now, "soft": True, "line": line}
                    if context.get("typing"):
                        self.offering["typing_since"] = now
                else:
                    self._deliver(item, reason, line, today, now)
        if not context.get("busy"):
            self.completed = False  # A job that ended while another, or its answer in the bubble, still had the floor stays an occasion for after.
        self.hand = bool(self.pending())  # Quiet keeps the count, never the private words held out.
        offer = None
        if self.offering:
            item = self.get(self.offering["id"])
            place = item.get("place") or {}
            soft = self.offering.get("soft", False)
            label = place.get("chat") or self.offering.get("line", "")
            offer = {k: self.offering[k] for k in ("id", "reason", "since")}
            offer.update(soft=soft, text=label[:14] if soft else item.get("offered_text", item["text"]),
                         key=item.get("k", "desktop"), repeat=item.get("deferred", 0))
        return {"holding": self.hand, "count": len(self.pending()), "offer": offer}

    def _deliver(self, item, reason, line, today, now, *, touched=False):
        if reason != "due":
            self.daily = {today: self.daily.get(today, 0) + 1}
            self.ladder.state["deliveries"] = self.daily
            self.ladder._save()
        self.append(item, "offered", reason=reason, offered_text=line)
        self.ladder.first_offered(item["id"])
        self.visited.add(item["id"])
        self.offering = {"id": item["id"], "reason": reason, "since": now, "touched": touched}

    def later_line(self, identity):
        item = self.get(identity) or {}
        return later_line(wait_after(int(item.get("deferred", 0))))

    def memory(self, *, full=False):
        return records.entrusted_memory(self.items, limit=None if full else 12000)

    def recently_put_down(self):
        ended = [i for i in self.items.values() if i.get("source") == "owner"
                 and i.get("state") in ("done", "cancelled") and i.get("action") in ("done", "cancel")
                 and i.get("reason") not in ("no_answer", "no_draft", "unsent")]
        return sorted(ended, key=lambda i: i["at"], reverse=True)[:3]

    def native_state(self):
        """What the app compares and shows, in the panel's order: what has a time first (soonest first), then what waits for a person
        or a place (the oldest first). Reminders' words reach the app only for its local comparison and the owner's own panel."""
        pending = self.pending()
        timed = sorted((i for i in pending if i.get("due") is not None), key=lambda i: i["due"])
        rest = sorted((i for i in pending if i.get("due") is None), key=lambda i: i.get("created", 0))
        wake = rungs.next_meeting_moment(self.calendar, time.time()) if any((i.get("place") or {}).get("chat") for i in pending) else None
        return {"revision": self.revision, "wake": wake,
                "recently_put_down": [{k: i[k] for k in ("id", "text")} for i in self.recently_put_down()],
                "items": [{**{k: i.get(k) for k in ("id", "due", "place", "text", "created", "ignored_streak")}, **({"from": i["from"]} if i.get("from") else {}),
                           "due_display": display_time(i["due"]) if i.get("due") is not None else ""} for i in [*timed, *rest]]}
