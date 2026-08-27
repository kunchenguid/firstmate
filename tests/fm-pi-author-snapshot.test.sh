#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Behavior tests for the task-private Pi author-home snapshot boundary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-pi-author-snapshot.py"
fm_test_tmproot_into TMP_ROOT fm-pi-author-snapshot

make_identity_source() {
  local source=$1
  mkdir -p "$source"
  printf '%s\n' \
    '{"openai-codex":{"type":"oauth","access":"fixture-access","refresh":"fixture-refresh","expires":4102444800000,"accountId":"fixture-account"}}' \
    > "$source/auth.json"
  printf '%s\n' '{"defaultProvider":"openai-codex"}' > "$source/settings.json"
}

assert_refused_and_cleaned() {
  local source=$1 destination=$2 label=$3
  if "$SNAPSHOT" "$source" "$destination" >/dev/null 2>&1; then
    fail "$label was accepted"
  fi
  [ ! -e "$destination" ] && [ ! -L "$destination" ] \
    || fail "$label left a partial destination"
}

test_safe_relative_links_are_preserved() {
  local source="$TMP_ROOT/safe-source" destination="$TMP_ROOT/safe-destination"
  make_identity_source "$source"
  mkdir -p "$source/npm/node_modules/.bin" \
    "$source/npm/node_modules/pi-agent-browser-native/bin"
  printf '#!/usr/bin/env node\n' \
    > "$source/npm/node_modules/pi-agent-browser-native/bin/config.js"
  chmod 755 "$source/npm/node_modules/pi-agent-browser-native/bin/config.js"
  ln -s config.js \
    "$source/npm/node_modules/pi-agent-browser-native/bin/nested-config"
  ln -s ../pi-agent-browser-native/bin/nested-config \
    "$source/npm/node_modules/.bin/pi-agent-browser-config"
  ln -s pi-agent-browser-native "$source/npm/node_modules/current-browser"

  "$SNAPSHOT" "$source" "$destination" >/dev/null 2>&1 \
    || fail "safe relative package links were refused"
  [ "$(readlink "$destination/npm/node_modules/.bin/pi-agent-browser-config")" \
      = ../pi-agent-browser-native/bin/nested-config ] \
    || fail "package-manager shim was not preserved as a relative link"
  [ "$(readlink "$destination/npm/node_modules/pi-agent-browser-native/bin/nested-config")" \
      = config.js ] \
    || fail "nested in-root link was not preserved"
  [ "$(readlink "$destination/npm/node_modules/current-browser")" \
      = pi-agent-browser-native ] \
    || fail "in-root directory link was not preserved"

  python3 - "$ROOT/bin/fm-crosscheck.py" "$destination" <<'PY' \
    || fail "safe snapshot contents, identity, containment, or permissions are invalid"
import importlib.util
import os
from pathlib import Path
import stat
import sys

module_path, destination_value = sys.argv[1:]
spec = importlib.util.spec_from_file_location("fm_crosscheck", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
root = Path(destination_value)
assert module.account_identity("pi", root) == "openai-codex:fixture-account"
assert stat.S_IMODE(root.stat().st_mode) == 0o700
assert stat.S_IMODE((root / "auth.json").stat().st_mode) == 0o600
assert stat.S_IMODE(
    (root / "npm/node_modules/pi-agent-browser-native/bin/config.js").stat().st_mode
) == 0o700
root_real = os.path.realpath(str(root))
for directory, directories, files in os.walk(root, followlinks=False):
    for name in directories + files:
        candidate = Path(directory) / name
        if candidate.is_symlink():
            resolved = os.path.realpath(str(candidate))
            assert os.path.commonpath((root_real, resolved)) == root_real
            assert os.path.exists(resolved)
PY
  pass "safe relative package and nested links are preserved inside the snapshot"
}

test_unsafe_links_are_refused() {
  local source destination outside

  source="$TMP_ROOT/absolute-source"
  destination="$TMP_ROOT/absolute-destination"
  make_identity_source "$source"
  ln -s /etc/passwd "$source/absolute"
  assert_refused_and_cleaned "$source" "$destination" "absolute link"

  source="$TMP_ROOT/escape-source"
  destination="$TMP_ROOT/escape-destination"
  outside="$TMP_ROOT/outside-target"
  make_identity_source "$source"
  printf 'outside\n' > "$outside"
  ln -s ../outside-target "$source/escape"
  assert_refused_and_cleaned "$source" "$destination" "parent escape"

  source="$TMP_ROOT/dangling-source"
  destination="$TMP_ROOT/dangling-destination"
  make_identity_source "$source"
  ln -s missing "$source/dangling"
  assert_refused_and_cleaned "$source" "$destination" "dangling link"

  source="$TMP_ROOT/loop-source"
  destination="$TMP_ROOT/loop-destination"
  make_identity_source "$source"
  ln -s loop-b "$source/loop-a"
  ln -s loop-a "$source/loop-b"
  assert_refused_and_cleaned "$source" "$destination" "link loop"

  source="$TMP_ROOT/directory-loop-source"
  destination="$TMP_ROOT/directory-loop-destination"
  make_identity_source "$source"
  mkdir -p "$source/nested"
  ln -s .. "$source/nested/back"
  assert_refused_and_cleaned "$source" "$destination" "directory link loop"

  source="$TMP_ROOT/excluded-source"
  destination="$TMP_ROOT/excluded-destination"
  make_identity_source "$source"
  mkdir -p "$source/sessions"
  printf 'excluded\n' > "$source/sessions/current"
  ln -s sessions/current "$source/excluded-target"
  assert_refused_and_cleaned "$source" "$destination" "link into excluded content"

  source="$TMP_ROOT/special-source"
  destination="$TMP_ROOT/special-destination"
  make_identity_source "$source"
  mkfifo "$source/special"
  ln -s special "$source/special-target"
  assert_refused_and_cleaned "$source" "$destination" "link to special file"

  source="$TMP_ROOT/indirect-escape-source"
  destination="$TMP_ROOT/indirect-escape-destination"
  make_identity_source "$source"
  ln -s ../outside-target "$source/escape-hop"
  ln -s escape-hop "$source/indirect-escape"
  assert_refused_and_cleaned "$source" "$destination" "indirect link escape"

  pass "absolute, escaping, dangling, looping, excluded, and special targets are refused"
}

test_links_consume_the_file_count_budget() {
  local source="$TMP_ROOT/count-source" destination="$TMP_ROOT/count-destination"
  mkdir -p "$source"
  printf 'target\n' > "$source/target"
  ln -s target "$source/link-a"
  ln -s target "$source/link-b"

  python3 - "$SNAPSHOT" "$source" "$destination" <<'PY' \
    || fail "link-count fixture did not enforce cleanup and the shared entry bound"
import contextlib
import importlib.util
import io
from pathlib import Path
import sys

module_path, source_value, destination_value = sys.argv[1:]
spec = importlib.util.spec_from_file_location("fm_pi_author_snapshot", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.MAX_FILES = 2
module.sys.argv = [module_path, source_value, destination_value]
with contextlib.redirect_stderr(io.StringIO()):
    status = module.main()
assert status == 1
assert not Path(destination_value).exists()
PY
  pass "symlinks cannot bypass the snapshot entry-count bound"
}

test_target_mutation_race_is_refused() {
  local source="$TMP_ROOT/race-source" destination="$TMP_ROOT/race-destination"
  mkdir -p "$source"
  printf 'before\n' > "$source/a-target"
  ln -s a-target "$source/z-link"

  python3 - "$SNAPSHOT" "$source" "$destination" <<'PY' \
    || fail "target mutation race was not refused and cleaned"
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import sys

module_path, source_value, destination_value = sys.argv[1:]
spec = importlib.util.spec_from_file_location("fm_pi_author_snapshot", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
source = Path(source_value)
real_symlink = os.symlink
mutated = False


def racing_symlink(target, path, *args, **kwargs):
    global mutated
    result = real_symlink(target, path, *args, **kwargs)
    if not mutated:
        replacement = source / "replacement"
        replacement.write_text("after!\n", encoding="utf-8")
        os.replace(replacement, source / "a-target")
        mutated = True
    return result


module.os.symlink = racing_symlink
module.sys.argv = [module_path, source_value, destination_value]
with contextlib.redirect_stderr(io.StringIO()):
    status = module.main()
assert mutated
assert status == 1
assert not Path(destination_value).exists()
PY
  pass "a symlink target replaced during capture is refused"
}

test_finite_repeated_link_traversal() {
  local source="$TMP_ROOT/repeated-source" destination="$TMP_ROOT/repeated-destination"
  mkdir -p "$source/real"
  printf 'captured\n' > "$source/real/file"
  ln -s real "$source/alias"
  ln -s alias/../alias/file "$source/shim"
  "$SNAPSHOT" "$source" "$destination" >/dev/null 2>&1 \
    || fail "finite repeated traversal was refused"
  [ "$(readlink "$destination/shim")" = alias/../alias/file ] \
    || fail "finite repeated traversal was not preserved"
  [ "$(cat "$destination/shim")" = captured ] \
    || fail "finite repeated traversal resolved incorrectly"
  pass "finite repeated traversal of an in-root link succeeds"
}

test_symlink_resolution_bound() {
  local source destination index previous current

  source="$TMP_ROOT/resolution-limit-source"
  destination="$TMP_ROOT/resolution-limit-destination"
  mkdir -p "$source"
  printf 'captured\n' > "$source/target"
  ln -s target "$source/link-00"
  previous=link-00
  index=1
  while [ "$index" -lt 32 ]; do
    current=$(printf 'link-%02d' "$index")
    ln -s "$previous" "$source/$current"
    previous=$current
    index=$((index + 1))
  done
  "$SNAPSHOT" "$source" "$destination" >/dev/null 2>&1 \
    || fail "a portable 32-dereference chain was refused"
  [ "$(cat "$destination/link-31")" = captured ] \
    || fail "a portable 32-dereference chain did not resolve"

  source="$TMP_ROOT/over-limit-source"
  destination="$TMP_ROOT/over-limit-destination"
  mkdir -p "$source"
  printf 'captured\n' > "$source/target"
  ln -s target "$source/link-00"
  previous=link-00
  index=1
  while [ "$index" -lt 33 ]; do
    current=$(printf 'link-%02d' "$index")
    ln -s "$previous" "$source/$current"
    previous=$current
    index=$((index + 1))
  done
  assert_refused_and_cleaned \
    "$source" "$destination" "over-limit symlink resolution"

  source="$TMP_ROOT/expanding-source"
  destination="$TMP_ROOT/expanding-destination"
  mkdir -p "$source/real"
  printf 'captured\n' > "$source/real/file"
  ln -s real "$source/l0"
  previous=l0
  index=1
  while [ "$index" -le 30 ]; do
    current="l$index"
    ln -s "$previous/../$previous" "$source/$current"
    previous=$current
    index=$((index + 1))
  done
  python3 - "$SNAPSHOT" "$source" "$destination" <<'PYTHON' \
    || fail "expanding link graph did not fail quickly and cleanly"
from pathlib import Path
import subprocess
import sys

snapshot, source, destination = sys.argv[1:]
try:
    result = subprocess.run(
        [snapshot, source, destination],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=5,
        check=False,
    )
except subprocess.TimeoutExpired as exc:
    raise AssertionError("expanding link graph exceeded the resolution deadline") from exc
assert result.returncode != 0
assert not Path(destination).exists()
PYTHON
  pass "symlink resolution is portable and hostile expansion is bounded"
}

test_destination_mutation_race_is_refused() {
  local source="$TMP_ROOT/destination-race-source" destination="$TMP_ROOT/destination-race-output"
  mkdir -p "$source"
  printf 'captured\n' > "$source/target"
  ln -s target "$source/shim"
  printf 'outside\n' > "$TMP_ROOT/destination-race-outside"
  python3 - "$SNAPSHOT" "$source" "$destination" "$TMP_ROOT/destination-race-outside" <<'PYTHON' \
    || fail "destination mutation was accepted or not cleaned"
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import sys

module_path, source_value, destination_value, outside_value = sys.argv[1:]
spec = importlib.util.spec_from_file_location("fm_pi_author_snapshot", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
real_readlink = os.readlink
reads = 0
mutated = False


def racing_readlink(path, *args, **kwargs):
    global reads, mutated
    result = real_readlink(path, *args, **kwargs)
    descriptor = kwargs.get("dir_fd")
    if path == "shim" and descriptor is not None:
        actual = os.fstat(descriptor)
        destination = os.stat(destination_value, follow_symlinks=False)
        if (actual.st_dev, actual.st_ino) == (destination.st_dev, destination.st_ino):
            reads += 1
            if reads == 2:
                os.unlink("shim", dir_fd=descriptor)
                os.symlink(outside_value, "shim", dir_fd=descriptor)
                mutated = True
    return result


module.os.readlink = racing_readlink
module.sys.argv = [module_path, source_value, destination_value]
with contextlib.redirect_stderr(io.StringIO()):
    status = module.main()
assert mutated
assert status == 1
assert not Path(destination_value).exists()
assert Path(outside_value).read_text() == "outside\n"
PYTHON
  pass "destination link replacement during validation is refused and cleaned"
}

test_safe_relative_links_are_preserved
test_unsafe_links_are_refused
test_links_consume_the_file_count_budget
test_target_mutation_race_is_refused
test_destination_mutation_race_is_refused
test_finite_repeated_link_traversal
test_symlink_resolution_bound

echo "# all fm-pi-author-snapshot tests passed"
