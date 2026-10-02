# Prefab on nextgen (.253) — runbook

Operator runbook for the Prefab HomeKit bridge on `.253` (FR-A9 of skynet-mcp PRD-1-01). The normative step list is
the PRD-1-01 implementation plan in `ericsmith66/skynet-mcp` (`knowledge_base/epics/backlog/1-Skynet-MCP-Server/`):
§ 9 (build + parity) and § 10 (window) as amended by § 15.10, § 15.11, § 15.14 (R3) and § 15.15 (R4). Where this file
and the plan differ, the plan wins. Every state-changing step needs Eric's "yes" at the time it runs.

Placeholders: `S` = the pinned 40-hex commit that is built and deployed; `<repo>` = a clean checkout of `S` on `.253`
(the 2026-10-02 dry build used the scratch clone `~/tmp/prefab-prd01`; `~/Development/prefab` on `.253` is a secondary
clone and is left untouched — Eric, 2026-10-02); `<date>` = `$(date +%Y%m%d)` of the day the step runs.

## 1. Hosts & layout

- **nextgen = `.253`** (192.168.4.253), headless Mac Studio, user `ericsmith66`, reached from m3ultra as `ssh nextgen`.
  bash 3.2 + BSD userland: there is no `timeout` (use `perl -e 'alarm N; exec @ARGV' …`); never edit with BSD `sed`.
- **Bundle:** `~/Applications/Server/Prefab.app` (bundle id `com.ericsmith66.prefab`, Mac Catalyst).
- **LaunchAgent:** `~/Library/LaunchAgents/com.ericsmith66.prefab.plist`, label `com.ericsmith66.prefab`; it runs
  `/usr/bin/open -W ~/Applications/Server/Prefab.app` (Aqua session, KeepAlive). `launchctl bootout` stops only the
  `open -W` waiter — the app itself has its own pid and process group (PA-1), see `prefab_stop` in § 10.
- **HTTP:** `127.0.0.1:8080` only (P12); no Bonjour. Routes: `/version` (never behind the HomeKit auth check),
  `/homes`, `/rooms/:home[/:room]`, `/accessories/:home[/summary|/:room[/:accessory]|/id/:uuid[?characteristic=]]`,
  `/scenes/:home[/:scene[/execute]]`, `/groups/:home[/:group]`.
- **Config:** `~/Library/Application Support/Prefab/config.json` (mode 600 once it holds `webhook.authToken`).
  **Debug log:** `~/Documents/homebase_debug.log` (written only when `logging.enabled` is true; recreated at every
  start). Overrides, honoured by every build and reported by `/version`: `PREFAB_PORT` (1024–65535),
  `PREFAB_CONFIG_PATH`, `PREFAB_LOG_PATH` (absolute paths); a bad value exits 2 with `prefab: invalid <NAME>` on stderr.
  Debug builds only: `PREFAB_FORCE_UNAUTHORIZED=1`, `PREFAB_FAULT=write_failed|write_timeout` (release builds compile
  them out).
- **Timeouts (Prefab side of the ladder):** write 4 s → 504 `write_timeout`; scene 25 s → 504 `scene_timeout`;
  full-detail read 12 s → 504 `read_timeout`; single-characteristic read 5 s → 504 `read_timeout`.
  `/version.timeouts` reports them.
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
2. **Check out `S`** (D-1): `cd <repo> && perl -e 'alarm 60; exec @ARGV' git fetch origin </dev/null && git checkout -q
   epic-1/prd-01-lane-h-substrate && git merge --ff-only -q origin/epic-1/prd-01-lane-h-substrate && git status
   --porcelain && git rev-parse HEAD` → empty status; HEAD == `S`.
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

## 5. Parity record

