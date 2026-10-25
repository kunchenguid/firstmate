#!/usr/bin/env bash
# fm-owner-rules-tree.sh <backlog-file> - print parent chains and items with invalid parents.
set -eu
[ "$#" -eq 1 ] || { echo "usage: fm-owner-rules-tree.sh <backlog-file>" >&2; exit 2; }
[ -r "$1" ] || { echo "fm-owner-rules-tree: cannot read backlog file: $1" >&2; exit 1; }

awk '
function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
function save_item(    fields, rest) {
  if (!id) return
  count++
  order[count] = id
  titles[id] = title
  parents[id] = parent
  id = title = parent = ""
}
/^- \[[^]]\] / {
  save_item()
  rest = substr($0, 7)
  split(rest, fields, /[[:space:]]+/)
  id = fields[1]
  sub(/^[^[:space:]]+[[:space:]]+-[[:space:]]*/, "", rest)
  title = rest
  next
}
id && /^[[:space:]]*parent:[[:space:]]*/ {
  value = $0
  sub(/^[[:space:]]*parent:[[:space:]]*/, "", value)
  parent = trim(value)
}
END {
  save_item()
  print "Parent chains:"
  for (i = 1; i <= count; i++) {
    start = order[i]
    current = start
    chain = start
    delete seen
    invalid = 0
    while (1) {
      if (seen[current]) {
        chain = chain " -> [cycle: " current "]"
        invalid = 1
        break
      }
      seen[current] = 1
      parent_id = parents[current]
      if (parent_id == "") {
        if (titles[current] ~ /^\[captain-ask\]/) chain = chain " -> [epic root]"
        else { chain = chain " -> [no parent]"; invalid = 1 }
        break
      }
      if (parent_id == "upkeep") { chain = chain " -> [upkeep]"; break }
      if (!(parent_id in titles)) {
        chain = chain " -> [missing: " parent_id "]"
        invalid = 1
        break
      }
      chain = chain " -> " parent_id
      current = parent_id
    }
    print "  " start ": " chain
    if (invalid) bad[++bad_count] = start
  }
  print "Items with no valid parent:"
  if (!bad_count) print "  (none)"
  for (i = 1; i <= bad_count; i++) print "  " bad[i]
}
' "$1"
