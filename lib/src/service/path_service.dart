import 'dart:io';

import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_data_transfer_service.dart';
import 'jh_service.dart';

PathService pathService = PathService();

class PathService with JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  /// visible for all
  late Directory tempDir;

  /// visible on ios&windows&macos
  Directory? appDocDir;

  /// visible on windows
  Directory? appSupportDir;

  /// visible on android
  Directory? externalStorageDir;

  Directory? systemDownloadDir;

  /// Windows portable mode: the portable package ships a `portable.flag`
  /// file next to the executable, and all app/account data then lives in
  /// the `JH_Data` folder beside the executable instead of AppData.
  bool isPortableWindows = false;
  Directory? portableDataDir;

  @override
  List<JHLifeCircleBean> get initDependencies => [];

  @override
  Future<void> doInitBean() async {
    await Future.wait([
      getTemporaryDirectory().then((value) => tempDir = value),
      getApplicationDocumentsDirectory().then((value) => appDocDir = value).catchError((error) => null),
      getApplicationSupportDirectory().then((value) => appSupportDir = value).catchError((error) => null),
      getExternalStorageDirectory().then((value) => externalStorageDir = value).catchError((error) => null),
      getDownloadsDirectory().then((value) => systemDownloadDir = value).catchError((error) => null),
    ]);
    if (Platform.isWindows) {
      _applyWindowsPortableOverride();
    }
    // A staged full-data import is swapped in here, before any consumer
    // opens the database or the GetStorage container.
    AppDataTransferService.applyPendingImport(getVisibleDir().path);
  }

  /// Portable detection: a `portable.flag` file or an existing `JH_Data`
  /// folder next to the executable. The installed build ships neither, so
  /// it keeps the path_provider defaults (AppData, no admin rights needed).
  void _applyWindowsPortableOverride() {
    try {
      String exeDir = p.dirname(Platform.resolvedExecutable);
      Directory dataDir = Directory(p.join(exeDir, 'JH_Data'));
      bool flagged = File(p.join(exeDir, 'portable.flag')).existsSync();
      if (!flagged && !dataDir.existsSync()) {
        return;
      }
      dataDir.createSync(recursive: true);
      isPortableWindows = true;
      portableDataDir = dataDir;
      appDocDir = dataDir;
      appSupportDir = dataDir;
    } catch (_) {
      // Fall back to the path_provider defaults if the portable folder
      // cannot be created (e.g. read-only install location).
    }
  }

  @override
  Future<void> doAfterBeanReady() async {}

  Directory getVisibleDir() {
    if (Platform.isAndroid && externalStorageDir != null) {
      return externalStorageDir!;
    }
    if (GetPlatform.isWindows && appSupportDir != null) {
      return appSupportDir!;
    }
    if (GetPlatform.isLinux && appSupportDir != null) {
      return appSupportDir!;
    }
    return appDocDir ?? appSupportDir ?? systemDownloadDir!;
  }
}
