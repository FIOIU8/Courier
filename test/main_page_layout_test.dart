import 'package:courier_flutter/main.dart' show MainPage;
import 'package:courier_flutter/services/ai_service.dart';
import 'package:courier_flutter/services/app_logger.dart';
import 'package:courier_flutter/services/courier_service.dart';
import 'package:courier_flutter/services/safe_file_system.dart';
import 'package:courier_flutter/services/secure_storage_service.dart';
import 'package:courier_flutter/services/settings_state.dart';
import 'package:courier_flutter/services/workspace_config_service.dart';
import 'package:courier_flutter/services/workspace_service.dart';
import 'package:courier_flutter/widgets/glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_fakes.dart';

void main() {
  testWidgets('主窗口标题栏和状态栏贴合窗口边缘', (tester) async {
    SharedPreferences.setMockInitialValues({'restore_workspace': false});
    final secureStorage = SecureStorageService(store: MemoryCredentialStore());
    final settings = SettingsState(
      secureStorage: secureStorage,
      environment: const {},
    );
    await settings.load();
    final logger = AppLogger();
    final courier = CourierService(
      settings: settings,
      secureStorage: secureStorage,
      logger: logger,
      aiService: AIService(
        settings: settings,
        secureStorage: secureStorage,
        logger: logger,
        providers: {'openai': FakeAIProviderClient()},
      ),
    );
    final workspace = WorkspaceService(
      fileSystem: SafeFileSystem(),
      configService: WorkspaceConfigService(logger: logger),
      logger: logger,
    );
    addTearDown(() {
      workspace.dispose();
      courier.dispose();
      settings.dispose();
    });

    tester.view.physicalSize = const Size(1024, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsState>.value(value: settings),
          ChangeNotifierProvider<CourierService>.value(value: courier),
          ChangeNotifierProvider<WorkspaceService>.value(value: workspace),
        ],
        child: const MaterialApp(home: MainPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: '主窗口布局渲染异常');

    final titleBar = find.byKey(const ValueKey('window-title-bar'));
    final statusBar = find.byKey(const ValueKey('window-status-bar'));
    expect(titleBar, findsOneWidget);
    expect(statusBar, findsOneWidget);
    expect(
      find.ancestor(of: titleBar, matching: find.byType(Glass)),
      findsNothing,
    );
    expect(
      find.ancestor(of: statusBar, matching: find.byType(Glass)),
      findsNothing,
    );
    expect(find.byType(Glass), findsAtLeastNWidgets(3));

    final titleRect = tester.getRect(titleBar);
    final statusRect = tester.getRect(statusBar);
    expect(titleRect.left, 0);
    expect(titleRect.top, 0);
    expect(titleRect.right, 1024);
    expect(statusRect.left, 0);
    expect(statusRect.right, 1024);
    expect(statusRect.bottom, 720);

    final titleDecoration =
        tester.widget<Container>(titleBar).decoration! as BoxDecoration;
    final statusDecoration =
        tester.widget<DecoratedBox>(statusBar).decoration as BoxDecoration;
    expect(titleDecoration.color, kGlassHeaderBg);
    expect(titleDecoration.borderRadius, isNull);
    expect(titleDecoration.boxShadow, isNull);
    expect((titleDecoration.border! as Border).bottom.color, kGlassBorder);
    expect(statusDecoration.color, kGlassHeaderBg);
    expect(statusDecoration.borderRadius, isNull);
    expect(statusDecoration.boxShadow, isNull);
    expect((statusDecoration.border! as Border).top.color, kGlassBorder);
  });
}
