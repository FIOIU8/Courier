// codex_task_executor.dart - Task executor that shells out to Codex CLI.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_error.dart';
import 'app_logger.dart';
import 'models.dart';
import 'task_service.dart';

/// 基于 Codex CLI 的任务执行器。
///
/// 通过 `codex` 命令行工具执行任务，支持三种权限级别：
/// - [TaskPermission.readOnly]：仅读取
/// - [TaskPermission.readWrite]：读取、写入和删除（默认全权限）
/// - [TaskPermission.yolo]：全自动，跳过所有确认
///
/// 实时流式输出 stdout/stderr，估算进度，支持取消。
class CodexTaskExecutor implements TaskExecutor {
  static const int _maxOutputBytes = 1024 * 1024; // 1 MB
  static const int _maxPromptBytes = 256 * 1024; // 256 KB

  final AppLogger logger;
  final Map<String, Process> _processes = {};
  final Map<String, StreamSubscription<void>> _subscriptions = {};

  CodexTaskExecutor({required this.logger});

  @override
  Future<TaskExecutionResult> execute(
    TaskItem task, {
    required String workspacePath,
    required TaskCancellationToken cancellationToken,
    required void Function(double progress) onProgress,
    required void Function(String event) onEvent,
  }) async {
    // 检测 codex 是否可用
    final codexPath = await _resolveCodexPath();
    if (codexPath == null) {
      throw const CourierException(
        'CODEX_NOT_FOUND',
        'Codex CLI 未检测到。请安装 codex 并确保其在 PATH 中。',
      );
    }

    final prompt = '${task.title}\n\n${task.markdownContent}';
    final promptBytes = utf8.encode(prompt);
    if (promptBytes.length > _maxPromptBytes) {
      throw const CourierException(
        'PROMPT_TOO_LARGE',
        '任务内容超过 Codex 允许的大小限制（256 KB）',
      );
    }

    // 根据权限级别构建参数
    final args = _buildArgs(task, prompt);

    onEvent('启动 Codex CLI（${TaskPermission.label(task.permission)}）');
    onProgress(0.01);

    final output = StringBuffer();
    final errorOutput = StringBuffer();
    Process? process;

    try {
      process = await Process.start(
        codexPath,
        args,
        workingDirectory: workspacePath,
        runInShell: Platform.isWindows,
      );
      _processes[task.id] = process;

      onEvent('Codex 进程已启动 (PID: ${process.pid})');

      final stdoutDone = Completer<void>();
      final stderrDone = Completer<void>();

      // 流式读取 stdout
      final stdoutSub = process.stdout
          .transform(utf8.decoder)
          .listen(
        (chunk) {
          cancellationToken.throwIfCancelled();
          output.write(chunk);
          if (output.length > _maxOutputBytes) {
            process?.kill(ProcessSignal.sigkill);
            throw const CourierException(
              'OUTPUT_TOO_LARGE',
              'Codex 输出超过应用允许的大小限制（1 MB）',
            );
          }
          final estimated = _estimateProgress(output.length);
          onProgress(estimated);
          _emitOutputEvent(chunk, onEvent);
        },
        onError: (error) {
          onEvent('stdout 读取错误: $error');
        },
        onDone: () => stdoutDone.complete(),
      );

      // 流式读取 stderr
      final stderrSub = process.stderr
          .transform(utf8.decoder)
          .listen(
        (chunk) {
          errorOutput.write(chunk);
        },
        onError: (_) {},
        onDone: () => stderrDone.complete(),
      );

      _subscriptions[task.id] = _MergedSubscription([stdoutSub, stderrSub]);

      // 等待进程结束
      final exitCode = await process.exitCode;

      // 等待流完全结束（最多等 10 秒）
      await Future.wait([stdoutDone.future, stderrDone.future]).timeout(
        const Duration(seconds: 10),
        onTimeout: () => <void>[],
      );

      cancellationToken.throwIfCancelled();

      if (exitCode != 0) {
        final errorText = errorOutput.toString().trim();
        throw CourierException(
          'CODEX_EXIT_ERROR',
          'Codex 进程异常退出（code: $exitCode）${errorText.isNotEmpty ? ': $errorText' : ''}',
        );
      }

      onProgress(1.0);
      onEvent('Codex 执行完成');

      final result = output.toString().trim();
      if (result.isEmpty) {
        onEvent('Codex 未产生输出');
        return const TaskExecutionResult(output: '(Codex 未产生输出)');
      }

      return TaskExecutionResult(output: result);
    } on CourierException {
      rethrow;
    } catch (error) {
      throw CourierException(
        'CODEX_EXECUTION_FAILED',
        'Codex 执行失败: ${ErrorSanitizer.redact(error.toString(), maxLength: 500)}',
      );
    } finally {
      _cleanup(task.id);
    }
  }

