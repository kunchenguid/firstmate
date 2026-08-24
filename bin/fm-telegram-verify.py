#!/usr/bin/env python3
"""Verify the signed initData a Telegram Mini App hands to its page.

Telegram appends an initData string to every Mini App load
(window.Telegram.WebApp.initData). It carries user, auth_date, query_id and a
hash. The hash is an HMAC-SHA256 over the alphabetically sorted "key=value"
lines, keyed by a secret only the holder of the bot token can derive:

    secret = HMAC_SHA256(key="WebAppData", msg=<bot-token>)
    hash   = HMAC_SHA256(key=secret,       msg=<sorted lines>)

Skipping that computation means accepting any POST body at all: a stranger who
knows the page's address - it is public, it travels in the button and in the
network trace - could drop arbitrary answers into the captain's inbox and have
firstmate act on them.

Three checks, not one, because a valid signature alone is not enough:

  1. signature - did this payload come from Telegram at all?
  2. freshness - is it recent? Without this an intercepted initData stays valid
     forever and can be replayed at will.
  3. sender    - is it the captain? A valid signature only proves "some user of
     this bot", which is not the same person.

The module holds no bot name, chat id, domain or default token. Everything
comes from the caller. There is deliberately no helper here that BUILDS signed
initData: that belongs to the test file, so production code ships no ready way
to sign a decision.

CLI, for use from tests and for a quick manual check:

    FM_TELEGRAM_BOT_TOKEN=<token> fm-telegram-verify.py --owner-id 123 \\
        --init-data '<initData>'

initData is read from stdin when --init-data is absent. Exit 0 prints the
accepted fields as JSON; exit 3 rejects and prints the reason to stderr; exit 2
is a usage error. A rejection reason never contains a secret and never a field
VALUE - only field names, which is what makes a rejected real payload
distinguishable from a forgery.
"""

import hashlib
import hmac
import json
import os
import sys
import time
import urllib.parse

# Telegram itself recommends rejecting old initData. 900 s is generous enough
# for a decision the captain takes at his own pace and short enough that an
# intercepted payload does not stay usable for days.
DEFAULT_MAX_AGE_S = 900

# A clock that runs backwards, or a phone a little ahead of the server, must not
# reject a genuine answer. Anything further ahead than this is not clock skew.
FUTURE_TOLERANCE_S = 60


class InvalidInitData(Exception):
    """initData is not acceptable. The message never names a secret."""


def _secret_key(bot_token):
    return hmac.new(b"WebAppData", bot_token.encode(), hashlib.sha256).digest()


def _chain(fields):
    return "\n".join(f"{k}={fields[k]}" for k in sorted(fields))


def _expected_hash(secret, fields):
    return hmac.new(secret, _chain(fields).encode(), hashlib.sha256).hexdigest()


