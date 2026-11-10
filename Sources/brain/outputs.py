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
import time
from pathlib import Path

import settings
from settings import BACKUPS, RUNTIME, WORK, ZONE

PRODUCTS = "产出文件"
RECORDS = "对话记录"
WORK_DAYS, BACKUP_DAYS = 7, 30
DAY = re.compile(r"\d{4}-\d{2}-\d{2}")


def products_root():
    return settings.output_root() / PRODUCTS


def output_roots():
    """Where a turn's work may be: Tako's folder, the fallback when that can't be written, and the scratch."""
    return (settings.output_root(), RUNTIME / "output", WORK)


def folder_name(chat):
    return re.sub(r"[^\w\u4e00-\u9fff-]+", "-", chat["name"] if chat else "tako").strip("-")[:24] or "tako"


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
    """Where a turn puts what it hands the owner. A folder the owner refused or that can't exist never stops the work: it goes to Tako's own."""
    day = dt.datetime.now(ZONE).strftime("%Y-%m-%d")
    for root in (products_root(), RUNTIME / "output"):
        path = root / day / folder_name(chat)
        with contextlib.suppress(OSError):
            path.mkdir(parents=True, exist_ok=True)
            return path
    raise OSError("no folder to write in")


def make_work_dir(chat):
    """The turn's scratch, where commands run: what it needs on the way and nobody asked for (Joe 2026-11-10: a cleanup's 772 files sat among the work)."""
    path = WORK / dt.datetime.now(ZONE).strftime("%Y-%m-%d") / folder_name(chat)
    path.mkdir(parents=True, exist_ok=True)
    return path


def tidy_output_dir(path):
    """Nothing landed in it: it goes, and so do the day's folder and 产出文件 if they are empty now."""
    with contextlib.suppress(OSError):
        path.rmdir()
        path.parent.rmdir()
        path.parent.parent.rmdir()


def files_in(folder):
    """Every file under a folder and when it last changed, hidden ones left out."""
    found = {}
    with contextlib.suppress(OSError):
        for path in Path(folder).rglob("*"):
            if path.is_file() and not any(part.startswith(".") for part in path.relative_to(folder).parts):
                with contextlib.suppress(OSError):
                    found[str(path)] = path.stat().st_mtime
    return found


def made_since(folder, before):
    """What this one ask made or changed in the folder, not what earlier asks left there."""
    return sorted(path for path, changed in files_in(folder).items() if before.get(path) != changed)


def _to_trash(path):
    trash = Path.home() / ".Trash"
    target = trash / path.name
    if target.exists():
        target = trash / f"{path.stem} {time.strftime('%H.%M.%S')}{path.suffix}"
    shutil.move(str(path), str(target))


def tidy_runtime(now=None):
    """Tako's own leftovers, without asking: scratch after a week is gone, backups after a month go to the Trash. What the owner was handed is theirs to delete."""
    now = now or time.time()
    with contextlib.suppress(OSError):
        for day in WORK.iterdir():
            if day.is_dir() and now - day.stat().st_mtime > WORK_DAYS * 86400:
                shutil.rmtree(day, ignore_errors=True)
    with contextlib.suppress(OSError):
        for backup in BACKUPS.iterdir():
            if now - backup.stat().st_mtime > BACKUP_DAYS * 86400:
                with contextlib.suppress(OSError):
                    _to_trash(backup)


def move_old_layout(root=None):
    """Before 对话记录 and 产出文件, a day's folders sat in Tako's folder itself as TAKO-name: they go where they belong now. Only Tako's own, never anything else in there."""
    root = Path(root or settings.output_root())
    with contextlib.suppress(OSError):
        for day in root.iterdir():
            if not (day.is_dir() and DAY.fullmatch(day.name)):
                continue
            for old in day.iterdir():
                if old.is_dir() and old.name.startswith("TAKO-"):
                    target = root / PRODUCTS / day.name / (old.name[5:] or "tako")
                    if not target.exists():
                        target.parent.mkdir(parents=True, exist_ok=True)
                        old.rename(target)
            with contextlib.suppress(OSError):
                (day / ".DS_Store").unlink(missing_ok=True)
                day.rmdir()


def change_problem(source, copy):
    if not source.is_file() or not copy.is_file():
        return "原文件或副本不存在"
    if not any(copy.resolve().is_relative_to(root.resolve()) for root in output_roots()):
        return "副本要放在本轮草稿目录或作品目录里"
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
