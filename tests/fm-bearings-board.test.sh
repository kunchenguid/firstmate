#!/usr/bin/env bash
# Behavior tests for bin/fm-bearings-board.sh: fail-closed payload validation,
# slot-injection round-trip through the built page, bind-before-arm, and
# idempotent re-arm of the stable board source, plus the built board's
# full-text tooltip invariant, asserted by running the shipped renderer against
# a minimal DOM shim so the coverage never depends on a headless browser.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-bearings-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/state" "$home/data"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" lavish-axi
  printf '%s\n' "$home"
}

run_board() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" "$@"
}

run_procevent() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" "$@"
}

run_decisions() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-decision-hold.sh" "$@"
}

# A realistic payload: a cross-origin full-identity decision key past the old
# 64-char cap, a merge card, a dispatchable charted row, and a string that
# tries to terminate the data block early.
write_valid_payload() {  # <path>
  cat > "$1" <<'EOF'
{
  "schema": "fm-bearings-board.v1",
  "home": "test-home",
  "generated": "2026-08-19T00:00Z",
  "prs_live": false,
  "captains_call": [
    {
      "key": "sample-instruction-layer-refinement-review-decision-perishable-first-admission-choice",
      "type": "decision",
      "repo": "sample",
      "title": "Perishable-first admission",
      "about": "A payload string that tries to break out: </script><b>x</b>",
      "decide": "Adopt it?",
      "options": [
        { "value": "yes", "label": "Adopt", "hint": "recommended" },
        { "value": "no", "label": "Keep current" }
      ],
      "allow_freeform": true
    },
    {
      "key": "merge.sample-task",
      "type": "merge",
      "repo": "sample",
      "title": "Merge: sample change",
      "detail": "validation green",
      "task_id": "sample-task",
      "pr_url": "https://github.com/example/sample/pull/1",
      "checks": "green",
      "risk": "low",
      "options": [
        { "value": "merge", "label": "Merge now" },
        { "value": "hold", "label": "Not yet" }
      ],
      "allow_freeform": true
    }
  ],
  "underway": [],
  "landed": [],
  "charted": [
    { "id": "sample-queued", "repo": "sample", "title": "Queued work", "reason": "", "dispatchable": true }
  ],
  "charted_more": 0
}
EOF
}

# Extract the injected payload back out of a built board page.
extract_payload() {  # <board-path>
  sed -n '/<script id="bearings-data" type="application\/json">/,/<\/script>/p' "$1" \
    | sed '1d;$d'
}

