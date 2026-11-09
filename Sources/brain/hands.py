"""What the model can reach for: the tools, the cards that wait for the owner, and the bridge to the app, the only process with the permissions."""
from __future__ import annotations

import asyncio
import base64
import json
import secrets
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urlparse

import feedback as fb
import webfill
import wechat_reader as reader
from chats import render
from guards import LOCAL_NAMES, SCRIPTABLE, clipped, full_chat_name, lasting_command, overwritten_paths, plain_command, same_chat, risky_script, unsafe_script, workbench_packet
from outputs import back_up, change_problem, file_in_title, file_pictures, replace_file
from settings import CONFIG, HAS_WECHAT, OWNER, WECHAT, WORKBENCH, WORKBENCH_CARDS, local_today, note_metric

FEEDBACK_KINDS = {"bug": "出了问题", "rough": "不好用", "wish": "想用的场景"}
COMING_BACK_SECONDS = 1800  # How long the last step of a job waits for the owner to come back to its window.
OWNER_WENT_SECONDS = 3  # A window coming to the front this soon after the owner's own click or key is them going there.
PICK_UPS = 2  # Turns a step that needs the window in front may start by itself before it stops asking the model.


class Hands:
    async def on_server_request(self, method, params):
        # A throwaway thread is never on this list, so it has no tools and can ask for nothing. If it ever tried, no running job answers for it.
        job = self.on_thread.get(params.get("threadId"))
        if method == "item/tool/call":
            if not job:
                return self._reply("这个线程没有工具。", ok=False)
            result = await self._tool(params.get("tool"), params.get("arguments") or {}, job)
            self._weigh(job, sum(len(item.get("imageUrl") or "") for item in result.get("contentItems") or []))
            self.feedback.count(f"tool.{params.get('tool')}" if result.get("success") else f"tool_failed.{params.get('tool')}")
            return result
        if method in ("item/commandExecution/requestApproval", "item/fileChange/requestApproval"):
            if not job:
                return {"decision": "decline"}
            # The owner is asked only about what can't be taken back (Joe 2026-11-04: keep the cards that matter, interrupt as little as possible).
            if method == "item/fileChange/requestApproval":
                await asyncio.sleep(0.1)  # the item's own start event carries the paths
                paths = [str(path) for path in job.changing.get(params.get("itemId")) or [] if path]
                if paths and await asyncio.to_thread(self._backed_up, paths):
                    note_metric(kind="approval", by="itself", what="file")
                    return {"decision": "accept"}  # Not for the session: the next change gets its own backup.
                text = "改动文件：" + "、".join(paths) if paths else f"改动文件：{params.get('grantRoot') or '不知道改哪里'}"
                why = str(params.get("reason") or "")[:200]
            else:
                text = plain_command(params.get("command")) or "运行命令"
                why = lasting_command(params.get("command") or text)
                if not why:
                    note_metric(kind="approval", by="itself", what="command")
                    # Writing over a file with > or tee: what was there is backed up first, and the next time asks again so it gets its own.
                    over = [path for path in overwritten_paths(params.get("command") or text, params.get("cwd")) if Path(path).is_file()]
                    if over and await asyncio.to_thread(self._backed_up, over):
                        return {"decision": "accept"}
                    return {"decision": "acceptForSession"}
            note_metric(kind="approval", by="owner", what="file" if method == "item/fileChange/requestApproval" else why)
            accepted = await self._card({"kind": "approval", "text": clipped(str(text)), "reason": why}, job)
            # Asked once: the same thing doesn't come back to the owner for the rest of this session.
            return {"decision": "acceptForSession" if accepted else "decline"}
        if method == "item/permissions/requestApproval":
            return {"permissions": {}, "scope": "turn"}
        if method == "item/tool/requestUserInput":
            return {"answers": {}}
        if method == "mcpServer/elicitation/request":
            return {"action": "decline"}
        raise RuntimeError("unsupported_server_request")

    @staticmethod
    def _backed_up(paths):
        """A file the owner didn't name may still be changed: what was there goes to the backups first, so it can always be had back."""
        if any(Path(path).is_dir() for path in paths):
            return False
        for path in map(Path, paths):
            if path.exists():
                back_up(path)
        return True

    async def _card(self, card, job):
        card["id"], card["job"] = secrets.token_hex(4), job
        card["future"] = self.loop.create_future()
        self.pending[card["id"]] = card
        try:
            return await card["future"]
        finally:
            self.pending.pop(card["id"], None)

    def _dismiss_cards(self, job):
        for card in list(self.pending.values()):
            if card["job"] is job and not card["future"].done():
                card["future"].set_result(False)

    def decide(self, card_id, accepted):
        card = self.pending.get(card_id)
        if card and not card["future"].done():
            self.loop.call_soon_threadsafe(card["future"].set_result, accepted)

    async def native(self, command, timeout=30, **args):
        """Ask the app side to do something only it has the permissions for."""
        request = secrets.token_hex(4)
        future = self.loop.create_future()
        self.waiting[request] = future
        self.outbox.put({"id": request, "command": command, "expires": time.time() + timeout, **{k: v for k, v in args.items() if v is not None}})
        try:
            return await asyncio.wait_for(future, timeout)
        except asyncio.TimeoutError:
            return {"ok": False, "noAnswer": True, "error": "TAKO 那边没有回应"}
        finally:
            self.waiting.pop(request, None)

    async def _unless_needs_front(self, job, command, timeout=30, **args):
        """Nearly everything happens behind the owner's back. What needs the real pointer never takes it and never asks them over: the model finds another way or finishes the rest, and if they happen on that window later it goes on by itself."""
        began = time.time()
        while True:
            result = await self.native(command, timeout=timeout, **args)
            if job and result.get("noAnswer"):
                job.blocked.append("no_answer")
            if not result.get("needsFront"):
                return result
            if job:
                job.blocked.append(result.get("why") or "front")
                job.left_for_owner = {"window": str(result.get("id") or args.get("window") or job.window_id or ""), "app": result.get("app")}
                return {"ok": False, "error": f"{result.get('error')}，先没做。不要让 {OWNER} 切窗口，也不要说在等TA。先换条路：文件、命令、脚本接口、聊天记录；换不了就把其余做完，最后说清差什么。"}
            # The owner just pressed a button on the panel: a few seconds for their hand to settle is all this takes.
            if time.time() - began > 8:
                return {"ok": False, "error": f"{result.get('error')}，这一步没有做"}
            await asyncio.sleep(0.5)

    @staticmethod
    def _conversation(job):
        return (job.chat or {}).get("username") or id(job.events)

    def _say_to_owner(self, events, text):
        """In the conversation it belongs to, and on the panel in front of them if that is another one."""
        self.add("tako", text, events)
        if events is not self.events:
            self.add("tako", text)

    async def _pick_up_when_back(self, job):
        key = self._conversation(job)
        window, app = job.left_for_owner["window"], job.left_for_owner.get("app") or (job.window or {}).get("app") or "那个窗口"
        self.picked_up[key] = self.picked_up.get(key, 0) + 1
        # The window was in front and the step still could not be done: asking the model again only spends money until the owner leaves.
        if self.picked_up[key] > PICK_UPS:
            self.feedback.count("job.gave_up")
            self._say_to_owner(job.events, "差的这一步在后台没走通，放下了，其余的都在上面。")
            return
        mark = self.held[key] = {"name": job.name, "events": job.events, "window": window, "chat": job.wechat_chat, "trouble": f"差一步在后台做不了。不用专门切过去，你之后用到 {app} 时我接上。"}
        deadline = time.time() + COMING_BACK_SECONDS
        try:
            while self.held.get(key) is mark and time.time() < deadline:
                await asyncio.sleep(2)
                seen = await self.native("isBack", timeout=5, window=window)
                if seen.get("error") and not seen.get("noAnswer"):  # The window has gone.
                    return
                if seen.get("ok") and self.held.get(key) is mark:
                    del self.held[key]
                    await self.turn(f"{app} 回到前台了。把刚才差的那一步做完，做完说一声。", where=(job.chat, job.events, job.window))
                    return
        finally:
            if self.held.get(key) is mark:
                del self.held[key]

    def _hands_on(self, job, window):
        """A job's hands on a window other than its own, doing something there; a look is not that, and the result of one belongs where it was asked (Joe 2026-11-09: asked in Finder to mail a file, Tako worked the mailbox and stayed on Finder).
        That window now shows the job's conversation, its line goes there, and the owner going to it brings Tako along."""
        found = str((window or {}).get("id") or "")
        if not job or found in ("", "0", job.window_id or "") or window.get("bundle") == WECHAT:
            return
        job.hands_on = {"id": found, "app": window.get("app"), "bundle": window.get("bundle")}
        if job.chat:
            self.worked[f"window:{window.get('bundle')}:{found}"] = job.chat
        if not job.following:
            job.following = True
            self._later(self._follow_hands(job))

    async def _follow_hands(self, job):
        """While it works, the owner going to the window its hands are on finds Tako there, once each time they go: put somewhere else, it stays put."""
        was_front = False
        try:
            while job in self.active:
                window = job.hands_on["id"]
                seen = await self.native("isBack", timeout=5, window=window)
                if seen.get("error") and not seen.get("noAnswer"):  # the window has gone
                    return
                front = bool(seen.get("front"))
                # Only the owner's own going there: a window that came up by itself (an app opened for the job) is no reason, and they get only the result (Joe 2026-11-09).
                went = front and not was_front and float(seen.get("input", 99)) < OWNER_WENT_SECONDS
                if went and job in self.active and (await self.native("followTo", timeout=5, window=window)).get("ok"):
                    await asyncio.sleep(0.4)  # the panel moves over with the goo before it opens there
                    await self.native("followDone", timeout=5)
                was_front = front
                await asyncio.sleep(1)
        finally:
            job.following = False

    def _hold_fill(self, text, files, window, chat, job, app, why=None):
        """The hand-over itself is known exactly, so no model is needed to finish it: the owner getting to that window is enough. Asked again, the newest one stands."""
        key = ("fill", self._conversation(job))
        where = f"{app}「{chat}」" if chat else app
        what = "、".join(Path(f).name for f in files) or "这段话"
        mark = self.held[key] = {"name": job.name, "events": job.events, "what": what, "where": where, "app": app, "window": window or (WECHAT if chat else None), "chat": chat or job.wechat_chat,
                                 "trouble": f"{what} 备好了，切到{app}就自动放进去。", "placed": asyncio.Event()}
        self._later(self._place_when_back(key, mark, text, files, window, chat, job))
        # Facts, not orders: told "don't try again, don't look", the model obeyed that over the owner saying the chat was open (2026-11-06).
        why = why or f"{app}的输入框要用真鼠标放字"
        return {"ok": True, "message": f"还没放进去，排着：{why}。{OWNER} 到{app}、手停下时系统自己放，不用你再做什么。跟 {OWNER} 照实说“排着，切过去就放”，不要说已经放进去了。再调 fill_input 会换掉排着的这条，cancel:true 取消。"}

    async def _place_when_back(self, key, mark, text, files, window, chat, job):
        ending = f"文件在这里：{' '.join(f'[{Path(f).name}](</{f.lstrip(chr(47))}>)' for f in files)}" if files else ""
        deadline = time.time() + COMING_BACK_SECONDS
        here = False
        try:
            while self.held.get(key) is mark:
                if time.time() > deadline:
                    self._say_to_owner(mark["events"], f"等了半小时{mark['app']}都没到前台，{mark['what']}没放进去。{ending}")
                    return
                seen = await self.native("isBack", timeout=5, window=window)
                if self.held.get(key) is not mark:
                    return
                if seen.get("error") and not seen.get("noAnswer"):
                    self._say_to_owner(mark["events"], f"{mark['app']}的窗口没了，{mark['what']}没放进去。{ending}")
                    return
                if seen.get("front") and not here:
                    await self.native("followTo", timeout=5, window=window)
                    mark["trouble"] = f"到{mark['app']}了，鼠标停一下就放。"
                    await asyncio.sleep(0.4)  # The panel moves over with the goo before it says anything there.
                elif not seen.get("front") and here:
                    mark["trouble"] = f"{mark['what']} 备好了，切到{mark['app']}就自动放进去。"
                here = bool(seen.get("front"))
                if seen.get("ok"):
                    mark["placing"] = True
                    result = await self._place(text, files, window, chat, job)
                    if not result.get("needsFront"):  # The owner's hand came back: not a failure, only not yet.
                        await self._placed(mark, result, ending)
                        return
                    mark["placing"] = False
                await asyncio.sleep(0.7)
        finally:
            mark["placed"].set()
            if self.held.get(key) is mark:
                del self.held[key]
            await self.native("followDone", timeout=5)

    async def _placed(self, mark, result, ending):
        mark["result"] = result
        if result.get("ok"):
            said = str(result.get("message") or "").replace(" 用户 ", "你")
            self.limb_news = [*self.limb_news, f"（刚才排着的一步系统已做完：{mark['what']} 放进了{mark['where']}的输入框，没有发送。不要再放一次。）"][-5:]
            self._say_to_owner(mark["events"], f"{mark['what']} 放进{mark['where']}了。{said}")
        else:
            why = result.get('error') or '这一步没走通'
            # The model was told it is queued and not to try again; left at that, "just paste it" next gets nothing done.
            self.limb_news = [*self.limb_news, f"（刚才排着的一步没做成：{mark['what']} 没放进{mark['where']}，{why}。现在没有排着的了，{OWNER} 再要就重新调 fill_input。）"][-5:]
            self._say_to_owner(mark["events"], f"{mark['what']} 没放进{mark['where']}：{why}。{ending}")

    def _waiting_fill_note(self):
        """The owner is talking while a hand-over waits: the model should know, and only it can tell whether this calls it off. No paths here: this reads as the owner's own words."""
        mark = self.held.get(("fill", (self.chat or {}).get("username") or id(self.events)))
        if not mark:
            return ""
        return f"（系统提示，不是 {OWNER} 说的：还排着一步，把 {mark['what']} 放进{mark['where']}，TA切过去就自动放。下面这句话如果是不要了，调 fill_input 传 cancel:true；再调 fill_input 会换掉排着的这条。）\n"

    def native_done(self, request, result):
        future = self.waiting.get(request)
        if future and not future.done():
            self.loop.call_soon_threadsafe(future.set_result, result)

    @staticmethod
    def _reply(text, image=None, ok=True):
        items = [{"type": "inputText", "text": text}]
        if image:
            items.append({"type": "inputImage", "imageUrl": f"data:image/jpeg;base64,{image}"})
        return {"success": ok, "contentItems": items}

    async def _point_when_back(self, text, window):
        """A ring nobody saw is no answer: it goes round again when the owner gets to that window. Only the latest one for a window."""
        self.rings[window] = mark = object()
        deadline = time.time() + COMING_BACK_SECONDS
        try:
            while self.rings.get(window) is mark and time.time() < deadline:
                await asyncio.sleep(1)
                seen = await self.native("isBack", timeout=5, window=window)
                if seen.get("error"):
                    return
                if seen.get("front"):
                    await self.native("point", text=text, window=window)
                    return
        finally:
            if self.rings.get(window) is mark:
                del self.rings[window]

    @staticmethod
    def _once_is_enough(result, job, name):
        """The same refusal twice means a third try won't change it. The model hears so, whichever tool and whatever the reason."""
        if result.get("success", True):
            return result
        said = " ".join(item.get("text", "") for item in result.get("contentItems", []))
        key = (name, said[:200])
        job.refused[key] = job.refused.get(key, 0) + 1
        if job.refused[key] >= 2:
            result["contentItems"].append({"type": "inputText", "text": "这一步已经同样失败两次，不要再试。先把能做的做完，用一句话告诉 {} 结果和差什么。".format(OWNER)})
        return result

    async def _tool(self, name, args, job):
        job.call_waiting = None
        job.tools_running += 1
        job.status = "working"
        try:
            result = self._once_is_enough(await self._run_tool(name, args, job), job, name)
            job.trail.append(f"{name}:{'ok' if result.get('success', True) else 'failed'}")
            return result
        except Exception as exc:
            # Whatever went wrong here, the model hears it and the turn goes on.
            self.feedback.error(f"tool.{name}", exc)
            return self._reply(f"这一步出错了（{type(exc).__name__}），没有做成。", ok=False)
        finally:
            job.tools_running -= 1
            # A tool can outlive its turn when the owner stops it, and it must not bring the busy state back.
            if not job.tools_running and job.status == "working":
                job.status = "thinking"

    async def _run_tool(self, name, args, job):
        # Tied to where it was asked: the goo may be on another window by now.
        window = str(args.get("window") or "") or job.window_id
        if name == "list_windows":
            result = await self.native("windows")
            lines = [f"{w['id']}｜{w['app']}｜{w['title']}" + ("｜TAKO 粘在这里" if w.get("stuck") else "") for w in result.get("windows", [])]
            return self._reply("\n".join(lines) or "没有打开的窗口")
        if name == "look_at_window":
            return await self._look(window, job)
        if name == "look_at_file":
            return await self._look_at_file(str(args.get("path") or ""), int(args.get("first") or 1))
        if name == "operate_window":
            return await self._operate(args.get("steps") or [], window, job)
        if name == "fill_input":
            if args.get("cancel"):
                dropped = self.held.pop(("fill", self._conversation(job)), None)
                return self._reply(f"不放了：{dropped['what']}。" if dropped else "没有排着的。")
            result = await self.fill(str(args.get("text") or ""), [str(f) for f in args.get("files") or []], window, str(args.get("chat") or "") or None, job,
                                     field=str(args.get("field") or "") or None)
            return self._reply(result.get("message") or result.get("error") or "", ok=bool(result.get("ok")))
        if name == "read_wechat":
            return await self._read_wechat(str(args.get("chat") or ""), int(args.get("limit") or 30))
        if name == "point_at":
            text = str(args.get("text") or "")
            result = await self.native("point", text=text, window=window)
            if not result.get("ok"):
                return self._reply(result.get("error", "窗口上没找到这段文字"), ok=False)
            if result.get("seen", True):
                return self._reply("标好了")
            self._later(self._point_when_back(text, window))
            return self._reply(f"标好了，但这个窗口现在不在前台，{OWNER} 切过来时会再标一次。回答里也用文字说清在哪。")
        if name == "run_in_app":
            return await self._script(str(args.get("script") or ""), str(args.get("app") or ""), job)
        if name == "tell_workbench":
            return await self._tell_workbench(args)
        if name == "report_feedback":
            return await self._report_feedback(args, job)
        if name == "listen":
            return await self._listen(str(args.get("action") or ""), str(args.get("text") or ""), window)
        if name == "propose_file_change":
            return await self._propose(str(args.get("original")), str(args.get("edited")), str(args.get("summary")), job)
        return self._reply("没有这个工具", ok=False)

    async def _look(self, window, job=None):
        result = await self._unless_needs_front(job, "look", window=window)
        if not result.get("ok"):
            return self._reply(result.get("error", "看不到窗口"), ok=False)
        lines = [f"窗口 id：{result.get('id')}", f"应用：{result.get('app')}", f"标题：{result.get('title')}"]
        if result.get("note"):
            lines.append(result["note"])
        if result.get("imageScale", 1) != 1:
            lines.append(f"截图比例：1 个窗口坐标点 = {result['imageScale']:.3f} 像素")
        if document := result.get("document") or await asyncio.to_thread(file_in_title, result.get("title")):
            lines.append(f"文件：{document}")
        if result.get("elements"):
            lines.append("可以按的元素（编号 角色 名称 (x,y,宽,高)，编号到下次看窗口前有效）：\n" + str(result["elements"])[:14000])
        if result.get("lines"):
            lines.append("画面上的文字 (x,y,宽,高)：\n" + str(result["lines"])[:9000])
        if result.get("text") and not result.get("lines"):
            lines.append("窗口文字：\n" + str(result["text"])[:9000])
        return self._reply("\n".join(lines), result.get("image"))

    async def _look_at_file(self, path, first):
        try:
            pages = await asyncio.to_thread(file_pictures, path, max(1, first))
        except (OSError, subprocess.SubprocessError) as exc:
            return self._reply(f"这个文件转不成图片（{type(exc).__name__}），先读它的内容。", ok=False)
        if not pages:
            return self._reply("这个文件转不成图片，或者已经没有更多页了。先读它的内容。", ok=False)
        said = f"{Path(path).name}：从第 {max(1, first)} 页起的 {len(pages)} 页。一次最多 6 页，后面还有就把 first 往后传。"
        return {"success": True, "contentItems": [{"type": "inputText", "text": said}, *({"type": "inputImage", "imageUrl": f"data:image/jpeg;base64,{page}"} for page in pages)]}

    async def _operate(self, steps, window, job):
        target = await self.native("resolve", window=window)
        if not target.get("ok"):
            return self._reply(target.get("error", "没找到窗口"), ok=False)
        window = str(target.get("id") or "") or window  # Named once, the same window for every step, whatever comes to the front.
        self._hands_on(job, target)
        done = []
        fell_short = False
        run = job.running
        try:
            for step in steps[:40]:
                if job.stopping or job.running != run:
                    done.append(f"{OWNER} 让停下，后面的没有做。")
                    return self._reply("\n".join(done))
                result = await self._unless_needs_front(job, "step", timeout=40, window=window, step=step)
                if result.get("needs"):
                    accepted = await self._card({"kind": "approval", "text": str(result["needs"])[:400], "reason": ""}, job)
                    if not accepted:
                        done.append(f"{OWNER} 没批准：{result['needs']}。已停下")
                        break
                    result = await self._unless_needs_front(job, "step", timeout=40, window=window, step=step, confirmed=True)
                if not result.get("ok"):
                    done.append(str(result.get("error") or "这一步没做成") + ("" if not result.get("refused") else "（这是底线，不要换办法绕过）"))
                    fell_short = True
                    break
                done.append(str(result.get("did") or "完成"))
        finally:
            await self.native("endSteps")
        # An upload button clicked opens the system's file chooser, which nothing behind the owner's back can work (GitHub issue 3).
        if target.get("bundle") in webfill.BROWSERS and any(str(s.get("action")) in ("click", "double_click") for s in steps[:40]):
            if (await self.native("closeFileChooser", window=window)).get("closed"):
                done.append("这一下打开了系统的文件选择框，后台选不了文件，已经点“取消”关掉了，什么都没选。"
                            "要传文件，用 fill_input 的 files（文件路径）和 field（上传按钮或那一块上的字），它在后台直接交给网页，不要再点上传按钮。")
        seen = await self.native("look", window=window)
        report = "\n".join(done)
        if seen.get("ok"):
            more = str(seen.get("elements") or "")[:6000]
            return self._reply(f"{report}\n\n现在的窗口：{seen.get('title')}\n可以按的元素：\n{more}", seen.get("image"), ok=not fell_short)
        return self._reply(report, ok=not fell_short)

    async def _report_feedback(self, args, job):
        """Something the owner chose to say: nothing leaves until they have read exactly what would, and pressed send."""
        kind = args.get("kind")
        text = fb.scrub(str(args.get("text") or ""), self._private_names(job))
        if kind not in FEEDBACK_KINDS or not text or not fb.URL:
            return self._reply("这条反馈发不了。", ok=False)
        packet = self.feedback.say_packet(kind, text)
        shown = f"{text}\n\n{FEEDBACK_KINDS[kind]} · Tako {packet['version']} · macOS {packet['macos']}"
        if not await self._card({"kind": "feedback", "text": shown}, job):
            return self._reply(f"{OWNER} 决定不发，这条反馈没有离开这台电脑。")
        try:
            await asyncio.to_thread(self.feedback.send, packet)
        except (OSError, ValueError):
            return self._reply("没发出去，可能是网络问题。可以稍后再说一次。", ok=False)
        return self._reply("发给作者了。")

    async def _tell_workbench(self, args):
        try:
            packet = workbench_packet(args, self.said, local_today())
        except ValueError as exc:
            return self._reply(str(exc), ok=False)
        # The workbench's own client owns its session check and idempotency; TAKO keeps no copy of either.
        done = await asyncio.to_thread(subprocess.run, [sys.executable, str(WORKBENCH_CARDS), "respond", "--base", WORKBENCH, "--packet", "-"],
                                       input=json.dumps(packet, ensure_ascii=False), capture_output=True, text=True, timeout=70)
        try:
            result = json.loads(done.stdout)
        except ValueError:
            return self._reply("工作台没有给出结果，不确定写进去没有，先读 /api/desk 核对，不要直接重试。", ok=False)
        if done.returncode:
            conflict = "事项刚变过，重新读一次再写。" if result.get("http_status") == 409 else "不确定写进去没有，先读 /api/desk 核对，不要直接重试。"
            return self._reply(f"工作台没收：{result.get('error')} {conflict}", ok=False)
        return self._reply(str(result.get("message") or "工作台收到了。"))

    async def _read_wechat(self, name, limit):
        chats = await asyncio.to_thread(reader.find_chats, name)
        if not chats:
            return self._reply(f"没找到叫“{name}”的对话", ok=False)
        chat = await asyncio.to_thread(self._latest, chats[:8])
        if not chat:
            return self._reply(f"“{name}”不在当前可读的消息库里", ok=False)
        rows = await asyncio.to_thread(self._read_tail, chat, max(1, min(limit, 200)))
        return self._reply(f"对话：{chat['name']}\n\n{render(rows)}" if rows else "这段对话没有可读的消息")

    def _read_tail(self, chat, limit):
        con, _ = reader.open_shard()
        try:
            return reader.read_messages(con, chat["username"], 0, limit) or []
        finally:
            con.close()

    async def _script(self, script, app_name, job):
        if app_name:
            app = LOCAL_NAMES.get(app_name) or next((name for name in SCRIPTABLE.values() if app_name.lower() in name.lower() or name.lower() in app_name.lower()), None)
            app = app if app in SCRIPTABLE.values() else None
        else:
            app = SCRIPTABLE.get((job.window or {}).get("bundle"))
        if not app:
            return self._reply(f"{app_name or (job.window or {}).get('app') or '这个应用'} 没有脚本接口。", ok=False)
        bundle = next(key for key, name in SCRIPTABLE.items() if name == app)
        if problem := unsafe_script(script, app):
            return self._reply(problem, ok=False)
        if word := risky_script(script):
            if not await self._card({"kind": "approval", "text": clipped(script), "reason": f"在 {app} 里运行这段脚本（含 {word}）"}, job):
                return self._reply(f"{OWNER} 没批准这段脚本，没有运行。")
        result = await self.native("script", timeout=90, script=script, bundle=bundle)
        if not result.get("ok") and not result.get("consent") and not result.get("denied") and not result.get("error"):
            return self._reply(f"{app} 80 秒没有回应，脚本被停下了。", ok=False)  # killed for taking too long: nothing on stderr
        return self._reply(str(result.get("output") or result.get("error") or "完成"), ok=bool(result.get("ok")))

    def _page_runner(self, app, bundle, window, within=15):
        """Runs Tako's own page code in the browser: (output, None), or (None, why it can't run there)."""
        async def run(source):
            result = await self.native("script", timeout=within + 10, script=source, bundle=bundle, within=within, window=window)
            if result.get("ok"):
                return result.get("output") or "", None
            if result.get("consent") or result.get("denied"):
                return None, f"{result.get('error')}（{app}）"
            if webfill.scripting_off(result.get("error")):
                return None, f"{app} 没开「允许 Apple 事件中的 JavaScript」（菜单 显示 › 开发者），{OWNER} 打开一次，网页就都能在后台填了"
            return None, f"{app} 没有回应" + (f"：{str(result.get('error')).strip()[:200]}" if result.get("error") else "")
        return run

    async def _fill_page(self, text, field, shown, window):
        """Into a field of a web page, behind the owner's back (`webfill`). None: the page code can't run here, and why, for the usual way to go on."""
        app, bundle = webfill.BROWSERS[shown["bundle"]], shown["bundle"]
        text = text.rstrip("\r\n")  # a line break at the end becomes an empty paragraph in a rich editor
        run = self._page_runner(app, bundle, window)

        listed, why = await run(webfill.windows_script(app))
        if listed is None:
            return None, why
        found = webfill.which_window(listed, shown.get("title"), shown.get("frame"))
        if not found:
            return {"ok": False, "error": f"认不出是 {app} 的哪个窗口，没有填"}, None
        page, address = found
        mark = secrets.token_hex(4)

        async def step(name):
            output, why = await run(webfill.run_script(app, page, name, field, text, mark))
            return webfill.answer(output) if why is None else {"error": "script", "why": why}

        said = await step("start")
        if said.get("pending"):
            for again in (False, True):
                if again:  # the editor let the paste go by: its own typing
                    await step("reselect")
                await asyncio.sleep(webfill.SETTLE)
                await step("type" if again else "paste")
                await asyncio.sleep(0.3)
                said = await step("check")
                if said.get("ok") or said.get("error"):
                    break
        name = said.get("name") or field or "输入框"
        errors = {"which": f"页面上不止一个输入框，用 field 说填哪个：{'、'.join(said.get('fields') or [])}",
                  "none": f"页面上没找到「{field}」这个输入框。看得到的有：{'、'.join(said.get('fields') or []) or '没有'}。可能要先切模式或展开那一块",
                  "hidden": f"「{name}」现在看不见，可能要先切到对应的模式或展开那一块，没有填",
                  "refused": f"「{name}」是密码或支付信息框，不填，留给 {OWNER}",
                  "readonly": f"「{name}」现在不能输入，没有填",
                  "gone": "页面刷新或换了，没有填完",
                  "script": said.get("why"), "unreadable": f"{app} 回的话看不懂，没有填"}
        if said.get("error"):
            return {"ok": False, "error": errors.get(said["error"], "没有填")}, None
        if said.get("ok"):
            return {"ok": True, "message": f"在后台填进了「{name}」，读回核对一致（{said.get('length', 0)} 字）。没有点任何按钮。"}, None
        return {"ok": False, "error": f"填了「{name}」但读回不对，现在框里是：{said.get('now', '')}"}, None

    async def _upload_page(self, files, field, shown, window, job):
        """Files into a web page's upload box, behind the owner's back (`webfill.UPLOAD`): never through the system's file chooser,
        which only the real pointer can work. The files leave this Mac, so the owner sees which ones and where first, once per site
        in a job. Then the page is read to see whether the upload began. None: the page code can't run here, and why."""
        app, bundle = webfill.BROWSERS[shown["bundle"]], shown["bundle"]
        paths = [Path(f).expanduser() for f in files]
        missing = [str(p) for p in paths if not p.is_file()]
        if missing:
            return {"ok": False, "error": f"没有这个文件：{'、'.join(missing)}，什么都没传"}, None
        sizes = [p.stat().st_size for p in paths]
        if sum(sizes) > webfill.UPLOAD_LIMIT:
            return {"ok": False, "error": f"这些文件一共 {sum(sizes) / 1e9:.1f} GB，太大了，后台交不过去；一次少传几个"}, None
        run = self._page_runner(app, bundle, window, within=30)
        listed, why = await run(webfill.windows_script(app))
        if listed is None:
            return None, why
        found = webfill.which_window(listed, shown.get("title"), shown.get("frame"))
        if not found:
            return {"ok": False, "error": f"认不出是 {app} 的哪个窗口，什么都没传"}, None
        page, address = found
        site = urlparse(address).hostname or address[:60]
        mark = secrets.token_hex(4)

        async def step(name, data=None):
            output, why = await run(webfill.upload_script(app, page, name, field, data, mark))
            return webfill.answer(output) if why is None else {"error": "script", "why": why}

        # A chooser opened by an earlier click would sit over the page for nothing: close it (it is the Cancel button, nothing chosen).
        closed = await self.native("closeFileChooser", window=window)
        said = await step("find", {"kind": webfill.kind_of(paths)})
        if said.get("error") == "button":
            said = await step("catch", {"kind": webfill.kind_of(paths)})
        boxes = "、".join(said.get("boxes") or []) or "没有"
        errors = {"none": f"页面上没找到「{field}」对应的上传框。页面上的上传框有：{boxes}。可能要先切到对应的模式或展开那一块",
                  "which": f"页面上不止一个上传框，用 field 说传到哪个（上传按钮或那一块上的字）：{boxes}",
                  "nobox": f"点了「{said.get('button')}」，没等到上传框出来，也没打开系统的选择框。可能要先选上传方式；look_at_window 看看现在是什么样",
                  "script": said.get("why"), "unreadable": f"{app} 回的话看不懂，什么都没传"}
        if not said.get("found"):
            return {"ok": False, "error": errors.get(said.get("error"), "没找到上传框，什么都没传")}, None
        box = said.get("name") or field or "上传框"
        if len(paths) > 1 and not said.get("multiple"):
            return {"ok": False, "error": f"「{box}」一次只收一个文件：一个一个传，每次 files 只给一个"}, None
        # The one card: these files, to this site. Once said yes to, the rest of this job's files for the same site go ahead.
        allowed = job.uploads_allowed
        if site not in allowed:
            listed_files = "\n".join(f"{p.name}（{size / 1e6:.1f} MB）" for p, size in zip(paths, sizes))
            if not await self._card({"kind": "approval", "text": listed_files, "reason": f"把这些文件传到 {site} 的「{box}」"}, job):
                await step("drop")
                return {"ok": False, "error": f"{OWNER} 没批准上传，什么都没传"}, None
            allowed.add(site)
        for path, size in zip(paths, sizes):
            said = await step("file", {"name": path.name, "type": webfill.type_of(path), "size": size, "modified": int(path.stat().st_mtime * 1000)})
            if not said.get("ok"):
                break
            with path.open("rb") as handle:
                while said.get("ok") and (piece := await asyncio.to_thread(handle.read, webfill.CHUNK)):
                    said = await step("chunk", base64.b64encode(piece).decode())
                    if job and job.stopping:
                        await step("drop")
                        return {"ok": False, "error": f"{OWNER} 让停下，没有上传"}, None
            if not said.get("ok"):
                break
        else:
            said = await step("set")
        if not said.get("ok"):
            await step("drop")
            problems = {"gone": "页面刷新或换了，上传框不在了，什么都没传", "lost": "页面没接住文件（可能刷新了），什么都没传",
                        "single": f"「{box}」一次只收一个文件：一个一个传",
                        "accept": f"「{box}」不收「{said.get('name')}」这种文件（它只收 {said.get('accept')}），没有传。看看是不是传错了框",
                        "script": said.get("why")}
            return {"ok": False, "error": problems.get(said.get("error"), "没传进去")}, None
        given = said.get("given") or [p.name for p in paths]
        # The uploader starts on the change event; a moment later the page shows whether it did.
        seen = {}
        for wait in (1.5, 2.5, 4):
            await asyncio.sleep(wait)
            seen = await step("check", {"names": given})
            if seen.get("failed") or seen.get("done") or seen.get("uploading") or seen.get("percent") or seen.get("bars"):
                break
        signs = [f"页面出现了文件名 {'、'.join(seen['seen'])}" if seen.get("seen") else "",
                 f"进度 {seen['percent']}%" if seen.get("percent") else ("有进度条" if seen.get("bars") else ""),
                 f"页面上写着「{seen['uploading']}」" if seen.get("uploading") else "",
                 f"页面上写着「{seen['done']}」" if seen.get("done") else ""]
        signs = "；".join(s for s in signs if s)
        head = f"在后台把 {'、'.join(given)} 交给了 {site} 的「{box}」，没有打开系统的选择框，也没有点发布或提交。" + ("（先关掉了一个开着的系统文件选择框。）" if closed.get("closed") else "")
        if seen.get("failed"):
            return {"ok": False, "error": f"{head}但页面上写着「{seen['failed']}」：上传没成。看一眼窗口，告诉 {OWNER} 差在哪"}, None
        if signs:
            return {"ok": True, "message": f"{head}看到：{signs}。上传要一会儿，传完前不要保存或发布；用 look_at_window 核对传完了再接着做"}, None
        return {"ok": True, "message": f"{head}但页面上还看不出开始上传了：look_at_window 看一眼。没开始就说清停在哪一步，不要说传好了"}, None

    async def fill(self, text, files=(), window=None, chat=None, job=None, field=None):
        """Into a window's input. `job` left out: the owner pressed the panel's button, right here. A job's fill that needs the window in front waits for the owner to get there, and that is not a failure."""
        if job:
            key = ("fill", self._conversation(job))
            earlier = self.held.get(key)
            if earlier and earlier.get("placing"):  # Going in right now: another one would make two.
                await earlier["placed"].wait()
                if (earlier.get("result") or {}).get("ok"):
                    return {"ok": True, "message": "刚才排着的那一步刚放好，没有再放一次。"}
            self.held.pop(key, None)
        if chat and HAS_WECHAT:
            known = await asyncio.to_thread(lambda: [found["name"] for found in reader.find_chats(chat)[:40]])
            chat, others = full_chat_name(chat, known, ((job.chat if job else self.chat) or {}).get("name"))
            if others:
                return {"ok": False, "error": f"微信里有几个「{chat}」：{'、'.join(others[:5])}。问 {OWNER} 是哪一个，再填，chat 写全名"}
        why = None
        # A web page fills from inside, in the background, whatever editor it uses: nothing to wait for (Joe 2026-11-04).
        if job and not chat:
            shown = await self.native("resolve", window=window)
            if shown.get("ok") and shown.get("bundle") in webfill.BROWSERS:
                self._hands_on(job, shown)
                if files:  # a page's upload box takes the files from inside too: the system's file chooser is never opened (GitHub issue 3)
                    result, why = await self._upload_page(files, field, shown, str(shown.get("id") or window or ""), job)
                    if result is not None:
                        return result
                    return {"ok": False, "error": f"没有上传：{why}。不要去点上传按钮：系统的文件选择框后台选不了。{OWNER} 打开那个开关后再调一次就行；"
                                                  f"要是TA宁愿自己选，告诉TA在选择框里选哪个文件（{'、'.join(files)}），选好说一声你再接着做"}
                result, why = await self._fill_page(text, field, shown, str(shown.get("id") or window or ""))
                if result is not None:
                    return result
        result = await self._place(text, files, window, chat, job)
        if job and result.get("needsFront"):
            result = self._hold_fill(text, files, WECHAT if result.get("bundle") == WECHAT else str(result.get("id") or window or ""), chat, job, result.get("app") or "那个窗口", result.get("why"))
        if why:  # the model hears why the page's own way was missed, and can tell the owner the one thing that turns it on
            told = "message" if result.get("ok") else "error"
            result = {**result, told: f"{result.get(told) or ''}（网页里的后台填法没用上：{why}）"}
        return result

    async def _place(self, text, files, window, chat, job):
        """WeChat must be showing the conversation this was written for, checked again every time: the owner may have moved on since it was asked."""
        hand = self.native if job else lambda command, **args: self._unless_needs_front(None, command, **args)
        shown = await self.native("resolve", window=window or (WECHAT if chat else None))
        # A chat is a WeChat chat, whichever window it was asked in. Left to the job's own window, the file goes into the document.
        if chat and shown.get("bundle") != WECHAT:
            shown = await self.native("resolve", window=WECHAT)
        if not shown.get("ok"):
            return shown
        window = str(shown.get("id") or "") or window
        if not job:
            await self.native("bringForward", window=window)
        self._hands_on(job, shown)
        asked = job.chat if job else self.chat
        waiting = {"needsFront": True, "app": shown.get("app"), "bundle": shown.get("bundle"), "id": shown.get("id")}
        if shown.get("bundle") == WECHAT:
            want = chat or ((asked or {}).get("name") if (asked or {}).get("kind", "wechat") != "window" and (job or shown.get("stuck")) else None)
            # Without the optional reader no draft belongs to a chat: it goes where the owner is looking, and nothing is sent.
            if not want and HAS_WECHAT:
                return {"ok": False, "error": "要说清填到微信的哪段对话，没有填"}
            # Already showing it: nothing to search for, and the owner's pointer stays out of it. "Showing" is decided the way the panel follows the chat.
            async def header():
                seen = await self.native("titles", timeout=10, window=window)
                return [*(seen.get("lines") or []), *(seen.get("others") or [])]
            showing = await header() if chat else []
            if chat and not await asyncio.to_thread(self.is_showing, chat, showing):
                opened = await hand("openChat", timeout=15, window=window, name=chat)
                if opened.get("needsFront"):
                    return {**opened, **waiting, "why": f"微信标题读到的是「{(showing or ['看不清'])[0]}」，要先在搜索框里打开「{chat}」，这要用真鼠标"}
                if not opened.get("ok"):
                    return opened
            if want:
                seen = await header()
                if not await asyncio.to_thread(self.is_showing, want, seen):
                    return {"ok": False, "error": f"微信标题读到的是「{(seen or ['看不清'])[0]}」，对不上「{want}」，没有填。要是 {OWNER} 说开着的就是它，look_at_window 看一眼，对就不传 chat 再填"}
        result = await hand("fill", timeout=20, text=text, files=list(files), window=window)
        if result.get("needsFront"):
            return {**result, **waiting}
        if result.get("ok") and shown.get("bundle") == WECHAT and asked and (not chat or same_chat(chat, asked["name"])):
            self._remember_draft(text, asked, filled=True)
        return result

    async def _propose(self, original, edited, summary, job):
        source, copy = Path(original).expanduser(), Path(edited).expanduser()
        # Every touch of these files runs in a thread: the system may stop to ask the owner for a folder, and nothing else should wait for that.
        problem = await asyncio.to_thread(change_problem, source, copy)
        if problem:
            return self._reply(problem, ok=False)
        # The original is backed up before anything happens, so this goes ahead without a card (Joe 2026-11-04). What changed is in the answer.
        backup = await asyncio.to_thread(back_up, source)
        # The card's 看副本 leaves the copy open beside the original. It has done its job; if it won't go, nothing depends on it.
        await self.native("closeDocument", timeout=25, document=str(copy), held=True)
        close = await self._unless_needs_front(job, "closeDocument", timeout=25, document=str(source))
        if not close.get("ok"):
            if close.get("closing"):  # It may close late: the owner keeps their document either way.
                await self.native("openDocument", timeout=15, document=str(source), app=close.get("app"))
            return self._reply(close.get("error", "关不掉原文档，没有替换"), ok=False)
        problem = await asyncio.to_thread(replace_file, source, copy)
        opened = await self.native("openDocument", timeout=15, document=str(source), app=close.get("app"))
        if problem:
            return self._reply(f"替换失败（{problem}），原文件没动，已重新打开。", ok=False)
        if not opened.get("ok"):
            return self._reply(f"已替换，但没能重新打开：{opened.get('error') or '没有回应'}。原文件备份在 {backup}", ok=False)
        return self._reply(f"已替换并重新打开，原文件备份在 {backup}")

    def _private_names(self, job):
        return (OWNER, *(CONFIG.get("calls") or []), (job.chat or {}).get("name"), (job.window or {}).get("title"))
