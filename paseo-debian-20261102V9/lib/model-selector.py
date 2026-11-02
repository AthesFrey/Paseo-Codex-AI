#!/usr/bin/env python3
"""Read model IDs from the deployment terminal without contacting a provider."""
from __future__ import annotations

import argparse
import json
import re
import sys
from typing import TextIO


class ModelSelectionError(RuntimeError):
    """A safe, user-facing model input error."""


class InputClosedError(ModelSelectionError):
    """The interactive terminal closed before a model was entered."""


def _read_line(input_stream: TextIO, output_stream: TextIO, prompt: str) -> str:
    output_stream.write(prompt)
    output_stream.flush()
    line = input_stream.readline()
    if line == "":
        raise InputClosedError("无法从当前终端读取模型名称。")
    return line.rstrip("\r\n")


def parse_model_ids(value: str) -> list[str]:
    """Parse comma- or whitespace-separated IDs and preserve input order."""
    value = value.strip()
    if not value:
        raise ModelSelectionError("至少输入一个模型名称。")
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise ModelSelectionError("模型名称不能包含空白控制字符。")

    ids = [token for token in re.split(r"[\s,]+", value) if token]
    if not ids:
        raise ModelSelectionError("至少输入一个模型名称。")

    seen: set[str] = set()
    for model_id in ids:
        if model_id in seen:
            raise ModelSelectionError(f"模型名称重复：{model_id}。")
        seen.add(model_id)
    return ids


def read_model_selection(
    provider_label: str,
    input_stream: TextIO,
    output_stream: TextIO,
) -> dict[str, object]:
    """Read one provider's IDs; the first ID is its default model."""
    while True:
        try:
            ids = parse_model_ids(
                _read_line(
                    input_stream,
                    output_stream,
                    f"输入{provider_label}模型名称（多个用逗号或空格分隔，第一个为默认）： ",
                )
            )
            break
        except InputClosedError:
            raise
        except ModelSelectionError as exc:
            output_stream.write(f"输入无效：{exc}\n")
            output_stream.flush()

    return {
        "models": [{"id": model_id} for model_id in ids],
        "default": ids[0],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--label", required=True)
    args = parser.parse_args()

    try:
        with open("/dev/tty", "r", encoding="utf-8") as tty_in, open(
            "/dev/tty", "w", encoding="utf-8"
        ) as tty_out:
            selection = read_model_selection(args.label, tty_in, tty_out)
        json.dump(selection, sys.stdout, ensure_ascii=False, separators=(",", ":"))
        sys.stdout.write("\n")
        return 0
    except (OSError, UnicodeError, ModelSelectionError) as exc:
        print(f"模型选择失败：{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
