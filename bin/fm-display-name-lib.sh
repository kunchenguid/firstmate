#!/usr/bin/env bash
# fm-display-name-lib.sh - single owner of task display-name validation and fallback.
#
# A display name is presentation only.
# Immutable task ids, state/<id>.meta filenames, backend targets, endpoint task
# bindings, incarnation tokens, worktrees, routing, control, recovery, and cleanup
# never resolve through this value.
#
# Contract:
#   - one non-empty line, with no leading or trailing whitespace;
#   - at most 64 characters and 96 UTF-8 bytes;
#   - printable ASCII plus U+00B7 MIDDLE DOT only;
#   - no path separators, parent-path token, shell/metadata delimiters, URL form,
#     common credential form, version, task or branch slug, delivery mechanic,
#     or random or secret-like suffix.
# The narrow character set rejects control and invisible transport characters by
# construction while retaining the documented "Project · Outcome" form.
#
# fm_display_name_validate <value> returns 0 when valid and otherwise prints one
# concise diagnostic to stderr.
# fm_display_name_fallback <task-id> derives a bounded readable presentation for
# legacy metadata. It rejects unsafe source values, removes version, random,
# branch, task-shape, and delivery-mechanics tokens, converts separators to
# words, title-cases ordinary words, preserves common technical acronyms, and
# inserts a middle dot after the first word. It never mutates or replaces the
# task id.
# fm_display_name_for_meta <meta> <task-id> returns the one valid display_name=
# value when present, otherwise the safe fallback. Missing, duplicated, or
# malformed historical values are read compatibly and are not migrated in place.

FM_DISPLAY_NAME_MAX_CHARS=64
FM_DISPLAY_NAME_MAX_BYTES=96

fm_display_name_error() {
  printf 'error: invalid display name: %s\n' "$1" >&2
  return 1
}

fm_display_name_contains_aws_access_key() {
  printf '%s' "${1-}" | LC_ALL=C grep -Eq '(^|[^A-Z0-9])(AKIA|ASIA)[A-Z0-9]{16}([^A-Z0-9]|$)'
}

fm_display_name_contains_scp_path() {
  printf '%s' "${1-}" | LC_ALL=C grep -Eq '(^|[^A-Za-z0-9._-])[-A-Za-z0-9._]+@[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?:[-A-Za-z0-9._~]+([^A-Za-z0-9._~-]|$)'
}

