# Away email on Pi

Away email lets a Pi supervision branch send captain-facing outcomes to John Poyser's Gmail inbox and accept a reply for one specific outcome.

It is an optional extension of the existing mail plane and does not change what actions the away session is authorized to take.
Other primary harnesses retain their existing away behavior and do not claim this delivery path.

## Setup

Use a dedicated sending mailbox if practical, and create an app password for it rather than using your normal account password.
Inbound replies are accepted only from `johnpoyser@gmail.com` when Google's receiving-server `Authentication-Results` reports a Gmail-aligned DKIM or DMARC pass; a `From` header by itself is not proof of identity.


Add the following values to this Firstmate home's gitignored `.env`:

```sh
FM_MAIL_USER=mailbox@example.com
FM_MAIL_PASS=your-mailbox-app-password
FM_IMAP_HOST=imap.example.com
FM_SMTP_HOST=smtp.example.com
FM_AFK_EMAIL_TO=johnpoyser@gmail.com
```

`FM_MAIL_USER`, `FM_MAIL_PASS`, `FM_IMAP_HOST`, and `FM_SMTP_HOST` are the existing mail-plane settings.
`FM_AFK_EMAIL_TO` must be exactly `johnpoyser@gmail.com`; this fixed destination is also the only permitted reply identity.

The mail plane requires implicit TLS on IMAP port 993 and SMTP port 465 by default; STARTTLS and port 587 are not supported.
Set `FM_IMAP_PORT` or `FM_SMTP_PORT` only when your provider uses different implicit-TLS ports.

Arm received-mail polling once in this home:

```sh
bin/fm-mail-check.sh arm
```

Then enter `/afk` on Pi and confirm its read-back says email reach is active.
Pi refuses `/afk` before writing or announcing an active posture if `FM_AFK_EMAIL_TO` is absent or differs from `johnpoyser@gmail.com`.
With the exact destination but incomplete mail transport settings, away mode retains the hold-for-return behavior instead.

No credential needs to be shared with Firstmate.

## Replies and limits

Captain-facing Pi supervision outcomes are grouped into plain-text email updates, with the full pull-request URL retained when present and a short one-time reply code for each item. Outcome selection compares integer-second epochs, so an outcome recorded immediately before `/afk` in the same second may be included; this is a known boundary.
To answer an item, reply from exactly `johnpoyser@gmail.com` and make the first non-empty line exactly `FM-AFK-REPLY FM-AFK-<code>`; put your words on the following lines before any quoted message.
The poller reads a message body only when its single `From` address is the owner and the receiving server's `Authentication-Results` shows DKIM or DMARC passing with alignment to `gmail.com`. Other senders and messages without that authenticated result are silently ignored without a body read or mail wake.
Each code is accepted only for its own sent item, once, and for seven days after sending. Correctly authenticated owner messages larger than 256 KiB total, including attachments, are not processed as away-mode replies, but receive an ordinary mail wake marked that the body exceeds the limit. Replies over 8,000 characters are rejected with a notice in the durable mail wake.

A matching reply enters Firstmate's existing captain inbox as words for that outcome.
An authenticated owner message with a missing, invalid, expired, or already-used code follows the ordinary mail wake path and is never treated as verified instructions.
The email footer states the same safety boundary: replies never authorize destructive, irreversible, or security-sensitive actions, which still require your return or trusted-channel confirmation.

Away updates are batched, with a minimum interval of one message per minute. If another batch is ready sooner, it remains queued until the interval expires.


Email transport settings and received-mail polling are owned by the [Mail plane](configuration.md#mail-plane-env).
The durable away-posture reach selection and its hold-for-return fallback are owned by `bin/fm-afk-contract.sh` and the [`/afk` skill](../.agents/skills/afk/SKILL.md).