def verify_init_data(
    init_data,
    bot_token,
    *,
    owner_id=None,
    max_age_s=DEFAULT_MAX_AGE_S,
    now=None,
):
    """Check initData and return its fields. Raises InvalidInitData.

    The returned dict carries the payload's own fields plus two derived keys:
    _age_s (how old the payload was) and _reading (which of the two hash
    readings matched, see below).
    """
    if not init_data:
        raise InvalidInitData("initData missing")
    if not bot_token:
        raise InvalidInitData("no bot token configured")

    pairs = urllib.parse.parse_qsl(init_data, keep_blank_values=True)
    fields = dict(pairs)
    # parse_qsl keeps duplicates, dict() silently drops all but the last. A
    # payload that carries a field twice is ambiguous about which copy was
    # signed, so refuse it instead of guessing.
    if len(fields) != len(pairs):
        raise InvalidInitData("duplicate fields in initData")

    received = fields.pop("hash", None)
    if not received:
        raise InvalidInitData("hash missing")

    # Bot API 8.0 added a `signature` field, the Ed25519 part third parties can
    # check without the bot token. Whether it belongs inside the HMAC chain is
    # Telegram's call, not ours, and hand-built test data does not settle it:
    # the prototype dropped the field, stayed green against its own fixtures and
    # was rejected three times by a real phone. So compute both readings and
    # take whichever matches the supplied hash. This is not a loophole - both
    # readings demand the same bot-token-derived key, so a payload without that
    # key fails both.
    if "signature" in fields:
        without_signature = {k: v for k, v in fields.items() if k != "signature"}
        readings = (
            ("with-signature", fields),
            ("without-signature", without_signature),
        )
    else:
        readings = (("without-signature", fields),)

    secret = _secret_key(bot_token)
    reading = None
    for name, candidate in readings:
        # compare_digest, never ==: a character-wise comparison returns early on
        # the first difference and leaks through its runtime how much of the
        # hash is already right, which is enough to guess it character by
        # character.
        if hmac.compare_digest(_expected_hash(secret, candidate), received):
            reading = name
            break
    if reading is None:
        raise InvalidInitData("signature does not match")

    try:
        auth_date = int(fields["auth_date"])
    except (KeyError, ValueError):
        raise InvalidInitData("auth_date missing or not a number") from None
    age = (time.time() if now is None else now) - auth_date
    if age > max_age_s:
        raise InvalidInitData(f"initData is {int(age)} s old (limit {max_age_s} s)")
    if age < -FUTURE_TOLERANCE_S:
        raise InvalidInitData("auth_date lies in the future")

    user = {}
    if fields.get("user"):
        try:
            user = json.loads(fields["user"])
        except json.JSONDecodeError:
            raise InvalidInitData("user is not valid JSON") from None
    if owner_id is not None and user.get("id") != owner_id:
        raise InvalidInitData("sender is not the owner")

    accepted = dict(fields)
    accepted["_age_s"] = int(age)
    accepted["_reading"] = reading
    return accepted


def field_names(init_data):
    """The field names of a payload, never their values.

    A rejected real payload and a forgery look identical without this, and that
    cost the prototype a full round of debugging. Values stay unlogged because
    they carry the captain's identity and a valid hash.
    """
    try:
        pairs = urllib.parse.parse_qsl(init_data or "", keep_blank_values=True)
    except ValueError:
        return []
    return sorted({k for k, _ in pairs})


def _usage(message):
    print(f"fm-telegram-verify: {message}", file=sys.stderr)
    print(__doc__.strip().splitlines()[0], file=sys.stderr)
    return 2


def main(argv):
    init_data = None
    owner_id = None
    max_age_s = DEFAULT_MAX_AGE_S
    i = 1
    while i < len(argv):
        arg = argv[i]
        if arg == "--init-data" and i + 1 < len(argv):
            init_data = argv[i + 1]
            i += 2
        elif arg == "--owner-id" and i + 1 < len(argv):
            try:
                owner_id = int(argv[i + 1])
            except ValueError:
                return _usage("--owner-id must be a number")
            i += 2
        elif arg == "--max-age" and i + 1 < len(argv):
            try:
                max_age_s = int(argv[i + 1])
            except ValueError:
                return _usage("--max-age must be a number")
            i += 2
        elif arg in ("-h", "--help"):
            print(__doc__.strip())
            return 0
        else:
            return _usage(f"unknown argument: {arg}")

    token = os.environ.get("FM_TELEGRAM_BOT_TOKEN", "")
    if not token:
        return _usage("FM_TELEGRAM_BOT_TOKEN is not set")
    if init_data is None:
        init_data = sys.stdin.read().strip()

    try:
        accepted = verify_init_data(
            init_data, token, owner_id=owner_id, max_age_s=max_age_s
        )
    except InvalidInitData as exc:
        print(f"rejected: {exc}", file=sys.stderr)
        print(f"fields: {','.join(field_names(init_data))}", file=sys.stderr)
        return 3
    print(json.dumps(accepted, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
