"""An office agent the owner already uses (WorkBuddy, Qoder, 千问办公) as Tako's brain, on the login and credits it already has.

Each ships a command-line agent that speaks ACP (Agent Client Protocol). `AcpRuntime` has the same methods as `CodexRuntime` and turns
them into ACP, so everything above it goes on talking Codex: threads, turns, their events and the requests made of `on_request`.
The agent's own tools are all switched off; the model gets Tako's tools over MCP (`tako_mcp.py`, which comes back here through a socket
only this process can open) and Codex's command and file change as `codex_tools.py` does them. A session is a thread.
Tako never reads their tokens. What the owner picked lives in `office.json`; whether its login is good is read from disk, at no cost.
"""
from __future__ import annotations

import asyncio
import base64
import contextlib
import json
import mimetypes
import os
import re
import secrets
import subprocess
import sys
import time
import uuid
from collections import defaultdict, deque
from pathlib import Path

import codex_tools
from codex_runtime import RuntimeErrorCode
from settings import CONFIG, HERE, OWNER, RUNTIME

FILE = RUNTIME / "office.json"
SESSIONS = RUNTIME / "office-sessions"  # The folder every session runs in, so the agent's own record of them can be found and cleared.
HOME = Path.home()

WORKBUDDY_APP = Path("/Applications/WorkBuddy.app")
WORKBUDDY_CLI = WORKBUDDY_APP / "Contents/Resources/app.asar.unpacked/cli/bin/codebuddy"
# The desktop app keeps its login here, and its command-line agent reads it from here too.
WORKBUDDY_LOGIN = HOME / "Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info"
# Every tool WorkBuddy's agent has of its own (2.137.1). It has no way to switch them all off, only to refuse them by name; anything
# newer that isn't named here still asks before it runs, and Tako refuses whatever isn't its own (`AcpRuntime.permission`).
WORKBUDDY_TOOLS = ("Agent Read Write Edit Bash Glob Grep PowerShell EnterPlanMode ExitPlanMode TaskCreate TaskGet TaskUpdate TaskList WebFetch "
                   "WebSearch TaskStop TaskOutput Skill AskUserQuestion StructuredOutput ToolSearch DeferExecuteTool SendMessage TeamCreate TeamDelete "
                   "ImageGen VideoGen WeChatReply WeComReply ListMcpResources ReadMcpResource MessageColleague SpeakInChannel NotebookEdit").split()

QODER_APP = Path("/Applications/Qoder CN.app")
QWENWORK_APP = Path("/Applications/QwenWorkCN.app")
QWENWORK_CLI = QWENWORK_APP / "Contents/Resources/bin/qoderclicn"
QODER_HOME = HOME / ".qoder-cn"  # Qoder CN and 千问办公 share this login.

# The only tool of their own Tako keeps: a web search answers questions and changes nothing. Their image and video makers, browsers,
# messaging and shells stay off, as Codex's do (`prompts.BRAIN_CONFIG`).
KEPT = ("WebSearch",)


def sessions_folder():
    """Its real name: the agent finds a session again only by the folder it was made in, and /var and /private/var are one folder by two names."""
    SESSIONS.mkdir(parents=True, exist_ok=True)
    return os.path.realpath(SESSIONS)


def _newest(paths):
    found = [p for p in paths if os.access(p, os.X_OK)]
    return max(found, key=lambda p: [int(n) for n in re.findall(r"\d+", p.name)] or [0], default=None)


def _qoder_cli():
    """Qoder CN's own copy first; the one inside 千问办公 is the same agent on the same login."""
    return _newest((QODER_HOME / "bin/qoderclicn").glob("qoderclicn-*")) or (QWENWORK_CLI if os.access(QWENWORK_CLI, os.X_OK) else None)


AGENTS = {
    "workbuddy": {"name": "WorkBuddy", "app": "WorkBuddy"},
    "qoder": {"name": "Qoder", "app": "Qoder CN"},
    "qwenwork": {"name": "千问办公", "app": "千问办公"},
}


