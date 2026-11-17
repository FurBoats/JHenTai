import 'dart:convert';

import 'package:get/get.dart';
import 'package:jhentai/src/enum/config_enum.dart';

import '../service/jh_service.dart';
import '../service/log.dart';

XraySetting xraySetting = XraySetting();

class XrayNode {
  String name;
  String link;

  /// Name of the subscription this node came from; '' means manually imported.
  String group;

  XrayNode({required this.name, required this.link, this.group = ''});

  factory XrayNode.fromJson(Map<String, dynamic> json) {
    return XrayNode(
      name: json['name'] ?? '',
      link: json['link'] ?? '',
      group: json['group'] ?? '',
    );
  }

  Map<String, dynamic> toJson() => {'name': name, 'link': link, 'group': group};
}

class XraySubscription {
  String id;
  String name;
  String url;

  /// 5-field cron expression (minute hour day-of-month month day-of-week).
  /// Empty means manual refresh only.
  String cron;

  /// Epoch milliseconds of the last successful refresh; 0 = never.
  int lastUpdatedMs;

  XraySubscription({
    required this.id,
    required this.name,
    required this.url,
    this.cron = '',
    this.lastUpdatedMs = 0,
  });

  factory XraySubscription.fromJson(Map<String, dynamic> json) {
    return XraySubscription(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      url: json['url'] ?? '',
      cron: json['cron'] ?? '',
      lastUpdatedMs: json['lastUpdatedMs'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'cron': cron,
        'lastUpdatedMs': lastUpdatedMs,
      };
}

/// Nodes for the embedded Xray core (Android only).
///
/// Two roles are selected independently: the main node carries all normal
/// traffic, the igneous node is used only when refreshing the exhentai
/// igneous cookie. An index of -1 (or out of range) means "not selected",
/// and that route falls back to direct.
class XraySetting
    with JHLifeCircleBeanWithConfigStorage
    implements JHLifeCircleBean {
  RxList<XrayNode> nodes = <XrayNode>[].obs;
  RxList<XraySubscription> subscriptions = <XraySubscription>[].obs;
  RxInt mainNodeIndex = (-1).obs;
  RxInt igneousNodeIndex = (-1).obs;

  XrayNode? get mainNode => _nodeAt(mainNodeIndex.value);

  XrayNode? get igneousNode => _nodeAt(igneousNodeIndex.value);

  XrayNode? _nodeAt(int index) {
    if (index < 0 || index >= nodes.length) {
      return null;
    }
    return nodes[index];
  }

  @override
  ConfigEnum get configEnum => ConfigEnum.xraySetting;

  @override
  void applyBeanConfig(String configString) {
    Map map = jsonDecode(configString);

    List nodeList = map['nodes'] ?? [];
    nodes.value = nodeList
        .map((e) => XrayNode.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    List subscriptionList = map['subscriptions'] ?? [];
    subscriptions.value = subscriptionList
        .map((e) => XraySubscription.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    mainNodeIndex.value = map['mainNodeIndex'] ?? -1;
    igneousNodeIndex.value = map['igneousNodeIndex'] ?? -1;
  }

  @override
  String toConfigString() {
    return jsonEncode({
      'nodes': nodes.map((e) => e.toJson()).toList(),
      'subscriptions': subscriptions.map((e) => e.toJson()).toList(),
      'mainNodeIndex': mainNodeIndex.value,
      'igneousNodeIndex': igneousNodeIndex.value,
    });
  }

  @override
  Future<void> doInitBean() async {}

  @override
  void doAfterBeanReady() {}

  Future<void> addNodes(List<XrayNode> newNodes) async {
    if (newNodes.isEmpty) {
      return;
    }
    log.debug('addXrayNodes:${newNodes.length}');
    nodes.value = [...nodes, ...newNodes];
    await saveBeanConfig();
  }

  Future<void> removeNodeAt(int index) async {
    if (index < 0 || index >= nodes.length) {
      return;
    }
    log.debug('removeXrayNodeAt:$index');
    List<XrayNode> newNodes = [...nodes]..removeAt(index);
    nodes.value = newNodes;
    mainNodeIndex.value = _adjustIndexAfterRemove(mainNodeIndex.value, index);
    igneousNodeIndex.value =
        _adjustIndexAfterRemove(igneousNodeIndex.value, index);
    await saveBeanConfig();
  }

  int _adjustIndexAfterRemove(int selected, int removed) {
    if (selected == removed) {
      return -1;
    }
    if (selected > removed) {
      return selected - 1;
    }
    return selected;
  }

  Future<void> saveMainNodeIndex(int index) async {
    log.debug('saveMainNodeIndex:$index');
    mainNodeIndex.value = index;
    await saveBeanConfig();
  }

  Future<void> saveIgneousNodeIndex(int index) async {
    log.debug('saveIgneousNodeIndex:$index');
    igneousNodeIndex.value = index;
    await saveBeanConfig();
  }

  // ------------------------------------------------------------------
  // Subscriptions
  // ------------------------------------------------------------------

  XraySubscription? subscriptionById(String id) {
    for (XraySubscription sub in subscriptions) {
      if (sub.id == id) {
        return sub;
      }
    }
    return null;
  }

  Future<XraySubscription> addSubscription({
    required String name,
    required String url,
    String cron = '',
  }) async {
    XraySubscription sub = XraySubscription(
      id: '${DateTime.now().millisecondsSinceEpoch}-${subscriptions.length}',
      name: name,
      url: url,
      cron: cron,
    );
    subscriptions.value = [...subscriptions, sub];
    await saveBeanConfig();
    return sub;
  }

  /// Removes the subscription and every node in its group, fixing the
  /// main/igneous indices.
  Future<void> removeSubscription(XraySubscription sub) async {
    log.debug('removeXraySubscription:${sub.name}');
    String? mainLink = mainNode?.link;
    String? igneousLink = igneousNode?.link;
    List<XrayNode> kept =
        nodes.where((node) => node.group != sub.name).toList();
    nodes.value = kept;
    mainNodeIndex.value = _indexOfLink(kept, mainLink);
    igneousNodeIndex.value = _indexOfLink(kept, igneousLink);
    subscriptions.value =
        subscriptions.where((e) => e.id != sub.id).toList();
    await saveBeanConfig();
  }

  /// Replaces all nodes of [group] with [newNodes] (deduped by link). The
  /// main/igneous selections follow their node by link; a selection whose
  /// node disappeared becomes -1.
  Future<void> replaceGroupNodes(String group, List<XrayNode> newNodes) async {
    String? mainLink = mainNode?.link;
    String? igneousLink = igneousNode?.link;

    Set<String> seen = {};
    List<XrayNode> deduped = [];
    for (XrayNode node in newNodes) {
      if (seen.add(node.link)) {
        deduped.add(node);
      }
    }

    List<XrayNode> merged = [
      ...nodes.where((node) => node.group != group),
      ...deduped,
    ];
    nodes.value = merged;
    mainNodeIndex.value = _indexOfLink(merged, mainLink);
    igneousNodeIndex.value = _indexOfLink(merged, igneousLink);
    await saveBeanConfig();
  }

  int _indexOfLink(List<XrayNode> list, String? link) {
    if (link == null) {
      return -1;
    }
    for (int i = 0; i < list.length; i++) {
      if (list[i].link == link) {
        return i;
      }
    }
    return -1;
  }

  Future<void> saveSubscriptions() async {
    // lastUpdatedMs mutations live on the subscription objects themselves;
    // reassign so Rx listeners fire, then persist everything.
    subscriptions.value = [...subscriptions];
    await saveBeanConfig();
  }
}
