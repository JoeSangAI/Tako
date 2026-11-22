"""Recognize an actual protected-folder failure; never probe a folder in advance."""
import re
import shlex
from pathlib import Path

PROTECTED = re.compile(r'(?:~/|' + re.escape(str(Path.home())) + r'/)(?:Desktop|Documents|Downloads)(?=/|[\s"\':]|$)', re.I)


def protected_denial(text, path=None, command=None):
    text = str(text or "")
    if command is not None:
        if any(c in command for c in "><|;&\n"):
            return False
        try:
            words = shlex.split(command)
        except ValueError:
            return False
        if not words or Path(words[0]).name not in {"cat", "head", "tail", "less", "more", "file", "stat"}:
            return False
    return "operation not permitted" in text.lower() and bool(PROTECTED.search(text + " " + str(path or "")))
