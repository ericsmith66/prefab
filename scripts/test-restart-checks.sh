#!/bin/bash
# scripts/test-restart-checks.sh — PT-165 (PRD-1-01 plan § 15.18 R7-12, § 15.19 R8-9): the restart-check functions of
# docs/RUNBOOK-nextgen.md § 18.1 (plan R8-4's preamble), tested against fixture logs with every outside command stubbed.
#
# m3ultra only — NEVER on .253. Binding stub rule (plan R8-2): no process is started (pgrep is a stub that prints canned
# pids), nothing is named `Prefab` (the counted name is the neutral `prefabstub`), nothing is created under a `.app`
# folder, no open / LaunchServices / lsregister. curl, codesign, shasum, git, launchctl, date, sleep, bin/rails and the
# read-only `ro` psql wrapper are stubs; HOME points into a scratch directory, so the preamble's paths are fixtures.
# Usage: scripts/test-restart-checks.sh      exit 0 = every case as expected; 1 = a case failed; 2 = setup failed.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
RUNBOOK="$ROOT/docs/RUNBOOK-nextgen.md"
T=$(mktemp -d "${TMPDIR:-/tmp}/restart-checks.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
PRE="$T/preamble.sh"
awk '/^# R8-16 preamble/{f=1} f&&/^```$/{exit} f' "$RUNBOOK" > "$PRE"
[ -s "$PRE" ] || { echo "STOP: the § 18.1 preamble was not found in $RUNBOOK"; exit 2; }
bash -n "$PRE" || { echo "STOP: the preamble does not parse"; exit 2; }
echo "preamble: $(wc -l < "$PRE" | tr -d ' ') lines, md5 $(md5 -q "$PRE"), bash -n ok"

H="$T/home"; EUREKA="$H/Development/legion/projects/eureka-homekit"; S="$T/stubs"
mkdir -p "$S" "$H/Documents" "$EUREKA/bin" "$EUREKA/log"
NOW=2000000000

# --- stubs -----------------------------------------------------------------------------------------------------------
cat > "$S/date" <<'EOF'
#!/bin/bash
case "${1:-}" in +%s) echo "${STUB_NOW}" ;; +%H) echo "${STUB_HOUR:-14}" ;; *) exec /bin/date "$@" ;; esac
EOF
cat > "$S/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$S/pgrep" <<'EOF'
#!/bin/bash
mode=""
for a in "$@"; do case "$a" in -f) mode=f ;; -x) mode=x ;; -fl) mode=fl ;; -lx) mode=lx ;; esac; done
case "$mode" in f|fl) n=${STUB_PATH_COUNT:-1} ;; x|lx) n=${STUB_NAME_COUNT:-1} ;; *) n=0 ;; esac
i=0
while [ "$i" -lt "$n" ]; do i=$((i + 1)); case "$mode" in fl|lx) echo "$((1000 + i)) ${PNAME:-stub}" ;; *) echo "$((1000 + i))" ;; esac; done
[ "$n" -gt 0 ]
EOF
cat > "$S/curl" <<'EOF'
#!/bin/bash
url=""; fmt=""; out=""; close=0; http10=0
while [ $# -gt 0 ]; do
  case "$1" in
    -w) fmt=$2; shift 2 ;;
    -o) out=$2; shift 2 ;;
    -H) case "$2" in [Cc]onnection:*[Cc]lose*) close=1 ;; esac; shift 2 ;;
    -m) shift 2 ;;
    -0) http10=1; shift ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
pat='%{http_code}'
if [ "${STUB_F1:-fixed}" = sprime ] && { [ "$close" = 1 ] || [ "$http10" = 1 ]; }; then
  [ -n "$fmt" ] && printf '%b' "${fmt//"$pat"/000}"
  exit 52
fi
code=200
case "$url" in
  */version) body=$(printf '{"git_sha": "%s", "bind": "127.0.0.1:8080", "bonjour": false}' "${STUB_SHA:-}") ;;
  */accessories/Waverly) body=$(cat "${STUB_ACCESSORIES:-/dev/null}") ;;
  *) code=404; body='{"error":"not_found"}' ;;
