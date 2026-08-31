#!/usr/bin/env bash
# Platform-neutral process-table primitives for harness ancestry.
#
# ONE owner of "how does this platform answer comm / args / ppid / liveness for
# a pid?", so the ancestry walks in fm-session-lock-lib.sh and
# fm-sessionstart-nudge.sh stay a single readable walk instead of each growing
# its own platform branch.
# This file is sourced by scripts and has no side effects on source.
#
# Why it exists - three independent facts about Git Bash / MSYS on Windows, any
# one of which alone breaks an ancestry walk written for POSIX:
#
#   1. Cygwin ps (3.5.7) has no `-o` option at all. Every `ps -o comm= -p "$pid"`
#      exits 1 with "ps: unknown option -- o", so a walk breaks on its first hop
#      and the session can never verify fleet-lock ownership. Fails loudly.
#   2. The Cygwin process table lists only MSYS processes. A native harness
#      binary (claude.exe) is simply absent from it, and the shell it launched
#      reports PPID 1 - so a Cygwin-only walk stops at a root that is not the
#      harness. `ps -W` does list native processes but reports PPID 0 for every
#      one of them, so it cannot rebuild a chain either.
#   3. MSYS emulates fork by launching a fresh Windows process, and Windows
#      never reparents or clears ParentProcessId. So a Windows-only walk that
#      starts in a short-lived subshell follows ParentProcessId straight into a
#      pid that has already exited. Fails SILENTLY.
#
# So neither table alone can answer the question, and the walk uses each for
# what it actually knows: Cygwin for parent links between MSYS processes and for
# their real identity, Windows for the hops above the outermost MSYS process.
#
# PID NAMESPACE - the part that is easy to get silently wrong:
#
#   On Windows this library speaks WINPID and nothing else, for MSYS and native
#   processes alike. It has to: a native harness exists ONLY as a WINPID, so an
#   ancestry that must reach it cannot be expressed in Cygwin pids. Every pid
#   this library accepts or prints on Windows is a WINPID, including the value
#   fm-lock.sh writes into state/.lock.
#
#   The consequence callers must respect: Cygwin `kill -0` does NOT resolve a
#   WINPID. Measured against a live claude.exe it returns 1, exactly as it does
#   for a pid that never existed - so it cannot tell a live harness from a dead
#   one here and must never be used on a pid that came from this library. Use
#   fm_ps_pid_alive instead.
#
#   POSIX process-group control (pgid, signalling a whole group) is a DIFFERENT
#   namespace: it addresses MSYS children firstmate spawned itself, which do
#   live in the Cygwin table and do answer Cygwin signals. Those call sites keep
#   Cygwin pids and are deliberately not served by this library. Do not mix the
#   two namespaces.

# Selection is by CAPABILITY, not by platform name, and the POSIX path wins
# whenever it works.
#
# That ordering is deliberate and load-bearing. `ps -o` fails loudly here, so a
# real Git Bash session still lands on the Windows path - but any caller that
# puts a working `ps` in front on PATH, which is exactly how the behavior tests
# drive a deterministic process table, keeps the original POSIX semantics and
# the identity rules stay testable from any host. Platform is still required for
# the Windows path so that a POSIX box whose `ps` failed for an unrelated reason
# never starts shelling out to PowerShell; it just has no working source.
FM_PS_WINDOWS=0
case "$(uname -s 2>/dev/null)" in
  MSYS*|MINGW*|CYGWIN*)
    ps -o comm= -p $$ >/dev/null 2>&1 || FM_PS_WINDOWS=1
    ;;
esac

# Cached tables. FM_PS_TABLE is the Windows process table as TSV rows
#   winpid <TAB> parent-winpid <TAB> name <TAB> command-line
# FM_PS_CYG_TABLE is raw Cygwin `ps` output (PID PPID PGID WINPID ... COMMAND).
FM_PS_TABLE=''
FM_PS_CYG_TABLE=''

