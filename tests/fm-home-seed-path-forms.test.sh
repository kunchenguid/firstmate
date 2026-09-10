#!/usr/bin/env bash
# tests/fm-home-seed-path-forms.test.sh - secondmate-home path-form handling.
#
# On MSYS hosts treehouse prints leased worktree paths in Windows drive form
# (C:/Users/...). canonical_path_for_check must recognize a drive path as
# absolute (converting it through cygpath when available) instead of joining it
# onto the caller's cwd, which made the lease land inside the active home and
# tripped the nested-home safety refusal.
set -u

# shellcheck source=tests/secondmate-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-home-seed-path-forms)
export FM_BACKEND=tmux

test_home_seed_accepts_windows_form_leased_home() {
  local home acquired fakebin log err out
  home="$TMP_ROOT/win-home"
  err="$TMP_ROOT/win.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/win-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"

  # The leased home exists in drive form in the test tree; the fake cygpath
  # maps that form onto the same directory in POSIX form.
  WIN_CYGROOT="$TMP_ROOT/win-c"
  acquired="$WIN_CYGROOT/Users/tester/.treehouse/firstmate-abc/1/firstmate"
  git clone --quiet "$ROOT" "$acquired"

  fakebin=$(make_fake_tmux "$TMP_ROOT/win-fake")
  log="$TMP_ROOT/win-fake/tmux.log"
  cat > "$fakebin/cygpath" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = -u ] || exit 1
p=\${2:-}
case "\$p" in
  [A-Za-z]:[/\\\\]*)
    rest=\${p#?:}
    rest=\${rest#/}
    rest=\${rest#\\\\}
    printf '%s/%s\n' "\$WIN_CYGROOT" "\$rest" | tr '\\\\' '/'
    ;;
  *) printf '%s\n' "\$p" ;;
esac
SH
  chmod +x "$fakebin/cygpath"

  out=$(PATH="$fakebin:$PATH" WIN_CYGROOT="$WIN_CYGROOT" FM_HOME="$home" \
    FM_FAKE_TREEHOUSE_HOME='C:/Users/tester/.treehouse/firstmate-abc/1/firstmate' \
    FM_FAKE_TMUX_LOG="$log" FM_FAKE_TREEHOUSE_LEASE_FILE="$TMP_ROOT/win-fake/lease" \
    FM_SECONDMATE_CHARTER='win form scope' FM_SECONDMATE_SCOPE='win form scope' \
    "$ROOT/bin/fm-home-seed.sh" winform - alpha 2>"$err") \
    || { cat "$err" >&2; fail "seed refused a Windows-form leased home"; }
  printf '%s\n' "$out" | grep -F "home=$acquired" >/dev/null \
    || fail "seed did not report the converted POSIX home path"
  [ -f "$acquired/.fm-secondmate-home" ] || fail "seed did not mark the acquired home"
  if grep -F 'cannot be inside the active firstmate home' "$err" >/dev/null 2>&1; then
    fail "seed treated a Windows-form absolute path as relative"
  fi
  pass "home seeding accepts Windows drive-form leased home paths"
}

test_home_seed_accepts_windows_form_leased_home
