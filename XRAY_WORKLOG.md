# Xray dual-node worklog

Started 2026-11-17. Branch: xray-dual-node (to create).

## Plan
1. Kotlin bridge XrayBridge.kt + MainActivity channel `top.jtmonster.jhentai.xray` + libXray.aar in android/app/libs/
2. Dart: xray_setting.dart, xray_service.dart, register beans in main.dart
3. Wiring: JProxyType.xray appended, proxy_util, eh_request.currentProxyConfig, cookie_page _initDio igneous port 28781
4. UI: network setting page xray option + xray_page, routes, l18n
5. Workflows: build-xray-release.yml, sync-upstream.yml
6. Verify: flutter pub get / analyze / build apk
7. Commit to xray-dual-node, no push

## Status
- [x] read key files (CLAUDE.md, network_setting, proxy_util, eh_request, cookie_page, routes, upstream workflow, Nodyssey LibXrayBridge/XrayConfigFactory — node name = outbound tag from convertShareLinksToXrayJson)
- [x] kotlin bridge: XrayBridge.kt (org.json, ports 28780/28781, dual inbounds/outbounds/routing, testXray→stop→run), MainActivity channel `top.jtmonster.jhentai.xray` on single-thread executor, libXray.aar copied to android/app/libs/ (52MB, 4 ABIs), build.gradle implementation files('libs/libXray.aar')
- [x] dart setting/service: ConfigEnum.xraySetting added; xray_setting.dart (nodes/mainNodeIndex/igneousNodeIndex, index adjust on remove); xray_service.dart (Android-only, ever() listeners, serialized sync queue, status/running Rx); registered in main.dart (xraySetting after networkSetting, xrayService in services)
- [x] wiring: JProxyType.xray appended at end; proxy_util → SOCKS5 127.0.0.1:28780; DIRECT; eh_request.currentProxyConfig → socks5 127.0.0.1:28780; cookie_page _initDio gets IOHttpClientAdapter(createHttpClient:) — xray mode pins findProxy to SOCKS5 127.0.0.1:28781 with NO direct fallback, badCertificateCallback same allIPs rule (dio fork adapter signature still to verify after pub get)
- [x] UI: proxy page dropdown + xray item, address/user/pass disabled in xray mode, Xray nodes entry row when xray selected; new xray_page.dart (status, node list with main/igneous chips + popup menu set/delete, paste import, subscription URL import); route Routes.xrayNodes registered; l18n keys added to all 6 locales (en/zh_CN/zh_TW translated, ko/pt/ru English)
- [x] workflows: build-xray-release.yml (tags xray-* + dispatch, JDK17, Flutter 3.44.8 channel master like upstream, keystore secret or ephemeral fallback, split-per-abi, rename JHenTai-<ver>-xray-<abi>.apk, softprops release); sync-upstream.yml (cron 17 3 * * * UTC, merge upstream, push, tag xray-v<ver>-<date> with -N dedup, comment re build_publish side effect). Both YAML-validated.
- [x] AAR not in git (follow-up change): .gitignore `android/app/libs/libXray.aar`; CI downloads LibXray v26.10.31 zip from XTLS/LibXray release, verifies zip sha256 fb99f04a… and AAR sha256 4c90532f… before build
- [ ] build verify:
  - Flutter 3.44.8 installed at ~/tools/flutter (first download was truncated by proxy + resume corrupted it; full re-download sha256 matches official 672089e0…ace332d)
  - flutter pub get OK (200 packages)
  - dio fork IOHttpClientAdapter signature verified in pub cache: `IOHttpClientAdapter({onHttpClientCreate, createHttpClient, validateCertificate})`, exported via package:dio/io.dart — cookie_page usage matches
  - flutter analyze on all new/changed files: **0 errors**; 3 warnings all confirmed pre-existing via git stash comparison (eh_request unreachable_switch_default, cookie_page unused_catch_stack, network_setting unused_import); rest info-level
  - SDK quirk: sandbox SDK only has android-37.0 platform and sdkmanager cannot fetch manifests through the proxy; made a local platforms/android-36 copy (ApiLevel edited to 36) purely for local verification — repo untouched
  - Signing quirk confirmed: without android/key.properties the release signing config is all-null, so a local ephemeral keystore + key.properties (both gitignored) were created, mirroring the CI fallback path
  - release build running…
