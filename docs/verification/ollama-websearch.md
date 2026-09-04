# Ollama Cloud web search verification

Audience: maintainer verification.

This record supports the active guarantees behind the `web_search` tool given to Pi scouts.
[`docs/configuration.md`](../configuration.md) owns the operator-facing behavior, and `bin/fm-ollama-websearch.sh`'s header owns the mechanics and the non-disclosure guarantee.

Measured on 2026-09-01 against the live Ollama Cloud API, with curl 8.7.1 on macOS 25.6.0 and Pi 0.84.2.

## The endpoint accepts the same credential as the usage probe

The usage probe was already sending this home's `OLLAMA_API_KEY` to `https://ollama.com/api/usage` as a bearer token.
Web search accepts the same credential the same way, so the feature reuses an existing key rather than introducing a second one.

`POST https://ollama.com/api/web_search` with `Authorization: Bearer <key>` and `{"query":"firstmate agent framework","max_results":3}` returned `http=200` and a body shaped:

```json
{"results":[{"title":"...","url":"...","content":"..."}]}
```

`jq '.results | length'` returned `3` and `jq '.results[0] | keys'` returned `["content","title","url"]`, so `max_results` is honored and each result carries exactly those three fields.

## Web searches are counted in the quota this home already reports

This was the open question behind the feature: whether a search spends the same metered budget the usage probe reports, or a separate one.
It is the same budget, and it is itemized.

`GET https://ollama.com/api/usage` immediately before and after one real search, with nothing else running:

```
before: "limits":{"session":{"usage":0.047,"models":[{"name":"glm-5.2","request_count":51}]},
                  "weekly":{"usage":0.008,"models":[{"name":"glm-5.2","request_count":51},
                                                    {"name":"deepseek-v4-flash:0731","request_count":4}]}}

after:  "limits":{"session":{"usage":0.047,"models":[{"name":"glm-5.2","request_count":51},
                                                     {"name":"web search","request_count":1}]},
                  "weekly":{"usage":0.009,"models":[{"name":"glm-5.2","request_count":51},
                                                    {"name":"deepseek-v4-flash:0731","request_count":4},
                                                    {"name":"web search","request_count":1}]}}
```

A new `{"name":"web search","request_count":1}` entry appears in both the session and weekly model lists, and the aggregate `weekly.usage` moves from `0.008` to `0.009`.
So an operator watching the existing usage report already sees search spend, and can separate it from model spend by that entry's name.
This is why exposure is limited to scouts and why the extension caps calls per turn: search competes with model calls for one budget.

## Untruncated results would cost a scout its context

The upstream `content` field is a whole-page dump, not a snippet.
Three results for a single query measured `103600` bytes (`wc -c`), roughly 26k tokens for one call.

This is the reason `bin/fm-ollama-websearch.sh` reshapes rather than relays: it returns three results by default and truncates each `content`, marking the result `truncated: true` so a scout never quotes a cut-off page as if it were whole.

The same query through the proxy at its defaults returned `6688` bytes for the same three results, all three marked truncated:

```
$ bin/fm-ollama-websearch.sh search --query "firstmate agent framework" | wc -c
    6688
$ ... | jq -c '[.results[].truncated]'
[true,true,true]
```

That is a 15x reduction against the `103600` bytes the same three results carry upstream.

## The key is not disclosed through the proxy

`tests/fm-ollama-websearch.test.sh` is the maintained regression and is portable: it drives the real script with a real curl against a local endpoint stub, and asserts the key is absent from stdout, stderr, the child's argument vector, and the child's environment, while present on the child's stdin, which is the one channel that carries it.

Those assertions were confirmed to be load-bearing rather than vacuous by breaking each protection in turn and observing exactly the matching failure:

| Injected fault | Failing assertion |
|---|---|
| `export OLLAMA_API_KEY="$key"` before the request | the key must never be exported into a child's environment |
| `-H "Authorization: Bearer $key"` added to curl's arguments | the key must never be passed in a child's argument vector |
| default-key-file check removed from the redirect guard | a redirect must be refused for a key at a default location |

With all three faults reverted the suite returns exit 0.

## The extension registers a callable tool in the installed Pi

Pi exposes no built-in web tool and no MCP, so the tool exists only because `pi.registerTool()` accepts it.
That is a vendor-surface fact, so it is proven against the real binary rather than a stub: `tests/fm-pi-websearch-live-e2e.test.sh` runs the installed Pi non-interactively with the extension loaded and built-in tools disabled, and asserts from Pi's own structured JSON output that a `web_search` tool call ran and returned results.
It is opt-in (`FM_PI_WEBSEARCH_LIVE_E2E=1`) because it needs Pi credentials and spends quota; run it after a Pi upgrade.

`tests/fm-pi-primary-types.test.sh` additionally typechecks the extension against the installed Pi package's own declarations, so a breaking change to the extension API fails locally rather than at a scout's first search.
