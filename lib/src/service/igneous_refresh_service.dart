import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:get/get.dart' hide Response;
import 'package:jhentai/src/consts/eh_consts.dart';
import 'package:jhentai/src/extension/dio_exception_extension.dart';
import 'package:jhentai/src/network/eh_ip_provider.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/network/eh_timeout_translator.dart';
import 'package:jhentai/src/setting/advanced_setting.dart';
import 'package:jhentai/src/setting/network_setting.dart';
import 'package:jhentai/src/setting/user_setting.dart';
import 'package:jhentai/src/utils/cookie_util.dart';
import 'package:jhentai/src/utils/proxy_util.dart';
import 'package:jhentai/src/utils/toast_util.dart';

import '../exception/eh_site_exception.dart';
import 'jh_service.dart';
import 'log.dart';

IgneousRefreshService igneousRefreshService = IgneousRefreshService();

class IgneousRefreshResult {
  final bool success;

  /// Human-readable failure reason; null on success or when skipped.
  final String? errorMessage;

  /// True when the call was skipped (throttle, fresh-window reuse, or the
  /// automatic refresh switch is off).
  final bool skipped;

  const IgneousRefreshResult({
    required this.success,
    this.errorMessage,
    this.skipped = false,
  });
}

/// Refreshes the exhentai `igneous` cookie and stores the fresh value.
///
/// Two refresh modes (see AdvancedSetting):
/// - API mode (default): POST the base cookies as JSON to the configured
///   refresh API (a self-hosted igneous_refresh service), which performs
///   the exhentai request from its own network and returns the freshly
///   issued igneous. The request goes through the app's configured proxy
///   when one is set (Xray main node included).
/// - Legacy mode: request the EX index directly with the base cookies
///   over the app's normal network path and keep the returned cookie.
///
/// There is no dedicated igneous proxy node anymore; both modes ride the
/// normal proxy setting.
///
/// Sad Panda callers use [refreshForSadPanda]: gated by the
/// auto-refresh switch in the advanced settings, every Sad Panda triggers
/// a refresh right away (no long throttle), but concurrent triggers share
/// a single in-flight refresh, and a trigger landing within
/// [sadPandaFreshWindow] after a successful refresh reuses that result —
/// the caller just reloads its request with the fresh cookie. Consecutive
/// automatic failures are counted in AdvancedSetting and auto-disable the
/// switch at the configured threshold.
class IgneousRefreshService
    with JHLifeCircleBeanErrorCatch
    implements JHLifeCircleBean {
  static const Duration autoThrottle = Duration(minutes: 3);
  static const Duration sadPandaFreshWindow = Duration(seconds: 20);

  Dio? _dio;
  String _systemProxyAddress = '';
  DateTime? _lastAutoRefreshAt;
  Future<IgneousRefreshResult>? _inFlightRefresh;
  DateTime? _lastRefreshSuccessAt;

  @override
  List<JHLifeCircleBean> get initDependencies =>
      super.initDependencies..addAll([networkSetting, userSetting, advancedSetting]);

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
  /// unless the auto-refresh switch is off (skipped), a refresh is already
  /// in flight (share it) or one succeeded within [sadPandaFreshWindow]
  /// (the stored cookie is fresh — the caller should simply reload). A
  /// shared/reused success is reported with `skipped: true` when no new
  /// request was made.
  Future<IgneousRefreshResult> refreshForSadPanda() async {
    if (advancedSetting.autoRefreshIgneous.isFalse) {
      log.info('Auto refresh igneous is disabled, skip for Sad Panda');
      return const IgneousRefreshResult(success: false, skipped: true);
    }
    DateTime? lastSuccess = _lastRefreshSuccessAt;
    if (_inFlightRefresh == null &&
        lastSuccess != null &&
        DateTime.now().difference(lastSuccess) < sadPandaFreshWindow) {
      log.info('Igneous already refreshed moments ago, skip for Sad Panda');
      return const IgneousRefreshResult(success: true, skipped: true);
    }
    IgneousRefreshResult result = await refreshIgneousDetailed(force: true);
    if (result.skipped) {
      return result;
    }
    if (result.success) {
      await advancedSetting.recordIgneousRefreshSuccess();
    } else {
      bool tripped = await advancedSetting.recordIgneousRefreshFailure();
      if (tripped) {
        toast('autoRefreshIgneousDisabled'.tr, isCenter: false, isShort: false);
      }
    }
    return result;
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
      if (advancedSetting.useIgneousRefreshApi.value) {
        return await _refreshViaApi();
      }
      return await _refreshViaDirectRequest();
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

  /// API mode: POST the base cookies to the refresh API and store the
  /// igneous it returns.
  Future<IgneousRefreshResult> _refreshViaApi() async {
    String apiUrl = advancedSetting.igneousRefreshApiUrl.value.trim();
    if (apiUrl.isEmpty) {
      return const IgneousRefreshResult(
          success: false, errorMessage: 'Sad panda');
    }

    Response response = await _dio!.post(
      apiUrl,
      data: {
        'cookies': {
          'ipb_member_id': userSetting.ipbMemberId.value.toString(),
          'ipb_pass_hash': userSetting.ipbPassHash.value!,
        },
      },
      options: Options(contentType: Headers.jsonContentType),
    );

    dynamic data = response.data;
    if (data is Map && data['ok'] == true) {
      String igneous = data['igneous']?.toString().trim() ?? '';
      if (_isUsableIgneous(igneous)) {
        await ehRequest.storeEHCookies([Cookie(EHConsts.igneousCookieName, igneous)]);
        log.info('Refresh igneous via API succeeded');
        return const IgneousRefreshResult(success: true);
      }
      return const IgneousRefreshResult(
          success: false, errorMessage: 'Sad panda');
    }

    String? apiError = data is Map ? data['error']?.toString() : null;
    log.error('Refresh igneous via API failed: $apiError');
    return IgneousRefreshResult(
        success: false,
        errorMessage: (apiError == null || apiError.isEmpty) ? 'Sad panda' : apiError);
  }

  /// Legacy mode: request the EX index with the base cookies (and no
  /// igneous) and keep the cookie the site issues in response.
  Future<IgneousRefreshResult> _refreshViaDirectRequest() async {
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

      if (!_isUsableIgneous(value)) {
        return const IgneousRefreshResult(
            success: false, errorMessage: 'Sad panda');
      }

      await ehRequest.storeEHCookies([Cookie(name, value)]);
      return const IgneousRefreshResult(success: true);
    }

    return const IgneousRefreshResult(
        success: false, errorMessage: 'Sad panda');
  }

  /// exhentai answers a request it will not honor with a placeholder
  /// igneous ("mystery"); empty and literal "null" are just as unusable.
  bool _isUsableIgneous(String value) {
    String v = value.trim().toLowerCase();
    return v.isNotEmpty && v != 'mystery' && v != 'null';
  }

  Future<void> _initDio() async {
    if (_dio != null) {
      return;
    }

    _systemProxyAddress = await getSystemProxyAddress();
    String Function(Uri) findProxy =
        await findProxySettingFunc(() => _systemProxyAddress);

    _dio = Dio(BaseOptions(
      connectTimeout:
          Duration(milliseconds: networkSetting.connectTimeout.value),
      receiveTimeout:
          Duration(milliseconds: networkSetting.receiveTimeout.value),
    ));

    /// This Dio follows the app's normal proxy setting (system / custom /
    /// Xray main node / direct) — the refresh rides the same egress as
    /// everything else; there is no dedicated igneous channel anymore.
    _dio!.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        HttpClient client = HttpClient();
        client.badCertificateCallback = (_, String host, __) {
          return networkSetting.allIPs.contains(host);
        };
        client.findProxy = findProxy;
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
