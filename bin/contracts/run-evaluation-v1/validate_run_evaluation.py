#!/usr/bin/env python3
"""Validate neutral RunEvaluation v1 and its redacted Cockpit export."""

from __future__ import annotations

import argparse
from datetime import datetime
import hashlib
import json
import math
from pathlib import Path
import re
import sys
from typing import Any, Iterable


EVALUATION_SCHEMA_VERSION = "governance.run-evaluation.v1"
EXPORT_SCHEMA_VERSION = "governance.cockpit-run-evaluation-export.v1"
EVALUATION_KIND = "run_evaluation"
EXPORT_KIND = "cockpit_run_evaluation_export"

DIMENSION_NAMES = (
    "quality",
    "reliability",
    "cost",
    "duration",
    "reviewEffort",
    "policyViolations",
)
COMPARISON_NAMES = ("model", "executionHarness", "fullRoute")
TASK_CLASSES = (
    "analysis_planning",
    "summary_documentation",
    "coding",
    "code_review",
)
DATA_CLASS_ORDER = (
    "synthetic",
    "public",
    "internal_non_sensitive",
    "sensitive",
    "production",
)
EXPORT_DATA_CLASSES = frozenset(DATA_CLASS_ORDER[:3])
MEASUREMENT_QUALITIES = ("exact", "estimated", "unavailable")
IDENTITY_SOURCES = ("requested", "launched", "provider_confirmed")
EVIDENCE_KINDS = ("artifact", "log", "metric")
VISIBILITIES = ("home_only", "operator_requested", "surface_labelled")
EVALUATION_STATES = ("assessed", "partial", "unassessable", "invalid")
EXPORT_STATES = EVALUATION_STATES[:-1]

EXPORT_STALE_AFTER_SECONDS = 300
EXPORT_MAX_RECORDS = 100
EXPORT_MAX_BYTES = 262_144

IDENTIFIER = re.compile(
    r"^(?![A-Za-z]:)[A-Za-z0-9][A-Za-z0-9._:-]*(?:/[A-Za-z0-9][A-Za-z0-9._:-]*)*$"
)
IDENTIFIER_MAX_LENGTH = 128
DIGEST = re.compile(r"^sha256:[a-f0-9]{64}$")
EVIDENCE_REF = re.compile(
    r"^[A-Za-z0-9][A-Za-z0-9._-]*(?:/[A-Za-z0-9][A-Za-z0-9._-]*)*$"
)
EVIDENCE_REF_MAX_LENGTH = 512
CREDENTIAL_SHAPE = re.compile(
    r"(?i)(?:secret|token|password|passwd|credential|api[_-]?key|access[_-]?key|authorization|bearer)"
    r"[\"'\s]*[:=]?[\s\-_]*[A-Za-z0-9+=]{24,}"
)

EVALUATION_FIELDS = frozenset(
    {
        "schemaVersion",
        "kind",
        "evaluationId",
        "evaluatedAt",
        "scoringProfile",
        "derivedFrom",
        "contextAxes",
        "subject",
        "identityKeys",
        "dimensions",
        "comparisons",
        "state",
        "dataClass",
        "freshness",
        "retention",
        "routingApplied",
    }
)
EXPORT_FIELDS = frozenset(
    {
        "schemaVersion",
        "kind",
        "generatedAt",
        "source",
        "freshness",
        "retention",
        "records",
        "withheld",
    }
)
PROFILE_FIELDS = frozenset(
    {
        "id",
        "version",
        "digest",
        "benchmarkId",
        "benchmarkRevision",
        "caseSetDigest",
        "metricId",
        "metricVersion",
        "normalizationPolicyDigest",
        "evaluatorName",
        "evaluatorVersion",
        "evaluatorDigest",
    }
)
PROFILE_REF_FIELDS = frozenset({"id", "version", "digest"})
AXIS_FIELDS = frozenset({"schemeId", "schemeVersion", "value"})
CONTEXT_AXIS_FIELDS = frozenset(
    {
        "taskClass",
        "dataClassification",
        "executionEnvironment",
        "inputTrust",
        "externalEffect",
        "approvalAuthority",
    }
)
MODEL_FIELDS = frozenset({"provider", "modelId", "effort", "identitySource"})
HARNESS_FIELDS = frozenset({"name", "version", "mode", "surface"})
ROUTE_FIELDS = frozenset(
    {
        "routeRef",
        "routingPolicyVersion",
        "permissionProfileRef",
        "dispatcherAdapter",
        "dispatcherAdapterVersion",
    }
)
IDENTITY_KEY_FIELDS = frozenset(
    {"modelKey", "executionHarnessKey", "routeFrameKey", "fullRouteKey", "taskContextKey"}
)
DIMENSION_FIELDS = frozenset(
    {
        "measurementQuality",
        "raw",
        "normalized",
        "uncertainty",
        "basisRefs",
        "evidenceRefs",
        "reasonCodes",
    }
)
COMPARISON_FIELDS = frozenset({"eligibility", "candidateKey", "cohortKey", "reasonCodes"})
EVIDENCE_FIELDS = frozenset({"ref", "kind", "dataClass", "visibility"})


def finding(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def is_integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def is_number(value: Any) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
    )


def is_identifier(value: Any) -> bool:
    return (
        isinstance(value, str)
        and len(value) <= IDENTIFIER_MAX_LENGTH
        and bool(IDENTIFIER.fullmatch(value))
    )


def is_digest(value: Any) -> bool:
    return isinstance(value, str) and bool(DIGEST.fullmatch(value))


