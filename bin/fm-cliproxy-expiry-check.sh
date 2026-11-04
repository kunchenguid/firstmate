#!/usr/bin/env bash
# fm-cliproxy-expiry-check.sh - the registered watcher check that notices a
# CLIProxyAPI Claude credential is about to die, and wakes firstmate while there
# is still time to re-login.
#
# Usage:
#   fm-cliproxy-expiry-check.sh [check]   run the sweep (silent unless it is news)
#   fm-cliproxy-expiry-check.sh status    print the current finding set (no wake, no record)
#   fm-cliproxy-expiry-check.sh arm       write state/cliproxy-expiry.check.sh and bind its bytes
#   fm-cliproxy-expiry-check.sh disarm    remove the shim, its trust binding, and the record
#   fm-cliproxy-expiry-check.sh --help    print this help
#
# WHY THIS EXISTS. A Claude OAuth credential family dies 27-30 days after the
# human login no matter how faithfully it refreshes, and CLIProxyAPI cannot see
# that deadline: it ignores the refresh-token expiry the token endpoint omits,
# retries a rejected credential every five minutes forever, and keeps serving
# the still-valid access token until that expires. So the pool degrades silently
# and requests only start failing eight hours later, one account at a time.
# data/cliproxy-refresh-research-r1/report.md records the whole failure wave.
#
# TWO SIGNALS, because they catch different failures.
#
#   stall   an account whose last_refresh is older than FM_CLIPROXY_STALL_SECS
#           (default 9h). A healthy account refreshes inside 8h, so a frozen
#           last_refresh means the refresh token is already dead: this catches
#           today's failure mode within about nine hours.
#   age     an account whose last human login is older than
#           FM_CLIPROXY_MAX_AGE_DAYS (default 23). Half a week of runway before
#           the measured 27-30 day wall.
#   setup   a one-year setup-token credential has no refresh at all, so age is
#           not a death signal for it: its own `expired` field is the deadline,
#           and it is reported inside FM_CLIPROXY_SETUP_WARN_DAYS (default 30).
#
# The login date is not stored in a CLIProxyAPI auth file, so the age signal
# reads FM_CLIPROXY_LOGIN_REGISTRY, a small JSON object of "<email>": "<ISO
# date>" that bin/cliproxy-relogin.sh updates on every re-login. An account that
# registry does not name, and a registry that cannot be read, are reported as
# their own conditions rather than silently disabling the age signal: an alarm
# that quietly stopped measuring is the exact failure this check exists against.
#
# WHAT IS NEWS. The record state/.cliproxy-expiry holds the identity set of the
# last sweep, where an identity is the account plus the fact itself (its login
# date, its frozen last_refresh, or its token's expiry), never the sentence
# around it. A sweep prints one line only for conditions that were not in the
# previous set, so a standing condition wakes firstmate once instead of on every
# poll, and a condition that clears and returns is news again because a dead
# credential that comes back must resurface. `status` prints the whole current
# set and writes nothing.
#
# The check reads files only: no network call, no secret is read out, and the
# whole sweep is a glob and a few JSON parses, so it ends far inside
# FM_CHECK_TIMEOUT.
#
# Environment (all optional):
#   FM_CLIPROXY_AUTH_DIR          auth dir to sweep (default ~/.cli-proxy-api)
#   FM_CLIPROXY_LOGIN_REGISTRY    login-date registry (default config/cliproxy-login-registry.json)
#   FM_CLIPROXY_STALL_SECS        refresh stall threshold (default 32400 = 9h)
#   FM_CLIPROXY_MAX_AGE_DAYS      login age threshold in days (default 23)
#   FM_CLIPROXY_SETUP_WARN_DAYS   setup-token expiry warning window (default 30)
#   FM_CLIPROXY_FAMILY_DAYS       family lifetime used for the printed expiry estimate (default 28)
#   FM_CLIPROXY_NOW               override "now" for a test (ISO 8601)
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
RECORD="$STATE/.cliproxy-expiry"
CHECK_ID=cliproxy-expiry
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
# One finding clause is short; several accounts can report at once.
MAX_LINE=1200

# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-cliproxy-expiry-check.sh [check]   sweep the Claude credential pool (silent unless news)
  fm-cliproxy-expiry-check.sh status    print the current finding set, write nothing
  fm-cliproxy-expiry-check.sh arm       write and register state/cliproxy-expiry.check.sh
  fm-cliproxy-expiry-check.sh disarm    remove the check shim, its trust binding, and the record
  fm-cliproxy-expiry-check.sh --help    print this help

Reads FM_CLIPROXY_AUTH_DIR (default ~/.cli-proxy-api) and
FM_CLIPROXY_LOGIN_REGISTRY (default config/cliproxy-login-registry.json).
docs/configuration.md "CLIProxyAPI credential expiry watch" owns the operator contract.
EOF
}

# The registry default follows this home, so an armed shim resolves the same file
# the operator sees. An explicit environment value always wins.
registry() {
  if [ -n "${FM_CLIPROXY_LOGIN_REGISTRY:-}" ]; then
    printf '%s\n' "$FM_CLIPROXY_LOGIN_REGISTRY"
  else
    printf '%s\n' "$CONFIG/cliproxy-login-registry.json"
  fi
}

run_engine() {  # <check|status>
  CE_ACTION=$1 \
  CE_RECORD="$RECORD" \
  CE_AUTH_DIR="${FM_CLIPROXY_AUTH_DIR:-$HOME/.cli-proxy-api}" \
  CE_REGISTRY="$(registry)" \
  CE_STALL_SECS="${FM_CLIPROXY_STALL_SECS:-32400}" \
  CE_MAX_AGE_DAYS="${FM_CLIPROXY_MAX_AGE_DAYS:-23}" \
  CE_SETUP_WARN_DAYS="${FM_CLIPROXY_SETUP_WARN_DAYS:-30}" \
  CE_FAMILY_DAYS="${FM_CLIPROXY_FAMILY_DAYS:-28}" \
  CE_NOW="${FM_CLIPROXY_NOW:-}" \
  python3 - <<'PY'
import datetime
import glob
import json
import os
import re
import sys

E = os.environ
ACTION = E["CE_ACTION"]
RECORD = E["CE_RECORD"]
AUTH_DIR = os.path.expanduser(E["CE_AUTH_DIR"])
REGISTRY = os.path.expanduser(E["CE_REGISTRY"])
SCHEMA = "fm-cliproxy-expiry-v1"


def ival(name, default):
    raw = (E.get(name) or "").strip()
    try:
        return int(raw)
    except ValueError:
        return default


STALL_SECS = max(3600, ival("CE_STALL_SECS", 32400))
MAX_AGE_DAYS = max(1, ival("CE_MAX_AGE_DAYS", 23))
SETUP_WARN_DAYS = max(1, ival("CE_SETUP_WARN_DAYS", 30))
FAMILY_DAYS = max(1, ival("CE_FAMILY_DAYS", 28))


def parse_iso(value):
    """Parse an RFC3339 or plain ISO timestamp into an aware UTC datetime."""
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip().replace("Z", "+00:00")
    try:
        parsed = datetime.datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=datetime.timezone.utc)
    return parsed.astimezone(datetime.timezone.utc)


raw_now = (E.get("CE_NOW") or "").strip()
if raw_now:
    NOW = parse_iso(raw_now)
    if NOW is None:
        sys.exit("fm-cliproxy-expiry-check: FM_CLIPROXY_NOW is not an ISO 8601 timestamp")
else:
    NOW = datetime.datetime.now(datetime.timezone.utc)
TODAY = NOW.date()


