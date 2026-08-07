#!/usr/bin/env bash
# Behavior tests for capabilities/catalog.json - the typed capability catalog.
#
# The catalog is data with no runtime, so the guarantee under test is the data's
# own contract rather than any executing code:
#   (a) every capability names an owner file that exists in this repo
#   (b) network.request is the ONE deliberately unowned row, and it is
#       captain-required
#   (c) every authority_class is a value already in loopspecs/schema.json's
#       validated enum, so the catalog never grows a second vocabulary
#   (d) the not-a-security-boundary certification is present and says what it
#       must - the catalog constrains a mistaken agent, not a hostile one
#
# Each check runs against a MUTATED copy first and must fail there, so a pass on
# the real catalog is evidence the check fires rather than evidence it is
# vacuous. Every verifier path is pinned the same way: a row may name only a
# check that exists.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CATALOG="$ROOT/capabilities/catalog.json"
SCHEMA="$ROOT/loopspecs/schema.json"

command -v python3 >/dev/null 2>&1 || fail "capability catalog: python3 is required to read the catalog"

# check <what> <catalog-path> - echoes one violation per line, exits 0 always.
# The single validator both the real catalog and every mutated control run
# through, so a negative control exercises the same code path as the real check.
check() {
  local what=$1 path=$2
  python3 - "$what" "$path" "$ROOT" "$SCHEMA" <<'PY'
import json, os, sys

what, path, root, schema_path = sys.argv[1:5]

def out(msg):
    print(msg)

try:
    with open(path) as fh:
        cat = json.load(fh)
except Exception as exc:  # unreadable or malformed is a violation, never an empty pass
    out("catalog unreadable: %s" % exc)
    sys.exit(0)

caps = cat.get("capabilities")
if not isinstance(caps, list) or not caps:
    out("catalog has no capabilities list")
    sys.exit(0)

if what == "owners":
    for cap in caps:
        name = cap.get("name", "<unnamed>")
        owner = cap.get("owner")
        if name == "network.request":
            continue
        if not owner:
            out("%s has no owner" % name)
        elif not os.path.exists(os.path.join(root, owner)):
            out("%s owner does not exist: %s" % (name, owner))

elif what == "verifiers":
    for cap in caps:
        name = cap.get("name", "<unnamed>")
        verifier = cap.get("verifier")
        if name == "network.request":
            continue
        if not verifier:
            out("%s has no verifier" % name)
        elif not os.path.exists(os.path.join(root, verifier)):
            out("%s verifier does not exist: %s" % (name, verifier))

elif what == "unowned":
    rows = [c for c in caps if c.get("name") == "network.request"]
    if len(rows) != 1:
        out("expected exactly one network.request row, found %d" % len(rows))
    else:
        row = rows[0]
        if row.get("owner") is not None:
            out("network.request must stay unowned, found owner: %r" % row["owner"])
        if row.get("authority_class") != "captain-required":
            out("network.request must be captain-required, found: %r"
                % row.get("authority_class"))
    unowned = [c.get("name") for c in caps
               if c.get("name") != "network.request" and not c.get("owner")]
    for name in unowned:
        out("%s is unowned but only network.request may be" % name)

elif what == "enum":
    with open(schema_path) as fh:
        allowed = json.load(fh)["enums"]["authority_class"]
    declared = cat.get("authority_class", {}).get("meaning", {})
    for name in declared:
        if name not in allowed:
            out("documented class %r is not in the LoopSpec enum" % name)
    for cap in caps:
        cls = cap.get("authority_class")
        if cls not in allowed:
            out("%s has authority_class %r, not in the LoopSpec enum %r"
                % (cap.get("name", "<unnamed>"), cls, allowed))

elif what == "certification":
    cert = cat.get("not_a_security_boundary")
    if not isinstance(cert, dict):
        out("the not-a-security-boundary certification is absent")
    else:
        blob = " ".join(str(v) for v in cert.values()).lower()
        for phrase in ("not a security boundary", "mistaken agent"):
            if phrase not in blob:
                out("certification does not state %r" % phrase)

else:
    out("unknown check: %s" % what)
PY
}

