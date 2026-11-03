"""Where a turn writes its work, and replacing a document only after a backup."""
from __future__ import annotations

import base64
import contextlib
import datetime as dt
import glob
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

from settings import BACKUPS, OUTPUT_ROOT, RUNTIME, ZONE


def output_roots():
    return (OUTPUT_ROOT, RUNTIME / "output")


def file_pictures(path, first=1, count=6):
    """A document as pictures of its pages, with nothing on screen. This runs out here because the model's sandbox stops LibreOffice and Quick Look, and it would otherwise ask the owner, or open Word in front of them, just to see its own work. No profile or copy stays behind."""
    source = Path(path).expanduser()
    if not source.is_file():
        raise FileNotFoundError(path)
    tools = f"{os.environ.get('PATH', '')}:/opt/homebrew/bin:/usr/local/bin:/Applications/LibreOffice.app/Contents/MacOS"
    def run(*command):
        subprocess.run(command, capture_output=True, timeout=90, check=False)

    with tempfile.TemporaryDirectory(dir=RUNTIME) as work:
        work = Path(work)
        pdf = source if source.suffix.lower() == ".pdf" else None
        soffice = shutil.which("soffice", path=tools)
        if not pdf and soffice:
            run(soffice, "--headless", "--norestore", f"-env:UserInstallation=file://{work}/profile", "--convert-to", "pdf", "--outdir", str(work), str(source))
            pdf = next(work.glob("*.pdf"), None)
        poppler = shutil.which("pdftoppm", path=tools)
        if pdf and poppler:
            run(poppler, "-jpeg", "-r", "80", "-f", str(first), "-l", str(first + count - 1), str(pdf), str(work / "page"))
            pages = sorted(work.glob("page*.jpg"))
        else:  # Quick Look comes with every Mac, and shows the first page only.
            run("/usr/bin/qlmanage", "-t", "-s", "1200", "-o", str(work), str(source))
            pages = []
            for picture in work.glob("*.png"):
                run("/usr/bin/sips", "-s", "format", "jpeg", str(picture), "--out", str(picture.with_suffix(".jpg")))
                pages.append(picture.with_suffix(".jpg"))
        return [base64.b64encode(page.read_bytes()).decode() for page in pages if page.is_file()]


def file_in_title(title):
    """A window that only names its document: WPS doesn't hold a Word file open, so no process can say where it is. WeChat's folder first, then Spotlight, and only when one file fits."""
    name = Path(str(title or "").replace("[只读]", "").strip()).name
    if not re.fullmatch(r".+\.(docx?|xlsx?|pptx?|pdf|csv|txt|md|key|numbers|pages)", name, re.I):
        return None
    wechat = Path.home() / "Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files"
    found = sorted(wechat.glob(f"*/msg/file/*/{glob.escape(name)}"), key=lambda path: path.stat().st_mtime)
    if found:
        return str(found[-1])
    with contextlib.suppress(OSError, subprocess.SubprocessError):
        lines = subprocess.run(["/usr/bin/mdfind", "-name", name], capture_output=True, text=True, timeout=3).stdout.splitlines()
        exact = [line for line in lines if Path(line).name == name]
        if len(exact) == 1:
            return exact[0]
    return None


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