# Take one snapshot of both process tables.
#
# Deliberately one snapshot per WALK rather than one query per HOP: a walk is up
# to 16 hops, a single-pid Windows query costs ~0.4s and a whole-table snapshot
# ~0.7s, and this runs in session start AND in the Claude Stop hook every turn.
#
# Tabs and newlines are stripped from the command line so one process can never
# occupy more than one row or shift a column. An absent command line (Windows
# denies it for elevated processes) is a legitimately empty last field, not a
# failure - the name alone still identifies the harness.
fm_ps_table_refresh() {  # [start-winpid]
  local start=${1:-0} filter
  [ "$FM_PS_WINDOWS" -eq 1 ] || return 1
  # Seed the chain at the OUTERMOST MSYS ancestor, not at the caller. Windows
  # ParentProcessId dangles across MSYS fork emulation, so a chain rooted at an
  # inner shell can stop dead one hop up and never reach the harness; the
  # outermost MSYS process is the last one whose Windows parent is real. This
  # climb is pure builtins over the already-cheap Cygwin table.
  if [ "$start" -gt 0 ] 2>/dev/null && fm_ps_cyg_ensure; then
    local __fm_s1 __fm_s2 __fm_s3 __fm_s4 __fm_cur='' __fm_next __fm_hop
    while read -r __fm_s1 __fm_s2 __fm_s3 __fm_s4 _; do
      [ "$__fm_s4" = "$start" ] && { __fm_cur=$__fm_s1; break; }
    done <<< "$FM_PS_CYG_TABLE"
    for __fm_hop in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
      [ -n "$__fm_cur" ] || break
      __fm_next=''
      while read -r __fm_s1 __fm_s2 __fm_s3 __fm_s4 _; do
        [ "$__fm_s1" = "$__fm_cur" ] && { __fm_next=$__fm_s2; break; }
      done <<< "$FM_PS_CYG_TABLE"
      case "$__fm_next" in
        ''|*[!0-9]*) break ;;
      esac
      [ "$__fm_next" -gt 1 ] || break
      __fm_cur=$__fm_next
    done
    if [ -n "$__fm_cur" ]; then
      read -r __fm_next < "/proc/$__fm_cur/winpid" 2>/dev/null || :
      case "$__fm_next" in
        ''|*[!0-9]*) : ;;
        *) start=$__fm_next ;;
      esac
    fi
  fi
  # Ask for the ANCESTRY of one pid rather than every process on the machine
  # when a start pid is known. The PowerShell spawn costs the same either way,
  # but the result drops from ~340 rows and 80KB to a couple of dozen - and that
  # matters because this string is then read inside further shells, where under
  # MSYS a large variable makes every one of them measurably more expensive.
  if [ "$start" -gt 0 ] 2>/dev/null; then
    # The chain walk is a statement block, so it has to be a script block before
    # it can be piped; a bare `while {...} | ForEach-Object` is a parse error and
    # yields nothing, which reads exactly like "no such process".
    filter="&{ \$p = Get-CimInstance Win32_Process -Filter 'ProcessId=$start' -ErrorAction SilentlyContinue; \$d = 0; while (\$p -and \$d -lt 24) { \$p; \$p = Get-CimInstance Win32_Process -Filter \"ProcessId=\$(\$p.ParentProcessId)\" -ErrorAction SilentlyContinue; \$d++ } }"
  else
    filter="Get-CimInstance Win32_Process"
  fi
  FM_PS_TABLE=$(powershell.exe -NoProfile -NonInteractive -Command \
    "$filter | ForEach-Object { (\$_.ProcessId, \$_.ParentProcessId, \$_.Name, (\$_.CommandLine -replace '[\r\n\t]',' ')) -join \"\`t\" }" \
    2>/dev/null | tr -d '\r') || return 1
  [ -n "$FM_PS_TABLE" ] || return 1
  return 0
}

