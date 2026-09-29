#!/usr/bin/env bash
# vmctl.sh — the only thing in this plugin that talks to the VM.
#
#   vmctl.sh <verb> <host> <user> <port> <key> [arg]
#
# Every call rides one multiplexed SSH connection (ControlMaster), so polling
# every few seconds costs a round trip, not a handshake. The collector is
# streamed over stdin; nothing is installed on the VM.
#
# Hermes guard: any verb that changes state refuses targets matching "hermes".
set -uo pipefail

verb=${1:?verb}; host=${2:?host}; user=${3:?user}; port=${4:-22}; key=${5:-}
arg=${6:-}
here=$(cd "$(dirname "$0")" && pwd)
cache="${XDG_CACHE_HOME:-$HOME/.cache}/omavm"
# Our own private dir. Refuse a symlink here rather than follow it.
[ -L "$cache" ] && { echo "refused: $cache is a symlink" >&2; exit 2; }
mkdir -p -- "$cache" && chmod 700 -- "$cache"

# Settings come from the widget config; refuse anything ssh could mistake for
# an option (a leading "-") or that isn't a plain hostname/IP, user or port.
[[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.:_-]*$ ]] || { echo "refused: bad host '$host'" >&2; exit 2; }
[[ "$user" =~ ^[A-Za-z_][A-Za-z0-9._-]*$ ]] || { echo "refused: bad user '$user'" >&2; exit 2; }
[[ "$port" =~ ^[0-9]{1,5}$ ]] && (( port >= 1 && port <= 65535 )) || { echo "refused: bad port '$port'" >&2; exit 2; }

key=${key/#\~/$HOME}
opts=(-p "$port" -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=15
      -o ServerAliveCountMax=2 -o StrictHostKeyChecking=accept-new
      -o ControlMaster=auto -o "ControlPath=$cache/cm-%C" -o ControlPersist=15m
      -o LogLevel=ERROR)
[[ -n "$key" ]] && opts+=(-i "$key" -o IdentitiesOnly=yes)
target="$user@$host"

valid() {
  [[ "$1" =~ ^[A-Za-z0-9@._:-]+$ ]] || { echo "refused: bad unit name '$1'" >&2; exit 2; }
}

guard() {
  valid "$1"
  if [[ "${1,,}" == *hermes* ]]; then
    echo "refused: '$1' belongs to the Hermes agent and is protected" >&2
    exit 3
  fi
}

terminal() {
  local title=$1; shift
  exec setsid uwsm-app -- xdg-terminal-exec --app-id=org.omarchy.omavm --title="$title" -- "$@"
}

case "$verb" in
  fast|slow|pkg)
    # stderr goes to a fresh mktemp file (exclusive create, random name),
    # removed on exit, never to a fixed path that a symlink could redirect.
    errf=$(mktemp -- "$cache/err.XXXXXX") || exit 1
    trap 'rm -f -- "$errf"' EXIT
    # Everything the VM sends is bounded while it arrives: stderr keeps only its
    # first 4 KiB on disk and the rest is drained to /dev/null (so ssh never
    # blocks or dies on a full pipe), stdout is capped at 8 MiB. pipefail keeps
    # ssh's exit status.
    exec 4> >(head -c 4096 > "$errf"; cat > /dev/null)
    errpid=$!
    t0=$(date +%s%N)
    out=$(ssh "${opts[@]}" "$target" "nice -n 10 python3 - $verb" < "$here/collector.py" 2>&4 | head -c 8388608)
    rc=$?
    exec 4>&-
    wait "$errpid" 2>/dev/null
    t1=$(date +%s%N)
    printf '%s\n' "$(( (t1 - t0) / 1000000 ))"
    if (( rc != 0 )); then
      printf '{"error":%s}\n' "$(head -c 4096 -- "$errf" | tr '\n' ' ' | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip() or "ssh exited '"$rc"'"))')"
      exit "$rc"
    fi
    printf '%s\n' "$out"
    ;;
  shell)    terminal "VM · $host" ssh "${opts[@]}" -t "$target" ;;
  top)      terminal "VM top · $host" ssh "${opts[@]}" -t "$target" "top -d 2" ;;
  journal)  terminal "VM journal · $host" ssh "${opts[@]}" -t "$target" "sudo journalctl -f -n 80" ;;
  unitlog)  valid "$arg"  # tailing a log is read-only, so no Hermes guard needed
            terminal "VM log · $arg" ssh "${opts[@]}" -t "$target" "sudo journalctl -f -n 120 -u $arg" ;;
  hermeslog)
            # Read-only tail of the Hermes gateway's user journal. No signals, no restarts.
            terminal "Hermes log (read-only)" ssh "${opts[@]}" -t "$target" "journalctl --user -f -n 120 -u hermes-gateway" ;;
  sshlog)   terminal "VM sshd · $host" ssh "${opts[@]}" -t "$target" "sudo journalctl -f -n 120 -u sshd" ;;
  upgrade)  terminal "VM upgrade · $host" ssh "${opts[@]}" -t "$target" \
              "sudo dnf upgrade --refresh; echo; read -rp 'Done — press Enter to close '" ;;
  makecache)
    ssh "${opts[@]}" "$target" "sudo -n dnf -q makecache" ;;
  restart)
    guard "$arg"
    ssh "${opts[@]}" "$target" "sudo -n systemctl restart -- '$arg' && systemctl is-active -- '$arg'" ;;
  reboot)
    ssh "${opts[@]}" "$target" "sudo -n systemctl reboot" ; exit 0 ;;
  disconnect)
    ssh "${opts[@]}" -O exit "$target" 2>/dev/null; exit 0 ;;
  *) echo "unknown verb $verb" >&2; exit 2 ;;
esac