- [x] commit be43804 (v1), pushed via Git Data API, CI release built, user verified on device

## v2 (2026-11-17, on top of be43804)

User device feedback round: 7 issues.

1. **WebView proxy** — androidx.webkit:webkit:1.12.0 added; `XrayBridge.setWebViewProxy(mode, address)` (main thread, handled inline in MainActivity, not on the Go executor) uses ProxyController when PROXY_OVERRIDE is supported. NOTE on API semantics (checked against official docs): the proxy protocol goes in the rule URL itself (`socks://127.0.0.1:28780`); the two-arg `addProxyRule(url, schemeFilter)` overload's second parameter filters *request URL* schemes, it does NOT select the proxy protocol — so it is not used. Modes: xray → socks://127.0.0.1:28780; http → address as-is (defaults to HTTP); socks5/socks4 → socks://address (ProxyConfig has no distinct socks4 scheme; Chromium's SOCKS is v5 — best effort); direct/system → clearProxyOverride. Dart: XrayService syncs on proxyType/proxyAddress/proxyUsername/proxyPassword changes + once at bean ready. NetworkSetting has no separate proxyPort — proxyAddress is a single "host:port" string.
2. **testXray isolated-process error** — XrayBridge.start() now stops a running core BEFORE testXray (was test → stop → run).
3a. **hy2 pinSHA256** — Go verification in ~/workspace/libxray-src/share (temp test, deleted after use) against the bundled xray-core (v1.260327.1) infra/conf Build():
   - Brief's field `pinnedPeerCertificateChainSha256: [base64]` builds OK but the pin is **silently dropped** (built tls.Config has 0 pins) — do NOT use.
   - Correct field for this core: `pinnedPeerCertSha256: "<hex>"` (comma-separated hex string) — Build OK and the pin **is effective** (tls.Config.PinnedPeerCertSha256 == pin bytes). Bridge injects this into streamSettings.tlsSettings (creating them + security=tls if missing) after stripping pinSHA256 from the link.
   - `allowInsecure: true` makes Build() fail with a removed-feature error ("The feature \"allowInsecure\" has been removed..."). So hy2 links with insecure=1/true fail explicitly with "insecure hy2 not supported by core" instead of being converted.
   - convertLinks (bridge) now returns per-link {nodes, failures{link summary, reason}}; Dart XrayService.convertLinks returns XrayConvertResult; paste import reports "Imported X, skipped Y" + first reason; all-failed shows the first real reason.
3b. **Subscription fetch** — new lib/src/service/subscription_fetch.dart: UA rotation (v2rayNG, clash-verge, Shadowrocket, browser), proxy-first via main SOCKS then direct (or direct only when core stopped), HTML error pages rejected, thrown error carries the last attempt's HTTP status/exception. Clash YAML: tolerant line parser for `proxies:` synthesizing ss/vmess/vless/trojan/hysteria2 share links; unsupported/incomplete entries are counted as failures (hy2 with skip-cert-verify is rejected with reason, matching the core limitation).
4+5. **Subscriptions as first-class objects** — XraySubscription{id,name,url,cron,lastUpdatedMs} stored in xray_setting config (back-compatible); XrayNode.group added ('' = manual, shown as 「手动导入」). Node page: subscription section (add dialog with name/url/cron + cron validation, per-sub refresh with spinner, delete removes the group + fixes indices, refresh-all), nodes rendered grouped by subscription. Refresh replaces the group wholesale (dedupe by link), main/igneous selections follow by link else -1, group untouched when conversion yields 0 nodes. Cron: lib/src/utils/cron_util.dart 5-field evaluator (*, lists, ranges, steps; dow 0/7=Sunday; dom+dow both restricted = OR). XrayService checks every 30s + once at startup, per-minute dedupe via in-memory set + lastUpdatedMs (restart guard). KNOWN LIMIT: Android may kill the app in background; timers only run while the process lives.
6. **Main failover** — XrayService health check every 30s (only in xray mode, core running, ≥2 nodes, main selected): probe http://www.gstatic.com/generate_204 through SOCKS 127.0.0.1:28780, 8s timeout, 20s grace after each (re)start. 3 consecutive failures → main advances to the next node in list order (ring), failoverNote shown on the node page; the existing ever() listener restarts the core. Igneous never fails over.
7. **Sad Panda auto-refresh** — igneous refresh logic extracted from cookie_page into lib/src/service/igneous_refresh_service.dart (same dedicated Dio incl. 28781 pinning + domain fronting + timeout translator; cookie page calls it with force and keeps its exact UI/toast/snack behavior). Auto callers are throttled to 1 per 3 minutes. EHRequest._getWithErrorHandler/_postWithErrorHandler: on EHSiteExceptionType.blankBody for an exhentai request while logged in, refresh igneous once and replay the request once; retry failure or refresh failure rethrows the original exception. Other exception types untouched.

