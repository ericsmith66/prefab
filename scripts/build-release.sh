#!/bin/bash
# scripts/build-release.sh: FR-A1 / D5. Build Prefab at the pinned commit S with AUTOMATIC signing (D5, proven
# 2026-10-02) and write the parity record. PRD-1-01 plan § 15.15 R4-4.
#
# codesign needs the login keychain, so this runs inside .253's logged-in desktop session:
#   from ssh:   ~/Development/prefab/scripts/run-in-gui-session.sh --timeout 1800 -- \
#                 ~/Development/prefab/scripts/build-release.sh <S> [Release|Debug]
#   at .253's screen, in Terminal:   ~/Development/prefab/scripts/build-release.sh <S> [Release|Debug]
# Over plain ssh it fails at CodeSign with errSecInternalComponent, and says so.
#
# usage: build-release.sh <S = the 40-hex commit to build> [Release|Debug]
#   optional env: PREFAB_BUILD_ROOT (default ~/Library/Developer/Xcode/DerivedData)
#                 PREFAB_SPM_CACHE  (default $PREFAB_BUILD_ROOT/prefab-spm, the resolved Swift packages)
#                 REBUILD=1         (rebuild an existing product for S; its CDHash changes)
# Refuses: a dirty tree, HEAD != S, no package cache, an existing product for S without REBUILD=1.
# Non-interactive, no network (packages from the cache), never -allowProvisioningUpdates.
# DerivedData: a fresh $PREFAB_BUILD_ROOT/prefab-<first 12 of S>-<config> per S; next to it <that>.build.log
# and <that>.parity.txt (the record, also printed).
# exit: 0 built, every parity check passed | 1 refused | 2 xcodebuild failed | 3 a parity check failed
# S″ (plan § 15.18 R7-9 item 2, § 15.19 R8-7): the Release must carry no coverage instrumentation. `xcodebuild build`
# takes the scheme's test-plan coverage setting (S′'s Release had 10,078 ___profc_ symbols), and Xcode 26.2 refuses
# `-enableCodeCoverage NO` outside testing ("only supported when testing", exit 64), so Prefab.xctestplan's
# defaultOptions say "codeCoverage" : false (R7-9's fallback). scripts/parity-checks.sh then checks the product's binary:
# 0 ___profc_ symbols, 0 __llvm_prf_cnts sections, and (Release) 0 PREFAB_FAULT / PREFAB_FORCE_UNAUTHORIZED strings.
# Its lines go into the record; any failure (coverage-instrumented, nm-failed, debug-switch-strings) → exit 3.
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
die() { echo "build-release: $2" >&2; exit "$1"; }
[ $# -ge 1 ] && [ $# -le 2 ] || die 1 "usage: build-release.sh <S (40-hex commit)> [Release|Debug]"
S=$1; CONFIG=${2:-Release}
case "$S" in ''|*[!0-9a-f]*) die 1 "S must be a 40-hex commit id, got '$S'" ;; esac
[ ${#S} -eq 40 ] || die 1 "S must be a 40-hex commit id, got '$S'"
case "$CONFIG" in Release|Debug) ;; *) die 1 "configuration must be Release or Debug, got '$CONFIG'" ;; esac
cd "$(/usr/bin/dirname "$0")/.."
HEAD_SHA=$(/usr/bin/git rev-parse HEAD)
[ "$HEAD_SHA" = "$S" ] || die 1 "HEAD is $HEAD_SHA, not S=$S"
DIRTY=$(/usr/bin/git status --porcelain)
[ -z "$DIRTY" ] || { printf '%s\n' "$DIRTY" >&2; die 1 "working tree is dirty"; }
ROOT=${PREFAB_BUILD_ROOT:-$HOME/Library/Developer/Xcode/DerivedData}
SPM=${PREFAB_SPM_CACHE:-$ROOT/prefab-spm}
DD="$ROOT/prefab-${S:0:12}-$CONFIG"
APP="$DD/Build/Products/$CONFIG-maccatalyst/Prefab.app"
REC="$DD.parity.txt"; LOG="$DD.build.log"
[ -d "$SPM/checkouts" ] || die 1 "no resolved package cache at $SPM (seed it: PRD-1-01 plan § 15.15 R4-4)"
if [ -e "$APP" ] && [ "${REBUILD:-0}" != 1 ]; then
  die 1 "a product for S already exists: $APP (record: $REC); REBUILD=1 rebuilds it and changes its CDHash"
fi
XCODE=$(/usr/bin/xcodebuild -version | /usr/bin/tr '\n' ' ')
echo "build-release: S=$S config=$CONFIG ($XCODE) DerivedData=$DD"
set +e
/usr/bin/xcodebuild -project prefab.xcodeproj -scheme Prefab -configuration "$CONFIG" \
  -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath "$DD" \
  -clonedSourcePackagesDirPath "$SPM" -disableAutomaticPackageResolution -skipPackageUpdates \
  build </dev/null >"$LOG" 2>&1
