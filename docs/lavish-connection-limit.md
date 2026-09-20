# Lavish review pages stalling past six open tabs

## The problem

Chrome allows six simultaneous connections to one server origin.
Every open Lavish review page permanently holds one of them open for its live-update stream (`dist/chrome-client.js`, `new EventSource("/events/" + key)`), served by a handler that never closes.
At six pages open at once, the seventh page never loads and "Send to agent" on an already-open page silently queues instead of arriving - the message is not lost, it just waits for a connection to free up.
Full investigation: `data/fm-lavish-pages-dont-load/report.md`.

This is a client bug in lavish-axi upstream, not anything in this repo or in the Lavish server.
Confirmed still present as of the installed 0.1.63 (the original report checked 0.1.43 and 0.1.52).

## The patch

`bin/fm-lavish-client-patch.sh` edits the installed `dist/chrome-client.js` in place.
It releases the page's `EventSource` when the tab goes to the background (`document.visibilitychange`, `document.hidden`) and reopens it when the tab is shown again.
Since the captain looks at one page at a time, this removes the six-page ceiling entirely.

Run it any time to check or reapply:

```
bin/fm-lavish-client-patch.sh
```

It is idempotent - a second run detects the patch is already present and changes nothing - and it refuses without touching the file if lavish-axi's surrounding code no longer matches what it expects to replace, rather than risk corrupting the installed client.

A server restart is required for a freshly applied patch to take effect in already-open pages; this script never restarts the shared server itself.

Upgrading lavish-axi silently reverts the patch: an upgrade reinstalls `dist/chrome-client.js` from the new package, unpatched.
Re-run the script after every `lavish-axi update`.

Verification for this patch was static (syntax check, presence of the new code, three idempotency cases against throwaway copies, and an HTTP check against a disposable Lavish instance on a private port) rather than a live six-plus-tab browser proof.
This machine's only browsers are the captain's own, so proving the fix live needs opening more than six real tabs and no browser here can do that without it being his.
The real proof will be the captain simply no longer seeing pages stall.

## Two workarounds that need no patch

- Keep at most four or five review pages open at once.
- Spread pages across `127.0.0.1:4387` and `localhost:4387` - the browser budgets each address's six connections separately, so up to twelve pages can stay open split between the two.
  (`[::1]:4387` is not a third address; the server only listens on IPv4.)
