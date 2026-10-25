#!/usr/bin/env bash
# Sourced helper: a long-running native stand-in for an agent-named process.
#
# Fixtures give the stand-in a harness name through a symlink, because a copied
# platform binary fails code signing on macOS arm64 and the symlink name is what
# the kernel records as the process identity. The target must not dispatch on
# its own argv[0]: a multicall coreutils (uutils on current hosted Linux
# runners, or busybox) resolves the applet from the name it is invoked by, so
# `sleep` behind a symlink named `pi` or `claude` exits at once with a security
# violation and no agent-named process ever exists.

# fm_standin_alive <path>: succeeds when <path> stays running under its own name.
fm_standin_alive() {
  local pid
  "$1" 60 >/dev/null 2>&1 &
  pid=$!
  sleep 0.2
  kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; return 1; }
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# fm_standin_build <dir>: prints the path of a stand-in that survives a rename,
# preferring a tiny compiled spinner and falling back to the host `sleep` only
# when it demonstrably survives one. Fails (prints nothing) when neither does.
fm_standin_build() {
  local dir=$1 cc_bin sleep_bin
  mkdir -p "$dir"
  cc_bin=$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null || true)
  if [ -n "$cc_bin" ] &&
    printf '%s\n' '#include <unistd.h>' 'int main(void){int i;for(i=0;i<600;i++)sleep(1);return 0;}' > "$dir/standin.c" &&
    "$cc_bin" -o "$dir/standin" "$dir/standin.c" 2>/dev/null &&
    fm_standin_alive "$dir/standin"; then
    printf '%s\n' "$dir/standin"
    return 0
  fi
  rm -f "$dir/standin"
  sleep_bin=$(command -v sleep) || return 1
  ln -s "$sleep_bin" "$dir/standin" 2>/dev/null || return 1
  if fm_standin_alive "$dir/standin"; then
    printf '%s\n' "$dir/standin"
    return 0
  fi
  rm -f "$dir/standin"
  return 1
}
