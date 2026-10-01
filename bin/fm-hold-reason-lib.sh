#!/usr/bin/env bash
# fm-hold-reason-lib.sh - the one reversible encoding of a captain-hold reason.
#
# tasks-axi stores a hold reason as one markdown line inside a parenthesised tag,
# so its own `hold` refuses parentheses and line breaks. A decision reason is
# ordinary prose, so bin/fm-captain-hold.sh encodes the reason where it writes
# it and every reader that shows it decodes it again, instead of banning the
# characters. Four bytes are escaped as percent codes and nothing else is:
#   %   -> %25     (   -> %28     )   -> %29
#   LF  -> %0A     CR  -> %0D
# Every `%` in an encoded reason therefore begins one of those escapes, which is
# what makes decoding exact whatever the text contains. Semicolons, quotes, and
# every other character pass through tasks-axi unchanged, so they are stored as
# written. A reason written before this encoding that happens to contain one of
# the five escapes literally would decode to the character instead; the
# ordinary case, a reason with no percent sign, is unaffected.
#
# Source this file; it defines functions only.

# fm_hold_reason_encode <reason>: print the storable form, no trailing newline.
fm_hold_reason_encode() {
  local v=$1 lf=$'\n' cr=$'\r'
  v=${v//%/%25}
  v=${v//(/%28}
  v=${v//)/%29}
  v=${v//"$lf"/%0A}
  v=${v//"$cr"/%0D}
  printf '%s' "$v"
}

# fm_hold_reason_decode <stored>: print the original reason, no trailing newline.
# %25 is decoded last so an escaped percent sign can never start another escape.
fm_hold_reason_decode() {
  local v=$1 lf=$'\n' cr=$'\r'
  v=${v//%28/(}
  v=${v//%29/)}
  v=${v//%0A/"$lf"}
  v=${v//%0D/"$cr"}
  v=${v//%25/%}
  printf '%s' "$v"
}

# fm_hold_reason_decode_stream: filter tool output that lists stored reasons
# line by line. A line break cannot survive inside one listed row, so the two
# line-break escapes become a space and nothing here ever joins or splits rows.
fm_hold_reason_decode_stream() {
  sed -e 's/%0A/ /g' -e 's/%0D//g' -e 's/%28/(/g' -e 's/%29/)/g' -e 's/%25/%/g'
}
