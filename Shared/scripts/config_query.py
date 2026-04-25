#!/usr/bin/env python3
import json
import shlex
import sys
from pathlib import Path


def eprint(msg: str) -> None:
    print(msg, file=sys.stderr)


def load_json(path: Path):
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def shell_quote(value) -> str:
    if value is None:
        value = ""
    return shlex.quote(str(value))


def emit_models_shell(models):
    nums = [str(m.get("num", "")) for m in models if m.get("num") is not None]
    print(f"MODEL_NUMS=({' '.join(nums)})")
    fields = ("NAME", "FILE", "URL", "SIZE", "MINB", "LOCAL", "LABEL", "BADGE", "PROMPT")
    key_map = {
        "NAME": "name",
        "FILE": "file",
        "URL": "url",
        "SIZE": "size",
        "MINB": "min_bytes",
        "LOCAL": "local",
        "LABEL": "label",
        "BADGE": "badge",
        "PROMPT": "prompt",
    }
    for m in models:
        num = m.get("num")
        if num is None:
            continue
        for field in fields:
            key = key_map[field]
            val = m.get(key, "")
            print(f"MODEL_{field}_{num}={shell_quote(val)}")


def emit_vendors_lines(assets):
    for a in assets:
        name = a.get("name", "")
        url = a.get("url", "")
        if name and url:
            print(f"{name}|{url}")


def main():
    if len(sys.argv) < 2:
        eprint("Usage: config_query.py <vendors|models-shell> [desktop|android]")
        return 1

    cmd = sys.argv[1]
    root = Path(__file__).resolve().parent.parent

    if cmd == "vendors":
        data = load_json(root / "config" / "ui-vendor-assets.json")
        emit_vendors_lines(data.get("assets", []))
        return 0

    if cmd == "models-shell":
        if len(sys.argv) < 3 or sys.argv[2] not in ("desktop", "android"):
            eprint("Usage: config_query.py models-shell <desktop|android>")
            return 1
        profile = sys.argv[2]
        data = load_json(root / "config" / "models.json")
        key = "desktop_models" if profile == "desktop" else "android_models"
        emit_models_shell(data.get(key, []))
        return 0

    eprint(f"Unknown command: {cmd}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