# mutate <python-expression-body> - writes a copy of the real catalog with the
# named edit applied and echoes its path. `cat` is the parsed catalog. A
# mutation that does not apply fails the test: a control run against an
# unwritten copy would fire on "catalog unreadable" and prove nothing.
mutate() {
  local body=$1 dest
  dest="$TMP/mutated-$RANDOM.json"
  if ! python3 - "$CATALOG" "$dest" "$body" <<'PY'
import json, sys
src, dest, body = sys.argv[1:4]
with open(src) as fh:
    cat = json.load(fh)
exec(body)  # noqa: S102 - test fixture mutation, not runtime code
with open(dest, "w") as fh:
    json.dump(cat, fh)
PY
  then
    fail "capability catalog: mutation did not apply: $body"
  fi
  [ -f "$dest" ] || fail "capability catalog: mutation wrote no catalog: $body"
  printf '%s\n' "$dest"
}

assert_clean() {  # <what> <label>
  local got
  got=$(check "$1" "$CATALOG")
  [ -z "$got" ] || fail "$2: $got"
}

assert_control_fires() {  # <what> <mutation> <label>
  local copy got
  copy=$(mutate "$2") || exit 1
  got=$(check "$1" "$copy")
  [ -n "$got" ] || fail "$3: negative control did not fire - the check is vacuous"
}

TMP=$(fm_test_tmproot fm-capability-catalog)

test_every_owner_resolves() {
  assert_control_fires owners \
    'cat["capabilities"][0]["owner"] = "bin/fm-does-not-exist.sh"' \
    "capability catalog: owner-existence control"
  assert_control_fires owners \
    'cat["capabilities"][0]["owner"] = None' \
    "capability catalog: missing-owner control"
  assert_clean owners "capability catalog: every owner must resolve to an existing file"
  pass "capability catalog: every capability names an owner file that exists"
}

test_every_verifier_resolves() {
  assert_control_fires verifiers \
    'cat["capabilities"][0]["verifier"] = "tests/fm-does-not-exist.test.sh"' \
    "capability catalog: verifier-existence control"
  assert_clean verifiers "capability catalog: every verifier must resolve to an existing check"
  pass "capability catalog: every verifier names a check that exists"
}

test_network_request_is_unowned_and_captain_required() {
  assert_control_fires unowned \
    'cat["capabilities"] = [c for c in cat["capabilities"] if c["name"] != "network.request"]' \
    "capability catalog: network.request-present control"
  assert_control_fires unowned \
    '[c.update(owner="bin/fm-send.sh") for c in cat["capabilities"] if c["name"] == "network.request"]' \
    "capability catalog: network.request-unowned control"
  assert_control_fires unowned \
    '[c.update(authority_class="read-only") for c in cat["capabilities"] if c["name"] == "network.request"]' \
    "capability catalog: network.request-captain-required control"
  assert_clean unowned "capability catalog: network.request contract"
  pass "capability catalog: network.request is the only unowned row and is captain-required"
}

test_authority_class_reuses_the_existing_enum() {
  assert_control_fires enum \
    'cat["capabilities"][0]["authority_class"] = "worker-routine"' \
    "capability catalog: new-authority_class control"
  assert_control_fires enum \
    'cat["authority_class"]["meaning"]["worker-routine"] = "invented"' \
    "capability catalog: documented-class control"
  assert_clean enum "capability catalog: authority_class must come from loopspecs/schema.json"
  pass "capability catalog: every authority_class is in the existing LoopSpec enum"
}

test_security_boundary_disclaimer_is_present() {
  assert_control_fires certification \
    'del cat["not_a_security_boundary"]' \
    "capability catalog: absent-certification control"
  assert_control_fires certification \
    'cat["not_a_security_boundary"] = {"statement": "this catalog contains the blast radius"}' \
    "capability catalog: weakened-certification control"
  assert_clean certification "capability catalog: security-boundary disclaimer"
  pass "capability catalog: states it is a capability boundary, not a security boundary"
}

test_sixteen_capabilities_with_unique_names() {
  local count dupes
  count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["capabilities"]))' "$CATALOG")
  [ "$count" = "16" ] || fail "capability catalog: expected 16 capabilities, found $count"
  dupes=$(python3 -c '
import json, sys, collections
names = [c["name"] for c in json.load(open(sys.argv[1]))["capabilities"]]
print(",".join(n for n, k in collections.Counter(names).items() if k > 1))' "$CATALOG")
  [ -z "$dupes" ] || fail "capability catalog: duplicate capability names: $dupes"
  pass "capability catalog: sixteen capabilities with unique names"
}

test_every_owner_resolves
test_every_verifier_resolves
test_network_request_is_unowned_and_captain_required
test_authority_class_reuses_the_existing_enum
test_security_boundary_disclaimer_is_present
test_sixteen_capabilities_with_unique_names
