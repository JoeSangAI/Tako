"""Install the official Windows Codex binary after the owner presses Connect."""
import hashlib
import json
import os
from pathlib import Path
import tempfile
import tarfile
import shutil
import time
import urllib.request


def install(folder):
    folder = Path(folder)
    class HTTPSRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            if not newurl.startswith("https://"):
                raise ValueError("insecure_release_redirect")
            return super().redirect_request(req, fp, code, msg, headers, newurl)
    opener = urllib.request.build_opener(HTTPSRedirect())
    def fetch(url, target):
        began, size = time.monotonic(), 0
        request = urllib.request.Request(url, headers={"User-Agent": "Tako-Windows-installer"})
        with opener.open(request, timeout=30) as response, target.open("wb") as output:
            while block := response.read(65536):
                size += len(block)
                if size > 512 * 1024 * 1024 or time.monotonic() - began > 300:
                    raise TimeoutError("release_download_limit")
                output.write(block)
    with tempfile.TemporaryDirectory() as temporary:
        temporary = Path(temporary)
        fetch("https://api.github.com/repos/openai/codex/releases/latest", temporary / "release.json")
        release = json.loads((temporary / "release.json").read_text(encoding="utf-8"))
        asset = next(a for a in release["assets"] if a["name"] == "codex-package-x86_64-pc-windows-msvc.tar.gz")
        url, digest = asset["browser_download_url"], asset.get("digest", "")
        if not url.startswith("https://github.com/openai/codex/releases/download/") or not digest.startswith("sha256:"):
            raise ValueError("official_release_digest_missing")
        archive = temporary / "codex.tar.gz"; fetch(url, archive)
        with archive.open("rb") as source:
            actual = hashlib.file_digest(source, "sha256").hexdigest()
        if actual != digest.split(":", 1)[1]:
            raise ValueError("release_digest_mismatch")
        extracted = temporary / "unpacked"
        with tarfile.open(archive) as bundled:
            bundled.extractall(extracted, filter="data")
        expected = ("codex-package.json", "bin/codex.exe", "bin/codex-code-mode-host.exe",
                    "codex-path/rg.exe", "codex-resources/codex-command-runner.exe",
                    "codex-resources/codex-windows-sandbox-setup.exe")
        if not all((extracted / name).is_file() for name in expected):
            raise ValueError("release_package_incomplete")
        version = str(int(release["id"]))
        target = folder / "releases" / version
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists():
            shutil.move(str(extracted), str(target))
        if not all((target / name).is_file() for name in expected):
            raise ValueError("installed_package_incomplete")
        pointer = folder / "current.json.new"
        pointer.write_text(json.dumps({"path": f"releases/{version}/bin/codex.exe"}), encoding="utf-8")
        os.replace(pointer, folder / "current.json")
