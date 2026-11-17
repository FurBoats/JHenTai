import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'log.dart';
import 'xray_service.dart';

/// Subscription fetching shared by the node page and the cron auto-updater.
///
/// Some providers serve different (or no) content depending on the client
/// User-Agent and on whether the request comes from a "clean" IP, so the
/// fetcher rotates through several well-known client UAs and tries both the
/// embedded Xray main SOCKS (when the core is running) and a direct
/// connection before giving up. The thrown error always carries the last
/// attempt's HTTP status / exception.

const List<String> _subscriptionUserAgents = [
  'v2rayNG/1.9.27',
  'clash-verge/v2.0.0',
  'Shadowrocket/2.2.60',
  'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
];

Dio _subscriptionDio({required bool viaProxy}) {
  Dio dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
  ));
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () {
      HttpClient client = HttpClient();
      client.findProxy = (_) =>
          viaProxy ? 'SOCKS5 ${XrayService.mainAddress}' : 'DIRECT';
      return client;
    },
  );
  return dio;
}

Future<String> fetchSubscriptionContent(String url,
    {required bool viaProxyAvailable}) async {
  List<bool> channels =
      viaProxyAvailable ? [true, false] : [false];
  String lastError = 'unknown error';

  for (bool viaProxy in channels) {
    Dio dio = _subscriptionDio(viaProxy: viaProxy);
    for (String ua in _subscriptionUserAgents) {
      try {
        Response<String> response = await dio.get<String>(
          url,
          options: Options(
            responseType: ResponseType.plain,
            headers: {'User-Agent': ua},
            validateStatus: (status) => status != null && status < 600,
          ),
        );
        int status = response.statusCode ?? 0;
        String body = response.data ?? '';
        if (status >= 200 && status < 300 && body.trim().isNotEmpty) {
          if (body.trimLeft().startsWith('<')) {
            lastError =
                'HTTP $status but HTML content via ${viaProxy ? 'proxy' : 'direct'} (UA $ua)';
            continue;
          }
          return body;
        }
        lastError =
            'HTTP $status via ${viaProxy ? 'proxy' : 'direct'} (UA $ua)';
      } catch (e) {
        lastError = '${viaProxy ? 'proxy' : 'direct'} (UA $ua): $e';
      }
    }
  }

  log.error('Fetch subscription failed: $lastError');
  throw Exception('fetch subscription failed: $lastError');
}

// --------------------------------------------------------------------
// Clash YAML -> share links
//
// A tolerant, line-based extraction of the top-level `proxies:` list.
// Only ss / vmess / vless / trojan / hysteria2 entries are converted;
// anything else (or entries missing required fields) is reported in
// [ClashParseResult.failures] instead of being dropped silently.
// --------------------------------------------------------------------

class ClashParseResult {
  final List<String> links;
  final List<String> failures;

  ClashParseResult(this.links, this.failures);
}

bool looksLikeClashYaml(String content) {
  for (String line in content.split('\n')) {
    if (line.startsWith('proxies:')) {
      return true;
    }
  }
  return false;
}

String _stripQuotes(String value) {
  String v = value.trim();
  if (v.length >= 2 &&
      ((v.startsWith('"') && v.endsWith('"')) ||
          (v.startsWith("'") && v.endsWith("'")))) {
    return v.substring(1, v.length - 1);
  }
  return v;
}

class _ClashEntry {
  final Map<String, String> fields = {};

  String? operator [](String key) => fields[key];

  String get name => fields['name'] ?? 'node';
}

