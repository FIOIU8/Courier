// ai_assistant_panel_test.dart - AI 助手面板消息渲染测试。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:courier_flutter/services/ai_service.dart';
import 'package:courier_flutter/services/app_logger.dart';
import 'package:courier_flutter/services/courier_service.dart';
import 'package:courier_flutter/services/secure_storage_service.dart';
import 'package:courier_flutter/services/settings_state.dart';
import 'package:courier_flutter/widgets/ai_assistant_panel.dart';

import 'support/test_fakes.dart';

void main() {
  late MemoryCredentialStore credentialStore;
  late SecureStorageService secureStorage;
  late SettingsState settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    credentialStore = MemoryCredentialStore();
    secureStorage = SecureStorageService(store: credentialStore);
    settings = SettingsState(
      secureStorage: secureStorage,
      environment: const {},
    );
    await settings.load();
    await settings.saveApiKey(generatedCredential());
    await settings.setAiModelId('model-under-test');
  });

  tearDown(() {
    settings.dispose();
  });

  Future<Directory> createWorkspace(WidgetTester tester) async {
    // testWidgets 的 FakeAsync 环境中真实文件 IO 会挂起，必须经 runAsync 执行
    late Directory workspace;
    await tester.runAsync(() async {
      workspace = await Directory.systemTemp.createTemp('courier-ai-panel-');
    });
    return workspace;
  }

  testWidgets('AI 回复含 Markdown 标记时以单个纯文本控件渲染', (tester) async {
    final workspace = await createWorkspace(tester);
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
          'openai': FakeAIProviderClient(
            chunks: const ['- 第一项\n- 第二项\n\n> 引用块'],
          ),
        },
      ),
    );
    addTearDown(courier.dispose);
    addTearDown(() => tester.runAsync(() => workspace.delete(recursive: true)));

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsState>.value(value: settings),
          ChangeNotifierProvider<CourierService>.value(value: courier),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: AIAssistantPanel(workspacePath: workspace.path),
          ),
        ),
      ),
    );
    // 会话初始化涉及真实目录检查（FakeAsync 中会挂起），
    // 用 runAsync 推进真实事件循环后再继续渲染
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '列出要点');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    // 整段回复是一个 SelectableText，文本保持 Markdown 原样（未被解析成多个块）
    final selectables = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .toList();
    expect(selectables, isNotEmpty);
    expect(
      selectables.map((widget) => widget.data),
      contains('- 第一项\n- 第二项\n\n> 引用块'),
    );
    expect(tester.takeException(), isNull);
  });
}
