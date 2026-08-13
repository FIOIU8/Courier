// theme.dart — 应用主题工厂
//
// 根据 UI 样式（Material 3 / VSCode）构建 ThemeData。
// Material 3：玻璃拟态 + 自定义强调色（colorSchemeSeed）。
// VSCode：暗色扁平风格（#1E1E1E 背景、紧凑密度、无阴影、小圆角）。

import 'package:flutter/material.dart';

import 'services/models.dart';

/// VSCode 风格配色（主题与玻璃组件共用，单一来源）
abstract final class VscodePalette {
  static const Color background = Color(0xFF1E1E1E);
  static const Color panel = Color(0xFF252526);
  static const Color border = Color(0xFF3C3C3C);
  static const Color accent = Color(0xFF007ACC);
  static const Color selection = Color(0xFF04395E);
  static const Color foreground = Color(0xFFCCCCCC);
  static const Color foregroundMuted = Color(0xFF8A8A8A);
}

/// 根据 [style] 构建应用主题。
/// [accentColor] 为强调色（自定义主题）：Material 3 驱动整套配色；
/// VSCode 风格中驱动交互控件（按钮/滑杆/Switch/选中态），表面保持中性扁平。
ThemeData buildAppTheme(AppUiStyle style, Color accentColor) {
  return switch (style) {
    AppUiStyle.material3 => _buildMaterial3Theme(accentColor),
    AppUiStyle.vscode => _buildVscodeTheme(accentColor),
  };
}

ThemeData _buildMaterial3Theme(Color accentColor) {
  return ThemeData(
    brightness: Brightness.dark,
    colorSchemeSeed: accentColor,
    useMaterial3: true,
    fontFamily: 'Microsoft YaHei UI',
    // 显式分割线色（对齐 glass.dart 的 kGlassBorder 0x1F615775），
    // 使全应用的 Divider()/VerticalDivider() 视觉一致且不残留蓝色调。
    dividerTheme: const DividerThemeData(color: Color(0x1F615775)),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
    ),
  );
}

ThemeData _buildVscodeTheme(Color accentColor) {
  // 从强调色派生交互色（onPrimary/onSecondary 等对比度自动处理），
  // 仅把表面/边界替换为 VSCode 中性扁平色。
  final scheme = ColorScheme.fromSeed(
    seedColor: accentColor,
    brightness: Brightness.dark,
  ).copyWith(
    surface: VscodePalette.panel,
    onSurface: VscodePalette.foreground,
    onSurfaceVariant: VscodePalette.foregroundMuted,
    surfaceContainerHighest: const Color(0xFF2D2D2D),
    outline: VscodePalette.border,
    outlineVariant: VscodePalette.border,
  );
  return ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    fontFamily: 'Microsoft YaHei UI',
    colorScheme: scheme,
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    dividerTheme: const DividerThemeData(color: VscodePalette.border),
    cardTheme: const CardThemeData(
      color: VscodePalette.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(4)),
        side: BorderSide(color: VscodePalette.border),
      ),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: VscodePalette.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(6)),
        side: BorderSide(color: VscodePalette.border),
      ),
    ),
    inputDecorationTheme: const InputDecorationThemeData(
      isDense: true,
      filled: true,
      fillColor: Color(0xFF2D2D2D),
      hintStyle: TextStyle(color: VscodePalette.foregroundMuted, fontSize: 13),
      labelStyle: TextStyle(color: VscodePalette.foregroundMuted, fontSize: 13),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(4)),
        borderSide: BorderSide(color: VscodePalette.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(4)),
        borderSide: BorderSide(color: VscodePalette.accent),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Color(0xFF333333),
      contentTextStyle: TextStyle(color: VscodePalette.foreground),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(4)),
      ),
    ),
    tooltipTheme: const TooltipThemeData(
      decoration: BoxDecoration(
        color: Color(0xFF2D2D2D),
        borderRadius: BorderRadius.all(Radius.circular(4)),
        border: Border.fromBorderSide(BorderSide(color: VscodePalette.border)),
      ),
      textStyle: TextStyle(color: VscodePalette.foreground, fontSize: 12),
    ),
    menuTheme: const MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(VscodePalette.panel),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
        side: WidgetStatePropertyAll(BorderSide(color: VscodePalette.border)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4))),
        ),
      ),
    ),
    listTileTheme: const ListTileThemeData(dense: true),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    ),
  );
}
