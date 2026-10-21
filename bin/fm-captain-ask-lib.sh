# shellcheck shell=bash
# Shared structured-ask rule for captain-held decisions.
# Usage: . bin/fm-captain-ask-lib.sh; splice "$FM_CAPTAIN_ASK_JQ_DEFS" ahead of
# a jq program, then call `captain_ask_problems` or `captain_ask_normalize`.
#
# ONE OWNER for what a stored captain ask may contain. bin/fm-captain-hold.sh
# validates and normalizes an ask before it stores one, and
# bin/fm-fleet-snapshot.sh re-validates every stored ask before it publishes it
# as decisions_open[].ask. Both answer the one question "may the dashboard
# render this ask", so the rule lives here and neither restates it.
#
# The shape is the dashboard's FleetAsk:
#   {question, options?: [{id?, label, recommended?}], free_text_allowed?, link?}
# The rule is structural only: the question and every label are non-empty text,
# there are at most 6 options, at most one is recommended, option ids are unique
# slugs, and unknown fields are rejected rather than passed through. It does not
# inspect the wording of the text.
#
# `captain_ask_problems` returns an array of plain-English problems, empty for a
# valid ask. `captain_ask_normalize` takes a valid ask and returns the stored
# form: trimmed text, every option given an explicit id (its 1-based position
# when absent), label, and recommended flag, the recommended option first, and
# explicit free_text_allowed and link values.

# shellcheck disable=SC2016,SC2034 # consumed by the scripts that source this library
FM_CAPTAIN_ASK_JQ_DEFS='
def captain_ask_trim: sub("^\\s+"; "") | sub("\\s+$"; "");
def captain_ask_text_problems($name):
  if type != "string" then ["\($name) must be text"]
  elif (captain_ask_trim | length) == 0 then ["\($name) must not be empty"]
  else [] end;
def captain_ask_option_problems($n):
  if type != "object" then ["option \($n) must be an object"]
  else
    [keys[] | select(IN("id", "label", "recommended") | not) | "option \($n) has unknown field \(.)"]
    + (if has("label") then (.label | captain_ask_text_problems("option \($n) label"))
       else ["option \($n) needs a label"] end)
    + (if has("id") and ((.id | type) != "string"
          or (.id | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$") | not))
       then ["option \($n) id must be a slug of at most 64 characters"] else [] end)
    + (if has("recommended") and ((.recommended | type) != "boolean")
       then ["option \($n) recommended must be true or false"] else [] end)
  end;
def captain_ask_options_problems:
  if type != "array" then ["options must be a list"]
  elif length > 6 then ["at most 6 options are allowed"]
  else
    ([to_entries[] | .key as $i | .value | captain_ask_option_problems($i + 1)] | add // [])
    + (if ([.[] | select(type == "object" and .recommended == true)] | length) > 1
       then ["at most one option may be recommended"] else [] end)
    + ([to_entries[] | select(.value | type == "object")
        | (.value.id // (.key + 1 | tostring))]
       | if length != (unique | length) then ["option ids must be unique"] else [] end)
  end;
def captain_ask_problems:
  if type != "object" then ["the ask must be a JSON object"]
  else
    [keys[] | select(IN("question", "options", "free_text_allowed", "link") | not) | "unknown ask field \(.)"]
    + (if has("question") then (.question | captain_ask_text_problems("question"))
       else ["question is required"] end)
    + (if has("options") then (.options | captain_ask_options_problems) else [] end)
    + (if has("free_text_allowed") and ((.free_text_allowed | type) != "boolean")
       then ["free_text_allowed must be true or false"] else [] end)
    + (if (.link // null) == null then []
       elif (.link | type) == "string" and (.link | length) <= 2048
         and (.link | test("^https?://[^\\s]+$")) then []
       else ["link must be an http or https URL"] end)
  end;
def captain_ask_valid: captain_ask_problems | length == 0;
def captain_ask_normalize:
  { question: (.question | captain_ask_trim),
    options: ([(.options // []) | to_entries[]
               | { id: (.value.id // (.key + 1 | tostring)),
                   label: (.value.label | captain_ask_trim),
                   recommended: (.value.recommended == true) }]
              | map(select(.recommended)) + map(select(.recommended | not))),
    free_text_allowed: (.free_text_allowed == true),
    link: (.link // null) };
'
