# shellcheck shell=bash
# Shared fm-decision-card.v1 contract for an authored captain-call card.
# Usage: . bin/fm-decision-card-lib.sh; splice "$FM_DECISION_CARD_JQ_DEFS"
# ahead of a jq program, then test a card with `call_item`, name the first
# broken invariant with `call_reasons`, or accept a durable record that already
# carries the injected reconcile choice with `stored_call_item`.
#
# ONE OWNER for the authored-card contract. Three surfaces answer the same
# question - "is this a well-formed card the captain can be shown": the payload
# validator in bin/fm-bearings-board.sh, the raise-time writer in
# bin/fm-captain-hold.sh, and the board build's read of a durable record it
# merges back into the payload. A second copy of these rules would drift, so
# they live here and every surface splices them in.
#
# The authored form reserves the `reconcile` option value: the board build
# injects that choice itself on every decision card, so an author - an agent or
# a flag - must never supply it. `stored_call_item` is the reader-side form for
# the durable store, whose records are the EFFECTIVE cards and therefore carry
# that injected choice exactly once.

# shellcheck disable=SC2034,SC2016
FM_DECISION_CARD_JQ_DEFS='
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
    def reconcile_options:
      [ ((.options // []) | .[] | select(type == "object" and .value == "reconcile")) ];
    def without_reconcile:
      if type == "object" and (.options | type == "array")
        then .options = [.options[] | select((type == "object" and .value == "reconcile") | not)]
        else . end;
    def stored_call_item:
      type == "object"
      and ((reconcile_options | length) <= 1)
      and ([reconcile_options[]
        | type == "object"
          and (.label | nonempty_string)
          and optional_string("hint")] | all)
      and (without_reconcile | call_item);
    # Best-effort message ladder for humans. `call_item` is the contract; this
    # names the first invariant an author most likely broke, so a refusal can
    # say what to fix instead of restating the schema.
    def call_reasons:
      if type != "object" then ["card must be a JSON object"]
      elif (.key | slug(128) | not) then ["key must be a non-empty [A-Za-z0-9._-] slug of at most 128 characters"]
      elif (.type != "decision" and .type != "merge" and .type != "credential") then ["type must be decision, merge, or credential"]
      elif (repo_marker | not) then ["repo must be present and be a string or null"]
      elif (.title | nonempty_string | not) then ["title must be a non-empty string"]
      elif (.options | type == "array" | not) then ["options must be an array"]
      elif ((.options | length) == 0 and .allow_freeform != true) then ["a card needs at least one option or allow_freeform true"]
      elif ([.options[]
        | type == "object"
          and (.value | slug(128))
          and (.label | nonempty_string)
          and optional_string("hint")] | all | not) then ["every option needs a [A-Za-z0-9._-] value and a non-empty label, with an optional string hint"]
      elif (optional_string("about") | not) then ["about must be a string"]
      elif (optional_string("decide") | not) then ["decide must be a string"]
      elif (optional_string("detail") | not) then ["detail must be a string"]
      elif (optional_https_url("pr_url") | not) then ["pr_url must be an https URL"]
      elif (optional_subject | not) then ["subject must be {artifact: slug, version: 3-part version}"]
      elif (has("subject") and .type != "decision") then ["subject belongs to a decision card only"]
      elif (optional_string("freeform_hint") | not) then ["freeform_hint must be a string"]
      elif (has("close") and .close != "done" and .close != "release") then ["close must be done or release"]
      elif (has("allow_freeform") and (.allow_freeform | type != "boolean")) then ["allow_freeform must be a boolean"]
      elif (has("recommend_value")
        and (.recommend_value as $recommend
          | ((.recommend_value | slug(128) | not)
            or ([.options[].value] | index($recommend) == null))))
        then ["recommend_value must name one of the authored option values"]
      elif ([.options[].value] | index("reconcile") != null) then ["reconcile is reserved: the board build injects that choice itself"]
      elif (.type == "merge" and (.risk | nonempty_string | not)) then ["a merge card needs a non-empty risk"]
      else [] end;
'
