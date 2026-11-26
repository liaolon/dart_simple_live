import 'package:flutter/material.dart';
import 'package:simple_live_app/app/app_skin.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';

/// 页面级皮肤底。
///
/// 主题里 `scaffoldBackgroundColor` / `canvasColor` 是透明的，
/// 渐变以前只画在 app 根部（main.dart 的 Stack 底层）。页面因此没有自己的
/// 不透明底：一旦启用页面过渡，新旧两页会同时绘制，旧页元素就透在新页上。
/// 这里给每个路由页面补一层渐变底，过渡就正常了。
class SkinPage extends StatelessWidget {
  final Widget child;

  const SkinPage({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final settings = AppSettingsController.instance;
    final brightness = Theme.of(context).brightness;

    // 动态取色 / 自定义主色时没有渐变，用主题 surface 兜底
    if (settings.isDynamic.value || settings.skinId.value == "custom") {
      return ColoredBox(
        color: Theme.of(context).colorScheme.surface,
        child: child,
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: AppSkins.byId(settings.skinId.value).gradient(brightness),
      ),
      child: child,
    );
  }
}
