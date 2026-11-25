#!/usr/bin/env python3
"""Apply manually entered Codex and Claude model IDs to Paseo."""
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


def model_entries(selection: dict, provider_label: str, codex: bool = False) -> list[dict]:
    entries = []
    for item in selection["models"]:
        model_id = item["id"]
        entry = {
            "id": model_id,
            "label": f"{model_id} ({provider_label})",
            "isDefault": model_id == selection["default"],
        }
        if codex:
            entry["thinkingOptions"] = [dict(option) for option in THINKING_OPTIONS]
        entries.append(entry)
    if sum(bool(item["isDefault"]) for item in entries) != 1:
        raise ValueError(f"{provider_label} 必须恰好有一个默认模型。")
    return entries


def atomic_write(path: Path, content: str, reference: Path | None = None) -> None:
    original = (reference or path).stat()
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
    claude_selection = load_selection(args.claude_selection)
    config_path = args.paseo_config
    config = json.loads(config_path.read_text(encoding="utf-8"))
    providers = config.setdefault("agents", {}).setdefault("providers", {})
    providers["codex"]["enabled"] = True
    providers["codex"]["models"] = model_entries(main_selection, "HahaAPI", codex=True)
    providers["claude"]["enabled"] = True
    providers["claude"]["env"] = {"ANTHROPIC_BASE_URL": args.claude_base_url}
    providers["claude"]["models"] = model_entries(claude_selection, "Claude")
    config["agents"]["metadataGeneration"]["providers"] = [
        {
            "provider": "codex",
            "model": main_selection["default"],
            "thinkingOptionId": "high",
        }
    ]

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

    # Validate every generated document before replacing any live config.
    updated_json = json.dumps(config, ensure_ascii=False, indent=2) + "\n"
    json.loads(updated_json)
    atomic_write(toml_path, updated_toml)
    atomic_write(config_path, updated_json)

    print(
        f"MODEL_CONFIG_OK：主 API {len(main_selection['models'])} 个模型"
        f"（默认 {main_selection['default']}）。"
    )
    print(
        f"CLAUDE_CONFIG_OK：Claude {len(claude_selection['models'])} 个模型"
        f"（默认 {claude_selection['default']}）。"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--paseo-config", required=True, type=Path)
    parser.add_argument("--codex-config", required=True, type=Path)
    parser.add_argument("--main-selection", required=True, type=Path)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--claude-selection", required=True, type=Path)
    parser.add_argument("--claude-base-url", required=True)
    args = parser.parse_args()
    try:
        apply(args)
        return 0
    except (OSError, ValueError, json.JSONDecodeError, tomllib.TOMLDecodeError) as exc:
        print(f"模型配置写入失败：{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
