// widget_test.dart — UI 组件冒烟测试
//
// 验证玻璃拟态基础组件（Glass）可正常渲染。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:courier_flutter/main.dart' show StartupFailureApp;
import 'package:courier_flutter/widgets/glass.dart';

void main() {
  testWidgets('Glass 组件可渲染内容', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Glass(padding: EdgeInsets.all(16), child: Text('玻璃容器')),
          ),
        ),
      ),
    );

    expect(find.text('玻璃容器'), findsOneWidget);
    expect(find.byType(Glass), findsOneWidget);
  });

  testWidgets('HoverCard 组件可渲染内容', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: HoverCard(padding: EdgeInsets.all(16), child: Text('悬浮卡片')),
          ),
        ),
      ),
    );

    expect(find.text('悬浮卡片'), findsOneWidget);
  });

  testWidgets('启动失败界面显示错误并允许关闭应用', (WidgetTester tester) async {
    var closeCount = 0;
    await tester.pumpWidget(
      StartupFailureApp(
        errorCode: 'STARTUP_FAILED',
        message: '应用服务初始化失败，请关闭应用后重试。',
        onClose: () async {
          closeCount += 1;
        },
      ),
    );

    expect(find.text('Courier 无法启动'), findsOneWidget);
    expect(find.text('错误代码: STARTUP_FAILED'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '关闭应用'));
    await tester.pump();

    expect(closeCount, 1);
  });
}
