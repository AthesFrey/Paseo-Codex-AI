#!/usr/bin/env python3
"""Apply manually entered primary and backup model IDs to Paseo and Codex."""
from __future__ import annotations

import argparse
import json
import os
import stat
import sys
import tempfile
import tomllib
from pathlib import Path


THINKING_OPTIONS = [
    {"id": "low", "label": "Low"},
    {"id": "medium", "label": "Medium"},
    {"id": "high", "label": "High", "isDefault": True},
    {"id": "xhigh", "label": "Extra High"},
    {"id": "max", "label": "Max"},
]


def load_selection(path: Path) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    models = data.get("models")
    default = data.get("default")
    if not isinstance(models, list) or not models or not isinstance(default, str):
        raise ValueError(f"模型选择文件无效：{path}")
    ids: list[str] = []
    for item in models:
        if not isinstance(item, dict) or not isinstance(item.get("id"), str) or not item["id"]:
            raise ValueError(f"模型选择文件包含无效 ID：{path}")
        if item["id"] in ids:
            raise ValueError(f"模型选择文件包含重复 ID：{item['id']}")
        ids.append(item["id"])
    if default not in ids:
        raise ValueError(f"默认模型不在选择列表中：{default}")
    return {"models": models, "default": default}


def model_entries(selection: dict, provider_label: str) -> list[dict]:
    entries = []
    for item in selection["models"]:
        model_id = item["id"]
        entries.append(
            {
                "id": model_id,
                "label": f"{model_id} ({provider_label})",
                "isDefault": model_id == selection["default"],
                "thinkingOptions": [dict(option) for option in THINKING_OPTIONS],
            }
        )
    if sum(bool(item["isDefault"]) for item in entries) != 1:
        raise ValueError(f"{provider_label} 必须恰好有一个默认模型。")
    return entries


def atomic_write(path: Path, content: str) -> None:
    original = path.stat()
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent), text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(content)
        os.chown(temporary, original.st_uid, original.st_gid)
        os.chmod(temporary, stat.S_IMODE(original.st_mode))
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def apply(args: argparse.Namespace) -> None:
    main_selection = load_selection(args.main_selection)
    back_selection = load_selection(args.back_selection) if args.back_selection else None
    config_path = args.paseo_config
    config = json.loads(config_path.read_text(encoding="utf-8"))
    providers = config.setdefault("agents", {}).setdefault("providers", {})
    providers["codex"]["enabled"] = True
    providers["codex"]["models"] = model_entries(main_selection, "HahaAPI")
    config["agents"]["metadataGeneration"]["providers"] = [
        {
            "provider": "codex",
            "model": main_selection["default"],
            "thinkingOptionId": "high",
        }
    ]

    if back_selection:
        providers["codex-bk"] = {
            "extends": "codex",
            "label": "Codex_bk",
            "description": "Codex via BackAPI",
            "enabled": True,
            "order": 20,
            "command": [args.wrapper],
            "env": {
                "OPENAI_BASE_URL": args.backapi_base_url,
                "OPENAI_API_KEY": "__paseo_backapi_wrapper__",
            },
            "models": model_entries(back_selection, "BackAPI"),
        }
    else:
        providers.pop("codex-bk", None)

    toml_path = args.codex_config
    lines = toml_path.read_text(encoding="utf-8").splitlines(keepends=True)
    model_line = next((i for i, line in enumerate(lines) if line.startswith("model =")), None)
    if model_line is None:
        raise ValueError("Codex 配置缺少 model。")
    lines[model_line] = f"model = {json.dumps(main_selection['default'])}\n"
    section_name = "[model_providers.hahaapi]"
    section_start = next((i for i, line in enumerate(lines) if line.strip() == section_name), None)
    if section_start is None:
        raise ValueError("Codex 配置缺少主 API provider。")
    section_end = next(
        (i for i in range(section_start + 1, len(lines)) if lines[i].lstrip().startswith("[")),
        len(lines),
    )
    base_url_line = next(
        (i for i in range(section_start + 1, section_end) if lines[i].lstrip().startswith("base_url =")),
        None,
    )
    replacement = f"base_url = {json.dumps(args.base_url)}\n"
    if base_url_line is None:
        lines.insert(section_start + 1, replacement)
    else:
        lines[base_url_line] = replacement
    updated_toml = "".join(lines)
    tomllib.loads(updated_toml)

    # Validate both full documents before replacing either live config.
    json.dumps(config, ensure_ascii=False, indent=2)
    atomic_write(toml_path, updated_toml)
    atomic_write(config_path, json.dumps(config, ensure_ascii=False, indent=2) + "\n")

    print(
        f"MODEL_CONFIG_OK：主 API {len(main_selection['models'])} 个模型"
        f"（默认 {main_selection['default']}）。"
    )
    if back_selection:
        print(
            f"BACKAPI_CONFIG_OK：BackAPI {len(back_selection['models'])} 个模型"
            f"（默认 {back_selection['default']}）。"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--paseo-config", required=True, type=Path)
    parser.add_argument("--codex-config", required=True, type=Path)
    parser.add_argument("--main-selection", required=True, type=Path)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--wrapper", required=True)
    parser.add_argument("--back-selection", type=Path)
    parser.add_argument("--backapi-base-url", default="")
    args = parser.parse_args()
    if bool(args.back_selection) != bool(args.backapi_base_url):
        parser.error("BackAPI selection and base URL must be provided together")
    try:
        apply(args)
        return 0
    except (OSError, ValueError, json.JSONDecodeError, tomllib.TOMLDecodeError) as exc:
        print(f"模型配置写入失败：{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
