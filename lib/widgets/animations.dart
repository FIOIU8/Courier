// animations.dart — 统一动画时长与曲线常量
//
// 所有界面动画的参数集中在文件顶部，方便整体微调（改一处全应用生效）。
// 约定：控件态动画用 fast，面板/视图切换用 med，大区域打开/关闭用 slow。

import 'package:flutter/material.dart';

/// 控件态动画时长（图标切换、行内高亮、气泡入场、列表项状态变化）
const Duration kAnimDurationFast = Duration(milliseconds: 120);

/// 面板/视图切换动画时长（右栏 Tab 内容、Git 视图、设置区块、详情展开）
const Duration kAnimDurationMed = Duration(milliseconds: 200);

/// 大区域动画时长（设置卡片打开/关闭）
const Duration kAnimDurationSlow = Duration(milliseconds: 280);

/// 入场曲线（快速启动后缓出，避免生硬）
const Curve kAnimCurveIn = Curves.easeOutCubic;

/// 退场曲线（缓入减速）
const Curve kAnimCurveOut = Curves.easeInCubic;

/// 通用的"淡入 + 轻微上移"切换过渡，供各面板 AnimatedSwitcher 复用。
/// 仅用于 Glass 内部内容区（纯色/普通 Material），不会触碰 BackdropFilter，
/// 因此透明度动画不会导致毛玻璃模糊失效。
Widget kPanelSwitchTransition(Widget child, Animation<double> animation) {
  return FadeTransition(
    opacity: animation,
    child: SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, 0.02),
        end: Offset.zero,
      ).animate(animation),
      child: child,
    ),
  );
}

/// 图标/按钮切换过渡：淡入 + 轻微缩放，用于发送/停止、启动/暂停等控件态。
Widget kIconSwitchTransition(Widget child, Animation<double> animation) {
  return FadeTransition(
    opacity: animation,
    child: ScaleTransition(
      scale: Tween<double>(begin: 0.8, end: 1.0).animate(animation),
      child: child,
    ),
  );
}
