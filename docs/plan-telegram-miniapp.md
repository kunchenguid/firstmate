# Plan: Telegram Mini App as a decision surface (ship)

Written 2026-08-21 on branch `fm/fm-telegram-miniapp-ship`.
The basis is the scout report `data/fm-telegram-miniapp/report.md` of 2026-08-16, which is private and stays private.
This plan states only what has been measured since, and settles the choices that report handed back to the captain.

## 1. Goal

Firstmate asks the captain a decision question in Telegram, the captain taps an answer, and the answer lands as a file in the existing inbox within a second.
Today that return path is measurably dead: the polling check listens for 0 seconds every 310 to 326 seconds, and Telegram's callback id has always expired by then.
A Mini App is the only route that needs no second `getUpdates` reader, so it is the only one that honors the captain's standing instruction to leave the existing listening behavior alone.

## 2. What changed since the scout report

The report named one expensive open point: the live Caddy configuration lives in no repository, so there is no branch a new block could live in.
That has not been true since 2026-08-16, and it changes the recommendation.

Measured on 2026-08-21 on `hetzner` (2.28.5.107):

- `~/quiz-web/Caddyfile` opens with `import projekte/*.caddy`, and `/etc/caddy/projekte` is a directory mount.
- `~/quiz-web/caddy-projekte/` holds exactly one file today, `quiz-web.caddy`.
- `Quiz-Web/infra/hetzner/BESITZ.md` records that a project shipping its own blocks drops its own file there, and that a Quiz-Web deploy explicitly leaves foreign files under `caddy-projekte/` alone.

So the missing branch exists: the Mini App gets its own snippet file and its own rollout script, both versioned in this branch.
The root configuration is not touched, no foreign deploy script is touched, and none of the 18 existing blocks changes.
This is the report's option 2, without the reaching-into-a-foreign-file cost it feared.

## 3. Scope for v1

Deliberately small: one question, several options, one measured round trip.

The flow:

1. Firstmate runs `bin/fm-miniapp-frage.sh` with a question and its options.
2. The script stores the question as a JSON file on the server and sends the captain a message through the chosen bot carrying a `web_app` button to `https://<address>/?f=<question-id>`.
3. The captain taps it, Telegram opens the page in its built-in view and supplies `initData`.
4. The page fetches the question from the service, renders it, and posts the choice back.
5. The service checks signature, freshness and sender, then writes the answer as `<query_id>.<project>.msg` containing `[MiniApp <question-id>] <choice>` into the inbox.

The question therefore comes from the task instead of being wired into the page script.
That is the difference between a demo and a tool, and the report called it the largest remaining piece.
It costs about 40 lines here, because only an id travels in the address and the service looks the question up.

Explicitly **not** in v1:

- No rework of the existing poller and no second listening process.
- No free-text answers, no follow-up questions, no history view.
- No BotFather registration, because `web_app` buttons inside messages need no registered domain; that was measured in the prototype.

## 4. Signature verification

Carried over from the prototype, which survived two real failures and carries tests for them.

Three checks, in this order, each rejecting on its own:

1. **Signature** - HMAC-SHA256 over the alphabetically sorted `key=value` lines, with `secret = HMAC_SHA256(key="WebAppData", msg=<bot-token>)`.
   Compared with `hmac.compare_digest`, never `==`, so the runtime does not leak how many characters already match.
2. **Freshness** - `auth_date` at most 900 seconds old and not in the future, so an intercepted `initData` cannot be replayed forever.
3. **Sender** - the user id inside `user` must be the captain's, because a valid signature only proves "some user of this bot".

Two subtleties the prototype learned the hard way, kept here:

- The `signature` field belongs **inside** the verification chain, while `hash` belongs outside.
  The prototype dropped `signature` first and was rejected three times by real phone data, while every hand-built test stayed green.
  Verification therefore computes both readings and takes the one matching the supplied hash; both demand the same bot-token-derived key, so the second reading rescues no forgery.
- `parse_qsl(..., keep_blank_values=True)`, otherwise a different chain is computed than the one Telegram signed.

