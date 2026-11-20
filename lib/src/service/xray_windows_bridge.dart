import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// Windows counterpart of the Android Kotlin `XrayBridge`.
///
/// The Android bridge talks to libXray through JNI; on Windows the same
/// libXray build ships as `libXray.dll` next to the executable and exposes
/// the identical JSON-envelope invoke API through the C exports
/// `CGoInvoke` / `CGoFree`. All bridge logic that lives in Kotlin on
/// Android (share-link conversion, hysteria2 pin preprocessing, base64
/// subscription decoding, single-inbound config building) is ported here
/// one-to-one so both platforms behave the same.
///
/// Every invoke call is blocking FFI into Go, so calls run in a short-lived
/// background isolate; the core state itself is process-global inside the
/// DLL, so starting it from one isolate and querying it from another works.
class XrayWindowsBridge {
  static const int _apiVersion = 3;

  static String get _dllPath =>
      p.join(p.dirname(Platform.resolvedExecutable), 'libXray.dll');

  // --------------------------------------------------------------------
  // libXray invoke (FFI)
  // --------------------------------------------------------------------

  static Future<Map<String, dynamic>> _invoke(
      String method, Map<String, dynamic> payload) async {
    String requestJson = jsonEncode({
      'apiVersion': _apiVersion,
      'method': method,
      'payload': payload,
    });
    String dllPath = _dllPath;
    String raw = await Isolate.run(() => _invokeNative(dllPath, requestJson));
    if (raw.isEmpty) {
      throw StateError('libXray $method returned an empty response');
    }
    Map<String, dynamic> response =
        Map<String, dynamic>.from(jsonDecode(raw) as Map);
    if (response['success'] != true) {
      dynamic error = response['error'];
      throw StateError(
          error is String && error.isNotEmpty ? error : 'libXray $method failed');
    }
    dynamic data = response['data'];
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  }

  static String _invokeNative(String dllPath, String requestJson) {
    DynamicLibrary lib = DynamicLibrary.open(dllPath);
    var invoke = lib.lookupFunction<
        Pointer<Utf8> Function(Pointer<Utf8>),
        Pointer<Utf8> Function(Pointer<Utf8>)>('CGoInvoke');
    var free = lib.lookupFunction<Void Function(Pointer<Utf8>),
        void Function(Pointer<Utf8>)>('CGoFree');
    Pointer<Utf8> requestPtr = requestJson.toNativeUtf8();
    Pointer<Utf8> responsePtr = nullptr;
    try {
      responsePtr = invoke(requestPtr);
      if (responsePtr == nullptr) {
        return '';
      }
      return responsePtr.toDartString();
    } finally {
      malloc.free(requestPtr);
      if (responsePtr != nullptr) {
        free(responsePtr);
      }
    }
  }

  // --------------------------------------------------------------------
  // Core lifecycle
  // --------------------------------------------------------------------

  /// Validates and (re)starts the core with the single-node config.
  /// Empty link = direct (freedom outbound).
  static Future<void> start({
    String? mainLink,
    required int mainPort,
  }) async {
    Map<String, dynamic> mainOutbound = await _outboundFor(mainLink, 'out-main');
    Map<String, dynamic> config = {
      'log': {'loglevel': 'warning'},
      'inbounds': [
        _socksInbound('in-main', mainPort),
      ],
      'outbounds': [
        mainOutbound,
        {'tag': 'direct', 'protocol': 'freedom'},
      ],
      'routing': {
        'domainStrategy': 'AsIs',
        'rules': [
          _routingRule('in-main', 'out-main'),
        ],
      },
    };
    String configJson = jsonEncode(config);
    // testXray refuses to run while a managed core instance exists, so
    // stop the running core first (same as the Android bridge).
    if (await isRunning()) {
      await _invoke('stopXray', {});
    }
    await _invoke('testXray', {'xrayJson': configJson});
    await _invoke('runXray', {'xrayJson': configJson});
  }

  static Future<void> stop() async {
    if (await isRunning()) {
      await _invoke('stopXray', {});
    }
  }