# Execute the shipped renderer from a built board page against a minimal DOM
# shim and print the rendered node state as JSON, so tooltip behavior is
# asserted from what the renderer actually produced rather than from a headless
# browser that the runner may not have. The board page is generated public
# output and the renderer is the real consumer under test.
render_board_node_json() {  # <board-path>
  local render
  command -v node >/dev/null 2>&1 || return 4
  render=$(BOARD_PAGE="$1" node --input-type=module <<'JS'
import { readFileSync } from "node:fs";

const html = readFileSync(process.env.BOARD_PAGE, "utf8");
const dataBlock = html.match(
  /<script id="bearings-data" type="application\/json">\n([\s\S]*?)\n<\/script>/);
if (!dataBlock) throw new Error("the built board carries no bearings-data block");
const rendererBlock = html
  .slice(dataBlock.index + dataBlock[0].length)
  .match(/<script>\n([\s\S]*?)\n<\/script>/);
if (!rendererBlock) throw new Error("the built board carries no renderer script");

class ClassList {
  constructor(node) { this.node = node; }
  tokens() {
    return this.node.className ? this.node.className.split(/\s+/).filter(Boolean) : [];
  }
  write(tokens) { this.node.className = tokens.join(" "); }
  contains(name) { return this.tokens().indexOf(name) !== -1; }
  add(name) { if (!this.contains(name)) this.write(this.tokens().concat([name])); }
  remove(name) { this.write(this.tokens().filter((t) => t !== name)); }
  toggle(name, on) {
    const want = on === undefined ? !this.contains(name) : !!on;
    if (want) this.add(name); else this.remove(name);
  }
}

class Element {
  constructor(tag) {
    this.tagName = String(tag).toUpperCase();
    this.children = [];
    this.parentNode = null;
    this.id = "";
    this.className = "";
    this.attributes = {};
    this.listeners = {};
    this.ownText = "";
    this.titleValue = undefined;
    this.rawHtml = "";
    this.classList = new ClassList(this);
  }
  get textContent() {
    return this.ownText + this.children.map((c) => c.textContent).join("");
  }
  set textContent(value) {
    this.children = [];
    this.ownText = value == null ? "" : String(value);
  }
  /* title reflects a DOMString, so the DOM stringifies whatever it is given -
     that is exactly what makes a null value observable as "null". */
  get title() { return this.titleValue === undefined ? "" : this.titleValue; }
  set title(value) { this.titleValue = String(value); }
  get innerHTML() { return this.rawHtml; }
  set innerHTML(value) {
    this.rawHtml = value == null ? "" : String(value);
    this.children = [];
    this.ownText = "";
  }
  appendChild(node) { node.parentNode = this; this.children.push(node); return node; }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  getAttribute(name) {
    return Object.prototype.hasOwnProperty.call(this.attributes, name)
      ? this.attributes[name] : null;
  }
  addEventListener(type, fn) {
    (this.listeners[type] = this.listeners[type] || []).push(fn);
  }
  matches(selector) {
    const parts = selector.split(":");
    const cls = parts[0].replace(/^\./, "");
    if (cls && !this.classList.contains(cls)) return false;
    return parts.slice(1).every((p) => (p === "checked" ? this.checked === true : false));
  }
  querySelectorAll(selector) {
    const found = [];
    const walk = (node) => node.children.forEach((child) => {
      if (child.matches(selector)) found.push(child);
      walk(child);
    });
    walk(this);
    return found;
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
}

const byId = new Map();
/* Each id node hangs off its own root so the collector below reports the id
   node itself, not just whatever the renderer appends inside it. */
const idRoots = [];
for (const m of html.matchAll(/\bid="([^"]+)"/g)) {
  const node = new Element("div");
  node.id = m[1];
  const root = new Element("div");
  root.appendChild(node);
  idRoots.push(root);
  byId.set(m[1], node);
}
const main = new Element("main");
main.className = "bb-main";
const dataNode = byId.get("bearings-data");
if (!dataNode) throw new Error("the built board carries no bearings-data element");
dataNode.textContent = dataBlock[1];

globalThis.window = {};
globalThis.document = {
  createElement: (tag) => new Element(tag),
  getElementById: (id) => byId.get(id) || null,
  querySelector: (selector) => (selector === ".bb-main" ? main : null),
};
new Function(rendererBlock[1])();

const nodes = [];
const collect = (node) => node.children.forEach((child) => {
  nodes.push({
    tag: child.tagName,
    id: child.id || null,
    classes: child.className ? child.className.split(/\s+/).filter(Boolean) : [],
    text: child.textContent,
    title: child.titleValue === undefined ? null : child.titleValue,
    href: child.href === undefined ? null : child.href,
    placeholder: child.placeholder === undefined ? null : child.placeholder,
  });
  collect(child);
});
/* anything under .bb-main means the renderer bailed to its fail-closed card */
const errored = main.children.length > 0;
collect(main);
idRoots.forEach(collect);
process.stdout.write(JSON.stringify({ errored, nodes }) + "\n");
JS
  ) || return 1
  printf '%s' "$render" | jq -e '.errored == false' >/dev/null || return 3
  # title reflects a DOMString, so absent text left to the DOM would surface as
  # the literal "null" - no rendered node may ever advertise that as its value.
  printf '%s' "$render" | jq -e 'all(.nodes[]; .title != "null")' >/dev/null || return 2
  printf '%s' "$render" | jq -c 'del(.errored)'
}

