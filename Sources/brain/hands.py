"""What the model can reach for: the tools, the cards that wait for the owner, and the bridge to the app, the only process with the permissions."""
from __future__ import annotations

import asyncio
import difflib
import json
import secrets
import subprocess
import sys
import time
from pathlib import Path

import feedback as fb
import wechat_reader as reader
from chats import render
from guards import SCRIPTABLE, clipped, normalized, plain_command, risky_script, unsafe_script, workbench_packet
from outputs import back_up, change_problem, replace_file
from settings import CONFIG, HAS_WECHAT, OWNER, WECHAT, WORKBENCH, WORKBENCH_CARDS, local_today

FEEDBACK_KINDS = {"bug": "出了问题", "rough": "不好用", "wish": "想用的场景"}
COMING_BACK_SECONDS = 1800  # How long the last step of a job waits for the owner to come back to its window.


class Hands:
    async def on_server_request(self, method, params):
        # A throwaway thread is never on this list, so it has no tools and can ask for nothing. If it ever tried, no running job answers for it.
        job = self.on_thread.get(params.get("threadId"))
        if method == "item/tool/call":
            if not job:
                return self._reply("这个线程没有工具。", ok=False)
            result = await self._tool(params.get("tool"), params.get("arguments") or {}, job)
            self._weigh(job, sum(len(item.get("imageUrl") or "") for item in result.get("contentItems") or []))
            if job.origin == "owner":
                self.feedback.count(f"tool.{params.get('tool')}" if result.get("success") else f"tool_failed.{params.get('tool')}")
            return result
        if method in ("item/commandExecution/requestApproval", "item/fileChange/requestApproval"):
            if not job or job.origin != "owner":
                return {"decision": "decline"}
            if method == "item/fileChange/requestApproval":
                await asyncio.sleep(0.1)  # the item's own start event carries the paths
                paths = job.changing.get(params.get("itemId")) or [params.get("grantRoot")]
                text = "改动文件：" + "、".join(str(path) for path in paths if path) if any(paths) else "改动文件"
            else:
                text = plain_command(params.get("command")) or "运行命令"
            accepted = await self._card({"kind": "approval", "text": clipped(str(text)), "reason": str(params.get("reason") or "")[:200]}, job)
            # Asked once: the same thing doesn't come back to the owner for the rest of this session.
            return {"decision": "acceptForSession" if accepted else "decline"}
        if method == "item/permissions/requestApproval":
            return {"permissions": {}, "scope": "turn"}
        if method == "item/tool/requestUserInput":
            return {"answers": {}}
        if method == "mcpServer/elicitation/request":
            return {"action": "decline"}
        raise RuntimeError("unsupported_server_request")

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
            return {"ok": False, "error": "TAKO 那边没有回应"}
        finally:
            self.waiting.pop(request, None)

    async def _unless_needs_front(self, job, command, timeout=30, **args):
        """Nearly everything happens behind the owner's back. What needs the real pointer never takes it: the model finishes the rest, and the job picks it up when they are back on that window."""
        began = time.time()
        while True:
            result = await self.native(command, timeout=timeout, **args)
            if not result.get("needsFront"):
                return result
            if job:
                job.left_for_owner = True
                return {"ok": False, "error": f"{result.get('error')}，先没做。后面能做的先做完，最后说一句差哪一步；{OWNER} 回到这个窗口时你会被叫来接着做，TA不用开口。"}
            # The owner just pressed a button on the panel: a few seconds for their hand to settle is all this takes.
            if time.time() - began > 8:
                return {"ok": False, "error": f"{result.get('error')}，这一步没有做"}
            await asyncio.sleep(0.5)

    async def _pick_up_when_back(self, job):
        key = (job.chat or {}).get("username") or id(job.events)
        mark = self.held[key] = {"name": job.name, "events": job.events, "trouble": f"差一步要 {(job.window or {}).get('app') or '那个窗口'} 在前台，切回去就接着做。"}
        deadline = time.time() + COMING_BACK_SECONDS
        try:
            while self.held.get(key) is mark and time.time() < deadline:
                await asyncio.sleep(2)
                seen = await self.native("isBack", timeout=5, window=job.window_id)
                if seen.get("error"):  # The window has gone.
                    return
                if seen.get("ok") and self.held.get(key) is mark:
                    del self.held[key]
                    await self.turn("窗口回到前台了。把刚才差的那一步做完，做完说一声。", where=(job.chat, job.events, job.window))
                    return
        finally:
            if self.held.get(key) is mark:
                del self.held[key]

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

    async def _tool(self, name, args, job):
        # Whatever an incoming message says, it cannot make TAKO look around or act.
        if job.origin != "owner":
            return self._reply("这一轮由对方的新消息触发，不能看窗口，也不能动手。", ok=False)
        job.call_waiting = None
        job.tools_running += 1
        job.status = "working"
        try:
            return await self._run_tool(name, args, job)
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
        if name == "operate_window":
            return await self._operate(args.get("steps") or [], window, job)
        if name == "fill_input":
            result = await self.fill(str(args.get("text") or ""), [str(f) for f in args.get("files") or []], window, str(args.get("chat") or "") or None, job)
            return self._reply(result.get("message") or result.get("error") or "", ok=bool(result.get("ok")))
        if name == "read_wechat":
            return await self._read_wechat(str(args.get("chat") or ""), int(args.get("limit") or 30))
        if name == "point_at":
            result = await self.native("point", text=str(args.get("text") or ""), window=window)
            return self._reply("标好了" if result.get("ok") else result.get("error", "窗口上没找到这段文字"), ok=bool(result.get("ok")))
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
        if result.get("document"):
            lines.append(f"文件：{result['document']}")
        if result.get("elements"):
            lines.append("可以按的元素（编号 角色 名称 (x,y,宽,高)，编号到下次看窗口前有效）：\n" + str(result["elements"])[:14000])
        if result.get("lines"):
            lines.append("画面上的文字 (x,y,宽,高)：\n" + str(result["lines"])[:9000])
        if result.get("text") and not result.get("lines"):
            lines.append("窗口文字：\n" + str(result["text"])[:9000])
        return self._reply("\n".join(lines), result.get("image"))

    async def _operate(self, steps, window, job):
        target = await self.native("resolve", window=window)
        if not target.get("ok"):
            return self._reply(target.get("error", "没找到窗口"), ok=False)
        window = str(target.get("id") or "") or window  # Named once, the same window for every step, whatever comes to the front.
        done = []
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
                    break
                done.append(str(result.get("did") or "完成"))
        finally:
            await self.native("endSteps")
        seen = await self.native("look", window=window)
        report = "\n".join(done)
        if seen.get("ok"):
            more = str(seen.get("elements") or "")[:6000]
            return self._reply(f"{report}\n\n现在的窗口：{seen.get('title')}\n可以按的元素：\n{more}", seen.get("image"))
        return self._reply(report)

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
            app = next((name for name in SCRIPTABLE.values() if app_name.lower() in name.lower() or name.lower() in app_name.lower()), None)
        else:
            app = SCRIPTABLE.get((job.window or {}).get("bundle"))
        if not app:
            return self._reply(f"{app_name or (job.window or {}).get('app') or '这个应用'} 没有脚本接口。", ok=False)
        if problem := unsafe_script(script, app):
            return self._reply(problem, ok=False)
        if word := risky_script(script):
            if not await self._card({"kind": "approval", "text": clipped(script), "reason": f"在 {app} 里运行这段脚本（含 {word}）"}, job):
                return self._reply(f"{OWNER} 没批准这段脚本，没有运行。")
        result = await self.native("script", timeout=90, script=script)
        return self._reply(str(result.get("output") or result.get("error") or "完成"), ok=bool(result.get("ok")))

    async def fill(self, text, files=(), window=None, chat=None, job=None):
        """Into a window's input. WeChat must be showing the conversation this was written for. `job` left out: the owner pressed the panel's button, right here."""
        if chat and not window:
            window = WECHAT  # A chat is a WeChat chat, whichever window it was asked in.
        shown = await self.native("resolve", window=window)
        if not shown.get("ok"):
            return shown
        window = str(shown.get("id") or "") or window
        if not job:
            await self.native("bringForward", window=window)
        asked = job.chat if job else self.chat
        if shown.get("bundle") == WECHAT:
            want = chat or ((asked or {}).get("name") if (asked or {}).get("kind", "wechat") != "window" and (job or shown.get("stuck")) else None)
            # Without the optional reader no draft belongs to a chat: it goes where the owner is looking, and nothing is sent.
            if not want and HAS_WECHAT:
                return {"ok": False, "error": "要说清填到微信的哪段对话，没有填"}
            if chat:
                opened = await self._unless_needs_front(job, "openChat", timeout=15, window=window, name=chat)
                if not opened.get("ok"):
                    return opened
            if want:
                seen = await self.native("titles", timeout=10, window=window)
                key = normalized(want)
                lines = [normalized(line) for line in seen.get("lines") or []]
                digits = lambda text: "".join(ch for ch in text if ch.isdigit())
                # Forgiving of a misread character, not of a sibling chat: 产品讨论组1 is not 产品讨论组2.
                if not any(line == key or (digits(line) == digits(key) and difflib.SequenceMatcher(None, line, key).ratio() >= 0.9) for line in lines):
                    return {"ok": False, "error": f"微信现在打开的不是「{want}」，没有填"}
        result = await self._unless_needs_front(job, "fill", timeout=20, text=text, files=list(files), window=window)
        if result.get("ok") and shown.get("bundle") == WECHAT and asked and (not chat or normalized(chat) == normalized(asked["name"])):
            self._remember_draft(text, asked, filled=True)
        return result

    async def _propose(self, original, edited, summary, job):
        source, copy = Path(original).expanduser(), Path(edited).expanduser()
        # Every touch of these files runs in a thread: the system may stop to ask the owner for a folder, and nothing else should wait for that.
        problem = await asyncio.to_thread(change_problem, source, copy)
        if problem:
            return self._reply(problem, ok=False)
        accepted = await self._card({"kind": "change", "text": clipped(summary), "original": str(source), "edited": str(copy)}, job)
        if not accepted:
            return self._reply(f"{OWNER} 没有应用这份改动，原文件没动。")
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
