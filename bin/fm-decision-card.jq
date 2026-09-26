# The decision-card contract for one Captain's Call item.
#
# One definition owns the card wherever it crosses a surface: the
# captains_call items in bin/fm-bearings-board.sh's fm-bearings-board.v1
# payload and the durable fm-decision-card.v1 records under
# <home>/state/decision-cards/<task>.json. bin/fm-decision-card-lib.sh owns
# that store (validate, make effective, persist, remove);
# bin/fm-captain-hold.sh fills it when a call is held and clears it when the
# call resolves, while bin/fm-bearings-board.sh refreshes every card a build
# shows.
#
# `reconcile` is reserved: the board injects the standard reconcile_option on
# every decision card, and no composed input may occupy that value.
# docs/captain-hold-lifecycle.md owns why it can never close a call.

def nonempty_string: type == "string" and length > 0;
def slug($max): type == "string" and test("^[A-Za-z0-9._-]{1," + ($max | tostring) + "}$");
def repo_marker: has("repo") and (.repo == null or (.repo | type == "string"));
def optional_string($name): (has($name) | not) or (.[$name] | type == "string");
def optional_https_url($name):
  (has($name) | not)
  or (.[$name]
    | type == "string"
      and test("^https://[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?(?:[/?#][^[:space:]]*)?$"));
def version: type == "string" and test("^(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})$");
def optional_subject:
  (has("subject") | not)
  or (.subject
    | type == "object"
      and (keys | sort) == ["artifact", "version"]
      and (.artifact | slug(128))
      and (.version | version));

# The one standard reconcile choice. The board and the hold-time store both
# add it to a decision card that lacks one, and the deck renders it as the
# Reconcile option.
def reconcile_option:
  {
    value: "reconcile",
    label: "Reconcile",
    hint: "Re-check the latest state, then close this with evidence or keep it open with a note"
  };

def call_item:
  type == "object"
  and (.key | slug(128))
  and (.type == "decision" or .type == "merge" or .type == "credential")
  and repo_marker
  and (.title | nonempty_string)
  and (.options | type == "array")
  and ((.options | length) > 0 or .allow_freeform == true)
  and ([.options[]
    | type == "object"
      and (.value | slug(128))
      and (.label | nonempty_string)
      and optional_string("hint")] | all)
  and (optional_string("about"))
  and (optional_string("decide"))
  and (optional_string("detail"))
  and (optional_https_url("pr_url"))
  and optional_subject
  and (if has("subject") then .type == "decision" else true end)
  and (optional_string("freeform_hint"))
  and ((has("close") | not) or (.close == "done" or .close == "release"))
  and ((has("allow_freeform") | not) or (.allow_freeform | type == "boolean"))
  and ((has("recommend_value") | not)
    or ((.recommend_value | slug(128))
      and (.recommend_value as $recommend
        | ([.options[].value] | index($recommend) != null))))
  and ([.options[].value] | index("reconcile") == null)
  and (if .type == "merge" then (.risk | nonempty_string) else true end);