# Render <board-path> and publish the node JSON as RENDERED_NODES. The guards
# above run inside a command substitution, where fail would only exit the
# subshell and let a generic caller message mask the real cause, so they report
# through distinct exit codes that this caller turns into the exact diagnostic.
render_board_nodes() {  # <board-path>
  local rc
  RENDERED_NODES=$(render_board_node_json "$1") && return 0
  rc=$?
  case "$rc" in
    2) fail "the rendered board exposed a stringified null as a tooltip" ;;
    3) fail "the renderer fell back to its fail-closed card instead of rendering the board" ;;
    4) fail "node is required to render the board for the tooltip assertions" ;;
    *) fail "the shipped renderer could not run over the built board" ;;
  esac
}

# Assert a rendered node of <class> carries <want> as its exact full tooltip.
# Pass "visible" to also require that the visible text is that same exact value.
assert_node_title() {  # <render> <class> <want> [visible]
  local also=""
  # shellcheck disable=SC2016 # $want is a jq variable bound by --arg below, not a shell expansion.
  [ "${4:-}" = visible ] && also=' and .text == $want'
  printf '%s' "$1" | jq -e --arg cls "$2" --arg want "$3" \
    "any(.nodes[]; (.classes | index(\$cls)) != null and .title == \$want$also)" \
    >/dev/null || fail "the rendered board hid the full text of .$2: $3"
}

test_path_is_stable_and_home_scoped() {
  local home
  home=$(make_home path)
  [ "$(run_board "$home" path)" = "$home/.lavish/bearings-board.html" ] \
    || fail "the board path is not the stable home-scoped location"
  pass "path prints the stable home-scoped board location"
}

test_build_refuses_malformed_payloads_before_touching_the_board() {
  local home data board rc out
  home=$(make_home refusal)
  board="$home/.lavish/bearings-board.html"
  data="$home/payload.json"

  printf 'not json\n' > "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-JSON payload was accepted"
  assert_contains "$out" "not valid JSON" "the non-JSON refusal did not say why: $out"

  printf '{"schema":"fm-bearings-board.v2"}\n' > "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a wrong-schema payload was accepted"
  assert_contains "$out" "fm-bearings-board.v1" "the schema refusal did not name the contract: $out"

  write_valid_payload "$data"
  jq '.captains_call[0].key = (reduce range(129) as $i (""; . + "x"))' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a 129-char captains_call key was accepted"

  write_valid_payload "$data"
  jq 'del(.charted[0].dispatchable)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a charted row without a dispatchable boolean was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].type = "verdict"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an unknown captains_call type was accepted"

  write_valid_payload "$data"
  jq 'del(.captains_call[0].options[0].value)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a captains_call option without an answer value was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].options[0].label = ""' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a captains_call option with an empty label was accepted"

  write_valid_payload "$data"
  jq 'del(.charted[0].repo)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a fleet row without an explicit repo marker was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].allow_freeform = "yes"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-boolean renderer field was accepted"

  write_valid_payload "$data"
  jq '.captains_call[0].options = [] | .captains_call[0].allow_freeform = false' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an unanswerable captains_call item was accepted"

  write_valid_payload "$data"
  jq '.captains_call[1].pr_url = "javascript:alert(1)"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-HTTPS Captain’s Call PR URL was accepted"

  write_valid_payload "$data"
  jq '.landed = [{
    "id": "sample-landed",
    "repo": "sample",
    "what": "Landed work",
    "owner": "firstmate",
    "pr_url": "data:text/html,unsafe"
  }]' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-HTTPS Landed PR URL was accepted"

  assert_absent "$board" "a refused payload still produced a board"
  pass "build refuses malformed payloads before touching the board"
}

