import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../database/database.dart';

/// Full app-data export / import, on top of the built-in partial
/// config export (which only covers read records, quick search, search
/// history, block rules and history).
///
/// The bundle is a zip holding the files that make up the app's data in
/// the visible dir:
/// - `db.sqlite` — every bean config (account, all settings, Xray nodes
///   and subscriptions), history, block rules, download metadata;
/// - `jhentai.gs` / `jhentai.bak` — the GetStorage container;
/// - `cookies/` and `EBWebView/` — desktop webview data (login session),
///   minus cache folders.
///
/// The format is platform-independent, so a bundle moves data between the
/// Windows installer build, the Windows portable build and Android.
///
/// Import never touches the live files: the bundle is extracted into an
/// `appdata_import` staging folder and swapped in by
/// [applyPendingImport] at the next startup, before the database or
/// GetStorage is opened. Absolute paths that only make sense on the
/// source machine (download/save paths) are stripped from the staged
/// database so the target install falls back to its own defaults.
class AppDataTransferService {
  static const String stagingDirName = 'appdata_import';
  static const String _readyMarker = 'READY';
  static const String manifestName = 'manifest.json';
  static const String manifestFormat = 'JHenTaiAppData';
  static const int manifestVersion = 1;

  static const List<String> _dataFiles = [
    'db.sqlite',
    'jhentai.gs',
    'jhentai.bak',
  ];
  static const List<String> _dataDirs = ['cookies', 'EBWebView'];
  static const Set<String> _skippedDirNames = {
    'Cache',
    'Code Cache',
    'GPUCache',
    'DawnCache',
    'ShaderCache',
    'GrShaderCache',
    'GraphiteDawnCache',
  };

  // --------------------------------------------------------------------
  // Export
  // --------------------------------------------------------------------

