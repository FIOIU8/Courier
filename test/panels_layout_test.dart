import 'package:courier_flutter/services/ai_service.dart';
import 'package:courier_flutter/services/app_logger.dart';
import 'package:courier_flutter/services/courier_service.dart';
import 'package:courier_flutter/services/safe_file_system.dart';
import 'package:courier_flutter/services/secure_storage_service.dart';
import 'package:courier_flutter/services/settings_state.dart';
import 'package:courier_flutter/services/workspace_config_service.dart';
import 'package:courier_flutter/services/workspace_service.dart';
import 'package:courier_flutter/widgets/right_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_fakes.dart';

void main() {
  testWidgets('右侧面板在窄宽度下切换各标签无溢出', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final secureStorage = SecureStorageService(store: MemoryCredentialStore());
    final settings = SettingsState(
      secureStorage: secureStorage,
      environment: const {},
    );
    await settings.load();
    final logger = AppLogger();
    final ai = AIService(
      settings: settings,
      secureStorage: secureStorage,
      logger: logger,
      providers: {'openai': FakeAIProviderClient()},
    );
    final courier = CourierService(
      settings: settings,
      secureStorage: secureStorage,
      logger: logger,
      aiService: ai,
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

    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsState>.value(value: settings),
          ChangeNotifierProvider<CourierService>.value(value: courier),
          ChangeNotifierProvider<WorkspaceService>.value(value: workspace),
        ],
        child: const MaterialApp(home: Scaffold(body: RightPanel())),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);

    for (final label in ['任务', 'Git', '助手']) {
      await tester.tap(find.text(label).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull, reason: '$label 标签布局异常');
    }
  }, timeout: const Timeout(Duration(seconds: 20)));

  testWidgets('右栏 Tab 切换为反向推入动画（新旧面板滑动方向相反）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final secureStorage = SecureStorageService(store: MemoryCredentialStore());
    final settings = SettingsState(
      secureStorage: secureStorage,
      environment: const {},
    );
    await settings.load();
    final logger = AppLogger();
    final ai = AIService(
      settings: settings,
      secureStorage: secureStorage,
      logger: logger,
      providers: {'openai': FakeAIProviderClient()},
    );
    final courier = CourierService(
      settings: settings,
      secureStorage: secureStorage,
      logger: logger,
      aiService: ai,
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

    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsState>.value(value: settings),
          ChangeNotifierProvider<CourierService>.value(value: courier),
          ChangeNotifierProvider<WorkspaceService>.value(value: workspace),
        ],
        child: const MaterialApp(home: Scaffold(body: RightPanel())),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    List<double> activeDx() => tester
        .widgetList<SlideTransition>(find.byType(SlideTransition))
        .where((w) => w.position.value != Offset.zero)
        .map((w) => w.position.value.dx)
        .toList();

    // 初始面板应静止在原位（无位移残留，否则被移出屏幕导致空白）
    expect(activeDx(), isEmpty, reason: '初始面板应静止原位');
    expect(find.text('新会话'), findsOneWidget, reason: '初始助手面板应可见');

    // 前进：助手 → 任务，旧面板向左滑出（dx<0）、新面板从右滑入（dx>0）
    await tester.tap(find.text('任务').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final forward = activeDx();
    expect(forward.any((dx) => dx > 0), isTrue, reason: '前进时新面板应从右滑入');
    expect(forward.any((dx) => dx < 0), isTrue, reason: '前进时旧面板应向左滑出');
    await tester.pumpAndSettle();

    // 后退：任务 → 助手，新面板从左滑入（dx<0）、旧面板向右滑出（dx>0）
    await tester.tap(find.text('助手').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final backward = activeDx();
    expect(backward.any((dx) => dx < 0), isTrue, reason: '后退时新面板应从左滑入');
    expect(backward.any((dx) => dx > 0), isTrue, reason: '后退时旧面板应向右滑出');
    await tester.pumpAndSettle();

    // 切换完成后不得有位移残留（否则当前面板被移出屏幕导致空白）
    final settled = activeDx();
    expect(settled, isEmpty, reason: '切换完成后当前面板应静止在原位');

    // 当前面板内容应可见
    expect(find.text('新会话'), findsOneWidget, reason: '助手面板内容应可见');
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(seconds: 20)));

  testWidgets('动画中途快速切换 Tab 无空白', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final secureStorage = SecureStorageService(store: MemoryCredentialStore());
    final settings = SettingsState(
      secureStorage: secureStorage,
      environment: const {},
    );
    await settings.load();
    final logger = AppLogger();
    final ai = AIService(
      settings: settings,
      secureStorage: secureStorage,
      logger: logger,
      providers: {'openai': FakeAIProviderClient()},
    );
    final courier = CourierService(
      settings: settings,
      secureStorage: secureStorage,
      logger: logger,
      aiService: ai,
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

    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsState>.value(value: settings),
          ChangeNotifierProvider<CourierService>.value(value: courier),
          ChangeNotifierProvider<WorkspaceService>.value(value: workspace),
        ],
        child: const MaterialApp(home: Scaffold(body: RightPanel())),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    List<double> activeDx() => tester
        .widgetList<SlideTransition>(find.byType(SlideTransition))
        .where((w) => w.position.value != Offset.zero)
        .map((w) => w.position.value.dx)
        .toList();

    // 前进到任务，动画进行到一半时立刻切回助手
    await tester.tap(find.text('任务').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.text('助手').first);
    await tester.pump();
    await tester.pumpAndSettle();

    // 快速切换后无位移残留、内容可见（无空白帧）
    expect(activeDx(), isEmpty, reason: '快速切换后应静止原位');
    expect(find.text('新会话'), findsOneWidget, reason: '助手面板内容应可见');
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(seconds: 20)));
}