test_build_injects_binds_then_arms() {
  local home data board out sid
  home=$(make_home build)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"

  out=$(run_board "$home" build "$data") || fail "a valid payload did not build"
  assert_contains "$out" "board: $board" "build did not report the board path: $out"
  assert_contains "$out" "served: $board" "build did not establish the Lavish session: $out"
  assert_contains "$out" "bound: " "build did not report the answer binding: $out"
  assert_contains "$out" "armed: " "the first build did not arm the board source: $out"
  assert_present "$board" "build reported success without a board"

  # Round-trip: the payload extracted from the built page is byte-for-byte the
  # same JSON document, and the escaped </script> string can no longer
  # terminate the data block.
  extract_payload "$board" | jq -S . > "$home/extracted.json" \
    || fail "the built board does not carry parseable payload JSON"
  jq -S . "$data" > "$home/expected.json"
  diff -u "$home/expected.json" "$home/extracted.json" >/dev/null \
    || fail "the injected payload does not round-trip to the input document"
  grep -qF '</script><b>' "$board" \
    && fail "a payload string embedded a live closing script tag in the page"
  grep -qxF '__FM_BEARINGS_BOARD_DATA__' "$board" \
    && fail "the data slot survived injection"

  sid=$(run_lavish_source_id "$home" "$board")
  assert_contains "$out" "bound: $sid" "the binding does not name the board source: $out"
  [ "$(run_decisions "$home" binding "$sid")" = "(any)" ] \
    || fail "the board source is not bound any-origin"
  run_procevent "$home" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$sid" \
    || fail "the board source is not registered after build"
  pass "build injects the payload, binds any-origin, then arms the source"
}

