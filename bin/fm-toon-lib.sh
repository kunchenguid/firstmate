#!/usr/bin/env bash
# fm-toon-lib.sh - the single owner of firstmate's JSON-to-TOON rendering.
#
# Sourced, never executed.
#
# AXI-style commands keep their internal model as JSON (`--json` prints it
# verbatim) and render TOON only at the output boundary, so TOON and JSON stay
# parity representations of one model. Every such command renders through this
# one function rather than carrying its own copy of the rules.
#
#   fm_toon_render
#       Reads one JSON object on stdin and prints its TOON form on stdout.
#       Exit status is jq's, so a caller can refuse to print a partial render.
#
# Forms, per the TOON spec:
#   - scalars:               key: value
#   - nested objects:        key: then the object's keys indented by two spaces
#   - empty arrays:          key: []
#   - arrays of scalars:     key[N]: a,b,c
#   - arrays of objects:     key[N]{f1,f2}: then one comma row per element at
#                            +2 indent, with the fields taken from the first
#                            element in its key order
# A string is quoted when it is empty, has leading or trailing whitespace, reads
# as a boolean, null, or number, contains a delimiter or control character, or
# starts with "-"; quoting escapes backslash, quote, newline, return, and tab.
#
# Requires jq on PATH; callers check for it before rendering.

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
    if ($v | type) == "object" then
      "\($k): ", ($v | to_entries[] | emit(.key;.value) | "  " + .)
    elif ($v | type) == "array" then
      if ($v | length) == 0 then "\($k): []"
      elif all($v[]; type != "object" and type != "array") then
        "\($k)[\($v | length)]: " + ([ $v[] | scal ] | join(","))
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
