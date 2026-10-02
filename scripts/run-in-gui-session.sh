#!/bin/bash
# scripts/run-in-gui-session.sh: run ONE command inside this Mac's logged-in desktop (Aqua) session and
# return its exit status. PRD-1-01 plan § 15.15 R4-2, derived from the 2026-10-02 signing probe (c).
#
# Why: from ssh, codesign cannot use the login keychain (errSecInternalComponent; `security
# show-keychain-info` says "User interaction is not allowed"). Inside the desktop session it can, with no
# password and no dialog.
#
# usage: run-in-gui-session.sh [--timeout SECONDS] [--tail LINES] -- COMMAND [ARG...]
#   COMMAND runs once, as a launchd job in gui/<uid>: plist in /tmp only (never ~/Library/LaunchAgents),
#   LimitLoadToSessionType Aqua, RunAtLoad true, KeepAlive false, ProcessType Interactive, stdin /dev/null,
#   hard-bounded by a perl alarm (default 1800 s). cwd = the caller's cwd, HOME = the caller's HOME,
#   PATH = /usr/bin:/bin:/usr/sbin:/sbin. Use absolute paths; pass variables as -- /usr/bin/env K=V COMMAND.
#   COMMAND's stdout+stderr go to /tmp/<label>.out (kept, mode 600); its last LINES (default 40) are printed.
# exit: COMMAND's own status, or 64 usage | 69 no desktop session (run attended) | 70 job not started |
#   124 no result by the deadline (alarm + 30 s) | 142 the alarm fired.
#   124 and 142 are INCONCLUSIVE: rerun attended. A hidden dialog (e.g. a locked keychain asking for its
#   password) looks exactly like this.
# Not for apps that need TCC (HomeKit): the job's /bin/bash becomes their responsible process and TCC
# hard-denies it. Launch apps with /usr/bin/open (LaunchServices); this script may run that open.
# bash 3.2 + BSD userland only: no `timeout`, no GNU flags.
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
TIMEOUT=1800; TAIL=40; GRACE=30
usage() { echo "usage: run-in-gui-session.sh [--timeout SECONDS] [--tail LINES] -- COMMAND [ARG...]" >&2; exit 64; }
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) [ $# -ge 2 ] || usage; TIMEOUT=$2; shift 2 ;;
    --tail)    [ $# -ge 2 ] || usage; TAIL=$2; shift 2 ;;
    --)        shift; break ;;
    *)         usage ;;
  esac
done
[ $# -ge 1 ] || usage
for n in "$TIMEOUT" "$TAIL"; do case "$n" in ''|*[!0-9]*) usage ;; esac; done
[ "$TIMEOUT" -ge 1 ] || usage
: "${HOME:?HOME must be set}"

U=$(id -u)
if ! launchctl print "gui/$U" >/dev/null 2>&1; then
  echo "run-in-gui-session: no logged-in desktop session for uid $U (gui/$U missing): run the command attended, in Terminal on this Mac" >&2
  exit 69
fi

L="ai.agentforge.prefab-oneshot.$(date +%Y%m%d%H%M%S).$$"
P="/tmp/$L.plist"; OUT="/tmp/$L.out"; DONE="/tmp/$L.done"; JLOG="/tmp/$L.launchd.log"
BUILD_RE='xcodebuild|swift-frontend|swift-driver|XCBBuildService|SWBBuildService'
BEFORE=" $(pgrep -U "$U" -f "$BUILD_RE" | tr '\n' ' ') "
BOOTED=0
cleanup() {
  [ "$BOOTED" = 1 ] && launchctl bootout "gui/$U/$L" >/dev/null 2>&1
  rm -f "$P" "$DONE" "$DONE.tmp" "$JLOG"
}
trap cleanup EXIT
trap 'exit 129' HUP; trap 'exit 141' PIPE
trap 'echo "run-in-gui-session: interrupted, stopping the job" >&2; exit 130' INT
trap 'echo "run-in-gui-session: terminated, stopping the job" >&2; exit 143' TERM

# The job: bash writes the done marker (exit=<status>) atomically and exits with the same status,
# so `launchctl print` reports it too. exec {…} never goes through a shell; a failed exec exits 127.
IFS= read -r -d '' INNER <<'EOS' || true
umask 077
out=$1; mark=$2; secs=$3; shift 3
/usr/bin/perl -e '$s = shift @ARGV; alarm $s; exec { $ARGV[0] } @ARGV; print STDERR "run-in-gui-session: cannot exec $ARGV[0]: $!\n"; exit 127' "$secs" "$@" >"$out" 2>&1 </dev/null
rc=$?
echo "exit=$rc" >"$mark.tmp" && /bin/mv -f "$mark.tmp" "$mark"
exit $rc
EOS

