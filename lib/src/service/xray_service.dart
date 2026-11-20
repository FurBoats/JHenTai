import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../setting/network_setting.dart';
import '../setting/xray_setting.dart';
import '../utils/toast_util.dart';
import 'jh_service.dart';
import 'log.dart';
import 'subscription_fetch.dart';
import 'xray_windows_bridge.dart';

XrayService xrayService = XrayService();

/// One link that failed to convert, with the reason reported by the core.
class XrayConvertFailure {
  final String link;
  final String reason;

  XrayConvertFailure({required this.link, required this.reason});
}

class XrayConvertResult {
  final List<XrayNode> nodes;
  final List<XrayConvertFailure> failures;

  XrayConvertResult({required this.nodes, required this.failures});
}

/// Drives the embedded Xray core: through the Android MethodChannel on
/// Android, and through the Dart FFI bridge ([XrayWindowsBridge]) on
/// Windows. Both end at the same libXray invoke API.
///
/// The core exposes one loopback SOCKS inbound, [mainPort], routed to the
/// main node; [findProxySettingFunc] points all normal traffic here when
/// the proxy type is xray. (The former second inbound for a dedicated
/// igneous node is gone — the igneous cookie now refreshes through an API,
/// see IgneousRefreshService.)
///
/// The port defaults to 23366 and is resolved once per process: when the
/// default is already occupied, a random free port takes its place (see
/// [ensurePortsResolved]). Consumers must always read [mainAddress]
/// instead of hardcoding a port.
///
/// Extra duties: keeping the WebView proxy override in sync with the app
/// proxy setting (Android only), and main-node failover.
///
/// On platforms other than Android and Windows every method is a no-op.
class XrayService with JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  static const MethodChannel _channel =
      MethodChannel('top.jtmonster.jhentai.xray');

  static const int defaultMainPort = 23366;

  static int _mainPort = defaultMainPort;
  static bool _portsResolved = false;

  static int get mainPort => _mainPort;
  static String get mainAddress => '127.0.0.1:$_mainPort';

  /// Picks the loopback port for this process: the default when it is
  /// free, a random free port when it is already occupied.
  static Future<void> ensurePortsResolved() async {
    if (_portsResolved) {
      return;
    }
    _portsResolved = true;
    _mainPort = await _resolvePort(defaultMainPort);
    if (_mainPort != defaultMainPort) {
      log.info('Xray default port occupied, using main=$_mainPort');
    }
  }

  static Future<int> _resolvePort(int preferred) async {
    if (await _isPortFree(preferred)) {
      return preferred;
    }
    try {
      ServerSocket socket =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      int port = socket.port;
      await socket.close();
      return port;
    } catch (_) {
      return preferred;
    }
  }

  static Future<bool> _isPortFree(int port) async {
    try {
      ServerSocket socket =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await socket.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  RxBool running = false.obs;

  /// One of: stopped / starting / running / error: <message>
  RxString status = 'stopped'.obs;

  /// Set when the main node was automatically switched by failover.
  RxString failoverNote = ''.obs;

  bool get isSupported => GetPlatform.isAndroid || GetPlatform.isWindows;

  bool _started = false;
  String? _startedMainLink;
  Future<void> _syncQueue = Future.value();

  // Failover state.
  Timer? _healthTimer;
  int _consecutiveHealthFailures = 0;
  DateTime? _coreStartedAt;
  bool _healthCheckInFlight = false;

  @override
  List<JHLifeCircleBean> get initDependencies =>
      super.initDependencies..addAll([networkSetting, xraySetting]);

  @override
  Future<void> doInitBean() async {}

  @override
  Future<void> doAfterBeanReady() async {
    if (!isSupported) {
      return;
    }

    ever(networkSetting.proxyType, (_) => _scheduleSync());
    ever(xraySetting.mainNodeIndex, (_) => _scheduleSync());
    ever(xraySetting.nodes, (_) => _scheduleSync());

    // WebView does not use the app HttpClient proxy: keep its process-wide
    // proxy override in sync with the proxy setting (all modes, not just
    // xray — manual http/socks proxies need it too).
    ever(networkSetting.proxyType, (_) => _syncWebViewProxy());
    ever(networkSetting.proxyAddress, (_) => _syncWebViewProxy());
    ever(networkSetting.proxyUsername, (_) => _syncWebViewProxy());
    ever(networkSetting.proxyPassword, (_) => _syncWebViewProxy());
    _syncWebViewProxy();

    _scheduleSync();

    _healthTimer?.cancel();
    _healthTimer =
        Timer.periodic(const Duration(seconds: 30), (_) => _healthCheckTick());
  }

  void _scheduleSync() {
    _syncQueue = _syncQueue.then((_) => _sync()).catchError((_) {});
  }

  /// Cold-start entry point, awaited from main() before runApp. When the
  /// saved proxy mode is xray, bring the core up (and wait until its
  /// loopback SOCKS listener actually accepts connections) before the UI
  /// loads, so the home page's first requests don't hit a not-yet-listening
  /// proxy port and die with connection reset. In doAfterBeanReady the
  /// regular _sync then sees the core already running with the same nodes
  /// and stays a no-op.
  Future<void> ensureStartedForColdStart() async {
    if (!isSupported) {
      return;
    }
    if (networkSetting.proxyType.value != JProxyType.xray) {
      return;
    }
    await _sync();
    if (running.value) {
      await _waitForMainInbound();
    }
  }

  /// The native start call returns once the core is up, but the listener
  /// can lag a few milliseconds behind; poll it briefly so the first real
  /// request never races it.
  Future<void> _waitForMainInbound() async {
    DateTime deadline = DateTime.now().add(const Duration(seconds: 3));
    while (DateTime.now().isBefore(deadline)) {
      try {
        Socket socket = await Socket.connect(
          '127.0.0.1',
          mainPort,
          timeout: const Duration(milliseconds: 300),
        );
        socket.destroy();
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    log.info('Xray main inbound not accepting connections yet (cold start)');
  }

  Future<void> _sync() async {
    if (!isSupported) {
      return;
    }

    if (networkSetting.proxyType.value != JProxyType.xray) {
      if (_started) {
        await stop();
      }
      return;
    }

    String? mainLink = xraySetting.mainNode?.link;
    if (_started && _startedMainLink == mainLink) {
      return;
    }
    await start(mainLink: mainLink);
  }

  Future<void> start({String? mainLink}) async {
    if (!isSupported) {
      return;
    }

    try {
      status.value = 'starting';
      await ensurePortsResolved();
      if (Platform.isWindows) {
        await XrayWindowsBridge.start(
          mainLink: mainLink,
          mainPort: mainPort,
        );
      } else {
        await _channel.invokeMethod('start', {
          'mainLink': mainLink,
          'mainPort': mainPort,
        });
      }
      _started = true;
      _startedMainLink = mainLink;
      running.value = true;
      status.value = 'running';
      _coreStartedAt = DateTime.now();
      _consecutiveHealthFailures = 0;
      log.info('Xray core started (main: ${mainLink != null})');
    } catch (e, stack) {
      running.value = false;
      status.value = 'error: $e';
      log.error('Xray core start failed', e, stack);
    }
  }

  Future<void> stop() async {
    if (!isSupported) {
      return;
    }

    try {
      if (Platform.isWindows) {
        await XrayWindowsBridge.stop();
      } else {
        await _channel.invokeMethod('stop');
      }
    } catch (e, stack) {
      log.error('Xray core stop failed', e, stack);
    }
    _started = false;
    _startedMainLink = null;
    running.value = false;
    status.value = 'stopped';
    _coreStartedAt = null;
    _consecutiveHealthFailures = 0;
  }

  Future<bool> isRunning() async {
    if (!isSupported) {
      return false;
    }
    if (Platform.isWindows) {
      return XrayWindowsBridge.isRunning();
    }
    return await _channel.invokeMethod<bool>('isRunning') ?? false;
  }

  /// Parses pasted text (share links, one per line, or a base64 subscription
  /// body) into nodes via the native converter. Individual bad links land in
  /// [XrayConvertResult.failures] with the core's reason instead of failing
  /// the whole import.
  Future<XrayConvertResult> convertLinks(String text,
      {String group = ''}) async {
    if (!isSupported) {
      return XrayConvertResult(nodes: [], failures: []);
    }
    Map<dynamic, dynamic>? result = Platform.isWindows
        ? await XrayWindowsBridge.convertLinks(text)
        : await _channel.invokeMapMethod<dynamic, dynamic>(
            'convertLinks', text);
    if (result == null) {
      return XrayConvertResult(nodes: [], failures: []);
    }
    List<XrayNode> nodes = [];
    for (dynamic e in (result['nodes'] as List? ?? [])) {
      Map map = Map.from(e as Map);
      nodes.add(XrayNode(
        name: map['name']?.toString() ?? '',
        link: map['link']?.toString() ?? '',
        group: group,
      ));
    }
    List<XrayConvertFailure> failures = [];
    for (dynamic e in (result['failures'] as List? ?? [])) {
      Map map = Map.from(e as Map);
      failures.add(XrayConvertFailure(
        link: map['link']?.toString() ?? '',
        reason: map['reason']?.toString() ?? '',
      ));
    }
    return XrayConvertResult(nodes: nodes, failures: failures);
  }

  Future<String> decodeSubscription(String text) async {
    if (!isSupported) {
      return text;
    }
    if (Platform.isWindows) {
      return XrayWindowsBridge.decodeSubscriptionText(text);
    }
    return await _channel.invokeMethod<String>('decodeSubscription', text) ??
        '';
  }

  // ------------------------------------------------------------------
  // WebView proxy sync
  // ------------------------------------------------------------------

  String _proxyAddressWithAuth() {
    String? username = networkSetting.proxyUsername.value?.trim();
    String? password = networkSetting.proxyPassword.value?.trim();
    if ((username == null || username.isEmpty) &&
        (password == null || password.isEmpty)) {
      return networkSetting.proxyAddress.value;
    }
    return '${username ?? ''}:${password ?? ''}@${networkSetting.proxyAddress.value}';
  }

  Future<void> _syncWebViewProxy() async {
    if (!isSupported) {
      return;
    }
    if (Platform.isWindows) {
      // The Windows WebView (WebView2) takes its proxy from the process
      // command line at environment creation; there is no runtime override
      // to sync. The app's HTTP stack follows the proxy setting itself.
      return;
    }
    await ensurePortsResolved();
    String mode;
    String address = '';
    switch (networkSetting.proxyType.value) {
      case JProxyType.xray:
        mode = 'xray';
        break;
      case JProxyType.http:
        mode = 'http';
        address = _proxyAddressWithAuth();
        break;
      case JProxyType.socks5:
        mode = 'socks5';
        address = _proxyAddressWithAuth();
        break;
      case JProxyType.socks4:
        mode = 'socks4';
        address = _proxyAddressWithAuth();
        break;
      case JProxyType.system:
        mode = 'system';
        break;
      case JProxyType.direct:
        mode = 'direct';
        break;
    }
    try {
      await _channel.invokeMethod('setWebViewProxy',
          {'mode': mode, 'address': address, 'mainPort': mainPort});
    } catch (e) {
      log.error('Sync WebView proxy failed: $e');
    }
  }

  // ------------------------------------------------------------------
  // Main node failover / manual switch
  // ------------------------------------------------------------------

  Future<void> _healthCheckTick() async {
    if (_healthCheckInFlight || !isSupported) {
      return;
    }
    if (networkSetting.proxyType.value != JProxyType.xray ||
        !running.value ||
        xraySetting.mainNodeIndex.value < 0 ||
        xraySetting.nodes.length < 2 ||
        _coreStartedAt == null) {
      return;
    }
    // Grace period after (re)start so boot jitter is not mistaken for a
    // dead node.
    if (DateTime.now().difference(_coreStartedAt!) <
        const Duration(seconds: 20)) {
      return;
    }

    _healthCheckInFlight = true;
    try {
      bool ok = await _probeMainInbound();
      if (ok) {
        _consecutiveHealthFailures = 0;
        return;
      }
      _consecutiveHealthFailures++;
      log.info(
          'Xray main node health check failed ($_consecutiveHealthFailures/3)');
      if (_consecutiveHealthFailures >= 3) {
        await _failoverMainNode();
      }
    } finally {
      _healthCheckInFlight = false;
    }
  }

  Future<bool> _probeMainInbound() async {
    HttpClient client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 8);
    client.findProxy = (_) => 'SOCKS5 $mainAddress';
    try {
      HttpClientRequest request = await client
          .getUrl(Uri.parse('http://www.gstatic.com/generate_204'))
          .timeout(const Duration(seconds: 8));
      HttpClientResponse response =
          await request.close().timeout(const Duration(seconds: 8));
      await response.drain<void>();
      return response.statusCode == 204 || response.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// Switches the main node to the next one in the list and waits until
  /// the restarted core accepts connections again. Returns the new node's
  /// display name, or null when no switch is possible (xray unsupported,
  /// no main node selected, or fewer than two nodes).
  Future<String?> switchToNextMainNode() async {
    int current = xraySetting.mainNodeIndex.value;
    int count = xraySetting.nodes.length;
    if (!isSupported || current < 0 || count < 2) {
      return null;
    }
    int next = (current + 1) % count;
    XrayNode node = xraySetting.nodes[next];
    String displayName = node.name.isEmpty ? node.link : node.name;
    log.info(
        'Xray main node switch: ${xraySetting.nodes[current].name} -> ${node.name}');
    failoverNote.value = 'xrayFailoverTo'.trParams({'name': displayName});
    // The ever() listener on mainNodeIndex restarts the core with the new
    // node; give that restart a head start, drain the sync queue, then
    // wait until the new inbound actually accepts connections.
    await xraySetting.saveMainNodeIndex(next);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _syncQueue;
    if (running.value) {
      await _waitForMainInbound();
    }
    return displayName;
  }

  Future<void> _failoverMainNode() async {
    int current = xraySetting.mainNodeIndex.value;
    if (current < 0 || xraySetting.nodes.length < 2) {
      return;
    }
    String fromName = xraySetting.nodes[current].name;
    _consecutiveHealthFailures = 0;
    String? switchedTo = await switchToNextMainNode();
    if (switchedTo == null) {
      return;
    }
    log.info('Xray main node failover: $fromName -> $switchedTo');
    // Automatic failover must not happen silently: tell the user.
    toast('xrayFailoverTo'.trParams({'name': switchedTo}),
        isCenter: false, isShort: false);
  }

  // ------------------------------------------------------------------
  // Subscriptions: manual refresh only (the cron auto-refresh mechanism
  // was removed — it proved impractical)
  // ------------------------------------------------------------------

  /// Fetches and converts a subscription, replacing its whole node group.
  /// Throws with a descriptive message on failure (callers decide whether
  /// to surface it); the group is left untouched when conversion yields no
  /// nodes at all.
  Future<void> refreshSubscription(XraySubscription sub) async {
    String content = await fetchSubscriptionContent(
      sub.url,
      viaProxyAvailable: running.value,
    );

    XrayConvertResult result;
    if (looksLikeClashYaml(content)) {
      ClashParseResult clash = clashYamlToShareLinks(content);
      if (clash.links.isEmpty) {
        throw Exception(clash.failures.isNotEmpty
            ? clash.failures.first
            : 'no nodes in subscription');
      }
      XrayConvertResult converted =
          await convertLinks(clash.links.join('\n'), group: sub.name);
      result = XrayConvertResult(
        nodes: converted.nodes,
        failures: [
          ...clash.failures
              .map((f) => XrayConvertFailure(link: sub.name, reason: f)),
          ...converted.failures,
        ],
      );
    } else {
      result = await convertLinks(content, group: sub.name);
    }

    if (result.nodes.isEmpty) {
      throw Exception(result.failures.isNotEmpty
          ? result.failures.first.reason
          : 'no nodes in subscription');
    }
    if (result.failures.isNotEmpty) {
      log.info(
          'Subscription ${sub.name}: ${result.nodes.length} nodes, ${result.failures.length} skipped (${result.failures.first.reason})');
    }

    await xraySetting.replaceGroupNodes(sub.name, result.nodes);
    sub.lastUpdatedMs = DateTime.now().millisecondsSinceEpoch;
    await xraySetting.saveSubscriptions();
    log.info(
        'Subscription ${sub.name} refreshed: ${result.nodes.length} nodes');
  }

  Future<void> refreshAllSubscriptions() async {
    for (XraySubscription sub in [...xraySetting.subscriptions]) {
      try {
        await refreshSubscription(sub);
      } catch (e) {
        log.error('Refresh subscription ${sub.name} failed: $e');
      }
    }
  }

}
