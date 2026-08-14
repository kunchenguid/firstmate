---
name: wayd-comment-spam-triage
description: >-
  Agent-only lookup-and-analysis procedure for bot or spam comments on a profile's WAYD thread.
  Use before investigating bot or spam comments on a profile's comment thread, given a profile id.
  Owns the profile-to-thread lookup against production DynamoDB, the read-only query path, and the detection signals a prior campaign was found by.
user-invocable: false
metadata:
  internal: true
---

# wayd-comment-spam-triage

Use this procedure to find a profile's WAYD comment thread in production DynamoDB and identify bot or spam comments on it, given a profile id.

## Confirm the environment first

Production is the `ops0` AWS profile, account `135055922332`, role `DevOps_Backend`, region `eu-west-1`.
The `default` AWS profile is staging and has differently-named tables (`nbl_stg_*`); it answers silently with the wrong data rather than failing, so confirm `ops0` is the active profile before trusting any result from the commands below.

## Step 1: profile id to WAYD id

`nbl_profileattributes_attributes` has a single hash key `ProfileAndGameId` and no secondary indexes: the profile id, then the separator `¤` (U+00A4 CURRENCY SIGN), then the game id.
The game id is a parameter, not a constant; `j68d` is the MSP2 value.

```
aws dynamodb get-item --table-name nbl_profileattributes_attributes --region eu-west-1 \
  --key '{"ProfileAndGameId":{"S":"<profileId>¤<gameId>"}}'
```

The WAYD id is at `Item.AdditionalData.M.WAYD.S`.

## Step 2: WAYD id to comment thread

`nbl_comments_comments` has hash key `CommentId` and two indexes: `Author-index` and `ThreadId-Created-index`.
The thread id is the WAYD id prefixed with `ugc:`.

```
aws dynamodb query --table-name nbl_comments_comments --index-name ThreadId-Created-index \
  --region eu-west-1 --key-condition-expression 'ThreadId = :t' \
  --expression-attribute-values '{":t":{"S":"ugc:<waydId>"}}'
```

Run the same query with `--select COUNT` first to size the thread before pulling it.

Never scan either table: `nbl_comments_comments` holds roughly 148 million items and 29 GB, and `nbl_profileattributes_attributes` holds roughly 197 million items.
Always use the indexed query or the keyed get above.

Comment items carry `Author`, `CommentId`, `Created`, `State`, `Text`, `ThreadId`.
`State` is `Active`, `Deleted`, or `DeletedUser`; only `Active` comments are still visible, which is what separates already-handled comments from still-live ones.

## Detection signals

These signals found a real campaign on thread `ugc:e87fceb2e5b949a89a6437ea811f909b`: 759 comments, 263 authors, 24 authors flagged, 228 of their comments still `Active`.
Weigh them as signals, not a scoring formula; judgment on what counts as bot or spam activity stays with the agent applying the procedure.

- **Cap-maxing.** In the confirmed campaign, 17 authors posted exactly 25 comments each, 56% of the thread. A per-user comment cap exists; sitting exactly on it is a strong automation signal.
- **Machine-speed bursts.** Those 25-comment runs completed in 10 to 27 seconds. Treat five or more comments from one author inside a minute as automated.
- **Repeated identical payload.** Flagged authors posted one or two distinct texts many times over.
- **Coordinated timing.** Many of the flagged accounts fired within hours of each other on one day, which is what distinguishes a campaign from one enthusiastic user.
- **Invisible-character filter evasion.** The confirmed campaign used 936 soft hyphens (U+00AD) across 134 comments from 7 authors, inserted between letters to break profanity matching. Also check U+200B, U+200C, U+200D, U+2060, and U+FEFF. The stored `Text` shows `#` where the moderation filter masked content, so partially-masked text alongside invisible characters is the tell that evasion partly worked.

## Safety rules

- This procedure is read-only: never delete, update, or write to production. Cleanup of any comments identified as bot or spam is a separate captain decision; report findings, do not act on them.
- This data is real user data on a children's platform. Write full findings, including message text and author ids, to a file under `data/`; keep raw message text out of captain chat and report patterns, counts, and the file path instead.