test_rendered_truncated_text_has_full_native_tooltips() {
  local home data board marker long_id render entry
  home=$(make_home tooltips)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  marker='Long & exact "captain-facing" value <must stay text> '
  long_id='long-slug-legal-charted-id-that-overflows-the-half-width-charted-column-and-stays-hoverable'
  write_valid_payload "$data"
  # Every row carries a truncation-prone value: markup-like long text on the
  # repo-bearing rows, and the genuinely-no-repo rows fall back to the routing
  # id, which the charted schema restricts to a slug.
  jq --arg marker "$marker" --arg long_id "$long_id" '
    .generated = ($marker + "generated stamp") |
    .captains_call[0].repo = ($marker + "decision repo") |
    .captains_call[1].pr_url = "https://github.com/example/sample/pull/12345678901234567890?view=full&mode=review" |
    .captains_call += [{
      "key": "sample-no-repo-decision",
      "type": "decision",
      "repo": null,
      "title": "A decision that names no repository",
      "options": [{ "value": "ack", "label": "Acknowledge" }]
    }] |
    .underway = [
      {
        "id": "underway-with-repo",
        "repo": ($marker + "underway repo"),
        "kind": "ship",
        "state": ($marker + "working badge"),
        "doing": ($marker + "underway title")
      },
      {
        "id": ($marker + "underway id"),
        "repo": "",
        "kind": "ship",
        "state": "working",
        "doing": "a short underway line"
      }
    ] |
    .landed = [
      {
        "id": "landed-with-repo",
        "repo": ($marker + "landed repo"),
        "what": ($marker + "landed title"),
        "owner": ($marker + "landed owner"),
        "pr_url": "https://github.com/example/sample/pull/98765432109876543210?view=full&mode=review"
      },
      {
        "id": ($marker + "landed id"),
        "repo": "",
        "what": "a short landed line",
        "owner": ($marker + "landed owner")
      }
    ] |
    .charted = [
      {
        "id": "charted-with-repo",
        "repo": ($marker + "charted repo"),
        "title": ($marker + "charted title"),
        "reason": ($marker + "charted reason"),
        "dispatchable": true
      },
      {
        "id": $long_id,
        "repo": "",
        "title": "a short charted line",
        "reason": "",
        "dispatchable": false
      }
    ]
  ' "$data" > "$data.tmp" && mv "$data.tmp" "$data"

  run_board "$home" build "$data" >/dev/null || fail "the long-text tooltip board did not build"
  # The markup-like text stays inert data in the page, and only the renderer
  # turns it back into an exact tooltip value.
  grep -qF 'value \u003cmust stay text>' "$board" \
    || fail "the markup-like tooltip text was not \\u003c-escaped in the injected payload"
  grep -qF 'value <must stay text>' "$board" \
    && fail "the built board embedded the markup-like tooltip text as live markup"

  render_board_nodes "$board"
  render=$RENDERED_NODES

  for entry in \
    "bb-decision__repo|${marker}decision repo" \
    "bb-decision__link|https://github.com/example/sample/pull/12345678901234567890?view=full&mode=review" \
    "fm-badge|${marker}working badge" \
    "bb-row__title|${marker}underway title" \
    "bb-row__sub|ship · ${marker}underway repo" \
    "bb-row__sub|ship · ${marker}underway id" \
    "bb-row__title|${marker}landed title" \
    "bb-row__sub|${marker}landed repo · ${marker}landed owner" \
    "bb-row__sub|${marker}landed id · ${marker}landed owner" \
    "bb-row__pr|https://github.com/example/sample/pull/98765432109876543210?view=full&mode=review" \
    "bb-row__title|${marker}charted title" \
    "bb-row__sub|${marker}charted reason · ${marker}charted repo" \
    "bb-row__sub|$long_id"; do
    assert_node_title "$render" "${entry%%|*}" "${entry#*|}"
  done

  # The footer provenance is nowrap inside a flex-end row, so an overlong stamp
  # escapes past the start edge where no scrolling can reach it.
  printf '%s' "$render" | jq -e \
    --arg want "fm-bearings-board.v1 · ${marker}generated stamp" '
    any(.nodes[]; .id == "bb-provenance" and .text == $want and .title == $want)
  ' >/dev/null || fail "the footer provenance did not expose its exact full text"

  # Tooltips carry the payload text verbatim - the renderer must not smuggle
  # entity-escaped or truncated text into the captain-facing value.
  printf '%s' "$render" | jq -e '
    [.nodes[] | select(.title != null) | .title | select(test("must stay text"))] as $titles
    | ($titles | length) >= 8
      and ($titles | all(contains("<must stay text>")
        and (contains("&lt;") | not)
        and (contains("&amp;") | not)
        and (contains("&quot;") | not)))
  ' >/dev/null || fail "a rendered tooltip did not carry the exact unescaped payload text"

  # A genuinely-repo-less Captain's Call item shows no repo and must not
  # advertise a stringified "null" as its hidden full text.
  printf '%s' "$render" | jq -e '
    any(.nodes[]; (.classes | index("bb-decision__repo")) != null
      and .text == "" and .title == null)
  ' >/dev/null || fail "a repo-less Captain's Call item produced a tooltip for absent text"

  pass "the rendered board exposes exact full tooltips and none for absent text"
}

test_rendered_decision_body_text_exposes_full_values() {
  local home data board token render entry
  home=$(make_home decision-body)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  # One unbreakable token wider than the single-column card: without a
  # full-text affordance the card's overflow:hidden clips it outright.
  token='https://github.com/example/sample/pull/1234#issuecomment-2938471029384-with-an-unbreakable-tail'
  write_valid_payload "$data"
  jq --arg token "$token" '
    .captains_call[0].title = ("Adopt the change tracked at " + $token) |
    .captains_call[0].about = ("see " + $token) |
    .captains_call[0].decide = ("compare against " + $token) |
    .captains_call[0].options[0].label = ("Adopt per " + $token) |
    .captains_call[0].options[0].hint = ("rationale at " + $token) |
    .captains_call[1].detail = ("validation green, evidence at " + $token)
  ' "$data" > "$data.tmp" && mv "$data.tmp" "$data"

  run_board "$home" build "$data" >/dev/null \
    || fail "the unbreakable-token decision board did not build"
  render_board_nodes "$board"
  render=$RENDERED_NODES

  for entry in \
    "bb-decision__title|Adopt the change tracked at $token" \
    "bb-ctx__v|see $token" \
    "bb-ctx__v|compare against $token" \
    "bb-opt__label|Adopt per $token" \
    "bb-opt__hint|rationale at $token" \
    "bb-decision__detail|validation green, evidence at $token"; do
    # The visible label keeps the text and the tooltip carries the same exact
    # value - the affordance adds reach, it never replaces what is on screen.
    assert_node_title "$render" "${entry%%|*}" "${entry#*|}" visible
  done

  # Static context keys are fully exposed, so they must stay tooltip-free.
  printf '%s' "$render" | jq -e '
    [.nodes[] | select((.classes | index("bb-ctx__k")) != null)] as $keys
    | ($keys | length) >= 2 and ($keys | all(.title == null))
  ' >/dev/null || fail "a fully exposed context key gained a redundant tooltip"

  pass "decision card body text exposes its exact full value without hiding the label"
}

