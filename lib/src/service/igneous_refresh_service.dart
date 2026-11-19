import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:get/get_rx/get_rx.dart';
import 'package:jhentai/src/consts/eh_consts.dart';
import 'package:jhentai/src/extension/dio_exception_extension.dart';
import 'package:jhentai/src/network/eh_ip_provider.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/network/eh_timeout_translator.dart';
import 'package:jhentai/src/service/xray_service.dart';
import 'package:jhentai/src/setting/network_setting.dart';
import 'package:jhentai/src/setting/user_setting.dart';
import 'package:jhentai/src/utils/cookie_util.dart';

import '../exception/eh_site_exception.dart';
import 'jh_service.dart';
import 'log.dart';

IgneousRefreshService igneousRefreshService = IgneousRefreshService();

class IgneousRefreshResult {
  final bool success;

  /// Human-readable failure reason (matches what the cookie page showed
  /// before this logic became a service); null on success or when skipped
  /// by the throttle.
  final String? errorMessage;

  /// True when the call was skipped by the automatic-refresh throttle.
  final bool skipped;

  const IgneousRefreshResult({
    required this.success,
    this.errorMessage,
    this.skipped = false,
  });
}

/// Refreshes the exhentai `igneous` cookie by requesting the EX index with
/// the member cookies and storing the returned cookie.
///
/// This is the logic that used to live in the cookie page; its dedicated Dio
/// pins traffic to the Xray igneous inbound (XrayService.igneousAddress) in xray mode
/// with no DIRECT fallback. Manual callers pass `force: true`.
///
/// Sad Panda callers use [refreshForSadPanda]: every Sad Panda triggers a
/// refresh right away (no long throttle), but concurrent triggers share a
/// single in-flight refresh, and a trigger landing within
/// [sadPandaFreshWindow] after a successful refresh reuses that result —
/// the caller just reloads its request with the fresh cookie.
class IgneousRefreshService
    with JHLifeCircleBeanErrorCatch
    implements JHLifeCircleBean {
  static const Duration autoThrottle = Duration(minutes: 3);
  static const Duration sadPandaFreshWindow = Duration(seconds: 20);

  Dio? _dio;
  DateTime? _lastAutoRefreshAt;
  Future<IgneousRefreshResult>? _inFlightRefresh;
  DateTime? _lastRefreshSuccessAt;

  @override
  List<JHLifeCircleBean> get initDependencies =>
      super.initDependencies..addAll([networkSetting, userSetting]);

  @override
  Future<void> doInitBean() async {}

  @override
  Future<void> doAfterBeanReady() async {}

  /// Refreshes the igneous cookie; true when a fresh cookie was stored.
  ///
  /// With `force: false` (automatic), a call made less than [autoThrottle]
  /// after the previous automatic refresh is skipped and returns false.
  Future<bool> refreshIgneous({bool force = false}) async {
    IgneousRefreshResult result = await refreshIgneousDetailed(force: force);
    return result.success;
  }

  /// Refresh entry point for Sad Panda handling: refresh immediately,
  /// unless a refresh is already in flight (share it) or one succeeded
  /// within [sadPandaFreshWindow] (the stored cookie is fresh — the caller
  /// should simply reload). A shared/reused success is reported with
  /// `skipped: true` when no new request was made.
  Future<IgneousRefreshResult> refreshForSadPanda() async {
    DateTime? lastSuccess = _lastRefreshSuccessAt;
    if (_inFlightRefresh == null &&
        lastSuccess != null &&
        DateTime.now().difference(lastSuccess) < sadPandaFreshWindow) {
      log.info('Igneous already refreshed moments ago, skip for Sad Panda');
      return const IgneousRefreshResult(success: true, skipped: true);
    }
    return refreshIgneousDetailed(force: true);
  }

  Future<IgneousRefreshResult> refreshIgneousDetailed({
    bool force = false,
  }) async {
    Future<IgneousRefreshResult>? inFlight = _inFlightRefresh;
    if (inFlight != null) {
      return inFlight;
    }
    Future<IgneousRefreshResult> future =
        _refreshIgneousDetailed(force: force);
    _inFlightRefresh = future;
    try {
      IgneousRefreshResult result = await future;
      if (result.success) {
        _lastRefreshSuccessAt = DateTime.now();
      }
      return result;
    } finally {
      if (identical(_inFlightRefresh, future)) {
        _inFlightRefresh = null;
      }
    }
  }

  Future<IgneousRefreshResult> _refreshIgneousDetailed({
    bool force = false,
  }) async {
    if (!userSetting.hasLoggedIn() || userSetting.ipbPassHash.value == null) {
      return const IgneousRefreshResult(success: false, errorMessage: 'Sad panda');
    }

    if (!force && _lastAutoRefreshAt != null) {
      Duration elapsed = DateTime.now().difference(_lastAutoRefreshAt!);
      if (elapsed < autoThrottle) {
        log.info(
            'Skip igneous auto refresh, last one was ${elapsed.inSeconds}s ago');
        return const IgneousRefreshResult(success: false, skipped: true);
      }
    }
    if (!force) {
      _lastAutoRefreshAt = DateTime.now();
    }

    try {
      await _initDio();

      Response response = await _dio!.request(
        EHConsts.EXIndex,
        options: Options(headers: {
          'cookie': CookieUtil.parse2String(
            [
              Cookie('ipb_member_id', userSetting.ipbMemberId.value.toString()),
              Cookie('ipb_pass_hash', userSetting.ipbPassHash.value!),
            ],
          )
        }),
      );

      log.info(
          'Refresh igneous cookie, set-cookie: ${response.headers.value('set-cookie')}');

      List<String>? cookiePairs =
          response.headers.value('set-cookie')?.split(';');
      if (cookiePairs == null) {
        return const IgneousRefreshResult(
            success: false, errorMessage: 'Sad panda');
      }

      for (String cookiePair in cookiePairs) {
        String name = cookiePair.split('=')[0];
        String value = cookiePair.split('=')[1];
        if (name != EHConsts.igneousCookieName) {
          continue;
        }

        if (value == 'mystery') {
          return const IgneousRefreshResult(
              success: false, errorMessage: 'Sad panda');
        }

        await ehRequest.storeEHCookies([Cookie(name, value)]);
        return const IgneousRefreshResult(success: true);
      }

      return const IgneousRefreshResult(
          success: false, errorMessage: 'Sad panda');
    } on DioException catch (e) {
      log.error('Refresh igneous failed: ${e.errorMsg}');
      return IgneousRefreshResult(
          success: false, errorMessage: e.errorMsg ?? '');
    } on EHSiteException catch (e) {
      log.error('Refresh igneous failed: ${e.message}');
      return IgneousRefreshResult(success: false, errorMessage: e.message);
    } catch (e) {
      log.error('Refresh igneous failed: $e');
      return IgneousRefreshResult(success: false, errorMessage: e.toString());
    }
  }

  Future<void> _initDio() async {
    if (_dio != null) {
      return;
    }

    _dio = Dio(BaseOptions(
      connectTimeout:
          Duration(milliseconds: networkSetting.connectTimeout.value),
      receiveTimeout:
          Duration(milliseconds: networkSetting.receiveTimeout.value),
    ));

    /// This Dio refreshes the igneous cookie, so in xray mode its traffic is
    /// pinned to the igneous node's inbound (XrayService.igneousAddress)
    /// with no DIRECT fallback. In every other mode the client is left
    /// untouched and keeps using the global proxy override, exactly as
    /// before.
    _dio!.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        HttpClient client = HttpClient();
        client.badCertificateCallback = (_, String host, __) {
          return networkSetting.allIPs.contains(host);
        };
        if (networkSetting.proxyType.value == JProxyType.xray) {
          client.findProxy = (_) => 'SOCKS5 ${XrayService.igneousAddress}';
        }
        return client;
      },
    );

    EHIpProvider ehIpProvider = RoundRobinIpProvider(NetworkSetting.host2IPs);

    _dio!.interceptors.add(InterceptorsWrapper(
      onRequest: (RequestOptions options, RequestInterceptorHandler handler) {
        if (networkSetting.enableDomainFronting.isFalse) {
          handler.next(options);
          return;
        }

        String rawPath = options.path;
        String host = options.uri.host;
        if (!ehIpProvider.supports(host)) {
          handler.next(options);
          return;
        }

        String ip = ehIpProvider.nextIP(host);
        handler.next(options.copyWith(
          path: rawPath.replaceFirst(host, ip),
          headers: {...options.headers, 'host': host},
          extra: options.extra..[EHRequest.domainFrontingExtraKey] = {'host': host, 'ip': ip},
        ));
      },
      onError: (DioException e, ErrorInterceptorHandler handler) {
        if (!e.requestOptions.extra
            .containsKey(EHRequest.domainFrontingExtraKey)) {
          handler.next(e);
          return;
        }

        if (e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.badResponse ||
            e.type == DioExceptionType.connectionError) {
          String host =
              e.requestOptions.extra[EHRequest.domainFrontingExtraKey]['host'];
          String ip =
              e.requestOptions.extra[EHRequest.domainFrontingExtraKey]['ip'];
          ehIpProvider.addUnavailableIp(host, ip);
          log.info('Refresh igneous, add unavailable host-ip: $host-$ip');
        }

        handler.next(e);
      },
    ));

    _dio!.interceptors.add(EHTimeoutTranslator());
  }
}
