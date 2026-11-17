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
- [ ] commit

## Local build prerequisite (AAR not in git)

The 52MB `libXray.aar` is **not committed** (gitignored; the fork is pushed via the GitHub Git Data API, which cannot carry large binaries). Before building locally, place it at `android/app/libs/libXray.aar`:

- Download `libxray-android.zip` from the official XTLS/LibXray **v26.10.31** release: https://github.com/XTLS/LibXray/releases/download/v26.10.31/libxray-android.zip (zip sha256 `fb99f04acf379cc2957c1e1d0ce2b3c0005d3f49974a44c09a11242a0562c1ca`), extract `libxray-android/libXray.aar` into `android/app/libs/` (AAR sha256 `4c90532f61ff8363e7fcf52e064ff1aa66d065e06afbadc0ea4c6acf384c452f`).
- CI does the same download + sha256 verification automatically in build-xray-release.yml.

## Notes
- Signing: build.gradle release always uses signingConfigs.release built from android/key.properties; without the file all values are null. Local release build may fail on signing — will test; CI workflow handles it (secret or ephemeral keystore + key.properties).
- Android SDK present: platforms android-37.0/37.2, build-tools 36/37, cmdline-tools latest. Project compileSdk 36 — may need sdkmanager "platforms;android-36".
- JDK21 at ~/tools/jdk21; AGP version in project TBD — try jdk21 first, fallback JDK17 download.