  static Future<bool> isRunning() async {
    Map<String, dynamic> data = await _invoke('getXrayState', {});
    return data['running'] == true;
  }

  static Future<String> version() async {
    Map<String, dynamic> data = await _invoke('xrayVersion', {});
    return data['version']?.toString() ?? '';
  }

  static Map<String, dynamic> _socksInbound(String tag, int port) {
    return {
      'tag': tag,
      'listen': '127.0.0.1',
      'port': port,
      'protocol': 'socks',
      'settings': {'auth': 'noauth', 'udp': true},
      'sniffing': {
        'enabled': true,
        'destOverride': ['http', 'tls'],
      },
    };
  }

  static Map<String, dynamic> _routingRule(
      String inboundTag, String outboundTag) {
    return {
      'type': 'field',
      'inboundTag': [inboundTag],
      'outboundTag': outboundTag,
    };
  }

  static Future<Map<String, dynamic>> _outboundFor(
      String? link, String tag) async {
    if (link == null || link.trim().isEmpty) {
      return {'tag': tag, 'protocol': 'freedom'};
    }
    Map<String, dynamic> outbound = await _convertSingleOutboundAsync(link);
    outbound['tag'] = tag;
    return outbound;
  }

  // --------------------------------------------------------------------
  // Share-link conversion (port of the Kotlin bridge logic)
  // --------------------------------------------------------------------

