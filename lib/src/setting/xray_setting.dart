import 'dart:convert';

import 'package:get/get.dart';
import 'package:jhentai/src/enum/config_enum.dart';

import '../service/jh_service.dart';
import '../service/log.dart';

XraySetting xraySetting = XraySetting();

class XrayNode {
  String name;
  String link;

  XrayNode({required this.name, required this.link});

  factory XrayNode.fromJson(Map<String, dynamic> json) {
    return XrayNode(name: json['name'] ?? '', link: json['link'] ?? '');
  }

  Map<String, dynamic> toJson() => {'name': name, 'link': link};
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
    mainNodeIndex.value = map['mainNodeIndex'] ?? -1;
    igneousNodeIndex.value = map['igneousNodeIndex'] ?? -1;
  }

  @override
  String toConfigString() {
    return jsonEncode({
      'nodes': nodes.map((e) => e.toJson()).toList(),
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
}
