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


class Hands:
    async def on_server_request(self, method, params):
        # A throwaway thread has no tools and can ask for nothing. If it ever tried, the owner's running turn must not answer for it.
        ours = params.get("threadId") == self.thread
        if method == "item/tool/call":
            if not ours:
                return self._reply("这个线程没有工具。", ok=False)
            result = await self._tool(params.get("tool"), params.get("arguments") or {})
            if self.origin == "owner":
                self.feedback.count(f"tool.{params.get('tool')}" if result.get("success") else f"tool_failed.{params.get('tool')}")
            return result
        if method in ("item/commandExecution/requestApproval", "item/fileChange/requestApproval"):
            if self.origin != "owner" or not ours:
                return {"decision": "decline"}
            if method == "item/fileChange/requestApproval":
                await asyncio.sleep(0.1)  # the item's own start event carries the paths
                paths = self.changing.get(params.get("itemId")) or [params.get("grantRoot")]
                text = "改动文件：" + "、".join(str(path) for path in paths if path) if any(paths) else "改动文件"
            else:
                text = plain_command(params.get("command")) or "运行命令"
            accepted = await self._card({"kind": "approval", "text": clipped(str(text)), "reason": str(params.get("reason") or "")[:200]})
            return {"decision": "accept" if accepted else "decline"}
        if method == "item/permissions/requestApproval":
            return {"permissions": {}, "scope": "turn"}
        if method == "item/tool/requestUserInput":
            return {"answers": {}}
        if method == "mcpServer/elicitation/request":
            return {"action": "decline"}
        raise RuntimeError("unsupported_server_request")

    async def _card(self, card):
        card["id"] = secrets.token_hex(4)
        card["future"] = self.loop.create_future()
        self.pending[card["id"]] = card
        try:
            return await card["future"]
        finally:
            self.pending.pop(card["id"], None)

    def _dismiss_cards(self):
        for card in list(self.pending.values()):
            if not card["future"].done():
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

    async def _tool(self, name, args):
        # Whatever an incoming message says, it cannot make TAKO look around or act.
        if self.origin != "owner":
            return self._reply("这一轮由对方的新消息触发，不能看窗口，也不能动手。", ok=False)
        self.call_waiting = None
        self.tools_running += 1
        self.status = "working"
        try:
            return await self._run_tool(name, args)
        except Exception as exc:
            # Whatever went wrong here, the model hears it and the turn goes on.
            self.feedback.error(f"tool.{name}", exc)
            return self._reply(f"这一步出错了（{type(exc).__name__}），没有做成。", ok=False)
        finally:
            self.tools_running -= 1
            # A tool can outlive its turn when the owner stops it, and it must not bring the busy state back.
            if not self.tools_running and self.status == "working":
                self.status = "thinking"

    async def _run_tool(self, name, args):
        window = str(args.get("window") or "") or None
        if name == "list_windows":
            result = await self.native("windows")
            lines = [f"{w['id']}｜{w['app']}｜{w['title']}" + ("｜TAKO 粘在这里" if w.get("stuck") else "") for w in result.get("windows", [])]
            return self._reply("\n".join(lines) or "没有打开的窗口")
        if name == "look_at_window":
            return await self._look(window)
        if name == "operate_window":
            return await self._operate(args.get("steps") or [], window)
        if name == "fill_input":
            result = await self.fill(str(args.get("text") or ""), [str(f) for f in args.get("files") or []], window, str(args.get("chat") or "") or None)
            return self._reply(result.get("message") or result.get("error") or "", ok=bool(result.get("ok")))
        if name == "read_wechat":
            return await self._read_wechat(str(args.get("chat") or ""), int(args.get("limit") or 30))
        if name == "point_at":
            result = await self.native("point", text=str(args.get("text") or ""), window=window)
            return self._reply("标好了" if result.get("ok") else result.get("error", "窗口上没找到这段文字"), ok=bool(result.get("ok")))
        if name == "run_in_app":
            return await self._script(str(args.get("script") or ""), str(args.get("app") or ""))
        if name == "tell_workbench":
            return await self._tell_workbench(args)
        if name == "report_feedback":
            return await self._report_feedback(args)
        if name == "listen":
            return await self._listen(str(args.get("action") or ""), str(args.get("text") or ""), window)
        if name == "propose_file_change":
            return await self._propose(str(args.get("original")), str(args.get("edited")), str(args.get("summary")), window)
        return self._reply("没有这个工具", ok=False)

    async def _look(self, window):
        result = await self.native("look", window=window)
        if not result.get("ok"):
            return self._reply(result.get("error", "看不到窗口"), ok=False)
        lines = [f"窗口 id：{result.get('id')}", f"应用：{result.get('app')}", f"标题：{result.get('title')}"]
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

    async def _operate(self, steps, window):
        target = await self.native("resolve", window=window)
        if not target.get("ok"):
            return self._reply(target.get("error", "没找到窗口"), ok=False)
        await self.native("beginSteps", window=window)
        done = []
        run = self.running
        try:
            for step in steps[:40]:
                if self.stopping or self.running != run:
                    done.append(f"{OWNER} 让停下，后面的没有做。")
                    return self._reply("\n".join(done))
                result = await self.native("step", timeout=40, window=window, step=step)
                if result.get("needs"):
                    accepted = await self._card({"kind": "approval", "text": str(result["needs"])[:400], "reason": ""})
                    if not accepted:
                        done.append(f"{OWNER} 没批准：{result['needs']}。已停下")
                        break
                    result = await self.native("step", timeout=40, window=window, step=step, confirmed=True)
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

    async def _report_feedback(self, args):
        """Something the owner chose to say: nothing leaves until they have read exactly what would, and pressed send."""
        kind = args.get("kind")
        text = fb.scrub(str(args.get("text") or ""), self._private_names())
        if kind not in FEEDBACK_KINDS or not text or not fb.URL:
            return self._reply("这条反馈发不了。", ok=False)
        packet = self.feedback.say_packet(kind, text)
        shown = f"{text}\n\n{FEEDBACK_KINDS[kind]} · Tako {packet['version']} · macOS {packet['macos']}"
        if not await self._card({"kind": "feedback", "text": shown}):
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

    async def _script(self, script, app_name):
        if app_name:
            app = next((name for name in SCRIPTABLE.values() if app_name.lower() in name.lower() or name.lower() in app_name.lower()), None)
        else:
            app = SCRIPTABLE.get((self.window or {}).get("bundle"))
        if not app:
            return self._reply(f"{app_name or (self.window or {}).get('app') or '这个应用'} 没有脚本接口。", ok=False)
        if problem := unsafe_script(script, app):
            return self._reply(problem, ok=False)
        if word := risky_script(script):
            if not await self._card({"kind": "approval", "text": clipped(script), "reason": f"在 {app} 里运行这段脚本（含 {word}）"}):
                return self._reply(f"{OWNER} 没批准这段脚本，没有运行。")
        result = await self.native("script", timeout=90, script=script)
        return self._reply(str(result.get("output") or result.get("error") or "完成"), ok=bool(result.get("ok")))

    async def fill(self, text, files=(), window=None, chat=None):
        """Into a window's input. WeChat must be showing the conversation this was written for."""
        window = window or (WECHAT if chat else None)  # A chat is a WeChat chat, whichever window the goo sits on.
        shown = await self.native("resolve", window=window)
        if not shown.get("ok"):
            return shown
        if shown.get("bundle") == WECHAT:
            want = chat or (self.chat["name"] if shown.get("stuck") and self.chat and self.chat.get("kind") != "window" else None)
            # Without the optional reader no draft belongs to a chat: it goes where the owner is looking, and nothing is sent.
            if not want and HAS_WECHAT:
                return {"ok": False, "error": "要说清填到微信的哪段对话，没有填"}
            if chat:
                opened = await self.native("openChat", timeout=15, window=window, name=chat)
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
        result = await self.native("fill", timeout=20, text=text, files=list(files), window=window)
        if result.get("ok") and shown.get("bundle") == WECHAT and self.chat and (not chat or normalized(chat) == normalized(self.chat["name"])):
            self._remember_draft(text, self.chat, filled=True)
        return result

    async def _propose(self, original, edited, summary, window=None):
        source, copy = Path(original).expanduser(), Path(edited).expanduser()
        # Every touch of these files runs in a thread: the system may stop to ask the owner for a folder, and nothing else should wait for that.
        problem = await asyncio.to_thread(change_problem, source, copy)
        if problem:
            return self._reply(problem, ok=False)
        accepted = await self._card({"kind": "change", "text": clipped(summary), "original": str(source), "edited": str(copy)})
        if not accepted:
            return self._reply(f"{OWNER} 没有应用这份改动，原文件没动。")
        backup = await asyncio.to_thread(back_up, source)
        close = await self.native("closeDocument", timeout=15, document=str(source))
        if not close.get("ok"):
            return self._reply(close.get("error", "关不掉原文档，没有替换"), ok=False)
        problem = await asyncio.to_thread(replace_file, source, copy)
        opened = await self.native("openDocument", timeout=15, document=str(source), app=close.get("app"))
        if problem:
            return self._reply(f"替换失败（{problem}），原文件没动，已重新打开。", ok=False)
        if not opened.get("ok"):
            return self._reply(f"已替换，但没能重新打开：{opened.get('error') or '没有回应'}。原文件备份在 {backup}", ok=False)
        return self._reply(f"已替换并重新打开，原文件备份在 {backup}")

    def _private_names(self):
        return (OWNER, *(CONFIG.get("calls") or []), (self.chat or {}).get("name"), (self.window or {}).get("title"))
