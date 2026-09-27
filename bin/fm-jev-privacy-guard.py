#!/usr/bin/env python3
"""fm-jev-privacy-guard.py - Inline Privacy & PII Ingestion / Staging Guardrail.

Protects repositories and staging directories by detecting and quarantining
personal tax forms (W-2, 1099, 1040), bank routing/account numbers, SSNs,
and private keys before commit, drive-sync, or ingestion into Second Mates.

Usage:
  fm-jev-privacy-guard.py [--file <path>] [--text <str>] [--quarantine] [--quarantine-dir <path>] [--source <name>] [--json]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import tempfile
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

TS_BASE = "https://api.typesafe.ai"
TS_MODEL = "jev-latest"
TS_TIMEOUT = 4.0

SSN_RE = re.compile(
    r"(?:\b(?:SSN|Social\s+Security(?:\s+Number)?)\b\s*[:=]?\s*\d{3}[-\s]?\d{2}[-\s]?\d{4}\b)|"
    r"(?:\b(?!000|666|9\d\d)\d{3}[-\s]?(?!00)\d{2}[-\s]?(?!0000)\d{4}\b)",
    re.IGNORECASE,
)

BANK_ROUTING_RE = re.compile(
    r"\b(?:routing\s*(?:number|#|no)?\s*[:=]?\s*|ABA\s*[:=]?\s*)\d{9}\b",
    re.IGNORECASE,
)

BANK_ACCT_RE = re.compile(
    r"\b(?:bank\s*account|account\s*(?:number|#|no)|acct\s*#?)\s*[:=]?\s*\d{8,17}\b",
    re.IGNORECASE,
)

TAX_MARKER_RE = re.compile(
    r"\b(?:Form\s+(?:W-2|W-2G|1099(?:-[A-Z]+)?|1040(?:-SR|-ES|-EZ)?|1098|1095-[A-C]|Schedule\s+[A-F]|941|940))\b|"
    r"\b(?:Wage\s+and\s+Tax\s+Statement|Internal\s+Revenue\s+Service|Adjusted\s+Gross\s+Income|Employee's\s+Withholding\s+Certificate)\b|"
    r"\b(?:EIN|Employer\s+Identification\s+Number)\b\s*[:=]?\s*\d{2}-\d{7}\b",
    re.IGNORECASE,
)

PRIVATE_KEY_RE = re.compile(
    r"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----|"
    r"\b(?:ghp_[a-zA-Z0-9]{36,}|xox[baprs]-[a-zA-Z0-9-]+)\b",
)


def get_api_key() -> str | None:
    key = os.environ.get("TYPESAFE_API_KEY", "").strip()
    if key:
        return key

    run_py = Path("/opt/ra/firstmate/bin/jev-typesafe-run.py")
    if run_py.exists():
        try:
            res = subprocess.run(
                ["sudo", "-n", str(run_py), "--", "env"],
                capture_output=True,
                text=True,
                timeout=3,
                check=False,
            )
            for line in res.stdout.splitlines():
                if line.startswith("TYPESAFE_API_KEY="):
                    k = line.split("=", 1)[1].strip()
                    if k:
                        return k
        except Exception:
            pass

    return None


def log_telemetry(verdict: str, tier: str, code: str, source: str, reason: str) -> None:
    fm_root = Path(os.environ.get("FM_HOME", "/opt/ra/firstmate"))
    state_dir = Path(os.environ.get("FM_STATE_OVERRIDE", fm_root / "state"))
    telem_file = state_dir / ".jev-privacy-telemetry"
    try:
        state_dir.mkdir(parents=True, exist_ok=True)
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        clean_reason = " ".join(reason.split())[:120]
        line = f"{ts}\t{verdict}\t{tier}\t{code}\t{source}\t{clean_reason}\n"
        with open(telem_file, "a", encoding="utf-8") as f:
            f.write(line)
    except Exception:
        pass


def execute_quarantine(
    file_path: Path | None,
    text_content: str,
    quarantine_dir: Path,
    code: str,
    reason: str,
    tier: str,
) -> Path | None:
    try:
        quarantine_dir.mkdir(parents=True, exist_ok=True)
        ts = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")

        record_dir = Path(tempfile.mkdtemp(prefix=f"{ts}_", dir=quarantine_dir))
        if file_path and file_path.exists():
            target_dest = record_dir / f"{ts}_{file_path.name}"
            shutil.copy2(str(file_path), str(target_dest))
            meta = {
                "source_path": str(file_path.resolve()),
                "quarantined_at": ts,
                "code": code,
                "reason": reason,
                "tier": tier,
            }
            (record_dir / f"{ts}_{file_path.name}.meta.json").write_text(
                json.dumps(meta, indent=2), encoding="utf-8"
            )
            # Remove original to protect disk / workspace
            try:
                file_path.unlink()
            except Exception as exc:
                print(f"Unable to remove quarantined source: {exc}", file=sys.stderr)
            return target_dest
        elif text_content:
            target_dest = record_dir / f"quarantine_{ts}.txt"
            target_dest.write_text(text_content, encoding="utf-8")
            meta = {
                "source": "text",
                "quarantined_at": ts,
                "code": code,
                "reason": reason,
                "tier": tier,
            }
            (record_dir / f"quarantine_{ts}.meta.json").write_text(
                json.dumps(meta, indent=2), encoding="utf-8"
            )
            return target_dest
    except Exception as exc:
        print(f"Quarantine failed: {exc}", file=sys.stderr)
    return None


def emit_result(
    verdict: str,
    code: str,
    reason: str,
    tier: str = "tier1",
    source: str = "",
    quarantined_path: Path | None = None,
    as_json: bool = False,
    exit_code: int = 0,
) -> None:
    log_telemetry(verdict, tier, code, source, reason)
    q_str = str(quarantined_path) if quarantined_path else None
    if as_json:
        payload = {
            "verdict": verdict,
            "code": code,
            "reason": reason,
            "tier": tier,
            "source": source,
            "quarantined_path": q_str,
        }
        print(json.dumps(payload, indent=2))
        sys.exit(exit_code)

    if verdict == "allow":
        print(f"VERDICT: allow [{code}] {reason}")
    else:
        q_note = f" (quarantined to {q_str})" if q_str else ""
        print(f"VERDICT: quarantine [{code}] {reason}{q_note}", file=sys.stderr)
    sys.exit(exit_code)


def inspect_tier1_static(content: str) -> tuple[bool, str, str]:
    """Run Tier 1 static regex checks for critical PII."""
    if PRIVATE_KEY_RE.search(content):
        return False, "private_key_detected", "Found private key or sensitive credential token"

    if SSN_RE.search(content):
        return False, "ssn_detected", "Found Social Security Number pattern"

    if BANK_ROUTING_RE.search(content):
        return False, "banking_routing_detected", "Found bank routing/ABA number pattern"

    if BANK_ACCT_RE.search(content):
        return False, "banking_account_detected", "Found bank account number pattern"

    if TAX_MARKER_RE.search(content):
        return False, "tax_w2_marker_detected", "Found personal tax form or W-2/1099 wage statement markers"

    return True, "tier1_clean", "No high-risk static PII signatures matched"


def inspect_tier3_semantic(content: str, source: str, key: str) -> tuple[str, str, str]:
    clean_sample = " ".join(content.split())[:1500]
    payload = {
        "model": TS_MODEL,
        "state": {
            "content_sample": clean_sample,
            "source": source,
        },
        "questions": {
            "contains_personal_pii": {
                "type": "noul",
                "instructions": (
                    "Does this text or document contain personal private financial or tax records, "
                    "such as an individual's tax filing details, personal W-2/1099 wage statements, "
                    "individual tax returns (Form 1040), private bank account statements, or confidential "
                    "personal identity records that must not be committed to code repositories?"
                ),
            },
            "pii_classification": {
                "type": "choice",
                "instructions": "Classify the privacy risk of this material:",
                "criteria": {
                    "personal_tax_or_w2": "Personal tax forms, W-2s, 1099s, or personal tax return filings.",
                    "personal_banking": "Personal bank account statements, transactions, or account balances.",
                    "public_or_code": "Standard code, public business records, system logs, or non-confidential documentation.",
                    "business_operations": "Routine business communications or clinical operations without personal tax/financial PII.",
                },
            },
        },
    }

    req = urllib.request.Request(
        f"{TS_BASE}/v1/systemone",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=TS_TIMEOUT) as resp:
            body = resp.read().decode("utf-8")
            data = json.loads(body)

        answers = data.get("answers", {})
        noul_val = float(answers.get("contains_personal_pii", {}).get("noul", 0.0))
        choice = answers.get("pii_classification", {}).get("choice", "public_or_code")

        if noul_val >= 0.7 or choice in ("personal_tax_or_w2", "personal_banking"):
            return "quarantine", f"semantic_{choice}", f"Jev semantic PII detected: {choice} (noul={noul_val:.2f})"
        else:
            return "allow", "semantic_clean", f"Jev semantic check verified clean of personal tax/banking PII (noul={noul_val:.2f})"
    except Exception as exc:
        # Fail-open
        return "allow", "jev_fail_open", f"Jev API timeout/error ({exc}); allowed fail-open"


def main() -> None:
    parser = argparse.ArgumentParser(description="Jev Inline Privacy & PII Ingestion Guardrail")
    parser.add_argument("--file", type=Path, help="Path to file to inspect")
    parser.add_argument("--text", type=str, help="Text string to inspect")
    parser.add_argument("--quarantine", action="store_true", help="Quarantine file/text if PII detected")
    parser.add_argument("--quarantine-dir", type=Path, help="Quarantine directory path")
    parser.add_argument("--source", default="stage", help="Source context (e.g. pre-commit, ingest)")
    parser.add_argument("--json", action="store_true", help="Emit JSON output")
    args = parser.parse_args()

    fm_root = Path(os.environ.get("FM_HOME", "/opt/ra/firstmate"))
    quarantine_dir = args.quarantine_dir or (
        Path(os.environ.get("FM_STATE_OVERRIDE", fm_root / "state")) / "quarantine"
    )

    target_file = None
    content = ""
    if args.file:
        target_file = args.file
        if not target_file.exists():
            emit_result("allow", "file_not_found", f"File not found: {target_file}", "tier1", args.source, as_json=args.json, exit_code=0)
        try:
            content = target_file.read_text(encoding="utf-8", errors="replace")
        except Exception as exc:
            emit_result("allow", "read_error", f"Could not read file: {exc}", "tier1", args.source, as_json=args.json, exit_code=0)
    elif args.text is not None:
        content = args.text
    elif not sys.stdin.isatty():
        content = sys.stdin.read()

    if not content.strip():
        emit_result("allow", "empty_content", "Empty input content is clean", "tier1", args.source, as_json=args.json, exit_code=0)

    # 1. Tier 1 Static Regex Checks (<1ms)
    t1_clean, t1_code, t1_reason = inspect_tier1_static(content)
    if not t1_clean:
        q_path = None
        if args.quarantine:
            q_path = execute_quarantine(target_file, content, quarantine_dir, t1_code, t1_reason, "tier1")
        exit_code = 0 if args.json else 1
        emit_result("quarantine", t1_code, t1_reason, "tier1", args.source, q_path, as_json=args.json, exit_code=exit_code)

    # 2. Tier 3 Jev Semantic Evaluation
    key = get_api_key()
    if key:
        verdict, code, reason = inspect_tier3_semantic(content, args.source, key)
        q_path = None
        if verdict == "quarantine" and args.quarantine:
            q_path = execute_quarantine(target_file, content, quarantine_dir, code, reason, "tier3")
        exit_code = 0 if (args.json or verdict == "allow") else 1
        emit_result(verdict, code, reason, "tier3", args.source, q_path, as_json=args.json, exit_code=exit_code)

    # Clean pass
    emit_result("allow", "clean", "Content clean of personal financial/tax PII", "tier1", args.source, as_json=args.json, exit_code=0)


if __name__ == "__main__":
    main()
