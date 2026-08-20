# Telegram Mini App decision surface

A page inside Telegram that asks the captain one question and takes his answer straight back over HTTPS.
He taps an option and sees it land immediately; the answer arrives as a file in the same inbox the Telegram poller already writes to, so every reader of that inbox understands it unchanged.

It exists because inline keyboard buttons cannot do this.
Telegram's callback id expires within seconds, while the poller that would answer it listens for zero seconds once every five minutes, so the acknowledgement always fails.
Fixing that with a second, permanently listening reader is not available either: Telegram allows exactly one `getUpdates` reader per bot, and a second one takes the messages away from the first.
The Mini App route needs no reader at all, which is why it does not disturb the existing poller in any way.

## The pieces

| Piece | Where it runs | What it does |
|---|---|---|
| [`bin/fm-miniapp-serve.py`](../bin/fm-miniapp-serve.py) | the host, as `fm-miniapp.service` | serves the page, verifies initData, writes answers |
| [`bin/fm-telegram-verify.py`](../bin/fm-telegram-verify.py) | beside the service | the signature, freshness and sender checks |
| [`bin/fm-miniapp/`](../bin/fm-miniapp) | served by the service | the page, its script and its styling |
| [`bin/fm-miniapp.caddy.template`](../bin/fm-miniapp.caddy.template) | rendered onto the host | the reverse proxy block for the address |
| [`bin/fm-miniapp-deploy.sh`](../bin/fm-miniapp-deploy.sh) | here | installs, inspects and removes all of the above |
| [`bin/fm-miniapp-ask.sh`](../bin/fm-miniapp-ask.sh) | here | stores a question and sends the button |
| [`bin/fm-miniapp-inbox-check.sh`](../bin/fm-miniapp-inbox-check.sh) | here, as a registered check | brings answers home and wakes firstmate |

The service binds a private address on its host and is reachable only through the reverse proxy in front of it.
On a host without a running firewall that is not a nicety: binding a public interface would be reachable from the internet the moment the service starts.

Every script's own header and `--help` own its exact flags; this page does not repeat them.

## Setup

Settings live in `~/.config/fm-miniapp.env`, overridable with `FM_MINIAPP_CONFIG`, and any exported value wins over the file.
The file holds settings, not secrets: the bot token stays in whatever environment file already holds it and is read one variable at a time.
Nothing has a default that points at a real bot, chat, host or address, so an unset value refuses the run rather than guessing.

```sh
FM_MINIAPP_SSH=<ssh destination of the host>
FM_MINIAPP_ADDRESS=<public hostname, no scheme>
FM_MINIAPP_LISTEN=<host:port the service binds ON THE HOST>
FM_MINIAPP_UPSTREAM=<host:port the proxy forwards to; defaults to LISTEN>
FM_MINIAPP_OWNER_ID=<the only Telegram user id allowed to answer>
FM_MINIAPP_CHAT_ID=<the chat the question is sent to>
FM_MINIAPP_CHANNEL=<the <channel> part of the answer filename>
FM_MINIAPP_TOKEN_FILE=<file holding the bot token>
FM_MINIAPP_TOKEN_VAR=<variable name inside that file>
FM_MINIAPP_INBOX=<local inbox directory answers are filed into>
FM_MINIAPP_CADDY_DIR=<remote directory holding Caddyfile and caddy-projekte>
FM_MINIAPP_NEIGHBOURS=<https URLs of other sites on the same proxy>
```

`FM_MINIAPP_NEIGHBOURS` is worth filling in wherever the proxy serves more than this one address.
Deployment probes those addresses before and after the reload and refuses the run if any of them changed, which turns a configuration mistake into a failed deploy instead of a quiet outage on somebody else's site.

Then:

```sh
bin/fm-miniapp-deploy.sh render     # print the block, touch nothing
bin/fm-miniapp-deploy.sh deploy
bin/fm-miniapp-deploy.sh status
```

