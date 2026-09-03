#!/usr/bin/env python3
"""Generate the pre-registration plan for the keyboard-boundary slate.

Seven paired lanes, one pair per model, in the order the repository owner
ratified. Arm order inside a lane is decided by the parity of a hash of the
lane name, the same method the earlier slate used, so no lane's order is a
choice made after seeing an outcome.
"""

import argparse
import hashlib
import json
import pathlib
import sys

ARM_ORDER_SALT = "canonical-guard-keyboard"
SLATE = [
    ("lane-1", "gpt-5.6-luna", "codex", None, "high"),
    ("lane-2", "deepseek-v4-pro-0813", "pi", "qwen-token-plan-individual", "high"),
    ("lane-3", "qwen3.8-max", "pi", "qwen-token-plan-individual", "high"),
    ("lane-4", "deepseek-v4-flash-0731", "pi", "qwen-token-plan-individual", "high"),
    ("lane-5", "gpt-5.6-terra", "codex", None, "high"),
    ("lane-6", "k3", "pi", "kimi-coding", "high"),
    ("lane-7", "gpt-5.6-sol", "codex", None, "high"),
]


def digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def arms_for(lane: str) -> tuple[str, str]:
    guard_on_first = int(digest(f"{ARM_ORDER_SALT}|{lane}"), 16) % 2 == 0
    return ("guard-on", "guard-off") if guard_on_first else ("guard-off", "guard-on")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--prompt", required=True)
    parser.add_argument("--head", required=True, help="the exact pull-request head the templates are built from")
    parser.add_argument("--guard-off-diff", required=True, help="prepare-guard-off.py output, as JSON")
    parser.add_argument("--out", required=True)
    parser.add_argument("--ratified-at", required=True)
    parser.add_argument("--max-load", type=float, default=8.0)
    parser.add_argument("--timeout", type=int, default=1800)
    arguments = parser.parse_args()

    prompt = pathlib.Path(arguments.prompt).resolve()
    prompt_sha = hashlib.sha256(prompt.read_bytes()).hexdigest()
    guard_off = json.loads(pathlib.Path(arguments.guard_off_diff).read_text())

    runs = []
    for lane, model, harness, provider, effort in SLATE:
        for order, arm in enumerate(arms_for(lane), 1):
            runs.append({
                "run_id": "r-" + digest(f"{arguments.head}|{lane}|{arm}")[:16],
                "arm": arm,
                "harness": harness,
                "model": model,
                "provider": provider,
                "effort": effort,
                "helper_family": "both",
                "lane": lane,
                "lane_order": order,
                "concurrent_lane_count": 2,
                "wave": None,
            })

    plan = {
        "ratified_at": arguments.ratified_at,
        "amendment": (
            "Keyboard-boundary slate: seven paired lanes on one ratified task, run in the order "
            "gpt-5.6-luna, deepseek-v4-pro-0813, qwen3.8-max, deepseek-v4-flash-0731, gpt-5.6-terra, k3, gpt-5.6-sol. "
            "The first four are the fast slate; the last three run only if the machine reaches them before the "
            "deterministic evasion pass finishes, and any lane not reached is reported as not-dispatched rather than "
            "as an outcome. Width is two concurrent lanes while the one-minute load average is under 8, runs stay "
            "back-to-back within a lane, the timeout is 1800 seconds, and one-minute load samples are recorded for "
            "every run. The helper-family axis belongs to the earlier duplicate-implementation task and does not "
            "apply here; it is held constant at 'both' across every lane and no result is reported by it."
        ),
        "prompt_sha256": prompt_sha,
        "rule_marker": {"rule_id": "keyboard-listener"},
        "max_load": arguments.max_load,
        "timeout_seconds": arguments.timeout,
        "arm_order_method": f"SHA-256 parity of {ARM_ORDER_SALT}|<lane>: parity 0 runs guard-on first.",
        "load_policy": "Two concurrent lanes admitted while the one-minute load average is under 8; every run records one-minute load samples.",
        "measured_rule": {
            "id": "keyboard-listener",
            "kind": "only-inside",
            "scope": "packages/frontend/src/features/3d-viz-v2",
            "allowed_inside": [
                "packages/frontend/src/features/3d-viz-v2/api/engine",
                "packages/frontend/src/features/3d-viz-v2/api/active-scene-drag.ts",
            ],
            "replacement": "useSceneElementEventListener(target, type, listener, opts)",
            "enforced_at": ["lefthook pre-push", "two blocking CI steps"],
        },
        "templates": {
            "head": arguments.head,
            "guard_on": "the pull-request head, installed, unmodified",
            "guard_off": (
                "the same head with the pre-push command block deleted by the harness, plus the keyboard rule entry "
                "removed from canonical-rules.ts and both blocking CI steps removed, all three hidden from the "
                "candidate's working tree the same way the harness hides the deleted hook block"
            ),
            "guard_off_diff": guard_off["diff"],
            "guard_off_ci_steps_removed": guard_off["ci_steps_removed"],
        },
        "primary_outcome": "the machine verdict of `pnpm check:canonical` replayed on the run's final captured diff",
        "secondary_outcome": "two independent language-model scorers per run, reported as provisional",
        "runs": runs,
    }
    out = pathlib.Path(arguments.out).resolve()
    out.write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"plan": str(out), "runs": len(runs), "prompt_sha256": prompt_sha,
                      "arm_order": {lane: arms_for(lane)[0] for lane, *_ in SLATE}}, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