esac
[ "$out" = /dev/null ] || printf '%s' "$body"
[ -n "$fmt" ] && printf '%b' "${fmt//"$pat"/$code}"
exit 0
EOF
cat > "$S/codesign" <<'EOF'
#!/bin/bash
printf 'Executable=/fixture\nIdentifier=com.ericsmith66.prefab\nCDHash=%s\n' "${STUB_CDHASH:-}" >&2
EOF
cat > "$S/shasum" <<'EOF'
#!/bin/bash
echo "${STUB_SHA256:-}  ${3:-}"
EOF
cat > "$S/git" <<'EOF'
#!/bin/bash
[ "${1:-}" = rev-parse ] && [ "${2:-}" = HEAD ] && { echo "${STUB_HEAD:-}"; exit 0; }
exit 1
EOF
cat > "$S/launchctl" <<'EOF'
#!/bin/bash
[ "${1:-}" = print ] && printf 'gui/501/com.ericsmith66.eureka = {\n\tactive count = 1\n\tpid = %s\n\tstate = running\n}\n' "${STUB_PUMA_PID:-}"
EOF
cat > "$EUREKA/bin/rails" <<'EOF'
#!/bin/bash
echo "${STUB_RESPONDS:-false}"
EOF
chmod 755 "$S"/* "$EUREKA/bin/rails"

# --- harness ---------------------------------------------------------------------------------------------------------
# The read-only psql wrapper `ro` runs an absolute path, so it is replaced by this function after the preamble is
# sourced (defined here, outside any $( ), because bash 3.2 cannot parse a `case` inside a command substitution).
ro_stub() {
  case "$*" in
    *"25 hours"*) echo "${STUB_EVY:-0}" ;;
    *"60 minutes"*) echo "${STUB_EV60:-0}" ;;
    *"10 minutes"*) echo "${STUB_EV10:-0}" ;;
    *"max(created_at)"*) echo "${STUB_AGE:-5}" ;;
    *) echo 0 ;;
  esac
}
PASSN=0; FAILN=0
# check <name> <expected rc> <expected substring> <shell code run after the preamble is sourced>
check() {
  local name=$1 erc=$2 esub=$3 code=$4 out rc
  out=$( ( export HOME="$H" PNAME=prefabstub STUB_NOW="${STUB_NOW:-$NOW}"
           cd "$T" && . "$PRE" >/dev/null 2>&1
           PATH="$S:$PATH"; export PATH
           ro() { ro_stub "$@"; }
           eval "$code" ) 2>&1 ); rc=$?
  if [ "$rc" = "$erc" ] && printf '%s\n' "$out" | grep -qF -- "$esub"; then
    PASSN=$((PASSN + 1)); echo "ok   $name"
  else
    FAILN=$((FAILN + 1)); echo "FAIL $name — rc=$rc (want $erc), want output containing: $esub"
    printf '%s\n' "$out" | sed 's/^/     | /'
  fi
}
DLOG="$H/Documents/homebase_debug.log"
TS='[2026-10-08T20:00:00Z]'
mklog() { : > "$DLOG"; local n=$1 i=0; shift; while [ "$i" -lt "$n" ]; do echo "$TS [NATIVE] Lamp - Power State: Optional(1)" >> "$DLOG"; i=$((i + 1)); done; for l in "$@"; do echo "$l" >> "$DLOG"; done; }
OFF="$TS Polling: mode=failed-only enabled=false subscriptions=812 ok=812 failed=0 pending=0 excluded=0 polled=0 bridges=0 limit=6/min/bridge"
ON="$TS Polling: mode=failed-only enabled=true subscriptions=812 ok=809 failed=3 pending=0 excluded=1 polled=2 bridges=1 limit=6/min/bridge"

echo "--- s2_rate_check (PC-1's six rows, the log restart, WAIT)"
rate() { mklog "$1"; export STUB_EV60=$2 STUB_EVY=$3 S2_HOUR=$4; }
rate 580 600 600 14; check "rate 580/600 yday 600 @14 → PASS"   0 "PASS rate (both >= 300)" 's2_rate_check $((STUB_NOW - 3600)) 0'
rate 0 0 0 04;       check "rate 0/0 yday 0 @04 → FAIL"         1 "FAIL rate"               's2_rate_check $((STUB_NOW - 3600)) 0'
rate 200 200 350 14; check "rate 200/200 yday 350 @14 → FAIL"   1 "FAIL rate (08:00-22:00"  's2_rate_check $((STUB_NOW - 3600)) 0'
rate 150 150 300 04; check "rate 150/150 yday 300 @04 → PASS"   0 "PASS rate (night rule"   's2_rate_check $((STUB_NOW - 3600)) 0'
rate 250 250 300 04; check "rate 250/250 yday 300 @04 → PASS"   0 "PASS rate (night rule"   's2_rate_check $((STUB_NOW - 3600)) 0'
rate 100 100 150 04; check "rate 100/100 yday 150 @04 → FAIL"   1 "FAIL rate"               's2_rate_check $((STUB_NOW - 3600)) 0'
rate 580 600 600 14; check "the log restarted after the mark → FAIL" 1 "the debug log restarted after the mark" 's2_rate_check $((STUB_NOW - 3600)) 900'
rate 580 600 600 14; check "10 min after the mark → WAIT rc 2"  2 "WAIT: only 10 min"       's2_rate_check $((STUB_NOW - 600)) 0'
unset STUB_EV60 STUB_EVY S2_HOUR

echo "--- s2_polling_check (PC-2)"
mklog 3 "$OFF";                       check "good off line → PASS"                  0 "PASS polling line (enabled=false subscriptions=812" 's2_polling_check'
mklog 3 "$ON";                        check "good on line → PASS"                   0 "PASS polling line (enabled=true subscriptions=812 ok=809 failed=3 pending=0 polled=2)" 's2_polling_check'
mklog 3 "$OFF" "$OFF";                check "duplicate line → FAIL"                 1 "expected exactly one S″ polling line, found 2" 's2_polling_check'
mklog 3 "$OFF" "$TS Polling: 0 accessories, enabled: false"; check "mixed S′ line → FAIL" 1 "an S′ polling line is present" 's2_polling_check'
mklog 3 "$TS Polling: mode=failed-only enabled=true subscriptions=812 ok=809 failed=3 pending=0 excluded=0 polled=3 bridges=0 limit=6/min/bridge"
                                      check "bridges=0 with polled=3 → FAIL"        1 "bridges inconsistent with polled" 's2_polling_check'
mklog 3 "$TS Polling: mode=failed-only enabled=true subscriptions=812 ok=809 failed=3 pending=0 excluded=0 polled=3 bridges=9 limit=6/min/bridge"
                                      check "bridges=9 with polled=3 → FAIL"        1 "bridges inconsistent with polled" 's2_polling_check'
mklog 3 "$TS XPolling: mode=failed-only enabled=false subscriptions=812 ok=812 failed=0 pending=0 excluded=0 polled=0 bridges=0 limit=6/min/bridge"
                                      check "XPolling prefix → FAIL"               1 "the line does not match O27" 's2_polling_check'
mklog 3 "$TS Polling: mode=failed-only enabled=false subscriptions=812 ok=800 failed=0 pending=0 excluded=0 polled=0 bridges=0 limit=6/min/bridge"
                                      check "bad sum → FAIL"                        1 "ok+failed+pending != subscriptions" 's2_polling_check'
mklog 3 "$TS Polling: mode=failed-only enabled=false subscriptions=812 ok=809 failed=3 pending=0 excluded=0 polled=2 bridges=1 limit=6/min/bridge"
                                      check "polling off but polled → FAIL"         1 "polling off but polled/bridges not 0" 's2_polling_check'
mklog 3 "$OFF" "$TS Starting polling for 277 delegate accessories"; check "poll-all line → FAIL" 1 "the poll-all line is present" 's2_polling_check'
mklog 0;                              check "empty log → FAIL"                      1 "expected exactly one S″ polling line, found 0" 's2_polling_check'
mklog 3 "$TS Polling: mode=failed-only enabled=false subscriptions=760 ok=760 failed=0 pending=0 excluded=0 polled=0 bridges=0 limit=6/min/bridge"
                                      check "760 vs the reference 812 → rc 3"       3 "REPORT TO ERIC" 's2_polling_check 812'
mklog 3 "$OFF";                       check "812 vs the reference 812 → rc 0"       0 "PASS polling line" 's2_polling_check 812'

echo "--- prefab_start_check / s2_restart_check instance counts (PC-3, E-115)"
export STUB_SHA=b2ca6d35801107019489eb0d4d4d94018eee3af8
STUB_PATH_COUNT=1 STUB_NAME_COUNT=2 check "one at \$PP, two named prefabstub → STOP rc 1" 1 "STOP: 1 at the production path, 2 named prefabstub" 'prefab_start_check'
STUB_PATH_COUNT=1 STUB_NAME_COUNT=1 check "one and one → rc 0, /version 200"            0 "200" 'prefab_start_check'
STUB_PATH_COUNT=0 STUB_NAME_COUNT=0 check "none running → STOP rc 1"                     1 "STOP: 0 at the production path, 0 named prefabstub" 'prefab_start_check'

echo "--- s2_identity (E-107)"
export STUB_CDHASH=876f1e2f3b3c1dc098af276ed61dd0668927fbcb STUB_SHA256=7fd0c015becce5f4e050b9fd884ad511452d20b2f9083e700c189d0ab84fe3e4
check "an empty expected value → FAIL"    1 "FAIL identity: an expected value is empty" 's2_identity "" "" ""'
check "/version + CDHash + sha256 match → PASS" 0 "PASS identity" 's2_identity "$STUB_SHA" "$STUB_CDHASH" "$STUB_SHA256"'
check "a CDHash mismatch → FAIL"          1 "FAIL identity" 's2_identity "$STUB_SHA" 0000000000000000000000000000000000000000 "$STUB_SHA256"'
check "a git_sha mismatch → FAIL"         1 "FAIL identity" 's2_identity 1111111111111111111111111111111111111111 "$STUB_CDHASH" "$STUB_SHA256"'

echo "--- s2_restart_check (E-114, E-115)"
mklog 3 "$OFF"; STUB_PATH_COUNT=1 STUB_NAME_COUNT=1 check "all good → rc 0, rate mark printed" 0 "rate mark: $NOW 3" 's2_restart_check "$STUB_SHA" "$STUB_CDHASH" "$STUB_SHA256" ""'
mklog 3 "$TS Polling: mode=failed-only enabled=false subscriptions=760 ok=760 failed=0 pending=0 excluded=0 polled=0 bridges=0 limit=6/min/bridge"
STUB_PATH_COUNT=1 STUB_NAME_COUNT=1 check "760 vs reference 812 → REPORT TO ERIC, rc 0, continues to the mark" 0 "continued past REPORT TO ERIC" 's2_restart_check "$STUB_SHA" "$STUB_CDHASH" "$STUB_SHA256" 812 > "$T/rc.out"; r=$?; cat "$T/rc.out"; [ "$r" = 0 ] && grep -q "REPORT TO ERIC" "$T/rc.out" && grep -q "rate mark: $STUB_NOW 3" "$T/rc.out" && echo "continued past REPORT TO ERIC"'
mklog 3 "$OFF"; STUB_PATH_COUNT=1 STUB_NAME_COUNT=2 check "a second named process → FAIL" 1 "FAIL: not exactly one Prefab" 's2_restart_check "$STUB_SHA" "$STUB_CDHASH" "$STUB_SHA256" ""'
mklog 3 "$TS Polling: mode=failed-only enabled=false subscriptions=812 ok=800 failed=0 pending=0 excluded=0 polled=0 bridges=0 limit=6/min/bridge"
STUB_PATH_COUNT=1 STUB_NAME_COUNT=1 check "a bad polling line → FAIL, no mark" 1 "ok+failed+pending != subscriptions" 's2_restart_check "$STUB_SHA" "$STUB_CDHASH" "$STUB_SHA256" ""'

echo "--- webhook_401s (PC-16, E-116)"
cat > "$EUREKA/log/production_server.log" <<'EOF'
[0a1b2c3d-0000-4000-8000-000000000001] Started POST "/api/homekit/events" for 127.0.0.1 at 2026-10-08 15:00:00 -0500
[0a1b2c3d-0000-4000-8000-000000000001] Completed 401 Unauthorized in 1ms (ActiveRecord: 0.0ms)
[0a1b2c3d-0000-4000-8000-000000000002] Started POST "/accessories/control" for 127.0.0.1 at 2026-10-08 15:00:01 -0500
[0a1b2c3d-0000-4000-8000-000000000002] Completed 401 Unauthorized in 1ms (ActiveRecord: 0.0ms)
[0a1b2c3d-0000-4000-8000-000000000003] Started POST "/api/homekit/events" for 127.0.0.1 at 2026-10-08 15:00:02 -0500
[0a1b2c3d-0000-4000-8000-000000000003] Completed 200 OK in 2ms (ActiveRecord: 0.4ms)
EOF
check "one 401 on the webhook path, one elsewhere → 1" 0 "1" '[ "$(webhook_401s)" = 1 ] && echo 1'

echo "--- lutron_unreachable (PC-18b)"
cat > "$T/accessories.json" <<'EOF'
[{"name": "Lutron Processor (2)", "uniqueIdentifier": "P0000000-0000-0000-0000-000000000000", "bridgedBy": null, "isReachable": true},
 {"name": "Rear Attic Lights", "uniqueIdentifier": "A1111111-0000-0000-0000-000000000000", "bridgedBy": "P0000000-0000-0000-0000-000000000000", "isReachable": true},
 {"name": "Alley Flood Light", "uniqueIdentifier": "A2222222-0000-0000-0000-000000000000", "bridgedBy": "P0000000-0000-0000-0000-000000000000", "isReachable": false},
 {"name": "Garage Sconces", "uniqueIdentifier": "A3333333-0000-0000-0000-000000000000", "bridgedBy": "P0000000-0000-0000-0000-000000000000", "isReachable": true},
 {"name": "Thermostat", "uniqueIdentifier": "T4444444-0000-0000-0000-000000000000", "bridgedBy": null, "isReachable": false}]
EOF
STUB_ACCESSORIES="$T/accessories.json" check "three bridged, one unreachable → the set" 0 "lutron_bridge=1 bridged=3 unreachable=1 A2222222-0000-0000-0000-000000000000" 'lutron_unreachable'

echo "--- f1_check (PC-17d)"
STUB_F1=sprime check "S′-like server → 200 / 000 rc=52 / 000 rc=52" 0 "Connection:close http=000 rc=52" 'f1_check | tee /dev/stderr | grep -c "rc=52" | grep -qx 2'
STUB_F1=fixed  check "fixed server → 200 rc=0 three times"          0 "HTTP/1.0         http=200 rc=0" 'f1_check | tee /dev/stderr | grep -c "http=200 rc=0" | grep -qx 3'

echo "--- pr1e_live_check (PC-10, E-111)"
check "E1 / PUMA0 not set → STOP"     1 "STOP: set E1 and PUMA0 in the preamble first" 'pr1e_live_check'
STUB_HEAD=aaaa STUB_PUMA_PID=222 STUB_RESPONDS=true  check "HEAD is not E1 → STOP"         1 "STOP: PR 1e is not live in Puma — no W4" 'E1=bbbb; PUMA0=111; pr1e_live_check'
STUB_HEAD=bbbb STUB_PUMA_PID=111 STUB_RESPONDS=true  check "Puma not restarted → STOP"     1 "STOP: PR 1e is not live in Puma — no W4" 'E1=bbbb; PUMA0=111; pr1e_live_check'
STUB_HEAD=bbbb STUB_PUMA_PID=222 STUB_RESPONDS=false check "new code not loaded → STOP"    1 "STOP: PR 1e is not live in Puma — no W4" 'E1=bbbb; PUMA0=111; pr1e_live_check'
STUB_HEAD=bbbb STUB_PUMA_PID=222 STUB_RESPONDS=true  check "all three true → pr1e-live"    0 "pr1e-live" 'E1=bbbb; PUMA0=111; pr1e_live_check'
STUB_PUMA_PID=4242 check "puma_pid reads launchctl's pid line" 0 "4242" 'puma_pid'

echo "---"
echo "PT-165: $PASSN passed, $FAILN failed"
[ "$FAILN" = 0 ] || exit 1
exit 0