  @override
  Future<void> cancel(String taskId) async {
    final process = _processes[taskId];
    if (process != null) {
      process.kill(ProcessSignal.sigkill);
      await logger.info('codex', 'cancelled', 'Codex 进程已终止', requestId: taskId);
    }
    _cleanup(taskId);
  }

  /// 构建 Codex CLI 参数。
  List<String> _buildArgs(TaskItem task, String prompt) {
    final args = <String>[];

    // Codex CLI 用法: codex [OPTIONS] [PROMPT]
    // 权限通过 --sandbox 控制（Codex 0.80+ 支持）
    // readonly  → --sandbox readonly   （只读，不写入磁盘）
    // readWrite → --sandbox workspace-write （允许写入工作区）
    // yolo      → 不传 sandbox（默认全权限）
    switch (task.permission) {
      case TaskPermission.readOnly:
        args.addAll(['--sandbox', 'readonly']);
      case TaskPermission.readWrite:
        args.addAll(['--sandbox', 'workspace-write']);
      case TaskPermission.yolo:
        // 不传 sandbox 参数，全权限
        break;
    }

    // 提示词直接作为位置参数传入
    args.add(prompt);

    return args;
  }

  /// 估算进度（基于输出长度的启发式）。
  double _estimateProgress(int outputLength) {
    final estimated = 0.1 + 0.8 * (1 - 1 / (1 + outputLength / 10000));
    return estimated.clamp(0.1, 0.95);
  }

  /// 解析输出块，提取有意义的事件。
  void _emitOutputEvent(String chunk, void Function(String event) onEvent) {
    final lines = chunk.split('\n');
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      // 检测文件操作（中英文）
      if (trimmed.startsWith('Reading') || trimmed.startsWith('读取')) {
        onEvent('📖 ${trimmed.length > 100 ? '${trimmed.substring(0, 100)}...' : trimmed}');
      } else if (trimmed.startsWith('Writing') || trimmed.startsWith('写入')) {
        onEvent('✏️ ${trimmed.length > 100 ? '${trimmed.substring(0, 100)}...' : trimmed}');
      } else if (trimmed.startsWith('Creating') || trimmed.startsWith('创建')) {
        onEvent('📄 ${trimmed.length > 100 ? '${trimmed.substring(0, 100)}...' : trimmed}');
      } else if (trimmed.startsWith('Deleting') || trimmed.startsWith('删除')) {
        onEvent('🗑️ ${trimmed.length > 100 ? '${trimmed.substring(0, 100)}...' : trimmed}');
      }
    }
  }

  /// 清理进程和订阅。
  void _cleanup(String taskId) {
    _processes.remove(taskId);
    final sub = _subscriptions.remove(taskId);
    sub?.cancel();
  }

  /// 检测 codex 命令路径。
  Future<String?> _resolveCodexPath() async {
    try {
      if (Platform.isWindows) {
        // Windows: 尝试 where 命令
        final result = await Process.run(
          'where',
          ['codex'],
          runInShell: true,
        );
        if (result.exitCode == 0) {
          final paths = (result.stdout as String)
              .split('\n')
              .map((line) => line.trim())
              .where((line) => line.isNotEmpty)
              .toList();
          if (paths.isNotEmpty) return paths.first;
        }
      } else {
        // macOS/Linux: 尝试 which 命令
        final result = await Process.run('which', ['codex']);
        if (result.exitCode == 0) {
          final path = (result.stdout as String).trim();
          if (path.isNotEmpty) return path;
        }
      }
    } catch (_) {
      // 命令不存在
    }

    // 尝试直接运行 codex --version
    try {
      final result = await Process.run(
        'codex',
        ['--version'],
        runInShell: true,
      );
      if (result.exitCode == 0) return 'codex';
    } catch (_) {}

    return null;
  }

  /// 释放所有资源。
  Future<void> dispose() async {
    final taskIds = _processes.keys.toList(growable: false);
    for (final taskId in taskIds) {
      await cancel(taskId);
    }
  }
}

/// 合并多个 StreamSubscription 为一个可取消的订阅。
class _MergedSubscription implements StreamSubscription<void> {
  final List<StreamSubscription<void>> _subs;

  _MergedSubscription(this._subs);

  @override
  Future<void> cancel() async {
    await Future.wait(_subs.map((s) => s.cancel()));
  }

  @override
  void onData(void Function(void data)? handleData) {}

  @override
  void onDone(void Function()? handleDone) {}

  @override
  void onError(Function? handleError) {}

  @override
  void pause([Future<void>? resumeSignal]) {
    for (final sub in _subs) {
      sub.pause(resumeSignal);
    }
  }

  @override
  void resume() {
    for (final sub in _subs) {
      sub.resume();
    }
  }

  @override
  bool get isPaused => _subs.any((s) => s.isPaused);

  @override
  Future<E> asFuture<E>([E? futureValue]) {
    return Future.wait(_subs.map((s) => s.asFuture())).then((_) => futureValue as E);
  }
}