mkplist() {
  plutil -create xml1 "$P" &&
  plutil -insert Label -string "$L" "$P" &&
  plutil -insert ProgramArguments -array "$P" || return 1
  for a in /bin/bash -c "$INNER" run-in-gui-session "$OUT" "$DONE" "$TIMEOUT" "$@"; do
    plutil -insert ProgramArguments -string "$a" -append "$P" || return 1
  done
  plutil -insert LimitLoadToSessionType -string Aqua "$P" &&
  plutil -insert RunAtLoad -bool true "$P" &&
  plutil -insert KeepAlive -bool false "$P" &&
  plutil -insert ProcessType -string Interactive "$P" &&
  plutil -insert WorkingDirectory -string "$PWD" "$P" &&
  plutil -insert EnvironmentVariables -dictionary "$P" &&
  plutil -insert EnvironmentVariables.HOME -string "$HOME" "$P" &&
  plutil -insert EnvironmentVariables.PATH -string "/usr/bin:/bin:/usr/sbin:/sbin" "$P" &&
  plutil -insert StandardInPath -string /dev/null "$P" &&
  plutil -insert StandardOutPath -string "$JLOG" "$P" &&
  plutil -insert StandardErrorPath -string "$JLOG" "$P" &&
  plutil -lint "$P" >/dev/null
}
( umask 077; mkplist "$@" ) || { echo "run-in-gui-session: could not write $P" >&2; exit 70; }

echo "run-in-gui-session: $L - timeout ${TIMEOUT}s - $*"
launchctl bootstrap "gui/$U" "$P" || { echo "run-in-gui-session: launchctl bootstrap gui/$U failed" >&2; exit 70; }
BOOTED=1
START=$(date +%s); DEADLINE=$((START + TIMEOUT + GRACE)); BEAT=$((START + 60))
while [ ! -f "$DONE" ]; do
  NOW=$(date +%s)
  [ "$NOW" -ge "$DEADLINE" ] && break
  if [ "$NOW" -ge "$BEAT" ]; then
    echo "  ... $((NOW - START))s: $(tail -n 1 "$OUT" 2>/dev/null | cut -c1-150)"; BEAT=$((NOW + 60))
  fi
  sleep 2
done

if [ -f "$DONE" ]; then
  RC=$(tr -dc '0-9' < "$DONE"); [ -n "$RC" ] || RC=70
  for i in 1 2 3 4 5; do launchctl print "gui/$U/$L" 2>/dev/null | grep -q 'state = running' || break; sleep 1; done
  STATE=$(launchctl print "gui/$U/$L" 2>/dev/null | grep -E '^[[:space:]](state|runs|last exit code) = ' | tr -s ' \t' ' ' | tr '\n' ';')
else
  RC=124; STATE="no done marker after $((TIMEOUT + GRACE))s"
fi

if [ "$RC" = 124 ] || [ "$RC" = 142 ]; then
  launchctl bootout "gui/$U/$L" >/dev/null 2>&1; BOOTED=0   # stops the job; launchd kills its process group
  sleep 2
  for SIG in TERM KILL; do
    for pid in $(pgrep -U "$U" -f "$BUILD_RE"); do
      [ "$pid" = "$$" ] && continue
      case "$BEFORE" in *" $pid "*) continue ;; esac
      echo "run-in-gui-session: kill -$SIG leftover $pid: $(ps -o command= -p "$pid" | cut -c1-120)" >&2
      kill "-$SIG" "$pid" 2>/dev/null
    done
    [ "$SIG" = TERM ] && sleep 3
  done
fi

if [ "$TAIL" -gt 0 ] && [ -f "$OUT" ]; then
  echo "--- last $TAIL lines of $OUT"; tail -n "$TAIL" "$OUT"; echo "---"
fi
[ -s "$JLOG" ] && { echo "--- launchd log of the job wrapper"; cat "$JLOG"; }
echo "run-in-gui-session: exit=$RC - $STATE - output kept: $OUT"
if [ "$RC" = 124 ] || [ "$RC" = 142 ]; then
  echo "run-in-gui-session: TIMED OUT after ${TIMEOUT}s: INCONCLUSIVE, rerun attended (a dialog on the desktop, e.g. a locked keychain, looks like this)" >&2
fi
exit "$RC"
