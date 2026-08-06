// settings_page_test.dart - 设置页渲染测试。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:courier_flutter/services/app_logger.dart';
import 'package:courier_flutter/services/ai_service.dart';
import 'package:courier_flutter/services/courier_service.dart';
import 'package:courier_flutter/services/safe_file_system.dart';
import 'package:courier_flutter/services/secure_storage_service.dart';
import 'package:courier_flutter/services/settings_state.dart';
import 'package:courier_flutter/services/workspace_config_service.dart';
import 'package:courier_flutter/services/workspace_service.dart';
import 'package:courier_flutter/widgets/glass.dart';
import 'package:courier_flutter/widgets/settings_page.dart';

import 'support/test_fakes.dart';

class _MemoryCredentialStore implements CredentialStore {
  final Map<String, String> _values = {};

  @override
  Future<bool> containsKey(String key) async => _values.containsKey(key);

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }
}

void main() {
  testWidgets('设置页各分区渲染无溢出', (WidgetTester tester) async {
    var closeCount = 0;
    SharedPreferences.setMockInitialValues({});
    final secureStorage = SecureStorageService(store: _MemoryCredentialStore());
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
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsState>.value(value: settings),
          ChangeNotifierProvider<CourierService>.value(value: courier),
          ChangeNotifierProvider<WorkspaceService>.value(value: workspace),
        ],
        child: MaterialApp(
          home: Scaffold(body: SettingsPage(onClose: () => closeCount += 1)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: '设置页初始渲染异常/溢出');

    final settingsCard = find.byType(Glass);
    final closeButton = find.byTooltip('关闭设置');
    expect(settingsCard, findsOneWidget);
    expect(closeButton, findsOneWidget);

    final cardRect = tester.getRect(settingsCard);
    final closeRect = tester.getRect(closeButton);
    expect(cardRect.right - closeRect.right, lessThanOrEqualTo(24));
    expect(closeRect.top - cardRect.top, lessThanOrEqualTo(24));

    await tester.tap(closeButton);
    await tester.pump();
    expect(closeCount, 1);

    for (final label in ['供应商', '编辑器', '任务', '通用', '外观', '关于']) {
      await tester.tap(find.text(label).first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '「$label」分区渲染异常/溢出');
    }

    // 外观区块：切换主题强调色并验证持久化与回退
    await tester.tap(find.text('外观').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('蓝'));
    await tester.pumpAndSettle();
    expect(settings.accentColor.toARGB32(), 0xFF3B82F6, reason: '主题色应切换为蓝色');
    await tester.tap(find.text('青绿'));
    await tester.pumpAndSettle();
    expect(settings.accentColor.toARGB32(), 0xFF23B8A4, reason: '主题色应恢复默认青绿');
    expect(tester.takeException(), isNull);
  });

  testWidgets('自定义供应商表单可新增并经二次确认删除', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final secureStorage = SecureStorageService(store: _MemoryCredentialStore());
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
        customProviderClientFactory: (provider) => FakeAIProviderClient(
          id: provider.id,
          displayName: provider.displayName,
        ),
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
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsState>.value(value: settings),
          ChangeNotifierProvider<CourierService>.value(value: courier),
          ChangeNotifierProvider<WorkspaceService>.value(value: workspace),
        ],
        child: const MaterialApp(home: Scaffold(body: SettingsPage())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('添加自定义供应商'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '供应商名称'),
      '界面测试供应商',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Base API 地址'),
      'https://api.openai.com/v1/widget/',
    );
    await tester.tap(find.byType(Switch));
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(find.text('界面测试供应商'), findsOneWidget);
    expect(find.text('https://api.openai.com/v1/widget/'), findsOneWidget);
    expect(find.text('百万上下文'), findsOneWidget);

    await tester.tap(find.byTooltip('删除 界面测试供应商'));
    await tester.pumpAndSettle();
    expect(find.text('删除自定义供应商'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(find.text('界面测试供应商'), findsNothing);
    expect(settings.customProviders, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('设置页区块切换为同向上下滑动', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final secureStorage = SecureStorageService(store: _MemoryCredentialStore());
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
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsState>.value(value: settings),
          ChangeNotifierProvider<CourierService>.value(value: courier),
          ChangeNotifierProvider<WorkspaceService>.value(value: workspace),
        ],
        child: const MaterialApp(home: Scaffold(body: SettingsPage())),
      ),
    );
    await tester.pumpAndSettle();

    // 向下切换：供应商 → 编辑器（direction = 1）
    await tester.tap(find.text('编辑器').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final dys = tester
        .widgetList<SlideTransition>(find.byType(SlideTransition))
        .where((w) => w.position.value != Offset.zero)
        .map((w) => w.position.value.dy)
        .toList();
    // 同向上移的中间态：新区块在下方（dy>0）滑入、旧区块在上方（dy<0）滑出
    expect(dys.any((dy) => dy > 0), isTrue, reason: '新区块应从下滑入（dy>0）');
    expect(dys.any((dy) => dy < 0), isTrue, reason: '旧区块应向上滑出（dy<0）');
    await tester.pumpAndSettle();

    // 切换完成后无位移残留（不空白）
    final settled = tester
        .widgetList<SlideTransition>(find.byType(SlideTransition))
        .where((w) => w.position.value != Offset.zero)
        .toList();
    expect(settled, isEmpty, reason: '切换完成后应静止原位');
    expect(tester.takeException(), isNull);
  });
}
