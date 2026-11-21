import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart' hide FormData, MultipartFile, Response, Value;
import 'package:path/path.dart';

import '../database/database.dart';
import '../database/dao/super_resolution_info_dao.dart';
import '../extension/get_logic_extension.dart';
import '../model/gallery_image.dart';
import '../setting/super_resolution_setting.dart';
import '../utils/archive_util.dart';
import '../utils/eh_executor.dart';
import '../utils/toast_util.dart';
import 'archive_download_service.dart';
import 'gallery_download/download_path_resolver.dart';
import 'gallery_download/gallery_download_service.dart';
import 'gallery_download/gallery_images_retainer.dart';
import 'jh_service.dart';
import 'log.dart';
import 'super_resolution_service.dart';

CloudSuperResolutionService cloudSuperResolutionService = CloudSuperResolutionService();

/// 内置提供商节点参数：写死在程序里，设置界面不显示。
/// 地址是公开端点，可以明文；CLIENT_KEY 由 CI 在构建时用
/// --dart-define=EHSR_BUILTIN_KEY=... 注入，未注入时为空，
/// 此时设置里的「内置提供商」选项不显示、也不可用。
const String builtinSchedulerUrl = 'https://ehsr.fur.boats';
const String builtinClientKey = String.fromEnvironment('EHSR_BUILTIN_KEY', defaultValue: '');

bool get builtinProviderAvailable => builtinClientKey.isNotEmpty;

