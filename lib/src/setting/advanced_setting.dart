import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/service/log.dart';

import '../service/jh_service.dart';

AdvancedSetting advancedSetting = AdvancedSetting();

class AdvancedSetting with JHLifeCircleBeanWithConfigStorage implements JHLifeCircleBean {
  RxBool enableLogging = true.obs;
  RxBool enableVerboseLogging = kDebugMode.obs;
  RxBool enableCheckUpdate = true.obs;
  RxBool enableCheckClipboard = true.obs;
  RxBool inNoImageMode = false.obs;

  /// Default endpoint of the igneous refresh API (the self-hosted
  /// igneous_refresh service).
  static const String defaultIgneousRefreshApiUrl = 'https://exrefresh.fur.boats/ign_refresh';

  /// Automatic igneous refresh (e.g. after a Sad Panda). On by default;
  /// turns itself off after [igneousRefreshMaxFailStreak] consecutive
  /// failures so a broken setup does not retry forever.
  RxBool autoRefreshIgneous = true.obs;

  /// Consecutive automatic-refresh failures; reset on any success.
  RxInt igneousRefreshFailStreak = 0.obs;

  static const int igneousRefreshMaxFailStreak = 5;

  /// Refresh mode: true = call the refresh API ([igneousRefreshApiUrl]),
  /// false = legacy direct request to the EX index over the normal
  /// network path. On by default: the API is the primary refresh path.
  RxBool useIgneousRefreshApi = true.obs;
  RxString igneousRefreshApiUrl = defaultIgneousRefreshApiUrl.obs;

  @override
  ConfigEnum get configEnum => ConfigEnum.advancedSetting;

  @override
  void applyBeanConfig(String configString) {
    Map map = jsonDecode(configString);

    enableLogging.value = map['enableLogging'];
    enableVerboseLogging.value = map['enableVerboseLogging'] ?? enableVerboseLogging.value;
    enableCheckUpdate.value = map['enableCheckUpdate'] ?? enableCheckUpdate.value;
    enableCheckClipboard.value = map['enableCheckClipboard'] ?? enableCheckClipboard.value;
    inNoImageMode.value = map['inNoImageMode'] ?? inNoImageMode.value;
    autoRefreshIgneous.value = map['autoRefreshIgneous'] ?? autoRefreshIgneous.value;
    igneousRefreshFailStreak.value = map['igneousRefreshFailStreak'] ?? igneousRefreshFailStreak.value;
    useIgneousRefreshApi.value = map['useIgneousRefreshApi'] ?? useIgneousRefreshApi.value;
    igneousRefreshApiUrl.value = map['igneousRefreshApiUrl'] ?? igneousRefreshApiUrl.value;
  }

  @override
  String toConfigString() {
    return jsonEncode({
      'enableLogging': enableLogging.value,
      'enableVerboseLogging': enableVerboseLogging.value,
      'enableCheckUpdate': enableCheckUpdate.value,
      'enableCheckClipboard': enableCheckClipboard.value,
      'inNoImageMode': inNoImageMode.value,
      'autoRefreshIgneous': autoRefreshIgneous.value,
      'igneousRefreshFailStreak': igneousRefreshFailStreak.value,
      'useIgneousRefreshApi': useIgneousRefreshApi.value,
      'igneousRefreshApiUrl': igneousRefreshApiUrl.value,
    });
  }

  @override
  Future<void> doInitBean() async {}

  @override
  void doAfterBeanReady() {}

  Future<void> saveEnableLogging(bool enableLogging) async {
    log.debug('saveEnableLogging:$enableLogging');
    this.enableLogging.value = enableLogging;
    await saveBeanConfig();
  }

  Future<void> saveEnableVerboseLogging(bool enableVerboseLogging) async {
    log.debug('saveEnableVerboseLogging:$enableVerboseLogging');
    this.enableVerboseLogging.value = enableVerboseLogging;
    await saveBeanConfig();
  }

  Future<void> saveEnableCheckUpdate(bool enableCheckUpdate) async {
    log.debug('saveEnableCheckUpdate:$enableCheckUpdate');
    this.enableCheckUpdate.value = enableCheckUpdate;
    await saveBeanConfig();
  }

  Future<void> saveEnableCheckClipboard(bool enableCheckClipboard) async {
    log.debug('saveEnableCheckClipboard:$enableCheckClipboard');
    this.enableCheckClipboard.value = enableCheckClipboard;
    await saveBeanConfig();
  }

  Future<void> saveInNoImageMode(bool inNoImageMode) async {
    log.debug('saveInNoImageMode:$inNoImageMode');
    this.inNoImageMode.value = inNoImageMode;
    await saveBeanConfig();
  }

  Future<void> saveAutoRefreshIgneous(bool value) async {
    log.debug('saveAutoRefreshIgneous:$value');
    autoRefreshIgneous.value = value;
    if (value) {
      // Re-enabling by hand starts with a clean failure slate.
      igneousRefreshFailStreak.value = 0;
    }
    await saveBeanConfig();
  }

  /// Records one automatic-refresh outcome. Returns true when this failure
  /// just tripped the auto-disable threshold.
  Future<bool> recordIgneousRefreshFailure() async {
    igneousRefreshFailStreak.value = igneousRefreshFailStreak.value + 1;
    bool tripped = igneousRefreshFailStreak.value >= igneousRefreshMaxFailStreak;
    if (tripped) {
      autoRefreshIgneous.value = false;
      igneousRefreshFailStreak.value = 0;
    }
    await saveBeanConfig();
    return tripped;
  }

  Future<void> recordIgneousRefreshSuccess() async {
    if (igneousRefreshFailStreak.value == 0) {
      return;
    }
    igneousRefreshFailStreak.value = 0;
    await saveBeanConfig();
  }

  Future<void> saveIgneousRefreshApi({required bool useApi, required String apiUrl}) async {
    log.debug('saveIgneousRefreshApi:$useApi,$apiUrl');
    useIgneousRefreshApi.value = useApi;
    igneousRefreshApiUrl.value = apiUrl;
    await saveBeanConfig();
  }
}