test_rendered_landed_pr_link_exposes_exact_url() {
  local home data board url render
  home=$(make_home landed-pr-tooltip)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  url='https://github.com/example/sample/pull/98765432109876543210?view=full&mode=review'
  write_valid_payload "$data"
  jq --arg url "$url" '.landed = [{
    "id": "landed-pr-tooltip",
    "repo": "sample",
    "what": "Landed work with a pull request",
    "owner": "firstmate",
    "pr_url": $url
  }]' "$data" > "$data.tmp" && mv "$data.tmp" "$data"

  run_board "$home" build "$data" >/dev/null \
    || fail "the landed-PR tooltip board did not build"
  render_board_nodes "$board"
  render=$RENDERED_NODES

  printf '%s' "$render" | jq -e --arg url "$url" '
    any(.nodes[]; (.classes | index("bb-row__pr")) != null
      and .text == "#98765432109876543210?view=full&mode=review"
      and .href == $url
      and .title == $url)
  ' >/dev/null || fail "the landed PR link did not preserve its label, href, and exact native title"

  pass "the landed PR link exposes its exact URL without replacing its visible label"
}

test_rendered_freeform_hint_is_reachable_beyond_the_placeholder() {
  local home data board hint render
  home=$(make_home freeform-hint)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  # A hint far wider than a single-line field, with markup-like and unbreakable
  # runs: the input clips its placeholder at the field edge with no ellipsis.
  hint='or answer in your own words <e.g. "name the branch"> https://github.com/example/sample/compare/f170ced...aba38e6-and-an-unbreakable-tail'
  write_valid_payload "$data"
  jq --arg hint "$hint" '
    .captains_call[0].allow_freeform = true |
    .captains_call[0].freeform_hint = $hint |
    .captains_call[1].allow_freeform = true |
    del(.captains_call[1].freeform_hint)
  ' "$data" > "$data.tmp" && mv "$data.tmp" "$data"

  run_board "$home" build "$data" >/dev/null \
    || fail "the long-freeform-hint board did not build"
  grep -qF 'own words \u003ce.g.' "$board" \
    || fail "the markup-like freeform hint was not \\u003c-escaped in the injected payload"

  render_board_nodes "$board"
  render=$RENDERED_NODES

  # The visible placeholder keeps the hint and the tooltip carries the same
  # exact value, so the full text is reachable without relying on the browser
  # drawing the whole placeholder.
  printf '%s' "$render" | jq -e --arg hint "$hint" '
    any(.nodes[]; (.classes | index("bb-freeform")) != null
      and .placeholder == $hint and .title == $hint)
  ' >/dev/null || fail "the freeform input did not expose its exact full hint"

  # The built-in fallback placeholder is short, fixed, and fully shown, so it
  # must not gain a tooltip - and an absent hint must never surface as "null".
  printf '%s' "$render" | jq -e '
    any(.nodes[]; (.classes | index("bb-freeform")) != null
      and .placeholder == "or answer in your own words\u2026" and .title == null)
  ' >/dev/null || fail "the default freeform placeholder gained a tooltip"

  pass "the freeform input exposes its exact full hint and none for the default"
}

