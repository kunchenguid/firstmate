#!/usr/bin/env bash
# fm-konten-fixture-lib.sh - the ONE builder of a fake account ledger for tests.
#
# Usage (sourced by a test after tests/lib.sh):
#   . "$(dirname "${BASH_SOURCE[0]}")/fm-konten-fixture-lib.sh"
#   fm_test_konten_fixture <home> <store-root> [projektpfad...]
#
# WHY. Since fm-spawn resolves its account from config/konten.tsv instead of
# inheriting CLAUDE_CONFIG_DIR (bin/fm-spawn-gate-lib.sh, AGENTS.md "Accounts and
# day close"), EVERY claude-family spawn fixture needs a ledger plus a store that
# passes fm_konto_startfaehig. Without one the spawn refuses loudly - correctly,
# but that would make each spawn test restate the same seven lines of setup.
#
# What it writes:
#   <home>/config/konten.tsv     basis (captain-handbetrieb) + konto-1
#                                (offiziere-worker, wrapper `claude1`, so
#                                claude-ox resolves back to it) - the same shape
#                                as the real ledger, minus the private accounts.
#   <store-root>/<speicher>/.claude.json
#                                hasCompletedOnboarding plus one
#                                projects[<pfad>].hasTrustDialogAccepted entry
#                                per projektpfad passed, which is exactly what
#                                fm_konto_startfaehig reads.
#
# Every projektpfad is stored as its PHYSICAL path (`cd && pwd`), because that is
# what fm-spawn resolves PROJ_ABS to; a symlinked temp root would otherwise miss.
#
# The paths are written absolute, not as `$HOME`-relative, so a test may point
# HOME wherever it likes without the ledger following it.

# fm_test_konten_fixture <home> <store-root> [projektpfad...]
# The usual form: the ledger lands where $FM_HOME/config/konten.tsv is looked up.
fm_test_konten_fixture() {
  local home=$1
  shift
  mkdir -p "$home/config"
  fm_test_konten_akte "$home/config/konten.tsv" "$@"
}

# fm_test_konten_akte <akte-pfad> <store-root> [projektpfad...]
# For a fixture that pins FM_KONTEN_AKTE directly - a case with no FM_HOME of its
# own, where the lookup would otherwise reach the checkout's real ledger.
fm_test_konten_akte() {
  local akte=$1 store_root=$2
  shift 2
  local speicher pfad projekt eintraege=''

  # A path that does not exist yet is kept verbatim: a fixture often has to
  # declare the trust for a home or worktree it creates a few lines later, and
  # dropping those silently would hand the caller an unexplained refusal.
  for projekt in "$@"; do
    [ -n "$projekt" ] || continue
    if [ -d "$projekt" ]; then
      projekt=$(cd "$projekt" && pwd)
    fi
    eintraege="$eintraege$projekt"$'\n'
  done

  mkdir -p "$(dirname "$akte")"
  {
    printf '# test ledger (tests/fm-konten-fixture-lib.sh)\n'
    printf 'basis\t%s\ttest-basis@example.invalid\tcaptain-handbetrieb\tfixture\n' "$store_root/basis"
    # The role column is a closed set in bin/fm-konten-lib.sh; offiziere-worker is
    # the seat every spawn takes, so konto-1 holds it here.
    printf 'konto-1\t%s\ttest-worker@example.invalid\toffiziere-worker\tfixture\n' "$store_root/konto-1"
  } > "$akte"

  for speicher in basis konto-1; do
    pfad="$store_root/$speicher"
    mkdir -p "$pfad"
    {
      printf '{"hasCompletedOnboarding": true, "projects": {'
      local erst=1
      while IFS= read -r projekt; do
        [ -n "$projekt" ] || continue
        [ "$erst" -eq 1 ] || printf ', '
        erst=0
        printf '"%s": {"hasTrustDialogAccepted": true}' "$projekt"
      done <<< "$eintraege"
      printf '}}\n'
    } > "$pfad/.claude.json"
  done
}

# fm_test_konten_store_pfad <store-root> <speicher>: the launch prefix a spawn on
# that storage must carry, so a test asserts against the ledger, not a literal.
fm_test_konten_store_pfad() {
  printf '%s/%s\n' "$1" "$2"
}
