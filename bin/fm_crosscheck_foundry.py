"""Coordinator-owned configuration for the Azure-billed regular GLM lane."""

import json
import os
from pathlib import Path
import re


def foundry_lanes():
    home = Path(os.environ.get("FM_HOME", str(Path(__file__).resolve().parent.parent)))
    path = home / "config" / "crosscheck-foundry.json"
    if not path.exists():
        return {}
    if path.stat().st_size > 4096:
        raise ValueError("Crosscheck Foundry configuration exceeds 4096 bytes")
    value = json.loads(path.read_text(encoding="utf-8"))
    endpoint = value.get("endpoint", "")
    match = re.fullmatch(r"https://([a-z0-9][a-z0-9-]*\.services\.ai\.azure\.com)/openai/v1", endpoint)
    if set(value) != {"endpoint"} or not match:
        raise ValueError("Crosscheck Foundry endpoint must be one Azure Foundry /openai/v1 endpoint")
    return {"foundry-glm": {
        "slot": "foundry-glm", "model": "crosscheck-glm-5p2",
        "api": "openai-completions",
        "compat": {"supportsStrictMode": True, "sendSessionAffinityHeaders": True, "sessionAffinityFormat": "openai"},
        "cost": {"input": 1.54, "cacheRead": 0.15, "cacheWrite": 1.54, "output": 4.84},
        "host": match.group(1), "base_url": endpoint,
    }}