The address needs no DNS record when it is an `sslip.io` name, which resolves to the IP embedded in it.
Any other name needs its own A record, and an AAAA record too wherever the zone carries them: a name with an A record but no AAAA sends phones - which frequently prefer IPv6 - somewhere else entirely, while every IPv4 check still looks green.

## Asking a question

```sh
bin/fm-miniapp-ask.sh --text "Merge the fix now?" --option "Merge" --option "Wait"
```

The question is stored on the host and only its id travels in the button's address.
That is why the answer is a label this side authored: the page reports which option was chosen, never what the answer should say.

The answer arrives as `<query-id>.<channel>.msg` containing `[MiniApp <question-id>] <label>`, mode 0600, written through a temp file and a rename.

## Waking firstmate

An answer landing in the inbox does not by itself wake anybody: the Telegram poller prints its wake line only for messages it fetched itself.
`bin/fm-miniapp-inbox-check.sh` closes that gap - it fetches accepted answers into the local inbox and prints one line when something arrived, nothing otherwise.

Register it as a check for the task it belongs to, then arm it with `bin/fm-check-register.sh`, the same way as any other custom check.
Until it is armed, answers still arrive safely; they are simply noticed at the next ordinary sweep instead of immediately.

## Verifying an installation

Five commands settle whether a deployment is actually working, and they are worth running after every move to a new address.
Each one corresponds to a way the page shows up as "does not load" while looking healthy from another angle.

```sh
curl -sI https://<address>/          # 200, and NO www-authenticate header
curl -sI https://<address>/app.js    # 200 - the page is inert without it
openssl s_client -connect <address>:443 -servername <address> </dev/null \
  | grep 'Verify return code'        # 0 (ok)
dig +short AAAA <address>            # empty, or the right address - never a stale one
bash tests/fm-miniapp-verify.test.sh # the signature checks
```

Green tests are not an acceptance on their own.
Both failures the prototype shipped with were invisible against hand-built payloads and obvious on the first contact with a real phone, so a real tap belongs in the acceptance of any change to the page or the verification.

## Extending it

- **A prettier address.** Nothing knows the hostname: the page posts back to its own origin, the service never learns its public name, and a `web_app` button inside a message needs no domain registered with BotFather. Change `FM_MINIAPP_ADDRESS`, add the DNS records, redeploy. Only a bot menu button or a direct `t.me` link would add a domain-bound registration step.
- **Another bot.** Change `FM_MINIAPP_TOKEN_VAR` and redeploy. The Mini App polls nothing, so it never competes with a poller on the same bot.
- **A new route.** Add it to the service; the proxy block passes everything through and needs no edit. A block that enumerates paths instead would 404 the new route until someone remembered to update it.
- **A page change.** Keep the script and the styling in their own files. The service sends a content-security-policy without `'unsafe-inline'`, so an inline `<script>` block is blocked and the page renders its heading and then stops. Relaxing the policy to work around that throws away the only reason the page cannot be made to load foreign script.
- **Verification without a token on the host.** Since Bot API 8.0 initData carries an Ed25519 part that can be checked with Telegram's public key instead of the bot token, which would let the service hold no secret at all. It needs a crypto library the current implementation deliberately avoids, and the HMAC route is the one measured against real phone data.

## Deliberately not there

There is no free-text answer, no follow-up question and no history view.
There is also no helper anywhere in `bin/` that BUILDS signed initData: one exists in `tests/fm-miniapp-verify.test.sh` because the tests need it, and shipping a second copy next to the service would ship a working recipe for forging decisions the moment a token leaked.

## Removing it

```sh
bin/fm-miniapp-deploy.sh rollback
```

It stops and removes the service, shreds the token file, deletes the install directory, and moves the proxy block aside before validating and reloading.
Nothing else on the host is touched at any point - the deployment writes exactly one file into the proxy's configuration directory and never edits a shared one - so there is nothing else to undo.
