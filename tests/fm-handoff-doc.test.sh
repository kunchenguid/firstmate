#!/usr/bin/env bash
# Behavior tests for bin/fm-handoff-doc.sh — session handoff documents.
#
# The bug this feature exists to close: work finished under one operator was
# unreachable to another operator on the SAME host because it sat in a mode-0700
# home. The fix is a store both can read, plus a verb that discovers it. These
# tests pin the properties that make that safe:
#
#   - solo by default: no fleet, no group, no root, and every verb still works
#   - the shared store engages ONLY on the explicit config/admiral opt-in
#   - "seen" is reader-local, so the shared store can stay strictly read-only
#     for consumers and a reader can never mutate the publisher's artifact
#   - fetch lands remote-tracking refs only, and never trusts an unverified bundle
set -u

# Portable helpers: BSD stat/sed (macOS) differ from GNU. macOS is a declared
# supported platform, so the suite must not assume GNU coreutils.
fm_portable_mode() { # <path>
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then stat -f '%Lp' "$1" 2>/dev/null
  else stat -c '%a' "$1" 2>/dev/null; fi
}
fm_portable_sed_i() { # <expr> <file>
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then sed -i '' "$1" "$2"
  else sed -i "$1" "$2"; fi
}

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HANDOFF="$ROOT/bin/fm-handoff-doc.sh"

# A disposable operator home + store. Each test gets its own so ordering never
# matters and a leaked marker cannot mask a failure in a later test.
new_home() { # <label> -> prints "<home> <store>"
  local base; base=$(fm_test_tmproot "$1"); mkdir -p "$base/home" "$base/store"
  printf '%s %s\n' "$base/home" "$base/store"
}

# Run the script as an operator whose home is <home> against store <store>.
ho() { # <home> <store> <args...>
  local home=$1 store=$2; shift 2
  FM_HOME="$home" FM_HANDOFF_DIR="$store" bash "$HANDOFF" "$@"
}

seed_doc() { # <path> [title]
  printf '# %s\n\nBody.\n' "${2:-Example handoff}" > "$1"
}

# Rewrite an entry's author so a test can model a document from ANOTHER operator
# without needing a second uid.
set_author() { # <store> <id> <author>
  fm_portable_sed_i "s/^author=.*/author=$3/" "$1/$2/meta"
}

test_solo_is_the_default() {
  local home store out; read -r home store < <(new_home ho-solo)
  out=$(FM_HOME="$home" bash "$HANDOFF" where)
  case "$out" in
    *"solo store (this home only)"*) ;;
    *) fail "a home without config/admiral must resolve to the solo store, got: $out" ;;
  esac
  case "$out" in
    "$home/state/handoffs"*) ;;
    *) fail "solo store must live under the operator's own home, got: $out" ;;
  esac
  pass "fm-handoff-doc: solo store is the default with no opt-in"
}

test_publish_writes_a_readable_entry() {
  local home store entry; read -r home store < <(new_home ho-publish)
  local src="$home/note.md"; seed_doc "$src" "Fork consolidation"
  ho "$home" "$store" publish "$src" >/dev/null || fail "publish failed"
  entry="$store/$(date -u +%Y-%m-%d)-fork-consolidation"
  [ -f "$entry/meta" ] || fail "publish must write meta"
  [ -f "$entry/note.md" ] || fail "publish must copy the document"
  grep -q '^title=Fork consolidation$' "$entry/meta" \
    || fail "title must default to the document's first heading"
  grep -q "^author=$(id -un)$" "$entry/meta" || fail "meta must record the author"
  [ "$(fm_portable_mode "$entry/note.md")" = 644 ] \
    || fail "a shared document must be group-readable (0644)"
  pass "fm-handoff-doc: publish writes a readable entry with correct meta"
}

test_publish_refuses_an_env_file() {
  local home store; read -r home store < <(new_home ho-env)
  printf 'TOKEN=redacted\n' > "$home/.env"
  if ho "$home" "$store" publish "$home/.env" >/dev/null 2>&1; then
    fail "publishing a .env into a shared store must be refused"
  fi
  pass "fm-handoff-doc: publish refuses a .env outright"
}

test_publish_suffixes_colliding_entry_ids() {
  local home store base first second; read -r home store < <(new_home ho-collision)
  local src="$home/note.md"
  seed_doc "$src" "Repeatable handoff"
  ho "$home" "$store" publish "$src" >/dev/null || fail "first publish failed"

  printf '# Repeatable handoff\n\nSecond body.\n' > "$src"
  ho "$home" "$store" publish "$src" >/dev/null || fail "second publish failed"

  base="$(date -u +%Y-%m-%d)-repeatable-handoff"
  first="$store/$base"
  second="$store/$base-2"
  [ -f "$first/meta" ] || fail "first publish entry is missing"
  [ -f "$second/meta" ] || fail "colliding publish must allocate a suffixed entry"
  grep -q '^id=.*-2$' "$second/meta" || fail "suffixed entry must record its own id"
  grep -q 'Body\.' "$first/note.md" || fail "second publish overwrote the first document"
  grep -q 'Second body\.' "$second/note.md" || fail "second publish did not copy its document"
  pass "fm-handoff-doc: publish suffixes colliding entry ids"
}

