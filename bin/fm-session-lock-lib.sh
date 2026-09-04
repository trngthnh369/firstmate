#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.

# Cursor process identity is NOT expressible as a command-name pattern and is
# deliberately not added to the tables below: Cursor's installed names are
# cursor-agent and the far-too-generic legacy alias `agent`, and it runs as a
# bundled node script. bin/fm-cursor-lib.sh is the fleet's single owner of that
# decision, so this file delegates to it rather than widening the name match.
# shellcheck source=bin/fm-cursor-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-cursor-lib.sh"

# Process-table access (comm / args / ppid / liveness) is platform-specific and
# owned by fm-ps-lib.sh. On Windows it also fixes this file's pid namespace to
# WINPID - read that file's PID NAMESPACE note before changing anything here.
# shellcheck source=bin/fm-ps-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-ps-lib.sh"

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi)

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# True when the process described by command name $1 and full argument string $2
# is a verified harness. Sets FM_HARNESS_IS_CLAUDE for the ancestry walk.
#
# Evidence, in order:
#   1. the basename of the reported command name, against FM_HARNESS_RE.
#   2. an exact harness component in that command path or in argv[0]. Both are
#      needed because the two platforms report different things: macOS reports
#      argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
#      name and ignores argv[0] entirely, so a version-named Claude Code binary
#      is identified by its install path on macOS and by argv[0] on Linux.
#   3. a bare interpreter (node, python) running a harness script path.
#   4. Cursor's own structural identity, owned by bin/fm-cursor-lib.sh.
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  # Builtins, not `basename` and `grep`. This runs once per ancestry hop and the
  # walk is on the Claude Stop hook's path at every turn end; under MSYS, where
  # each fork is a real Windows process costing ~85ms, the three spawns this used
  # to make per hop dominated the whole walk. Bash's =~ is ERE, same as grep -E,
  # and the pattern must stay unquoted to be read as a regex.
  base=${comm%/}
  base=${base##*/}
  if [[ $base =~ $FM_HARNESS_RE ]]; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if [[ $args =~ $FM_HARNESS_RE ]]; then
        case "$args" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
        return 0
      fi
      ;;
  esac
  # Cursor: its own owner decides, from Cursor's name or versioned install tree
  # in the command path or argv[0]. Without this a Cursor primary can never
  # locate its own harness in the ancestry, so every session start refuses the
  # fleet lock as read-only and the park can never arm.
  fm_cursor_process_matches "$comm" "$args" "$argv0" && return 0
  return 1
}

