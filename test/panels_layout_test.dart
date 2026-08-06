// panels_layout_test.dart

import 'package:courier_flutter/services/ai_service.dart';
import 'package:courier_flutter/services/app_logger.dart';
import 'package:courier_flutter/services/courier_service.dart';
import 'package:courier_flutter/services/safe_file_system.dart';
import 'package:courier_flutter/services/secure_storage_service.dart';
import 'package:courier_flutter/services/settings_state.dart';
import 'package:courier_flutter/services/workspace_config_service.dart';
import 'package:courier_flutter/services/workspace_service.dart';
import 'package:courier_flutter/widgets/ai_assistant_panel.dart';
import 'package:courier_flutter/widgets/right_panel.dart';
import 'package:courier_flutter/widgets/task_queue_panel.dart';
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

  testWidgets('右栏 Tab 切换为原位淡入（旧面板立即移除、无滑动暴露）', (tester) async {
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

    // 切换不再使用滑动，任何时刻都不应存在位移残留
    List<double> activeDx() => tester
        .widgetList<SlideTransition>(find.byType(SlideTransition))
        .where((w) => w.position.value != Offset.zero)
        .map((w) => w.position.value.dx)
        .toList();

    // 初始助手面板应静止可见
    expect(activeDx(), isEmpty, reason: '初始面板应静止原位');
    expect(find.text('新会话'), findsOneWidget, reason: '初始助手面板应可见');

    // 切到任务：旧面板立即移除，任务面板可见
    await tester.tap(find.text('任务').first);
    await tester.pump();
    expect(find.text('新会话'), findsNothing, reason: '旧助手面板应立即移除');
    await tester.pumpAndSettle();
    expect(activeDx(), isEmpty, reason: '切换后无位移残留');
    expect(find.byType(TaskQueuePanel), findsOneWidget, reason: '任务面板应可见');

    // 切回助手：助手面板重新可见
    await tester.tap(find.text('助手').first);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(activeDx(), isEmpty);
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

  testWidgets('助手面板 header 在无会话时显示模型下拉并禁用切换', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final secureStorage = SecureStorageService(store: MemoryCredentialStore());
    final settings = SettingsState(
      secureStorage: secureStorage,
      environment: const {},
    );
    await settings.load();
    await settings.saveApiKey(generatedCredential());
    await settings.addAiModel('model-a');
    await settings.addAiModel('model-b');
    await settings.setAiModelId('model-a');
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
    addTearDown(() {
      courier.dispose();
      settings.dispose();
    });

    tester.view.physicalSize = const Size(420, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsState>.value(value: settings),
          ChangeNotifierProvider<CourierService>.value(value: courier),
        ],
        // workspacePath 为空：不建立会话（真实目录 IO 在 widget 测试中不可用）
        child: const MaterialApp(
          home: Scaffold(body: AIAssistantPanel(workspacePath: '')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 会话未建立：header 显示模型下拉（禁用），并展示默认模型
    expect(courier.aiSession, isNull);
    expect(find.byKey(const ValueKey('assistant-model-select')), findsOneWidget);
    expect(find.text('model-a'), findsOneWidget, reason: '下拉显示当前默认模型');
    final dropdown = tester.widget<DropdownButton<String>>(
      find.byKey(const ValueKey('assistant-model-select')),
    );
    expect(dropdown.onChanged, isNull, reason: '会话未建立时切换应禁用');
    expect(dropdown.items, hasLength(2), reason: '选项来自我的模型集合');
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(seconds: 20)));
}