Test data comes from a helper that builds correctly signed `initData`.
It lives **in the test file**, not in the shipped module, so production code carries no ready way to sign decisions.
The prototype had a separate service for this and the report puts it in the layer that belongs in no repository at all.

**Not in v1, but named:** since Bot API 8.0 `initData` carries an Ed25519 part in `signature` that can be verified without the bot token.
The service could then hold no secret at all.
`cryptography 46.0.5` is present on `hetzner`, so the route is open.
I propose it as separate follow-up work rather than v1, because the HMAC route is measured against real phone data and the Ed25519 route is not.

## 5. Host and address

**Host: `hetzner` (2.28.5.107).**
Not for spare capacity - it has 384 MB of memory and 7 GB of disk free, while `gex44` has 56 GB and 1.4 TB.
But because the versioned, guarded rollout path exists there and not on `gex44`, whose `/root/caddy/Caddyfile` lives in no repository, only beside its own backup copies.
The service is a Python process with no third-party packages and needs roughly 20 MB, which the small machine carries.
`hetzner` already runs exactly this shape in `goatcounter.service`: a host service behind the same Caddy.

**Address: `entscheid.2.28.5.107.sslip.io`.**

Measured on 2026-08-21:

```
entscheid.2.28.5.107.sslip.io   A: 2.28.5.107     AAAA: -
entscheid.struck-webdesign.de   A: -              AAAA: -
```

The sslip.io name already resolves to the right machine and needs **no** DNS record.
`entscheid.struck-webdesign.de` does not exist and would only exist once someone adds A and AAAA by hand in the Hetzner Robot zone - a web console, no API key, so a step only the captain can take and one that would block this delivery.

Three further reasons for the sslip.io name:

- The machine already uses this pattern for nine blocks, among them `zaehler.lensclash.2.28.5.107.sslip.io`.
- It removes the most common relocation trap the report lists: a missing AAAA silently sending IPv6 visitors to the old Apache.
  With no AAAA there is nothing that can point wrong.
- `struck-webdesign.de` is the customer-facing side of that machine, and a private decision tool for the captain does not belong there.

Moving to a prettier name later costs the code nothing: no address is wired in anywhere, the page posts back to its own origin, and `web_app` buttons need no BotFather entry.
The price would be two DNS records and one line in the snippet.

## 6. Caddy block

Its own file, `~/quiz-web/caddy-projekte/fm-miniapp.caddy`, and nothing else on the machine is touched:

```caddy
entscheid.2.28.5.107.sslip.io {
	reverse_proxy 172.18.0.1:8779
}
```

Deliberately this short, against the three traps the report lists:

- **No `basic_auth`.** The access control here is the signature check; Telegram's built-in view cannot serve a password prompt.
  That is a conscious deviation from the existing blocks, nearly all of which carry one.
- **No path list.** The block passes everything through instead of enumerating `/`, `/app.js` and `/antwort`; exactly such a list has already lost a path on this machine once.
- **No Caddy-side `content-security-policy`.** The service sends its own, a second one applies on top, and the stricter wins - which would block the page script again.

The service runs as `fm-miniapp.service` and listens **only** on `172.18.0.1:8779`, the Docker bridge gateway.
That is not a gesture: `ufw` is inactive on this machine, so binding `0.0.0.0` would be reachable from the internet immediately.
`goatcounter.service` justifies the same binding in the same words.

In the branch the snippet is a template with placeholders for address and port, so no concrete name of the captain's ends up in shared material; the rollout script substitutes the values.

## 7. Where the code lives

The report's layering holds.

Versioned in this branch, with no secret, no bot name and no domain:

| File | Purpose |
|---|---|
| `bin/fm-telegram-verify.py` | the verification, the reusable core |
| `bin/fm-miniapp-serve.py` | the service; everything from the environment, no defaults |
| `bin/fm-miniapp/index.html`, `bin/fm-miniapp/app.js` | the page; script in its own file, see below |
| `bin/fm-miniapp-frage.sh` | store a question and send the button |
| `bin/fm-miniapp-deploy.sh` | roll out and roll back |
| `bin/fm-miniapp.caddy.template` | the block with placeholders |
| `tests/fm-miniapp-verify.test.sh` | the verification exercised through its executable interface |
| `docs/telegram-miniapp.md` | what it is, which address, how to extend it |