Verify: flutter pub get OK; flutter analyze on all v2 changed/new files: **0 errors**. Remaining warnings are pre-existing (l18n equal_keys_in_map for upstream `quickSearch` duplicate — confirmed present in HEAD; eh_request unreachable_switch_default — v1-confirmed). No local flutter build (sandbox Gradle daemon loopback issue, same as v1); Kotlin changes are code-reviewed only, CI builds.

## v3 (2026-11-17, on top of 62b41b7)

User device feedback: subscription import reports "no nodes" even though the subscription URL returns content. Root cause found in LibXray source: `DecodeSubscriptionText` only decrypts Age-armored bodies and passes everything else through unchanged — it does **not** base64-decode. The bridge's convertLinks relied on it for base64 bodies, so a base64 subscription (the user's panel returns one base64 blob per line, each encoding a single link) yielded zero `://` lines and zero failures, surfacing as "no nodes in subscription".

Fix (XrayBridge.kt only): convertLinks now normalizes the body via `extractShareLinkText` — plain link lists pass through untouched; Age bodies still go to libXray's decodeSubscriptionText; base64 is decoded locally with android.util.Base64 (minSdk 24 rules out java.util.Base64): whole-body first (standard/url-safe, padding optional, whitespace ignored), then per-line (each line independently encoded), then per-line again on a whole-body result. Non-UTF-8 decode results are rejected via the replacement-char check so random base64-looking garbage cannot turn into phantom links.