/// 云端超分：把已下载的图片上传到调度器派发的 Modal 后端做超分，
/// 结果写回与本地超分完全相同的位置（<图片目录>/super_resolution/），
/// 进度共用 SuperResolutionService 的信息表与数据库，阅读器无感知。
/// 本地超分已配置时菜单优先本地，本服务只在未配置本地时被入口调用。
class CloudSuperResolutionService extends GetxController with JHLifeCircleBeanErrorCatch, GalleryImagesRetainer implements JHLifeCircleBean {
  EHExecutor executor = EHExecutor(concurrency: 1);

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(minutes: 5),
      sendTimeout: const Duration(minutes: 5),
    ),
  );

  @override
  List<JHLifeCircleBean> get initDependencies => super.initDependencies
    ..add(galleryDownloadService)
    ..add(archiveDownloadService)
    ..add(superResolutionService);

  @override
  Future<void> doInitBean() async {
    Get.put(this, permanent: true);
    super.onInit();
  }

  @override
  Future<void> doAfterBeanReady() async {}

  // ---------------- 配置 ----------------

  String? get schedulerUrl {
    if (superResolutionSetting.cloudUseBuiltin.value) {
      return builtinProviderAvailable ? builtinSchedulerUrl : null;
    }
    String url = superResolutionSetting.cloudCustomSchedulerUrl.value.trim();
    if (url.isEmpty) {
      return null;
    }
    return url.replaceAll(RegExp(r'/+$'), '');
  }

  String? get clientKey {
    if (superResolutionSetting.cloudUseBuiltin.value) {
      return builtinProviderAvailable ? builtinClientKey : null;
    }
    String key = superResolutionSetting.cloudCustomClientKey.value.trim();
    return key.isEmpty ? null : key;
  }

  bool get isReady => superResolutionSetting.cloudEnabled.value && schedulerUrl != null && clientKey != null;

  // ---------------- 入口 ----------------

  Future<bool> superResolve(int gid, SuperResolutionType type, {required int scale}) async {
    if (!isReady) {
      toast('cloudNotConfigured'.tr);
      return false;
    }

    if (type == SuperResolutionType.gallery) {
      GalleryDownloadInfo? galleryDownloadInfo = galleryDownloadService.galleryDownloadInfos[gid];
      if (galleryDownloadInfo?.downloadProgress.downloadStatus != DownloadStatus.downloaded) {
        toast('requireDownloadComplete'.tr);
        return false;
      }
    } else {
      ArchiveDownloadInfo? archiveDownloadInfo = archiveDownloadService.archiveDownloadInfos[gid];
      if (archiveDownloadInfo?.archiveStatus != ArchiveStatus.completed) {
        toast('requireDownloadComplete'.tr);
        return false;
      }
    }

    SuperResolutionInfo? info = superResolutionService.get(gid, type);
    if (info?.status == SuperResolutionStatus.success || info?.status == SuperResolutionStatus.running) {
      return true;
    }

    List<GalleryImage> rawImages;
    if (type == SuperResolutionType.gallery) {
      await galleryDownloadService.galleryDownloadInfos[gid]!.ensureImagesLoaded();
      rawImages = galleryDownloadService.galleryDownloadInfos[gid]!.images!.whereType<GalleryImage>().toList();
    } else {
      rawImages = await archiveDownloadService.getUnpackedImages(gid);
    }
    if (rawImages.isEmpty) {
      toast('cloudNotConfigured'.tr);
      return false;
    }

    if (info == null) {
      info = SuperResolutionInfo(
        type,
        SuperResolutionStatus.running,
        List.generate(rawImages.length, (_) => SuperResolutionStatus.running),
      );
      superResolutionService.superResolutionInfoTable.put(gid, type, info);
      await SuperResolutionInfoDao.insertSuperResolutionInfo(
        SuperResolutionInfoData(
          gid: gid,
          type: type.index,
          status: info.status.index,
          imageStatuses: info.imageStatuses.map((s) => s.index).join(SuperResolutionInfo.imageStatusesSeparator),
        ),
      );
      Directory(dirname(superResolutionService.computeImageOutputAbsolutePath(rawImages[0].path!))).createSync(recursive: true);
    } else {
      info.status = SuperResolutionStatus.running;
      for (int i = 0; i < info.imageStatuses.length; i++) {
        if (info.imageStatuses[i] != SuperResolutionStatus.success) {
          info.imageStatuses[i] = SuperResolutionStatus.running;
        }
      }
      await _persist(gid, info);
    }
    superResolutionService.updateSafely(['${SuperResolutionService.superResolutionId}::$gid']);

    toast('${'startProcess'.tr}: $gid');
    executor.scheduleTask(0, () => _doCloudSuperResolve(gid, type, scale, rawImages));
    return true;
  }

  // ---------------- 任务主体 ----------------

  Future<void> _doCloudSuperResolve(int gid, SuperResolutionType type, int scale, List<GalleryImage> rawImages) async {
    final bool needRetain = type == SuperResolutionType.gallery;
    if (needRetain) {
      await retainGalleryImages(gid);
    }
    String? backendUrl;
    String? sessionId;
    try {
      SuperResolutionInfo info = superResolutionService.get(gid, type)!;

      // 1. 向调度器要后端（可能要等唤醒）
      final dispatch = await _requestDispatch(gid, type);
      backendUrl = dispatch['backendUrl'] as String;
      sessionId = dispatch['sessionId'] as String;
      if (_aborted(gid, type)) {
        return;
      }

      // 2. 整理上传清单：gif 照本地超分的规矩直接复制，其余上传
      final String outDir = dirname(superResolutionService.computeImageOutputAbsolutePath(rawImages[0].path!));
      final List<_UploadEntry> uploads = [];
      for (int i = 0; i < rawImages.length; i++) {
        if (info.imageStatuses[i] == SuperResolutionStatus.success) {
          continue;
        }
        String rawPath = rawImages[i].path!;
        String inputAbsolutePath = DownloadPathResolver.computeImageDownloadAbsolutePathFromRelativePath(rawPath);
        if (extension(rawPath) == '.gif') {
          File(inputAbsolutePath).copySync(superResolutionService.computeImageOutputAbsolutePath(rawPath));
          info.imageStatuses[i] = SuperResolutionStatus.success;
          await _persist(gid, info);
          superResolutionService.updateSafely(['${SuperResolutionService.superResolutionId}::$gid', '${SuperResolutionService.superResolutionImageId}::$gid::$i']);
          continue;
        }
        uploads.add(
          _UploadEntry(
            imageIndex: i,
            inputAbsolutePath: inputAbsolutePath,
            outName: basenameWithoutExtension(rawPath) + '.png',
          ),
        );
      }

      if (uploads.isNotEmpty) {
        // 3. 开上传会话并逐张上传
        await _backendPost(backendUrl, '/sr/begin-upload', sessionId, data: {'total': uploads.length, 'scale': scale});
        for (final entry in uploads) {
          if (_aborted(gid, type)) {
            return;
          }
          FormData form = FormData.fromMap({
            'name': entry.outName,
            'file': await MultipartFile.fromFile(entry.inputAbsolutePath, filename: entry.outName),
          });
          await _dio.post(
            '$backendUrl/sr/upload-one',
            data: form,
            options: Options(headers: {'X-Session-Id': sessionId}),
          );
        }

        // 4. 轮询进度
        await _pollUntilDone(gid, type, info, backendUrl, sessionId, uploads);
        if (_aborted(gid, type)) {
          return;
        }

        // 5. 取结果包并解压到 super_resolution 目录
        Response<List<int>> result = await _dio.get<List<int>>(
          '$backendUrl/sr/result',
          options: Options(headers: {'X-Session-Id': sessionId}, responseType: ResponseType.bytes, receiveTimeout: const Duration(minutes: 15)),
        );
        String zipPath = join(outDir, '.cloud_result.zip');
        File(zipPath).writeAsBytesSync(result.data!);
        bool extracted = await extractZipArchive(zipPath, outDir);
        File(zipPath).deleteSync();
        if (!extracted) {
          throw Exception('extract result failed');
        }
        File errorsFile = File(join(outDir, '_errors.txt'));
        if (errorsFile.existsSync()) {
          errorsFile.deleteSync();
        }

        bool anyMissing = false;
        for (final entry in uploads) {
          if (File(join(outDir, entry.outName)).existsSync()) {
            info.imageStatuses[entry.imageIndex] = SuperResolutionStatus.success;
          } else {
            info.imageStatuses[entry.imageIndex] = SuperResolutionStatus.paused;
            anyMissing = true;
          }
        }
        await _persist(gid, info);
        superResolutionService.updateSafely(['${SuperResolutionService.superResolutionId}::$gid']);
        if (anyMissing) {
          throw Exception('some images failed on the backend');
        }
      }

      if (superResolutionService.get(gid, type) != null && info.imageStatuses.every((s) => s == SuperResolutionStatus.success)) {
        info.status = SuperResolutionStatus.success;
        await _persist(gid, info);
        superResolutionService.updateSafely(['${SuperResolutionService.superResolutionId}::$gid']);
        log.info('cloud super resolve success, gid:$gid');
      }
    } on _CloudAborted {
      // 用户暂停/删除，状态已由对方处理，这里静默退出
    } catch (e, s) {
      log.error('cloud super resolve failed, gid:$gid', e, s);
      SuperResolutionInfo? info = superResolutionService.get(gid, type);
      if (info != null && info.status == SuperResolutionStatus.running) {
        info.status = SuperResolutionStatus.paused;
        await _persist(gid, info);
        superResolutionService.updateSafely(['${SuperResolutionService.superResolutionId}::$gid']);
      }
      toast('${'cloudSuperResolutionFailed'.tr}: $e', isShort: false);
    } finally {
      if (backendUrl != null && sessionId != null) {
        try {
          await _dio.delete('$backendUrl/sr/session', options: Options(headers: {'X-Session-Id': sessionId}));
        } catch (_) {}
      }
      if (needRetain) {
        releaseGalleryImages(gid);
      }
    }
  }

  // ---------------- 归档下载时超分（整包链接交给后端） ----------------

  /// 供 ArchiveDownloadService 调用：把归档压缩包链接发给后端超分，
  /// 完成后把结果包写到 [savePath]（即本地归档文件应落的位置）。
  Future<bool> fetchSuperResolvedArchive({
    required String archiveUrl,
    required int scale,
    required String savePath,
    bool Function()? shouldAbort,
  }) async {
    if (!isReady) {
      return false;
    }
    bool aborted() => shouldAbort?.call() ?? false;
    String? backendUrl;
    String? sessionId;
    try {
      final dispatch = await _dispatch(aborted);
      backendUrl = dispatch['backendUrl'] as String;
      sessionId = dispatch['sessionId'] as String;
      if (aborted()) {
        return false;
      }
      await _backendPost(backendUrl, '/sr/submit-archive', sessionId, data: {'url': archiveUrl, 'scale': scale});
      // 等后端收包 + 处理完成
      DateTime deadline = DateTime.now().add(const Duration(hours: 2));
      while (DateTime.now().isBefore(deadline)) {
        if (aborted()) {
          return false;
        }
        Response response = await _dio.get('$backendUrl/sr/status', options: Options(headers: {'X-Session-Id': sessionId}));
        Map<String, dynamic> data = Map<String, dynamic>.from(response.data as Map);
        String stage = data['stage'] as String? ?? '';
        if (stage == 'done') {
          break;
        }
        if (stage == 'error') {
          log.error('cloud archive SR backend error: ${data['error']}');
          return false;
        }
        await Future.delayed(const Duration(seconds: 3));
      }
      if (DateTime.now().isAfter(deadline)) {
        return false;
      }
      Response<List<int>> result = await _dio.get<List<int>>(
        '$backendUrl/sr/result',
        options: Options(headers: {'X-Session-Id': sessionId}, responseType: ResponseType.bytes, receiveTimeout: const Duration(minutes: 30)),
      );
      File(savePath).writeAsBytesSync(result.data!);
      return true;
    } catch (e, s) {
      log.error('fetchSuperResolvedArchive failed', e, s);
      return false;
    } finally {
      if (backendUrl != null && sessionId != null) {
        try {
          await _dio.delete('$backendUrl/sr/session', options: Options(headers: {'X-Session-Id': sessionId}));
        } catch (_) {}
      }
    }
  }

  // ---------------- 画廊下载时超分（图片链接交给后端抓取） ----------------

  /// 供 GalleryDownloadService 调用：把一批图片链接发给后端超分，
  /// 成功返回结果 zip 的字节，失败/取消返回 null（调用方回退普通下载）。
  Future<List<int>?> superResolveByUrls({
    required List<String> urls,
    required int scale,
    bool Function()? shouldAbort,
  }) async {
    if (!isReady || urls.isEmpty) {
      return null;
    }
    bool aborted() => shouldAbort?.call() ?? false;
    String? backendUrl;
    String? sessionId;
    try {
      final dispatch = await _dispatch(aborted);
      backendUrl = dispatch['backendUrl'] as String;
      sessionId = dispatch['sessionId'] as String;
      if (aborted()) {
        return null;
      }
      Response submit = await _dio.post(
        '$backendUrl/sr/submit-urls',
        data: {'urls': urls, 'scale': scale},
        options: Options(headers: {'X-Session-Id': sessionId}),
      );
      Map<String, dynamic> submitData = Map<String, dynamic>.from(submit.data as Map);
      if (((submitData['accepted'] as num?)?.toInt() ?? 0) == 0) {
        log.error('cloud url SR: all urls rejected by backend');
        return null;
      }
      DateTime deadline = DateTime.now().add(const Duration(hours: 2));
      while (DateTime.now().isBefore(deadline)) {
        if (aborted()) {
          return null;
        }
        Response response = await _dio.get('$backendUrl/sr/status', options: Options(headers: {'X-Session-Id': sessionId}));
        Map<String, dynamic> data = Map<String, dynamic>.from(response.data as Map);
        String stage = data['stage'] as String? ?? '';
        if (stage == 'done') {
          break;
        }
        if (stage == 'error') {
          log.error('cloud url SR backend error: ${data['error']}');
          return null;
        }
        await Future.delayed(const Duration(seconds: 3));
      }
      if (DateTime.now().isAfter(deadline)) {
        return null;
      }
      Response<List<int>> result = await _dio.get<List<int>>(
        '$backendUrl/sr/result',
        options: Options(headers: {'X-Session-Id': sessionId}, responseType: ResponseType.bytes, receiveTimeout: const Duration(minutes: 30)),
      );
      return result.data;
    } catch (e, s) {
      log.error('superResolveByUrls failed', e, s);
      return null;
    } finally {
      if (backendUrl != null && sessionId != null) {
        try {
          await _dio.delete('$backendUrl/sr/session', options: Options(headers: {'X-Session-Id': sessionId}));
        } catch (_) {}
      }
    }
  }

  Future<Map<String, dynamic>> _dispatch(bool Function() aborted) async {
    String url = schedulerUrl!;
    Options options = Options(headers: {'X-Client-Key': clientKey});
    Response response = await _dio.post('$url/resolution_img', options: options);
    Map<String, dynamic> data = Map<String, dynamic>.from(response.data as Map);
    if (data['state'] == 'ready') {
      return data;
    }
    if (data['state'] != 'waking' || data['dispatchId'] == null) {
      throw Exception('scheduler dispatch failed: $data');
    }
    String dispatchId = data['dispatchId'] as String;
    DateTime deadline = DateTime.now().add(const Duration(minutes: 10));
    while (DateTime.now().isBefore(deadline)) {
      if (aborted()) {
        throw const _CloudAborted();
      }
      await Future.delayed(const Duration(seconds: 3));
      Response poll = await _dio.get('$url/resolution_img/status', queryParameters: {'dispatchId': dispatchId}, options: options);
      Map<String, dynamic> pollData = Map<String, dynamic>.from(poll.data as Map);
      if (pollData['state'] == 'ready') {
        return pollData;
      }
      if (pollData['state'] == 'error') {
        throw Exception('scheduler dispatch error: ${pollData['error']}');
      }
    }
    throw Exception('scheduler dispatch timeout');
  }

  Future<Map<String, dynamic>> _requestDispatch(int gid, SuperResolutionType type) {
    return _dispatch(() => _aborted(gid, type));
  }

  Future<void> _pollUntilDone(
    int gid,
    SuperResolutionType type,
    SuperResolutionInfo info,
    String backendUrl,
    String sessionId,
    List<_UploadEntry> uploads,
  ) async {
    DateTime deadline = DateTime.now().add(const Duration(hours: 2));
    while (DateTime.now().isBefore(deadline)) {
      if (_aborted(gid, type)) {
        throw const _CloudAborted();
      }
      Response response = await _dio.get('$backendUrl/sr/status', options: Options(headers: {'X-Session-Id': sessionId}));
      Map<String, dynamic> data = Map<String, dynamic>.from(response.data as Map);
      int done = (data['done'] as num?)?.toInt() ?? 0;
      bool changed = false;
      for (int k = 0; k < uploads.length && k < done; k++) {
        int imageIndex = uploads[k].imageIndex;
        if (info.imageStatuses[imageIndex] != SuperResolutionStatus.success) {
          info.imageStatuses[imageIndex] = SuperResolutionStatus.success;
          superResolutionService.updateSafely(['${SuperResolutionService.superResolutionImageId}::$gid::$imageIndex']);
          changed = true;
        }
      }
      if (changed) {
        await _persist(gid, info);
        superResolutionService.updateSafely(['${SuperResolutionService.superResolutionId}::$gid']);
      }
      String stage = data['stage'] as String? ?? '';
      if (stage == 'done') {
        return;
      }
      if (stage == 'error') {
        throw Exception('backend error: ${data['error']}');
      }
      await Future.delayed(const Duration(seconds: 3));
    }
    throw Exception('backend processing timeout');
  }

  Future<dynamic> _backendPost(String backendUrl, String path, String sessionId, {Object? data}) {
    return _dio.post('$backendUrl$path', data: data, options: Options(headers: {'X-Session-Id': sessionId}));
  }

  bool _aborted(int gid, SuperResolutionType type) {
    SuperResolutionInfo? info = superResolutionService.get(gid, type);
    return info == null || info.status == SuperResolutionStatus.paused;
  }

  Future<void> _persist(int gid, SuperResolutionInfo info) async {
    await SuperResolutionInfoDao.updateSuperResolutionInfo(
      SuperResolutionInfoCompanion(
        gid: Value(gid),
        type: Value(info.type.index),
        status: Value(info.status.index),
        imageStatuses: Value(info.imageStatuses.map((s) => s.index).join(SuperResolutionInfo.imageStatusesSeparator)),
      ),
    );
  }
}

class _UploadEntry {
  final int imageIndex;
  final String inputAbsolutePath;
  final String outName;

  const _UploadEntry({required this.imageIndex, required this.inputAbsolutePath, required this.outName});
}

class _CloudAborted implements Exception {
  const _CloudAborted();
}

/// 云端超分倍率选择（2x / 3x / 4x，后端固定 Real-ESRGAN-Anime 先 4x 再缩放）
Future<int?> pickCloudSuperResolutionScale() {
  return Get.dialog<int>(
    SimpleDialog(
      title: Text('superResolutionScale'.tr),
      children: [2, 3, 4]
          .map(
            (s) => SimpleDialogOption(
              onPressed: () => Get.back(result: s),
              child: Text('${s}x'),
            ),
          )
          .toList(),
    ),
  );
}
