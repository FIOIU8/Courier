// settings_page_test.dart - 设置页渲染测试。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:courier_flutter/services/app_error.dart';
import 'package:courier_flutter/services/app_logger.dart';
import 'package:courier_flutter/services/ai_service.dart';
import 'package:courier_flutter/services/courier_service.dart';
import 'package:courier_flutter/services/models.dart';
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

  testWidgets('供应商弹窗内配置请求方式/API Key/提示词并显示正规提示', (tester) async {
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
        providers: {
          'openai': FakeAIProviderClient(),
          'anthropic': FakeAIProviderClient(
            id: 'anthropic',
            displayName: 'Anthropic',
          ),
        },
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

    // 设置主界面不再直接显示请求方式与 API Key
    expect(find.text('请求方式'), findsNothing);
    expect(find.textContaining('Responses API'), findsNothing);

    // 打开当前供应商（内置 openai）的编辑弹窗
    await tester.tap(find.byTooltip('编辑供应商'));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(find.text('编辑供应商设置'), findsOneWidget);
    expect(
      find.descendant(of: dialog, matching: find.text('OpenAI')),
      findsOneWidget,
    );
    expect(find.text('https://api.openai.com/v1/'), findsOneWidget);
    expect(find.text('Chat Completions'), findsOneWidget);
    expect(
      find.textContaining('第三方中转网关兼容 OpenAI Responses API'),
      findsOneWidget,
    );
    expect(find.text('系统提示词（可选）'), findsOneWidget);
    expect(find.text('更新 API Key（可选）'), findsOneWidget);

    // 切换请求方式并填写提示词后保存
    await tester.tap(find.text('Chat Completions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Responses API'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '系统提示词（可选）'),
      '你是代码助手',
    );
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(settings.aiRequestMode, AIRequestMode.responses);
    expect(settings.aiSystemPrompt, '你是代码助手');

    // 切换到 anthropic 供应商：弹窗只提供 Anthropic API，无中转站提示
    await tester.tap(find.byKey(const ValueKey('openai')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Anthropic').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('编辑供应商'));
    await tester.pumpAndSettle();
    expect(find.text('Anthropic API'), findsOneWidget);
    expect(find.text('Responses API'), findsNothing);
    expect(
      find.textContaining('第三方中转网关兼容 OpenAI Responses API'),
      findsNothing,
    );
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

  testWidgets('未保存Key时点击读取模型列表显示提示且不发请求', (tester) async {
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

    await tester.tap(find.byKey(const ValueKey('add-model-button')));
    await tester.pumpAndSettle();
    expect(find.text('请先保存 API Key 再读取模型列表'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('MODELS_NOT_SUPPORTED时显示手动添加提示', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final secureStorage = SecureStorageService(store: _MemoryCredentialStore());
    final settings = SettingsState(
      secureStorage: secureStorage,
      environment: const {},
    );
    await settings.load();
    await settings.saveApiKey('test-key');
    final logger = AppLogger();
    final courier = CourierService(
      settings: settings,
      secureStorage: secureStorage,
      logger: logger,
      aiService: AIService(
        settings: settings,
        secureStorage: secureStorage,
        logger: logger,
        providers: {
          'openai': _ThrowingListModelsProvider(),
        },
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

    await tester.tap(find.byKey(const ValueKey('add-model-button')));
    await tester.pumpAndSettle();
    expect(
      find.text('该供应商不支持自动获取，请使用手动输入添加模型'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('读取模型列表失败时界面直接展示API返回的错误', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final secureStorage = SecureStorageService(store: _MemoryCredentialStore());
    final settings = SettingsState(
      secureStorage: secureStorage,
      environment: const {},
    );
    await settings.load();
    await settings.saveApiKey('test-key');
    final logger = AppLogger();
    final courier = CourierService(
      settings: settings,
      secureStorage: secureStorage,
      logger: logger,
      aiService: AIService(
        settings: settings,
        secureStorage: secureStorage,
        logger: logger,
        providers: {
          'openai': _ThrowingListModelsProvider(
            error: const CourierException(
              'PROVIDER_HTTP_401',
              'Authentication Fails, Your api key is invalid',
            ),
          ),
        },
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

    await tester.tap(find.byKey(const ValueKey('add-model-button')));
    await tester.pumpAndSettle();
    expect(
      find.text('Authentication Fails, Your api key is invalid'),
      findsOneWidget,
    );
    expect(find.textContaining('CourierException'), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('错误提示可复制完整内容到剪贴板', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final secureStorage = SecureStorageService(store: _MemoryCredentialStore());
    final settings = SettingsState(
      secureStorage: secureStorage,
      environment: const {},
    );
    await settings.load();
    await settings.saveApiKey('test-key');
    final logger = AppLogger();
    final courier = CourierService(
      settings: settings,
      secureStorage: secureStorage,
      logger: logger,
      aiService: AIService(
        settings: settings,
        secureStorage: secureStorage,
        logger: logger,
        providers: {
          'openai': _ThrowingListModelsProvider(
            error: const CourierException(
              'PROVIDER_HTTP_401',
              'Authentication Fails, Your api key is invalid',
            ),
          ),
        },
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

    final clipboardCalls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        clipboardCalls.add(call);
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
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

    // 手动输入含控制字符的模型标识触发校验错误，错误条出现在设置页并可复制
    await tester.tap(find.byKey(const ValueKey('add-model-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('手动输入'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, '模型标识'),
      'bad\u0000model',
    );
    await tester.tap(find.widgetWithText(FilledButton, '添加'));
    await tester.pumpAndSettle();

    expect(find.textContaining('供应商模型标识无效'), findsOneWidget);
    await tester.tap(find.byTooltip('复制错误信息'));
    await tester.pump();

    final copyCall = clipboardCalls
        .where((call) => call.method == 'Clipboard.setData')
        .single;
    final arguments = copyCall.arguments as Map<Object?, Object?>;
    expect(
      arguments['text'],
      'CourierException(INVALID_SETTING): 供应商模型标识无效',
    );
    expect(find.byIcon(Icons.check), findsOneWidget, reason: '复制后应显示对勾反馈');
    // 推进时间让复制反馈的 2 秒计时器完成
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });
  testWidgets('模型区冒烟：默认模型下拉、删除回退与手动添加', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final secureStorage = SecureStorageService(store: _MemoryCredentialStore());
    final settings = SettingsState(
      secureStorage: secureStorage,
      environment: const {},
    );
    await settings.load();
    await settings.addAiModel('gpt-4o');
    await settings.addAiModel('claude-sonnet-4-5');
    await settings.setAiModelId('gpt-4o');
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

    // 默认模型下拉与"我的模型"列表
    expect(find.text('默认模型'), findsOneWidget);
    expect(find.text('gpt-4o'), findsWidgets);
    expect(find.text('默认'), findsOneWidget, reason: '当前默认模型应带默认标记');
    expect(find.text('共 2 个模型'), findsOneWidget);

    // 删除默认模型：确认后回退到列表第一个
    await tester.tap(find.byTooltip('删除模型').first);
    await tester.pumpAndSettle();
    expect(find.text('删除默认模型'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(settings.aiModelId, 'claude-sonnet-4-5', reason: '删除默认模型后应回退');
    expect(settings.aiModelIds, ['claude-sonnet-4-5']);
    expect(find.text('默认'), findsOneWidget, reason: '回退后的模型应带默认标记');

    // 手动输入添加模型
    await tester.tap(find.byKey(const ValueKey('add-model-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('手动输入'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, '模型标识'),
      'manual-model',
    );
    await tester.tap(find.widgetWithText(FilledButton, '添加'));
    await tester.pumpAndSettle();
    expect(settings.aiModelIds, ['claude-sonnet-4-5', 'manual-model']);
    expect(find.text('manual-model'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}

class _ThrowingListModelsProvider extends FakeAIProviderClient {
  final CourierException error;

  _ThrowingListModelsProvider({
    this.error = const CourierException(
      'MODELS_NOT_SUPPORTED',
      '该供应商不支持自动获取模型列表，请手动输入模型标识',
    ),
  });

  @override
  Future<List<AIModelOption>> listModels(String apiKey) async {
    throw error;
  }
}
