# shellcheck shell=bash
# fm-hold-ask-lib.sh - the one contract for a captain hold's structured ask.
#
# A captain hold whose restart condition is the captain's answer may carry an
# ask: the question, the options that answer it, whether a free-text answer is
# accepted, and an optional link to more context. bin/fm-captain-hold.sh
# `hold --ask-file` validates, normalizes, and writes it at hold time, and
# bin/fm-fleet-snapshot.sh reads it back. Neither reads hold reason or body
# prose to guess an ask: a hold without this structured line has no ask.
#
# Storage: one task body line `Captain hold ask: <compact JSON>`, written beside
# the `Captain hold set:` stamp. It belongs to the hold lifecycle that wrote it:
# repeating an active hold without --ask-file keeps it, while a hold that starts
# a new lifecycle drops it unless a new ask is given.
#
# Shape, enforced by `hold_ask_valid` on write and on every read:
#   question           non-empty string, at most 500 characters
#   options            at most 6 {id,label,recommended} objects; ids unique,
#                      matching [A-Za-z0-9][A-Za-z0-9._-]* (at most 64), and never
#                      the reserved answer value `reconcile`; labels non-empty,
#                      at most 120 characters; at most one recommended
#   free_text_allowed  boolean; an ask with no options must allow free text
#   link               non-empty string of at most 500 characters, or null
# No other key is accepted. `hold_ask_normalize` keeps options in the order the
# hold author wrote them and records an absent link as null. A stored line that
# does not parse or validate reads back as no ask rather than a partial one.
#
# Splice "$FM_HOLD_ASK_JQ_DEFS" ahead of a jq program.

# shellcheck disable=SC2016,SC2034 # jq program: $vars must stay literal; output global, read by the sourcing caller.
FM_HOLD_ASK_JQ_DEFS='
  def hold_ask_prefix: "Captain hold ask: ";
  def hold_ask_bounded_string($max):
    type == "string" and length > 0 and length <= $max and test("\\S");
  def hold_ask_option_valid:
    type == "object"
    and ((keys - ["id","label","recommended"]) | length) == 0
    and (.id | type) == "string"
    and (.id | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"))
    and .id != "reconcile"
    and (.label | hold_ask_bounded_string(120))
    and (.recommended | type) == "boolean";
  def hold_ask_valid:
    type == "object"
    and ((keys - ["question","options","free_text_allowed","link"]) | length) == 0
    and (.question | hold_ask_bounded_string(500))
    and (.options | type) == "array"
    and (.options | length) <= 6
    and all(.options[]; hold_ask_option_valid)
    and ([.options[].id] | unique | length) == (.options | length)
    and ([.options[] | select(.recommended)] | length) <= 1
    and (.free_text_allowed | type) == "boolean"
    and ((.options | length) > 0 or .free_text_allowed)
    and (.link == null or (.link | hold_ask_bounded_string(500)));
  def hold_ask_normalize:
    {question,
     options:(.options | map({id,label,recommended})),
     free_text_allowed,
     link:(.link // null)};
  def hold_ask_from_lines:
    ([.[]? | select(type == "string" and startswith(hold_ask_prefix))][0] // null) as $line
    | if $line == null then null
      else (try ($line[(hold_ask_prefix | length):] | fromjson) catch null)
        | if . != null and hold_ask_valid then hold_ask_normalize else null end
      end;
'
