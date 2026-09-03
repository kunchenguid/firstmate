#!/usr/bin/env python3
"""Execute the frozen slate: lanes in ratified order, at most `--width` at once.

Both arms of a lane run back-to-back in the frozen lane order, so a lane is the
unit of concurrency and no arm of one lane is ever compared across a different
machine state than its pair. Every launch, exit and wall time is appended to a
dispatch log; a lane that is never reached is recorded as not-dispatched.
"""

import argparse
import datetime
import json
import pathlib
import subprocess
import sys
import threading
import time

BENCH = "scripts/canonical-guard-benchmark/benchmark.py"


def utc_now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")


class Log:
    def __init__(self, path: pathlib.Path) -> None:
        self.path = path
        self.lock = threading.Lock()
        path.parent.mkdir(parents=True, exist_ok=True)

    def append(self, **fields: object) -> None:
        with self.lock:
            with self.path.open("a") as handle:
                handle.write(json.dumps({"at": utc_now(), **fields}, sort_keys=True) + "\n")


def run_one(root: pathlib.Path, workspace: str, prompt: str, item: dict, log: Log, timeout: int) -> int:
    # A run that already produced a manifest is captured; the harness refuses a
    # duplicate run id, so re-entering a partly executed slate must skip it
    # rather than fail the whole lane.
    if (root / workspace / "bundles" / item["run_id"] / "manifest.json").is_file():
        log.append(event="skip", run_id=item["run_id"], lane=item["lane"], arm=item["arm"],
                   model=item["model"], reason="already captured")
        return 0
    command = [
        sys.executable, str(root / BENCH), "run",
        "--workspace", workspace,
        "--run-id", item["run_id"],
        "--arm", item["arm"],
        "--harness", item["harness"],
        "--model", item["model"],
        "--prompt-file", prompt,
        "--helper-family", item["helper_family"],
        "--stage", item.get("stage", "matrix"),
        "--lane", item["lane"],
        "--concurrent-lane-count", str(item["concurrent_lane_count"]),
        "--max-load", str(item["max_load"]),
        "--timeout", str(timeout),
    ]
    if item.get("provider"):
        command += ["--provider", item["provider"]]
    if item.get("effort"):
        command += ["--effort", item["effort"]]
    if item.get("wave") and item.get("stage") == "wave":
        command += ["--wave", item["wave"]]
    log.append(event="launch", run_id=item["run_id"], lane=item["lane"], arm=item["arm"],
               model=item["model"], stage=item.get("stage", "matrix"))
    started = time.monotonic()
    result = subprocess.run(command, cwd=root, text=True, capture_output=True)
    log.append(event="finish", run_id=item["run_id"], lane=item["lane"], arm=item["arm"], model=item["model"],
               exit_code=result.returncode, wall_seconds=round(time.monotonic() - started, 3),
               stdout=result.stdout[-4000:], stderr=result.stderr[-4000:])
    return result.returncode


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, help="the firstmate checkout holding the harness")
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--prompt", required=True)
    parser.add_argument("--plan", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--width", type=int, default=2)
    parser.add_argument("--lanes", help="comma-separated lane subset, in ratified order")
    arguments = parser.parse_args()

    root = pathlib.Path(arguments.root).resolve()
    plan = json.loads(pathlib.Path(arguments.plan).read_text())
    log = Log(pathlib.Path(arguments.log).resolve())

    lanes: dict[str, list[dict]] = {}
    for item in plan["runs"]:
        lanes.setdefault(item["lane"], []).append(dict(item, max_load=plan["max_load"]))
    order: list[str] = []
    for item in plan["runs"]:
        if item["lane"] not in order:
            order.append(item["lane"])
    if arguments.lanes:
        wanted = [lane.strip() for lane in arguments.lanes.split(",") if lane.strip()]
        order = [lane for lane in order if lane in wanted]
    for lane in lanes:
        lanes[lane].sort(key=lambda item: item["lane_order"])

    log.append(event="dispatch-start", lanes=order, width=arguments.width,
               plan_sha_runs=len(plan["runs"]), timeout_seconds=plan["timeout_seconds"])

    results: dict[str, list[int]] = {}
    pending = list(order)
    active: list[tuple[str, threading.Thread]] = []

    def drive(lane: str) -> None:
        codes = []
        for item in lanes[lane]:
            codes.append(run_one(root, arguments.workspace, arguments.prompt, item, log, plan["timeout_seconds"]))
        results[lane] = codes

    while pending or active:
        while pending and len(active) < arguments.width:
            lane = pending.pop(0)
            thread = threading.Thread(target=drive, args=(lane,))
            thread.start()
            active.append((lane, thread))
        time.sleep(2)
        for lane, thread in list(active):
            if not thread.is_alive():
                thread.join()
                active.remove((lane, thread))

    not_dispatched = [lane for lane in sorted(lanes) if lane not in results]
    log.append(event="dispatch-end", executed=sorted(results), not_dispatched=not_dispatched)
    print(json.dumps({"executed": {lane: results[lane] for lane in sorted(results)},
                      "not_dispatched": not_dispatched, "log": arguments.log}, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
