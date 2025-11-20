#!/usr/bin/env python3
"""
Generate a Solidity standard-json input for BurnMintTokenPool with:
  - full source contents (including remapping aliases)
  - original compiler settings, except removing unsupported keys

Output: tmp/BurnMintTokenPool.standard.cleaned.json
"""

from __future__ import annotations

import ast
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ARTIFACT = ROOT / "out" / "BurnMintTokenPool.sol" / "BurnMintTokenPool.json"
FOUNDRY_TOML = ROOT / "foundry.toml"
OUTPUT = ROOT / "tmp" / "BurnMintTokenPool.standard.cleaned.json"


def load_artifact() -> dict:
    data = json.loads(ARTIFACT.read_text())
    metadata = data["metadata"]
    if isinstance(metadata, str):
        metadata = json.loads(metadata)
    return metadata


def read_sources(metadata: dict) -> dict[str, str]:
    sources: dict[str, str] = {}
    for path in metadata["sources"].keys():
        file_path = ROOT / path
        if not file_path.exists():
            raise FileNotFoundError(f"Source file missing on disk: {path}")
        sources[path] = file_path.read_text()
    return sources


def parse_remappings() -> list[tuple[str, str]]:
    text = FOUNDRY_TOML.read_text()
    match = re.search(r"remappings\s*=\s*\[(.*?)\]", text, re.S)
    if not match:
        return []

    raw_block = match.group(1)
    entries: list[str] = []
    for line in raw_block.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        # ensure trailing comma removed; ast.literal_eval expects valid list syntax
        if line.endswith(","):
            line = line[:-1]
        entries.append(line)

    if not entries:
        return []

    literal = "[" + ",".join(entries) + "]"
    remappings = ast.literal_eval(literal)

    result: list[tuple[str, str]] = []
    for item in remappings:
        alias, target = item.split("=", 1)
        result.append((alias, target))
    return result


def expand_alias_sources(sources: dict[str, str], remaps: list[tuple[str, str]]) -> dict[str, str]:
    expanded = dict(sources)
    for alias, target in remaps:
        for path, content in sources.items():
            if path.startswith(target):
                candidate = alias + path[len(target) :]
                if candidate not in expanded:
                    expanded[candidate] = content
    return expanded


def sanitize_settings(settings: dict) -> dict:
    settings = json.loads(json.dumps(settings))  # deep copy via serialization
    settings.pop("compilationTarget", None)
    return settings


def main() -> None:
    metadata = load_artifact()
    sources = read_sources(metadata)
    remaps = parse_remappings()
    all_sources = expand_alias_sources(sources, remaps)
    settings = sanitize_settings(metadata["settings"])

    standard = {
        "language": metadata["language"],
        "sources": {path: {"content": content} for path, content in all_sources.items()},
        "settings": settings,
    }

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(standard, ensure_ascii=False, indent=2))
    print(f"Standard JSON written to {OUTPUT}")


if __name__ == "__main__":
    main()
