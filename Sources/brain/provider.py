"""Bring your own key: a model service other than a ChatGPT login, reached through the same Codex.

Codex talks to any service that speaks OpenAI's Responses API; nothing else in Tako changes with it. The key the owner typed in
the panel lives in `provider.json` (0600) on this Mac and reaches Codex only as an environment variable of its own process.
"""
from __future__ import annotations

import contextlib
import json
import os
import subprocess
import sys
from pathlib import Path

from settings import CONFIG, LIGHT_MODEL, MODEL, RUNTIME

FILE = RUNTIME / "provider.json"
ENV = "TAKO_PROVIDER_KEY"
# All of them answer OpenAI's Responses API, which is all Codex speaks. `page` is where the owner makes a key.
# DeepSeek and Qwen were run through Tako's scenes (2026-11-07); Kimi and GLM only by their documentation until someone with a key tries.
PRESETS = {
    "deepseek": {"name": "DeepSeek", "base_url": "https://api.deepseek.com/v1", "model": "deepseek-flash", "page": "https://platform.deepseek.com/api_keys"},
    "qwen": {"name": "通义千问", "base_url": "https://dashscope.aliyuncs.com/compatible-mode/v1", "model": "qwen3.8-flash", "page": "https://bailian.console.aliyun.com/?tab=model#/api-key"},
    "kimi": {"name": "Kimi", "base_url": "https://api.moonshot.cn/v1", "model": "kimi-k3", "page": "https://platform.moonshot.cn/console/api-keys"},
    "glm": {"name": "智谱 GLM", "base_url": "https://open.bigmodel.cn/api/v1", "model": "glm-5.3", "page": "https://open.bigmodel.cn/usercenter/proj-mgmt/apikeys"},
}


def services():
    """What the panel offers, in this order; the last one is any other address that speaks Responses, such as a relay."""
    return [*({"id": key, "name": value["name"], "page": value["page"]} for key, value in PRESETS.items()), {"id": "custom", "name": "其他 / 中转站", "page": ""}]


def _key(found):
    """Typed in the panel, or a line in an env file the owner already keeps (`path#NAME`), read when it is needed."""
    if found.get("key"):
        return str(found["key"]).strip()
    path, _, name = str(found.get("key_file") or "").partition("#")
    with contextlib.suppress(OSError):
        for line in Path(path).expanduser().read_text().splitlines():
            left, sep, right = line.strip().removeprefix("export ").partition("=")
            if sep and left.strip() == name:
                return right.strip().strip("'\"")
    return ""


def current():
    """The service Tako uses instead of a ChatGPT login, or None. What the panel saved comes before config.json."""
    found = None
    with contextlib.suppress(OSError, ValueError):
        found = json.loads(FILE.read_text())
    if not isinstance(found, dict):
        found = CONFIG.get("provider") if isinstance(CONFIG.get("provider"), dict) else None
    if not found:
        return None
    merged = {**PRESETS.get(found.get("preset"), {}), **{k: v for k, v in found.items() if v}}
    if not merged.get("base_url") or not merged.get("model"):
        return None
    return {**merged, "key": _key(merged)}


def model():
    found = current()
    return found["model"] if found else MODEL


def light_model():
    found = current()
    return (found.get("light_model") or found["model"]) if found else LIGHT_MODEL


def codex_args(found=None):
    """What the app server is started with: a provider of Tako's own, so the owner's Codex settings stay as they are."""
    found = found or current()
    if not found:
        return []
    values = {"model_provider": "tako", "model_providers.tako.name": found.get("name") or "Tako", "model_providers.tako.base_url": found["base_url"],
              "model_providers.tako.env_key": ENV, "model_providers.tako.wire_api": "responses", "web_search": "disabled"}
    args = []
    for name, value in values.items():
        args += ["-c", f"{name}={json.dumps(value, ensure_ascii=False)}"]
    return args


def codex_env(found=None):
    found = found or current()
    return {ENV: found["key"]} if found and found.get("key") else {}


def address(base_url):
    """What people paste: a bare host, or the whole chat/completions URL from a relay's page. Codex wants the API root."""
    url = (base_url or "").strip().rstrip("/")
    for tail in ("/chat/completions", "/responses", "/models"):
        url = url.removesuffix(tail)
    if url and "://" not in url:
        url = "https://" + url
    if url.count("/") == 2:  # Only the host: OpenAI-style services and relays serve /v1.
        url += "/v1"
    return url


def _curl(url, key, body=None):
    """Through the system's curl: it trusts what this Mac trusts (a proxy's certificate in the Keychain), as Codex does and Python's own SSL doesn't.
    The key goes in on stdin, never in an argument another process could see. Returns (status, body); status 0 when nothing answered."""
    executable = str(Path(os.environ.get("SystemRoot", "C:/Windows")) / "System32/curl.exe") if sys.platform == "win32" else "/usr/bin/curl"
    command = [executable, "-sS", "--max-time", "15", "-H", "@-", "-w", "\n%{http_code}", url]
    if body is not None:
        command[5:5] = ["-X", "POST", "--data", body]
    headers = f"Authorization: Bearer {key}\n" + ("Content-Type: application/json\n" if body is not None else "")
    try:
        done = subprocess.run(command, input=headers, capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return 0, ""
    text, _, code = done.stdout.rpartition("\n")
    return (int(code) if code.isdigit() else 0), text


def check(service, key, base_url="", model=""):
    """Asks the service who this key is, which costs nothing. Returns (what to tell the owner or '', the models it offers).
    A service of the owner's own choosing (a relay) is also asked whether it speaks Responses at all, with an empty request it can only refuse."""
    known = PRESETS.get(service)
    name = known["name"] if known else "这个地址"
    root = known["base_url"] if known else address(base_url)
    if not root:
        return "先填中转站或服务商的地址。", []
    code, body = _curl(f"{root}/models", key)
    if not code:
        return f"连不上{' ' * name[0].isascii()}{name}，检查地址和网络后再试。", []
    if code in (401, 403):
        return "这个 key 不对，或者已经停用了。", []
    names = []
    with contextlib.suppress(ValueError, AttributeError, TypeError):
        names = sorted(str(m.get("id")) for m in json.loads(body).get("data", []) if m.get("id"))
    if code != 200 and known:
        return f"{name} 那边出错了（{code}），稍后再试。", []
    wanted = known["model"] if known else model
    if known and names and wanted not in names:
        return f"这个 key 用不了 {wanted}，先在 {name} 的控制台开通它。", names
    if not known:
        answered, _ = _curl(f"{root}/responses", key, "{}")
        if answered in (0, 404, 405, 501):
            return "这个地址不支持 Responses 接口，Tako 用的 Codex 只认它。换一个支持 Responses 的中转站或服务商。", names
        if not wanted:
            return ("选一个模型。" if names else "这个地址没列出模型，填上要用的模型名。"), names
    return "", names


def save(service, key, base_url="", model=""):
    """A known service keeps only its name and the key; anything else keeps where it is and which model."""
    found = {"preset": service, "key": key} if service in PRESETS else {"name": "中转站", "base_url": address(base_url), "model": model.strip(), "key": key}
    FILE.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as out:
        json.dump(found, out, ensure_ascii=False)
    os.chmod(FILE, 0o600)


def forget():
    with contextlib.suppress(OSError):
        FILE.unlink()