XC=$?
set -e
if [ "$XC" -ne 0 ] || ! /usr/bin/grep -q 'BUILD SUCCEEDED' "$LOG"; then
  /usr/bin/grep -E 'error:|errSec|BUILD FAILED' "$LOG" | /usr/bin/tail -n 20 >&2 || true
  if /usr/bin/grep -q errSecInternalComponent "$LOG"; then
    echo "build-release: codesign could not use the login keychain: run inside the desktop session (scripts/run-in-gui-session.sh) or in Terminal on .253" >&2
  fi
  die 2 "xcodebuild failed (exit $XC); full log: $LOG"
fi
# Xcode's RegisterWithLaunchServices step registered the product; unregister it (R4-6). Production starts by path.
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -u "$APP" || true

SHA256=$(/usr/bin/shasum -a 256 "$APP/Contents/MacOS/Prefab" | /usr/bin/awk '{print $1}')
CS=$(/usr/bin/codesign -dvvv "$APP" 2>&1 || true)
field() { printf '%s\n' "$CS" | /usr/bin/awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }'; }
IDENT=$(field Identifier); CDHASH=$(field CDHash); AUTH=$(field Authority); TEAM=$(field TeamIdentifier)
PROFILE=$(/usr/bin/perl -0777 -ne 'print $1 if m{<key>UUID</key>\s*<string>([^<]+)</string>}' "$APP/Contents/embedded.provisionprofile" 2>/dev/null || true)
HOMEKIT=$(/usr/bin/codesign -d --entitlements - --xml "$APP" 2>/dev/null | /usr/bin/perl -0777 -ne 'print m{<key>com.apple.developer.homekit</key>\s*<true/>} ? "true" : "MISSING"' || true); HOMEKIT=${HOMEKIT:-MISSING}
VERIFY=$(/usr/bin/codesign --verify --strict --verbose=2 "$APP" 2>&1 | /usr/bin/tr '\n' ' ' || true)
BI="$APP/Contents/Resources/PrefabBuildInfo.plist"
GITSHA=$(/usr/bin/plutil -extract GitSHA raw -o - "$BI" 2>/dev/null || echo MISSING)
GITDIRTY=$(/usr/bin/plutil -extract GitDirty raw -o - "$BI" 2>/dev/null || echo MISSING)
BUILT=$(/usr/bin/plutil -extract BuiltAt raw -o - "$BI" 2>/dev/null || echo MISSING)
AFTER=$(/usr/bin/git status --porcelain)
PCRC=0; PCOUT=$(scripts/parity-checks.sh --binary "$APP/Contents/MacOS/Prefab" --config "$CONFIG") || PCRC=$?

FAIL=""
[ "$GITSHA" = "$S" ] || FAIL="$FAIL GitSHA"
[ "$GITDIRTY" = false ] || FAIL="$FAIL GitDirty"
[ "$IDENT" = com.ericsmith66.prefab ] || FAIL="$FAIL Identifier"
[ "$AUTH" = "Apple Development: Eric Smith (9FKJJZD97L)" ] || FAIL="$FAIL Authority"
[ "$TEAM" = L3D6CRNC26 ] || FAIL="$FAIL TeamIdentifier"
[ -n "$PROFILE" ] || FAIL="$FAIL profile"
[ "$HOMEKIT" = true ] || FAIL="$FAIL homekit-entitlement"
case "$VERIFY" in *"valid on disk"*"satisfies its Designated Requirement"*) ;; *) FAIL="$FAIL codesign-verify" ;; esac
[ -z "$AFTER" ] || FAIL="$FAIL tree-dirtied-by-build"
case "$PCRC" in
  0) ;;
  3) FAIL="$FAIL $(printf '%s\n' "$PCOUT" | /usr/bin/sed -n 's/^checks: *//p')" ;;
  *) FAIL="$FAIL parity-checks-rc-$PCRC" ;;
esac

{
  echo "date: $(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "S: $S"
  echo "config: $CONFIG"
  echo "xcode: $XCODE"
  echo "product: $APP"
  echo "PrefabBuildInfo: GitSHA=$GITSHA GitDirty=$GITDIRTY BuiltAt=$BUILT"
  echo "sha256 Contents/MacOS/Prefab: $SHA256"
  echo "CDHash: $CDHASH"
  echo "Identifier: $IDENT"
  echo "Authority: $AUTH"
  echo "TeamIdentifier: $TEAM"
  echo "embedded profile UUID: $PROFILE"
  echo "entitlement com.apple.developer.homekit: $HOMEKIT"
  echo "codesign --verify --strict: $VERIFY"
  printf '%s\n' "$PCOUT" | /usr/bin/grep -v '^checks:' || true
  echo "parity row: $(/bin/date +%F) | $S | $SHA256 | $CDHASH | $BUILT | $PROFILE"
  echo "checks: ${FAIL:- all passed}"
} | /usr/bin/tee "$REC"
[ -z "$FAIL" ] || die 3 "parity check failed:$FAIL (record: $REC)"
echo "build-release: OK; record: $REC"