/// Splits the proxies section into raw entries of (indent, text) lines.
List<List<MapEntry<int, String>>> _splitClashEntries(String content) {
  List<String> lines = content.split('\n');
  int start = -1;
  for (int i = 0; i < lines.length; i++) {
    if (lines[i].startsWith('proxies:')) {
      start = i;
      break;
    }
  }
  if (start < 0) {
    return [];
  }

  List<List<MapEntry<int, String>>> entries = [];
  List<MapEntry<int, String>>? current;
  for (int i = start + 1; i < lines.length; i++) {
    String raw = lines[i];
    String trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) {
      continue;
    }
    int indent = raw.length - raw.trimLeft().length;
    if (indent == 0 && !trimmed.startsWith('-')) {
      break; // next top-level key: proxies section is over
    }
    if (trimmed.startsWith('- ') || trimmed == '-') {
      current = [];
      entries.add(current);
      String rest = trimmed.substring(1).trim();
      if (rest.isNotEmpty) {
        current.add(MapEntry(indent + 2, rest));
      }
      continue;
    }
    current?.add(MapEntry(indent, trimmed));
  }
  return entries;
}

_ClashEntry _parseClashEntry(List<MapEntry<int, String>> lines) {
  _ClashEntry entry = _ClashEntry();

  void putField(String key, String value, List<String> parents) {
    entry.fields[key] = value;
    if (parents.isNotEmpty) {
      entry.fields['${parents.join('.')}.$key'] = value;
    }
  }

  void parseFlow(String text, List<String> parents) {
    String body = text.trim();
    if (body.startsWith('{') && body.endsWith('}')) {
      body = body.substring(1, body.length - 1);
    }
    for (String piece in body.split(',')) {
      int colon = piece.indexOf(':');
      if (colon < 0) {
        continue;
      }
      String key = piece.substring(0, colon).trim();
      String value = _stripQuotes(piece.substring(colon + 1));
      if (key.isNotEmpty) {
        putField(key, value, parents);
      }
    }
  }

  // Stack of (indent, key) for nested maps like ws-opts / headers.
  List<MapEntry<int, String>> stack = [];
  for (MapEntry<int, String> line in lines) {
    int indent = line.key;
    String text = line.value;
    while (stack.isNotEmpty && stack.last.key >= indent) {
      stack.removeLast();
    }
    List<String> parents = stack.map((e) => e.value).toList();

    if (text.startsWith('{')) {
      parseFlow(text, parents);
      continue;
    }
    int colon = text.indexOf(':');
    if (colon < 0) {
      continue;
    }
    String key = text.substring(0, colon).trim();
    String value = text.substring(colon + 1).trim();
    if (key.isEmpty) {
      continue;
    }
    if (value.startsWith('{')) {
      parseFlow(value, [...parents, key]);
      continue;
    }
    putField(key, _stripQuotes(value), parents);
    if (value.isEmpty) {
      stack.add(MapEntry(indent, key));
    }
  }
  return entry;
}

String _q(String value) => Uri.encodeComponent(value);

