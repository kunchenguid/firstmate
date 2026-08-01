# Provenance

This package is the firstmate-owned, incompatible successor to [`lavish-axi`](https://github.com/kunchenguid/lavish-axi).

The upstream package is MIT licensed and established the Lavish product name and the `lavish-axi` executable.
This fork retains those compatibility names but replaces the upstream browser runtime, local server, long-poll, and session lifecycle with a durable file protocol and bounded commands.
Its `board` command emits self-contained HTML and exits without opening a browser or starting a service.

No upstream runtime source is copied into this implementation.
