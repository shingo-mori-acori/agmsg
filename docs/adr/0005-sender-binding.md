# ADR 0005: Bind send.sh's sender to the calling session's seat

**Status:** accepted
**Date:** 2026-08-02
**Deciders:** @fujibee

## Context

`send.sh` took `<from>` as a free-text positional argument bound to nothing.
Any process that could reach the bus could write a message attributed to any
role — including an agent session writing a message attributed to the *other*
role in its own team. In dual-agent review workflows built on agmsg, a
downstream push gate reads a `reviewer -> implementer: review-done ...
Verdict: LGTM` history line as a review receipt; with an unbound sender, an
implementer session could mint that receipt itself, so the receipt was a
claim, not evidence. Consumer-side gates cannot close this: a history line's
routing header is trustworthy about which *field* text came from and says
nothing about who *typed* it.

The bus, however, already knows which session embodies which role:

- the **actas lock** (`run/actas.<team>__<agent>.session`) names the live
  session that currently holds a role's seat, with liveness checking;
- the **role-session record** (`run/role-session.<team>__<agent>`) names the
  session that last embodied the role (codex roles hold no watcher lock, so
  the record is their only binding).

## Decision

`send.sh` now checks `<from>` against that state before inserting. The
calling session is resolved from the agent-type manifests: type detection
(shared with `whoami.sh`, extracted to `lib/type-detect.sh`) plus a new
per-type `session_env=` manifest key naming the env var that holds the
session's own id (`CLAUDE_CODE_SESSION_ID`, `CODEX_THREAD_ID`,
`GROK_SESSION_ID`). Comparison is on the bare session id — composite lock
tokens vary in their pid across resume generations, and a pid can be shared
across sessions (#349), so the sid is the discriminator.

Policy, first match wins:

1. `AGMSG_SENDER_BIND=off|0` → allow (operator kill switch);
2. caller unresolvable → allow (unbound send);
3. caller holds the live actas lock for `(team, from)` → allow;
4. another live session holds that lock → **refuse**;
5. the role-session record for `(team, from)` names the caller, and its
   recorded type matches → allow;
6. the caller is seated as some *other* role in this team (live lock, or
   type-matching role-session record) → **refuse**;
7. otherwise → allow.

`--force` continues to bypass roster membership only; it does not bypass the
seat check — `--force` widens who may be *messaged*, never who the caller is.

The containment boundary is a cooperating-author session: bypassing the
binding requires overt tampering (stripping the session env vars, setting
`AGMSG_SENDER_BIND=off`, or writing to the SQLite store directly), all of
which are visible in the session's transcript. The binding turns silent
impersonation into deliberate, attributable tampering; it is not a
cryptographic guarantee.

## Alternatives considered

- **Do nothing (document tamper-evidence).** Leaves every receipt gate built
  on agmsg at "the sender field is a claim". Rejected: the bus already holds
  the state needed to do better, and the failure mode (a forged approval
  unblocking a push) is exactly what those gates exist to refuse.
- **Sign messages (per-session key, gates verify a signature).** Stronger —
  survives direct DB writes — but requires key material per session, a
  signing step in every consumer's fixed parser, and a trust root the
  filesystem bus doesn't have. The consumers' parsers are fixed (they read
  `<status> [<ts>] <from> -> <to>: <body>` lines); a signature would have to
  ride in the body and change every gate. Rejected for now; the refusal
  design deliberately leaves history-line output byte-identical.
- **Fail-closed on unresolvable callers.** Refusing sends with no resolvable
  session would break every non-session entry point: humans at a terminal,
  CI, the desktop app, agent types with no exported session id (gemini,
  detect=explicit types), and grok monitor-launched shells. Rejected;
  fail-open there, with enforcement wherever identity *is* resolvable.
- **Enforce in consumers' gates.** A gate can only parse what history prints;
  it cannot know which session wrote a row. Rejected as structurally
  impossible (this is what BAS-25's consumers concluded).

## Consequences

- Positive: a seated session cannot silently speak as another role; the
  dual-agent review receipt becomes attributable within the
  cooperating-author boundary. Refusals are loud and name the seat state.
- Positive: history output and the message schema are unchanged — consumers'
  fixed parsers are unaffected.
- Negative: send.sh now sources the seat-state libs and runs type detection
  per send (env-var check, plus a bounded process-tree walk when no env var
  matches). A wedged seat state (stale lock naming a live-but-unrelated pid)
  can refuse a legitimate send until reclaimed; `AGMSG_SENDER_BIND=off` is
  the escape hatch.
- Neutral: sends from unresolvable callers remain unbound, exactly as before.

## References

- Linear BAS-25 (the forged-verdict repro), BAS-26 (consumer-side receipt
  hardening this cannot be closed from)
- `scripts/lib/sender-binding.sh`, `scripts/lib/type-detect.sh`
- Related: [ADR-0002](0002-driver-discovery-and-plugin-opt-in.md) (manifest
  key conventions), #93/#349 (instance-id semantics the comparison relies on)
