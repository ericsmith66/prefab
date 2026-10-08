# Prefab on nextgen (.253) — runbook

Operator runbook for the Prefab HomeKit bridge on `.253` (FR-A9 of skynet-mcp PRD-1-01). The normative step list is
the PRD-1-01 implementation plan in `ericsmith66/skynet-mcp` (`knowledge_base/epics/backlog/1-Skynet-MCP-Server/`):
§ 9 (build + parity) and § 10 (window) as amended by § 15.10, § 15.11, § 15.14 (R3) and § 15.15 (R4). Where this file
and the plan differ, the plan wins. Every state-changing step needs Eric's "yes" at the time it runs.

> **2026-10-08 — PRD-1-01 closeout (QA R-1; plan § 15.18 R7-2).** Added: rule 11 (§ 7 — never a second Prefab
> instance on `.253`), R6-2's `prefab_stop` (§ 10 — TERM → TERM → KILL, by path), step 20b (§ 10), the F-1 keep-alive
> rule for every client (§ 1) and the native-callback-rate check after every restart and every HomeKit-touching step
> (§ 10a). The scratch launches (§ 7.1, § 8 step 5) and step 23d are history: never rerun them while production runs.

Placeholders: `S` = the pinned 40-hex commit that is built and deployed (today `S′`, see § 5); `<repo>` = `.253`'s build
clone `~/Development/prefab-build`, **detached at `S` and never pulled** (plan § 15.16 R5-2). Until window prep the build
clone is still `~/tmp/prefab-prd01` (detached at `S′`); at window prep it is moved to `~/Development/prefab-build`.
`~/Development/prefab` on `.253` is a secondary clone: never built, reset or deployed from (Eric, 2026-10-02). `<date>` =
`$(date +%Y%m%d)` of the day the step runs.

## 1. Hosts & layout

- **nextgen = `.253`** (192.168.4.253), headless Mac Studio, user `ericsmith66`, reached from m3ultra as `ssh nextgen`.
  bash 3.2 + BSD userland: there is no `timeout` (use `perl -e 'alarm N; exec @ARGV' …`); never edit with BSD `sed`.
- **Bundle:** `~/Applications/Server/Prefab.app` (bundle id `com.ericsmith66.prefab`, Mac Catalyst).
- **LaunchAgent:** `~/Library/LaunchAgents/com.ericsmith66.prefab.plist`, label `com.ericsmith66.prefab`; it runs
  `/usr/bin/open -W ~/Applications/Server/Prefab.app` (Aqua session, KeepAlive). `launchctl bootout` stops only the
  `open -W` waiter — the app itself has its own pid and process group (PA-1), see `prefab_stop` in § 10.
- **HTTP:** `127.0.0.1:8080` only (P12); no Bonjour. Routes: `/version` (never behind the HomeKit auth check),
  `/homes`, `/rooms/:home[/:room]`, `/accessories/:home[/summary|/:room[/:accessory]|/id/:uuid[?characteristic=]]`
  (from S″ the two full-detail routes also take `?read=cache|live`, § 18), and from S″ `GET /triggers/:home` and
  `PUT /triggers/:home/:uuid/enabled` (PRD-1-07 Track A, behind the write flag — § 19),
  `/scenes/:home[/:scene[/execute]]`, `/groups/:home[/:group]`.
