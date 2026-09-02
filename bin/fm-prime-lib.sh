#!/usr/bin/env bash
# Prime Agent executable and Node process identity.

fm_prime_structured_argv_ready() {
  local proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  [ -d "$proc_root" ] && return 0
  [ "$(uname)" = Darwin ] || return 1
  type -P python3 >/dev/null 2>&1
}

fm_prime_node_argv_for_pid() {
  local pid=$1 proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc} argv0='' script=''
  if [ -r "$proc_root/$pid/cmdline" ]; then
    exec 3< "$proc_root/$pid/cmdline" || return 1
    IFS= read -r -d '' argv0 <&3 || true
    IFS= read -r -d '' script <&3 || true
    exec 3<&-
    [ -n "$argv0" ] && [ -n "$script" ] || return 1
    printf '%s\n%s\n' "$argv0" "$script"
    return 0
  fi
  fm_prime_structured_argv_ready || return 1
  python3 - "$pid" <<'PY'
import ctypes
import ctypes.util
import struct
import sys

pid = int(sys.argv[1])
libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
mib = (ctypes.c_int * 3)(1, 49, pid)
buf = ctypes.create_string_buffer(1024 * 1024)
size = ctypes.c_size_t(len(buf))
if libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0) != 0:
    raise SystemExit(1)
data = buf.raw[: size.value]
argc = struct.unpack_from("i", data)[0]
pos = 4
end = data.find(b"\0", pos)
if argc < 2 or end < 0:
    raise SystemExit(1)
pos = end
while pos < len(data) and data[pos] == 0:
    pos += 1
args = []
for _ in range(argc):
    end = data.find(b"\0", pos)
    if end < 0:
        raise SystemExit(1)
    args.append(data[pos:end])
    pos = end + 1
sys.stdout.buffer.write(args[0] + b"\n" + args[1] + b"\n")
PY
}

fm_prime_package_entry_matches() {
  local script=$1 canonical root parent manifest node_bin manifest_values package_name bin_entry entry
  canonical=$(fm_cursor_canonical_path "$script") || return 1
  root=${canonical%/*}
  while [ -n "$root" ] && [ "$root" != / ]; do
    manifest="$root/package.json"
    [ ! -f "$manifest" ] || break
    parent=${root%/*}
    [ -n "$parent" ] || parent=/
    [ "$parent" != "$root" ] || return 1
    root=$parent
  done
  [ -f "${manifest:-}" ] || return 1
  node_bin=$(type -P node 2>/dev/null) || return 1
  manifest_values=$("$node_bin" --input-type=commonjs - "$manifest" 2>/dev/null <<'NODE'
const fs = require("node:fs");
const pkg = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const bin = typeof pkg.bin === "string" ? pkg.bin : pkg.bin?.["prime-agent"];
if (typeof pkg.name !== "string" || typeof bin !== "string") process.exit(1);
process.stdout.write(`${pkg.name}\t${bin}`);
NODE
  ) || return 1
  IFS=$'\t' read -r package_name bin_entry <<< "$manifest_values"
  [ "$package_name" = prime-agent ] || return 1
  entry=$(fm_cursor_canonical_path "$root/$bin_entry") || return 1
  [ "$canonical" = "$entry" ]
}

fm_prime_node_pid_matches() {
  local pid=$1 values argv0 script base
  values=$(fm_prime_node_argv_for_pid "$pid") || return 1
  argv0=${values%%$'\n'*}
  script=${values#*$'\n'}
  base=${argv0##*/}
  base=${base#-}
  case "$base" in node*) ;; *) return 1 ;; esac
  fm_prime_package_entry_matches "$script"
}
