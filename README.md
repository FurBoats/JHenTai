# JHenTai (Xray-enhanced fork)

This repository is based on [JHenTai](https://github.com/jiangtian616/JHenTai) by the original author **JTMonster (jiangtian616)**. All original features, documentation and credits belong to the original project; please see the original repository for the full manual. This fork only adds the changes listed below — everything else behaves exactly like the original app.

## What this fork changes

1. **Built-in Xray core** (LibXray 26.10.31). Nodes and subscriptions are imported and run inside the app, no separate proxy app needed. Supports vless / vmess / trojan / shadowsocks / socks / hysteria2.
2. **Single main node.** All traffic goes through one main node. The former dedicated `igneous` node is gone: the E-Hentai `igneous` cookie is refreshed directly over the app's normal network path (configured proxy / main node). As an opt-in alternative, a self-hosted refresh API can perform the refresh — it is off by default and can only be enabled from the cookie page (long-press the `igneous` row), after a warning that your login cookies will be sent to that third-party endpoint.
3. **Subscriptions as first-class objects.** Grouped display, fetching through multiple links/channels, manual refresh. Plain share links, base64 subscription bodies and Clash YAML are all accepted; base64 bodies are decoded locally by the bridge.
4. **Hysteria2 certificate pinning.** A `pinSHA256` value from a subscription is converted into the `pinnedPeerCertSha256` field the core accepts and injected automatically.
5. **Main-node health check with ordered failover.** If the current main node is unreachable, the next node in the list is used automatically, with a toast notice.
6. **Automatic Sad Panda handling.** On the EX site, an empty response triggers a forced `igneous` refresh and one reload of the original request, with a toast notice. The auto-refresh has its own switch in the advanced settings and turns itself off after 5 consecutive failures.
7. **WebView follows the app's proxy setting**, and on cold start the Xray core is started before the UI loads, so the first screen no longer hits a refused connection.
8. **Downloads go through the main node** — both gallery image downloads and archive downloads.
9. **IP-ban failover.** If the site replies that this IP address has been temporarily banned due to an excessive request rate, the app switches the main node, notifies the user with a toast, and reloads the request.
10. **Full app-data export, merged into the built-in export.** The original export-data selection gains a "full app data" option that produces a zip archive; the original import flow accepts that zip and restores everything.
11. **Cloud super resolution (Android & Windows).** Advanced Settings → Image Super Resolution gains a cloud SR switch (off by default; enabling it uploads your images to the cloud node, as the in-app hint warns). When on, super resolution runs on a remote Real-ESRGAN backend instead of the local ncnn models: at gallery download time the image links are sent to the backend, at archive download time the archive link is sent, and for already-downloaded galleries/archives the long-press menu uploads the local files. Scale is 2x/3x/4x. On desktop, if the local ncnn models are configured, local SR takes precedence. Backends are dispatched by a scheduler (companion projects `JH_SuperResolution_Scheduler` and `JH_SuperResolution`); a built-in provider node can be baked in at build time through the `EHSR_BUILTIN_KEY` repository secret, or you can point the app at your own scheduler with your own client key.

## Downloads

See this repository's [Releases](../../releases). Release versions follow the scheme `Jhentai-<JHenTai version>-<Xray version>-<build date>`, e.g. `Jhentai-8.0.18-26.10.31-20261119`. Each release provides per-ABI APKs (arm64-v8a, armeabi-v7a, x86_64), a universal APK that fits all architectures, and Windows builds (an installer and a portable zip).
