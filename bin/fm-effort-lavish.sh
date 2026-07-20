#!/usr/bin/env bash
# fm-effort-lavish.sh - render folded effort rows as a Lavish captain board.
#
# Canonical state remains the JSONL ledger folded by bin/fm-effort.sh and the
# optional typed inventory JSON supplied by a source adapter.
# This script writes a self-contained, no-network HTML review surface under
# .lavish/ by default.
# It does not open the browser itself; use `lavish-axi <html-file>` or
# bin/fm-effort-board-loop.sh for the one-cycle open/poll flow.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
EFFORT="$SCRIPT_DIR/fm-effort.sh"
NOW="${FM_EFFORT_NOW:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"
DEFAULT_OUT="$FM_ROOT/.lavish/fm-effort-captain-board.html"

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage: fm-effort-lavish.sh [--rows <rows.json>] [--inventory <inventory.json>] [--repo-allowlist <patterns>] [--output <html>] [--cards-json <json>]

Inputs:
  --rows <rows.json>       folded rows from `fm-effort.sh list --json`.
                           When omitted, this script runs that command.
  --inventory <json>       optional Lindy typed inventory JSON with richer ticket/PR fields.
  --repo-allowlist <list>  optional comma-separated repo glob list for PR URLs, for example lindy-ai/*.

Outputs:
  --output <html>          self-contained Lavish HTML path.
                           Default: .lavish/fm-effort-captain-board.html
  --cards-json <json>      also write normalized card data for tests/debugging.
EOF
}

need_jq() {
  command -v jq >/dev/null 2>&1 || die "jq is required"
}

cards_json() {  # <rows-json> <inventory-json-or-empty> <repo-allowlist>
  local rows=$1 inventory=$2 repo_allowlist=$3
  if [ -n "$inventory" ]; then
    jq -n --arg generated "$NOW" --arg repo_allowlist "$repo_allowlist" --slurpfile rows "$rows" --slurpfile inventory "$inventory" "$JQ_CARDS"
  else
    jq -n --arg generated "$NOW" --arg repo_allowlist "$repo_allowlist" --slurpfile rows "$rows" --argjson inventory '[]' "$JQ_CARDS"
  fi
}

# shellcheck disable=SC2016
JQ_CARDS='
  def rows: ($rows[0] // []);
  def inv_source:
    if ($inventory | type) == "array" then ($inventory[0] // [])
    else $inventory
    end;
  def inv_rows:
    (inv_source) as $i
    | if ($i | type) == "array" then $i else ($i.items // $i.rows // $i.efforts // []) end;
  def text($v): if $v == null then "" else ($v | tostring) end;
  def epoch:
    try (
      if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") then . + "T00:00:00Z" else . end
      | sub("\\.[0-9]+Z$"; "Z")
      | fromdateiso8601
    ) catch 0;
  def unique_text: map(text(.)) | map(select(length > 0)) | unique;
  def allowlist:
    $repo_allowlist
    | split(",")
    | map(gsub("^[[:space:]]+|[[:space:]]+$"; ""))
    | map(select(length > 0));
  def repo_from_url($url):
    try ($url | capture("github\\.com/(?<repo>[^/]+/[^/]+)/").repo) catch "";
  def glob_match($repo; $pattern):
    if $pattern == "*" then true
    elif ($pattern | contains("*")) then
      ($pattern | split("*")) as $parts
      | ($repo | startswith($parts[0]) and endswith($parts[-1]))
    else
      $repo == $pattern
    end;
  def github_url_allowed($url):
    (allowlist) as $allow
    | if ($allow | length) == 0 then true
      elif ($url | test("^https?://github\\.com/") | not) then true
      else (repo_from_url($url)) as $repo | any($allow[]; glob_match($repo; .))
      end;
  def url_list($r; $i):
    [
      $r.evidence?,
      $r.evidence_url?,
      $r.evidence_path?,
      $i.evidence?,
      $i.url?,
      $i.source_url?,
      $i.sourceUrl?,
      $i.urls[]?,
      $i.prs[]?.url?,
      $i.linear[]?.url?
    ] | unique_text | map(select(test("^https?://"))) | map(select(github_url_allowed(.)));
  def ci_state($i):
    ([ $i.ci?.state?, $i.prs[]?.ci.state? ] | unique_text) as $states
    | if ($states | length) > 0 then ($states | join(", ")) else "unknown" end;
  def human_approvals($i):
    (
      [ $i.review?.approvals[]?, $i.prs[]?.review.approvals[]? ]
      + [ $i.review?.latest[]? | select((.state // "" | ascii_downcase) == "approved") | .login ]
      + [ $i.prs[]?.review.latest[]? | select((.state // "" | ascii_downcase) == "approved") | .login ]
    ) | unique_text;
  def review_decisions($i):
    [ $i.review?.decision?, $i.prs[]?.review.decision? ] | unique_text;
  def review_state($i):
    (human_approvals($i)) as $humans
    | (review_decisions($i)) as $decisions
    | if ($humans | length) > 0 then "real-human-approved: " + ($humans | join(", "))
      elif ($decisions | map(ascii_downcase) | index("approved")) != null then "bot-only-or-unverified approval"
      elif ($decisions | length) > 0 then ($decisions | join(", "))
      else "unknown"
      end;
  def blockers($r; $i):
    (
      if ($i.blockers // null) == null then []
      elif ($i.blockers | type) == "array" then $i.blockers
      else [$i.blockers]
      end
    ) as $from_inv
    | ($from_inv + (if $r.stage == "blocked" and (($r.note // "") | length) > 0 then [$r.note] else [] end))
    | unique_text;
  def decision_kind($r; $i):
    text($r.decision.kind // $i.decision.kind //
      (if (text($i.exactCaptainAction // $i.captain_action // $i.captainAction) | test("merge|stamp"; "i")) then "merge_word"
       elif (text($i.exactCaptainAction // $i.captain_action // $i.captainAction) | test("cancel|close|obsolete|resurrect"; "i")) then "cancellation"
       elif (text($i.exactCaptainAction // $i.captain_action // $i.captainAction) | test("priority|ownership"; "i")) then "priority"
       else "scope"
       end));
  def decision_question($r; $i):
    text($r.decision.question // $i.decision.question // $i.exactCaptainAction // $i.captain_action // $i.captainAction // $r.note // ("Decide next action for " + $r.effort_id));
  def group_for($r):
    ($generated | epoch) as $now
    | (($r.stage_ts // $r.updated_at // "") | epoch) as $stage_epoch
    | if $r.stage == "needs_captain" then "needs"
      elif $r.stage == "blocked" then "blocked"
      elif (["intake","in_progress","in_review","merge_ready"] | index($r.stage)) != null then "in_flight"
      elif ((["merged","deployed","fallout_observed","done"] | index($r.stage)) != null and $stage_epoch >= ($now - 172800)) then "landed"
      else "hidden"
      end;
  def inventory_by_id:
    reduce inv_rows[] as $i ({}; .[text($i.effort_id // $i.effortId // $i.logicalId // $i.id)] = $i);
  (inventory_by_id) as $by_id
  | rows
  | map(
      . as $r
      | ($by_id[$r.effort_id] // {}) as $i
      | {
          effort_id: $r.effort_id,
          title: text($i.title // $i.name // $r.title // $r.effort_id),
          stage: $r.stage,
          group: group_for($r),
          stage_badge: ($r.stage | gsub("_"; " ")),
          urls: url_list($r; $i),
          ci_state: ci_state($i),
          review_state: review_state($i),
          bot_only_review_flag: (review_state($i) == "bot-only-or-unverified approval"),
          blockers: blockers($r; $i),
          owner_lane: text($i.owner // $i.lane_owner // $i.laneOwner // $r.actor // "unknown"),
          last_transition: text($i.last_transition_ts // $i.lastTransitionTs // $i.updatedAt // $i.fetchedAt // $r.stage_ts // $r.updated_at),
          why: text(($r.note // "") | split(";")[0]),
          note: text($r.note),
          next_machine_action: text($i.next_machine_action // $i.nextMachineAction // $i.exactNextMachineAction),
          captain_action: text($i.captain_action // $i.captainAction // $i.exactCaptainAction // $r.decision.question),
          decision_kind: decision_kind($r; $i),
          decision_question: decision_question($r; $i),
          decision_options: [
            {value:"APPROVE_MERGE_WORD", label:"APPROVE/MERGE-WORD"},
            {value:"CHANGES_REQUESTED", label:"CHANGES_REQUESTED"},
            {value:"PARK", label:"PARK"},
            {value:"CLOSE_AS_OBSOLETE", label:"CLOSE-AS-OBSOLETE"}
          ]
        }
    )
'

render_html() {  # <cards-json> <out-html>
  local cards_file=$1 out=$2 tmp
  mkdir -p "$(dirname "$out")"
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-effort-lavish.XXXXXX")
  {
    cat <<'HTML_HEAD'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Firstmate Effort Captain Board</title>
  <style>
    :root {
      color-scheme: light;
      --ink: #17202a;
      --muted: #667085;
      --line: #d9dee7;
      --surface: #ffffff;
      --back: #f7f8fb;
      --need: #b42318;
      --need-soft: #fff1f0;
      --flight: #175cd3;
      --flight-soft: #eff6ff;
      --blocked: #9a3412;
      --blocked-soft: #fff7ed;
      --landed: #067647;
      --landed-soft: #ecfdf3;
      --shadow: 0 1px 2px rgba(16, 24, 40, .08);
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font: 14px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      color: var(--ink);
      background: var(--back);
    }
    header {
      padding: 24px clamp(16px, 3vw, 40px);
      border-bottom: 1px solid var(--line);
      background: #fff;
      position: sticky;
      top: 0;
      z-index: 2;
    }
    h1 {
      margin: 0 0 12px;
      font-size: 24px;
      letter-spacing: 0;
    }
    .summary {
      display: grid;
      grid-template-columns: repeat(4, minmax(0, 1fr));
      gap: 10px;
      max-width: 1040px;
    }
    .metric {
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 10px 12px;
      background: #fff;
      box-shadow: var(--shadow);
      min-width: 0;
    }
    .metric strong {
      display: block;
      font-size: 22px;
      line-height: 1.1;
    }
    main {
      padding: 18px clamp(16px, 3vw, 40px) 48px;
    }
    section {
      margin: 0 0 26px;
    }
    h2 {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
      margin: 0 0 12px;
      font-size: 17px;
      letter-spacing: 0;
    }
    .cards {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(min(100%, 420px), 1fr));
      gap: 12px;
    }
    .card {
      background: var(--surface);
      border: 1px solid var(--line);
      border-radius: 8px;
      box-shadow: var(--shadow);
      padding: 14px;
      min-width: 0;
    }
    .card.needs { border-left: 5px solid var(--need); }
    .card.in_flight { border-left: 5px solid var(--flight); }
    .card.blocked { border-left: 5px solid var(--blocked); }
    .card.landed { border-left: 5px solid var(--landed); }
    .card-head {
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto;
      gap: 10px;
      align-items: start;
    }
    .title {
      margin: 0;
      font-size: 15px;
      font-weight: 700;
      overflow-wrap: anywhere;
    }
    .id {
      display: block;
      color: var(--muted);
      font-size: 12px;
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      overflow-wrap: anywhere;
      margin-top: 2px;
    }
    .badge {
      border-radius: 999px;
      border: 1px solid var(--line);
      padding: 3px 8px;
      white-space: nowrap;
      font-size: 12px;
      background: #f8fafc;
    }
    .needs .badge { color: var(--need); background: var(--need-soft); border-color: #fecdca; }
    .in_flight .badge { color: var(--flight); background: var(--flight-soft); border-color: #bfdbfe; }
    .blocked .badge { color: var(--blocked); background: var(--blocked-soft); border-color: #fed7aa; }
    .landed .badge { color: var(--landed); background: var(--landed-soft); border-color: #bbf7d0; }
    dl {
      display: grid;
      grid-template-columns: 120px minmax(0, 1fr);
      gap: 5px 10px;
      margin: 12px 0;
    }
    dt {
      color: var(--muted);
      font-weight: 600;
    }
    dd {
      margin: 0;
      min-width: 0;
      overflow-wrap: anywhere;
    }
    .urls {
      display: flex;
      flex-wrap: wrap;
      gap: 6px;
      margin-top: 8px;
    }
    a.url {
      max-width: 100%;
      overflow-wrap: anywhere;
      border: 1px solid var(--line);
      border-radius: 6px;
      padding: 3px 6px;
      color: #0b5cab;
      text-decoration: none;
      background: #fbfcff;
    }
    .decision {
      margin-top: 12px;
      padding-top: 12px;
      border-top: 1px solid var(--line);
    }
    .decision p {
      margin: 0 0 8px;
      font-weight: 650;
      overflow-wrap: anywhere;
    }
    .decision-buttons {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
    }
    button {
      border: 1px solid #9aa4b2;
      border-radius: 6px;
      background: #fff;
      color: var(--ink);
      padding: 7px 10px;
      cursor: pointer;
      font: inherit;
    }
    button.primary {
      border-color: var(--need);
      color: #fff;
      background: var(--need);
    }
    .queued {
      margin-top: 8px;
      color: var(--landed);
      font-weight: 650;
      min-height: 20px;
    }
    .empty {
      color: var(--muted);
      border: 1px dashed var(--line);
      border-radius: 8px;
      padding: 18px;
      background: #fff;
    }
    .bot-flag {
      color: var(--need);
      font-weight: 700;
    }
    @media (max-width: 720px) {
      header { position: static; }
      .summary { grid-template-columns: repeat(2, minmax(0, 1fr)); }
      dl { grid-template-columns: 1fr; }
    }
  </style>
</head>
<body>
  <header>
    <h1>Firstmate Effort Captain Board</h1>
    <div class="summary" id="summary"></div>
  </header>
  <main id="board"></main>
  <script type="application/json" id="cards-data">
HTML_HEAD
    jq '.' "$cards_file"
    cat <<'HTML_TAIL'
  </script>
  <script>
    const cards = JSON.parse(document.getElementById('cards-data').textContent);
    const groups = [
      ['needs', '1. NEEDS TIM NOW', 'needs'],
      ['in_flight', '2. In-Flight', 'in_flight'],
      ['blocked', '3. Blocked-on-others', 'blocked'],
      ['landed', '4. Landed-48h', 'landed']
    ];
    const counts = Object.fromEntries(groups.map(([key]) => [key, cards.filter(card => card.group === key).length]));
    const summary = document.getElementById('summary');
    for (const [key, label] of groups) {
      const box = document.createElement('div');
      box.className = 'metric';
      box.innerHTML = `<strong>${counts[key]}</strong><span>${label.replace(/^[0-9]+\. /, '')}</span>`;
      summary.appendChild(box);
    }
    function text(value) {
      return value == null || value === '' ? 'none' : String(value);
    }
    function addField(dl, label, value, className = '') {
      const dt = document.createElement('dt');
      const dd = document.createElement('dd');
      dt.textContent = label;
      dd.textContent = text(value);
      if (className) dd.className = className;
      dl.append(dt, dd);
    }
    function queueDecision(card, option, label, button) {
      const prompt = `FM_EFFORT_DECISION effort_id=${card.effort_id} option=${option} kind=${card.decision_kind}`;
      const data = {
        effort_id: card.effort_id,
        option,
        label,
        kind: card.decision_kind,
        question: card.decision_question,
        source: 'fm-effort-lavish'
      };
      if (window.lavish && typeof window.lavish.queuePrompt === 'function') {
        window.lavish.queuePrompt(prompt, {
          tag: 'fm-effort-decision',
          text: `${card.effort_id}: ${label}`,
          data,
          queueKey: `fm-effort-decision:${card.effort_id}`,
          element: button
        });
        if (typeof window.lavish.sendQueuedPrompts === 'function') {
          window.lavish.sendQueuedPrompts();
        }
      }
      const status = button.closest('.decision').querySelector('.queued');
      status.textContent = `Queued ${label} for ${card.effort_id}`;
    }
    function renderCard(card) {
      const article = document.createElement('article');
      article.className = `card ${card.group}`;
      article.dataset.effortId = card.effort_id;
      article.dataset.lavishQuestion = `decision:${card.effort_id}`;

      const head = document.createElement('div');
      head.className = 'card-head';
      const titleWrap = document.createElement('div');
      const title = document.createElement('h3');
      title.className = 'title';
      title.textContent = card.title || card.effort_id;
      const id = document.createElement('span');
      id.className = 'id';
      id.textContent = card.effort_id;
      titleWrap.append(title, id);
      const badge = document.createElement('span');
      badge.className = 'badge';
      badge.textContent = card.stage_badge;
      head.append(titleWrap, badge);
      article.appendChild(head);

      const dl = document.createElement('dl');
      addField(dl, 'CI', card.ci_state);
      addField(dl, 'Review', card.review_state, card.bot_only_review_flag ? 'bot-flag' : '');
      addField(dl, 'Owner lane', card.owner_lane);
      addField(dl, 'Last transition', card.last_transition);
      addField(dl, 'Blocker', (card.blockers || []).join(' | '));
      addField(dl, 'Why', card.why);
      addField(dl, 'Next machine', card.next_machine_action);
      addField(dl, 'Captain action', card.captain_action);
      article.appendChild(dl);

      const urls = document.createElement('div');
      urls.className = 'urls';
      for (const url of card.urls || []) {
        const a = document.createElement('a');
        a.className = 'url';
        a.href = url;
        a.target = '_blank';
        a.rel = 'noreferrer';
        a.textContent = url;
        urls.appendChild(a);
      }
      article.appendChild(urls);

      if (card.group === 'needs') {
        const decision = document.createElement('div');
        decision.className = 'decision';
        const q = document.createElement('p');
        q.textContent = card.decision_question;
        const buttons = document.createElement('div');
        buttons.className = 'decision-buttons';
        for (const opt of card.decision_options) {
          const button = document.createElement('button');
          button.type = 'button';
          button.textContent = opt.label;
          if (opt.value === 'APPROVE_MERGE_WORD') button.className = 'primary';
          button.addEventListener('click', () => queueDecision(card, opt.value, opt.label, button));
          buttons.appendChild(button);
        }
        const queued = document.createElement('div');
        queued.className = 'queued';
        decision.append(q, buttons, queued);
        article.appendChild(decision);
      }
      return article;
    }
    const board = document.getElementById('board');
    for (const [key, title] of groups) {
      const section = document.createElement('section');
      const h2 = document.createElement('h2');
      h2.innerHTML = `<span>${title}</span><span>${counts[key]}</span>`;
      section.appendChild(h2);
      const groupCards = cards.filter(card => card.group === key);
      if (groupCards.length === 0) {
        const empty = document.createElement('div');
        empty.className = 'empty';
        empty.textContent = 'None.';
        section.appendChild(empty);
      } else {
        const wrap = document.createElement('div');
        wrap.className = 'cards';
        groupCards.forEach(card => wrap.appendChild(renderCard(card)));
        section.appendChild(wrap);
      }
      board.appendChild(section);
    }
  </script>
</body>
</html>
HTML_TAIL
  } > "$tmp"
  mv "$tmp" "$out"
}

main() {
  need_jq
  local rows="" inventory="" output=$DEFAULT_OUT cards_out="" repo_allowlist="" tmp_rows="" tmp_cards=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --rows) [ $# -ge 2 ] || die "--rows needs a value"; rows=$2; shift 2 ;;
      --inventory) [ $# -ge 2 ] || die "--inventory needs a value"; inventory=$2; shift 2 ;;
      --repo-allowlist) [ $# -ge 2 ] || die "--repo-allowlist needs a value"; repo_allowlist=$2; shift 2 ;;
      --output) [ $# -ge 2 ] || die "--output needs a value"; output=$2; shift 2 ;;
      --cards-json) [ $# -ge 2 ] || die "--cards-json needs a value"; cards_out=$2; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *) usage; exit 1 ;;
    esac
  done

  if [ -z "$rows" ]; then
    tmp_rows=$(mktemp "${TMPDIR:-/tmp}/fm-effort-rows.XXXXXX")
    "$EFFORT" list --json > "$tmp_rows"
    rows=$tmp_rows
  fi
  [ -f "$rows" ] || die "missing rows JSON: $rows"
  if [ -n "$inventory" ] && [ ! -f "$inventory" ]; then
    die "missing inventory JSON: $inventory"
  fi

  tmp_cards=$(mktemp "${TMPDIR:-/tmp}/fm-effort-cards.XXXXXX")
  cards_json "$rows" "$inventory" "$repo_allowlist" > "$tmp_cards"
  if [ -n "$cards_out" ]; then
    mkdir -p "$(dirname "$cards_out")"
    cp "$tmp_cards" "$cards_out"
  fi
  render_html "$tmp_cards" "$output"
  rm -f "${tmp_rows:-}" "$tmp_cards"
  printf 'lavish-board: %s\n' "$output"
}

main "$@"