def installed():
    """The office agents on this Mac, in the order the panel offers them."""
    found = []
    if os.access(WORKBUDDY_CLI, os.R_OK) and os.access(WORKBUDDY_APP / "Contents/MacOS/Electron", os.X_OK):
        found.append("workbuddy")
    if _qoder_cli():
        if QODER_APP.exists() or (QODER_HOME / "bin/qoderclicn").exists():
            found.append("qoder")
        if QWENWORK_APP.exists():
            found.append("qwenwork")
    return found


def current():
    """The office agent Tako uses instead of Codex, or None. Always on the model its own app is set to. A `cli` is only for the tests' stand-in."""
    found = None
    with contextlib.suppress(OSError, ValueError):
        found = json.loads(FILE.read_text())
    if not isinstance(found, dict):
        found = CONFIG.get("office") if isinstance(CONFIG.get("office"), dict) else None
    if not found or found.get("agent") not in AGENTS:
        return None
    return {**AGENTS[found["agent"]], "id": found["agent"], **({"cli": found["cli"]} if found.get("cli") else {})}


def save(agent):
    FILE.parent.mkdir(parents=True, exist_ok=True)
    FILE.write_text(json.dumps({"agent": agent}))


def forget():
    with contextlib.suppress(OSError):
        FILE.unlink()


def command(found, *, tools):
    """How to start the agent: (argv, environment, the folder it keeps its records in). `tools` False: none at all, not even a search."""
    keep = KEPT if tools else ()
    if found.get("cli"):  # A stand-in: told which agent it plays, nothing else.
        return [found["cli"], "--acp", "--plays", found["id"], *(["--keep", *keep] if keep else [])], {}, RUNTIME / "office-agent"
    if found["id"] == "workbuddy":
        # Its own copy of node, as the desktop app runs it; a folder of Tako's own for its records, so nothing lands in the owner's WorkBuddy.
        home = RUNTIME / "workbuddy-agent"
        argv = [str(WORKBUDDY_APP / "Contents/MacOS/Electron"), str(WORKBUDDY_CLI), "--acp", "--setting-sources", "project", "--no-session-persistence",
                "--disallowedTools", *[t for t in WORKBUDDY_TOOLS if t not in keep]]
        # Without this its agent hides tools that come from outside behind a search the model has to know to make.
        return argv, {"ELECTRON_RUN_AS_NODE": "1", "CODEBUDDY_CONFIG_DIR": str(home), "CODEBUDDY_DEFER_TOOL_LOADING": "false"}, home
    cli = str(_qoder_cli() or QWENWORK_CLI)
    return [cli, "--acp", "--setting-sources", "project", "--tools", *(keep or ("",))], {}, QODER_HOME