fm_display_name_validate() {  # <value>
  local value=${1-} ascii bytes chars lower
  [ -n "$value" ] || fm_display_name_error 'must not be empty' || return 1
  case "$value" in
    *$'\n'*|*$'\r'*|*$'\t'*) fm_display_name_error 'must be a single line without control characters'; return 1 ;;
    ' '*|*' ') fm_display_name_error 'must be trimmed'; return 1 ;;
  esac

  bytes=$(printf '%s' "$value" | LC_ALL=C wc -c | tr -d '[:space:]')
  chars=${#value}
  [ "$bytes" -le "$FM_DISPLAY_NAME_MAX_BYTES" ] 2>/dev/null \
    && [ "$chars" -le "$FM_DISPLAY_NAME_MAX_CHARS" ] 2>/dev/null \
    || { fm_display_name_error "must be at most $FM_DISPLAY_NAME_MAX_CHARS characters and $FM_DISPLAY_NAME_MAX_BYTES UTF-8 bytes"; return 1; }

  ascii=${value//·/}
  if printf '%s' "$ascii" | LC_ALL=C grep -q '[^ -~]'; then
    fm_display_name_error 'allows printable ASCII and the middle dot only'
    return 1
  fi
  case "$value" in
    */*|*\\*|*'..'*|~*|.*) fm_display_name_error 'must not contain a path-like value'; return 1 ;;
    *'='*|*'$'*|*'`'*|*'{'*|*'}'*|*'['*|*']'*|*'<'*|*'>'*|*'|'*|*';'*)
      fm_display_name_error 'contains a transport or shell delimiter'; return 1 ;;
  esac
  if printf '%s' "$value" | LC_ALL=C grep -Eq '(^|[ ·_-])[A-Za-z]:([^ ]|$)'; then
    fm_display_name_error 'must not contain a path-like value'
    return 1
  fi
  if fm_display_name_contains_aws_access_key "$value" \
     || fm_display_name_contains_scp_path "$value"; then
    fm_display_name_error 'must not contain a URL, path, or credential-like value'
    return 1
  fi
  lower=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
  if printf '%s' "$lower" | LC_ALL=C grep -Eq '(^|[ ·_-])(file|ssh):'; then
    fm_display_name_error 'must not contain a URL, path, or credential-like value'
    return 1
  fi
  case "$lower" in
    *'://'*|*'-----begin '*|bearer\ *|*' bearer '*|*xox[baprs]-*|*aiza[0-9a-z_-]*|*eyj[0-9a-z_-]*|ghp_*|github_pat_*|*glpat-[a-z0-9_-]*|sk-[a-z0-9]*|*'password:'*|*'secret:'*|*'token:'*|*'api key:'*|*'api-key:'*)
      fm_display_name_error 'must not contain a URL, path, or credential-like value'; return 1 ;;
  esac
  if printf '%s' "$lower" | LC_ALL=C grep -Eq '(^|[ ·_-])(v([ ]*|ersion[ ]*)[0-9]+([.][0-9]+)*|[0-9]+[.][0-9]+)([ _-]|$)'; then
    fm_display_name_error 'must not contain a version'
    return 1
  fi
  if printf '%s' "$value" | LC_ALL=C grep -Eq '^[a-z0-9]+([_-][a-z0-9]+)+$' \
     || printf '%s' "$lower" | LC_ALL=C grep -Eq '(^|[ ·_-])(feature|fix|bugfix|hotfix|chore|refactor|release)([ :_-]|$)' \
     || printf '%s' "$lower" | LC_ALL=C grep -Eq '(^|[ ·_-])(main|master|trunk|develop|development)([ ·_-]|$)'; then
    fm_display_name_error 'must not be a task slug or branch name'
    return 1
  fi
  if printf '%s' "$lower" | LC_ALL=C grep -Eq '(^|[ ·_-])(open[ ·_-]+pr|pull[ ·_-]+request|direct[ ·_-]+pr|merge|deploy|deployment|release|ship|shipping)([ ·_-]|$)'; then
    fm_display_name_error 'must not describe delivery mechanics'
    return 1
  fi
  if printf '%s' "$value" | LC_ALL=C grep -Eq '[A-Za-z0-9_-]{24,}' \
     || printf '%s' "$lower" | LC_ALL=C grep -Eq '(^|[ ·_-])([a-z][0-9]{1,3}|[a-z][a-z0-9]*[0-9][a-z0-9]{5,}|[0-9][a-z0-9]*[a-z][a-z0-9]{5,})([ ]*)$'; then
    fm_display_name_error 'must not contain a random or secret-like suffix'
    return 1
  fi
  return 0
}

fm_display_name_fallback() {  # <task-id>
  local raw=${1-} id out word low pretty first rest lower ascii
  local -a words clean
  raw=${raw#fm-}
  lower=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
  ascii=${raw//·/}
  case "$raw" in
    ''|*$'\n'*|*$'\r'*|*$'\t'*|*/*|*\\*|*'..'*|~*|.*|*'='*|*'$'*|*'`'*|*'{'*|*'}'*|*'['*|*']'*|*'<'*|*'>'*|*'|'*|*';'*)
      printf 'Task'
      return 0
      ;;
  esac
  if printf '%s' "$ascii" | LC_ALL=C grep -q '[^ -~]' \
     || fm_display_name_contains_aws_access_key "$raw" \
     || fm_display_name_contains_scp_path "$raw" \
     || printf '%s' "$lower" | LC_ALL=C grep -Eq '(^|[^a-z0-9])(file:|ssh:|https?://|bearer |xox[baprs]-|aiza[0-9a-z_-]*|eyj[0-9a-z_-]*|ghp_|github_pat_|glpat-|sk-[a-z0-9]{16,}|password:|secret:|token:|api[ _-]?key:)'; then
    printf 'Task'
    return 0
  fi

  id=$(printf '%s' "$raw" | sed -E 's/[-_.]+/ /g; s/[^A-Za-z0-9 ]+/ /g; s/^[ ]+//; s/[ ]+$//')
  IFS=' ' read -r -a words <<< "$id"
  set -- "${words[@]}"
  while [ "$#" -gt 0 ]; do
    word=$1
    shift
    low=$(printf '%s' "$word" | tr '[:upper:]' '[:lower:]')
    case "$low" in
      feature|fix|bugfix|hotfix|chore|refactor|release|main|master|trunk|develop|development|open|pull|request|direct|pr|merge|deploy|deployment|ship|shipping)
        continue
        ;;
      v|version)
        if [ "$#" -gt 0 ] && printf '%s' "$1" | LC_ALL=C grep -Eq '^[0-9]+([.][0-9]+)*$'; then
          shift
          continue
        fi
        ;;
    esac
    if printf '%s' "$low" | LC_ALL=C grep -Eq '^v[0-9]+([.][0-9]+)*$|^[0-9]+[.][0-9]+$'; then
      continue
    fi
    if [ "$#" -eq 0 ] && printf '%s' "$low" | LC_ALL=C grep -Eq '^([a-z][0-9]{1,3}|[a-z][a-z0-9]*[0-9][a-z0-9]{5,}|[0-9][a-z0-9]*[a-z][a-z0-9]{5,})$'; then
      continue
    fi
    clean+=("$low")
  done

  out=
  set -- "${clean[@]}"
  while [ "$#" -gt 0 ]; do
    low=$1
    shift
    case "$low" in
      api|ci|cli|cpu|crm|css|db|dns|gpu|html|http|https|id|ios|ip|json|jwt|macos|qa|sdk|sql|ssh|tls|tui|ui|url|ux|xml)
        pretty=$(printf '%s' "$low" | tr '[:lower:]' '[:upper:]')
        ;;
      *)
        first=$(printf '%s' "$low" | cut -c1 | tr '[:lower:]' '[:upper:]')
        rest=$(printf '%s' "$low" | cut -c2-)
        pretty=$first$rest
        ;;
    esac
    if [ -z "$out" ]; then
      out=$pretty
      [ "$#" -eq 0 ] || out="$out ·"
    else
      out="$out $pretty"
    fi
  done
  [ -n "$out" ] || out=Task
  if [ "${#out}" -gt "$FM_DISPLAY_NAME_MAX_CHARS" ]; then
    out=${out:0:$FM_DISPLAY_NAME_MAX_CHARS}
    out=${out%"${out##*[! ]}"}
  fi
  fm_display_name_validate "$out" >/dev/null 2>&1 || out=Task
  printf '%s' "$out"
}

fm_display_name_for_meta() {  # <meta-file> <task-id>
  local meta=$1 id=$2 count value
  count=$(grep -c '^display_name=' "$meta" 2>/dev/null || true)
  if [ "$count" -eq 1 ]; then
    value=$(grep '^display_name=' "$meta" | cut -d= -f2-)
    if fm_display_name_validate "$value" >/dev/null 2>&1; then
      printf '%s' "$value"
      return 0
    fi
  fi
  fm_display_name_fallback "$id"
}
