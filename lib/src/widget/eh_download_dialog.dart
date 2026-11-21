import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/config/ui_config.dart';
import 'package:jhentai/src/service/cloud_super_resolution_service.dart';
import 'package:jhentai/src/setting/download_setting.dart';
import 'package:jhentai/src/utils/route_util.dart';
import 'package:jhentai/src/utils/toast_util.dart';

import 'eh_group_name_selector.dart';

class EHDownloadDialog extends StatefulWidget {
  final String title;
  final String? currentGroup;
  final List<String> candidates;
  final bool showDownloadOriginalImageCheckBox;
  final bool downloadOriginalImage;
  final List<String> preferredGroups;
  final bool showCloudSrOption;

  const EHDownloadDialog({
    Key? key,
    required this.title,
    this.currentGroup,
    required this.candidates,
    this.showDownloadOriginalImageCheckBox = false,
    this.downloadOriginalImage = false,
    this.preferredGroups = const [],
    this.showCloudSrOption = false,
  }) : super(key: key);

  @override
  State<EHDownloadDialog> createState() => _EHDownloadDialogState();
}

class _EHDownloadDialogState extends State<EHDownloadDialog> {
  late String group;
  late List<String> candidates;
  late bool downloadOriginalImage;
  bool cloudSr = false;
  int cloudScale = 4;

  @override
  void initState() {
    super.initState();

    group = widget.currentGroup ?? widget.candidates.firstOrNull ?? 'default'.tr;
    final validGroups = widget.candidates.toSet();
    candidates = <String>{...widget.preferredGroups.where(validGroups.contains), group, ...widget.candidates}.toList();
    downloadOriginalImage = widget.downloadOriginalImage;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      contentPadding: const EdgeInsets.only(left: 24, right: 24, bottom: 12, top: 24),
      actionsPadding: const EdgeInsets.only(left: 24, right: 20, bottom: 12),
      content: _buildBody(),
      actions: [
        TextButton(onPressed: backRoute, child: Text('cancel'.tr)),
        TextButton(
          onPressed: () {
            if (group.isEmpty) {
              toast('invalid'.tr);
              backRoute();
              return;
            }
            backRoute(
              result: (
                group: group,
                downloadOriginalImage: downloadOriginalImage,
                cloudSrScale: (!downloadOriginalImage && cloudSr) ? cloudScale : null,
              ),
            );
          },
          child: Text('OK'.tr),
        ),
      ],
    );
  }

  Widget _buildBody() {
    return SizedBox(
      width: UIConfig.downloadDialogWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          EHGroupNameSelector(
            currentGroup: widget.currentGroup ?? 'default'.tr,
            candidates: candidates,
            listener: (g) => group = g,
          ),
          if (widget.showDownloadOriginalImageCheckBox) _buildDownloadOriginalImageCheckBox().marginOnly(top: 16),
          if (widget.showCloudSrOption && cloudSuperResolutionService.isReady)
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              alignment: Alignment.topCenter,
              child: downloadOriginalImage ? const SizedBox.shrink() : _buildCloudSrRow().marginOnly(top: 16),
            ),
        ],
      ),
    );
  }

  Widget _buildCloudSrRow() {
    // 标签+勾选一行、倍率选择单独一行：全挤在一行会超出对话框宽度被裁掉
    return SizedBox(
      width: UIConfig.downloadDialogWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text('cloudSuperResolve'.tr + ' ?', style: const TextStyle(fontSize: UIConfig.groupDialogCheckBoxTextSize)),
              Checkbox(
                value: cloudSr,
                activeColor: UIConfig.groupDialogCheckBoxColor(context),
                onChanged: (bool? value) => setState(() => cloudSr = value ?? false),
              ),
            ],
          ),
          if (cloudSr)
            SegmentedButton<int>(
              showSelectedIcon: false,
              style: const ButtonStyle(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 8, vertical: 2)),
              ),
              segments: const [
                ButtonSegment(value: 2, label: Text('2x')),
                ButtonSegment(value: 3, label: Text('3x')),
                ButtonSegment(value: 4, label: Text('4x')),
              ],
              selected: {cloudScale},
              onSelectionChanged: (Set<int> selection) => setState(() => cloudScale = selection.first),
            ).marginOnly(top: 8),
        ],
      ),
    );
  }

  Widget _buildDownloadOriginalImageCheckBox() {
    return SizedBox(
      height: UIConfig.downloadDialogCheckBoxHeight,
      width: UIConfig.downloadDialogWidth,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text('downloadOriginalImage'.tr + ' ?', style: const TextStyle(fontSize: UIConfig.groupDialogCheckBoxTextSize)),
          Checkbox(
            value: downloadOriginalImage,
            activeColor: UIConfig.groupDialogCheckBoxColor(context),
            onChanged: (bool? value) => setState(() => downloadOriginalImage = (value ?? true)),
          ),
        ],
      ),
    );
  }
}
