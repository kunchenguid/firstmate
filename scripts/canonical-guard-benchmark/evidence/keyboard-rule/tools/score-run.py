#!/usr/bin/env python3
"""Machine-score one captured run with the harness's own pinned detector.

`benchmark.py score` refuses until every frozen matrix run has a manifest. Six
of this slate's fourteen runs can never have one - their provider's quota is
exhausted until after this study - so that completeness gate can never be
satisfied here. This tool does not re-implement the scorer: it imports the
harness and calls the same reconstruction, the same pinned detector, the same
remediation recovery and the same verdict normaliser, then writes a verdict
object for `benchmark.py record-verdict`, which is the harness's own path for an
externally adjudicated verdict and has no completeness gate.
"""

import argparse
import importlib.util
import json
import os
import pathlib
import shutil
import sys


def load_harness(root: pathlib.Path):
    spec = importlib.util.spec_from_file_location(
        "benchmark", root / "scripts/canonical-guard-benchmark/benchmark.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--semantic-file", required=True)
    parser.add_argument("--out", required=True)
    arguments = parser.parse_args()

    root = pathlib.Path(arguments.root).resolve()
    harness = load_harness(root)
    workspace = pathlib.Path(arguments.workspace).resolve()
    manifest_by_id = {item["run_id"]: item for item in harness.manifests(workspace)}
    if arguments.run_id not in manifest_by_id:
        raise SystemExit(f"unknown run: {arguments.run_id}")
    manifest = manifest_by_id[arguments.run_id]

    semantic = json.loads(pathlib.Path(arguments.semantic_file).read_text())
    scorers = semantic.get("scorers")
    semantic_verdict = harness.validate_scorers(scorers)

    config = harness.read_json(workspace / "workspace.json")
    if manifest["detector_sha"] != config.get("detector_sha"):
        raise SystemExit("manifest detector_sha differs from the initialized pinned detector")
    template = pathlib.Path(config["templates"]["guard-on"]["path"])

    def score_patch(patch: pathlib.Path, suffix: str):
        scratch = workspace / f".score-{arguments.run_id}-{suffix}-{os.getpid()}"
        harness.cow_copy(template, scratch)
        try:
            harness.apply_captured_patch(scratch, patch)
            return harness.pinned_detector_run(scratch, template, manifest["base_sha"], manifest["detector_sha"])
        finally:
            shutil.rmtree(scratch, ignore_errors=True)

    bundle = workspace / "bundles" / arguments.run_id
    machine_result = score_patch(bundle / "final.diff", "final")
    historical = []
    for index, relative in enumerate(manifest["git"].get("history_diffs", []), 1):
        historical.append(score_patch(bundle / relative, f"history-{index}").returncode != 0)
    marker = harness.workspace_rule_marker(workspace)
    machine = harness.machine_verdict(machine_result, marker, arguments.run_id)
    remediations = harness.captured_gate_remediations(bundle, manifest, marker)
    firing_count = max(manifest["gate"]["firing_count"], len(remediations))
    fired = firing_count > 0
    shipped = machine == "duplicate" or semantic_verdict == "duplicate"
    outcome = ("reached-review" if shipped else
               "caught-early" if fired else
               "self-corrected" if any(historical) else
               "never-duplicated")
    value = {
        "run_id": arguments.run_id,
        "machine": machine,
        "semantic": semantic_verdict,
        "outcome_class": outcome,
        "false_fire": fired and semantic_verdict == "clean" and machine == "clean" and not any(historical),
        "ack": bool(manifest["git"]["trailers"]),
        "gate_firing_count": firing_count,
        "gate_evidence_source": "post-hoc derivation from immutable transcript and terminal captures",
        "remediation_text_exact": remediations,
        "fix_matches_remediation": next(
            (firing.get("fix_matches_remediation") for firing in reversed(manifest["gate"].get("firings", []))
             if isinstance(firing.get("fix_matches_remediation"), bool)), None),
        "review_rounds": None,
        "scorers": scorers,
        "machine_evidence": {"exit_code": machine_result.returncode, "stdout": machine_result.stdout,
                             "stderr": machine_result.stderr, "historical_duplicates": historical},
    }
    harness.normalize_verdict(dict(value), manifest_by_id)
    out = pathlib.Path(arguments.out).resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"run_id": arguments.run_id, "machine": machine, "semantic": semantic_verdict,
                      "outcome_class": outcome, "verdict_file": str(out)}, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
