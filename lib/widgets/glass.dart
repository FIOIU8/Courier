// glass.dart — 玻璃拟态（Glassmorphism）UI 基础组件
//
// 统一提供：圆角、悬浮阴影、半透明底色（透光）、毛玻璃模糊。
// 所有视觉参数集中在文件顶部，方便整体微调（改一处全应用生效）。

import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/models.dart';
import '../services/settings_state.dart';
import '../theme.dart';
import 'animations.dart';

// ============================================================
// 一、统一视觉参数（调整入口）
// ============================================================

/// 是否启用毛玻璃模糊（BackdropFilter）。
/// 桌面端渲染开销较大，若感觉卡顿可改为 false，自动回退为半透明圆角背景。
const bool kEnableGlass = true;

/// 毛玻璃模糊强度
const double kBlurSigma = 14;

// ---- 圆角 ----
const double kRadiusSm = 8; // 小控件：输入框、气泡、标签
const double kRadiusMd = 12; // 中：任务卡片、菜单
const double kRadiusLg = 16; // 大：悬浮面板、对话框

// ---- 悬浮阴影 ----
const List<BoxShadow> kShadowSm = [
  BoxShadow(color: Color(0x33000000), blurRadius: 12, offset: Offset(0, 3)),
];
const List<BoxShadow> kShadowMd = [
  BoxShadow(color: Color(0x55000000), blurRadius: 24, offset: Offset(0, 8)),
];
const List<BoxShadow> kShadowLg = [
  BoxShadow(color: Color(0x66000000), blurRadius: 36, offset: Offset(0, 14)),
];

// ---- 半透明底色（透光）----
/// 面板主体底色（约 80% 不透光，底层内容隐约透出）
const Color kGlassBg = Color(0xCC0C1220);

/// 头部/状态栏底色（约 60%，更透）
const Color kGlassHeaderBg = Color(0x990D1424);

/// 浮层底色（右键菜单、对话框，接近不透明保证可读性）
const Color kGlassFloatBg = Color(0xF20D1424);

/// 弱背景（标签、气泡）
const Color kGlassChipBg = Color(0x26FFFFFF);

/// 悬停高亮
const Color kGlassHoverBg = Color(0x3DFFFFFF);

/// 选中高亮（主色 15%）
const Color kGlassSelectedBg = Color(0x266366F1);

/// 玻璃边界（深色半透明，对齐原项目 glass-border: 220 15% 40% / 0.12）
const Color kGlassBorder = Color(0x1F615775);

/// 主色调（对齐原 React 版 Courier：teal 青色 hsl(172, 68%, 43%)）
/// 默认强调色；自定义主题启用后请使用 [accentColorOf]/[accentLightOf] 动态读取。
const Color kPrimary = Color(0xFF23B8A4);

/// 主色调浅色
const Color kPrimaryLight = Color(0xFF55D6C0);

/// 从 [SettingsState] 动态读取当前强调色（自定义主题）。
/// 调用方需位于 Provider 树内且处于 build 上下文（触发主题色变化重建）。
Color accentColorOf(BuildContext context) =>
    context.watch<SettingsState>().accentColor;

/// 从 [SettingsState] 动态读取当前强调色浅色。
Color accentLightOf(BuildContext context) =>
    context.watch<SettingsState>().accentLightColor;

/// 当前 UI 样式下的头部/状态栏底色（VSCode 风格为略亮于面板的中性色）。
/// 调用方需位于 Provider 树内且处于 build 上下文。
Color glassHeaderBgOf(BuildContext context) =>
    context.watch<SettingsState>().uiStyle == AppUiStyle.vscode
    ? const Color(0xFF2D2D2D)
    : kGlassHeaderBg;

/// 当前 UI 样式下的浮层底色（对话框、右键菜单，VSCode 风格为中性面板色）。
Color glassFloatBgOf(BuildContext context) =>
    context.watch<SettingsState>().uiStyle == AppUiStyle.vscode
    ? const Color(0xFF2D2D2D)
    : kGlassFloatBg;

/// 当前 UI 样式下的选中高亮（VSCode 风格为选中蓝）。
Color glassSelectedBgOf(BuildContext context) =>
    context.watch<SettingsState>().uiStyle == AppUiStyle.vscode
    ? VscodePalette.selection
    : kGlassSelectedBg;

/// 当前 UI 样式下的玻璃边界色。
Color glassBorderOf(BuildContext context) =>
    context.watch<SettingsState>().uiStyle == AppUiStyle.vscode
    ? VscodePalette.border
    : kGlassBorder;

