import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:jhentai/src/extension/widget_extension.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/xray_service.dart';
import 'package:jhentai/src/setting/xray_setting.dart';
import 'package:jhentai/src/utils/cron_util.dart';
import 'package:jhentai/src/utils/route_util.dart';
import 'package:jhentai/src/utils/snack_util.dart';
import 'package:jhentai/src/utils/toast_util.dart';

class XrayPage extends StatefulWidget {
  const XrayPage({Key? key}) : super(key: key);

  @override
  State<XrayPage> createState() => _XrayPageState();
}

class _XrayPageState extends State<XrayPage> {
  final Set<String> _refreshingSubscriptionIds = {};

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
            _buildSectionTitle('subscriptions'.tr),
            ...xraySetting.subscriptions
                .map((sub) => _buildSubscriptionTile(context, sub)),
            _buildAddSubscription(context),
            _buildRefreshAllSubscriptions(context),
            const Divider(),
            ..._buildGroupedNodes(context),
            if (xraySetting.nodes.isEmpty)
              ListTile(
                  title: Text('noXrayNodes'.tr,
                      style: TextStyle(color: Theme.of(context).hintColor))),
            const Divider(),
            _buildImportByPaste(context),
          ],
        ),
      ).withListTileTheme(context),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(title,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
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
    String note = xrayService.failoverNote.value;
    return ListTile(
      title: Text('xrayStatus'.tr),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text, maxLines: 2, overflow: TextOverflow.ellipsis),
          if (note.isNotEmpty)
            Text(note,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
      ),
      trailing: Icon(
        Icons.circle,
        size: 12,
        color: xrayService.running.value ? Colors.green : Colors.grey,
      ),
    );
  }

  // ------------------------------------------------------------------
  // Subscriptions
  // ------------------------------------------------------------------

  Widget _buildSubscriptionTile(BuildContext context, XraySubscription sub) {
    bool refreshing = _refreshingSubscriptionIds.contains(sub.id);
    String lastUpdated = sub.lastUpdatedMs <= 0
        ? 'never'.tr
        : DateFormat('yyyy-MM-dd HH:mm')
            .format(DateTime.fromMillisecondsSinceEpoch(sub.lastUpdatedMs));
    return ListTile(
      title: Text(sub.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(sub.url, maxLines: 1, overflow: TextOverflow.ellipsis),
          Text('${'lastUpdated'.tr}: $lastUpdated'),
          if (sub.cron.isNotEmpty) Text('Cron: ${sub.cron}'),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (refreshing)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => _refreshSubscription(sub),
            ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              await xraySetting.removeSubscription(sub);
              toast('success'.tr);
            },
          ),
        ],
      ),
    );
  }

  Future<void> _refreshSubscription(XraySubscription sub) async {
    if (!xrayService.isSupported) {
      toast('xrayAndroidOnly'.tr);
      return;
    }
    setState(() => _refreshingSubscriptionIds.add(sub.id));
    try {
      await xrayService.refreshSubscription(sub);
      toast('subscriptionRefreshed'.tr);
    } catch (e, stack) {
      log.error('Refresh subscription ${sub.name} failed', e, stack);
      snack('subscriptionRefreshFailed'.tr, e.toString());
    } finally {
      if (mounted) {
        setState(() => _refreshingSubscriptionIds.remove(sub.id));
      }
    }
  }

  Widget _buildAddSubscription(BuildContext context) {
    return ListTile(
      title: Text('addSubscription'.tr),
      trailing: const Icon(Icons.keyboard_arrow_right).marginOnly(right: 4),
      onTap: () async {
        if (!xrayService.isSupported) {
          toast('xrayAndroidOnly'.tr);
          return;
        }
        _SubscriptionInput? input = await showDialog<_SubscriptionInput>(
          context: context,
          builder: (context) => const _SubscriptionInputDialog(),
        );
        if (input == null) {
          return;
        }
        XraySubscription sub = await xraySetting.addSubscription(
          name: input.name,
          url: input.url,
          cron: input.cron,
        );
        await _refreshSubscription(sub);
      },
    );
  }

  Widget _buildRefreshAllSubscriptions(BuildContext context) {
    return ListTile(
      title: Text('refreshAllSubscriptions'.tr),
      trailing: const Icon(Icons.keyboard_arrow_right).marginOnly(right: 4),
      onTap: () async {
        if (!xrayService.isSupported) {
          toast('xrayAndroidOnly'.tr);
          return;
        }
        for (XraySubscription sub in [...xraySetting.subscriptions]) {
          await _refreshSubscription(sub);
        }
      },
    );
  }

  // ------------------------------------------------------------------
  // Nodes, grouped by subscription
  // ------------------------------------------------------------------

  List<Widget> _buildGroupedNodes(BuildContext context) {
    List<String> groupOrder = [
      ...xraySetting.subscriptions.map((e) => e.name),
      '',
    ];
    Set<String> seenGroups = {};
    List<Widget> widgets = [];
    for (String group in groupOrder) {
      if (!seenGroups.add(group)) {
        continue;
      }
      List<int> indices = [];
      for (int i = 0; i < xraySetting.nodes.length; i++) {
        if (xraySetting.nodes[i].group == group) {
          indices.add(i);
        }
      }
      if (indices.isEmpty) {
        continue;
      }
      widgets.add(_buildSectionTitle(
          group.isEmpty ? 'manualImportGroup'.tr : group));
      widgets.addAll(indices.map((index) => _buildNodeTile(context, index)));
    }
    return widgets;
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
              xrayService.failoverNote.value = '';
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

  // ------------------------------------------------------------------
  // Paste import (manual group)
  // ------------------------------------------------------------------

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

  Future<void> _importText(String text) async {
    try {
      XrayConvertResult result = await xrayService.convertLinks(text);
      if (result.nodes.isEmpty) {
        snack(
          'importNodeFailed'.tr,
          result.failures.isNotEmpty ? result.failures.first.reason : '',
        );
        return;
      }
      await xraySetting.addNodes(result.nodes);
      if (result.failures.isEmpty) {
        toast('nodesImported'
            .trParams({'count': result.nodes.length.toString()}));
      } else {
        snack(
          'importResult'.trParams({
            'ok': result.nodes.length.toString(),
            'skipped': result.failures.length.toString(),
          }),
          result.failures.first.reason,
        );
      }
    } catch (e, stack) {
      log.error('Import xray nodes failed', e, stack);
      snack('importNodeFailed'.tr, e.toString());
    }
  }
}

