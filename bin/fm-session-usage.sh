#!/usr/bin/env bash
# fm-session-usage.sh - read-only JSON report for an observed-stable Pi session.
#
# Usage: fm-session-usage.sh [--run-label <label>] [--role <role>]
#   [--task <task>] [--attempt <number>] [--settle-ms <number>] <session.jsonl>
#
# Reads only a regular Pi JSONL artifact. final means observed-stable: one
# first header, valid records, and unchanged identity and size during read and settle.
# It does not prove permanent closure because Pi JSONL has no closed marker.
# Measures only top-level usage entries and emits no prompts, tool output,
# credentials, authenticated content, or paths. Caller metadata is tag-only;
# identity and correlation are never inferred or sidecar-backed.
# Provider usage and model-rate estimates remain separate and neither means
# subscription or quota consumption.
set -eu
command -v python3 >/dev/null 2>&1 || { printf 'fm-session-usage: python3 is required\n' >&2; exit 2; }
exec python3 - "$@" <<'PY'
import hashlib, json, math, os, re, stat, sys, time

TAG = re.compile(r"[A-Za-z0-9._:+,@-]{1,128}\Z")
SESSION_ID = re.compile(r"[A-Za-z0-9._:-]{1,128}\Z")
TOKENS = dict(input="input", cache_read="cacheRead", cache_write="cacheWrite",
              output="output", reasoning="reasoning", provider_total="totalTokens")
REQUIRED = {k: v for k, v in TOKENS.items() if k != "reasoning"}
COSTS = dict(input="input", cache_read="cacheRead", cache_write="cacheWrite", output="output", total="total")
HELP = """fm-session-usage.sh - read-only JSON report for an observed-stable Pi session.

Usage: fm-session-usage.sh [--run-label <label>] [--role <role>]
  [--task <task>] [--attempt <number>] [--settle-ms <number>] <session.jsonl>
"""


def fail(message):
    print(f"fm-session-usage: {message}", file=sys.stderr)
    raise SystemExit(2)


def parse(argv):
    values = dict(run_label=None, role=None, task=None, attempt=None, settle_ms="10")
    positional, options = [], {"--run-label", "--role", "--task", "--attempt", "--settle-ms"}
    while argv:
        arg = argv.pop(0)
        if arg in ("-h", "--help"):
            print(HELP, end="", file=sys.stderr); raise SystemExit(0)
        if arg == "--":
            positional.extend(argv); break
        if arg in options:
            if not argv: fail(f"{arg} requires a value")
            values[arg[2:].replace("-", "_")] = argv.pop(0)
        elif arg.startswith("-"):
            fail("unknown option")
        else:
            positional.append(arg)
    if len(positional) != 1 or positional[0].startswith("-"):
        fail("one session JSONL path is required")
    for key in ("run_label", "role", "task"):
        if values[key] is not None and not TAG.fullmatch(values[key]):
            fail(f"{key.replace('_', '-')} must be a content-free tag")
    if values["attempt"] is not None and not re.fullmatch(r"[0-9]+", values["attempt"]):
        fail("attempt must be a non-negative integer")
    if not re.fullmatch(r"[0-9]+", values["settle_ms"]):
        fail("settle milliseconds must be a non-negative integer")
    values["settle_ms"] = int(values["settle_ms"])
    if values["settle_ms"] > 60000:
        fail("settle milliseconds must be between 0 and 60000")
    return values, positional[0]


def signature(path):
    try:
        info = os.stat(path)
        return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns) \
            if stat.S_ISREG(info.st_mode) else None
    except OSError:
        return None


def number(value):
    try:
        return None if isinstance(value, bool) or not isinstance(value, (int, float)) \
            or not math.isfinite(value) or value < 0 else value
    except (OverflowError, TypeError):
        return None


def text(value):
    return value if isinstance(value, str) and value else None


def session_id_digest(value):
    value = text(value)
    return hashlib.sha256(value.encode()).hexdigest() if value and SESSION_ID.fullmatch(value) else None


def provider_values(usage):
    return {key: number(usage.get(source)) for key, source in TOKENS.items()} \
        if isinstance(usage, dict) else None


def cost_values(usage):
    cost = usage.get("cost") if isinstance(usage, dict) else None
    return {key: number(cost.get(source)) for key, source in COSTS.items()} \
        if isinstance(cost, dict) else None


def measurement(entry, entry_class, parent, provider=None, model=None):
    usage = parent.get("usage")
    state = "missing" if "usage" not in parent else "present" if isinstance(usage, dict) else "invalid"
    return dict(entry_class=entry_class, line=entry["_line"], provider=text(provider), model=text(model),
                usage_state=state, has_usage=state == "present", provider_usage=provider_values(usage),
                model_rate_cost_estimate=cost_values(usage))


def measurements(entries):
    result = []
    for entry in entries:
        message = entry.get("message")
        if entry.get("type") == "message" and isinstance(message, dict):
            role = message.get("role")
            if role == "assistant":
                model = text(message.get("responseModel")) or text(message.get("model"))
                result.append(measurement(entry, "assistant", message, message.get("provider"), model))
            elif role == "toolResult" and "usage" in message:
                result.append(measurement(entry, "tool_result", message))
        elif entry.get("type") in ("compaction", "branch_summary") and "usage" in entry:
            result.append(measurement(entry, entry["type"], entry))
    return result