test_rendered_static_badges_stay_tooltip_free() {
  local home data board risk state render
  home=$(make_home badge-tooltips)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  risk='elevated because the migration touches every tracked payload validator at once'
  state='waiting on the authenticated fork push before the review gate can advance'
  write_valid_payload "$data"
  jq --arg risk "$risk" --arg state "$state" '
    .captains_call[1].risk = $risk |
    .underway = [{
      "id": "underway-dynamic-state",
      "repo": "sample",
      "kind": "ship",
      "state": $state,
      "doing": "a short underway line"
    }] |
    .charted[0].reason = "blocked"
  ' "$data" > "$data.tmp" && mv "$data.tmp" "$data"

  run_board "$home" build "$data" >/dev/null \
    || fail "the dynamic-badge board did not build"
  render_board_nodes "$board"
  render=$RENDERED_NODES

  # Payload-derived badge text is unbounded, so it carries its full value.
  printf '%s' "$render" | jq -e --arg risk "risk $risk" --arg state "$state" '
    ([.nodes[] | select((.classes | index("fm-badge")) != null)]) as $badges
    | ($badges | any(.text == $risk and .title == $risk))
      and ($badges | any(.text == $state and .title == $state))
  ' >/dev/null || fail "a dynamic badge did not expose its exact full text"

  # Fixed short badge literals are always fully drawn, so they stay tooltip-free.
  printf '%s' "$render" | jq -e '
    ([.nodes[] | select((.classes | index("fm-badge")) != null)]) as $badges
    | (["decision", "checks green", "waiting"] | all(. as $literal
        | $badges | any(.text == $literal) and all(.text != $literal or .title == null)))
  ' >/dev/null || fail "a fixed, fully visible badge literal gained a redundant tooltip"

  pass "dynamic badges expose full text while fixed badge literals stay tooltip-free"
}

test_registration_cannot_consume_before_any_origin_binding() {
  local home data runtime origin key hold board sid show
  home=$(make_home order-proof)
  data="$home/payload.json"
  runtime="$home/runtime"
  origin=order-proof-review
  key=captain-choice
  hold="$origin-decision-$key"
  board="$home/.lavish/bearings-board.html"

  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fm_write_meta "$home/state/$origin.meta" "project=$home/projects/sample" "kind=scout"
  run_decisions "$home" hold "$origin" "$key" \
    --title "Choose the order proof" --reason "captain choice pending" --repo sample >/dev/null \
    || fail "could not create the order-proof captain hold"

  write_valid_payload "$data"
  jq --arg hold "$hold" '.captains_call[0].key = $hold' "$data" > "$data.tmp" \
    && mv "$data.tmp" "$data"

  mkdir -p "$runtime"
  cp -R "$ROOT/bin" "$runtime/bin"
  cat > "$runtime/bin/fm-procevent-lavish.sh" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = arm ]; then
  artifact=${2:-}
  "$REAL_LAVISH_ADAPTER" arm "$artifact" >/dev/null
  sid=$("$REAL_LAVISH_ADAPTER" source-id "$artifact")
  "$REAL_PROCEVENT" start "$sid" >/dev/null
  exit 0
fi
exec "$REAL_LAVISH_ADAPTER" "$@"
SH
  chmod +x "$runtime/bin/fm-procevent-lavish.sh"
  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" != poll ]; then
  exit 0
fi
cat <<EOF
session:
  status: feedback
  session_ended: false
prompts[1]{uid,prompt,selector,tag,text}:
  "2","Order proof: yes\\n\\nContext data:\\n{\\n  \\"question\\": \\"$ORDER_PROOF_HOLD\\",\\n  \\"answer\\": \\"yes\\"\\n}","form",choice,"Order proof: yes"
