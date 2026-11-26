import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class AccountController extends GetxController {
  void bilibiliTap() async {
    if (BiliBiliAccountService.instance.logined.value) {
      var result = await Utils.showAlertDialog("确定要退出哔哩哔哩账号吗？", title: "退出登录");
      if (result) {
        BiliBiliAccountService.instance.logout();
      }
    } else {
      //AppNavigator.toBiliBiliLogin();
      bilibiliLogin();
    }
  }

  void bilibiliLogin() {
    Utils.showBottomSheet(
      title: "登录哔哩哔哩",
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Visibility(
            visible: Platform.isAndroid || Platform.isIOS,
            child: ListTile(
              leading: const Icon(Icons.account_circle_outlined),
              title: const Text("Web登录"),
              subtitle: const Text("填写用户名密码登录"),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Get.back();
                Get.toNamed(RoutePath.kBiliBiliWebLogin);
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.qr_code),
            title: const Text("扫码登录"),
            subtitle: const Text("使用哔哩哔哩APP扫描二维码登录"),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Get.back();
              Get.toNamed(RoutePath.kBiliBiliQRLogin);
            },
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text("Cookie登录"),
            subtitle: const Text("手动输入Cookie登录"),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Get.back();
              doBiliBiliCookieLogin();
            },
          ),
        ],
      ),
    );
  }

  void doBiliBiliCookieLogin() async {
    var cookie = await Utils.showEditTextDialog(
      "",
      title: "请输入Cookie",
      hintText: "请输入Cookie",
    );
    if (cookie == null || cookie.isEmpty) {
      return;
    }
    BiliBiliAccountService.instance.setCookie(cookie);
    await BiliBiliAccountService.instance.loadUserInfo();
  }

  void douyinTap() async {
    // 已登录：只提供退出
    if (DouyinAccountService.instance.logined.value) {
      var result = await Utils.showAlertDialog(
        "当前已登录抖音账号，退出后「我的关注」会回退到本地关注列表。",
        title: "退出抖音登录",
      );
      if (result) {
        DouyinAccountService.instance.clearCookie();
        SmartDialog.showToast("已退出抖音账号");
      }
      return;
    }

    // 未登录：在「网页登录」和「手动填 cookie」之间选
    var action = await Get.dialog<String>(
      AlertDialog(
        title: const Text("抖音直播"),
        content: const Text(
          "登录抖音账号后，首页「我的关注」会直接展示账号关注的主播；"
          "不登录也可以继续看热门直播。",
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: "cookie"),
            child: const Text("手动填 Cookie"),
          ),
          TextButton(
            onPressed: () => Get.back(result: "login"),
            child: const Text("网页登录"),
          ),
        ],
      ),
    );

    if (action == "login") {
      Get.toNamed(RoutePath.kDouyinWebLogin);
    } else if (action == "cookie") {
      doDouyinCookieConfig();
    }
  }

  /// 手动填写 Cookie：既支持只填 ttwid 值，也支持粘贴包含登录态的完整 Cookie。
  void doDouyinCookieConfig() {
    var savedCookie = DouyinAccountService.instance.cookie;
    var controller = TextEditingController(text: savedCookie);

    Get.dialog(
      AlertDialog(
        title: const Text("配置抖音 Cookie"),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "粘贴完整 Cookie（含 sessionid）即视为登录，可解锁搜索主播、关注列表。\n"
                "只填 ttwid 值则仅能看直播；留空使用默认 ttwid。",
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 6,
                decoration: const InputDecoration(
                  hintText: "请粘贴完整 Cookie 或 ttwid 值（留空则使用默认值）",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () {
                  controller.text = DouyinSite.kDefaultCookie;
                },
                icon: const Icon(Icons.restore),
                label: const Text("恢复默认 ttwid"),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: const Text("取消"),
          ),
          TextButton(
            onPressed: () {
              var input = controller.text.trim();
              Get.back();
              if (input.isEmpty) {
                DouyinAccountService.instance.clearCookie();
                SmartDialog.showToast("已清除 Cookie，将使用默认 ttwid");
              } else {
                // 只填了 ttwid 的值时自动补前缀，粘贴完整 Cookie 则原样保存
                var cookie = input;
                if (!input.contains('=')) {
                  cookie = 'ttwid=$input';
                }
                DouyinAccountService.instance.setCookie(cookie);
                SmartDialog.showToast("Cookie 已保存");
              }
            },
            child: const Text("确定"),
          ),
        ],
      ),
    );
  }
}