  static Future<Uint8List> exportAppData({
    required String visibleDirPath,
    required String tempDirPath,
  }) async {
    Directory workDir = Directory(p.join(tempDirPath, 'appdata_export'));
    if (workDir.existsSync()) {
      workDir.deleteSync(recursive: true);
    }
    workDir.createSync(recursive: true);

    try {
      // Consistent snapshot of the live database without disturbing it.
      File dbSnapshot = File(p.join(workDir.path, 'db.sqlite'));
      String escapedPath = dbSnapshot.path.replaceAll("'", "''");
      await appDb.customStatement("VACUUM INTO '$escapedPath'");

      Archive archive = Archive();
      PackageInfo packageInfo = await PackageInfo.fromPlatform();
      Map<String, dynamic> manifest = {
        'format': manifestFormat,
        'version': manifestVersion,
        'appVersion': packageInfo.version,
        'platform': Platform.operatingSystem,
        'exportedAt': DateTime.now().toIso8601String(),
      };
      archive.addFile(ArchiveFile(
          manifestName, utf8.encode(jsonEncode(manifest)).length, utf8.encode(jsonEncode(manifest))));

      archive.addFile(ArchiveFile(
          'db.sqlite', dbSnapshot.lengthSync(), dbSnapshot.readAsBytesSync()));

      for (String name in _dataFiles.skip(1)) {
        File file = File(p.join(visibleDirPath, name));
        if (file.existsSync()) {
          archive.addFile(
              ArchiveFile(name, file.lengthSync(), file.readAsBytesSync()));
        }
      }

      for (String dirName in _dataDirs) {
        Directory dir = Directory(p.join(visibleDirPath, dirName));
        if (!dir.existsSync()) {
          continue;
        }
        for (FileSystemEntity entity
            in dir.listSync(recursive: true, followLinks: false)) {
          if (entity is! File) {
            continue;
          }
          String relative = p.relative(entity.path, from: visibleDirPath);
          if (p
              .split(relative)
              .any((segment) => _skippedDirNames.contains(segment))) {
            continue;
          }
          try {
            archive.addFile(ArchiveFile(
                relative, entity.lengthSync(), entity.readAsBytesSync()));
          } catch (_) {
            // A file locked by a running webview must not fail the whole
            // export; it is simply left out.
          }
        }
      }

      List<int>? encoded = ZipEncoder().encode(archive);
      if (encoded == null) {
        throw StateError('Failed to encode app data zip');
      }
      return Uint8List.fromList(encoded);
    } finally {
      try {
        workDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  // --------------------------------------------------------------------
  // Import: validate + stage. Returns false for an invalid bundle.
  // --------------------------------------------------------------------

  static Future<bool> stageImport({
    required String visibleDirPath,
    required List<int> zipBytes,
  }) async {
    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zipBytes);
    } catch (_) {
      return false;
    }

    ArchiveFile? manifestFile = archive.findFile(manifestName);
    if (manifestFile == null) {
      return false;
    }
    try {
      Map<String, dynamic> manifest =
          jsonDecode(utf8.decode(manifestFile.content as List<int>));
      if (manifest['format'] != manifestFormat ||
          manifest['version'] != manifestVersion) {
        return false;
      }
    } catch (_) {
      return false;
    }
    if (archive.findFile('db.sqlite') == null) {
      return false;
    }

    Directory staging = Directory(p.join(visibleDirPath, stagingDirName));
    if (staging.existsSync()) {
      staging.deleteSync(recursive: true);
    }
    staging.createSync(recursive: true);

    for (ArchiveFile file in archive.files) {
      if (!file.isFile) {
        continue;
      }
      String name = file.name.replaceAll('\\', '/');
      if (name == manifestName) {
        continue;
      }
      if (!_isWhitelisted(name)) {
        continue;
      }
      File target = File(p.join(staging.path, name));
      target.parent.createSync(recursive: true);
      target.writeAsBytesSync(file.content as List<int>);
    }

    _sanitizeStagedDownloadPaths(File(p.join(staging.path, 'db.sqlite')));

    File(p.join(staging.path, _readyMarker)).writeAsStringSync('ok');
    return true;
  }

  static bool _isWhitelisted(String name) {
    List<String> segments = name.split('/');
    if (segments.any((s) => s == '..' || s.isEmpty)) {
      return false;
    }
    if (segments.length == 1) {
      return _dataFiles.contains(name);
    }
    return _dataDirs.contains(segments.first);
  }

  /// Download/save paths are absolute and machine-specific: strip them
  /// from the staged downloadSetting config so the target install uses
  /// its own defaults (and, on Windows, asks on first download again).
  static void _sanitizeStagedDownloadPaths(File stagedDb) {
    if (!stagedDb.existsSync()) {
      return;
    }
    Database? db;
    try {
      db = sqlite3.open(stagedDb.path);
      ResultSet rows = db.select(
          "SELECT value FROM local_config WHERE config_key = 'downloadSetting' AND sub_config_key = ''");
      if (rows.isEmpty) {
        return;
      }
      Map<String, dynamic> config =
          jsonDecode(rows.first['value'] as String) as Map<String, dynamic>;
      config.remove('downloadPath');
      config.remove('singleImageSavePath');
      config.remove('extraGalleryScanPath');
      config.remove('downloadPathConfigured');
      db.execute(
          "UPDATE local_config SET value = ? WHERE config_key = 'downloadSetting' AND sub_config_key = ''",
          [jsonEncode(config)]);
    } catch (_) {
      // Sanitizing is best-effort: an untouched staged DB still imports.
    } finally {
      db?.dispose();
    }
  }

  // --------------------------------------------------------------------
  // Startup: swap a staged import in. Called from PathService before the
  // database or GetStorage has been opened. Never throws.
  // --------------------------------------------------------------------

  static void applyPendingImport(String visibleDirPath) {
    try {
      Directory staging = Directory(p.join(visibleDirPath, stagingDirName));
      if (!staging.existsSync() ||
          !File(p.join(staging.path, _readyMarker)).existsSync()) {
        return;
      }

      for (String name in _dataFiles) {
        File staged = File(p.join(staging.path, name));
        if (!staged.existsSync()) {
          continue;
        }
        if (name == 'db.sqlite') {
          // A leftover WAL/journal belongs to the old database and must
          // not be replayed into the imported one.
          for (String suffix in ['-wal', '-shm', '-journal']) {
            File stale = File(p.join(visibleDirPath, 'db.sqlite$suffix'));
            if (stale.existsSync()) {
              stale.deleteSync();
            }
          }
        }
        File live = File(p.join(visibleDirPath, name));
        if (live.existsSync()) {
          live.deleteSync();
        }
        staged.renameSync(live.path);
      }

      for (String name in _dataDirs) {
        Directory stagedDir = Directory(p.join(staging.path, name));
        if (!stagedDir.existsSync()) {
          continue;
        }
        Directory liveDir = Directory(p.join(visibleDirPath, name));
        if (liveDir.existsSync()) {
          liveDir.deleteSync(recursive: true);
        }
        stagedDir.renameSync(liveDir.path);
      }

      staging.deleteSync(recursive: true);
      debugPrint('AppDataTransfer: staged import applied');
    } catch (e) {
      debugPrint('AppDataTransfer: failed to apply staged import: $e');
    }
  }
}
