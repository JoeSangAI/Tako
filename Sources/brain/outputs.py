"""Where a turn writes its work, and replacing a document only after a backup."""
from __future__ import annotations

import contextlib
import datetime as dt
import os
import re
import shutil

from settings import BACKUPS, OUTPUT_ROOT, RUNTIME, ZONE


def output_roots():
    return (OUTPUT_ROOT, RUNTIME / "output")


def make_output_dir(chat):
    """Where a turn may write. A folder the owner refused or that can't exist never stops the work: it goes to Tako's own."""
    name = re.sub(r"[^\w\u4e00-\u9fff-]+", "-", chat["name"] if chat else "tako").strip("-")[:24] or "tako"
    day = dt.datetime.now(ZONE).strftime("%Y-%m-%d")
    for root in output_roots():
        path = root / day / f"TAKO-{name}"
        with contextlib.suppress(OSError):
            path.mkdir(parents=True, exist_ok=True)
            return path
    raise OSError("no folder to write in")


def tidy_output_dir(path):
    """Nothing landed in it: it goes, and so do the day's folder and the root if they are empty now."""
    with contextlib.suppress(OSError):
        path.rmdir()
        path.parent.rmdir()
        path.parent.parent.rmdir()


def change_problem(source, copy):
    if not source.is_file() or not copy.is_file():
        return "原文件或副本不存在"
    if not any(copy.resolve().is_relative_to(root.resolve()) for root in output_roots()):
        return "副本要放在本轮作品目录里"
    if source.stat().st_mtime > copy.stat().st_mtime:
        return "原文件在复制之后又变过，这份副本已经旧了。重新复制再改。"
    return None


def back_up(source):
    BACKUPS.mkdir(parents=True, exist_ok=True)
    backup = BACKUPS / f"{dt.datetime.now(ZONE).strftime('%Y%m%d-%H%M%S')}-{source.name}"
    shutil.copy2(source, backup)
    return backup


def replace_file(source, copy):
    """Whole or not at all: a failure halfway never leaves a truncated original. Returns what went wrong."""
    temporary = source.with_name(f".{source.name}.tako")
    try:
        shutil.copy2(copy, temporary)
        os.replace(temporary, source)
        return None
    except OSError as exc:
        temporary.unlink(missing_ok=True)
        return type(exc).__name__