test_check_is_quiet_for_your_own_document() {
  local home store; read -r home store < <(new_home ho-own)
  local src="$home/note.md"; seed_doc "$src"
  ho "$home" "$store" publish "$src" >/dev/null || fail "publish failed"
  if ho "$home" "$store" check >/dev/null; then
    fail "check must not report a document you wrote yourself"
  fi
  pass "fm-handoff-doc: check ignores your own documents"
}

test_check_reports_another_operators_document() {
  local home store id; read -r home store < <(new_home ho-other)
  local src="$home/note.md"; seed_doc "$src" "From elsewhere"
  ho "$home" "$store" publish "$src" >/dev/null || fail "publish failed"
  id="$(date -u +%Y-%m-%d)-from-elsewhere"
  set_author "$store" "$id" someone-else
  ho "$home" "$store" check >/dev/null || fail "check must report another operator's document"
  pass "fm-handoff-doc: check reports a document from another operator"
}

test_seen_state_is_reader_local_and_never_touches_the_store() {
  local home store id; read -r home store < <(new_home ho-seen)
  local src="$home/note.md"; seed_doc "$src" "Shared note"
  ho "$home" "$store" publish "$src" >/dev/null || fail "publish failed"
  id="$(date -u +%Y-%m-%d)-shared-note"
  set_author "$store" "$id" someone-else

  ho "$home" "$store" check >/dev/null || fail "precondition: document should be waiting"
  ho "$home" "$store" show "$id" >/dev/null || fail "show failed"

  if ho "$home" "$store" check >/dev/null; then
    fail "check must go quiet once the document has been read"
  fi
  [ -f "$home/state/handoff-seen/$id" ] \
    || fail "seen state must live in the reader's own home"
  # The store must remain exactly what the publisher wrote: a reader that could
  # write into it could tamper with another operator's handoff.
  [ -z "$(find "$store" -name '.seen-by-*' -print -quit)" ] \
    || fail "no reader state may be written into the shared store"
  pass "fm-handoff-doc: seen state is reader-local and the store stays untouched"
}

test_show_works_against_a_read_only_store() {
  local home store id out rc; read -r home store < <(new_home ho-ro)
  local src="$home/note.md"; seed_doc "$src" "Readonly note"
  ho "$home" "$store" publish "$src" >/dev/null || fail "publish failed"
  id="$(date -u +%Y-%m-%d)-readonly-note"
  chmod -R a-w "$store"
  out=$(ho "$home" "$store" show "$id" 2>&1); rc=$?
  chmod -R u+w "$store"
  [ "$rc" = 0 ] || fail "show must succeed against a read-only store, exit $rc"
  case "$out" in
    *"Readonly note"*) ;;
    *) fail "show must print the document, got: $out" ;;
  esac
  case "$out" in
    *"Permission denied"*) fail "show must not leak a permission error, got: $out" ;;
  esac
  pass "fm-handoff-doc: show works against a read-only store without leaking errors"
}

test_fetch_lands_remote_tracking_refs_only() {
  local home store id repo dest; read -r home store < <(new_home ho-fetch)
  repo="$home/repo"
  git init -q "$repo"
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed
  git -C "$repo" branch handoff-work

  local src="$home/note.md"; seed_doc "$src" "Bundled work"
  ho "$home" "$store" publish "$src" --bundle handoff-work --repo "$repo" >/dev/null \
    || fail "publish with --bundle failed"
  id="$(date -u +%Y-%m-%d)-bundled-work"

  dest="$home/dest"; git init -q "$dest"
  ho "$home" "$store" fetch "$id" --into "$dest" >/dev/null || fail "fetch failed"
  git -C "$dest" rev-parse --verify -q refs/remotes/handoff/handoff-work >/dev/null \
    || fail "fetch must create refs/remotes/handoff/<branch>"
  # A handoff must never move the receiving operator's own branches.
  [ -z "$(git -C "$dest" for-each-ref refs/heads)" ] \
    || fail "fetch must not create or move local branches"
  pass "fm-handoff-doc: fetch lands remote-tracking refs only"
}

test_fetch_refuses_a_corrupt_bundle() {
  local home store id repo dest; read -r home store < <(new_home ho-corrupt)
  repo="$home/repo"
  git init -q "$repo"
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed
  git -C "$repo" branch handoff-work
  local src="$home/note.md"; seed_doc "$src" "Corrupt case"
  ho "$home" "$store" publish "$src" --bundle handoff-work --repo "$repo" >/dev/null \
    || fail "publish failed"
  id="$(date -u +%Y-%m-%d)-corrupt-case"
  printf 'not a bundle' > "$store/$id/handoff.bundle"
  dest="$home/dest"; git init -q "$dest"
  if ho "$home" "$store" fetch "$id" --into "$dest" >/dev/null 2>&1; then
    fail "fetch must refuse a bundle that fails verification"
  fi
  pass "fm-handoff-doc: fetch refuses an unverifiable bundle"
}

