// git_service.dart - Workspace-root constrained Git CLI integration.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'app_error.dart';
import 'app_logger.dart';
import 'models.dart';
import 'workspace_directory_guard.dart';

class GitService extends ChangeNotifier {
  static const Duration _commandTimeout = Duration(seconds: 30);
  static const int _defaultOutputLimit = 1024 * 1024;

  final AppLogger logger;
  final int _outputLimit;

  String? _workspacePath;
  bool _gitAvailable = false;
  bool _repositoryAvailable = false;
  bool _loading = false;
  int _operationDepth = 0;
  Completer<void>? _idleCompleter;
  Future<void> _mutationTail = Future<void>.value();
  String? _lastError;
  GitStatusResult? _status;
  GitBranchListResult? _branches;
  GitDiffResult? _diff;
  GitLogResult? _log;

  GitService({required this.logger}) : _outputLimit = _defaultOutputLimit;

  @visibleForTesting
  GitService.withOutputLimit({required this.logger, required int outputLimit})
    : _outputLimit = outputLimit {
    if (outputLimit <= 0) {
      throw ArgumentError.value(outputLimit, 'outputLimit', '必须大于 0');
    }
  }

  String? get workspacePath => _workspacePath;
  bool get gitAvailable => _gitAvailable;
  bool get repositoryAvailable => _repositoryAvailable;
  bool get loading => _loading;
  String? get lastError => _lastError;
  GitStatusResult? get status => _status;
  GitBranchListResult? get branches => _branches;
  GitDiffResult? get diff => _diff;
  GitLogResult? get log => _log;

  Future<void> bindWorkspace(String workspacePath) async {
    await _mutationTail;
    await _waitForIdle();
    final directory = Directory(workspacePath);
    if (!await directory.exists()) {
      throw const CourierException('WORKSPACE_NOT_FOUND', '工作区目录不存在');
    }
    final type = await FileSystemEntity.type(workspacePath, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw const CourierException(
        'WORKSPACE_LINK_NOT_ALLOWED',
        'Git 工作区根目录不能是符号链接',
      );
    }
    _workspacePath = p.normalize(await directory.resolveSymbolicLinks());
    _status = null;
    _branches = null;
    _diff = null;
    _log = null;
    _lastError = null;
    _loading = false;

    _gitAvailable = await _checkGitAvailable();
    if (!_gitAvailable) {
      _repositoryAvailable = false;
      notifyListeners();
      return;
    }

    try {
      final result = await _runGit(['rev-parse', '--show-toplevel']);
      final topLevel = p.normalize(result.stdout.trim());
      _repositoryAvailable = _samePath(topLevel, _workspacePath!);
      if (!_repositoryAvailable) {
        _lastError = '当前工作区必须是 Git 仓库根目录';
      }
    } on CourierException {
      _repositoryAvailable = false;
      _lastError = '当前工作区不是 Git 仓库';
    }
    notifyListeners();
  }

  Future<GitStatusResult> refreshStatus() async {
    return _runOperation('status', () async {
      _requireRepository();
      final results = await Future.wait([
        _runGit(['status', '--porcelain=v1', '-z', '--untracked-files=all']),
        _runGit(['branch', '--show-current']),
      ]);
      final files = _parseStatus(results[0].stdout);
      _status = GitStatusResult(
        workspacePath: _workspacePath!,
        files: files,
        clean: files.isEmpty,
        currentBranch: results[1].stdout.trim(),
      );
      return _status!;
    });
  }

  Future<GitBranchListResult> refreshBranches() async {
    return _runOperation('branches', () async {
      _requireRepository();
      final results = await Future.wait([
        _runGit(['for-each-ref', '--format=%(refname:short)', 'refs/heads']),
        _runGit(['branch', '--show-current']),
      ]);
      final branches =
          const LineSplitter()
              .convert(results[0].stdout)
              .map((branch) => branch.trim())
              .where((branch) => branch.isNotEmpty)
              .toList(growable: false)
            ..sort();
      _branches = GitBranchListResult(
        branches: branches,
        current: results[1].stdout.trim(),
      );
      return _branches!;
    });
  }

