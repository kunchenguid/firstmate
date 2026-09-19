#!/usr/bin/env bash
# Public scaffold, link, validator, archive and brief contracts with local tasks.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-alignment)
trap 'rm -rf "$TMP_ROOT"' EXIT
export FM_HOME="$TMP_ROOT/home"
unset FM_DATA_OVERRIDE FM_ROOT_OVERRIDE FM_STATE_OVERRIDE
mkdir -p "$FM_HOME/data" "$FM_HOME/config" "$TMP_ROOT/bin"
export PATH="$TMP_ROOT/bin:$PATH"
# A public tasks-axi fixture preserves arbitrary existing body text and exposes
# the same JSON-encoded scalar that the real show --full contract uses.
cat > "$TMP_ROOT/bin/tasks-axi" <<'FAKE'
#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
if args[0] in ('--version', '-v', '-V'):
    print('tasks-axi 0.12.0'); sys.exit()
p = pathlib.Path(os.environ['FM_HOME']) / 'data' / (args[1] + '.json')
if args[0] == 'show':
    print('task:\n  body: ' + json.dumps(p.read_text()))
elif args[0] == 'update':
    p.write_text(args[args.index('--body') + 1])
else:
    sys.exit(1)
FAKE
chmod +x "$TMP_ROOT/bin/tasks-axi"
tool="$ROOT/bin/fm-alignment.sh"
key=2026-09-19-test
printf 'Preserve the intended outcome.\n' > "$TMP_ROOT/ask"
printf 'Original notes.\n' > "$FM_HOME/data/one.json"
printf 'Other notes.\n' > "$FM_HOME/data/two.json"
printf 'alignment: marker for fixture lookup\n' > "$FM_HOME/data/backlog.md"
refuses() {
  if "$@" > "$TMP_ROOT/result" 2>&1; then
    echo "unexpected success: $*" >&2; exit 1
  fi
}
"$tool" validate
"$tool" create "$key" "$TMP_ROOT/ask"
"$tool" validate
refuses "$tool" create "$key" "$TMP_ROOT/ask"
refuses "$tool" create ../escape "$TMP_ROOT/ask"
refuses "$tool" create 2026-02-30-bad "$TMP_ROOT/ask"
refuses "$tool" validate --ready "$key"
"$tool" link "$key" one direct-PR
"$tool" link "$key" two scout
"$tool" link "$key" one direct-PR
python3 - "$FM_HOME" "$key" <<'PY'
import pathlib, sys
home, key = pathlib.Path(sys.argv[1]), sys.argv[2]
assert (home/'data/one.json').read_text() == 'Original notes.\n\nalignment: ' + key
p = home/'data/alignments'/key
for name, status in [('spec', 'aligned'), ('plan', 'approved')]:
    file = p/(name+'.md')
    file.write_text(file.read_text().replace('status: draft', 'status: '+status))
PY
"$tool" validate --ready "$key"
# Brief integration emits both pointer and PR citation, never into intent.
"$ROOT/bin/fm-brief.sh" one demo --mode direct-PR --alignment "$key" >/dev/null
grep -qx "alignment: $key" "$FM_HOME/data/one/brief.md"
grep -q "spec: $key" "$FM_HOME/data/one/brief.md"
"$tool" validate --intake one
refuses "$tool" validate --task one
refuses "$tool" archive "$key"
refuses "$tool" delivered "$key" one not-a-url
"$tool" delivered "$key" one https://github.com/example/repo/pull/1
"$tool" validate --task one
refuses "$tool" archive "$key"
refuses "$tool" delivered "$key" two missing/report.md
mkdir -p "$FM_HOME/data/two"
printf 'Findings\n' > "$FM_HOME/data/two/report.md"
"$tool" delivered "$key" two two/report.md
refuses "$tool" validate --task two
"$tool" archive "$key"
"$tool" validate
"$tool" validate --task one
"$tool" validate --task two
refuses "$tool" create "$key" "$TMP_ROOT/ask"
# Broken index and decision references stop validation.
cp "$FM_HOME/data/alignments/index.md" "$TMP_ROOT/index"
printf 'broken\n' > "$FM_HOME/data/alignments/index.md"
refuses "$tool" validate --task one
cp "$TMP_ROOT/index" "$FM_HOME/data/alignments/index.md"
archive=$(find "$FM_HOME/data/alignments/archive" -name plan.md)
printf '\ndecision: D99\n' >> "$archive"
refuses "$tool" validate
# Grandfather homes with no pointers do not need tasks-axi or alignment records.
export FM_HOME="$TMP_ROOT/legacy"
mkdir -p "$FM_HOME/data"
printf 'legacy backlog\n' > "$FM_HOME/data/backlog.md"
"$tool" validate --task old
# Local-only evidence and placement checks.
printf 'local notes\n' > "$FM_HOME/data/local.json"
"$tool" create "$key" "$TMP_ROOT/ask"
"$tool" link "$key" local local-only
refuses "$tool" delivered "$key" local local:abc
"$tool" delivered "$key" local local:0123456789012345678901234567890123456789
cp "$FM_HOME/data/alignments/$key/spec.md" "$FM_HOME/data/spec.md"
refuses "$tool" validate
rm "$FM_HOME/data/spec.md"
ln -s "$TMP_ROOT/ask" "$FM_HOME/data/alignments/$key/extra"
# Invalid decision and work-item links already tested; symlink spec is refused.
rm "$FM_HOME/data/alignments/$key/spec.md"
ln -s "$TMP_ROOT/ask" "$FM_HOME/data/alignments/$key/spec.md"
refuses "$tool" validate
printf 'ok - alignment records and completion contracts\n'
