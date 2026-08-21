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
speaker    <-------------------------------------------------      (eu-north-1)
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

Measured on 2026-08-21, `amazon.nova-2-sonic-v1:0` in `eu-north-1`, on a spoken
question that makes the agent read the records before it can answer, which is the
slowest ordinary case. Six runs each, all six answered each way.

| Path | First audio out, seconds | Median |
| --- | --- | --- |
| Direct from this desktop, no relay | 1.147 1.179 1.203 1.237 1.244 1.317 | 1.220 |
| Over the relay, real client and framing | 1.229 1.379 1.428 1.447 1.481 1.516 | 1.438 |

The clock starts the instant the captain stops speaking and stops when the first
byte of reply audio arrives. The direct figure reproduces the 1.164 second
measurement in the earlier survey, which is what makes it usable as a control.

**The relay costs about 0.22 seconds of the median.** That is framing, the extra
process hop, and reconnecting the model session at the start of each turn.

What the relay figure does NOT include, and could not be measured from here:

- **Your laptop's round trip to this desktop.** The measurement ran over
  `ssh localhost`, so the network hop is zero. Add roughly your own round trip
  time: the audio goes up and the reply comes back, so it lands about once.
- **Microphone capture and speaker output latency.** This desktop has no
  microphone and no speaker, so every measurement used audio files. The client
  reports both device figures in its own output, so your first live run measures
  them rather than guessing.

So your number is about 1.2 to 1.5 seconds plus your round trip time plus your
audio devices. It is worth saying plainly that this came in at or under the
bottom of the 1.5 to 2.5 second estimate the relay shape was given before it was
built. The safer shape, with no credentials on the laptop, is not the slower one.

## Setting up this desktop

The model is only reachable over HTTP/2 bidirectional streaming, which the AWS
CLI cannot drive and `boto3` cannot either. It needs the experimental SDK, in a
virtual environment of its own:

```
python3 -m venv ~/.fm-voice-venv
~/.fm-voice-venv/bin/pip install aws-sdk-bedrock-runtime
```

Check it end to end without a microphone, using a recorded question:

```
cd /workplace/inthuson/firstmate
~/.fm-voice-venv/bin/python bin/fm-voice-relay.py --self-test <clip.pcm>
```

The clip is headerless 16000 Hz mono signed 16-bit little-endian PCM and must end
on speech, not silence. It prints one JSON line: what it heard, what it said, how
long each stage took, and whether it answered at all. Feed it a clip that already
ends in silence and it will tell you the timings are measured from the wrong
instant rather than printing a number that looks fast.

## Setting up the laptop

**None of this is verified.** No worker can reach the captain's laptop, so the
capture and playback paths have never run. Everything else in the client is
exercised with files. Treat the first live run as the test, and expect the audio
device setup to be where it fails.

Copy the two files the laptop needs, and install the one dependency:

```
scp <desktop>:/workplace/inthuson/firstmate/bin/fm-voice-client.py .
scp <desktop>:/workplace/inthuson/firstmate/bin/fm_voice_frame.py .
python3 -m pip install sounddevice
```

`sounddevice` needs PortAudio, which on macOS is `brew install portaudio`. macOS
will ask for microphone permission for whichever terminal you run this from, once.

Then talk:

```
python3 fm-voice-client.py --host <desktop> --relay-python ~/.fm-voice-venv/bin/python
```

Press Enter to start talking, press Enter again when you have finished. It prints
the timings for each turn as JSON on stdout and everything human on stderr, so
`--runs 5 > runs.jsonl` gives you your own spread to compare against the table
above.

If the audio devices are not the ones you want, `--input-device` and
`--output-device` take a name or an index; run with `--verbose` to see what it
picked. If it fails before any audio, add `--verbose` and look for the handshake:
a chatty login shell on the desktop printing to stdout is the one failure that
looks like a protocol error and is not.

## What it may read

The captain granted the voice agent full read access to the first mate's records.
Two whole classes of record are still excluded, and excluded by construction
rather than filtered on the way out:

- **Finished work**, because a spoken "what is happening" answer is about open
  work, and old engagements accumulate in the history.
- **Free-form note bodies**, because they are written for someone with the whole
  file in front of them, and they are where commercial detail gets quoted.

Only open work and this home's own runtime records are ever assembled. Verified
against the captain's live records on 2026-08-21: every occurrence of the one
customer identifier those records contain sits in finished work or a note body,
so nothing a status answer can say names a customer.
`tests/fm-voice-relay.test.sh` holds that boundary as an executable check, so
widening the reader later fails a test instead of quietly widening what is sent.

Two settings narrow it further, both optional and both in `config/`:

| File | Effect |
| --- | --- |
| `voice-read-scope` | `full` (the default) sends counts plus the names, titles and pull request links of open work. `counts` sends counts only, with no record free text assembled at all. |
| `voice-read-deny` | One plain case-insensitive substring per line; `#` comments. Anything matching becomes a withheld count, so the agent still says how much is waiting without saying what it is. An absent file means an empty list. |

`voice-read-deny` exists so that one future open item carrying a customer name
can be excluded in a single line rather than by turning the feature off.

The wider scope is not free. Measured on the same question, the wide answer is
2872 bytes against 445, and it costs both time and consistency: 1.348, 1.866 and
2.273 seconds against 1.351, 1.299 and 1.376. If the spoken answer only ever
needs to be "three jobs running, two decisions waiting", `counts` is faster and
steadier as well as narrower.

An unreadable or misspelled `voice-read-scope` refuses rather than falling back
to the wider setting, because falling back would widen what is sent on the
strength of a typo.

## Push to talk, and how to flip it

Push to talk is the default: the microphone is closed until you ask for it. That
is `$0.0101` per minute against `$0.0151` for an open microphone, and it is the
setting nobody has decided yet, so this build does not choose the expensive one
on the captain's behalf.

One flag flips it: `--listen open-mic`. The model's own speech detector then ends
each turn instead of your key release, and the relay clock follows it, so the
timings above stay comparable.

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

`$0.00293` per exchange on the numbers above, which is roughly a dollar for three
hundred and forty questions. Push to talk is `$0.0101` per minute of session
against `$0.0151` with an open microphone.

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
