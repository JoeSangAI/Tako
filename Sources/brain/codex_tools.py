"""Codex's own two tools, a command and a file change, for a brain that doesn't bring Codex (`office.py`).

They work the way Codex's do, so everything after them is unchanged: a command runs in the same macOS sandbox, writing only to the
turn's folder and where the owner pointed; one that has to leave it, or a change outside those places, is put to `Hands.on_server_request`
as the same approval Codex would ask for, which backs up, asks a card or lets it go exactly as it does for Codex.
"""
from __future__ import annotations

import asyncio
import contextlib
import os
import tempfile
import time
import uuid
from pathlib import Path

OUTPUT_LIMIT = 16000

SHELL = {"name": "shell", "description": "在这台 Mac 上运行一条 shell 命令（zsh），返回退出码和输出。默认在沙箱里：哪里都能读，只能写本轮作品目录、草稿目录和主人指给你的地方。"
         "命令要写到别处、要出沙箱时，带上 with_escalated_permissions: true 和一句 justification 申请。改已有的文件用 apply_patch。",
         "inputSchema": {"type": "object", "properties": {
             "command": {"type": "string", "description": "要运行的命令"},
             "workdir": {"type": "string", "description": "在哪个文件夹运行，不填就是本轮草稿目录"},
             "timeout_ms": {"type": "integer", "description": "最长等多久，默认 120000"},
             "with_escalated_permissions": {"type": "boolean", "description": "true：申请在沙箱外运行"},
             "justification": {"type": "string", "description": "为什么要出沙箱，一句话"}}, "required": ["command"], "additionalProperties": False}}
APPLY_PATCH = {"name": "apply_patch", "description": "新建、修改或删除文件。input 用这个格式：\n*** Begin Patch\n*** Add File: 路径\n+新文件的每一行\n"
               "*** Update File: 路径\n@@ 要改的地方附近的一行（可省）\n 不变的行\n-删掉的行\n+加上的行\n*** Delete File: 路径\n*** End Patch\n"
               "路径可以是绝对路径，或相对本轮草稿目录。改的行前后各带两三行不变的行，按原文逐字写。",
               "inputSchema": {"type": "object", "properties": {"input": {"type": "string", "description": "整个补丁"}}, "required": ["input"], "additionalProperties": False}}
TOOLS = (SHELL, APPLY_PATCH)
NAMES = {tool["name"] for tool in TOOLS}


def _real(path):
    return os.path.realpath(os.path.expanduser(str(path)))


def writable_roots(turn):
    """Where a command may write without asking: the turn's own places, and the temporary folders every command needs."""
    roots = [*(turn.get("writable") or []), tempfile.gettempdir(), "/private/tmp"]
    if turn.get("cwd"):
        roots.insert(0, turn["cwd"])
    return [_real(root) for root in roots if root]


def inside(path, roots):
    real = _real(path)
    return any(real == root or real.startswith(root.rstrip("/") + "/") for root in roots)


def profile(roots):
    """The sandbox: everything as usual, except that writing goes only to these places (and the devices a shell writes to)."""
    quoted = " ".join(f'(subpath "{root}")' for root in roots)
    return ("(version 1)\n(allow default)\n"
            f'(deny file-write* (require-not (require-any {quoted} (literal "/dev/null") (literal "/dev/zero") (regex #"^/dev/tty") (subpath "/dev/fd"))))\n')


def _clip(text):
    return text if len(text) <= OUTPUT_LIMIT else text[:OUTPUT_LIMIT // 2] + f"\n…（中间省略 {len(text) - OUTPUT_LIMIT} 字）…\n" + text[-OUTPUT_LIMIT // 2:]


async def _run(command, cwd, timeout, sandbox_roots):
    argv = ["/bin/zsh", "-lc", command]
    if sandbox_roots is not None:
        argv = ["/usr/bin/sandbox-exec", "-p", profile(sandbox_roots), *argv]
    began = time.time()
    process = await asyncio.create_subprocess_exec(*argv, cwd=cwd, stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE,
                                                   stderr=asyncio.subprocess.STDOUT, start_new_session=True)
    try:
        output, _ = await asyncio.wait_for(process.communicate(), timeout)
        code = process.returncode
    except asyncio.TimeoutError:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, 9)
        output, code = (await process.communicate())[0], None
    except asyncio.CancelledError:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, 9)
        raise
    return code, output.decode(errors="replace"), time.time() - began


async def shell(runtime, thread, turn, args):
    """One command, as Codex runs it: in the sandbox unless asked otherwise, and outside it only once the approval says so."""
    context = runtime.turn_context(thread)
    command = str(args.get("command") or "").strip()
    if not command:
        return "没有命令。", False
    cwd = _real(args.get("workdir") or context.get("cwd") or Path.home())
    if not os.path.isdir(cwd):
        return f"文件夹不存在：{cwd}", False
    timeout = min(max(int(args.get("timeout_ms") or 120000), 1000), 600000) / 1000
    item = str(uuid.uuid4())
    runtime.emit(thread, "item/started", turnId=turn, item={"type": "commandExecution", "id": item, "command": command, "cwd": cwd})
    outside = bool(args.get("with_escalated_permissions"))
    if outside and command not in runtime.accepted(thread):
        decision = await runtime.ask_owner("item/commandExecution/requestApproval", {
            "threadId": thread, "turnId": turn, "itemId": item, "command": command, "cwd": cwd, "reason": str(args.get("justification") or "")[:200]})
        if decision == "acceptForSession":
            runtime.accepted(thread).add(command)
        elif decision != "accept":
            runtime.emit(thread, "item/completed", turnId=turn, item={"type": "commandExecution", "id": item, "status": "declined"})
            return f"{runtime.owner} 没有同意在沙箱外运行这条命令。", False
    code, output, took = await _run(command, cwd, timeout, None if outside else writable_roots(context))
    runtime.emit(thread, "item/completed", turnId=turn, item={"type": "commandExecution", "id": item, "exitCode": code})
    said = f"Exit code: {'超时，已停' if code is None else code}\nWall time: {took:.1f} seconds\nOutput:\n{_clip(output)}"
    if not outside and code and "operation not permitted" in output.lower():
        said += "\n（沙箱拦下了写入。真要写到这里，就带 with_escalated_permissions 和 justification 再申请一次。）"
    return said, code == 0