def days_text(delta):
    whole = int(delta.total_seconds() // 86400)
    return "%dd" % whole


def hours_text(delta):
    secs = max(0, int(delta.total_seconds()))
    return "%dh" % (secs // 3600) if secs >= 3600 else "%dm" % (secs // 60)


def load_registry():
    """Return (dates, problem) where dates maps a lowercased email to a date."""
    if not os.path.isfile(REGISTRY):
        return {}, "login registry %s is missing" % REGISTRY
    try:
        with open(REGISTRY) as handle:
            data = json.load(handle)
    except (OSError, ValueError) as exc:
        return {}, "login registry %s cannot be read: %s" % (REGISTRY, exc)
    if not isinstance(data, dict):
        return {}, "login registry %s is not a JSON object" % REGISTRY
    dates = {}
    for key, value in data.items():
        if key.startswith("_"):
            continue
        parsed = parse_iso(value) if isinstance(value, str) else None
        if parsed is not None:
            dates[key.strip().lower()] = parsed.date()
    return dates, None


def load_record():
    try:
        with open(RECORD) as handle:
            data = json.load(handle)
        if isinstance(data, dict) and data.get("schema") == SCHEMA:
            identities = data.get("identities")
            if isinstance(identities, list):
                return [str(i) for i in identities]
    except (OSError, ValueError):
        pass
    return []


def save_record(identities):
    payload = {"schema": SCHEMA, "identities": sorted(identities),
               "updated": NOW.isoformat().replace("+00:00", "Z")}
    tmp = RECORD + ".tmp"
    try:
        with open(tmp, "w") as handle:
            json.dump(payload, handle, separators=(",", ":"), sort_keys=True)
        os.chmod(tmp, 0o600)
        os.replace(tmp, RECORD)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def sweep():
    """Return a list of (identity, clause, remedy) for every condition holding now."""
    dates, problem = load_registry()
    findings = []
    if problem:
        findings.append((
            "registry:" + REGISTRY,
            problem,
            "write it with bin/cliproxy-relogin.sh (or by hand) so the login-age alarm can measure"),
        )

    if not os.path.isdir(AUTH_DIR):
        # Reported once, then absorbed: an armed check on a host with no proxy is
        # a misplaced alarm, which is news, but not a wake on every poll.
        findings.append((
            "no-auth-dir:" + AUTH_DIR,
            "the CLIProxyAPI auth dir %s does not exist" % AUTH_DIR,
            "arm this check only on a host that serves the Claude pool",
        ))
        return findings

    paths = sorted(glob.glob(os.path.join(AUTH_DIR, "claude-*.json")))
    if not paths:
        findings.append((
            "no-credentials:" + AUTH_DIR,
            "no claude-*.json credential is present in %s" % AUTH_DIR,
            "the Claude pool has no credential at all; run bin/cliproxy-relogin.sh",
        ))
        return findings

    for path in paths:
        name = os.path.basename(path)
        try:
            with open(path) as handle:
                data = json.load(handle)
        except (OSError, ValueError) as exc:
            findings.append((
                "unreadable:%s" % name,
                "%s cannot be read: %s" % (name, exc),
                "repair or re-login that credential",
            ))
            continue
        if not isinstance(data, dict):
            findings.append((
                "unreadable:%s" % name,
                "%s is not a JSON object" % name,
                "repair or re-login that credential",
            ))
            continue
        # The proxy does not load a disabled credential, so its calendar is not a
        # condition until something enables it.
        if data.get("disabled") is True:
            continue

        stem = name[:-5] if name.endswith(".json") else name
        account = str(data.get("email") or stem)
        login_date = dates.get(account.strip().lower())
        age_days = (TODAY - login_date).days if login_date else None
        age = " age=%dd" % age_days if age_days is not None else ""

        setup_token = bool(data.get("is_setup_token")) or not data.get("refresh_token")
        expiry = parse_iso(data.get("expired"))

        if setup_token:
            if expiry is None:
                findings.append((
                    "setup-no-expiry:%s" % account,
                    "%s is a setup-token credential with no usable expiry%s" % (account, age),
                    "rewrite its expired field so the proxy and this alarm can see its deadline",
                ))
                continue
            remaining = expiry - NOW
            if remaining <= datetime.timedelta(days=SETUP_WARN_DAYS):
                findings.append((
                    "setup-expiry:%s:%s" % (account, expiry.date().isoformat()),
                    "%s%s expires=%s (%s left)" % (
                        account, age, expiry.date().isoformat(),
                        "expired" if remaining.total_seconds() <= 0 else days_text(remaining)),
                    "replace the one-year setup token before it lapses (bin/cliproxy-relogin.sh)",
                ))
            continue

        last_refresh = parse_iso(data.get("last_refresh"))
        if last_refresh is None or NOW - last_refresh > datetime.timedelta(seconds=STALL_SECS):
            findings.append((
                "stall:%s:%s" % (account, data.get("last_refresh")),
                "%s%s refresh-stalled=%s last_refresh=%s expired=%s" % (
                    account, age,
                    "unknown" if last_refresh is None else hours_text(NOW - last_refresh),
                    "never" if last_refresh is None else last_refresh.date().isoformat(),
                    expiry.date().isoformat() if expiry else "unknown"),
                "its refresh token is dead; re-login that account now (bin/cliproxy-relogin.sh)",
            ))

        if login_date is None:
            # One registry problem line already says every account is unmeasured.
            if problem is None:
                findings.append((
                    "unregistered:%s" % account,
                    "%s is not named in the login registry, so its login age is unmeasured" % account,
                    "add it to %s" % REGISTRY,
                ))
        else:
            if age_days > MAX_AGE_DAYS:
                family_expiry = login_date + datetime.timedelta(days=FAMILY_DAYS)
                findings.append((
                    "age:%s:%s" % (account, login_date.isoformat()),
                    "%s age=%dd login=%s expires~=%s" % (
                        account, age_days, login_date.isoformat(), family_expiry.isoformat()),
                    "the family dies ~%dd after login; re-login or move it to a one-year setup token"
                    " (bin/cliproxy-relogin.sh)" % FAMILY_DAYS,
                ))
    return findings


def render(findings):
    clauses = [f[1] for f in findings]
    remedies = []
    for _, _, remedy in findings:
        if remedy and remedy not in remedies:
            remedies.append(remedy)
    text = "; ".join(clauses)
    if remedies:
        text += " - " + "; ".join(remedies[:3])
    return text


findings = sweep()
if ACTION == "status":
    if not findings:
        print("cliproxy-expiry: every Claude credential is inside its refresh and age bounds")
    else:
        print("cliproxy-expiry: %s" % render(findings))
    sys.exit(0)

current = [f[0] for f in findings]
previous = load_record()
fresh = [f for f in findings if f[0] not in previous]
# The record always carries the current set, so a condition that clears is
# absorbed and its return is news again.
save_record(current)
if fresh:
    print("cliproxy-expiry: %s" % render(fresh))
PY
}

action_check() {
  local out
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 0
  out=$(run_engine check 2>/dev/null) || out='cliproxy-expiry: could-not-determine the sweep failed'
  [ -n "$out" ] || return 0
  fm_cap_line "$out" "$MAX_LINE"
}

action_status() {
  run_engine status 2>/dev/null || printf 'cliproxy-expiry: the sweep failed\n'
}

# The home is embedded already resolved, because the watcher runs the shim from
# its own working directory.
shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-cliproxy-expiry-check.sh - CLIProxyAPI credential expiry sweeper.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-cliproxy-expiry-check.sh") check"
}

action_arm() {
  local want home
  mkdir -p "$STATE" || return 1
  home=$(fm_custom_check_resolve_home "$FM_HOME") || {
    printf 'fm-cliproxy-expiry-check: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
    return 1
  }
  want=$(shim_content "$home")
  fm_custom_check_arm "$STATE" "$CHECK_ID" .fm-cliproxy-expiry \
    fm-cliproxy-expiry-check "$REGISTER_BIN" "$home" "$want" || return 1
  [ -f "$(registry)" ] || printf 'fm-cliproxy-expiry-check: %s does not exist yet, so the login-age signal reports a missing registry until it does\n' "$(registry)" >&2
  return 0
}

action_disarm() {
  fm_custom_check_disarm "$STATE" "$CHECK_ID" "$RECORD"
}

case "${1:-check}" in
  check) action_check ;;
  status) action_status ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help|help) usage ;;
  *) usage; exit 2 ;;
esac
