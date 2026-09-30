#!/usr/bin/env bash
# Quarantined rendered-surface adapter for Gemini CLI 0.62.0 / Herdr 0.7.4.
# Source through fm-composer-lib.sh; its helpers provide ANSI/content handling.
# This pin describes the verified layout, not a generic Gemini UI contract.
# Standing debt: vendor rendering is expected to break on upgrade; refresh
# tests/fm-gemini-composer-live-e2e.test.sh before extending this adapter's pin.
# Verification and limitations: docs/verification/runtime-backends.md,
# "Gemini half-block composer on Herdr".

# Gemini's half-block composer requires native Gemini idle/done identity as
# well as geometry.
# The asterisk is not a generic agent glyph: accepting it globally would make
# arbitrary transcript bullets injectable. Only the final three-row envelope
# is eligible, with no lower prompt or structure; blocked/working identities
# never authorize lifecycle text, even when the input region looks empty.
# Only a complete workspace/branch/sandbox/model footer proves the trailing
# rows are furniture: its values must name an absolute path, branch, no sandbox
# and Auto model selection. Other layouts fail closed until verified.
_fm_composer_adapter_gemini_0_62_0() {  # <screen> <plain> <styled> <has-identity> <identity> <cursor>
  local screen=$1 plain=$2 styled=$3 has_identity=$4 identity=$5 cy=$6
  local row=0 top=-1 input=-1 bottom=-1 line trimmed width=0 content agent status footer=0
  local header_re='^workspace \(/directory\)[[:space:]]+branch[[:space:]]+sandbox[[:space:]]+/model$'
  local values_re='^/[^[:space:]]+[[:space:]]+[A-Za-z0-9_./-]+[[:space:]]+no sandbox[[:space:]]+Auto$'
  while IFS= read -r line; do
    trimmed=$line
    fm_composer_normalize_trim_var trimmed
    case "$trimmed" in
      ▄▄▄▄▄▄▄▄*)
        if [ -z "${trimmed//▄/}" ]; then top=$row; width=${#trimmed}; input=-1; bottom=-1; fi
        ;;
      ▀▀▀▀▀▀▀▀*)
        if [ "$top" -ge 0 ] && [ "$row" -eq "$((top + 2))" ] \
           && [ -z "${trimmed//▀/}" ] && [ "${#trimmed}" -eq "$width" ]; then bottom=$row; fi
        ;;
      '* '*|'*')
        [ "$top" -ge 0 ] && [ "$row" -eq "$((top + 1))" ] && input=$row
        ;;
    esac
    if [ "$input" -ge 0 ] && [ "$bottom" -ge 0 ] && [ "$row" -gt "$bottom" ]; then
      if fm_composer_row_has_edge "$trimmed" \
         || fm_composer_leading_prompt_glyph_var content "$trimmed"; then printf unknown; return 0; fi
      if [ "$row" -eq "$((bottom + 1))" ]; then
        [[ "$trimmed" =~ $header_re ]] || { printf unknown; return 0; }
        footer=1
      elif [ "$footer" = 1 ] && [ "$row" -eq "$((bottom + 2))" ]; then
        [[ "$trimmed" =~ $values_re ]] || { printf unknown; return 0; }
        footer=2
      else
        printf unknown; return 0
      fi
    fi
    row=$((row + 1))
  done <<EOF
$plain
EOF
  [ "$input" -ge 0 ] && [ "$bottom" -ge 0 ] && [ "$((row - bottom))" -le 3 ] || return 1
  [ "$footer" = 2 ] || { printf unknown; return 0; }
  [ -z "$cy" ] || [ "$cy" = "$input" ] || return 1
  [ "$has_identity" = 1 ] || { printf unknown; return 0; }
  [ -n "$identity" ] || { printf need-identity; return 0; }
  agent=${identity%%$'\t'*}
  status=${identity#*$'\t'}
  [ "$agent" = gemini ] || { printf unknown; return 0; }
  case "$status" in idle|done) ;; *) printf unknown; return 0 ;; esac
  content=$(_fm_composer_row_content "$(_fm_composer_screen_row "$input" "$screen")" "$styled")
  fm_composer_normalize_trim_var content
  # Strip exactly the proven prompt, never a later asterisk in a draft.
  case "$content" in '* '*|'*') content=${content#\*} ;; *) printf unknown; return 0 ;; esac
  fm_composer_normalize_trim_var content
  if [ -z "$content" ]; then printf empty; else printf pending; fi
}

