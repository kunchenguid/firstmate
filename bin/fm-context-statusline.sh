#!/usr/bin/env bash
# Render Claude Code's host-computed context-window pressure for a Firstmate
# session without estimating from transcript text.
# Usage: fm-context-statusline.sh [--record <absolute-path>]
#
# Claude Code invokes a statusLine command with its JSON payload on stdin.
# This command reads context_window.remaining_percentage, used_percentage,
# total_tokens, and current_usage. It prints one compact display line and, when
# --record is present, atomically writes the complete reading plus the derived
# 70%-compaction advisory as JSON for the worker named by a generated brief.
# Invalid or incomplete input prints nothing, removes any requested stale
# snapshot, and exits zero so telemetry can never disrupt the host session.
# Snapshot persistence is best-effort: the parent directory is recreated when
# missing, and a failed write never suppresses the display line nor removes
# the last valid snapshot. Percentages display truncated to one decimal so a
# reading below 70 never shows as 70 without the compaction advisory.
set -u

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

record=
case "${1:-}" in
  '') ;;
  -h|--help) usage; exit 0 ;;
  --record)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    record=$2
    case "$record" in
      /*) ;;
      *) echo "error: --record requires an absolute path" >&2; exit 2 ;;
    esac
    ;;
  *) usage >&2; exit 2 ;;
esac

IFS= read -r -d '' node_program <<'NODE' || true
const fs = require("fs");
const path = require("path");

const record = process.argv[1] || "";

function clearStaleRecord() {
  if (!record) return;
  try {
    fs.unlinkSync(record);
  } catch (error) {
    if (error.code !== "ENOENT") return;
  }
}

function finiteNumber(value) {
  return typeof value === "number" && Number.isFinite(value);
}

function formatPercentage(value) {
  let text = value.toFixed(1);
  if (Number(text) > value) text = (Number(text) - 0.1).toFixed(1);
  return text.replace(/\.0$/, "");
}

function formatTokens(value) {
  if (value >= 1000000) return `${(value / 1000000).toFixed(value % 1000000 === 0 ? 0 : 1)}m`;
  if (value >= 1000) return `${(value / 1000).toFixed(value % 1000 === 0 ? 0 : 1)}k`;
  return String(value);
}

try {
  const payload = JSON.parse(fs.readFileSync(0, "utf8"));
  const contextWindow = payload && payload.context_window;
  if (!contextWindow || typeof contextWindow !== "object" || Array.isArray(contextWindow)) throw new Error("missing context_window");

  const used = contextWindow.used_percentage;
  const remaining = contextWindow.remaining_percentage;
  const total = contextWindow.total_tokens;
  const currentUsage = contextWindow.current_usage;
  if (!finiteNumber(used) || used < 0 || used > 100) throw new Error("invalid used_percentage");
  if (!finiteNumber(remaining) || remaining < 0 || remaining > 100) throw new Error("invalid remaining_percentage");
  if (!finiteNumber(total) || total <= 0) throw new Error("invalid total_tokens");
  if (!currentUsage || typeof currentUsage !== "object" || Array.isArray(currentUsage)) throw new Error("invalid current_usage");

  const compactRecommended = used >= 70;
  if (record) {
    try {
      const parent = path.dirname(record);
      fs.mkdirSync(parent, { recursive: true });
      const temporary = path.join(parent, `.${path.basename(record)}.${process.pid}.tmp`);
      const snapshot = {
        context_window: contextWindow,
        compact_at_used_percentage: 70,
        compact_recommended: compactRecommended,
      };
      fs.writeFileSync(temporary, `${JSON.stringify(snapshot, null, 2)}\n`, { mode: 0o600 });
      try {
        fs.renameSync(temporary, record);
      } catch (error) {
        try { fs.unlinkSync(temporary); } catch (_) {}
        throw error;
      }
    } catch (_) {}
  }

  let line = `CTX ${formatPercentage(used)}% used / ${formatPercentage(remaining)}% left (${formatTokens(total)})`;
  if (compactRecommended) line += " | COMPACT NOW: /compact";
  process.stdout.write(line);
} catch (_) {
  clearStaleRecord();
}
NODE

node -e "$node_program" "$record"
