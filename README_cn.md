# JHenTai（Xray 增强版）

本仓库基于 [JHenTai](https://github.com/jiangtian616/JHenTai)，原作者 **JTMonster（jiangtian616）**。原项目的全部功能、文档与署名归原项目所有，完整说明请看原仓库。本仓库只加入了下面这些 Xray 相关改动，其余行为与原版完全一致。

## 本仓库的改动

1. **内置 Xray 核心**（LibXray 26.10.31）。节点和订阅直接在应用内导入和运行，不需要再单独开代理软件。支持 vless / vmess / trojan / shadowsocks / socks / hysteria2。
2. **双节点分流。** 主节点承载全部流量；另设一个专用节点，只用来刷新 E-Hentai 的 `igneous` cookie，不走其他流量，也没有直连兜底。
3. **订阅作为一等对象管理。** 分组显示、多链接/多渠道拉取、定时自动更新；纯链接、base64 订阅正文、Clash YAML 都能解析，base64 正文由桥接层在本地解码。
4. **Hysteria2 证书锁定。** 订阅里的 `pinSHA256` 会被转换成核心接受的 `pinnedPeerCertSha256` 字段并自动注入。
5. **主节点健康检查与按顺序回退。** 当前主节点不通时，自动切到列表里的下一个节点。
6. **Sad Panda 自动处理。** 在 EX 站点遇到空白响应时，自动用专用节点强制刷新 `igneous` 并重载原请求一次，带 toast 提示。
7. **WebView 跟随应用的代理设置**；冷启动时先启动 Xray 核心再加载界面，首屏不再撞上连接被拒。
8. **下载走主节点代理**——画廊图片下载和归档下载都是。

## 下载

见本仓库 [Releases](../../releases)。Release 版本号规范为 `Jhentai-<JH版本>-<Xray版本>-<构建日期>`，例如 `Jhentai-8.0.18-26.10.31-20261119`。每个 Release 提供分架构 APK（arm64-v8a、armeabi-v7a、x86_64）和一个通用的 universal APK。