# Snapshot the Cygwin table. Kept separate from the Windows one and always
# taken first because it is nearly free, while the Windows snapshot shells out
# to PowerShell. An ancestry that never leaves MSYS - which is exactly what the
# behavior fixtures build - must therefore cost no PowerShell call at all.
fm_ps_cyg_ensure() {
  [ "$FM_PS_WINDOWS" -eq 1 ] || return 0
  [ -n "$FM_PS_CYG_TABLE" ] && return 0
  FM_PS_CYG_TABLE=$(ps 2>/dev/null) || return 1
  [ -n "$FM_PS_CYG_TABLE" ]
}

# Take the snapshots now if they have not been taken in this shell.
#
# Callers about to make several reads must call this in their OWN shell first:
# each $(fm_ps_comm ...) runs in a subshell that inherits a populated table but
# cannot publish one back, so without this every read would spawn its own
# snapshot.
fm_ps_table_ensure() {  # [start-winpid]
  [ "$FM_PS_WINDOWS" -eq 1 ] || return 0
  [ -n "$FM_PS_TABLE" ] && return 0
  fm_ps_table_refresh "${1:-0}"
}

# Print field $2 (2=parent winpid, 3=name, 4=command line) of winpid $1.
fm_ps_table_field() {  # <winpid> <field-index>
  local pid=$1 field=$2
  [ -n "$FM_PS_TABLE" ] || fm_ps_table_refresh || return 1
  printf '%s\n' "$FM_PS_TABLE" \
    | awk -F'\t' -v p="$pid" -v f="$field" '$1==p { print $f; found=1; exit } END { exit !found }'
}

# Print the Cygwin pid owning winpid $1, or return 1 when it is not an MSYS
# process. Cygwin ps prints WINPID in its fourth column, which is the one place
# the two namespaces are bridged.
fm_ps_cyg_pid() {  # <winpid>
  local winpid=$1 cyg
  [ -n "$FM_PS_CYG_TABLE" ] || FM_PS_CYG_TABLE=$(ps 2>/dev/null) || return 1
  cyg=$(printf '%s\n' "$FM_PS_CYG_TABLE" | awk -v w="$winpid" '$4==w { print $1; exit }')
  case "$cyg" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$cyg"
}

# Resolve the pid the ancestry walk should START from into variable named $1.
#
# ASSIGNS rather than prints, and that is the whole point on Windows: read
# through $( ) this would name the substitution's own short-lived subshell.
# Assigned in the caller's shell it names a process that stays alive for the
# walk, which is what makes /proc/self/winpid safe to use here.
#
# The locals are __fm_-prefixed because a local named after the caller's own
# variable would shadow the very variable this assigns to.
fm_ps_self_pid() {  # <outvar>
  local __fm_out=$1 __fm_pid=''
  if [ "$FM_PS_WINDOWS" -eq 1 ]; then
    read -r __fm_pid < /proc/self/winpid 2>/dev/null || return 1
  else
    __fm_pid=$$
  fi
  case "$__fm_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf -v "$__fm_out" '%s' "$__fm_pid"
}

# Command name of pid $1, or return 1 when the process is gone.
#
# An MSYS process is identified from /proc rather than from the Windows table,
# because the Windows table would only ever say bash.exe for it. That matters
# for more than tidiness: a harness that runs as a script under MSYS - which the
# node-hosted adapters can - is a harness the Windows name alone would hide.
fm_ps_comm() {  # <pid>
  local pid=$1 cyg name
  if [ "$FM_PS_WINDOWS" -eq 1 ]; then
    if cyg=$(fm_ps_cyg_pid "$pid"); then
      # No trailing newline in this /proc entry, so read's exit status lies;
      # only the assigned value is evidence.
      read -r name < "/proc/$cyg/exename" 2>/dev/null || :
      if [ -n "$name" ]; then
        printf '%s\n' "$name"
        return 0
      fi
    fi
    fm_ps_table_field "$pid" 3
    return
  fi
  ps -o comm= -p "$pid" 2>/dev/null
}