test_unknown_id_fails_clearly() {
  local home store out; read -r home store < <(new_home ho-missing)
  out=$(ho "$home" "$store" show 1999-01-01-nope 2>&1) && fail "show of a missing id must fail"
  case "$out" in
    *"no handoff document"*) ;;
    *) fail "a missing id must say so plainly, got: $out" ;;
  esac
  pass "fm-handoff-doc: an unknown id fails with a clear message"
}

test_an_id_cannot_escape_the_store() {
  local home store out; read -r home store < <(new_home ho-traversal)
  mkdir -p "$home/outside"
  printf 'id=e\ntitle=t\nauthor=x\ncreated=2026-01-01T00:00:00Z\ndoc=d.md\nbundle=\n' \
    > "$home/outside/meta"
  printf 'OUTSIDE\n' > "$home/outside/d.md"
  for bad in '../outside' "$home/outside" 'a/b' '..'; do
    out=$(ho "$home" "$store" show "$bad" 2>&1) \
      && fail "show must refuse the id '$bad'"
    case "$out" in
      *"invalid handoff id"*) ;;
      *) fail "id '$bad' must be rejected as invalid, got: $out" ;;
    esac
  done
  pass "fm-handoff-doc: an id cannot escape the store"
}

test_a_planted_meta_cannot_redirect_a_read() {
  # The shared store is group-writable on a multi-operator host, so meta is
  # untrusted input. A planted doc= must never make a reader open a path outside
  # the entry with the reader's own credentials.
  local home store out; read -r home store < <(new_home ho-planted)
  printf 'SENSITIVE\n' > "$home/outside.md"
  mkdir -p "$store/planted"
  printf 'id=planted\ntitle=t\nauthor=x\ncreated=2026-01-01T00:00:00Z\ndoc=../../outside.md\nbundle=\n' \
    > "$store/planted/meta"
  out=$(ho "$home" "$store" show planted 2>&1) && fail "show must refuse a traversing doc="
  case "$out" in
    *SENSITIVE*) fail "show leaked a file outside the entry" ;;
    *"inside its own entry"*) ;;
    *) fail "a traversing doc= must be refused plainly, got: $out" ;;
  esac
  pass "fm-handoff-doc: a planted meta cannot redirect a read outside the entry"
}

test_reserved_entry_names_are_refused() {
  # Publishing a file named "meta" would be overwritten by the metadata written
  # just after it, silently losing the document.
  local home store out; read -r home store < <(new_home ho-reserved)
  local name
  for name in meta handoff.bundle; do
    mkdir -p "$home/src"
    seed_doc "$home/src/$name" "Reserved $name"
    out=$(ho "$home" "$store" publish "$home/src/$name" 2>&1) \
      && fail "publish must refuse the reserved name '$name'"
    case "$out" in
      *"reserved name"*) ;;
      *) fail "'$name' must be refused as reserved, got: $out" ;;
    esac
  done
  pass "fm-handoff-doc: reserved entry names are refused"
}

test_a_symlinked_document_is_refused() {
  local home store out; read -r home store < <(new_home ho-symlink)
  printf 'SENSITIVE\n' > "$home/outside.md"
  mkdir -p "$store/linked"
  printf 'id=linked\ntitle=t\nauthor=x\ncreated=2026-01-01T00:00:00Z\ndoc=link.md\nbundle=\n' \
    > "$store/linked/meta"
  ln -s "$home/outside.md" "$store/linked/link.md"
  out=$(ho "$home" "$store" show linked 2>&1) && fail "show must refuse a symlinked document"
  case "$out" in
    *SENSITIVE*) fail "show followed a symlink out of the entry" ;;
    *"inside its own entry"*) ;;
    *) fail "a symlinked document must be refused, got: $out" ;;
  esac
  pass "fm-handoff-doc: a symlinked document is refused"
}

# --- run --------------------------------------------------------------------
test_solo_is_the_default
test_publish_writes_a_readable_entry
test_publish_refuses_an_env_file
test_publish_suffixes_colliding_entry_ids
test_check_is_quiet_for_your_own_document
test_check_reports_another_operators_document
test_seen_state_is_reader_local_and_never_touches_the_store
test_show_works_against_a_read_only_store
test_fetch_lands_remote_tracking_refs_only
test_fetch_refuses_a_corrupt_bundle
test_unknown_id_fails_clearly
test_an_id_cannot_escape_the_store
test_a_planted_meta_cannot_redirect_a_read
test_a_symlinked_document_is_refused
test_reserved_entry_names_are_refused
echo "ALL PASS: fm-handoff-doc"