/// 当前 UI 样式下输入框未聚焦底线的颜色（VSCode 风格为中性边界色）。
Color glassInputUnderlineOf(BuildContext context) =>
    context.watch<SettingsState>().uiStyle == AppUiStyle.vscode
    ? VscodePalette.border
    : const Color(0xFF1E2438);

/// 按系数 [opacity]（0.0–1.0）缩放颜色透明度，
/// 用于面板/标题栏/状态栏透明度调节（1.0 = 保持原样）。
Color applyOpacity(Color color, double opacity) =>
    color.withValues(alpha: color.a * opacity);

/// 统一对话框圆角与边框样式（随 UI 样式联动）。
ShapeBorder kDialogShapeOf(BuildContext context) => RoundedRectangleBorder(
  borderRadius: BorderRadius.circular(kRadiusLg),
  side: BorderSide(color: glassBorderOf(context)),
);

// ============================================================
// 二、Glass — 毛玻璃容器
// ============================================================

/// 圆角 + 半透明底色 + 毛玻璃模糊 + 悬浮阴影的容器。
/// [kEnableGlass] 为 false 时自动退化为纯半透明圆角卡片。
/// [color]/[boxShadow]/[border] 未指定时按当前 UI 样式取默认
/// （VSCode 风格为扁平面板色、无阴影）。
/// [opacity] 对底色做透明度缩放（0.0–1.0），用于让背景图片透出。
class Glass extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double radius;
  final Color? color;
  final double? opacity;
  final List<BoxShadow>? boxShadow;
  final Border? border;
  final Clip clipBehavior;

  const Glass({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.radius = kRadiusLg,
    this.color,
    this.opacity,
    this.boxShadow,
    this.border,
    this.clipBehavior = Clip.antiAlias,
  });

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsState>();
    final isVscode = settings.uiStyle == AppUiStyle.vscode;
    final baseColor = color ?? (isVscode ? VscodePalette.panel : kGlassBg);
    final resolvedColor = opacity == null
        ? baseColor
        : applyOpacity(baseColor, opacity!);
    Widget inner = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: resolvedColor,
        borderRadius: BorderRadius.circular(radius),
        border:
            border ??
            Border.all(
              color: isVscode ? VscodePalette.border : kGlassBorder,
            ),
      ),
      child: child,
    );

    // 毛玻璃模糊运行时开关与强度（自定义主题外观设置）。
    // 关闭、强度为 0 或 VSCode 扁平风格时自动退化为纯色圆角卡片。
    final sigma = settings.blurSigma;
    if (settings.glassEnabled && sigma > 0 && !isVscode) {
      inner = ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        clipBehavior: clipBehavior,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: inner,
        ),
      );
    }

    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: boxShadow ?? (isVscode ? const <BoxShadow>[] : kShadowMd),
      ),
      child: inner,
    );
  }
}

// ============================================================
// 三、HoverCard — 悬停提升的悬浮卡片
// ============================================================

/// 鼠标悬停时阴影增强、背景提亮的卡片（任务卡片、列表项等）。
class HoverCard extends StatefulWidget {
  final Widget child;
  final double radius;
  final Color color;
  final Color hoverColor;
  final List<BoxShadow> shadow;
  final List<BoxShadow> hoverShadow;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;
  final Border? border;
  final Border? hoverBorder;

  const HoverCard({
    super.key,
    required this.child,
    this.radius = kRadiusMd,
    this.color = Colors.transparent,
    this.hoverColor = kGlassHoverBg,
    this.shadow = const [],
    this.hoverShadow = kShadowSm,
    this.padding,
    this.margin,
    this.onTap,
    this.border,
    this.hoverBorder,
  });

  @override
  State<HoverCard> createState() => _HoverCardState();
}

class _HoverCardState extends State<HoverCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : MouseCursor.defer,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: kAnimDurationFast,
          curve: Curves.easeOutCubic,
          margin: widget.margin,
          padding: widget.padding,
          transform: _hover
              ? Matrix4.translationValues(0, -2, 0)
              : Matrix4.identity(),
          decoration: BoxDecoration(
            color: _hover ? widget.hoverColor : widget.color,
            borderRadius: BorderRadius.circular(widget.radius),
            border: _hover
                ? (widget.hoverBorder ?? widget.border)
                : widget.border,
            boxShadow: _hover ? widget.hoverShadow : widget.shadow,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