ClashParseResult clashYamlToShareLinks(String content) {
  List<String> links = [];
  List<String> failures = [];

  for (List<MapEntry<int, String>> rawEntry in _splitClashEntries(content)) {
    _ClashEntry entry = _parseClashEntry(rawEntry);
    String name = entry.name;
    String? type = entry['type'];
    String? server = entry['server'];
    String? port = entry['port'];

    String? require(List<String> keys) {
      for (String key in keys) {
        String? v = entry[key];
        if (v == null || v.isEmpty) {
          return key;
        }
      }
      return null;
    }

    if (type == null || server == null || port == null) {
      failures.add('$name: missing type/server/port');
      continue;
    }

    switch (type) {
      case 'ss':
        String? missing = require(['cipher', 'password']);
        if (missing != null) {
          failures.add('$name: ss missing $missing');
          continue;
        }
        String userinfo = base64Url
            .encode(utf8.encode('${entry['cipher']}:${entry['password']}'))
            .replaceAll('=', '');
        links.add('ss://$userinfo@$server:$port#${_q(name)}');
        break;
      case 'vmess':
        String? missing = require(['uuid']);
        if (missing != null) {
          failures.add('$name: vmess missing $missing');
          continue;
        }
        bool tls = entry['tls'] == 'true';
        Map<String, dynamic> vmess = {
          'v': '2',
          'ps': name,
          'add': server,
          'port': port,
          'id': entry['uuid'],
          'aid': entry['alterId'] ?? '0',
          'scy': entry['cipher'] ?? 'auto',
          'net': entry['network'] ?? 'tcp',
          'type': 'none',
          'host': entry['ws-opts.headers.Host'] ?? entry['ws-opts.host'] ?? '',
          'path': entry['ws-opts.path'] ??
              entry['grpc-opts.grpc-service-name'] ??
              '',
          'tls': tls ? 'tls' : '',
          'sni': entry['servername'] ?? entry['sni'] ?? '',
        };
        links.add('vmess://${base64.encode(utf8.encode(jsonEncode(vmess)))}');
        break;
      case 'vless':
        String? missing = require(['uuid']);
        if (missing != null) {
          failures.add('$name: vless missing $missing');
          continue;
        }
        String? pbk = entry['reality-opts.public-key'];
        bool tls = entry['tls'] == 'true';
        Map<String, String> query = {'encryption': 'none'};
        if (entry['flow'] != null && entry['flow']!.isNotEmpty) {
          query['flow'] = entry['flow']!;
        }
        if (pbk != null && pbk.isNotEmpty) {
          query['security'] = 'reality';
          query['pbk'] = pbk;
          String? sid = entry['reality-opts.short-id'];
          if (sid != null && sid.isNotEmpty) {
            query['sid'] = sid;
          }
        } else if (tls) {
          query['security'] = 'tls';
        } else {
          query['security'] = 'none';
        }
        String? sni = entry['servername'] ?? entry['sni'];
        if (sni != null && sni.isNotEmpty) {
          query['sni'] = sni;
        }
        String network = entry['network'] ?? 'tcp';
        query['type'] = network;
        if (network == 'ws') {
          String? path = entry['ws-opts.path'];
          if (path != null && path.isNotEmpty) {
            query['path'] = path;
          }
          String? host = entry['ws-opts.headers.Host'];
          if (host != null && host.isNotEmpty) {
            query['host'] = host;
          }
        } else if (network == 'grpc') {
          String? serviceName = entry['grpc-opts.grpc-service-name'];
          if (serviceName != null && serviceName.isNotEmpty) {
            query['serviceName'] = serviceName;
          }
        }
        String queryString = query.entries
            .map((e) => '${e.key}=${_q(e.value)}')
            .join('&');
        links.add(
            'vless://${entry['uuid']}@$server:$port?$queryString#${_q(name)}');
        break;
      case 'trojan':
        String? missing = require(['password']);
        if (missing != null) {
          failures.add('$name: trojan missing $missing');
          continue;
        }
        String? sni = entry['sni'] ?? entry['servername'];
        String query = (sni != null && sni.isNotEmpty) ? '?sni=${_q(sni)}' : '';
        links.add(
            'trojan://${_q(entry['password']!)}@$server:$port$query#${_q(name)}');
        break;
      case 'hysteria2':
        String? password = entry['password'] ?? entry['auth'];
        if (password == null || password.isEmpty) {
          failures.add('$name: hysteria2 missing password');
          continue;
        }
        if (entry['skip-cert-verify'] == 'true') {
          failures.add(
              '$name: hysteria2 with skip-cert-verify not supported by core');
          continue;
        }
        List<String> params = [];
        String? sni = entry['sni'] ?? entry['servername'];
        if (sni != null && sni.isNotEmpty) {
          params.add('sni=${_q(sni)}');
        }
        String? ports = entry['ports'];
        if (ports != null && ports.isNotEmpty) {
          params.add('mport=${_q(ports)}');
        }
        String query = params.isEmpty ? '' : '?${params.join('&')}';
        links.add(
            'hysteria2://${_q(password)}@$server:$port$query#${_q(name)}');
        break;
      default:
        failures.add('$name: unsupported type $type');
    }
  }

  return ClashParseResult(links, failures);
}