  Future<GitLogResult> refreshLog({int limit = 50}) async {
    return _runOperation('log', () async {
      _requireRepository();
      if (limit < 1 || limit > 500) {
        throw const CourierException(
          'INVALID_GIT_LOG_LIMIT',
          '提交记录数量必须在 1 到 500 之间',
        );
      }

      final head = await _runGit(
        ['rev-parse', '--verify', '--quiet', 'HEAD'],
        allowedExitCodes: const {0, 1},
      );
      if (head.exitCode != 0) {
        _log = GitLogResult(
          workspacePath: _workspacePath!,
          entries: const [],
          truncated: false,
        );
        return _log!;
      }

      final result = await _runGit([
        'log',
        '--no-color',
        '-n',
        '$limit',
        '--format=%H%x00%h%x00%an%x00%ae%x00%aI%x00%s%x00',
      ], outputLimit: _outputLimit);
      _log = GitLogResult(
        workspacePath: _workspacePath!,
        entries: _parseLog(result.stdout, head.stdout.trim()),
        truncated: result.stdoutTruncated,
      );
      return _log!;
    });
  }

  Future<String> loadCommitDetail(String hash) async {
    return _runOperation('commit_detail', () async {
      _requireRepository();
      final normalized = hash.trim();
      if (!RegExp(r'^[0-9a-fA-F]{7,64}$').hasMatch(normalized)) {
        throw const CourierException('INVALID_COMMIT_HASH', '提交哈希无效');
      }
      final result = await _runGit([
        'show',
        '--stat',
        '--no-color',
        '--no-ext-diff',
        '--format=fuller',
        normalized,
        '--',
      ], outputLimit: _outputLimit);
      final detail = result.stdout.trimRight();
      if (!result.stdoutTruncated) return detail;
      return detail.isEmpty ? '[输出已截断]' : '$detail\n\n[输出已截断]';
    });
  }

  Future<void> stage(String path) async {
    await _runMutation(() {
      return _runOperation('stage', () async {
        final relative = _validateRelativePath(path);
        await _runGit(['add', '--', relative]);
        await refreshStatus();
      });
    });
  }

  Future<void> unstage(String path) async {
    await _runMutation(() {
      return _runOperation('unstage', () async {
        final relative = _validateRelativePath(path);
        final result = await _runGit(
          ['restore', '--staged', '--', relative],
          allowedExitCodes: const {0, 128},
        );
        if (result.exitCode != 0) {
          await _runGit(['reset', '--', relative]);
        }
        await refreshStatus();
      });
    });
  }

  /// 一键暂存全部可暂存变更（无变更时为空操作，不执行 git 命令）。
  Future<void> stageAll() async {
    await _runMutation(() {
      return _runOperation('stage_all', () async {
        _requireRepository();
        final status = await refreshStatus();
        final hasStageable = status.files.any(
          (file) => file.untracked || file.workTreeStatus.trim().isNotEmpty,
        );
        if (!hasStageable) return;
        await _runGit(['add', '-A']);
        await refreshStatus();
      });
    });
  }

  /// 一键取消暂存全部已暂存变更（无已暂存变更时为空操作）。
  Future<void> unstageAll() async {
    await _runMutation(() {
      return _runOperation('unstage_all', () async {
        _requireRepository();
        final status = await refreshStatus();
        if (!status.files.any((file) => file.staged)) return;
        final result = await _runGit(
          ['restore', '--staged', '.'],
          allowedExitCodes: const {0, 128},
        );
        if (result.exitCode != 0) {
          await _runGit(['reset', '--quiet']);
        }
        await refreshStatus();
      });
    });
  }