Verify: the decoding algorithm was ported 1:1 to Python and passes 7 cases (per-line base64 of link+CRLF — the user's format — per-line bare, per-line no-padding, whole-body, whole-body url-safe/no-padding/76-wrapped, plain passthrough, garbage rejected). The three link archetypes in the user's subscription (vless ws+tls with extra params, vless tcp+reality+flow, hy2 after pin strip with insecure=false + mport kept) were converted with the bundled core via a temporary Go test in libxray-src: all pass (test deleted after use; note a hand-transcribed 42-char pbk fails — real 43-char keys pass). Kotlin is code-reviewed only, CI builds.

## v4 (2026-11-17, on top of 563a9d5)

User device feedback round 3: two issues.

1. **Sad Panda: refresh on every occurrence + reload + user-visible prompt** — v2 only retried on blankBody from exhentai-host requests and silently, behind a 3-minute auto throttle, so on device it often looked like nothing happened. Rework:
   - Gate is now the site mode itself: `ehSetting.site.value == 'EX'` (was: request host == exhentai.org / domain-fronting host match; `_isExhentaiRequest` removed, along with the now-unused `failedResponse` parameter).
   - New `IgneousRefreshService.refreshForSadPanda()`: no long throttle — every Sad Panda triggers a forced refresh immediately; concurrent triggers share one in-flight refresh (dedupe added inside `refreshIgneousDetailed`, which also records `_lastRefreshSuccessAt`); a trigger within 20s (`sadPandaFreshWindow`) after a successful refresh reuses it and just reloads. `_refreshIgneousDetailed` keeps the old body; `_initDio()` moved inside its try so init failures return a result instead of throwing.
   - EHRequest toasts on trigger (`sadPandaAutoRefreshing`, deduped to once per fresh window) and on refresh failure (`sadPandaAutoRefreshFailed`); keys added to all 6 locales (zh translated, others English like xrayFailoverTo). On success the original request is reloaded exactly once, as before.
2. **Cold start: core up before first frame** — previously the core only started in `doAfterBeanReady` (GetMaterialApp onReady), i.e. after the home page had already fired its first requests into a dead 127.0.0.1:28780 → connection reset. `main()` now awaits `xrayService.ensureStartedForColdStart()` after all beans' initBean (settings loaded) and before runApp: in xray mode it runs the regular `_sync()` start, then polls the main SOCKS port (100ms interval, 3s cap) until it accepts a connection. doAfterBeanReady's `_scheduleSync` then no-ops (same links already started). Non-xray modes and non-Android are untouched no-ops.

Verify: dart format parse-check on all touched files OK; dart analyze on eh_request.dart / igneous_refresh_service.dart / xray_service.dart / main.dart: **0 errors** (only the pre-existing unreachable_switch_default warning at eh_request.dart:431, v1-confirmed). No local build (Gradle daemon loopback issue); CI builds.

## Local build prerequisite (AAR not in git)

The 52MB `libXray.aar` is **not committed** (gitignored; the fork is pushed via the GitHub Git Data API, which cannot carry large binaries). Before building locally, place it at `android/app/libs/libXray.aar`:

- Download `libxray-android.zip` from the official XTLS/LibXray **v26.10.31** release: https://github.com/XTLS/LibXray/releases/download/v26.10.31/libxray-android.zip (zip sha256 `fb99f04acf379cc2957c1e1d0ce2b3c0005d3f49974a44c09a11242a0562c1ca`), extract `libxray-android/libXray.aar` into `android/app/libs/` (AAR sha256 `4c90532f61ff8363e7fcf52e064ff1aa66d065e06afbadc0ea4c6acf384c452f`).
- CI does the same download + sha256 verification automatically in build-xray-release.yml.

## Notes
- Signing: build.gradle release always uses signingConfigs.release built from android/key.properties; without the file all values are null. Local release build may fail on signing — will test; CI workflow handles it (secret or ephemeral keystore + key.properties).
- Android SDK present: platforms android-37.0/37.2, build-tools 36/37, cmdline-tools latest. Project compileSdk 36 — may need sdkmanager "platforms;android-36".
- JDK21 at ~/tools/jdk21; AGP version in project TBD — try jdk21 first, fallback JDK17 download.

## 2026-11-20 — Windows client, port 23366, release-notes convention

Standing rule (user, 2026-11-20): **release notes list only that release's
changes** — no more cumulative backfill. The 20261119 notes stay as history;
every new release-notes/<tag>.md starts fresh.

- **Windows Xray bridge** (`lib/src/service/xray_windows_bridge.dart`): the
  official LibXray v26.10.31 release also ships `libxray-windows-x64.zip`
  (zip sha256 `9a3b1548667836a42b48bb0e37505726d4cd72e8429182e870b92df4cc8172f3`)
  containing `libXray.dll` with the same JSON invoke API via C exports
  `CGoInvoke`/`CGoFree`. The bridge is a one-to-one Dart port of the Kotlin
  bridge (hy2 pin preprocessing, base64 subscription decoding, dual-inbound
  config) calling the DLL through FFI from a background isolate.
  `XrayService.isSupported` now covers Android + Windows; WebView proxy sync
  stays Android-only (WebView2 has no runtime proxy override).
- **Ports**: defaults changed 28780/28781 → **23366/23367** on both
  platforms. `XrayService.ensurePortsResolved()` probes the defaults once
  per process; an occupied default is replaced by a random free port.
  All consumers read `XrayService.mainAddress` / `igneousAddress` (the
  hardcoded strings in proxy_util / eh_request / igneous_refresh_service
  are gone); Dart passes the resolved ports to the Kotlin bridge with
  every start / setWebViewProxy call.
- **Windows data dirs** (`path_service.dart`): portable packages carry a
  `portable.flag` next to the exe → all app/account data goes to `JH_Data`
  beside the exe (created on first run). Installed builds keep the
  path_provider default `%APPDATA%\top.jtmonster\jhentai` (no admin rights).
- **Windows first download** (`download_setting.dart`): first gallery or
  archive download pops a path chooser prefilled with
  `<system Downloads>\JHentai`; the choice persists as
  `downloadPathConfigured` in the download setting config.
- **Reader**: wheel page-turns in paged layouts get a 280ms cooldown (one
  notch = one page); ArrowUp/ArrowDown added as second-slot default
  bindings for prev/next page.
- **Packaging**: `windows/CMakeLists.txt` bundles `windows/libXray.dll`
  when present (CI downloads it, sha256-verified). New `BuildWindows` job
  in build-xray-release.yml (needs BuildAndroid) produces the portable zip
  and an Inno Setup installer (`installer/JHenTai.iss`): per-user install,
  optional Start-menu/desktop-shortcut tasks, existing-version detection
  shown on the Ready page, and an uninstall-time "erase app data" checkbox
  that deletes ONLY `%APPDATA%\top.jtmonster\jhentai` after strict
  constant-path validation.
- Verify: flutter analyze on all touched Dart files: **0 errors** (only
  pre-existing warnings). Windows build itself runs in CI (no Windows
  toolchain in the sandbox).
- **Full app-data export/import** (`app_data_transfer_service.dart`, added
  same day at the user's request): the built-in export only covers a few
  config types, so a file-level bundle was added — zip of a VACUUM INTO
  snapshot of `db.sqlite` (all bean configs incl. account + Xray nodes,
  history, block rules), `jhentai.gs`/`.bak`, and `cookies/`+`EBWebView/`
  minus cache folders, plus a manifest. Import stages into
  `appdata_import/` and `PathService` swaps it in at the next startup
  before the DB/GetStorage opens (stale WAL/SHM deleted with the swap);
  the staged DB's downloadSetting has its absolute path keys stripped so
  a bundle from another machine/install never imports foreign paths.
  Format is platform-independent: installer ⇄ portable ⇄ Android.

## 2026-11-20 (second batch): igneous API refresh, single-node Xray

- **About page**: added the FurBoats fork repo tile next to the original
  Github tile; original author/repo entries untouched.
- **App-data export merged**: the separate export/import app-data tiles
  in advanced settings are gone. `CloudConfigTypeEnum.appData` (code 6)
  is now one checkbox in the original export-data selection dialog —
  selecting it exports the AppDataTransferService zip alongside/instead
  of the JSON; the original import flow accepts `.zip` too and stages it
  the same way as before.
- **Igneous node removed**: XraySetting drops `igneousNodeIndex`;
  XrayService/Windows bridge/Kotlin bridge now build a single-inbound
  config (main only, port 23366 default). IgneousRefreshService was
  rewritten: API mode (opt-in, off by default — default is the legacy
direct refresh through the app proxy / main node) POSTs base cookies as JSON to the
  configured refresh API (default
  `https://exrefresh.fur.boats/ign_refresh`) and stores the returned
  igneous; legacy mode requests the EX index directly. Both ride
  `findProxySettingFunc` (the app's normal proxy setting, Xray main node
  included). Placeholder igneous values (empty / "mystery" / "null")
  count as failure in both modes.
- **Auto-refresh gate**: AdvancedSetting gains `autoRefreshIgneous`
  (default on), `igneousRefreshFailStreak`, `useIgneousRefreshApi`,
  `igneousRefreshApiUrl`. Sad Panda refreshes are skipped silently when
  the switch is off; 5 consecutive failures auto-disable it (with a
  toast). Advanced settings page has the new switch.
- **Cookie page**: the igneous row shows a small "long press to switch
  refresh mode" hint; long-press opens the API-mode dialog (switch +
  address). Confirming with the switch on shows a second warning dialog
  stating the login credentials will be sent to that third-party
  endpoint.
- **Failover visibility**: health-check failover now toasts the user;
  the switch logic lives in `XrayService.switchToNextMainNode()` which
  waits for the restarted core's inbound.
- **Ban handling**: EHRequest retries once after a node switch when a
  response is an IP-ban page (EHSiteExceptionType.banned), with a toast.
- **Cron removed**: subscription cron auto-refresh deleted end to end
  (XrayService timer/tick, XraySubscription.cron, page UI, cron_util.dart).

## 2026-11-20 (third batch): uninstall wipe, igneous row always visible

- **Installer**: uninstall no longer offers the erase-data checkbox.
  It now always wipes the per-user AppData data folder (settings,
  account, caches) except the `download` subfolder, which keeps its
  contents and path; the previous triple path-safety checks are
  unchanged and still gate the deletion.
- **Cookie page**: the igneous row is always rendered. When no igneous
  cookie is stored, a placeholder row shows the value as "empty"
  (l18n `emptyValue`), so the refresh button and the long-press
  refresh-mode dialog stay reachable.
- **-3 first build fix**: run #17's Windows job failed Inno compilation
  with "Unknown identifier 'faDirectory'" (Inno Pascal Script has no
  Delphi-style attribute constants). The directory test now uses a
  locally defined DirectoryAttribute = $10 (FILE_ATTRIBUTE_DIRECTORY).
  The incomplete -3 Release/tag from run #17 were deleted and the
  workflow re-triggered from the fixed master.
