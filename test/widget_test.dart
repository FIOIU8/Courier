// widget_test.dart — UI 组件冒烟测试
//
// 验证玻璃拟态基础组件（Glass）可正常渲染。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:courier_flutter/main.dart' show StartupFailureApp;
import 'package:courier_flutter/services/models.dart';
import 'package:courier_flutter/services/secure_storage_service.dart';
import 'package:courier_flutter/services/settings_state.dart';
import 'package:courier_flutter/widgets/glass.dart';

import 'support/test_fakes.dart';

void main() {
  testWidgets('Glass 组件可渲染内容', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final secureStorage = SecureStorageService(store: MemoryCredentialStore());
    final settings = SettingsState(
      secureStorage: secureStorage,
      environment: const {},
    );
    await settings.load();
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsState>.value(value: settings),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Center(
              child: Glass(padding: EdgeInsets.all(16), child: Text('玻璃容器')),
            ),
          ),
        ),
      ),
    );

    expect(find.text('玻璃容器'), findsOneWidget);
    expect(find.byType(Glass), findsOneWidget);
  });

  testWidgets('Glass 在 VSCode 风格下使用扁平面板色且无阴影', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final secureStorage = SecureStorageService(store: MemoryCredentialStore());
    final settings = SettingsState(
      secureStorage: secureStorage,
      environment: const {},
    );
    await settings.load();
    await settings.setUiStyle(AppUiStyle.vscode);
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsState>.value(value: settings),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Center(
              child: Glass(padding: EdgeInsets.all(16), child: Text('扁平面板')),
            ),
          ),
        ),
      ),
    );

    final containers = tester.widgetList<Container>(find.byType(Container));
    expect(
      containers.any((c) {
        final decoration = c.decoration;
        return decoration is BoxDecoration &&
            decoration.color == const Color(0xFF252526);
      }),
      isTrue,
      reason: 'VSCode 风格下 Glass 面板底色应为 #252526',
    );
    expect(
      containers.any((c) {
        final decoration = c.decoration;
        return decoration is BoxDecoration &&
            (decoration.boxShadow?.isNotEmpty ?? false);
      }),
      isFalse,
      reason: 'VSCode 扁平风格下不应有悬浮阴影',
    );
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