  Future<GitDiffResult> loadDiff({String? path, bool staged = false}) async {
    return _runOperation('diff', () async {
      _requireRepository();
      final arguments = <String>['diff', '--no-ext-diff', '--no-color'];
      if (staged) arguments.add('--cached');
      String? relative;
      if (path != null) {
        relative = _validateRelativePath(path);
        arguments.addAll(['--', relative]);
      }
      final result = await _runGit(arguments, outputLimit: _outputLimit);
      _diff = GitDiffResult(
        diff: result.stdout,
        staged: staged,
        path: relative,
        truncated: result.stdoutTruncated,
      );
      return _diff!;
    });
  }

  Future<GitCommitResult> commit(String message) async {
    return _runMutation(() {
      return _runOperation('commit', () async {
        _requireRepository();
        final normalized = message.trim();
        if (normalized.isEmpty ||
            normalized.length > 200 ||
            normalized.contains(RegExp(r'[\r\n\x00]'))) {
          throw const CourierException(
            'INVALID_COMMIT_MESSAGE',
            '提交信息为空、过长或包含不允许的控制字符',
          );
        }
        final staged = await _runGit(
          ['diff', '--cached', '--quiet'],
          allowedExitCodes: const {0, 1},
        );
        if (staged.exitCode == 0) {
          throw const CourierException('NOTHING_STAGED', '没有已暂存的变更');
        }
        final result = await _runGit(['commit', '-m', normalized]);
        await refreshStatus();
        await refreshBranches();
        await refreshLog();
        return GitCommitResult(
          output: result.stdout.trim(),
          message: normalized,
        );
      });
    });
  }

  Future<void> switchBranch(String branch) async {
    await _runMutation(() {
      return _runOperation('switch_branch', () => _switchToBranch(branch));
    });
  }

  /// 切换分支的核心逻辑（不含 [._runMutation] 串行化）。
  /// 供 [switchBranch] 与 [createBranch]（创建后切换）复用，避免嵌套串行化死锁。
  Future<void> _switchToBranch(String branch) async {
    _requireRepository();
    final branchList = await refreshBranches();
    final normalized = branch.trim();
    if (!branchList.branches.contains(normalized)) {
      throw const CourierException('BRANCH_NOT_FOUND', '目标分支不存在');
    }
    final currentStatus = await refreshStatus();
    if (!currentStatus.clean) {
      throw const CourierException(
        'WORKTREE_NOT_CLEAN',
        '工作区存在未提交变更，已阻止切换分支',
      );
    }
    if (normalized == branchList.current) return;
    await _runGit(['switch', '--no-guess', '--', normalized]);
    _diff = null;
    await refreshStatus();
    await refreshBranches();
    await refreshLog();
  }

  /// 新建分支；[switchTo] 为 true 时创建后立即切换到新分支。
  Future<void> createBranch(String name, {bool switchTo = false}) async {
    await _runMutation(() {
      return _runOperation('create_branch', () async {
        _requireRepository();
        final normalized = _validateBranchName(name);
        final branchList = await refreshBranches();
        if (branchList.branches.contains(normalized)) {
          throw const CourierException('BRANCH_ALREADY_EXISTS', '分支已存在');
        }
        await _runGit(['branch', '--', normalized]);
        await refreshBranches();
        if (switchTo) {
          await _switchToBranch(normalized);
        }
      });
    });
  }

  Future<T> _runOperation<T>(
    String event,
    Future<T> Function() operation,
  ) async {
    if (_operationDepth == 0) {
      _idleCompleter = Completer<void>();
    }
    _operationDepth++;
    _loading = true;
    _lastError = null;
    notifyListeners();
    try {
      final result = await operation();
      await logger.info('git', event, 'Git 操作完成');
      return result;
    } on CourierException catch (error) {
      _lastError = error.message;
      await logger.error('git', event, error.message, errorCode: error.code);
      rethrow;
    } finally {
      _operationDepth--;
      _loading = _operationDepth > 0;
      if (_operationDepth == 0) {
        _idleCompleter?.complete();
        _idleCompleter = null;
      }
      notifyListeners();
    }
  }

