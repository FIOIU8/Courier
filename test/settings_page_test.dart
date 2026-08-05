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
    SharedPreferences.setMockInitialValues({});
    final secureStorage = SecureStorageService(store: _MemoryCredentialStore());
    final settings = SettingsState(secureStorage: secureStorage);
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

    expect(tester.takeException(), isNull, reason: '设置页初始渲染异常/溢出');

    for (final label in ['AI', '编辑器', '任务', '通用', '关于']) {
      await tester.tap(find.text(label).first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '「$label」分区渲染异常/溢出');
    }
  });
}