class PatchError(ValueError):
    pass


def parse_patch(text, cwd):
    """Codex's patch format: [(action, path, body, move_to)]. Relative paths are inside the turn's folder."""
    lines = text.strip("\n").splitlines()
    if not lines or lines[0].strip() != "*** Begin Patch":
        raise PatchError("补丁要以 *** Begin Patch 开头")
    ops, current = [], None
    for line in lines[1:]:
        if line.strip() == "*** End Patch":
            break
        for action in ("Add", "Delete", "Update"):
            head = f"*** {action} File: "
            if line.startswith(head):
                path = line[len(head):].strip()
                current = [action, _real(path if os.path.isabs(os.path.expanduser(path)) else Path(cwd) / path), [], None]
                ops.append(current)
                break
        else:
            if current is None:
                raise PatchError(f"这一行不属于任何文件：{line[:80]}")
            if line.startswith("*** Move to: "):
                target = line[len("*** Move to: "):].strip()
                current[3] = _real(target if os.path.isabs(os.path.expanduser(target)) else Path(cwd) / target)
            elif line.strip() != "*** End of File":
                current[2].append(line)
    if not ops:
        raise PatchError("补丁里没有文件")
    return ops


def _apply_hunks(original, body):
    """Each hunk's old lines must be found in order; context lines match exactly first, then without trailing spaces."""
    lines, at = original.split("\n"), 0
    hunks, hunk = [], []
    for line in body:
        if line.startswith("@@"):
            if hunk:
                hunks.append(hunk)
            hunk = [line]
        else:
            hunk.append(line)
    if hunk:
        hunks.append(hunk)
    for hunk in hunks:
        anchor = hunk[0][2:].strip() if hunk[0].startswith("@@") else ""
        rows = hunk[1:] if hunk[0].startswith("@@") else hunk
        old = [row[1:] for row in rows if row[:1] in (" ", "-") or row == ""]
        new = [row[1:] for row in rows if row[:1] in (" ", "+") or row == ""]
        if anchor:
            found = next((i for i in range(at, len(lines)) if anchor in lines[i]), None)
            if found is not None:
                at = found
        for same in (lambda a, b: a == b, lambda a, b: a.rstrip() == b.rstrip()):
            place = next((i for i in range(at, len(lines) - len(old) + 1) if all(same(lines[i + k], old[k]) for k in range(len(old)))), None)
            if place is not None:
                break
        if place is None:
            raise PatchError("找不到要改的那几行，先读一下文件现在的样子再改：" + " / ".join(old[:3])[:160])
        lines[place:place + len(old)] = new
        at = place + len(new)
    return "\n".join(lines)


def _write(ops):
    done = []
    for action, path, body, move_to in ops:
        target = Path(move_to or path)
        if action == "Delete":
            Path(path).unlink()
            done.append(f"D {path}")
            continue
        if action == "Add":
            text = "\n".join(row[1:] if row.startswith("+") else row for row in body) + "\n"
        else:
            text = _apply_hunks(Path(path).read_text(), body)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        if move_to and move_to != path:
            Path(path).unlink()
        done.append(f"{'A' if action == 'Add' else 'M'} {target}")
    return done


async def apply_patch(runtime, thread, turn, args):
    """A file change, as Codex makes one: inside the turn's places it just happens; anywhere else the approval decides, after a backup."""
    context = runtime.turn_context(thread)
    try:
        ops = parse_patch(str(args.get("input") or ""), context.get("cwd") or Path.home())
        # Checked before anything is written: a change that can't go in leaves every file as it was.
        for action, path, body, _ in ops:
            if action == "Update":
                _apply_hunks(Path(path).read_text(), body)
            elif action == "Delete" and not Path(path).is_file():
                raise PatchError(f"没有这个文件：{path}")
    except (PatchError, OSError, UnicodeDecodeError) as exc:
        return f"补丁没有用上：{exc}", False
    paths = sorted({p for _, path, _, move_to in ops for p in (path, move_to) if p})
    item = str(uuid.uuid4())
    runtime.emit(thread, "item/started", turnId=turn, item={"type": "fileChange", "id": item, "changes": [{"path": p} for p in paths]})
    if not all(inside(p, writable_roots(context)) for p in paths):
        decision = await runtime.ask_owner("item/fileChange/requestApproval", {"threadId": thread, "turnId": turn, "itemId": item, "reason": ""})
        if decision not in ("accept", "acceptForSession"):
            runtime.emit(thread, "item/completed", turnId=turn, item={"type": "fileChange", "id": item, "status": "declined"})
            return f"{runtime.owner} 没有同意这次改动。", False
    try:
        done = _write(ops)
    except (PatchError, OSError, UnicodeDecodeError) as exc:
        return f"补丁没有用上：{exc}", False
    finally:
        runtime.emit(thread, "item/completed", turnId=turn, item={"type": "fileChange", "id": item})
    return "Success. Updated the following files:\n" + "\n".join(done), True


async def run(runtime, thread, turn, name, args):
    return await (shell if name == "shell" else apply_patch)(runtime, thread, turn, args)