# Full argument string of pid $1. An empty result is a legitimate answer, so
# callers must not treat it as failure.
fm_ps_args() {  # <pid>
  local pid=$1 cyg args
  if [ "$FM_PS_WINDOWS" -eq 1 ]; then
    if cyg=$(fm_ps_cyg_pid "$pid"); then
      args=$(tr '\0' ' ' < "/proc/$cyg/cmdline" 2>/dev/null) || args=''
      if [ -n "$args" ]; then
        printf '%s\n' "$args"
        return 0
      fi
    fi
    fm_ps_table_field "$pid" 4
    return
  fi
  ps -o args= -p "$pid" 2>/dev/null
}

# Parent pid of pid $1, or return 1 when it cannot be determined.
#
# For an MSYS process the parent link comes from the Cygwin table, never from
# Windows: MSYS fork emulation leaves Windows ParentProcessId pointing at a
# forked pid that has already exited, so the Windows link is the one that
# dangles. The Windows table is used only once the Cygwin chain is exhausted -
# at the outermost MSYS process, whose parent is the native harness.
fm_ps_ppid() {  # <pid>
  local pid=$1 cyg cyg_parent ppid=''
  if [ "$FM_PS_WINDOWS" -eq 1 ]; then
    if cyg=$(fm_ps_cyg_pid "$pid"); then
      cyg_parent=$(printf '%s\n' "$FM_PS_CYG_TABLE" \
        | awk -v x="$cyg" '$1==x { print $2; exit }')
      case "$cyg_parent" in
        ''|*[!0-9]*) cyg_parent='' ;;
      esac
      if [ -n "$cyg_parent" ] && [ "$cyg_parent" -gt 1 ]; then
        read -r ppid < "/proc/$cyg_parent/winpid" 2>/dev/null || ppid=''
      fi
    fi
    [ -n "$ppid" ] || ppid=$(fm_ps_table_field "$pid" 2) || return 1
  else
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  fi
  case "$ppid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$ppid"
}

