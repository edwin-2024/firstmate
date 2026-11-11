#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process run inside that same session?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock and its
# state/.lock-session sidecar; bin/fm-claude-stop-autoarm.sh uses it to prove a
# Stop hook fires inside the lock-owning primary session before it may arm or
# rewake. Two signals decide ownership, either one sufficient: the recorded pid
# is a member of this process's contiguous harness ancestry, or the trusted
# Claude session id below matches the id recorded beside a live lock. Neither
# signal ever fails open: no id, no sidecar, an untrusted id, or a different
# recorded id leaves the ancestry verdict exactly as it was.
# This file is sourced by scripts and has no side effects on source.

# Cursor process identity is NOT expressible as a command-name pattern and is
# deliberately not added to the tables below: Cursor's installed names are
# cursor-agent and the far-too-generic legacy alias `agent`, and it runs as a
# bundled node script. bin/fm-cursor-lib.sh is the fleet's single owner of that
# decision, so this file delegates to it rather than widening the name match.
_FM_SESSION_LOCK_LIB_DIR=${BASH_SOURCE[0]%/*}
[ "$_FM_SESSION_LOCK_LIB_DIR" != "${BASH_SOURCE[0]}" ] || _FM_SESSION_LOCK_LIB_DIR=.
# shellcheck source=bin/fm-cursor-lib.sh
. "${_FM_SESSION_LOCK_LIB_DIR:-/}/fm-cursor-lib.sh"
unset _FM_SESSION_LOCK_LIB_DIR

# Known harness command names; extend when a new adapter is verified. omp is
# anchored exactly like pi: its process name is the bare word `omp` (verified,
# omp 18.1.11), and a substring match would claim ompd or comp. Antigravity's
# Windows installer names the executable Antigravity.exe and the backend
# language_server.exe, both inside a directory component named `antigravity`.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$|^omp$|^agy$|^Antigravity$|^language_server$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi omp agy antigravity)

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
  path=${path//\\//}
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
  base=$(basename -- "$comm")
  base=${base%.[eE][xX][eE]}
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
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
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE" || printf '%s' "$args" | grep -qE 'pi-coding-agent|/\.?pi/|\\\.?pi\\'; then
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

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
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
_fm_winpid_alive() {
  local pid=$1
  case "${_FM_UNAME:-$(uname -s 2>/dev/null)}" in
    MINGW*|MSYS*|CYGWIN*)
      if command -v tasklist.exe >/dev/null 2>&1; then
        tasklist.exe //FI "PID eq $pid" //NH 2>/dev/null | grep -iqE "^[a-zA-Z0-9_.-]+\.exe\s+$pid" && return 0
      fi
      ;;
  esac
  return 1
}

_fm_process_comm_args() {  # <pid> -> outputs comm\nargs
  local pid=$1 comm args
  if comm=$(ps -o comm= -p "$pid" 2>/dev/null); then
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    printf '%s\n%s\n' "$comm" "$args"
    return 0
  fi
  if [ ! -r "/proc/$pid/cmdline" ]; then
    local msys_p
    msys_p=$(grep -lx "$pid" /proc/[0-9]*/winpid 2>/dev/null | head -n 1)
    if [ -n "$msys_p" ]; then
      pid=${msys_p%/winpid}
      pid=${pid#/proc/}
    fi
  fi
  if [ -r "/proc/$pid/cmdline" ]; then
    args=$(cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ')
    comm=$(awk '{print $2}' "/proc/$pid/stat" 2>/dev/null | tr -d '()')
    [ -n "$comm" ] || comm=${args%% *}
    printf '%s\n%s\n' "$comm" "$args"
    return 0
  fi
  if command -v powershell.exe >/dev/null 2>&1; then
    local pw_out
    pw_out=$(powershell.exe -NoProfile -Command "
\$p = Get-CimInstance Win32_Process -Filter \"ProcessId = $pid\"
if (\$p) {
  Write-Host \$p.Name
  Write-Host \$p.CommandLine
}
" 2>/dev/null)
    if [ -n "$pw_out" ]; then
      printf '%s\n' "$pw_out"
      return 0
    fi
  fi
  return 1
}

_fm_process_ppid() {  # <pid> -> outputs ppid
  local pid=$1 ppid
  if ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' '); then
    [ -n "$ppid" ] && { printf '%s\n' "$ppid"; return 0; }
  fi
  if [ -r "/proc/$pid/stat" ]; then
    ppid=$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null)
    [ -n "$ppid" ] && { printf '%s\n' "$ppid"; return 0; }
  fi
  return 1
}

