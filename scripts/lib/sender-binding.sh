#!/usr/bin/env bash
# sender-binding.sh — bind send.sh's <from> to the calling session's seat.
#
# Background (ADR-0005): send.sh used to take <from> as free text bound to
# nothing, so any session that could reach the bus could write a message
# attributed to any role — including an implementer session minting its own
# "reviewer" approval. Every receipt a downstream gate reads was therefore a
# claim, not evidence. The bus, however, already knows which session holds
# which role: the actas lock (run/actas.<team>__<agent>.session, live seat)
# and the role-session record (run/role-session.<team>__<agent>, last
# embodiment). This lib checks the calling session against that state.
#
# Policy — checked in order, first match wins:
#   1. enforcement off (AGMSG_SENDER_BIND=off/0)            → allow
#   2. caller session unresolvable (no session_env for the
#      detected type, or the var is unset)                  → allow (unbound)
#   3. caller holds the live actas lock for (team, from)    → allow
#   4. another LIVE session holds that lock                 → REFUSE
#   5. the role-session record for (team, from) names the
#      caller (it last embodied the role; no live conflict) → allow
#   6. the caller is seated as some OTHER role in this team
#      (live lock, or role-session record naming it)        → REFUSE
#   7. otherwise (unseated caller, unclaimed role)          → allow
#
# The fail-open cases (2, 7) are deliberate: humans at a terminal, CI, the
# desktop app, and agent types with no exported session id all send with no
# resolvable session, and refusing them would break every non-session entry
# point. What the binding contains is the case that matters: a session that
# IS identifiable and IS seated in the team cannot speak as a role it does
# not hold, whether that role's seat is live (4) or empty (6). Bypassing it
# requires overt tampering (stripping the session env vars, setting
# AGMSG_SENDER_BIND=off, or writing to the DB directly), which is visible in
# the session transcript — the containment boundary is a cooperating-author
# session, per ADR-0005.
#
# Comparison is on the BARE session id (agmsg_instance_bare_sid): the lock
# owner token is composite "<sid>.<pid>", where the pid varies across resume
# generations and derivation paths, and a pid can be shared across sessions
# under the CC 2.1.x daemon (#349) — the sid is the discriminator, the pid
# is not.
#
# Required caller-set variable:
#   SKILL_DIR — agmsg skill root.

# Guard against double-source.
[ -n "${_AGMSG_SENDER_BINDING_SH:-}" ] && return 0
_AGMSG_SENDER_BINDING_SH=1

: "${SKILL_DIR:?sender-binding.sh requires SKILL_DIR}"

_AGMSG_SENDER_BINDING_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

# type-detect pulls in type-registry + compat; actas-lock pulls in
# instance-id (only its pure helpers + liveness are used here — no composite
# derivation, so resolve-project is not needed) and provides the lock
# path/owner/liveness helpers; role-session provides the record readers.
# shellcheck disable=SC1091
. "$_AGMSG_SENDER_BINDING_LIB_DIR/type-detect.sh"
# shellcheck disable=SC1091
. "$_AGMSG_SENDER_BINDING_LIB_DIR/actas-lock.sh"
# shellcheck disable=SC1091
. "$_AGMSG_SENDER_BINDING_LIB_DIR/role-session.sh"

# Reverse of _actas_lock_encode: decode the %XX bytes of a lock filename
# segment back into the team/agent name (UTF-8 safe), for diagnostics.
_agmsg_sender_decode() {
  printf '%s' "$1" | LC_ALL=C awk '
    BEGIN { for (n = 0; n < 256; n++) chr[sprintf("%02X", n)] = sprintf("%c", n) }
    {
      out = ""
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == "%" && i + 2 <= length($0)) {
          out = out chr[toupper(substr($0, i + 1, 2))]
          i += 2
        } else out = out c
      }
      printf "%s", out
    }
  '
}

# Resolve the calling session. Sets (in the caller's shell):
#   AGMSG_SENDER_TYPE — detected agent type (always set; detection falls back
#                       to claude-code, in which case the session var decides)
#   AGMSG_SENDER_SID  — the caller's BARE session id; empty when unresolvable.
agmsg_sender_resolve() {
  AGMSG_SENDER_TYPE="$(agmsg_detect_cli_type)"
  AGMSG_SENDER_SID=""
  local var
  var="$(agmsg_type_get "$AGMSG_SENDER_TYPE" session_env)"
  [ -n "$var" ] || return 0
  AGMSG_SENDER_SID="${!var:-}"
  return 0
}

