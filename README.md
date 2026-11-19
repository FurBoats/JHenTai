# JHenTai (Xray-enhanced fork)

This repository is based on [JHenTai](https://github.com/jiangtian616/JHenTai) by the original author **JTMonster (jiangtian616)**. All original features, documentation and credits belong to the original project; please see the original repository for the full manual. This fork only adds the Xray-related changes listed below — everything else behaves exactly like the original app.

## What this fork changes

1. **Built-in Xray core** (LibXray 26.10.31). Nodes and subscriptions are imported and run inside the app, no separate proxy app needed. Supports vless / vmess / trojan / shadowsocks / socks / hysteria2.
2. **Dual-node split routing.** The main node carries all traffic. A second, dedicated node is used only to refresh the E-Hentai `igneous` cookie; it carries no other traffic and has no direct-connection fallback.
3. **Subscriptions as first-class objects.** Grouped display, fetching through multiple links/channels, scheduled auto-update. Plain share links, base64 subscription bodies and Clash YAML are all accepted; base64 bodies are decoded locally by the bridge.
4. **Hysteria2 certificate pinning.** A `pinSHA256` value from a subscription is converted into the `pinnedPeerCertSha256` field the core accepts and injected automatically.
5. **Main-node health check with ordered failover.** If the current main node is unreachable, the next node in the list is used automatically.
6. **Automatic Sad Panda handling.** On the EX site, an empty response triggers a forced `igneous` refresh through the dedicated node and one reload of the original request, with a toast notice.
7. **WebView follows the app's proxy setting**, and on cold start the Xray core is started before the UI loads, so the first screen no longer hits a refused connection.
8. **Downloads go through the main node** — both gallery image downloads and archive downloads.

## Downloads

See this repository's [Releases](../../releases). Release versions follow the scheme `Jhentai-<JHenTai version>-<Xray version>-<build date>`, e.g. `Jhentai-8.0.18-26.10.31-20261119`. Each release provides per-ABI APKs (arm64-v8a, armeabi-v7a, x86_64) and a universal APK that fits all architectures.