EOF
SH
  chmod +x "$home/fakebin/lavish-axi"

  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$runtime" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    FM_BEARINGS_BOARD_TEMPLATE="$ROOT/.agents/skills/bearings/assets/board-template.html" \
    REAL_LAVISH_ADAPTER="$ROOT/bin/fm-procevent-lavish.sh" \
    REAL_PROCEVENT="$ROOT/bin/fm-procevent.sh" ORDER_PROOF_HOLD="$hold" \
    "$runtime/bin/fm-bearings-board.sh" build "$data" >/dev/null \
    || fail "the order-proof board build failed"

  show=$(cd "$home" && tasks-axi show "$hold" --full) \
    || fail "the order-proof captain hold disappeared"
  assert_contains "$show" "state: done" \
    "registration consumed its answer before the any-origin binding existed"
  assert_contains "$show" "Resolution mode: answered" \
    "the answer was not closed through the real keyed-answer intake"
  sid=$(run_lavish_source_id "$home" "$board")
  [ "$(run_decisions "$home" binding "$sid")" = "(any)" ] \
    || fail "the order-proof source did not retain its any-origin binding"
  pass "registration can consume answers only after any-origin binding exists"
}

test_build_does_not_bind_or_arm_when_session_start_fails() {
  local home data rc sid
  home=$(make_home serve-failure)
  data="$home/payload.json"
  write_valid_payload "$data"
  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/lavish-axi"

  set +e
  run_board "$home" build "$data" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "build continued after Lavish session establishment failed"
  sid=$(run_lavish_source_id "$home" "$home/.lavish/bearings-board.html")
  ! run_decisions "$home" binding "$sid" >/dev/null 2>&1 \
    || fail "build bound the board before its Lavish session existed"
  ! run_procevent "$home" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$sid" \
    || fail "build armed the board before its Lavish session existed"
  pass "build establishes the Lavish session before binding and arming"
}

run_lavish_source_id() {  # <home> <artifact>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent-lavish.sh" source-id "$2"
}

test_rebuild_is_idempotent_and_does_not_double_arm() {
  local home data board out records
  home=$(make_home rearm)
  data="$home/payload.json"
  board="$home/.lavish/bearings-board.html"
  write_valid_payload "$data"
  run_board "$home" build "$data" >/dev/null || fail "the first build failed"

  jq '.generated = "2026-08-19T01:00Z"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  out=$(run_board "$home" build "$data") || fail "the rebuild failed"
  assert_contains "$out" "already-armed: " "the rebuild re-armed an already registered source: $out"
  extract_payload "$board" | jq -e '.generated == "2026-08-19T01:00Z"' >/dev/null \
    || fail "the rebuild did not refresh the board payload in place"
  records=$(find "$home/state/procevent" -name '*.source' | wc -l | tr -d ' ')
  [ "$records" = 1 ] || fail "rebuilding left $records source registrations instead of 1"
  pass "rebuild refreshes the board in place without double-arming"
}

test_build_refuses_a_template_without_exactly_one_slot() {
  local home data rc out
  home=$(make_home badslot)
  data="$home/payload.json"
  write_valid_payload "$data"
  printf '<html><body>no slot</body></html>\n' > "$home/broken-template.html"
  set +e
  out=$(FM_BEARINGS_BOARD_TEMPLATE="$home/broken-template.html" run_board "$home" build "$data" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a template with no data slot was accepted"
  assert_contains "$out" "data slot" "the slot refusal did not say why: $out"
  assert_absent "$home/.lavish/bearings-board.html" "a refused template still produced a board"
  pass "build refuses a template without exactly one data slot"
}

test_path_is_stable_and_home_scoped
test_build_refuses_malformed_payloads_before_touching_the_board
test_build_injects_binds_then_arms
test_rendered_truncated_text_has_full_native_tooltips
test_rendered_decision_body_text_exposes_full_values
test_rendered_landed_pr_link_exposes_exact_url
test_rendered_freeform_hint_is_reachable_beyond_the_placeholder
test_rendered_static_badges_stay_tooltip_free
test_registration_cannot_consume_before_any_origin_binding
test_build_does_not_bind_or_arm_when_session_start_fails
test_rebuild_is_idempotent_and_does_not_double_arm
test_build_refuses_a_template_without_exactly_one_slot
