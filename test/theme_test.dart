// theme_test.dart - 主题工厂输出差异测试。

import 'package:courier_flutter/services/models.dart';
import 'package:courier_flutter/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Material 3 与 VSCode 主题输出不同的配色与密度', () {
    const accent = Color(0xFF23B8A4);
    final material = buildAppTheme(AppUiStyle.material3, accent);
    final vscode = buildAppTheme(AppUiStyle.vscode, accent);

    expect(material.brightness, Brightness.dark);
    expect(material.useMaterial3, isTrue);

    // 密度：VSCode 紧凑，Material 3 为标准
    expect(vscode.visualDensity, VisualDensity.compact);
    expect(material.visualDensity, isNot(VisualDensity.compact));

    // 表面/前景/边界为 VSCode 中性色
    expect(vscode.colorScheme.surface, const Color(0xFF252526));
    expect(vscode.colorScheme.onSurface, const Color(0xFFCCCCCC));
    expect(vscode.colorScheme.outline, const Color(0xFF3C3C3C));
    expect(vscode.colorScheme.surface, isNot(material.colorScheme.surface));
    // 交互控件色（primary）跟随强调色：与 Material 3 同源，而非硬编码蓝
    expect(vscode.colorScheme.primary, material.colorScheme.primary);
    expect(vscode.colorScheme.primary, isNot(const Color(0xFF007ACC)));
  });

  test('VSCode 主题组件扁平化：无阴影卡片与面板色对话框', () {
    final vscode = buildAppTheme(AppUiStyle.vscode, const Color(0xFF23B8A4));

    final card = vscode.cardTheme;
    expect(card.elevation, 0);
    expect(card.surfaceTintColor, Colors.transparent);
    expect((card.shape! as RoundedRectangleBorder).borderRadius, const BorderRadius.all(Radius.circular(4)));

    expect(vscode.dialogTheme.backgroundColor, const Color(0xFF252526));
    expect(vscode.dialogTheme.surfaceTintColor, Colors.transparent);

    expect(vscode.dividerTheme.color, const Color(0xFF3C3C3C));
  });
}