# Walk the invoking shell's process ancestry (up to 16 hops) and report this
# session's contiguous verified-harness ancestry, innermost pid first.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess.
#
# For every harness except Claude the innermost match is the session, which is
# where e.g. Pi's shared signed-wrapper ancestry actually holds the lock: a
# "pi-signed" launcher can be the direct parent of the inner "pi" engine pid that
# owns the lock, and the wrapper pid above it is not that owner. Claude Code
# instead runs hooks several levels below the session inside its own nested
# worker chain (hook shell -> claude bg-spare -> claude bg-pty-host -> claude ->
# claude), with no non-harness process between them. Which pid in that run is the
# session cannot be read off the ancestry at all, so the whole contiguous run is
# reported and the callers below decide what they need from it.
#
# ASSIGNS the run, newline-separated, into the variable named $1.
#
# Assigning is what lets a caller take the walk in its OWN shell. That is a cost
# rule rather than a correctness one now that fm_ps_self_pid names the invoking
# shell on both platforms: the snapshots this walk takes are ordinary shell
# variables, so a $( ) fork inherits them but can never publish one back, and a
# walk read through a substitution throws its snapshot away. On Windows that
# snapshot is a PowerShell spawn, and this runs on the Claude Stop hook at every
# turn end.
#
# The locals carry a __fmw_ prefix of their own, and every out-variable name
# below is one of them. An assigning function writes through `printf -v` into
# whatever name it was handed, so a local of that same name inside the CALLEE
# shadows the caller's variable and swallows the value silently. The primitives
# in fm-ps-lib.sh all use __fm_, so a walk that named its own pid __fm_pid would
# hand fm_ps_self_pid the name of that function's own local and read back
# nothing. Keep each layer's prefix distinct from the layer it calls.
fm_harness_ancestry_pids_into() {  # <outvar>
  local __fmw_out=$1 __fmw_pid __fmw_next __fmw_comm __fmw_args
  local __fmw_extending=0 __fmw_run=''
  # Both snapshot calls must run in THIS shell, for the reason above: taken
  # inside one of the per-hop reads they would be retaken on every single read.
  fm_ps_self_pid __fmw_pid || return 1
  fm_ps_cyg_ensure || true
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    # One combined lookup per hop; see fm_ps_hop for why this is not three calls.
    fm_ps_hop "$__fmw_pid" __fmw_comm __fmw_args __fmw_next || break
    if fm_harness_process_matches "$__fmw_comm" "$__fmw_args"; then
      __fmw_run="${__fmw_run:+$__fmw_run
}$__fmw_pid"
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      __fmw_extending=1
    elif [ "$__fmw_extending" -eq 1 ]; then
      break
    fi
    [ -n "$__fmw_next" ] && [ "$__fmw_next" -gt 1 ] || break
    __fmw_pid=$__fmw_next
  done
  [ -n "$__fmw_run" ] || return 1
  printf -v "$__fmw_out" '%s' "$__fmw_run"
}

# Print that run, for callers outside this file that want it as text. Callers in
# this file take the assigning form above instead.
fm_harness_ancestry_pids() {
  local run
  fm_harness_ancestry_pids_into run || return 1
  printf '%s\n' "$run"
}

# Print the one pid that identifies this session when the session lock is being
# WRITTEN: the outermost pid of the contiguous run. That is the pid that lives as
# long as the session - a Claude worker several levels in is reaped when its hook
# returns, and a lock naming it would look stale moments later while the session
# is still running. Every non-Claude harness reports a single pid, so this is its
# innermost match unchanged.
#
# ASSIGNS into the variable named $1 and takes the walk in the caller's shell,
# so nothing this resolution costs is thrown away with a subshell.
# Its locals carry a __fmr_ prefix for the shadowing reason given above.
fm_harness_ancestry_pid_into() {  # <outvar>
  local __fmr_out=$1 __fmr_run __fmr_pid __fmr_outermost=''
  fm_harness_ancestry_pids_into __fmr_run || return 1
  while IFS= read -r __fmr_pid; do
    [ -n "$__fmr_pid" ] && __fmr_outermost=$__fmr_pid
  done <<EOF
$__fmr_run
EOF
  [ -n "$__fmr_outermost" ] || return 1
  printf -v "$__fmr_out" '%s' "$__fmr_outermost"
}

# Print that pid, for callers outside this file that want it as text.
fm_harness_ancestry_pid() {
  local pid
  fm_harness_ancestry_pid_into pid || return 1
  printf '%s\n' "$pid"
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  # Never `kill -0` here: on Windows this pid is a WINPID, which Cygwin kill
  # cannot resolve - it answers 1 for a live harness and for a dead one alike.
  fm_ps_pid_alive "$pid" || return 1
  fm_ps_cyg_ensure || true
  comm=$(fm_ps_comm "$pid") || return 1
  args=$(fm_ps_args "$pid")
  fm_harness_process_matches "$comm" "$args"
}

# True when state dir $1 holds a session lock whose pid is ANY harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. Membership is the honest test of that question, because the
# lock owner sits at an unknown depth in a contiguous Claude run - it is the
# outermost pid when the hook fires inside the session's own nested worker chain,
# and an inner pid when a harness-named daemon parents the session. A missing
# lock, a malformed lock, a lock held by a harness outside this ancestry, or an
# ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_harness_ancestry_pids_into pids || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  return 1
}
