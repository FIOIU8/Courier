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
    expect(service.log, isNotNull);
    expect(service.log!.entries.first.subject, 'test: persist tracked change');
    expect(service.log!.entries.first.isHead, isTrue);
  });

  test('提交记录解析多条记录、特殊字符和 HEAD', () async {
    if (!gitAvailable) return;
    const subject = 'feat: parse | brackets [ok] and tabs\tcleanly';
    await File(
      p.join(repository.path, 'tracked.txt'),
    ).writeAsString('second\n');
    await _runGit(repository.path, ['add', '--', 'tracked.txt']);
    await _runGit(repository.path, ['commit', '-m', subject]);

    final service = GitService(logger: AppLogger());
    addTearDown(service.dispose);
    await service.bindWorkspace(repository.path);
    final log = await service.refreshLog(limit: 10);

    expect(log.workspacePath, p.normalize(repository.path));
    expect(log.truncated, isFalse);
    expect(log.entries, hasLength(2));
    expect(log.entries.first.subject, subject);
    expect(log.entries.first.isHead, isTrue);
    expect(log.entries.last.isHead, isFalse);
    expect(log.entries.first.authorName, 'Courier Test Suite');
    expect(
      log.entries.first.authorEmail,
      'courier-tests@users.noreply.invalid',
    );
    expect(DateTime.tryParse(log.entries.first.authorDate), isNotNull);
    expect(log.entries.first.fullHash, matches(RegExp(r'^[0-9a-f]{40,64}$')));
    expect(log.entries.first.shortHash, matches(RegExp(r'^[0-9a-f]+$')));

    final detail = await service.loadCommitDetail(log.entries.first.fullHash);
    expect(detail, contains('feat: parse | brackets [ok] and tabs'));
    expect(detail, contains('cleanly'));
    expect(detail, contains('tracked.txt'));
    await expectLater(
      service.loadCommitDetail('../invalid'),
      throwsCourierCode('INVALID_COMMIT_HASH'),
    );
  });

  test('空仓库返回空提交记录', () async {
    if (!gitAvailable) return;
    final emptyRepository = await Directory.systemTemp.createTemp(
      'courier-empty-git-',
    );
    addTearDown(() async {
      if (await emptyRepository.exists()) {
        await emptyRepository.delete(recursive: true);
      }
    });
    await _runGit(emptyRepository.path, ['init']);

    final service = GitService(logger: AppLogger());
    addTearDown(service.dispose);
    await service.bindWorkspace(emptyRepository.path);
    final log = await service.refreshLog();

    expect(service.repositoryAvailable, isTrue);
    expect(log.entries, isEmpty);
    expect(log.truncated, isFalse);
  });

  test('提交记录输出超限时设置截断标记', () async {
    if (!gitAvailable) return;
    final service = GitService.withOutputLimit(
      logger: AppLogger(),
      outputLimit: 96,
    );
    addTearDown(service.dispose);
    await service.bindWorkspace(repository.path);

    final log = await service.refreshLog();

    expect(log.truncated, isTrue);
    expect(log.entries, isEmpty);
  });

  test('拒绝无效的提交记录数量', () async {
    if (!gitAvailable) return;
    final service = GitService(logger: AppLogger());
    addTearDown(service.dispose);
    await service.bindWorkspace(repository.path);

    await expectLater(
      service.refreshLog(limit: 0),
      throwsCourierCode('INVALID_GIT_LOG_LIMIT'),
    );
    await expectLater(
      service.refreshLog(limit: 501),
      throwsCourierCode('INVALID_GIT_LOG_LIMIT'),
    );
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
