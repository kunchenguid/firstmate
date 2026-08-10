# Structural readiness checklist for a captain decision filed with structured
# context. Every consumer applies this one definition to the decision's body
# lines, so the filing command, the read-only sweep, and the board cannot drift
# apart. The input to each entry point is the decision body split into lines.
#
# These checks are presence and shape only. Whether the question is clear, the
# recommendation sound, or the linked surface genuinely built stays a judgement
# no script makes; `.agents/skills/decision-hold-lifecycle/SKILL.md` owns it.

# jq has no builtin trim here, and a consumer may define its own; this module
# keeps a private one so the checklist never depends on the caller's program.
def decision_trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");

def decision_structured_labels:
  ["Decision question", "Decision options", "Decision kind", "Decision expects",
   "Decision group", "Why now", "What it affects", "Recommendation",
   "Decision URL", "No decision surface"];

# Leading whitespace is removed before matching so a caller may pass a body
# however it reads it: rendered backlog lines arrive indented, and an in-memory
# body does not. The label marker is recognized independently of its value so an
# explicitly empty structured field still brings the decision into scope.
def decision_body_field($label):
  ([ .[]?
     | select(type == "string")
     | sub("^[[:space:]]*"; "")
     | select(startswith($label + ":"))
     | ltrimstr($label + ":")
     | decision_trim ] | last) // null;

def decision_field_present($label):
  decision_body_field($label) as $value
  | $value != null and ($value | decision_trim | length) > 0;

# A decision carries structured context when any structured label is present.
# A decision held with only a free-text reason has none of them, which is how
# that deliberately preserved older shape stays outside this checklist.
def decision_structured:
  . as $lines
  | ([ decision_structured_labels[] as $label
       | $lines
       | decision_body_field($label)
       | select(. != null) ] | length) > 0;

# The same option-set shape the filing command enforces, applied to the raw
# stored value so a malformed set stays visible instead of reading as absent.
def decision_options_valid:
  (try fromjson catch null) as $parsed
  | if ($parsed | type) != "array" then false
    elif ($parsed | length) < 2 or ($parsed | length) > 4 then false
    elif ($parsed | all(.[]; type == "string") | not) then false
    else
      ($parsed | all(.[];
        length > 0 and utf8bytelength <= 80 and . == decision_trim))
      and ($parsed | (unique | length) == length)
    end;

def decision_readiness:
  . as $lines
  | if ($lines | decision_structured | not)
    then { structured: false, ready: true, gaps: [] }
    else
      [ (if ($lines | decision_field_present("Decision question")) then empty
         else { check: "question", flag: "--question",
                detail: "the decision question is missing" } end),

        (if ($lines | decision_field_present("Recommendation")) then empty
         else { check: "recommendation", flag: "--recommendation",
                detail: "the recommendation is missing" } end),

        (($lines | decision_field_present("Decision URL")) as $has_url
         | ($lines | decision_field_present("No decision surface")) as $has_none
         | if $has_url and $has_none
           then { check: "surface", flag: "--decision-url or --no-surface",
                  detail: "it records both a link to look at and a note that none applies" }
           elif ($has_url or $has_none) then empty
           else { check: "surface", flag: "--decision-url or --no-surface",
                  detail: "neither a link to look at nor a note that none applies is recorded" }
           end),

        (($lines | decision_body_field("Decision options")) as $options
         | if $options == null or ($options | decision_options_valid) then empty
           else { check: "options", flag: "--option",
                  detail: "the answer options are not two to four distinct short labels" }
           end),

        (if ($lines | decision_body_field("Decision kind")) == "fact"
              and (($lines | decision_field_present("Decision expects")) | not)
         then { check: "expects", flag: "--expects",
                detail: "it asks the captain for a fact without saying what answer shape it expects" }
         else empty end)
      ] as $gaps
      | { structured: true, ready: (($gaps | length) == 0), gaps: $gaps }
    end;

# One plain-English line naming every gap, for a reader who needs the summary
# rather than the structure.
def decision_readiness_detail:
  [ .gaps[]?.detail ] | join("; ");
