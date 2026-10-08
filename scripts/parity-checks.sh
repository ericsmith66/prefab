#!/bin/bash
# scripts/parity-checks.sh: the binary checks of a Prefab build (PRD-1-01 plan § 15.18 R7-9 item 2, § 15.19 R8-7 / PC-17e).
# build-release.sh calls it after every build; it can also check any copied binary (P5, PT-157, PT-158).
#
# usage: parity-checks.sh --binary <file> [--config Release|Debug]      (default Release)
#   coverage symbols (___profc_)          nm <file> | grep -c ___profc_                         → must be 0
#   coverage sections (__llvm_prf_cnts)   otool -l <file> | grep -c __llvm_prf_cnts             → must be 0 (survives stripping)
#   debug switch strings                  strings -a <file> | grep -c 'PREFAB_FAULT\|PREFAB_FORCE_UNAUTHORIZED'
#                                         → must be 0 for Release (the switches compile out); Debug: reported only
# Prints one line per check, then `checks: all passed` or `checks: <failures>`, where a failure is one of
# nm-failed, coverage-instrumented, debug-switch-strings.
# exit: 0 every check passed | 3 a check failed | 1 usage (no such file, bad option).
# Read-only: it never runs, signs, copies, registers or modifies the binary.
set -uo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
die() { echo "parity-checks: $2" >&2; exit "$1"; }

BIN=""; CONFIG=Release
while [ $# -gt 0 ]; do
  case "$1" in
    --binary) [ $# -ge 2 ] || die 1 "--binary needs a file"; BIN=$2; shift 2 ;;
    --config) [ $# -ge 2 ] || die 1 "--config needs Release or Debug"; CONFIG=$2; shift 2 ;;
    *) die 1 "usage: parity-checks.sh --binary <file> [--config Release|Debug]" ;;
  esac
done
[ -n "$BIN" ] || die 1 "usage: parity-checks.sh --binary <file> [--config Release|Debug]"
[ -f "$BIN" ] || die 1 "no such file: $BIN"
case "$CONFIG" in Release|Debug) ;; *) die 1 "configuration must be Release or Debug, got '$CONFIG'" ;; esac

FAIL=""
NMOUT=$(/usr/bin/nm "$BIN" 2>/dev/null) || NMOUT=""
[ -n "$NMOUT" ] || FAIL="$FAIL nm-failed"
PROFC=$(printf '%s\n' "$NMOUT" | /usr/bin/grep -c ___profc_ || true)
PRFCNTS=$(/usr/bin/otool -l "$BIN" 2>/dev/null | /usr/bin/grep -c __llvm_prf_cnts || true)
if [ "$PROFC" != 0 ] || [ "$PRFCNTS" != 0 ]; then FAIL="$FAIL coverage-instrumented"; fi
SWITCHES=$(/usr/bin/strings -a "$BIN" 2>/dev/null | /usr/bin/grep -c 'PREFAB_FAULT\|PREFAB_FORCE_UNAUTHORIZED' || true)
if [ "$CONFIG" = Release ] && [ "$SWITCHES" != 0 ]; then FAIL="$FAIL debug-switch-strings"; fi

echo "coverage symbols (___profc_): $PROFC"
echo "coverage sections (__llvm_prf_cnts): $PRFCNTS"
if [ "$CONFIG" = Release ]; then echo "debug switch strings: $SWITCHES"; else echo "debug switch strings: $SWITCHES (Debug: reported only)"; fi
echo "checks: ${FAIL:- all passed}"
[ -z "$FAIL" ] || exit 3
exit 0
