#!/usr/bin/env bash
# fm-toon-lib.sh - shared TOON renderer for flat snapshot projections.
#
# One owner for the TOON output boundary the agent-facing snapshot wrappers
# share (fm-bearings-snapshot.sh, fm-workstream-snapshot.sh), so the encoder
# cannot drift between them. The model each wrapper feeds it is a flat object
# of scalar fields plus arrays of uniform scalar objects, so the encoder only
# needs object scalars, the tabular array form (key[N]{fields}: + comma rows at
# +2 indent), and the empty-array form (key: []), per the TOON spec. Quoting
# follows the spec exactly.
#
# fm_toon_render reads the JSON model on stdin and prints TOON on stdout;
# non-zero exit means the model could not be rendered, and the caller owns the
# user-facing error message.

fm_toon_render() {
  jq -r '
  def q:
    tostring
    | if (. == "")
        or test("^\\s|\\s$")
        or (. == "true" or . == "false" or . == "null")
        or test("^-?[0-9]+(\\.[0-9]+)?([eE][+-]?[0-9]+)?$")
        or test("[:\"\\\\\\[\\]{},]")
        or test("[[:cntrl:]]")
        or test("^-")
      then "\"" + (gsub("\\\\"; "\\\\") | gsub("\""; "\\\"") | gsub("\n"; "\\n") | gsub("\r"; "\\r") | gsub("\t"; "\\t")) + "\""
      else . end;
  def scal:
    if . == null then "null"
    elif type == "boolean" then (if . then "true" else "false" end)
    elif type == "number" then tostring
    else q end;
  def emit($k; $v):
    if ($v | type) == "array" then
      if ($v | length) == 0 then "\($k): []"
      else
        ($v[0] | keys_unsorted) as $ks
        | ( "\($k)[\($v | length)]{\($ks | map(q) | join(","))}:",
            ($v[] as $row | "  " + ([ $ks[] as $kk | ($row[$kk] | scal) ] | join(","))) )
      end
    else "\($k): " + ($v | scal)
    end;
  [ to_entries[] | emit(.key; .value) ] | join("\n")
'
}