# Resolve pid $1 into the caller's variables named $2 (comm), $3 (args) and
# $4 (parent pid) in one go, returning 1 when the process cannot be found.
#
# This exists purely for cost, and the cost is not incidental. Under MSYS every
# subshell is a real Windows process, so the natural
#   comm=$(fm_ps_comm "$pid"); args=$(fm_ps_args "$pid"); ppid=$(fm_ps_ppid "$pid")
# spends six process spawns per hop, and a 16-hop walk runs on the Claude Stop
# hook at every single turn end. Measured on this machine that shape cost ~700ms
# per hop against ~230ms for one combined lookup. So this assigns instead of
# printing, and asks each table exactly once.
#
# The per-primitive functions above remain the readable reference and are what
# any non-walk caller should use; this is the hot path.
fm_ps_hop() {  # <pid> <comm-outvar> <args-outvar> <ppid-outvar>
  local __fm_pid=$1 __fm_c=$2 __fm_a=$3 __fm_p=$4
  local __fm_cyg='' __fm_cygppid='' __fm_comm='' __fm_args='' __fm_ppid=''
  if [ "$FM_PS_WINDOWS" -ne 1 ]; then
    __fm_comm=$(ps -o comm= -p "$__fm_pid" 2>/dev/null) || return 1
    __fm_args=$(ps -o args= -p "$__fm_pid" 2>/dev/null)
    __fm_ppid=$(ps -o ppid= -p "$__fm_pid" 2>/dev/null | tr -d ' ')
  else
    # One pass over the Cygwin table answers both "is this MSYS?" and "who is
    # its Cygwin parent?", which is the link that stays valid across MSYS fork
    # emulation while the Windows one dangles.
    #
    # Scanned with shell builtins over a here-string rather than piped into awk:
    # a pipeline is two more Windows processes per hop here, and process spawns
    # are the single most expensive thing this walk does.
    local __fm_c1 __fm_c2 __fm_c3 __fm_c4
    while read -r __fm_c1 __fm_c2 __fm_c3 __fm_c4 _; do
      if [ "$__fm_c4" = "$__fm_pid" ]; then
        __fm_cyg=$__fm_c1
        __fm_cygppid=$__fm_c2
        break
      fi
    done <<< "$FM_PS_CYG_TABLE"
    case "$__fm_cyg" in
      ''|*[!0-9]*) __fm_cyg='' ;;
    esac
    if [ -n "$__fm_cyg" ]; then
      # /proc reads are shell builtins here, so an MSYS hop stays nearly free
      # and reports the identity the Windows table would have hidden behind a
      # generic bash.exe.
      # These /proc entries carry no trailing newline, so `read` reports failure
      # even though it assigned the value. Judge by what landed in the variable,
      # never by read's exit status, or every MSYS hop silently falls through to
      # the Windows table and reports a generic bash.exe.
      read -r __fm_comm < "/proc/$__fm_cyg/exename" 2>/dev/null || :
      __fm_args=$(tr '\0' ' ' < "/proc/$__fm_cyg/cmdline" 2>/dev/null) || __fm_args=''
      case "$__fm_cygppid" in
        ''|*[!0-9]*) __fm_cygppid='' ;;
      esac
      if [ -n "$__fm_cygppid" ] && [ "$__fm_cygppid" -gt 1 ]; then
        read -r __fm_ppid < "/proc/$__fm_cygppid/winpid" 2>/dev/null || :
      fi
    fi
    # Native process, or an MSYS one whose chain has reached its outermost hop:
    # everything still missing comes from the Windows table.
    if [ -z "$__fm_comm" ] || [ -z "$__fm_ppid" ]; then
      # Only here does the Windows table become necessary, so only here is it
      # fetched. This runs in the CALLER's shell, so the snapshot it takes stays
      # visible to the rest of the walk - which is what makes lazy safe now and
      # did not hold back when each field read happened inside its own $( ).
      # The payoff: an ancestry that never leaves MSYS, which is what the
      # behavior fixtures build, spawns no PowerShell at all.
      fm_ps_table_ensure "$__fm_pid" || :
      local __fm_w1 __fm_w2 __fm_w3 __fm_w4 __fm_found=0
      while IFS=$'\t' read -r __fm_w1 __fm_w2 __fm_w3 __fm_w4; do
        if [ "$__fm_w1" = "$__fm_pid" ]; then
          __fm_found=1
          [ -n "$__fm_ppid" ] || __fm_ppid=$__fm_w2
          [ -n "$__fm_comm" ] || __fm_comm=$__fm_w3
          [ -n "$__fm_args" ] || __fm_args=$__fm_w4
          break
        fi
      done <<< "$FM_PS_TABLE"
      [ "$__fm_found" -eq 1 ] || [ -n "$__fm_comm" ] || return 1
    fi
  fi
  [ -n "$__fm_comm" ] || return 1
  case "$__fm_ppid" in
    ''|*[!0-9]*) __fm_ppid='' ;;
  esac
  printf -v "$__fm_c" '%s' "$__fm_comm"
  printf -v "$__fm_a" '%s' "$__fm_args"
  printf -v "$__fm_p" '%s' "$__fm_ppid"
}

# True when pid $1 currently exists.
#
# Always a FRESH read, never the cached snapshot: this is what separates a live
# lock owner from a stale one, and a cached answer would report a harness that
# exited moments ago as still holding the lock.
fm_ps_pid_alive() {  # <pid>
  local pid=$1 out cyg
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if [ "$FM_PS_WINDOWS" -eq 1 ]; then
    # An MSYS process answers a Cygwin signal on its own Cygwin pid, so ask the
    # cheap way first and keep PowerShell for pids Cygwin cannot see at all.
    # Re-read rather than reuse the cache: liveness must never be a stale answer.
    FM_PS_CYG_TABLE=$(ps 2>/dev/null) || FM_PS_CYG_TABLE=''
    if cyg=$(fm_ps_cyg_pid "$pid"); then
      kill -0 "$cyg" 2>/dev/null
      return
    fi
    out=$(powershell.exe -NoProfile -NonInteractive -Command \
      "if (Get-CimInstance Win32_Process -Filter 'ProcessId=$pid' -ErrorAction SilentlyContinue) { 'y' }" \
      2>/dev/null | tr -d '\r\n ')
    [ "$out" = "y" ]
    return
  fi
  kill -0 "$pid" 2>/dev/null
}
