import 'dart:io';

import 'package:clipboard/clipboard.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get_utils/get_utils.dart';
import 'package:jhentai/src/consts/eh_consts.dart';
import 'package:jhentai/src/extension/widget_extension.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/service/igneous_refresh_service.dart';
import 'package:jhentai/src/setting/advanced_setting.dart';
import 'package:jhentai/src/setting/user_setting.dart';
import 'package:jhentai/src/utils/route_util.dart';
import 'package:jhentai/src/utils/cookie_util.dart';
import 'package:jhentai/src/utils/snack_util.dart';
import 'package:jhentai/src/utils/toast_util.dart';
import 'package:jhentai/src/widget/loading_state_indicator.dart';

class CookiePage extends StatefulWidget {
  const CookiePage({super.key});

  @override
  State<CookiePage> createState() => _CookiePageState();
}

class _CookiePageState extends State<CookiePage> {
  LoadingState _refreshIgneousState = LoadingState.idle;

  @override
  Widget build(BuildContext context) {
    // The igneous row must always be visible: it carries the refresh
    // button and the long-press refresh-mode dialog. When no igneous
    // cookie is stored yet, show a placeholder row with an empty value.
    List<Cookie> displayCookies = [...ehRequest.cookies];
    if (!displayCookies.any((cookie) => cookie.name == EHConsts.igneousCookieName)) {
      displayCookies.add(Cookie(EHConsts.igneousCookieName, ''));
    }
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text('accountSetting'.tr),
        actions: [
          IconButton(icon: const Icon(Icons.copy), onPressed: _copyCookies),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 12),
        children: displayCookies
            .map(
              (cookie) => ListTile(
                title: Text(cookie.name),
                subtitle: cookie.name == EHConsts.igneousCookieName
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(cookie.value.isEmpty ? 'emptyValue'.tr : cookie.value),
                          const SizedBox(height: 2),
                          Text(
                            'longPress2SwitchIgneousRefreshMode'.tr,
                            style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
                          ),
                        ],
                      )
                    : Text(cookie.value),
                trailing: cookie.name == EHConsts.igneousCookieName
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          LoadingStateIndicator(
                            loadingState: _refreshIgneousState,
                            loadingWidgetBuilder: () => const CupertinoActivityIndicator().marginOnly(right: 10),
                            idleWidgetBuilder: () => IconButton(icon: const Icon(Icons.refresh), onPressed: _refreshIgneousCookie),
                            successWidgetSameWithIdle: true,
                            errorWidgetSameWithIdle: true,
                          )
                        ],
                      )
                    : null,
                onTap: () => _copyCookie(cookie),
                onLongPress: cookie.name == EHConsts.igneousCookieName ? () => _showIgneousRefreshModeDialog(context) : null,
                dense: true,
              ),
            )
            .toList(),
      ).withListTileTheme(context),
    );
  }

  Future<void> _copyCookie(Cookie cookie) async {
    await FlutterClipboard.copy(CookieUtil.parse2String([cookie]));
    toast('hasCopiedToClipboard'.tr);
  }

  Future<void> _copyCookies() async {
    await FlutterClipboard.copy(
      CookieUtil.parse2String(
        ehRequest.cookies
            .where(
              (cookie) => cookie.name == 'ipb_member_id' || cookie.name == 'ipb_pass_hash' || cookie.name == 'igneous',
            )
            .toList(),
      ),
    );
    toast('hasCopiedToClipboard'.tr);
  }

  Future<void> _showIgneousRefreshModeDialog(BuildContext context) async {
    await showDialog(
      context: context,
      builder: (_) => const _IgneousRefreshModeDialog(),
    );
  }

  Future<void> _refreshIgneousCookie() async {
    if (!userSetting.hasLoggedIn()) {
      return;
    }

    if (_refreshIgneousState == LoadingState.loading) {
      return;
    }

    setStateSafely(() {
      _refreshIgneousState = LoadingState.loading;
    });

    IgneousRefreshResult result =
        await igneousRefreshService.refreshIgneousDetailed(force: true);

    if (result.success) {
      toast('success'.tr);
      setStateSafely(() {
        _refreshIgneousState = LoadingState.success;
      });
      return;
    }

    snack('refreshIgneousFailed'.tr, result.errorMessage ?? 'Sad panda');
    setStateSafely(() {
      _refreshIgneousState = LoadingState.error;
    });
  }
}


/// Refresh-mode dialog for the igneous cookie: a switch for API mode and
/// the API address. Confirming with the switch ON asks once more, because
/// enabling it sends the account's login credentials to that endpoint.
class _IgneousRefreshModeDialog extends StatefulWidget {
  const _IgneousRefreshModeDialog();

  @override
  State<_IgneousRefreshModeDialog> createState() => _IgneousRefreshModeDialogState();
}

class _IgneousRefreshModeDialogState extends State<_IgneousRefreshModeDialog> {
  late bool _useApi;
  late final TextEditingController _urlController;

  @override
  void initState() {
    super.initState();
    _useApi = advancedSetting.useIgneousRefreshApi.value;
    _urlController = TextEditingController(text: advancedSetting.igneousRefreshApiUrl.value);
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  String get _url {
    String url = _urlController.text.trim();
    return url.isEmpty ? AdvancedSetting.defaultIgneousRefreshApiUrl : url;
  }

  Future<void> _onConfirm() async {
    if (_useApi) {
      bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          content: Text('igneousRefreshApiWarning'.trParams({'url': _url})),
          actions: [
            TextButton(onPressed: () => backRoute(result: false), child: Text('cancel'.tr)),
            TextButton(onPressed: () => backRoute(result: true), child: Text('continue'.tr)),
          ],
        ),
      );
      if (confirmed != true) {
        return;
      }
    }
    await advancedSetting.saveIgneousRefreshApi(useApi: _useApi, apiUrl: _url);
    toast('success'.tr);
    backRoute();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('refreshIgneousViaApi'.tr),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SwitchListTile(
            title: Text('refreshIgneousViaApi'.tr),
            value: _useApi,
            onChanged: (value) => setState(() => _useApi = value),
            contentPadding: EdgeInsets.zero,
          ),
          TextField(
            controller: _urlController,
            decoration: InputDecoration(hintText: 'igneousRefreshApiUrl'.tr, isDense: true),
            keyboardType: TextInputType.url,
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: backRoute, child: Text('cancel'.tr)),
        TextButton(onPressed: _onConfirm, child: Text('OK'.tr)),
      ],
    );
  }
}
