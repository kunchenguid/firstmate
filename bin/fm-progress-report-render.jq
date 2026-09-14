def pct_label($v):
  if ($v | type) == "number" then "\($v | floor)%"
  else "unknown" end;

(.status_level) as $level |
(.mention + " *" + .program + ", " + .header_time + "*  " +
  (if $level == "blocked" then "🔴 blocked"
   else "⚪ health unknown" end)) ,
(if (.waiting | length) == 0 then "*Waiting on you:* nothing"
 else .waiting | to_entries | map(if .key == 0 then "*Waiting on you:* " + .value else .value end) | .[] end),
"```",
"Fix classes landed   " + .bars.fixed + "  " + (.fixed_display|tostring) + " / " + (.fixed_denominator|tostring) + "   (fixed; verification window unknown)",
"Fix seats in flight  " + .bars.seats + "  unknown",
"Smoke on main        " + .bars.smoke + "  " + .smoke_label + " / 1",
"Quiet clock          " + .bars.quiet + "  " + .quiet_label + " / 24 h without a new silent failure",
"Quota (remaining)    Codex " + .bars.codex + " " + (pct_label(.codex_pct)) +
  " · Cursor " + .bars.cursor + " " + (pct_label(.cursor_pct)) +
  " · Kimi " + .bars.kimi + " " + (pct_label(.kimi_pct)),
"Ledger               " + (.class_total|tostring) + " classes: " +
  (.ledger_fixed|tostring) + " fixed · " + (.ledger_owned|tostring) + " owned · " +
  (.ledger_scouts|tostring) + " scouts · " + (.ledger_watch|tostring) + " watch",
"```",
("*Since last report:* merged " +
  (if .merged_invalid then "unknown"
   elif (.merged_since | length) == 0 then "none"
   else (.merged_since | map(.url + " unknown min") | join(", ")) end) +
  " · new flaw classes " + (.new_flaw_classes|tostring) +
  " · seats started/retired " + (.seats_started|tostring) +
  (if .seats_started == "unknown" then "" else "/" + (.seats_retired|tostring) end)),
"*Focus now and why:* " + .focus_text + " " + .queue_fact,
("*Next steps, in order:* " +
  (.next_steps | to_entries | map("\(.key + 1). " + .value) | join(" · "))),
"*Parked until then:* " + (.parked | join(" · "))