  Future<bool> _checkGitAvailable() async {
    try {
      final process = await Process.start('git', [
        '--version',
      ], runInShell: false);
      await process.stdout.drain<void>();
      await process.stderr.drain<void>();
      return await process.exitCode.timeout(const Duration(seconds: 5)) == 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> _waitForIdle() {
    return _idleCompleter?.future ?? Future<void>.value();
  }

  Future<T> _runMutation<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _mutationTail = _mutationTail.then((_) async {
      try {
        result.complete(await operation());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  Future<void> reset() async {
    await _mutationTail;
    await _waitForIdle();
    _workspacePath = null;
    _gitAvailable = false;
    _repositoryAvailable = false;
    _loading = false;
    _lastError = null;
    _status = null;
    _branches = null;
    _diff = null;
    _log = null;
    notifyListeners();
  }

  Future<_GitCommandResult> _runGit(
    List<String> arguments, {
    Set<int> allowedExitCodes = const {0},
    int outputLimit = _defaultOutputLimit,
  }) async {
    final workspace = _workspacePath;
    if (workspace == null) {
      throw const CourierException('WORKSPACE_REQUIRED', '需要先打开工作区');
    }
    if (!_gitAvailable) {
      throw const CourierException('GIT_NOT_AVAILABLE', '系统未检测到 Git CLI');
    }

    late final Process process;
    try {
      process = await Process.start(
        'git',
        arguments,
        workingDirectory: workspace,
        runInShell: false,
      );
    } on ProcessException {
      throw const CourierException('GIT_NOT_AVAILABLE', '无法启动 Git CLI');
    }

    final stdoutFuture = _readLimited(process.stdout, outputLimit);
    final stderrFuture = _readLimited(process.stderr, 64 * 1024);
    late final int exitCode;
    try {
      exitCode = await process.exitCode.timeout(_commandTimeout);
    } on TimeoutException {
      process.kill();
      throw const CourierException('GIT_TIMEOUT', 'Git 操作超时');
    }
    final stdoutResult = await stdoutFuture;
    final stderrResult = await stderrFuture;
    if (!allowedExitCodes.contains(exitCode)) {
      final message = stderrResult.text.trim().isNotEmpty
          ? stderrResult.text.trim()
          : stdoutResult.text.trim();
      throw CourierException(
        'GIT_COMMAND_FAILED',
        ErrorSanitizer.redact(
          message.isEmpty ? 'Git 操作失败，退出码 $exitCode' : message,
          maxLength: 2000,
        ),
      );
    }
    return _GitCommandResult(
      exitCode: exitCode,
      stdout: stdoutResult.text,
      stderr: stderrResult.text,
      stdoutTruncated: stdoutResult.truncated,
    );
  }

  Future<_LimitedText> _readLimited(Stream<List<int>> stream, int limit) async {
    final bytes = <int>[];
    var truncated = false;
    await for (final chunk in stream) {
      final remaining = limit - bytes.length;
      if (remaining > 0) {
        bytes.addAll(chunk.take(remaining));
      }
      if (chunk.length > remaining) truncated = true;
    }
    return _LimitedText(
      text: utf8.decode(bytes, allowMalformed: true),
      truncated: truncated,
    );
  }

  List<GitStatusFile> _parseStatus(String output) {
    final entries = output.split('\u0000');
    final files = <GitStatusFile>[];
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      if (entry.length < 4) continue;
      final indexStatus = entry.substring(0, 1);
      final workTreeStatus = entry.substring(1, 2);
      final path = entry.substring(3);
      files.add(
        GitStatusFile(
          indexStatus: indexStatus,
          workTreeStatus: workTreeStatus,
          path: path,
        ),
      );
      if ((indexStatus == 'R' ||
              indexStatus == 'C' ||
              workTreeStatus == 'R' ||
              workTreeStatus == 'C') &&
          index + 1 < entries.length) {
        index++;
      }
    }
    return files;
  }

  List<GitCommitEntry> _parseLog(String output, String headHash) {
    final fields = output.split('\u0000');
    final entries = <GitCommitEntry>[];
    final fullHashPattern = RegExp(r'^[0-9a-fA-F]{40,64}$');
    final shortHashPattern = RegExp(r'^[0-9a-fA-F]+$');
    for (var index = 0; index + 5 < fields.length; index += 6) {
      final fullHash = fields[index].replaceFirst(RegExp(r'^[\r\n]+'), '');
      final shortHash = fields[index + 1].trim();
      final authorDate = fields[index + 4].trim();
      if (!fullHashPattern.hasMatch(fullHash) ||
          !shortHashPattern.hasMatch(shortHash) ||
          DateTime.tryParse(authorDate) == null) {
        continue;
      }
      entries.add(
        GitCommitEntry(
          shortHash: shortHash,
          fullHash: fullHash,
          authorName: fields[index + 2],
          authorEmail: fields[index + 3],
          authorDate: authorDate,
          subject: fields[index + 5],
          isHead: fullHash == headHash,
        ),
      );
    }
    return List<GitCommitEntry>.unmodifiable(entries);
  }

  /// 校验分支名：非空、无空白/控制字符、无常见非法字符。
  /// 仅做前置友好校验，其余非法形式由 `git branch` 兜底拒绝。
  String _validateBranchName(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      throw const CourierException('INVALID_BRANCH_NAME', '分支名不能为空');
    }
    if (normalized.contains(RegExp(r'[\s\x00-\x1F\x7F]'))) {
      throw const CourierException(
        'INVALID_BRANCH_NAME',
        '分支名不能包含空格或控制字符',
      );
    }
    if (normalized.startsWith('-') ||
        normalized.startsWith('/') ||
        normalized.endsWith('/') ||
        normalized.endsWith('.') ||
        normalized.contains('..') ||
        normalized.contains(RegExp(r'[~^:?*\[\]\\@{}]'))) {
      throw const CourierException(
        'INVALID_BRANCH_NAME',
        '分支名包含不允许的字符',
      );
    }
    return normalized;
  }

  String _validateRelativePath(String value) {
    _requireRepository();
    final normalized = p.normalize(value.trim());
    if (normalized.isEmpty ||
        normalized == '.' ||
        p.isAbsolute(normalized) ||
        normalized == '..' ||
        normalized.startsWith('..${p.separator}') ||
        normalized.contains('\u0000')) {
      throw const CourierException('INVALID_GIT_PATH', 'Git 文件路径无效');
    }
    final absolute = p.normalize(p.join(_workspacePath!, normalized));
    if (!_isWithinWorkspace(absolute)) {
      throw const CourierException('INVALID_GIT_PATH', 'Git 文件路径超出工作区');
    }
    return normalized;
  }

  void _requireRepository() {
    if (!_gitAvailable) {
      throw const CourierException('GIT_NOT_AVAILABLE', '系统未检测到 Git CLI');
    }
    if (!_repositoryAvailable || _workspacePath == null) {
      throw const CourierException(
        'GIT_REPOSITORY_REQUIRED',
        '当前工作区不是 Git 仓库根目录',
      );
    }
  }

  bool _isWithinWorkspace(String path) {
    return WorkspaceDirectoryGuard.isWithin(_workspacePath!, path);
  }

  bool _samePath(String left, String right) =>
      WorkspaceDirectoryGuard.comparisonPath(left) ==
      WorkspaceDirectoryGuard.comparisonPath(right);
}

class _GitCommandResult {
  final int exitCode;
  final String stdout;
  final String stderr;
  final bool stdoutTruncated;

  const _GitCommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.stdoutTruncated,
  });
}

class _LimitedText {
  final String text;
  final bool truncated;

  const _LimitedText({required this.text, required this.truncated});
}