- **Every client uses keep-alive HTTP/1.1 (F-1, found 2026-10-03).** Prefab `S′` sends **no response** to a request
  that carries `Connection: close`, or to any HTTP/1.0 request: the connection just closes (curl exit 52, "Empty
  reply from server" — measured 2026-10-08 on `/version`). Use plain `curl` (HTTP/1.1 with keep-alive by default;
  never `-0`, never `-H 'Connection: close'`) or Python `http.client`. Never Python `urllib.request`: it always sends
  `Connection: close` (that is what broke step 20b's first runs). Rails' `PrefabClient` uses curl and is unaffected.
  The cause (found hostless on 2026-10-08, plan R8-5 branch 1): on Network.framework the server's close right after
  the response write loses the response. Prefab `S″` serves HTTP on BSD sockets instead (§ 18). Keep this rule until
  the S″ window's W8 (`f1_check`) shows `200 rc=0` three times on production.
- **Config:** `~/Library/Application Support/Prefab/config.json` (mode 600 once it holds `webhook.authToken`).
  **Debug log:** `~/Documents/homebase_debug.log` (written only when `logging.enabled` is true; recreated at every
  start). Overrides, honoured by every build and reported by `/version`: `PREFAB_PORT` (1024–65535),
  `PREFAB_CONFIG_PATH`, `PREFAB_LOG_PATH` (absolute paths); a bad value exits 2 with `prefab: invalid <NAME>` on stderr.
  All of them are validated together on the first line of `Server.init`, before the config is read, the debug log is
  recreated or HomeKit is touched (QA remediation RM-2); from S″ that check also decodes an existing `config.json` and
  exits 2 (`prefab: invalid PREFAB_CONFIG_PATH`) without ever overwriting it (§ 18). Debug builds only:
  `PREFAB_FORCE_UNAUTHORIZED=1`, `PREFAB_FAULT=write_failed|write_timeout`; a set (even empty)
  `PREFAB_FORCE_UNAUTHORIZED` other than `1`, or a non-empty `PREFAB_FAULT` outside those two, exits 2 at launch
  (`prefab: invalid PREFAB_FORCE_UNAUTHORIZED` / `… PREFAB_FAULT`, RM-3); an empty `PREFAB_FAULT` is off — a mistyped
  switch never falls through to a real write. Release builds ignore both (compiled out). From S″ a Debug 403 caused by
  the switch adds `"cause": "PREFAB_FORCE_UNAUTHORIZED"`; every other 403 keeps its bytes.
- **Timeouts (Prefab side of the ladder):** write 4 s → 504 `write_timeout`; scene 25 s → 504 `scene_timeout`;
  full-detail read 12 s → 504 `read_timeout`; single-characteristic read 5 s → 504 `read_timeout`.
  `/version.timeouts` reports them. A single-characteristic read whose HomeKit read fails answers 502
  `{"error":"read_failed","hm_code":…,"message":…}` (RM-4) — never the cached value; the full-detail read still
  returns HomeKit's cached values when individual reads fail. From S″ a full-detail read is HomeKit's cache by default
  (no device reads) and says so (`"values":"cache"`); `?read=live` reads first (§ 18).
- **Accessory JSON:** every item carries `uniqueIdentifier`, `room`, `isDefaultRoom` and `bridgedBy` — `null` when the
  accessory is not bridged (RM-1); the single-characteristic read always carries `value` and `format` (`null` when
  HomeKit has none).
- **Source tree:** the Xcode app target compiles `prefab/http` + `prefab/model` (+ `prefab/*.swift`).
  `Sources/PrefabServer/` is a divergent SwiftPM copy the target does not reference — never edit it (S16, Q-A3).
  `prefab/http/Data.swift` and `prefab/model/HAPUUIDs.swift` are also compiled into the `prefab` CLI target, which
  links no Hummingbird: keep Hummingbird-dependent code out of those two files.
- **Rails consumer:** eureka-homekit on `127.0.0.1:3002` receives the webhooks at `/api/homekit/events`.

## 2. Signing

- **Style AUTOMATIC** (D5, proven 2026-10-02 — plan § 15.15 R4-1). No `CODE_SIGN_STYLE = Manual` and no profile name
  are committed; Manual is impossible with the Xcode-managed profile.
- Identity `Apple Development: Eric Smith (9FKJJZD97L)`, team `L3D6CRNC26`, embedded profile
  `Mac Catalyst Team Provisioning Profile: com.ericsmith66.prefab`, UUID `d29ac58d-0875-4558-af32-4a98310ed221`,
  entitlement `com.apple.developer.homekit`.
- **The profile expires 2027-06-04T14:00:14Z.** Renewal is Eric's: in Xcode on m3ultra with his account, then copy
  the new `.provisionprofile` into `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` on `.253` before that
  date. `.253` never runs `-allowProvisioningUpdates`.
- **Signed builds run only inside Eric's logged-in desktop session** (§ 3). Over plain ssh, codesign fails with
  `errSecInternalComponent` because an ssh session cannot use the login keychain.
- Fallback (plan R4-4 "R1 fallback"): build on m3ultra (`.200`) from the same `S` with the same script in Eric's
  desktop session there; copy the product with `ditto`; compare the CDHash after the copy. Parity is still proven by
  `/version` + sha256 + CDHash.

## 3. Desktop-session builds

`scripts/run-in-gui-session.sh` runs ONE command as a one-shot launchd job in `gui/<uid>` (Aqua), so codesign can use
the login keychain without a password or dialog. The plist lives in `/tmp` only (never `~/Library/LaunchAgents`),
`KeepAlive` false, the command is bounded by a perl alarm, and a trap boots the job out on any exit.

```bash
<repo>/scripts/run-in-gui-session.sh [--timeout SECONDS] [--tail LINES] -- COMMAND [ARG...]
# variables: -- /usr/bin/env K=V COMMAND ; absolute paths only; output kept in /tmp/<label>.out (mode 600)
```

| Exit | Meaning | Next |
|---|---|---|
| the command's own (0, 1, 2, 7, …) | the job ran to its end | read the printed tail; full output in `/tmp/<label>.out` |
| 64 | usage | fix the call |
| 69 | no `gui/<uid>` domain: nobody is logged in at the desktop | attended: Eric logs in at `.253`'s screen, or runs the command in Terminal there |
| 70 | the plist could not be written or bootstrapped | read the message; nothing ran |
| 124 | no done marker by the alarm + 30 s | **INCONCLUSIVE → rerun attended** |
| 142 | the alarm fired (SIGALRM) | **INCONCLUSIVE → rerun attended** (a hidden dialog, e.g. a locked keychain, looks like this) |
| 129 / 130 / 141 / 143 | the ssh side was interrupted | the trap stopped the job; rerun |

**Never run a HomeKit app under the helper.** The job's `/bin/bash` would become the TCC-responsible process and TCC
hard-denies it without a prompt — a false 403. Prefab is always launched through `/usr/bin/open` (LaunchServices);
the helper may run that `open`.

Attended fallback: Eric runs the same command in Terminal at `.253`'s screen.

## 4. Build

1. **Package cache, once (D-1a; plain ssh, no signing):**
   ```bash
   cd <repo> && git status --porcelain && mkdir -p ~/Library/Developer/Xcode/DerivedData/prefab-spm \
     && perl -e 'alarm 900; exec @ARGV' /usr/bin/xcodebuild -resolvePackageDependencies -project prefab.xcodeproj -scheme Prefab \
        -clonedSourcePackagesDirPath ~/Library/Developer/Xcode/DerivedData/prefab-spm -disableAutomaticPackageResolution \
        -derivedDataPath /tmp/prefab-d1a-dd </dev/null 2>&1 | tail -22; ls ~/Library/Developer/Xcode/DerivedData/prefab-spm/checkouts | wc -l
   ```
   Expected: `hummingbird` 1.12.0, `hummingbird-core` 1.6.0 (the committed `Package.resolved`), `18` checkouts, the
   tree clean before and after. (`-derivedDataPath` keeps the resolve's activity logs out of a hash-named folder under
   `~/Library/Developer/Xcode/DerivedData`.)
2. **Check out `S`** (D-1, plan R5-6): `cd <repo> && perl -e 'alarm 60; exec @ARGV' git fetch origin </dev/null && git
   checkout -q --detach <S> && git status --porcelain && git rev-parse HEAD` → empty status; HEAD == `S`. **Never** a
   `pull` or `merge --ff-only`: the branch tip is `S` plus docs-only parity commits, and `build-release.sh` / D-7 refuse
   when HEAD ≠ `S`. If `.253` cannot reach GitHub, push `S` from m3ultra into the clone's remote-tracking ref first:
   `git push nextgen:<repo path> <S>:refs/remotes/origin/epic-1/prd-01-lane-h-substrate`.
3. **Release (D-2) and Debug (D-3), through the helper, from ssh:**
   ```bash
   S=<40-hex S>
   ssh nextgen "<repo>/scripts/run-in-gui-session.sh --timeout 1800 -- <repo>/scripts/build-release.sh $S"; echo "rc=$?"         # Release
   ssh nextgen "<repo>/scripts/run-in-gui-session.sh --timeout 1800 -- <repo>/scripts/build-release.sh $S Debug"; echo "rc=$?"   # Debug
   ```
   Expected rc 0 and a record ending `checks: all passed` (GitSHA = `S`, GitDirty false, Authority/Team as § 2,
   profile UUID, HomeKit entitlement true, `codesign --verify --strict` valid). `build-release.sh` exits 1 when it
   refuses (dirty tree, HEAD ≠ `S`, no package cache, product already exists), 2 when `xcodebuild` fails
   (`errSecInternalComponent` = not run in the desktop session), 3 when a parity check fails.
4. **Where things live:** a fresh DerivedData per `S` at
   `~/Library/Developer/Xcode/DerivedData/prefab-<first 12 of S>-<Release|Debug>`; next to it `<that>.build.log` and
   `<that>.parity.txt` (the record). Release product:
   `…/prefab-<S12>-Release/Build/Products/Release-maccatalyst/Prefab.app` (the window's swap source). Debug product:
   `…/prefab-<S12>-Debug/Build/Products/Debug-maccatalyst/Prefab.app` (scratch launches only, never deployed).
5. **`REBUILD=1` only for D-7** (window day, when the D-2 record is not `checks: all passed` or the product's
   `GitSHA` is not `S`): `ssh nextgen "<repo>/scripts/run-in-gui-session.sh --timeout 1800 -- /usr/bin/env REBUILD=1
   <repo>/scripts/build-release.sh $S"` — the CDHash changes; re-record it.
6. **Dry build days before the window.** The D-2 product must survive until the window (it is not in `/tmp`).
7. **Unsigned compile checks** (no keychain): add `CODE_SIGNING_ALLOWED=NO` and a `/tmp` `-derivedDataPath`; afterwards
   `lsregister -u` that product (§ 6).
8. **Any other `xcodebuild` call** (e.g. `-list`, `-resolvePackageDependencies`) also gets a `/tmp` `-derivedDataPath`,
   or Xcode creates a hash-named folder under `~/Library/Developer/Xcode/DerivedData`; `xcodebuild -list` then also
   needs `-scheme Prefab` (Xcode 26.2 exits 64 without it): `xcodebuild -list -project prefab.xcodeproj -scheme Prefab
   -derivedDataPath /tmp/<dir>`.

## 5. Parity record

One row per § 9 D-2 build — the record's `parity row:` line (`date | S | sha256 Contents/MacOS/Prefab | CDHash |
built_at | embedded profile UUID`). Rows are added by a docs-only commit made after D-2; that commit is never checked
out on `.253` before the window (`build-release.sh` and D-7 need HEAD == `S` there), so `S` is the built commit, not the
docs commit. At the window, step 15's CDHash after the copy and step 18's `/version.git_sha` must match the Release row.

**Release (deployable):**

| date | S | sha256 Contents/MacOS/Prefab | CDHash | built_at | profile |
|---|---|---|---|---|---|
| 2026-10-02 | b2ca6d35801107019489eb0d4d4d94018eee3af8 | 7fd0c015becce5f4e050b9fd884ad511452d20b2f9083e700c189d0ab84fe3e4 | 876f1e2f3b3c1dc098af276ed61dd0668927fbcb | 2026-10-02T18:07:23Z | d29ac58d-0875-4558-af32-4a98310ed221 |
| ~~2026-10-02~~ superseded by the QA-remediation S′ (never deployed) | f21d5d3c8b7a36109be2333c816fc3cfd52edf9a | e85631b67d167c227103aeded7cb91d5836fd51668665476a6325bc93d90e43c | 536c60739b99eec56c9e7de8b506323613a7914b | 2026-10-02T16:24:27Z | d29ac58d-0875-4558-af32-4a98310ed221 |

**Debug (scratch launches only; `Contents/MacOS/Prefab` is Xcode's debug-dylib stub there):**

| date | S | sha256 Contents/MacOS/Prefab | CDHash | built_at | profile |
|---|---|---|---|---|---|
| 2026-10-02 | b2ca6d35801107019489eb0d4d4d94018eee3af8 | a426c7b72c685a596d4810674bf2779ea86054a8d15d886765311f1546f3ac36 | b4ca303dc42edba4250194f13187cbf41f1641ac | 2026-10-02T18:07:58Z | d29ac58d-0875-4558-af32-4a98310ed221 |
| ~~2026-10-02~~ superseded by the QA-remediation S′ | f21d5d3c8b7a36109be2333c816fc3cfd52edf9a | 34505fb8e05fd94a8f4dce39513fc1c11ab5ba93d5c5d2b0be68fa68bd910dd2 | 484248ad44b502083e303978615624cc90fe0061 | 2026-10-02T16:24:54Z | d29ac58d-0875-4558-af32-4a98310ed221 |

Records: `~/Library/Developer/Xcode/DerivedData/prefab-b2ca6d358011-{Release,Debug}.parity.txt` on `.253` (`S′` = `b2ca6d35801107019489eb0d4d4d94018eee3af8`; Xcode 26.5 17F42; built 2026-10-02 in Eric's desktop session through `scripts/run-in-gui-session.sh` from the build clone; both `checks:  all passed`). `S` `f21d5d3`'s products and records were removed after `S′` passed (its rows above are kept for the record).

## 6. LaunchServices

- Production starts by path (`open -W ~/Applications/Server/Prefab.app`), so stray copies cannot hijack it. Nothing
  may open Prefab by bundle id (`open -b com.ericsmith66.prefab`, AppleScript `application id`, URL handlers).
- Xcode's `RegisterWithLaunchServices` step registers every product it builds, and `open` registers what it launches.
  `build-release.sh` runs `lsregister -u` on its product right after the build — but on 2026-10-02 both § 9 products
  (`prefab-f21d5d3c8b7a-Release`, `-Debug`) were registered again about 2 s later (LaunchServices `reg date` 2 s after the
  signing time), so always confirm with the dump below. Unregister every agent-made product once it is no longer needed: after the scratch launches `"$DBG/Prefab.app"`; after step 23d `/tmp/prefab-scratch/Prefab-release.app`
  (before the directory is removed); unsigned compile products.
- **Only ever `lsregister -u <agent-made path>`.** Never `-kill`, `-delete`, `-r` or `-R` scans; never on
  `~/Applications/Server/Prefab.app` or on Eric's older copies. Nothing at the window runs `lsregister`.

```bash
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
"$LSREG" -u "<agent-made product path>"
"$LSREG" -dump 2>/dev/null | awk '/^path:/{p=$0} /^identifier:[[:space:]]+com\.ericsmith66\.prefab$/{print p}' | sort -u   # read-only
```

Before the § 9 builds of 2026-10-02 the dump listed five paths: `~/Applications/Server/Prefab.app` (production) and four older Xcode copies
of Eric's (`~/Library/Developer/Xcode/DerivedData/prefab-faptzqxnfvnxsleiymoahonhqebb/…`, two under
`/Volumes/ericsmith66/Library/Developer/Xcode/DerivedData/prefab-*/…`, and
`/Volumes/ericsmith66/development/legion/projects/prefab/build/Build/Products/Release-maccatalyst/Prefab.app`).

## 7. Rule 11 — never a second Prefab instance on `.253` (2026-10-03 incident)

**Rule 11.** While production Prefab runs on `.253`, never start a second instance of `com.ericsmith66.prefab`
there: no scratch build, no Debug build, no release copy, no `open -n`, and no hosted `xcodebuild test` (the
`prefabTests` target is hosted by the app, so a test run launches one). A test that needs a running Prefab runs with
production **stopped** (and restarted after, with Eric's yes), or on another Mac. Prefab's logic tests run hostless
on m3ultra (plan § 15.18 R7-5).

- **Why.** On 2026-10-03 step 23d launched a release copy of the production app beside production. When the copy
  exited (22:43:35 UTC), HomeKit stopped delivering notifications to production for about 44 hours, until a restart
  on 2026-10-05 at 14:04 CDT. Production kept answering reads and writes, so `/homes`, `/version` and writes looked
  healthy; only the event rate showed it (≈ 600 events an hour → a trickle). HomeKit appears to tie notification
  registrations to the app, not the process (inferred from the timing).
- **After every restart, and after every step that touches HomeKit** (a scene run, a trigger toggle, a test with
  production stopped): run the native-callback-rate check of § 10a. The feed age alone is not enough.
- **The known fix** when reads work but notifications are gone: restart production Prefab (`prefab_stop`,
  bootstrap, `prefab_start_check`, § 10), with Eric's yes.

### 7.1 History — the 2026-10-02/03 scratch-launch rules (O30; plan § 15.11 D-4/D-5 + R4-5)

**Do not run anything in this section while production runs on `.253` (rule 11).** It is kept as the record of how
AC-01-06/41/42 were shown on 2026-10-02/03.


- Every scratch launch sets **all three** overrides: `PREFAB_PORT=8081`, `PREFAB_CONFIG_PATH=/tmp/prefab-scratch/config.json`,
  `PREFAB_LOG_PATH=/tmp/prefab-scratch/homebase_debug.log`. Never the production config or log path: a running scratch
  instance reads its config and recreates its debug log at start. (Since RM-2 a bad value exits before either happens;
  the all-three rule stays as defence in depth.)
- Scratch config: `umask 077`; `webhook.enabled:false` and `authToken` removed, `polling.enabled:false`,
  `logging.enabled:true`, everything else as production:
  ```bash
  umask 077; rm -rf /tmp/prefab-scratch; mkdir -p /tmp/prefab-scratch
  python3 -c 'import json,os; p=os.path.expanduser("~/Library/Application Support/Prefab/config.json"); c=json.load(open(p)); c["webhook"]["enabled"]=False; c["webhook"].pop("authToken", None); c["polling"]["enabled"]=False; c["logging"]["enabled"]=True; json.dump(c, open("/tmp/prefab-scratch/config.json","w"))'
  ```
- Launch through LaunchServices into the Aqua session (the app is then its own TCC-responsible process):
  ```bash
  DBG=$HOME/Library/Developer/Xcode/DerivedData/prefab-<S12>-Debug/Build/Products/Debug-maccatalyst
  open -n -W --stdout /tmp/prefab-scratch/out.log --stderr /tmp/prefab-scratch/err.log \
    --env PREFAB_PORT=8081 --env PREFAB_CONFIG_PATH=/tmp/prefab-scratch/config.json \
    --env PREFAB_LOG_PATH=/tmp/prefab-scratch/homebase_debug.log --env PREFAB_FORCE_UNAUTHORIZED=1 "$DBG/Prefab.app" &
  ```
  If `open` from ssh fails with a LaunchServices error, run the same `open` line (without `-W` and `&`) through the
  helper with `--timeout 60`; Eric's Terminal at `.253`'s screen is the last resort.
- Stop scratch instances **only by their own path**: `pkill -f "$DBG/Prefab.app/Contents/MacOS/Prefab"` — never the
  production process.
- Exit-2 checks always carry the scratch paths; the numeric status comes from the helper (no HomeKit is needed — since
  RM-2 the binary exits on the first line of `Server.init`, before `HomeBase`/`HMHomeManager` exist):
  ```bash
  H=<repo>/scripts/run-in-gui-session.sh
  $H --timeout 60 -- /usr/bin/env PREFAB_PORT=80 PREFAB_CONFIG_PATH=/tmp/prefab-scratch/config.json PREFAB_LOG_PATH=/tmp/prefab-scratch/homebase_debug.log \
    "$DBG/Prefab.app/Contents/MacOS/Prefab"; echo "rc=$?"          # → rc=2; "prefab: invalid PREFAB_PORT"
  $H --timeout 60 -- /usr/bin/env PREFAB_PORT=8081 PREFAB_CONFIG_PATH=/tmp/prefab-scratch/config.json PREFAB_LOG_PATH=rel/x \
    "$DBG/Prefab.app/Contents/MacOS/Prefab"; echo "rc=$?"          # → rc=2; "prefab: invalid PREFAB_LOG_PATH"
  pgrep -fl "$DBG/Prefab.app/Contents/MacOS/Prefab" || echo "no scratch pid"
  ```
- The production debug-log inode check (`stat -f %i ~/Documents/homebase_debug.log` unchanged) is meaningful only
  after the window: the pre-window binary recreates its log on every HTTP request.
- Afterwards: `lsregister -u` each launched scratch product (§ 6), then `rm -rf /tmp/prefab-scratch`.

## 8. Pre-checks (any day before the window; read-only unless noted)

| Step | Command | Expected |
|---|---|---|
| 1 | `git -C <repo> status --porcelain; git -C <repo> log -1 --oneline` | empty + `S` |
| 2 | off-box-caller check, § 17 | no off-box caller |
| 3 | `for i in 1 2 3; do lsof -nP -iTCP:8080 -sTCP:ESTABLISHED \| awk 'NR>1{print $9}'; sleep 20; done` | every peer `127.0.0.1` or `[::1]` |
| 4 | `launchctl print gui/$(id -u)/ai.agentforge.prefab-display-awake \| grep -E "state"; tail -1 ~/Library/Logs/homekit-feed-check.log` | `state = running`; `ok age=<small>s caffeinate=running` |
| 5 | § 4 (D-1a, D-1, D-2). **No scratch launch on `.253` while production runs** (rule 11, § 7); the D-4/D-5 launches of 2026-10-02 are history (§ 7.1) | a record ending `all passed` |

## 9. Window day, Rails part first (steps 7 → 6 + 8 → 9 → 10)

PR 1a deploys on window day, immediately before step 11 (plan R3-4). The commands are the R3 versions in plan
§ 15.14 — step 7 (append `skynet_api_token` with `append-cred.sh`), then steps 6 + 8 as ONE script
(`~/pr1a-deploy.sh`, md5 recorded, one "yes"; refuses 05:30–06:30 and while a `pg_dump` runs; `lock_timeout=5s`
migrate, immediate `launchctl kickstart -k gui/$(id -u)/com.ericsmith66.eureka`), then step 9 (`/api/skynet/scope` with
and without the token) and step 10 (header-less POST → 422; favourite toggle in the browser). Rollback: R3-1
(code-only `git reset --keep cd16daf` first; `db:rollback:primary` only on Eric's call, never after step 22).

## 10. The window (steps 11–20; Eric present; target ≤ 15 min between 14 and 17, hard limit 25)

Shell preamble on `.253` (plan § 15.10):

```bash
cd ~/Development/legion/projects/eureka-homekit
export PATH="$HOME/.rbenv/shims:/opt/homebrew/bin:/opt/homebrew/opt/postgresql@16/bin:$PATH"; export RAILS_ENV=production
P='/opt/homebrew/opt/postgresql@16/bin/psql -h 127.0.0.1 -U ericsmith66 eureka_production -At'
AGE="select extract(epoch from (now() at time zone 'UTC') - max(created_at))::int from homekit_events"
PP='/Users/ericsmith66/Applications/Server/Prefab.app/Contents/MacOS/Prefab'
prefab_stop() {   # PA-1 + PD-16: bootout stops only the `open -W` waiter; Hummingbird traps the first SIGTERM (HTTP only)
  launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.ericsmith66.prefab.plist    # first, so KeepAlive cannot relaunch
  local t0=$(date +%s) by=none i
  pkill -TERM -f "$PP"; for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$PP" >/dev/null || { by="first TERM"; break; }; sleep 1; done
  if pgrep -f "$PP" >/dev/null; then
    pkill -TERM -f "$PP"; for i in 1 2 3 4 5; do pgrep -f "$PP" >/dev/null || { by="second TERM"; break; }; sleep 1; done
  fi
  if pgrep -f "$PP" >/dev/null; then
    pkill -KILL -f "$PP"; for i in 1 2 3; do pgrep -f "$PP" >/dev/null || { by=KILL; break; }; sleep 1; done
  fi
  pgrep -fl "$PP" && { echo "STOP: Prefab still running after KILL"; return 1; }
  echo "prefab stopped (ended by $by after $(( $(date +%s) - t0 ))s)"   # expected: second TERM after ~10-11 s; at most ~19 s
}
prefab_start_check() {                             # after every bootstrap: exactly one NEW pid, then /version
  sleep 10; pgrep -fl "$PP"
  curl -s -m 5 -w '\n%{http_code}\n' 127.0.0.1:8080/version   # new binary: 200 + git_sha == S · old binary: 404
}
```

**Why TERM → TERM → KILL (plan R6-2, PD-16).** `launchctl bootout` stops only the `open -W` waiter. Hummingbird traps
the first SIGTERM and stops only its HTTP server; the HomeKit layer keeps running. The second TERM ends the process
(10–11 s on every stop so far). A stop by KILL is not a failure; `STOP` means Prefab survived KILL — ask Eric.

| Step | Command | Expected | Rollback / if not |
|---|---|---|---|
| 11 | `git -C <repo> status --porcelain && git -C <repo> rev-parse HEAD`; D-7 (reuse the D-2 product if its record says `checks: all passed` and its `PrefabBuildInfo.plist` `GitSHA` is `S`); then the PR 1b fetch/ff/creds checks of plan § 15.10 step 11 | empty, `S`; `ff-ok`, `creds-untouched` | rebuild (§ 4.5) before T0 |
| 12 | parity row checked; `cp "$HOME/Library/Application Support/com.apple.TCC/TCC.db" "$HOME/Library/Application Support/com.apple.TCC/TCC.db.bak-<date>"`; the TCC query of § 11 | backup exists; `2\|…` recorded (before) | — |
| 13 | `curl -s 127.0.0.1:8080/accessories/Waverly \| python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'` → `N_before`; `tail -1 ~/Library/Logs/homekit-feed-check.log`; `$P -c "$AGE"` | recorded — **T0** | — |
| 14 | `prefab_stop` | `prefab stopped (ended by second TERM after ~10–11s)`; KILL is not a failure; `STOP` only if Prefab survives KILL | `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.ericsmith66.prefab.plist; prefab_start_check` (old binary: `/version` 404, `/homes` 200) |
| 15 | `mv ~/Applications/Server/Prefab.app ~/Applications/Server/Prefab.app.prev-<date> && cp -R ~/Library/Developer/Xcode/DerivedData/prefab-<S12>-Release/Build/Products/Release-maccatalyst/Prefab.app ~/Applications/Server/Prefab.app && codesign -dvvv ~/Applications/Server/Prefab.app 2>&1 \| grep -E '^CDHash' && codesign --verify --strict --deep ~/Applications/Server/Prefab.app && shasum -a 256 ~/Applications/Server/Prefab.app/Contents/MacOS/Prefab` (the source is the D-2 `.app` itself; QA m4) | CDHash and sha256 == the Release parity row; `--verify` rc 0 | `rm -rf ~/Applications/Server/Prefab.app && mv ~/Applications/Server/Prefab.app.prev-<date> ~/Applications/Server/Prefab.app` |
| 16a | `cp -p "$HOME/Library/Application Support/Prefab/config.json" "$HOME/Library/Application Support/Prefab/config.json.bak-<date>"` | backup exists | — |
| 16 | webhook token, § 12 | `['authToken', 'enabled', 'url']`; `-rw-------` | `cp -p "…/config.json.bak-<date>" "…/config.json" && chmod 600 "…/config.json"` |
| 17 | credential + PR 1b + ONE Rails restart + Prefab start (plan § 15.10 step 17): `append-cred.sh` for `prefab_webhook_token`, `credentials_ok`, `git merge --ff-only "$B"`, `launchctl kickstart -k gui/$(id -u)/com.ericsmith66.eureka`, `/up` 200, then `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.ericsmith66.prefab.plist; prefab_start_check` | one NEW pid; `/version` 200 with `git_sha` == `S` | plan § 15.10 step 17 rollback (PR 1a merge checked out, credential removed, step 16 rollback, `prefab_stop`, bootstrap) |
| 18 | `curl -s 127.0.0.1:8080/version` (AC-01-01: `git_sha` `S`, `git_dirty` false, `bind` `127.0.0.1:8080`, `bonjour` false, production `config_path`/`debug_log`, `timeouts {4,25,12,5}`); `curl -s 127.0.0.1:8080/homes`; wait 3 min; `$P -c "$AGE"`; `tail -n 5000 log/production_server.log \| grep -c 'POST "/api/homekit/events".* 401'` | AC-01-01 JSON; `[{"name":"Waverly"}]`; age `< 120`; `0` | first `pgrep -fl "$PP"` + `/version` (an old instance answering 404 → `prefab_stop`, bootstrap, `prefab_start_check`); only then suspect a token mismatch (§ 12) |
| 19 | the TCC query of § 11 (after) | `2\|…` recorded | `/homes` 403 → re-grant (§ 11), `prefab_stop`, bootstrap, `prefab_start_check`, repeat 18 |
| 20 | the list check of plan § 15.10 step 20 (count = `N_before` + Default Room count, every item a `uniqueIdentifier`, a `room`, and `bridgedBy` null or the `uniqueIdentifier` of an item in the same list — any category can bridge, e.g. the alarm panel or a thermostat (F-2)); `lsof -nP -iTCP:8080 -sTCP:LISTEN`; § 16; watchdog and display-awake state | one `127.0.0.1:8080` listener; no `nextgen` Bonjour line; watchdog `ok`; display-awake `running` — **T1** | — |

Production `shasum -a 256 ~/Applications/Server/Prefab.app/Contents/MacOS/Prefab` and `codesign -dvvv` CDHash must equal
the Release parity row (D-8, AC-01-01).

**Step 20b — the latency gate (between steps 20 and 21; read-only; S′ era; plan R6-5).** It times three full-detail
reads behind the Lutron Processor (2) (the test light, `Alley | Alley Flood Light` and one more) and five single `On`
reads of the test light, with a keep-alive client (F-1):

```bash
python3 - <<'PY'
import http.client, json, os, time
PORT = int(os.environ.get("PREFAB_GATE_PORT", "8080"))          # 8080 = production; another port only for a fake-server test
def get(path, t):
    t0 = time.monotonic()
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=t)  # HTTP/1.1, keep-alive, never "Connection: close" (F-1)
    try:
        c.request("GET", path)
        r = c.getresponse(); body, code = r.read(), r.status
    except Exception as e:
        body, code = str(e).encode(), 0
    finally:
        c.close()
    return code, time.monotonic() - t0, body
B = "/accessories/Waverly"
code, dt, body = get(B, 15); assert code == 200, (code, body[:200])
d = json.loads(body)
proc = [a["uniqueIdentifier"] for a in d if a.get("name") == "Lutron Processor (2)"]; assert len(proc) == 1, proc
tl = [a for a in d if a.get("room") == "Kitchenette" and a.get("name") == "Rear Attic Lights"]
assert len(tl) == 1 and tl[0].get("bridgedBy") == proc[0], "test light not found behind Lutron Processor (2)"
others = sorted((a for a in d if a.get("bridgedBy") == proc[0] and a["uniqueIdentifier"] != tl[0]["uniqueIdentifier"]),
                key=lambda a: (a["room"], a["name"]))
pick = [a for a in others if (a["room"], a["name"]) == ("Alley", "Alley Flood Light")][:1]
pick += [a for a in others if a not in pick][: 2 - len(pick)]
details_ok, on = True, None
for a in tl + pick:
    code, dt, body = get(B + "/id/" + a["uniqueIdentifier"], 15)
    print("detail %s|%s: %d %.3fs" % (a["room"], a["name"], code, dt)); details_ok &= (code == 200 and dt < 12)
    if a is tl[0] and code == 200:
        svc = [s for s in json.loads(body)["services"] if s["type"].upper() == "00000043-0000-1000-8000-0026BB765291"]
        on = [x["uniqueIdentifier"] for x in svc[0]["characteristics"] if x["type"].upper() == "00000025-0000-1000-8000-0026BB765291"][0]
fast = 0
for i in range(5 if on else 0):
    code, dt, body = get(B + "/id/" + tl[0]["uniqueIdentifier"] + "?characteristic=" + on, 8)
    print("On read %d: %d %.3fs" % (i + 1, code, dt)); fast += (code == 200 and dt < 2.0); time.sleep(1)
ok = details_ok and on is not None and fast >= 4
print("latency gate: details %s; On reads 200 < 2 s: %d/5 -> %s" % ("all 200 < 12 s" if details_ok else "NOT all 200", fast, "PASS" if ok else "FAIL"))
PY
```

**Pass rule:** all three full-detail reads answer 200 in < 12 s **and** at least 4 of the 5 `On` reads answer 200 in
< 2 s → step 21. **FAIL → stop after step 20:** a valid resting state (plan R6-5); steps 21–29 are rescheduled, and no
new restart window is needed. On 2026-10-03 the first two runs (an `urllib` version) got no response (F-1); the
keep-alive rerun passed. From Prefab `S″` on, a full-detail read is served from HomeKit's cache by default and makes
no device reads, so this gate then measures nothing; a live check uses `?read=live` (plan § 15.18 R7-8).

**After the window:** re-key and live steps 21–29 (plan § 15.10 D; § 15.9). Prefab-only black-box checks there:
23 (`?characteristic=` read < 2 s, one `[readOne]` debug-log line), 23a (unknown `characteristicId` → 404
`what:characteristic`), 23b (unreachable accessory → 503 `unreachable`, no `Attempting write`), 23c (`value:"abc"` to a
`uint8` → 400 `bad_value`), 23d (history — its release-copy launch caused the 2026-10-03 incident; never rerun it while production runs, § 7).
Since RM-4 a `?characteristic=` read whose HomeKit read fails answers 502 `read_failed`. So step 23b (plan R5-7) takes
its PUT value **from the mirror**: `$P -c "select current_value from sensors where id=512"` (`Shop | 3d Printer`
`Lightbulb/On`). A null value means the PUT is not sent (AC-01-04 BLOCKED, ask Eric). The read-only
`?characteristic=` GET still runs, as PT-128 (2)'s record: 502 `read_failed`, 504 or 200. Step 23a carries R5-7's
400/404 matrix (PT-129).

## 10a. Native-callback-rate check — after every restart and every HomeKit-touching step (rule 11)

The feed age can look healthy while HomeKit notifications are lost (2026-10-03 incident). After every Prefab restart,
and after every step that touches HomeKit (a scene run, a trigger toggle, a test with production stopped), measure
the rate over the next hour:

```bash
L=~/Documents/homebase_debug.log      # Prefab recreates it at every start: take the mark AFTER the restart
P='/opt/homebrew/opt/postgresql@16/bin/psql -h 127.0.0.1 -U ericsmith66 eureka_production -At'
echo "mark $(date +%s) $(grep -a -c '\[NATIVE\]' "$L")"            # record both numbers: T0 N0
# … at least 55 minutes later, with the recorded T0 and N0:
T0=<recorded>; N0=<recorded>; T1=$(date +%s); N1=$(grep -a -c '\[NATIVE\]' "$L")
echo "native/h = $(( (N1 - N0) * 3600 / (T1 - T0) ))"                                   # → ≥ 300
$P -c "select count(*) from homekit_events where created_at >= (now() at time zone 'UTC') - interval '60 minutes'"   # → ≥ 300
$P -c "select count(*) from homekit_events where created_at >= (now() at time zone 'UTC') - interval '25 hours' and created_at < (now() at time zone 'UTC') - interval '24 hours'"   # same hour yesterday
```

- **Pass (08:00–22:00):** both numbers ≥ 300 — half of the 2026-10-06 baseline (≈ 600 events an hour; ≈ 560
  `[NATIVE]` lines an hour).
- **Pass (22:00–08:00):** both numbers ≥ 110 (half of the quietest hour measured on 2026-10-06, 222) **and** both
  ≥ 50 % of the same hour yesterday. A dead hour yesterday is never a baseline.
- **Fail:** tell Eric. A Prefab restart (`prefab_stop`, bootstrap, `prefab_start_check`) is the known fix when reads
  work but notifications are gone. The watchdog (§ 15) alerts only below 60 events an hour; it cannot see a partial
  loss.

## 11. TCC (`kTCCServiceWillow`)

- The HomeKit grant is the `kTCCServiceWillow` row for `com.ericsmith66.prefab` in the user TCC database. It is keyed by
  bundle id with `csreq` NULL, so it is expected to survive the CDHash change; tccd may write a requirement on first
  use — always re-read and record `typeof(csreq)`.
- Before the swap: `cp "$HOME/Library/Application Support/com.apple.TCC/TCC.db" "$HOME/Library/Application Support/com.apple.TCC/TCC.db.bak-<date>"`.
- Query (before step 14 and after step 17):
  `sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" "select auth_value, typeof(csreq) from access where service='kTCCServiceWillow' and client='com.ericsmith66.prefab'"`
  → `2|null` (or `2|blob` — record which).
- `GET /homes` must answer 200, not 403. If 403: re-grant by copying the granted row (the 2026-06-05 procedure: the
  `kTCCServiceWillow` row copied from m3ultra's TCC.db; `.253` is headless, so the consent prompt can never present),
  then `prefab_stop`, bootstrap, `prefab_start_check`. Restoring `TCC.db.bak-<date>` is Eric's explicit call only.

## 12. Webhook token (D1)

`W` is shared by Prefab `config.json webhook.authToken` (sent as `Authorization: Bearer W`) and Rails
`credentials.prefab_webhook_token`. It is generated into a 0600 file, applied to both sides, and the file is removed.

```bash
( umask 077; openssl rand -hex 32 > ~/.prefab_webhook_token )
python3 -c 'import json,os; p=os.path.expanduser("~/Library/Application Support/Prefab/config.json"); c=json.load(open(p)); c["webhook"]["authToken"]=open(os.path.expanduser("~/.prefab_webhook_token")).read().strip(); json.dump(c, open(p,"w"), indent=2, sort_keys=True); print(sorted(c["webhook"].keys()))'
chmod 600 "$HOME/Library/Application Support/Prefab/config.json"; ls -l "$HOME/Library/Application Support/Prefab/config.json"
# step 17: KEY=prefab_webhook_token VALUE_FILE=$HOME/.prefab_webhook_token VISUAL= EDITOR=$HOME/append-cred.sh bin/rails credentials:edit && rm -P ~/.prefab_webhook_token
```

Prefab reads the config at launch, so the token takes effect with the next start. If the two values ever differ, every
webhook answers 401 and the feed dies (watchdog P0 within 30 min): recreate the file from the credential
(`umask 077; bin/rails runner 'print Rails.application.credentials.prefab_webhook_token' > ~/.prefab_webhook_token`),
re-apply the python above, then `prefab_stop`, bootstrap, `prefab_start_check`.

## 13. Rollback

- **Bundle:** `prefab_stop; rm -rf ~/Applications/Server/Prefab.app; mv ~/Applications/Server/Prefab.app.prev-<date>
  ~/Applications/Server/Prefab.app; launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.ericsmith66.prefab.plist;
  prefab_start_check` → expect the OLD binary: `/version` 404, `/homes` 200.
- **PR 1b + credential:** plan § 15.10 step 17 rollback (PR 1a merge checked out detached, `remove-cred.sh` for
  `prefab_webhook_token`, `credentials_ok`, one kickstart).
- **Config:** `cp -p "…/config.json.bak-<date>" "…/config.json" && chmod 600 "…/config.json"`.
- **Whole window:** all three, then `/homes` 200 and feed age `< 120` confirmed; the point of failure goes into the task
  log. The re-key (steps 21–22) runs only after a window that ended green.
- **S″ → S′** (the S″ window's whole-window rollback — plan § 15.18 R7-15 as amended by § 15.19 R8-8; any time after
  W4; each line with Eric's yes; § 18.1's preamble first):
  ```bash
  prefab_stop
  rm -rf ~/Applications/Server/Prefab.app && mv ~/Applications/Server/Prefab.app.prev-s1-<date> ~/Applications/Server/Prefab.app
  [ "$(md5 -q "$CFG")" = "<W3 md5>" ] || cp -p "$CFG.bak-<date>-s2" "$CFG"        # S″ never writes the config: restore only if it changed
  rm -f "$FLAG"
  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.ericsmith66.prefab.plist; prefab_start_check      # → /version git_sha b2ca6d3…
  s2_identity b2ca6d35801107019489eb0d4d4d94018eee3af8 876f1e2f3b3c1dc098af276ed61dd0668927fbcb 7fd0c015becce5f4e050b9fd884ad511452d20b2f9083e700c189d0ab84fe3e4
  grep -a -m1 'Polling: 0 accessories, enabled: false' "$DLOG"                     # S′'s line
  s2_rate_mark                                                                     # then s2_rate_check after ≥ 55 min
  ```
  If the trigger proof's T1 ran, Eric disables `skynet test automation` in the Home app (S4). Rails PR 1e stays (it
  works with S′: S′ ignores `?read=cache`). A rollback resets the O27 reference: S′'s line applies until the next S″ start.

## 13a. Polling must stay OFF (production config) — 2026-10-02 incident

Production `~/Library/Application Support/Prefab/config.json` keeps **`"polling": {"enabled": false, …}`**.

- **Why:** when every HomeKit notification subscription succeeds (the normal case: "277 accessories, 277 delegates"),
  `HomeBase.homeManagerDidUpdateHomes` falls back to `startPollingAllDelegateAccessories()` — it re-reads EVERY readable
  characteristic of ALL accessories every `intervalSeconds` (15). On 2026-10-02 that load (~800 reads per tick on one
  bridge) swamped the Lutron RA3 processor's own HomeKit bridge: its reads timed out and the Lutron lights showed
  "No Response" in Apple Home. Switching polling off (backup `config.json.bak-20261002-203636-polling`) fixed it at once.
- **Check after any restart:** the debug log's startup lines must read `Polling: 0 accessories, enabled: false`
  (until Prefab `S″`; from `S″` on the line is `Polling: mode=failed-only enabled=false …`, plan § 15.18 R7-7), **and**
  the native-callback rate must pass § 10a.
- **Never** restore a config backup from before 2026-10-02 without flipping `polling.enabled` back to `false`.
- **Durable fix: built in Prefab S″ (§ 18).** Only characteristics whose subscription FAILED are polled, at most
  `polling.maxReadsPerMinutePerBridge` (default 6) reads a minute per bridge with one read in flight per bridge;
  poll-all is deleted, and an undecodable config can no longer fall back to a polling default. Until S″ runs on `.253`,
  S′'s poll-all code is still there and this flag is the only guard. After S″ the flag stays off (Eric's call).

## 14. Interim dependency: display-awake

`.253` is headless; when its (virtual) display sleeps, Prefab's HomeKit layer freezes while its HTTP server keeps
answering (root cause 2026-09-18). The recorded interim fix is LaunchAgent `ai.agentforge.prefab-display-awake`
(`~/Library/LaunchAgents/ai.agentforge.prefab-display-awake.plist`, `/usr/bin/caffeinate -d`, KeepAlive, Aqua). Check:
`launchctl print gui/$(id -u)/ai.agentforge.prefab-display-awake | grep state` → `running`. Removal (only on Eric's word,
once the root cause is fixed in Prefab): `launchctl bootout gui/$(id -u)/ai.agentforge.prefab-display-awake`, then
delete the plist.

## 15. Watchdog

`ai.agentforge.homekit-feed-check` runs every 10 min (log `~/Library/Logs/homekit-feed-check.log`). It raises **P0
DEAD** when the newest `homekit_events` row is older than 30 min and, since 2026-10-06, **P0 DEGRADED** when fewer than
60 events arrived in the last 60 minutes (once per episode, P1 on recovery). Script
`~/Development/scripts/homekit-feed-check.sh`, md5 `eb6eb92c8325964807a1e5a5204ff36a` (backup `.bak-20261006`). It is
never disabled during a window; a window longer than 25 min produces one real P0 and one P1 recovery — acknowledge
them in the task log, never silence them. It cannot see a partial loss above 60 events an hour: use § 10a for that.

## 16. Bonjour check (no `timeout` on macOS)

`dns-sd -B _prefab._tcp . & sleep 10; kill $!` → no line containing `nextgen` once the new binary runs (O16).

## 17. Off-box-caller check (P12 precondition; manual steps 2–3)

```bash
grep -rilE "8080|prefab" ~/Development/scripts ~/.openclaw/skills ~/.openclaw/openclaw.json ~/Library/LaunchAgents ~/Applications/Server/run-eureka.sh
for i in 1 2 3; do lsof -nP -iTCP:8080 -sTCP:ESTABLISHED | awk 'NR>1{print $9}'; sleep 20; done
```

Expected: hits only in `com.ericsmith66.prefab.plist`, `ai.agentforge.prefab-display-awake.plist` and
`homekit-feed-check.sh` (a comment) — none an off-box caller; the on-box `prefab` CLI talks `localhost:8080`; every
ESTABLISHED peer is `127.0.0.1` or `[::1]`. **Result: PENDING — recorded here at window prep** (date, hit list, peers).
An off-box caller → stop: the P12 precondition fails; ask Eric.

## 18. Prefab S″ and later (plan § 15.18 R7-3…R7-9, R7-16; § 15.19 R8-2…R8-7)

Until the S″ window this section describes the build, not production: S′ (§ 5) runs on `.253`. `S2` = the 40-hex
commit S″ is built from (the tip of prefab `epic-1/prd-07-scene-judgment-scheduler`; recorded in the task log). No Debug
build (D-3) and no scratch launch is made for S″ (rule 11; plan R7-9 item 5).

**What S″ changes (one restart — the plan's R7-15 window).**
- **F-1 fixed (R8-5 branch 1):** the HTTP server runs on BSD sockets (`PrefabHTTP.makeApplication` on
  `MultiThreadedEventLoopGroup.singleton`) instead of Network.framework, with the same bind, port, routes and
  middleware. Reproduced hostless before the fix: on Network.framework 1/200 and 46/200 `Connection: close` requests got
  a response; on BSD sockets 200/200. hummingbird-core logs once that BSD sockets on iOS are "not recommended"
  (harmless on a Mac). § 1's keep-alive rule stays until W8.
- **Failed-only polling** (§ 13a's durable fix) — the lines and the decision below.
- **Config safety:** an existing `config.json` that does not decode → exit 2 at launch, the file never overwritten; a
  missing file → the default is written, now with `polling.enabled: false`. New optional key
  `polling.maxReadsPerMinutePerBridge` (missing → 6; clamped to 1…30).
- **Full-detail reads are HomeKit's cache by default** — the table below. Rails PR 1e (`HomekitRekey` asks for
  `?read=cache`; name-route read-backs are `readback_unverifiable`) must be live BEFORE the swap (W2 before W4).
- **Strict bool:** `GetValue(_, "bool")` accepts only `1/0/true/false/on/off` (any case); anything else → 400
  `{"error":"bad_value","format":"bool"}`, nothing written. Rails sends `"true"`/`"false"`.
- **403 body:** unchanged, except that a Debug build forced by `PREFAB_FORCE_UNAUTHORIZED` adds `"cause"`.
- **Webhook sender:** unchanged (fire-and-forget, as S′). The ordered retry is a deferred carry (plan R8-7 item 7).
- **Release without coverage instrumentation:** `Prefab.xctestplan`'s `defaultOptions` say `"codeCoverage" : false`
  (`xcodebuild build` takes the scheme's test-plan coverage: S′'s Release had 10,078 `___profc_` symbols; Xcode 26.2
  refuses `-enableCodeCoverage NO` outside testing). `build-release.sh` runs `scripts/parity-checks.sh` on the product: the
  D-2 record gains `coverage symbols (___profc_): 0`, `coverage sections (__llvm_prf_cnts): 0`,
  `debug switch strings: 0`, and any failure (`coverage-instrumented`, `nm-failed`, `debug-switch-strings`) → exit 3.
  P5 runs the same script on m3ultra, on a copy of the binary under a neutral name (never on `.253`):
  `scripts/parity-checks.sh --binary <copy>` → `checks:  all passed`, exit 0.

**O27 — the polling lines S″ prints** (written by `logToFile`, so each one starts with `[<ISO-8601 UTC>] ` in
`~/Documents/homebase_debug.log`; `logging.enabled` must stay true):
1. **Startup, exactly once per start**, when every subscription completion is in, or 60 s after setup:
   `Polling: mode=failed-only enabled=<true|false> subscriptions=<N> ok=<S> failed=<F> pending=<P> excluded=<X> polled=<C> bridges=<B> limit=<L>/min/bridge`
   — `N = S + F + P`; `excluded` = failed subscriptions whose accessory `deviceRegistry` excludes (computed with polling
   on or off), `X ≤ F`; polling off → `polled=0 bridges=0`; on → `polled = F − X`; `bridges ≤ polled`, and 0 exactly
   when `polled` is 0; `1 ≤ L ≤ 30`.
   Production (polling off): `Polling: mode=failed-only enabled=false subscriptions=<N> ok=<S> failed=<F> pending=<P> excluded=<X> polled=0 bridges=0 limit=6/min/bridge`.
   The first S″ start's `<N>` is the reference (`N_REF`); a later start more than 5 % away is reported to Eric.
2. **Change line** — only after the startup line, only when the set of failed subscriptions changes:
   `Polling: changed failed=<F> pending=<P> polled=<C> bridges=<B>`
3. **Clamp line** — only for a limit outside 1…30, once: `Polling: limit <raw> outside 1..30, using <L>`
4. **Read-state lines** — polling on only, on a change of state: `Polling: read failing <accessory> / <characteristic> code=<n>`
   (`code=-1` = no answer within 30 s) and `Polling: read ok again <accessory> / <characteristic>`
5. **Never again:** `Starting polling for …` (poll-all) and S′'s `Polling: <n> accessories, enabled: …`.

**The polling decision [Eric-pending — default: OFF].** The S″ window does not touch `polling.enabled: false`: with
every subscription succeeding (0 `Notification failed` lines since 2026-10-05) failed-only polling would read nothing,
and each start now measures `failed` anyway. If a start shows `failed>0`, Eric decides. Turning it on: back up
`config.json`, set `polling.enabled` to `true`, restart with his yes (§ 10's `prefab_stop`, bootstrap,
`prefab_start_check`), `s2_restart_check …` (it then expects `enabled=true`, `polled = failed − excluded`), and
`s2_rate_check` at least 55 minutes later. A subscription that failed is retried only by a restart: Prefab subscribes
at startup and for added accessories, and has no reachability handler yet (a carry for a later build).

**Full-detail read modes** (`GET /accessories/:home/id/:uuid` and the name route `GET /accessories/:home/:room/:accessory`):

| Query | Device reads | Response |
|---|---|---|
| none, or `?read=cache` | none: HomeKit's cached values (`value: ""` = HomeKit holds none) | the detail + `"values":"cache"` |
| `?read=live` | one `readValue` per characteristic, 12 s guard (504 `read_timeout`) | the detail + `"values":"live"`, `"readErrors":<failed reads>`; one `[readAll] <accessory uuid> readValue x<n>` line |
| `?characteristic=<uuid>` (id route only) | exactly one `readValue`, 5 s guard | the single-characteristic read, unchanged — the only read that verifies a write |
| any other `read` value, or `read` with `characteristic` | none | 400 `{"error":"bad_request","what":"read"}` |

A guard that expires logs `[readAll] <accessory uuid> → 504 read_timeout` or `[readOne] <characteristic uuid> → 504
read_timeout`. List, room and summary items are unchanged (no `values`). From S″ on, § 10's step 20b measures nothing
(cached reads); a live check uses `?read=live`, one accessory at a time.

**Prefab relaunches every ~10 s and `/version` never answers** — an undecodable config (S″ exits 2; the LaunchAgent's
`KeepAlive` with `open -W` relaunches it, and stderr is never seen):
`log show --last 5m --style compact --predicate 'process == "Prefab"' | grep -m3 'prefab: invalid'` names the reason.
Then `prefab_stop` (bootout ends the loop), fix the config or restore the newest backup (Eric's call), bootstrap and
`prefab_start_check`. In the S″ window this is W6's rollback cell: no `/version` within 30 s → the whole-window rollback (§ 13).

### 18.1 The restart check — every Prefab restart from S″ on (plan § 15.19 R8-4)

Every restart — the S″ window, PRD-1-05's N1 drill, PRD-1-08's `apply[all]`, PRD-1-09's E-8 drill, any incident fix —
runs `s2_restart_check "$S2" "$S2CD" "$S2SHA" "$N_REF"` and, at least 55 minutes later, `s2_rate_check <mark epoch> <mark
count>`. Every block starts with this preamble (bash on `.253`, never zsh). `S2`, `E1`, `PUMA0` and `N_REF` are edited
at its top, never carried in a shell.

```bash
# R8-16 preamble — REPLACES R7-16's preamble. bash on .253 (ssh nextgen 'bash -s' < block, or `bash` after ssh). Never zsh.
cd ~/Development/legion/projects/eureka-homekit
export PATH="$HOME/.rbenv/shims:/opt/homebrew/bin:/opt/homebrew/opt/postgresql@16/bin:$PATH"; export RAILS_ENV=production
# --- the four values carried between blocks (PC-13): edit them here, never rely on an earlier shell ---
S2=""        # the 40-hex S2 from the task log
E1=""        # PR 1e's merge commit (P2)
PUMA0=""     # Puma's pid printed at W1 by `puma_pid` (PC-10)
N_REF=""     # W7's `subscriptions=<N>` (PC-2); empty until W7
S2REC=$HOME/Library/Developer/Xcode/DerivedData/prefab-${S2:0:12}-Release.parity.txt
S2CD=$(sed -n 's/^CDHash: //p' "$S2REC" 2>/dev/null); S2SHA=$(sed -n 's/^sha256 Contents\/MacOS\/Prefab: //p' "$S2REC" 2>/dev/null)
P='/opt/homebrew/opt/postgresql@16/bin/psql -h 127.0.0.1 -U ericsmith66 eureka_production -At'
ro() { PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=60s' $P "$@"; }      # read-only psql
AGE="select extract(epoch from (now() at time zone 'UTC') - max(created_at))::int from homekit_events"
EV60="select count(*) from homekit_events where created_at >= (now() at time zone 'UTC') - interval '60 minutes'"
EV10="select count(*) from homekit_events where created_at >= (now() at time zone 'UTC') - interval '10 minutes'"
EVY="select count(*) from homekit_events where created_at >= (now() at time zone 'UTC') - interval '25 hours' and created_at < (now() at time zone 'UTC') - interval '24 hours'"
PP='/Users/ericsmith66/Applications/Server/Prefab.app/Contents/MacOS/Prefab'
PNAME=${PNAME:-Prefab}   # the process name rule 11 counts; tests set a neutral name (PC-23), never "Prefab"
DLOG="$HOME/Documents/homebase_debug.log"
CFG="$HOME/Library/Application Support/Prefab/config.json"
FLAG="$HOME/Library/Application Support/Prefab/triggers-write-enabled"
prefab_stop() {   # R6-2: bootout stops only the `open -W` waiter; Hummingbird traps the first SIGTERM (HTTP only)
  launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.ericsmith66.prefab.plist    # first, so KeepAlive cannot relaunch
  local t0=$(date +%s) by=none i
  pkill -TERM -f "$PP"; for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$PP" >/dev/null || { by="first TERM"; break; }; sleep 1; done
  if pgrep -f "$PP" >/dev/null; then
    pkill -TERM -f "$PP"; for i in 1 2 3 4 5; do pgrep -f "$PP" >/dev/null || { by="second TERM"; break; }; sleep 1; done
  fi
  if pgrep -f "$PP" >/dev/null; then
    pkill -KILL -f "$PP"; for i in 1 2 3; do pgrep -f "$PP" >/dev/null || { by=KILL; break; }; sleep 1; done
  fi
  pgrep -fl "$PP" && { echo "STOP: Prefab still running after KILL"; return 1; }
  echo "prefab stopped (ended by $by after $(( $(date +%s) - t0 ))s)"   # expected: second TERM after ~10-11 s
}
prefab_count()     { pgrep -f "$PP" | wc -l | tr -d ' '; }        # at the production path
prefab_count_any() { pgrep -x "$PNAME" | wc -l | tr -d ' '; }     # PC-3: any process with that name, any path (the CLI is lowercase `prefab`)
prefab_start_check() {   # after every bootstrap: exactly ONE Prefab anywhere, then /version
  local i; for i in $(seq 1 20); do [ "$(prefab_count)" = 1 ] && break; sleep 1; done
  pgrep -lx "$PNAME"
  [ "$(prefab_count)" = 1 ] && [ "$(prefab_count_any)" = 1 ] || { echo "STOP: $(prefab_count) at the production path, $(prefab_count_any) named $PNAME"; return 1; }
  sleep 5; curl -s -m 5 -w '\n%{http_code}\n' 127.0.0.1:8080/version
}
s2_identity() {   # (3) /version + (4) CDHash and sha256 of the running bundle. Args: <git_sha> <CDHash> <sha256>
  local v c s
  [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] || { echo "FAIL identity: an expected value is empty (set S2 in the preamble)"; return 1; }
  v=$(curl -s -m 5 127.0.0.1:8080/version | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["git_sha"], d["bind"], d["bonjour"])')
  c=$(codesign -dvvv ~/Applications/Server/Prefab.app 2>&1 | sed -n 's/^CDHash=//p')
  s=$(shasum -a 256 "$PP" | cut -c1-64)
  echo "version: $v"; echo "CDHash: $c"; echo "sha256: $s"
  if [ "$v" = "$1 127.0.0.1:8080 False" ] && [ "$c" = "$2" ] && [ "$s" = "$3" ]; then echo "PASS identity"; else echo "FAIL identity"; return 1; fi
}
s2_polling_check() {   # (1) O27. Args: [<reference N>]. Exactly one S″ startup line, its rules, no S′ or poll-all line (PC-2)
  local line n
  n=$(grep -a -c 'Polling: mode=failed-only' "$DLOG")
  [ "$n" = 1 ] || { echo "FAIL: expected exactly one S″ polling line, found $n"; return 1; }
  line=$(grep -a -m1 'Polling: mode=failed-only' "$DLOG")
  printf '%s\n' "$line"
  printf '%s\n' "$line" | REF="${1:-}" python3 -c '
import os, re, sys
s = sys.stdin.read().strip()
m = re.fullmatch(r"\[[0-9T:.+Z-]+\] Polling: mode=failed-only enabled=(true|false) subscriptions=(\d+) ok=(\d+) failed=(\d+) pending=(\d+) excluded=(\d+) polled=(\d+) bridges=(\d+) limit=(\d+)/min/bridge", s)
if not m:
    print("FAIL: the line does not match O27"); sys.exit(1)
en = m.group(1); n, ok, f, p, x, c, b, lim = (int(g) for g in m.groups()[1:])
bad = []
if ok + f + p != n: bad.append("ok+failed+pending != subscriptions")
if x > f: bad.append("excluded > failed")
if en == "false" and (c, b) != (0, 0): bad.append("polling off but polled/bridges not 0")
if en == "true" and c != f - x: bad.append("polled != failed - excluded")
if en == "true" and not (b <= c and (b == 0) == (c == 0)): bad.append("bridges inconsistent with polled")
if not 1 <= lim <= 30: bad.append("limit outside 1..30")
if bad:
    print("FAIL: " + "; ".join(bad)); sys.exit(1)
print("PASS polling line (enabled=%s subscriptions=%d ok=%d failed=%d pending=%d polled=%d)" % (en, n, ok, f, p, c))
ref = os.environ.get("REF", "")
if ref and (abs(n - int(ref)) * 20 > int(ref) or abs(ok - int(ref)) * 20 > int(ref)):
    print("REPORT TO ERIC: subscriptions/ok more than 5 %% away from the reference %s" % ref); sys.exit(3)
' || return $?
  [ "$(grep -a -c 'Starting polling for' "$DLOG")" = 0 ] || { echo "FAIL: the poll-all line is present"; return 1; }
  [ "$(grep -a -c -E 'Polling: [0-9]+ accessories, enabled:' "$DLOG")" = 0 ] || { echo "FAIL: an S′ polling line is present"; return 1; }
}
s2_rate_mark() { echo "rate mark: $(date +%s) $(grep -a -c '\[NATIVE\]' "$DLOG")  events_60m=$(ro -c "$EV60")"; }   # record the two numbers
s2_rate_check() {   # (2) args: <mark epoch> <mark count>. Mark AFTER the restart: the log restarts at every Prefab start (PC-1)
  local t0=$1 n0=$2 t1 n1 rate ev evy h
  t1=$(date +%s); n1=$(grep -a -c '\[NATIVE\]' "$DLOG"); h=${S2_HOUR:-$(date +%H)}; h=$((10#$h))
  [ $((t1 - t0)) -ge 3300 ] || { echo "WAIT: only $(( (t1 - t0) / 60 )) min since the mark"; return 2; }
  [ "$n1" -ge "$n0" ] || { echo "FAIL rate: the debug log restarted after the mark ($n1 < $n0); take a new mark"; return 1; }
  rate=$(( (n1 - n0) * 3600 / (t1 - t0) )); ev=$(ro -c "$EV60"); evy=$(ro -c "$EVY")
  echo "native/h=$rate events_60m=$ev same_hour_yesterday=$evy hour=$h over $(( (t1 - t0) / 60 )) min"
  if [ "$rate" -ge 300 ] && [ "$ev" -ge 300 ]; then echo "PASS rate (both >= 300)"; return 0; fi
  if [ "$h" -ge 8 ] && [ "$h" -lt 22 ]; then echo "FAIL rate (08:00-22:00: both must be >= 300)"; return 1; fi
  if [ "$rate" -ge 110 ] && [ "$ev" -ge 110 ] && [ $((rate * 2)) -ge "$evy" ] && [ $((ev * 2)) -ge "$evy" ]; then
    echo "PASS rate (night rule: both >= 110 and >= 50 % of the same hour yesterday)"; return 0
  fi
  echo "FAIL rate"; return 1
}
lutron_unreachable() {   # the Lutron Processor (2)'s bridged accessories: the count and the sorted unreachable set (PC-18b)
  curl -s 127.0.0.1:8080/accessories/Waverly | python3 -c 'import json, sys
d = json.load(sys.stdin); p = {a["uniqueIdentifier"] for a in d if a.get("name") == "Lutron Processor (2)"}
b = [a for a in d if a.get("bridgedBy") in p]; u = sorted(a["uniqueIdentifier"] for a in b if a.get("isReachable") is False)
print("lutron_bridge=%d bridged=%d unreachable=%d %s" % (len(p), len(b), len(u), ",".join(u) or "-"))'
}
f1_check() {   # F-1 — S′ (and R8-6 branches 2-4): 200 / 000 rc=52 / 000 rc=52; branch 1: 200 rc=0 three times
  curl -s -m 5 -o /dev/null -w 'plain            http=%{http_code}' 127.0.0.1:8080/version; echo " rc=$?"
  curl -s -m 5 -o /dev/null -w 'Connection:close http=%{http_code}' -H 'Connection: close' 127.0.0.1:8080/version; echo " rc=$?"
  curl -s -m 5 -o /dev/null -w 'HTTP/1.0         http=%{http_code}' -0 127.0.0.1:8080/version; echo " rc=$?"
}
webhook_401s() {   # PC-16: 401s answered to the webhook path in the last 20,000 lines (Rails tags Started/Completed by request id)
  tail -n 20000 "${RLOG:-log/production_server.log}" | awk 'match($0, /^\[[0-9a-f-]+\]/) { id = substr($0, RSTART, RLENGTH) } /Started POST "\/api\/homekit\/events"/ { ev[id] = 1 } /Completed 401/ && (id in ev) { n++ } END { print n + 0 }'
}
puma_pid() { launchctl print gui/$(id -u)/com.ericsmith66.eureka | awk '/^[[:space:]]*pid = / { print $3; exit }'; }   # PC-10
pr1e_live_check() {   # PC-10: W4's precondition — PR 1e on disk, Puma restarted since W1, the new code loads
  [ -n "$E1" ] && [ -n "$PUMA0" ] || { echo "STOP: set E1 and PUMA0 in the preamble first"; return 1; }
  if [ "$(git rev-parse HEAD)" = "$E1" ] && [ "$(puma_pid)" != "$PUMA0" ] \
     && [ "$(bin/rails runner 'p PrefabClient.respond_to?(:accessory_structure)' 2>/dev/null)" = true ]; then echo pr1e-live; return 0; fi
  echo "STOP: PR 1e is not live in Puma — no W4"; return 1
}
s2_restart_check() {   # THE restart check. Args: <git_sha> <CDHash> <sha256> [<reference N>]. Then s2_rate_check >= 55 min later
  local i rc
  echo "instances: path=$(prefab_count) any=$(prefab_count_any)"
  [ "$(prefab_count)" = 1 ] && [ "$(prefab_count_any)" = 1 ] || { echo "FAIL: not exactly one Prefab"; return 1; }
  s2_identity "$1" "$2" "$3" || return 1
  for i in $(seq 1 45); do grep -a -q 'Polling: mode=failed-only' "$DLOG" && break; sleep 2; done
  s2_polling_check "${4:-}"; rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 3 ] || return 1          # rc 3 = report to Eric and continue
  s2_rate_mark; echo "feed age: $(ro -c "$AGE") s"
}
```

**The quote every later restart check uses:** "`s2_restart_check <git_sha> <CDHash> <sha256> <N_REF>` passes: one Prefab at the production path and one named `Prefab` anywhere; `s2_identity` passes; the debug log has **exactly one** `Polling: mode=failed-only` line, and it passes `s2_polling_check` — with polling off (production's default) it reads `Polling: mode=failed-only enabled=false subscriptions=<N> ok=<S> failed=<F> pending=<P> excluded=<X> polled=0 bridges=0 limit=6/min/bridge` with `S + F + P = N`; a result more than 5 % from `N_REF` is reported to Eric. There is no `Starting polling for` line and no S′ polling line. `s2_rate_check` passes at least 55 minutes later. 'The failed-only count' in PRD-1-05, 1-07 and 1-09 is the line's `polled`: 0 with polling off; with polling on, each bridge gets at most `limit` reads a minute (PT-143, PT-144)."

**Tested on fixtures, never on `.253`** (PT-165): `scripts/test-restart-checks.sh` on m3ultra extracts the block above
from this file and runs every PASS/FAIL/WAIT path of `s2_rate_check`, `s2_polling_check`, `prefab_start_check`,
`s2_identity`, `s2_restart_check`, `webhook_401s`, `lutron_unreachable`, `f1_check` and `pr1e_live_check` against
fixture logs, with `pgrep`, `curl`, `codesign`, `shasum`, `git`, `launchctl`, `date`, `sleep`, `bin/rails` and `ro`
stubbed. No process is started, nothing is named `Prefab`, nothing is created under a `.app` folder.

**Test stubs (plan R8-2 — binding on any Mac, for every implementer and QA run).** Never an executable, script or
symlink named `Prefab`; nothing under a directory whose name ends in `.app`, and never the production bundle layout;
no `open`, LaunchServices or `lsregister` for a stub. Instance checks are tested with a stubbed `pgrep`. A test that
can only work with the real `Prefab.app/Contents/MacOS/Prefab` layout is not run; it goes to QA as a finding.

## 19. Trigger routes and the write flag (PRD-1-07 Track A; in Prefab S″)

**The operator text of record is skynet-mcp `docs/OPERATIONS.md`, section "Prefab trigger routes (PRD-1-07 Track A;
shipped in Prefab S″)"** (branch `epic-1/prd-07-scene-judgment-scheduler`): the routes, their answers, when the flag may
exist, who calls it, the log lines and the accepted gap. In short:

- `GET /triggers/<home>` — read-only; every HomeKit automation from memory (no device reads), with `write_enabled`.
- `PUT /triggers/<home>/<trigger uuid>/enabled` with `{"enabled": true}` or `{"enabled": false}` — `HMTrigger.enable`,
  4 s guard (504 = the outcome is unknown: GET to see). Only while the flag exists; without it
  `403 {"error":"triggers_write_disabled"}` and nothing is sent to HomeKit. No other trigger mutation exists.
- `POST /scenes/<home>/<uuid>/execute` on an action set that belongs ONLY to an automation (a trigger-owned set) needs the
  same flag; a set HomeKit also lists among the home's scenes does not (it was executable before S″).
- **The flag:** `/Users/ericsmith66/Library/Application Support/Prefab/triggers-write-enabled` — a regular file (not a
  symlink), owner `ericsmith66`, mode `600`; checked on every request, so no restart. **Only with Eric's go:** the FR-07-A4
  proof window and PRD-1-08's drills (removed after each), and permanently from just before PRD-1-08's `apply[all]`.

```bash
F="$HOME/Library/Application Support/Prefab/triggers-write-enabled"
( umask 077; printf '%s, %s, Eric present\n' "<why>" "$(date +%F)" > "$F" ); ls -l "$F"     # create → -rw-------  ericsmith66
rm "$F"                                                                                         # remove
curl -s 127.0.0.1:8080/triggers/Waverly | python3 -c 'import json,sys; print(json.load(sys.stdin)["write_enabled"])'   # check
```

- **Log lines** (`~/Documents/homebase_debug.log`): one per PUT,
  `[triggers] <request> PUT <uuid> enabled=<true|false|?> → <status> <ok|error>[ (<reason>)]` — the reason (absent,
  symlink, not_regular_file, owner, mode) only on the flag's 403; `[triggers] <request> <uuid> Attempting enable=<b>`
  right before a real HomeKit call; and one per execute, `[executeScene] <request> <uuid> → <status> <ok|error>`.
- **After every toggle or execute:** the native-callback rate for the next hour (§ 10a; `s2_rate_check` in § 18.1).
- The S″ window's read-only proof is W11 and the refused PUT W12; the toggle proof (T0–T9) needs Eric's separate go
  (PRD-1-01 plan § 15.18 R7-15 with § 15.19 R8-8).
