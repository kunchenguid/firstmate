# Shared validation for captain-facing decisions.
#
# A decision input is a JSON object using the presentation fields already
# established by fm-product-decision.sh: question, context, user_impact,
# options, recommended_option, and recommendation.

fm_decision_validate() {  # <json-file>
  local input=$1
  [ -f "$input" ] && [ ! -L "$input" ] || {
    printf 'fm-decision: input must be a regular non-symlinked file: %s\n' "$input" >&2
    return 1
  }
  [ "$(wc -c < "$input" | tr -d ' ')" -le 16384 ] || {
    printf 'fm-decision: input exceeds 16384 bytes\n' >&2
    return 1
  }
  jq -e '
    . as $x
    | ($x.schema == "fm-captain-decision.v1")
    and ($x.question | type == "string" and length > 0 and length <= 1200)
    and ($x.context | type == "string" and length > 0 and length <= 3000)
    and ($x.user_impact | type == "string" and length > 0 and length <= 1200)
    and ($x.options | type == "array" and length >= 2 and length <= 8)
    and (($x.options | map(.label)) == (["A","B","C","D","E","F","G","H"][:($x.options | length)]))
    and all($x.options[]; (.title | type == "string" and length > 0 and length <= 600)
      and (.pros | type == "array" and length > 0 and length <= 8
        and all(.[]; type == "string" and length > 0 and length <= 1000))
      and (.cons | type == "array" and length > 0 and length <= 8
        and all(.[]; type == "string" and length > 0 and length <= 1000)))
    and ($x.recommended_option | type == "string" and test("^[A-H]$"))
    and any($x.options[]; .label == $x.recommended_option)
    and ($x.recommendation | type == "string" and length > 0 and length <= 2000)
  ' "$input" >/dev/null 2>&1 || {
    printf 'fm-decision: input must include a question, context, user impact, at least two lettered options with pros and cons, and a recommendation naming an available option\n' >&2
    return 1
  }
}

fm_decision_compact() {  # <json-file>; prints canonical compact decision JSON
  jq -cS '{schema:"fm-captain-decision.v1",question,context,user_impact,options,recommended_option,recommendation}' "$1"
}