Local and never in the repository: the token values in `~/.config/claw/env`, the captain's chat id in `~/.config/claw/owner.json`, the concrete address, and the bot choice.

The page script lives in its **own file**, not as a `<script>` block inside the page.
That is the failure the captain saw in the prototype as "Mini App does not load": the service's own `content-security-policy` forbids inline script.
Repairing that later with `'unsafe-inline'` makes the protection worthless; the route is the separate file.

## 8. The secret on the server

HMAC verification needs the bot token where the verification happens.
It goes into a root-owned file with mode 0600 on `hetzner`, read by the systemd unit; it appears in no repository and in no log.

For v1 I propose **`TG_POOL_05`**, the test bot `bottest`.
The blast radius stays a channel that is a test channel anyway, the captain accepted the prototype on exactly that channel, and the Mini App polls nothing itself, so it does not collide with the existing check on the same bot.
Switching to the main bot later is one changed line in the server configuration and should be its own decision, not a side effect of this one.

## 9. Acceptance

The report's relocation table is the acceptance list, not "tests are green".

What I can and will show myself:

| Point | Evidence |
|---|---|
| verification accepts real data, rejects tampered data | tests in the branch, through the executable interface |
| the address serves the page | `curl -sI https://<address>/` with the output shown |
| no password prompt in front of it | no `www-authenticate` header |
| the page script is served | `curl -sI https://<address>/app.js` returns 200 |
| the return path is reachable | a POST to `/antwort` is not a 404 but a reasoned rejection |
| the certificate holds | `openssl s_client` with `Verify return code: 0 (ok)` |
| forgery is rejected | four live cases against the running service, inbox unchanged |

**What I cannot show myself.**
The report's lesson is that both real failures were invisible against hand-built data and obvious on the first contact with a phone.
A real tap on the captain's device therefore belongs in the acceptance - but a crewmate does not address the captain.
I will build the question and leave the exact command ready; sending it and collecting the reply belongs to firstmate.
I will state that this one point is still open rather than reporting it as done.

## 10. Wake path

A file another process drops into the inbox wakes nobody: the poller prints its wake line only for messages it fetched itself.
The answer would sit there for up to five minutes.

I ship `bin/fm-miniapp-inbox-check.sh` for that: a directory look with no network traffic that prints exactly one line when unread files are present.
Registering and arming it is firstmate's step, not mine.
I do not touch the existing poller; it lives outside this branch.

## 11. Rollback

Complete and without residue, because nothing foreign was touched:

1. Stop, disable and remove `fm-miniapp.service`.
2. Delete `~/quiz-web/caddy-projekte/fm-miniapp.caddy`, run `caddy validate` in a throwaway container, reload Caddy.
3. Remove `/root/fm-miniapp/`, including the token file and the questions.

No DNS record needs undoing, because none was created.
The root configuration, the 18 existing blocks, `bots.conf` and the existing poller stay unchanged, so there is nothing to revert there.
`bin/fm-miniapp-deploy.sh rollback` performs the three steps.

## 12. Decisions for firstmate

Approving this plan as a whole is enough; the four points are named separately in case one should go the other way.

1. **Address** `entscheid.2.28.5.107.sslip.io` rather than `entscheid.struck-webdesign.de`, because the latter needs a manual step by the captain in the Hetzner console and would block this delivery. The prettier name stays available at any time.
2. **Bot** `TG_POOL_05` (`bottest`) for v1, so a token on the server only concerns a test channel.
3. **Scope** with the question supplied by the task rather than a hard-wired demo, about 40 lines more.
4. **Placement** in shared, tracked `bin/` - with no token, no bot name and no domain, everything from the environment. The scout advised waiting, on the grounds that a half-working decision return path is worse for strangers than none. I judge that satisfied here, because this delivery is local-only and is not published, and because without environment values nothing starts at all instead of quietly pointing at a stranger's bot.
