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
import 'package:flutter/services.dart';
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

    await tester.tap(find.text('历史'));
    await tester.pump();
    expect(find.byKey(const Key('git-history-view')), findsOneWidget);
    expect(find.text('chore: initialize widget repository'), findsOneWidget);
    expect(find.text('HEAD'), findsOneWidget);
    // 提交详情默认隐藏
    expect(find.text('未选择提交'), findsNothing);

    final commitRow = tester.widget<InkWell>(
      find
          .ancestor(
            of: find.text('chore: initialize widget repository'),
            matching: find.byType(InkWell),
          )
          .first,
    );
    // 左键点击提交：选中并展开提交详情
    await tester.runAsync(() async {
      commitRow.onTap!();
      await waitForCondition(() => !courier.git.loading);
    });
    await tester.pump();
    final detailFinder = find.byKey(const Key('git-commit-detail'));
    expect(detailFinder, findsOneWidget);
    final detail = tester.widget<SingleChildScrollView>(detailFinder);
    final selectable = detail.child! as SelectableText;
    expect(selectable.data, contains('chore: initialize widget repository'));
    expect(selectable.data, contains('tracked.txt'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(courier.shutdown);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('Git 历史视图为空仓库显示空状态', (tester) async {
    final repository = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('courier-empty-git-panel-'),
    ))!;
    addTearDown(() async {
      if (await repository.exists()) {
        await repository.delete(recursive: true);
      }
    });
    late final SettingsState settings;
    late final CourierService courier;
    late final WorkspaceService workspace;
    var gitAvailable = true;
    await tester.runAsync(() async {
      try {
        await _runGit(repository.path, ['init']);
      } on ProcessException {
        gitAvailable = false;
        return;
      }
      final excludeFile = File(
        p.join(repository.path, '.git', 'info', 'exclude'),
      );
      await excludeFile.writeAsString(
        '${await excludeFile.readAsString()}.Courier/\n',
      );

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
      await courier.refreshAll();
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
    await tester.tap(find.text('历史'));
    await tester.pump();

    expect(find.text('仓库暂无提交记录'), findsOneWidget);
    // 提交详情默认隐藏
    expect(find.text('未选择提交'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(courier.shutdown);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('一键暂存与取消暂存按钮', (tester) async {
    final harness = await _createGitPanelHarness(tester);
    if (harness == null) return;
    _addHarnessTeardown(tester, harness);
    await harness.pump(tester);

    // 无已暂存变更时提交按钮禁用
    final commitButton = tester.widget<IconButton>(
      find.ancestor(
        of: find.byTooltip('提交已暂存变更'),
        matching: find.byType(IconButton),
      ),
    );
    expect(commitButton.onPressed, isNull);

    // 一键全部暂存
    await _invokeToolbarAction(
      tester,
      harness,
      '全部暂存',
      () =>
          harness.courier.currentGitStatus?.files.every(
            (file) => file.staged,
          ) ??
          false,
    );
    expect(
      harness.courier.currentGitStatus!.files.every((file) => file.staged),
      isTrue,
    );

    // 一键全部取消暂存
    await _invokeToolbarAction(
      tester,
      harness,
      '全部取消暂存',
      () => !(harness.courier.currentGitStatus?.files.any(
        (file) => file.staged,
      ) ?? true),
    );
    expect(
      harness.courier.currentGitStatus!.files.any((file) => file.staged),
      isFalse,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(harness.courier.shutdown);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('文件状态筛选过滤变更列表', (tester) async {
    final harness = await _createGitPanelHarness(
      tester,
      addUntrackedFile: true,
    );
    if (harness == null) return;
    _addHarnessTeardown(tester, harness);
    await harness.pump(tester);

    expect(find.text('tracked.txt'), findsOneWidget);
    expect(find.text('untracked.txt'), findsOneWidget);

    // 未跟踪筛选：仅显示未跟踪文件
    await tester.tap(find.widgetWithText(ChoiceChip, '未跟踪'));
    await tester.pump();
    expect(find.text('untracked.txt'), findsOneWidget);
    expect(find.text('tracked.txt'), findsNothing);

    // 已暂存筛选：无已暂存变更
    await tester.tap(find.widgetWithText(ChoiceChip, '已暂存'));
    await tester.pump();
    expect(find.text('无符合条件的变更'), findsOneWidget);

    // 全部：恢复显示全部文件
    await tester.tap(find.widgetWithText(ChoiceChip, '全部'));
    await tester.pump();
    expect(find.text('tracked.txt'), findsOneWidget);
    expect(find.text('untracked.txt'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(harness.courier.shutdown);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('多行提交输入与 Ctrl+Enter 提交', (tester) async {
    final harness = await _createGitPanelHarness(tester);
    if (harness == null) return;
    _addHarnessTeardown(tester, harness);
    await harness.pump(tester);

    // 先全部暂存
    await _invokeToolbarAction(
      tester,
      harness,
      '全部暂存',
      () =>
          harness.courier.currentGitStatus?.files.every(
            (file) => file.staged,
          ) ??
          false,
    );

    // 输入提交信息（多行输入框）
    await tester.enterText(
      find.byType(TextField).first,
      'test: commit via ctrl+enter',
    );
    await tester.pump();

    // 在 runAsync 内派发 Ctrl+Enter，使 _commit 的整个异步链处于真实异步区，
    // 随后确认提交时真实 git 进程才能完成。
    await tester.runAsync(() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    });
    await tester.pump();
    expect(find.text('确认提交'), findsOneWidget);

    // 确认提交（在 runAsync 内触发，允许真实 git 进程完成）
    await tester.runAsync(() async {
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '提交'))
          .onPressed!();
      await waitForCondition(() => harness.courier.git.loading);
      await waitForCondition(
        () =>
            harness.courier.currentGitLog?.entries.first.subject ==
            'test: commit via ctrl+enter',
      );
      // 等待提交后的 _refresh 完全空闲，避免 git 进程仍占用工作区导致
      // 临时目录删除失败（Windows 文件锁）。
      await waitForCondition(() => !harness.courier.git.loading);
    });
    await tester.pump();

    expect(
      harness.courier.currentGitLog!.entries.first.subject,
      'test: commit via ctrl+enter',
    );
    expect(find.text('提交成功'), findsOneWidget);

    // 清理 SnackBar 自动关闭计时器
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(harness.courier.shutdown);
  }, timeout: const Timeout(Duration(seconds: 30)));
}

class _GitPanelHarness {
  final Directory repository;
  final SettingsState settings;
  final CourierService courier;
  final WorkspaceService workspace;

  _GitPanelHarness({
    required this.repository,
    required this.settings,
    required this.courier,
    required this.workspace,
  });

  Future<void> pump(WidgetTester tester) async {
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
  }
}

/// 在 [tester.runAsync] 内触发工具栏图标按钮的 onPressed，并轮询等待
/// [done] 变为 true。
/// 依次等待"操作开始 → 结果达成 → 完全空闲"，避免在 _refresh 尚未结束时
/// 提前返回，导致后续按钮仍处于禁用态。
Future<void> _invokeToolbarAction(
  WidgetTester tester,
  _GitPanelHarness harness,
  String tooltip,
  bool Function() done,
) async {
  await tester.runAsync(() async {
    tester
        .widget<IconButton>(
          find.ancestor(
            of: find.byTooltip(tooltip),
            matching: find.byType(IconButton),
          ),
        )
        .onPressed!();
    await waitForCondition(() => harness.courier.git.loading);
    await waitForCondition(done);
    await waitForCondition(() => !harness.courier.git.loading);
  });
  await tester.pump();
}

/// 构建一个含 `tracked.txt`（初始提交后被修改）的 Git 仓库并绑定工作区；
/// [addUntrackedFile] 为 true 时额外创建一个未跟踪文件。
/// Git 不可用时返回 null，测试应直接跳过。
/// 整个初始化在 [tester.runAsync] 中执行，保证真实 git 进程可以完成。
Future<_GitPanelHarness?> _createGitPanelHarness(
  WidgetTester tester, {
  bool addUntrackedFile = false,
}) {
  return tester.runAsync<_GitPanelHarness?>(() async {
    final repository = await Directory.systemTemp.createTemp(
      'courier-git-panel-',
    );
    try {
      await _runGit(repository.path, ['init']);
    } on ProcessException {
      await repository.delete(recursive: true);
      return null;
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
    final tracked = File(p.join(repository.path, 'tracked.txt'));
    await tracked.writeAsString('initial\n');
    await _runGit(repository.path, ['add', '--', '.gitignore', 'tracked.txt']);
    await _runGit(repository.path, [
      'commit',
      '-m',
      'chore: initialize widget repository',
    ]);

    SharedPreferences.setMockInitialValues({});
    final secureStorage = SecureStorageService(
      store: MemoryCredentialStore(),
    );
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
      onWorkspaceOpened: courier.bindWorkspace,
    );
    await workspace.openWorkspace(repository.path, persist: false);
    await tracked.writeAsString('changed\n');
    if (addUntrackedFile) {
      await File(
        p.join(repository.path, 'untracked.txt'),
      ).writeAsString('new\n');
    }
    await courier.refreshAll();
    return _GitPanelHarness(
      repository: repository,
      settings: settings,
      courier: courier,
      workspace: workspace,
    );
  });
}

void _addHarnessTeardown(WidgetTester tester, _GitPanelHarness harness) {
  addTearDown(() async {
    if (await harness.repository.exists()) {
      await harness.repository.delete(recursive: true);
    }
  });
  addTearDown(() {
    harness.workspace.dispose();
    harness.courier.dispose();
    harness.settings.dispose();
  });
  tester.view.physicalSize = const Size(360, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
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
