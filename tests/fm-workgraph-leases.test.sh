#!/usr/bin/env bash
# Focused Slice 5 lease, fencing, authority-boundary, and audit regression tests.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
MATRIX_IDS='S5V1-01 S5V1-02 S5V1-03 S5V1-04 S5V1-05 S5V1-06 S5V1-07 S5V1-08 S5V1-09 S5V1-10 S5V1-11 S5V1-12 S5V1-13 S5V1-14 S5V1-15 S5V3-TXN-BOOT S5V3-TXN-NO-TIME S5V3-TXN-LIVE-UNCERTAIN S5V3-TXN-SUPERIOR-GENERATION S5V3-BOOT-ID-BYTES S5V3-UNSUPPORTED-IDENTITY S5V3-ACQUIRE-DEAD-SPLIT S5V3-ORPHAN-CACHE-STATUS S5V3-READBACK-ONCE S5V3-READBACK-BYTE-TYPE-METADATA-ERROR S5V3-TERMINAL-RECOVER S5V3-TERMINAL-RELEASE-FENCE S5V3-RELEASE-DIFFERENT-PID S5V3-EXACT-SUCCESS-BYTES S5V3-INSPECT-HISTORY-ORDER S5V3-STATUS-GOAL-SCOPE S5V3-COUNTER-RECONSTRUCTION S5V3-EVENT-RECORD-INVARIANTS S5V3-CRASH-EACH-PUBLICATION S5V3-SLICE4-BYTE-ORACLE S5V3-OUTPUT-MANIFEST S5V4-GENERATION-ZERO S5V4-FRESH-LOCK-OPEN S5V4-TRANSACTION-CROSS-FILE S5V4-SIX-SCHEMAS S5V4-IMMUTABLE-REVISION-HISTORY S5V4-CACHE-CANONICAL-BYTES S5V4-COUNTER-FLOOR S5V4-PUBLICATION-SUB-BOUNDARIES S5V4-TARGET-ONLY-REPAIR S5V4-EVIDENCE-SERIALIZATION S5V4-ORACLE-ROOTS'
[ "$(wc -w <<<"$MATRIX_IDS")" -eq 47 ] || { printf 'not ok - sealed matrix manifest\n' >&2; exit 1; }
MATRIX_CASE_MODE=0
MATRIX_CASE_ID=
MATRIX_OUT=
matrix_case_seen=0
matrix_out_seen=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --matrix-case)
      [ "$matrix_case_seen" -eq 0 ] || { printf 'not ok - duplicate matrix-case\n' >&2; exit 2; }
      [ "$#" -ge 2 ] || { printf 'not ok - malformed matrix-case\n' >&2; exit 2; }
      MATRIX_CASE_ID=$2
      matrix_case_seen=1
      shift 2
      ;;
    --matrix-out)
      [ "$matrix_out_seen" -eq 0 ] || { printf 'not ok - duplicate matrix-out\n' >&2; exit 2; }
      [ "$#" -ge 2 ] || { printf 'not ok - malformed matrix-out\n' >&2; exit 2; }
      MATRIX_OUT=$2
      matrix_out_seen=1
      shift 2
      ;;
    *)
      printf 'not ok - unexpected matrix argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done
if [ "$matrix_case_seen" -ne 0 ] || [ "$matrix_out_seen" -ne 0 ]; then
  [ "$matrix_case_seen" -eq 1 ] && [ "$matrix_out_seen" -eq 1 ] || { printf 'not ok - matrix-case and matrix-out are required together\n' >&2; exit 2; }
  matrix_id_known=1
  for matrix_known_id in $MATRIX_IDS; do
    if [ "$matrix_known_id" = "$MATRIX_CASE_ID" ]; then
      matrix_id_known=0
      break
    fi
  done
  [ "$matrix_id_known" -eq 0 ] || { printf 'not ok - unknown matrix case: %s\n' "$MATRIX_CASE_ID" >&2; exit 2; }
  case "$MATRIX_OUT" in
    /*) ;;
    *) printf 'not ok - matrix-out must be absolute\n' >&2; exit 2 ;;
  esac
  [ -d "$MATRIX_OUT" ] && [ ! -L "$MATRIX_OUT" ] || { printf 'not ok - matrix-out must be a real directory\n' >&2; exit 2; }
  [ "$(readlink -f -- "$MATRIX_OUT")" = "$MATRIX_OUT" ] || { printf 'not ok - matrix-out path alias or symlink\n' >&2; exit 2; }
  case "$MATRIX_OUT" in
    "$ROOT"|"$ROOT"/*) printf 'not ok - matrix-out overlaps the worktree\n' >&2; exit 2 ;;
  esac
  [ -z "$(find "$MATRIX_OUT" -mindepth 1 -print -quit)" ] || { printf 'not ok - matrix-out must be empty\n' >&2; exit 2; }
  MATRIX_CASE_MODE=1
  TMP_ROOT="$MATRIX_OUT/.private"
  mkdir -m 0700 "$TMP_ROOT" || { printf 'not ok - matrix private root\n' >&2; exit 2; }
else
  TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-workgraph-leases.XXXXXX")
fi

matrix_cleanup() {
  local matrix_exit=$?
  local child_pid child_pgid self_pgid
  if [ "${MATRIX_CLEANUP_RUNNING:-0}" -ne 0 ]; then
    return
  fi
  MATRIX_CLEANUP_RUNNING=1
  if [ "$#" -eq 1 ]; then
    matrix_exit=$1
  fi
  self_pgid=$(ps -o pgid= -p "$$" | tr -d ' ')
  for child_pid in $(jobs -pr 2>/dev/null); do
    child_pgid=$(ps -o pgid= -p "$child_pid" 2>/dev/null | tr -d ' ')
    if [ -n "$child_pgid" ] && [ "$child_pgid" != "$self_pgid" ]; then
      kill -TERM -- "-$child_pgid" 2>/dev/null || true
    else
      kill -TERM "$child_pid" 2>/dev/null || true
    fi
  done
  for child_pid in $(jobs -pr 2>/dev/null); do
    wait "$child_pid" 2>/dev/null || true
  done
  if [ "$MATRIX_CASE_MODE" -eq 1 ]; then
    printf 'case_id=%s\nexit_code=%s\nresult=%s\n' "$MATRIX_CASE_ID" "$matrix_exit" "$([ "$matrix_exit" -eq 0 ] && printf pass || printf fail)" >"$MATRIX_OUT/result.txt"
    chmod 0600 "$MATRIX_OUT/result.txt"
    find "$TMP_ROOT" -depth -mindepth 1 ! -type d -delete 2>/dev/null
    find "$TMP_ROOT" -depth -type d -empty -delete 2>/dev/null
  else
    find "$TMP_ROOT" -depth -mindepth 1 ! -type d -delete 2>/dev/null
    find "$TMP_ROOT" -depth -type d -empty -delete 2>/dev/null
  fi
  exit "$matrix_exit"
}
MATRIX_CLEANUP_RUNNING=0
trap 'matrix_cleanup 129' HUP
trap 'matrix_cleanup 130' INT
trap 'matrix_cleanup 131' QUIT
trap 'matrix_cleanup 143' TERM
trap 'matrix_cleanup' EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
ok() { printf 'ok - %s\n' "$1"; }
run() { set +e; OUT=$(FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$DATA_ROOT" FM_STATE_OVERRIDE="$STATE_ROOT" "$@" 2>"$TMP_ROOT/err"); RC=$?; set -e; }
serialize_tree() {
  local mode=$1 output=$2 root_param=$3 identity_file=$4
  shift 4
  [ -n "$root_param" ] || fail "serializer root parameter"
  [ -n "$identity_file" ] || fail "serializer identity parameter"
  python3 - "$mode" "$output" "$root_param" "$identity_file" "$@" <<'PY_SERIALIZER'
import hashlib
import json
import os
import re
import stat
import sys

mode, output, run_root, identity_file = sys.argv[1:5]
args = sys.argv[5:]
if mode not in {"rawhex", "global", "normalized", "state", "stream", "mutations", "union"}:
    raise SystemExit("unknown serializer mode")
if not run_root or not os.path.isabs(run_root):
    raise SystemExit("serializer arguments")
if mode in {"normalized", "state", "stream", "mutations"} and identity_file == "-":
    raise SystemExit("identity token set required")
run_root_b = os.fsencode(run_root)
tmp_re = re.compile(br"\.tmp\.[A-Za-z0-9]{6}$")
identity_keys = {"pid":"<PID>", "start_ticks":"<START_TICKS>", "cmdline_sha256":"<CMDLINE_SHA256>", "boot_id":"<BOOT_ID>", "hostname":"<HOSTNAME>"}
identity_exact = {name: () for name in ("namespace_id", "cmdline_sha256", "boot_id", "hostname")}
identity_decimal = {name: () for name in ("pid", "start_ticks")}
race_swap_done = set()

def race_swap(kind):
    if os.environ.get("FM_SERIALIZER_RACE_SWAP") != kind or kind in race_swap_done:
        return
    run_abs = os.path.abspath(run_root_b)
    paths = [os.fsencode(os.environ[name]) for name in ("FM_SERIALIZER_RACE_FROM", "FM_SERIALIZER_RACE_TO", "FM_SERIALIZER_RACE_HOLD")]
    for candidate in paths:
        if os.path.commonpath((run_abs, os.path.abspath(candidate))) != run_abs:
            raise SystemExit("race swap escapes rerun root")
    try:
        os.rename(paths[0], paths[2])
        os.rename(paths[1], paths[0])
    except OSError:
        raise SystemExit("race swap setup")
    race_swap_done.add(kind)

def contains_volatile(payload):
    if run_root_b in payload or re.search(br"\.tmp\.[A-Za-z0-9]{6}", payload):
        return True
    if any(value in payload for values in identity_exact.values() for value in values):
        return True
    for values in identity_decimal.values():
        for value in values:
            if re.search(br"(?<![0-9])" + re.escape(value) + br"(?![0-9])", payload):
                return True
    return False

class DuplicateKey(ValueError):
    pass

def pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            raise DuplicateKey(key)
        result[key] = value
    return result

if identity_file != "-":
    try:
        identity_abs = os.path.abspath(identity_file)
        run_abs_text = os.path.abspath(run_root)
        if os.path.commonpath((run_abs_text, identity_abs)) != run_abs_text:
            raise ValueError("identity token confinement")
        if os.path.realpath(run_abs_text) != run_abs_text:
            raise ValueError("identity token root")
        identity_anchor = os.open(run_abs_text, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        identity_held = [(identity_anchor, None, run_abs_text)]
        identity_root_stat = os.lstat(run_abs_text)
        identity_anchor_stat = os.fstat(identity_anchor)
        identity_root_key = (identity_root_stat.st_mode, identity_root_stat.st_ino, identity_root_stat.st_dev, identity_root_stat.st_uid, identity_root_stat.st_gid, identity_root_stat.st_nlink, identity_root_stat.st_size, identity_root_stat.st_mtime_ns, identity_root_stat.st_ctime_ns)
        identity_anchor_key = (identity_anchor_stat.st_mode, identity_anchor_stat.st_ino, identity_anchor_stat.st_dev, identity_anchor_stat.st_uid, identity_anchor_stat.st_gid, identity_anchor_stat.st_nlink, identity_anchor_stat.st_size, identity_anchor_stat.st_mtime_ns, identity_anchor_stat.st_ctime_ns)
        if identity_root_key != identity_anchor_key:
            raise ValueError("identity token root race")
        identity_held[0] = (identity_anchor, identity_root_stat, run_abs_text)
        identity_parent = identity_anchor
        identity_parent_path = run_abs_text
        try:
            identity_rel = os.path.relpath(identity_abs, run_abs_text)
            identity_parts = [part.encode("utf-8") for part in identity_rel.split(os.sep) if part not in {"", "."}]
            if not identity_parts:
                raise ValueError("identity token type")
            for component in identity_parts[:-1]:
                before = os.stat(component, dir_fd=identity_parent, follow_symlinks=False)
                if not stat.S_ISDIR(before.st_mode):
                    raise ValueError("identity token parent")
                next_parent = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=identity_parent)
                opened = os.fstat(next_parent)
                if (before.st_mode, before.st_ino, before.st_dev, before.st_uid, before.st_gid, before.st_nlink) != (opened.st_mode, opened.st_ino, opened.st_dev, opened.st_uid, opened.st_gid, opened.st_nlink):
                    os.close(next_parent)
                    raise ValueError("identity token parent race")
                identity_parent_path = os.path.join(identity_parent_path, os.fsdecode(component))
                identity_held.append((next_parent, before, identity_parent_path))
                identity_parent = next_parent
            identity_name = identity_parts[-1]
            identity_before = os.stat(identity_name, dir_fd=identity_parent, follow_symlinks=False)
            if not stat.S_ISREG(identity_before.st_mode):
                raise ValueError("identity token type")
            identity_fd = os.open(identity_name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=identity_parent)
            try:
                identity_opened = os.fstat(identity_fd)
                identity_key = (identity_before.st_mode, identity_before.st_ino, identity_before.st_dev, identity_before.st_uid, identity_before.st_gid, identity_before.st_nlink, identity_before.st_size, identity_before.st_mtime_ns, identity_before.st_ctime_ns)
                opened_key = (identity_opened.st_mode, identity_opened.st_ino, identity_opened.st_dev, identity_opened.st_uid, identity_opened.st_gid, identity_opened.st_nlink, identity_opened.st_size, identity_opened.st_mtime_ns, identity_opened.st_ctime_ns)
                if identity_key != opened_key:
                    raise ValueError("identity token open race")
                identity_chunks = []
                while True:
                    identity_chunk = os.read(identity_fd, 1024 * 1024)
                    if not identity_chunk:
                        break
                    identity_chunks.append(identity_chunk)
                identity_bytes = b"".join(identity_chunks)
                if os.environ.get("FM_SERIALIZER_IDENTITY_SHORT_READ") == "1":
                    identity_bytes = identity_bytes[:-1]
                if len(identity_bytes) != identity_before.st_size:
                    raise ValueError("identity token short read")
                identity_after_fd = os.fstat(identity_fd)
            finally:
                os.close(identity_fd)
            race_swap("identity_file")
            identity_after_path = os.stat(identity_name, dir_fd=identity_parent, follow_symlinks=False)
            identity_after_key = (identity_after_path.st_mode, identity_after_path.st_ino, identity_after_path.st_dev, identity_after_path.st_uid, identity_after_path.st_gid, identity_after_path.st_nlink, identity_after_path.st_size, identity_after_path.st_mtime_ns, identity_after_path.st_ctime_ns)
            identity_after_fd_key = (identity_after_fd.st_mode, identity_after_fd.st_ino, identity_after_fd.st_dev, identity_after_fd.st_uid, identity_after_fd.st_gid, identity_after_fd.st_nlink, identity_after_fd.st_size, identity_after_fd.st_mtime_ns, identity_after_fd.st_ctime_ns)
            if identity_after_key != identity_key or identity_after_fd_key != identity_key:
                raise ValueError("identity token race")
            for held_fd, held_stat, held_path in identity_held:
                current_stat = os.fstat(held_fd)
                lexical_stat = os.lstat(held_path)
                expected = (held_stat.st_mode, held_stat.st_ino, held_stat.st_dev, held_stat.st_uid, held_stat.st_gid, held_stat.st_nlink, held_stat.st_size, held_stat.st_mtime_ns, held_stat.st_ctime_ns)
                current = (current_stat.st_mode, current_stat.st_ino, current_stat.st_dev, current_stat.st_uid, current_stat.st_gid, current_stat.st_nlink, current_stat.st_size, current_stat.st_mtime_ns, current_stat.st_ctime_ns)
                lexical = (lexical_stat.st_mode, lexical_stat.st_ino, lexical_stat.st_dev, lexical_stat.st_uid, lexical_stat.st_gid, lexical_stat.st_nlink, lexical_stat.st_size, lexical_stat.st_mtime_ns, lexical_stat.st_ctime_ns)
                if current != expected or lexical != expected:
                    raise ValueError("identity token ancestor race")
        finally:
            for held_fd, _, _ in reversed(identity_held):
                os.close(held_fd)
        identity_value = json.loads(identity_bytes.decode("utf-8"), object_pairs_hook=pairs,
                                    parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        if identity_bytes.count(b"\n") != 1 or not identity_bytes.endswith(b"\n"):
            raise ValueError("identity token framing")
        if not isinstance(identity_value, dict) or set(identity_value) != set(identity_exact) | set(identity_decimal):
            raise ValueError("identity token keys")
        for name in identity_exact:
            values = identity_value[name]
            if not isinstance(values, list) or len(values) != len(set(values)) or any(not isinstance(value, str) or not value or any(ord(ch) < 0x20 or 0xD800 <= ord(ch) <= 0xDFFF for ch in value) for value in values):
                raise ValueError("identity exact tokens")
            identity_exact[name] = tuple(value.encode("utf-8") for value in values)
        for name in identity_decimal:
            values = identity_value[name]
            if not isinstance(values, list) or len(values) != len(set(values)) or any(not isinstance(value, str) or not re.fullmatch(r"[1-9][0-9]*", value) for value in values):
                raise ValueError("identity decimal tokens")
            identity_decimal[name] = tuple(value.encode("ascii") for value in values)
    except (OSError, UnicodeError, json.JSONDecodeError, DuplicateKey, ValueError):
        raise SystemExit("identity token set")

def normalize_component(component):
    return tmp_re.sub(b".tmp.<TMP6>", component)

def normalize_path(path):
    path = path.replace(run_root_b, b"<RUN_ROOT>")
    return b"/".join(normalize_component(component) for component in path.split(b"/"))

def normalized_collision(normalized, first, second, first_origin=b"", second_origin=b""):
    message = (
        "normalized path collision: normalized_hex="
        + normalized.hex()
        + " first_hex="
        + first.hex()
        + " second_hex="
        + second.hex()
    )
    if first_origin or second_origin:
        message += " first_origin_hex=" + first_origin.hex() + " second_origin_hex=" + second_origin.hex()
    return message

def clean_string(value):
    if any(0xD800 <= ord(ch) <= 0xDFFF for ch in value):
        raise ValueError("unpaired surrogate")
    value = value.replace(run_root, "<RUN_ROOT>")
    return "/".join(re.sub(r"\.tmp\.[A-Za-z0-9]{6}$", ".tmp.<TMP6>", part) for part in value.split("/"))

def normalize_json(value, key=""):
    if isinstance(value, list):
        return [normalize_json(item, key) for item in value]
    if isinstance(value, dict):
        if any(any(ord(ch) < 0x20 or 0xD800 <= ord(ch) <= 0xDFFF for ch in name) or run_root in name or re.search(r"\.tmp\.[A-Za-z0-9]{6}$", name) or contains_volatile(name.encode("utf-8")) for name in value):
            raise ValueError("invalid JSON key")
        identity_object = all(name in value for name in identity_keys)
        result = {}
        for name, item in value.items():
            if name == "namespace_id":
                result[name] = "<NAMESPACE_ID>"
            elif identity_object and name in identity_keys:
                result[name] = identity_keys[name]
            else:
                result[name] = normalize_json(item, name)
        return result
    if isinstance(value, str):
        return clean_string(value)
    return value

def normalized_bytes(path, payload, binding_records=None):
    if path.rsplit(b"/", 1)[-1] in {b"fencing-counter", b"transaction-generation", b".transaction-lock"}:
        return payload
    if payload.endswith(b"\n") and not payload.endswith(b"\n\n"):
        try:
            value = json.loads(payload[:-1].decode("utf-8"), object_pairs_hook=pairs,
                               parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        except json.JSONDecodeError:
            if contains_volatile(payload):
                raise SystemExit("volatile non-JSON evidence")
            return payload
        except DuplicateKey:
            raise SystemExit("duplicate JSON evidence")
        except UnicodeDecodeError:
            if contains_volatile(payload):
                raise SystemExit("volatile non-JSON evidence")
            return payload
        except ValueError:
            raise SystemExit("invalid JSON evidence")
        if not isinstance(value, dict):
            raise SystemExit("non-object JSON evidence")
        try:
            normalized_value = normalize_json(value)
            if (
                binding_records is not None
                and value.get("schema_version") == "lease-event/v1"
                and isinstance(value.get("goal_id"), str)
                and isinstance(value.get("lease_id"), str)
                and value.get("record_revision") in {"1", "2"}
                and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", value["goal_id"])
                and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", value["lease_id"])
            ):
                record_path = (
                    b"D/workgraphs/.leases/v1/records/"
                    + value["goal_id"].encode("ascii") + b"/"
                    + value["lease_id"].encode("ascii") + b"/"
                    + value["record_revision"].encode("ascii") + b".json"
                )
                record_payload = binding_records.get(record_path)
                if record_payload is not None:
                    normalized_record = normalized_bytes(record_path, record_payload)
                    normalized_value["record_sha256"] = hashlib.sha256(normalized_record).hexdigest()
            return (json.dumps(normalized_value, ensure_ascii=False, allow_nan=False,
                               separators=(",", ":"), sort_keys=False) + "\n").encode("utf-8")
        except (UnicodeEncodeError, ValueError):
            raise SystemExit("invalid JSON evidence")
    if contains_volatile(payload):
        raise SystemExit("volatile non-JSON evidence")
    return payload

def normalize_stream_bytes(raw):
    if not raw:
        return b""
    if not raw.endswith(b"\n"):
        raise SystemExit("unterminated JSON stream")
    records = [record + b"\n" for record in raw[:-1].split(b"\n")]
    normalized = []
    raw_fallback = False
    for record in records:
        try:
            if not record.endswith(b"\n"):
                raise json.JSONDecodeError("record", "", 0)
            value = json.loads(record[:-1].decode("utf-8"), object_pairs_hook=pairs,
                               parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
            if not isinstance(value, dict):
                raise ValueError("non-object")
            normalized.append((json.dumps(normalize_json(value), ensure_ascii=False,
                                           allow_nan=False, separators=(",", ":"),
                                           sort_keys=False) + "\n").encode("utf-8"))
        except json.JSONDecodeError:
            raw_fallback = True
            continue
        except UnicodeDecodeError:
            raw_fallback = True
            continue
        except DuplicateKey:
            raise SystemExit("duplicate JSON stream")
        except (ValueError, UnicodeEncodeError):
            raise SystemExit("invalid JSON stream")
    if raw_fallback:
        if contains_volatile(raw):
            raise SystemExit("volatile non-JSON stream")
        return raw
    return b"".join(normalized)

def parse_manifest_line(raw):
    if not raw.endswith(b"\n"):
        raise SystemExit("unterminated manifest")
    fields = raw[:-1].split(b"  ", 3)
    if len(fields) != 4:
        raise SystemExit("bad manifest separators")
    digest, kind, mode, path_field = fields
    if kind not in {b"f", b"d", b"l"}:
        raise SystemExit("bad manifest type")
    if (kind == b"f" and not re.fullmatch(br"[0-9a-f]{64}", digest)) or (kind in {b"d", b"l"} and digest != b"-"):
        raise SystemExit("bad manifest digest")
    if not re.fullmatch(br"[0-7]{4}", mode):
        raise SystemExit("bad manifest mode")
    path, tab, target = path_field.partition(b"\t")
    validate_manifest_path(path)
    if kind == b"l":
        if not tab or target.count(b"\t") or not target or not re.fullmatch(br"[0-9a-f]+", target) or len(target) % 2:
            raise SystemExit("manifest symlink target")
    if kind != b"l" and tab:
        raise SystemExit("unexpected manifest target")
    return digest.decode("ascii"), kind, mode, path, target

def validate_manifest_path(path):
    try:
        decoded = path.decode("utf-8")
    except UnicodeDecodeError:
        raise SystemExit("manifest path encoding")
    if not path or any(ord(ch) < 0x20 or ord(ch) == 0x7f for ch in decoded):
        raise SystemExit("manifest path grammar")
    return path

def encode_manifest_record(digest, kind, mode, path, target=b""):
    if isinstance(digest, str):
        digest = digest.encode("ascii")
    if isinstance(mode, str):
        mode = mode.encode("ascii")
    if isinstance(path, str):
        path = path.encode("utf-8")
    if isinstance(target, str):
        target = target.encode("ascii")
    validate_manifest_path(path)
    if kind == b"l":
        if not target or not re.fullmatch(br"[0-9a-f]+", target) or len(target) % 2:
            raise SystemExit("manifest symlink target")
    elif target:
        raise SystemExit("unexpected manifest target")
    record = digest + b"  " + kind + b"  " + mode + b"  " + path
    if kind == b"l":
        record += b"\t" + target
    return record

def read_bound_regular(path):
    path_abs = os.path.abspath(path)
    run_abs_text = os.path.abspath(run_root)
    if os.path.commonpath((run_abs_text, path_abs)) != run_abs_text:
        raise SystemExit("input escapes rerun root")
    if os.path.realpath(run_abs_text) != run_abs_text:
        raise SystemExit("rerun root symlink")
    anchor = os.open(run_abs_text, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    held = [(anchor, None, run_abs_text)]
    root_stat = os.lstat(run_abs_text)
    anchor_stat = os.fstat(anchor)
    root_key = (root_stat.st_mode, root_stat.st_ino, root_stat.st_dev, root_stat.st_uid, root_stat.st_gid, root_stat.st_nlink, root_stat.st_size, root_stat.st_mtime_ns, root_stat.st_ctime_ns)
    anchor_key = (anchor_stat.st_mode, anchor_stat.st_ino, anchor_stat.st_dev, anchor_stat.st_uid, anchor_stat.st_gid, anchor_stat.st_nlink, anchor_stat.st_size, anchor_stat.st_mtime_ns, anchor_stat.st_ctime_ns)
    if root_key != anchor_key:
        raise SystemExit("root anchor race")
    held[0] = (anchor, root_stat, run_abs_text)
    parent = anchor
    parent_path = run_abs_text
    try:
        relative = os.path.relpath(path_abs, run_abs_text)
        parts = [part.encode("utf-8") for part in relative.split(os.sep) if part not in {"", "."}]
        if not parts:
            raise SystemExit("input is not regular")
        for component in parts[:-1]:
            before = os.stat(component, dir_fd=parent, follow_symlinks=False)
            if not stat.S_ISDIR(before.st_mode):
                raise SystemExit("input parent type")
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
            opened = os.fstat(child)
            if (before.st_mode, before.st_ino, before.st_dev, before.st_uid, before.st_gid, before.st_nlink) != (opened.st_mode, opened.st_ino, opened.st_dev, opened.st_uid, opened.st_gid, opened.st_nlink):
                os.close(child)
                raise SystemExit("input parent race")
            parent_path = os.path.join(parent_path, os.fsdecode(component))
            held.append((child, before, parent_path))
            parent = child
        name = parts[-1]
        before = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if not stat.S_ISREG(before.st_mode):
            raise SystemExit("input type")
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
        try:
            opened = os.fstat(fd)
            key = (before.st_mode, before.st_ino, before.st_dev, before.st_uid, before.st_gid, before.st_nlink, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
            opened_key = (opened.st_mode, opened.st_ino, opened.st_dev, opened.st_uid, opened.st_gid, opened.st_nlink, opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns)
            if key != opened_key:
                raise SystemExit("input open race")
            chunks = []
            while True:
                chunk = os.read(fd, 1024 * 1024)
                if not chunk:
                    break
                chunks.append(chunk)
            after_fd = os.fstat(fd)
        finally:
            os.close(fd)
        race_swap("read_bound_regular")
        after_path = os.stat(name, dir_fd=parent, follow_symlinks=False)
        after_key = (after_path.st_mode, after_path.st_ino, after_path.st_dev, after_path.st_uid, after_path.st_gid, after_path.st_nlink, after_path.st_size, after_path.st_mtime_ns, after_path.st_ctime_ns)
        after_fd_key = (after_fd.st_mode, after_fd.st_ino, after_fd.st_dev, after_fd.st_uid, after_fd.st_gid, after_fd.st_nlink, after_fd.st_size, after_fd.st_mtime_ns, after_fd.st_ctime_ns)
        for held_fd, held_stat, held_path in held:
            current_stat = os.fstat(held_fd)
            lexical_stat = os.lstat(held_path)
            expected = (held_stat.st_mode, held_stat.st_ino, held_stat.st_dev, held_stat.st_uid, held_stat.st_gid, held_stat.st_nlink, held_stat.st_size, held_stat.st_mtime_ns, held_stat.st_ctime_ns)
            current = (current_stat.st_mode, current_stat.st_ino, current_stat.st_dev, current_stat.st_uid, current_stat.st_gid, current_stat.st_nlink, current_stat.st_size, current_stat.st_mtime_ns, current_stat.st_ctime_ns)
            lexical = (lexical_stat.st_mode, lexical_stat.st_ino, lexical_stat.st_dev, lexical_stat.st_uid, lexical_stat.st_gid, lexical_stat.st_nlink, lexical_stat.st_size, lexical_stat.st_mtime_ns, lexical_stat.st_ctime_ns)
            if current != expected or lexical != expected:
                raise SystemExit("input ancestor race")
        if after_key != key or after_fd_key != key:
            raise SystemExit("input read race")
        data = b"".join(chunks)
        if len(data) != before.st_size:
            raise SystemExit("input short read")
        return data
    finally:
        for held_fd, _, _ in reversed(held):
            os.close(held_fd)

def write_bound_regular(path, payload):
    path_abs = os.path.abspath(path)
    run_abs_text = os.path.abspath(run_root)
    if os.path.commonpath((run_abs_text, path_abs)) != run_abs_text:
        raise SystemExit("output escapes rerun root")
    if os.path.realpath(run_abs_text) != run_abs_text:
        raise SystemExit("rerun root symlink")
    anchor = os.open(run_abs_text, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    held = [(anchor, os.lstat(run_abs_text))]
    parent = anchor
    temp_name = None
    published = False
    try:
        relative = os.path.relpath(path_abs, run_abs_text)
        parts = [part.encode("utf-8") for part in relative.split(os.sep) if part not in {"", "."}]
        if not parts:
            raise SystemExit("output is not regular")
        component_paths = [run_abs_text]
        for component in parts[:-1]:
            before = os.stat(component, dir_fd=parent, follow_symlinks=False)
            if not stat.S_ISDIR(before.st_mode):
                raise SystemExit("output parent type")
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
            opened = os.fstat(child)
            if (before.st_mode, before.st_ino, before.st_dev, before.st_uid, before.st_gid, before.st_nlink, before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (opened.st_mode, opened.st_ino, opened.st_dev, opened.st_uid, opened.st_gid, opened.st_nlink, opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns):
                os.close(child)
                raise SystemExit("output parent race")
            held.append((child, before))
            component_paths.append(os.path.join(component_paths[-1], os.fsdecode(component)))
            parent = child
        name = parts[-1]
        try:
            os.stat(name, dir_fd=parent, follow_symlinks=False)
            raise SystemExit("output exists")
        except FileNotFoundError:
            pass
        deepest = len(held) - 1
        def verify_ancestors(full_deepest):
            for index, (fd_bound, bound_stat) in enumerate(held):
                current_stat = os.fstat(fd_bound)
                lexical_stat = os.lstat(component_paths[index])
                expected = (bound_stat.st_mode, bound_stat.st_ino, bound_stat.st_dev, bound_stat.st_uid, bound_stat.st_gid, bound_stat.st_nlink, bound_stat.st_size, bound_stat.st_mtime_ns, bound_stat.st_ctime_ns)
                observed = (current_stat.st_mode, current_stat.st_ino, current_stat.st_dev, current_stat.st_uid, current_stat.st_gid, current_stat.st_nlink, current_stat.st_size, current_stat.st_mtime_ns, current_stat.st_ctime_ns)
                lexical = (lexical_stat.st_mode, lexical_stat.st_ino, lexical_stat.st_dev, lexical_stat.st_uid, lexical_stat.st_gid, lexical_stat.st_nlink, lexical_stat.st_size, lexical_stat.st_mtime_ns, lexical_stat.st_ctime_ns)
                if index == deepest and not full_deepest:
                    expected = expected[:6]
                    observed = observed[:6]
                    lexical = lexical[:6]
                if expected != observed or expected != lexical:
                    raise SystemExit("output ancestor changed")
        verify_ancestors(True)
        for attempt in range(100):
            candidate = b".serializer.tmp." + str(os.getpid()).encode("ascii") + b"." + str(attempt).encode("ascii")
            try:
                fd = os.open(candidate, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=parent)
                temp_name = candidate
                break
            except FileExistsError:
                continue
        else:
            raise SystemExit("output temp collision")
        try:
            opened = os.fstat(fd)
            parent_stat = os.fstat(parent)
            if not stat.S_ISREG(opened.st_mode) or stat.S_IMODE(opened.st_mode) != 0o600 or opened.st_uid != os.geteuid() or opened.st_nlink != 1 or opened.st_dev != parent_stat.st_dev:
                raise SystemExit("output shape")
            offset = 0
            fail_after = os.environ.get("FM_SERIALIZER_FAIL_AFTER_BYTES")
            fail_after = int(fail_after) if fail_after else None
            while offset < len(payload):
                written = os.write(fd, payload[offset:])
                if written <= 0:
                    raise SystemExit("output short write")
                offset += written
                if fail_after is not None and offset >= fail_after:
                    raise SystemExit("injected output write failure")
            os.fsync(fd)
            after_fd = os.fstat(fd)
            if after_fd.st_dev != opened.st_dev or after_fd.st_ino != opened.st_ino or after_fd.st_nlink != 1 or after_fd.st_size != len(payload) or stat.S_IMODE(after_fd.st_mode) != 0o600:
                raise SystemExit("output temp race")
            os.lseek(fd, 0, os.SEEK_SET)
            readback = b"".join(iter(lambda: os.read(fd, 1024 * 1024), b""))
            if readback != payload:
                raise SystemExit("output temp readback")
            race_swap("output_parent")
            os.lseek(fd, 0, os.SEEK_SET)
            verify_ancestors(False)
            import ctypes
            import ctypes.util
            libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
            renameat2 = getattr(libc, "renameat2", None)
            if renameat2 is None:
                raise SystemExit("renameat2 unavailable")
            renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
            renameat2.restype = ctypes.c_int
            if renameat2(parent, temp_name, parent, name, 1) != 0:
                error = ctypes.get_errno()
                raise SystemExit("output rename %s" % error)
            published = True
            verify_ancestors(False)
            target_fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
            try:
                target_stat = os.fstat(target_fd)
                if (target_stat.st_dev, target_stat.st_ino, target_stat.st_mode, target_stat.st_uid, target_stat.st_nlink, target_stat.st_size) != (opened.st_dev, opened.st_ino, opened.st_mode, opened.st_uid, 1, len(payload)):
                    raise SystemExit("output target identity")
                os.lseek(target_fd, 0, os.SEEK_SET)
                if b"".join(iter(lambda: os.read(target_fd, 1024 * 1024), b"")) != payload:
                    raise SystemExit("output target readback")
            finally:
                os.close(target_fd)
            os.fsync(parent)
            verify_ancestors(False)
        finally:
            os.close(fd)
    finally:
        if temp_name is not None and not published:
            try:
                os.unlink(temp_name, dir_fd=parent)
                os.fsync(parent)
            except FileNotFoundError:
                pass
            except OSError:
                raise SystemExit("output temp cleanup")
        for fd_bound, _ in reversed(held):
            os.close(fd_bound)

def load_manifest(path):
    result = {}
    for raw in read_bound_regular(path).splitlines(keepends=True):
        digest, kind, mode, rel, target = parse_manifest_line(raw)
        if rel in result:
            raise SystemExit("manifest path collision")
        result[rel] = (digest, kind, mode, target)
    return result

def mutation_bytes(before, after):
    old, new = load_manifest(before), load_manifest(after)
    output = bytearray()
    for rel in sorted(set(old) | set(new)):
        if rel not in old:
            state, entry = b"A", new[rel]
        elif rel not in new:
            state, entry = b"D", ("-", b"", b"")
        elif old[rel] == new[rel]:
            continue
        else:
            state, entry = b"M", new[rel]
        output.extend(state + b"\t" + rel + b"\t" + entry[0].encode("ascii") + b"\n")
    return bytes(output)

if mode == "stream":
    if len(args) != 1:
        raise SystemExit("stream arguments")
    stream_bytes = read_bound_regular(args[0])
    write_bound_regular(output, normalize_stream_bytes(stream_bytes))
    raise SystemExit(0)
if mode == "mutations":
    if len(args) != 2:
        raise SystemExit("mutation arguments")
    write_bound_regular(output, mutation_bytes(args[0], args[1]))
    raise SystemExit(0)
if mode == "union":
    if len(args) == 0 or len(args) % 3:
        raise SystemExit("union arguments")
    output_bytes = bytearray()
    normalized_paths = {}
    for display, source, manifest in zip(args[0::3], args[1::3], args[2::3]):
        display_b, source_b = os.fsencode(display), os.fsencode(source)
        origin = b"\0".join((display_b, source_b, os.fsencode(manifest)))
        for raw in read_bound_regular(manifest).splitlines(keepends=True):
            if not raw.endswith(b"\n"):
                raise SystemExit("unterminated union manifest")
            digest, kind, mode, path_b, target = parse_manifest_line(raw)
            if not (path_b == source_b or path_b.startswith(source_b + b"/")):
                continue
            rewritten = display_b + path_b[len(source_b):]
            normalized_path = normalize_path(rewritten)
            if normalized_path in normalized_paths:
                first_path, first_origin = normalized_paths[normalized_path]
                raise SystemExit(normalized_collision(normalized_path, first_path, rewritten, first_origin, origin))
            normalized_paths[normalized_path] = (rewritten, origin)
            output_bytes.extend(encode_manifest_record(digest, kind, mode, rewritten, target) + b"\n")
    write_bound_regular(output, bytes(output_bytes))
    raise SystemExit(0)

def stat_tuple(value):
    return (stat.S_IFMT(value.st_mode), stat.S_IMODE(value.st_mode), value.st_dev,
            value.st_ino, value.st_uid, value.st_gid, value.st_nlink, value.st_size,
            value.st_mtime_ns, value.st_ctime_ns)

def same_stat(left, right):
    return stat_tuple(left) == stat_tuple(right)

def read_regular(parent_fd, name, before):
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent_fd)
    try:
        opened = os.fstat(fd)
        if not same_stat(before, opened):
            raise SystemExit("regular open race")
        chunks = []
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after_fd = os.fstat(fd)
    finally:
        os.close(fd)
    after_path = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if not same_stat(before, after_fd) or not same_stat(before, after_path):
        raise SystemExit("regular read race")
    return b"".join(chunks)

def observe_entry(parent_fd, name, rel, records):
    before = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    kind = stat.S_IFMT(before.st_mode)
    if tmp_re.search(name) and (
        kind != stat.S_IFREG or stat.S_IMODE(before.st_mode) != 0o600
        or before.st_uid != os.getuid() or before.st_nlink != 1
    ):
        raise SystemExit("unsupported temporary filesystem object")
    if kind == stat.S_IFDIR:
        child_fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent_fd)
        try:
            opened = os.fstat(child_fd)
            if not same_stat(before, opened):
                raise SystemExit("directory open race")
            records.append((rel, b"d", before, b""))
            names = sorted(os.listdir(child_fd), key=os.fsencode)
            for child in names:
                observe_entry(child_fd, os.fsencode(child), rel + b"/" + os.fsencode(child), records)
            after = os.fstat(child_fd)
            if not same_stat(before, after):
                raise SystemExit("directory enumeration race")
        finally:
            os.close(child_fd)
        return
    if kind == stat.S_IFREG:
        records.append((rel, b"f", before, read_regular(parent_fd, name, before)))
        return
    if kind == stat.S_IFLNK:
        target = os.fsencode(os.readlink(name, dir_fd=parent_fd))
        after = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if not same_stat(before, after) or not target:
            raise SystemExit("symlink race or empty target")
        records.append((rel, b"l", before, target))
        return
    raise SystemExit("unsupported filesystem object")

def observe_scope_bound(root, prefix):
    root_b = os.fsencode(root)
    root_abs = os.path.abspath(root_b)
    run_abs = os.path.abspath(run_root_b)
    if os.path.commonpath((run_abs, root_abs)) != run_abs:
        raise SystemExit("scope escapes rerun root")
    if os.path.realpath(run_root_b) != run_abs:
        raise SystemExit("rerun root symlink")
    anchor = os.open(run_root_b, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    held = [(anchor, os.lstat(run_abs), run_abs)]
    anchor_stat = os.fstat(anchor)
    if not same_stat(held[0][1], anchor_stat):
        raise SystemExit("scope root anchor race")
    parent = anchor
    parent_path = run_abs
    try:
        root_rel = os.path.relpath(root_abs, run_abs)
        root_parts = [part for part in root_rel.split(os.fsencode(os.sep)) if part not in {b"", b"."}]
        for component in root_parts:
            before = os.stat(component, dir_fd=parent, follow_symlinks=False)
            if not stat.S_ISDIR(before.st_mode):
                raise SystemExit("scope root type")
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
            if not same_stat(before, os.fstat(child)):
                os.close(child)
                raise SystemExit("scope root race")
            parent_path = parent_path + b"/" + component
            held.append((child, before, parent_path))
            parent = child
        components = [os.fsencode(part) for part in prefix.split("/")]
        if not components or not components[0]:
            raise SystemExit("empty scope")
        records = []
        if len(components) == 1:
            root_stat = os.fstat(parent)
            records.append((components[0], b"d", root_stat, b""))
            for name in sorted(os.listdir(parent), key=os.fsencode):
                observe_entry(parent, os.fsencode(name), components[0] + b"/" + os.fsencode(name), records)
            verify = [(fd, st, path) for fd, st, path in held]
            for fd, expected_stat, lexical_path in verify:
                current_stat = os.fstat(fd)
                lexical_stat = os.lstat(lexical_path)
                if not same_stat(current_stat, expected_stat) or not same_stat(lexical_stat, expected_stat):
                    raise SystemExit("scope ancestor race")
            if not same_stat(root_stat, os.fstat(parent)):
                raise SystemExit("root enumeration race")
            return records
        current = parent
        current_path = parent_path
        for index, component in enumerate(components[1:], start=1):
            try:
                before = os.stat(component, dir_fd=current, follow_symlinks=False)
            except FileNotFoundError:
                break
            rel = b"/".join(components[:index + 1])
            kind = stat.S_IFMT(before.st_mode)
            if kind == stat.S_IFDIR:
                child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=current)
                if not same_stat(before, os.fstat(child)):
                    os.close(child)
                    raise SystemExit("scope prefix race")
                current_path = current_path + b"/" + component
                held.append((child, before, current_path))
                current = child
                records.append((rel, b"d", before, b""))
                if index == len(components) - 1:
                    final_stat = os.fstat(current)
                    for name in sorted(os.listdir(current), key=os.fsencode):
                        observe_entry(current, os.fsencode(name), rel + b"/" + os.fsencode(name), records)
                    if not same_stat(final_stat, os.fstat(current)):
                        raise SystemExit("scope enumeration race")
                    break
                continue
            if kind == stat.S_IFREG:
                records.append((rel, b"f", before, read_regular(current, component, before)))
            elif kind == stat.S_IFLNK:
                target = os.fsencode(os.readlink(component, dir_fd=current))
                after = os.stat(component, dir_fd=current, follow_symlinks=False)
                if not same_stat(before, after) or not target:
                    raise SystemExit("scope symlink race")
                records.append((rel, b"l", before, target))
            else:
                raise SystemExit("unsupported scope object")
            break
        for fd, expected_stat, lexical_path in held:
            current_stat = os.fstat(fd)
            lexical_stat = os.lstat(lexical_path)
            if not same_stat(current_stat, expected_stat) or not same_stat(lexical_stat, expected_stat):
                raise SystemExit("scope ancestor race")
        return records
    finally:
        for fd, _, _ in reversed(held):
            os.close(fd)

def collect(prefix, root):
    # prefix is the complete labeled scope (D/workgraphs/.leases/v1 or S/workgraphs/g).
    records = observe_scope_bound(root, prefix)
    race_swap("observe_scope")
    return records

def remap_path(display, path):
    source = path.split(b"/", 1)[0]
    if not source or not (path == source or path.startswith(source + b"/")):
        raise SystemExit("walk prefix mismatch")
    return display + path[len(source):]

if len(args) == 0 or len(args) % 3:
    raise SystemExit("manifest arguments")
raw_records = []
for display, root, walk_prefix in zip(args[0::3], args[1::3], args[2::3]):
    display_b = os.fsencode(display)
    if not display_b or not walk_prefix:
        raise SystemExit("empty manifest prefix")
    first = collect(walk_prefix, root)
    second = collect(walk_prefix, root)
    key = lambda item: (item[0], item[1], stat_tuple(item[2]), item[3])
    def comparable(items):
        return [(rel, kind, stat_tuple(st), payload) for rel, kind, st, payload in sorted(items, key=lambda item: item[0])]
    if comparable(first) != comparable(second):
        raise SystemExit("two-pass walk mismatch")
    for rel, kind, st, payload in sorted(second, key=lambda item: item[0]):
        validate_manifest_path(rel)
        raw_records.append((remap_path(display_b, rel), kind, st, payload))

binding_records = {rel: payload for rel, kind, _, payload in raw_records if kind == b"f"}

if mode == "rawhex":
    raw_records.sort(key=lambda item: item[0])
if mode == "state":
    authority, cache = [], []
    normalized_paths = {}
    for rel, kind, st, payload in raw_records:
        normalized_rel = normalize_path(rel)
        if normalized_rel in normalized_paths:
            raise SystemExit(normalized_collision(normalized_rel, normalized_paths[normalized_rel], rel))
        normalized_paths[normalized_rel] = rel
        normalized_payload = payload if kind == b"d" else (normalize_path(payload) if kind == b"l" else normalized_bytes(rel, payload, binding_records))
        entry = {"type": kind.decode("ascii"), "mode": f"{stat.S_IMODE(st.st_mode):04o}", "path_hex": normalized_rel.hex(), "payload_hex": normalized_payload.hex()}
        (authority if rel.startswith(b"D/") else cache).append(entry)
    authority.sort(key=lambda item: bytes.fromhex(item["path_hex"]))
    cache.sort(key=lambda item: bytes.fromhex(item["path_hex"]))
    value = {"schema_version":"lease-evidence-state/v1", "authority":authority, "cache":cache}
    payload = (json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":"), sort_keys=False) + "\n").encode("utf-8")
else:
    lines = []
    normalized_paths = {}
    for rel, kind, st, payload in raw_records:
        if mode == "rawhex":
            lines.append(kind + b"\t" + f"{stat.S_IMODE(st.st_mode):04o}".encode() + b"\t" + rel.hex().encode() + b"\t" + payload.hex().encode())
        else:
            path = rel if mode == "global" else normalize_path(rel)
            if path in normalized_paths:
                raise SystemExit(normalized_collision(path, normalized_paths[path], rel))
            normalized_paths[path] = rel
            target = b""
            if kind == b"f":
                content = payload if mode == "global" else normalized_bytes(rel, payload, binding_records)
                digest = hashlib.sha256(content).hexdigest().encode()
            else:
                digest = b"-"
                if kind == b"l":
                    target = payload if mode == "global" else normalize_path(payload)
            target_field = target.hex().encode("ascii") if target else b""
            lines.append(encode_manifest_record(digest, kind, f"{stat.S_IMODE(st.st_mode):04o}", path, target_field))
    if mode != "rawhex":
        lines.sort(key=lambda line: line.split(b"  ", 3)[-1].split(b"\t", 1)[0])
    payload = b"\n".join(lines) + (b"\n" if lines else b"")
write_bound_regular(output, payload)
PY_SERIALIZER
  local serializer_rc=$?
  if [ "$serializer_rc" -ne 0 ]; then
    if [ "${FM_SERIALIZER_EXPECT_FAILURE:-0}" = 1 ]; then
      return "$serializer_rc"
    fi
    fail "filesystem serializer"
  fi
}
raw_manifest() {
  local output=$1; shift
  serialize_tree rawhex "$output" "${MATRIX_RERUN_ROOT:-$TMP_ROOT}" - "$@"
}
fs_manifest() {
  local root=$1 output=$2
  serialize_tree rawhex "$output" "${MATRIX_RERUN_ROOT:-$TMP_ROOT}" - . "$root" .
}
roots_manifest() {
  local data_root=$1 state_root=$2 output=$3
  serialize_tree rawhex "$output" "${MATRIX_RERUN_ROOT:-$TMP_ROOT}" - D "$data_root" D S "$state_root" S
}
ds_manifest() { roots_manifest "$DATA_ROOT" "$STATE_ROOT" "$1"; }

HOME_ROOT="$TMP_ROOT/outer/home"
DATA_ROOT="$TMP_ROOT/outer/data"
STATE_ROOT="$TMP_ROOT/outer/state"
mkdir -p "$HOME_ROOT" "$DATA_ROOT" "$STATE_ROOT"
chmod 0755 "$TMP_ROOT/outer" "$HOME_ROOT" "$DATA_ROOT" "$STATE_ROOT"
IDENTITY_EMPTY="$TMP_ROOT/identity-empty.json"
printf '%s\n' '{"namespace_id":[],"cmdline_sha256":[],"boot_id":[],"hostname":[],"pid":[],"start_ticks":[]}' >"$IDENTITY_EMPTY"
chmod 0600 "$IDENTITY_EMPTY"
SERIALIZER_IDENTITY_FILE="$IDENTITY_EMPTY"
mkdir -p "$TMP_ROOT/inputs"
cat >"$TMP_ROOT/inputs/contract.json" <<'JSON'
{"schema_version":"slice-contract/v1","slice_id":"s","goal_id":"g","purpose":"lease","type":"ship","depends_on":[],"immutable_inputs":[],"outputs":["x"],"claims":[{"resource":"path:///tmp","mode":"exclusive"}],"worktree":"/tmp/wt","harness":"codex","model":"m","effort":"high","acceptance":["x"],"validation_commands":["true"],"expected_evidence":["x"],"context_budget":{"source_tokens":1,"report_words":1},"gates":["x"],"implementer":"x","independent_validators":["v"],"authorized_exceptions":[]}
JSON
CONTRACT_SHA=$(sha256sum "$TMP_ROOT/inputs/contract.json" | awk '{print $1}')
cat >"$TMP_ROOT/inputs/graph.json" <<JSON
{"schema_version":"workgraph/v1","goal_id":"g","slices":[{"slice_id":"s","contract_path":"contract.json","contract_sha256":"$CONTRACT_SHA"}]}
JSON
printf '%s\n' '{"schema_version":"resource-registry/v1","instances":[]}' >"$TMP_ROOT/inputs/registry.json"

if [ "$MATRIX_CASE_MODE" -eq 0 ]; then
HELP_TEXT=$("$ROOT/bin/fm-workgraph.sh" --help)
for lease_help in \
  'fm-workgraph.sh acquire <graph.json> <slice-id> --registry <registry.json> --lease-id <id> --holder-id <id> --holder-pid <pid>' \
  'fm-workgraph.sh release <goal-id> --lease-id <id> --holder-id <id> --fencing-token <token>' \
  'fm-workgraph.sh inspect <goal-id> [--lease-id <id>] [--history]' \
  'fm-workgraph.sh fence <goal-id> --lease-id <id> --holder-id <id> --fencing-token <token>' \
  'fm-workgraph.sh recover <goal-id> --lease-id <id> --actor-id <id>'; do
  grep -Fqx "  $lease_help" <<<"$HELP_TEXT" || fail "public lease help: $lease_help"
done
for malformed in \
  'acquire' \
  'release g' \
  'inspect g --history --history' \
  'fence g --lease-id l --holder-id h' \
  'recover g --lease-id l'; do
  read -r -a malformed_args <<<"$malformed"
  set +e
  FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$DATA_ROOT" FM_STATE_OVERRIDE="$STATE_ROOT" "$ROOT/bin/fm-workgraph.sh" "${malformed_args[@]}" >"$TMP_ROOT/err.out" 2>"$TMP_ROOT/err"
  RC=$?
  set -e
  if ! { [ "$RC" -eq 2 ] && [ ! -s "$TMP_ROOT/err.out" ] && grep -qx 'fm-workgraph: WG-L-E-USAGE: lease operation failed' "$TMP_ROOT/err"; }; then fail "public lease usage: $malformed"; fi
done
ok "public lease help and malformed grammar"

set +e
FM_WORKGRAPH_LEASE_DEBUG=1 FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$DATA_ROOT" FM_STATE_OVERRIDE="$STATE_ROOT" "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/missing-graph.json" s --registry "$TMP_ROOT/inputs/registry.json" --lease-id l-debug --holder-id h --holder-pid "$$" >"$TMP_ROOT/debug.out" 2>"$TMP_ROOT/debug.err"
RC=$?
set -e
if ! { [ "$RC" -eq 1 ] && [ ! -s "$TMP_ROOT/debug.out" ] && cmp <(printf '%s\n' 'fm-workgraph: WG-L-E-CAPTURE: lease operation failed') "$TMP_ROOT/debug.err" >/dev/null; }; then fail "debug environment preserves exact failure bytes"; fi
ok "debug environment cannot emit a diagnostic stack"

set +e
FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$DATA_ROOT" FM_STATE_OVERRIDE="$STATE_ROOT" "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/missing-graph.json" s --registry "$TMP_ROOT/inputs/registry.json" --lease-id 'bad/id' --holder-id h --holder-pid bad >"$TMP_ROOT/err.out" 2>"$TMP_ROOT/err"
RC=$?
set -e
if ! { [ "$RC" -eq 1 ] && [ ! -s "$TMP_ROOT/err.out" ] && grep -qx 'fm-workgraph: WG-L-E-CAPTURE: lease operation failed' "$TMP_ROOT/err"; }; then fail "capture outranks invalid acquire values"; fi
set +e
FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$DATA_ROOT" FM_STATE_OVERRIDE="$STATE_ROOT" "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/graph.json" bad/id --registry "$TMP_ROOT/inputs/registry.json" --lease-id lbad --holder-id h --holder-pid "$$" >"$TMP_ROOT/err.out" 2>"$TMP_ROOT/err"
RC=$?
set -e
if ! { [ "$RC" -eq 1 ] && grep -qx 'fm-workgraph: WG-L-E-SCHEMA: lease operation failed' "$TMP_ROOT/err"; }; then fail "invalid selector is SCHEMA after graph capture"; fi
set +e
FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$DATA_ROOT" FM_STATE_OVERRIDE="$STATE_ROOT" "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/graph.json" s --registry "$TMP_ROOT/inputs/registry.json" --lease-id labsent --holder-id h --holder-pid 999999999 >"$TMP_ROOT/err.out" 2>"$TMP_ROOT/err"
RC=$?
set -e
if ! { [ "$RC" -eq 1 ] && grep -qx 'fm-workgraph: WG-L-E-IDENTITY: lease operation failed' "$TMP_ROOT/err"; }; then fail "valid absent PID is IDENTITY"; fi
set +e
FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$DATA_ROOT" FM_STATE_OVERRIDE="$STATE_ROOT" "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/graph.json" absent --registry "$TMP_ROOT/inputs/registry.json" --lease-id lmissing --holder-id h --holder-pid "$$" >"$TMP_ROOT/err.out" 2>"$TMP_ROOT/err"
RC=$?
set -e
if ! { [ "$RC" -eq 1 ] && grep -qx 'fm-workgraph: WG-L-E-CAPTURE: lease operation failed' "$TMP_ROOT/err"; }; then fail "valid missing selector is CAPTURE"; fi
printf '%s\n' '{' >"$TMP_ROOT/inputs/malformed-graph.json"
set +e
FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$DATA_ROOT" FM_STATE_OVERRIDE="$STATE_ROOT" "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/malformed-graph.json" s --registry "$TMP_ROOT/inputs/missing-registry.json" --lease-id lbadcapture --holder-id h --holder-pid "$$" >"$TMP_ROOT/err.out" 2>"$TMP_ROOT/err"
RC=$?
set -e
if ! { [ "$RC" -eq 1 ] && grep -qx 'fm-workgraph: WG-L-E-CAPTURE: lease operation failed' "$TMP_ROOT/err"; }; then fail "malformed graph plus missing registry is CAPTURE"; fi
set +e
FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$DATA_ROOT" FM_STATE_OVERRIDE="$STATE_ROOT" "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/graph.json" s --registry "$TMP_ROOT/inputs/missing-registry.json" --lease-id bad/id --holder-id h --holder-pid bad >"$TMP_ROOT/err.out" 2>"$TMP_ROOT/err"
RC=$?
set -e
if ! { [ "$RC" -eq 1 ] && grep -qx 'fm-workgraph: WG-L-E-CAPTURE: lease operation failed' "$TMP_ROOT/err"; }; then fail "invalid acquire values plus missing registry is CAPTURE"; fi
printf '%s\n' '{"schema_version":"workgraph/v1","goal_id":"g","slices":[{"slice_id":"s","contract_path":"missing-contract.json","contract_sha256":"0000000000000000000000000000000000000000000000000000000000000000"}]}' >"$TMP_ROOT/inputs/missing-contract-graph.json"
for missing_contract_collision in lease holder pid; do
  case "$missing_contract_collision" in
    lease) missing_contract_lease='bad/id'; missing_contract_holder=h; missing_contract_pid=$$ ;;
    holder) missing_contract_lease=lmissing; missing_contract_holder='bad/id'; missing_contract_pid=$$ ;;
    pid) missing_contract_lease=lmissing; missing_contract_holder=h; missing_contract_pid=bad ;;
  esac
  set +e
  FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$DATA_ROOT" FM_STATE_OVERRIDE="$STATE_ROOT" "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/missing-contract-graph.json" s --registry "$TMP_ROOT/inputs/registry.json" --lease-id "$missing_contract_lease" --holder-id "$missing_contract_holder" --holder-pid "$missing_contract_pid" >"$TMP_ROOT/err.out" 2>"$TMP_ROOT/err"
  RC=$?
  set -e
  if ! { [ "$RC" -eq 1 ] && grep -qx 'fm-workgraph: WG-L-E-CAPTURE: lease operation failed' "$TMP_ROOT/err"; }; then fail "missing selected contract capture $missing_contract_collision"; fi
done
ok "capture/schema/identity precedence fixtures"

for incoming_umask in 000 022 077 777; do
  UMASK_HOME="$TMP_ROOT/umask-$incoming_umask"
  UMASK_DATA="$UMASK_HOME/data"
  UMASK_STATE="$UMASK_HOME/state"
  mkdir -p "$UMASK_DATA" "$UMASK_STATE"
  set +e
  ( umask "$incoming_umask"; FM_HOME="$UMASK_HOME" FM_DATA_OVERRIDE="$UMASK_DATA" FM_STATE_OVERRIDE="$UMASK_STATE" "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/graph.json" s --registry "$TMP_ROOT/inputs/registry.json" --lease-id "umask-$incoming_umask" --holder-id h --holder-pid "$$" >"$TMP_ROOT/umask-$incoming_umask.out" 2>"$TMP_ROOT/umask-$incoming_umask.err" )
  RC=$?
  set -e
  [ "$RC" -eq 0 ] && [ ! -s "$TMP_ROOT/umask-$incoming_umask.err" ] || fail "umask $incoming_umask acquire"
  for mode_path in "$UMASK_DATA/workgraphs" "$UMASK_DATA/workgraphs/.leases" "$UMASK_DATA/workgraphs/.leases/v1" "$UMASK_DATA/workgraphs/.leases/v1/records" "$UMASK_DATA/workgraphs/.leases/v1/events" "$UMASK_DATA/workgraphs/.leases/v1/records/g" "$UMASK_DATA/workgraphs/.leases/v1/records/g/umask-$incoming_umask" "$UMASK_STATE/workgraphs" "$UMASK_STATE/workgraphs/g"; do
    [ "$(stat -c '%a' "$mode_path")" = 700 ] || fail "umask $incoming_umask directory mode $mode_path"
  done
  for mode_path in "$UMASK_DATA/workgraphs/.leases/v1/namespace.json" "$UMASK_DATA/workgraphs/.leases/v1/fencing-counter" "$UMASK_DATA/workgraphs/.leases/v1/transaction-generation" "$UMASK_DATA/workgraphs/.leases/v1/.transaction-lock" "$UMASK_DATA/workgraphs/.leases/v1/transaction-owner.json" "$UMASK_DATA/workgraphs/.leases/v1/records/g/umask-$incoming_umask/1.json" "$UMASK_DATA/workgraphs/.leases/v1/events/00000000000000000001.json" "$UMASK_STATE/workgraphs/g/leases.v1.json"; do
    [ "$(stat -c '%a' "$mode_path")" = 600 ] || fail "umask $incoming_umask file mode $mode_path"
  done
done
ok "incoming umasks converge to exact 0700/0600 authority and cache modes"

capability_failure_case() {
  local name=$1 hook=$2
  local cap_home="$TMP_ROOT/capability-$name"
  local cap_data="$cap_home/data"
  local cap_state="$cap_home/state"
  local hook_dir="$cap_home/hook"
  mkdir -p "$cap_data" "$cap_state" "$hook_dir"
  if [ "$hook" = "node" ]; then
    printf '%s\n' unavailable >"$cap_home/not-node"
  else
    case "$hook" in
      flock) printf '%s\n' 'import fcntl; fcntl.flock = lambda *args: (_ for _ in ()).throw(OSError("flock"))' >"$hook_dir/sitecustomize.py" ;;
      proc-locks)
        cat >"$hook_dir/sitecustomize.py" <<'PY_CAP_PROC_LOCKS'
import os
_open = os.open
def _blocked(path, *args, **kwargs):
    if path == "/proc/locks":
        raise OSError("proc-locks")
    return _open(path, *args, **kwargs)
os.open = _blocked
PY_CAP_PROC_LOCKS
        ;;
      fsync) printf '%s\n' 'import os; os.fsync = lambda *args: (_ for _ in ()).throw(OSError("fsync"))' >"$hook_dir/sitecustomize.py" ;;
      renameat2)
        cat >"$hook_dir/sitecustomize.py" <<'PY_CAP_RENAME'
import ctypes
_real_cdll = ctypes.CDLL
class _NoRename:
    def __init__(self, value):
        self._value = value
    def __getattr__(self, name):
        if name == "renameat2":
            raise AttributeError(name)
        return getattr(self._value, name)
def _cdll(name, *args, **kwargs):
    return self._value(name, *args, **kwargs)
_cdll._value = _real_cdll
def _patched_cdll(name, *args, **kwargs):
    value = _real_cdll(name, *args, **kwargs)
    return value if name is None else _NoRename(value)
ctypes.CDLL = _patched_cdll
PY_CAP_RENAME
        ;;
    esac
  fi
  if [ "$hook" = "proc-locks" ]; then
    printf '%s\n' permitted >"$cap_home/permitted"
    if ! PYTHONPATH="$hook_dir" python3 - "$cap_home/permitted" <<'PY_CAP_PROC_PROBE'
import os
import sys
fd = os.open(sys.argv[1], os.O_RDONLY)
os.close(fd)
try:
    os.open("/proc/locks", os.O_RDONLY)
except OSError as error:
    if str(error) != "proc-locks":
        raise
else:
    raise SystemExit("proc-locks fixture did not intercept exact path")
PY_CAP_PROC_PROBE
    then fail "proc-locks fixture hook"; fi
  fi
  roots_manifest "$cap_data" "$cap_state" "$cap_home/before"
  set +e
  if [ "$hook" = "node" ]; then
    env -u PYTHONPATH NODE="$cap_home/not-node" FM_HOME="$cap_home" FM_DATA_OVERRIDE="$cap_data" FM_STATE_OVERRIDE="$cap_state" "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/graph.json" s --registry "$TMP_ROOT/inputs/registry.json" --lease-id "cap-$name" --holder-id h --holder-pid "$$" >"$cap_home/stdout" 2>"$cap_home/stderr"
  else
    env NODE=node PYTHONPATH="$hook_dir" FM_HOME="$cap_home" FM_DATA_OVERRIDE="$cap_data" FM_STATE_OVERRIDE="$cap_state" "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/graph.json" s --registry "$TMP_ROOT/inputs/registry.json" --lease-id "cap-$name" --holder-id h --holder-pid "$$" >"$cap_home/stdout" 2>"$cap_home/stderr"
  fi
  RC=$?
  set -e
  roots_manifest "$cap_data" "$cap_state" "$cap_home/after"
  if ! { [ "$RC" -eq 1 ] && [ ! -s "$cap_home/stdout" ] && grep -qx 'fm-workgraph: WG-L-E-STORE: lease operation failed' "$cap_home/stderr" && cmp "$cap_home/before" "$cap_home/after"; }; then fail "capability preflight $name"; fi
}
capability_failure_case node node
capability_failure_case flock flock
capability_failure_case proc-locks proc-locks
capability_failure_case fsync fsync
capability_failure_case renameat2 renameat2
ok "runtime and publication capabilities fail STORE before fresh-authority mutation"

ABSENT_CACHE_DATA="$TMP_ROOT/absent-cache/data"
ABSENT_CACHE_STATE="$TMP_ROOT/absent-cache/state"
mkdir -p "$ABSENT_CACHE_DATA" "$ABSENT_CACHE_STATE/workgraphs/g"
roots_manifest "$ABSENT_CACHE_DATA" "$ABSENT_CACHE_STATE" "$TMP_ROOT/absent-cache-before"
run env FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$ABSENT_CACHE_DATA" FM_STATE_OVERRIDE="$ABSENT_CACHE_STATE" "$ROOT/bin/fm-workgraph-lease-lib.sh" status g
if ! { [ "$RC" -eq 0 ] && grep -qx 'lease_cache=absent' <<<"$OUT"; }; then fail "absent authority absent cache"; fi
printf '%s\n' stale >"$ABSENT_CACHE_STATE/workgraphs/g/leases.v1.json"
for cache_kind in regular symlink directory fifo; do
  [ "$cache_kind" = regular ] || rm -f "$ABSENT_CACHE_STATE/workgraphs/g/leases.v1.json"
  case "$cache_kind" in
    symlink) ln -s /dev/null "$ABSENT_CACHE_STATE/workgraphs/g/leases.v1.json" ;;
    directory) mkdir "$ABSENT_CACHE_STATE/workgraphs/g/leases.v1.json" ;;
    fifo) mkfifo "$ABSENT_CACHE_STATE/workgraphs/g/leases.v1.json" ;;
  esac
  run env FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$ABSENT_CACHE_DATA" FM_STATE_OVERRIDE="$ABSENT_CACHE_STATE" "$ROOT/bin/fm-workgraph-lease-lib.sh" status g
  if ! { [ "$RC" -eq 0 ] && grep -qx 'lease_cache=present' <<<"$OUT"; }; then fail "absent authority cache presence $cache_kind"; fi
  case "$cache_kind" in directory) rmdir "$ABSENT_CACHE_STATE/workgraphs/g/leases.v1.json" ;; fifo|symlink) rm -f "$ABSENT_CACHE_STATE/workgraphs/g/leases.v1.json" ;; esac
done
ABSENT_CACHE_EXTERNAL="$TMP_ROOT/absent-cache-external"
mkdir -p "$ABSENT_CACHE_EXTERNAL/g"
printf '%s\n' external >"$ABSENT_CACHE_EXTERNAL/g/leases.v1.json"
mv "$ABSENT_CACHE_STATE/workgraphs" "$ABSENT_CACHE_STATE/workgraphs.real"
ln -s "$ABSENT_CACHE_EXTERNAL" "$ABSENT_CACHE_STATE/workgraphs"
run env FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$ABSENT_CACHE_DATA" FM_STATE_OVERRIDE="$ABSENT_CACHE_STATE" "$ROOT/bin/fm-workgraph-lease-lib.sh" status g
if ! { [ "$RC" -eq 0 ] && grep -qx 'lease_cache=present' <<<"$OUT"; }; then fail "absent authority intermediate cache symlink presence"; fi
rm "$ABSENT_CACHE_STATE/workgraphs"
mv "$ABSENT_CACHE_STATE/workgraphs.real" "$ABSENT_CACHE_STATE/workgraphs"
roots_manifest "$ABSENT_CACHE_DATA" "$ABSENT_CACHE_STATE" "$TMP_ROOT/absent-cache-after"
cmp "$TMP_ROOT/absent-cache-before" "$TMP_ROOT/absent-cache-after" || fail "absent cache status mutation"
ok "absent authority cache presence is nonfollowing and nonmutating"

ds_manifest "$TMP_ROOT/absent-before"
set +e
FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$DATA_ROOT" FM_STATE_OVERRIDE="$STATE_ROOT" "$ROOT/bin/fm-workgraph-lease-lib.sh" release g --lease-id missing --holder-id h --fencing-token 1 >"$TMP_ROOT/err.out" 2>"$TMP_ROOT/err"
RC=$?
set -e
ds_manifest "$TMP_ROOT/absent-after-release"
if ! { [ "$RC" -eq 1 ] && [ ! -s "$TMP_ROOT/err.out" ] && grep -qx 'fm-workgraph: WG-L-E-NOT-RECONSTRUCTABLE: lease operation failed' "$TMP_ROOT/err" && cmp "$TMP_ROOT/absent-before" "$TMP_ROOT/absent-after-release"; }; then fail "absent release zero mutation"; fi
set +e
FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$DATA_ROOT" FM_STATE_OVERRIDE="$STATE_ROOT" "$ROOT/bin/fm-workgraph-lease-lib.sh" recover g --lease-id missing --actor-id actor >"$TMP_ROOT/err.out" 2>"$TMP_ROOT/err"
RC=$?
set -e
ds_manifest "$TMP_ROOT/absent-after-recover"
if ! { [ "$RC" -eq 1 ] && [ ! -s "$TMP_ROOT/err.out" ] && grep -qx 'fm-workgraph: WG-L-E-NOT-RECONSTRUCTABLE: lease operation failed' "$TMP_ROOT/err" && cmp "$TMP_ROOT/absent-before" "$TMP_ROOT/absent-after-recover"; }; then fail "absent recover zero mutation"; fi
ok "absent release/recover preserve D/S"

run "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/graph.json" s --registry "$TMP_ROOT/inputs/registry.json" --lease-id l1 --holder-id h1 --holder-pid "$$"
[ "$RC" -eq 0 ] || fail "acquire"
[ ! -s "$TMP_ROOT/err" ] || fail "acquire emitted unexpected stderr or traceback"
printf '%s' "$OUT" | jq -e '.state=="held" and .holder_fencing_token=="1" and .current_fencing_token=="1"' >/dev/null || fail "acquire result"
ok "acquire and canonical result"

STORE="$DATA_ROOT/workgraphs/.leases/v1"
cp "$STORE/namespace.json" "$TMP_ROOT/status-namespace.original"
printf '{' >"$STORE/namespace.json"
set +e
FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$DATA_ROOT" FM_STATE_OVERRIDE="$STATE_ROOT" "$ROOT/bin/fm-workgraph.sh" status "$TMP_ROOT/inputs/graph.json" >"$TMP_ROOT/err.out" 2>"$TMP_ROOT/err"
RC=$?
set -e
mv "$TMP_ROOT/status-namespace.original" "$STORE/namespace.json"
if ! { [ "$RC" -eq 1 ] && [ ! -s "$TMP_ROOT/err.out" ] && grep -qx 'fm-workgraph: WG-L-E-NOT-RECONSTRUCTABLE: lease operation failed' "$TMP_ROOT/err"; }; then fail "one-node corrupt status output atomicity"; fi
chmod 0755 "$STORE"
set +e
FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$DATA_ROOT" FM_STATE_OVERRIDE="$STATE_ROOT" "$ROOT/bin/fm-workgraph.sh" status "$TMP_ROOT/inputs/graph.json" >"$TMP_ROOT/err.out" 2>"$TMP_ROOT/err"
RC=$?
set -e
chmod 0700 "$STORE"
if ! { [ "$RC" -eq 1 ] && [ ! -s "$TMP_ROOT/err.out" ] && grep -qx 'fm-workgraph: WG-L-E-STORE: lease operation failed' "$TMP_ROOT/err"; }; then fail "one-node unsafe-store status output atomicity"; fi
ok "one-node status buffers all output until lease reopen succeeds"

[ "$(stat -c '%a' "$STORE")" = 700 ] || fail "authority root mode"
[ "$(stat -c '%a' "$TMP_ROOT/outer")" = 755 ] || fail "outer ancestor preserved"
ok "0755 outer ancestor with 0700 lease authority root"

set +e
FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$DATA_ROOT" FM_STATE_OVERRIDE="$STATE_ROOT" "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/graph.json" s --registry "$TMP_ROOT/inputs/registry.json" --lease-id l-conflict --holder-id h-conflict --holder-pid "$$" >"$TMP_ROOT/err.out" 2>"$TMP_ROOT/err"
RC=$?
set -e
if ! { [ "$RC" -eq 1 ] && [ ! -s "$TMP_ROOT/err.out" ] && grep -qx 'fm-workgraph: WG-L-E-CONFLICT: lease operation failed' "$TMP_ROOT/err"; }; then fail "captured-helper conflicting acquire"; fi
ok "captured-helper conflicting acquire"

jq '.slice_id="sr" | .claims=[{"resource":"path:///tmp/read-only","mode":"read"}]' "$TMP_ROOT/inputs/contract.json" >"$TMP_ROOT/inputs/read-contract.json"
READ_CONTRACT_SHA=$(sha256sum "$TMP_ROOT/inputs/read-contract.json" | awk '{print $1}')
printf '%s\n' "{\"schema_version\":\"workgraph/v1\",\"goal_id\":\"g\",\"slices\":[{\"slice_id\":\"sr\",\"contract_path\":\"read-contract.json\",\"contract_sha256\":\"$READ_CONTRACT_SHA\"}]}" >"$TMP_ROOT/inputs/read-graph.json"
printf '%s\n' '{"schema_version":"resource-registry/v1","instances":[{"id":"read-only","namespace":"path","resource":"path:///tmp/read-only","aliases":[],"contains":[]}]}' >"$TMP_ROOT/inputs/read-registry.json"
jq '.slice_id="sx" | .claims=[{"resource":"path:///tmp/read-only","mode":"exclusive"}]' "$TMP_ROOT/inputs/contract.json" >"$TMP_ROOT/inputs/exclusive-contract.json"
EXCLUSIVE_CONTRACT_SHA=$(sha256sum "$TMP_ROOT/inputs/exclusive-contract.json" | awk '{print $1}')
printf '%s\n' "{\"schema_version\":\"workgraph/v1\",\"goal_id\":\"g\",\"slices\":[{\"slice_id\":\"sx\",\"contract_path\":\"exclusive-contract.json\",\"contract_sha256\":\"$EXCLUSIVE_CONTRACT_SHA\"}]}" >"$TMP_ROOT/inputs/exclusive-graph.json"
COMPAT_HOME="$TMP_ROOT/compatible-home"
COMPAT_DATA="$COMPAT_HOME/data"
COMPAT_STATE="$COMPAT_HOME/state"
mkdir -p "$COMPAT_DATA" "$COMPAT_STATE"
set +e
FM_HOME="$COMPAT_HOME" FM_DATA_OVERRIDE="$COMPAT_DATA" FM_STATE_OVERRIDE="$COMPAT_STATE" "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/read-graph.json" sr --registry "$TMP_ROOT/inputs/read-registry.json" --lease-id lr1 --holder-id hr1 --holder-pid "$$" >"$TMP_ROOT/compat-lr1.out" 2>"$TMP_ROOT/compat-lr1.err"
RC=$?
set -e
if ! { [ "$RC" -eq 0 ] && [ ! -s "$TMP_ROOT/compat-lr1.err" ]; }; then fail "captured-helper first compatible acquire"; fi
COMPAT_TOKEN1=$(jq -r '.holder_fencing_token' "$TMP_ROOT/compat-lr1.out")
set +e
FM_HOME="$COMPAT_HOME" FM_DATA_OVERRIDE="$COMPAT_DATA" FM_STATE_OVERRIDE="$COMPAT_STATE" "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/read-graph.json" sr --registry "$TMP_ROOT/inputs/read-registry.json" --lease-id lr2 --holder-id hr2 --holder-pid "$$" >"$TMP_ROOT/compat-lr2.out" 2>"$TMP_ROOT/compat-lr2.err"
RC=$?
set -e
if ! { [ "$RC" -eq 0 ] && [ ! -s "$TMP_ROOT/compat-lr2.err" ]; }; then fail "captured-helper second compatible acquire"; fi
COMPAT_TOKEN2=$(jq -r '.holder_fencing_token' "$TMP_ROOT/compat-lr2.out")
if ! { [ "$COMPAT_TOKEN1" = 1 ] && [ "$COMPAT_TOKEN2" = 2 ] && [ "$COMPAT_TOKEN1" != "$COMPAT_TOKEN2" ]; }; then fail "captured-helper compatible fencing tokens"; fi
set +e
roots_manifest "$COMPAT_DATA" "$COMPAT_STATE" "$TMP_ROOT/compat-before-exclusive"
FM_HOME="$COMPAT_HOME" FM_DATA_OVERRIDE="$COMPAT_DATA" FM_STATE_OVERRIDE="$COMPAT_STATE" "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/exclusive-graph.json" sx --registry "$TMP_ROOT/inputs/read-registry.json" --lease-id lx --holder-id hx --holder-pid "$$" >"$TMP_ROOT/compat-exclusive.out" 2>"$TMP_ROOT/compat-exclusive.err"
RC=$?
set -e
roots_manifest "$COMPAT_DATA" "$COMPAT_STATE" "$TMP_ROOT/compat-after-exclusive"
if ! { [ "$RC" -eq 1 ] && [ ! -s "$TMP_ROOT/compat-exclusive.out" ] && grep -qx 'fm-workgraph: WG-L-E-CONFLICT: lease operation failed' "$TMP_ROOT/compat-exclusive.err" && cmp "$TMP_ROOT/compat-before-exclusive" "$TMP_ROOT/compat-after-exclusive" >/dev/null; }; then fail "captured-helper exclusive overlap"; fi
cat >"$TMP_ROOT/compat-status.expected" <<'COMPAT_STATUS_EXPECTED'
lease_store=ready
lease_cache=present
lease_active_count=2
lease_terminal_count=0
lease_fencing=monotonic
lease_enforcement=available
COMPAT_STATUS_EXPECTED
FM_HOME="$COMPAT_HOME" FM_DATA_OVERRIDE="$COMPAT_DATA" FM_STATE_OVERRIDE="$COMPAT_STATE" "$ROOT/bin/fm-workgraph-lease-lib.sh" status g >"$TMP_ROOT/compat-status.out" 2>"$TMP_ROOT/compat-status.err"
if ! { [ ! -s "$TMP_ROOT/compat-status.err" ] && cmp "$TMP_ROOT/compat-status.expected" "$TMP_ROOT/compat-status.out" >/dev/null; }; then fail "captured-helper compatible status"; fi
FM_HOME="$COMPAT_HOME" FM_DATA_OVERRIDE="$COMPAT_DATA" FM_STATE_OVERRIDE="$COMPAT_STATE" "$ROOT/bin/fm-workgraph-lease-lib.sh" inspect g --lease-id lr1 >"$TMP_ROOT/compat-inspect.out" 2>"$TMP_ROOT/compat-inspect.err"
if ! { [ ! -s "$TMP_ROOT/compat-inspect.err" ] && cmp "$COMPAT_DATA/workgraphs/.leases/v1/records/g/lr1/1.json" "$TMP_ROOT/compat-inspect.out" >/dev/null && jq -e '.goal_id=="g" and .lease_id=="lr1" and .holder_id=="hr1" and .holder_fencing_token=="1" and .current_fencing_token=="1"' "$TMP_ROOT/compat-inspect.out" >/dev/null; }; then fail "captured-helper compatible inspect"; fi
ok "captured-helper compatible read/read acquires, overlap conflict, status, and inspect"

DRIFT_HOME="$TMP_ROOT/drift-home"; DRIFT_DATA="$DRIFT_HOME/data"; DRIFT_STATE="$DRIFT_HOME/state"; mkdir -p "$DRIFT_DATA" "$DRIFT_STATE"
jq '.slice_id="project" | .claims=[{"resource":"docker://project/p1","mode":"exclusive"}]' "$TMP_ROOT/inputs/contract.json" >"$TMP_ROOT/inputs/project-contract.json"
PROJECT_CONTRACT_SHA=$(sha256sum "$TMP_ROOT/inputs/project-contract.json" | awk '{print $1}')
printf '%s\n' "{\"schema_version\":\"workgraph/v1\",\"goal_id\":\"g\",\"slices\":[{\"slice_id\":\"project\",\"contract_path\":\"project-contract.json\",\"contract_sha256\":\"$PROJECT_CONTRACT_SHA\"}]}" >"$TMP_ROOT/inputs/project-graph.json"
printf '%s\n' '{"schema_version":"resource-registry/v1","instances":[{"id":"project","namespace":"docker","resource":"docker://project/p1","aliases":[],"contains":[]}]}' >"$TMP_ROOT/inputs/project-registry.json"
run env FM_HOME="$DRIFT_HOME" FM_DATA_OVERRIDE="$DRIFT_DATA" FM_STATE_OVERRIDE="$DRIFT_STATE" "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/project-graph.json" project --registry "$TMP_ROOT/inputs/project-registry.json" --lease-id lproject --holder-id hproject --holder-pid "$$"
[ "$RC" -eq 0 ] || fail "registry drift project seed"
jq '.slice_id="network" | .claims=[{"resource":"docker://network/n1","mode":"exclusive"}]' "$TMP_ROOT/inputs/contract.json" >"$TMP_ROOT/inputs/network-contract.json"
NETWORK_CONTRACT_SHA=$(sha256sum "$TMP_ROOT/inputs/network-contract.json" | awk '{print $1}')
printf '%s\n' "{\"schema_version\":\"workgraph/v1\",\"goal_id\":\"g\",\"slices\":[{\"slice_id\":\"network\",\"contract_path\":\"network-contract.json\",\"contract_sha256\":\"$NETWORK_CONTRACT_SHA\"}]}" >"$TMP_ROOT/inputs/network-graph.json"
printf '%s\n' '{"schema_version":"resource-registry/v1","instances":[{"id":"project","namespace":"docker","resource":"docker://project/p1","aliases":["docker://project/alias"],"contains":["network"]},{"id":"network","namespace":"docker","resource":"docker://network/n1","aliases":[],"contains":[]}]}' >"$TMP_ROOT/inputs/network-registry.json"
set +e
FM_HOME="$DRIFT_HOME" FM_DATA_OVERRIDE="$DRIFT_DATA" FM_STATE_OVERRIDE="$DRIFT_STATE" "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/network-graph.json" network --registry "$TMP_ROOT/inputs/network-registry.json" --lease-id lnetwork --holder-id hnetwork --holder-pid "$$" >"$TMP_ROOT/err.out" 2>"$TMP_ROOT/err"
RC=$?
set -e
if ! { [ "$RC" -eq 1 ] && grep -qx 'fm-workgraph: WG-L-E-CONFLICT: lease operation failed' "$TMP_ROOT/err"; }; then fail "registry drift contained network conflict"; fi
run env FM_HOME="$DRIFT_HOME" FM_DATA_OVERRIDE="$DRIFT_DATA" FM_STATE_OVERRIDE="$DRIFT_STATE" "$ROOT/bin/fm-workgraph-lease-lib.sh" status g
if ! { [ "$RC" -eq 0 ] && grep -qx 'lease_store=ready' <<<"$OUT"; }; then fail "registry drift status-ready"; fi
ok "registry drift Docker containment and alias revision fail closed"

OVERFLOW_HOME="$TMP_ROOT/overflow-home"
OVERFLOW_DATA="$OVERFLOW_HOME/data"
OVERFLOW_STATE="$OVERFLOW_HOME/state"
OVERFLOW_STORE="$OVERFLOW_DATA/workgraphs/.leases/v1"
mkdir -p "$OVERFLOW_DATA" "$OVERFLOW_STATE"
set +e
FM_HOME="$OVERFLOW_HOME" FM_DATA_OVERRIDE="$OVERFLOW_DATA" FM_STATE_OVERRIDE="$OVERFLOW_STATE" "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/read-graph.json" sr --registry "$TMP_ROOT/inputs/read-registry.json" --lease-id ldrift --holder-id hdrift --holder-pid "$$" >"$TMP_ROOT/overflow-seed.out" 2>"$TMP_ROOT/overflow-seed.err"
RC=$?
set -e
if ! { [ "$RC" -eq 0 ] && [ ! -s "$TMP_ROOT/overflow-seed.err" ]; }; then fail "counter overflow seed"; fi

COUNTER_SAVED=$(cat "$OVERFLOW_STORE/fencing-counter")
COUNTER_MODE=$(stat -c '%a' "$OVERFLOW_STORE/fencing-counter")
DRIFT_TOKEN=$(jq -r '.holder_fencing_token' "$OVERFLOW_STORE/records/g/ldrift/1.json")
printf '%s\n' 9223372036854775807 >"$OVERFLOW_STORE/fencing-counter"
chmod 0600 "$OVERFLOW_STORE/fencing-counter"
roots_manifest "$OVERFLOW_DATA" "$OVERFLOW_STATE" "$TMP_ROOT/held-overflow-before"
set +e
FM_HOME="$OVERFLOW_HOME" FM_DATA_OVERRIDE="$OVERFLOW_DATA" FM_STATE_OVERRIDE="$OVERFLOW_STATE" "$ROOT/bin/fm-workgraph-lease-lib.sh" release g --lease-id ldrift --holder-id hdrift --fencing-token "$DRIFT_TOKEN" >"$TMP_ROOT/err.out" 2>"$TMP_ROOT/err"
RC=$?
set -e
roots_manifest "$OVERFLOW_DATA" "$OVERFLOW_STATE" "$TMP_ROOT/held-overflow-after"
if ! { [ "$RC" -eq 1 ] && [ ! -s "$TMP_ROOT/err.out" ] && grep -qx 'fm-workgraph: WG-L-E-OVERFLOW: lease operation failed' "$TMP_ROOT/err" && cmp "$TMP_ROOT/held-overflow-before" "$TMP_ROOT/held-overflow-after"; }; then fail "release-held counter overflow mutation"; fi

printf '%s\n' "$COUNTER_SAVED" >"$OVERFLOW_STORE/fencing-counter"
chmod "$COUNTER_MODE" "$OVERFLOW_STORE/fencing-counter"
FM_HOME="$OVERFLOW_HOME" FM_DATA_OVERRIDE="$OVERFLOW_DATA" FM_STATE_OVERRIDE="$OVERFLOW_STATE" "$ROOT/bin/fm-workgraph-lease-lib.sh" release g --lease-id ldrift --holder-id hdrift --fencing-token "$DRIFT_TOKEN" >"$TMP_ROOT/overflow-terminal.out" 2>"$TMP_ROOT/overflow-terminal.err"
if ! { [ ! -s "$TMP_ROOT/overflow-terminal.err" ] && [ "$(jq -r '.state' "$TMP_ROOT/overflow-terminal.out")" = released ]; }; then fail "overflow terminal seed"; fi
REV2_SHA_BEFORE=$(sha256sum "$OVERFLOW_STORE/records/g/ldrift/2.json" | awk '{print $1}')
OVERFLOW_EVENT_SHA_BEFORE=$(find "$OVERFLOW_STORE/events" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)
COUNTER_DURABLE=$(cat "$OVERFLOW_STORE/fencing-counter")
printf '%s\n' 9223372036854775807 >"$OVERFLOW_STORE/fencing-counter"
chmod 0600 "$OVERFLOW_STORE/fencing-counter"
TERMINAL_RETRY_GENERATION_BEFORE=$(cat "$OVERFLOW_STORE/transaction-generation")
TERMINAL_RETRY_NAMESPACE_SHA_BEFORE=$(sha256sum "$OVERFLOW_STORE/namespace.json" | awk '{print $1}')
TERMINAL_RETRY_OWNER_SHA_BEFORE=$(sha256sum "$OVERFLOW_STORE/transaction-owner.json" | awk '{print $1}')
roots_manifest "$OVERFLOW_DATA" "$OVERFLOW_STATE" "$TMP_ROOT/terminal-retry-before"
serialize_tree normalized "$TMP_ROOT/terminal-retry-before.normalized" "$TMP_ROOT" "$IDENTITY_EMPTY" D "$OVERFLOW_DATA" D/workgraphs/.leases/v1 S "$OVERFLOW_STATE" S/workgraphs/g
serialize_tree global "$TMP_ROOT/terminal-retry-before.manifest" "$TMP_ROOT" "$IDENTITY_EMPTY" D "$OVERFLOW_DATA" D/workgraphs/.leases/v1 S "$OVERFLOW_STATE" S/workgraphs/g
set +e
FM_HOME="$OVERFLOW_HOME" FM_DATA_OVERRIDE="$OVERFLOW_DATA" FM_STATE_OVERRIDE="$OVERFLOW_STATE" "$ROOT/bin/fm-workgraph-lease-lib.sh" release g --lease-id ldrift --holder-id hdrift --fencing-token "$DRIFT_TOKEN" >"$TMP_ROOT/overflow-terminal-retry.out" 2>"$TMP_ROOT/overflow-terminal-retry.err" &
TERMINAL_RETRY_PID=$!
wait "$TERMINAL_RETRY_PID"
TERMINAL_RETRY_RC=$?
set -e
OVERFLOW_EVENT_SHA_AFTER=$(find "$OVERFLOW_STORE/events" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)
roots_manifest "$OVERFLOW_DATA" "$OVERFLOW_STATE" "$TMP_ROOT/terminal-retry-after"
TERMINAL_RETRY_GENERATION_AFTER=$(cat "$OVERFLOW_STORE/transaction-generation")
TERMINAL_RETRY_OWNER_STATE=$(jq -r '.state' "$OVERFLOW_STORE/transaction-owner.json")
TERMINAL_RETRY_OWNER_GENERATION=$(jq -r '.generation' "$OVERFLOW_STORE/transaction-owner.json")
serialize_tree normalized "$TMP_ROOT/terminal-retry-after.normalized" "$TMP_ROOT" "$IDENTITY_EMPTY" D "$OVERFLOW_DATA" D/workgraphs/.leases/v1 S "$OVERFLOW_STATE" S/workgraphs/g
serialize_tree global "$TMP_ROOT/terminal-retry-after.manifest" "$TMP_ROOT" "$IDENTITY_EMPTY" D "$OVERFLOW_DATA" D/workgraphs/.leases/v1 S "$OVERFLOW_STATE" S/workgraphs/g
serialize_tree mutations "$TMP_ROOT/terminal-retry.mutations" "$TMP_ROOT" "$IDENTITY_EMPTY" "$TMP_ROOT/terminal-retry-before.manifest" "$TMP_ROOT/terminal-retry-after.manifest"
serialize_tree mutations "$TMP_ROOT/terminal-retry.mutations.normalized" "$TMP_ROOT" "$IDENTITY_EMPTY" "$TMP_ROOT/terminal-retry-before.normalized" "$TMP_ROOT/terminal-retry-after.normalized"
TERMINAL_RETRY_GENERATION_DIGEST=$(awk -F '\t' '$2 == "D/workgraphs/.leases/v1/transaction-generation" {print $3}' "$TMP_ROOT/terminal-retry.mutations")
TERMINAL_RETRY_OWNER_DIGEST=$(awk -F '\t' '$2 == "D/workgraphs/.leases/v1/transaction-owner.json" {print $3}' "$TMP_ROOT/terminal-retry.mutations")
TERMINAL_RETRY_CACHE_DIGEST=$(awk -F '\t' '$2 == "S/workgraphs/g/leases.v1.json" {print $3}' "$TMP_ROOT/terminal-retry.mutations")
TERMINAL_RETRY_NAMESPACE=$(jq -r '.namespace_id' "$OVERFLOW_STORE/namespace.json")
TERMINAL_RETRY_OWNER_RAW=$(cat "$OVERFLOW_STORE/transaction-owner.json")
set +e
TERMINAL_RETRY_OWNER_CANONICAL=$(jq -ce --arg namespace "$TERMINAL_RETRY_NAMESPACE" --arg generation "$TERMINAL_RETRY_GENERATION_AFTER" '. as $o | if (($o | keys_unsorted) == ["schema_version","namespace_id","state","generation","pid","start_ticks","cmdline_sha256","boot_id","hostname"] and $o.schema_version == "lease-transaction-owner/v1" and $o.namespace_id == $namespace and $o.state == "released" and $o.generation == $generation and ($o.pid | type) == "string" and ($o.pid | test("^[1-9][0-9]*$")) and ($o.start_ticks | type) == "string" and ($o.start_ticks | test("^[1-9][0-9]*$")) and ($o.cmdline_sha256 | type) == "string" and ($o.cmdline_sha256 | test("^[0-9a-f]{64}$")) and ($o.boot_id | type) == "string" and ($o.boot_id | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and ($o.hostname | type) == "string" and ($o.hostname | test("^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$"))) then $o else error end' "$OVERFLOW_STORE/transaction-owner.json" 2>"$TMP_ROOT/terminal-retry-owner.jq.err")
TERMINAL_RETRY_OWNER_JQ_RC=$?
set -e
TERMINAL_RETRY_OWNER_CANONICAL=${TERMINAL_RETRY_OWNER_CANONICAL%$'\n'}
TERMINAL_RETRY_GENERATION_DIGEST_NORMALIZED=$(awk -F '\t' '$2 == "D/workgraphs/.leases/v1/transaction-generation" {print $3}' "$TMP_ROOT/terminal-retry.mutations.normalized")
TERMINAL_RETRY_OWNER_DIGEST_NORMALIZED=$(awk -F '\t' '$2 == "D/workgraphs/.leases/v1/transaction-owner.json" {print $3}' "$TMP_ROOT/terminal-retry.mutations.normalized")
TERMINAL_RETRY_CACHE_DIGEST_NORMALIZED=$(awk -F '\t' '$2 == "S/workgraphs/g/leases.v1.json" {print $3}' "$TMP_ROOT/terminal-retry.mutations.normalized")
{
  printf 'M\tD/workgraphs/.leases/v1/transaction-generation\t%s\n' "$TERMINAL_RETRY_GENERATION_DIGEST"
  printf 'M\tD/workgraphs/.leases/v1/transaction-owner.json\t%s\n' "$TERMINAL_RETRY_OWNER_DIGEST"
  if [ -n "$TERMINAL_RETRY_CACHE_DIGEST" ]; then
    printf 'M\tS/workgraphs/g/leases.v1.json\t%s\n' "$TERMINAL_RETRY_CACHE_DIGEST"
  fi
} >"$TMP_ROOT/terminal-retry.mutations.expected"
{
  printf 'M\tD/workgraphs/.leases/v1/transaction-generation\t%s\n' "$TERMINAL_RETRY_GENERATION_DIGEST_NORMALIZED"
  printf 'M\tD/workgraphs/.leases/v1/transaction-owner.json\t%s\n' "$TERMINAL_RETRY_OWNER_DIGEST_NORMALIZED"
  if [ -n "$TERMINAL_RETRY_CACHE_DIGEST_NORMALIZED" ]; then
    printf 'M\tS/workgraphs/g/leases.v1.json\t%s\n' "$TERMINAL_RETRY_CACHE_DIGEST_NORMALIZED"
  fi
} >"$TMP_ROOT/terminal-retry.mutations.normalized.expected"
if ! {
  [ "$TERMINAL_RETRY_RC" -eq 0 ] &&
  [ "$TERMINAL_RETRY_OWNER_JQ_RC" -eq 0 ] &&
  [ ! -s "$TMP_ROOT/terminal-retry-owner.jq.err" ] &&
  [ ! -s "$TMP_ROOT/overflow-terminal-retry.err" ] &&
  cmp "$TMP_ROOT/overflow-terminal.out" "$TMP_ROOT/overflow-terminal-retry.out" >/dev/null &&
  [ "$(cat "$OVERFLOW_STORE/fencing-counter")" = 9223372036854775807 ] &&
  [ "$REV2_SHA_BEFORE" = "$(sha256sum "$OVERFLOW_STORE/records/g/ldrift/2.json" | awk '{print $1}')" ] &&
  [ "$OVERFLOW_EVENT_SHA_BEFORE" = "$OVERFLOW_EVENT_SHA_AFTER" ] &&
  [ "$TERMINAL_RETRY_GENERATION_AFTER" -eq $((TERMINAL_RETRY_GENERATION_BEFORE + 1)) ] &&
  [ "$TERMINAL_RETRY_OWNER_STATE" = released ] &&
  [ "$TERMINAL_RETRY_OWNER_GENERATION" = "$TERMINAL_RETRY_GENERATION_AFTER" ] &&
  [ "$(jq -r '.pid' "$OVERFLOW_STORE/transaction-owner.json")" = "$TERMINAL_RETRY_PID" ] &&
  [ "$TERMINAL_RETRY_OWNER_RAW" = "$TERMINAL_RETRY_OWNER_CANONICAL" ] &&
  [ "$TERMINAL_RETRY_NAMESPACE_SHA_BEFORE" = "$(sha256sum "$OVERFLOW_STORE/namespace.json" | awk '{print $1}')" ] &&
  [ "$TERMINAL_RETRY_OWNER_SHA_BEFORE" != "$(sha256sum "$OVERFLOW_STORE/transaction-owner.json" | awk '{print $1}')" ] &&
  [ -n "$TERMINAL_RETRY_GENERATION_DIGEST" ] && [ -n "$TERMINAL_RETRY_OWNER_DIGEST" ] &&
  cmp "$TMP_ROOT/terminal-retry.mutations.expected" "$TMP_ROOT/terminal-retry.mutations" >/dev/null &&
  [ -n "$TERMINAL_RETRY_GENERATION_DIGEST_NORMALIZED" ] && [ -n "$TERMINAL_RETRY_OWNER_DIGEST_NORMALIZED" ] &&
  cmp "$TMP_ROOT/terminal-retry.mutations.normalized.expected" "$TMP_ROOT/terminal-retry.mutations.normalized" >/dev/null
}; then fail "terminal retry at max counter"; fi

printf '%s\n' "$COUNTER_DURABLE" >"$OVERFLOW_STORE/fencing-counter"
chmod 0600 "$OVERFLOW_STORE/fencing-counter"
sleep 10 & MAX_RECOVER_PID=$!
set +e
FM_HOME="$OVERFLOW_HOME" FM_DATA_OVERRIDE="$OVERFLOW_DATA" FM_STATE_OVERRIDE="$OVERFLOW_STATE" "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/read-graph.json" sr --registry "$TMP_ROOT/inputs/read-registry.json" --lease-id lrecover-max --holder-id hrecover --holder-pid "$MAX_RECOVER_PID" >"$TMP_ROOT/recover-seed.out" 2>"$TMP_ROOT/recover-seed.err"
RECOVER_SEED_RC=$?
set -e
if ! { [ "$RECOVER_SEED_RC" -eq 0 ] && [ ! -s "$TMP_ROOT/recover-seed.err" ] && [ "$(jq -r '.state' "$TMP_ROOT/recover-seed.out")" = held ]; }; then kill "$MAX_RECOVER_PID" 2>/dev/null || true; wait "$MAX_RECOVER_PID" 2>/dev/null || true; fail "recover overflow seed"; fi
kill "$MAX_RECOVER_PID" 2>/dev/null || true; wait "$MAX_RECOVER_PID" 2>/dev/null || true
printf '%s\n' 9223372036854775807 >"$OVERFLOW_STORE/fencing-counter"
chmod 0600 "$OVERFLOW_STORE/fencing-counter"
roots_manifest "$OVERFLOW_DATA" "$OVERFLOW_STATE" "$TMP_ROOT/recover-overflow-before"
set +e
FM_HOME="$OVERFLOW_HOME" FM_DATA_OVERRIDE="$OVERFLOW_DATA" FM_STATE_OVERRIDE="$OVERFLOW_STATE" "$ROOT/bin/fm-workgraph-lease-lib.sh" recover g --lease-id lrecover-max --actor-id actor-max >"$TMP_ROOT/err.out" 2>"$TMP_ROOT/err"
RC=$?
set -e
roots_manifest "$OVERFLOW_DATA" "$OVERFLOW_STATE" "$TMP_ROOT/recover-overflow-after"
if ! { [ "$RC" -eq 1 ] && [ ! -s "$TMP_ROOT/err.out" ] && grep -qx 'fm-workgraph: WG-L-E-OVERFLOW: lease operation failed' "$TMP_ROOT/err" && cmp "$TMP_ROOT/recover-overflow-before" "$TMP_ROOT/recover-overflow-after"; }; then fail "recover-held counter overflow mutation"; fi
ok "held release/recover overflow prechecks and terminal retry"

run "$ROOT/bin/fm-workgraph-lease-lib.sh" status g
[ "$RC" -eq 0 ] && [ ! -s "$TMP_ROOT/err" ] || fail "captured-helper status"
printf '%s\n' "$OUT" | grep -qx 'lease_store=ready' || fail "status fixture"
run "$ROOT/bin/fm-workgraph-lease-lib.sh" inspect g --history
[ "$RC" -eq 0 ] && [ ! -s "$TMP_ROOT/err" ] || fail "captured-helper inspect"
printf '%s\n' "$OUT" | jq -s -e 'length >= 1 and all(.[]; .goal_id=="g")' >/dev/null || fail "inspect fixture"
ok "captured-helper status and inspect"

CACHE_PATH="$STATE_ROOT/workgraphs/g/leases.v1.json"
cp "$CACHE_PATH" "$TMP_ROOT/cache.original"
for cache_case in symlink wrong-mode malformed fifo; do
  rm -f "$CACHE_PATH"
  rm -f "$TMP_ROOT/cache-fifo"
  rmdir "$TMP_ROOT/cache-dir" 2>/dev/null || true
  case "$cache_case" in
    symlink) ln -s /dev/null "$CACHE_PATH" ;;
    wrong-mode) cp "$TMP_ROOT/cache.original" "$CACHE_PATH"; chmod 0644 "$CACHE_PATH" ;;
    malformed) printf '{\n' >"$CACHE_PATH"; chmod 0600 "$CACHE_PATH" ;;
    fifo) mkfifo "$CACHE_PATH" ;;
  esac
  run "$ROOT/bin/fm-workgraph-lease-lib.sh" status g
  if ! { [ "$RC" -eq 0 ] && [ ! -s "$TMP_ROOT/err" ] && grep -qx 'lease_cache=reconstructed' <<<"$OUT"; }; then fail "status cache $cache_case"; fi
done
rm -f "$CACHE_PATH"
cp "$TMP_ROOT/cache.original" "$CACHE_PATH"
chmod 0600 "$CACHE_PATH"
ok "status cache anomalies are nonfatal reconstructed results"

CACHE_GOAL_DIR="$STATE_ROOT/workgraphs/g"
mv "$CACHE_GOAL_DIR" "$STATE_ROOT/workgraphs/g.real"
ln -s g.real "$CACHE_GOAL_DIR"
run "$ROOT/bin/fm-workgraph-lease-lib.sh" status g
if ! { [ "$RC" -eq 0 ] && [ ! -s "$TMP_ROOT/err" ] && grep -qx 'lease_cache=reconstructed' <<<"$OUT"; }; then fail "cache goal symlink is reconstructed"; fi
rm "$CACHE_GOAL_DIR"
mv "$STATE_ROOT/workgraphs/g.real" "$CACHE_GOAL_DIR"
mv "$STATE_ROOT/workgraphs" "$STATE_ROOT/workgraphs.real"
ln -s workgraphs.real "$STATE_ROOT/workgraphs"
run "$ROOT/bin/fm-workgraph-lease-lib.sh" status g
if ! { [ "$RC" -eq 0 ] && [ ! -s "$TMP_ROOT/err" ] && grep -qx 'lease_cache=reconstructed' <<<"$OUT"; }; then fail "cache workgraphs symlink is reconstructed"; fi
rm "$STATE_ROOT/workgraphs"
mv "$STATE_ROOT/workgraphs.real" "$STATE_ROOT/workgraphs"

CACHE_SOURCE="$TMP_ROOT/cache-source.js"
sed -n '/^\/\/ NODE_SOURCE_BEGIN$/,/^\/\/ NODE_SOURCE_END$/{ /^\/\/ NODE_SOURCE_BEGIN$/d; /^\/\/ NODE_SOURCE_END$/d; p; }' "$ROOT/bin/fm-workgraph-lease-lib.sh" | sed '/^const argv = process.argv/,$d' >"$CACHE_SOURCE"
printf '%s\n' 'module.exports = {probeCache, updateCache};' >>"$CACHE_SOURCE"
CACHE_RACE_DRIVER="$TMP_ROOT/cache-race-driver.js"
cat >"$CACHE_RACE_DRIVER" <<'NODE_CACHE_RACE'
const fs = require("node:fs");
const path = require("node:path");
const source = process.argv[2];
const cache = process.argv[3];
const goal = process.argv[4];
const mode = process.argv[5] || "race";
const goalDir = path.dirname(cache);
const moved = `${goalDir}.moved`;
const {probeCache, updateCache, loadStore} = require(source);
if (mode === "publish") {
  updateCache(goal, {namespace: "a".repeat(64), records: []});
  throw new Error("cache publication unexpectedly followed a symlink");
}
const realOpen = fs.openSync;
let swapped = false;
fs.openSync = (file, flags, ...rest) => {
  const fd = realOpen(file, flags, ...rest);
  if (!swapped && typeof file === "string" && /\/proc\/self\/fd\/\d+\/g$/u.test(file)) {
    fs.renameSync(goalDir, moved);
    fs.mkdirSync(goalDir, {mode: 0o700});
    swapped = true;
  }
  return fd;
};
const result = probeCache(cache, fs.readFileSync(cache));
if (result !== "reconstructed" || !swapped) throw new Error(`cache parent race result: ${result}`);
fs.rmSync(goalDir, {recursive: true, force: true});
fs.renameSync(moved, goalDir);
process.stdout.write("cache parent race fixture passed\n");
NODE_CACHE_RACE
printf 'cache parent race fixture passed\n' >"$TMP_ROOT/cache-race.expected"
set +e
FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$DATA_ROOT" FM_STATE_OVERRIDE="$STATE_ROOT" node "$CACHE_RACE_DRIVER" "$CACHE_SOURCE" "$CACHE_PATH" g >"$TMP_ROOT/cache-race.out" 2>"$TMP_ROOT/cache-race.err"
RC=$?
set -e
if ! { [ "$RC" -eq 0 ] && cmp "$TMP_ROOT/cache-race.expected" "$TMP_ROOT/cache-race.out" >/dev/null && [ ! -s "$TMP_ROOT/cache-race.err" ]; }; then fail "cache parent swap race"; fi
mv "$STATE_ROOT/workgraphs" "$STATE_ROOT/workgraphs.real"
ln -s workgraphs.real "$STATE_ROOT/workgraphs"
fs_manifest "$STATE_ROOT/workgraphs.real" "$TMP_ROOT/cache-publish-real.before"
printf 'link\t%s\t%s\n' "$(stat -c '%F\t%a\t%u\t%g\t%h\t%d\t%i' "$STATE_ROOT/workgraphs")" "$(readlink -- "$STATE_ROOT/workgraphs")" >"$TMP_ROOT/cache-publish-link.before"
set +e
FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$DATA_ROOT" FM_STATE_OVERRIDE="$STATE_ROOT" node "$CACHE_RACE_DRIVER" "$CACHE_SOURCE" "$CACHE_PATH" g publish >"$TMP_ROOT/cache-publish.out" 2>"$TMP_ROOT/cache-publish.err"
RC=$?
set -e
fs_manifest "$STATE_ROOT/workgraphs.real" "$TMP_ROOT/cache-publish-real.after"
printf 'link\t%s\t%s\n' "$(stat -c '%F\t%a\t%u\t%g\t%h\t%d\t%i' "$STATE_ROOT/workgraphs")" "$(readlink -- "$STATE_ROOT/workgraphs")" >"$TMP_ROOT/cache-publish-link.after"
rm "$STATE_ROOT/workgraphs"
mv "$STATE_ROOT/workgraphs.real" "$STATE_ROOT/workgraphs"
if ! { [ "$RC" -eq 1 ] && [ ! -s "$TMP_ROOT/cache-publish.out" ] && grep -qx 'fm-workgraph: WG-L-E-IO: lease operation failed' "$TMP_ROOT/cache-publish.err" && cmp "$TMP_ROOT/cache-publish-real.before" "$TMP_ROOT/cache-publish-real.after" >/dev/null && cmp "$TMP_ROOT/cache-publish-link.before" "$TMP_ROOT/cache-publish-link.after" >/dev/null && [ -d "$STATE_ROOT/workgraphs" ] && [ ! -L "$STATE_ROOT/workgraphs" ]; }; then fail "cache publication parent symlink"; fi
ok "cache intermediate symlinks and parent swaps are nonfollowing"

HELPER_SOURCE_BLOCK=$(sed -n '/^function canonicalProjectionResource(value) {$/,/^const AUTHORITY_TMP_RE =/p' "$ROOT/bin/fm-workgraph-lease-lib.sh")
EXPECTED_NORMALIZE_SPAWN=$(cat <<'JS_EXPECT_NORMALIZE'
  const result = child.spawnSync(`/proc/self/fd/${bashFd}`, ["/proc/self/fd/3", "__lease-normalize"], {input: canonical({value}), encoding: "utf8", stdio: ["pipe", "pipe", "pipe", helperFd, bashFd]});
JS_EXPECT_NORMALIZE
)
EXPECTED_OVERLAP_SPAWN=$(cat <<'JS_EXPECT_OVERLAP'
  const result = child.spawnSync(`/proc/self/fd/${bashFd}`, ["/proc/self/fd/3", "__lease-overlap"], {
JS_EXPECT_OVERLAP
)
EXPECTED_HELPER_STDIO=$(cat <<'JS_EXPECT_STDIO'
    stdio: ["pipe", "pipe", "pipe", helperFd, bashFd],
JS_EXPECT_STDIO
)
if [ -z "$HELPER_SOURCE_BLOCK" ] || grep -Fq 'fs.openSync' <<<"$HELPER_SOURCE_BLOCK" || ! grep -Fqx "$EXPECTED_NORMALIZE_SPAWN" <<<"$HELPER_SOURCE_BLOCK" || ! grep -Fqx "$EXPECTED_OVERLAP_SPAWN" <<<"$HELPER_SOURCE_BLOCK" || ! grep -Fqx "$EXPECTED_HELPER_STDIO" <<<"$HELPER_SOURCE_BLOCK"; then
  fail "captured helper descriptor was reopened"
fi
ok "captured helper descriptor is passed directly without pathname reopen"

PUBLISH_SOURCE="$TMP_ROOT/publish-source.js"
sed -n '/^\/\/ NODE_SOURCE_BEGIN$/,/^\/\/ NODE_SOURCE_END$/{ /^\/\/ NODE_SOURCE_BEGIN$/d; /^\/\/ NODE_SOURCE_END$/d; p; }' "$ROOT/bin/fm-workgraph-lease-lib.sh" | sed '/^const argv = process.argv/,$d' >"$PUBLISH_SOURCE"
printf '%s\n' 'module.exports = {publish};' >>"$PUBLISH_SOURCE"
PUBLISH_DRIVER="$TMP_ROOT/publish-driver.js"
cat >"$PUBLISH_DRIVER" <<'NODE_PUBLISH_DRIVER'
const fs = require("node:fs");
const path = require("node:path");
const child = require("node:child_process");
const source = process.argv[2];
const mode = process.argv[3];
const parent = process.argv[4];
const cacheMode = process.argv[5] === "cache";
const targetName = cacheMode ? (process.argv[6] || "leases.v1.json") : (process.argv[5] && process.argv[5] !== "false" ? process.argv[5] : (process.argv[6] || "target.json"));
const target = path.join(parent, targetName);
const moved = `${parent}.moved`;
const lease = require(source);
function swapParent() {
  fs.renameSync(parent, moved);
  fs.mkdirSync(parent, {mode: 0o700});
}
function restoreParent() {
  fs.rmSync(parent, {recursive: true, force: true});
  fs.renameSync(moved, parent);
}
if (mode === "cleanup") {
  const lexicalMarker = `${parent}.lexical-open`;
  const realOpen = fs.openSync;
  fs.openSync = (file, flags, ...rest) => {
    if (file === parent) fs.writeFileSync(lexicalMarker, "1\n", {mode: 0o600});
    return realOpen(file, flags, ...rest);
  };
  const realFsync = fs.fsyncSync;
  let injected = false;
  fs.fsyncSync = (fd) => {
    let link = "";
    try { link = fs.readlinkSync(`/proc/self/fd/${fd}`); } catch {}
    if (!injected && link.startsWith(`${parent}/.`)) {
      swapParent();
      injected = true;
      throw new Error("injected publication failure");
    }
    return realFsync(fd);
  };
  lease.publish(target, Buffer.from("cleanup\n"), false, false);
  throw new Error("publication unexpectedly succeeded");
}
if (mode === "metadata") {
  const payload = Buffer.from("metadata\n");
  const realSpawn = child.spawnSync;
  let changed = false;
  child.spawnSync = (command, args, options) => {
    const result = realSpawn(command, args, options);
    if (!changed && args.some((arg) => typeof arg === "string" && arg.includes("renameat2")) && result.status === 0) {
      fs.utimesSync(target, new Date(1000), new Date(1000));
      try { fs.chownSync(target, process.getuid(), process.getgid()); } catch {}
      changed = true;
    }
    return result;
  };
  lease.publish(target, payload, true, cacheMode);
  if (!changed) throw new Error("metadata change was not injected");
  process.stdout.write("non-authoritative metadata fixture passed\n");
  process.exit(0);
}
if (mode === "substitution") {
  const payload = Buffer.from("substitution\n");
  const realSpawn = child.spawnSync;
  let swapped = false;
  child.spawnSync = (command, args, options) => {
    const result = realSpawn(command, args, options);
    if (!swapped && args.some((arg) => typeof arg === "string" && arg.includes("renameat2")) && result.status === 0) {
      fs.renameSync(target, `${target}.attacker`);
      fs.writeFileSync(target, payload, {mode: 0o600});
      fs.chmodSync(target, 0o600);
      swapped = true;
    }
    return result;
  };
  lease.publish(target, payload, true, cacheMode);
  throw new Error("publication unexpectedly accepted a substituted inode");
}
if (mode.startsWith("fault-")) {
  const fault = mode.slice("fault-".length);
  const payload = Buffer.from("fault-original\n");
  fs.rmSync(parent, {recursive: true, force: true});
  fs.rmSync(moved, {recursive: true, force: true});
  fs.mkdirSync(parent, {mode: 0o700});
  let injected = false;
  let boundTarget = null;
  function findBoundTarget() {
    for (const fdName of fs.readdirSync("/proc/self/fd")) {
      const fdPath = "/proc/self/fd/" + fdName;
      try { if (fs.readlinkSync(fdPath) === parent) return fdPath + "/" + targetName; } catch {}
    }
    throw new Error("bound target descriptor not found");
  }
  function writeMarker(intercepted) {
    fs.writeFileSync(process.env.FM_FAULT_MARKER, "injected=true\nintercepted=" + (intercepted ? "true" : "false") + "\nbound=" + boundTarget + "\nfault=" + fault + "\n", {mode: 0o600});
  }
  const realLstat = fs.lstatSync;
  fs.lstatSync = (file, ...rest) => {
    const stat = realLstat(file, ...rest);
    if (!injected || file !== boundTarget || !["owner", "device"].includes(fault)) return stat;
    const field = {owner: "uid", device: "dev"}[fault];
    writeMarker(true);
    return new Proxy(stat, {get(object, property, receiver) { if (property !== field) return Reflect.get(object, property, receiver); const value = object[property]; return typeof value === "bigint" ? value + 1n : value + 1; }});
  };
  const realSpawn = child.spawnSync;
  child.spawnSync = (command, args, options) => {
    const result = realSpawn(command, args, options);
    if (!injected && args.some((arg) => typeof arg === "string" && arg.includes("renameat2")) && result.status === 0) {
      boundTarget = findBoundTarget();
      if (fault === "byte") fs.writeFileSync(boundTarget, Buffer.from("fault-corrupt\n"), {mode: 0o600});
      if (fault === "type") { fs.unlinkSync(boundTarget); fs.mkdirSync(boundTarget, {mode: 0o700}); }
      if (fault === "mode") fs.chmodSync(boundTarget, 0o644);
      if (fault === "inode") { fs.renameSync(boundTarget, boundTarget + ".attacker"); fs.copyFileSync(boundTarget + ".attacker", boundTarget); fs.chmodSync(boundTarget, 0o600); }
      if (fault === "nlink") fs.linkSync(boundTarget, boundTarget + ".hardlink");
      injected = true;
      writeMarker(fault !== "owner" && fault !== "device");
    }
    return result;
  };
  lease.publish(target, payload, true, false);
  throw new Error("fault publication unexpectedly succeeded");
}
fs.rmSync(parent, {recursive: true, force: true});
fs.rmSync(moved, {recursive: true, force: true});
fs.mkdirSync(parent, {mode: 0o700});
if (mode === "precheck") {
  fs.writeFileSync(target, "existing\n", {mode: 0o600});
  const realOpen = fs.openSync;
  let parentOpens = 0;
  let swapped = false;
  fs.openSync = (file, flags, ...rest) => {
    const fd = realOpen(file, flags, ...rest);
    if (!swapped && typeof file === "string" && file.endsWith("/publish-pre")) {
      parentOpens += 1;
      if (parentOpens === 2) { swapParent(); swapped = true; }
    }
    return fd;
  };
  lease.publish(target, Buffer.from("existing\n"), true, false);
  if (!swapped || !fs.existsSync(path.join(moved, "target.json")) || fs.existsSync(target)) throw new Error("existing-target precheck escaped bound parent");
  restoreParent();
} else if (mode === "readback") {
  const realSpawn = child.spawnSync;
  let swapped = false;
  child.spawnSync = (command, args, options) => {
    const result = realSpawn(command, args, options);
    if (!swapped && args.some((arg) => typeof arg === "string" && arg.includes("renameat2")) && result.status === 0) {
      swapParent();
      swapped = true;
    }
    return result;
  };
  lease.publish(target, Buffer.from("readback\n"), true, false);
  if (!swapped || !fs.existsSync(path.join(moved, "target.json")) || fs.existsSync(target)) throw new Error("post-rename readback escaped bound parent");
  child.spawnSync = realSpawn;
  restoreParent();
} else {
  throw new Error(`unknown mode: ${mode}`);
}
process.stdout.write("publication bound-parent fixtures passed\n");
NODE_PUBLISH_DRIVER
exec {PUBLISH_PYTHON_FD}< /usr/bin/python3
PUBLISH_PYTHON_TARGET=$(readlink "/proc/$$/fd/$PUBLISH_PYTHON_FD")
PUBLISH_PYTHON_RESOLVED=$(readlink -f /usr/bin/python3)
if ! { [ -n "$PUBLISH_PYTHON_FD" ] && [ "$PUBLISH_PYTHON_TARGET" = "$PUBLISH_PYTHON_RESOLVED" ] && [ -r "/proc/$$/fd/$PUBLISH_PYTHON_FD" ]; }; then fail "publication Python descriptor precondition"; fi
FM_LEASE_PYTHON_FD="$PUBLISH_PYTHON_FD" node "$PUBLISH_DRIVER" "$PUBLISH_SOURCE" precheck "$TMP_ROOT/publish-pre" >/dev/null || fail "bound existing-target precheck race"
FM_LEASE_PYTHON_FD="$PUBLISH_PYTHON_FD" node "$PUBLISH_DRIVER" "$PUBLISH_SOURCE" readback "$TMP_ROOT/publish-readback" >/dev/null || fail "bound post-rename readback race"
set +e
FM_LEASE_PYTHON_FD="$PUBLISH_PYTHON_FD" node "$PUBLISH_DRIVER" "$PUBLISH_SOURCE" cleanup "$TMP_ROOT/publish-cleanup" >"$TMP_ROOT/publish-cleanup.out" 2>"$TMP_ROOT/publish-cleanup.err"
RC=$?
set -e
if ! { [ "$RC" -eq 1 ] && [ ! -s "$TMP_ROOT/publish-cleanup.out" ] && grep -qx 'fm-workgraph: WG-L-E-IO: lease operation failed' "$TMP_ROOT/publish-cleanup.err"; }; then fail "bound failure cleanup error"; fi
for cleanup_root in "$TMP_ROOT/publish-cleanup" "$TMP_ROOT/publish-cleanup.moved"; do
  find "$cleanup_root" -mindepth 1 -maxdepth 1 -name '.target.json.tmp.*' -print -quit | grep -q . && fail "bound failure cleanup temp survived"
done
[ ! -e "$TMP_ROOT/publish-cleanup.lexical-open" ] || fail "failure cleanup reopened lexical parent"
ok "publication target checks, readback, and cleanup stay on the bound parent"
AUTH_IDENTITY_TARGET="$STORE/publication-identity-race.json"
set +e
FM_LEASE_PYTHON_FD="$PUBLISH_PYTHON_FD" node "$PUBLISH_DRIVER" "$PUBLISH_SOURCE" substitution "$STORE" false publication-identity-race.json >"$TMP_ROOT/publication-authority.out" 2>"$TMP_ROOT/publication-authority.err"
RC=$?
set -e
if ! { [ "$RC" -eq 1 ] && [ ! -s "$TMP_ROOT/publication-authority.out" ] && grep -qx 'fm-workgraph: WG-L-E-IO: lease operation failed' "$TMP_ROOT/publication-authority.err"; }; then fail "authority substituted inode"; fi
rm -f "$AUTH_IDENTITY_TARGET" "$AUTH_IDENTITY_TARGET.attacker"
rm -f "$CACHE_PATH" "$CACHE_PATH.attacker"
set +e
FM_LEASE_PYTHON_FD="$PUBLISH_PYTHON_FD" node "$PUBLISH_DRIVER" "$PUBLISH_SOURCE" substitution "$STATE_ROOT/workgraphs/g" cache leases.v1.json >"$TMP_ROOT/publication-cache.out" 2>"$TMP_ROOT/publication-cache.err"
RC=$?
set -e
if ! { [ "$RC" -eq 1 ] && [ ! -s "$TMP_ROOT/publication-cache.out" ] && grep -qx 'fm-workgraph: WG-L-E-IO: lease operation failed' "$TMP_ROOT/publication-cache.err"; }; then fail "cache substituted inode"; fi
cp "$TMP_ROOT/cache.original" "$CACHE_PATH"
chmod 0600 "$CACHE_PATH"
ok "authority and cache publication reject byte-identical inode substitution"
set +e
FM_LEASE_PYTHON_FD="$PUBLISH_PYTHON_FD" node "$PUBLISH_DRIVER" "$PUBLISH_SOURCE" metadata "$STORE" false publication-metadata-race.json >"$TMP_ROOT/publication-authority-metadata.out" 2>"$TMP_ROOT/publication-authority-metadata.err"
RC=$?
set -e
[ "$RC" -eq 0 ] && [ ! -s "$TMP_ROOT/publication-authority-metadata.err" ] || fail "authority non-authoritative metadata change"
rm -f "$STORE/publication-metadata-race.json"
rm -f "$CACHE_PATH"
set +e
FM_LEASE_PYTHON_FD="$PUBLISH_PYTHON_FD" node "$PUBLISH_DRIVER" "$PUBLISH_SOURCE" metadata "$STATE_ROOT/workgraphs/g" cache leases.v1.json >"$TMP_ROOT/publication-cache-metadata.out" 2>"$TMP_ROOT/publication-cache-metadata.err"
RC=$?
set -e
[ "$RC" -eq 0 ] && [ ! -s "$TMP_ROOT/publication-cache-metadata.err" ] || fail "cache non-authoritative metadata change"
rm -f "$CACHE_PATH"
cp "$TMP_ROOT/cache.original" "$CACHE_PATH"
chmod 0600 "$CACHE_PATH"
for publication_fault in byte type mode owner device inode nlink; do
  FAULT_PARENT="$TMP_ROOT/publish-fault-$publication_fault"
  set +e
  FM_FAULT_MARKER="$TMP_ROOT/publish-fault-$publication_fault.marker" FM_LEASE_PYTHON_FD="$PUBLISH_PYTHON_FD" node "$PUBLISH_DRIVER" "$PUBLISH_SOURCE" "fault-$publication_fault" "$FAULT_PARENT" >"$TMP_ROOT/publish-fault-$publication_fault.out" 2>"$TMP_ROOT/publish-fault-$publication_fault.err"
  RC=$?
  set -e
  if ! { [ "$RC" -eq 1 ] && [ ! -s "$TMP_ROOT/publish-fault-$publication_fault.out" ] && grep -qx 'fm-workgraph: WG-L-E-IO: lease operation failed' "$TMP_ROOT/publish-fault-$publication_fault.err" && grep -qx 'injected=true' "$TMP_ROOT/publish-fault-$publication_fault.marker" && grep -qx 'intercepted=true' "$TMP_ROOT/publish-fault-$publication_fault.marker" && grep -q '^bound=/proc/self/fd/' "$TMP_ROOT/publish-fault-$publication_fault.marker" && grep -qx "fault=$publication_fault" "$TMP_ROOT/publish-fault-$publication_fault.marker"; }; then fail "post-rename publication fault $publication_fault"; fi
  if find "$FAULT_PARENT" -maxdepth 1 -name '.target.json.tmp.*' -print -quit | grep -q .; then fail "post-rename publication fault $publication_fault temp cleanup"; fi
done
ok "post-rename byte/type/mode/owner/device/inode/nlink anomalies map to exact IO"
exec {PUBLISH_PYTHON_FD}<&-
ok "GID/timestamp changes do not decide publication identity when available"

REOPEN_HOME="$TMP_ROOT/durable-reopen/home"
REOPEN_DATA="$REOPEN_HOME/data"
REOPEN_STATE="$REOPEN_HOME/state"
mkdir -p "$REOPEN_DATA" "$REOPEN_STATE"
run env FM_HOME="$REOPEN_HOME" FM_DATA_OVERRIDE="$REOPEN_DATA" FM_STATE_OVERRIDE="$REOPEN_STATE" "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/graph.json" s --registry "$TMP_ROOT/inputs/registry.json" --lease-id durable-reopen --holder-id h-reopen --holder-pid "$$"
[ "$RC" -eq 0 ] && [ ! -s "$TMP_ROOT/err" ] || fail "durable reopen seed"
REOPEN_RECORD="$REOPEN_DATA/workgraphs/.leases/v1/records/g/durable-reopen/1.json"
printf '%s\n' '{"schema_version":"workgraph-lease/v1"}' >"$REOPEN_RECORD"
chmod 0600 "$REOPEN_RECORD"
roots_manifest "$REOPEN_DATA" "$REOPEN_STATE" "$TMP_ROOT/durable-reopen-before"
set +e
FM_HOME="$REOPEN_HOME" FM_DATA_OVERRIDE="$REOPEN_DATA" FM_STATE_OVERRIDE="$REOPEN_STATE" "$ROOT/bin/fm-workgraph-lease-lib.sh" status g >"$TMP_ROOT/durable-reopen.out" 2>"$TMP_ROOT/durable-reopen.err"
RC=$?
set -e
roots_manifest "$REOPEN_DATA" "$REOPEN_STATE" "$TMP_ROOT/durable-reopen-after"
if ! { [ "$RC" -eq 1 ] && [ ! -s "$TMP_ROOT/durable-reopen.out" ] && grep -qx 'fm-workgraph: WG-L-E-NOT-RECONSTRUCTABLE: lease operation failed' "$TMP_ROOT/durable-reopen.err" && cmp -s "$TMP_ROOT/durable-reopen-before" "$TMP_ROOT/durable-reopen-after"; }; then fail "durable reopen corruption remains NOT-RECONSTRUCTABLE"; fi
ok "durable reopen corruption remains exact NOT-RECONSTRUCTABLE without mutation"

run "$ROOT/bin/fm-workgraph-lease-lib.sh" fence g --lease-id l1 --holder-id h1 --fencing-token 1
[ "$RC" -eq 0 ] && [ ! -s "$TMP_ROOT/err" ] || fail "fence"
printf '%s' "$OUT" | jq -e '.command=="fence" and .current_fencing_token=="1"' >/dev/null || fail "fence result"
ok "fencing token accepted"

run "$ROOT/bin/fm-workgraph-lease-lib.sh" release g --lease-id l1 --holder-id h1 --fencing-token 1
[ "$RC" -eq 0 ] && [ ! -s "$TMP_ROOT/err" ] || fail "release"
printf '%s' "$OUT" | jq -e '.state=="released" and .current_fencing_token=="2"' >/dev/null || fail "release result"
ok "release advances fencing"

REV2_SHA=$(sha256sum "$STORE/records/g/l1/2.json" | awk '{print $1}')
run "$ROOT/bin/fm-workgraph-lease-lib.sh" release g --lease-id l1 --holder-id h1 --fencing-token 1
[ "$RC" -eq 0 ] || fail "terminal retry"
[ "$REV2_SHA" = "$(sha256sum "$STORE/records/g/l1/2.json" | awk '{print $1}')" ] || fail "immutable revision clobber"
flock -n "$STORE/.transaction-lock" -c true || fail "explicit normal unlock"
ok "revision retry is no-clobber"

run "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/graph.json" s --registry "$TMP_ROOT/inputs/registry.json" --lease-id l1 --holder-id h1 --holder-pid "$$"
if ! { [ "$RC" -eq 1 ] && grep -qx 'fm-workgraph: WG-L-E-LEASE-ID-REUSED: lease operation failed' "$TMP_ROOT/err"; }; then fail "lease id reuse"; fi
ok "immutable lease-id reuse rejection"

sleep 30 & DEAD_PID=$!
run "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/graph.json" s --registry "$TMP_ROOT/inputs/registry.json" --lease-id l2 --holder-id h2 --holder-pid "$DEAD_PID"
[ "$RC" -eq 0 ] && [ ! -s "$TMP_ROOT/err" ] || fail "second acquire"
kill "$DEAD_PID" 2>/dev/null || true; wait "$DEAD_PID" 2>/dev/null || true
run "$ROOT/bin/fm-workgraph-lease-lib.sh" recover g --lease-id l2 --actor-id actorA
[ "$RC" -eq 0 ] && [ ! -s "$TMP_ROOT/err" ] || fail "recover"
printf '%s' "$OUT" | jq -e '.state=="recovered" and .actor_id=="actorA"' >/dev/null || fail "recover result"
REC=$(FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$DATA_ROOT" FM_STATE_OVERRIDE="$STATE_ROOT" "$ROOT/bin/fm-workgraph-lease-lib.sh" inspect g --lease-id l2 --history)
printf '%s\n' "$REC" | jq -e 'select(.revision=="2") | .state=="recovered" and .terminal.kind=="recover" and .terminal.actor_id=="actorA"' >/dev/null || fail "v14 recovery record"
EVENT=$(cat "$(grep -l '"event":"recover"' "$STORE"/events/*.json | head -1)")
printf '%s\n' "$EVENT" | jq -e 'select((has("actor")|not) and .event=="recover" and (.record_sha256 != null))' >/dev/null || fail "event actor field"
RECORD_SHA=$(sha256sum "$STORE/records/g/l2/2.json" | awk '{print $1}')
EVENT_SHA=$(printf '%s\n' "$EVENT" | jq -r .record_sha256)
[ "$EVENT_SHA" = "$RECORD_SHA" ] || fail "recovery record digest"
ok "positive-evidence recovery and v14 terminal relation"

BEGIN_TX_SOURCE="$TMP_ROOT/begin-tx-source.js"
sed -n '/^\/\/ NODE_SOURCE_BEGIN$/,/^\/\/ NODE_SOURCE_END$/{ /^\/\/ NODE_SOURCE_BEGIN$/d; /^\/\/ NODE_SOURCE_END$/d; p; }' "$ROOT/bin/fm-workgraph-lease-lib.sh" | sed '/^const argv = process.argv/,$d' >"$BEGIN_TX_SOURCE"
printf '%s\n' 'module.exports = {beginTx};' >>"$BEGIN_TX_SOURCE"
BEGIN_TX_DRIVER="$TMP_ROOT/begin-tx-driver.js"
printf '%s\n' \
'const {beginTx} = require(process.argv[2]);' \
'beginTx({generation: 0n}, {});' \
>"$BEGIN_TX_DRIVER"
UNLOCKED_BEFORE="$TMP_ROOT/valid-unlocked-before"
UNLOCKED_AFTER="$TMP_ROOT/valid-unlocked-after"
ds_manifest "$UNLOCKED_BEFORE"
exec {UNLOCKED_LOCK_FD}>>"$STORE/.transaction-lock"
set +e
FM_LEASE_LOCK_FD="$UNLOCKED_LOCK_FD" FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$DATA_ROOT" FM_STATE_OVERRIDE="$STATE_ROOT" node "$BEGIN_TX_DRIVER" "$BEGIN_TX_SOURCE" >"$TMP_ROOT/valid-unlocked.out" 2>"$TMP_ROOT/valid-unlocked.err"
RC=$?
set -e
exec {UNLOCKED_LOCK_FD}>&-
ds_manifest "$UNLOCKED_AFTER"
if ! { [ "$RC" -eq 1 ] && [ ! -s "$TMP_ROOT/valid-unlocked.out" ] && grep -qx 'fm-workgraph: WG-L-E-STORE: lease operation failed' "$TMP_ROOT/valid-unlocked.err" && cmp -s "$UNLOCKED_BEFORE" "$UNLOCKED_AFTER"; }; then fail "valid unlocked fd"; fi
ok "valid unlocked fd fails closed before store dereference"

IDENTITY_SOURCE="$TMP_ROOT/identity-source.js"
sed -n '/^\/\/ NODE_SOURCE_BEGIN$/,/^\/\/ NODE_SOURCE_END$/{ /^\/\/ NODE_SOURCE_BEGIN$/d; /^\/\/ NODE_SOURCE_END$/d; p; }' "$ROOT/bin/fm-workgraph-lease-lib.sh" | sed '/^const argv = process.argv/,$d' >"$IDENTITY_SOURCE"
printf '%s\n' 'module.exports = {identity, compareRecords, identityProof};' >>"$IDENTITY_SOURCE"
IDENTITY_DRIVER="$TMP_ROOT/identity-driver.js"
# shellcheck disable=SC2016
# The fixture is emitted as single-quoted JavaScript so its ${...} expressions remain literal.
printf '%s\n' \
'const Module = require("node:module");' \
'const realLoad = Module._load;' \
'const lf = String.fromCharCode(10); const cr = String.fromCharCode(13);' \
'let mode = "stable"; let reads = 0;' \
'const fakeFs = {readFileSync(file, encoding) {' \
'  reads += 1;' \
'  if (mode === "target-absent") { const e = new Error("missing target"); e.code = "ENOENT"; throw e; }' \
'  if (mode === "boot-absent" && file === "/proc/sys/kernel/random/boot_id") { const e = new Error("missing boot"); e.code = "ENOENT"; throw e; }' \
'  if (mode === "hostname-absent" && file === "/proc/sys/kernel/hostname") { const e = new Error("missing hostname"); e.code = "ENOENT"; throw e; }' \
'  if (file === "/proc/123/cmdline") return mode === "cmdline-changing" && reads === 5 ? Buffer.from([115, 101, 99, 111, 110, 100, 0]) : Buffer.from([102, 105, 114, 115, 116, 0]);' \
'  if (file === "/proc/123/stat") { let value = `123 (fixture) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 42${lf}`; if (mode === "stat-dynamic" && reads === 6) value = `123 (fixture) S 9 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 42${lf}`; return value; };' \
'  if (file === "/proc/sys/kernel/random/boot_id") { let value = `aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa${lf}`; if (mode === "boot-changing" && reads === 7) value = `bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb${lf}`; if (mode === "boot-no-lf") value = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"; if (mode === "boot-two-lf") value = `aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa${lf}${lf}`; if (mode === "boot-crlf") value = `aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa${cr}${lf}`; if (mode === "boot-leading-space") value = ` aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa${lf}`; if (mode === "boot-trailing-space") value = `aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa ${lf}`; if (mode === "boot-uppercase") value = `AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA${lf}`; if (mode === "boot-nul") value = `aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa${String.fromCharCode(0)}${lf}`; if (mode === "boot-short") value = `a${lf}`; if (mode === "boot-long") value = `aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa-extra${lf}`; return value; };' \
'  if (file === "/proc/sys/kernel/hostname") { let value = `host-a${lf}`; if (mode === "hostname-changing" && reads === 8) value = `host-b${lf}`; if (mode === "hostname-no-lf") value = "host-a"; if (mode === "hostname-two-lf") value = `host-a${lf}${lf}`; if (mode === "hostname-crlf") value = `host-a${cr}${lf}`; return value; };' \
'  throw new Error("unexpected fixture read: " + file);' \
'}};' \
'Module._load = (request, parent, isMain) => request === "node:fs" ? fakeFs : realLoad(request, parent, isMain);' \
'const lease = require(process.argv[2]);' \
'function expectUndefined(name, nextMode) { mode = nextMode; reads = 0; if (lease.identity("123", false) !== undefined) throw new Error(name + ": changing or uncertain identity was accepted"); }' \
'mode = "stable"; reads = 0; if (lease.identity("123", false) === undefined) throw new Error("stable identity rejected");' \
'mode = "boot-no-lf"; reads = 0; if (lease.identity("123", false) === undefined) throw new Error("boot without LF rejected");' \
'mode = "hostname-no-lf"; reads = 0; if (lease.identity("123", false) === undefined) throw new Error("hostname without LF rejected");' \
'mode = "target-absent"; reads = 0; if (lease.identity("123", false) !== null) throw new Error("target absence was not positive pid absence");' \
'expectUndefined("cmdline", "cmdline-changing");' \
'mode = "stat-dynamic"; reads = 0; if (lease.identity("123", false) === undefined) throw new Error("volatile stat field change rejected stable identity");' \
'expectUndefined("boot", "boot-changing");' \
'expectUndefined("hostname", "hostname-changing");' \
'expectUndefined("boot two LF", "boot-two-lf");' \
'expectUndefined("boot CRLF", "boot-crlf");' \
'expectUndefined("boot leading space", "boot-leading-space");' \
'expectUndefined("boot trailing space", "boot-trailing-space");' \
'expectUndefined("boot uppercase", "boot-uppercase");' \
'expectUndefined("boot NUL", "boot-nul");' \
'expectUndefined("boot short", "boot-short");' \
'expectUndefined("boot long", "boot-long");' \
'expectUndefined("hostname two LF", "hostname-two-lf");' \
'expectUndefined("hostname CRLF", "hostname-crlf");' \
'expectUndefined("boot ENOENT", "boot-absent");' \
'expectUndefined("hostname ENOENT", "hostname-absent");' \
'mode = "stable"; reads = 0; if (lease.identityProof({pid: "123", hostname: "foreign-host", boot_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", start_ticks: "42", cmdline_sha256: require("node:crypto").createHash("sha256").update(Buffer.from([102, 105, 114, 115, 116, 0])).digest("hex")}) !== null) throw new Error("foreign hostname was accepted");' \
'process.stdout.write("identity fixtures passed" + lf);' \
>"$IDENTITY_DRIVER"
node "$IDENTITY_DRIVER" "$IDENTITY_SOURCE" >/dev/null || fail "changing-byte identity fixtures"
ok "changing identity bytes and global-file uncertainty fail closed"

PRIVATE_SOURCE="$TMP_ROOT/workgraph-node-source.js"
sed -n '/^\/\/ WORKGRAPH_NODE_SOURCE_BEGIN$/,/^\/\/ WORKGRAPH_NODE_SOURCE_END$/p' \
  "$ROOT/bin/fm-workgraph.sh" >"$PRIVATE_SOURCE"
for private_command in __lease-normalize __lease-overlap; do
  set +e
  FM_WORKGRAPH_PRIVATE_INPUT_FD=99 node "$PRIVATE_SOURCE" /dev/null "$private_command" >"$TMP_ROOT/private-invalid.out" 2>"$TMP_ROOT/private-invalid.err"
  RC=$?
  set -e
  if ! { [ "$RC" -eq 1 ] && [ ! -s "$TMP_ROOT/private-invalid.out" ] && grep -q '^fm-workgraph: WG-E-CORRUPT: captured private-input descriptor is unavailable:' "$TMP_ROOT/private-invalid.err"; }; then fail "private $private_command invalid descriptor"; fi
done
for private_command in __lease-normalize __lease-overlap; do
  for private_kind in truncated duplicate; do
    if [ "$private_command" = __lease-normalize ]; then
      if [ "$private_kind" = truncated ]; then
        private_payload='{"value":"path:///tmp"'
      else
        private_payload='{"value":"path:///tmp","value":"path:///tmp"}'
      fi
    elif [ "$private_kind" = truncated ]; then
      private_payload='{"registry":'
    else
      private_payload='{"registry":{"schema_version":"resource-registry/v1","instances":[]},"left_scopes":[],"right_scopes":[],"right_scopes":[]}'
    fi
    exec 9<<<"$private_payload"
  set +e
  FM_WORKGRAPH_PRIVATE_INPUT_FD=9 node "$PRIVATE_SOURCE" /dev/null "$private_command" >"$TMP_ROOT/private-case.out" 2>"$TMP_ROOT/private-case.err"
  RC=$?
    set -e
    exec 9>&-
    if ! { [ "$RC" -eq 1 ] && [ ! -s "$TMP_ROOT/private-case.out" ] && grep -q '^fm-workgraph: WG-E-CORRUPT:' "$TMP_ROOT/private-case.err"; }; then fail "private $private_command $private_kind malformed JSON"; fi
  done
done
ok "private normalize/overlap descriptors are explicit and malformed JSON is rejected"

RECOVER_HOME="$TMP_ROOT/recover-positive/home"
RECOVER_DATA="$TMP_ROOT/recover-positive/data"
RECOVER_STATE="$TMP_ROOT/recover-positive/state"
mkdir -p "$RECOVER_HOME" "$RECOVER_DATA" "$RECOVER_STATE"
roots_manifest "$RECOVER_DATA" "$RECOVER_STATE" "$TMP_ROOT/recover-positive/before"
sleep 30 & RECOVER_HOLDER=$!
run env FM_HOME="$RECOVER_HOME" FM_DATA_OVERRIDE="$RECOVER_DATA" FM_STATE_OVERRIDE="$RECOVER_STATE" "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/graph.json" s --registry "$TMP_ROOT/inputs/registry.json" --lease-id recover-positive --holder-id h-recover --holder-pid "$RECOVER_HOLDER"
[ "$RC" -eq 0 ] && [ ! -s "$TMP_ROOT/err" ] || fail "positive recover acquire"
RECOVER_STORE="$RECOVER_DATA/workgraphs/.leases/v1"
python3 - "$RECOVER_STORE/records/g/recover-positive/1.json" "$RECOVER_HOLDER" <<'PY_RECOVER_IDENTITY' || fail "positive recover holder proof"
import hashlib, json, os, sys
record = json.load(open(sys.argv[1], encoding="utf-8"))
pid = sys.argv[2]
holder = record["holder_process"]
assert holder["pid"] == pid
cmdline = open(f"/proc/{pid}/cmdline", "rb").read()
stat_text = open(f"/proc/{pid}/stat", encoding="utf-8").read()
fields = stat_text[stat_text.rfind(")") + 2:].split()
assert holder["start_ticks"] == fields[19]
assert holder["cmdline_sha256"] == hashlib.sha256(cmdline).hexdigest()
boot = open("/proc/sys/kernel/random/boot_id", encoding="ascii").read()
boot = boot[:-1] if boot.endswith("\n") else boot
hostname = open("/proc/sys/kernel/hostname", encoding="ascii").read()
hostname = hostname[:-1] if hostname.endswith("\n") else hostname
assert holder["boot_id"] == boot and holder["hostname"] == hostname
PY_RECOVER_IDENTITY
kill "$RECOVER_HOLDER"
wait "$RECOVER_HOLDER" 2>/dev/null || true
[ ! -e "/proc/$RECOVER_HOLDER" ] || fail "positive recover holder did not terminate"
run env FM_HOME="$RECOVER_HOME" FM_DATA_OVERRIDE="$RECOVER_DATA" FM_STATE_OVERRIDE="$RECOVER_STATE" "$ROOT/bin/fm-workgraph-lease-lib.sh" recover g --lease-id recover-positive --actor-id A
[ "$RC" -eq 0 ] && [ ! -s "$TMP_ROOT/err" ] || fail "positive recover"
printf '%s' "$OUT" | jq -e '.state=="recovered" and .actor_id=="A"' >/dev/null || fail "positive recover result"
RECOVER_RECORD="$RECOVER_STORE/records/g/recover-positive/2.json"
mapfile -t RECOVER_EVENTS < <(grep -l '"event":"recover"' "$RECOVER_STORE/events"/*.json)
[ "${#RECOVER_EVENTS[@]}" -eq 1 ] || fail "positive recover event count"
RECOVER_EVENT=${RECOVER_EVENTS[0]}
jq -e '(.state=="recovered") and (.revision=="2") and (.transaction_generation=="2") and (.holder_fencing_token=="1") and (.current_fencing_token=="2") and (.terminal.kind=="recover") and (.terminal.actor_id=="A") and (.terminal.proof=="pid-absent")' "$RECOVER_RECORD" >/dev/null || fail "positive recover record"
jq -e '(.event=="recover") and ((has("actor"))|not) and ((has("actor_id"))|not) and (.proof=="pid-absent") and (.transaction_generation=="2") and (.fencing_token=="2") and (.record_revision=="2") and (.holder_id=="h-recover") and (.record_sha256 != null)' "$RECOVER_EVENT" >/dev/null || fail "positive recover event shape"
[ "$(jq -r .record_sha256 "$RECOVER_EVENT")" = "$(sha256sum "$RECOVER_RECORD" | awk '{print $1}')" ] || fail "positive recover event digest"
roots_manifest "$RECOVER_DATA" "$RECOVER_STATE" "$TMP_ROOT/recover-positive/after"
ok "fresh positive recovery, holder proof, v14 event bytes, and manifests"

RACE_HOME="$TMP_ROOT/authority-race/home"
RACE_DATA="$RACE_HOME/data"
RACE_STATE="$RACE_HOME/state"
mkdir -p "$RACE_DATA" "$RACE_STATE"
run env FM_HOME="$RACE_HOME" FM_DATA_OVERRIDE="$RACE_DATA" FM_STATE_OVERRIDE="$RACE_STATE" "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/graph.json" s --registry "$TMP_ROOT/inputs/registry.json" --lease-id authority-race --holder-id h-race --holder-pid "$$"
[ "$RC" -eq 0 ] && [ ! -s "$TMP_ROOT/err" ] || fail "authority race seed"
RACE_STORE="$RACE_DATA/workgraphs/.leases/v1"
RACE_SOURCE="$TMP_ROOT/authority-race-source.js"
sed -n '/^\/\/ NODE_SOURCE_BEGIN$/,/^\/\/ NODE_SOURCE_END$/{ /^\/\/ NODE_SOURCE_BEGIN$/d; /^\/\/ NODE_SOURCE_END$/d; p; }' "$ROOT/bin/fm-workgraph-lease-lib.sh" | sed '/^const argv = process.argv/,$d' >"$RACE_SOURCE"
printf '%s\n' 'module.exports = {loadStore};' >>"$RACE_SOURCE"
RACE_DRIVER="$TMP_ROOT/authority-race-driver.js"
cat >"$RACE_DRIVER" <<'NODE_AUTHORITY_RACE'
const Module = require("node:module");
const realLoad = Module._load;
const realFs = require("node:fs");
const source = process.argv[2];
const mode = process.argv[3];
const target = process.argv[4];
const replacement = process.argv[5];
const marker = process.env.FM_RACE_SWAP_MARKER;
const triggers = {data: 1, workgraphs: 1, leases: 1, store: 1, records: 2, goal: 3, lease: 4, events: 5};
let calls = 0;
let swapped = false;
function swap() {
  realFs.renameSync(target, target + ".old");
  realFs.renameSync(replacement, target);
  realFs.writeFileSync(marker, "swapped\n", {mode: 0o600});
  swapped = true;
}
const wrappedFs = new Proxy(realFs, {
  get(targetObject, property, receiver) {
    if (property === "readdirSync") {
      return function readdirSyncBound(...args) {
        calls += 1;
        if (!swapped && calls === triggers[mode]) swap();
        return realFs.readdirSync(...args);
      };
    }
    return Reflect.get(targetObject, property, receiver);
  },
});
Module._load = (request, parent, isMain) => request === "node:fs" ? wrappedFs : realLoad(request, parent, isMain);
const {loadStore} = require(source);
const result = loadStore();
process.stdout.write("load=" + (result.absent ? "absent" : "ready") + " swapped=" + swapped + "\n");
NODE_AUTHORITY_RACE
exec {RACE_HELPER_FD}<"$ROOT/bin/fm-workgraph.sh"
exec {RACE_BASH_FD}<"$(readlink -f /usr/bin/bash)"
for race_mode in data workgraphs leases store records goal lease events; do
  case "$race_mode" in
    data) RACE_TARGET="$RACE_DATA"; RACE_REPLACEMENT="$TMP_ROOT/race-data" ;;
    workgraphs) RACE_TARGET="$RACE_DATA/workgraphs"; RACE_REPLACEMENT="$TMP_ROOT/race-workgraphs" ;;
    leases) RACE_TARGET="$RACE_DATA/workgraphs/.leases"; RACE_REPLACEMENT="$TMP_ROOT/race-leases" ;;
    store) RACE_TARGET="$RACE_STORE"; RACE_REPLACEMENT="$TMP_ROOT/race-store" ;;
    records) RACE_TARGET="$RACE_STORE/records"; RACE_REPLACEMENT="$TMP_ROOT/race-records" ;;
    goal) RACE_TARGET="$RACE_STORE/records/g"; RACE_REPLACEMENT="$TMP_ROOT/race-goal" ;;
    lease) RACE_TARGET="$RACE_STORE/records/g/authority-race"; RACE_REPLACEMENT="$TMP_ROOT/race-lease" ;;
    events) RACE_TARGET="$RACE_STORE/events"; RACE_REPLACEMENT="$TMP_ROOT/race-events" ;;
  esac
  cp -a "$RACE_TARGET" "$RACE_REPLACEMENT"
  roots_manifest "$RACE_DATA" "$RACE_STATE" "$TMP_ROOT/authority-race-$race_mode-before"
  set +e
  FM_HOME="$RACE_HOME" FM_DATA_OVERRIDE="$RACE_DATA" FM_STATE_OVERRIDE="$RACE_STATE" FM_LEASE_HELPER_FD="$RACE_HELPER_FD" FM_LEASE_BASH_FD="$RACE_BASH_FD" FM_RACE_SWAP_MARKER="$TMP_ROOT/authority-race-$race_mode-swapped" node "$RACE_DRIVER" "$RACE_SOURCE" "$race_mode" "$RACE_TARGET" "$RACE_REPLACEMENT" >"$TMP_ROOT/authority-race-$race_mode.out" 2>"$TMP_ROOT/authority-race-$race_mode.err"
  RC=$?
  set -e
  if ! { [ "$RC" -eq 1 ] && [ ! -s "$TMP_ROOT/authority-race-$race_mode.out" ] && grep -qx 'fm-workgraph: WG-L-E-NOT-RECONSTRUCTABLE: lease operation failed' "$TMP_ROOT/authority-race-$race_mode.err" && [ -s "$TMP_ROOT/authority-race-$race_mode-swapped" ]; }; then fail "authority ancestor swap $race_mode"; fi
  mv "$RACE_TARGET" "$RACE_REPLACEMENT.observed"
  mv "$RACE_TARGET.old" "$RACE_TARGET"
  roots_manifest "$RACE_DATA" "$RACE_STATE" "$TMP_ROOT/authority-race-$race_mode-after"
  if ! cmp -s "$TMP_ROOT/authority-race-$race_mode-before" "$TMP_ROOT/authority-race-$race_mode-after"; then fail "authority ancestor swap $race_mode mutation"; fi
done
exec {RACE_HELPER_FD}<&-
exec {RACE_BASH_FD}<&-
ok "durable authority ancestor swaps fail closed from bound D through records, goals, leases, and events"

ORDER_SOURCE="$TMP_ROOT/order-source.js"
sed -n '/^\/\/ NODE_SOURCE_BEGIN$/,/^\/\/ NODE_SOURCE_END$/{ /^\/\/ NODE_SOURCE_BEGIN$/d; /^\/\/ NODE_SOURCE_END$/d; p; }' "$ROOT/bin/fm-workgraph-lease-lib.sh" | sed '/^const argv = process.argv/,$d' >"$ORDER_SOURCE"
printf '%s\n' 'module.exports = {compareRecords};' >>"$ORDER_SOURCE"
ORDER_DRIVER="$TMP_ROOT/order-driver.js"
# shellcheck disable=SC2016
# The fixture is emitted as single-quoted JavaScript so its ${...} expressions remain literal.
printf '%s\n' \
'const {compareRecords} = require(process.argv[2]);' \
'const rec = (goal, slice, token, lease) => ({goal_id: goal, slice_id: slice, holder_fencing_token: token, lease_id: lease});' \
'const text = [rec("a", "s", "1", "l"), rec("A", "s", "1", "l"), rec("A-", "s", "1", "l"), rec("A.", "s", "1", "l"), rec("A_", "s", "1", "l"), rec("Aa", "s", "1", "l")].sort(compareRecords).map((x) => x.goal_id).join(",");' \
'if (text !== "A,A-,A.,A_,Aa,a") throw new Error(`ordinal ordering mismatch: ${text}`);' \
'const tokens = [rec("g", "s", "9223372036854775807", "z"), rec("g", "s", "9223372036854775806", "z"), rec("g", "s", "1", "z")].sort(compareRecords).map((x) => x.holder_fencing_token).join(",");' \
'if (tokens !== "1,9223372036854775806,9223372036854775807") throw new Error(`BigInt ordering mismatch: ${tokens}`);' \
'const leases = [rec("g", "s", "7", "a"), rec("g", "s", "7", "A"), rec("g", "s", "7", "a-")].sort(compareRecords).map((x) => x.lease_id).join(",");' \
'if (leases !== "A,a,a-") throw new Error(`lease ordering mismatch: ${leases}`);' \
'process.stdout.write("ordering fixtures passed\\n");' \
>"$ORDER_DRIVER"
node "$ORDER_DRIVER" "$ORDER_SOURCE" >/dev/null || fail "ordinal and BigInt ordering fixtures"
ok "ordinal punctuation/case and adjacent maximum-token ordering"

set +e
FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$DATA_ROOT" FM_STATE_OVERRIDE="$STATE_ROOT" "$ROOT/bin/fm-workgraph-lease-lib.sh" release g --lease-id l2 --holder-id actorA --fencing-token 1 >/dev/null 2>"$TMP_ROOT/err"
RC=$?
set -e
if ! { [ "$RC" -eq 1 ] && grep -qx 'fm-workgraph: WG-L-E-OWNER: lease operation failed' "$TMP_ROOT/err"; }; then fail "terminal owner precedence"; fi
ok "terminal owner rejection"

for precedence_case in fence-terminal-owner fence-terminal-token fence-terminal-state release-terminal-token; do
  set +e
  case "$precedence_case" in
    fence-terminal-owner) FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$DATA_ROOT" FM_STATE_OVERRIDE="$STATE_ROOT" "$ROOT/bin/fm-workgraph-lease-lib.sh" fence g --lease-id l1 --holder-id wrong --fencing-token 999 >"$TMP_ROOT/err.out" 2>"$TMP_ROOT/err"; RC=$?; expected_code=OWNER ;;
    fence-terminal-token) FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$DATA_ROOT" FM_STATE_OVERRIDE="$STATE_ROOT" "$ROOT/bin/fm-workgraph-lease-lib.sh" fence g --lease-id l1 --holder-id h1 --fencing-token 999 >"$TMP_ROOT/err.out" 2>"$TMP_ROOT/err"; RC=$?; expected_code=TOKEN ;;
    fence-terminal-state) FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$DATA_ROOT" FM_STATE_OVERRIDE="$STATE_ROOT" "$ROOT/bin/fm-workgraph-lease-lib.sh" fence g --lease-id l1 --holder-id h1 --fencing-token 2 >"$TMP_ROOT/err.out" 2>"$TMP_ROOT/err"; RC=$?; expected_code=STATE ;;
    release-terminal-token) FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$DATA_ROOT" FM_STATE_OVERRIDE="$STATE_ROOT" "$ROOT/bin/fm-workgraph-lease-lib.sh" release g --lease-id l1 --holder-id h1 --fencing-token 999 >"$TMP_ROOT/err.out" 2>"$TMP_ROOT/err"; RC=$?; expected_code=TOKEN ;;
  esac
  set -e
  if ! { [ "$RC" -eq 1 ] && [ ! -s "$TMP_ROOT/err.out" ] && grep -qx "fm-workgraph: WG-L-E-$expected_code: lease operation failed" "$TMP_ROOT/err"; }; then fail "$precedence_case"; fi
done
ok "fence OWNER/TOKEN/STATE and terminal release TOKEN precedence"

sleep 10 & CONFLICT_PID=$!
run "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/graph.json" s --registry "$TMP_ROOT/inputs/registry.json" --lease-id l3 --holder-id h3 --holder-pid "$CONFLICT_PID"
[ "$RC" -eq 0 ] || fail "precedence conflict seed"
printf '%s\n' 9223372036854775807 >"$STORE/fencing-counter"
set +e
FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$DATA_ROOT" FM_STATE_OVERRIDE="$STATE_ROOT" "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/graph.json" s --registry "$TMP_ROOT/inputs/registry.json" --lease-id l4 --holder-id h4 --holder-pid "$$" >"$TMP_ROOT/err.out" 2>"$TMP_ROOT/err"
RC=$?; set -e
kill "$CONFLICT_PID" 2>/dev/null || true; wait "$CONFLICT_PID" 2>/dev/null || true
if ! { [ "$RC" -eq 1 ] && [ ! -s "$TMP_ROOT/err.out" ] && grep -qx 'fm-workgraph: WG-L-E-CONFLICT: lease operation failed' "$TMP_ROOT/err"; }; then fail "acquire conflict before overflow"; fi
ok "acquire conflict wins over overflow"

jq '.claims=[{"resource":"unknown://unprojectable","mode":"exclusive"}]' "$TMP_ROOT/inputs/contract.json" >"$TMP_ROOT/inputs/self-contract.json"
SELF_CONTRACT_SHA=$(sha256sum "$TMP_ROOT/inputs/self-contract.json" | awk '{print $1}')
printf '%s\n' "{\"schema_version\":\"workgraph/v1\",\"goal_id\":\"g\",\"slices\":[{\"slice_id\":\"s\",\"contract_path\":\"self-contract.json\",\"contract_sha256\":\"$SELF_CONTRACT_SHA\"}]}" >"$TMP_ROOT/inputs/self-graph.json"
FRESH_SELF_DATA="$TMP_ROOT/fresh-self/data"
FRESH_SELF_STATE="$TMP_ROOT/fresh-self/state"
mkdir -p "$FRESH_SELF_DATA" "$FRESH_SELF_STATE"
roots_manifest "$FRESH_SELF_DATA" "$FRESH_SELF_STATE" "$TMP_ROOT/fresh-self-before"
set +e
FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$FRESH_SELF_DATA" FM_STATE_OVERRIDE="$FRESH_SELF_STATE" "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/self-graph.json" s --registry "$TMP_ROOT/inputs/registry.json" --lease-id l-fresh-self --holder-id h4 --holder-pid "$$" >"$TMP_ROOT/err.out" 2>"$TMP_ROOT/err"
RC=$?
set -e
roots_manifest "$FRESH_SELF_DATA" "$FRESH_SELF_STATE" "$TMP_ROOT/fresh-self-after"
if ! { [ "$RC" -eq 1 ] && [ ! -s "$TMP_ROOT/err.out" ] && grep -qx 'fm-workgraph: WG-L-E-SELF: lease operation failed' "$TMP_ROOT/err" && cmp "$TMP_ROOT/fresh-self-before" "$TMP_ROOT/fresh-self-after"; }; then fail "fresh SELF zero mutation"; fi

RESIDUAL_DATA="$TMP_ROOT/residual/data"
RESIDUAL_STATE="$TMP_ROOT/residual/state"
mkdir -p "$RESIDUAL_DATA/workgraphs/.leases/v1" "$RESIDUAL_STATE"
chmod 0700 "$RESIDUAL_DATA/workgraphs" "$RESIDUAL_DATA/workgraphs/.leases" "$RESIDUAL_DATA/workgraphs/.leases/v1"
printf '%s\n' not-a-counter >"$RESIDUAL_DATA/workgraphs/.leases/v1/fencing-counter"
chmod 0600 "$RESIDUAL_DATA/workgraphs/.leases/v1/fencing-counter"
roots_manifest "$RESIDUAL_DATA" "$RESIDUAL_STATE" "$TMP_ROOT/residual-before"
set +e
FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$RESIDUAL_DATA" FM_STATE_OVERRIDE="$RESIDUAL_STATE" "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/self-graph.json" s --registry "$TMP_ROOT/inputs/registry.json" --lease-id l-residual-self --holder-id h4 --holder-pid "$$" >"$TMP_ROOT/err.out" 2>"$TMP_ROOT/err"
RC=$?
set -e
roots_manifest "$RESIDUAL_DATA" "$RESIDUAL_STATE" "$TMP_ROOT/residual-after"
if ! { [ "$RC" -eq 1 ] && [ ! -s "$TMP_ROOT/err.out" ] && grep -qx 'fm-workgraph: WG-L-E-NOT-RECONSTRUCTABLE: lease operation failed' "$TMP_ROOT/err" && cmp "$TMP_ROOT/residual-before" "$TMP_ROOT/residual-after"; }; then fail "residual namespace-less authority precedes SELF"; fi
ok "namespace-less residual authority is NOT-RECONSTRUCTABLE with zero mutation"

UNRELATED_DATA="$TMP_ROOT/unrelated/data"
UNRELATED_STATE="$TMP_ROOT/unrelated/state"
mkdir -p "$UNRELATED_DATA/workgraphs/ordinary-goal" "$UNRELATED_STATE"
chmod 0755 "$UNRELATED_DATA/workgraphs" "$UNRELATED_DATA/workgraphs/ordinary-goal"
printf '%s\n' unrelated >"$UNRELATED_DATA/workgraphs/ordinary-goal/output.txt"
chmod 0600 "$UNRELATED_DATA/workgraphs/ordinary-goal/output.txt"
roots_manifest "$UNRELATED_DATA" "$UNRELATED_STATE" "$TMP_ROOT/unrelated-before"
set +e
FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$UNRELATED_DATA" FM_STATE_OVERRIDE="$UNRELATED_STATE" "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/self-graph.json" s --registry "$TMP_ROOT/inputs/registry.json" --lease-id l-unrelated-self --holder-id h4 --holder-pid "$$" >"$TMP_ROOT/err.out" 2>"$TMP_ROOT/err"
RC=$?
set -e
roots_manifest "$UNRELATED_DATA" "$UNRELATED_STATE" "$TMP_ROOT/unrelated-after"
if ! { [ "$RC" -eq 1 ] && [ ! -s "$TMP_ROOT/err.out" ] && grep -qx 'fm-workgraph: WG-L-E-SELF: lease operation failed' "$TMP_ROOT/err" && cmp "$TMP_ROOT/unrelated-before" "$TMP_ROOT/unrelated-after"; }; then fail "unrelated workgraph data does not outrank SELF"; fi
ok "unrelated workgraph data permits deferred SELF with zero mutation"

ds_manifest "$TMP_ROOT/self-store-before"
chmod 0755 "$STORE"
set +e
FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$DATA_ROOT" FM_STATE_OVERRIDE="$STATE_ROOT" "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/self-graph.json" s --registry "$TMP_ROOT/inputs/registry.json" --lease-id l-self-store --holder-id h4 --holder-pid "$$" >"$TMP_ROOT/err.out" 2>"$TMP_ROOT/err"
RC=$?
set -e
chmod 0700 "$STORE"
ds_manifest "$TMP_ROOT/self-store-after"
if ! { [ "$RC" -eq 1 ] && [ ! -s "$TMP_ROOT/err.out" ] && grep -qx 'fm-workgraph: WG-L-E-STORE: lease operation failed' "$TMP_ROOT/err" && cmp "$TMP_ROOT/self-store-before" "$TMP_ROOT/self-store-after"; }; then fail "SELF plus STORE precedence"; fi

set +e
FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$DATA_ROOT" FM_STATE_OVERRIDE="$STATE_ROOT" "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/self-graph.json" s --registry "$TMP_ROOT/inputs/registry.json" --lease-id l-self-identity --holder-id h4 --holder-pid 999999999 >"$TMP_ROOT/err.out" 2>"$TMP_ROOT/err"
RC=$?
set -e
if ! { [ "$RC" -eq 1 ] && [ ! -s "$TMP_ROOT/err.out" ] && grep -qx 'fm-workgraph: WG-L-E-IDENTITY: lease operation failed' "$TMP_ROOT/err"; }; then fail "SELF plus IDENTITY precedence"; fi

cp "$STORE/records/g/l2/1.json" "$TMP_ROOT/self-corrupt-record.json"
printf '{' >"$STORE/records/g/l2/1.json"
set +e
FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$DATA_ROOT" FM_STATE_OVERRIDE="$STATE_ROOT" "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/self-graph.json" s --registry "$TMP_ROOT/inputs/registry.json" --lease-id l-self-corrupt --holder-id h4 --holder-pid "$$" >"$TMP_ROOT/err.out" 2>"$TMP_ROOT/err"
RC=$?
set -e
mv "$TMP_ROOT/self-corrupt-record.json" "$STORE/records/g/l2/1.json"
if ! { [ "$RC" -eq 1 ] && [ ! -s "$TMP_ROOT/err.out" ] && grep -qx 'fm-workgraph: WG-L-E-NOT-RECONSTRUCTABLE: lease operation failed' "$TMP_ROOT/err"; }; then fail "SELF plus corrupt store precedence"; fi

ds_manifest "$TMP_ROOT/reused-before"
set +e
FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$DATA_ROOT" FM_STATE_OVERRIDE="$STATE_ROOT" "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/self-graph.json" s --registry "$TMP_ROOT/inputs/registry.json" --lease-id l1 --holder-id h4 --holder-pid "$$" >"$TMP_ROOT/err.out" 2>"$TMP_ROOT/err"
RC=$?; set -e
ds_manifest "$TMP_ROOT/reused-after"
if ! { [ "$RC" -eq 1 ] && [ ! -s "$TMP_ROOT/err.out" ] && grep -qx 'fm-workgraph: WG-L-E-LEASE-ID-REUSED: lease operation failed' "$TMP_ROOT/err" && cmp "$TMP_ROOT/reused-before" "$TMP_ROOT/reused-after"; }; then fail "reused ID before invalid self projection"; fi
ok "reused ID wins over SELF with zero mutation"

cp "$STORE/records/g/l2/2.json" "$TMP_ROOT/revision2.original"
for relation_field in namespace_id goal_id slice_id lease_id graph_sha256 contract_sha256 registry_sha256 holder_id holder_process holder_fencing_token resources state revision transaction_generation current_fencing_token terminal_kind terminal_actor terminal_proof; do
  cp "$TMP_ROOT/revision2.original" "$STORE/records/g/l2/2.json"
  case "$relation_field" in
    namespace_id) relation_filter='.namespace_id="0000000000000000000000000000000000000000000000000000000000000000"' ;;
    goal_id) relation_filter='.goal_id="wrong-goal"' ;;
    slice_id) relation_filter='.slice_id="wrong-slice"' ;;
    lease_id) relation_filter='.lease_id="wrong-lease"' ;;
    graph_sha256) relation_filter='.graph_sha256="0000000000000000000000000000000000000000000000000000000000000000"' ;;
    contract_sha256) relation_filter='.contract_sha256="0000000000000000000000000000000000000000000000000000000000000000"' ;;
    registry_sha256) relation_filter='.registry_sha256="0000000000000000000000000000000000000000000000000000000000000000"' ;;
    holder_id) relation_filter='.holder_id="wrong-holder"' ;;
    holder_process) relation_filter='.holder_process.start_ticks="1"' ;;
    holder_fencing_token) relation_filter='.holder_fencing_token="2"' ;;
    resources) relation_filter='.resources=[]' ;;
    state) relation_filter='.state="held"' ;;
    revision) relation_filter='.revision="1"' ;;
    transaction_generation) relation_filter='.transaction_generation="1"' ;;
    current_fencing_token) relation_filter='.current_fencing_token="1"' ;;
    terminal_kind) relation_filter='.terminal.kind="release"' ;;
    terminal_actor) relation_filter='.terminal.actor_id=""' ;;
    terminal_proof) relation_filter='.terminal.proof="holder-release"' ;;
  esac
  jq "$relation_filter" "$TMP_ROOT/revision2.original" >"$TMP_ROOT/tampered-revision.json"
  mv "$TMP_ROOT/tampered-revision.json" "$STORE/records/g/l2/2.json"
  chmod 0600 "$STORE/records/g/l2/2.json"
  set +e
  FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$DATA_ROOT" FM_STATE_OVERRIDE="$STATE_ROOT" "$ROOT/bin/fm-workgraph-lease-lib.sh" inspect g --lease-id l2 --history >/dev/null 2>"$TMP_ROOT/err"
  RC=$?
  set -e
  if ! { [ "$RC" -eq 1 ] && grep -qx 'fm-workgraph: WG-L-E-NOT-RECONSTRUCTABLE: lease operation failed' "$TMP_ROOT/err"; }; then fail "revision relation negative: $relation_field"; fi
done
cp "$TMP_ROOT/revision2.original" "$STORE/records/g/l2/2.json"
ok "all immutable and transition relation negatives"

mkdir -p "$STORE/records/other/l1"
jq -c '.goal_id="other"' "$STORE/records/g/l1/1.json" >"$TMP_ROOT/duplicate.json"
chmod 0600 "$TMP_ROOT/duplicate.json"
mv "$TMP_ROOT/duplicate.json" "$STORE/records/other/l1/1.json"
set +e
FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$DATA_ROOT" FM_STATE_OVERRIDE="$STATE_ROOT" "$ROOT/bin/fm-workgraph-lease-lib.sh" inspect g --history >/dev/null 2>"$TMP_ROOT/err"
RC=$?
set -e
if ! { [ "$RC" -eq 1 ] && grep -qx 'fm-workgraph: WG-L-E-NOT-RECONSTRUCTABLE: lease operation failed' "$TMP_ROOT/err"; }; then fail "cross-goal duplicate lease id"; fi
rm -f "$STORE/records/other/l1/1.json"
rmdir "$STORE/records/other/l1" "$STORE/records/other"
ok "cross-goal duplicate lease id rejected"

OWNER_ZERO_SEED_HOME="$TMP_ROOT/owner-zero-seed"
OWNER_ZERO_SEED_DATA="$OWNER_ZERO_SEED_HOME/data"
OWNER_ZERO_SEED_STATE="$OWNER_ZERO_SEED_HOME/state"
mkdir -p "$OWNER_ZERO_SEED_DATA" "$OWNER_ZERO_SEED_STATE"
run env FM_HOME="$OWNER_ZERO_SEED_HOME" FM_DATA_OVERRIDE="$OWNER_ZERO_SEED_DATA" FM_STATE_OVERRIDE="$OWNER_ZERO_SEED_STATE" "$ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$TMP_ROOT/inputs/graph.json" s --registry "$TMP_ROOT/inputs/registry.json" --lease-id owner-zero-seed --holder-id owner-zero-holder --holder-pid "$$"
[ "$RC" -eq 0 ] || fail "owner-zero seed"
owner_zero_case() {
  local name=$1
  local case_home="$TMP_ROOT/owner-zero-$name"
  local case_data="$case_home/data"
  local case_state="$case_home/state"
  local case_store="$case_data/workgraphs/.leases/v1"
  mkdir -p "$case_data" "$case_state"
  cp -a "$OWNER_ZERO_SEED_DATA/." "$case_data/"
  cp -a "$OWNER_ZERO_SEED_STATE/." "$case_state/"
  jq -c '.generation="0"' "$case_store/transaction-owner.json" >"$case_home/owner.json"
  chmod 0600 "$case_home/owner.json"
  mv "$case_home/owner.json" "$case_store/transaction-owner.json"
  case "$name" in
    record) printf '%s\n' '{' >"$case_store/records/g/owner-zero-seed/1.json" ;;
    event) printf '%s\n' '{' >"$case_store/events/00000000000000000001.json" ;;
    namespace) jq -c '.namespace_id="0000000000000000000000000000000000000000000000000000000000000000"' "$case_store/namespace.json" >"$case_home/namespace.json"; chmod 0600 "$case_home/namespace.json"; mv "$case_home/namespace.json" "$case_store/namespace.json" ;;
    temp) printf 'invalid-temp-name\n' >"$case_store/.bad.tmp.!!!!!"; chmod 0600 "$case_store/.bad.tmp.!!!!!" ;;
    counter) rm "$case_store/fencing-counter"; ln -s /dev/null "$case_store/fencing-counter" ;;
    generation) printf '%s\n' not-a-generation >"$case_store/transaction-generation"; chmod 0600 "$case_store/transaction-generation" ;;
    duplicate) mkdir -p "$case_store/records/other/owner-zero-seed"; jq -c '.goal_id="other"' "$case_store/records/g/owner-zero-seed/1.json" >"$case_home/duplicate.json"; chmod 0600 "$case_home/duplicate.json"; mv "$case_home/duplicate.json" "$case_store/records/other/owner-zero-seed/1.json" ;;
  esac
  roots_manifest "$case_data" "$case_state" "$case_home/before"
  set +e
  FM_HOME="$case_home" FM_DATA_OVERRIDE="$case_data" FM_STATE_OVERRIDE="$case_state" "$ROOT/bin/fm-workgraph-lease-lib.sh" inspect g --history >"$case_home/stdout" 2>"$case_home/stderr"
  RC=$?
  set -e
  roots_manifest "$case_data" "$case_state" "$case_home/after"
  if ! { [ "$RC" -eq 1 ] && [ ! -s "$case_home/stdout" ] && grep -qx 'fm-workgraph: WG-L-E-SCHEMA: lease operation failed' "$case_home/stderr" && cmp "$case_home/before" "$case_home/after"; }; then fail "owner-zero schema precedence $name"; fi
}
for owner_zero_collision in record event namespace temp counter generation duplicate; do owner_zero_case "$owner_zero_collision"; done
ok "owner generation zero promotes durable multi-error collisions to SCHEMA without mutation"

for temp_case in symlink fifo directory hardlink mode; do
  temp_name="$STORE/.audit.tmp.AAAAAA"
  expected_temp_code=NOT-RECONSTRUCTABLE
  case "$temp_case" in
    symlink) ln -s /dev/null "$temp_name" ;;
    fifo) mkfifo "$temp_name" ;;
    directory) mkdir "$temp_name" ;;
    hardlink) ln "$STORE/namespace.json" "$temp_name"; expected_temp_code=STORE ;;
    mode) printf 'x' >"$temp_name"; chmod 0644 "$temp_name" ;;
  esac
  set +e
  FM_SERIALIZER_EXPECT_FAILURE=1 serialize_tree rawhex "$TMP_ROOT/unsupported.manifest" "${MATRIX_RERUN_ROOT:-$TMP_ROOT}" - D "$DATA_ROOT" D 2>"$TMP_ROOT/unsupported.manifest.stderr"
  manifest_rc=$?
  FM_HOME="$HOME_ROOT" FM_DATA_OVERRIDE="$DATA_ROOT" FM_STATE_OVERRIDE="$STATE_ROOT" "$ROOT/bin/fm-workgraph-lease-lib.sh" inspect g --history >/dev/null 2>"$TMP_ROOT/err"
  RC=$?
  set -e
  [ "$manifest_rc" -ne 0 ] || fail "raw manifest accepted unsupported temp $temp_case"
  if ! { [ "$RC" -eq 1 ] && grep -qx "fm-workgraph: WG-L-E-$expected_temp_code: lease operation failed" "$TMP_ROOT/err"; }; then fail "unsafe temp $temp_case"; fi
  case "$temp_case" in
    directory) rmdir "$temp_name" ;;
    *) rm -f "$temp_name" ;;
  esac
done
ok "all ignored temporary-file shapes are validated"

fi

# Contract matrix: these are the sealed IDs, not generated placeholders.
MATRIX_IDS='S5V1-01 S5V1-02 S5V1-03 S5V1-04 S5V1-05 S5V1-06 S5V1-07 S5V1-08 S5V1-09 S5V1-10 S5V1-11 S5V1-12 S5V1-13 S5V1-14 S5V1-15 S5V3-TXN-BOOT S5V3-TXN-NO-TIME S5V3-TXN-LIVE-UNCERTAIN S5V3-TXN-SUPERIOR-GENERATION S5V3-BOOT-ID-BYTES S5V3-UNSUPPORTED-IDENTITY S5V3-ACQUIRE-DEAD-SPLIT S5V3-ORPHAN-CACHE-STATUS S5V3-READBACK-ONCE S5V3-READBACK-BYTE-TYPE-METADATA-ERROR S5V3-TERMINAL-RECOVER S5V3-TERMINAL-RELEASE-FENCE S5V3-RELEASE-DIFFERENT-PID S5V3-EXACT-SUCCESS-BYTES S5V3-INSPECT-HISTORY-ORDER S5V3-STATUS-GOAL-SCOPE S5V3-COUNTER-RECONSTRUCTION S5V3-EVENT-RECORD-INVARIANTS S5V3-CRASH-EACH-PUBLICATION S5V3-SLICE4-BYTE-ORACLE S5V3-OUTPUT-MANIFEST S5V4-GENERATION-ZERO S5V4-FRESH-LOCK-OPEN S5V4-TRANSACTION-CROSS-FILE S5V4-SIX-SCHEMAS S5V4-IMMUTABLE-REVISION-HISTORY S5V4-CACHE-CANONICAL-BYTES S5V4-COUNTER-FLOOR S5V4-PUBLICATION-SUB-BOUNDARIES S5V4-TARGET-ONLY-REPAIR S5V4-EVIDENCE-SERIALIZATION S5V4-ORACLE-ROOTS'
[ "$(wc -w <<<"$MATRIX_IDS")" -eq 47 ] || fail "sealed matrix manifest"
write_identity_tokens() {
  local root=$1 data_root=$2 state_root=$3 output=$4
  shift 4
  python3 - "$root" "$data_root" "$state_root" "$output" "$@" <<'PY_IDENTITY_TOKENS' || fail "case identity token capture"
import ctypes
import ctypes.util
import hashlib
import json
import os
import stat
import sys

root, data_root, state_root, output = sys.argv[1:5]
candidate_pids = sys.argv[5:]
exact_names = ("namespace_id", "cmdline_sha256", "boot_id", "hostname")
decimal_names = ("pid", "start_ticks")
values = {name: set() for name in exact_names + decimal_names}
if not candidate_pids:
    raise SystemExit("explicit identity capture required")

def unique_items(items):
    result = {}
    for key, value in items:
        if key in result:
            raise ValueError("duplicate identity token key")
        result[key] = value
    return result

def stat_key(value):
    return (value.st_mode, value.st_ino, value.st_dev, value.st_uid, value.st_gid,
            value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns)

def read_identity(pid):
    proc = f"/proc/{pid}"
    def read():
        with open(f"{proc}/stat", "rb") as stream:
            stat_bytes = stream.read()
        close = stat_bytes.rfind(b")")
        fields = stat_bytes[close + 2:].split()
        if len(fields) <= 19:
            raise RuntimeError("stat fields")
        with open(f"{proc}/cmdline", "rb") as stream:
            cmdline = stream.read()
        with open("/proc/sys/kernel/random/boot_id", "rb") as stream:
            boot = stream.read()
        with open("/proc/sys/kernel/hostname", "rb") as stream:
            hostname = stream.read()
        if boot.endswith(b"\n"):
            boot = boot[:-1]
        if hostname.endswith(b"\n"):
            hostname = hostname[:-1]
        return {
            "pid": str(pid),
            "start_ticks": fields[19].decode("ascii"),
            "cmdline_sha256": hashlib.sha256(cmdline).hexdigest(),
            "boot_id": boot.decode("ascii"),
            "hostname": hostname.decode("ascii"),
        }
    first, second = read(), read()
    if first != second:
        raise RuntimeError("identity changed")
    return first

def main():
    root_abs = os.path.abspath(root)
    output_abs = os.path.abspath(output)
    if os.path.commonpath((root_abs, output_abs)) != root_abs or os.path.realpath(root_abs) != root_abs:
        raise SystemExit("identity output confinement")
    anchor = os.open(root_abs, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    held = [(anchor, os.lstat(root_abs), root_abs)]
    existing_fd = None
    try:
        if stat_key(held[0][1]) != stat_key(os.fstat(anchor)):
            raise SystemExit("identity root race")
        parent = anchor
        parent_path = root_abs
        relative = os.path.relpath(output_abs, root_abs)
        parts = [part.encode("utf-8") for part in relative.split(os.sep) if part not in {"", "."}]
        if not parts:
            raise SystemExit("identity output type")
        for component in parts[:-1]:
            before = os.stat(component, dir_fd=parent, follow_symlinks=False)
            if not stat.S_ISDIR(before.st_mode):
                raise SystemExit("identity output parent")
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
            if stat_key(before) != stat_key(os.fstat(child)):
                os.close(child)
                raise SystemExit("identity output parent race")
            parent_path = os.path.join(parent_path, os.fsdecode(component))
            held.append((child, before, parent_path))
            parent = child
        output_name = parts[-1]
        deepest = len(held) - 1

        def verify_chain(full_deepest):
            for index, (fd_bound, bound_stat, lexical_path) in enumerate(held):
                expected = stat_key(bound_stat)
                current = stat_key(os.fstat(fd_bound))
                lexical = stat_key(os.lstat(lexical_path))
                if index == deepest and not full_deepest:
                    expected, current, lexical = expected[:6], current[:6], lexical[:6]
                if current != expected or lexical != expected:
                    raise SystemExit("identity output ancestor race")

        def swap_for_test():
            if os.environ.get("FM_IDENTITY_RACE_SWAP") != "1":
                return
            names = ("FM_IDENTITY_RACE_FROM", "FM_IDENTITY_RACE_TO", "FM_IDENTITY_RACE_HOLD")
            paths = [os.path.abspath(os.environ[name]) for name in names]
            for candidate in paths:
                if os.path.commonpath((root_abs, os.path.abspath(candidate))) != root_abs:
                    raise SystemExit("identity race escapes root")
            os.rename(paths[0], paths[2])
            os.rename(paths[1], paths[0])

        def read_exact(fd, size):
            chunks = []
            while True:
                chunk = os.read(fd, 65536)
                if not chunk:
                    break
                chunks.append(chunk)
            value = b"".join(chunks)
            if len(value) != size:
                raise SystemExit("identity seed short read")
            return value

        try:
            existing_stat = os.stat(output_name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            existing_stat = None
        existing_key = None
        if existing_stat is not None:
            if not stat.S_ISREG(existing_stat.st_mode) or existing_stat.st_nlink != 1 or existing_stat.st_uid != os.geteuid() or stat.S_IMODE(existing_stat.st_mode) != 0o600:
                raise SystemExit("identity seed shape")
            existing_fd = os.open(output_name, os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
            existing_key = stat_key(existing_stat)
            if stat_key(os.fstat(existing_fd)) != existing_key:
                raise SystemExit("identity seed race")
            seed_bytes = read_exact(existing_fd, existing_stat.st_size)
            if stat_key(os.fstat(existing_fd)) != existing_key or stat_key(os.stat(output_name, dir_fd=parent, follow_symlinks=False)) != existing_key:
                raise SystemExit("identity seed race")
            seed = json.loads(seed_bytes.decode("utf-8"), object_pairs_hook=unique_items,
                              parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
            if not isinstance(seed, dict) or set(seed) != set(exact_names + decimal_names):
                raise SystemExit("identity seed keys")
            for name in exact_names + decimal_names:
                if not isinstance(seed[name], list):
                    raise SystemExit("identity seed values")
                values[name].update(seed[name])

        namespace_path = os.path.abspath(data_root)
        values["namespace_id"].add(hashlib.sha256(f"firstmate-workgraph-lease-namespace/v1\n{namespace_path}\n".encode("utf-8")).hexdigest())
        for pid in candidate_pids:
            captured = read_identity(pid)
            for name, value in captured.items():
                values[name].add(value)
        result = {}
        for name in exact_names:
            result[name] = sorted(values[name])
        for name in decimal_names:
            result[name] = sorted(values[name], key=lambda item: (len(item), item))
        payload = (json.dumps(result, ensure_ascii=False, separators=(",", ":"), sort_keys=False) + "\n").encode("utf-8")

        if existing_fd is not None:
            swap_for_test()
            verify_chain(True)
            if stat_key(os.fstat(existing_fd)) != existing_key or stat_key(os.stat(output_name, dir_fd=parent, follow_symlinks=False)) != existing_key:
                raise SystemExit("identity output race")
            os.ftruncate(existing_fd, 0)
            offset = 0
            while offset < len(payload):
                written = os.write(existing_fd, payload[offset:])
                if written <= 0:
                    raise SystemExit("identity output short write")
                offset += written
            os.fsync(existing_fd)
            os.lseek(existing_fd, 0, os.SEEK_SET)
            if read_exact(existing_fd, len(payload)) != payload:
                raise SystemExit("identity output readback")
            final_key = stat_key(os.fstat(existing_fd))
            lexical_key = stat_key(os.stat(output_name, dir_fd=parent, follow_symlinks=False))
            if final_key[:6] != (existing_key[0], existing_key[1], existing_key[2], existing_key[3], existing_key[4], 1) or lexical_key[:6] != final_key[:6]:
                raise SystemExit("identity output identity")
            verify_chain(False)
            return

        verify_chain(True)
        temp_name = None
        temp_fd = None
        published = False
        try:
            for attempt in range(100):
                candidate = b".identity.tmp." + str(os.getpid()).encode("ascii") + b"." + str(attempt).encode("ascii")
                try:
                    temp_fd = os.open(candidate, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=parent)
                    temp_name = candidate
                    break
                except FileExistsError:
                    continue
            if temp_fd is None:
                raise SystemExit("identity temp collision")
            temp_stat = os.fstat(temp_fd)
            parent_stat = os.fstat(parent)
            if not stat.S_ISREG(temp_stat.st_mode) or stat.S_IMODE(temp_stat.st_mode) != 0o600 or temp_stat.st_uid != os.geteuid() or temp_stat.st_nlink != 1 or temp_stat.st_dev != parent_stat.st_dev:
                raise SystemExit("identity temp shape")
            offset = 0
            while offset < len(payload):
                written = os.write(temp_fd, payload[offset:])
                if written <= 0:
                    raise SystemExit("identity temp short write")
                offset += written
            os.fsync(temp_fd)
            if stat_key(os.fstat(temp_fd))[:6] != stat_key(temp_stat)[:6]:
                raise SystemExit("identity temp race")
            os.lseek(temp_fd, 0, os.SEEK_SET)
            if read_exact(temp_fd, len(payload)) != payload:
                raise SystemExit("identity temp readback")
            swap_for_test()
            verify_chain(False)
            libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
            renameat2 = getattr(libc, "renameat2", None)
            if renameat2 is None:
                raise SystemExit("renameat2 unavailable")
            renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
            renameat2.restype = ctypes.c_int
            if renameat2(parent, temp_name, parent, output_name, 1) != 0:
                raise SystemExit("identity output exists")
            published = True
            verify_chain(False)
            final_fd = os.open(output_name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
            try:
                final_stat = os.fstat(final_fd)
                if (final_stat.st_dev, final_stat.st_ino, final_stat.st_mode, final_stat.st_uid, final_stat.st_nlink, final_stat.st_size) != (temp_stat.st_dev, temp_stat.st_ino, temp_stat.st_mode, temp_stat.st_uid, 1, len(payload)):
                    raise SystemExit("identity output identity")
                os.lseek(final_fd, 0, os.SEEK_SET)
                if read_exact(final_fd, len(payload)) != payload:
                    raise SystemExit("identity output readback")
            finally:
                os.close(final_fd)
            os.fsync(parent)
            verify_chain(False)
        finally:
            if temp_fd is not None:
                os.close(temp_fd)
            if temp_name is not None and not published:
                try:
                    os.unlink(temp_name, dir_fd=parent)
                    os.fsync(parent)
                except FileNotFoundError:
                    pass
                except OSError:
                    raise SystemExit("identity temp cleanup")
    finally:
        if existing_fd is not None:
            os.close(existing_fd)
        for fd_bound, _, _ in reversed(held):
            os.close(fd_bound)

main()
PY_IDENTITY_TOKENS
}
manifest_files() {
  local root=$1 output=$2
  serialize_tree global "$output" "${MATRIX_RERUN_ROOT:-$TMP_ROOT}" "$SERIALIZER_IDENTITY_FILE" D "$root/data" D/workgraphs/.leases/v1 S "$root/state" S/workgraphs/g
}
normalized_manifest_files() {
  local root=$1 output=$2
  serialize_tree normalized "$output" "${MATRIX_RERUN_ROOT:-$TMP_ROOT}" "$SERIALIZER_IDENTITY_FILE" D "$root/data" D/workgraphs/.leases/v1 S "$root/state" S/workgraphs/g
}
run_manifest() {
  local mode=$1 output=$2 snapshot_kind=$3
  local matrix_id matrix_index=0
  local -a pairs=()
  for matrix_id in $MATRIX_IDS; do
    matrix_index=$((matrix_index + 1))
    pairs+=("cases/$matrix_id/D" "D" "$MATRIX_RERUN_ROOT/matrix-${matrix_pass}-${matrix_id}.${snapshot_kind}")
    pairs+=("cases/$matrix_id/S" "S" "$MATRIX_RERUN_ROOT/matrix-${matrix_pass}-${matrix_id}.${snapshot_kind}")
  done
  if [ "$mode" = union ]; then
    serialize_tree union "$output" "$MATRIX_RERUN_ROOT" - "${pairs[@]}"
  else
    fail "run manifest mode"
  fi
}
write_mutations() {
  local before=$1 after=$2 output=$3
  serialize_tree mutations "$output" "$MATRIX_RERUN_ROOT" "$SERIALIZER_IDENTITY_FILE" "$before" "$after"
}
normalize_stream() {
  local source=$1 output=$2
  serialize_tree stream "$output" "$MATRIX_RERUN_ROOT" "$SERIALIZER_IDENTITY_FILE" "$source"
}
serializer_vectors() {
  local vector_root=${1:-"$TMP_ROOT/serializer-vectors"}
  local raw_paths expected_paths target_hex normalized_target vector_identity raw_path_hex raw_symlink_line normalized_symlink_line
  mkdir -p "$vector_root/a/data/workgraphs/.leases/v1" "$vector_root/a/state/workgraphs/g"
  mkdir -p "$vector_root/b/data/workgraphs/.leases/v1" "$vector_root/b/state/workgraphs/g"
  vector_identity="$vector_root/identity.json"
  printf '%s\n' '{"namespace_id":[],"cmdline_sha256":[],"boot_id":[],"hostname":[],"pid":[],"start_ticks":[]}' >"$vector_identity"
  chmod 0600 "$vector_identity"
  printf '%s' b >"$vector_root/a/data/workgraphs/.leases/v1/z"
  printf '%s' a >"$vector_root/a/data/workgraphs/.leases/v1/a"
  printf '%s' S >"$vector_root/b/state/workgraphs/g/item"
  ln -s "$vector_root/x.tmp.A1b2C3" "$vector_root/a/state/workgraphs/g/vector"
  target_hex=$(printf '%s' "$vector_root/x.tmp.A1b2C3" | od -An -tx1 | tr -d ' \n')
  normalized_target=$(printf '%s' '<RUN_ROOT>/x.tmp.<TMP6>' | od -An -tx1 | tr -d ' \n')
  raw_path_hex=$(printf '%s' 'S/workgraphs/g/vector' | od -An -tx1 | tr -d ' \n')
  raw_symlink_line=$(printf 'l\t0777\t%s\t%s\n' "$raw_path_hex" "$target_hex")
  normalized_symlink_line=$(printf '%s  l  0777  S/workgraphs/g/vector\t%s\n' '-' "$normalized_target")
  serialize_tree rawhex "$vector_root/a.raw" "$vector_root" - D "$vector_root/a/data" D/workgraphs/.leases/v1 S "$vector_root/a/state" S/workgraphs/g
  raw_paths=$(cut -f3 "$vector_root/a.raw")
  expected_paths=$(printf '%s\n' "$raw_paths" | LC_ALL=C sort)
  [ "$raw_paths" = "$expected_paths" ] || fail "serializer raw path order"
  grep -Fqx "$raw_symlink_line" "$vector_root/a.raw" || fail "serializer raw symlink target"
  serialize_tree normalized "$vector_root/a.normalized" "$vector_root" "$vector_identity" D "$vector_root/a/data" D/workgraphs/.leases/v1 S "$vector_root/a/state" S/workgraphs/g
  grep -Fqx -- "$normalized_symlink_line" "$vector_root/a.normalized" || fail "serializer normalized symlink target"
  serialize_tree global "$vector_root/a.manifest" "$vector_root" - D "$vector_root/a/data" D/workgraphs/.leases/v1 S "$vector_root/a/state" S/workgraphs/g
  serialize_tree global "$vector_root/b.manifest" "$vector_root" - D "$vector_root/b/data" D/workgraphs/.leases/v1 S "$vector_root/b/state" S/workgraphs/g
  v10_root="$vector_root/cases/S5V3-OUTPUT-MANIFEST/S"
  v10_dir="$v10_root/workgraphs/g/vector"
  mkdir -p "$v10_dir"
  python3 - "$v10_dir" "$vector_root" <<'PY_V10_FIXTURE' || fail "serializer v10 fixture"
import os
import sys
directory, run_root = map(os.fsencode, sys.argv[1:3])
targets = [b"../target", b"a\tb", b"a\nb", b"\x80\xff", b"610a62", b"\x80/x.tmp.Ab09Zz", b"pre" + run_root + b"/x.tmp.A1b2C3"]
names = [b"01-ordinary", b"02-tab", b"03-lf", b"04-nonutf8", b"05-hex-looking", b"06-nonutf8-temp", b"07-run-root"]
for name, target in zip(names, targets):
    os.symlink(target, directory + b"/" + name)
PY_V10_FIXTURE
  local v10_name v10_raw_hex v10_raw_manifest v10_normalized_manifest
  for v10_name in 01-ordinary 02-tab 03-lf 04-nonutf8 05-hex-looking 06-nonutf8-temp 07-run-root; do
    v10_raw_hex="$vector_root/v10.rawhex.$v10_name"
    v10_raw_manifest="$vector_root/v10.raw.$v10_name"
    v10_normalized_manifest="$vector_root/v10.normalized.$v10_name"
    serialize_tree rawhex "$v10_raw_hex" "$vector_root" - S "$v10_dir" "S/$v10_name"
    serialize_tree global "$v10_raw_manifest" "$vector_root" - S "$v10_dir" "S/$v10_name"
    serialize_tree normalized "$v10_normalized_manifest" "$vector_root" "$vector_identity" S "$v10_dir" "S/$v10_name"
  done
  v10_union() {
    local output=$1 kind=$2 v10_item
    shift 2
    set --
    for v10_item in 01-ordinary 02-tab 03-lf 04-nonutf8 05-hex-looking 06-nonutf8-temp 07-run-root; do
      set -- "$@" cases/S5V3-OUTPUT-MANIFEST/S/workgraphs/g/vector S "$vector_root/v10.$kind.$v10_item"
    done
    serialize_tree union "$output" "$vector_root" - "$@"
  }
  v10_union "$vector_root/v10.raw-before" raw
  v10_union "$vector_root/v10.raw-after" raw
  v10_union "$vector_root/v10.normalized" normalized
  for v10_roundtrip in raw-before raw-after normalized; do
    serialize_tree union "$vector_root/v10.$v10_roundtrip.roundtrip" "$vector_root" - \
      cases/S5V3-OUTPUT-MANIFEST/S/workgraphs/g/vector cases/S5V3-OUTPUT-MANIFEST/S/workgraphs/g/vector "$vector_root/v10.$v10_roundtrip"
    cmp "$vector_root/v10.$v10_roundtrip" "$vector_root/v10.$v10_roundtrip.roundtrip" >/dev/null || fail "serializer v10 $v10_roundtrip roundtrip"
  done
  cat "$vector_root/v10.raw-before.roundtrip" "$vector_root/v10.raw-after.roundtrip" "$vector_root/v10.normalized.roundtrip" >"$vector_root/v10.expected"
  python3 - "$vector_root/v10.raw-before" "$vector_root/v10.raw-after" "$vector_root/v10.normalized" "$v10_dir" "$vector_root" <<'PY_V10_CHECK' || fail "serializer v10 target checker"
import os
import sys
raw_before, raw_after, normalized, directory, run_root = map(os.fsencode, sys.argv[1:6])
targets = [b"../target", b"a\tb", b"a\nb", b"\x80\xff", b"610a62", b"\x80/x.tmp.Ab09Zz", b"pre" + run_root + b"/x.tmp.A1b2C3"]
names = [b"01-ordinary", b"02-tab", b"03-lf", b"04-nonutf8", b"05-hex-looking", b"06-nonutf8-temp", b"07-run-root"]
manifest_prefix = b"cases/S5V3-OUTPUT-MANIFEST/S/workgraphs/g/vector/"
def manifest(path):
    found = []
    for index, line in enumerate(open(path, "rb")):
        fields = line.rstrip(b"\n").split(b"  ", 3)
        if fields[3].split(b"\t", 1)[0] != manifest_prefix + names[index]:
            raise SystemExit("v10 path mismatch")
        found.append(bytes.fromhex(fields[3].split(b"\t", 1)[1].decode("ascii")))
    if len(found) != 7:
        raise SystemExit("v10 target count")
    return found
if manifest(raw_before) != targets or manifest(raw_after) != targets:
    raise SystemExit("v10 raw target mismatch")
if [os.readlink(directory + b"/" + name) for name in names] != targets:
    raise SystemExit("v10 readlink mismatch")
rawhex = []
for name in names:
    line = open(run_root + b"/v10.rawhex." + name, "rb").read().rstrip(b"\n")
    rawhex.append(bytes.fromhex(line.split(b"\t", 3)[3].decode("ascii")))
if rawhex != targets:
    raise SystemExit("v10 rawhex mismatch")
expected = [item.replace(run_root, b"<RUN_ROOT>").replace(b".tmp.A1b2C3", b".tmp.<TMP6>").replace(b".tmp.Ab09Zz", b".tmp.<TMP6>") for item in targets]
if manifest(normalized) != expected:
    raise SystemExit("v10 normalized target mismatch")
PY_V10_CHECK
  serialize_tree union "$vector_root/union.manifest" "$vector_root" - cases/S5V3-TXN-BOOT/D D "$vector_root/a.manifest" cases/S5V1-01/D D "$vector_root/b.manifest" cases/S5V3-TXN-BOOT/S S "$vector_root/a.manifest" cases/S5V1-01/S S "$vector_root/b.manifest"
  grep -q 'cases/S5V3-TXN-BOOT/D/workgraphs/.leases/v1/a' "$vector_root/union.manifest" || fail "serializer union first case"
  grep -q 'cases/S5V1-01/S/workgraphs/g/item' "$vector_root/union.manifest" || fail "serializer union second case"
  [ "$(sed -n '1s/^.*  [fdl]  [0-7][0-7][0-7][0-7]  //p' "$vector_root/union.manifest")" = 'cases/S5V3-TXN-BOOT/D/workgraphs' ] || fail "serializer union case order"
  if (serialize_tree union "$vector_root/union-duplicate.out" "$vector_root" - cases/S5V3-TXN-BOOT/D D "$vector_root/a.manifest" cases/S5V3-TXN-BOOT/D D "$vector_root/a.manifest"); then fail "serializer union duplicate display path"; fi
  mkdir -p "$vector_root/missing/data/workgraphs/.leases" "$vector_root/missing/state"
  chmod 0755 "$vector_root/missing/data/workgraphs/.leases"
  serialize_tree global "$vector_root/missing.global" "$vector_root" - D "$vector_root/missing/data" D/workgraphs/.leases/v1
  grep -Fqx -- '-  d  0755  D/workgraphs/.leases' "$vector_root/missing.global" || fail "serializer missing-prefix predecessor"
  ! grep -Fqx -- '-  d  0755  D/workgraphs/.leases/v1' "$vector_root/missing.global" || fail "serializer missing-prefix descendant"
  printf '%s\n' $'-  l  0777  D/x\t6161' >"$vector_root/m-before"
  printf '%s\n' $'-  l  0777  D/x\t6262' >"$vector_root/m-after"
  serialize_tree mutations "$vector_root/mutations" "$vector_root" "$vector_identity" "$vector_root/m-before" "$vector_root/m-after"
  grep -qx $'M\tD/x\t-' "$vector_root/mutations" || fail "serializer symlink retarget mutation"
  for bad in no-tab empty odd upper nonhex extra-tab extra-byte f-digest d-digest; do
    case "$bad" in
      no-tab) line='-  l  0777  D/x' ;;
      empty) line=$'-  l  0777  D/x\t' ;;
      odd) line=$'-  l  0777  D/x\t6' ;;
      upper) line=$'-  l  0777  D/x\tAA' ;;
      nonhex) line=$'-  l  0777  D/x\tzz' ;;
      extra-tab) line=$'-  l  0777  D/x\t6161\tmore' ;;
      extra-byte) line=$'-  l  0777  D/x\t6161X' ;;
      f-digest) line=$'-  f  0600  D/x\t6161' ;;
      d-digest) line=$(printf '%064d  d  0755  D/x\n' 1) ;;
    esac
    printf '%s\n' "$line" >"$vector_root/bad"
    if (serialize_tree union "$vector_root/bad.out" "$vector_root" - D D "$vector_root/bad"); then fail "serializer accepted $bad"; fi
    if (serialize_tree mutations "$vector_root/bad.mutations" "$vector_root" "$vector_identity" "$vector_root/bad" "$vector_root/m-before"); then fail "mutations accepted $bad"; fi
  done
  for bad_path in nonutf8 control tab lf del; do
    path_manifest="$vector_root/path-$bad_path"
    case "$bad_path" in
      nonutf8) printf '%b\n' '-  d  0755  D/\200' >"$path_manifest" ;;
      control) printf '%b\n' '-  d  0755  D/\001' >"$path_manifest" ;;
      tab) printf '%b\n' '-  d  0755  D/\tbad' >"$path_manifest" ;;
      lf) printf '%b\n' '-  d  0755  D/a\nb' >"$path_manifest" ;;
      del) printf '%b\n' '-  d  0755  D/\177' >"$path_manifest" ;;
    esac
    if (serialize_tree union "$vector_root/path-$bad_path.out" "$vector_root" - D D "$path_manifest"); then fail "serializer accepted path $bad_path"; fi
  done
  control_name=$'\001'
  printf '%s' x >"$vector_root/a/data/workgraphs/.leases/v1/$control_name"
  if (serialize_tree global "$vector_root/control-path.manifest" "$vector_root" - D "$vector_root/a/data" D/workgraphs/.leases/v1); then fail "serializer observed control path"; fi
  rm -f -- "$vector_root/a/data/workgraphs/.leases/v1/$control_name"
  race_read="$vector_root/race-read"
  mkdir -p "$race_read/parent/alt" "$race_read/parent-alt/alt"
  printf '%s\n' read-old >"$race_read/parent/alt/stream"
  printf '%s\n' read-new >"$race_read/parent-alt/alt/stream"
  if (FM_SERIALIZER_RACE_SWAP=read_bound_regular FM_SERIALIZER_RACE_FROM="$race_read/parent" FM_SERIALIZER_RACE_TO="$race_read/parent-alt" FM_SERIALIZER_RACE_HOLD="$race_read/parent-old" serialize_tree stream "$vector_root/race-read.out" "$vector_root" "$vector_identity" "$race_read/parent/alt/stream"); then fail "serializer read-bound ancestor swap accepted"; fi
  [ ! -e "$vector_root/race-read.out" ] || fail "serializer read-bound swap published output"

  race_identity="$vector_root/race-identity"
  mkdir -p "$race_identity/parent" "$race_identity/parent-alt"
  cp "$vector_identity" "$race_identity/parent/tokens.json"
  cp "$vector_identity" "$race_identity/parent-alt/tokens.json"
  if (FM_SERIALIZER_RACE_SWAP=identity_file FM_SERIALIZER_RACE_FROM="$race_identity/parent" FM_SERIALIZER_RACE_TO="$race_identity/parent-alt" FM_SERIALIZER_RACE_HOLD="$race_identity/parent-old" serialize_tree stream "$vector_root/race-identity.out" "$vector_root" "$race_identity/parent/tokens.json" "$vector_root/stream-one"); then fail "serializer identity-file ancestor swap accepted"; fi
  [ ! -e "$vector_root/race-identity.out" ] || fail "serializer identity swap published output"

  race_scope="$vector_root/race-scope"
  mkdir -p "$race_scope/data/workgraphs/.leases/v1" "$race_scope/data-alt/workgraphs/.leases/v1"
  printf '%s' old >"$race_scope/data/workgraphs/.leases/v1/item"
  printf '%s' new >"$race_scope/data-alt/workgraphs/.leases/v1/item"
  if (FM_SERIALIZER_RACE_SWAP=observe_scope FM_SERIALIZER_RACE_FROM="$race_scope/data" FM_SERIALIZER_RACE_TO="$race_scope/data-alt" FM_SERIALIZER_RACE_HOLD="$race_scope/data-old" serialize_tree global "$vector_root/race-scope.out" "$vector_root" - D "$race_scope/data" D/workgraphs/.leases/v1); then fail "serializer observe-scope ancestor swap accepted"; fi
  [ ! -e "$vector_root/race-scope.out" ] || fail "serializer observe-scope swap published output"

  race_output="$vector_root/race-output"
  mkdir -p "$race_output/deep" "$race_output/deep-alt"
  if (FM_SERIALIZER_RACE_SWAP=output_parent FM_SERIALIZER_RACE_FROM="$race_output/deep" FM_SERIALIZER_RACE_TO="$race_output/deep-alt" FM_SERIALIZER_RACE_HOLD="$race_output/deep-old" serialize_tree rawhex "$race_output/deep/manifest" "$vector_root" - D "$vector_root/a/data" D/workgraphs/.leases/v1); then fail "serializer output-parent ancestor swap accepted"; fi
  [ ! -e "$race_output/deep/manifest" ] && [ ! -e "$race_output/deep-old/manifest" ] || fail "serializer output-parent swap published output"
  ! find "$race_output" -type f -name '.serializer.tmp.*' -print -quit | grep -q . || fail "serializer output-parent swap left temp"
  ok "deterministic read, identity, scope, and output-parent ancestor swaps fail closed"

  race_identity_publish="$vector_root/race-identity-publish"
  mkdir -p "$race_identity_publish/parent" "$race_identity_publish/parent-alt"
  race_identity_parent_key=$(stat -c '%d:%i' "$race_identity_publish/parent")
  printf '%s' outside >"$race_identity_publish/outside"
  cp "$race_identity_publish/outside" "$race_identity_publish/outside.before"
  ln -s "$race_identity_publish/outside" "$race_identity_publish/parent-alt/identity.json"
  if (FM_IDENTITY_RACE_SWAP=1 FM_IDENTITY_RACE_FROM="$race_identity_publish/parent" FM_IDENTITY_RACE_TO="$race_identity_publish/parent-alt" FM_IDENTITY_RACE_HOLD="$race_identity_publish/parent-old" write_identity_tokens "$vector_root" "$vector_root" "$vector_root" "$race_identity_publish/parent/identity.json" "$$"); then fail "identity publisher ancestor swap accepted"; fi
  [ -d "$race_identity_publish/parent-old" ] || fail "identity publisher race hook did not retain original parent"
  [ "$(stat -c '%d:%i' "$race_identity_publish/parent-old")" = "$race_identity_parent_key" ] || fail "identity publisher race hook changed original parent identity"
  [ -L "$race_identity_publish/parent/identity.json" ] || fail "identity publisher race hook did not install substituted symlink"
  cmp "$race_identity_publish/outside.before" "$race_identity_publish/outside" >/dev/null || fail "identity publisher truncated outside target"
  [ ! -e "$race_identity_publish/parent-old/identity.json" ] || fail "identity publisher published final output"
  ! find "$race_identity_publish" -type f -name '.identity.tmp.*' -print -quit | grep -q . || fail "identity publisher left temp"
  ok "descriptor-bound identity publication rejects validation-to-publication swap"

  mkdir -p "$vector_root/output-nested/one/two"
  serialize_tree rawhex "$vector_root/output-nested/one/two/manifest" "$vector_root" - D "$vector_root/a/data" D/workgraphs/.leases/v1
  printf '%s' preserved >"$vector_root/output-existing"
  cp "$vector_root/output-existing" "$vector_root/output-existing.before"
  if (serialize_tree rawhex "$vector_root/output-existing" "$vector_root" - D "$vector_root/a/data" D/workgraphs/.leases/v1); then fail "serializer clobbered existing output"; fi
  cmp "$vector_root/output-existing.before" "$vector_root/output-existing" >/dev/null || fail "existing output changed"
  printf '%s' hardlink-source >"$vector_root/output-hardlink-source"
  ln "$vector_root/output-hardlink-source" "$vector_root/output-hardlink"
  if (serialize_tree rawhex "$vector_root/output-hardlink" "$vector_root" - D "$vector_root/a/data" D/workgraphs/.leases/v1); then fail "serializer accepted hardlink output"; fi
  printf '%s' symlink-source >"$vector_root/output-symlink-target"
  ln -s "$vector_root/output-symlink-target" "$vector_root/output-symlink"
  if (serialize_tree rawhex "$vector_root/output-symlink" "$vector_root" - D "$vector_root/a/data" D/workgraphs/.leases/v1); then fail "serializer followed output symlink"; fi
  symlink_target=$(readlink "$vector_root/output-symlink")
  [ "$symlink_target" = "$vector_root/output-symlink-target" ] || fail "output symlink changed"
  if (FM_SERIALIZER_FAIL_AFTER_BYTES=1 serialize_tree rawhex "$vector_root/output-failed" "$vector_root" - D "$vector_root/a/data" D/workgraphs/.leases/v1); then fail "serializer write failure accepted"; fi
  [ ! -e "$vector_root/output-failed" ] || fail "failed output survived"
  ! find "$vector_root" -type f -name '.serializer.tmp.*' -print -quit | grep -q . || fail "serializer temp survived"
  printf '%s\n' '{"pid":"partial"}' >"$vector_root/stream-partial"
  serialize_tree stream "$vector_root/stream-partial.out" "$vector_root" "$vector_identity" "$vector_root/stream-partial"
  grep -q '"pid":"partial"' "$vector_root/stream-partial.out" || fail "serializer partial identity normalization"
  printf '%s\n' '{"pid":"x","start_ticks":"y","cmdline_sha256":"z","boot_id":"b","hostname":"h"}' >"$vector_root/stream-identity"
  serialize_tree stream "$vector_root/stream-identity.out" "$vector_root" "$vector_identity" "$vector_root/stream-identity"
  grep -q '"pid":"<PID>"' "$vector_root/stream-identity.out" || fail "serializer complete identity normalization"
  : >"$vector_root/stream-empty"
  serialize_tree stream "$vector_root/stream-empty.out" "$vector_root" "$vector_identity" "$vector_root/stream-empty"
  cmp "$vector_root/stream-empty" "$vector_root/stream-empty.out" >/dev/null || fail "serializer empty stream"
  printf '%s\n' '{"namespace_id":"one"}' >"$vector_root/stream-one"
  serialize_tree stream "$vector_root/stream-one.out" "$vector_root" "$vector_identity" "$vector_root/stream-one"
  grep -Fqx '{"namespace_id":"<NAMESPACE_ID>"}' "$vector_root/stream-one.out" || fail "serializer one JSON stream"
  printf '{"namespace_id":"ns-one","pid":"1234","start_ticks":"91234","cmdline_sha256":"cmd-one","boot_id":"boot-one","hostname":"host-one","path":"%s/x.tmp.A1b2C3"}\n{"namespace_id":"ns-two","pid":"5678","start_ticks":"81234","cmdline_sha256":"cmd-two","boot_id":"boot-two","hostname":"host-two","path":"pre%s/y.tmp.D3e4F5"}\n' "$vector_root" "$vector_root" >"$vector_root/stream-many"
  serialize_tree stream "$vector_root/stream-many.out" "$vector_root" "$vector_identity" "$vector_root/stream-many"
  ! cmp "$vector_root/stream-many" "$vector_root/stream-many.out" >/dev/null || fail "serializer multiple JSON stream fallback"
  ! grep -Fq "$vector_root" "$vector_root/stream-many.out" || fail "serializer stream root normalization"
  [ "$(grep -c '\"cmdline_sha256\":\"<CMDLINE_SHA256>\"' "$vector_root/stream-many.out")" -eq 2 ] || fail "serializer stream per-record identity normalization"
  grep -Fq '<RUN_ROOT>/x.tmp.<TMP6>' "$vector_root/stream-many.out" || fail "serializer stream first path normalization"
  grep -Fq 'pre<RUN_ROOT>/y.tmp.<TMP6>' "$vector_root/stream-many.out" || fail "serializer stream second path normalization"
  printf '%s\n\n%s\n' '{"a":1}' '{"b":2}' >"$vector_root/stream-interior-empty"
  serialize_tree stream "$vector_root/stream-interior-empty.out" "$vector_root" "$vector_identity" "$vector_root/stream-interior-empty"
  cmp "$vector_root/stream-interior-empty" "$vector_root/stream-interior-empty.out" >/dev/null || fail "serializer interior-empty stream"
  printf '%s\nraw\n' '{"a":1}' >"$vector_root/stream-mixed"
  serialize_tree stream "$vector_root/stream-mixed.out" "$vector_root" "$vector_identity" "$vector_root/stream-mixed"
  cmp "$vector_root/stream-mixed" "$vector_root/stream-mixed.out" >/dev/null || fail "serializer mixed stream"
  printf '%s\n%s\n' 'raw' '{"a":1,"a":2}' >"$vector_root/stream-raw-then-duplicate"
  if (serialize_tree stream "$vector_root/stream-raw-then-duplicate.out" "$vector_root" "$vector_identity" "$vector_root/stream-raw-then-duplicate"); then fail "serializer hidden duplicate after raw"; fi
  printf '%s\n%s\n' '{"a":1,"a":2}' 'raw' >"$vector_root/stream-duplicate-then-raw"
  if (serialize_tree stream "$vector_root/stream-duplicate-then-raw.out" "$vector_root" "$vector_identity" "$vector_root/stream-duplicate-then-raw"); then fail "serializer hidden duplicate before raw"; fi
  printf '\377\n' >"$vector_root/stream-nonutf8"
  serialize_tree stream "$vector_root/stream-nonutf8.out" "$vector_root" "$vector_identity" "$vector_root/stream-nonutf8"
  cmp "$vector_root/stream-nonutf8" "$vector_root/stream-nonutf8.out" >/dev/null || fail "serializer non-UTF8 stream"
  printf '\377\nNaN\n' >"$vector_root/stream-raw-then-nonfinite"
  if (serialize_tree stream "$vector_root/stream-raw-then-nonfinite.out" "$vector_root" "$vector_identity" "$vector_root/stream-raw-then-nonfinite"); then fail "serializer hidden nonfinite after non-UTF8"; fi
  printf 'NaN\n\377\n' >"$vector_root/stream-nonfinite-then-raw"
  if (serialize_tree stream "$vector_root/stream-nonfinite-then-raw.out" "$vector_root" "$vector_identity" "$vector_root/stream-nonfinite-then-raw"); then fail "serializer hidden nonfinite before non-UTF8"; fi
  mkdir -p "$vector_root/duplicate-dir"
  printf '%s\n' '{"a":1,"a":2}' >"$vector_root/duplicate-dir/duplicate"
  if (serialize_tree stream "$vector_root/duplicate.out" "$vector_root" "$vector_identity" "$vector_root/duplicate-dir/duplicate"); then fail "serializer duplicate stream accepted"; fi
  if (serialize_tree normalized "$vector_root/duplicate.normalized" "$vector_root" "$vector_identity" D "$vector_root/duplicate-dir" D); then fail "serializer duplicate JSON file"; fi
  printf '%s\n' '1' >"$vector_root/stream-scalar"
  if (serialize_tree stream "$vector_root/stream-scalar.out" "$vector_root" "$vector_identity" "$vector_root/stream-scalar"); then fail "serializer scalar stream accepted"; fi
  printf '%s\n' '[1,2,3]' >"$vector_root/stream-array"
  if (serialize_tree stream "$vector_root/stream-array.out" "$vector_root" "$vector_identity" "$vector_root/stream-array"); then fail "serializer array stream accepted"; fi
  printf '%s\n%s\n' 'raw' '[1,2,3]' >"$vector_root/stream-raw-then-array"
  if (serialize_tree stream "$vector_root/stream-raw-then-array.out" "$vector_root" "$vector_identity" "$vector_root/stream-raw-then-array"); then fail "serializer hidden array after raw"; fi
  printf '%s\n%s\n' '[1,2,3]' 'raw' >"$vector_root/stream-array-then-raw"
  if (serialize_tree stream "$vector_root/stream-array-then-raw.out" "$vector_root" "$vector_identity" "$vector_root/stream-array-then-raw"); then fail "serializer hidden array before raw"; fi
  for nonfinite in NaN Infinity -Infinity; do
    printf '%s\n' "$nonfinite" >"$vector_root/stream-nonfinite-$nonfinite"
    if (serialize_tree stream "$vector_root/stream-nonfinite-$nonfinite.out" "$vector_root" "$vector_identity" "$vector_root/stream-nonfinite-$nonfinite"); then fail "serializer nonfinite stream accepted: $nonfinite"; fi
  done
  mkdir -p "$vector_root/surrogate-dir"
  printf '%s\n' '{"x":"\ud800"}' >"$vector_root/surrogate-dir/stream-surrogate"
  if (serialize_tree stream "$vector_root/stream-surrogate.out" "$vector_root" "$vector_identity" "$vector_root/surrogate-dir/stream-surrogate"); then fail "serializer surrogate stream accepted"; fi
  if (serialize_tree normalized "$vector_root/stream-surrogate.normalized" "$vector_root" "$vector_identity" D "$vector_root/surrogate-dir" D); then fail "serializer surrogate JSON file"; fi
  if (serialize_tree normalized "$vector_root/no-token" "$vector_root" - D "$vector_root" D); then fail "serializer omitted identity token set"; fi
  printf '%s\n' '{"namespace_id":["namespace-token"],"cmdline_sha256":["cmdline-token"],"boot_id":["boot-token"],"hostname":["host-token"],"pid":["1234"],"start_ticks":["5678"]}' >"$vector_root/identity-tokens.json"
  printf '%s\n' 'namespace-token safe' >"$vector_root/identity-nonjson"
  if (serialize_tree stream "$vector_root/identity-nonjson.out" "$vector_root" "$vector_root/identity-tokens.json" "$vector_root/identity-nonjson"); then fail "serializer identity token nonjson"; fi
  printf '%s\n' 'safe 1234 safe' >"$vector_root/identity-pid-match"
  if (serialize_tree stream "$vector_root/identity-pid-match.out" "$vector_root" "$vector_root/identity-tokens.json" "$vector_root/identity-pid-match"); then fail "serializer delimited PID token"; fi
  for identity_nonmatch in 'safe91234x' 'x12349'; do
    identity_nonmatch_name=$(printf '%s' "$identity_nonmatch" | tr -cd '[:alnum:]')
    printf '%s\n' "$identity_nonmatch" >"$vector_root/$identity_nonmatch_name"
    serialize_tree stream "$vector_root/$identity_nonmatch_name.out" "$vector_root" "$vector_root/identity-tokens.json" "$vector_root/$identity_nonmatch_name"
    cmp "$vector_root/$identity_nonmatch_name" "$vector_root/$identity_nonmatch_name.out" >/dev/null || fail "serializer nonmatching PID token"
  done
  printf '%s' 'raw-without-final-lf' >"$vector_root/stream-no-final-lf"
  if (serialize_tree stream "$vector_root/stream-no-final-lf.out" "$vector_root" "$vector_identity" "$vector_root/stream-no-final-lf"); then fail "serializer stream missing LF"; fi
  mkdir -p "$vector_root/identity-key-dir"
  printf '%s\n' '{"namespace-token":1}' >"$vector_root/identity-key-dir/identity-key.json"
  if (serialize_tree normalized "$vector_root/identity-key.out" "$vector_root" "$vector_root/identity-tokens.json" D "$vector_root/identity-key-dir" D); then fail "serializer identity token JSON key"; fi
  if (serialize_tree stream "$vector_root/no-token-stream" "$vector_root" - "$vector_root/stream-scalar"); then fail "serializer omitted stream token set"; fi
  FM_EVIDENCE_IDENTITY_FILE="$vector_root/identity-tokens.json" serialize_tree stream "$vector_root/env-ignored.out" "$vector_root" "$vector_identity" "$vector_root/identity-nonjson"
  cmp "$vector_root/identity-nonjson" "$vector_root/env-ignored.out" >/dev/null || fail "serializer inherited identity environment"
  printf '%s\n' '{"namespace_id":[],"namespace_id":[],"cmdline_sha256":[],"boot_id":[],"hostname":[],"pid":[],"start_ticks":[]}' >"$vector_root/identity-duplicate.json"
  if (serialize_tree stream "$vector_root/identity-duplicate.out" "$vector_root" "$vector_root/identity-duplicate.json" "$vector_root/stream-scalar"); then fail "serializer duplicate token file"; fi
  printf '%s\n' '{"namespace_id":[],"cmdline_sha256":[],"boot_id":[],"hostname":[],"pid":[NaN],"start_ticks":[]}' >"$vector_root/identity-nonfinite.json"
  if (serialize_tree stream "$vector_root/identity-nonfinite.out" "$vector_root" "$vector_root/identity-nonfinite.json" "$vector_root/stream-scalar"); then fail "serializer nonfinite token file"; fi
  cat "$vector_identity" >"$vector_root/identity-prefix-trailer.json"
  printf '%s' trailer >>"$vector_root/identity-prefix-trailer.json"
  if (serialize_tree stream "$vector_root/identity-prefix-trailer.out" "$vector_root" "$vector_root/identity-prefix-trailer.json" "$vector_root/stream-one"); then fail "serializer accepted identity trailer"; fi
  if (FM_SERIALIZER_IDENTITY_SHORT_READ=1 serialize_tree stream "$vector_root/identity-short-read.out" "$vector_root" "$vector_identity" "$vector_root/stream-one"); then fail "serializer accepted identity short read"; fi
  ln -s "$vector_identity" "$vector_root/identity-link.json"
  if (serialize_tree stream "$vector_root/identity-link.out" "$vector_root" "$vector_root/identity-link.json" "$vector_root/stream-scalar"); then fail "serializer symlink token file"; fi
  printf '%s\n' 'raw' >"$TMP_ROOT/outside-serializer-input"
  if (serialize_tree stream "$vector_root/outside-input.out" "$vector_root" "$vector_identity" "$TMP_ROOT/outside-serializer-input"); then fail "serializer outside input"; fi
  ln -s "$vector_root/stream-scalar" "$vector_root/input-link"
  if (serialize_tree stream "$vector_root/input-link.out" "$vector_root" "$vector_identity" "$vector_root/input-link"); then fail "serializer symlink final input"; fi
  mkdir -p "$vector_root/input-parent"
  ln -s "$vector_root" "$vector_root/input-parent/link-parent"
  if (serialize_tree stream "$vector_root/input-parent-link.out" "$vector_root" "$vector_identity" "$vector_root/input-parent/link-parent/stream-scalar"); then fail "serializer symlink intermediate input"; fi
  ln -s "$vector_root/a/data" "$vector_root/link-data"
  if (serialize_tree global "$vector_root/symlink-root" "$vector_root" - D "$vector_root/link-data" D/workgraphs/.leases/v1); then fail "serializer symlinked root"; fi
  if (serialize_tree global "$vector_root/escape-root" "$vector_root" - D "$vector_root/../escape" D/workgraphs/.leases/v1); then fail "serializer escaped root"; fi
  if (serialize_tree typo "$vector_root/typo" "$vector_root" - D "$vector_root/a/data" D/workgraphs/.leases/v1); then fail "serializer unknown mode"; fi
}
if [ "$MATRIX_CASE_MODE" -eq 0 ]; then
  serializer_vectors
  ok "focused serializer, union, mutation, and parser vectors"
fi

matrix_seed_manifest() {
  local root=$1 output=$2 rel size mode digest
  : >"$output"
  while IFS= read -r -d '' rel; do
    size=$(stat -c '%s' "$root/$rel") || fail "seed stat $rel"
    mode=$(stat -c '%a' "$root/$rel") || fail "seed mode $rel"
    digest=$(sha256sum "$root/$rel" | awk '{print $1}') || fail "seed digest $rel"
    printf '%s\t%s\t%s\t%s\n' "$rel" "$size" "$mode" "$digest" >>"$output"
  done < <(cd "$root" && find . -type f -printf '%P\0' | LC_ALL=C sort -z)
}

matrix_build_candidate_archive() {
  local output=$1 commit=$2 stage raw
  stage=$(mktemp -d "$TMP_ROOT/candidate-stage.XXXXXX") || fail "candidate staging root"
  raw="$stage/raw.tar"
  git -c tar.umask=0022 archive --format=tar --mtime='1970-01-01T00:00:00Z' --prefix=firstmate/ "$commit" >"$raw" || fail "candidate source archive"
  mkdir -p "$stage/tree"
  tar -xf "$raw" -C "$stage/tree" || fail "candidate source extraction"
  if [ "$MATRIX_CASE_MODE" -eq 1 ]; then
    local overlay
    for overlay in \
      bin/fm-workgraph-lease-lib.sh \
      bin/fm-workgraph.sh \
      docs/configuration.md \
      docs/scripts.md \
      docs/workgraph.md \
      schemas/workgraph/lease-cache-v1.json \
      schemas/workgraph/lease-command-result-v1.json \
      schemas/workgraph/lease-event-v1.json \
      schemas/workgraph/lease-namespace-v1.json \
      schemas/workgraph/lease-transaction-owner-v1.json \
      schemas/workgraph/lease-v1.json \
      tests/fm-workgraph-leases.test.sh; do
      [ -f "$ROOT/$overlay" ] || fail "candidate overlay missing: $overlay"
      mkdir -p "$stage/tree/firstmate/$(dirname "$overlay")"
      cp "$ROOT/$overlay" "$stage/tree/firstmate/$overlay"
    done
  fi
  python3 - "$stage/tree/firstmate" "$commit" <<'PY_CANDIDATE_MODES' || fail "candidate mode binding"
import os
import subprocess
import sys

root, commit = sys.argv[1:]
tree_bytes = subprocess.run(
    ["git", "ls-tree", "-r", "-z", commit],
    check=True,
    stdout=subprocess.PIPE,
).stdout
parents = {root}
for row in tree_bytes.split(b"\0"):
    if not row:
        continue
    meta, path = row.split(b"\t", 1)
    mode, kind, _ = meta.split()
    target = os.path.join(root, os.fsdecode(path))
    if mode == b"100644":
        os.chmod(target, 0o644, follow_symlinks=False)
    elif mode == b"100755":
        os.chmod(target, 0o755, follow_symlinks=False)
    elif mode == b"120000":
        if not os.path.islink(target):
            raise SystemExit("candidate symlink mode")
    else:
        raise SystemExit("candidate unsupported tree mode")
    parent = os.path.dirname(target)
    while parent and parent not in parents:
        parents.add(parent)
        os.chmod(parent, 0o755, follow_symlinks=False)
        parent = os.path.dirname(parent)
os.chmod(root, 0o755, follow_symlinks=False)
PY_CANDIDATE_MODES
  tar --format=ustar --sort=name --mtime='1970-01-01T00:00:00Z' --owner=0 --group=0 --numeric-owner --create --file="$output" -C "$stage/tree" firstmate || fail "candidate deterministic archive"
}

matrix_prepare_candidate() {
  local commit tree archive_digest second_digest
  if [ "$MATRIX_CASE_MODE" -eq 0 ] && [ -n "$(git status --porcelain --untracked-files=all)" ]; then
    fail "matrix candidate requires a clean committed worktree"
  fi
  commit=$(git rev-parse --verify 'HEAD^{commit}') || fail "candidate commit"
  tree=$(git rev-parse --verify "$commit^{tree}") || fail "candidate tree"
  MATRIX_CANDIDATE_ARCHIVE="$TMP_ROOT/candidate.tar"
  MATRIX_CANDIDATE_ARCHIVE_SECOND="$TMP_ROOT/candidate.second.tar"
  MATRIX_CANDIDATE_INPUT="$TMP_ROOT/candidate-input.json"
  matrix_build_candidate_archive "$MATRIX_CANDIDATE_ARCHIVE" "$commit"
  matrix_build_candidate_archive "$MATRIX_CANDIDATE_ARCHIVE_SECOND" "$commit"
  archive_digest=$(sha256sum "$MATRIX_CANDIDATE_ARCHIVE" | awk '{print $1}') || fail "candidate archive digest"
  second_digest=$(sha256sum "$MATRIX_CANDIDATE_ARCHIVE_SECOND" | awk '{print $1}') || fail "candidate archive repeat digest"
  [ "$archive_digest" = "$second_digest" ] || fail "candidate archive nondeterministic"
  MATRIX_CANDIDATE_COMMIT="$commit"
  MATRIX_CANDIDATE_TREE="$tree"
  MATRIX_CANDIDATE_ARCHIVE_DIGEST="$archive_digest"
  printf '%s\n' "{\"schema_version\":\"lease-candidate-input/v1\",\"commit_sha\":\"$commit\",\"tree_sha\":\"$tree\",\"archive_sha256\":\"$archive_digest\"}" >"$MATRIX_CANDIDATE_INPUT"
  [ "$(sha256sum "$MATRIX_CANDIDATE_ARCHIVE" | awk '{print $1}')" = "$archive_digest" ] || fail "candidate archive binding"
  if [ "$MATRIX_CASE_MODE" -eq 0 ]; then
    matrix_validate_candidate_archive "$MATRIX_CANDIDATE_ARCHIVE" "$commit"
    matrix_validate_candidate_archive "$MATRIX_CANDIDATE_ARCHIVE_SECOND" "$commit"
  fi

  MATRIX_SEED_ROOT="$TMP_ROOT/seed"
  MATRIX_SEED_MANIFEST="$TMP_ROOT/seed-manifest.tsv"
  mkdir -p "$MATRIX_SEED_ROOT"
  cp "$TMP_ROOT/inputs/contract.json" "$MATRIX_SEED_ROOT/contract.json"
  cp "$TMP_ROOT/inputs/registry.json" "$MATRIX_SEED_ROOT/registry.json"
  matrix_seed_manifest "$MATRIX_SEED_ROOT" "$MATRIX_SEED_MANIFEST"
  [ -s "$MATRIX_SEED_MANIFEST" ] || fail "empty seed manifest"
}

matrix_validate_candidate_archive() {
  local archive=$1 commit=$2
  python3 - "$archive" "$commit" <<'PY_CANDIDATE_ARCHIVE' || fail "candidate archive validation"
import os
import subprocess
import sys
import tarfile

archive, commit = sys.argv[1:]
tree_bytes = subprocess.run(
    ["git", "ls-tree", "-r", "-z", commit],
    check=True,
    stdout=subprocess.PIPE,
).stdout
expected = {}
for row in tree_bytes.split(b"\0"):
    if not row:
        continue
    meta, path = row.split(b"\t", 1)
    mode, kind, object_id = meta.split()
    expected[path] = (mode, kind, object_id)
    if kind != b"blob" or mode not in (b"100644", b"100755", b"120000"):
        raise SystemExit("candidate unsupported tree entry")

def blob(path):
    return subprocess.run(["git", "show", f"{commit}:{os.fsdecode(path)}"], check=True, stdout=subprocess.PIPE).stdout

with tarfile.open(archive, "r:") as stream:
    members = stream.getmembers()
    names = [os.fsencode(member.name) for member in members]
    if names != sorted(names):
        raise SystemExit("candidate archive path order")
    seen = set()
    files = {}
    directories = set()
    for member, name in zip(members, names):
        if name == b"firstmate":
            relative = b""
        elif name.startswith(b"firstmate/"):
            relative = name[len(b"firstmate/"):]
        else:
            raise SystemExit("candidate archive prefix")
        if name.startswith(b"/"):
            raise SystemExit("candidate archive absolute path")
        parts = relative.split(b"/")
        if b".." in parts or relative.startswith(b"/") or relative.startswith(b"firstmate/"):
            raise SystemExit("candidate archive path")
        if name in seen:
            raise SystemExit("candidate archive duplicate")
        seen.add(name)
        if member.uid != 0 or member.gid != 0 or member.mtime != 0:
            raise SystemExit("candidate archive metadata")
        if member.isdir():
            if (member.mode & 0o777) != 0o755:
                raise SystemExit("candidate archive directory mode")
            directories.add(name.rstrip(b"/") + b"/")
        elif member.isfile() or member.issym():
            files[relative] = member
        else:
            raise SystemExit("candidate archive type")
    expected_dirs = {b""}
    for path in expected:
        parent = path
        while b"/" in parent:
            parent = parent.rsplit(b"/", 1)[0]
            expected_dirs.add(parent)
    expected_directory_names = {b"firstmate/"}
    for directory in expected_dirs:
        if directory:
            expected_directory_names.add(b"firstmate/" + directory + b"/")
    if directories != expected_directory_names:
        raise SystemExit("candidate archive directory set")
    if set(files) != set(expected):
        raise SystemExit("candidate archive tree set")
    for path, (mode, kind, _) in expected.items():
        member = files[path]
        value = blob(path)
        if mode == b"120000":
            if not member.issym() or (member.mode & 0o777) != 0o777 or os.fsencode(member.linkname) != value:
                raise SystemExit("candidate archive symlink content")
        elif mode in (b"100644", b"100755"):
            expected_mode = 0o644 if mode == b"100644" else 0o755
            if not member.isfile() or (member.mode & 0o777) != expected_mode or stream.extractfile(member).read() != value:
                raise SystemExit("candidate archive file content")
        else:
            raise SystemExit("candidate unsupported tree mode")
PY_CANDIDATE_ARCHIVE
}

matrix_extract_candidate() {
  local rerun_root=$1 candidate_input_copy=$2 seed_copy
  local candidate_input_canonical="$rerun_root/candidate-input.canonical.json"
  python3 - "$MATRIX_CANDIDATE_INPUT" "$candidate_input_canonical" "$MATRIX_CANDIDATE_COMMIT" "$MATRIX_CANDIDATE_TREE" "$MATRIX_CANDIDATE_ARCHIVE_DIGEST" <<'PY_CANDIDATE_INPUT' || fail "candidate input binding"
import json
import re
import sys

source, canonical_path, expected_commit, expected_tree, expected_archive = sys.argv[1:]
class DuplicateKey(ValueError):
    pass
def pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            raise DuplicateKey(key)
        result[key] = value
    return result
def reject_constant(_):
    raise ValueError("nonfinite")
try:
    payload = open(source, "rb").read()
    if payload.count(b"\n") != 1 or not payload.endswith(b"\n"):
        raise ValueError("candidate framing")
    value = json.loads(payload[:-1].decode("utf-8"), object_pairs_hook=pairs, parse_constant=reject_constant)
    if not isinstance(value, dict) or list(value) != ["schema_version", "commit_sha", "tree_sha", "archive_sha256"]:
        raise ValueError("candidate keys")
    if value != {
        "schema_version": "lease-candidate-input/v1",
        "commit_sha": expected_commit,
        "tree_sha": expected_tree,
        "archive_sha256": expected_archive,
    }:
        raise ValueError("candidate identity")
    if not re.fullmatch(r"[0-9a-f]{40}", value["commit_sha"]):
        raise ValueError("candidate commit")
    if not re.fullmatch(r"[0-9a-f]{40}", value["tree_sha"]):
        raise ValueError("candidate tree")
    if not re.fullmatch(r"[0-9a-f]{64}", value["archive_sha256"]):
        raise ValueError("candidate archive")
    canonical = (json.dumps(value, ensure_ascii=True, separators=(",", ":"), sort_keys=False) + "\n").encode("ascii")
    open(canonical_path, "wb").write(canonical)
except DuplicateKey:
    raise SystemExit("candidate duplicate")
except UnicodeDecodeError:
    raise SystemExit("candidate encoding")
except json.JSONDecodeError:
    raise SystemExit("candidate json")
except ValueError as error:
    raise SystemExit(str(error))
PY_CANDIDATE_INPUT
  cmp "$candidate_input_canonical" "$MATRIX_CANDIDATE_INPUT" >/dev/null || fail "candidate input canonical bytes"
  [ "$(sha256sum "$MATRIX_CANDIDATE_ARCHIVE" | awk '{print $1}')" = "$MATRIX_CANDIDATE_ARCHIVE_DIGEST" ] || fail "candidate archive rerun binding"
  mkdir -p "$rerun_root/oracle/s5"
  tar -xf "$MATRIX_CANDIDATE_ARCHIVE" -C "$rerun_root/oracle/s5" || fail "candidate extraction"
  CANDIDATE_ROOT="$rerun_root/oracle/s5/firstmate"
  [ -f "$CANDIDATE_ROOT/bin/fm-workgraph.sh" ] && [ -f "$CANDIDATE_ROOT/bin/fm-workgraph-lease-lib.sh" ] || fail "candidate root shape"
  [ "$(realpath -e "$CANDIDATE_ROOT")" = "$rerun_root/oracle/s5/firstmate" ] || fail "candidate root binding"
  tar --format=ustar --sort=name --mtime='1970-01-01T00:00:00Z' --owner=0 --group=0 --numeric-owner --create --file="$rerun_root/extracted.tar" -C "$rerun_root/oracle/s5" firstmate || fail "candidate extracted tree archive"
  cmp "$rerun_root/extracted.tar" "$MATRIX_CANDIDATE_ARCHIVE" >/dev/null || fail "candidate extracted tree binding"
  cp "$MATRIX_CANDIDATE_INPUT" "$candidate_input_copy"
  cmp "$candidate_input_copy" "$MATRIX_CANDIDATE_INPUT" >/dev/null || fail "candidate input rerun binding"
  seed_copy="$rerun_root/seed"
  mkdir -p "$seed_copy"
  cp "$MATRIX_SEED_ROOT/contract.json" "$seed_copy/contract.json"
  cp "$MATRIX_SEED_ROOT/registry.json" "$seed_copy/registry.json"
  matrix_seed_manifest "$seed_copy" "$rerun_root/seed-manifest.tsv"
  cmp "$MATRIX_SEED_MANIFEST" "$rerun_root/seed-manifest.tsv" >/dev/null || fail "seed manifest rerun binding"
  MATRIX_SEED_RERUN_ROOT="$seed_copy"
}

matrix_candidate_binding_vectors() {
  local vector_root="$TMP_ROOT/candidate-binding-vectors"
  local commit tree archive_digest archive_case input_case rerun
  mkdir -p "$vector_root/archive" "$vector_root/input"
  commit=$(git rev-parse --verify 'HEAD^{commit}') || fail "candidate vector commit"
  tree=$(git rev-parse --verify "$commit^{tree}") || fail "candidate vector tree"
  MATRIX_CANDIDATE_ARCHIVE="$vector_root/valid.tar"
  MATRIX_CANDIDATE_INPUT="$vector_root/valid-input.json"
  MATRIX_CANDIDATE_COMMIT="$commit"
  MATRIX_CANDIDATE_TREE="$tree"
  matrix_build_candidate_archive "$MATRIX_CANDIDATE_ARCHIVE" "$commit"
  archive_digest=$(sha256sum "$MATRIX_CANDIDATE_ARCHIVE" | awk '{print $1}') || fail "candidate vector archive digest"
  MATRIX_CANDIDATE_ARCHIVE_DIGEST="$archive_digest"
  printf '%s\n' "{\"schema_version\":\"lease-candidate-input/v1\",\"commit_sha\":\"$commit\",\"tree_sha\":\"$tree\",\"archive_sha256\":\"$archive_digest\"}" >"$MATRIX_CANDIDATE_INPUT"
  matrix_validate_candidate_archive "$MATRIX_CANDIDATE_ARCHIVE" "$commit"
  python3 - "$MATRIX_CANDIDATE_ARCHIVE" "$vector_root/archive" <<'PY_CANDIDATE_NEGATIVE_ARCHIVES' || fail "candidate archive negative fixture"
import copy
import io
import os
import tarfile
import sys

source, destination = sys.argv[1:]
with tarfile.open(source, "r:") as stream:
    originals = []
    for member in stream.getmembers():
        payload = stream.extractfile(member).read() if member.isfile() else None
        originals.append((member, payload))

def clone_entries():
    return [(copy.copy(member), payload) for member, payload in originals]

def write(name, entries, ordered=True):
    if ordered:
        entries = sorted(entries, key=lambda entry: os.fsencode(entry[0].name))
    with tarfile.open(os.path.join(destination, name + ".tar"), "w", format=tarfile.USTAR_FORMAT) as stream:
        for member, payload in entries:
            stream.addfile(member, io.BytesIO(payload) if payload is not None else None)

root_index = next(index for index, (member, _) in enumerate(originals) if member.name in ("firstmate", "firstmate/"))
regular_index = next(index for index, (member, _) in enumerate(originals) if member.isfile())
symlink_index = next(index for index, (member, _) in enumerate(originals) if member.issym())

write("root-missing", [entry for index, entry in enumerate(clone_entries()) if index != root_index])
entries = clone_entries()
entries[root_index][0].type = tarfile.REGTYPE
entries[root_index][0].size = 0
write("root-nondir", entries)
entries = clone_entries()
extra = tarfile.TarInfo("firstmate/.git")
extra.type = tarfile.DIRTYPE
extra.mode = 0o755
entries.append((extra, None))
write("extra-git-dir", entries)
entries = clone_entries()
extra = tarfile.TarInfo("firstmate/extra-file")
extra.type = tarfile.REGTYPE
extra.mode = 0o644
extra.size = 1
entries.append((extra, b"x"))
write("extra-file", entries)
write("missing-file", [entry for index, entry in enumerate(clone_entries()) if index != regular_index])
write("reordered", list(reversed(clone_entries())), ordered=False)
entries = clone_entries()
entries.insert(1, copy.copy(entries[0]))
write("duplicate-name", entries)
entries = clone_entries()
extra = tarfile.TarInfo("/absolute")
extra.type = tarfile.REGTYPE
extra.mode = 0o644
extra.size = 1
entries.append((extra, b"x"))
write("absolute-path", entries)
entries = clone_entries()
extra = tarfile.TarInfo("firstmate/../escape")
extra.type = tarfile.REGTYPE
extra.mode = 0o644
extra.size = 1
entries.append((extra, b"x"))
write("dotdot-path", entries)
for name, field, value in (("uid", "uid", 1), ("gid", "gid", 1), ("mtime", "mtime", 1)):
    entries = clone_entries()
    setattr(entries[root_index][0], field, value)
    write(name, entries)
entries = clone_entries()
entries[root_index][0].mode = 0o700
write("directory-mode", entries)
entries = clone_entries()
entries[regular_index][0].mode = 0o600
write("regular-mode", entries)
entries = clone_entries()
entries[symlink_index][0].mode = 0o600
write("symlink-mode", entries)
entries = clone_entries()
special = tarfile.TarInfo("firstmate/special")
special.type = tarfile.FIFOTYPE
special.mode = 0o644
entries.append((special, None))
write("special-type", entries)
entries = clone_entries()
entries[regular_index] = (entries[regular_index][0], b"changed")
entries[regular_index][0].size = len(b"changed")
write("file-bytes", entries)
entries = clone_entries()
entries[symlink_index][0].linkname = "changed-target"
write("symlink-target", entries)
PY_CANDIDATE_NEGATIVE_ARCHIVES
  for archive_case in root-missing root-nondir extra-git-dir extra-file missing-file reordered duplicate-name absolute-path dotdot-path uid gid mtime directory-mode regular-mode symlink-mode special-type file-bytes symlink-target; do
    case "$archive_case" in
      root-missing|root-nondir|extra-git-dir) archive_expected='candidate archive directory set' ;;
      extra-file|missing-file) archive_expected='candidate archive tree set' ;;
      reordered) archive_expected='candidate archive path order' ;;
      duplicate-name) archive_expected='candidate archive duplicate' ;;
      absolute-path) archive_expected='candidate archive prefix' ;;
      dotdot-path) archive_expected='candidate archive path' ;;
      uid|gid|mtime) archive_expected='candidate archive metadata' ;;
      directory-mode) archive_expected='candidate archive directory mode' ;;
      regular-mode|file-bytes) archive_expected='candidate archive file content' ;;
      symlink-mode|symlink-target) archive_expected='candidate archive symlink content' ;;
      special-type) archive_expected='candidate archive type' ;;
      *) fail "candidate archive negative manifest: $archive_case" ;;
    esac
    set +e
    (matrix_validate_candidate_archive "$vector_root/archive/$archive_case.tar" "$commit" >"$vector_root/archive/$archive_case.out" 2>"$vector_root/archive/$archive_case.err")
    archive_rc=$?
    set -e
    [ "$archive_rc" -ne 0 ] || fail "candidate archive negative accepted: $archive_case"
    printf '%s\n' "$archive_expected" 'not ok - candidate archive validation' >"$vector_root/archive/$archive_case.expected"
    cmp "$vector_root/archive/$archive_case.expected" "$vector_root/archive/$archive_case.err" >/dev/null || fail "candidate archive negative diagnostic: $archive_case"
    [ ! -s "$vector_root/archive/$archive_case.out" ] || fail "candidate archive negative stdout: $archive_case"
    [ ! -e "$vector_root/oracle" ] || fail "candidate archive negative extracted oracle: $archive_case"
    [ ! -e "$vector_root/summary.json" ] || fail "candidate archive negative wrote summary: $archive_case"
  done
  python3 - "$MATRIX_CANDIDATE_INPUT" "$vector_root/input" <<'PY_CANDIDATE_NEGATIVE_INPUTS' || fail "candidate input negative fixture"
import json
import sys

source, destination = sys.argv[1:]
value = json.loads(open(source, "rb").read())
def write(name, payload):
    with open(f"{destination}/{name}.json", "wb") as stream:
        stream.write(payload)
canonical = json.dumps(value, separators=(",", ":"), sort_keys=False).encode("ascii") + b"\n"
write("missing", json.dumps({key: item for key, item in value.items() if key != "tree_sha"}, separators=(",", ":"), sort_keys=False).encode("ascii") + b"\n")
extra = dict(value)
extra["extra"] = "x"
write("extra", json.dumps(extra, separators=(",", ":"), sort_keys=False).encode("ascii") + b"\n")
duplicate = b"{\"schema_version\":\"lease-candidate-input/v1\",\"commit_sha\":\"" + value["commit_sha"].encode("ascii") + b"\",\"tree_sha\":\"" + value["tree_sha"].encode("ascii") + b"\",\"tree_sha\":\"" + value["tree_sha"].encode("ascii") + b"\",\"archive_sha256\":\"" + value["archive_sha256"].encode("ascii") + b"\"}\n"
write("duplicate", duplicate)
write("truncated", canonical[:-2])
for key, short_name in (("commit_sha", "commit"), ("tree_sha", "tree"), ("archive_sha256", "archive")):
    mutated = dict(value)
    mutated[key] = "0" * len(value[key])
    write("false-" + short_name, json.dumps(mutated, separators=(",", ":"), sort_keys=False).encode("ascii") + b"\n")
PY_CANDIDATE_NEGATIVE_INPUTS
  MATRIX_CANDIDATE_ARCHIVE="$vector_root/valid.tar"
  MATRIX_CANDIDATE_ARCHIVE_DIGEST="$archive_digest"
  MATRIX_CANDIDATE_COMMIT="$commit"
  MATRIX_CANDIDATE_TREE="$tree"
  for input_case in missing extra duplicate truncated false-commit false-tree false-archive; do
    MATRIX_CANDIDATE_INPUT="$vector_root/input/$input_case.json"
    rerun="$vector_root/rerun-$input_case"
    mkdir -p "$rerun/evidence"
    MATRIX_SEED_ROOT="$vector_root/seed"
    MATRIX_SEED_MANIFEST="$vector_root/seed-manifest.tsv"
    mkdir -p "$MATRIX_SEED_ROOT"
    printf '%s\n' seed >"$MATRIX_SEED_ROOT/contract.json"
    printf '%s\n' registry >"$MATRIX_SEED_ROOT/registry.json"
    matrix_seed_manifest "$MATRIX_SEED_ROOT" "$MATRIX_SEED_MANIFEST"
    case "$input_case" in
      missing|extra) input_expected='candidate keys' ;;
      duplicate) input_expected='candidate duplicate' ;;
      truncated) input_expected='candidate framing' ;;
      false-commit|false-tree|false-archive) input_expected='candidate identity' ;;
      *) fail "candidate input negative manifest: $input_case" ;;
    esac
    set +e
    (matrix_extract_candidate "$rerun" "$rerun/evidence/candidate-input.json" >"$rerun/stdout" 2>"$rerun/stderr")
    input_rc=$?
    set -e
    [ "$input_rc" -ne 0 ] || fail "candidate input negative accepted: $input_case"
    printf '%s\n' "$input_expected" 'not ok - candidate input binding' >"$rerun/expected.stderr"
    cmp "$rerun/expected.stderr" "$rerun/stderr" >/dev/null || fail "candidate input negative diagnostic: $input_case"
    [ ! -s "$rerun/stdout" ] || fail "candidate input negative stdout: $input_case"
    [ ! -e "$rerun/oracle" ] || fail "candidate input negative extracted oracle: $input_case"
    [ ! -e "$rerun/evidence/summary.json" ] || fail "candidate input negative wrote summary: $input_case"
  done
  ok "candidate archive/input binding negatives fail before oracle extraction and summary"
}

if [ "$MATRIX_CASE_MODE" -eq 0 ]; then
  matrix_candidate_binding_vectors
fi
matrix_prepare_candidate
matrix_candidate_binding_guard() {
  local archive_digest second_digest input_digest
  archive_digest=$(sha256sum "$MATRIX_CANDIDATE_ARCHIVE" | awk '{print $1}') || fail "candidate archive guard digest"
  second_digest=$(sha256sum "$MATRIX_CANDIDATE_ARCHIVE_SECOND" | awk '{print $1}') || fail "candidate repeat guard digest"
  input_digest=$(sha256sum "$MATRIX_CANDIDATE_INPUT" | awk '{print $1}') || fail "candidate input guard digest"
  [ "$archive_digest" = "$MATRIX_CANDIDATE_ARCHIVE_DIGEST" ] || fail "candidate archive guard binding"
  [ "$second_digest" = "$MATRIX_CANDIDATE_ARCHIVE_DIGEST" ] || fail "candidate repeat guard binding"
  [ "$MATRIX_CANDIDATE_COMMIT" = "$(git rev-parse --verify 'HEAD^{commit}')" ] || fail "candidate commit guard binding"
  [ "$MATRIX_CANDIDATE_TREE" = "$(git rev-parse --verify 'HEAD^{tree}')" ] || fail "candidate tree guard binding"
  grep -Fq "\"archive_sha256\":\"$MATRIX_CANDIDATE_ARCHIVE_DIGEST\"}" "$MATRIX_CANDIDATE_INPUT" || fail "candidate input guard archive"
  [ -n "$input_digest" ] || fail "candidate input guard empty"
}
matrix_candidate_binding_guard

matrix_case_setup() {
  local home=$1 data=$2 state=$3 stdout=$4 stderr=$5
  shift 5
  FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_STATE_OVERRIDE="$state" "$@" >"$stdout" 2>"$stderr"
}
matrix_case_action() {
  local home=$1 data=$2 state=$3 stdout=$4 stderr=$5
  shift 5
  FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_STATE_OVERRIDE="$state" "$@" >"$stdout" 2>"$stderr"
}
matrix_case_assert() {
  local home=$1 data=$2 state=$3 stdout=$4 stderr=$5
  shift 5
  FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_STATE_OVERRIDE="$state" "$@" >"$stdout" 2>"$stderr"
}
run_matrix_case_body() {
  local id=$1 case_index=$2 matrix_pass=$3
  local case_root graph contract registry action_graph multi_contract
  local status_driver schema_driver reconstruction_driver schema_case schema_digest
  local case_before case_after case_before_normalized case_after_normalized evidence serializer_identity_sha
  local setup_stdout setup_stderr case_stdout case_stderr assert_stdout assert_stderr
  local setup_rc case_rc assert_rc

  case_root="$MATRIX_RERUN_ROOT/cases/$id"
  mkdir -p "$case_root/home" "$case_root/data" "$case_root/state"
  chmod 0755 "$case_root" "$case_root/home" "$case_root/data" "$case_root/state"
  HOME_ROOT="$case_root/home"
  DATA_ROOT="$case_root/data"
  STATE_ROOT="$case_root/state"
  setup_stdout="$case_root/setup.stdout"
  setup_stderr="$case_root/setup.stderr"
  case_stdout="$MATRIX_RERUN_ROOT/$id.stdout"
  case_stderr="$MATRIX_RERUN_ROOT/$id.stderr"
  : >"$setup_stdout"
  : >"$setup_stderr"
  : >"$case_stdout"
  : >"$case_stderr"

  cp "$MATRIX_SEED_RERUN_ROOT/contract.json" "$case_root/contract.json"
  contract=$(sha256sum "$case_root/contract.json" | awk '{print $1}')
  graph="$case_root/graph.json"
  registry="$case_root/registry.json"
  cp "$MATRIX_SEED_RERUN_ROOT/registry.json" "$registry"
  printf '%s\n' "{\"schema_version\":\"workgraph/v1\",\"goal_id\":\"g\",\"slices\":[{\"slice_id\":\"s\",\"contract_path\":\"contract.json\",\"contract_sha256\":\"$contract\"}]}" >"$graph"
  SERIALIZER_IDENTITY_FILE="$case_root/evidence-identity.json"

  case "$id" in
    S5V1-02)
      multi_contract="$case_root/contract2.json"
      jq '.slice_id="s2" | .worktree="/tmp/wt-s2"' "$case_root/contract.json" >"$multi_contract"
      multi_contract=$(sha256sum "$multi_contract" | awk '{print $1}')
      printf '%s\n' "{\"schema_version\":\"workgraph/v1\",\"goal_id\":\"g\",\"slices\":[{\"slice_id\":\"s\",\"contract_path\":\"contract.json\",\"contract_sha256\":\"$contract\"},{\"slice_id\":\"s2\",\"contract_path\":\"contract2.json\",\"contract_sha256\":\"$multi_contract\"}]}" >"$case_root/multi.json"
      cp "$graph" "$case_root/absence.json"
      cat >"$case_root/one.expected" <<EXPECTED_ONE
valid=true
schema_version=workgraph/v1
goal_id=g
slice_count=1
slice_id=s
contract_path=contract.json
contract_sha256=$contract
contract_verified=true
resource_lint=warn
resource_claim_count=1
resource_resolved_count=0
resource_warning_count=2
resource_warning_codes=WG-W-CLAIM-BROADENED,WG-W-RESOURCE-UNREGISTERED
claim[0].resolution=unregistered
claim[0].canonical_id_json="path:///tmp"
claim[0].effective_mode=exclusive
claim[0].effective_scope=global
resource_warning[0].code=WG-W-CLAIM-BROADENED
resource_warning[0].claim=0
resource_warning[1].code=WG-W-RESOURCE-UNREGISTERED
resource_warning[1].claim=0
enforcement=disabled
lease_store=absent
lease_cache=absent
lease_active_count=0
lease_terminal_count=0
lease_fencing=unavailable
lease_enforcement=unavailable
EXPECTED_ONE
      cat >"$case_root/multi.expected" <<EXPECTED_MULTI
valid=true
schema_version=workgraph/v1
goal_id=g
slice_count=2
slice[0].slice_id=s
slice[0].contract_path_json="contract.json"
slice[0].contract_sha256=$contract
slice[0].contract_verified=true
slice[1].slice_id=s2
slice[1].contract_path_json="contract2.json"
slice[1].contract_sha256=$multi_contract
slice[1].contract_verified=true
resource_lint=warn
resource_claim_count=2
resource_resolved_count=0
resource_warning_count=5
resource_warning_codes=WG-W-CLAIM-BROADENED,WG-W-RESOURCE-UNREGISTERED,WG-W-CLAIM-DUPLICATE
claim[0].resolution=unregistered
claim[0].canonical_id_json="path:///tmp"
claim[0].effective_mode=exclusive
claim[0].effective_scope=global
claim[1].resolution=unregistered
claim[1].canonical_id_json="path:///tmp"
claim[1].effective_mode=exclusive
claim[1].effective_scope=global
resource_warning[0].code=WG-W-CLAIM-BROADENED
resource_warning[0].claim=0
resource_warning[1].code=WG-W-RESOURCE-UNREGISTERED
resource_warning[1].claim=0
resource_warning[2].code=WG-W-CLAIM-BROADENED
resource_warning[2].claim=1
resource_warning[3].code=WG-W-CLAIM-DUPLICATE
resource_warning[3].claim=1
resource_warning[4].code=WG-W-RESOURCE-UNREGISTERED
resource_warning[4].claim=1
mode=on
wave_count=2
wave[0].slice_count=1
wave[0].slice[0]=s
wave[1].slice_count=1
wave[1].slice[0]=s2
compatibility_source=workgraph-claims
gates=enforcement-pending
enforcement=disabled
lease_store=absent
lease_cache=absent
lease_active_count=0
lease_terminal_count=0
lease_fencing=unavailable
lease_enforcement=unavailable
EXPECTED_MULTI
      status_driver="$case_root/status-driver.sh"
      cat >"$status_driver" <<'STATUS_DRIVER'
#!/usr/bin/env bash
set -u
candidate=$1 home=$2 data=$3 state=$4 one=$5 multi=$6 absence=$7 registry=$8 expected_one=$9 expected_multi=${10} evidence_root=${11}
run_status() {
  local label=$1 graph=$2 expected=$3 output error rc
  output="$evidence_root/$label.out"
  error="$evidence_root/$label.err"
  set +e
  FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_STATE_OVERRIDE="$state" "$candidate/bin/fm-workgraph.sh" status "$graph" --registry "$registry" >"$output" 2>"$error"
  rc=$?
  set -e
  if ! { [ "$rc" -eq 0 ] && [ ! -s "$error" ] && cmp "$output" "$expected" >/dev/null; }; then exit 1; fi
}
run_status one-node "$one" "$expected_one"
run_status multi-node "$multi" "$expected_multi"
run_status absent-authority "$absence" "$expected_one"
cat "$evidence_root/one-node.out" "$evidence_root/multi-node.out" "$evidence_root/absent-authority.out"
STATUS_DRIVER
      chmod 0700 "$status_driver"
      mkdir -p "$MATRIX_RERUN_ROOT/driver-evidence/$id"
      cat "$case_root/one.expected" "$case_root/multi.expected" "$case_root/one.expected" >"$case_root/status.expected"
      action_graph="$graph"
      ;;
    S5V1-03|S5V4-SIX-SCHEMAS)
      schema_driver="$case_root/schema-driver.sh"
      mkdir -p "$case_root/schema-fixtures" "$case_root/schema-submatrix"
      cat >"$case_root/schema-expected.tsv" <<'SCHEMA_EXPECTED'
lease-namespace-v1	f6e2d6c3ebd00394cabedcd04f44db0eb5da02e45ee7d54553ab74beacf0d125
lease-v1	67a459da8004de92d99b97f69e8e68c7b60a203c4abd36b18ec01fc3719ddd56
lease-event-v1	e7e33fee2536c7e8a4a10be3f35e65bede76dd3db5e5cd608954b45708d19ade
lease-transaction-owner-v1	15b0b2442dba654ed3862d01ae7164ad2206fbb8fbb045efeeeddf761138c66c
lease-command-result-v1	5e8dd5eb696db1d383d5cbc1a52a47552485a6ecff4870f27abed360dcb08fba
lease-cache-v1	5152c3e7cbda0cf40c4252fe29ec1241225156d1407568edf1759c900981ce7d
SCHEMA_EXPECTED
      while IFS=$'\t' read -r schema_name _schema_hash; do
        cp "$CANDIDATE_ROOT/schemas/workgraph/$schema_name.json" "$case_root/schema-fixtures/$schema_name.json"
      done <"$case_root/schema-expected.tsv"
      cp "$case_root/contract.json" "$case_root/schema-submatrix/contract.valid.json"
      cp "$registry" "$case_root/schema-submatrix/registry.valid.json"
      printf '%s\n' "{\"schema_version\":\"workgraph/v1\",\"goal_id\":\"g\",\"slices\":[{\"slice_id\":\"s\",\"contract_path\":\"contract.valid.json\",\"contract_sha256\":\"$contract\"}]}" >"$case_root/schema-submatrix/graph.valid.json"
      for schema_case in malformed duplicate extra bool-as-int negative capture-precedence schema-precedence; do
        mkdir -p "$case_root/schema-submatrix/$schema_case/home" "$case_root/schema-submatrix/$schema_case/data" "$case_root/schema-submatrix/$schema_case/state"
        cp "$case_root/schema-submatrix/contract.valid.json" "$case_root/schema-submatrix/$schema_case/contract.valid.json"
        cp "$case_root/schema-submatrix/registry.valid.json" "$case_root/schema-submatrix/$schema_case/registry.valid.json"
      done
      printf '%s' '{' >"$case_root/schema-submatrix/malformed/graph.json"
      printf '%s\n' '{"schema_version":"workgraph/v1","schema_version":"workgraph/v1","goal_id":"g","slices":[]}' >"$case_root/schema-submatrix/duplicate/graph.json"
      jq '.extra=1' "$case_root/schema-submatrix/graph.valid.json" >"$case_root/schema-submatrix/extra/graph.json"
      jq '.context_budget.source_tokens=true' "$case_root/schema-submatrix/contract.valid.json" >"$case_root/schema-submatrix/bool-as-int/contract.json"
      jq '.context_budget.source_tokens=-1' "$case_root/schema-submatrix/contract.valid.json" >"$case_root/schema-submatrix/negative/contract.json"
      for schema_case in bool-as-int negative; do
        schema_digest=$(sha256sum "$case_root/schema-submatrix/$schema_case/contract.json" | awk '{print $1}')
        printf '%s\n' "{\"schema_version\":\"workgraph/v1\",\"goal_id\":\"g\",\"slices\":[{\"slice_id\":\"s\",\"contract_path\":\"contract.json\",\"contract_sha256\":\"$schema_digest\"}]}" >"$case_root/schema-submatrix/$schema_case/graph.json"
      done
      cp "$case_root/schema-submatrix/graph.valid.json" "$case_root/schema-submatrix/capture-precedence/graph.json"
      rm "$case_root/schema-submatrix/capture-precedence/registry.valid.json"
      cp "$case_root/schema-submatrix/malformed/graph.json" "$case_root/schema-submatrix/schema-precedence/graph.json"
      for schema_case in malformed duplicate extra bool-as-int negative capture-precedence schema-precedence; do
        roots_manifest "$case_root/schema-submatrix/$schema_case/data" "$case_root/schema-submatrix/$schema_case/state" "$case_root/schema-submatrix/$schema_case.before"
      done
      cat >"$schema_driver" <<'SCHEMA_DRIVER'
#!/usr/bin/env bash
set -u
candidate=$1
root=$2
holder_pid=$3
evidence_root=$4
while IFS=$'\t' read -r schema_name schema_hash; do
  actual=$(sha256sum "$root/schema-fixtures/$schema_name.json" | awk '{print $1}')
  [ "$actual" = "$schema_hash" ] || exit 1
  printf '%s\t%s\n' "$schema_name" "$schema_hash"
done <"$root/schema-expected.tsv"
run_case() {
  local name=$1 graph=$2 registry=$3 expected_code=$4
  local data="$root/schema-submatrix/$name/data" state="$root/schema-submatrix/$name/state"
  local output error rc expected_line
  output="$evidence_root/$name.out"
  error="$evidence_root/$name.err"
  set +e
  FM_HOME="$root/schema-submatrix/$name/home" FM_DATA_OVERRIDE="$data" FM_STATE_OVERRIDE="$state" "$candidate/bin/fm-workgraph-lease-lib.sh" acquire "$graph" s --registry "$registry" --lease-id "schema-$name" --holder-id schema-holder --holder-pid "$holder_pid" >"$output" 2>"$error"
  rc=$?
  set -e
  expected_line="fm-workgraph: WG-L-E-$expected_code: lease operation failed"
  if ! { [ "$rc" -eq 1 ] && [ ! -s "$output" ] && grep -qx "$expected_line" "$error"; }; then exit 1; fi
  cat "$error" >&2
}
run_case malformed "$root/schema-submatrix/malformed/graph.json" "$root/schema-submatrix/registry.valid.json" SCHEMA
run_case duplicate "$root/schema-submatrix/duplicate/graph.json" "$root/schema-submatrix/registry.valid.json" SCHEMA
run_case extra "$root/schema-submatrix/extra/graph.json" "$root/schema-submatrix/registry.valid.json" SCHEMA
run_case bool-as-int "$root/schema-submatrix/bool-as-int/graph.json" "$root/schema-submatrix/bool-as-int/registry.valid.json" SCHEMA
run_case negative "$root/schema-submatrix/negative/graph.json" "$root/schema-submatrix/negative/registry.valid.json" SCHEMA
run_case capture-precedence "$root/schema-submatrix/capture-precedence/graph.json" "$root/schema-submatrix/capture-precedence/missing-registry.json" CAPTURE
run_case schema-precedence "$root/schema-submatrix/schema-precedence/graph.json" "$root/schema-submatrix/schema-precedence/registry.valid.json" SCHEMA
SCHEMA_DRIVER
      chmod 0700 "$schema_driver"
      mkdir -p "$MATRIX_RERUN_ROOT/driver-evidence/$id"
      cp "$case_root/schema-expected.tsv" "$case_root/schema-action.stdout"
      {
        for schema_case in malformed duplicate extra bool-as-int negative capture-precedence schema-precedence; do
          printf 'fm-workgraph: WG-L-E-%s: lease operation failed\n' "$(case "$schema_case" in capture-precedence) printf CAPTURE ;; *) printf SCHEMA ;; esac)"
        done
      } >"$case_root/schema-action.stderr"
      ;;
    S5V1-11)
      if matrix_case_setup "$HOME_ROOT" "$DATA_ROOT" "$STATE_ROOT" "$setup_stdout" "$setup_stderr" "$CANDIDATE_ROOT/bin/fm-workgraph-lease-lib.sh" acquire "$graph" s --registry "$registry" --lease-id x --holder-id h --holder-pid "$$"; then setup_rc=0; else setup_rc=$?; fi
      if ! { [ "$setup_rc" -eq 0 ] && [ ! -s "$setup_stderr" ]; }; then fail "$id setup seed"; fi
      rm -f "$STATE_ROOT/workgraphs/g/leases.v1.json"
      reconstruction_driver="$case_root/reconstruction-driver.sh"
      mkdir -p "$case_root/reconstruction-evidence"
      cat >"$reconstruction_driver" <<'RECONSTRUCTION_DRIVER'
#!/usr/bin/env bash
set -u
candidate=$1
home=$2
data=$3
state=$4
evidence_root=$5
status_expected=$6
graph=$7
registry=$8
record="$data/workgraphs/.leases/v1/records/g/x/1.json"
set +e
FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_STATE_OVERRIDE="$state" "$candidate/bin/fm-workgraph-lease-lib.sh" status g >"$evidence_root/status.out" 2>"$evidence_root/status.err"
status_rc=$?
FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_STATE_OVERRIDE="$state" "$candidate/bin/fm-workgraph-lease-lib.sh" inspect g --lease-id x >"$evidence_root/inspect.out" 2>"$evidence_root/inspect.err"
inspect_rc=$?
FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_STATE_OVERRIDE="$state" "$candidate/bin/fm-workgraph-lease-lib.sh" acquire "$graph" s --registry "$registry" --lease-id conflict --holder-id conflict-holder --holder-pid "$$" >"$evidence_root/conflict.out" 2>"$evidence_root/conflict.err"
conflict_rc=$?
set -e
if ! { [ "$status_rc" -eq 0 ] && [ "$inspect_rc" -eq 0 ] && [ "$conflict_rc" -eq 1 ] && [ ! -s "$evidence_root/status.err" ] && [ ! -s "$evidence_root/inspect.err" ] && [ ! -s "$evidence_root/conflict.out" ] && grep -qx 'fm-workgraph: WG-L-E-CONFLICT: lease operation failed' "$evidence_root/conflict.err" && cmp "$status_expected" "$evidence_root/status.out" >/dev/null && cmp "$record" "$evidence_root/inspect.out" >/dev/null; }; then exit 1; fi
jq -e '(.goal_id == "g" and .lease_id == "x" and .state == "held" and .holder_id == "h" and .holder_fencing_token == "1" and .current_fencing_token == "1")' "$evidence_root/inspect.out" >/dev/null || exit 1
cat "$evidence_root/inspect.out"
cat "$evidence_root/status.out" "$evidence_root/conflict.err" >&2
RECONSTRUCTION_DRIVER
      chmod 0700 "$reconstruction_driver"
      mkdir -p "$MATRIX_RERUN_ROOT/driver-evidence/$id"
      cat >"$case_root/reconstruction-status.expected" <<'RECONSTRUCTION_STATUS_EXPECTED'
lease_store=ready
lease_cache=reconstructed
lease_active_count=1
lease_terminal_count=0
lease_fencing=monotonic
lease_enforcement=available
RECONSTRUCTION_STATUS_EXPECTED
      cp "$DATA_ROOT/workgraphs/.leases/v1/records/g/x/1.json" "$case_root/reconstruction.expected"
      cat "$case_root/reconstruction-status.expected" >"$case_root/reconstruction.stderr.expected"
      printf '%s\n' 'fm-workgraph: WG-L-E-CONFLICT: lease operation failed' >>"$case_root/reconstruction.stderr.expected"
      ;;
    S5V1-04|S5V1-05|S5V3-BOOT-ID-BYTES|S5V3-UNSUPPORTED-IDENTITY|S5V4-COUNTER-FLOOR)
      action_graph="$graph"
      ;;
    S5V1-08|S5V1-09|S5V1-12|S5V3-ACQUIRE-DEAD-SPLIT|S5V3-ORPHAN-CACHE-STATUS|S5V3-READBACK-ONCE|S5V3-READBACK-BYTE-TYPE-METADATA-ERROR|S5V3-TERMINAL-RECOVER|S5V3-TERMINAL-RELEASE-FENCE|S5V3-RELEASE-DIFFERENT-PID|S5V3-EXACT-SUCCESS-BYTES|S5V3-INSPECT-HISTORY-ORDER|S5V3-STATUS-GOAL-SCOPE|S5V3-COUNTER-RECONSTRUCTION|S5V3-EVENT-RECORD-INVARIANTS)
      c3_matrix_setup "$id" "$CANDIDATE_ROOT" "$case_root" "$HOME_ROOT" "$DATA_ROOT" "$STATE_ROOT" "$graph" "$registry" "$MATRIX_RERUN_ROOT/driver-evidence/$id"
      action_graph="$graph"
      ;;
    S5V1-10|S5V1-13|S5V3-CRASH-EACH-PUBLICATION|S5V4-IMMUTABLE-REVISION-HISTORY|S5V4-PUBLICATION-SUB-BOUNDARIES|S5V4-TARGET-ONLY-REPAIR)
      c4_matrix_setup "$id" "$CANDIDATE_ROOT" "$case_root" "$HOME_ROOT" "$DATA_ROOT" "$STATE_ROOT" "$graph" "$registry" "$MATRIX_RERUN_ROOT/driver-evidence/$id"
      action_graph="$graph"
      ;;
    S5V1-01|S5V1-14|S5V1-15|S5V3-SLICE4-BYTE-ORACLE|S5V3-OUTPUT-MANIFEST|S5V4-CACHE-CANONICAL-BYTES|S5V4-EVIDENCE-SERIALIZATION|S5V4-ORACLE-ROOTS)
      c5_matrix_setup "$id" "$CANDIDATE_ROOT" "$case_root" "$HOME_ROOT" "$DATA_ROOT" "$STATE_ROOT" "$graph" "$registry" "$MATRIX_RERUN_ROOT/driver-evidence/$id"
      action_graph="$graph"
      ;;
    S5V3-TXN-BOOT|S5V3-TXN-NO-TIME|S5V3-TXN-LIVE-UNCERTAIN|S5V3-TXN-SUPERIOR-GENERATION|S5V4-GENERATION-ZERO|S5V4-FRESH-LOCK-OPEN|S5V4-TRANSACTION-CROSS-FILE|S5V1-06|S5V1-07)
      c2_matrix_setup "$id" "$CANDIDATE_ROOT" "$case_root" "$HOME_ROOT" "$DATA_ROOT" "$STATE_ROOT" "$graph" "$registry" "$MATRIX_RERUN_ROOT/driver-evidence/$id"
      action_graph="$graph"
      ;;
  esac

  write_identity_tokens "$case_root" "$case_root/data" "$case_root/state" "$SERIALIZER_IDENTITY_FILE" "$$"
  chmod 0444 "$SERIALIZER_IDENTITY_FILE"
  serializer_identity_sha=$(sha256sum "$SERIALIZER_IDENTITY_FILE" | awk '{print $1}')
  case_before="$MATRIX_RERUN_ROOT/matrix-${matrix_pass}-${id}.before"
  case_after="$MATRIX_RERUN_ROOT/matrix-${matrix_pass}-${id}.after"
  case_before_normalized="$MATRIX_RERUN_ROOT/matrix-${matrix_pass}-${id}.before.normalized"
  case_after_normalized="$MATRIX_RERUN_ROOT/matrix-${matrix_pass}-${id}.after.normalized"
  manifest_files "$case_root" "$case_before"
  normalized_manifest_files "$case_root" "$case_before_normalized"

  case "$id" in
    S5V1-02)
      if matrix_case_action "$HOME_ROOT" "$DATA_ROOT" "$STATE_ROOT" "$case_stdout" "$case_stderr" "$status_driver" "$CANDIDATE_ROOT" "$HOME_ROOT" "$DATA_ROOT" "$STATE_ROOT" "$graph" "$case_root/multi.json" "$case_root/absence.json" "$registry" "$case_root/one.expected" "$case_root/multi.expected" "$MATRIX_RERUN_ROOT/driver-evidence/$id"; then case_rc=0; else case_rc=$?; fi
      if ! { [ "$case_rc" -eq 0 ] && [ ! -s "$case_stderr" ] && cmp "$case_stdout" "$case_root/status.expected" >/dev/null; }; then fail "$id action"; fi
      assert_stdout="$case_root/assert.status-reopen.stdout"
      assert_stderr="$case_root/assert.status-reopen.stderr"
      if matrix_case_assert "$HOME_ROOT" "$DATA_ROOT" "$STATE_ROOT" "$assert_stdout" "$assert_stderr" "$CANDIDATE_ROOT/bin/fm-workgraph.sh" status "$action_graph" --registry "$registry"; then assert_rc=0; else assert_rc=$?; fi
      if ! { [ "$assert_rc" -eq 0 ] && [ ! -s "$assert_stderr" ] && cmp "$case_root/one.expected" "$assert_stdout" >/dev/null; }; then fail "$id readonly reopen"; fi
      ;;
    S5V1-03|S5V4-SIX-SCHEMAS)
      if matrix_case_action "$HOME_ROOT" "$DATA_ROOT" "$STATE_ROOT" "$case_stdout" "$case_stderr" "$schema_driver" "$CANDIDATE_ROOT" "$case_root" "$$" "$MATRIX_RERUN_ROOT/driver-evidence/$id"; then case_rc=0; else case_rc=$?; fi
      if ! { [ "$case_rc" -eq 0 ] && cmp "$case_stdout" "$case_root/schema-action.stdout" >/dev/null && cmp "$case_stderr" "$case_root/schema-action.stderr" >/dev/null; }; then fail "$id action"; fi
      for schema_case in malformed duplicate extra bool-as-int negative capture-precedence schema-precedence; do
        roots_manifest "$case_root/schema-submatrix/$schema_case/data" "$case_root/schema-submatrix/$schema_case/state" "$case_root/schema-submatrix/$schema_case.after"
        if ! cmp "$case_root/schema-submatrix/$schema_case.before" "$case_root/schema-submatrix/$schema_case.after" >/dev/null; then fail "$id zero mutation $schema_case"; fi
      done
      cat >"$case_root/schema-reopen.expected" <<'SCHEMA_REOPEN_EXPECTED'
lease_store=absent
lease_cache=absent
lease_active_count=0
lease_terminal_count=0
lease_fencing=unavailable
lease_enforcement=unavailable
SCHEMA_REOPEN_EXPECTED
      assert_stdout="$case_root/assert.status-reopen.stdout"
      assert_stderr="$case_root/assert.status-reopen.stderr"
      if matrix_case_assert "$HOME_ROOT" "$DATA_ROOT" "$STATE_ROOT" "$assert_stdout" "$assert_stderr" "$CANDIDATE_ROOT/bin/fm-workgraph-lease-lib.sh" status g; then assert_rc=0; else assert_rc=$?; fi
      if ! { [ "$assert_rc" -eq 0 ] && [ ! -s "$assert_stderr" ] && cmp "$case_root/schema-reopen.expected" "$assert_stdout" >/dev/null; }; then fail "$id readonly reopen"; fi
      ;;
    S5V1-11)
      if matrix_case_action "$HOME_ROOT" "$DATA_ROOT" "$STATE_ROOT" "$case_stdout" "$case_stderr" "$reconstruction_driver" "$CANDIDATE_ROOT" "$HOME_ROOT" "$DATA_ROOT" "$STATE_ROOT" "$MATRIX_RERUN_ROOT/driver-evidence/$id" "$case_root/reconstruction-status.expected" "$graph" "$registry"; then case_rc=0; else case_rc=$?; fi
      if ! { [ "$case_rc" -eq 0 ] && cmp "$case_stdout" "$case_root/reconstruction.expected" >/dev/null && cmp "$case_stderr" "$case_root/reconstruction.stderr.expected" >/dev/null; }; then fail "$id action"; fi
      assert_stdout="$case_root/assert.status-reopen.stdout"
      assert_stderr="$case_root/assert.status-reopen.stderr"
      if matrix_case_assert "$HOME_ROOT" "$DATA_ROOT" "$STATE_ROOT" "$assert_stdout" "$assert_stderr" "$CANDIDATE_ROOT/bin/fm-workgraph-lease-lib.sh" status g; then assert_rc=0; else assert_rc=$?; fi
      if ! { [ "$assert_rc" -eq 0 ] && [ ! -s "$assert_stderr" ] && cmp "$case_root/reconstruction-status.expected" "$assert_stdout" >/dev/null; }; then fail "$id readonly reopen"; fi
      ;;
    S5V1-04|S5V1-05|S5V3-BOOT-ID-BYTES|S5V3-UNSUPPORTED-IDENTITY|S5V4-COUNTER-FLOOR)
      if c6_matrix_action "$id" "$CANDIDATE_ROOT" "$case_root" "$MATRIX_RERUN_ROOT/driver-evidence/$id" >"$case_stdout" 2>"$case_stderr"; then case_rc=0; else case_rc=$?; fi
      if ! { [ "$case_rc" -eq 0 ] && [ ! -s "$case_stderr" ] && grep -qx "c6_case=$id" "$case_stdout"; }; then fail "$id action"; fi
      ;;
    S5V1-08|S5V1-09|S5V1-12|S5V3-ACQUIRE-DEAD-SPLIT|S5V3-ORPHAN-CACHE-STATUS|S5V3-READBACK-ONCE|S5V3-READBACK-BYTE-TYPE-METADATA-ERROR|S5V3-TERMINAL-RECOVER|S5V3-TERMINAL-RELEASE-FENCE|S5V3-RELEASE-DIFFERENT-PID|S5V3-EXACT-SUCCESS-BYTES|S5V3-INSPECT-HISTORY-ORDER|S5V3-STATUS-GOAL-SCOPE|S5V3-COUNTER-RECONSTRUCTION|S5V3-EVENT-RECORD-INVARIANTS)
      if c3_matrix_action "$id" >"$case_stdout" 2>"$case_stderr"; then case_rc=0; else case_rc=$?; fi
      if ! { [ "$case_rc" -eq 0 ] && [ ! -s "$case_stderr" ] && grep -qx "c3_case=$id" "$case_stdout"; }; then fail "$id action"; fi
      ;;
    S5V1-10|S5V1-13|S5V3-CRASH-EACH-PUBLICATION|S5V4-IMMUTABLE-REVISION-HISTORY|S5V4-PUBLICATION-SUB-BOUNDARIES|S5V4-TARGET-ONLY-REPAIR)
      if c4_matrix_action "$id" >"$case_stdout" 2>"$case_stderr"; then case_rc=0; else case_rc=$?; fi
      if ! { [ "$case_rc" -eq 0 ] && [ ! -s "$case_stderr" ] && grep -qx "c4_case=$id" "$case_stdout"; }; then fail "$id action"; fi
      ;;
    S5V1-01|S5V1-14|S5V1-15|S5V3-SLICE4-BYTE-ORACLE|S5V3-OUTPUT-MANIFEST|S5V4-CACHE-CANONICAL-BYTES|S5V4-EVIDENCE-SERIALIZATION|S5V4-ORACLE-ROOTS)
      if c5_matrix_action "$id" >"$case_stdout" 2>"$case_stderr"; then case_rc=0; else case_rc=$?; fi
      if ! { [ "$case_rc" -eq 0 ] && [ ! -s "$case_stderr" ] && grep -qx "c5_case=$id" "$case_stdout"; }; then fail "$id action"; fi
      ;;
    S5V3-TXN-BOOT|S5V3-TXN-NO-TIME|S5V3-TXN-LIVE-UNCERTAIN|S5V3-TXN-SUPERIOR-GENERATION|S5V4-GENERATION-ZERO|S5V4-FRESH-LOCK-OPEN|S5V4-TRANSACTION-CROSS-FILE|S5V1-06|S5V1-07)
      if c2_matrix_action "$id" "$CANDIDATE_ROOT" "$case_root" "$MATRIX_RERUN_ROOT/driver-evidence/$id" >"$case_stdout" 2>"$case_stderr"; then case_rc=0; else case_rc=$?; fi
      if ! { [ "$case_rc" -eq 0 ] && [ ! -s "$case_stderr" ] && grep -qx "c2_case=$id" "$case_stdout"; }; then fail "$id action"; fi
      ;;
  esac

  if ! { [ "$serializer_identity_sha" = "$(sha256sum "$SERIALIZER_IDENTITY_FILE" | awk '{print $1}')" ]; }; then fail "$id identity token file changed after action"; fi
  manifest_files "$case_root" "$case_after"
  case "$id" in
    S5V1-11)
      if ! cmp "$case_before" "$case_after" >/dev/null; then fail "$id conflict mutated authority"; fi
      ;;
  esac
  normalized_manifest_files "$case_root" "$case_after_normalized"
  evidence="$MATRIX_RERUN_ROOT/evidence/cases/$id"
  mkdir -p "$evidence"
  cp "$case_stdout" "$evidence/stdout.bin"
  cp "$case_stderr" "$evidence/stderr.bin"
  printf '%s\n' "$case_rc" >"$evidence/exit.txt"
  write_mutations "$case_before" "$case_after" "$evidence/mutations.txt"
  normalize_stream "$case_stdout" "$evidence/stdout.normalized.bin"
  normalize_stream "$case_stderr" "$evidence/stderr.normalized.bin"
  write_mutations "$case_before_normalized" "$case_after_normalized" "$evidence/mutations.normalized.txt"
  serialize_tree state "$evidence/authority.normalized.json" "$MATRIX_RERUN_ROOT" "$SERIALIZER_IDENTITY_FILE" D "$DATA_ROOT" D/workgraphs/.leases/v1 S "$STATE_ROOT" S/workgraphs/g
  serialize_tree rawhex "$evidence/authority.raw.hex" "$MATRIX_RERUN_ROOT" - D "$DATA_ROOT" D/workgraphs/.leases/v1
  serialize_tree rawhex "$evidence/cache.raw.hex" "$MATRIX_RERUN_ROOT" - S "$STATE_ROOT" S/workgraphs/g
  chmod 0600 "$evidence"/*
}
matrix_case_S5V4_SIX_SCHEMAS() { run_matrix_case_body S5V4-SIX-SCHEMAS "$1" "$2"; }

c6_matrix_action() {
  local c6_id=$1 c6_candidate=$2 c6_case_root=$3 c6_evidence=$4
  local c6_root c6_registry c6_rc c6_out c6_err c6_count=0
  mkdir -p "$c6_evidence"
  c6_manifest() {
    local data_root=$1 state_root=$2 output=$3
    python3 - "$data_root" "$state_root" "$output" <<'PY_C6_MANIFEST'
import hashlib
import os
import stat
import sys

data_root, state_root, output = sys.argv[1:]
rows = []
for label, root in (("D", data_root), ("S", state_root)):
    if not os.path.lexists(root):
        rows.append((label, "absent"))
        continue
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        directories.sort()
        files.sort()
        for name in directories + files:
            path = os.path.join(current, name)
            relative = os.path.relpath(path, root)
            item = os.lstat(path)
            prefix = f"{label}/{relative}"
            mode = stat.S_IMODE(item.st_mode)
            if stat.S_ISLNK(item.st_mode):
                value = os.readlink(path).encode("utf-8", "surrogateescape")
                rows.append((prefix, f"l:{mode:o}:{hashlib.sha256(value).hexdigest()}"))
            elif stat.S_ISREG(item.st_mode):
                with open(path, "rb") as stream:
                    value = stream.read()
                rows.append((prefix, f"f:{mode:o}:{hashlib.sha256(value).hexdigest()}"))
            elif stat.S_ISDIR(item.st_mode):
                rows.append((prefix, f"d:{mode:o}"))
            else:
                rows.append((prefix, f"o:{mode:o}"))
rows.sort()
with open(output, "w", encoding="ascii") as stream:
    for path, value in rows:
        stream.write(f"{path}\t{value}\n")
PY_C6_MANIFEST
  }
  c6_make() {
    local root=$1 slice=$2 resource=$3 mode=$4 registry=$5
    local digest
    mkdir -p "$root/home" "$root/data" "$root/state"
    printf '%s\n' "$registry" >"$root/C6-registry.json"
    jq --arg slice "$slice" --arg resource "$resource" --arg mode "$mode" \
      '.slice_id=$slice | .claims=[{"resource":$resource,"mode":$mode}]' \
      "$c6_case_root/contract.json" >"$root/C6-contract.json" || return 1
    digest=$(sha256sum "$root/C6-contract.json" | awk '{print $1}')
    printf '%s\n' "{\"schema_version\":\"workgraph/v1\",\"goal_id\":\"g\",\"slices\":[{\"slice_id\":\"$slice\",\"contract_path\":\"C6-contract.json\",\"contract_sha256\":\"$digest\"}]}" >"$root/C6-graph.json"
  }
  c6_acquire() {
    local root=$1 slice=$2 lease=$3
    c6_out="$root/C6-$lease.out"
    c6_err="$root/C6-$lease.err"
    if FM_HOME="$root/home" FM_DATA_OVERRIDE="$root/data" FM_STATE_OVERRIDE="$root/state" \
      "$c6_candidate/bin/fm-workgraph-lease-lib.sh" acquire "$root/C6-graph.json" "$slice" \
      --registry "$root/C6-registry.json" --lease-id "$lease" --holder-id "h-$lease" --holder-pid "$$" \
      >"$c6_out" 2>"$c6_err"; then c6_rc=0; else c6_rc=$?; fi
    c6_count=$((c6_count + 1))
  }
  c6_success() {
    local token=$1
    [ "$c6_rc" -eq 0 ] && [ ! -s "$c6_err" ] || return 1
    jq -e --arg token "$token" '.state=="held" and .holder_fencing_token==$token' "$c6_out" >/dev/null
  }
  c6_failure() {
    local code=$1
    [ "$c6_rc" -eq 1 ] && [ ! -s "$c6_out" ] || return 1
    grep -qx "fm-workgraph: WG-L-E-$code: lease operation failed" "$c6_err"
  }
  c6_unchanged() {
    local root=$1
    c6_manifest "$root/data" "$root/state" "$root/C6-after.tsv" || return 1
    cmp "$root/C6-before.tsv" "$root/C6-after.tsv" >/dev/null
  }
  c6_status_failure() {
    local root=$1 code=$2
    local output="$root/C6-status.out" error="$root/C6-status.err"
    if FM_HOME="$root/home" FM_DATA_OVERRIDE="$root/data" FM_STATE_OVERRIDE="$root/state" \
      "$c6_candidate/bin/fm-workgraph-lease-lib.sh" status g >"$output" 2>"$error"; then c6_rc=0; else c6_rc=$?; fi
    [ "$c6_rc" -eq 1 ] && [ ! -s "$output" ] || return 1
    grep -qx "fm-workgraph: WG-L-E-$code: lease operation failed" "$error"
  }

  case "$c6_id" in
    S5V1-04)
      c6_registry='{"schema_version":"resource-registry/v1","instances":[{"id":"c6-resource","namespace":"path","resource":"path:///tmp/c6-resource","aliases":["path:///tmp/c6-alias"],"contains":[]}]}'
      c6_root="$c6_case_root/C6-S5V1-04-read-read"
      c6_make "$c6_root" s path:///tmp/c6-resource read "$c6_registry" || return 1
      c6_acquire "$c6_root" s c6rr1; c6_success 1 || return 1
      c6_acquire "$c6_root" s c6rr2; c6_success 2 || return 1
      c6_root="$c6_case_root/C6-S5V1-04-read-write"
      c6_make "$c6_root" s path:///tmp/c6-resource read "$c6_registry" || return 1
      c6_acquire "$c6_root" s c6rw1; c6_success 1 || return 1
      c6_make "$c6_root" s path:///tmp/c6-resource exclusive "$c6_registry" || return 1
      c6_manifest "$c6_root/data" "$c6_root/state" "$c6_root/C6-before.tsv" || return 1
      c6_acquire "$c6_root" s c6rw2; c6_failure CONFLICT || return 1
      c6_unchanged "$c6_root" || return 1
      c6_root="$c6_case_root/C6-S5V1-04-alias"
      c6_make "$c6_root" s path:///tmp/c6-resource exclusive "$c6_registry" || return 1
      c6_acquire "$c6_root" s c6a1; c6_success 1 || return 1
      c6_make "$c6_root" s path:///tmp/c6-alias exclusive "$c6_registry" || return 1
      c6_manifest "$c6_root/data" "$c6_root/state" "$c6_root/C6-before.tsv" || return 1
      c6_acquire "$c6_root" s c6a2; c6_failure CONFLICT || return 1
      c6_unchanged "$c6_root" || return 1
      ;;
    S5V1-05)
      c6_registry='{"schema_version":"resource-registry/v1","instances":[{"id":"c6-parent","namespace":"path","resource":"path:///tmp/c6-parent","aliases":[],"contains":[]}]}'
      c6_root="$c6_case_root/C6-S5V1-05-unregistered"
      c6_make "$c6_root" s path:///tmp/c6-parent/child write "$c6_registry" || return 1
      c6_acquire "$c6_root" s c6u1; c6_success 1 || return 1
      jq -e '.resources[0].mode=="exclusive" and .resources[0].resource=="path:///tmp/c6-parent"' "$c6_root/data/workgraphs/.leases/v1/records/g/c6u1/1.json" >/dev/null || return 1
      c6_registry='{"schema_version":"resource-registry/v1","instances":[{"id":"c6-root-a","namespace":"path","resource":"path:///tmp/c6-ambiguous","aliases":[],"contains":[]},{"id":"c6-root-b","namespace":"path","resource":"path:///tmp/c6-ambiguous/child","aliases":[],"contains":[]}]}'
      c6_root="$c6_case_root/C6-S5V1-05-ambiguous"
      c6_make "$c6_root" s path:///tmp/c6-ambiguous/child/leaf write "$c6_registry" || return 1
      c6_acquire "$c6_root" s c6a1; c6_success 1 || return 1
      jq -e '.resources[0].mode=="exclusive" and .resources[0].lock_scopes==["global://all"]' "$c6_root/data/workgraphs/.leases/v1/records/g/c6a1/1.json" >/dev/null || return 1
      c6_registry='{"schema_version":"resource-registry/v1","instances":[]}'
      c6_root="$c6_case_root/C6-S5V1-05-no-container"
      c6_make "$c6_root" s path:///tmp/c6-no-container write "$c6_registry" || return 1
      c6_acquire "$c6_root" s c6n1; c6_success 1 || return 1
      jq -e '.resources[0].mode=="exclusive" and .resources[0].lock_scopes==["global://all"]' "$c6_root/data/workgraphs/.leases/v1/records/g/c6n1/1.json" >/dev/null || return 1
      c6_root="$c6_case_root/C6-S5V1-05-unknown"
      c6_make "$c6_root" s unknown://c6 write "$c6_registry" || return 1
      c6_manifest "$c6_root/data" "$c6_root/state" "$c6_root/C6-before.tsv" || return 1
      c6_acquire "$c6_root" s c6x1; c6_failure SELF || return 1; c6_unchanged "$c6_root" || return 1
      ;;
    S5V3-BOOT-ID-BYTES)
      c6_registry='{"schema_version":"resource-registry/v1","instances":[{"id":"c6-boot","namespace":"path","resource":"path:///tmp/c6-boot","aliases":[],"contains":[]}]}'
      c6_root="$c6_case_root/C6-S5V3-BOOT-ID-BYTES"
      c6_make "$c6_root" s path:///tmp/c6-boot exclusive "$c6_registry" || return 1
      c6_acquire "$c6_root" s c6boot; c6_success 1 || return 1
      python3 - "$c6_root/data/workgraphs/.leases/v1/records/g/c6boot/1.json" <<'PY_C6_BOOT'
import json
import sys

record = json.load(open(sys.argv[1], encoding="utf-8"))
raw = open("/proc/sys/kernel/random/boot_id", "rb").read()
if raw.endswith(b"\n"):
    raw = raw[:-1]
if len(raw) != 36 or record["holder_process"]["boot_id"].encode("ascii") != raw:
    raise SystemExit(1)
PY_C6_BOOT
      ;;
    S5V3-UNSUPPORTED-IDENTITY)
      c6_registry='{"schema_version":"resource-registry/v1","instances":[{"id":"c6-identity","namespace":"path","resource":"path:///tmp/c6-identity","aliases":[],"contains":[]}]}'
      c6_root="$c6_case_root/C6-S5V3-UNSUPPORTED-IDENTITY"
      c6_make "$c6_root" s path:///tmp/c6-identity exclusive "$c6_registry" || return 1
      c6_manifest "$c6_root/data" "$c6_root/state" "$c6_root/C6-before.tsv" || return 1
      if FM_HOME="$c6_root/home" FM_DATA_OVERRIDE="$c6_root/data" FM_STATE_OVERRIDE="$c6_root/state" \
        "$c6_candidate/bin/fm-workgraph-lease-lib.sh" acquire "$c6_root/C6-graph.json" s \
        --registry "$c6_root/C6-registry.json" --lease-id c6identity --holder-id h-c6identity --holder-pid 999999999 \
        >"$c6_root/C6-identity.out" 2>"$c6_root/C6-identity.err"; then c6_rc=0; else c6_rc=$?; fi
      [ "$c6_rc" -eq 1 ] && [ ! -s "$c6_root/C6-identity.out" ] || return 1
      grep -qx 'fm-workgraph: WG-L-E-IDENTITY: lease operation failed' "$c6_root/C6-identity.err" || return 1
      c6_unchanged "$c6_root" || return 1
      ;;
    S5V4-COUNTER-FLOOR)
      c6_registry='{"schema_version":"resource-registry/v1","instances":[{"id":"c6-counter","namespace":"path","resource":"path:///tmp/c6-counter","aliases":[],"contains":[]}]}'
      c6_root="$c6_case_root/C6-S5V4-COUNTER-FLOOR-high"
      c6_make "$c6_root" s path:///tmp/c6-counter read "$c6_registry" || return 1
      c6_acquire "$c6_root" s c6high1; c6_success 1 || return 1
      printf '%s\n' 5 >"$c6_root/data/workgraphs/.leases/v1/fencing-counter"; chmod 0600 "$c6_root/data/workgraphs/.leases/v1/fencing-counter"
      c6_acquire "$c6_root" s c6high2; c6_success 6 || return 1
      c6_root="$c6_case_root/C6-S5V4-COUNTER-FLOOR-authority"
      c6_make "$c6_root" s path:///tmp/c6-counter read "$c6_registry" || return 1
      c6_acquire "$c6_root" s c6auth1; c6_success 1 || return 1
      printf '%s\n' 0 >"$c6_root/data/workgraphs/.leases/v1/fencing-counter"; chmod 0600 "$c6_root/data/workgraphs/.leases/v1/fencing-counter"
      c6_acquire "$c6_root" s c6auth2; c6_success 2 || return 1
      c6_root="$c6_case_root/C6-S5V4-COUNTER-FLOOR-invalid"
      c6_make "$c6_root" s path:///tmp/c6-counter exclusive "$c6_registry" || return 1
      c6_acquire "$c6_root" s c6invalid1; c6_success 1 || return 1
      printf '%s\n' 9223372036854775808 >"$c6_root/data/workgraphs/.leases/v1/fencing-counter"; chmod 0600 "$c6_root/data/workgraphs/.leases/v1/fencing-counter"
      c6_manifest "$c6_root/data" "$c6_root/state" "$c6_root/C6-before.tsv" || return 1
      c6_acquire "$c6_root" s c6invalid2; c6_failure NOT-RECONSTRUCTABLE || return 1; c6_unchanged "$c6_root" || return 1
      c6_root="$c6_case_root/C6-S5V4-COUNTER-FLOOR-namespace"
      c6_make "$c6_root" s path:///tmp/c6-counter exclusive "$c6_registry" || return 1
      c6_acquire "$c6_root" s c6namespace; c6_success 1 || return 1
      jq '.counter_floor="1"' "$c6_root/data/workgraphs/.leases/v1/namespace.json" >"$c6_root/C6-namespace.tmp" || return 1
      mv "$c6_root/C6-namespace.tmp" "$c6_root/data/workgraphs/.leases/v1/namespace.json"; chmod 0600 "$c6_root/data/workgraphs/.leases/v1/namespace.json"
      c6_manifest "$c6_root/data" "$c6_root/state" "$c6_root/C6-before.tsv" || return 1
      c6_status_failure "$c6_root" NOT-RECONSTRUCTABLE || return 1; c6_unchanged "$c6_root" || return 1
      ;;
    *) return 1 ;;
  esac
  printf 'c6_case=%s\nc6_subcases=%s\n' "$c6_id" "$c6_count"
}

# C3 recovery/state cases are deliberately self-contained. They use one
# private authority root per matrix case and never share transaction state.
c3_setup() {
  local id=$1 candidate=$2 case_root=$3 home=$4 data=$5 state=$6 graph=$7 registry=$8 evidence=$9 namespace_id
  C3_ID="$id"; C3_CANDIDATE="$candidate"; C3_CASE_ROOT="$case_root"; C3_HOME="$home"; C3_DATA="$data"; C3_STATE="$state"; C3_GRAPH="$graph"; C3_REGISTRY="$registry"; C3_CONTRACT="$case_root/contract.json"; C3_STORE="$data/workgraphs/.leases/v1"; C3_DRIVER_EVIDENCE="$evidence"; C3_COMMAND_INDEX=0
  mkdir -p "$C3_DRIVER_EVIDENCE" "$C3_STORE/records" "$C3_STORE/events"; chmod 0700 "$C3_DRIVER_EVIDENCE" "$data/workgraphs" "$data/workgraphs/.leases" "$C3_STORE" "$C3_STORE/records" "$C3_STORE/events"
  namespace_id=$(printf 'firstmate-workgraph-lease-namespace/v1\n%s\n' "$data" | sha256sum | awk '{print $1}')
  printf '%s\n' "{\"schema_version\":\"lease-namespace/v1\",\"namespace_id\":\"$namespace_id\",\"goal_scope\":\"all-goals\",\"counter_floor\":\"0\"}" >"$C3_STORE/namespace.json"
  printf '0\n' >"$C3_STORE/fencing-counter"; printf '0\n' >"$C3_STORE/transaction-generation"; : >"$C3_STORE/.transaction-lock"; chmod 0600 "$C3_STORE/namespace.json" "$C3_STORE/fencing-counter" "$C3_STORE/transaction-generation" "$C3_STORE/.transaction-lock"
  : >"$C3_DRIVER_EVIDENCE/commands.txt"; : >"$C3_DRIVER_EVIDENCE/trace.txt"
}
c3_call() {
  local name=$1; shift; C3_COMMAND_INDEX=$((C3_COMMAND_INDEX + 1)); local stem; stem=$(printf '%03d-%s' "$C3_COMMAND_INDEX" "$name"); C3_OUT="$C3_DRIVER_EVIDENCE/$stem.stdout"; C3_ERR="$C3_DRIVER_EVIDENCE/$stem.stderr"
  set +e; FM_HOME="$C3_HOME" FM_DATA_OVERRIDE="$C3_DATA" FM_STATE_OVERRIDE="$C3_STATE" "$C3_CANDIDATE/bin/fm-workgraph-lease-lib.sh" "$@" >"$C3_OUT" 2>"$C3_ERR"; C3_RC=$?; set -e
  { printf 'command=%s rc=%s\nstdout:\n' "$name" "$C3_RC"; cat "$C3_OUT"; printf 'stderr:\n'; cat "$C3_ERR"; } >>"$C3_DRIVER_EVIDENCE/commands.txt"
}
c3_expect_code() { local code=$1; if ! { [ "$C3_RC" -eq 1 ] && [ ! -s "$C3_OUT" ] && grep -qx "fm-workgraph: WG-L-E-$code: lease operation failed" "$C3_ERR"; }; then fail "C3 expected $code"; fi; }
c3_same() { cmp "$1" "$2" >/dev/null || fail "C3 unexpected D/S mutation"; }
c3_manifest() { roots_manifest "$C3_DATA" "$C3_STATE" "$1"; }
c3_trace() { printf '%s\n' "$*" >>"$C3_DRIVER_EVIDENCE/trace.txt"; }
c3_seed_live() { local lease=$1 holder=$2; c3_call "$lease-live-acquire" acquire "$C3_GRAPH" s --registry "$C3_REGISTRY" --lease-id "$lease" --holder-id "$holder" --holder-pid "$$"; [ "$C3_RC" -eq 0 ] && [ ! -s "$C3_ERR" ] || fail "C3 live seed acquire $lease"; }
c3_seed_dead() {
  local lease=$1 holder=$2 output="$C3_DRIVER_EVIDENCE/$1-dead-seed.stdout" error="$C3_DRIVER_EVIDENCE/$1-dead-seed.stderr" rc
  set +e; FM_HOME="$C3_HOME" FM_DATA_OVERRIDE="$C3_DATA" FM_STATE_OVERRIDE="$C3_STATE" bash -c 'exec "$1" acquire "$2" s --registry "$3" --lease-id "$4" --holder-id "$5" --holder-pid "$$"' c3-dead-seed "$C3_CANDIDATE/bin/fm-workgraph-lease-lib.sh" "$C3_GRAPH" "$C3_REGISTRY" "$lease" "$holder" >"$output" 2>"$error"; rc=$?; set -e
  [ "$rc" -eq 0 ] && [ ! -s "$error" ] || fail "C3 dead seed acquire $lease"; printf 'dead_seed=%s rc=%s\n' "$lease" "$rc" >>"$C3_DRIVER_EVIDENCE/commands.txt"
}
c3_assert_event_bindings() { local event revision goal lease record digest; while IFS= read -r event; do revision=$(jq -r '.record_revision' "$event"); goal=$(jq -r '.goal_id' "$event"); lease=$(jq -r '.lease_id' "$event"); record="$C3_STORE/records/$goal/$lease/$revision.json"; [ -f "$record" ] || fail 'C3 event record missing'; digest=$(sha256sum "$record" | awk '{print $1}'); jq -e --arg digest "$digest" '.record_sha256==$digest' "$event" >/dev/null || fail 'C3 event digest binding'; done < <(find "$C3_STORE/events" -type f -name '*.json' | LC_ALL=C sort); }
c3_authority_digest() { local output=$1; find "$C3_STORE" -type f \( -name 'namespace.json' -o -name 'fencing-counter' -o -name 'transaction-generation' -o -name '*.json' \) -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum >"$output"; }
c3_make_read_graphs() { local digest digest_h; jq -c '.claims |= map(.mode="read")' "$C3_CONTRACT" >"$C3_CASE_ROOT/read-contract.tmp"; mv "$C3_CASE_ROOT/read-contract.tmp" "$C3_CONTRACT"; chmod 0600 "$C3_CONTRACT"; digest=$(sha256sum "$C3_CONTRACT" | awk '{print $1}'); printf '%s\n' "{\"schema_version\":\"workgraph/v1\",\"goal_id\":\"g\",\"slices\":[{\"slice_id\":\"s\",\"contract_path\":\"contract.json\",\"contract_sha256\":\"$digest\"}]}" >"$C3_GRAPH"; jq '.goal_id="h"' "$C3_CONTRACT" >"$C3_CASE_ROOT/contract-h.json"; digest_h=$(sha256sum "$C3_CASE_ROOT/contract-h.json" | awk '{print $1}'); printf '%s\n' "{\"schema_version\":\"workgraph/v1\",\"goal_id\":\"h\",\"slices\":[{\"slice_id\":\"s\",\"contract_path\":\"contract-h.json\",\"contract_sha256\":\"$digest_h\"}]}" >"$C3_CASE_ROOT/graph-h.json"; C3_GRAPH_H="$C3_CASE_ROOT/graph-h.json"; chmod 0600 "$C3_GRAPH" "$C3_GRAPH_H" "$C3_CASE_ROOT/contract-h.json"; }
c3_matrix_setup() {
  local id=$1 candidate=$2 case_root=$3 home=$4 data=$5 state=$6 graph=$7 registry=$8 evidence=$9
  if [ "$id" = S5V3-ORPHAN-CACHE-STATUS ]; then c3_setup_orphan "$@"; return; fi
  c3_setup "$id" "$candidate" "$case_root" "$home" "$data" "$state" "$graph" "$registry" "$evidence"
  case "$id" in
    S5V1-08) c3_seed_live seed holder; c3_call seed-release release g --lease-id seed --holder-id holder --fencing-token 1; [ "$C3_RC" -eq 0 ] || fail 'C3 S5V1-08 seed release'; c3_seed_dead dead-seed dead-holder ;;
    S5V1-09) c3_seed_live seed holder ;;
    S5V1-12) c3_seed_live seed holder; c3_call seed-release release g --lease-id seed --holder-id holder --fencing-token 1; [ "$C3_RC" -eq 0 ] || fail 'C3 S5V1-12 seed release' ;;
    S5V3-ACQUIRE-DEAD-SPLIT|S5V3-TERMINAL-RECOVER|S5V3-RELEASE-DIFFERENT-PID) c3_seed_dead seed holder ;;
    S5V3-READBACK-ONCE) c3_seed_live seed holder ;;
    S5V3-READBACK-BYTE-TYPE-METADATA-ERROR) c3_seed_live seed holder; cp "$C3_STORE/records/g/seed/1.json" "$case_root/record.backup.json"; chmod 0600 "$case_root/record.backup.json" ;;
    S5V3-TERMINAL-RELEASE-FENCE) c3_seed_live seed holder ;;
    S5V3-EXACT-SUCCESS-BYTES|S5V3-INSPECT-HISTORY-ORDER) : ;;
    S5V3-STATUS-GOAL-SCOPE) printf '%s\n' '{"schema_version":"resource-registry/v1","instances":[{"id":"c3-resource","namespace":"path","resource":"path:///tmp","aliases":[],"contains":[]}]}' >"$C3_REGISTRY"; chmod 0600 "$C3_REGISTRY"; c3_make_read_graphs ;;
    S5V3-COUNTER-RECONSTRUCTION) c3_seed_live seed holder; c3_call seed-release release g --lease-id seed --holder-id holder --fencing-token 1; [ "$C3_RC" -eq 0 ] || fail 'C3 counter seed release'; printf '0\n' >"$C3_STORE/fencing-counter"; chmod 0600 "$C3_STORE/fencing-counter" ;;
    S5V3-EVENT-RECORD-INVARIANTS) c3_seed_live seed holder; c3_call seed-release release g --lease-id seed --holder-id holder --fencing-token 1; [ "$C3_RC" -eq 0 ] || fail 'C3 event seed release' ;;
    *) fail "C3 setup id $id" ;;
  esac
}
c3_setup_orphan() {
  local id=$1 candidate=$2 case_root=$3 home=$4 data=$5 state=$6 graph=$7 registry=$8 evidence=$9
  C3_ID="$id"; C3_CANDIDATE="$candidate"; C3_CASE_ROOT="$case_root"; C3_HOME="$home"; C3_DATA="$data"; C3_STATE="$state"; C3_GRAPH="$graph"; C3_REGISTRY="$registry"; C3_DRIVER_EVIDENCE="$evidence"; C3_COMMAND_INDEX=0
  mkdir -p "$evidence" "$state/workgraphs/g"; chmod 0700 "$evidence"; printf '%s\n' orphan-cache >"$state/workgraphs/g/leases.v1.json"; chmod 0600 "$state/workgraphs/g/leases.v1.json"; : >"$evidence/commands.txt"; : >"$evidence/trace.txt"
}
c3_case_S5V1_08() { local before="$C3_DRIVER_EVIDENCE/before" after="$C3_DRIVER_EVIDENCE/after"; c3_manifest "$before"; c3_call dead-contender acquire "$C3_GRAPH" s --registry "$C3_REGISTRY" --lease-id contender --holder-id contender --holder-pid "$$"; c3_expect_code RECOVERY-REQUIRED; c3_manifest "$after"; c3_same "$before" "$after"; c3_trace 'released_seed=1 dead_holder=positive_death contender=RECOVERY-REQUIRED zero_mutation=1'; }
c3_case_S5V1_09() { local before="$C3_DRIVER_EVIDENCE/before" after="$C3_DRIVER_EVIDENCE/after"; c3_manifest "$before"; c3_call live-contender acquire "$C3_GRAPH" s --registry "$C3_REGISTRY" --lease-id contender --holder-id contender --holder-pid "$$"; c3_expect_code CONFLICT; c3_manifest "$after"; c3_same "$before" "$after"; c3_trace 'live_holder=CONFLICT zero_mutation=1'; }
c3_case_S5V1_12() { local before="$C3_DRIVER_EVIDENCE/before" after="$C3_DRIVER_EVIDENCE/after"; c3_manifest "$before"; c3_call reused acquire "$C3_GRAPH" s --registry "$C3_REGISTRY" --lease-id seed --holder-id second --holder-pid "$$"; c3_expect_code LEASE-ID-REUSED; c3_manifest "$after"; c3_same "$before" "$after"; c3_trace 'released_terminal=1 reused_id=LEASE-ID-REUSED zero_mutation=1'; }
c3_case_S5V3_ACQUIRE_DEAD_SPLIT() { local before="$C3_DRIVER_EVIDENCE/before" after="$C3_DRIVER_EVIDENCE/after"; c3_manifest "$before"; c3_call dead-contender acquire "$C3_GRAPH" s --registry "$C3_REGISTRY" --lease-id contender --holder-id contender --holder-pid "$$"; c3_expect_code RECOVERY-REQUIRED; c3_manifest "$after"; c3_same "$before" "$after"; c3_call explicit-recover recover g --lease-id seed --actor-id recovery-a; [ "$C3_RC" -eq 0 ] || fail 'C3 dead split recover'; c3_call post-recover-acquire acquire "$C3_GRAPH" s --registry "$C3_REGISTRY" --lease-id contender --holder-id contender --holder-pid "$$"; [ "$C3_RC" -eq 0 ] || fail 'C3 dead split acquire'; c3_trace 'dead_overlap=RECOVERY-REQUIRED explicit_recover=1 post_recover_acquire=1'; }
c3_case_S5V3_ORPHAN_CACHE_STATUS() { local expected="$C3_CASE_ROOT/status.expected" before="$C3_DRIVER_EVIDENCE/before" after="$C3_DRIVER_EVIDENCE/after"; printf '%s\n' 'lease_store=absent' 'lease_cache=present' 'lease_active_count=0' 'lease_terminal_count=0' 'lease_fencing=unavailable' 'lease_enforcement=unavailable' >"$expected"; c3_manifest "$before"; c3_call orphan-status status g; if ! { [ "$C3_RC" -eq 0 ] && [ ! -s "$C3_ERR" ] && cmp "$expected" "$C3_OUT" >/dev/null; }; then fail 'C3 orphan cache status'; fi; c3_manifest "$after"; c3_same "$before" "$after"; c3_trace 'durable=absent cache=present counts=0 zero_mutation=1'; }
c3_case_S5V3_READBACK_ONCE() { local record="$C3_STORE/records/g/seed/1.json" before="$C3_DRIVER_EVIDENCE/before" after="$C3_DRIVER_EVIDENCE/after"; c3_manifest "$before"; c3_call inspect-once inspect g --lease-id seed; [ "$C3_RC" -eq 0 ] && [ ! -s "$C3_ERR" ] && cmp "$record" "$C3_OUT" >/dev/null && [ "$(wc -l <"$C3_OUT")" -eq 1 ] || fail 'C3 readback canonical bytes'; c3_manifest "$after"; c3_same "$before" "$after"; c3_trace 'inspect_read=one_canonical_record readback=exact zero_mutation=1'; }
c3_case_S5V3_READBACK_BYTE_TYPE_METADATA_ERROR() {
  local record="$C3_STORE/records/g/seed/1.json" before after name
  for name in mode trailing-byte metadata; do
    cp "$C3_CASE_ROOT/record.backup.json" "$record"; chmod 0600 "$record"
    case "$name" in mode) chmod 0644 "$record" ;; trailing-byte) printf '\n' >>"$record" ;; metadata) jq '.holder_process.pid="0"' "$record" >"$C3_CASE_ROOT/record.tmp"; mv "$C3_CASE_ROOT/record.tmp" "$record"; chmod 0600 "$record" ;; esac
    before="$C3_DRIVER_EVIDENCE/$name.before"; after="$C3_DRIVER_EVIDENCE/$name.after"; c3_manifest "$before"; c3_call "$name-status" status g; c3_expect_code NOT-RECONSTRUCTABLE; c3_manifest "$after"; c3_same "$before" "$after"
  done
  cp "$C3_CASE_ROOT/record.backup.json" "$record"; chmod 0600 "$record"; c3_trace 'mode=NOT-RECONSTRUCTABLE trailing-byte=NOT-RECONSTRUCTABLE metadata=NOT-RECONSTRUCTABLE zero_runtime_mutation=1'
}
c3_case_S5V3_TERMINAL_RECOVER() {
  local record="$C3_STORE/records/g/seed/2.json" event="$C3_STORE/events/00000000000000000002.json" digest
  c3_call recover recover g --lease-id seed --actor-id recovery-a; [ "$C3_RC" -eq 0 ] && [ ! -s "$C3_ERR" ] || fail 'C3 recover success'
  jq -e '.state=="recovered" and .revision=="2" and .terminal.kind=="recover" and .terminal.actor_id=="recovery-a" and (.terminal.proof|IN("pid-absent","pid-identity-mismatch","boot-changed"))' "$record" >/dev/null || fail 'C3 recover record'
  digest=$(sha256sum "$record" | awk '{print $1}'); jq -e --arg d "$digest" '.event=="recover" and .record_revision=="2" and .record_sha256==$d and .holder_id=="holder"' "$event" >/dev/null || fail 'C3 recover event relation'
  c3_authority_digest "$C3_DRIVER_EVIDENCE/authority.before-retry"; c3_call retry recover g --lease-id seed --actor-id recovery-a; [ "$C3_RC" -eq 0 ] || fail 'C3 recover retry'; c3_authority_digest "$C3_DRIVER_EVIDENCE/authority.after-retry"
  c3_call wrong-actor recover g --lease-id seed --actor-id other; c3_expect_code OWNER; c3_call terminal-release release g --lease-id seed --holder-id holder --fencing-token 1; c3_expect_code STATE; c3_call reused acquire "$C3_GRAPH" s --registry "$C3_REGISTRY" --lease-id seed --holder-id other --holder-pid "$$"; c3_expect_code LEASE-ID-REUSED
  c3_trace 'recover=state:recovered kind:recover actor:recovery-a retry=success wrong_actor=OWNER release=STATE reuse=LEASE-ID-REUSED'
}
c3_case_S5V3_TERMINAL_RELEASE_FENCE() {
  local record="$C3_STORE/records/g/seed/2.json" event="$C3_STORE/events/00000000000000000002.json" digest
  c3_call release release g --lease-id seed --holder-id holder --fencing-token 1; [ "$C3_RC" -eq 0 ] || fail 'C3 release success'
  digest=$(sha256sum "$record" | awk '{print $1}'); jq -e '.state=="released" and .terminal.kind=="release" and .terminal.actor_id=="holder" and .terminal.proof=="holder-release"' "$record" >/dev/null || fail 'C3 release record'; jq -e --arg d "$digest" '.event=="release" and .record_sha256==$d' "$event" >/dev/null || fail 'C3 release event'
  c3_call retry release g --lease-id seed --holder-id holder --fencing-token 1; [ "$C3_RC" -eq 0 ] || fail 'C3 release retry'; c3_call terminal-fence fence g --lease-id seed --holder-id holder --fencing-token 2; c3_expect_code STATE; c3_call terminal-recover recover g --lease-id seed --actor-id recovery-a; c3_expect_code STATE; c3_call reused acquire "$C3_GRAPH" s --registry "$C3_REGISTRY" --lease-id seed --holder-id other --holder-pid "$$"; c3_expect_code LEASE-ID-REUSED
  c3_trace 'release=state:released retry=success fence=STATE recover=STATE reuse=LEASE-ID-REUSED'
}
c3_case_S5V3_RELEASE_DIFFERENT_PID() {
  local record="$C3_STORE/records/g/seed/2.json"
  c3_call different-pid-release release g --lease-id seed --holder-id holder --fencing-token 1; [ "$C3_RC" -eq 0 ] || fail 'C3 different pid release'; jq -e '.state=="released" and .terminal.actor_id=="holder"' "$record" >/dev/null || fail 'C3 different pid record'; c3_call wrong-actor release g --lease-id seed --holder-id wrong --fencing-token 1; c3_expect_code OWNER; c3_trace 'seed_pid=dead caller_pid=different exact_holder=success wrong_holder=OWNER'
}
c3_expected_result() {
  local command=$1 record=$2 actor=$3 output=$4 expected
  expected="$C3_CASE_ROOT/$command.expected"
  jq -c --arg command "$command" --arg actor "$actor" '{schema_version:"lease-command-result/v1",command:$command,goal_id:.goal_id,slice_id:.slice_id,lease_id:.lease_id,state:.state,actor_id:$actor,holder_fencing_token:.holder_fencing_token,current_fencing_token:.current_fencing_token,resource_count:(.resources|length|tostring)}' "$record" >"$expected"
  cmp "$expected" "$output" >/dev/null || fail "C3 exact result $command"
}
c3_case_S5V3_EXACT_SUCCESS_BYTES() {
  local record="$C3_STORE/records/g/exact/1.json" token
  c3_call acquire acquire "$C3_GRAPH" s --registry "$C3_REGISTRY" --lease-id exact --holder-id holder --holder-pid "$$"; [ "$C3_RC" -eq 0 ] && [ ! -s "$C3_ERR" ] || fail 'C3 exact acquire'; c3_expected_result acquire "$record" holder "$C3_OUT"; token=$(jq -r '.holder_fencing_token' "$record")
  c3_call release release g --lease-id exact --holder-id holder --fencing-token "$token"; [ "$C3_RC" -eq 0 ] && [ ! -s "$C3_ERR" ] || fail 'C3 exact release'; c3_expected_result release "$C3_STORE/records/g/exact/2.json" holder "$C3_OUT"; c3_trace 'acquire_stdout=canonical_one_line release_stdout=canonical_one_line stderr=empty'
}
c3_case_S5V3_INSPECT_HISTORY_ORDER() {
  local history held
  c3_seed_live a holder-a; c3_call release-a release g --lease-id a --holder-id holder-a --fencing-token 1; [ "$C3_RC" -eq 0 ] || fail 'C3 history release a'; c3_seed_live b holder-b; c3_call history inspect g --history; history="$C3_OUT"; [ "$(wc -l <"$history")" -eq 3 ] || fail 'C3 history count'; jq -e -s '.[0].lease_id=="a" and .[0].revision=="1" and .[1].lease_id=="a" and .[1].revision=="2" and .[2].lease_id=="b" and .[2].revision=="1"' "$history" >/dev/null || fail 'C3 history order'; c3_call held inspect g; held="$C3_OUT"; if ! { [ "$(wc -l <"$held")" -eq 1 ] && jq -e '.lease_id=="b" and .state=="held"' "$held" >/dev/null; }; then fail 'C3 held filter'; fi; c3_trace 'history=a:1,a:2,b:1 held_filter=b:1 order=compareRecords'
}
c3_case_S5V3_STATUS_GOAL_SCOPE() {
  local gstatus hstatus
  c3_call g-acquire acquire "$C3_GRAPH" s --registry "$C3_REGISTRY" --lease-id glease --holder-id gholder --holder-pid "$$"; [ "$C3_RC" -eq 0 ] || fail 'C3 goal g acquire'; c3_call h-acquire acquire "$C3_GRAPH_H" s --registry "$C3_REGISTRY" --lease-id hlease --holder-id hholder --holder-pid "$$"; [ "$C3_RC" -eq 0 ] || fail 'C3 goal h acquire'; c3_call status-g status g; gstatus=$(cat "$C3_OUT"); c3_call status-h status h; hstatus=$(cat "$C3_OUT"); grep -qx 'lease_active_count=1' <<<"$gstatus" || fail 'C3 goal g count'; grep -qx 'lease_terminal_count=0' <<<"$gstatus" || fail 'C3 goal g terminal'; grep -qx 'lease_active_count=1' <<<"$hstatus" || fail 'C3 goal h count'; grep -qx 'lease_terminal_count=0' <<<"$hstatus" || fail 'C3 goal h terminal'; c3_call g-release release g --lease-id glease --holder-id gholder --fencing-token 1; [ "$C3_RC" -eq 0 ] || fail 'C3 goal release'; c3_call status-g-terminal status g; grep -qx 'lease_terminal_count=1' "$C3_OUT" || fail 'C3 goal terminal count'; c3_call status-h-active status h; grep -qx 'lease_active_count=1' "$C3_OUT" || fail 'C3 goal isolation'; c3_trace 'goal=g active_then_terminal=1/1 goal=h active=1 terminal=0 scoped_counts=1'
}
c3_case_S5V3_COUNTER_RECONSTRUCTION() { local record="$C3_STORE/records/g/next/1.json"; c3_call reconstructed acquire "$C3_GRAPH" s --registry "$C3_REGISTRY" --lease-id next --holder-id next-holder --holder-pid "$$"; [ "$C3_RC" -eq 0 ] || fail 'C3 counter reconstruction acquire'; jq -e '.holder_fencing_token=="3" and .current_fencing_token=="3"' "$record" >/dev/null || fail 'C3 reconstructed token'; c3_trace 'counter_corrupted=0 durable_max=2 next_token=3 reconstruction=1'; }
c3_case_S5V3_EVENT_RECORD_INVARIANTS() { local event revision goal lease record digest; c3_assert_event_bindings; while IFS= read -r event; do revision=$(jq -r '.record_revision' "$event"); goal=$(jq -r '.goal_id' "$event"); lease=$(jq -r '.lease_id' "$event"); record="$C3_STORE/records/$goal/$lease/$revision.json"; digest=$(sha256sum "$record" | awk '{print $1}'); jq -e --arg d "$digest" --arg r "$revision" '.record_sha256==$d and .record_revision==$r and .fencing_token != "0"' "$event" >/dev/null || fail 'C3 event invariant fields'; done < <(find "$C3_STORE/events" -type f -name '*.json' | LC_ALL=C sort); c3_call event-inspect inspect g --history; [ "$C3_RC" -eq 0 ] || fail 'C3 event inspect'; c3_trace 'events=acquire+release digests=record_sha256 revisions=1,2 orphans=0'; }
c3_matrix_action() {
  case "$C3_ID" in
    S5V1-08) c3_case_S5V1_08 ;;
    S5V1-09) c3_case_S5V1_09 ;;
    S5V1-12) c3_case_S5V1_12 ;;
    S5V3-ACQUIRE-DEAD-SPLIT) c3_case_S5V3_ACQUIRE_DEAD_SPLIT ;;
    S5V3-ORPHAN-CACHE-STATUS) c3_case_S5V3_ORPHAN_CACHE_STATUS ;;
    S5V3-READBACK-ONCE) c3_case_S5V3_READBACK_ONCE ;;
    S5V3-READBACK-BYTE-TYPE-METADATA-ERROR) c3_case_S5V3_READBACK_BYTE_TYPE_METADATA_ERROR ;;
    S5V3-TERMINAL-RECOVER) c3_case_S5V3_TERMINAL_RECOVER ;;
    S5V3-TERMINAL-RELEASE-FENCE) c3_case_S5V3_TERMINAL_RELEASE_FENCE ;;
    S5V3-RELEASE-DIFFERENT-PID) c3_case_S5V3_RELEASE_DIFFERENT_PID ;;
    S5V3-EXACT-SUCCESS-BYTES) c3_case_S5V3_EXACT_SUCCESS_BYTES ;;
    S5V3-INSPECT-HISTORY-ORDER) c3_case_S5V3_INSPECT_HISTORY_ORDER ;;
    S5V3-STATUS-GOAL-SCOPE) c3_case_S5V3_STATUS_GOAL_SCOPE ;;
    S5V3-COUNTER-RECONSTRUCTION) c3_case_S5V3_COUNTER_RECONSTRUCTION ;;
    S5V3-EVENT-RECORD-INVARIANTS) c3_case_S5V3_EVENT_RECORD_INVARIANTS ;;
    *) fail "C3 action id $C3_ID" ;;
  esac
  printf 'c3_case=%s\n' "$C3_ID"
}

# C4 publication/crash cases keep every subprocess and authority root private.
# Runtime hooks are inert unless the complete, test-only contract is supplied.
c4_matrix_setup() {
  local id=$1 candidate=$2 case_root=$3 home=$4 data=$5 state=$6 graph=$7 registry=$8 evidence=$9
  c3_setup "$id" "$candidate" "$case_root" "$home" "$data" "$state" "$graph" "$registry" "$evidence"
  C4_ID=$id
  C4_CANDIDATE=$candidate
  C4_CASE_ROOT=$case_root
  C4_HOME=$home
  C4_DATA=$data
  C4_STATE=$state
  C4_GRAPH=$graph
  C4_REGISTRY=$registry
  C4_EVIDENCE=$evidence
  C4_COMMAND_INDEX=0
  C4_STORE="$data/workgraphs/.leases/v1"
  case "$id" in
    S5V1-10)
      c3_seed_dead seed holder
      c4_write_race_driver
      ;;
    S5V1-13)
      c3_seed_live seed holder
      ;;
    S5V3-CRASH-EACH-PUBLICATION)
      :
      ;;
    S5V4-IMMUTABLE-REVISION-HISTORY)
      c3_seed_live seed holder
      ;;
    S5V4-PUBLICATION-SUB-BOUNDARIES)
      :
      ;;
    S5V4-TARGET-ONLY-REPAIR)
      c3_seed_live l1 h1
      c3_call l1-release release g --lease-id l1 --holder-id h1 --fencing-token 1
      [ "$C3_RC" -eq 0 ] || fail "C4 target repair l1 release"
      c3_seed_live l2 h2
      ;;
    *)
      fail "C4 setup id $id"
      ;;
  esac
}

c4_write_race_driver() {
  C4_RACE_DRIVER="$C4_CASE_ROOT/c4-terminal-race.py"
  cat >"$C4_RACE_DRIVER" <<'PY_C4_TERMINAL_RACE'
import os
import pathlib
import subprocess
import sys
import time

script, home, data, state, sync_root, evidence = sys.argv[1:]
sync = pathlib.Path(sync_root)
out = pathlib.Path(evidence)
base = os.environ.copy()
base.update({
    "FM_HOME": home,
    "FM_DATA_OVERRIDE": data,
    "FM_STATE_OVERRIDE": state,
    "FM_WORKGRAPH_TEST_HOOKS": "1",
    "FM_LEASE_TEST_ADMISSION_ROOT": sync_root,
})

release_env = dict(base)
release_env["FM_LEASE_TEST_ADMISSION_ID"] = "release"
release_env["FM_LEASE_TEST_ADMISSION_HOLD"] = "1"
recover_env = dict(base)
recover_env["FM_LEASE_TEST_ADMISSION_ID"] = "recover"

release = subprocess.Popen(
    [script, "release", "g", "--lease-id", "seed", "--holder-id", "holder", "--fencing-token", "1"],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=release_env)
recover = subprocess.Popen(
    [script, "recover", "g", "--lease-id", "seed", "--actor-id", "recovery"],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=recover_env)

def wait_for(name):
    deadline = time.monotonic() + 15
    marker = sync / name
    while time.monotonic() < deadline:
        if marker.is_file():
            return
        if release.poll() is not None or recover.poll() is not None:
            raise SystemExit(f"terminal worker exited before {name}")
        time.sleep(0.01)
    raise SystemExit(f"terminal marker timeout: {name}")

def gate(name):
    path = sync / name
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    os.write(fd, b"go\n")
    os.fsync(fd)
    os.close(fd)

wait_for("release.ready")
wait_for("recover.ready")
gate("release.go")
wait_for("release.contending")
wait_for("release.locked")
gate("recover.go")
wait_for("recover.contending")
gate("release.continue")
release_stdout, release_stderr = release.communicate(timeout=20)
recover_stdout, recover_stderr = recover.communicate(timeout=20)
(out / "race-release.stdout").write_bytes(release_stdout)
(out / "race-release.stderr").write_bytes(release_stderr)
(out / "race-recover.stdout").write_bytes(recover_stdout)
(out / "race-recover.stderr").write_bytes(recover_stderr)
if release.returncode != 0 or release_stderr:
    raise SystemExit("release did not win deterministic terminal race")
if recover.returncode != 1 or recover_stdout or recover_stderr != b"fm-workgraph: WG-L-E-STATE: lease operation failed\n":
    raise SystemExit("recover did not lose deterministic terminal race")
print("barrier=both-ready")
print("release=locked-while-recover-contending")
print("winner=release")
print("loser=recover:STATE")
PY_C4_TERMINAL_RACE
  chmod 0700 "$C4_RACE_DRIVER"
}

c4_build_template() {
  local kind=$1 root="$C4_CASE_ROOT/c4-templates/$1" output error rc
  mkdir -p "$root/home" "$root/data" "$root/state"
  cp "$C4_GRAPH" "$root/graph.json"
  cp "$C3_CONTRACT" "$root/contract.json"
  cp "$C4_REGISTRY" "$root/registry.json"
  output="$C4_EVIDENCE/template-$kind.stdout"
  error="$C4_EVIDENCE/template-$kind.stderr"
  set +e
  if [ "$kind" = release ]; then
    FM_HOME="$root/home" FM_DATA_OVERRIDE="$root/data" FM_STATE_OVERRIDE="$root/state" \
      "$C4_CANDIDATE/bin/fm-workgraph-lease-lib.sh" acquire "$root/graph.json" s --registry "$root/registry.json" --lease-id seed --holder-id holder --holder-pid "$$" >"$output" 2>"$error"
    rc=$?
  else
    FM_HOME="$root/home" FM_DATA_OVERRIDE="$root/data" FM_STATE_OVERRIDE="$root/state" \
      bash -c 'exec "$1" acquire "$2" s --registry "$3" --lease-id seed --holder-id holder --holder-pid "$$"' c4-dead-template \
      "$C4_CANDIDATE/bin/fm-workgraph-lease-lib.sh" "$root/graph.json" "$root/registry.json" >"$output" 2>"$error"
    rc=$?
  fi
  set -e
  [ "$rc" -eq 0 ] && [ ! -s "$error" ] || fail "C4 $kind template"
}

c4_clone_template() {
  local kind=$1 label=$2 root output error rc
  root="$C4_CASE_ROOT/c4-arenas/$label"
  mkdir -p "$root/home" "$root/data" "$root/state"
  cp "$C4_GRAPH" "$root/graph.json"
  cp "$C3_CONTRACT" "$root/contract.json"
  cp "$C4_REGISTRY" "$root/registry.json"
  output="$C4_EVIDENCE/setup-$label.stdout"
  error="$C4_EVIDENCE/setup-$label.stderr"
  set +e
  if [ "$kind" = release ]; then
    FM_HOME="$root/home" FM_DATA_OVERRIDE="$root/data" FM_STATE_OVERRIDE="$root/state" \
      "$C4_CANDIDATE/bin/fm-workgraph-lease-lib.sh" acquire "$root/graph.json" s --registry "$root/registry.json" --lease-id seed --holder-id holder --holder-pid "$$" >"$output" 2>"$error"
    rc=$?
  else
    FM_HOME="$root/home" FM_DATA_OVERRIDE="$root/data" FM_STATE_OVERRIDE="$root/state" \
      bash -c 'exec "$1" acquire "$2" s --registry "$3" --lease-id seed --holder-id holder --holder-pid "$$"' c4-dead-arena \
      "$C4_CANDIDATE/bin/fm-workgraph-lease-lib.sh" "$root/graph.json" "$root/registry.json" >"$output" 2>"$error"
    rc=$?
  fi
  set -e
  [ "$rc" -eq 0 ] && [ ! -s "$error" ] || fail "C4 arena setup $label"
  C4_ARENA=$root
}

c4_arena_command() {
  local label=$1 crash=$2
  shift 2
  C4_COMMAND_INDEX=$((C4_COMMAND_INDEX + 1))
  local stem
  stem=$(printf '%03d-%s' "$C4_COMMAND_INDEX" "$label")
  C4_OUT="$C4_EVIDENCE/$stem.stdout"
  C4_ERR="$C4_EVIDENCE/$stem.stderr"
  set +e
  if [ -n "$crash" ]; then
    python3 - "$C4_OUT" "$C4_ERR" "$C4_ARENA/home" "$C4_ARENA/data" "$C4_ARENA/state" "$crash" \
      "$C4_CANDIDATE/bin/fm-workgraph-lease-lib.sh" "$@" <<'PY_C4_CRASH_RUNNER'
import os
import pathlib
import subprocess
import sys

stdout_path, stderr_path, home, data, state, crash, script, *args = sys.argv[1:]
env = os.environ.copy()
env.update({
    "FM_HOME": home,
    "FM_DATA_OVERRIDE": data,
    "FM_STATE_OVERRIDE": state,
    "FM_WORKGRAPH_TEST_HOOKS": "1",
    "FM_LEASE_TEST_CRASH_PUBLICATION": crash,
})
result = subprocess.run([script, *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, check=False)
pathlib.Path(stdout_path).write_bytes(result.stdout)
pathlib.Path(stderr_path).write_bytes(result.stderr)
raise SystemExit(128 - result.returncode if result.returncode < 0 else result.returncode)
PY_C4_CRASH_RUNNER
  else
    FM_HOME="$C4_ARENA/home" FM_DATA_OVERRIDE="$C4_ARENA/data" FM_STATE_OVERRIDE="$C4_ARENA/state" \
      "$C4_CANDIDATE/bin/fm-workgraph-lease-lib.sh" "$@" >"$C4_OUT" 2>"$C4_ERR"
  fi
  C4_RC=$?
  set -e
  printf 'command=%s crash=%s rc=%s\n' "$label" "${crash:-none}" "$C4_RC" >>"$C4_EVIDENCE/commands.txt"
}

c4_case_S5V1_10() {
  local sync="$C4_CASE_ROOT/c4-terminal-sync" race_out="$C4_EVIDENCE/race-driver.stdout" race_err="$C4_EVIDENCE/race-driver.stderr" rc before after
  mkdir -m 0700 "$sync"
  c3_manifest "$C4_EVIDENCE/race.before"
  set +e
  python3 "$C4_RACE_DRIVER" "$C4_CANDIDATE/bin/fm-workgraph-lease-lib.sh" "$C4_HOME" "$C4_DATA" "$C4_STATE" "$sync" "$C4_EVIDENCE" >"$race_out" 2>"$race_err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] && [ ! -s "$race_err" ] || fail "C4 terminal race driver"
  grep -qx 'release=locked-while-recover-contending' "$race_out" || fail "C4 terminal race overlap"
  jq -e '.state=="released" and .revision=="2" and .terminal.kind=="release"' "$C4_STORE/records/g/seed/2.json" >/dev/null || fail "C4 terminal race authority"
  c3_call inspect-active inspect g
  [ "$C3_RC" -eq 0 ] && [ ! -s "$C3_OUT" ] && [ ! -s "$C3_ERR" ] || fail "C4 inspect active filter"
  c3_call inspect-history inspect g --history
  [ "$C3_RC" -eq 0 ] && [ "$(wc -l <"$C3_OUT")" -eq 2 ] || fail "C4 inspect history"
  before="$C4_EVIDENCE/inspect.before"
  after="$C4_EVIDENCE/inspect.after"
  c3_manifest "$before"
  c3_call inspect-repeat inspect g --history
  c3_manifest "$after"
  c3_same "$before" "$after"
  c3_trace 'terminal_race=release_locked_while_recover_contending winner=release loser=STATE inspect=read-only'
}

c4_case_S5V1_13() {
  local before="$C4_EVIDENCE/overflow.before" after="$C4_EVIDENCE/overflow.after"
  printf '9223372036854775807\n' >"$C4_STORE/fencing-counter"
  chmod 0600 "$C4_STORE/fencing-counter"
  c3_manifest "$before"
  c3_call overflow release g --lease-id seed --holder-id holder --fencing-token 1
  c3_expect_code OVERFLOW
  c3_manifest "$after"
  c3_same "$before" "$after"
  c3_trace 'counter=max release=OVERFLOW zero_mutation=1'
}

c4_case_S5V3_CRASH_EACH_PUBLICATION() {
  local kind ordinal phase label
  for kind in release recover; do
    for ordinal in 1 2 3 4 5 6 7; do
      for phase in before-rename after-rename-before-parent-fsync after-parent-fsync-before-readback after-readback; do
        label="$kind-$ordinal-$phase"
        c4_clone_template "$kind" "$label"
        if [ "$kind" = release ]; then
          c4_arena_command "crash-$label" "$ordinal:$phase" release g --lease-id seed --holder-id holder --fencing-token 1
        else
          c4_arena_command "crash-$label" "$ordinal:$phase" recover g --lease-id seed --actor-id recovery
        fi
        [ "$C4_RC" -eq 137 ] || fail "C4 crash $label"
        c4_arena_command "reopen-$label" "" status g
        [ "$C4_RC" -eq 0 ] && [ ! -s "$C4_ERR" ] || fail "C4 reopen $label"
        if [ "$kind" = release ]; then
          c4_arena_command "retry-$label" "" release g --lease-id seed --holder-id holder --fencing-token 1
        else
          c4_arena_command "retry-$label" "" recover g --lease-id seed --actor-id recovery
        fi
        [ "$C4_RC" -eq 0 ] && [ ! -s "$C4_ERR" ] || fail "C4 retry $label"
      done
    done
  done
  c3_trace 'publication_ordinals=1..7 phases=4 commands=release,recover crash=137 reopen=success retry=idempotent'
}

c4_case_S5V4_IMMUTABLE_REVISION_HISTORY() {
  local record1="$C4_STORE/records/g/seed/1.json" event1="$C4_STORE/events/00000000000000000001.json"
  local record2="$C4_STORE/records/g/seed/2.json" event2="$C4_STORE/events/00000000000000000002.json"
  local before="$C4_EVIDENCE/history.before" after="$C4_EVIDENCE/history.after" hashes="$C4_EVIDENCE/history.sha256"
  c3_call release release g --lease-id seed --holder-id holder --fencing-token 1
  [ "$C3_RC" -eq 0 ] || fail "C4 immutable release"
  sha256sum "$record1" "$event1" "$record2" "$event2" >"$hashes"
  c3_call release-retry release g --lease-id seed --holder-id holder --fencing-token 1
  [ "$C3_RC" -eq 0 ] || fail "C4 immutable retry"
  sha256sum -c "$hashes" >/dev/null || fail "C4 immutable history hashes"
  c3_manifest "$before"
  c3_call wrong-holder release g --lease-id seed --holder-id other --fencing-token 1
  c3_expect_code OWNER
  c3_call terminal-recover recover g --lease-id seed --actor-id recovery
  c3_expect_code STATE
  c3_manifest "$after"
  c3_same "$before" "$after"
  c3_trace 'revisions=1,2 events=1,2 immutable=sha256-stable retry=idempotent rejected=zero-mutation'
}

c4_case_S5V4_PUBLICATION_SUB_BOUNDARIES() {
  local hostile="$C4_CASE_ROOT/c4-hostile" before="$C4_EVIDENCE/hostile.before" after="$C4_EVIDENCE/hostile.after" rc
  mkdir -p "$hostile/home" "$hostile/data" "$hostile/state" "$hostile/escape"
  ln -s "$hostile/escape" "$hostile/data/workgraphs"
  roots_manifest "$hostile/data" "$hostile/state" "$before"
  set +e
  FM_HOME="$hostile/home" FM_DATA_OVERRIDE="$hostile/data" FM_STATE_OVERRIDE="$hostile/state" \
    "$C4_CANDIDATE/bin/fm-workgraph-lease-lib.sh" status g >"$C4_EVIDENCE/hostile.stdout" 2>"$C4_EVIDENCE/hostile.stderr"
  rc=$?
  set -e
  if ! { [ "$rc" -eq 1 ] && [ ! -s "$C4_EVIDENCE/hostile.stdout" ] && grep -qx 'fm-workgraph: WG-L-E-STORE: lease operation failed' "$C4_EVIDENCE/hostile.stderr"; }; then
    fail "C4 hostile path"
  fi
  roots_manifest "$hostile/data" "$hostile/state" "$after"
  cmp "$before" "$after" >/dev/null || fail "C4 hostile path mutation"
  c3_trace 'publication_phases=before-rename,after-rename-before-parent-fsync,after-parent-fsync-before-readback,after-readback hostile_symlink=STORE zero_mutation=1'
}

c4_case_S5V4_TARGET_ONLY_REPAIR() {
  local target_event="$C4_STORE/events/00000000000000000002.json"
  local unrelated_event="$C4_STORE/events/00000000000000000003.json"
  local safe_temp="$C4_STORE/records/g/l2/.audit.json.tmp.AAAAAA"
  cp "$unrelated_event" "$C4_EVIDENCE/unrelated.before"
  cp "$target_event" "$C4_EVIDENCE/target-event.before"
  rm "$target_event"
  printf 'safe orphan\n' >"$safe_temp"
  chmod 0600 "$safe_temp"
  c3_call repair release g --lease-id l1 --holder-id h1 --fencing-token 1
  [ "$C3_RC" -eq 0 ] && [ ! -s "$C3_ERR" ] || fail "C4 target repair"
  [ -f "$target_event" ] || fail "C4 target event not repaired"
  [ -f "$safe_temp" ] || fail "C4 unrelated safe temp removed"
  cmp "$unrelated_event" "$C4_EVIDENCE/unrelated.before" >/dev/null || fail "C4 unrelated event changed"
  cmp "$target_event" "$C4_EVIDENCE/target-event.before" >/dev/null || fail "C4 repaired event bytes"
  c3_trace 'target_event=repaired unrelated_event=unchanged safe_temp=preserved'
}

c4_matrix_action() {
  case "$C4_ID" in
    S5V1-10) c4_case_S5V1_10 ;;
    S5V1-13) c4_case_S5V1_13 ;;
    S5V3-CRASH-EACH-PUBLICATION) c4_case_S5V3_CRASH_EACH_PUBLICATION ;;
    S5V4-IMMUTABLE-REVISION-HISTORY) c4_case_S5V4_IMMUTABLE_REVISION_HISTORY ;;
    S5V4-PUBLICATION-SUB-BOUNDARIES) c4_case_S5V4_PUBLICATION_SUB_BOUNDARIES ;;
    S5V4-TARGET-ONLY-REPAIR) c4_case_S5V4_TARGET_ONLY_REPAIR ;;
    *) fail "C4 action id $C4_ID" ;;
  esac
  printf 'c4_case=%s\n' "$C4_ID"
}

# C5 closes the static/oracle/evidence family.  All roots are descendants of
# the focused case root; the only external input is the sealed, read-only S4 tar.
c5_matrix_setup() {
  local id=$1 candidate=$2 case_root=$3 home=$4 data=$5 state=$6 graph=$7 registry=$8 evidence=$9
  C5_ID=$id
  C5_CANDIDATE=$candidate
  C5_CASE_ROOT=$case_root
  C5_STATE=$state
  C5_GRAPH=$graph
  C5_REGISTRY=$registry
  C5_EVIDENCE=$evidence
  C5_S4_ARCHIVE=/home/gary/firstmate/data/fm-workgraph-s4-candidate-20260729-v1/candidate.tar
  mkdir -p "$C5_EVIDENCE" "$C5_CASE_ROOT/tmp"
  chmod 0700 "$C5_EVIDENCE" "$C5_CASE_ROOT/tmp"
  : >"$C5_EVIDENCE/trace.txt"
  if [ "$id" = S5V4-CACHE-CANONICAL-BYTES ]; then
    c3_setup "$id" "$candidate" "$case_root" "$home" "$data" "$state" "$graph" "$registry" "$evidence"
    c3_make_read_graphs
    C5_GRAPH=$C3_GRAPH
    c3_seed_live b hb
    c3_call b-release release g --lease-id b --holder-id hb --fencing-token 1
    [ "$C3_RC" -eq 0 ] || fail "C5 cache seed release"
    c3_seed_live a ha
  fi
}

c5_trace() { printf '%s\n' "$*" >>"$C5_EVIDENCE/trace.txt"; }

c5_case_S5V1_01() {
  local pass test test_path rc output error
  for pass in 1 2; do
    for test in fm-workgraph.test.sh fm-workgraph-compatibility.test.sh fm-workgraph-docs.test.sh; do
      test_path="$C5_CANDIDATE/tests/$test"
      output="$C5_EVIDENCE/pass-$pass-$test.stdout"
      error="$C5_EVIDENCE/pass-$pass-$test.stderr"
      set +e
      TMPDIR="$C5_CASE_ROOT/tmp" bash "$test_path" >"$output" 2>"$error"
      rc=$?
      set -e
      [ "$rc" -eq 0 ] && [ ! -s "$error" ] || fail "C5 legacy test $pass $test"
    done
  done
  for test in fm-workgraph.test.sh fm-workgraph-compatibility.test.sh fm-workgraph-docs.test.sh; do
    cmp "$C5_EVIDENCE/pass-1-$test.stdout" "$C5_EVIDENCE/pass-2-$test.stdout" >/dev/null || fail "C5 legacy rerun bytes $test"
  done
  bash -n "$C5_CANDIDATE/bin/fm-parallelism.sh" "$C5_CANDIDATE/bin/fm-workgraph.sh" "$C5_CANDIDATE/bin/fm-workgraph-lease-lib.sh" \
    "$C5_CANDIDATE/tests/fm-workgraph.test.sh" "$C5_CANDIDATE/tests/fm-workgraph-compatibility.test.sh" "$C5_CANDIDATE/tests/fm-workgraph-leases.test.sh"
  shellcheck -x "$C5_CANDIDATE/bin/fm-parallelism.sh" "$C5_CANDIDATE/bin/fm-workgraph.sh" "$C5_CANDIDATE/bin/fm-workgraph-lease-lib.sh" \
    "$C5_CANDIDATE/tests/fm-workgraph.test.sh" "$C5_CANDIDATE/tests/fm-workgraph-compatibility.test.sh" "$C5_CANDIDATE/tests/fm-workgraph-leases.test.sh"
  git -C "$ROOT" diff --check
  c5_trace 'legacy_tests=3 passes=2 syntax=pass shellcheck=pass workgraph_docs=pass diff_check=pass'
}

c5_case_S5V1_14() {
  local run root output error rc source="$C5_CANDIDATE/tests/fm-workgraph-leases.test.sh"
  grep -Fq 'for matrix_pass in 1 2; do' "$source" || fail "C5 two-pass loop"
  grep -Fq 'filesystem-after.normalized.sha256' "$source" || fail "C5 normalized global manifest equality"
  grep -Fq 'summary.json' "$source" || fail "C5 summary equality"
  grep -Fq 'candidate-input.json' "$source" || fail "C5 candidate input equality"
  for run in 1 2; do
    root="$C5_CASE_ROOT/determinism-$run"
    mkdir -p "$root/home" "$root/data" "$root/state"
    output="$C5_EVIDENCE/determinism-$run.stdout"
    error="$C5_EVIDENCE/determinism-$run.stderr"
    set +e
    FM_HOME="$root/home" FM_DATA_OVERRIDE="$root/data" FM_STATE_OVERRIDE="$root/state" \
      "$C5_CANDIDATE/bin/fm-workgraph-lease-lib.sh" status g >"$output" 2>"$error"
    rc=$?
    set -e
    [ "$rc" -eq 0 ] && [ ! -s "$error" ] || fail "C5 deterministic reopen $run"
  done
  cmp "$C5_EVIDENCE/determinism-1.stdout" "$C5_EVIDENCE/determinism-2.stdout" >/dev/null || fail "C5 deterministic reopen bytes"
  [ "$(wc -l <"$C5_EVIDENCE/determinism-1.stdout")" -eq 6 ] || fail "C5 deterministic status line count"
  c5_trace 'global_loop=two serial=true equality_set=present reopen_runs=2 byte_identical=true'
}

c5_case_S5V1_15() {
  python3 - "$C5_CANDIDATE/bin/fm-workgraph-lease-lib.sh" "$C5_EVIDENCE/static-audit.txt" <<'PY_C5_STATIC_AUDIT' || fail "C5 static dependency audit"
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_bytes()
forbidden = [
    b"fm-spawn", b"fm-brief", b"fm-teardown", b"fm-watch", b"fm-pr-",
    b"fm-parallelism", b"fm-backend", b"fm-check-", b"gh-axi",
    b"chrome-devtools-axi", b"lavish-axi", b"node:net", b"node:http",
    b"node:https", b"node:dns", b"socket.", b"docker ", b"psql ",
]
hits = [item.decode("ascii") for item in forbidden if item in source]
if hits:
    raise SystemExit("forbidden static dependency: " + ",".join(hits))
pathlib.Path(sys.argv[2]).write_text(
    "scope=bin/fm-workgraph-lease-lib.sh\n"
    "forbidden_dependency_matches=0\n"
    "network_modules=0\n"
    "operational_targets=0\n",
    encoding="ascii",
)
PY_C5_STATIC_AUDIT
  c5_trace 'audit=static scope=lease-runtime forbidden_dependencies=0 operational_access=0'
}

c5_extract_s4() {
  local destination=$1 digest
  digest=$(sha256sum "$C5_S4_ARCHIVE" | awk '{print $1}')
  [ "$digest" = 644f94e26b6bcaf08f286ad57248faadfa0ac6dbccb9c34e89c1bc93c38e61b8 ] || fail "C5 sealed S4 archive hash"
  mkdir -p "$destination"
  tar -xf "$C5_S4_ARCHIVE" -C "$destination"
  [ -d "$destination/firstmate" ] && [ ! -L "$destination/firstmate" ] || fail "C5 sealed S4 root"
}

c5_case_S5V3_SLICE4_BYTE_ORACLE() {
  local s4_parent="$C5_CASE_ROOT/oracle/s4" s4 s5="$C5_CANDIDATE" test which root output error rc
  local s4_status="$C5_EVIDENCE/s4-status.stdout" s5_status="$C5_EVIDENCE/s5-status.stdout"
  c5_extract_s4 "$s4_parent"
  s4="$s4_parent/firstmate"
  for test in fm-workgraph.test.sh fm-workgraph-compatibility.test.sh; do
    for which in s4 s5; do
      if [ "$which" = s4 ]; then root=$s4; else root=$s5; fi
      output="$C5_EVIDENCE/$which-$test.stdout"
      error="$C5_EVIDENCE/$which-$test.stderr"
      set +e
      TMPDIR="$C5_CASE_ROOT/tmp" bash "$root/tests/$test" >"$output" 2>"$error"
      rc=$?
      set -e
      printf '%s\n' "$rc" >"$C5_EVIDENCE/$which-$test.exit"
      [ "$rc" -eq 0 ] && [ ! -s "$error" ] || fail "C5 Slice4 oracle $which $test"
    done
    if [ "$test" = fm-workgraph-compatibility.test.sh ]; then
      cp "$C5_EVIDENCE/s4-$test.stdout" "$C5_EVIDENCE/$test.expected"
      printf '%s\n' \
        'ok - unknown contract selector fails closed' \
        'ok - missing contract selector fails closed' \
        'ok - contract selector returns only the exact sealed bytes' \
        >>"$C5_EVIDENCE/$test.expected"
      cmp "$C5_EVIDENCE/$test.expected" "$C5_EVIDENCE/s5-$test.stdout" >/dev/null || fail "C5 Slice4 stdout extension oracle $test"
    else
      cmp "$C5_EVIDENCE/s4-$test.stdout" "$C5_EVIDENCE/s5-$test.stdout" >/dev/null || fail "C5 Slice4 stdout oracle $test"
    fi
    cmp "$C5_EVIDENCE/s4-$test.stderr" "$C5_EVIDENCE/s5-$test.stderr" >/dev/null || fail "C5 Slice4 stderr oracle $test"
    cmp "$C5_EVIDENCE/s4-$test.exit" "$C5_EVIDENCE/s5-$test.exit" >/dev/null || fail "C5 Slice4 exit oracle $test"
  done
  FM_HOME="$C5_CASE_ROOT/s4-status-home" FM_DATA_OVERRIDE="$C5_CASE_ROOT/s4-status-data" FM_STATE_OVERRIDE="$C5_CASE_ROOT/s4-status-state" \
    "$s4/bin/fm-workgraph.sh" status "$C5_GRAPH" --registry "$C5_REGISTRY" >"$s4_status" 2>"$C5_EVIDENCE/s4-status.stderr"
  FM_HOME="$C5_CASE_ROOT/s5-status-home" FM_DATA_OVERRIDE="$C5_CASE_ROOT/s5-status-data" FM_STATE_OVERRIDE="$C5_CASE_ROOT/s5-status-state" \
    "$s5/bin/fm-workgraph.sh" status "$C5_GRAPH" --registry "$C5_REGISTRY" >"$s5_status" 2>"$C5_EVIDENCE/s5-status.stderr"
  cp "$s4_status" "$C5_EVIDENCE/status.expected"
  printf '%s\n' 'lease_store=absent' 'lease_cache=absent' 'lease_active_count=0' 'lease_terminal_count=0' 'lease_fencing=unavailable' 'lease_enforcement=unavailable' >>"$C5_EVIDENCE/status.expected"
  cmp "$C5_EVIDENCE/status.expected" "$s5_status" >/dev/null || fail "C5 Slice4 status suffix"
  cmp "$C5_EVIDENCE/s4-status.stderr" "$C5_EVIDENCE/s5-status.stderr" >/dev/null || fail "C5 Slice4 status stderr"
  [ ! -e "$C5_CASE_ROOT/s4-status-data/workgraphs/.leases" ] && [ ! -e "$C5_CASE_ROOT/s5-status-data/workgraphs/.leases" ] || fail "C5 Slice4 oracle lease mutation"
  c5_trace 'sealed_s4_sha256=644f94e26b6bcaf08f286ad57248faadfa0ac6dbccb9c34e89c1bc93c38e61b8 legacy_tests=2 base_bytes=identical compatibility_extensions=3 status_suffix=6'
}

c5_case_S5V3_OUTPUT_MANIFEST() {
  if ! (serializer_vectors "$C5_CASE_ROOT/serializer-output") >"$C5_EVIDENCE/serializer.stdout" 2>"$C5_EVIDENCE/serializer.stderr"; then
    fail "C5 output manifest vectors"
  fi
  [ "$(find "$C5_CASE_ROOT/serializer-output/cases/S5V3-OUTPUT-MANIFEST/S/workgraphs/g/vector" -type l | wc -l)" -eq 7 ] || fail "C5 output manifest vector count"
  c5_trace 'serializer=single vectors=7 raw_manifests=2 normalized_manifests=1 arbitrary_target_bytes=preserved'
}

c5_cache_expected() {
  local output=$1
  shift
  jq -c -s 'sort_by(.slice_id, (.holder_fencing_token|tonumber), .lease_id) as $records | {schema_version:"lease-cache/v1",namespace_id:$records[0].namespace_id,goal_id:"g",records:$records}' "$@" >"$output"
}

c5_assert_cache_shape() {
  local cache=$1
  [ -f "$cache" ] && [ ! -L "$cache" ] || fail "C5 cache regular file"
  [ "$(stat -c %a "$cache")" = 600 ] || fail "C5 cache mode"
  [ "$(stat -c %u "$cache")" = "$(id -u)" ] || fail "C5 cache owner"
  [ "$(stat -c %h "$cache")" = 1 ] || fail "C5 cache link count"
}

c5_case_S5V4_CACHE_CANONICAL_BYTES() {
  local cache="$C5_STATE/workgraphs/g/leases.v1.json" expected="$C5_EVIDENCE/cache.expected"
  local record_b="$C3_STORE/records/g/b/2.json" record_a="$C3_STORE/records/g/a/1.json"
  c5_cache_expected "$expected" "$record_b" "$record_a"
  c5_assert_cache_shape "$cache"
  cmp "$expected" "$cache" >/dev/null || fail "C5 canonical cache bytes"
  printf 'corrupt\n' >"$cache"
  chmod 0600 "$cache"
  c3_call corrupted-status status g
  if ! { [ "$C3_RC" -eq 0 ] && grep -qx 'lease_cache=reconstructed' "$C3_OUT"; }; then
    fail "C5 cache reconstructed status"
  fi
  cmp <(printf 'corrupt\n') "$cache" >/dev/null || fail "C5 readonly status changed cache"
  c3_call a-release release g --lease-id a --holder-id ha --fencing-token 3
  [ "$C3_RC" -eq 0 ] || fail "C5 cache rebuild release"
  record_a="$C3_STORE/records/g/a/2.json"
  c5_cache_expected "$expected" "$record_b" "$record_a"
  c5_assert_cache_shape "$cache"
  cmp "$expected" "$cache" >/dev/null || fail "C5 rebuilt canonical cache bytes"
  c5_trace 'cache=canonical key_order=sealed record_order=slice,token,lease corrupt_status=reconstructed rebuild=atomic'
}

c5_case_S5V4_EVIDENCE_SERIALIZATION() {
  local vector_root="$C5_CASE_ROOT/serializer-evidence"
  if ! (serializer_vectors "$C5_CASE_ROOT/serializer-evidence") >"$C5_EVIDENCE/serializer.stdout" 2>"$C5_EVIDENCE/serializer.stderr"; then
    fail "C5 evidence serializer vectors"
  fi
  [ "$(wc -l <"$vector_root/v10.raw-before.roundtrip")" -eq 7 ] || fail "C5 evidence raw-before count"
  [ "$(wc -l <"$vector_root/v10.raw-after.roundtrip")" -eq 7 ] || fail "C5 evidence raw-after count"
  [ "$(wc -l <"$vector_root/v10.normalized.roundtrip")" -eq 7 ] || fail "C5 evidence normalized count"
  c5_trace 'serializer=single roundtrip_records=21 parser_negatives=fail-closed empty_targets=rejected terminal_normalization=shared'
}

c5_case_S5V4_ORACLE_ROOTS() {
  local s4_parent="$C5_CASE_ROOT/oracle-roots/s4" s4 s5="$C5_CANDIDATE" current
  c5_extract_s4 "$s4_parent"
  s4="$s4_parent/firstmate"
  for current in "$s4" "$s5"; do
    [ -d "$current" ] && [ ! -L "$current" ] || fail "C5 oracle root shape"
    [ -z "$(find "$current" -name .git -print -quit)" ] || fail "C5 oracle root contains git metadata"
    case "$(realpath -e "$current")" in
      "$MATRIX_RERUN_ROOT"/*) ;;
      *) fail "C5 oracle root outside rerun" ;;
    esac
  done
  mkdir -p "$C5_CASE_ROOT/tmp/oracle"
  [ "$(realpath -e "$C5_CASE_ROOT/tmp/oracle")" = "$C5_CASE_ROOT/tmp/oracle" ] || fail "C5 oracle tmp root"
  [ "$(sha256sum "$MATRIX_CANDIDATE_ARCHIVE" | awk '{print $1}')" = "$MATRIX_CANDIDATE_ARCHIVE_DIGEST" ] || fail "C5 oracle candidate archive binding"
  c5_trace 'oracle_roots=s4,s5 isolated=true git_metadata=absent candidate_archive=bound tmp=beneath-rerun serializer_root=single'
}

c5_matrix_action() {
  case "$C5_ID" in
    S5V1-01) c5_case_S5V1_01 ;;
    S5V1-14) c5_case_S5V1_14 ;;
    S5V1-15) c5_case_S5V1_15 ;;
    S5V3-SLICE4-BYTE-ORACLE) c5_case_S5V3_SLICE4_BYTE_ORACLE ;;
    S5V3-OUTPUT-MANIFEST) c5_case_S5V3_OUTPUT_MANIFEST ;;
    S5V4-CACHE-CANONICAL-BYTES) c5_case_S5V4_CACHE_CANONICAL_BYTES ;;
    S5V4-EVIDENCE-SERIALIZATION) c5_case_S5V4_EVIDENCE_SERIALIZATION ;;
    S5V4-ORACLE-ROOTS) c5_case_S5V4_ORACLE_ROOTS ;;
    *) fail "C5 action id $C5_ID" ;;
  esac
  printf 'c5_case=%s\n' "$C5_ID"
}

# C2 transaction/arbitration cases are deliberately self-contained.  They
# never share an authority root because Linux flock visibility is process-global.
c2_setup() {
  local id=$1 candidate=$2 case_root=$3 home=$4 data=$5 state=$6 graph=$7 registry=$8 evidence=$9 namespace_id
  C2_HOLDER_PID=${C2_HOLDER_PID:-$$}
  export C2_HOLDER_PID
  C2_CANDIDATE="$candidate"
  C2_CASE_ROOT="$case_root"
  C2_HOME="$home"
  C2_DATA="$data"
  C2_STATE="$state"
  C2_GRAPH="$graph"
  C2_REGISTRY="$registry"
  C2_CONTRACT="$C2_CASE_ROOT/contract.json"
  C2_STORE="$C2_DATA/workgraphs/.leases/v1"
  C2_DRIVER_EVIDENCE="$evidence"
  C2_COMMAND_INDEX=0
  mkdir -p "$C2_DRIVER_EVIDENCE"
  chmod 0700 "$C2_DRIVER_EVIDENCE"
  mkdir -p "$C2_STORE/records" "$C2_STORE/events"
  chmod 0700 "$C2_DATA/workgraphs" "$C2_DATA/workgraphs/.leases" "$C2_STORE" "$C2_STORE/records" "$C2_STORE/events"
  namespace_id=$(printf 'firstmate-workgraph-lease-namespace/v1\n%s\n' "$C2_DATA" | sha256sum | awk '{print $1}')
  printf '%s\n' "{\"schema_version\":\"lease-namespace/v1\",\"namespace_id\":\"$namespace_id\",\"goal_scope\":\"all-goals\",\"counter_floor\":\"0\"}" >"$C2_STORE/namespace.json"
  printf '0\n' >"$C2_STORE/fencing-counter"
  printf '0\n' >"$C2_STORE/transaction-generation"
  : >"$C2_STORE/.transaction-lock"
  chmod 0600 "$C2_STORE/namespace.json" "$C2_STORE/fencing-counter" "$C2_STORE/transaction-generation" "$C2_STORE/.transaction-lock"
  : >"$C2_DRIVER_EVIDENCE/commands.txt"
  : >"$C2_DRIVER_EVIDENCE/trace.txt"
}
c2_call() {
  local name=$1
  shift
  C2_COMMAND_INDEX=$((C2_COMMAND_INDEX + 1))
  local stem
  stem=$(printf '%03d-%s' "$C2_COMMAND_INDEX" "$name")
  C2_OUT="$C2_DRIVER_EVIDENCE/$stem.stdout"
  C2_ERR="$C2_DRIVER_EVIDENCE/$stem.stderr"
  set +e
  FM_HOME="$C2_HOME" FM_DATA_OVERRIDE="$C2_DATA" FM_STATE_OVERRIDE="$C2_STATE" "$C2_CANDIDATE/bin/fm-workgraph-lease-lib.sh" "$@" >"$C2_OUT" 2>"$C2_ERR"
  C2_RC=$?
  set -e
  {
    printf 'command=%s rc=%s\nstdout:\n' "$name" "$C2_RC"
    cat "$C2_OUT"
    printf 'stderr:\n'
    cat "$C2_ERR"
  } >>"$C2_DRIVER_EVIDENCE/commands.txt"
}
c2_expect_code() {
  local code=$1
  if ! { [ "$C2_RC" -eq 1 ] && [ ! -s "$C2_OUT" ] && grep -qx "fm-workgraph: WG-L-E-$code: lease operation failed" "$C2_ERR"; }; then
    printf 'C2 diagnostic rc=%s stdout=%s stderr=%s\n' "$C2_RC" "$(cat "$C2_OUT")" "$(cat "$C2_ERR")" >&2
    fail "C2 expected $code"
  fi
}
c2_manifest() {
  roots_manifest "$C2_DATA" "$C2_STATE" "$1"
}
c2_same() {
  cmp "$1" "$2" >/dev/null || fail "C2 unexpected D/S mutation"
}
c2_acquire_seed() {
  c2_call seed-acquire acquire "$C2_GRAPH" s --registry "$C2_REGISTRY" --lease-id seed --holder-id holder --holder-pid "$C2_HOLDER_PID"
  [ "$C2_RC" -eq 0 ] && [ ! -s "$C2_ERR" ] || fail "C2 seed acquire"
}
c2_trace() {
  printf '%s\n' "$*" >>"$C2_DRIVER_EVIDENCE/trace.txt"
}
c2_finish() {
  c2_trace "case=$1 rc=pass"
}
c2_arena_make() {
  local arena=$1 mode=$2 digest namespace_id
  mkdir -p "$arena/home" "$arena/data" "$arena/state"
  chmod 0755 "$arena" "$arena/home" "$arena/data" "$arena/state"
  mkdir -p "$arena/data/workgraphs/.leases/v1/records" "$arena/data/workgraphs/.leases/v1/events"
  chmod 0700 "$arena/data/workgraphs" "$arena/data/workgraphs/.leases" "$arena/data/workgraphs/.leases/v1" "$arena/data/workgraphs/.leases/v1/records" "$arena/data/workgraphs/.leases/v1/events"
  namespace_id=$(printf 'firstmate-workgraph-lease-namespace/v1\n%s\n' "$arena/data" | sha256sum | awk '{print $1}')
  printf '%s\n' "{\"schema_version\":\"lease-namespace/v1\",\"namespace_id\":\"$namespace_id\",\"goal_scope\":\"all-goals\",\"counter_floor\":\"0\"}" >"$arena/data/workgraphs/.leases/v1/namespace.json"
  printf '0\n' >"$arena/data/workgraphs/.leases/v1/fencing-counter"
  printf '0\n' >"$arena/data/workgraphs/.leases/v1/transaction-generation"
  : >"$arena/data/workgraphs/.leases/v1/.transaction-lock"
  chmod 0600 "$arena/data/workgraphs/.leases/v1/namespace.json" "$arena/data/workgraphs/.leases/v1/fencing-counter" "$arena/data/workgraphs/.leases/v1/transaction-generation" "$arena/data/workgraphs/.leases/v1/.transaction-lock"
  jq --arg mode "$mode" '.claims=[{"resource":"path:///tmp/c2-resource","mode":$mode}]' "$C2_CONTRACT" >"$arena/contract.json"
  printf '%s\n' '{"schema_version":"resource-registry/v1","instances":[{"id":"c2-resource","namespace":"path","resource":"path:///tmp/c2-resource","aliases":[],"contains":[]}]}' >"$arena/registry.json"
  digest=$(sha256sum "$arena/contract.json" | awk '{print $1}')
  printf '%s\n' "{\"schema_version\":\"workgraph/v1\",\"goal_id\":\"g\",\"slices\":[{\"slice_id\":\"s\",\"contract_path\":\"contract.json\",\"contract_sha256\":\"$digest\"}]}" >"$arena/graph.json"
  chmod 0600 "$arena/contract.json" "$arena/registry.json" "$arena/graph.json"
}
c2_arena_use() {
  local arena=$1
  C2_HOME="$arena/home"
  C2_DATA="$arena/data"
  C2_STATE="$arena/state"
  C2_GRAPH="$arena/graph.json"
  C2_REGISTRY="$arena/registry.json"
  C2_STORE="$C2_DATA/workgraphs/.leases/v1"
}
c2_arena_manifest() {
  local arena=$1 output=$2
  roots_manifest "$arena/data" "$arena/state" "$output"
}
c2_arena_seed() {
  local label=$1
  c2_call "$label-seed" acquire "$C2_GRAPH" s --registry "$C2_REGISTRY" --lease-id seed --holder-id holder --holder-pid "$C2_HOLDER_PID"
  [ "$C2_RC" -eq 0 ] && [ ! -s "$C2_ERR" ] || fail "C2 $label seed"
}
c2_assert_no_orphans() {
  local store=$1 record_count event_count record token
  record_count=$(find "$store/records" -type f -name '*.json' | wc -l)
  event_count=$(find "$store/events" -type f -name '*.json' | wc -l)
  [ "$record_count" -eq "$event_count" ] || fail "C2 orphan event count"
  while IFS= read -r record; do
    token=$(jq -r '.holder_fencing_token' "$record")
    [ -f "$store/events/$(printf '%020d' "$token").json" ] || fail "C2 orphan record event"
  done < <(find "$store/records" -type f -name '1.json' | LC_ALL=C sort)
  [ -z "$(find "$store" -type f -name '.*.tmp.*' -print -quit)" ] || fail "C2 orphan temporary"
}
c2_assert_event_bindings() {
  local store=$1 event revision goal lease record digest
  while IFS= read -r event; do
    revision=$(jq -r '.record_revision' "$event")
    goal=$(jq -r '.goal_id' "$event")
    lease=$(jq -r '.lease_id' "$event")
    record="$store/records/$goal/$lease/$revision.json"
    [ -f "$record" ] || fail "C2 orphan event record"
    digest=$(sha256sum "$record" | awk '{print $1}')
    jq -e --arg digest "$digest" '.record_sha256==$digest' "$event" >/dev/null || fail "C2 event record binding"
  done < <(find "$store/events" -type f -name '*.json' | LC_ALL=C sort)
}
c2_arbitration_pair() {
  local arena=$1 label=$2
  python3 - "$C2_CANDIDATE" "$arena" "$label" "$C2_DRIVER_EVIDENCE" <<'PY_C2_ARBITRATION'
import os
import subprocess
import sys
import threading

candidate, arena, label, evidence = sys.argv[1:]
holder_pid = os.environ.get("C2_HOLDER_PID")
if not holder_pid:
    raise SystemExit("C2_HOLDER_PID missing")
command = [
    os.path.join(candidate, "bin/fm-workgraph-lease-lib.sh"), "acquire",
    os.path.join(arena, "graph.json"), "s", "--registry",
    os.path.join(arena, "registry.json"),
]
barrier = threading.Barrier(2)
results = {}

def contender(lane):
    stdout_path = os.path.join(evidence, f"{label}-{lane}.stdout")
    stderr_path = os.path.join(evidence, f"{label}-{lane}.stderr")
    argv = command + ["--lease-id", f"{label}-{lane}", "--holder-id", f"{label}-{lane}", "--holder-pid", holder_pid]
    env = os.environ.copy()
    env.update({
        "FM_HOME": os.path.join(arena, "home"),
        "FM_DATA_OVERRIDE": os.path.join(arena, "data"),
        "FM_STATE_OVERRIDE": os.path.join(arena, "state"),
    })
    barrier.wait()
    with open(stdout_path, "wb") as stdout, open(stderr_path, "wb") as stderr:
        process = subprocess.Popen(argv, stdout=stdout, stderr=stderr, env=env)
        results[lane] = process.wait()

threads = [threading.Thread(target=contender, args=(lane,)) for lane in ("a", "b")]
for thread in threads:
    thread.start()
for thread in threads:
    thread.join()
for lane in ("a", "b"):
    with open(os.path.join(evidence, f"{label}-{lane}.exit"), "w", encoding="ascii") as output:
        output.write(f"{results[lane]}\n")
with open(os.path.join(evidence, f"{label}-concurrent.commands"), "w", encoding="utf-8") as output:
    for lane in ("a", "b"):
        argv = command + ["--lease-id", f"{label}-{lane}", "--holder-id", f"{label}-{lane}", "--holder-pid", holder_pid]
        output.write("argv=" + " ".join(argv) + f" rc={results[lane]}\n")
PY_C2_ARBITRATION
}
c2_recovery_seed() {
  local arena=$1
  python3 - "$C2_CANDIDATE" "$arena" "$C2_DRIVER_EVIDENCE" <<'PY_C2_RECOVERY'
import os
import subprocess
import sys

candidate, arena, evidence = sys.argv[1:]
holder = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
prefix = os.path.join(evidence, "recovery-holder")
try:
    env = os.environ.copy()
    env.update({
        "FM_HOME": os.path.join(arena, "home"),
        "FM_DATA_OVERRIDE": os.path.join(arena, "data"),
        "FM_STATE_OVERRIDE": os.path.join(arena, "state"),
    })
    argv = [
        os.path.join(candidate, "bin/fm-workgraph-lease-lib.sh"), "acquire",
        os.path.join(arena, "graph.json"), "s", "--registry", os.path.join(arena, "registry.json"),
        "--lease-id", "seed", "--holder-id", "holder", "--holder-pid", str(holder.pid),
    ]
    with open(prefix + ".stdout", "wb") as stdout, open(prefix + ".stderr", "wb") as stderr:
        result = subprocess.run(argv, stdout=stdout, stderr=stderr, env=env, check=False)
    with open(prefix + ".exit", "w", encoding="ascii") as output:
        output.write(f"{result.returncode}\n")
    with open(prefix + ".commands", "w", encoding="utf-8") as output:
        output.write("argv=" + " ".join(argv) + f" rc={result.returncode}\n")
    if result.returncode != 0:
        raise SystemExit(result.returncode)
finally:
    holder.terminate()
    holder.wait()
with open(prefix + ".holder-exit", "w", encoding="ascii") as output:
    output.write(f"{holder.returncode}\n")
PY_C2_RECOVERY
  [ "$(cat "$C2_DRIVER_EVIDENCE/recovery-holder.exit")" = 0 ] || fail "C2 recovery holder acquire"
  [ ! -s "$C2_DRIVER_EVIDENCE/recovery-holder.stderr" ] || fail "C2 recovery holder stderr"
  [ "$(cat "$C2_DRIVER_EVIDENCE/recovery-holder.holder-exit")" -lt 0 ] || fail "C2 recovery holder termination"
}
c2_expect_read_pair() {
  local arena=$1 label=$2 tokens
  for lane in a b; do
    [ "$(cat "$C2_DRIVER_EVIDENCE/$label-$lane.exit")" = 0 ] || fail "C2 compatible winner $lane"
    [ ! -s "$C2_DRIVER_EVIDENCE/$label-$lane.stderr" ] || fail "C2 compatible stderr $lane"
    jq -e '.state=="held" and .holder_fencing_token != null' "$C2_DRIVER_EVIDENCE/$label-$lane.stdout" >/dev/null || fail "C2 compatible result $lane"
  done
  tokens=$(for lane in a b; do jq -r '.holder_fencing_token' "$C2_DRIVER_EVIDENCE/$label-$lane.stdout"; done | LC_ALL=C sort -n | paste -sd, -)
  local first=${tokens%,*} second=${tokens#*,}
  [ "$first" != "$second" ] && [ "$second" -eq $((first + 1)) ] || fail "C2 compatible tokens"
  c2_assert_no_orphans "$arena/data/workgraphs/.leases/v1"
}
c2_expect_conflict_pair() {
  local arena=$1 label=$2 success=0 conflict=0 lane
  for lane in a b; do
    case "$(cat "$C2_DRIVER_EVIDENCE/$label-$lane.exit")" in
      0)
        success=$((success + 1))
        [ ! -s "$C2_DRIVER_EVIDENCE/$label-$lane.stderr" ] || fail "C2 conflict winner stderr"
        jq -e '.state=="held" and .holder_fencing_token != null' "$C2_DRIVER_EVIDENCE/$label-$lane.stdout" >/dev/null || fail "C2 conflict winner result"
        ;;
      1)
        conflict=$((conflict + 1))
        [ ! -s "$C2_DRIVER_EVIDENCE/$label-$lane.stdout" ] || fail "C2 conflict loser stdout"
        grep -qx 'fm-workgraph: WG-L-E-CONFLICT: lease operation failed' "$C2_DRIVER_EVIDENCE/$label-$lane.stderr" || fail "C2 conflict loser code"
        ;;
      *) fail "C2 conflict loser exit" ;;
    esac
  done
  [ "$success" -eq 1 ] && [ "$conflict" -eq 1 ] || fail "C2 conflict arbitration count"
  c2_assert_no_orphans "$arena/data/workgraphs/.leases/v1"
}
c2_matrix_setup() {
  local id=$1 candidate=$2 case_root=$3 home=$4 data=$5 state=$6 graph=$7 registry=$8 evidence=$9
  c2_setup "$id" "$candidate" "$case_root" "$home" "$data" "$state" "$graph" "$registry" "$evidence"
  case "$id" in
    S5V3-TXN-BOOT)
      c2_acquire_seed
      jq -c '.state="held" | .boot_id="00000000-0000-0000-0000-000000000001"' "$C2_STORE/transaction-owner.json" >"$C2_CASE_ROOT/owner.tmp"
      mv "$C2_CASE_ROOT/owner.tmp" "$C2_STORE/transaction-owner.json"; chmod 0600 "$C2_STORE/transaction-owner.json"
      ;;
    S5V3-TXN-NO-TIME)
      c2_acquire_seed
      jq -c --argjson holder "$(jq -c '.holder_process' "$C2_STORE/records/g/seed/1.json")" '.state="held" | .pid=$holder.pid | .start_ticks=$holder.start_ticks | .cmdline_sha256=$holder.cmdline_sha256 | .boot_id=$holder.boot_id | .hostname=$holder.hostname' "$C2_STORE/transaction-owner.json" >"$C2_CASE_ROOT/owner.tmp"
      mv "$C2_CASE_ROOT/owner.tmp" "$C2_STORE/transaction-owner.json"; chmod 0600 "$C2_STORE/transaction-owner.json"
      find "$C2_DATA" "$C2_STATE" -type f -exec touch -d '1970-01-01 UTC' {} +
      ;;
    S5V3-TXN-LIVE-UNCERTAIN)
      c2_acquire_seed
      c2_call setup-uncertain-release release g --lease-id seed --holder-id holder --fencing-token 1
      [ "$C2_RC" -eq 0 ] || fail "C2 uncertain setup release"
      jq -c --argjson holder "$(jq -c '.holder_process' "$C2_STORE/records/g/seed/1.json")" '.state="held" | .pid=$holder.pid | .start_ticks=$holder.start_ticks | .cmdline_sha256=$holder.cmdline_sha256 | .boot_id=$holder.boot_id | .hostname="foreign-c2-host"' "$C2_STORE/transaction-owner.json" >"$C2_CASE_ROOT/owner.tmp"
      mv "$C2_CASE_ROOT/owner.tmp" "$C2_STORE/transaction-owner.json"; chmod 0600 "$C2_STORE/transaction-owner.json"
      ;;
    S5V3-TXN-SUPERIOR-GENERATION)
      c2_acquire_seed
      c2_call setup-superior-release release g --lease-id seed --holder-id holder --fencing-token 1
      [ "$C2_RC" -eq 0 ] || fail "C2 superior setup release"
      printf '%s\n' 4 >"$C2_STORE/transaction-generation"; chmod 0600 "$C2_STORE/transaction-generation"
      ;;
    S5V4-GENERATION-ZERO)
      c2_acquire_seed
      c2_call setup-zero-release release g --lease-id seed --holder-id holder --fencing-token 1
      [ "$C2_RC" -eq 0 ] || fail "C2 zero setup release"
      rm -rf "$C2_STORE/records" "$C2_STORE/events" "$C2_STATE/workgraphs"
      rm -f "$C2_STORE/transaction-owner.json"
      printf '0\n' >"$C2_STORE/transaction-generation"; printf '0\n' >"$C2_STORE/fencing-counter"
      chmod 0600 "$C2_STORE/transaction-generation" "$C2_STORE/fencing-counter"
      mkdir -m 0700 "$C2_STORE/records" "$C2_STORE/events"
      ;;
    S5V4-FRESH-LOCK-OPEN)
      c2_acquire_seed
      c2_call setup-fresh-release release g --lease-id seed --holder-id holder --fencing-token 1
      [ "$C2_RC" -eq 0 ] || fail "C2 fresh setup release"
      ;;
    S5V4-TRANSACTION-CROSS-FILE)
      c2_acquire_seed
      c2_call setup-cross-release release g --lease-id seed --holder-id holder --fencing-token 1
      [ "$C2_RC" -eq 0 ] || fail "C2 cross setup release"
      ;;
    S5V1-06|S5V1-07)
      :
      ;;
    *) fail "C2 setup id $id" ;;
  esac
}
c2_matrix_action() {
  local id=$1 candidate=$2 case_root=$3 evidence=$4
  [ "$candidate" = "$C2_CANDIDATE" ] && [ "$case_root" = "$C2_CASE_ROOT" ] && [ "$evidence" = "$C2_DRIVER_EVIDENCE" ] || fail "C2 action binding"
  case "$id" in
    S5V3-TXN-BOOT) c2_case_S5V3_TXN_BOOT ;;
    S5V3-TXN-NO-TIME) c2_case_S5V3_TXN_NO_TIME ;;
    S5V3-TXN-LIVE-UNCERTAIN) c2_case_S5V3_TXN_LIVE_UNCERTAIN ;;
    S5V3-TXN-SUPERIOR-GENERATION) c2_case_S5V3_TXN_SUPERIOR_GENERATION ;;
    S5V4-GENERATION-ZERO) c2_case_S5V4_GENERATION_ZERO ;;
    S5V4-FRESH-LOCK-OPEN) c2_case_S5V4_FRESH_LOCK_OPEN ;;
    S5V4-TRANSACTION-CROSS-FILE) c2_case_S5V4_TRANSACTION_CROSS_FILE ;;
    S5V1-06) c2_case_S5V1_06 ;;
    S5V1-07) c2_case_S5V1_07 ;;
    *) fail "C2 action id $id" ;;
  esac
  printf 'c2_case=%s\n' "$id"
}

 c2_case_S5V3_TXN_BOOT() {
  local owner="$C2_STORE/transaction-owner.json" before after
  before="$C2_CASE_ROOT/before.manifest"; after="$C2_CASE_ROOT/after.manifest"
  c2_manifest "$before"
  c2_call boot-release release g --lease-id seed --holder-id holder --fencing-token 1
  [ "$C2_RC" -eq 0 ] && [ ! -s "$C2_ERR" ] || fail "C2 boot identity release"
  c2_manifest "$after"; if cmp "$before" "$after" >/dev/null; then fail "C2 boot success did not mutate"; fi
  jq -e '.state=="released" and .generation=="2"' "$owner" >/dev/null || fail "C2 boot released owner"
  local expected_boot actual_boot
  expected_boot=$(tr -d '\n' < /proc/sys/kernel/random/boot_id)
  actual_boot=$(jq -r '.boot_id' "$owner")
  [ "$actual_boot" = "$expected_boot" ] || fail "C2 boot published owner boot id"
  jq -e --arg boot "$expected_boot" '.holder_process.boot_id==$boot' "$C2_STORE/records/g/seed/2.json" >/dev/null || fail "C2 boot published holder boot id"
  c2_call boot-status status g; [ "$C2_RC" -eq 0 ] && [ ! -s "$C2_ERR" ] || fail "C2 boot reopen"
  cp "$C2_OUT" "$C2_CASE_ROOT/boot-status.first"
  c2_call boot-status-repeat status g; [ "$C2_RC" -eq 0 ] && [ ! -s "$C2_ERR" ] || fail "C2 boot repeat reopen"
  cmp "$C2_OUT" "$C2_CASE_ROOT/boot-status.first" >/dev/null || fail "C2 boot nondeterministic reopen"
  c2_finish S5V3-TXN-BOOT
}

 c2_case_S5V3_TXN_NO_TIME() {
  local before="$C2_CASE_ROOT/before.manifest" after="$C2_CASE_ROOT/after.manifest"
  c2_manifest "$before"
  c2_call no-time status g
  c2_expect_code STORE
  c2_manifest "$after"; c2_same "$before" "$after"
  c2_trace "live_holder=STORE durable_mtime=1970-01-01 ttl=none expiry=none heartbeat=none action=0"
  c2_finish S5V3-TXN-NO-TIME
}

 c2_case_S5V3_TXN_LIVE_UNCERTAIN() {
  local owner="$C2_STORE/transaction-owner.json" before after
  before="$C2_CASE_ROOT/before.manifest"; after="$C2_CASE_ROOT/after.manifest"
  c2_manifest "$before"
  c2_call uncertain acquire "$C2_GRAPH" s --registry "$C2_REGISTRY" --lease-id contender --holder-id contender --holder-pid "$C2_HOLDER_PID"
  c2_expect_code STORE
  c2_manifest "$after"; c2_same "$before" "$after"
  c2_trace "foreign hostname=STORE ttl=none redispatch=none action=0"
  c2_finish S5V3-TXN-LIVE-UNCERTAIN
}

 c2_case_S5V3_TXN_SUPERIOR_GENERATION() {
  c2_call superior-acquire acquire "$C2_GRAPH" s --registry "$C2_REGISTRY" --lease-id successor --holder-id successor --holder-pid "$C2_HOLDER_PID"
  [ "$C2_RC" -eq 0 ] && [ ! -s "$C2_ERR" ] || fail "C2 superior generation acquire"
  jq -e '.state=="held" and .transaction_generation=="5"' "$C2_STORE/records/g/successor/1.json" >/dev/null || fail "C2 superior record generation"
  [ "$(cat "$C2_STORE/transaction-generation")" = "5" ] || fail "C2 superior generation bytes"
  c2_trace "gap=4 owner=2 successor=5 action=1"
  c2_finish S5V3-TXN-SUPERIOR-GENERATION
}

 c2_case_S5V4_GENERATION_ZERO() {
  c2_call zero-status status g
  [ "$C2_RC" -eq 0 ] && [ ! -s "$C2_ERR" ] || fail "C2 generation zero status"
  grep -qx 'lease_store=ready' <(head -1 "$C2_OUT") || fail "C2 generation zero ready"
  c2_call zero-acquire acquire "$C2_GRAPH" s --registry "$C2_REGISTRY" --lease-id zero --holder-id holder --holder-pid "$C2_HOLDER_PID"
  [ "$C2_RC" -eq 0 ] || fail "C2 generation zero acquire"
  jq -e '.transaction_generation=="1"' "$C2_STORE/records/g/zero/1.json" >/dev/null || fail "C2 generation zero successor"
  jq -c '.generation="0"' "$C2_STORE/transaction-owner.json" >"$C2_CASE_ROOT/owner-zero.tmp"
  mv "$C2_CASE_ROOT/owner-zero.tmp" "$C2_STORE/transaction-owner.json"; chmod 0600 "$C2_STORE/transaction-owner.json"
  c2_call zero-owner status g; c2_expect_code SCHEMA
  c2_trace "fresh_generation=0 owner_generation=0=SCHEMA successor=1"
  c2_finish S5V4-GENERATION-ZERO
}

 c2_case_S5V4_FRESH_LOCK_OPEN() {
  local lock="$C2_STORE/.transaction-lock" inode
  inode=$(stat -c '%d:%i:%a:%h' "$lock")
  c2_call fresh-second acquire "$C2_GRAPH" s --registry "$C2_REGISTRY" --lease-id second --holder-id holder2 --holder-pid "$C2_HOLDER_PID"
  if ! { [ "$C2_RC" -eq 0 ] && [ ! -s "$C2_ERR" ]; }; then
    printf 'C2 fresh diagnostic rc=%s stdout=%s stderr=%s\n' "$C2_RC" "$(cat "$C2_OUT")" "$(cat "$C2_ERR")" >&2
    fail "C2 fresh open second writer"
  fi
  [ "$(stat -c '%d:%i:%a:%h' "$lock")" = "$inode" ] || fail "C2 fresh lock identity"
  [ "$(find "$C2_STORE" -maxdepth 1 -name '.transaction-lock' | wc -l)" -eq 1 ] || fail "C2 duplicate lock path"
  c2_call fresh-status status g; [ "$C2_RC" -eq 0 ] && [ ! -s "$C2_ERR" ] || fail "C2 fresh reopen"
  c2_trace "lock=$inode writers=2 flock=one-shot path-count=1"
  c2_finish S5V4-FRESH-LOCK-OPEN
}

c2_case_S5V4_TRANSACTION_CROSS_FILE() {
  local record="$C2_STORE/records/g/seed/2.json" event="$C2_STORE/events/00000000000000000002.json" digest before after
  c2_assert_no_orphans "$C2_STORE"
  c2_assert_event_bindings "$C2_STORE"
  jq -c '.state="recovered" | .terminal={"kind":"recover","actor_id":"","proof":"pid-absent"}' "$record" >"$C2_DRIVER_EVIDENCE/record.tmp"
  digest=$(sha256sum "$C2_DRIVER_EVIDENCE/record.tmp" | awk '{print $1}')
  mv "$C2_DRIVER_EVIDENCE/record.tmp" "$record"; chmod 0600 "$record"
  jq -c --arg digest "$digest" '.event="recover" | .proof="pid-absent" | .record_sha256=$digest' "$event" >"$C2_DRIVER_EVIDENCE/event.tmp"
  mv "$C2_DRIVER_EVIDENCE/event.tmp" "$event"; chmod 0600 "$event"
  before="$C2_DRIVER_EVIDENCE/cross-injected.before"; after="$C2_DRIVER_EVIDENCE/cross-injected.after"
  c2_manifest "$before"; c2_call cross-status status g; c2_expect_code NOT-RECONSTRUCTABLE; c2_manifest "$after"; c2_same "$before" "$after"
  c2_trace "recovered_empty_actor=NOT-RECONSTRUCTABLE cross_file=zero_mutation"
  c2_finish S5V4-TRANSACTION-CROSS-FILE
}

 c2_case_S5V1_06() {
  local arena="$C2_DRIVER_EVIDENCE/06-compatible" recovery="$C2_DRIVER_EVIDENCE/06-recovery" conflict="$C2_DRIVER_EVIDENCE/06-conflict"
  c2_arena_make "$arena" read
  c2_arena_use "$arena"; c2_arena_seed compatible-setup
  c2_call compatible-setup-release release g --lease-id seed --holder-id holder --fencing-token 1
  [ "$C2_RC" -eq 0 ] || fail "C2 compatible setup release"
  c2_arbitration_pair "$arena" compatible
  c2_expect_read_pair "$arena" compatible
  c2_arena_make "$conflict" exclusive
  c2_arena_use "$conflict"; c2_arena_seed conflict-setup
  c2_call conflict-setup-release release g --lease-id seed --holder-id holder --fencing-token 1
  [ "$C2_RC" -eq 0 ] || fail "C2 conflict setup release"
  c2_arbitration_pair "$conflict" conflicting
  c2_expect_conflict_pair "$conflict" conflicting
  c2_arena_make "$recovery" exclusive
  c2_arena_use "$recovery"
  c2_recovery_seed "$recovery"
  c2_assert_no_orphans "$C2_STORE"
  local before="$C2_DRIVER_EVIDENCE/recovery.before" after="$C2_DRIVER_EVIDENCE/recovery.after"
  c2_arena_manifest "$recovery" "$before"
  c2_call recovery-loser acquire "$C2_GRAPH" s --registry "$C2_REGISTRY" --lease-id contender --holder-id contender --holder-pid "$$"
  c2_expect_code RECOVERY-REQUIRED
  c2_arena_manifest "$recovery" "$after"; cmp "$before" "$after" >/dev/null || fail "C2 recovery loser mutation"
  c2_trace "concurrent_arbitration=compatible_winners:2 unique_increasing_tokens conflicting=winner:1_loser:CONFLICT recovery=RECOVERY-REQUIRED orphan_files=0"
  c2_finish S5V1-06
}

c2_case_S5V1_07() {
  local arena before after
  arena="$C2_DRIVER_EVIDENCE/07-owner"
  c2_arena_make "$arena" exclusive; c2_arena_use "$arena"; c2_arena_seed owner
  c2_arena_manifest "$arena" "$C2_DRIVER_EVIDENCE/07-owner.before"
  c2_call wrong-owner release g --lease-id seed --holder-id wrong --fencing-token 1; c2_expect_code OWNER
  c2_arena_manifest "$arena" "$C2_DRIVER_EVIDENCE/07-owner.after"; c2_same "$C2_DRIVER_EVIDENCE/07-owner.before" "$C2_DRIVER_EVIDENCE/07-owner.after"

  arena="$C2_DRIVER_EVIDENCE/07-reused"; c2_arena_make "$arena" exclusive; c2_arena_use "$arena"; c2_arena_seed reused
  c2_arena_manifest "$arena" "$C2_DRIVER_EVIDENCE/07-reused.before"
  c2_call reused-id acquire "$C2_GRAPH" s --registry "$C2_REGISTRY" --lease-id seed --holder-id second --holder-pid "$C2_HOLDER_PID"; c2_expect_code LEASE-ID-REUSED
  c2_arena_manifest "$arena" "$C2_DRIVER_EVIDENCE/07-reused.after"; c2_same "$C2_DRIVER_EVIDENCE/07-reused.before" "$C2_DRIVER_EVIDENCE/07-reused.after"

  arena="$C2_DRIVER_EVIDENCE/07-token"; c2_arena_make "$arena" read; c2_arena_use "$arena"; c2_arena_seed token
  c2_call token-second acquire "$C2_GRAPH" s --registry "$C2_REGISTRY" --lease-id second --holder-id holder2 --holder-pid "$C2_HOLDER_PID"; [ "$C2_RC" -eq 0 ] || fail "C2 token second seed"
  c2_arena_manifest "$arena" "$C2_DRIVER_EVIDENCE/07-token.before"
  c2_call lower-token release g --lease-id second --holder-id holder2 --fencing-token 1; c2_expect_code TOKEN
  c2_call higher-token release g --lease-id second --holder-id holder2 --fencing-token 3; c2_expect_code TOKEN
  c2_call owner-token-collision release g --lease-id seed --holder-id wrong --fencing-token 2; c2_expect_code OWNER
  c2_arena_manifest "$arena" "$C2_DRIVER_EVIDENCE/07-token.after"; c2_same "$C2_DRIVER_EVIDENCE/07-token.before" "$C2_DRIVER_EVIDENCE/07-token.after"

  arena="$C2_DRIVER_EVIDENCE/07-state"; c2_arena_make "$arena" exclusive; c2_arena_use "$arena"; c2_arena_seed state
  c2_call terminal-release release g --lease-id seed --holder-id holder --fencing-token 1; [ "$C2_RC" -eq 0 ] || fail "C2 terminal setup release"
  c2_arena_manifest "$arena" "$C2_DRIVER_EVIDENCE/07-state.before"
  c2_call terminal-fence fence g --lease-id seed --holder-id holder --fencing-token 2; c2_expect_code STATE
  c2_arena_manifest "$arena" "$C2_DRIVER_EVIDENCE/07-state.after"; c2_same "$C2_DRIVER_EVIDENCE/07-state.before" "$C2_DRIVER_EVIDENCE/07-state.after"

  arena="$C2_DRIVER_EVIDENCE/07-malformed"; c2_arena_make "$arena" exclusive; c2_arena_use "$arena"; c2_arena_seed malformed
  printf '%s\n' -1 >"$C2_STORE/transaction-generation"; chmod 0600 "$C2_STORE/transaction-generation"
  c2_arena_manifest "$arena" "$C2_DRIVER_EVIDENCE/07-malformed.before"
  c2_call malformed-authority status g; c2_expect_code NOT-RECONSTRUCTABLE
  c2_arena_manifest "$arena" "$C2_DRIVER_EVIDENCE/07-malformed.after"; c2_same "$C2_DRIVER_EVIDENCE/07-malformed.before" "$C2_DRIVER_EVIDENCE/07-malformed.after"

  arena="$C2_DRIVER_EVIDENCE/07-schema"; c2_arena_make "$arena" exclusive; c2_arena_use "$arena"; c2_arena_seed schema
  printf '%s\n' -1 >"$C2_STORE/transaction-generation"
  jq '.generation="0"' "$C2_STORE/transaction-owner.json" >"$C2_DRIVER_EVIDENCE/schema-owner.tmp"
  mv "$C2_DRIVER_EVIDENCE/schema-owner.tmp" "$C2_STORE/transaction-owner.json"; chmod 0600 "$C2_STORE/transaction-generation" "$C2_STORE/transaction-owner.json"
  c2_arena_manifest "$arena" "$C2_DRIVER_EVIDENCE/07-schema.before"
  c2_call schema-authority status g; c2_expect_code SCHEMA
  c2_arena_manifest "$arena" "$C2_DRIVER_EVIDENCE/07-schema.after"; c2_same "$C2_DRIVER_EVIDENCE/07-schema.before" "$C2_DRIVER_EVIDENCE/07-schema.after"
  c2_trace "OWNER> TOKEN> STATE; LEASE-ID-REUSED; malformed=NOT-RECONSTRUCTABLE; owner-generation-zero=SCHEMA; zero_mutation=all"
  c2_finish S5V1-07
}

matrix_case_S5V3_TXN_BOOT() { run_matrix_case_body S5V3-TXN-BOOT "$1" "$2"; }
matrix_case_S5V3_TXN_NO_TIME() { run_matrix_case_body S5V3-TXN-NO-TIME "$1" "$2"; }
matrix_case_S5V3_TXN_LIVE_UNCERTAIN() { run_matrix_case_body S5V3-TXN-LIVE-UNCERTAIN "$1" "$2"; }
matrix_case_S5V3_TXN_SUPERIOR_GENERATION() { run_matrix_case_body S5V3-TXN-SUPERIOR-GENERATION "$1" "$2"; }
matrix_case_S5V4_GENERATION_ZERO() { run_matrix_case_body S5V4-GENERATION-ZERO "$1" "$2"; }
matrix_case_S5V4_FRESH_LOCK_OPEN() { run_matrix_case_body S5V4-FRESH-LOCK-OPEN "$1" "$2"; }
matrix_case_S5V4_TRANSACTION_CROSS_FILE() { run_matrix_case_body S5V4-TRANSACTION-CROSS-FILE "$1" "$2"; }
matrix_case_S5V1_06() { run_matrix_case_body S5V1-06 "$1" "$2"; }
matrix_case_S5V1_07() { run_matrix_case_body S5V1-07 "$1" "$2"; }

matrix_case_S5V1_02() { run_matrix_case_body S5V1-02 "$1" "$2"; }
matrix_case_S5V1_03() { run_matrix_case_body S5V1-03 "$1" "$2"; }
matrix_case_S5V1_11() { run_matrix_case_body S5V1-11 "$1" "$2"; }
matrix_case_S5V1_04() { run_matrix_case_body S5V1-04 "$1" "$2"; }
matrix_case_S5V1_05() { run_matrix_case_body S5V1-05 "$1" "$2"; }
matrix_case_S5V3_BOOT_ID_BYTES() { run_matrix_case_body S5V3-BOOT-ID-BYTES "$1" "$2"; }
matrix_case_S5V3_UNSUPPORTED_IDENTITY() { run_matrix_case_body S5V3-UNSUPPORTED-IDENTITY "$1" "$2"; }
matrix_case_S5V4_COUNTER_FLOOR() { run_matrix_case_body S5V4-COUNTER-FLOOR "$1" "$2"; }
matrix_case_S5V1_08() { run_matrix_case_body S5V1-08 "$1" "$2"; }
matrix_case_S5V1_09() { run_matrix_case_body S5V1-09 "$1" "$2"; }
matrix_case_S5V1_12() { run_matrix_case_body S5V1-12 "$1" "$2"; }
matrix_case_S5V3_ACQUIRE_DEAD_SPLIT() { run_matrix_case_body S5V3-ACQUIRE-DEAD-SPLIT "$1" "$2"; }
matrix_case_S5V3_ORPHAN_CACHE_STATUS() { run_matrix_case_body S5V3-ORPHAN-CACHE-STATUS "$1" "$2"; }
matrix_case_S5V3_READBACK_ONCE() { run_matrix_case_body S5V3-READBACK-ONCE "$1" "$2"; }
matrix_case_S5V3_READBACK_BYTE_TYPE_METADATA_ERROR() { run_matrix_case_body S5V3-READBACK-BYTE-TYPE-METADATA-ERROR "$1" "$2"; }
matrix_case_S5V3_TERMINAL_RECOVER() { run_matrix_case_body S5V3-TERMINAL-RECOVER "$1" "$2"; }
matrix_case_S5V3_TERMINAL_RELEASE_FENCE() { run_matrix_case_body S5V3-TERMINAL-RELEASE-FENCE "$1" "$2"; }
matrix_case_S5V3_RELEASE_DIFFERENT_PID() { run_matrix_case_body S5V3-RELEASE-DIFFERENT-PID "$1" "$2"; }
matrix_case_S5V3_EXACT_SUCCESS_BYTES() { run_matrix_case_body S5V3-EXACT-SUCCESS-BYTES "$1" "$2"; }
matrix_case_S5V3_INSPECT_HISTORY_ORDER() { run_matrix_case_body S5V3-INSPECT-HISTORY-ORDER "$1" "$2"; }
matrix_case_S5V3_STATUS_GOAL_SCOPE() { run_matrix_case_body S5V3-STATUS-GOAL-SCOPE "$1" "$2"; }
matrix_case_S5V3_COUNTER_RECONSTRUCTION() { run_matrix_case_body S5V3-COUNTER-RECONSTRUCTION "$1" "$2"; }
matrix_case_S5V3_EVENT_RECORD_INVARIANTS() { run_matrix_case_body S5V3-EVENT-RECORD-INVARIANTS "$1" "$2"; }
matrix_case_S5V1_10() { run_matrix_case_body S5V1-10 "$1" "$2"; }
matrix_case_S5V1_13() { run_matrix_case_body S5V1-13 "$1" "$2"; }
matrix_case_S5V3_CRASH_EACH_PUBLICATION() { run_matrix_case_body S5V3-CRASH-EACH-PUBLICATION "$1" "$2"; }
matrix_case_S5V4_IMMUTABLE_REVISION_HISTORY() { run_matrix_case_body S5V4-IMMUTABLE-REVISION-HISTORY "$1" "$2"; }
matrix_case_S5V4_PUBLICATION_SUB_BOUNDARIES() { run_matrix_case_body S5V4-PUBLICATION-SUB-BOUNDARIES "$1" "$2"; }
matrix_case_S5V4_TARGET_ONLY_REPAIR() { run_matrix_case_body S5V4-TARGET-ONLY-REPAIR "$1" "$2"; }
matrix_case_S5V1_01() { run_matrix_case_body S5V1-01 "$1" "$2"; }
matrix_case_S5V1_14() { run_matrix_case_body S5V1-14 "$1" "$2"; }
matrix_case_S5V1_15() { run_matrix_case_body S5V1-15 "$1" "$2"; }
matrix_case_S5V3_SLICE4_BYTE_ORACLE() { run_matrix_case_body S5V3-SLICE4-BYTE-ORACLE "$1" "$2"; }
matrix_case_S5V3_OUTPUT_MANIFEST() { run_matrix_case_body S5V3-OUTPUT-MANIFEST "$1" "$2"; }
matrix_case_S5V4_CACHE_CANONICAL_BYTES() { run_matrix_case_body S5V4-CACHE-CANONICAL-BYTES "$1" "$2"; }
matrix_case_S5V4_EVIDENCE_SERIALIZATION() { run_matrix_case_body S5V4-EVIDENCE-SERIALIZATION "$1" "$2"; }
matrix_case_S5V4_ORACLE_ROOTS() { run_matrix_case_body S5V4-ORACLE-ROOTS "$1" "$2"; }
run_matrix_case() {
  local id=$1 case_index=$2 matrix_pass=$3
  local function_name
  function_name="matrix_case_${id//-/_}"
  if ! declare -F "$function_name" >/dev/null 2>&1; then
    fail "unmigrated sealed matrix id: $id"
  fi
  "$function_name" "$case_index" "$matrix_pass"
}
if [ "$MATRIX_CASE_MODE" -eq 1 ]; then
  MATRIX_RERUN_ROOT="$TMP_ROOT/rerun"
  mkdir -p "$MATRIX_RERUN_ROOT/evidence"
  matrix_extract_candidate "$MATRIX_RERUN_ROOT" "$MATRIX_RERUN_ROOT/evidence/candidate-input.json"
  run_matrix_case "$MATRIX_CASE_ID" 1 single
  matrix_case_evidence="$MATRIX_RERUN_ROOT/evidence/cases/$MATRIX_CASE_ID"
  matrix_output_evidence="$MATRIX_OUT/evidence/$MATRIX_CASE_ID"
  mkdir -p "$matrix_output_evidence"
  chmod 0700 "$MATRIX_OUT/evidence" "$matrix_output_evidence"
  cp "$matrix_case_evidence"/* "$matrix_output_evidence/"
  chmod 0600 "$matrix_output_evidence"/*
  exit 0
fi
for matrix_pass in 1 2; do
  MATRIX_RERUN_ROOT="$TMP_ROOT/rerun-$matrix_pass"
  mkdir -p "$MATRIX_RERUN_ROOT/evidence"
  matrix_extract_candidate "$MATRIX_RERUN_ROOT" "$MATRIX_RERUN_ROOT/evidence/candidate-input.json"
  : >"$MATRIX_RERUN_ROOT/evidence/cases.txt"
  for matrix_id in $MATRIX_IDS; do printf '%s\n' "$matrix_id" >>"$MATRIX_RERUN_ROOT/evidence/cases.txt"; done
  matrix_index=0
  while IFS= read -r matrix_id; do
    matrix_index=$((matrix_index + 1))
    run_matrix_case "$matrix_id" "$matrix_index" "$matrix_pass"
  done <"$MATRIX_RERUN_ROOT/evidence/cases.txt"
  run_manifest union "$MATRIX_RERUN_ROOT/evidence/filesystem-before.sha256" before
  run_manifest union "$MATRIX_RERUN_ROOT/evidence/filesystem-after.sha256" after
  run_manifest union "$MATRIX_RERUN_ROOT/evidence/filesystem-after.normalized.sha256" after.normalized
  required_cases=$(printf '%s\n' "$MATRIX_IDS" | wc -w | tr -d ' ')
  executed_cases=$matrix_index
  [ "$executed_cases" -eq "$required_cases" ] || fail "matrix refused unexecuted IDs"
  printf '%s\n' "{\"schema_version\":\"lease-test-evidence/v1\",\"required_cases\":\"$required_cases\",\"passed_cases\":\"$executed_cases\",\"failed_cases\":\"0\"}" >"$MATRIX_RERUN_ROOT/evidence/summary.json"
  (cd "$MATRIX_RERUN_ROOT/evidence" && LC_ALL=C find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum | sed 's#  ./#  #') >"$MATRIX_RERUN_ROOT/evidence/SHA256SUMS"
done
for normalized_path in candidate-input.json cases.txt filesystem-after.normalized.sha256 summary.json; do
  cmp "$TMP_ROOT/rerun-1/evidence/$normalized_path" "$TMP_ROOT/rerun-2/evidence/$normalized_path" || fail "normalized rerun equality $normalized_path"
done
while IFS= read -r matrix_id; do
  for normalized_path in stdout.normalized.bin stderr.normalized.bin exit.txt mutations.normalized.txt authority.normalized.json; do
    cmp "$TMP_ROOT/rerun-1/evidence/cases/$matrix_id/$normalized_path" "$TMP_ROOT/rerun-2/evidence/cases/$matrix_id/$normalized_path" || fail "normalized rerun equality $matrix_id/$normalized_path"
  done
done <"$TMP_ROOT/rerun-1/evidence/cases.txt"
ok "sealed 47-case matrix evidence inventory generated twice"
