#!/usr/bin/env bash
# type-detect.sh — auto-detect the enclosing CLI agent type.
#
# Extracted verbatim from whoami.sh so that other entry points (send.sh's
# sender binding, BAS-25) can resolve "what kind of agent session am I running
# inside" without shelling out to whoami.sh. Detection is driven by the
# per-type manifests' `detect=` (env-var names) and `detect_proc=` (process
# name globs) keys — no hardcoded type list lives here.
#
# Requires: type-registry.sh and compat.sh sourced (this file sources both,
# guarded, relative to its own directory).

# Guard against double-source.
[ -n "${_AGMSG_TYPE_DETECT_SH:-}" ] && return 0
_AGMSG_TYPE_DETECT_SH=1

# Resolve THIS lib's directory at SOURCE time (same rationale as
# type-registry.sh: BASH_SOURCE inside a later function call can resolve
# against the wrong directory).
_AGMSG_TYPE_DETECT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

# shellcheck disable=SC1091
. "$_AGMSG_TYPE_DETECT_LIB_DIR/type-registry.sh"
# shellcheck disable=SC1091
. "$_AGMSG_TYPE_DETECT_LIB_DIR/compat.sh"

agmsg_detect_cli_type() {
  # `detect=` / `detect_proc=` tokens are split with `read -ra` (IFS word-split,
  # NO pathname expansion) rather than an unquoted `for x in $list` — a file in
  # the caller's cwd matching a pattern like `claude-*` must not glob-eat the
  # pattern. (Plain `set -f` can't be used here: agmsg_known_types discovers types
  # via a `*/` glob that must keep working.)

  # 1. Environment variables. Sorted registry order preserves the historical
  # precedence: a runtime's own session vars (CLAUDE_CODE_SESSION_ID, CODEX_*) are
  # checked before the GEMINI_* family, which users also set for the SDK without
  # the CLI. `detect=explicit` (and types with no detect=) are never auto-detected.
  local _t _v _detect _toks
  while IFS= read -r _t; do
    [ -n "$_t" ] || continue
    _detect="$(agmsg_type_get "$_t" detect)"
    if [ -z "$_detect" ] || [ "$_detect" = "explicit" ]; then
      continue
    fi
    read -ra _toks <<<"$_detect"
    for _v in "${_toks[@]}"; do
      if [ -n "${!_v:-}" ]; then
        echo "$_t"
        return 0
      fi
    done
  done <<EOF
$(agmsg_known_types | sort -u)
EOF

  # 2. Process-tree detection via each type's `detect_proc=` name globs. Walk up
  # from this process; at each ancestor the first type whose glob matches wins
  # (the globs are disjoint, so order within a level is irrelevant).
  local pid=$$ max_depth=10 depth=0 proc_name _pats _pat
  while [ $depth -lt $max_depth ] && [ "$pid" != "1" ] && [ -n "$pid" ]; do
    proc_name=$(compat_get_comm "$pid" 2>/dev/null || true)
    if [ -n "$proc_name" ]; then
      while IFS= read -r _t; do
        [ -n "$_t" ] || continue
        _pats="$(agmsg_type_get "$_t" detect_proc)"
        [ -n "$_pats" ] || continue
        read -ra _toks <<<"$_pats"
        for _pat in "${_toks[@]}"; do
          # $_pat is intentionally an UNQUOTED glob pattern matched against the
          # process name; read -ra already kept it out of pathname expansion.
          # shellcheck disable=SC2254
          case "$proc_name" in
            $_pat) echo "$_t"; return 0 ;;
          esac
        done
      done <<EOF
$(agmsg_known_types | sort -u)
EOF
    fi

    # Move to parent process
    pid=$(compat_get_ppid "$pid" 2>/dev/null || true)
    depth=$((depth + 1))
  done

  # Default fallback
  echo "claude-code"
}
