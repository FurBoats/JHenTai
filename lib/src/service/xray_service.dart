import 'dart:async';

import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../setting/network_setting.dart';
import '../setting/xray_setting.dart';
import 'jh_service.dart';
import 'log.dart';

XrayService xrayService = XrayService();

/// Drives the embedded Xray core through the Android MethodChannel.
///
/// The core exposes two loopback SOCKS inbounds:
/// - [mainPort]: routed to the main node; [findProxySettingFunc] points all
///   normal traffic here when the proxy type is xray.
/// - [igneousPort]: routed to the igneous node; only the igneous cookie
///   refresh Dio in cookie_page uses it.
///
/// On non-Android platforms every method is a no-op.
class XrayService with JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  static const MethodChannel _channel =
      MethodChannel('top.jtmonster.jhentai.xray');

  static const int mainPort = 28780;
  static const int igneousPort = 28781;
  static const String mainAddress = '127.0.0.1:28780';
  static const String igneousAddress = '127.0.0.1:28781';

  RxBool running = false.obs;

  /// One of: stopped / starting / running / error: <message>
  RxString status = 'stopped'.obs;

  bool get isSupported => GetPlatform.isAndroid;

  bool _started = false;
  String? _startedMainLink;
  String? _startedIgneousLink;
  Future<void> _syncQueue = Future.value();

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

    _scheduleSync();
  }

  void _scheduleSync() {
    _syncQueue = _syncQueue.then((_) => _sync()).catchError((_) {});
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
      await _channel.invokeMethod(
          'start', {'mainLink': mainLink, 'igneousLink': igneousLink});
      _started = true;
      _startedMainLink = mainLink;
      _startedIgneousLink = igneousLink;
      running.value = true;
      status.value = 'running';
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
      await _channel.invokeMethod('stop');
    } catch (e, stack) {
      log.error('Xray core stop failed', e, stack);
    }
    _started = false;
    _startedMainLink = null;
    _startedIgneousLink = null;
    running.value = false;
    status.value = 'stopped';
  }

  Future<bool> isRunning() async {
    if (!isSupported) {
      return false;
    }
    return await _channel.invokeMethod<bool>('isRunning') ?? false;
  }

  /// Parses pasted text (share links, one per line, or a base64 subscription
  /// body) into nodes via the native converter.
  Future<List<XrayNode>> convertLinks(String text) async {
    if (!isSupported) {
      return [];
    }
    List<dynamic>? result =
        await _channel.invokeListMethod<dynamic>('convertLinks', text);
    if (result == null) {
      return [];
    }
    return result.map((e) {
      Map map = Map.from(e as Map);
      return XrayNode(
          name: map['name']?.toString() ?? '',
          link: map['link']?.toString() ?? '');
    }).toList();
  }

  Future<String> decodeSubscription(String text) async {
    if (!isSupported) {
      return text;
    }
    return await _channel.invokeMethod<String>('decodeSubscription', text) ??
        '';
  }
}
