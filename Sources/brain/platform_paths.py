"""Small OS boundary shared by the brain and its standalone CLI."""
import os
import sys
from pathlib import Path


def runtime_root():
    if os.environ.get("TAKO_HOME"):
        return Path(os.environ["TAKO_HOME"])
    if sys.platform == "win32":
        return Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData/Local") / "Tako"
    return Path.home() / "Library/Application Support/Tako"