def canonical_digest(kind: str, value: Any) -> str:
    payload = json.dumps(
        {"kind": kind, "value": value},
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return "sha256:" + hashlib.sha256(payload).hexdigest()


def reject_nonstandard_number(value: str) -> None:
    raise ValueError(f"Nichtstandardisierte Zahl {value}")


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Doppelter Objektschlüssel {key}")
        result[key] = value
    return result


def expected_profile_digest(profile: dict[str, Any]) -> str:
    return canonical_digest(
        "scoring-profile.v1",
        {name: profile[name] for name in sorted(PROFILE_FIELDS - {"digest"})},
    )


def expected_identity_keys(document: dict[str, Any]) -> dict[str, str]:
    subject = document["subject"]
    axes = document["contextAxes"]
    model = subject["model"]
    model_key = canonical_digest(
        "model.v1",
        {name: model[name] for name in ("provider", "modelId", "effort")},
    )
    harness_key = canonical_digest("execution-harness.v1", subject["executionHarness"])
    route_frame_key = canonical_digest(
        "route-frame.v1",
        {
            "route": subject["route"],
            "executionEnvironment": axes["executionEnvironment"],
            "externalEffect": axes["externalEffect"],
            "approvalAuthority": axes["approvalAuthority"],
        },
    )
    full_route_key = canonical_digest(
        "full-route.v1",
        {
            "routeFrameKey": route_frame_key,
            "modelKey": model_key,
            "executionHarnessKey": harness_key,
        },
    )
    task_context_key = canonical_digest("task-context.v1", axes)
    return {
        "modelKey": model_key,
        "executionHarnessKey": harness_key,
        "routeFrameKey": route_frame_key,
        "fullRouteKey": full_route_key,
        "taskContextKey": task_context_key,
    }


def expected_comparison_keys(
    identity_keys: dict[str, str], scoring_profile_digest: str
) -> dict[str, dict[str, str]]:
    return {
        "model": {
            "candidateKey": identity_keys["modelKey"],
            "cohortKey": canonical_digest(
                "model-cohort.v1",
                {
                    "taskContextKey": identity_keys["taskContextKey"],
                    "executionHarnessKey": identity_keys["executionHarnessKey"],
                    "routeFrameKey": identity_keys["routeFrameKey"],
                    "scoringProfileDigest": scoring_profile_digest,
                },
            ),
        },
        "executionHarness": {
            "candidateKey": identity_keys["executionHarnessKey"],
            "cohortKey": canonical_digest(
                "execution-harness-cohort.v1",
                {
                    "taskContextKey": identity_keys["taskContextKey"],
                    "modelKey": identity_keys["modelKey"],
                    "routeFrameKey": identity_keys["routeFrameKey"],
                    "scoringProfileDigest": scoring_profile_digest,
                },
            ),
        },
        "fullRoute": {
            "candidateKey": identity_keys["fullRouteKey"],
            "cohortKey": canonical_digest(
                "full-route-cohort.v1",
                {
                    "taskContextKey": identity_keys["taskContextKey"],
                    "scoringProfileDigest": scoring_profile_digest,
                },
            ),
        },
    }


def _object(
    value: Any,
    path: str,
    allowed: Iterable[str],
    required: Iterable[str],
    code: str,
    findings: list[dict[str, str]],
) -> dict[str, Any] | None:
    if not isinstance(value, dict):
        findings.append(finding(code, path, "Wert muss ein Objekt sein."))
        return None
    allowed_set = frozenset(allowed)
    required_set = frozenset(required)
    unexpected = sorted(set(value) - allowed_set)
    missing = sorted(required_set - set(value))
    if unexpected:
        findings.append(finding(code, path, f"Unerwartete Felder: {', '.join(unexpected)}"))
    if missing:
        findings.append(finding(code, path, f"Pflichtfelder fehlen: {', '.join(missing)}"))
    return value


def _identifier(value: Any, path: str, code: str, findings: list[dict[str, str]]) -> None:
    if not is_identifier(value):
        findings.append(finding(code, path, "Wert muss eine begrenzte technische Kennung sein."))


def _digest(value: Any, path: str, code: str, findings: list[dict[str, str]]) -> None:
    if not is_digest(value):
        findings.append(finding(code, path, "Wert muss ein sha256-Digest sein."))


def _positive_integer(
    value: Any, path: str, code: str, findings: list[dict[str, str]], minimum: int = 1
) -> None:
    if not is_integer(value) or value < minimum:
        findings.append(finding(code, path, f"Wert muss eine ganze Zahl ab {minimum} sein."))


def _date_time(value: Any, path: str, code: str, findings: list[dict[str, str]]) -> None:
    if not isinstance(value, str) or not value.endswith("Z"):
        findings.append(finding(code, path, "Zeitstempel muss UTC mit abschließendem Z sein."))
        return
    try:
        datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError:
        findings.append(finding(code, path, "Zeitstempel ist nicht ISO-8601-konform."))


def _identifier_array(
    value: Any,
    path: str,
    findings: list[dict[str, str]],
    *,
    minimum: int = 0,
    code: str = "identifier_list_invalid",
) -> list[Any] | None:
    if not isinstance(value, list) or len(value) < minimum:
        findings.append(finding(code, path, f"Wert muss eine Liste mit mindestens {minimum} Elementen sein."))
        return None
    if len(value) != len({json.dumps(item, sort_keys=True) for item in value}):
        findings.append(finding(code, path, "Liste darf keine Duplikate enthalten."))
    for index, item in enumerate(value):
        _identifier(item, f"{path}/{index}", code, findings)
    return value


def _validate_axis(value: Any, path: str, findings: list[dict[str, str]]) -> None:
    axis = _object(value, path, AXIS_FIELDS, AXIS_FIELDS, "axis_invalid", findings)
    if axis is None:
        return
    _identifier(axis.get("schemeId"), f"{path}/schemeId", "axis_invalid", findings)
    _positive_integer(axis.get("schemeVersion"), f"{path}/schemeVersion", "axis_invalid", findings)
    _identifier(axis.get("value"), f"{path}/value", "axis_invalid", findings)


def _validate_profile(
    value: Any, path: str, findings: list[dict[str, str]], *, reference_only: bool = False
) -> None:
    fields = PROFILE_REF_FIELDS if reference_only else PROFILE_FIELDS
    profile = _object(value, path, fields, fields, "scoring_profile_invalid", findings)
    if profile is None:
        return
    _identifier(profile.get("id"), f"{path}/id", "scoring_profile_invalid", findings)
    _positive_integer(profile.get("version"), f"{path}/version", "scoring_profile_invalid", findings)
    _digest(profile.get("digest"), f"{path}/digest", "scoring_profile_invalid", findings)
    if reference_only:
        return
    for name in ("benchmarkId", "metricId", "metricVersion", "evaluatorName", "evaluatorVersion"):
        _identifier(profile.get(name), f"{path}/{name}", "scoring_profile_invalid", findings)
    _positive_integer(
        profile.get("benchmarkRevision"),
        f"{path}/benchmarkRevision",
        "scoring_profile_invalid",
        findings,
    )
    _digest(profile.get("caseSetDigest"), f"{path}/caseSetDigest", "scoring_profile_invalid", findings)
    _digest(
        profile.get("normalizationPolicyDigest"),
        f"{path}/normalizationPolicyDigest",
        "scoring_profile_invalid",
        findings,
    )
    _digest(
        profile.get("evaluatorDigest"),
        f"{path}/evaluatorDigest",
        "scoring_profile_invalid",
        findings,
    )
    if set(profile) == PROFILE_FIELDS and all(name in profile for name in PROFILE_FIELDS):
        try:
            expected = expected_profile_digest(profile)
            if profile.get("digest") != expected:
                findings.append(
                    finding(
                        "scoring_profile_digest_mismatch",
                        f"{path}/digest",
                        "Profil-Digest stimmt nicht mit der kanonischen Profilidentität überein.",
                    )
                )
        except (KeyError, TypeError, ValueError):
            pass


def _validate_subject(
    value: Any, path: str, findings: list[dict[str, str]], *, export_mode: bool = False
) -> None:
    subject = _object(value, path, {"model", "executionHarness", "route"}, {"model", "executionHarness", "route"}, "subject_invalid", findings)
    if subject is None:
        return

    model = _object(subject.get("model"), f"{path}/model", MODEL_FIELDS, MODEL_FIELDS, "model_subject_invalid", findings)
    if model is not None:
        for name in ("provider", "modelId"):
            _identifier(model.get(name), f"{path}/model/{name}", "model_subject_invalid", findings)
        effort = model.get("effort")
        if effort is not None:
            _identifier(effort, f"{path}/model/effort", "model_subject_invalid", findings)
        if model.get("identitySource") not in IDENTITY_SOURCES:
            findings.append(finding("model_subject_invalid", f"{path}/model/identitySource", "Unbekannte Identitätsquelle."))

    harness = _object(subject.get("executionHarness"), f"{path}/executionHarness", HARNESS_FIELDS, HARNESS_FIELDS, "execution_harness_invalid", findings)
    if harness is not None:
        for name in HARNESS_FIELDS:
            _identifier(harness.get(name), f"{path}/executionHarness/{name}", "execution_harness_invalid", findings)

    route_fields = frozenset({"routeRef"}) if export_mode else ROUTE_FIELDS
    route = _object(subject.get("route"), f"{path}/route", route_fields, route_fields, "route_subject_invalid", findings)
    if route is not None:
        _identifier(route.get("routeRef"), f"{path}/route/routeRef", "route_subject_invalid", findings)
        if not export_mode:
            _positive_integer(route.get("routingPolicyVersion"), f"{path}/route/routingPolicyVersion", "route_subject_invalid", findings)
            for name in ("permissionProfileRef", "dispatcherAdapter", "dispatcherAdapterVersion"):
                _identifier(route.get(name), f"{path}/route/{name}", "route_subject_invalid", findings)


def _validate_identity_keys(value: Any, path: str, findings: list[dict[str, str]]) -> None:
    keys = _object(value, path, IDENTITY_KEY_FIELDS, IDENTITY_KEY_FIELDS, "identity_keys_invalid", findings)
    if keys is None:
        return
    for name in IDENTITY_KEY_FIELDS:
        _digest(keys.get(name), f"{path}/{name}", "identity_keys_invalid", findings)


def _validate_evidence(
    value: Any,
    path: str,
    evaluation_data_class: Any,
    findings: list[dict[str, str]],
    *,
    export_mode: bool,
) -> None:
    evidence = _object(value, path, EVIDENCE_FIELDS, EVIDENCE_FIELDS, "evidence_ref_invalid", findings)
    if evidence is None:
        return
    ref = evidence.get("ref")
    if (
        not isinstance(ref, str)
        or len(ref) > EVIDENCE_REF_MAX_LENGTH
        or not EVIDENCE_REF.fullmatch(ref)
    ):
        findings.append(finding("evidence_ref_invalid", f"{path}/ref", "Evidenzreferenz muss relativ und begrenzt sein."))
    elif CREDENTIAL_SHAPE.search(ref):
        findings.append(finding("credential_shaped_value", f"{path}/ref", "Evidenzreferenz wirkt wie ein Geheimnis."))
    if evidence.get("kind") not in EVIDENCE_KINDS:
        findings.append(finding("evidence_ref_invalid", f"{path}/kind", "Unbekannte Evidenzart."))
    data_class = evidence.get("dataClass")
    if data_class not in DATA_CLASS_ORDER:
        findings.append(finding("evidence_ref_invalid", f"{path}/dataClass", "Unbekannte Datenklasse."))
    visibility = evidence.get("visibility")
    if visibility not in VISIBILITIES:
        findings.append(finding("evidence_ref_invalid", f"{path}/visibility", "Unbekannte Sichtbarkeit."))

    if data_class in DATA_CLASS_ORDER and evaluation_data_class in DATA_CLASS_ORDER:
        if DATA_CLASS_ORDER.index(data_class) > DATA_CLASS_ORDER.index(evaluation_data_class):
            findings.append(finding("evidence_class_exceeds_evaluation", f"{path}/dataClass", "Evidenzklasse übersteigt die Evaluationsklasse."))
    if data_class in {"sensitive", "production"} and visibility != "home_only":
        findings.append(finding("sensitive_evidence_left_home", f"{path}/visibility", "Sensible oder produktive Evidenz muss home_only bleiben."))
    if export_mode:
        if data_class not in EXPORT_DATA_CLASSES:
            findings.append(finding("export_evidence_class_blocked", f"{path}/dataClass", "Datenklasse ist im Cockpit-Export gesperrt."))
        if visibility != "surface_labelled":
            findings.append(finding("export_evidence_visibility_blocked", f"{path}/visibility", "Cockpit-Evidenz muss surface_labelled sein."))


def _validate_dimension(
    value: Any,
    path: str,
    evaluation_data_class: Any,
    findings: list[dict[str, str]],
    *,
    export_mode: bool,
) -> str | None:
    dimension = _object(value, path, DIMENSION_FIELDS, DIMENSION_FIELDS, "dimension_invalid", findings)
    if dimension is None:
        return None
    quality = dimension.get("measurementQuality")
    if quality not in MEASUREMENT_QUALITIES:
        findings.append(finding("dimension_quality_invalid", f"{path}/measurementQuality", "Unbekannte Messqualität."))

    raw = _object(dimension.get("raw"), f"{path}/raw", {"value", "unit"}, {"value", "unit"}, "dimension_raw_invalid", findings)
    raw_value = raw.get("value") if raw is not None else None
    if raw is not None:
        _identifier(raw.get("unit"), f"{path}/raw/unit", "dimension_raw_invalid", findings)

    normalized = dimension.get("normalized")
    if quality == "unavailable":
        if raw_value is not None or normalized is not None:
            findings.append(finding("unavailable_dimension_has_value", path, "Fehlende Messwerte müssen null bleiben und dürfen nicht als 0 erscheinen."))
    elif quality in {"exact", "estimated"}:
        if not is_number(raw_value) or raw_value < 0:
            findings.append(finding("dimension_raw_invalid", f"{path}/raw/value", "Verfügbarer Rohwert muss eine nichtnegative Zahl sein."))
        if not is_number(normalized) or not 0 <= normalized <= 1:
            findings.append(finding("dimension_normalized_invalid", f"{path}/normalized", "Normalisierter Wert muss zwischen 0 und 1 liegen."))

    uncertainty = _object(dimension.get("uncertainty"), f"{path}/uncertainty", {"value", "quality"}, {"value", "quality"}, "uncertainty_invalid", findings)
    if uncertainty is not None:
        uncertainty_quality = uncertainty.get("quality")
        uncertainty_value = uncertainty.get("value")
        if uncertainty_quality not in MEASUREMENT_QUALITIES:
            findings.append(finding("uncertainty_invalid", f"{path}/uncertainty/quality", "Unbekannte Unsicherheitsqualität."))
        elif uncertainty_quality == "unavailable":
            if uncertainty_value is not None:
                findings.append(finding("uncertainty_invalid", f"{path}/uncertainty/value", "Nicht verfügbare Unsicherheit muss null sein."))
        elif not is_number(uncertainty_value) or not 0 <= uncertainty_value <= 1:
            findings.append(finding("uncertainty_invalid", f"{path}/uncertainty/value", "Unsicherheit muss zwischen 0 und 1 liegen."))

    _identifier_array(dimension.get("basisRefs"), f"{path}/basisRefs", findings, minimum=1)
    reasons = _identifier_array(dimension.get("reasonCodes"), f"{path}/reasonCodes", findings)
    if quality == "unavailable" and isinstance(reasons, list) and not reasons:
        findings.append(finding("unavailable_dimension_reason_missing", f"{path}/reasonCodes", "Nicht verfügbare Dimension braucht einen Grundcode."))

    evidence_refs = dimension.get("evidenceRefs")
    if not isinstance(evidence_refs, list):
        findings.append(finding("evidence_refs_invalid", f"{path}/evidenceRefs", "Evidenz muss eine Liste sein."))
    else:
        if quality == "exact" and not evidence_refs:
            findings.append(finding("exact_dimension_missing_evidence", f"{path}/evidenceRefs", "Exakte Dimension braucht mindestens eine Evidenzreferenz."))
        for index, evidence in enumerate(evidence_refs):
            _validate_evidence(
                evidence,
                f"{path}/evidenceRefs/{index}",
                evaluation_data_class,
                findings,
                export_mode=export_mode,
            )
    return quality if quality in MEASUREMENT_QUALITIES else None


def _validate_dimensions(
    value: Any,
    path: str,
    data_class: Any,
    findings: list[dict[str, str]],
    *,
    export_mode: bool,
) -> dict[str, str | None]:
    dimensions = _object(value, path, DIMENSION_NAMES, DIMENSION_NAMES, "dimensions_invalid", findings)
    qualities: dict[str, str | None] = {}
    if dimensions is None:
        return qualities
    for name in DIMENSION_NAMES:
        qualities[name] = _validate_dimension(
            dimensions.get(name),
            f"{path}/{name}",
            data_class,
            findings,
            export_mode=export_mode,
        )
    return qualities


def _validate_comparisons(value: Any, path: str, findings: list[dict[str, str]]) -> None:
    comparisons = _object(value, path, COMPARISON_NAMES, COMPARISON_NAMES, "comparisons_invalid", findings)
    if comparisons is None:
        return
    for name in COMPARISON_NAMES:
        comparison = _object(
            comparisons.get(name),
            f"{path}/{name}",
            COMPARISON_FIELDS,
            COMPARISON_FIELDS,
            "comparison_invalid",
            findings,
        )
        if comparison is None:
            continue
        eligibility = comparison.get("eligibility")
        if eligibility not in {"eligible", "ineligible"}:
            findings.append(finding("comparison_invalid", f"{path}/{name}/eligibility", "Unbekannter Vergleichszustand."))
        reasons = _identifier_array(comparison.get("reasonCodes"), f"{path}/{name}/reasonCodes", findings)
        if eligibility == "eligible":
            _digest(comparison.get("candidateKey"), f"{path}/{name}/candidateKey", "comparison_invalid", findings)
            _digest(comparison.get("cohortKey"), f"{path}/{name}/cohortKey", "comparison_invalid", findings)
            if isinstance(reasons, list) and reasons:
                findings.append(finding("eligible_comparison_has_reason", f"{path}/{name}/reasonCodes", "Zulässiger Vergleich darf keinen Sperrgrund tragen."))
        elif eligibility == "ineligible":
            if comparison.get("candidateKey") is not None or comparison.get("cohortKey") is not None:
                findings.append(finding("ineligible_comparison_has_key", f"{path}/{name}", "Unzulässiger Vergleich darf keinen Kandidaten- oder Kohortenschlüssel tragen."))
            if isinstance(reasons, list) and not reasons:
                findings.append(finding("ineligible_comparison_reason_missing", f"{path}/{name}/reasonCodes", "Unzulässiger Vergleich braucht einen Grundcode."))


def _expected_state(qualities: dict[str, str | None]) -> str | None:
    if set(qualities) != set(DIMENSION_NAMES) or any(value is None for value in qualities.values()):
        return None
    available = sum(value != "unavailable" for value in qualities.values())
    if available == len(DIMENSION_NAMES):
        return "assessed"
    if available == 0:
        return "unassessable"
    return "partial"


def _validate_state(
    value: Any,
    path: str,
    qualities: dict[str, str | None],
    findings: list[dict[str, str]],
    *,
    export_mode: bool,
) -> str | None:
    state = _object(value, path, {"status", "reasonCodes"}, {"status", "reasonCodes"}, "state_invalid", findings)
    if state is None:
        return None
    allowed = EXPORT_STATES if export_mode else EVALUATION_STATES
    status = state.get("status")
    if status not in allowed:
        findings.append(finding("state_invalid", f"{path}/status", "Unbekannter Evaluationszustand."))
        return None
    reasons = _identifier_array(state.get("reasonCodes"), f"{path}/reasonCodes", findings)
    expected = _expected_state(qualities)
    if status != "invalid" and expected is not None and status != expected:
        findings.append(finding("state_coverage_mismatch", f"{path}/status", f"Dimensionsabdeckung verlangt den Zustand {expected}."))
    if status == "assessed" and isinstance(reasons, list) and reasons:
        findings.append(finding("assessed_state_has_reason", f"{path}/reasonCodes", "Vollständig bewerteter Zustand darf keinen Fehlergrund tragen."))
    if status != "assessed" and isinstance(reasons, list) and not reasons:
        findings.append(finding("state_reason_missing", f"{path}/reasonCodes", "Unvollständiger oder ungültiger Zustand braucht einen Grundcode."))
    return status


def _validate_comparison_relationships(
    comparisons: Any,
    identity_keys: Any,
    expected: dict[str, dict[str, str]] | None,
    model_source: Any,
    state: str | None,
    findings: list[dict[str, str]],
    *,
    export_mode: bool,
) -> None:
    if not isinstance(comparisons, dict) or not isinstance(identity_keys, dict):
        return
    confirmed = model_source == "provider_confirmed"
    state_allows = state in {"assessed", "partial"}
    for name in COMPARISON_NAMES:
        comparison = comparisons.get(name)
        if not isinstance(comparison, dict):
            continue
        if (not confirmed or not state_allows) and comparison.get("eligibility") == "eligible":
            code = "model_comparison_requires_confirmed_identity" if not confirmed else "comparison_state_ineligible"
            findings.append(finding(code, f"/comparisons/{name}/eligibility", "Vergleich ist ohne bestätigte Modellidentität und bewertbaren Zustand unzulässig."))
            continue
        if comparison.get("eligibility") != "eligible":
            if not confirmed and "model_identity_unconfirmed" not in comparison.get("reasonCodes", []):
                findings.append(finding("model_identity_reason_missing", f"/comparisons/{name}/reasonCodes", "Unbestätigte Modellidentität muss als Sperrgrund reisen."))
            continue

        candidate_expected = {
            "model": identity_keys.get("modelKey"),
            "executionHarness": identity_keys.get("executionHarnessKey"),
            "fullRoute": identity_keys.get("fullRouteKey"),
        }[name]
        if comparison.get("candidateKey") != candidate_expected:
            findings.append(finding("comparison_candidate_mismatch", f"/comparisons/{name}/candidateKey", "Kandidatenschlüssel stimmt nicht mit der getrennten Identität überein."))
        if not export_mode and expected is not None:
            expected_values = expected[name]
            if comparison.get("candidateKey") != expected_values["candidateKey"]:
                findings.append(finding("comparison_candidate_digest_mismatch", f"/comparisons/{name}/candidateKey", "Kandidatenschlüssel ist nicht kanonisch berechnet."))
            if comparison.get("cohortKey") != expected_values["cohortKey"]:
                findings.append(finding("comparison_cohort_digest_mismatch", f"/comparisons/{name}/cohortKey", "Kohortenschlüssel ist nicht kanonisch berechnet."))


def validate_evaluation(document: Any) -> list[dict[str, str]]:
    findings: list[dict[str, str]] = []
    root = _object(document, "", EVALUATION_FIELDS, EVALUATION_FIELDS, "evaluation_unexpected_field", findings)
    if root is None:
        return findings
    if root.get("schemaVersion") != EVALUATION_SCHEMA_VERSION:
        findings.append(finding("schema_version_invalid", "/schemaVersion", "Falsche Evaluationsversion."))
    if root.get("kind") != EVALUATION_KIND:
        findings.append(finding("kind_invalid", "/kind", "Falsche Dokumentart."))
    _identifier(root.get("evaluationId"), "/evaluationId", "evaluation_id_invalid", findings)
    _date_time(root.get("evaluatedAt"), "/evaluatedAt", "evaluated_at_invalid", findings)

    _validate_profile(root.get("scoringProfile"), "/scoringProfile", findings)

    derived = _object(root.get("derivedFrom"), "/derivedFrom", {"agentRunRecord", "taskEnvelope"}, {"agentRunRecord", "taskEnvelope"}, "derived_from_invalid", findings)
    agent_run = None
    if derived is not None:
        agent_run_fields = {"recordId", "runId", "revision", "schemaVersion", "digest", "dataClass"}
        agent_run = _object(derived.get("agentRunRecord"), "/derivedFrom/agentRunRecord", agent_run_fields, agent_run_fields, "agent_run_binding_invalid", findings)
        if agent_run is not None:
            for name in ("recordId", "runId"):
                _identifier(agent_run.get(name), f"/derivedFrom/agentRunRecord/{name}", "agent_run_binding_invalid", findings)
            _positive_integer(agent_run.get("revision"), "/derivedFrom/agentRunRecord/revision", "agent_run_binding_invalid", findings)
            if agent_run.get("schemaVersion") != 3:
                findings.append(finding("agent_run_schema_version_invalid", "/derivedFrom/agentRunRecord/schemaVersion", "Evaluation bindet ausschließlich AgentRunRecord v3."))
            _digest(agent_run.get("digest"), "/derivedFrom/agentRunRecord/digest", "agent_run_binding_invalid", findings)
            if agent_run.get("dataClass") not in DATA_CLASS_ORDER:
                findings.append(finding("agent_run_binding_invalid", "/derivedFrom/agentRunRecord/dataClass", "Unbekannte Datenklasse."))
        envelope_fields = {"taskId", "schemaVersion", "digest", "dataClass"}
        envelope = _object(derived.get("taskEnvelope"), "/derivedFrom/taskEnvelope", envelope_fields, envelope_fields, "task_envelope_binding_invalid", findings)
        if envelope is not None:
            _identifier(envelope.get("taskId"), "/derivedFrom/taskEnvelope/taskId", "task_envelope_binding_invalid", findings)
            if envelope.get("schemaVersion") != 2:
                findings.append(finding("task_envelope_schema_version_invalid", "/derivedFrom/taskEnvelope/schemaVersion", "Evaluation bindet ausschließlich TaskEnvelope v2."))
            _digest(envelope.get("digest"), "/derivedFrom/taskEnvelope/digest", "task_envelope_binding_invalid", findings)
            if envelope.get("dataClass") not in DATA_CLASS_ORDER:
                findings.append(finding("task_envelope_binding_invalid", "/derivedFrom/taskEnvelope/dataClass", "Unbekannte Datenklasse."))

    axes = _object(root.get("contextAxes"), "/contextAxes", CONTEXT_AXIS_FIELDS, CONTEXT_AXIS_FIELDS, "context_axes_invalid", findings)
    if axes is not None:
        if axes.get("taskClass") not in TASK_CLASSES:
            findings.append(finding("task_class_invalid", "/contextAxes/taskClass", "Unbekannte Taskklasse."))
        for name in CONTEXT_AXIS_FIELDS - {"taskClass"}:
            _validate_axis(axes.get(name), f"/contextAxes/{name}", findings)

    _validate_subject(root.get("subject"), "/subject", findings)
    _validate_identity_keys(root.get("identityKeys"), "/identityKeys", findings)

    data_class = root.get("dataClass")
    if data_class not in DATA_CLASS_ORDER:
        findings.append(finding("data_class_invalid", "/dataClass", "Unbekannte Datenklasse."))
    if isinstance(derived, dict) and data_class in DATA_CLASS_ORDER:
        source_classes = []
        for name in ("agentRunRecord", "taskEnvelope"):
            source = derived.get(name)
            if isinstance(source, dict) and source.get("dataClass") in DATA_CLASS_ORDER:
                source_classes.append(source["dataClass"])
        if source_classes and any(
            DATA_CLASS_ORDER.index(source_class) > DATA_CLASS_ORDER.index(data_class)
            for source_class in source_classes
        ):
            findings.append(
                finding(
                    "evaluation_data_class_too_low",
                    "/dataClass",
                    "Evaluation unterschreitet die höchste gebundene Rohdatenklasse.",
                )
            )
    if isinstance(axes, dict) and isinstance(axes.get("dataClassification"), dict):
        if axes["dataClassification"].get("value") != data_class:
            findings.append(finding("data_class_axis_mismatch", "/contextAxes/dataClassification/value", "Datenklassifikationsachse und Evaluationsklasse widersprechen sich."))

    qualities = _validate_dimensions(root.get("dimensions"), "/dimensions", data_class, findings, export_mode=False)
    _validate_comparisons(root.get("comparisons"), "/comparisons", findings)
    state = _validate_state(root.get("state"), "/state", qualities, findings, export_mode=False)

    freshness = _object(root.get("freshness"), "/freshness", {"mode", "sourceRevision", "timeToLiveSeconds"}, {"mode", "sourceRevision", "timeToLiveSeconds"}, "freshness_invalid", findings)
    if freshness is not None:
        if freshness.get("mode") != "revision_bound" or freshness.get("timeToLiveSeconds") is not None:
            findings.append(finding("freshness_invalid", "/freshness", "Evaluation muss revisionsgebunden und ohne Zeitablauf sein."))
        _positive_integer(freshness.get("sourceRevision"), "/freshness/sourceRevision", "freshness_invalid", findings)
        if isinstance(agent_run, dict) and freshness.get("sourceRevision") != agent_run.get("revision"):
            findings.append(finding("source_revision_mismatch", "/freshness/sourceRevision", "Frischebindung stimmt nicht mit der AgentRun-Revision überein."))

    retention = _object(root.get("retention"), "/retention", {"mode", "policyRef"}, {"mode", "policyRef"}, "retention_invalid", findings)
    if retention is not None:
        if retention.get("mode") != "append_only":
            findings.append(finding("retention_invalid", "/retention/mode", "Evaluationen müssen append-only sein."))
        _identifier(retention.get("policyRef"), "/retention/policyRef", "retention_invalid", findings)

    if root.get("routingApplied") is not False:
        findings.append(finding("routing_applied", "/routingApplied", "Evaluation darf niemals Routing anwenden."))

    expected_keys = None
    if isinstance(root.get("subject"), dict) and isinstance(axes, dict):
        try:
            expected_keys = expected_identity_keys(root)
            if isinstance(root.get("identityKeys"), dict):
                for name, expected_value in expected_keys.items():
                    if root["identityKeys"].get(name) != expected_value:
                        findings.append(finding("identity_digest_mismatch", f"/identityKeys/{name}", "Identitätsschlüssel ist nicht kanonisch berechnet."))
        except (KeyError, TypeError, ValueError):
            pass

    expected_comparisons = None
    if expected_keys is not None and isinstance(root.get("scoringProfile"), dict):
        profile_digest = root["scoringProfile"].get("digest")
        if is_digest(profile_digest):
            expected_comparisons = expected_comparison_keys(expected_keys, profile_digest)
    model_source = None
    if isinstance(root.get("subject"), dict) and isinstance(root["subject"].get("model"), dict):
        model_source = root["subject"]["model"].get("identitySource")
    _validate_comparison_relationships(
        root.get("comparisons"),
        root.get("identityKeys"),
        expected_comparisons,
        model_source,
        state,
        findings,
        export_mode=False,
    )
    return findings


def _validate_export_record(value: Any, path: str, findings: list[dict[str, str]]) -> tuple[Any, Any]:
    fields = {
        "sourceEvaluationId",
        "sourceEvaluationDigest",
        "runId",
        "evaluatedAt",
        "taskClass",
        "dataClass",
        "state",
        "scoringProfile",
        "subject",
        "identityKeys",
        "dimensions",
        "comparisons",
    }
    record = _object(value, path, fields, fields, "export_record_invalid", findings)
    if record is None:
        return None, None
    for name in ("sourceEvaluationId", "runId"):
        _identifier(record.get(name), f"{path}/{name}", "export_record_invalid", findings)
    _digest(record.get("sourceEvaluationDigest"), f"{path}/sourceEvaluationDigest", "export_record_invalid", findings)
    _date_time(record.get("evaluatedAt"), f"{path}/evaluatedAt", "export_record_invalid", findings)
    if record.get("taskClass") not in TASK_CLASSES:
        findings.append(finding("export_record_invalid", f"{path}/taskClass", "Unbekannte Taskklasse."))
    data_class = record.get("dataClass")
    if data_class not in EXPORT_DATA_CLASSES:
        findings.append(finding("export_data_class_blocked", f"{path}/dataClass", "Cockpit-Export erlaubt nur synthetic, public oder internal_non_sensitive."))
    _validate_profile(record.get("scoringProfile"), f"{path}/scoringProfile", findings, reference_only=True)
    _validate_subject(record.get("subject"), f"{path}/subject", findings, export_mode=True)
    _validate_identity_keys(record.get("identityKeys"), f"{path}/identityKeys", findings)
    qualities = _validate_dimensions(record.get("dimensions"), f"{path}/dimensions", data_class, findings, export_mode=True)
    _validate_comparisons(record.get("comparisons"), f"{path}/comparisons", findings)
    state = _validate_state(record.get("state"), f"{path}/state", qualities, findings, export_mode=True)

    model_source = None
    if isinstance(record.get("subject"), dict) and isinstance(record["subject"].get("model"), dict):
        model_source = record["subject"]["model"].get("identitySource")
    before = len(findings)
    _validate_comparison_relationships(
        record.get("comparisons"),
        record.get("identityKeys"),
        None,
        model_source,
        state,
        findings,
        export_mode=True,
    )
    for item in findings[before:]:
        if item["path"].startswith("/comparisons"):
            item["path"] = path + item["path"]
    return record.get("sourceEvaluationId"), record.get("runId")


def validate_export(document: Any, *, source_bytes: int | None = None) -> list[dict[str, str]]:
    findings: list[dict[str, str]] = []
    root = _object(document, "", EXPORT_FIELDS, EXPORT_FIELDS, "export_unexpected_field", findings)
    if root is None:
        return findings
    if root.get("schemaVersion") != EXPORT_SCHEMA_VERSION:
        findings.append(finding("schema_version_invalid", "/schemaVersion", "Falsche Exportversion."))
    if root.get("kind") != EXPORT_KIND:
        findings.append(finding("kind_invalid", "/kind", "Falsche Dokumentart."))
    _date_time(root.get("generatedAt"), "/generatedAt", "generated_at_invalid", findings)

    source_fields = {"producerAdapter", "producerAdapterVersion", "evaluationSchemaVersion", "redactionPolicy"}
    source = _object(root.get("source"), "/source", source_fields, source_fields, "export_source_invalid", findings)
    if source is not None:
        for name in ("producerAdapter", "producerAdapterVersion"):
            _identifier(source.get(name), f"/source/{name}", "export_source_invalid", findings)
        if source.get("evaluationSchemaVersion") != EVALUATION_SCHEMA_VERSION:
            findings.append(finding("export_source_invalid", "/source/evaluationSchemaVersion", "Export muss den neutralen Evaluationsvertrag referenzieren."))
        redaction = _object(source.get("redactionPolicy"), "/source/redactionPolicy", {"id", "version", "digest"}, {"id", "version", "digest"}, "redaction_policy_invalid", findings)
        if redaction is not None:
            _identifier(redaction.get("id"), "/source/redactionPolicy/id", "redaction_policy_invalid", findings)
            _positive_integer(redaction.get("version"), "/source/redactionPolicy/version", "redaction_policy_invalid", findings)
            _digest(redaction.get("digest"), "/source/redactionPolicy/digest", "redaction_policy_invalid", findings)

    freshness = _object(root.get("freshness"), "/freshness", {"staleAfterSeconds"}, {"staleAfterSeconds"}, "export_freshness_invalid", findings)
    if freshness is not None and freshness.get("staleAfterSeconds") != EXPORT_STALE_AFTER_SECONDS:
        findings.append(finding("export_freshness_invalid", "/freshness/staleAfterSeconds", "Frischefenster muss 300 Sekunden betragen."))

    retention = _object(root.get("retention"), "/retention", {"mode", "maxRecords", "maxBytes"}, {"mode", "maxRecords", "maxBytes"}, "export_retention_invalid", findings)
    if retention is not None:
        expected = {"mode": "rolling_snapshot", "maxRecords": EXPORT_MAX_RECORDS, "maxBytes": EXPORT_MAX_BYTES}
        if retention != expected:
            findings.append(finding("export_retention_invalid", "/retention", "Export muss der feste Rolling-Snapshot-Vertrag sein."))

    records = root.get("records")
    identities: set[Any] = set()
    run_ids: set[Any] = set()
    if not isinstance(records, list):
        findings.append(finding("export_records_invalid", "/records", "Records müssen eine Liste sein."))
    else:
        if len(records) > EXPORT_MAX_RECORDS:
            findings.append(finding("export_record_limit", "/records", "Export überschreitet 100 Records."))
        for index, record in enumerate(records):
            evaluation_id, run_id = _validate_export_record(record, f"/records/{index}", findings)
            if evaluation_id in identities:
                findings.append(finding("duplicate_export_evaluation", f"/records/{index}/sourceEvaluationId", "Evaluation darf nur einmal exportiert werden."))
            if run_id in run_ids:
                findings.append(finding("duplicate_export_run", f"/records/{index}/runId", "Run darf nur einmal exportiert werden."))
            identities.add(evaluation_id)
            run_ids.add(run_id)

    withheld = _object(root.get("withheld"), "/withheld", {"count", "reasonCounts"}, {"count", "reasonCounts"}, "withheld_invalid", findings)
    if withheld is not None:
        _positive_integer(withheld.get("count"), "/withheld/count", "withheld_invalid", findings, minimum=0)
        reason_counts = withheld.get("reasonCounts")
        if not isinstance(reason_counts, list):
            findings.append(finding("withheld_invalid", "/withheld/reasonCounts", "Grundsummen müssen eine Liste sein."))
        else:
            total = 0
            codes: set[Any] = set()
            for index, item in enumerate(reason_counts):
                entry = _object(item, f"/withheld/reasonCounts/{index}", {"code", "count"}, {"code", "count"}, "withheld_invalid", findings)
                if entry is None:
                    continue
                _identifier(entry.get("code"), f"/withheld/reasonCounts/{index}/code", "withheld_invalid", findings)
                _positive_integer(entry.get("count"), f"/withheld/reasonCounts/{index}/count", "withheld_invalid", findings)
                if entry.get("code") in codes:
                    findings.append(finding("withheld_invalid", f"/withheld/reasonCounts/{index}/code", "Grundcode darf nur einmal vorkommen."))
                codes.add(entry.get("code"))
                if is_integer(entry.get("count")):
                    total += entry["count"]
            if is_integer(withheld.get("count")) and total != withheld["count"]:
                findings.append(finding("withheld_count_mismatch", "/withheld", "Summe der Grundcodes stimmt nicht mit count überein."))

    if source_bytes is not None and source_bytes > EXPORT_MAX_BYTES:
        findings.append(finding("export_byte_limit", "", "Export überschreitet 262.144 UTF-8-Bytes."))
    return findings


def validate_document(document: Any, *, source_bytes: int | None = None) -> list[dict[str, str]]:
    if not isinstance(document, dict):
        return [finding("document_invalid", "", "Dokument muss ein Objekt sein.")]
    serialized = json.dumps(document, ensure_ascii=False, sort_keys=True)
    if CREDENTIAL_SHAPE.search(serialized):
        return [finding("credential_shaped_value", "", "Dokument enthält eine credentialförmige Zeichenfolge.")]
    kind = document.get("kind")
    if kind == EVALUATION_KIND:
        return validate_evaluation(document)
    if kind == EXPORT_KIND:
        return validate_export(document, source_bytes=source_bytes)
    return [finding("kind_invalid", "/kind", "Dokumentart ist nicht unterstützt.")]


def validate_path(path: Path) -> list[dict[str, str]]:
    try:
        raw = path.read_bytes()
    except OSError as exc:
        return [finding("source_read_failed", "", f"Datei konnte nicht gelesen werden: {exc}")]
    try:
        document = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=reject_nonstandard_number,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        return [finding("source_invalid", "", f"Datei ist kein gültiges UTF-8-JSON: {exc}")]
    return validate_document(document, source_bytes=len(raw))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate neutral RunEvaluation v1 artifacts.")
    parser.add_argument("paths", nargs="+")
    args = parser.parse_args(argv)
    failed = False
    for raw_path in args.paths:
        path = Path(raw_path)
        findings = validate_path(path)
        if findings:
            failed = True
            for item in findings:
                print(f"{path}: {item['code']} {item['path']} {item['message']}")
        else:
            print(f"{path}: ok")
    return 1 if failed else 0


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    raise SystemExit(main())
