# The spoken interface

Talk to a voice agent that sits in front of the first mate. It answers questions
about what is happening from the first mate's own records, and when you ask for
real work it says so out loud and queues the request rather than pretending to
do it.

This is step one of three: a spoken round trip that works. Interrupting the agent
mid-sentence and carrying context from one question to the next are step three,
and [what this build does not do](#what-this-build-does-not-do) is explicit about
where the edge is.

## The shape

Your laptop captures the audio and plays the reply. This desktop holds the
conversation with the model. Nothing in between needs AWS credentials on the
laptop, which is the whole reason for this shape.

```
laptop                          this desktop                      AWS
------                          ------------                      ---
microphone --> fm-voice-client.py --(ssh)--> fm-voice-relay.py --> Nova Sonic 2
speaker    <-------------------------------------------------      (your region)
                                        |
                                        +--> the first mate's records (read)
                                        +--> fm-inbox.sh note (queue real work)
```

The two ends share one bidirectional byte stream over an SSH exec channel, so
audio and control travel together and need framing. `bin/fm_voice_frame.py` is
the owner of that format and is the only file both machines run.

The relay reads records and queues work. It never changes a project, and the
queueing half is `bin/fm-inbox.sh note`, the same surface the captain's own
out-of-band capture already uses, rather than a second queue.

## What it costs in time

Measured on 2026-08-21 against the reviewed relay code, `amazon.nova-2-sonic-v1:0` in `eu-north-1`, on a spoken question that makes the agent read the records before it can answer, which is the slowest ordinary case.
Six runs each, all six answered each way.

| Path | First audio out, seconds | Median |
| --- | --- | --- |
| Direct from this desktop, no relay | 1.165 1.190 1.215 1.250 1.281 1.352 | 1.232 |
| Over the relay, real client and framing | 1.138 1.165 1.171 1.174 1.177 1.283 | 1.172 |

The clock starts the instant the captain stops speaking and stops when the first byte of reply audio arrives.
An earlier measurement of the same question, on the same model and region and also reading the records, put the direct path at 1.164 seconds median over five runs, and this control reproduces it to within the noise floor below.
That measurement is not published here, so read it as corroboration rather than as something to open: the direct column stands as a control on its own, because it was taken in the same pass, on the same clip, model, region and read scope, with only the relay removed.

**The relay's own cost is smaller than this measurement can resolve.**
The relay median lands below the direct control, which does not mean the relay is faster: two direct-control passes twenty minutes apart differ by 0.070 seconds of median, so that is the floor, and framing and the extra process hop are both under it.
The earlier measurement above independently agrees on that floor, spreading 0.087 seconds across its own five runs, and two measurements agreeing on the noise are worth more than one asserting it.
Read the two rows as the same number.

The first pass, on the relay as first written, put it 0.22 seconds behind the control, and that gap read as framing, the process hop and the per-turn reconnect.
It was none of them, and the difference is worth keeping, because a wrong number invites a re-measurement while a wrong cause invites a fix to the wrong part of the relay.
Each relay run is six turns in one session, so a per-turn defect shows up as a step: that pass stepped from 1.229 on turn one to a 1.447 median across turns two to six, and the same step appeared independently on the talk-end-to-tool-request mark, 0.599 rising to 0.730.
The re-measured passes are flat, stepping 0.009 and 0.021.
The 0.22 seconds was the relay resolving AWS credentials again for every turn's session, which review found and fixed: `Credentials` in `bin/fm-voice-relay.py` resolves once, and every later session reuses that answer, so a reconnect costs a reconnect.
This is the second time credential resolution has dominated a voice path's latency on a host like this one, because earlier prototype work measured the local credential helper at about a second per call and found that fixed per-call overhead exceeded the model's own cost.
So it is the first thing to suspect when a spoken path is slower than the model, and it is worth checking that anything new doing per-turn work resolves credentials once rather than once per session.

What the relay figure does NOT include, and could not be measured from here:

- **The SSH hop itself.**
  These runs drove the relay as a local child process, which is the identical relay command with only the `ssh -T <host>` prefix omitted, so the client, the framing, the uplink ordering, the relay, the records read and the handover are all real and only the SSH subprocess is absent.
  Two facts bound what its absence can be hiding.
  A constant transport cost cannot produce the turn-by-turn step that the credential defect produced, and the first pass, which did run over `ssh localhost`, put its own first turn 0.009 seconds above its own direct control.
  Neither of those is a measurement of the SSH path on this code, and neither is offered as one.
- **Your laptop's round trip to this desktop.**
  Add roughly your own round trip time: the audio goes up and the reply comes back, so it lands about once.
- **Microphone capture and speaker output latency.**
  This desktop has no microphone and no speaker, so every measurement used audio files.
  The client reports both device figures in its own output, so your first live run measures them rather than guessing.

So your number is about 1.15 to 1.3 seconds plus your round trip time plus your audio devices.
It is worth saying plainly that this came in under the bottom of the 1.5 to 2.5 second estimate the relay shape was given before it was built.
The safer shape, with no credentials on the laptop, is not the slower one.

## Setting up this desktop

The model is only reachable over HTTP/2 bidirectional streaming, which the AWS
CLI cannot drive and `boto3` cannot either. It needs the experimental SDK, in a
virtual environment of its own:

```
python3 -m venv ~/.fm-voice-venv
~/.fm-voice-venv/bin/pip install aws-sdk-bedrock-runtime
```

Then tell this home which account and model to use.
The relay carries no default for any of these, because a region, a model id and an AWS profile name somebody's account and somebody's choices, and inheriting those from whoever wrote the code is not a sensible way to start talking to a paid API.
Each value is one line in your gitignored `config/` directory, and each has an environment variable that overrides it for a single run.

| File | Environment | Holds |
| --- | --- | --- |
| `config/voice-region` | `FM_VOICE_REGION` | The Bedrock region to open the session in, required. |
| `config/voice-model` | `FM_VOICE_MODEL` | The Nova Sonic model id, required. |
| `config/voice-profile` | `FM_VOICE_PROFILE` | The AWS profile to export credentials from, optional: with no profile the relay uses only credentials that are already in its environment. |
| `config/voice-id` | `FM_VOICE_ID` | The output voice, optional and `matthew` when unset. |

A missing required value refuses with the path to write, so an unconfigured home cannot start the relay by accident, and that configuration is the whole opt-in.
`docs/configuration.md` is the registry for these files.

Check it end to end without a microphone, using a recorded question:

```
cd <your firstmate home>
~/.fm-voice-venv/bin/python bin/fm-voice-relay.py --self-test <clip.pcm>
```

The clip is headerless 16000 Hz mono signed 16-bit little-endian PCM and must end
on speech, not silence. It prints one JSON line: what it heard, what it said, how
long each stage took, whether it answered at all, and, in `relay_error`, what
broke when a turn broke rather than merely going unanswered, so an
infrastructure failure is not read as a slow answer. Feed it a clip that
already ends in silence and it will tell you the timings are measured from the
wrong instant rather than printing a number that looks fast.

## Setting up the laptop

**The audio devices are not verified.** No worker can reach the captain's laptop, so neither the microphone nor the speaker has ever been opened.
Treat the first live run as their test, and expect the device setup to be where it fails.
Everything around them is exercised with files.
That includes the speaker's own byte accounting, the arithmetic deciding which turn a chunk of reply audio is credited to and whose first-audio clock it stamps, which runs against a stub stream in the test suite.
Covering that arithmetic says nothing about how a real output device behaves.

Copy the two files the laptop needs, and install the one dependency:

```
scp <desktop>:<firstmate home>/bin/fm-voice-client.py .
scp <desktop>:<firstmate home>/bin/fm_voice_frame.py .
python3 -m pip install sounddevice
```

`sounddevice` needs PortAudio, which on macOS is `brew install portaudio`. macOS
will ask for microphone permission for whichever terminal you run this from, once.

Then talk:

```
python3 fm-voice-client.py --host <desktop> \
  --relay <firstmate home>/bin/fm-voice-relay.py \
  --relay-python ~/.fm-voice-venv/bin/python
```

The client has no built-in idea of where the relay lives on your desktop, so `--relay` is required and `FM_VOICE_RELAY` sets it once for a shell.

Press Enter to start talking, press Enter again when you have finished. It prints
the timings for each turn as JSON on stdout and everything human on stderr, so
`--runs 5 > runs.jsonl` gives you your own spread to compare against the table
above.

Every record carries `relay_error`, which is null when nothing broke and otherwise names what did.
Where this end is left to infer what happened, it tells the two mid-turn failures apart, because they are not the same fault: a turn that got no reply audio at all says the connection ended, or was lost, or the relay stopped, or the session ended, before that turn was answered, while a turn whose answer had already started playing says the same thing happened before the reply finished.
The second still reads `answered: true`, because sound did reach you and `first_audio_s` is a real measurement of when.
Two other shapes carry neither clause, so do not read the pair above as the whole list: a fault the relay names itself arrives as the relay's own words, which point at the desktop and are kept unaltered because it knows what this end can only guess at.
A reason opening `this end could not handle the relay's reply` is the one that points at your laptop instead, so a healthy relay is not where to look for it.

The exit code is non-zero if any turn went unanswered, if any record carries a `relay_error`, or if the session stopped before it had taken the runs you asked for.
A truncated answer therefore fails the run rather than passing it, so a spread computed from `runs.jsonl` cannot quietly average an infrastructure failure into a latency figure.

If the audio devices are not the ones you want, `--input-device` and `--output-device` take a name or an index.
Neither the client nor this guide can yet tell you which device it resolved, so an unexpected device is diagnosed by trying the other name or index rather than by reading a log line.
If it fails before any audio, add `--verbose` and look for the handshake: a chatty login shell on the desktop printing to stdout is the one failure that looks like a protocol error and is not.

## What it may read

An unconfigured home gets the narrow scope: counts of what is in flight, what is waiting on the captain and what is open for review, with no identifier, title or link assembled at all.
Widening that is one line the captain of those records writes into `config/voice-read-scope` themselves.
Two whole classes of record are excluded at every scope, and excluded by construction rather than filtered on the way out:

- **Finished work in the backlog's done history**, because a spoken "what is
  happening" answer is about open work, and old engagements accumulate there.
- **Free-form note bodies**, because they are written for someone with the whole
  file in front of them, and they are where commercial detail gets quoted.

Only open work and this home's own runtime records are ever assembled.
A task keeps its runtime record until teardown, so the count of workers on deck
and the states beside it still include one whose item is already done; both are a
number and a state word, never anything written in a record.
Verified against the captain's live records on 2026-08-21: every occurrence of
the one customer identifier those records contain sits in finished work or a note
body, so nothing a status answer can say names a customer.
`tests/fm-voice-relay.test.sh` holds that boundary as an executable check, so
widening the reader later fails a test instead of quietly widening what is sent.

Two settings control it, both optional and both in `config/`:

| File | Effect |
| --- | --- |
| `voice-read-scope` | `counts` (the default, and what an absent file means) sends counts only, with no record free text assembled at all. `full` sends counts plus the names, titles and pull request links of open work. |
| `voice-read-deny` | One plain case-insensitive substring per line; `#` comments. Each open item is matched once, against its identifier, its title, its tag values and its pull request link together, and a match is withheld from every list it could have appeared in and reduced to a count, so the agent still says how much is waiting without saying what it is. An absent file means an empty list. |

`voice-read-deny` exists so that one future open item carrying a customer name
can be excluded in a single line rather than by turning the feature off.

The wider scope is not free. Measured on 2026-08-21 on the same question, on the
relay as first written, so compare the two sides with each other rather than with
the table above: the wide answer is 2872 bytes against 445, and it costs both time
and consistency, at 1.348, 1.866 and 2.273 seconds against 1.351, 1.299 and 1.376.
If the spoken answer only ever needs to be "three jobs running, two decisions
waiting", `counts` is faster and steadier as well as narrower.

An unreadable or misspelled `voice-read-scope` refuses rather than falling back
to the wider setting, because falling back would widen what is sent on the
strength of a typo.

## Push to talk, and the setting that refuses

Push to talk is the default: the microphone is closed until you ask for it. That
is `$0.0101` per minute against `$0.0151` for an open microphone, and it is the
setting nobody has decided yet, so this build does not choose the expensive one
on the captain's behalf.

`--listen open-mic` exists as a setting and refuses at startup today.
An open microphone needs something to decide when you stopped speaking, and the client has no end-of-speech detection, so the mode would open a turn, stream audio forever and never mark a boundary, which leaves the relay appending to a session that has already answered.
That detection belongs with carrying context across turns, which is step three, so the flag refuses before it opens an SSH connection or spends anything rather than half working.
The setting stays where it is so that turning it on later is a small change rather than a new flag.

## One turn per session, and what that gives up

The relay reconnects to the model at the start of each turn. That is not
tidiness, it is a measured requirement.

A second question inside a session that has already answered one is treated as an
interruption, unconditionally: the model raises it the instant the audio block
opens. Waiting does not help. Six consecutive turns were tried with no wait, with
a wait until all the reply audio had arrived, and with a wait of the reply's full
spoken duration on top of that. Every one interrupted every second turn. Worse,
an interrupted turn that needs to read the records is lost outright: the model
asks for the records, takes them, and then never answers at all.

Reconnecting costs 0.02 seconds and happens while the captain is pressing the
talk key rather than while they are waiting for a reply, so it is invisible. With
it, six turns in a row all answered.

The same path covers a session the model ends on its own, mid-conversation: that
costs the turn it was in and not the relay, and the next talk key builds a
replacement. Either way the client hears about it at once rather than waiting out
the whole reply timeout in silence.
A turn still waiting for its answer when either happens names why in its own `relay_error`, and [setting up the laptop](#setting-up-the-laptop) describes those reasons.

**What it gives up is memory.** Every question starts fresh, so "and what about
that one" will not work. Carrying context across turns means handling
interruption properly, which is step three.

## Two traps worth keeping

Both cost real time to find the first time. The code comments own the detail;
these are the shapes.

1. **The end of a reply is not the event that says the reply ended.** The obvious
   completion event never arrives on its own. The real end is the content-end
   event carrying an end-of-turn reason.
2. **A clip with no trailing silence is never answered.** The model truncates it
   and waits forever. The relay appends 400 ms of silence. Measured, this is a
   content requirement and not a timing one: 0 ms and 100 ms were never answered,
   while 200, 300, 400 and 800 ms all answered inside the same spread, because the
   padding is sent as fast as the socket takes it. 400 ms is free margin above the
   floor where answers start.

## What this build does not do

- **Interrupting the agent mid-sentence.** Nova Sonic supports it, measured, on
  both model versions, so the capability is there when it is wanted. The concrete
  thing step three has to solve is the interruption finding above: today any
  second question in a session is treated as an interruption, and an interrupted
  turn that reads the records produces no answer at all.
- **Remembering the last question.** See above.
- **Doing any project work.** Real work is queued for the first mate and the
  agent says so out loud. It has no tool that changes a project.

## Cost

`$0.00293` per exchange, derived from the first pass's token counts and session seconds, which is roughly a dollar for three hundred and forty questions.
The re-measured exchange is about a quarter of a second shorter, worth about `$0.00004` at the session rate below, so the figure is unchanged at the precision it is quoted to.
Push to talk is `$0.0101` per minute of session against `$0.0151` with an open microphone.

Text in and out is materially dearer on this model version than the one it
replaces, so a long system prompt or a large record answer is a real cost as well
as a real delay. That is the second reason the reader caps its lists rather than
sending every row.

## Owners

| Concern | Owner |
| --- | --- |
| Wire format between the two machines | `bin/fm_voice_frame.py` |
| The relay, the model session, the tools | `bin/fm-voice-relay.py` |
| The laptop end, capture and playback | `bin/fm-voice-client.py` |
| What may be read, and queueing real work | `bin/fm_voice_records.py` |
| The queue the handover writes to | `bin/fm-inbox.sh` |
| The boundary as an executable check | `tests/fm-voice-relay.test.sh` |
