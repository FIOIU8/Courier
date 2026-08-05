import 'dart:io';

import 'package:courier_flutter/services/app_logger.dart';
import 'package:courier_flutter/services/git_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/test_fakes.dart';

void main() {
  late Directory repository;
  late bool gitAvailable;

  setUp(() async {
    repository = await Directory.systemTemp.createTemp('courier-git-');
    final version = await Process.run('git', ['--version'], runInShell: false);
    gitAvailable = version.exitCode == 0;
    if (!gitAvailable) return;

    await _runGit(repository.path, ['init']);
    await _runGit(repository.path, [
      'config',
      'user.name',
      'Courier Test Suite',
    ]);
    await _runGit(repository.path, [
      'config',
      'user.email',
      'courier-tests@users.noreply.invalid',
    ]);
    await File(
      p.join(repository.path, 'tracked.txt'),
    ).writeAsString('initial\n');
    await _runGit(repository.path, ['add', '--', 'tracked.txt']);
    await _runGit(repository.path, [
      'commit',
      '-m',
      'chore: initialize test repository',
    ]);
    await _runGit(repository.path, ['branch', 'feature-test']);
  });

  tearDown(() async {
    if (await repository.exists()) await repository.delete(recursive: true);
  });

  test('状态、差异、暂存和提交形成完整闭环', () async {
    if (!gitAvailable) return;
    final service = GitService(logger: AppLogger());
    addTearDown(service.dispose);
    await service.bindWorkspace(repository.path);
    expect(service.repositoryAvailable, isTrue);

    await File(
      p.join(repository.path, 'tracked.txt'),
    ).writeAsString('changed\n');
    final status = await service.refreshStatus();
    expect(status.clean, isFalse);
    expect(status.files.single.path, 'tracked.txt');

    final diff = await service.loadDiff(path: 'tracked.txt');
    expect(diff.diff, contains('+changed'));
    expect(diff.truncated, isFalse);

    await service.stage('tracked.txt');
    expect(service.status!.files.single.staged, isTrue);
    final commit = await service.commit('test: persist tracked change');
    expect(commit.message, 'test: persist tracked change');
    expect(service.status!.clean, isTrue);
  });

  test('分支切换要求干净工作树', () async {
    if (!gitAvailable) return;
    final service = GitService(logger: AppLogger());
    addTearDown(service.dispose);
    await service.bindWorkspace(repository.path);

    await File(p.join(repository.path, 'tracked.txt')).writeAsString('dirty\n');
    await expectLater(
      service.switchBranch('feature-test'),
      throwsCourierCode('WORKTREE_NOT_CLEAN'),
    );
    await _runGit(repository.path, ['restore', '--', 'tracked.txt']);
    await service.switchBranch('feature-test');
    expect(service.status?.currentBranch, 'feature-test');
  });

  test('拒绝越界路径和非仓库根目录', () async {
    if (!gitAvailable) return;
    final service = GitService(logger: AppLogger());
    addTearDown(service.dispose);
    await service.bindWorkspace(repository.path);
    await expectLater(
      service.stage(p.join('..', 'outside.txt')),
      throwsCourierCode('INVALID_GIT_PATH'),
    );

    final nested = Directory(p.join(repository.path, 'nested'));
    await nested.create();
    await service.bindWorkspace(nested.path);
    expect(service.repositoryAvailable, isFalse);
    expect(service.lastError, '当前工作区必须是 Git 仓库根目录');
  });
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
