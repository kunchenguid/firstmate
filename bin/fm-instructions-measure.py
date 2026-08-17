#!/usr/bin/env python3
"""Measure Firstmate progressive-disclosure prompt and reachable-corpus costs.

Run reproducibly with:
  uv run --python 3.13 --with tiktoken==0.11.0 bin/fm-instructions-measure.py \
    --output docs/verification/prompt-disclosure-measurements.json
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import statistics
import subprocess
import tempfile
import time
from collections.abc import Iterable
from datetime import date
from pathlib import Path

tiktoken = None
ENCODINGS = ("o200k_base", "cl100k_base")
WORD_RE = re.compile(r"\S+")


def read_git(root: Path, revision: str, path: str) -> str:
    return subprocess.check_output(
        ["git", "show", f"{revision}:{path}"], cwd=root
    ).decode("utf-8")


def stats(parts: Iterable[str]) -> dict[str, int]:
    values = list(parts)
    result = {
        "physical_lines": sum(len(value.splitlines()) for value in values),
        "nonblank_lines": sum(
            sum(bool(line.strip()) for line in value.splitlines()) for value in values
        ),
        "words": sum(len(WORD_RE.findall(value)) for value in values),
        "utf8_bytes": sum(len(value.encode("utf-8")) for value in values),
    }
    for encoding_name in ENCODINGS:
        encoding = tiktoken.get_encoding(encoding_name)
        result[f"tokens_{encoding_name}"] = sum(
            len(encoding.encode(value)) for value in values
        )
    return result


def skill_catalog_entry(text: str) -> str:
    front = text.split("---", 2)[1].splitlines()
    name = next(line.split(":", 1)[1].strip() for line in front if line.startswith("name:"))
    index = next(i for i, line in enumerate(front) if line.startswith("description:"))
    first = front[index].split(":", 1)[1].strip()
    values = [] if first in {">-", ">", "|-", "|"} else [first]
    for line in front[index + 1 :]:
        if line.startswith(" "):
            values.append(line.strip())
        else:
            break
    return f"{name}\t{' '.join(values)}\n"


def comparison(before: dict[str, int], after: dict[str, int]) -> dict[str, dict]:
    result = {}
    for metric, before_value in before.items():
        after_value = after[metric]
        delta = after_value - before_value
        result[metric] = {
            "before": before_value,
            "after": after_value,
            "delta": delta,
            "percent_delta": round(delta / before_value * 100, 3),
        }
    return result


def generated_briefs(root: Path) -> list[str]:
    with tempfile.TemporaryDirectory(prefix="fm-instructions-measure.") as temp:
        home = Path(temp)
        (home / "data").mkdir()
        (home / "state").mkdir()
        env = {
            **os.environ,
            "FM_HOME": str(home),
            "FM_ROOT_OVERRIDE": "/FIRSTMATE_MEASUREMENT_ROOT",
        }
        commands = [
            (["measure-ship", "firstmate", "--mode", "direct-PR"], {}),
            (["measure-scout", "firstmate", "--scout"], {}),
            (
                ["measure-secondmate", "--secondmate", "--no-projects"],
                {
                    "FM_SECONDMATE_CHARTER": "Measurement charter.",
                    "FM_SECONDMATE_SCOPE": "Measurement scope.",
                },
            ),
        ]
        outputs = []
        for arguments, extra_env in commands:
            subprocess.run(
                [str(root / "bin/fm-brief.sh"), *arguments],
                cwd=root,
                env={**env, **extra_env},
                check=True,
                stdout=subprocess.DEVNULL,
            )
            output = (home / "data" / arguments[0] / "brief.md").read_text(
                encoding="utf-8"
            )
            outputs.append(output.replace(str(home), "/FIRSTMATE_MEASUREMENT_HOME"))
        return outputs


def timed_disclosure(root: Path, bundle: str, runs: int) -> dict:
    durations = []
    output = b""
    for _ in range(runs):
        started = time.perf_counter_ns()
        output = subprocess.check_output([str(root / "bin/fm-instructions.sh"), bundle])
        durations.append((time.perf_counter_ns() - started) / 1_000_000)
    return {
        "tool_calls_required": 1,
        "local_process_invocations_visible_to_caller": 1,
        "output_utf8_bytes": len(output),
        "timing_runs": runs,
        "median_local_wall_ms": round(statistics.median(durations), 3),
        "min_local_wall_ms": round(min(durations), 3),
        "max_local_wall_ms": round(max(durations), 3),
        "limitation": "Local process time excludes model/tool orchestration latency.",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--timing-runs", type=int, default=20)
    args = parser.parse_args()
    if args.timing_runs < 1:
        parser.error("--timing-runs must be at least 1")
    global tiktoken
    try:
        import tiktoken as tokenizer_library
    except ImportError as error:
        raise SystemExit(
            "tiktoken is required; run with "
            "`uv run --python 3.13 --with tiktoken==0.11.0`"
        ) from error
    tiktoken = tokenizer_library
    root = args.root.resolve()
    manifest = json.loads(
        (root / "docs/verification/prompt-disclosure-manifest.json").read_text(
            encoding="utf-8"
        )
    )
    lineage = json.loads((root / "docs/verification/prompt-lineage.json").read_text(encoding="utf-8"))
    baseline = manifest["baseline_git_commit"]
    comparison_baseline = next(
        item["commit"] for item in lineage["generations"] if item.get("kind") == "upstream-semantics"
    )
    baseline_agents = read_git(root, comparison_baseline, manifest["baseline_path"])
    current_agents = (root / "AGENTS.md").read_text(encoding="utf-8")
    bundles = list(dict.fromkeys(entry["bundle"] for entry in manifest["entries"]))
    bundle_text = {
        name: (root / next(
            entry["destination_path"]
            for entry in manifest["entries"]
            if entry["bundle"] == name
        )).read_text(encoding="utf-8")
        for name in bundles
    }
    skill_paths = sorted(str(path.relative_to(root)) for path in (root / ".agents/skills").glob("*/SKILL.md"))
    current_skills = [(root / path).read_text(encoding="utf-8") for path in skill_paths]
    baseline_skills = [read_git(root, comparison_baseline, path) for path in skill_paths]
    baseline_skill_catalog = [skill_catalog_entry(text) for text in baseline_skills]
    current_skill_catalog = [skill_catalog_entry(text) for text in current_skills]
    supervision_parts = [
        path.read_text(encoding="utf-8")
        for path in sorted((root / "docs/supervision-protocols").glob("*.md"))
    ]
    briefs = generated_briefs(root)
    baseline_common_parts = [*baseline_skills, *supervision_parts, *briefs]
    current_common_parts = [*current_skills, *supervision_parts, *briefs]
    per_bundle = {}
    for bundle in bundles:
        entries = [entry for entry in manifest["entries"] if entry["bundle"] == bundle]
        exact = "\n".join(entry["exact_text"] for entry in entries) + "\n"
        per_bundle[bundle] = {
            "source_lines": f"AGENTS.md:{entries[0]['baseline_line']}-{entries[-1]['baseline_line']}",
            "destination": entries[0]["destination_path"],
            "deferred_exact_baseline_volume": stats([exact]),
            "trigger_disclosure_cost": stats([bundle_text[bundle]]),
            "runtime_overhead": timed_disclosure(root, bundle, args.timing_runs),
        }
    data = {
        "schema_version": 1,
        "measurement_date": date.today().isoformat(),
        "baseline_git_commit": baseline,
        "comparison_baseline_commit": comparison_baseline,
        "python_version": platform.python_version(),
        "selected_environment": {
            "provider": os.environ.get("PI_PROVIDER"),
            "model": os.environ.get("PI_MODEL"),
            "reasoning_level": os.environ.get("PI_REASONING_LEVEL"),
        },
        "tokenizer": {
            "library": "tiktoken",
            "version": tiktoken.__version__,
            "encodings": list(ENCODINGS),
            "exact_model_mapping": None,
            "limitation": (
                "The selected provider-specific model has no tiktoken mapping; "
                "o200k_base is an OpenAI-family approximation and cl100k_base is a cross-check."
            ),
        },
        "definitions": {
            "physical_lines": "Python str.splitlines() count.",
            "nonblank_lines": "Physical lines containing non-whitespace.",
            "words": "Unicode regular-expression \\S+ spans.",
            "utf8_bytes": "Length after UTF-8 encoding.",
            "corpus_tokens": "Each included surface encoded independently, then summed.",
            "generated_path_normalization": (
                "Volatile generated-brief home and root paths are replaced with fixed placeholders."
            ),
        },
        "initially_loaded_primary": {
            "included_surfaces": ["AGENTS.md", "compact skill names and descriptions are measured separately below"],
            "comparison": comparison(stats([baseline_agents]), stats([current_agents])),
        },
        "compact_skill_catalog": comparison(stats(baseline_skill_catalog), stats(current_skill_catalog)),
        "total_directly_reachable_instruction_corpus": {
            "included_surfaces": [
                "AGENTS.md",
                ".agents/skills/*/SKILL.md",
                "docs/supervision-protocols/*.md",
                "canonical generated ship/scout/secondmate briefs",
                "FIRSTMATE_*.md deferred bundles after disclosure",
            ],
            "excluded_surfaces": [
                "vendor prompts",
                "dynamic private startup data",
                "general maintainer documentation",
                "script implementation source",
                "project-specific context outside Firstmate",
            ],
            "comparison": comparison(
                stats([baseline_agents, *baseline_common_parts]),
                stats([current_agents, *current_common_parts, *bundle_text.values()]),
            ),
        },
        "disclosed_common_paths": {
            "status_only": stats([current_agents]),
            "ordinary_intake": stats([current_agents, *(bundle_text[name] for name in ("task-lifecycle", "backlog", "briefing", "dispatch"))]),
            "recovery": stats([current_agents, bundle_text["recovery"], bundle_text["operational-home"]]),
            "merge_or_cleanup": stats([current_agents, bundle_text["task-lifecycle"]]),
        },
        "generated_artifacts": {
            "canonical_briefs": stats(briefs),
            "classification": "Generated outputs are measured separately and are not counted as initially loaded unless their role is launched.",
        },
        "deferred_bundles": per_bundle,
        "assumptions_and_unmeasured": [
            "No provider cache-read, cache-write, billing, or latency evidence was measured.",
            "Tokenizer counts approximate prompt volume and do not predict model interpretation.",
            "Dynamic startup data, vendor base prompts, and tool schemas are excluded.",
        ],
        "reproduction_command": (
            "uv run --python 3.13 --with tiktoken==0.11.0 bin/fm-instructions-measure.py "
            "--output docs/verification/prompt-disclosure-measurements.json"
        ),
    }
    rendered = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    if args.output:
        output = args.output if args.output.is_absolute() else root / args.output
        output.write_text(rendered, encoding="utf-8")
    print(rendered, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