One row per § 9 D-2 build — the record's `parity row:` line (`date | S | sha256 Contents/MacOS/Prefab | CDHash |
built_at | embedded profile UUID`). Rows are added by a docs-only commit made after D-2; that commit is never checked
out on `.253` before the window (`build-release.sh` and D-7 need HEAD == `S` there), so `S` is the built commit, not the
docs commit. At the window, step 15's CDHash after the copy and step 18's `/version.git_sha` must match the Release row.

**Release (deployable):**

| date | S | sha256 Contents/MacOS/Prefab | CDHash | built_at | profile |
|---|---|---|---|---|---|

**Debug (scratch launches only; `Contents/MacOS/Prefab` is Xcode's debug-dylib stub there):**

| date | S | sha256 Contents/MacOS/Prefab | CDHash | built_at | profile |
|---|---|---|---|---|---|

## 6. LaunchServices

- Production starts by path (`open -W ~/Applications/Server/Prefab.app`), so stray copies cannot hijack it. Nothing
  may open Prefab by bundle id (`open -b com.ericsmith66.prefab`, AppleScript `application id`, URL handlers).
- Xcode's `RegisterWithLaunchServices` step registers every product it builds, and `open` registers what it launches.
  `build-release.sh` unregisters its product right after the build. Unregister every other agent-made product once it is
  no longer needed: after the scratch launches `"$DBG/Prefab.app"`; after step 23d `/tmp/prefab-scratch/Prefab-release.app`
  (before the directory is removed); unsigned compile products.
- **Only ever `lsregister -u <agent-made path>`.** Never `-kill`, `-delete`, `-r` or `-R` scans; never on
  `~/Applications/Server/Prefab.app` or on Eric's older copies. Nothing at the window runs `lsregister`.

```bash
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
"$LSREG" -u "<agent-made product path>"
"$LSREG" -dump 2>/dev/null | awk '/^path:/{p=$0} /^identifier:[[:space:]]+com\.ericsmith66\.prefab$/{print p}' | sort -u   # read-only
```

On 2026-10-02 the dump listed five paths: `~/Applications/Server/Prefab.app` (production) and four older Xcode copies
of Eric's (`~/Library/Developer/Xcode/DerivedData/prefab-faptzqxnfvnxsleiymoahonhqebb/…`, two under
`/Volumes/ericsmith66/Library/Developer/Xcode/DerivedData/prefab-*/…`, and
`/Volumes/ericsmith66/development/legion/projects/prefab/build/Build/Products/Release-maccatalyst/Prefab.app`).

## 7. Scratch launch rules (O30; plan § 15.11 D-4/D-5 + R4-5)

- Every scratch launch sets **all three** overrides: `PREFAB_PORT=8081`, `PREFAB_CONFIG_PATH=/tmp/prefab-scratch/config.json`,
  `PREFAB_LOG_PATH=/tmp/prefab-scratch/homebase_debug.log`. Never the production config or log path: the binary reads
  its config and recreates its debug log before it parses the port.
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
- Exit-2 checks always carry the scratch paths; the numeric status comes from the helper (no HomeKit is needed):
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
| 5 | § 4 (D-1a, D-1, D-2, D-3), then the scratch launches of plan § 15.11 D-4/D-5 under § 7's rules — **each scratch launch only with Eric's word** | records `checks: all passed`; D-4: `/version` 200 with `bind:"127.0.0.1:8081"` + scratch paths, `/homes` 403; exit-2 lines rc 2; D-5 (1): 502 `write_failed` / 504 `write_timeout` with no `Attempting write` (BLOCKED if the debug instance answers 403 — ask Eric) |

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
prefab_stop() {                                    # PA-1: bootout stops only the `open -W` waiter
  launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.ericsmith66.prefab.plist    # first, so KeepAlive cannot relaunch
  pkill -TERM -f "$PP"; for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$PP" >/dev/null || break; sleep 1; done
  pgrep -f "$PP" >/dev/null && pkill -KILL -f "$PP"
  pgrep -fl "$PP" || echo "prefab stopped"
}
prefab_start_check() {                             # after every bootstrap: exactly one NEW pid, then /version
  sleep 10; pgrep -fl "$PP"
  curl -s -m 5 -w '\n%{http_code}\n' 127.0.0.1:8080/version   # new binary: 200 + git_sha == S · old binary: 404
}
```

