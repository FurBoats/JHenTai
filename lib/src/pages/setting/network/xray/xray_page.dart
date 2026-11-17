import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/extension/widget_extension.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/xray_service.dart';
import 'package:jhentai/src/setting/xray_setting.dart';
import 'package:jhentai/src/utils/route_util.dart';
import 'package:jhentai/src/utils/snack_util.dart';
import 'package:jhentai/src/utils/toast_util.dart';

class XrayPage extends StatelessWidget {
  const XrayPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(centerTitle: true, title: Text('xrayNodes'.tr)),
      body: Obx(
        () => ListView(
          padding: const EdgeInsets.only(top: 16),
          children: [
            _buildStatus(),
            const Divider(),
            ...List.generate(xraySetting.nodes.length,
                (index) => _buildNodeTile(context, index)),
            if (xraySetting.nodes.isEmpty)
              ListTile(
                  title: Text('noXrayNodes'.tr,
                      style: TextStyle(color: Theme.of(context).hintColor))),
            const Divider(),
            _buildImportByPaste(context),
            _buildImportBySubscription(context),
          ],
        ),
      ).withListTileTheme(context),
    );
  }

  Widget _buildStatus() {
    String status = xrayService.status.value;
    String text;
    if (status == 'running') {
      text = 'xrayRunning'.tr;
    } else if (status == 'starting') {
      text = 'xrayStarting'.tr;
    } else if (status.startsWith('error')) {
      text = status;
    } else {
      text = 'xrayStopped'.tr;
    }
    return ListTile(
      title: Text('xrayStatus'.tr),
      subtitle: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: Icon(
        Icons.circle,
        size: 12,
        color: xrayService.running.value ? Colors.green : Colors.grey,
      ),
    );
  }

  Widget _buildNodeTile(BuildContext context, int index) {
    XrayNode node = xraySetting.nodes[index];
    bool isMain = xraySetting.mainNodeIndex.value == index;
    bool isIgneous = xraySetting.igneousNodeIndex.value == index;

    return ListTile(
      title: Text(node.name.isEmpty ? node.link : node.name,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(node.link, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (isMain || isIgneous)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 6,
                children: [
                  if (isMain)
                    Chip(
                        label: Text('mainNode'.tr),
                        visualDensity: VisualDensity.compact),
                  if (isIgneous)
                    Chip(
                        label: Text('igneousNode'.tr),
                        visualDensity: VisualDensity.compact),
                ],
              ),
            ),
        ],
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (value) async {
          switch (value) {
            case 'main':
              await xraySetting.saveMainNodeIndex(isMain ? -1 : index);
              break;
            case 'igneous':
              await xraySetting.saveIgneousNodeIndex(isIgneous ? -1 : index);
              break;
            case 'delete':
              await xraySetting.removeNodeAt(index);
              toast('success'.tr);
              break;
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(value: 'main', child: Text('setAsMainNode'.tr)),
          PopupMenuItem(value: 'igneous', child: Text('setAsIgneousNode'.tr)),
          PopupMenuItem(value: 'delete', child: Text('delete'.tr)),
        ],
      ),
    );
  }

  Widget _buildImportByPaste(BuildContext context) {
    return ListTile(
      title: Text('importNode'.tr),
      subtitle: Text('pasteNodeLinksHint'.tr),
      trailing: const Icon(Icons.keyboard_arrow_right).marginOnly(right: 4),
      onTap: () async {
        if (!xrayService.isSupported) {
          toast('xrayAndroidOnly'.tr);
          return;
        }
        String? text = await showDialog<String>(
          context: context,
          builder: (context) => const _TextInputDialog(
            titleKey: 'importNode',
            hintKey: 'pasteNodeLinksHint',
            multiline: true,
          ),
        );
        if (text == null || text.trim().isEmpty) {
          return;
        }
        await _importText(text);
      },
    );
  }

  Widget _buildImportBySubscription(BuildContext context) {
    return ListTile(
      title: Text('importFromSubscription'.tr),
      subtitle: Text('subscriptionUrl'.tr),
      trailing: const Icon(Icons.keyboard_arrow_right).marginOnly(right: 4),
      onTap: () async {
        if (!xrayService.isSupported) {
          toast('xrayAndroidOnly'.tr);
          return;
        }
        String? url = await showDialog<String>(
          context: context,
          builder: (context) => const _TextInputDialog(
            titleKey: 'importFromSubscription',
            hintKey: 'subscriptionUrl',
            multiline: false,
          ),
        );
        if (url == null || url.trim().isEmpty) {
          return;
        }
        try {
          var response = await Dio().get<String>(url.trim(),
              options: Options(responseType: ResponseType.plain));
          String text = response.data ?? '';
          if (text.trim().isEmpty) {
            snack('fetchSubscriptionFailed'.tr, '');
            return;
          }
          await _importText(text);
        } catch (e, stack) {
          log.error('Fetch xray subscription failed', e, stack);
          snack('fetchSubscriptionFailed'.tr, e.toString());
        }
      },
    );
  }

  Future<void> _importText(String text) async {
    try {
      List<XrayNode> nodes = await xrayService.convertLinks(text);
      if (nodes.isEmpty) {
        snack('importNodeFailed'.tr, '');
        return;
      }
      await xraySetting.addNodes(nodes);
      toast('nodesImported'.trParams({'count': nodes.length.toString()}));
    } catch (e, stack) {
      log.error('Import xray nodes failed', e, stack);
      snack('importNodeFailed'.tr, e.toString());
    }
  }
}

class _TextInputDialog extends StatefulWidget {
  final String titleKey;
  final String hintKey;
  final bool multiline;

  const _TextInputDialog(
      {Key? key,
      required this.titleKey,
      required this.hintKey,
      required this.multiline})
      : super(key: key);

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  final TextEditingController controller = TextEditingController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.titleKey.tr),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLines: widget.multiline ? 8 : 1,
        decoration: InputDecoration(hintText: widget.hintKey.tr, isDense: true),
      ),
      actions: [
        TextButton(onPressed: backRoute, child: Text('cancel'.tr)),
        TextButton(
            onPressed: () => backRoute(result: controller.text),
            child: Text('OK'.tr)),
      ],
    );
  }
}