# reported and the callers below decide what they need from it.
fm_harness_ancestry_pids() {
  local pid=$$ comm args extending=0 printed=0 comm_args
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm_args=$(_fm_process_comm_args "$pid") || break
    comm=$(printf '%s\n' "$comm_args" | head -n 1)
    args=$(printf '%s\n' "$comm_args" | tail -n +2)
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(_fm_process_ppid "$pid") || break
    # Examine the top of the chain before stopping. Inside a PID namespace the
    # harness itself is pid 1, so stopping as soon as the next pid is 1 hides the
    # very process this walk exists to find. A host's real pid 1 (init, systemd,
    # launchd) is not harness-shaped, so fm_harness_process_matches rejects it.
    case "$pid" in '' | *[!0-9]*) break ;; esac
    [ "$pid" -ge 1 ] || break
  done
  if [ "$printed" -eq 0 ] && ([ -n "${PI_SESSION_FILE:-}" ] || [ -n "${PI_SESSION_ID:-}" ]); then
    local m marker_pid
    for m in "${FM_STATE_OVERRIDE:-${FM_HOME:-$FM_ROOT}/state}/.pi-watch-extension-loaded" "${FM_STATE_OVERRIDE:-${FM_HOME:-$FM_ROOT}/state}/.pi-turnend-extension-loaded"; do
      if [ -f "$m" ]; then
        marker_pid=$(sed -n '2p' "$m" 2>/dev/null)
        if [ -n "$marker_pid" ] && fm_harness_pid_alive "$marker_pid"; then
          printf '%s\n' "$marker_pid"
          printed=1
          break
        fi
      fi
    done
  fi
  if [ "$printed" -eq 0 ] && [ -r "/proc/$$/winpid" ] && command -v powershell.exe >/dev/null 2>&1; then
    # MSYS/Git Bash: the POSIX ancestry ends at the first Windows-native parent
    # (pid 1), and the Windows process behind $$ can be a transient exec stub
    # whose parent chain no longer reaches the harness. Start the Windows walk
    # from every MSYS ancestor's winpid, innermost first, and accept the first
    # chain that contains a verified harness.
    local start_winpids='' mp=$$ w row chain_pid chain_name chain_cmd
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
      [ -r "/proc/$mp/winpid" ] || break
      w=$(cat "/proc/$mp/winpid" 2>/dev/null)
      case "$w" in '' | *[!0-9]*) ;; *) start_winpids="$start_winpids $w" ;; esac
      mp=$(awk '{print $4}' "/proc/$mp/stat" 2>/dev/null)
      case "$mp" in '' | *[!0-9]* | 0 | 1) break ;; esac
    done
    if [ -n "$start_winpids" ]; then
      local win_rows
      win_rows=$(FM_START_WINPIDS="$start_winpids" powershell.exe -NoProfile -NonInteractive -Command '
$byId = @{}
foreach ($p in Get-CimInstance Win32_Process) { $byId[[int]$p.ProcessId] = $p }
foreach ($s in ($env:FM_START_WINPIDS -split "\s+")) {
  if (-not $s) { continue }
  $cur = [int]$s; $seen = @{}
  for ($i = 0; $i -lt 32 -and $cur -gt 0 -and -not $seen.ContainsKey($cur); $i++) {
    $seen[$cur] = 1
    $p = $byId[$cur]
    if (-not $p) { break }
    $cmd = [string]$p.CommandLine -replace "[\t\r\n]", " "
    Write-Output ("ROW`t{0}`t{1}`t{2}" -f $p.ProcessId, $p.Name, $cmd)
    $cur = [int]$p.ParentProcessId
  }
  Write-Output "END"
}' 2>/dev/null | tr -d '\r')
      extending=0
      while IFS= read -r row; do
        if [ "$row" = "END" ]; then
          [ "$printed" -eq 1 ] && break
          extending=0
          continue
        fi
        [ "${row%%$'\t'*}" = "ROW" ] || continue
        row=${row#ROW$'\t'}
        chain_pid=${row%%$'\t'*}; row=${row#*$'\t'}
        chain_name=${row%%$'\t'*}; chain_cmd=${row#*$'\t'}
        if fm_harness_process_matches "$chain_name" "$chain_cmd"; then
          printf '%s\n' "$chain_pid"
          printed=1
          [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] && { extending=1; continue; }
          break
        elif [ "$extending" -eq 1 ]; then
          break
        fi
      done <<EOF
$win_rows
EOF
    fi
  fi
  if [ "$printed" -eq 0 ] && ([ -n "${PI_SESSION_FILE:-}" ] || [ -n "${PI_SESSION_ID:-}" ]); then
    local want_id="${PI_SESSION_ID:-}"
    for p in /proc/[0-9]*; do
      local check_pid=${p#/proc/}
      local check_cmd
      check_cmd=$(cat "$p/cmdline" 2>/dev/null | tr '\0' ' ')
      if [[ "$check_cmd" == *"pi-coding-agent"* ]]; then
        local ret_pid=$check_pid
        if [ -r "$p/winpid" ]; then
          ret_pid=$(cat "$p/winpid" 2>/dev/null)
        fi
        if [ -z "$want_id" ] || [[ "$check_cmd" == *"$want_id"* ]] || fm_harness_pid_alive "$ret_pid"; then
          printf '%s\n' "$ret_pid"
          printed=1
          break
        fi
      fi
    done
  fi
  [ "$printed" -eq 1 ]
}

# Print the outermost pid of this session's contiguous harness run for callers
# that need that ancestry identity. This is not necessarily the pid written to
# the session lock: fm_session_lock_anchor_pid owns that choice and uses a
# trusted Claude session's model-loop pid instead. Every non-Claude harness
# reports a single pid, so this remains its innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids
  pids=$(fm_harness_ancestry_pids) || return 1
  _fm_harness_outermost_pid "$pids"
}

# Print the last (outermost) pid of ancestry list $1, or return 1 when empty.
_fm_harness_outermost_pid() {  # <ancestry-pids>
  local pid outermost=''
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$1
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args comm_args
  { kill -0 "$pid" 2>/dev/null || { [ -x /bin/kill ] && /bin/kill -W -0 "$pid" 2>/dev/null; } || _fm_winpid_alive "$pid"; } || return 1
  comm_args=$(_fm_process_comm_args "$pid") || return 1
  comm=$(printf '%s\n' "$comm_args" | head -n 1)
  args=$(printf '%s\n' "$comm_args" | tail -n +2)
  fm_harness_process_matches "$comm" "$args"
}

# --- trusted same-session identity -------------------------------------------
# Claude Code hands every hook and tool shell CLAUDE_CODE_SESSION_ID (the
# session's conversation id) and CLAUDE_PID (the pid of the process running the
# model loop). A background session runs that model loop in a transient helper
# bridged to its front-end by a shared daemon, and when that bridge is recycled
# the contiguous claude-named ancestry from a hook to the recorded lock owner
# breaks while the owner pid stays alive, so ancestry alone reads the session's
# own lock as another live session's. The id is the one identity that survives
# the recycling, so it is accepted as a second ownership signal - but only from
# an environment proven to belong to the current Claude run.
#
# Trust gate: CLAUDE_PID must be a Claude-shaped member of this process's
# contiguous harness ancestry. An id merely retained in a helper environment
# fails that membership and is ignored: a hand-started Pi or codex primary under
# a Claude pane still carries the pane's CLAUDE_CODE_SESSION_ID and CLAUDE_PID,
# and must never own a lock with them. Ids are read from the environment only,
# never from ps argv, where prompts and briefs are visible.
#
# A --fork-session successor mints a new id, so it stays a foreign live owner
# until the pre-fork process exits; that is the safe direction and a documented
# non-goal. Two genuinely different live sessions sharing one id is not a
# supported state (Claude refuses to resume a running session under its id).

# Print the Claude session id this process may own with, or return 1. $1 is the
# ancestry list an earlier walk already produced, so a caller that walked once
# need not walk again.
fm_session_lock_trusted_session_id() {  # [<ancestry-pids>]
  local id=${CLAUDE_CODE_SESSION_ID:-} claude_pid=${CLAUDE_PID:-} pids=${1:-} pid comm args
  [ -n "$id" ] || return 1
  case "$id" in *$'\n'*|*$'\r'*) return 1 ;; esac
  case "$claude_pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -z "$pids" ]; then
    pids=$(fm_harness_ancestry_pids) || return 1
  fi
  while IFS= read -r pid; do
    [ "$pid" = "$claude_pid" ] || continue
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    fm_harness_process_matches "$comm" "$args" || return 1
    [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || return 1
    printf '%s\n' "$id"
    return 0
  done <<EOF
$pids
EOF
  return 1
}

# Print the session id recorded beside the lock in state dir $1, or return 1.
# bin/fm-lock.sh is the only writer of state/.lock-session; a missing,
# symlinked, unreadable, or empty sidecar, or one whose first line contains a
# newline or carriage return, is simply no recorded id.
fm_session_lock_recorded_session_id() {  # <state>
  local state=$1 recorded
  [ -f "$state/.lock-session" ] && [ ! -L "$state/.lock-session" ] || return 1
  recorded=$(head -n 1 "$state/.lock-session" 2>/dev/null) || return 1
  [ -n "$recorded" ] || return 1
  case "$recorded" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf '%s\n' "$recorded"
}

# True when the lock in state dir $1 was recorded by this same Claude session:
# the trusted id equals the id recorded beside the lock. No trusted id, no
# sidecar, or a different recorded id is false.
fm_session_lock_same_session() {  # <state> [<ancestry-pids>]
  local state=$1 trusted recorded
  trusted=$(fm_session_lock_trusted_session_id "${2:-}") || return 1
  recorded=$(fm_session_lock_recorded_session_id "$state") || return 1
  [ "$recorded" = "$trusted" ]
}

# Print the pid bin/fm-lock.sh records on lock line 1 for this session. For a
# Claude session with a trusted id that is CLAUDE_PID, the model-loop process:
# never the shared transient daemon and never a front-end that outlives the
# session, so "recorded pid dead" keeps meaning "session gone" instead of
# wedging a home behind a live daemon whose session died. A replaced background
# helper leaves a dead pid that its own session's next hook reclaims, because
# the sidecar still names that session. Every other session records the
# outermost pid of its contiguous run, exactly as before.
fm_session_lock_anchor_pid() {
  local pids
  pids=$(fm_harness_ancestry_pids) || return 1
  if fm_session_lock_trusted_session_id "$pids" >/dev/null; then
    printf '%s\n' "$CLAUDE_PID"
    return 0
  fi
  _fm_harness_outermost_pid "$pids"
}

# True when state dir $1 holds a session lock that this process's session owns:
# the recorded pid is ANY harness ancestor of the current process, or the lock
# was recorded by this same trusted Claude session and its recorded pid is still
# a live harness. Membership is the honest ancestry test, because the lock owner
# sits at an unknown depth in a contiguous Claude run - it is the outermost pid
# when the hook fires inside the session's own nested worker chain, and an inner
# pid when a harness-named daemon parents the session. The same-session path
# requires the recorded pid alive so that a dead one is reclaimed through
# bin/fm-lock.sh's ordinary stale-owner path, which refreshes line 1, rather than
# silently owned with a dead anchor. A missing lock, a malformed lock, a lock
# held by a harness outside this ancestry under another (or no) session id, or
# an ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  fm_session_lock_same_session "$state" "$pids" || return 1
  fm_harness_pid_alive "$lock_pid"
}

# True when state dir $1 records a live verified harness outside this process's
# contiguous harness ancestry that was not recorded by this same trusted Claude
# session. Sets FM_SESSION_LOCK_FOREIGN_OWNER_PID for a diagnostic caller.
# Malformed, missing, dead, and ancestry-uncertain locks are not foreign-owner
# evidence.
# shellcheck disable=SC2034 # Output global, read by the sourcing guard caller.
FM_SESSION_LOCK_FOREIGN_OWNER_PID=
fm_session_lock_foreign_owner_live() {
  local state=$1 lock_pid pids pid
  FM_SESSION_LOCK_FOREIGN_OWNER_PID=
  [ -f "$state/.lock" ] && [ ! -L "$state/.lock" ] || return 1
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_harness_pid_alive "$lock_pid" || return 1
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 1
  done <<EOF
$pids
EOF
  fm_session_lock_same_session "$state" "$pids" && return 1
  # shellcheck disable=SC2034 # Output global, read by the sourcing guard caller.
  FM_SESSION_LOCK_FOREIGN_OWNER_PID=$lock_pid
  return 0
}

# Read-only classification of state/.lock for machine-readable callers.
# Never acquires the lock. A held lock is not proof the holder is consuming
# wakes; that question belongs to the inbox readiness projection.
#
# Sets:
#   FM_LOCK_INSPECT_STATE         free|held|stale|unreadable|unknown
#   FM_LOCK_INSPECT_PID           recorded pid, or empty
#   FM_LOCK_INSPECT_LIVE_HARNESS  true|false|unknown
#
# held: the recorded pid is a live verified harness.
# stale: the recorded pid is gone.
# unknown: the file or pid cannot be classified without guessing, including a
# live process that is not a verified harness. Existence of a lock file, a
# session record, or a pane is never treated as liveness.
# shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
FM_LOCK_INSPECT_STATE=unknown
FM_LOCK_INSPECT_PID=
FM_LOCK_INSPECT_LIVE_HARNESS=unknown
fm_session_lock_inspect() {  # <state>
  local state=$1 lock pid
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_STATE=unknown
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_PID=
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_LIVE_HARNESS=unknown
  lock="$state/.lock"
  if [ ! -e "$lock" ]; then
    FM_LOCK_INSPECT_STATE=free
    FM_LOCK_INSPECT_LIVE_HARNESS=false
    return 0
  fi
  if [ ! -f "$lock" ] || [ -L "$lock" ]; then
    FM_LOCK_INSPECT_STATE=unreadable
    return 0
  fi
  pid=$(cat "$lock" 2>/dev/null) || {
    FM_LOCK_INSPECT_STATE=unreadable
    return 0
  }
  pid=${pid%%$'\n'*}
  # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
  FM_LOCK_INSPECT_PID=$pid
  case "$pid" in
    ''|*[!0-9]*)
      FM_LOCK_INSPECT_STATE=unknown
      return 0
      ;;
  esac
  if kill -0 "$pid" 2>/dev/null || { [ -x /bin/kill ] && /bin/kill -W -0 "$pid" 2>/dev/null; } || _fm_winpid_alive "$pid"; then
    if fm_harness_pid_alive "$pid"; then
      FM_LOCK_INSPECT_STATE=held
      FM_LOCK_INSPECT_LIVE_HARNESS=true
    else
      FM_LOCK_INSPECT_STATE=unknown
      FM_LOCK_INSPECT_LIVE_HARNESS=false
    fi
    return 0
  fi
  if ps -o comm= -p "$pid" >/dev/null 2>&1; then
    FM_LOCK_INSPECT_STATE=unknown
    return 0
  fi
  # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
  FM_LOCK_INSPECT_STATE=stale
  # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
  FM_LOCK_INSPECT_LIVE_HARNESS=false
}