# agmsg_sender_check <team> <from>
# Return 0 when the calling session may send as <from> in <team>; return 1
# with a stderr diagnostic when it may not. Never prompts, never mutates
# state. See the policy table in the header.
agmsg_sender_check() {
  local team="$1" from="$2"

  # 1. Operator kill switch. For recovery from wedged seat state (a stale
  # lock naming a live-but-unrelated pid, say), not a routine flag: an agent
  # session using it to speak as another role is doing exactly what the
  # binding exists to surface.
  case "${AGMSG_SENDER_BIND:-on}" in
    off|0) return 0 ;;
  esac

  # 2. Who is calling?
  agmsg_sender_resolve
  [ -n "$AGMSG_SENDER_SID" ] || return 0
  local caller="$AGMSG_SENDER_SID"

  # 3./4. The live seat for (team, from), if any.
  local owner owner_bare owner_alive=0
  owner="$(actas_lock_owner "$team" "$from")"
  if [ -n "$owner" ]; then
    owner_bare="$(agmsg_instance_bare_sid "$owner")"
    if [ "$owner_bare" = "$caller" ]; then
      return 0
    fi
    if actas_lock_sid_alive "$owner"; then
      owner_alive=1
    fi
  fi
  if [ "$owner_alive" = 1 ]; then
    printf "Error: sender binding refused this send: '%s' in team '%s' is held by another live session. Messages must be sent as the role this session holds (see whoami.sh / the actas flow).\n" \
      "$from" "$team" >&2
    return 1
  fi

  # 5. No live seat. The role's last recorded embodiment counts: codex roles
  # hold no watcher lock at all, and a claude-code session may send between
  # its join and its watcher's claim. Type must agree when the record has one
  # (a thread id colliding with another type's session id must not bind).
  local rec_sid rec_type
  rec_sid="$(agmsg_role_session_get "$team" "$from" session)"
  if [ -n "$rec_sid" ] && [ "$rec_sid" = "$caller" ]; then
    rec_type="$(agmsg_role_session_get "$team" "$from" type)"
    if [ -z "$rec_type" ] || [ "$rec_type" = "$AGMSG_SENDER_TYPE" ]; then
      return 0
    fi
  fi

  # 6. Is the caller seated as some OTHER role in this team? Any live lock or
  # role-session record in THIS team naming the caller's sid seats it; a
  # seated session may not speak as a role it does not hold.
  local dir enc_team f o role seated=""
  dir="$(_actas_lock_dir)"
  enc_team="$(_actas_lock_encode "$team")"
  for f in "$dir/actas.${enc_team}__"*.session; do
    [ -f "$f" ] || continue
    o="$(head -1 "$f" 2>/dev/null || true)"
    [ -n "$o" ] || continue
    [ "$(agmsg_instance_bare_sid "$o")" = "$caller" ] || continue
    actas_lock_sid_alive "$o" || continue
    role="${f##*__}"; role="${role%.session}"
    role="$(_agmsg_sender_decode "$role")"
    seated="${seated:+$seated, }$role"
  done
  local rtype
  for f in "$dir"/role-session.*; do
    [ -f "$f" ] || continue
    [ "$(_agmsg_role_session_field "$f" session)" = "$caller" ] || continue
    [ "$(_agmsg_role_session_field "$f" team)" = "$team" ] || continue
    # The same type skepticism as rule 5, in both directions: an id collision
    # across types must neither authorize the caller nor restrict it.
    rtype="$(_agmsg_role_session_field "$f" type)"
    if [ -n "$rtype" ] && [ "$rtype" != "$AGMSG_SENDER_TYPE" ]; then continue; fi
    role="$(_agmsg_role_session_field "$f" agent)"
    [ -n "$role" ] || continue
    [ "$role" = "$from" ] && continue
    case ", $seated," in *", $role,"*) continue ;; esac
    seated="${seated:+$seated, }$role"
  done
  if [ -n "$seated" ]; then
    printf "Error: sender binding refused this send: this session is seated as '%s' in team '%s' and cannot send as '%s'. Send as the role you hold, or claim '%s' first (actas flow).\n" \
      "$seated" "$team" "$from" "$from" >&2
    return 1
  fi

  # 7. Unseated caller, unclaimed role.
  return 0
}