def usage_warnings(record):
    if record["usage_state"] != "present":
        return [dict(code=f"{record['usage_state']}_usage", entry_class=record["entry_class"], line=record["line"])]
    warnings = [dict(code="unknown_usage_field", entry_class=record["entry_class"], field=field, line=record["line"])
                for key, field in REQUIRED.items() if record["provider_usage"][key] is None]
    if record["model_rate_cost_estimate"] is None:
        warnings.append(dict(code="unknown_model_rate_cost", entry_class=record["entry_class"], line=record["line"]))
    else:
        warnings.extend(dict(code="unknown_model_rate_cost_field", entry_class=record["entry_class"],
                             field=field, line=record["line"])
                        for key, field in COSTS.items()
                        if record["model_rate_cost_estimate"][key] is None)
    return warnings


def aggregate(records, section, key, zero_if_empty):
    if not records:
        return 0 if zero_if_empty else None
    if any(not record["has_usage"] for record in records):
        return None
    values = [record[section].get(key) if isinstance(record[section], dict) else None
              for record in records]
    return sum(values) if all(value is not None for value in values) else None


def report(values, path):
    before = signature(path)
    if before is None:
        fail("session path is not a readable regular file")
    entries, warnings, malformed = [], [], 0

    def reject_constant(value):
        raise ValueError(value)

    try:
        with open(path, encoding="utf-8", errors="replace") as source:
            for line_no, line in enumerate(source, 1):
                if not line.strip():
                    continue
                try:
                    entry = json.loads(line, parse_constant=reject_constant)
                except (TypeError, ValueError):
                    warnings.append(dict(code="malformed_json", line=line_no)); malformed += 1; continue
                if not isinstance(entry, dict):
                    warnings.append(dict(code="record_not_object", line=line_no)); malformed += 1; continue
                entry["_line"] = line_no; entries.append(entry)
    except OSError:
        fail("could not read session file")

    after_read = signature(path)
    if values["settle_ms"]:
        time.sleep(values["settle_ms"] / 1000)
    stable = before == after_read == signature(path)
    records = measurements(entries)
    headers = [entry for entry in entries if entry.get("type") == "session"]
    header = headers[0] if headers else {}
    first_is_header = bool(entries and entries[0].get("type") == "session")
    for record in records:
        warnings.extend(usage_warnings(record))
    if not headers:
        warnings.append(dict(code="missing_session_header"))
    elif len(headers) > 1:
        warnings.append(dict(code="multiple_session_headers"))
    if headers and not first_is_header:
        warnings.append(dict(code="session_header_not_first", line=headers[0]["_line"]))
    warnings.extend(dict(code="embedded_history_ignored", entry_class="compaction", line=entry["_line"])
                    for entry in entries if entry.get("type") == "compaction" and isinstance(entry.get("retainedTail"), list))
    if not stable:
        warnings.append(dict(code="unstable_file"))

    def type_count(kind):
        return sum(entry.get("type") == kind for entry in entries)

    def role_count(role):
        return sum(entry.get("type") == "message" and isinstance(entry.get("message"), dict)
                   and entry["message"].get("role") == role for entry in entries)

    tool_calls = sum(isinstance(block, dict) and block.get("type") == "toolCall"
                     for entry in entries if entry.get("type") == "message" and isinstance(entry.get("message"), dict)
                     for block in (entry["message"].get("content") if isinstance(entry["message"].get("content"), list) else []))
    known = {"session", "message", "compaction", "branch_summary"}
    counts = dict(parsed=len(entries), malformed=malformed, session=type_count("session"), message=type_count("message"),
                  user_message=role_count("user"), assistant_message=role_count("assistant"),
                  tool_result_message=role_count("toolResult"), compaction=type_count("compaction"),
                  branch_summary=type_count("branch_summary"), other=sum(entry.get("type") not in known for entry in entries))
    calls = dict(assistant=role_count("assistant"), tool=tool_calls, tool_result=role_count("toolResult"),
                 compaction=type_count("compaction"), branch_summary=type_count("branch_summary"),
                 measured=sum(record["has_usage"] for record in records))
    provider = {key: aggregate(records, "provider_usage", key, key not in ("reasoning", "provider_total")) for key in TOKENS}
    model_cost = {key: aggregate(records, "model_rate_cost_estimate", key, True) for key in COSTS}
    report_data = dict(schema=1,
        artifact=dict(format="pi-session-jsonl", stability="stable" if stable else "unstable",
                      final=stable and malformed == 0 and len(headers) == 1 and first_is_header),
        session=dict(id=session_id_digest(header.get("id")),
                     version=header.get("version") if isinstance(header.get("version"), (int, float)) and not isinstance(header.get("version"), bool) else None),
        metadata=dict(run_label=values["run_label"], role=values["role"], task=values["task"],
                      attempt=int(values["attempt"]) if values["attempt"] is not None else None),
        entry_counts=counts, calls=calls, records=records,
        totals=dict(provider_usage=provider, model_rate_cost_estimate=model_cost), warnings=warnings,
        limitations=["final means observed-stable: the first record is the only session header, all records are valid, and the regular file stayed unchanged during this read and settle check. It does not prove permanent closure because Pi JSONL has no closed marker.",
                     "Session IDs are emitted only as SHA-256 digests; source paths and session content are never emitted.",
                     "Provider usage is not subscription or quota consumption, and model-rate cost is an estimate rather than a billing record.",
                     "Worker identity and run correlation are caller-supplied only; this parser does not infer primary versus worker or create a sidecar."])
    json.dump(report_data, sys.stdout, indent=2); print()


values, session_path = parse(sys.argv[1:])
report(values, session_path)
PY