def problem(found):
    """What stands between this agent and a first answer, in the owner's words, or ''. Read from disk: nothing is sent anywhere."""
    if found.get("cli"):
        return "" if os.access(found["cli"], os.X_OK) else f"找不到 {found['name']}。"
    if found["id"] == "workbuddy":
        if "workbuddy" not in installed():
            return "这台 Mac 上没找到 WorkBuddy。装好并登录后再选它。"
        if not WORKBUDDY_LOGIN.exists() or WORKBUDDY_LOGIN.with_name(WORKBUDDY_LOGIN.name + ".logged-out").exists():
            return "WorkBuddy 还没登录。打开 WorkBuddy 登录一次，再点一次。"
        with contextlib.suppress(OSError, ValueError, TypeError, KeyError):
            auth = json.loads(WORKBUDDY_LOGIN.read_text())["auth"]
            if float(auth.get("refreshExpiresAt") or auth.get("expiresAt") or 0) / 1000 < time.time():
                return "WorkBuddy 的登录过期了。打开一次 WorkBuddy 重新登录，再点一次。"
        return ""
    cli = _qoder_cli()
    if not cli:
        return f"这台 Mac 上没找到 {found['name']}。装好并登录后再选它。"
    try:
        said = subprocess.run([str(cli), "status"], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return ""  # A slow answer is no evidence of a missing login; the first turn will say.
    if "Not logged in" in said or "Username" not in said:
        return f"{found['name']} 还没登录。打开 {found['app']} 登录一次，再点一次。"
    return ""


def stale_login(found):
    """The agent turned a turn away for its login. What to do about it, in one sentence."""
    if found["id"] == "workbuddy":
        return "WorkBuddy 的登录要刷新了：打开一次 WorkBuddy，它会自己刷新，然后再说一次。"
    return f"{found['name']} 的登录过期了：打开 {found['app']} 重新登录，然后再说一次。"


def clear_records(found):
    """The agent keeps a record of every session by the folder it ran in; Tako's ran in `SESSIONS`, and none of them should outlive the app."""
    if not found:
        return
    _, _, home = command(found, tools=False)
    marker = re.sub(r"[^A-Za-z0-9]", "-", SESSIONS.name)
    for folder in (home / "projects").glob(f"*{marker}"):
        for path in folder.iterdir():
            with contextlib.suppress(OSError):
                if path.is_dir():
                    for inner in sorted(path.rglob("*"), reverse=True):
                        inner.rmdir() if inner.is_dir() else inner.unlink()
                    path.rmdir()
                else:
                    path.unlink()



SOCKET = RUNTIME / "office-tools.sock"
RUNNING = RUNTIME / "office-agents.json"  # the agents this brain started: they don't go when it does (WorkBuddy's ignores its stdin closing)
UNAUTHORIZED = ("authentication", "unauthorized", "401", "not logged in", "login", "登录")
QUOTA = ("quota", "credit", "insufficient", "balance", "rate limit", "too many requests", "429", "积分", "额度", "余额", "限流")


def _remember(pid, alive):
    pids = set()
    with contextlib.suppress(OSError, ValueError):
        pids = set(json.loads(RUNNING.read_text()))
    pids = pids | {pid} if alive else pids - {pid}
    with contextlib.suppress(OSError):
        RUNNING.write_text(json.dumps(sorted(pids)))


def end_agents():
    """Every agent a Tako on this Mac started and left behind (a crash, a kill), or the ones of this one as the app quits. Only an ACP agent with
    Tako's own flags: a number that has since gone to another process is left alone."""
    with contextlib.suppress(OSError, ValueError):
        for pid in json.loads(RUNNING.read_text()):
            try:
                command = subprocess.run(["ps", "-o", "command=", "-p", str(int(pid))], capture_output=True, text=True, timeout=5).stdout
            except (OSError, subprocess.SubprocessError):
                continue
            if "--acp" in command and ("--setting-sources" in command or "--plays" in command):
                with contextlib.suppress(ProcessLookupError, PermissionError):
                    os.killpg(int(pid), 9)
    with contextlib.suppress(OSError):
        RUNNING.unlink()


def failure_info(message):
    """Codex's word for what went wrong, from what the agent said: the panel's sentence for it is in `turns.plain_failure`."""
    said = str(message or "").lower()
    if any(word in said for word in UNAUTHORIZED):
        return "unauthorized"
    if any(word in said for word in QUOTA):
        return "usageLimitExceeded"
    if any(word in said for word in ("econn", "network", "timed out", "timeout", "socket", "fetch failed", "502", "503", "504")):
        return "httpConnectionFailed"
    return "other"


def mcp_content(result):
    """Codex's tool answer (`Hands._reply`) as MCP content: words, and pictures as base64."""
    content = []
    for item in (result or {}).get("contentItems") or []:
        if item.get("type") == "inputText":
            content.append({"type": "text", "text": item.get("text") or ""})
        elif item.get("type") == "inputImage" and str(item.get("imageUrl") or "").startswith("data:"):
            head, _, data = item["imageUrl"].partition(",")
            content.append({"type": "image", "data": data, "mimeType": head[5:].split(";")[0] or "image/jpeg"})
    return {"content": content or [{"type": "text", "text": ""}], "isError": not (result or {}).get("success", True)}


def _tool_name(update):
    """Which tool an agent says it is calling: each keeps the name somewhere of its own in `_meta`."""
    for key, value in (update.get("_meta") or {}).items():
        found = value.get("toolName") if isinstance(value, dict) else value if key.endswith("toolName") else None
        if found:
            return str(found)
    return str(update.get("title") or "")


def ours(name):
    return name.startswith("mcp__tako__") or "(tako" in name or name in KEPT


class Agent:
    """One running copy of the agent, with one system prompt. JSON-RPC over its stdin and stdout, one message a line."""

    def __init__(self, runtime, argv, env):
        self.runtime, self.argv, self.env = runtime, argv, env
        self.process, self.reader, self.drain = None, None, None
        self.pending, self.next_id = {}, 0
        self.dead, self.capabilities, self.watch = False, {}, None
        self.write_lock = asyncio.Lock()
        self.sessions = set()

    async def start(self):
        SESSIONS.mkdir(parents=True, exist_ok=True)
        try:
            self.process = await asyncio.create_subprocess_exec(*self.argv, cwd=sessions_folder(), stdin=asyncio.subprocess.PIPE,
                                                                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
                                                                limit=32 * 1024 * 1024, env={**os.environ, **self.env}, start_new_session=True)
        except OSError as exc:
            raise RuntimeErrorCode("agent_missing") from exc
        _remember(self.process.pid, True)
        # It doesn't go when its stdin closes, so something has to see that this brain went: a kill -9 runs nothing of ours.
        agent = self.process.pid
        self.watch = subprocess.Popen(["/bin/sh", "-c", f"while kill -0 {os.getpid()} 2>/dev/null && kill -0 {agent} 2>/dev/null; do sleep 2; done; "
                                       f"ps -o command= -p {agent} | grep -q -- --acp && kill -9 -{agent} 2>/dev/null; exit 0"],
                                      stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        self.reader = asyncio.create_task(self._read())
        self.drain = asyncio.create_task(self._drain())
        result = await self.request("initialize", {"protocolVersion": 1, "clientInfo": {"name": "tako", "title": "Tako", "version": "1"},
                                                   "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}, "terminal": False}}, timeout=90)
        self.capabilities = (result or {}).get("agentCapabilities") or {}

    async def _drain(self):
        # What it says on stderr may name files or people; nothing of it is kept.
        while await self.process.stderr.read(8192):
            pass

    async def send(self, message):
        if self.dead:
            raise RuntimeErrorCode("runtime_disconnected")
        async with self.write_lock:
            self.process.stdin.write(json.dumps({"jsonrpc": "2.0", **message}, ensure_ascii=False).encode() + b"\n")
            try:
                await self.process.stdin.drain()
            except (BrokenPipeError, ConnectionResetError) as exc:
                raise RuntimeErrorCode("runtime_disconnected") from exc

    async def request(self, method, params, timeout=60):
        self.next_id += 1
        ident = self.next_id
        future = self.pending[ident] = asyncio.get_running_loop().create_future()
        try:
            await self.send({"id": ident, "method": method, "params": params})
            return await (asyncio.wait_for(future, timeout) if timeout else future)
        except asyncio.TimeoutError as exc:
            raise RuntimeErrorCode("rpc_outcome_unknown") from exc
        finally:
            self.pending.pop(ident, None)

    async def _read(self):
        try:
            while line := await self.process.stdout.readline():
                with contextlib.suppress(ValueError):
                    message = json.loads(line)
                    if not isinstance(message, dict):
                        continue
                    if "method" in message and "id" in message:
                        self.runtime.later(self._answer(message))
                    elif "id" in message:
                        future = self.pending.get(message["id"])
                        if future and not future.done():
                            if "error" in message:
                                future.set_exception(AgentFailed((message["error"] or {}).get("message")))
                            else:
                                future.set_result(message.get("result"))
                    elif message.get("method") == "session/update":
                        await self.runtime.update(message.get("params") or {})
        except asyncio.CancelledError:
            raise
        except Exception:
            pass
        finally:
            self.dead = True
            for future in list(self.pending.values()):
                if not future.done():
                    future.set_exception(RuntimeErrorCode("runtime_disconnected"))
            await self.runtime.lost(self)

    async def _answer(self, message):
        method, params = message.get("method"), message.get("params") or {}
        if method == "session/request_permission":
            result = self.runtime.permission(params)
        else:
            # It was told this client reads no files and runs no terminal: it may ask for nothing else.
            return await self.send({"id": message["id"], "error": {"code": -32601, "message": "not offered"}})
        with contextlib.suppress(RuntimeErrorCode):
            await self.send({"id": message["id"], "result": result})

    async def close(self):
        self.dead = True
        if self.process and self.process.returncode is None:
            with contextlib.suppress(ProcessLookupError, OSError):
                os.killpg(self.process.pid, 15)
            try:
                await asyncio.wait_for(self.process.wait(), 3)
            except asyncio.TimeoutError:
                with contextlib.suppress(ProcessLookupError, OSError):
                    os.killpg(self.process.pid, 9)
                await self.process.wait()
        if self.process:
            _remember(self.process.pid, False)
        if self.watch and self.watch.poll() is None:
            self.watch.kill()
        for task in (self.reader, self.drain):
            if task:
                task.cancel()


class _Cancelled(Exception):
    pass


class AgentFailed(RuntimeErrorCode):
    """The agent refused a turn and said why: kept as its words, sorted into Codex's kinds."""

    def __init__(self, message):
        super().__init__(failure_info(message))
        self.message = str(message or "")

    def __str__(self):
        return self.message or self.code


class AcpRuntime:
    def __init__(self, found, *, on_request=None):
        self.found, self.on_request = found, on_request
        self.executable = ""  # Codex's tools look for each other next to it; nothing here needs that.
        self.agents = {}  # (system prompt, has tools) -> Agent: one process for every brain and limb thread, one per kind of throwaway thread
        self.session_agent = {}
        self.turns, self.tools_of, self.tokens = {}, {}, {}  # session -> (turn id, its answer so far, its context); session -> tool list; token -> session
        self._events = defaultdict(deque)
        self._event_failures = {}
        self._changed = asyncio.Condition()
        self._accepted = defaultdict(set)
        self._workers = set()
        self.server = None
        self.closed, self.failure = True, None
        self.owner = OWNER

    # ---- the same methods as CodexRuntime ----
    async def start(self):
        if not self.closed:
            raise RuntimeErrorCode("already_started")
        if await asyncio.to_thread(problem, self.found):
            raise RuntimeErrorCode("unauthorized")
        await asyncio.to_thread(end_agents)
        await asyncio.to_thread(clear_records, self.found)
        SOCKET.parent.mkdir(parents=True, exist_ok=True)
        with contextlib.suppress(OSError):
            SOCKET.unlink()
        self.server = await asyncio.start_unix_server(self._serve_tools, path=str(SOCKET), limit=64 * 1024 * 1024)
        os.chmod(SOCKET, 0o600)
        self.closed = False
        return {}

    async def start_thread(self, cwd, *, sandbox="read-only", approval_policy="on-request", dynamic_tools=None, developer_instructions=None,
                           model=None, effort=None, config=None):
        tools = bool(dynamic_tools)
        key = (developer_instructions or "", tools)
        agent = self.agents.get(key)
        if agent is None or agent.dead:
            argv, env, _ = command(self.found, tools=tools)
            argv = [*argv, *(["--system-prompt", developer_instructions] if developer_instructions else [])]
            agent = self.agents[key] = Agent(self, argv, env)
            try:
                await agent.start()
            except BaseException:
                self.agents.pop(key, None)
                await agent.close()
                raise
        token = secrets.token_urlsafe(18)
        if tools:  # The agent lists them while the session is still being made.
            self.tools_of[token] = [{"name": t["name"], "description": t["description"], "inputSchema": t["inputSchema"]} for t in dynamic_tools] + list(codex_tools.TOOLS)
        servers = [{"name": "tako", "command": sys.executable, "args": ["-I", str(HERE / "tako_mcp.py")],
                    "env": [{"name": "TAKO_TOOLS_SOCKET", "value": str(SOCKET)}, {"name": "TAKO_TOOLS_TOKEN", "value": token}]}] if tools else []
        try:
            result = await agent.request("session/new", {"cwd": sessions_folder(), "mcpServers": servers}, timeout=120)
        except BaseException:
            self.tools_of.pop(token, None)
            raise
        session = result["sessionId"]
        agent.sessions.add(session)
        self.session_agent[session] = agent
        if tools:
            self.tokens[token] = session
        return {"thread": {"id": session}}

    async def start_turn(self, thread_id, text, *, execution_directory=None, writable=None, images=None, approval_policy="never", network=True):
        agent = self.session_agent.get(thread_id)
        if agent is None or agent.dead:
            raise RuntimeErrorCode("thread_not_found")
        if thread_id in self.turns:
            raise RuntimeErrorCode("turn_start_requires_reconciliation")
        turn = str(uuid.uuid4())
        self.turns[thread_id] = {"id": turn, "text": "", "cwd": execution_directory, "writable": list(writable or []), "sent": False, "cancelled": False}
        prompt = [{"type": "text", "text": text}]
        for path in images or []:
            with contextlib.suppress(OSError):
                kind = mimetypes.guess_type(path)[0] or "image/png"
                prompt.append({"type": "image", "mimeType": kind, "data": base64.b64encode(Path(path).read_bytes()).decode()})
        self.emit(thread_id, "turn/started", turn={"id": turn, "status": "inProgress"})
        self.later(self._prompt(agent, thread_id, turn, prompt))
        return {"turn": {"id": turn, "status": "inProgress"}}

    async def _prompt(self, agent, thread, turn, prompt):
        error, status = None, "completed"
        try:
            if (self.turns.get(thread) or {}).get("cancelled"):
                raise _Cancelled()  # stopped before it went out: it never goes
            self.turns[thread]["sent"] = True
            result = await agent.request("session/prompt", {"sessionId": thread, "prompt": prompt}, timeout=None)
            stop = (result or {}).get("stopReason")
            said = (self.turns.get(thread) or {}).get("text", "")
            if stop == "cancelled":
                status = "interrupted"
            elif stop == "refusal" and not said.strip():
                # WorkBuddy turns a turn away like this when its login needs refreshing, and says nothing else.
                error = {"codexErrorInfo": "unauthorized", "message": ""}
            if said.strip():
                self.emit(thread, "item/completed", turnId=turn, item={"type": "agentMessage", "id": str(uuid.uuid4()), "text": said})
        except _Cancelled:
            status = "interrupted"
        except AgentFailed as exc:
            error = {"codexErrorInfo": exc.code, "message": exc.message}
        except RuntimeErrorCode as exc:
            if exc.code == "runtime_disconnected":
                return  # `lost` has already told whoever waits on this thread.
            error = {"codexErrorInfo": "unauthorized" if exc.code == "unauthorized" else "other", "message": exc.code}
        finally:
            if (self.turns.get(thread) or {}).get("id") == turn:
                self.turns.pop(thread, None)
        self.emit(thread, "turn/completed", turn={"id": turn, "status": "failed" if error else status, "error": error})

    async def request(self, method, params=None, *, timeout=30):
        params = params or {}
        if method == "thread/compact/start":
            # The agent keeps its own context short. A summary Tako asks for is done as soon as it is asked.
            turn = str(uuid.uuid4())
            self.emit(params.get("threadId"), "turn/started", turn={"id": turn})
            self.emit(params.get("threadId"), "turn/completed", turn={"id": turn, "error": None})
            return {}
        # Words for a running turn (`turn/steer`) have nowhere to go in ACP: they wait for a turn of their own.
        raise RuntimeErrorCode("unsupported")

    async def interrupt(self, thread_id, turn_id):
        agent, turn = self.session_agent.get(thread_id), self.turns.get(thread_id)
        if turn and not turn["sent"]:
            turn["cancelled"] = True
        elif agent and not agent.dead:
            with contextlib.suppress(RuntimeErrorCode):
                await agent.send({"method": "session/cancel", "params": {"sessionId": thread_id}})
        return {}

    async def let_go(self, thread_id):
        """A thread is done: the agent forgets it, and its record of the session goes too if it can say so."""
        agent = self.session_agent.pop(thread_id, None)
        for token, session in list(self.tokens.items()):
            if session == thread_id:
                self.tokens.pop(token, None)
                self.tools_of.pop(token, None)
        self._accepted.pop(thread_id, None)
        if agent and not agent.dead:
            agent.sessions.discard(thread_id)
            sessions = agent.capabilities.get("sessionCapabilities") or {}
            for method in ("session/delete", "session/close"):
                if method.split("/")[1] in sessions:
                    with contextlib.suppress(RuntimeErrorCode, AgentFailed):
                        await agent.request(method, {"sessionId": thread_id}, timeout=15)
                    break
        self._events.pop(thread_id, None)
        self._event_failures.pop(thread_id, None)

    def give_up(self, thread_id):
        self._event_failures[thread_id] = "given_up"
        self._events[thread_id].clear()
        self.later(self._wake())

    async def event(self, thread_id, *, timeout=120):
        async def take():
            async with self._changed:
                while not self._events[thread_id]:
                    if thread_id in self._event_failures:
                        raise RuntimeErrorCode(self._event_failures[thread_id])
                    if self.closed:
                        raise RuntimeErrorCode(self.failure or "runtime_disconnected")
                    await self._changed.wait()
                return self._events[thread_id].popleft()
        return await asyncio.wait_for(take(), timeout)

    async def close(self):
        self.closed = True
        for agent in list(self.agents.values()):
            await agent.close()
        self.agents.clear()
        if self.server:
            self.server.close()
            with contextlib.suppress(Exception):
                await self.server.wait_closed()
            with contextlib.suppress(OSError):
                SOCKET.unlink()
        for task in list(self._workers):
            task.cancel()
        with contextlib.suppress(OSError):
            await asyncio.to_thread(clear_records, self.found)
        await self._wake()

    # ---- what the agent says ----
    async def update(self, params):
        thread, update = params.get("sessionId"), params.get("update") or {}
        kind = update.get("sessionUpdate")
        turn = self.turns.get(thread)
        if not turn:
            return
        if kind == "agent_message_chunk" and (update.get("content") or {}).get("type") == "text":
            delta = update["content"].get("text") or ""
            turn["text"] += delta
            self.emit(thread, "item/agentMessage/delta", turnId=turn["id"], delta=delta)
        elif kind == "tool_call":
            # Tako's own tools say themselves where they arrive (`_call`); the agent's web search is shown as Codex shows one.
            name = _tool_name(update)
            if name in KEPT or "search" in str(update.get("kind") or "").lower():
                query = (update.get("rawInput") or {}).get("query") or update.get("title") or ""
                self.emit(thread, "item/started", turnId=turn["id"], item={"type": "webSearch", "id": update.get("toolCallId"), "query": str(query)})
        elif kind == "usage_update" and update.get("used"):
            self.emit(thread, "thread/tokenUsage/updated", turnId=turn["id"], tokenUsage={"last": {"inputTokens": update["used"]}, "total": {"totalTokens": update["used"]}})

    def permission(self, params):
        """Its own tools are off; if one still asks, it is refused. Tako's tools decide inside themselves, so they are let through."""
        name = _tool_name(params.get("toolCall") or {})
        options = params.get("options") or []
        if ours(name):
            pick = next((o for o in options if o.get("kind") == "allow_once"), None) or next((o for o in options if o.get("kind", "").startswith("allow")), None)
        else:
            pick = next((o for o in options if o.get("kind", "").startswith("reject")), None)
        return {"outcome": {"outcome": "selected", "optionId": pick["optionId"]}} if pick else {"outcome": {"outcome": "cancelled"}}

    async def lost(self, agent):
        """The process went away: whoever waits on one of its threads hears so, and a brain without its process starts again."""
        for session in list(agent.sessions):
            self._event_failures[session] = "runtime_disconnected"
            self.turns.pop(session, None)
        if any(key[1] and value is agent for key, value in self.agents.items()):
            self.closed, self.failure = True, "runtime_disconnected"
        await self._wake()

    # ---- what the tools need ----
    def turn_context(self, thread):
        return self.turns.get(thread) or {}

    def accepted(self, thread):
        return self._accepted[thread]

    async def ask_owner(self, method, params):
        try:
            return ((await self.on_request(method, params)) or {}).get("decision")
        except Exception:
            return "decline"  # Never a yes when nobody could be asked.

    def emit(self, thread, method, **params):
        if not thread:
            return
        turn = self.turns.get(thread)
        if method == "item/started" and turn and turn["text"].strip():
            # What it said before a step is an aside, as Codex keeps it: only the words after the last step are the answer.
            aside, turn["text"] = turn["text"], ""
            self._events[thread].append({"method": "item/completed", "params": {"threadId": thread, "turnId": turn["id"], "item": {
                "type": "agentMessage", "id": str(uuid.uuid4()), "text": aside, "phase": "commentary"}}})
        self._events[thread].append({"method": method, "params": {"threadId": thread, **params}})
        self.later(self._wake())

    async def _wake(self):
        async with self._changed:
            self._changed.notify_all()

    def later(self, coro):
        task = asyncio.get_running_loop().create_task(coro)
        self._workers.add(task)
        task.add_done_callback(self._workers.discard)
        return task

    async def _call(self, thread, name, args):
        turn = (self.turns.get(thread) or {}).get("id")
        if name in codex_tools.NAMES:
            text, ok = await codex_tools.run(self, thread, turn, name, args)
            return {"content": [{"type": "text", "text": text}], "isError": not ok}
        item = str(uuid.uuid4())
        self.emit(thread, "item/started", turnId=turn, item={"type": "dynamicToolCall", "id": item, "tool": name, "arguments": args})
        try:
            result = await self.on_request("item/tool/call", {"threadId": thread, "turnId": turn, "callId": item, "tool": name, "arguments": args})
        except Exception:
            result = {"success": False, "contentItems": [{"type": "inputText", "text": "这个工具这次没有回应。"}]}
        self.emit(thread, "item/completed", turnId=turn, item={"type": "dynamicToolCall", "id": item, "tool": name})
        return mcp_content(result)

    async def _serve_tools(self, reader, writer):
        """`tako_mcp.py` asking, one question a connection: which tools this session has, or a call. Only a session's own token gets an answer."""
        try:
            asked = json.loads(await reader.readline())
            token = str(asked.get("token") or "")
            thread = self.tokens.get(token)
            if asked.get("op") == "list" and token in self.tools_of:
                answer = {"tools": self.tools_of[token]}
            elif not thread:
                answer = {"error": "这个会话没有工具。"}
            else:
                answer = await self._call(thread, str(asked.get("tool") or ""), asked.get("arguments") or {})
            writer.write(json.dumps(answer, ensure_ascii=False).encode() + b"\n")
            await writer.drain()
        except (OSError, ValueError, asyncio.IncompleteReadError):
            pass
        finally:
            writer.close()


def brain_runtime(on_request):
    """Codex, unless the owner chose an office agent as the brain."""
    found = current()
    if found:
        return AcpRuntime(found, on_request=on_request)
    from first_run import find_codex
    from codex_runtime import CodexRuntime
    return CodexRuntime(find_codex() or "codex", on_request=on_request)
