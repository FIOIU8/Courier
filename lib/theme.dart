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
/// [accentColor] 为 Material 3 样式的强调色（自定义主题）。
ThemeData buildAppTheme(AppUiStyle style, Color accentColor) {
  return switch (style) {
    AppUiStyle.material3 => _buildMaterial3Theme(accentColor),
    AppUiStyle.vscode => _buildVscodeTheme(),
  };
}

ThemeData _buildMaterial3Theme(Color accentColor) {
  return ThemeData(
    brightness: Brightness.dark,
    colorSchemeSeed: accentColor,
    useMaterial3: true,
    fontFamily: 'Microsoft YaHei UI',
  );
}

ThemeData _buildVscodeTheme() {
  
  return ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    fontFamily: 'Microsoft YaHei UI',
    colorScheme: const ColorScheme.dark(
      primary: VscodePalette.accent,
      onPrimary: Colors.white,
      secondary: VscodePalette.accent,
      onSecondary: Colors.white,
      secondaryContainer: VscodePalette.selection,
      onSecondaryContainer: Color(0xFFD5EFFF),
      surface: VscodePalette.panel,
      onSurface: VscodePalette.foreground,
      onSurfaceVariant: VscodePalette.foregroundMuted,
      surfaceContainerHighest: Color(0xFF2D2D2D),
      outline: VscodePalette.border,
      outlineVariant: VscodePalette.border,
      error: Color(0xFFF48771),
      onError: Colors.white,
      shadow: Colors.black,
      scrim: Colors.black,
    ),
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
  );
}