  /// Parses pasted text (share links, one per line, or a base64
  /// subscription body) into per-link results:
  /// {"nodes": [{name, link}], "failures": [{link, reason}]}.
  static Future<Map<String, dynamic>> convertLinks(String text) async {
    String body = await _extractShareLinkText(text);
    List<String> links = body
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.contains('://'))
        .toList();
    List<Map<String, String>> nodes = [];
    List<Map<String, String>> failures = [];
    for (String link in links) {
      try {
        Map<String, dynamic> outbound =
            await _convertSingleOutboundAsync(link);
        String tag = outbound['tag']?.toString() ?? '';
        nodes.add({
          'name': tag.isNotEmpty ? tag : _fallbackName(link),
          'link': link,
        });
      } catch (e) {
        String reason = e is StateError ? e.message : e.toString();
        failures.add({
          'link': _linkSummary(link),
          'reason': reason.isNotEmpty ? reason : 'parse failed',
        });
      }
    }
    return {'nodes': nodes, 'failures': failures};
  }

  /// Raw libXray subscription decoding (Age-armored bodies only; base64
  /// handling lives in [_extractShareLinkText], exactly like Android).
  static Future<String> decodeSubscriptionText(String text) async {
    Map<String, dynamic> data =
        await _invoke('decodeSubscriptionText', {'text': text});
    return data['text']?.toString() ?? '';
  }

  static Future<List<dynamic>> _convertOutboundsAsync(String text) async {
    Map<String, dynamic> data =
        await _invoke('convertShareLinksToXrayJson', {'text': text});
    dynamic outbounds = data['outbounds'];
    return outbounds is List ? outbounds : [];
  }

  static Future<Map<String, dynamic>> _convertSingleOutboundAsync(
      String link) async {
    String effectiveLink = link;
    String? pinHex;
    if (_isHy2(link)) {
      var fix = _preprocessHy2(link);
      effectiveLink = fix.strippedLink;
      pinHex = fix.pinHex;
    }
    List<dynamic> outbounds = await _convertOutboundsAsync(effectiveLink);
    if (outbounds.isEmpty) {
      throw StateError('Cannot parse node link');
    }
    Map<String, dynamic> outbound =
        Map<String, dynamic>.from(outbounds.first as Map);
    if (pinHex != null) {
      _injectPinnedPeerCert(outbound, pinHex);
    }
    return outbound;
  }

  // --------------------------------------------------------------------
  // hysteria2 preprocessing
  //
  // LibXray's share parser deliberately rejects hysteria2 links carrying
  // pinSHA256 or insecure=true: the current Xray core removed
  // "allowInsecure" entirely and expresses pinning as the TLS setting
  // "pinnedPeerCertSha256" (comma-separated hex). So: strip the pin from
  // the link, convert, then inject it into the outbound. insecure hy2
  // links cannot be honored at all and fail with an explicit error.
  // --------------------------------------------------------------------

  static bool _isHy2(String link) {
    String scheme = link.split('://').first.toLowerCase();
    return scheme == 'hysteria2' || scheme == 'hy2';
  }

  static ({String strippedLink, String? pinHex}) _preprocessHy2(String link) {
    int fragmentIndex = link.indexOf('#');
    String fragment = fragmentIndex >= 0 ? link.substring(fragmentIndex) : '';
    String noFragment =
        fragmentIndex >= 0 ? link.substring(0, fragmentIndex) : link;
    int queryIndex = noFragment.indexOf('?');
    if (queryIndex < 0) {
      return (strippedLink: link, pinHex: null);
    }
    String base = noFragment.substring(0, queryIndex);
    String query = noFragment.substring(queryIndex + 1);
    String? pinHex;
    List<String> kept = [];
    for (String param in query.split('&')) {
      if (param.isEmpty) {
        continue;
      }
      int eq = param.indexOf('=');
      String key = eq >= 0 ? param.substring(0, eq) : param;
      String value = eq >= 0 ? param.substring(eq + 1) : '';
      switch (key) {
        case 'pinSHA256':
          String normalized = value.replaceAll(':', '').toLowerCase();
          if (normalized.length == 64 &&
              normalized.split('').every((c) =>
                  (c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57) ||
                  (c.codeUnitAt(0) >= 97 && c.codeUnitAt(0) <= 102))) {
            pinHex = normalized;
          } else {
            // Not a usable pin: keep the param so the core rejects the
            // link with its own error instead of dropping the pin silently.
            kept.add(param);
          }
          break;
        case 'insecure':
        case 'allowInsecure':
          if (value == '1' || value.toLowerCase() == 'true') {
            throw StateError('insecure hy2 not supported by core');
          }
          kept.add(param);
          break;
        default:
          kept.add(param);
      }
    }
    if (pinHex == null) {
      return (strippedLink: link, pinHex: null);
    }
    StringBuffer rebuilt = StringBuffer(base);
    if (kept.isNotEmpty) {
      rebuilt.write('?');
      rebuilt.write(kept.join('&'));
    }
    rebuilt.write(fragment);
    return (strippedLink: rebuilt.toString(), pinHex: pinHex);
  }

  static void _injectPinnedPeerCert(
      Map<String, dynamic> outbound, String pinHex) {
    Map<String, dynamic> stream = outbound['streamSettings'] is Map
        ? Map<String, dynamic>.from(outbound['streamSettings'] as Map)
        : <String, dynamic>{};
    outbound['streamSettings'] = stream;
    if ((stream['security']?.toString() ?? '').isEmpty) {
      stream['security'] = 'tls';
    }
    Map<String, dynamic> tls = stream['tlsSettings'] is Map
        ? Map<String, dynamic>.from(stream['tlsSettings'] as Map)
        : <String, dynamic>{};
    stream['tlsSettings'] = tls;
    tls['pinnedPeerCertSha256'] = pinHex;
  }

  /// Short, credential-free summary of a link for failure reporting.
  static String _linkSummary(String link) {
    String scheme = link.contains('://') ? link.split('://').first : '';
    String afterScheme =
        link.contains('://') ? link.substring(link.indexOf('://') + 3) : link;
    String hostPort = afterScheme.split('/').first.split('?').first;
    int at = hostPort.indexOf('@');
    if (at >= 0) {
      hostPort = hostPort.substring(at + 1);
    }
    return scheme.isEmpty ? link.substring(0, link.length < 40 ? link.length : 40) : '$scheme://$hostPort';
  }

  static String _fallbackName(String link) {
    String fragment =
        link.contains('#') ? link.substring(link.indexOf('#') + 1) : '';
    if (fragment.isNotEmpty) {
      try {
        return Uri.decodeComponent(fragment.replaceAll('+', ' '));
      } catch (_) {
        return fragment;
      }
    }
    try {
      String afterScheme =
          link.contains('://') ? link.substring(link.indexOf('://') + 3) : '';
      String hostPort = afterScheme.split('/').first.split('?').first;
      int at = hostPort.indexOf('@');
      if (at >= 0) {
        hostPort = hostPort.substring(at + 1);
      }
      String host = hostPort.split(':').first;
      return host.isNotEmpty ? host : 'node';
    } catch (_) {
      return 'node';
    }
  }

  // --------------------------------------------------------------------
  // Subscription body normalization
  //
  // LibXray's decodeSubscriptionText only decrypts Age-armored bodies and
  // passes everything else through unchanged — it does NOT base64-decode,
  // so base64 handling lives here: plain link lists pass through, Age
  // bodies still go to libXray, and base64 is tried both as one whole-body
  // blob (the common format) and per line (some panels encode every link
  // separately).
  // --------------------------------------------------------------------

  static Future<String> _extractShareLinkText(String text) async {
    String trimmed = text.trim();
    if (trimmed.split('\n').any((line) => line.contains('://'))) {
      return trimmed;
    }
    String? ageDecoded;
    try {
      ageDecoded = await decodeSubscriptionText(trimmed);
    } catch (_) {
      ageDecoded = null;
    }
    if (ageDecoded != null &&
        ageDecoded.trim().isNotEmpty &&
        ageDecoded.split('\n').any((line) => line.contains('://'))) {
      return ageDecoded.trim();
    }
    String? base64Decoded = _decodeBase64Body(trimmed);
    if (base64Decoded != null) {
      return base64Decoded;
    }
    return trimmed;
  }

  static String? _decodeBase64Body(String text) {
    String? whole = _tryDecodeBase64(text);
    if (whole != null) {
      if (whole.split('\n').any((line) => line.contains('://'))) {
        return whole.trim();
      }
      // The blob may itself wrap per-line base64.
      String? perLine = _decodePerLineBase64(whole);
      if (perLine != null) {
        return perLine;
      }
    }
    return _decodePerLineBase64(text);
  }

  static String? _decodePerLineBase64(String text) {
    StringBuffer out = StringBuffer();
    int hits = 0;
    for (String rawLine in text.split('\n')) {
      String line = rawLine.trim();
      if (line.isEmpty) {
        continue;
      }
      if (line.contains('://')) {
        out.writeln(line);
        hits++;
        continue;
      }
      String? decoded = _tryDecodeBase64(line);
      if (decoded == null) {
        continue;
      }
      String decodedTrimmed = decoded.trim();
      if (decodedTrimmed.split('\n').any((l) => l.contains('://'))) {
        out.writeln(decodedTrimmed);
        hits++;
      }
    }
    return hits > 0 ? out.toString().trim() : null;
  }

  static String? _tryDecodeBase64(String text) {
    StringBuffer cleaned = StringBuffer();
    for (int i = 0; i < text.length; i++) {
      String c = text[i];
      if (c == '-') {
        cleaned.write('+');
      } else if (c == '_') {
        cleaned.write('/');
      } else if (c.trim().isNotEmpty) {
        cleaned.write(c);
      }
    }
    String cleanedStr = cleaned.toString();
    if (cleanedStr.isEmpty || cleanedStr.length % 4 == 1) {
      return null;
    }
    String core = cleanedStr.replaceAll(RegExp(r'=+$'), '');
    if (core.isEmpty) {
      return null;
    }
    bool allValid = core.split('').every((c) {
      int u = c.codeUnitAt(0);
      return (u >= 65 && u <= 90) ||
          (u >= 97 && u <= 122) ||
          (u >= 48 && u <= 57) ||
          c == '+' ||
          c == '/';
    });
    if (!allValid) {
      return null;
    }
    String padded = core + '=' * ((4 - core.length % 4) % 4);
    List<int> bytes;
    try {
      bytes = base64Decode(padded);
    } catch (_) {
      return null;
    }
    String decoded;
    try {
      decoded = utf8.decode(bytes);
    } catch (_) {
      return null;
    }
    // Decoded subscriptions are printable text; a replacement character
    // means the input was not really base64-encoded UTF-8.
    if (decoded.contains('�')) {
      return null;
    }
    return decoded;
  }
}