class _SubscriptionInput {
  final String name;
  final String url;
  final String cron;

  const _SubscriptionInput(
      {required this.name, required this.url, required this.cron});
}

class _SubscriptionInputDialog extends StatefulWidget {
  const _SubscriptionInputDialog({Key? key}) : super(key: key);

  @override
  State<_SubscriptionInputDialog> createState() =>
      _SubscriptionInputDialogState();
}

class _SubscriptionInputDialogState extends State<_SubscriptionInputDialog> {
  final TextEditingController nameController = TextEditingController();
  final TextEditingController urlController = TextEditingController();
  final TextEditingController cronController = TextEditingController();

  @override
  void dispose() {
    nameController.dispose();
    urlController.dispose();
    cronController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('addSubscription'.tr),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: nameController,
            autofocus: true,
            decoration:
                InputDecoration(hintText: 'subscriptionName'.tr, isDense: true),
          ),
          TextField(
            controller: urlController,
            decoration:
                InputDecoration(hintText: 'subscriptionUrl'.tr, isDense: true),
          ),
          TextField(
            controller: cronController,
            decoration:
                InputDecoration(hintText: 'subscriptionCron'.tr, isDense: true),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: backRoute, child: Text('cancel'.tr)),
        TextButton(
          onPressed: () {
            String name = nameController.text.trim();
            String url = urlController.text.trim();
            String cron = cronController.text.trim();
            if (name.isEmpty || url.isEmpty) {
              return;
            }
            if (cron.isNotEmpty && CronExpression.tryParse(cron) == null) {
              snack('cronInvalid'.tr, cron);
              return;
            }
            backRoute(
                result:
                    _SubscriptionInput(name: name, url: url, cron: cron));
          },
          child: Text('OK'.tr),
        ),
      ],
    );
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
