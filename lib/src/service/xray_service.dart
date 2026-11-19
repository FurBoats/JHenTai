import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../setting/network_setting.dart';
import '../setting/xray_setting.dart';
import '../utils/cron_util.dart';
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
/// The core exposes two loopback SOCKS inbounds:
/// - [mainPort]: routed to the main node; [findProxySettingFunc] points all
///   normal traffic here when the proxy type is xray.
/// - [igneousPort]: routed to the igneous node; only the igneous cookie
///   refresh Dio uses it.
///
/// Ports default to 23366/23367 and are resolved once per process: when a
/// default port is already occupied, a random free port takes its place
/// (see [ensurePortsResolved]). Consumers must always read [mainAddress] /
/// [igneousAddress] instead of hardcoding a port.
///
/// Extra duties: keeping the WebView proxy override in sync with the app
/// proxy setting (Android only), cron-based subscription auto-refresh, and
/// main-node failover (the igneous node never fails over).
///
/// On platforms other than Android and Windows every method is a no-op.
class XrayService with JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  static const MethodChannel _channel =
      MethodChannel('top.jtmonster.jhentai.xray');

  static const int defaultMainPort = 23366;
  static const int defaultIgneousPort = 23367;

  static int _mainPort = defaultMainPort;
  static int _igneousPort = defaultIgneousPort;
  static bool _portsResolved = false;

  static int get mainPort => _mainPort;
  static int get igneousPort => _igneousPort;
  static String get mainAddress => '127.0.0.1:$_mainPort';
  static String get igneousAddress => '127.0.0.1:$_igneousPort';

  /// Picks the loopback ports for this process: the defaults when they are
  /// free, a random free port for each one that is already occupied.
  static Future<void> ensurePortsResolved() async {
    if (_portsResolved) {
      return;
    }
    _portsResolved = true;
    _mainPort = await _resolvePort(defaultMainPort);
    _igneousPort = await _resolvePort(defaultIgneousPort, avoid: _mainPort);
    if (_mainPort != defaultMainPort || _igneousPort != defaultIgneousPort) {
      log.info(
          'Xray default port occupied, using main=$_mainPort igneous=$_igneousPort');
    }
  }

  static Future<int> _resolvePort(int preferred, {int? avoid}) async {
    if (preferred != avoid && await _isPortFree(preferred)) {
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
  String? _startedIgneousLink;
  Future<void> _syncQueue = Future.value();

  // Failover state.
  Timer? _healthTimer;
  int _consecutiveHealthFailures = 0;
  DateTime? _coreStartedAt;
  bool _healthCheckInFlight = false;

  // Cron auto-refresh state.
  Timer? _cronTimer;
  final Set<String> _cronRanKeys = {};
  final Map<String, CronExpression?> _cronCache = {};

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
    ever(xraySetting.igneousNodeIndex, (_) => _scheduleSync());
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
    _cronTimer?.cancel();
    _cronTimer =
        Timer.periodic(const Duration(seconds: 30), (_) => _cronTick());
    _cronTick();
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
    String? igneousLink = xraySetting.igneousNode?.link;
    if (_started &&
        _startedMainLink == mainLink &&
        _startedIgneousLink == igneousLink) {
      return;
    }
    await start(mainLink: mainLink, igneousLink: igneousLink);
  }

  Future<void> start({String? mainLink, String? igneousLink}) async {
    if (!isSupported) {
      return;
    }

    try {
      status.value = 'starting';
      await ensurePortsResolved();
      if (Platform.isWindows) {
        await XrayWindowsBridge.start(
          mainLink: mainLink,
          igneousLink: igneousLink,
          mainPort: mainPort,
          igneousPort: igneousPort,
        );
      } else {
        await _channel.invokeMethod('start', {
          'mainLink': mainLink,
          'igneousLink': igneousLink,
          'mainPort': mainPort,
          'igneousPort': igneousPort,
        });
      }
      _started = true;
      _startedMainLink = mainLink;
      _startedIgneousLink = igneousLink;
      running.value = true;
      status.value = 'running';
      _coreStartedAt = DateTime.now();
      _consecutiveHealthFailures = 0;
      log.info(
          'Xray core started (main: ${mainLink != null}, igneous: ${igneousLink != null})');
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
    _startedIgneousLink = null;
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
  // Main node failover (igneous never participates)
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

  Future<void> _failoverMainNode() async {
    int current = xraySetting.mainNodeIndex.value;
    int count = xraySetting.nodes.length;
    if (current < 0 || count < 2) {
      return;
    }
    int next = (current + 1) % count;
    XrayNode node = xraySetting.nodes[next];
    log.info(
        'Xray main node failover: ${xraySetting.nodes[current].name} -> ${node.name}');
    _consecutiveHealthFailures = 0;
    failoverNote.value =
        'xrayFailoverTo'.trParams({'name': node.name.isEmpty ? node.link : node.name});
    // The ever() listener on mainNodeIndex restarts the core with the new node.
    await xraySetting.saveMainNodeIndex(next);
  }

  // ------------------------------------------------------------------
  // Subscriptions: manual + cron refresh
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

  void _cronTick() {
    if (!isSupported) {
      return;
    }
    DateTime now = DateTime.now();
    if (_cronRanKeys.length > 500) {
      _cronRanKeys.clear();
    }
    for (XraySubscription sub in xraySetting.subscriptions) {
      String cron = sub.cron.trim();
      if (cron.isEmpty) {
        continue;
      }
      String cacheKey = '${sub.id}|$cron';
      CronExpression? expression;
      if (_cronCache.containsKey(cacheKey)) {
        expression = _cronCache[cacheKey];
      } else {
        expression = CronExpression.tryParse(cron);
        _cronCache[cacheKey] = expression;
        if (expression == null) {
          log.error('Invalid cron expression for ${sub.name}: $cron');
        }
      }
      if (expression == null || !expression.matches(now)) {
        continue;
      }
      String ranKey =
          '${sub.id}@${now.year}-${now.month}-${now.day}-${now.hour}-${now.minute}';
      if (_cronRanKeys.contains(ranKey)) {
        continue;
      }
      // Also guard against a restart landing inside the same minute after a
      // successful run.
      if (sub.lastUpdatedMs > 0) {
        DateTime last = DateTime.fromMillisecondsSinceEpoch(sub.lastUpdatedMs);
        if (last.year == now.year &&
            last.month == now.month &&
            last.day == now.day &&
            last.hour == now.hour &&
            last.minute == now.minute) {
          _cronRanKeys.add(ranKey);
          continue;
        }
      }
      _cronRanKeys.add(ranKey);
      log.info('Cron refresh subscription: ${sub.name}');
      unawaited(refreshSubscription(sub).catchError((Object e) {
        log.error('Cron refresh subscription ${sub.name} failed: $e');
      }));
    }
  }
}
