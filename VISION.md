# Vision

`firstmate` exists so that one person can run a crew of coding agents with the leverage of a team and the accountability of a single pair of hands.
It serves the captain: an individual operator whose ambitions outrun their attention, and it turns intent stated once into delegated, supervised, evidence-backed work across every project they care about.
It empowers exactly one individual; collaboration between humans belongs to other systems.
It owns exactly one thing: the layer between the captain's intent and the agents that carry it out.

## One captain, one interface

The captain talks to the first mate and to nobody else; every worker reports through the first mate and never addresses the captain directly.
Captain-facing language is outcomes, consequences, and decisions; the machinery that produced them stays below deck.
An escalation exists for a decision only a human can make; progress, retries, and internal mechanics are never news.
The interface must stay honest under load: batching and silence are presentation choices, and never hide a failure, a decision, or a risk.
Experience features on top of this interface are welcome only when they compose with the workflows the captain already has: opt-in, and never in the way.

## Authority is explicit and never inferred

The captain is the default authority for every gate; autonomy exists only as an explicit grant, never as a default, and new capability ships as an option to enable, never as behavior that assumes consent.
The first mate reads projects but does not change them; project changes belong to workers in isolated copies, delivered through each project's selected path.
The first mate stays free to command by never doing the work itself: even the smallest change is a worker's job, because trivial is a guess and command attention does not scale.
Merging, discarding work, and anything destructive, irreversible, or security-sensitive require the captain's explicit word.
Standing autonomy is scoped consent granted per project, exercised only within the captain's original request, and it never quietly widens.
Evidence is never authorization: a diagnosis, a report, or a recommendation authorizes nothing by itself.
Initiative beyond a stated request is legitimate only where the captain has committed a vision precise enough to adjudicate it, and even then only as an explicit opt-in.
A current, explicit captain instruction outranks any standing rule the first mate wrote for itself, exactly as stated and no further.

## Scripts own the mechanics, agents own the judgment

Logic that can be exact lives in deterministic scripts; work that requires understanding lives in an agent; the two never mix.
A rigid script must never adjudicate meaning, and intelligence must never be spent on what a script can do exactly and repeatably.
Scripts stop safely and report when the world surprises them; agents read, interpret, and decide.
Token efficiency is a first-class concern: every agent's context stays lean, and every task is achieved with the fewest tokens that do it well.
The command structure stays flat: every layer between the captain's intent and the acting agent costs fidelity and tokens, so depth is capped, not grown.

## A restart is a non-event

Everything that matters survives the death of any conversation: work in flight, promises made, decisions pending, and the captain's preferences live in durable records, never in chat memory.
The fleet reconciles from disk and from live session state, so killing any session, including the first mate's own, loses nothing and surprises no one.
Obligations are closed by records, not by recollection: a promised reply, an open decision, or a queued wake is retired only by the durable event that answers it.

## Delegation with a spine

Every task gets an explicit contract before it starts: what to build or learn, how it ships, and how much autonomy the worker has; the machinery refuses to guess.
Ship work lands through the project's chosen delivery rigor; scout work leaves a standalone report; neither is allowed to blur into the other on its own.
Workers are supervised, not trusted: independent validation, behavioral tests, and the configured merge authority stand between a worker's confidence and anything that lands.
Unlanded work is never torn down; a refusal to discard is a finding, not an obstacle.
A new task shape earns its way in only when existing primitives genuinely cannot compose to cover it; simplicity is a capability the fleet defends.

## The fleet outlives any vendor

The first mate is an agent distro, not an app: instructions, skills, scripts, and state conventions that any verified harness can inhabit.
The first mate can read, understand, and evolve every part of itself: plain instructions, scripts, and text records keep the whole system introspectable and hot-modifiable by the very agent that runs it.
Harness adapters earn trust through verification, and the fleet keeps sailing when any one vendor's tool degrades.
Contracts bind to semantics a vendor actually exposes, never to the pixels of today's UI.
Quota, model, and effort choices stay inspectable and captain-owned; the first mate never downgrades the intelligence doing the work without the captain's standing, explicit permission.

## Scope

firstmate is the command layer, not the workshop: validation belongs to no-mistakes, CI belongs to the forge, and merge policy belongs to the configured authority.
It is not a general agent framework, not a hosted service, and not a prepackaged product; it is a template one person clones, owns, deeply customizes, and operates under their own identity.
The shared surface is generic and captain-agnostic; everything personal - preferences, projects, records, credentials - stays private to the home that owns it.
This repository ships through its own discipline: firstmate work is validated like any other project's, and field incidents become regression coverage.

A change aligns when it gives the captain more shipped outcomes per unit of attention and tokens, makes delegation safer or more legible, strengthens a refusal path, keeps the system introspectable and hot-modifiable, or lets the fleet survive another failure mode.
A change should be resisted when it lets the fleet act beyond adjudicable intent, assumes consent instead of asking for it, adds a layer between intent and action, mixes scripted mechanics with agent judgment, spends tokens where a script would do, serves anyone but the captain, couples the distro to one vendor, buries an outcome in mechanics, or grows the command layer into the workshop it commands.
