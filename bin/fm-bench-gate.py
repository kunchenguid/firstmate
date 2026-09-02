#!/usr/bin/env python3
"""fm-bench-gate.py - the single owner of the model-routing benchmark's launch,
evidence, and cleanup gates.

Invoked through bin/fm-bench-gate.sh, whose header owns the operator-facing
summary. This module owns every check, every schema key, and every exit code.

Each gate enforces one item of the adversarial review's correction set by
executing a check against recorded evidence, never by trusting a declared
verdict: hashes are recomputed, counts are recomputed from the plan, isolation
probes are actually run, and archive bundles are actually restored.

Output is line-oriented and deterministic:

    BENCH_CHECK <check-id> <ok|fail|stop> <detail>
    BENCH_RESULT <subcommand> <ok|refused|captain-stop> checks=<n> failed=<n>

Exit codes: 0 pass, 1 refused, 2 usage error, 3 captain-stop (a new fact the
captain must rule on, never resolvable by substitution or budget expansion).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

PLAN_SCHEMA = "fm-bench-plan.v1"
PROVENANCE_SCHEMA = "fm-bench-provenance.v1"
ISOLATION_SCHEMA = "fm-bench-isolation.v1"
ALLOWANCE_SCHEMA = "fm-bench-allowance.v1"
RESULT_SCHEMA = "fm-bench-result.v1"
ARCHIVE_SCHEMA = "fm-bench-archive.v1"
MANIFEST_SCHEMA = "fm-bench-manifest.v1"
FREEZE_SCHEMA = "fm-bench-freeze.v1"
RECEIPT_SCHEMA = "fm-bench-preflight-receipt.v1"
DRILL_SCHEMA = "fm-bench-restore-drill.v1"

EXIT_OK = 0
EXIT_REFUSED = 1
EXIT_USAGE = 2
EXIT_CAPTAIN_STOP = 3

# A provenance field carrying any of these is an absence, not an identification.
# "No record found" fails the contamination check; it never clears it.
ABSENT_TOKENS = {
    "",
    "-",
    "n/a",
    "na",
    "none",
    "null",
    "unknown",
    "unavailable",
    "not recorded",
    "no record",
    "no record found",
    "tbd",
    "todo",
    "unspecified",
}

# Cost and elapsed time stay descriptive until both are centrally measured for
# every candidate, so neither may appear in the tie rule.
FORBIDDEN_TIE_TOKENS = ("cost", "price", "usd", "spend", "time", "latency", "elapsed", "duration")

REQUIRED_FAILURE_POLICY = {
    "candidate_caused": "score_zero",
    "evaluator_infrastructure": "void_and_rerun",
    "provider_outage": "void_and_rerun",
    "quota_exhaustion": "void_and_rerun",
    "sibling_access": "blocker_class",
}

REQUIRED_TIMING_INTERVALS = (
    "dispatch_accepted_to_first_valid_final_commit",
    "first_assistant_event_to_first_valid_final_commit",
)

REQUIRED_EVALUATOR_LOCK_KEYS = (
    "browser",
    "browser_version",
    "playwright_version",
    "fonts",
    "locale",
    "timezone",
    "rendering_flags",
    "viewports",
    "fixtures",
    "network_mock",
    "animations",
    "color_scheme",
    "readiness_predicate",
    "device_scale_factor",
    "zoom_intervention",
)

# Producing mandatory evidence is a validity condition, not candidate quality,
# so each of these dimensions must carry zero score weight.
VALIDITY_GATE_DIMENSIONS = ("screenshot_completeness", "evaluator_success", "tree_binding")

REQUIRED_SCORE_MAP_KEYS = (
    "pixel_mismatch_to_points",
    "region_masks",
    "anti_alias_tolerance",
    "axe_severity_to_points",
    "test_result_to_points",
    "infrastructure_failure_treatment",
)

REQUIRED_ARCHIVE_GROUPS = (
    "packet_and_ground_truth",
    "candidate_bundle_and_projection",
    "tree_binding",
    "transcript",
    "capture_and_scoring",
    "judging",
    "timing_cost_quota",
    "key_and_verdict",
)

PRIVATE_STORAGE_KEYS = (
    "private_object_store",
    "private_tmp",
    "private_home",
    "private_session",
)

ISOLATION_PROBES = (
    "sibling_file_read",
    "sibling_worktree_enumeration",
    "sibling_object_enumeration",
    "sibling_unreachable_objects",
    "process_inspection",
    "environment_leakage",
    "protected_path_read",
)


class GateError(Exception):
    """A usage-level failure: the gate could not be evaluated at all."""


class Report:
    """Deterministic accumulator for one subcommand's checks."""

    def __init__(self, subcommand: str, quiet: bool = False) -> None:
        self.subcommand = subcommand
        self.quiet = quiet
        self.total = 0
        self.failed = 0
        self.captain_stop = False

    def _emit(self, check: str, status: str, detail: str) -> None:
        if not self.quiet:
            print(f"BENCH_CHECK {check} {status} {detail}")

    def ok(self, check: str, detail: str) -> None:
        self.total += 1
        self._emit(check, "ok", detail)

    def fail(self, check: str, detail: str) -> None:
        self.total += 1
        self.failed += 1
        self._emit(check, "fail", detail)

    def stop(self, check: str, detail: str) -> None:
        self.total += 1
        self.failed += 1
        self.captain_stop = True
        self._emit(check, "stop", detail)

    def require(self, condition: bool, check: str, ok_detail: str, fail_detail: str) -> bool:
        if condition:
            self.ok(check, ok_detail)
            return True
        self.fail(check, fail_detail)
        return False

    def finish(self) -> int:
        if self.captain_stop:
            verdict, code = "captain-stop", EXIT_CAPTAIN_STOP
        elif self.failed:
            verdict, code = "refused", EXIT_REFUSED
        else:
            verdict, code = "ok", EXIT_OK
        print(f"BENCH_RESULT {self.subcommand} {verdict} checks={self.total} failed={self.failed}")
        return code


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: Path, schema: str | None = None) -> dict[str, Any]:
    if not path.is_file():
        raise GateError(f"missing required file: {path}")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise GateError(f"unreadable JSON at {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise GateError(f"{path} must contain a JSON object")
    if schema is not None and data.get("schema") != schema:
        raise GateError(f"{path} has schema {data.get('schema')!r}, expected {schema!r}")
    return data


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def is_absent(value: Any) -> bool:
    if value is None:
        return True
    if not isinstance(value, str):
        return False
    return value.strip().lower() in ABSENT_TOKENS


def nonempty_str(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip()) and not is_absent(value)


# --------------------------------------------------------------------------
# Plan: corrections 1, 2, 3, 9 (distinct packets, sweep rule, neutral panels,
# frozen policy) plus the captain's fixed disposition and isolation choices.
# --------------------------------------------------------------------------


def track_candidates(track: dict[str, Any]) -> list[dict[str, Any]]:
    """Every scored output producer in a track: entrants plus any baseline."""
    candidates = list(track.get("entrants") or [])
    baseline = track.get("baseline")
    if isinstance(baseline, dict):
        candidates.append(baseline)
    return candidates


def track_families(track: dict[str, Any]) -> set[str]:
    return {
        str(candidate.get("family", "")).strip().lower()
        for candidate in track_candidates(track)
        if nonempty_str(candidate.get("family"))
    }


def check_plan(plan: dict[str, Any], report: Report) -> None:
    samples = plan.get("samples_per_entrant")
    baseline_samples = plan.get("samples_per_baseline")

    report.require(
        plan.get("isolation_mode") == "enforced",
        "plan.isolation_mode",
        "enforced per-entrant isolation selected",
        f"isolation_mode must be 'enforced', got {plan.get('isolation_mode')!r}",
    )
    report.require(
        plan.get("candidate_disposition") == "archive-then-discard" and plan.get("direct_ship") is False,
        "plan.disposition",
        "every candidate is archived then discarded; no direct shipping",
        "candidate_disposition must be 'archive-then-discard' with direct_ship false",
    )
    report.require(
        samples == 6,
        "plan.samples_per_entrant",
        "six samples per entrant",
        f"samples_per_entrant must be 6, got {samples!r}",
    )
    report.require(
        baseline_samples == 3,
        "plan.samples_per_baseline",
        "three baseline samples",
        f"samples_per_baseline must be 3, got {baseline_samples!r}",
    )
    report.require(
        plan.get("adaptive_extension") is False,
        "plan.adaptive_extension",
        "no adaptive ninth sample",
        "adaptive_extension must be false; an inconclusive six-sample result is 'no standing route'",
    )
    report.require(
        nonempty_str(plan.get("randomisation_seed")),
        "plan.randomisation_seed",
        "packet order seed preregistered",
        "randomisation_seed must be a recorded non-empty value",
    )
    approved = plan.get("approved_cost_class_usd")
    report.require(
        isinstance(approved, (int, float)) and not isinstance(approved, bool) and approved > 0,
        "plan.approved_cost_class_usd",
        f"approved cost class {approved}",
        "approved_cost_class_usd must be a positive number",
    )

    winner_rule = plan.get("sample_winner_rule")
    if isinstance(winner_rule, dict):
        missing = [key for key in ("definition", "ties", "voids", "missing") if not nonempty_str(winner_rule.get(key))]
        report.require(
            not missing,
            "plan.sample_winner_rule",
            "sample winner, tie, void, and missing handling preregistered",
            f"sample_winner_rule is missing: {', '.join(missing)}",
        )
    else:
        report.fail("plan.sample_winner_rule", "sample_winner_rule must be an object")

    check_promotion_rule(plan, report)
    check_failure_policy(plan, report)
    check_timing_policy(plan, report)

    tracks = plan.get("tracks")
    if not isinstance(tracks, dict) or not tracks:
        report.fail("plan.tracks", "tracks must be a non-empty object")
        return
    for name in sorted(tracks):
        track = tracks[name]
        if not isinstance(track, dict):
            report.fail(f"plan.track.{name}", "track must be an object")
            continue
        check_track(name, track, plan, report)


def check_promotion_rule(plan: dict[str, Any], report: Report) -> None:
    rule = plan.get("promotion_rule")
    if not isinstance(rule, dict):
        report.fail("plan.promotion_rule", "promotion_rule must be an object")
        return
    samples = plan.get("samples_per_entrant")
    report.require(
        rule.get("type") == "paired-sweep",
        "promotion.type",
        "paired directional sweep rule",
        f"promotion_rule.type must be 'paired-sweep', got {rule.get('type')!r}",
    )
    report.require(
        rule.get("required_wins") == samples and rule.get("of_samples") == samples,
        "promotion.sweep",
        f"a standing route needs {samples}/{samples}",
        "required_wins and of_samples must both equal samples_per_entrant; 5/6 and 4/6+margin are refused",
    )
    margin = rule.get("practical_margin")
    report.require(
        isinstance(margin, (int, float)) and not isinstance(margin, bool) and margin > 0,
        "promotion.practical_margin",
        f"predeclared practical margin {margin}",
        "promotion_rule.practical_margin must be a positive predeclared number",
    )
    report.require(
        rule.get("allow_blocker_class_failure") is False,
        "promotion.blocker_class",
        "no blocker-class failure may promote",
        "promotion_rule.allow_blocker_class_failure must be false",
    )
    report.require(
        rule.get("baseline_role") == "regression_veto",
        "promotion.baseline_role",
        "baseline is a non-competing regression veto",
        f"baseline_role must be 'regression_veto', got {rule.get('baseline_role')!r}",
    )
    veto = rule.get("baseline_veto")
    if isinstance(veto, dict):
        delta = veto.get("max_negative_mean_quality_delta")
        losses = veto.get("max_losses_of_three")
        report.require(
            isinstance(delta, (int, float))
            and not isinstance(delta, bool)
            and delta <= 0
            and losses == 1,
            "promotion.baseline_veto",
            "baseline veto bounds recorded",
            "baseline_veto needs max_negative_mean_quality_delta <= 0 and max_losses_of_three == 1",
        )
    else:
        report.fail("promotion.baseline_veto", "baseline_veto must be an object")

    breakers = rule.get("tie_breakers")
    if isinstance(breakers, list) and breakers:
        offending = [
            str(item)
            for item in breakers
            if any(token in str(item).lower() for token in FORBIDDEN_TIE_TOKENS)
        ]
        report.require(
            not offending,
            "promotion.tie_breakers",
            "tie rule carries no unmeasured cost or time input",
            f"tie_breakers may not use cost or elapsed time: {', '.join(offending)}",
        )
    else:
        report.fail("promotion.tie_breakers", "tie_breakers must be a non-empty list")

    stray = sorted(key for key in rule if "extension" in key.lower() or "adaptive" in key.lower())
    report.require(
        not stray,
        "promotion.no_extension",
        "no optional-stopping extension in the promotion rule",
        f"promotion_rule carries optional-stopping keys: {', '.join(stray)}",
    )


def check_failure_policy(plan: dict[str, Any], report: Report) -> None:
    policy = plan.get("failure_policy")
    if not isinstance(policy, dict):
        report.fail("plan.failure_policy", "failure_policy must be an object")
        return
    wrong = [
        f"{cls}={policy.get(cls)!r} (want {want!r})"
        for cls, want in sorted(REQUIRED_FAILURE_POLICY.items())
        if policy.get(cls) != want
    ]
    report.require(
        not wrong,
        "plan.failure_policy",
        "each failure class has its own disposition",
        "failure_policy is wrong for: " + "; ".join(wrong),
    )


def check_timing_policy(plan: dict[str, Any], report: Report) -> None:
    timing = plan.get("timing")
    if not isinstance(timing, dict):
        report.fail("plan.timing", "timing must be an object")
        return
    intervals = timing.get("intervals")
    report.require(
        isinstance(intervals, list) and all(item in intervals for item in REQUIRED_TIMING_INTERVALS),
        "timing.intervals",
        "both centrally clocked intervals recorded",
        "timing.intervals must contain " + " and ".join(REQUIRED_TIMING_INTERVALS),
    )
    report.require(
        nonempty_str(timing.get("clock")),
        "timing.clock",
        f"shared clock {timing.get('clock')!r}",
        "timing.clock must name the shared clock source",
    )
    report.require(
        timing.get("queue_trust_delay_recorded") is True,
        "timing.queue_trust_delay",
        "queue and trust delay recorded separately",
        "timing.queue_trust_delay_recorded must be true",
    )
    timeout = timing.get("no_commit_timeout_s")
    report.require(
        isinstance(timeout, int) and not isinstance(timeout, bool) and timeout > 0
        and timing.get("no_commit_disposition") == "void_and_rerun",
        "timing.no_commit",
        f"no-commit timeout {timeout}s voids and reruns",
        "timing needs a positive no_commit_timeout_s and no_commit_disposition 'void_and_rerun'",
    )


def check_track(name: str, track: dict[str, Any], plan: dict[str, Any], report: Report) -> None:
    prefix = f"track.{name}"
    packets = track.get("packets")
    packet_ids: list[str] = []
    if isinstance(packets, list) and all(isinstance(item, dict) for item in packets):
        packet_ids = [str(item.get("id", "")) for item in packets]
        distinct = len(set(packet_ids)) == len(packet_ids) and all(packet_ids)
        report.require(
            len(packets) == plan.get("samples_per_entrant") and distinct,
            f"{prefix}.packets",
            f"{len(packets)} distinct frozen packets, one sample each",
            "each entrant needs six distinct packets; repeated packets are not independent samples",
        )
        bad_kind = [item.get("id") for item in packets if item.get("kind") not in ("historical", "synthetic")]
        report.require(
            not bad_kind,
            f"{prefix}.packet_kind",
            "every packet declares historical or synthetic provenance",
            f"packets with an invalid kind: {', '.join(str(item) for item in bad_kind)}",
        )
    else:
        report.fail(f"{prefix}.packets", "packets must be a list of objects")

    baseline = track.get("baseline")
    strata = track.get("baseline_packets")
    if isinstance(baseline, dict):
        expected = packet_ids[0:5:2] if len(packet_ids) >= 5 else []
        report.require(
            isinstance(strata, list) and strata == expected and len(expected) == 3,
            f"{prefix}.baseline_packets",
            f"baseline runs the preregistered stratified subset {expected}",
            f"baseline_packets must be the preregistered stratified subset {expected}, got {strata!r}",
        )
    else:
        report.require(
            not strata,
            f"{prefix}.baseline_packets",
            "no baseline declared and no baseline strata",
            "baseline_packets requires a declared baseline",
        )

    entrants = track.get("entrants")
    if isinstance(entrants, list) and entrants:
        report.ok(f"{prefix}.entrants", f"{len(entrants)} entrants")
        for candidate in track_candidates(track):
            check_candidate_tuple(prefix, candidate, report)
    else:
        report.fail(f"{prefix}.entrants", "entrants must be a non-empty list")

    check_track_panel(prefix, track, report)
    check_track_spec_seat(prefix, track, report)

    probe = track.get("optional_probe")
    report.require(
        probe in (None, "all_samples"),
        f"{prefix}.optional_probe",
        "no outcome-dependent extra judge",
        "an implementation probe must be preregistered for all samples or removed",
    )

    if track.get("capture_required") is True:
        report.require(
            track.get("wave") == "single-complete",
            f"{prefix}.wave",
            "the whole field runs as one complete wave",
            "a capture track must declare wave 'single-complete'; no partial field may start",
        )


def check_candidate_tuple(prefix: str, candidate: dict[str, Any], report: Report) -> None:
    name = str(candidate.get("name", "<unnamed>"))
    check = f"{prefix}.tuple.{re.sub(r'[^A-Za-z0-9]+', '-', name).strip('-').lower() or 'unnamed'}"
    missing = [key for key in ("name", "family", "harness", "model") if not nonempty_str(candidate.get(key))]
    if missing:
        report.fail(check, f"{name} is missing: {', '.join(missing)}")
        return
    has_effort_axis = candidate.get("effort_axis", True)
    if has_effort_axis and not nonempty_str(candidate.get("effort")):
        report.fail(check, f"{name} declares an effort axis but pins no effort")
        return
    if not has_effort_axis and candidate.get("effort") is not None:
        report.fail(check, f"{name} declares no effort axis but pins effort {candidate.get('effort')!r}")
        return
    report.ok(check, f"{name} pinned to {candidate['harness']}/{candidate['model']}")


def check_track_panel(prefix: str, track: dict[str, Any], report: Report) -> None:
    """Correction 3: one common neutral panel scores every candidate in a track."""
    stray = sorted(key for key in track if key in ("candidate_judges", "judge_exclusions", "same_family_exclusion"))
    report.require(
        not stray,
        f"{prefix}.panel_common",
        "one panel scores every candidate in the track",
        f"candidate-specific judge selection is refused: {', '.join(stray)}",
    )

    judges = track.get("judges")
    if not isinstance(judges, list) or not judges:
        report.fail(f"{prefix}.judges", "judges must be a non-empty list")
        return
    names = [str(judge.get("name", "")) for judge in judges if isinstance(judge, dict)]
    families = [str(judge.get("family", "")).strip().lower() for judge in judges if isinstance(judge, dict)]
    if len(names) != len(judges) or not all(names) or not all(families):
        report.fail(f"{prefix}.judges", "every judge needs a name and a family")
        return
    report.require(
        len(judges) >= 2,
        f"{prefix}.panel_size",
        f"{len(judges)} common judges",
        "a track needs at least two common neutral-family judges",
    )
    report.require(
        len(set(names)) == len(names),
        f"{prefix}.panel_distinct",
        "judges are distinct",
        "the same judge is listed twice",
    )
    entrant_families = track_families(track)
    overlap = sorted(set(families) & entrant_families)
    report.require(
        not overlap,
        f"{prefix}.panel_neutral",
        "no judge family fields a candidate in this track",
        f"judge families also field candidates here: {', '.join(overlap)}",
    )


def check_track_spec_seat(prefix: str, track: dict[str, Any], report: Report) -> None:
    """Correction 3: the spec author may not judge, and each spec is audited pre-freeze."""
    author = track.get("spec_author")
    if not isinstance(author, dict):
        return
    author_family = str(author.get("family", "")).strip().lower()
    judge_families = {
        str(judge.get("family", "")).strip().lower()
        for judge in (track.get("judges") or [])
        if isinstance(judge, dict)
    }
    judge_names = {
        str(judge.get("name", "")).strip().lower()
        for judge in (track.get("judges") or [])
        if isinstance(judge, dict)
    }
    report.require(
        author_family not in judge_families
        and str(author.get("name", "")).strip().lower() not in judge_names,
        f"{prefix}.spec_author_not_judge",
        "the design author does not judge its own specification",
        "the specification author may not interpret its own unstated intent after outputs exist",
    )
    entrant_names = {
        str(candidate.get("name", "")).strip().lower() for candidate in track_candidates(track)
    }
    report.require(
        str(author.get("name", "")).strip().lower() not in entrant_names,
        f"{prefix}.spec_author_not_entrant",
        "the design author fields no entrant here",
        "the specification author is also an entrant in this track",
    )
    # Keeping the design seat is a fixed captain choice, so a same-family entrant
    # is not refused. It is a residual recognition channel, and the review's rule
    # is that residual channels are disclosed rather than left silent.
    adjacent = sorted(
        str(candidate.get("name"))
        for candidate in track_candidates(track)
        if str(candidate.get("family", "")).strip().lower() == author_family
    )
    if adjacent:
        disclosed = sorted(str(item) for item in (author.get("family_adjacency_disclosed") or []))
        report.require(
            disclosed == adjacent,
            f"{prefix}.spec_author_family_adjacency",
            f"the design author shares a family with {', '.join(adjacent)}, disclosed in the plan",
            f"entrants share the design author's family and are not disclosed: {', '.join(adjacent)}",
        )
    else:
        report.ok(f"{prefix}.spec_author_family_adjacency", "no entrant shares the design author's family")

    packet_ids = [str(item.get("id", "")) for item in (track.get("packets") or []) if isinstance(item, dict)]
    audits = track.get("spec_audit")
    if not isinstance(audits, list):
        report.fail(f"{prefix}.spec_audit", "spec_audit must be a list, one record per packet")
        return
    audited = {str(item.get("packet", "")) for item in audits if isinstance(item, dict)}
    report.require(
        audited == set(packet_ids) and len(audits) == len(packet_ids),
        f"{prefix}.spec_audit_coverage",
        f"{len(audits)} specifications independently audited",
        f"every packet needs one specification audit; missing {sorted(set(packet_ids) - audited)}",
    )
    bad = []
    for item in audits:
        if not isinstance(item, dict):
            bad.append("<malformed>")
            continue
        auditor_family = str(item.get("auditor_family", "")).strip().lower()
        if (
            not nonempty_str(item.get("auditor"))
            or auditor_family in ({author_family} | track_families(track))
            or item.get("pre_freeze") is not True
            or item.get("verdict") != "accepted"
        ):
            bad.append(str(item.get("packet", "<unnamed>")))
    report.require(
        not bad,
        f"{prefix}.spec_audit_independent",
        "each specification was accepted by an independent auditor before its hash was frozen",
        f"specification audits are not independent, pre-freeze, or accepted: {', '.join(bad)}",
    )


# --------------------------------------------------------------------------
# Provenance: correction 6. Positive identification of every original
# participant before a historical packet may be replayed.
# --------------------------------------------------------------------------


def check_provenance(root: Path, plan: dict[str, Any], report: Report) -> None:
    tracks = plan.get("tracks") or {}
    historical = [
        (name, packet)
        for name in sorted(tracks)
        if isinstance(tracks[name], dict)
        for packet in (tracks[name].get("packets") or [])
        if isinstance(packet, dict) and packet.get("kind") == "historical"
    ]
    if not historical:
        report.ok("provenance.scope", "no historical packet is scheduled")
        return

    cleared_by_track: dict[str, list[str]] = {}
    failed_by_track: dict[str, list[str]] = {}
    for track_name, packet in historical:
        packet_id = str(packet.get("id", ""))
        entrant_families = track_families(tracks[track_name])
        cleared = check_one_provenance(root, track_name, packet_id, entrant_families, report)
        bucket = cleared_by_track if cleared else failed_by_track
        bucket.setdefault(track_name, []).append(packet_id)

    for track_name in sorted(failed_by_track):
        if not cleared_by_track.get(track_name):
            report.stop(
                f"provenance.track.{track_name}",
                "every historical packet in this track failed its contamination check; "
                "a replacement packet is a captain call, never a substitution",
            )


def check_one_provenance(
    root: Path, track_name: str, packet_id: str, entrant_families: set[str], report: Report
) -> bool:
    check = f"provenance.{packet_id}"
    path = root / "provenance" / f"{packet_id}.json"
    if not path.is_file():
        report.fail(check, f"no provenance record at provenance/{packet_id}.json; absence never clears a replay")
        return False
    try:
        record = load_json(path, PROVENANCE_SCHEMA)
    except GateError as exc:
        report.fail(check, str(exc))
        return False

    participants = record.get("participants")
    if not isinstance(participants, list) or not participants:
        report.fail(check, "no participant was positively identified; 'no record found' fails the check")
        return False

    incomplete: list[str] = []
    contaminated: list[str] = []
    for index, participant in enumerate(participants):
        label = f"#{index}"
        if not isinstance(participant, dict):
            incomplete.append(label)
            continue
        label = str(participant.get("task_id") or label)
        missing = [
            key
            for key in ("task_id", "role", "model_id", "family", "session_id")
            if not nonempty_str(participant.get(key))
        ]
        if missing:
            incomplete.append(f"{label} missing {'/'.join(missing)}")
            continue
        if str(participant.get("role")).strip().lower() not in ("author", "reviewer", "judge"):
            incomplete.append(f"{label} has an unrecognised role")
            continue
        if str(participant.get("family")).strip().lower() in entrant_families:
            contaminated.append(f"{label} is {participant.get('model_id')}")

    if incomplete:
        report.fail(check, "participant records are incomplete: " + "; ".join(incomplete))
        return False
    if contaminated:
        report.fail(check, "entrant-family exposure found: " + "; ".join(contaminated))
        return False

    checked = {str(item).strip().lower() for item in (record.get("checked_families") or [])}
    if not entrant_families <= checked:
        report.fail(
            check,
            "the check did not cover every entrant family; missing "
            + ", ".join(sorted(entrant_families - checked)),
        )
        return False

    report.ok(check, f"{len(participants)} original participants positively identified, no entrant-family exposure")
    return True


# --------------------------------------------------------------------------
# Manifest and allowance: correction 7. Exact run, allowance, cost, timing,
# and failure arithmetic derived from the plan, never from a quoted range.
# --------------------------------------------------------------------------


def build_manifest(plan: dict[str, Any]) -> dict[str, Any]:
    samples = int(plan.get("samples_per_entrant") or 0)
    baseline_samples = int(plan.get("samples_per_baseline") or 0)
    cost_model = plan.get("cost_model") or {}
    classes = cost_model.get("job_classes") or {}

    tracks_out: dict[str, Any] = {}
    totals = {
        "entrant_runs": 0,
        "baseline_runs": 0,
        "scored_outputs": 0,
        "spec_jobs": 0,
        "judge_calls": 0,
        "capture_records": 0,
    }
    cost = {"low": 0.0, "base": 0.0, "high": 0.0}
    allowance_required: dict[str, int] = {}

    for name in sorted(plan.get("tracks") or {}):
        track = plan["tracks"][name]
        if not isinstance(track, dict):
            continue
        entrants = track.get("entrants") or []
        packets = track.get("packets") or []
        entrant_runs = len(entrants) * samples
        baseline_runs = baseline_samples if isinstance(track.get("baseline"), dict) else 0
        scored = entrant_runs + baseline_runs
        spec_jobs = len(packets) if isinstance(track.get("spec_author"), dict) else 0
        judge_calls = scored * len(track.get("judges") or [])
        captures = entrant_runs if track.get("capture_required") is True else 0

        tracks_out[name] = {
            "entrant_runs": entrant_runs,
            "baseline_runs": baseline_runs,
            "scored_outputs": scored,
            "spec_jobs": spec_jobs,
            "judge_calls": judge_calls,
            "judge_call_unit": track.get("judge_call_unit"),
            "capture_records": captures,
        }
        totals["entrant_runs"] += entrant_runs
        totals["baseline_runs"] += baseline_runs
        totals["scored_outputs"] += scored
        totals["spec_jobs"] += spec_jobs
        totals["judge_calls"] += judge_calls
        totals["capture_records"] += captures

        run_class = classes.get(str(track.get("run_cost_class", "")))
        priced: list[tuple[dict[str, Any], int]] = [(entrant, samples) for entrant in entrants]
        if isinstance(track.get("baseline"), dict):
            priced.append((track["baseline"], baseline_samples))
        for candidate, runs in priced:
            provider = candidate.get("metered_provider")
            if nonempty_str(provider):
                allowance_required[str(provider)] = allowance_required.get(str(provider), 0) + runs
            elif isinstance(run_class, dict):
                for bound in cost:
                    cost[bound] += float(run_class.get(bound, 0)) * runs
        for key, count in (("spec_authoring", spec_jobs), ("judge_call", judge_calls), ("capture_job", captures)):
            unit = classes.get(key)
            if isinstance(unit, dict):
                for bound in cost:
                    cost[bound] += float(unit.get(bound, 0)) * count

    totals["total_model_jobs"] = totals["scored_outputs"] + totals["spec_jobs"]
    return {
        "schema": MANIFEST_SCHEMA,
        "benchmark_id": plan.get("benchmark_id"),
        "plan_sha256": None,
        "tracks": tracks_out,
        "totals": totals,
        "cost_usd": {bound: round(cost[bound], 2) for bound in ("low", "base", "high")},
        "allowance_required_runs": allowance_required,
        "approved_cost_class_usd": plan.get("approved_cost_class_usd"),
    }


def check_cost_model(plan: dict[str, Any], report: Report) -> None:
    cost_model = plan.get("cost_model")
    if not isinstance(cost_model, dict):
        report.fail("manifest.cost_model", "cost_model must be an object of per-job-class low/base/high unit costs")
        return
    classes = cost_model.get("job_classes")
    if not isinstance(classes, dict) or not classes:
        report.fail("manifest.cost_model", "cost_model.job_classes must be a non-empty object")
        return
    bad = [
        name
        for name, unit in sorted(classes.items())
        if not isinstance(unit, dict)
        or not all(
            isinstance(unit.get(bound), (int, float)) and not isinstance(unit.get(bound), bool)
            for bound in ("low", "base", "high")
        )
        or not unit["low"] <= unit["base"] <= unit["high"]
    ]
    report.require(
        not bad,
        "manifest.cost_model",
        f"{len(classes)} job classes carry ordered low/base/high unit costs",
        f"job classes lack ordered low/base/high unit costs: {', '.join(bad)}",
    )


def check_manifest(root: Path, plan: dict[str, Any], report: Report) -> None:
    check_cost_model(plan, report)
    expected = build_manifest(plan)
    expected["plan_sha256"] = sha256_file(root / "benchmark.json")

    path = root / "manifest.json"
    if not path.is_file():
        report.fail("manifest.present", "manifest.json is absent; run `manifest-build` before launch")
        return
    try:
        stored = load_json(path, MANIFEST_SCHEMA)
    except GateError as exc:
        report.fail("manifest.present", str(exc))
        return

    report.require(
        stored.get("plan_sha256") == expected["plan_sha256"],
        "manifest.plan_binding",
        "the manifest is bound to the current plan",
        "manifest.json was generated from a different plan; rebuild it",
    )
    for section in ("tracks", "totals", "cost_usd", "allowance_required_runs"):
        report.require(
            stored.get(section) == expected[section],
            f"manifest.{section}",
            f"{section} matches the arithmetic recomputed from the plan",
            f"{section} disagrees with the plan: stored {stored.get(section)!r}, recomputed {expected[section]!r}",
        )

    high = expected["cost_usd"]["high"]
    approved = plan.get("approved_cost_class_usd")
    if isinstance(approved, (int, float)) and not isinstance(approved, bool):
        if high > approved:
            report.stop(
                "manifest.cost_class",
                f"the measured high case {high} exceeds the approved class {approved}; "
                "this is a captain call, never a silent budget expansion",
            )
        else:
            report.ok("manifest.cost_class", f"high case {high} is inside the approved class {approved}")

    check_allowance(root, plan, expected, report)


def check_allowance(root: Path, plan: dict[str, Any], manifest: dict[str, Any], report: Report) -> None:
    required = manifest["allowance_required_runs"]
    if not required:
        report.ok("allowance.scope", "no metered provider is in the field")
        return
    path = root / "allowance.json"
    if not path.is_file():
        report.fail("allowance.present", "allowance.json is absent; the metered field may not start unproven")
        return
    try:
        record = load_json(path, ALLOWANCE_SCHEMA)
    except GateError as exc:
        report.fail("allowance.present", str(exc))
        return
    providers = record.get("providers")
    if not isinstance(providers, dict):
        report.fail("allowance.present", "allowance.providers must be an object")
        return

    metered_tuples = {
        str(provider): sorted(
            f"{candidate.get('harness')}/{candidate.get('model')}"
            for name in (plan.get("tracks") or {})
            if isinstance(plan["tracks"][name], dict)
            for candidate in track_candidates(plan["tracks"][name])
            if str(candidate.get("metered_provider") or "") == str(provider)
        )
        for provider in required
    }
    field_sizes = {
        str(candidate.get("metered_provider")): len(plan["tracks"][name].get("entrants") or [])
        for name in (plan.get("tracks") or {})
        if isinstance(plan["tracks"][name], dict)
        for candidate in track_candidates(plan["tracks"][name])
        if nonempty_str(candidate.get("metered_provider"))
    }

    for provider in sorted(required):
        check = f"allowance.{provider}"
        entry = providers.get(provider)
        if not isinstance(entry, dict):
            report.fail(check, f"no measured allowance recorded for {provider}")
            continue
        need = required[provider]
        reserve = entry.get("reserve_runs")
        available = entry.get("measured_available_runs")
        if entry.get("required_runs") != need:
            report.fail(check, f"records {entry.get('required_runs')!r} required runs; the plan needs {need}")
            continue
        if not all(
            isinstance(value, int) and not isinstance(value, bool) and value >= 0
            for value in (reserve, available)
        ):
            report.fail(check, "reserve_runs and measured_available_runs must be recorded integers")
            continue
        if reserve < 1:
            report.fail(check, "a predeclared reserve of at least one run is required")
            continue
        if available < need + reserve:
            report.fail(
                check,
                f"measured allowance {available} does not cover {need} runs plus the {reserve}-run reserve; "
                "no partial field may start",
            )
            continue
        if not nonempty_str(entry.get("source")) or not nonempty_str(entry.get("measured_at")):
            report.fail(check, "the allowance measurement needs a recorded source and timestamp")
            continue

        proof = entry.get("concurrency_proof")
        if not isinstance(proof, dict):
            report.fail(check, "no concurrency proof recorded")
            continue
        sessions = proof.get("concurrent_sessions")
        if not isinstance(sessions, int) or isinstance(sessions, bool) or sessions < 2:
            report.fail(check, "the concurrency proof must show at least two concurrent sessions")
            continue
        if proof.get("used_benchmark_packet") is not False:
            report.fail(check, "the concurrency proof may not consume a benchmark packet")
            continue
        if sorted(str(item) for item in (proof.get("tuples") or [])) != metered_tuples[provider]:
            report.fail(
                check,
                f"the concurrency proof must cover the exact tuples {metered_tuples[provider]}",
            )
            continue

        start = entry.get("full_field_start_proof")
        want_field = field_sizes.get(provider)
        if not isinstance(start, dict) or start.get("entrants") != want_field or not nonempty_str(start.get("verified_at")):
            report.fail(check, f"a recorded start proof for the complete {want_field}-entrant field is required")
            continue
        report.ok(
            check,
            f"{available} runs measured against {need} required plus {reserve} reserve, "
            f"two concurrent sessions and the complete {want_field}-entrant field proven",
        )


# --------------------------------------------------------------------------
# Isolation: correction 4. The gate does not trust a declared mechanism; it
# runs the sibling-access probe set through the declared confinement and
# refuses unless every probe is positively denied. A probe that cannot run at
# all is inconclusive, and inconclusive fails closed.
# --------------------------------------------------------------------------


def probe_command(probe: str, target: str) -> list[str]:
    """The argv the confinement runs. Each probe prints LEAKED on success."""
    script_dir = Path(__file__).resolve().parent
    return [str(script_dir / "fm-bench-probe.sh"), probe, target]


def run_probe(
    wrapper: list[str], probe: str, target: str, timeout: int, env: dict[str, str] | None = None
) -> tuple[str, str]:
    argv = list(wrapper) + probe_command(probe, target)
    try:
        proc = subprocess.run(
            argv,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            env=env,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return "inconclusive", f"probe could not run: {exc}"
    out = proc.stdout.decode("utf-8", "replace").strip()
    err = proc.stderr.decode("utf-8", "replace").strip()
    verdict = ""
    for line in out.splitlines():
        if line.startswith("PROBE "):
            verdict = line.split(" ", 2)[1] if len(line.split(" ", 2)) > 1 else ""
    if verdict == "LEAKED":
        return "leaked", out.splitlines()[-1] if out else "target was reachable"
    if verdict == "DENIED":
        return "denied", "access refused inside the confinement"
    if verdict == "INCONCLUSIVE":
        return "inconclusive", out.splitlines()[-1] if out else "the probe could not measure the access"
    detail = err or out or f"exit {proc.returncode} with no probe verdict"
    return "inconclusive", f"probe produced no verdict ({detail[:160]})"


class ProbeControls:
    """Positive controls that make a denial verdict meaningful.

    A probe that reports DENIED because its target does not exist proves
    nothing. Before trusting any denial, the gate runs the same probe with no
    confinement at all and requires it to LEAK. A probe with no positive
    control is treated as inconclusive, which fails closed.
    """

    def __init__(self, canary: str) -> None:
        self.canary = canary
        self._tmp = tempfile.TemporaryDirectory(prefix="fm-bench-control-")
        self.env = dict(os.environ)
        self.env[f"{canary}LEAK_CANARY"] = "1"
        marker = Path(self._tmp.name) / "fm-bench-marker-entrant"
        marker.write_text("#!/bin/sh\nwhile :; do sleep 1; done\n", encoding="utf-8")
        marker.chmod(0o755)
        self._proc: subprocess.Popen[bytes] | None = None
        try:
            self._proc = subprocess.Popen(
                [str(marker)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
        except OSError:
            self._proc = None

    def close(self) -> None:
        if self._proc is not None:
            self._proc.terminate()
            try:
                self._proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self._proc.kill()
        self._tmp.cleanup()


def check_isolation(root: Path, report: Report, timeout: int) -> None:
    path = root / "isolation.json"
    if not path.is_file():
        report.fail("isolation.present", "isolation.json is absent; enforced isolation must be provisioned and proven")
        return
    try:
        record = load_json(path, ISOLATION_SCHEMA)
    except GateError as exc:
        report.fail("isolation.present", str(exc))
        return

    wrapper = record.get("exec_wrapper")
    if not isinstance(wrapper, list) or not wrapper or not all(isinstance(item, str) for item in wrapper):
        report.fail("isolation.exec_wrapper", "exec_wrapper must be the argv prefix that confines an entrant")
        return
    entrants = record.get("entrants")
    if not isinstance(entrants, list) or not entrants:
        report.fail("isolation.entrants", "entrants must be a non-empty list of provisioned per-entrant roots")
        return

    protected = [str(item) for item in (record.get("protected_paths") or [])]
    controls = ProbeControls(str(record.get("leak_marker", "FM_BENCH_")))
    try:
        probe_entrants(entrants, protected, wrapper, record, controls, report, timeout)
    finally:
        controls.close()

    report.require(
        len(entrants) >= 2,
        "isolation.sibling_coverage",
        f"{len(entrants)} entrants probed against each other",
        "at least two provisioned entrants are needed for a sibling-access proof",
    )


def is_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
    except ValueError:
        return False
    return True


def entrant_alternates(root: str) -> list[Path]:
    found: list[Path] = []
    base = Path(root)
    for marker in (
        base / ".git" / "objects" / "info" / "alternates",
        base / "objects" / "info" / "alternates",
    ):
        if not marker.is_file():
            continue
        try:
            text = marker.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for line in text.splitlines():
            entry = line.strip()
            if not entry or entry.startswith("#"):
                continue
            path = Path(entry)
            found.append(path if path.is_absolute() else marker.parent.parent / entry)
    return found


def probe_material(path: Path) -> bool:
    try:
        if path.is_file():
            return True
        if not path.is_dir():
            return False
        for entry in path.rglob("*"):
            if entry.is_file():
                return True
    except OSError:
        return False
    return False


def check_entrant_alternates(entrant_id: str, entrant: dict[str, Any], report: Report) -> list[Path]:
    root = Path(str(entrant.get("root"))).resolve()
    store = Path(str(entrant.get("private_object_store"))).resolve()
    alternates = entrant_alternates(str(entrant.get("root")))
    outside = sorted(
        str(path.resolve())
        for path in alternates
        if not is_within(path.resolve(), root) and not is_within(path.resolve(), store)
    )
    report.require(
        not outside,
        f"isolation.{entrant_id}.alternates",
        f"{len(alternates)} alternate object stores resolve inside this entrant's own storage"
        if alternates
        else "no alternate object store is configured",
        "the clone reaches an object store outside its own private storage through "
        f"objects/info/alternates: {', '.join(outside)}",
    )
    return alternates


def probe_entrants(
    entrants: list[Any],
    protected: list[str],
    wrapper: list[str],
    record: dict[str, Any],
    controls: "ProbeControls",
    report: Report,
    timeout: int,
) -> None:
    provisioned = [entrant for entrant in entrants if isinstance(entrant, dict)]
    if len(provisioned) != len(entrants):
        report.fail("isolation.entrant", "each entrant must be an object")
    for entrant in provisioned:
        entrant_id = str(entrant.get("id", ""))
        missing = [
            key
            for key in ("id", "root", *PRIVATE_STORAGE_KEYS)
            if not nonempty_str(entrant.get(key))
        ]
        if missing:
            report.fail(
                f"isolation.{entrant_id or '<unnamed>'}.provision",
                f"per-entrant storage is incomplete: missing {', '.join(missing)}",
            )
            continue
        report.ok(f"isolation.{entrant_id}.provision", "private clone, object store, temp, home, and session space recorded")

        barren = [key for key in PRIVATE_STORAGE_KEYS if not probe_material(Path(str(entrant.get(key))))]
        report.require(
            not barren,
            f"isolation.{entrant_id}.private_storage",
            "every declared private store holds material a sibling probe can be tested against",
            "declared private storage carries nothing a sibling probe could read, so a denial "
            f"against it would prove nothing: {', '.join(barren)}",
        )
        check_entrant_alternates(entrant_id, entrant, report)

        siblings = sorted(
            (other for other in provisioned if str(other.get("id", "")) != entrant_id and other.get("root")),
            key=lambda other: str(other.get("root")),
        )
        targets: list[tuple[str, str]] = []
        for sibling in siblings:
            sibling_root = str(sibling.get("root"))
            targets.append(("sibling_file_read", sibling_root))
            targets.append(("sibling_worktree_enumeration", sibling_root))
            targets.append(("sibling_object_enumeration", sibling_root))
            targets.append(("sibling_unreachable_objects", sibling_root))
            for key in PRIVATE_STORAGE_KEYS:
                private = Path(str(sibling.get(key, "")))
                if probe_material(private):
                    targets.append(("sibling_file_read", str(private)))
            for alternate in entrant_alternates(sibling_root):
                if probe_material(alternate):
                    targets.append(("sibling_file_read", str(alternate)))
        for guarded in protected:
            targets.append(("protected_path_read", guarded))
        # The control marker stands in for a sibling entrant's process: it is a
        # real process outside this entrant that a shared process table exposes.
        targets.append(("process_inspection", "fm-bench-marker"))
        targets.append(("environment_leakage", str(record.get("leak_marker", "FM_BENCH_"))))

        targets = list(dict.fromkeys(targets))
        exercised = {probe for probe, _ in targets}
        entrant_wrapper = [item.replace("{root}", str(entrant.get("root"))) for item in wrapper]
        for probe, target in targets:
            check = f"isolation.{entrant_id}.{probe}"
            control, control_detail = run_probe([], probe, target, timeout, controls.env)
            if control != "leaked":
                report.fail(
                    check,
                    f"no positive control against {target}: unconfined the probe reported "
                    f"{control} ({control_detail}); a denial here would prove nothing",
                )
                continue
            verdict, detail = run_probe(entrant_wrapper, probe, target, timeout, controls.env)
            if verdict == "denied":
                report.ok(check, f"denied against {target}, which is reachable without the confinement")
            elif verdict == "leaked":
                report.fail(check, f"reachable against {target}: {detail}")
            else:
                report.fail(check, f"inconclusive against {target}: {detail}; an unproven denial fails closed")

        unexercised = sorted(set(ISOLATION_PROBES) - exercised)
        report.require(
            not unexercised,
            f"isolation.{entrant_id}.coverage",
            f"all {len(ISOLATION_PROBES)} probe classes exercised",
            f"probe classes never exercised: {', '.join(unexercised)}",
        )


# --------------------------------------------------------------------------
# Evaluator: correction 5. A reproducible, calibrated evaluator with one bound
# capture record per candidate head.
# --------------------------------------------------------------------------


def check_evaluator(root: Path, plan: dict[str, Any], report: Report) -> None:
    expected_captures = build_manifest(plan)["totals"]["capture_records"]
    if expected_captures == 0:
        report.ok("evaluator.scope", "no track requires neutral capture")
        return
    base = root / "evaluator"
    check_evaluator_lock(base, report)
    weights = check_evaluator_score_map(base, report)
    check_evaluator_determinism(base, report)
    check_evaluator_mutations(base, weights, report)
    check_evaluator_captures(base, plan, expected_captures, report)


def check_evaluator_lock(base: Path, report: Report) -> None:
    try:
        lock = load_json(base / "lock.json")
    except GateError as exc:
        report.fail("evaluator.lock", str(exc))
        return
    missing = [key for key in REQUIRED_EVALUATOR_LOCK_KEYS if is_absent(lock.get(key)) or lock.get(key) is None]
    report.require(
        not missing,
        "evaluator.lock",
        f"the environment lock pins {len(REQUIRED_EVALUATOR_LOCK_KEYS)} required fields",
        f"the environment lock is missing: {', '.join(missing)}",
    )
    zoom = lock.get("zoom_intervention")
    scale = lock.get("device_scale_factor")
    report.require(
        isinstance(zoom, dict)
        and nonempty_str(zoom.get("mechanism"))
        and zoom.get("percent") == 200
        and zoom.get("mechanism") != "device_scale_factor",
        "evaluator.zoom_semantics",
        f"200% is a {zoom.get('mechanism') if isinstance(zoom, dict) else '?'} intervention, separate from screenshot resolution",
        "zoom_intervention must name one standards-aligned 200% mechanism distinct from device_scale_factor",
    )
    report.require(
        isinstance(scale, (int, float)) and not isinstance(scale, bool) and scale > 0,
        "evaluator.device_scale_factor",
        f"screenshot resolution recorded separately as {scale}",
        "device_scale_factor must be recorded as screenshot resolution, not as the zoom intervention",
    )


def check_evaluator_score_map(base: Path, report: Report) -> dict[str, Any] | None:
    try:
        score_map = load_json(base / "score-map.json")
    except GateError as exc:
        report.fail("evaluator.score_map", str(exc))
        return None
    missing = [key for key in REQUIRED_SCORE_MAP_KEYS if score_map.get(key) in (None, "", [], {})]
    report.require(
        not missing,
        "evaluator.score_map",
        "the complete raw-measurement to points mapping is published",
        f"the score map is missing: {', '.join(missing)}",
    )
    weights = score_map.get("dimension_weights")
    if not isinstance(weights, dict) or not weights:
        report.fail("evaluator.weights", "dimension_weights must be an object")
        return None
    scored = [
        name
        for name in VALIDITY_GATE_DIMENSIONS
        if isinstance(weights.get(name), (int, float)) and weights.get(name) != 0
    ]
    report.require(
        not scored,
        "evaluator.validity_gates",
        "evidence-validity conditions carry zero score weight",
        f"validity conditions still score candidate quality: {', '.join(scored)}",
    )
    total = sum(
        float(value)
        for value in weights.values()
        if isinstance(value, (int, float)) and not isinstance(value, bool)
    )
    report.require(
        abs(total - 100.0) < 1e-6,
        "evaluator.weight_sum",
        "dimension weights renormalise to 100",
        f"dimension weights sum to {total}, not 100",
    )
    return weights


def scored_dimensions(weights: dict[str, Any] | None) -> set[str]:
    if not isinstance(weights, dict):
        return set()
    return {
        str(name)
        for name, value in weights.items()
        if name not in VALIDITY_GATE_DIMENSIONS
        and isinstance(value, (int, float))
        and not isinstance(value, bool)
        and float(value) != 0.0
    }


def check_evaluator_determinism(base: Path, report: Report) -> None:
    first = base / "determinism" / "run-1.json"
    second = base / "determinism" / "run-2.json"
    if not first.is_file() or not second.is_file():
        report.fail("evaluator.determinism", "two dry-runs on the same golden head are required")
        return
    left, right = sha256_file(first), sha256_file(second)
    if left == right:
        report.ok("evaluator.determinism", f"two dry-runs on the golden head are byte-identical ({left[:12]})")
        return
    try:
        bound = load_json(base / "determinism" / "bound.json")
    except GateError:
        report.fail(
            "evaluator.determinism",
            "the two dry-runs differ and no preregistered bounded delta is declared",
        )
        return
    declared = bound.get("max_image_delta")
    observed = bound.get("observed_image_delta")
    report.require(
        isinstance(declared, (int, float))
        and isinstance(observed, (int, float))
        and not isinstance(declared, bool)
        and not isinstance(observed, bool)
        and observed <= declared
        and bound.get("structural_fields_identical") is True,
        "evaluator.determinism",
        f"structured results identical and image delta {observed} within the preregistered bound {declared}",
        "the two dry-runs differ outside the preregistered bounded delta",
    )


def check_evaluator_mutations(base: Path, weights: dict[str, Any] | None, report: Report) -> None:
    directory = base / "mutations"
    records = sorted(directory.glob("*.json")) if directory.is_dir() else []
    if not records:
        report.fail("evaluator.mutations", "no mutation calibration records; each dimension must be proven to move")
        return
    moved: set[str] = set()
    for path in records:
        check = f"evaluator.mutation.{path.stem}"
        try:
            record = load_json(path)
        except GateError as exc:
            report.fail(check, str(exc))
            continue
        dimension = record.get("dimension")
        deltas = record.get("dimension_deltas")
        threshold = record.get("movement_threshold")
        valid_threshold = (
            isinstance(threshold, (int, float))
            and not isinstance(threshold, bool)
            and math.isfinite(float(threshold))
            and float(threshold) > 0
        )
        if not nonempty_str(dimension) or not isinstance(deltas, dict) or not valid_threshold:
            report.fail(check, "a mutation record needs dimension, dimension_deltas, and movement_threshold")
            continue
        target = deltas.get(dimension)
        if (
            not isinstance(target, (int, float))
            or isinstance(target, bool)
            or not math.isfinite(float(target))
            or abs(float(target)) < float(threshold)
        ):
            report.fail(check, f"the mutated dimension {dimension} did not move beyond {threshold}")
            continue
        bled = sorted(
            name
            for name, value in deltas.items()
            if name != dimension
            and isinstance(value, (int, float))
            and not isinstance(value, bool)
            and math.isfinite(float(value))
            and abs(float(value)) >= float(threshold)
        )
        if bled:
            report.fail(check, f"unrelated dimensions moved with {dimension}: {', '.join(bled)}")
            continue
        moved.add(str(dimension))
        report.ok(check, f"{dimension} moved alone")
    expected = scored_dimensions(weights)
    uncalibrated = sorted(expected - moved)
    report.require(
        bool(moved) and not uncalibrated,
        "evaluator.mutations",
        f"all {len(moved)} scored dimensions calibrated by mutation",
        f"scored dimensions never proven to respond to their own mutation: {', '.join(uncalibrated)}"
        if uncalibrated
        else "no dimension was proven to respond to its own mutation",
    )


def check_evaluator_captures(base: Path, plan: dict[str, Any], expected: int, report: Report) -> None:
    directory = base / "captures"
    records = sorted(directory.glob("*.json")) if directory.is_dir() else []
    report.require(
        len(records) == expected,
        "evaluator.capture_count",
        f"{len(records)} capture records, one per candidate head",
        f"expected {expected} capture records bound to candidate heads, found {len(records)}",
    )
    seen: set[tuple[str, str]] = set()
    trees: set[str] = set()
    for path in records:
        check = f"evaluator.capture.{path.stem}"
        try:
            record = load_json(path)
        except GateError as exc:
            report.fail(check, str(exc))
            continue
        missing = [
            key
            for key in (
                "entrant",
                "packet",
                "original_sha",
                "original_tree",
                "neutral_sha",
                "neutral_tree",
                "base_tree",
                "patch_hash",
                "result_hash",
            )
            if not nonempty_str(record.get(key))
        ]
        if missing:
            report.fail(check, f"capture record is missing: {', '.join(missing)}")
            continue
        if record.get("original_tree") != record.get("neutral_tree"):
            report.fail(check, "neutralisation changed the tree; capture and judging would bind different objects")
            continue
        key = (str(record.get("entrant")), str(record.get("packet")))
        if key in seen:
            report.fail(check, f"a second capture record claims {key[0]} on {key[1]}")
            continue
        seen.add(key)
        trees.add(str(record.get("original_tree")))
        report.ok(check, f"{key[0]} on {key[1]} bound to tree {str(record.get('original_tree'))[:12]}")
    report.require(
        len(trees) == len(seen) if seen else False,
        "evaluator.capture_binding",
        f"{len(trees)} distinct candidate trees carry {len(seen)} independent results",
        "capture records share a candidate tree; each head needs its own bound result",
    )
    planned = {
        (str(entrant.get("name", "")), str(packet.get("id", "")))
        for track in (plan.get("tracks") or {}).values()
        if isinstance(track, dict) and track.get("capture_required") is True
        for entrant in (track.get("entrants") or [])
        if isinstance(entrant, dict)
        for packet in (track.get("packets") or [])
        if isinstance(packet, dict)
    }
    missing = sorted(planned - seen)
    unexpected = sorted(seen - planned)
    render = lambda pairs: ", ".join(f"{entrant} on {packet}" for entrant, packet in pairs)
    report.require(
        not missing and not unexpected,
        "evaluator.capture_scope",
        f"capture records exactly cover all {len(planned)} planned candidate heads",
        "capture records do not match planned candidate heads: "
        + "; ".join(
            part
            for part in (
                f"missing {render(missing)}" if missing else "",
                f"unexpected {render(unexpected)}" if unexpected else "",
            )
            if part
        ),
    )


# --------------------------------------------------------------------------
# Archive, restore drill, and cleanup: correction 8. Cleanup is authorised only
# by a passing restore drill bound to the archive it actually verified.
# --------------------------------------------------------------------------


def archive_samples(root: Path) -> list[Path]:
    directory = root / "archive"
    if not directory.is_dir():
        return []
    return sorted(path for path in directory.iterdir() if path.is_dir() and (path / "manifest.json").is_file())


def check_archive(root: Path, plan: dict[str, Any], report: Report) -> tuple[bool, str]:
    """Verify every sample archive by recomputing its content addresses."""
    samples = archive_samples(root)
    expected = build_manifest(plan)["totals"]["scored_outputs"]
    ok = report.require(
        len(samples) == expected,
        "archive.coverage",
        f"{len(samples)} sample archives, one per scored output",
        f"expected {expected} sample archives, found {len(samples)}",
    )
    digests: list[str] = []
    for sample in samples:
        check = f"archive.{sample.name}"
        try:
            record = load_json(sample / "manifest.json", ARCHIVE_SCHEMA)
        except GateError as exc:
            report.fail(check, str(exc))
            ok = False
            continue
        groups = record.get("groups")
        files = record.get("files")
        binding = record.get("tree_binding")
        if not isinstance(groups, dict) or not isinstance(files, dict) or not isinstance(binding, dict):
            report.fail(check, "an archive manifest needs groups, files, and tree_binding objects")
            ok = False
            continue
        empty = [name for name in REQUIRED_ARCHIVE_GROUPS if not groups.get(name)]
        if empty:
            report.fail(check, f"archive groups are empty or absent: {', '.join(empty)}")
            ok = False
            continue
        bound_missing = [
            key
            for key in ("original_sha", "original_tree", "neutral_sha", "neutral_tree", "base_tree", "patch_hash")
            if not nonempty_str(binding.get(key))
        ]
        if bound_missing:
            report.fail(check, f"tree binding is incomplete: {', '.join(bound_missing)}")
            ok = False
            continue
        if binding.get("original_tree") != binding.get("neutral_tree"):
            report.fail(check, "neutralisation did not preserve the tree")
            ok = False
            continue
        listed = {name for names in groups.values() if isinstance(names, list) for name in names}
        unlisted = sorted(listed - set(files))
        if unlisted:
            report.fail(check, f"grouped files carry no content address: {', '.join(unlisted)}")
            ok = False
            continue
        bad: list[str] = []
        sample_root = sample.resolve()
        for relative in sorted(files, key=str):
            if not isinstance(relative, str):
                bad.append(f"{relative!r} (path is not a string)")
                continue
            target = (sample / relative).resolve()
            if not is_within(target, sample_root):
                bad.append(f"{relative} (escapes sample archive)")
                continue
            if not target.is_file():
                bad.append(f"{relative} (absent)")
            elif sha256_file(target) != files[relative]:
                bad.append(f"{relative} (hash mismatch)")
        if bad:
            report.fail(check, "content addresses do not match stored bytes: " + "; ".join(bad))
            ok = False
            continue
        digests.append(
            sha256_bytes(
                json.dumps(
                    {"sample": sample.name, "files": files, "manifest_sha256": sha256_file(sample / "manifest.json")},
                    sort_keys=True,
                ).encode("utf-8")
            )
        )
        report.ok(check, f"{len(files)} files verified across {len(REQUIRED_ARCHIVE_GROUPS)} evidence groups")
    return ok, sha256_bytes("".join(sorted(digests)).encode("utf-8"))


def run_git(args: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        ["git", *args],
        check=False,
        cwd=str(cwd) if cwd else None,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def rerun_archived_evaluator(sample: Path, record: dict[str, Any]) -> tuple[bool, str]:
    rerun = record.get("evaluator_rerun")
    if not isinstance(rerun, dict):
        return False, "archive manifest has no deterministic evaluator rerun"
    argv = rerun.get("argv")
    expected = rerun.get("result_hash")
    if not isinstance(argv, list) or len(argv) < 2 or not all(isinstance(item, str) and item for item in argv):
        return False, "archived evaluator argv must name an executable and an archived evaluator file"
    if not isinstance(expected, str) or re.fullmatch(r"[0-9a-f]{64}", expected) is None:
        return False, "archived evaluator result_hash must be a sha256 digest"
    evaluator = (sample / argv[1]).resolve()
    if not is_within(evaluator, sample.resolve()) or not evaluator.is_file():
        return False, "archived evaluator file escapes or is absent from its sample archive"
    try:
        completed = subprocess.run(argv, cwd=str(sample), stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    except OSError as exc:
        return False, f"archived evaluator could not execute: {exc}"
    if completed.returncode != 0:
        return False, f"archived evaluator exited {completed.returncode}"
    actual = sha256_bytes(completed.stdout)
    if actual != expected:
        return False, f"archived evaluator result hash {actual[:12]} does not match {expected[:12]}"
    return True, actual


def restore_drill(root: Path, plan: dict[str, Any], report: Report) -> None:
    """Restore each candidate bundle into a fresh repository and rebind its tree."""
    archive_ok, archive_digest = check_archive(root, plan, report)
    if shutil.which("git") is None:
        report.fail("restore.git", "git is required to restore and verify candidate bundles")
        return
    samples = archive_samples(root)
    drill_ok = archive_ok and bool(samples)
    receipt = root / "archive" / "restore-drill.json"
    if not archive_ok:
        receipt.unlink(missing_ok=True)
        return
    if not samples:
        report.fail("restore.scope", "no sample archive to restore")
    reran = 0
    for sample in samples:
        check = f"restore.{sample.name}"
        try:
            record = load_json(sample / "manifest.json", ARCHIVE_SCHEMA)
        except GateError as exc:
            report.fail(check, str(exc))
            drill_ok = False
            continue
        bundles = [
            name
            for name in (record.get("groups", {}).get("candidate_bundle_and_projection") or [])
            if str(name).endswith(".bundle")
        ]
        if not bundles:
            report.fail(check, "no candidate bundle in the archive; a projection alone cannot be rejudged")
            drill_ok = False
            continue
        binding = record.get("tree_binding", {})
        sample_ok = True
        for bundle_name in bundles:
            bundle = sample / bundle_name
            with tempfile.TemporaryDirectory(prefix="fm-bench-restore-") as workdir:
                fresh = Path(workdir) / "repo"
                init = run_git(["init", "--quiet", "--bare", str(fresh)])
                if init.returncode != 0:
                    report.fail(check, "could not create a fresh repository for the restore")
                    sample_ok = False
                    continue
                verify = run_git(["bundle", "verify", str(bundle)], cwd=fresh)
                if verify.returncode != 0:
                    report.fail(check, f"{bundle_name} failed `git bundle verify`")
                    sample_ok = False
                    continue
                fetch = run_git(["fetch", "--quiet", str(bundle), "*:refs/restored/*"], cwd=fresh)
                if fetch.returncode != 0:
                    report.fail(check, f"{bundle_name} could not be fetched into a fresh repository")
                    sample_ok = False
                    continue
                tree = run_git(["rev-parse", f"{binding.get('original_sha')}^{{tree}}"], cwd=fresh)
                if tree.returncode != 0:
                    report.fail(check, f"the archived head {binding.get('original_sha')} is not in {bundle_name}")
                    sample_ok = False
                    continue
                restored = tree.stdout.decode("utf-8", "replace").strip()
                if restored != binding.get("original_tree"):
                    report.fail(
                        check,
                        f"the restored tree {restored[:12]} does not match the archived binding "
                        f"{str(binding.get('original_tree'))[:12]}",
                    )
                    sample_ok = False
                    continue
        if not sample_ok:
            drill_ok = False
            continue
        reran_ok, rerun_detail = rerun_archived_evaluator(sample, record)
        if reran_ok:
            reran += 1
        else:
            report.fail(check, rerun_detail)
            drill_ok = False
            continue
        report.ok(check, "bundle verified, restored into a fresh repository, and rebound to its archived tree; archived evaluator rerun")

    ok = report.require(
        reran == len(samples) if samples else False,
        "restore.evaluator_rerun",
        f"{reran} archived deterministic evaluator results rerun from the archive",
        "every archived candidate needs a deterministic evaluator rerun",
    )
    drill_ok = drill_ok and ok
    if drill_ok:
        write_json(
            root / "archive" / "restore-drill.json",
            {
                "schema": DRILL_SCHEMA,
                "verdict": "pass",
                "archive_digest": archive_digest,
                "samples": len(samples),
            },
        )
        report.ok("restore.receipt", "restore drill receipt written; cleanup may now be authorised")
    else:
        receipt.unlink(missing_ok=True)
        report.fail("restore.receipt", "no receipt written; the archive is not restorable and cleanup stays refused")


def cleanup_gate(root: Path, plan: dict[str, Any], report: Report) -> None:
    path = root / "archive" / "restore-drill.json"
    if not path.is_file():
        report.fail("cleanup.drill", "no restore drill receipt; candidate and snapshot cleanup stays refused")
        return
    try:
        receipt = load_json(path, DRILL_SCHEMA)
    except GateError as exc:
        report.fail("cleanup.drill", str(exc))
        return
    if receipt.get("verdict") != "pass":
        report.fail("cleanup.drill", "the recorded restore drill did not pass")
        return
    quiet = Report("archive-recheck", quiet=True)
    _, digest = check_archive(root, plan, quiet)
    if quiet.failed:
        report.fail("cleanup.archive", f"the archive no longer verifies ({quiet.failed} failed checks)")
        return
    report.require(
        receipt.get("archive_digest") == digest,
        "cleanup.binding",
        "the receipt is bound to the archive as it stands now",
        "the archive changed after the restore drill; rerun the drill before cleanup",
    )
    report.require(
        plan.get("candidate_disposition") == "archive-then-discard",
        "cleanup.disposition",
        "every candidate is scrap once archived; no candidate ships directly",
        "the plan does not declare the archive-then-discard disposition",
    )


# --------------------------------------------------------------------------
# Promotion: corrections 1, 2, and 9 applied to recorded results.
# --------------------------------------------------------------------------


def load_results(root: Path) -> list[dict[str, Any]]:
    directory = root / "results"
    records: list[dict[str, Any]] = []
    if not directory.is_dir():
        return records
    for path in sorted(directory.glob("*.json")):
        record = load_json(path, RESULT_SCHEMA)
        record["_path"] = path.name
        records.append(record)
    return records


def promote_evaluate(root: Path, plan: dict[str, Any], report: Report) -> None:
    rule = plan.get("promotion_rule") or {}
    samples = int(plan.get("samples_per_entrant") or 0)
    baseline_samples = int(plan.get("samples_per_baseline") or 0)
    margin_bar = float(rule.get("practical_margin") or 0)
    try:
        results = load_results(root)
    except GateError as exc:
        report.fail("promote.results", str(exc))
        return
    if not results:
        report.fail("promote.results", "no recorded results; a benchmark with no samples promotes nothing")
        return

    for name in sorted(plan.get("tracks") or {}):
        track = plan["tracks"][name]
        if not isinstance(track, dict):
            continue
        promote_track(name, track, results, samples, baseline_samples, margin_bar, report)
    print("BENCH_NOTE promote no benchmark candidate ships directly; every candidate is archived then discarded")


def promote_track(
    name: str,
    track: dict[str, Any],
    results: list[dict[str, Any]],
    samples: int,
    baseline_samples: int,
    margin_bar: float,
    report: Report,
) -> None:
    prefix = f"promote.{name}"
    packet_ids = [str(item.get("id", "")) for item in (track.get("packets") or []) if isinstance(item, dict)]
    entrants = [str(item.get("name", "")) for item in (track.get("entrants") or []) if isinstance(item, dict)]
    baseline = track.get("baseline")
    baseline_name = str(baseline.get("name", "")) if isinstance(baseline, dict) else ""
    strata = [str(item) for item in (track.get("baseline_packets") or [])]

    track_results = [record for record in results if str(record.get("track")) == name]
    scored = [record for record in track_results if record.get("status") == "scored"]
    voided = [record for record in track_results if record.get("status") == "void"]
    if voided:
        report.fail(
            f"{prefix}.voids",
            f"{len(voided)} voided samples have no scored replacement; a void reruns the same approved sample",
        )

    complete = True
    for entrant in entrants:
        own = [record for record in scored if str(record.get("candidate")) == entrant and record.get("role") == "entrant"]
        packets = [str(record.get("packet")) for record in own]
        if len(own) > samples:
            report.fail(f"{prefix}.{entrant}.sample_count", f"{len(own)} scored samples exceed the approved {samples}; no adaptive extension")
            complete = False
        elif sorted(packets) != sorted(packet_ids) or len(set(packets)) != samples:
            report.fail(
                f"{prefix}.{entrant}.sample_count",
                f"needs one scored sample on each of {samples} distinct packets, has {sorted(packets)}",
            )
            complete = False
        else:
            report.ok(f"{prefix}.{entrant}.sample_count", f"{samples} scored samples across {samples} distinct packets")
    if baseline_name:
        own = [record for record in scored if str(record.get("candidate")) == baseline_name and record.get("role") == "baseline"]
        packets = sorted(str(record.get("packet")) for record in own)
        if packets != sorted(strata) or len(own) != baseline_samples:
            report.fail(f"{prefix}.baseline.sample_count", f"baseline needs {baseline_samples} samples on {sorted(strata)}, has {packets}")
            complete = False
        else:
            report.ok(f"{prefix}.baseline.sample_count", f"{baseline_samples} baseline samples on the preregistered strata")

    if not complete or voided:
        report.fail(f"{prefix}.verdict", "no standing route: the sample set is incomplete")
        return

    by_packet: dict[str, dict[str, float]] = {}
    blockers: set[str] = set()
    for record in scored:
        if record.get("role") != "entrant":
            continue
        composite = record.get("composite")
        if not isinstance(composite, (int, float)) or isinstance(composite, bool):
            report.fail(f"{prefix}.composite", f"{record.get('_path')} has no numeric composite")
            return
        by_packet.setdefault(str(record.get("packet")), {})[str(record.get("candidate"))] = float(composite)
        if record.get("blocker_class") is True:
            blockers.add(str(record.get("candidate")))

    sweepers = [
        entrant
        for entrant in entrants
        if all(
            scores.get(entrant) is not None and scores[entrant] == max(scores.values())
            and sum(1 for value in scores.values() if value == max(scores.values())) == 1
            for scores in by_packet.values()
        )
    ]
    if len(sweepers) != 1:
        report.fail(
            f"{prefix}.sweep",
            "no entrant ranks first on every packet; the result is a ranked benchmark, not a standing route",
        )
        report.fail(f"{prefix}.verdict", "no standing route")
        return
    winner = sweepers[0]
    report.ok(f"{prefix}.sweep", f"{winner} ranks first on all {samples} packets")

    if winner in blockers:
        report.fail(f"{prefix}.blocker", f"{winner} carries a blocker-class failure")
        report.fail(f"{prefix}.verdict", "no standing route")
        return
    report.ok(f"{prefix}.blocker", "no blocker-class failure on the sweeping entrant")

    margins = [
        scores[winner] - max(value for name_, value in scores.items() if name_ != winner)
        for scores in by_packet.values()
        if len(scores) > 1
    ]
    mean_margin = sum(margins) / len(margins) if margins else 0.0
    if not report.require(
        margins and mean_margin >= margin_bar,
        f"{prefix}.margin",
        f"mean paired margin {mean_margin:.3f} meets the predeclared bar {margin_bar}",
        f"mean paired margin {mean_margin:.3f} is below the predeclared bar {margin_bar}",
    ):
        report.fail(f"{prefix}.verdict", "no standing route")
        return

    if baseline_name and not baseline_veto_clear(prefix, winner, baseline_name, strata, scored, report):
        report.fail(f"{prefix}.verdict", "no standing route: the baseline regression veto fired")
        return

    report.ok(f"{prefix}.verdict", f"standing route eligible: {winner}, subject to the captain's explicit word")


def baseline_veto_clear(
    prefix: str, winner: str, baseline_name: str, strata: list[str], scored: list[dict[str, Any]], report: Report
) -> bool:
    deltas: list[float] = []
    losses = 0
    for packet in strata:
        entrant = next(
            (
                record
                for record in scored
                if str(record.get("packet")) == packet
                and str(record.get("candidate")) == winner
                and record.get("role") == "entrant"
            ),
            None,
        )
        base = next(
            (
                record
                for record in scored
                if str(record.get("packet")) == packet
                and str(record.get("candidate")) == baseline_name
                and record.get("role") == "baseline"
            ),
            None,
        )
        if entrant is None or base is None:
            report.fail(f"{prefix}.baseline_veto", f"no paired baseline comparison on {packet}")
            return False
        if base.get("blocker_class") is not True and entrant.get("blocker_class") is True:
            report.fail(f"{prefix}.baseline_veto", f"{winner} has a blocker on {packet} that the baseline avoided")
            return False
        delta = float(entrant["composite"]) - float(base["composite"])
        deltas.append(delta)
        if delta < 0:
            losses += 1
    mean_delta = sum(deltas) / len(deltas)
    if mean_delta < 0:
        report.fail(f"{prefix}.baseline_veto", f"mean quality delta against the baseline is {mean_delta:.3f}")
        return False
    if losses >= 2:
        report.fail(f"{prefix}.baseline_veto", f"{winner} loses {losses} of {len(strata)} baseline packets")
        return False
    report.ok(f"{prefix}.baseline_veto", f"no regression against the baseline (mean delta {mean_delta:.3f}, {losses} loss)")
    return True


# --------------------------------------------------------------------------
# Freeze and preflight: correction 9 and the launch answer.
# --------------------------------------------------------------------------


def frozen_inputs(root: Path, plan: dict[str, Any]) -> dict[str, str]:
    """Every input that must be fixed before labels are assigned."""
    hashes: dict[str, str] = {"benchmark.json": sha256_file(root / "benchmark.json")}
    for relative in ("packets", "ground-truth", "scoring", "judge-prompts"):
        directory = root / relative
        if not directory.is_dir():
            continue
        for path in sorted(directory.rglob("*")):
            if path.is_file():
                hashes[str(path.relative_to(root))] = sha256_file(path)
    tuples = [
        f"{name}:{candidate.get('harness')}/{candidate.get('model')}@{candidate.get('effort')}"
        for name in sorted(plan.get("tracks") or {})
        if isinstance(plan["tracks"][name], dict)
        for candidate in track_candidates(plan["tracks"][name])
    ]
    hashes["<model-tuples>"] = sha256_bytes("\n".join(sorted(tuples)).encode("utf-8"))
    hashes["<seed>"] = sha256_bytes(str(plan.get("randomisation_seed")).encode("utf-8"))
    hashes["<failure-policy>"] = sha256_bytes(
        json.dumps(plan.get("failure_policy"), sort_keys=True).encode("utf-8")
    )
    return hashes


def freeze(root: Path, plan: dict[str, Any], report: Report) -> None:
    if (root / "key.json").exists():
        report.fail("freeze.before_labels", "key.json already exists; the freeze must precede label assignment")
        return
    hashes = frozen_inputs(root, plan)
    write_json(root / "freeze.json", {"schema": FREEZE_SCHEMA, "hashes": hashes})
    report.ok("freeze.written", f"{len(hashes)} inputs frozen before any label was assigned")


def check_freeze(root: Path, plan: dict[str, Any], report: Report) -> None:
    path = root / "freeze.json"
    if not path.is_file():
        report.fail("freeze.present", "freeze.json is absent; freeze every input before assigning labels")
        return
    try:
        record = load_json(path, FREEZE_SCHEMA)
    except GateError as exc:
        report.fail("freeze.present", str(exc))
        return
    stored = record.get("hashes")
    if not isinstance(stored, dict):
        report.fail("freeze.present", "freeze.json carries no hash map")
        return
    current = frozen_inputs(root, plan)
    changed = sorted(key for key in set(stored) | set(current) if stored.get(key) != current.get(key))
    report.require(
        not changed,
        "freeze.intact",
        f"all {len(current)} frozen inputs are unchanged",
        f"frozen inputs changed after the freeze: {', '.join(changed[:8])}",
    )


PREFLIGHT_STAGES = (
    "plan",
    "freeze",
    "provenance",
    "isolation",
    "evaluator",
    "manifest",
)


def preflight(root: Path, plan: dict[str, Any], report: Report, timeout: int) -> None:
    check_plan(plan, report)
    check_freeze(root, plan, report)
    check_provenance(root, plan, report)
    check_isolation(root, report, timeout)
    check_evaluator(root, plan, report)
    check_manifest(root, plan, report)
    receipt = root / "preflight.receipt"
    if report.captain_stop or report.failed:
        revoked = receipt.is_file()
        receipt.unlink(missing_ok=True)
        if revoked:
            print("BENCH_NOTE preflight the prior clearance is revoked")
        if report.captain_stop:
            print("BENCH_NOTE preflight a captain call is open; entrants stay held")
        else:
            print("BENCH_NOTE preflight no entrant may launch")
    else:
        write_json(
            receipt,
            {
                "schema": RECEIPT_SCHEMA,
                "verdict": "pass",
                "plan_sha256": sha256_file(root / "benchmark.json"),
                "isolation_sha256": sha256_file(root / "isolation.json"),
                "stages": list(PREFLIGHT_STAGES),
            },
        )
        print("BENCH_NOTE preflight entrants may launch")


# --------------------------------------------------------------------------
# Command line
# --------------------------------------------------------------------------


def resolve_root(value: str | None) -> Path:
    candidate = value or os.environ.get("FM_BENCH_ROOT")
    if not candidate:
        raise GateError("no benchmark directory: pass --bench <dir> or set FM_BENCH_ROOT")
    root = Path(candidate).expanduser()
    if not root.is_dir():
        raise GateError(f"benchmark directory does not exist: {root}")
    return root.resolve()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="fm-bench-gate.sh",
        description=(
            "Model-routing benchmark gates. Every gate recomputes its evidence: "
            "hashes are recomputed, counts are derived from the plan, isolation probes are run, "
            "and archives are actually restored. Exit 0 pass, 1 refused, 2 usage, 3 captain-stop."
        ),
        epilog=(
            "Benchmark directory layout: benchmark.json (the frozen plan), packets/, ground-truth/, "
            "scoring/, judge-prompts/, provenance/<packet>.json, isolation.json, allowance.json, "
            "evaluator/{lock.json,score-map.json,determinism/,mutations/,captures/}, manifest.json, "
            "freeze.json, results/<sample>.json, archive/<sample>/manifest.json, and the generated "
            "preflight.receipt and archive/restore-drill.json."
        ),
    )
    parser.add_argument("--bench", help="benchmark directory (default: $FM_BENCH_ROOT)")
    parser.add_argument(
        "--probe-timeout",
        type=int,
        default=60,
        help="seconds an isolation probe may run before it is inconclusive (default 60)",
    )
    parser.add_argument(
        "subcommand",
        choices=[
            "plan-check",
            "provenance-check",
            "isolation-verify",
            "evaluator-verify",
            "manifest-build",
            "manifest-check",
            "freeze",
            "freeze-check",
            "preflight",
            "archive-verify",
            "restore-drill",
            "cleanup-gate",
            "promote-evaluate",
        ],
        help="the gate to run",
    )
    return parser


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)
    try:
        root = resolve_root(args.bench)
        plan = load_json(root / "benchmark.json", PLAN_SCHEMA)
    except GateError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return EXIT_USAGE

    report = Report(args.subcommand)
    try:
        if args.subcommand == "plan-check":
            check_plan(plan, report)
        elif args.subcommand == "provenance-check":
            check_provenance(root, plan, report)
        elif args.subcommand == "isolation-verify":
            check_isolation(root, report, args.probe_timeout)
        elif args.subcommand == "evaluator-verify":
            check_evaluator(root, plan, report)
        elif args.subcommand == "manifest-build":
            manifest = build_manifest(plan)
            manifest["plan_sha256"] = sha256_file(root / "benchmark.json")
            write_json(root / "manifest.json", manifest)
            report.ok("manifest.built", f"manifest.json written for {manifest['totals']['total_model_jobs']} model jobs")
        elif args.subcommand == "manifest-check":
            check_manifest(root, plan, report)
        elif args.subcommand == "freeze":
            freeze(root, plan, report)
        elif args.subcommand == "freeze-check":
            check_freeze(root, plan, report)
        elif args.subcommand == "preflight":
            preflight(root, plan, report, args.probe_timeout)
        elif args.subcommand == "archive-verify":
            check_archive(root, plan, report)
        elif args.subcommand == "restore-drill":
            restore_drill(root, plan, report)
        elif args.subcommand == "cleanup-gate":
            cleanup_gate(root, plan, report)
        elif args.subcommand == "promote-evaluate":
            promote_evaluate(root, plan, report)
    except GateError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return EXIT_USAGE
    return report.finish()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
