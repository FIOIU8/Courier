import 'dart:io';

import 'package:courier_flutter/services/ai_service.dart';
import 'package:courier_flutter/services/app_logger.dart';
import 'package:courier_flutter/services/courier_service.dart';
import 'package:courier_flutter/services/secure_storage_service.dart';
import 'package:courier_flutter/services/settings_state.dart';
import 'package:courier_flutter/services/task_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_fakes.dart';

void main() {
  test('工作区子服务绑定失败时恢复原工作区', () async {
    SharedPreferences.setMockInitialValues({});
    final firstWorkspace = await Directory.systemTemp.createTemp(
      'courier-service-first-',
    );
    final secondWorkspace = await Directory.systemTemp.createTemp(
      'courier-service-second-',
    );
    addTearDown(() async {
      if (await firstWorkspace.exists()) {
        await firstWorkspace.delete(recursive: true);
      }
      if (await secondWorkspace.exists()) {
        await secondWorkspace.delete(recursive: true);
      }
    });

    final credentialStore = MemoryCredentialStore();
    final secureStorage = SecureStorageService(store: credentialStore);
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
    final taskService = TaskService(
      executor: ControllableTaskExecutor(),
      logger: logger,
    );
    final service = CourierService(
      settings: settings,
      secureStorage: secureStorage,
      logger: logger,
      aiService: ai,
      taskService: taskService,
    );
    addTearDown(() async {
      await service.shutdown();
      service.dispose();
      settings.dispose();
    });

    await service.bindWorkspace(firstWorkspace.path);
    final resolvedFirst = await firstWorkspace.resolveSymbolicLinks();
    final corruptTaskDirectory = Directory(
      p.join(secondWorkspace.path, '.Courier', 'tasks'),
    );
    await corruptTaskDirectory.create(recursive: true);
    await File(
      p.join(corruptTaskDirectory.path, 'task-index.json'),
    ).writeAsString('{invalid', flush: true);

    await expectLater(
      service.bindWorkspace(secondWorkspace.path),
      throwsCourierCode('INVALID_TASK_INDEX'),
    );

    expect(service.workspacePath, resolvedFirst);
    expect(service.taskQueue.workspacePath, resolvedFirst);
    expect(service.git.workspacePath, resolvedFirst);
    expect(logger.currentLogFile!.path, startsWith(resolvedFirst));
  });
}
