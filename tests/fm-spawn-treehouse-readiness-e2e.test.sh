#!/usr/bin/env bash
# Real-Treehouse check of the readiness signal bin/fm-spawn.sh waits for before
# its clean check: fm_treehouse_slot_acquired (bin/fm-wake-lib.sh) reads a pool
# slot as acquired only once Treehouse's pool state lists it under a live owner
# reservation. The spawn relies on Treehouse publishing that entry only after
# the slot is checked out, so this drives a real interactive `treehouse get` and
# samples the signal twice: from a post-checkout hook, which runs inside the
# acquisition's own git checkout, and from the shell Treehouse opens in the slot
# once it hands the slot over. The first sample must read pending and the second
# acquired, for a newly created slot and for a reused one.
#
# It runs whichever `treehouse` is on PATH. The required real-Herdr CI lane
# installs the pinned release (bin/fm-install-treehouse.sh), so that lane proves
# the pinned binary publishes the state the spawn reads.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-spawn-treehouse-readiness)
HOME_DIR="$TMP_ROOT/home"
PROJ="$TMP_ROOT/project"
PROBE_LOG="$TMP_ROOT/probe.log"
mkdir -p "$HOME_DIR" "$TMP_ROOT/bin"

# One probe serves as both the post-checkout hook and the slot shell. It records
# its label, the readiness verdict for the directory it runs in, and that path.
cat > "$TMP_ROOT/bin/probe" <<'SH'
#!/usr/bin/env bash
set -u
export FM_HOME="$FM_PROBE_HOME" FM_STATE_OVERRIDE="$FM_PROBE_HOME/state"
# shellcheck source=/dev/null
. "$FM_PROBE_ROOT/bin/fm-wake-lib.sh"
here=$(pwd -P)
if fm_treehouse_slot_acquired "$here"; then verdict=acquired; else verdict=pending; fi
printf '%s %s %s\n' "$FM_PROBE_LABEL" "$verdict" "$here" >> "$FM_PROBE_LOG"
SH
printf '#!/usr/bin/env bash\nFM_PROBE_LABEL=checkout exec "%s"\n' "$TMP_ROOT/bin/probe" > "$TMP_ROOT/bin/hook"
printf '#!/usr/bin/env bash\nFM_PROBE_LABEL=shell exec "%s"\n' "$TMP_ROOT/bin/probe" > "$TMP_ROOT/bin/slot-shell"
chmod +x "$TMP_ROOT/bin/probe" "$TMP_ROOT/bin/hook" "$TMP_ROOT/bin/slot-shell"

fm_git_init_commit "$PROJ"
fm_git_add_origin "$PROJ" "$PROJ.origin.git"
cp "$TMP_ROOT/bin/hook" "$PROJ/.git/hooks/post-checkout"

# An isolated HOME gives Treehouse a private pool root and no user config or
# hooks, on every release; TREEHOUSE_ROOT would override it on newer ones.
treehouse_get() {
  (
    cd "$PROJ" || exit 1
    env -u TREEHOUSE_ROOT HOME="$HOME_DIR" SHELL="$TMP_ROOT/bin/slot-shell" \
      FM_PROBE_ROOT="$ROOT" FM_PROBE_HOME="$TMP_ROOT/fm-home" FM_PROBE_LOG="$PROBE_LOG" \
      treehouse get </dev/null
  ) >"$TMP_ROOT/treehouse-get.out" 2>&1
}

slot_acquired_now() {  # <slot>
  (
    export FM_HOME="$TMP_ROOT/fm-home" FM_STATE_OVERRIDE="$TMP_ROOT/fm-home/state"
    # shellcheck source=bin/fm-wake-lib.sh
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_treehouse_slot_acquired "$1"
  )
}

# Runs one real acquisition and prints the slot its shell sampled, failing
# unless exactly one shell sample exists and it read the slot as acquired inside
# the isolated pool.
acquire_slot() {  # <description>
  local what=$1 slot
  treehouse_get || fail "$what: treehouse get failed: $(cat "$TMP_ROOT/treehouse-get.out")"
  [ "$(grep -c '^shell ' "$PROBE_LOG")" -eq 1 ] \
    || fail "$what: expected one slot-shell sample: $(cat "$PROBE_LOG")"
  slot=$(sed -n 's/^shell acquired //p' "$PROBE_LOG")
  [ -n "$slot" ] \
    || fail "$what: the shell treehouse opened in the slot read the slot as not acquired: $(cat "$PROBE_LOG")"
  case "$slot" in
    "$(cd "$HOME_DIR" && pwd -P)"/.treehouse/*) ;;
    *) fail "$what: the slot shell ran outside the isolated pool: '$slot'" ;;
  esac
  printf '%s\n' "$slot"
}

# Checkout samples taken before the shell sample belong to the acquisition; the
# ones after it come from Treehouse's release of the slot, which runs under the
# same reservation.
acquisition_checkout_samples() {
  sed '/^shell /q' "$PROBE_LOG" | grep '^checkout ' || true
}

assert_no_checkout_read_acquired() {  # <description>
  if acquisition_checkout_samples | grep -q '^checkout acquired '; then
    fail "$1: the slot read as acquired while its checkout was still running: $(cat "$PROBE_LOG")"
  fi
}

test_new_slot_reads_acquired_only_after_its_checkout() {
  local slot
  : > "$PROBE_LOG"
  slot=$(acquire_slot "new slot") || exit 1
  FIRST_SLOT=$slot
  [ -n "$(acquisition_checkout_samples)" ] \
    || fail "new slot: the post-checkout hook never sampled the slot during acquisition: $(cat "$PROBE_LOG")"
  assert_no_checkout_read_acquired "new slot"
  ! slot_acquired_now "$slot" || fail "new slot: still read as acquired after treehouse get exited"
  pass "real treehouse $(treehouse --version 2>/dev/null): a new slot reads acquired only after its checkout, and not after release"
}

test_reused_slot_reads_acquired_only_after_its_reset() {
  local slot
  : > "$PROBE_LOG"
  slot=$(acquire_slot "reused slot") || exit 1
  [ "$slot" = "$FIRST_SLOT" ] \
    || fail "reused slot: treehouse handed over '$slot' instead of reusing the first acquisition's '$FIRST_SLOT'"
  assert_no_checkout_read_acquired "reused slot"
  ! slot_acquired_now "$slot" || fail "reused slot: still read as acquired after treehouse get exited"
  pass "real treehouse $(treehouse --version 2>/dev/null): a reused slot reads acquired only once treehouse hands it over, and not after release"
}

test_new_slot_reads_acquired_only_after_its_checkout
test_reused_slot_reads_acquired_only_after_its_reset

echo "# all fm-spawn-treehouse-readiness-e2e tests passed"