| Step | Command | Expected | Rollback / if not |
|---|---|---|---|
| 11 | `git -C <repo> status --porcelain && git -C <repo> rev-parse HEAD`; D-7 (reuse the D-2 product if its record says `checks: all passed` and its `PrefabBuildInfo.plist` `GitSHA` is `S`); then the PR 1b fetch/ff/creds checks of plan § 15.10 step 11 | empty, `S`; `ff-ok`, `creds-untouched` | rebuild (§ 4.5) before T0 |
| 12 | parity row checked; `cp "$HOME/Library/Application Support/com.apple.TCC/TCC.db" "$HOME/Library/Application Support/com.apple.TCC/TCC.db.bak-<date>"`; the TCC query of § 11 | backup exists; `2\|…` recorded (before) | — |
| 13 | `curl -s 127.0.0.1:8080/accessories/Waverly \| python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'` → `N_before`; `tail -1 ~/Library/Logs/homekit-feed-check.log`; `$P -c "$AGE"` | recorded — **T0** | — |
| 14 | `prefab_stop` | `prefab stopped` | `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.ericsmith66.prefab.plist; prefab_start_check` (old binary: `/version` 404, `/homes` 200) |
| 15 | `mv ~/Applications/Server/Prefab.app ~/Applications/Server/Prefab.app.prev-<date> && cp -R ~/Library/Developer/Xcode/DerivedData/prefab-<S12>-Release/Build/Products/Release-maccatalyst/Prefab.app ~/Applications/Server/Prefab.app && codesign -dvvv ~/Applications/Server/Prefab.app 2>&1 \| grep -E '^CDHash'` (the source is the D-2 `.app` itself) | CDHash == the Release parity row | `rm -rf ~/Applications/Server/Prefab.app && mv ~/Applications/Server/Prefab.app.prev-<date> ~/Applications/Server/Prefab.app` |
| 16a | `cp -p "$HOME/Library/Application Support/Prefab/config.json" "$HOME/Library/Application Support/Prefab/config.json.bak-<date>"` | backup exists | — |
| 16 | webhook token, § 12 | `['authToken', 'enabled', 'url']`; `-rw-------` | `cp -p "…/config.json.bak-<date>" "…/config.json" && chmod 600 "…/config.json"` |
| 17 | credential + PR 1b + ONE Rails restart + Prefab start (plan § 15.10 step 17): `append-cred.sh` for `prefab_webhook_token`, `credentials_ok`, `git merge --ff-only "$B"`, `launchctl kickstart -k gui/$(id -u)/com.ericsmith66.eureka`, `/up` 200, then `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.ericsmith66.prefab.plist; prefab_start_check` | one NEW pid; `/version` 200 with `git_sha` == `S` | plan § 15.10 step 17 rollback (PR 1a merge checked out, credential removed, step 16 rollback, `prefab_stop`, bootstrap) |
| 18 | `curl -s 127.0.0.1:8080/version` (AC-01-01: `git_sha` `S`, `git_dirty` false, `bind` `127.0.0.1:8080`, `bonjour` false, production `config_path`/`debug_log`, `timeouts {4,25,12,5}`); `curl -s 127.0.0.1:8080/homes`; wait 3 min; `$P -c "$AGE"`; `tail -n 5000 log/production_server.log \| grep -c 'POST "/api/homekit/events".* 401'` | AC-01-01 JSON; `[{"name":"Waverly"}]`; age `< 120`; `0` | first `pgrep -fl "$PP"` + `/version` (an old instance answering 404 → `prefab_stop`, bootstrap, `prefab_start_check`); only then suspect a token mismatch (§ 12) |
| 19 | the TCC query of § 11 (after) | `2\|…` recorded | `/homes` 403 → re-grant (§ 11), `prefab_stop`, bootstrap, `prefab_start_check`, repeat 18 |
| 20 | the list check of plan § 15.10 step 20 (count = `N_before` + Default Room count, every item a `uniqueIdentifier`, a `room`, `bridgedBy` null or a Bridge); `lsof -nP -iTCP:8080 -sTCP:LISTEN`; § 16; watchdog and display-awake state | one `127.0.0.1:8080` listener; no `nextgen` Bonjour line; watchdog `ok`; display-awake `running` — **T1** | — |

Production `shasum -a 256 ~/Applications/Server/Prefab.app/Contents/MacOS/Prefab` and `codesign -dvvv` CDHash must equal
the Release parity row (D-8, AC-01-01).

**After the window:** re-key and live steps 21–29 (plan § 15.10 D; § 15.9). Prefab-only black-box checks there:
23 (`?characteristic=` read < 2 s, one `[readOne]` debug-log line), 23a (unknown `characteristicId` → 404
`what:characteristic`), 23b (unreachable accessory → 503 `unreachable`, no `Attempting write`), 23c (`value:"abc"` to a
`uint8` → 400 `bad_value`), 23d (post-window debug-log inode check + the release-copy scratch launch, AC-01-42).

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

## 14. Interim dependency: display-awake

`.253` is headless; when its (virtual) display sleeps, Prefab's HomeKit layer freezes while its HTTP server keeps
answering (root cause 2026-09-18). The recorded interim fix is LaunchAgent `ai.agentforge.prefab-display-awake`
(`~/Library/LaunchAgents/ai.agentforge.prefab-display-awake.plist`, `/usr/bin/caffeinate -d`, KeepAlive, Aqua). Check:
`launchctl print gui/$(id -u)/ai.agentforge.prefab-display-awake | grep state` → `running`. Removal (only on Eric's word,
once the root cause is fixed in Prefab): `launchctl bootout gui/$(id -u)/ai.agentforge.prefab-display-awake`, then
delete the plist.

## 15. Watchdog

`ai.agentforge.homekit-feed-check` runs every 10 min and raises P0 when the newest `homekit_events` row is older than
30 min (log `~/Library/Logs/homekit-feed-check.log`). It is never disabled during the window; a window longer than
25 min produces one real P0 and one P1 recovery — acknowledge them in the task log, never silence them.

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
