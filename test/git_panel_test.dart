import 'dart:io';

import 'package:courier_flutter/services/ai_service.dart';
import 'package:courier_flutter/services/app_logger.dart';
import 'package:courier_flutter/services/courier_service.dart';
import 'package:courier_flutter/services/safe_file_system.dart';
import 'package:courier_flutter/services/secure_storage_service.dart';
import 'package:courier_flutter/services/settings_state.dart';
import 'package:courier_flutter/services/workspace_config_service.dart';
import 'package:courier_flutter/services/workspace_service.dart';
import 'package:courier_flutter/widgets/git_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_fakes.dart';

void main() {
  testWidgets('Git 面板在窄宽度下展示状态和差异无溢出', (tester) async {
    final repository = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('courier-git-panel-'),
    ))!;
    addTearDown(() async {
      if (await repository.exists()) {
        await repository.delete(recursive: true);
      }
    });
    late final SettingsState settings;
    late final CourierService courier;
    late final WorkspaceService workspace;
    late final File tracked;
    var gitAvailable = true;
    await tester.runAsync(() async {
      try {
        await _runGit(repository.path, ['init']);
      } on ProcessException {
        gitAvailable = false;
        return;
      }
      await _runGit(repository.path, [
        'config',
        'user.name',
        'Courier Widget Test',
      ]);
      await _runGit(repository.path, [
        'config',
        'user.email',
        'courier-widget@users.noreply.invalid',
      ]);
      await File(
        p.join(repository.path, '.gitignore'),
      ).writeAsString('.Courier/\n');
      tracked = File(p.join(repository.path, 'tracked.txt'));
      await tracked.writeAsString('initial\n');
      await _runGit(repository.path, [
        'add',
        '--',
        '.gitignore',
        'tracked.txt',
      ]);
      await _runGit(repository.path, [
        'commit',
        '-m',
        'chore: initialize widget repository',
      ]);

      SharedPreferences.setMockInitialValues({});
      final secureStorage = SecureStorageService(
        store: MemoryCredentialStore(),
      );
      settings = SettingsState(
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
      courier = CourierService(
        settings: settings,
        secureStorage: secureStorage,
        logger: logger,
        aiService: ai,
      );
      workspace = WorkspaceService(
        fileSystem: SafeFileSystem(),
        configService: WorkspaceConfigService(logger: logger),
        logger: logger,
        onWorkspaceOpened: courier.bindWorkspace,
      );
      await workspace.openWorkspace(repository.path, persist: false);
      await tracked.writeAsString('changed\n');
      await courier.refreshAll();
      await courier.gitDiff(
        workspacePath: workspace.workspacePath,
        path: 'tracked.txt',
      );
    });
    if (!gitAvailable) return;
    addTearDown(() {
      workspace.dispose();
      courier.dispose();
      settings.dispose();
    });

    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsState>.value(value: settings),
          ChangeNotifierProvider<CourierService>.value(value: courier),
          ChangeNotifierProvider<WorkspaceService>.value(value: workspace),
        ],
        child: const MaterialApp(home: Scaffold(body: GitPanel())),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('tracked.txt'), findsOneWidget);
    expect(find.textContaining('+changed'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(courier.shutdown);
  }, timeout: const Timeout(Duration(seconds: 30)));
}

Future<void> _runGit(String workingDirectory, List<String> arguments) async {
  final result = await Process.run(
    'git',
    arguments,
    workingDirectory: workingDirectory,
    runInShell: false,
  );
  if (result.exitCode != 0) {
    fail('Git command failed: ${result.stderr}');
  }
}
