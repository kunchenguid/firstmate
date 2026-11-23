#!/usr/bin/env bash
# Shared home setup and failure output for the two opt-in agy live tests.

agy_live_stage_home() {  # <throwaway HOME>
  local agy_home=$1 login_keychain="$HOME/Library/Keychains/login.keychain-db"
  mkdir -p "$agy_home/.gemini/antigravity-cli" || return 1
  # macOS searches for the login Keychain under HOME. A link lets agy use
  # the native account session while its trust and settings stay in the lab.
  if [ "$(uname -s)" = Darwin ] && [ -f "$login_keychain" ]; then
    mkdir -p "$agy_home/Library/Keychains" &&
      ln -s "$login_keychain" "$agy_home/Library/Keychains/login.keychain-db"
  fi
}

agy_live_failure_tail() {
  # Drop links, credential fields and opaque credential strings before clipping
  # the output. A failed sign-in can render its authorization link in the pane.
  LC_ALL=C tail -n 40 | sed -E \
    -e 's#https?://[^[:space:]]+#[URL omitted]#g' \
    -e 's#([Bb]earer[[:space:]]+)[^[:space:]]+#\1[credential omitted]#g' \
    -e 's#(ya29\.|1//|4/|AIza|go-keyring-base64:)[A-Za-z0-9_.=+/-]+#[credential omitted]#g' \
    -e 's#[A-Za-z0-9_=+.-]{32,}#[opaque value omitted]#g' |
    LC_ALL=C awk '{
      if (tolower($0) ~ /(access.token|refresh.token|id.token|api.key|client.secret|authorization.code)"?[[:space:]]*[:=]/)
        print "[credential field omitted]"
      else
        print substr($0, 1, 400)
    }'
}
