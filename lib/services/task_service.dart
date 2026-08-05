// task_service.dart - Persistent cancellable workspace task queue.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'ai_service.dart';
import 'app_error.dart';
import 'app_logger.dart';
import 'atomic_file_writer.dart';
import 'id_generator.dart';
import 'models.dart';
import 'workspace_directory_guard.dart';

class TaskCancellationToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;

  void throwIfCancelled() {
    if (_cancelled) {
      throw const CourierException('TASK_CANCELLED', '任务已取消');
    }
  }
}

class TaskExecutionResult {
  final String output;

  const TaskExecutionResult({required this.output});
}

abstract interface class TaskExecutor {
  Future<TaskExecutionResult> execute(
    TaskItem task, {
    required String workspacePath,
    required TaskCancellationToken cancellationToken,
    required void Function(double progress) onProgress,
    required void Function(String event) onEvent,
  });

  Future<void> cancel(String taskId);
}

class AITaskExecutor implements TaskExecutor {
  final AIService aiService;
  final Map<String, String> _requestIds = {};

  AITaskExecutor({required this.aiService});

  @override
  Future<TaskExecutionResult> execute(
    TaskItem task, {
    required String workspacePath,
    required TaskCancellationToken cancellationToken,
    required void Function(double progress) onProgress,
    required void Function(String event) onEvent,
  }) async {
    final requestId = IdGenerator.create('task-request');
    _requestIds[task.id] = requestId;
    final output = StringBuffer();
    onEvent('AI 请求已开始');
    onProgress(0.05);
    try {
      final result = await aiService.executeTask(
        workspacePath: workspacePath,
        prompt: '${task.title}\n\n${task.markdownContent}',
        requestId: requestId,
        onDelta: (delta) {
          cancellationToken.throwIfCancelled();
          output.write(delta);
          final estimated = min(0.9, 0.1 + output.length / 50000);
          onProgress(estimated);
        },
      );
      cancellationToken.throwIfCancelled();
      onProgress(1.0);
      onEvent('AI 请求已完成');
      return TaskExecutionResult(output: result);
    } finally {
      _requestIds.remove(task.id);
    }
  }

  @override
  Future<void> cancel(String taskId) async {
    final requestId = _requestIds[taskId];
    if (requestId != null) {
      await aiService.cancelRequest(requestId);
    }
  }
}

class TaskService extends ChangeNotifier {
  static const int _schemaVersion = 1;
  static const int _maxIndexBytes = 5 * 1024 * 1024;
  static const int _maxTaskContentCharacters = 256 * 1024;
  static const int _maxTaskTitleCharacters = 160;
  static const int _maxTaskLogBytes = 1024 * 1024;
  static const int _maxResultBytes = 1024 * 1024;

  final TaskExecutor executor;
  final AppLogger logger;
  final List<TaskItem> _tasks = [];
  final Map<String, TaskCancellationToken> _activeTokens = {};
  final Map<String, Future<void>> _activeRuns = {};

  String? _workspacePath;
  Directory? _taskDirectory;
  File? _indexFile;
  bool _queueRunning = false;
  bool _scheduling = false;
  bool _disposed = false;
  String? _lastError;
  int _maxConcurrent = 1;
  Future<void> _persistenceChain = Future<void>.value();
  Future<void> _taskLogChain = Future<void>.value();
  Timer? _progressPersistenceTimer;

  TaskService({required this.executor, required this.logger});

  List<TaskItem> get tasks => List.unmodifiable(_tasks);
  String? get workspacePath => _workspacePath;
  bool get queueRunning => _queueRunning;
  int get maxConcurrent => _maxConcurrent;
  String? get lastError => _lastError;

  QueueSummary get summary {
    int count(String status) =>
        _tasks.where((task) => task.status == status).length;
    return QueueSummary(
      total: _tasks.length,
      queued: count(TaskStatus.queued),
      running: count(TaskStatus.running) + count(TaskStatus.cancelling),
      succeeded: count(TaskStatus.succeeded),
      failed: count(TaskStatus.failed),
      cancelled: count(TaskStatus.cancelled),
    );
  }

  Future<void> bindWorkspace(String workspacePath) async {
    _queueRunning = false;
    await _cancelAllActive();
    await _persistenceChain.catchError((Object _) {});
    await _taskLogChain.catchError((Object _) {});
    final previousWorkspacePath = _workspacePath;
    final previousTaskDirectory = _taskDirectory;
    final previousIndexFile = _indexFile;
    final previousTasks = List<TaskItem>.from(_tasks);
    final previousLastError = _lastError;
    try {
      final resolvedWorkspace =
          await WorkspaceDirectoryGuard.resolveWorkspaceRoot(workspacePath);
      final directory = await WorkspaceDirectoryGuard.ensureDirectory(
        resolvedWorkspace,
        const ['.Courier', 'tasks'],
      );
      _workspacePath = resolvedWorkspace;
      _taskDirectory = directory;
      _indexFile = File(
        '${directory.path}${Platform.pathSeparator}task-index.json',
      );
      await AtomicFileWriter.recover(_indexFile!);
      await _loadIndex();
      _lastError = null;
      notifyListeners();
    } catch (_) {
      _workspacePath = previousWorkspacePath;
      _taskDirectory = previousTaskDirectory;
      _indexFile = previousIndexFile;
      _tasks
        ..clear()
        ..addAll(previousTasks);
      _lastError = previousLastError;
      notifyListeners();
      rethrow;
    }
  }

  Future<TaskItem> createTask({
    required String title,
    required String sourceType,
    required String markdownContent,
    int maxAttempts = 3,
  }) async {
    _requireWorkspace();
    final normalizedTitle = title.trim().isEmpty ? '未命名任务' : title.trim();
    final normalizedContent = markdownContent.trim();
    final normalizedSource = sourceType.trim();
    if (normalizedTitle.length > _maxTaskTitleCharacters) {
      throw const CourierException('INVALID_TASK', '任务标题超过允许的长度');
    }
    if (normalizedContent.isEmpty ||
        normalizedContent.length > _maxTaskContentCharacters) {
      throw const CourierException('INVALID_TASK', '任务内容为空或超过允许的长度');
    }
    if (!RegExp(r'^[a-z][a-z0-9_-]{1,31}$').hasMatch(normalizedSource)) {
      throw const CourierException('INVALID_TASK', '任务来源标识无效');
    }
    if (maxAttempts < 1 || maxAttempts > 10) {
      throw const CourierException('INVALID_TASK', '任务重试上限无效');
    }

    final now = DateTime.now().toUtc().toIso8601String();
    final task = TaskItem(
      id: IdGenerator.create('task'),
      title: normalizedTitle,
      sourceType: normalizedSource,
      status: TaskStatus.queued,
      markdownContent: normalizedContent,
      progress: 0,
      createdAt: now,
      updatedAt: now,
      attempt: 0,
      maxAttempts: maxAttempts,
    );
    _tasks.insert(0, task);
    await _appendTaskEvent(task.id, '任务已创建');
    await _persist();
    notifyListeners();
    _schedule();
    return task;
  }

  List<TaskItem> listTasks({String status = ''}) {
    if (status.isEmpty) return List.unmodifiable(_tasks);
    if (!TaskStatus.isValid(status)) {
      throw const CourierException('INVALID_STATUS', '任务状态筛选值无效');
    }
    return _tasks
        .where((task) => task.status == status)
        .toList(growable: false);
  }

  TaskItem getTaskDetail(String taskId) {
    return _findTask(taskId);
  }

  Future<String> getTaskLogTail(
    String taskId, {
    int maxCharacters = 12000,
  }) async {
    _findTask(taskId);
    if (maxCharacters < 1 || maxCharacters > 50000) {
      throw const CourierException('INVALID_LOG_LIMIT', '任务日志读取上限无效');
    }
    final file = _taskLogFile(taskId);
    if (!await file.exists()) return '';
    final length = await file.length();
    final start = max(0, length - maxCharacters * 4);
    final handle = await file.open();
    try {
      await handle.setPosition(start);
      final bytes = await handle.read(length - start);
      final text = utf8.decode(bytes, allowMalformed: true);
      return text.length <= maxCharacters
          ? text
          : text.substring(text.length - maxCharacters);
    } finally {
      await handle.close();
    }
  }

  Future<String> getTaskResult(String taskId) async {
    final task = _findTask(taskId);
    final resultPath = task.resultPath;
    if (resultPath == null) return '';
    final file = _taskResultFile(task);
    if (!await file.exists()) {
      throw const CourierException('TASK_RESULT_MISSING', '任务结果文件不存在');
    }
    if (await file.length() > _maxResultBytes) {
      throw const CourierException('TASK_RESULT_TOO_LARGE', '任务结果超过读取限制');
    }
    return file.readAsString();
  }

  Future<DeleteTaskResult> deleteTask(String taskId) async {
    final task = _findTask(taskId);
    if (task.status == TaskStatus.running ||
        task.status == TaskStatus.cancelling) {
      throw const CourierException('TASK_RUNNING', '运行中的任务不能删除');
    }
    _tasks.removeWhere((item) => item.id == taskId);
    final logFile = _taskLogFile(taskId);
    if (await logFile.exists()) await logFile.delete();
    final resultPath = task.resultPath;
    if (resultPath != null) {
      final resultFile = _taskResultFile(task);
      if (await resultFile.exists()) await resultFile.delete();
    }
    await _persist();
    notifyListeners();
    return DeleteTaskResult(taskId: taskId, status: 'deleted');
  }

  Future<QueueControlResult> startQueue({required int maxConcurrent}) async {
    if (maxConcurrent < 1 || maxConcurrent > 10) {
      throw const CourierException('INVALID_CONCURRENCY', '任务并发数必须位于 1 到 10');
    }
    _requireWorkspace();
    _maxConcurrent = maxConcurrent;
    _queueRunning = true;
    _lastError = null;
    notifyListeners();
    _schedule();
    return const QueueControlResult(status: 'running');
  }

  Future<QueueControlResult> pauseQueue() async {
    _queueRunning = false;
    notifyListeners();
    return const QueueControlResult(status: 'paused');
  }

  void clearLastError() {
    if (_lastError == null) return;
    _lastError = null;
    notifyListeners();
  }

  Future<void> cancelTask(String taskId) async {
    final task = _findTask(taskId);
    if (task.status == TaskStatus.queued) {
      _replaceTask(
        task.copyWith(
          status: TaskStatus.cancelled,
          progress: 0,
          updatedAt: _now(),
          finishedAt: _now(),
        ),
      );
      await _appendTaskEvent(taskId, '任务已取消');
      await _persist();
      notifyListeners();
      return;
    }
    if (task.status != TaskStatus.running &&
        task.status != TaskStatus.cancelling) {
      throw const CourierException('TASK_NOT_CANCELLABLE', '当前任务状态不能取消');
    }
    final token = _activeTokens[taskId];
    token?.cancel();
    _replaceTask(
      task.copyWith(status: TaskStatus.cancelling, updatedAt: _now()),
    );
    await _appendTaskEvent(taskId, '正在取消任务');
    await _persist();
    notifyListeners();
    await executor.cancel(taskId);
  }

  Future<void> retryTask(String taskId) async {
    final task = _findTask(taskId);
    if (task.status != TaskStatus.failed) {
      throw const CourierException('TASK_NOT_RETRYABLE', '只有失败任务可以重试');
    }
    if (task.attempt >= task.maxAttempts) {
      throw const CourierException('TASK_RETRY_EXHAUSTED', '任务已达到最大重试次数');
    }
    _replaceTask(
      task.copyWith(
        status: TaskStatus.queued,
        progress: 0,
        updatedAt: _now(),
        startedAt: null,
        finishedAt: null,
        errorCode: null,
        errorMessage: null,
        resultPath: null,
      ),
    );
    await _appendTaskEvent(taskId, '任务已重新排队');
    await _persist();
    notifyListeners();
    _schedule();
  }

  void _schedule() {
    if (_scheduling || _disposed) return;
    _scheduling = true;
    scheduleMicrotask(() {
      try {
        if (!_queueRunning || _workspacePath == null) return;
        while (_activeTokens.length < _maxConcurrent) {
          final next = _tasks
              .where((task) => task.status == TaskStatus.queued)
              .firstOrNull;
          if (next == null) break;
          final token = TaskCancellationToken();
          _activeTokens[next.id] = token;
          final run = _runTask(next, token);
          _activeRuns[next.id] = run;
          unawaited(run.whenComplete(() => _activeRuns.remove(next.id)));
        }
      } finally {
        _scheduling = false;
      }
    });
  }

  Future<void> _runTask(
    TaskItem initialTask,
    TaskCancellationToken token,
  ) async {
    final started = initialTask.copyWith(
      status: TaskStatus.running,
      progress: 0.01,
      attempt: initialTask.attempt + 1,
      startedAt: _now(),
      finishedAt: null,
      errorCode: null,
      errorMessage: null,
      updatedAt: _now(),
    );
    _replaceTask(started);
    notifyListeners();

    var executionStarted = false;
    try {
      await _appendTaskEvent(started.id, '任务开始执行');
      await _persist();
      executionStarted = true;
      final result = await executor.execute(
        started,
        workspacePath: _workspacePath!,
        cancellationToken: token,
        onProgress: (progress) {
          if (token.isCancelled || _disposed) return;
          final current = _findTask(started.id);
          _replaceTask(current.copyWith(progress: progress, updatedAt: _now()));
          notifyListeners();
          _scheduleProgressPersistence();
        },
        onEvent: (event) {
          if (!_disposed) {
            unawaited(_appendTaskEventSafely(started.id, event));
          }
        },
      );
      token.throwIfCancelled();
      final resultName = '${started.id}.result.md';
      await AtomicFileWriter.writeString(
        File(p.join(_requireTaskDirectory().path, resultName)),
        result.output,
        maxBytes: _maxResultBytes,
      );
      final current = _findTask(started.id);
      _replaceTask(
        current.copyWith(
          status: TaskStatus.succeeded,
          progress: 1,
          updatedAt: _now(),
          finishedAt: _now(),
          resultPath: resultName,
        ),
      );
      await _appendTaskEvent(started.id, '任务执行成功');
      await logger.info('task', 'completed', '任务执行成功', requestId: started.id);
    } on CourierException catch (error) {
      if (!executionStarted) {
        await _recordTaskStorageFailure(started.id);
      } else {
        await _recordCourierFailure(started.id, token, error);
      }
    } catch (_) {
      if (!executionStarted) {
        await _recordTaskStorageFailure(started.id);
      } else {
        await _recordUnexpectedFailure(started.id);
      }
    } finally {
      _activeTokens.remove(started.id);
      await _persistInBackground();
      if (!_disposed) {
        notifyListeners();
        _schedule();
      }
    }
  }

  Future<void> _recordCourierFailure(
    String taskId,
    TaskCancellationToken token,
    CourierException error,
  ) async {
    final current = _findTask(taskId);
    if (token.isCancelled ||
        error.code == 'TASK_CANCELLED' ||
        error.code == 'REQUEST_CANCELLED') {
      _replaceTask(
        current.copyWith(
          status: TaskStatus.cancelled,
          updatedAt: _now(),
          finishedAt: _now(),
          errorCode: null,
          errorMessage: null,
        ),
      );
      await _appendTaskEventSafely(taskId, '任务已取消');
      return;
    }

    _replaceTask(
      current.copyWith(
        status: TaskStatus.failed,
        updatedAt: _now(),
        finishedAt: _now(),
        errorCode: error.code,
        errorMessage: ErrorSanitizer.redact(error.message, maxLength: 500),
      ),
    );
    await _appendTaskEventSafely(taskId, '任务执行失败：${error.message}');
    await logger.error(
      'task',
      'failed',
      error.message,
      requestId: taskId,
      errorCode: error.code,
    );
  }

  Future<void> _recordUnexpectedFailure(String taskId) async {
    final current = _findTask(taskId);
    _replaceTask(
      current.copyWith(
        status: TaskStatus.failed,
        updatedAt: _now(),
        finishedAt: _now(),
        errorCode: 'TASK_EXECUTION_FAILED',
        errorMessage: '任务执行期间发生未分类错误',
      ),
    );
    await _appendTaskEventSafely(taskId, '任务执行期间发生未分类错误');
    await logger.error(
      'task',
      'failed',
      '任务执行期间发生未分类错误',
      requestId: taskId,
      errorCode: 'TASK_EXECUTION_FAILED',
    );
  }

  Future<void> _recordTaskStorageFailure(String taskId) async {
    _queueRunning = false;
    _lastError = '任务状态无法持久化，队列已暂停';
    final current = _findTask(taskId);
    _replaceTask(
      current.copyWith(
        status: TaskStatus.failed,
        updatedAt: _now(),
        finishedAt: _now(),
        errorCode: 'TASK_STORAGE_FAILED',
        errorMessage: _lastError,
      ),
    );
    await _appendTaskEventSafely(taskId, _lastError!);
    await logger.error(
      'task',
      'storage_failed',
      _lastError!,
      requestId: taskId,
      errorCode: 'TASK_STORAGE_FAILED',
    );
  }

  Future<void> _loadIndex() async {
    _tasks.clear();
    final file = _indexFile!;
    if (!await file.exists()) {
      await _persist();
      return;
    }
    if (await file.length() > _maxIndexBytes) {
      throw const CourierException('TASK_INDEX_TOO_LARGE', '任务索引超过大小限制');
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['schemaVersion'] != _schemaVersion ||
          decoded['tasks'] is! List) {
        throw const FormatException('Invalid task index');
      }
      for (final value in decoded['tasks'] as List<dynamic>) {
        if (value is! Map<String, dynamic>) continue;
        var task = _validateLoadedTask(TaskItem.fromJson(value));
        if (task.status == TaskStatus.running ||
            task.status == TaskStatus.cancelling) {
          task = task.copyWith(
            status: TaskStatus.failed,
            updatedAt: _now(),
            finishedAt: _now(),
            errorCode: 'TASK_INTERRUPTED',
            errorMessage: '应用上次退出时任务仍在运行',
          );
        }
        _tasks.add(task);
      }
      _tasks.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      await _persist();
    } catch (_) {
      await logger.error(
        'task',
        'index_load_failed',
        '任务索引无法解析，原文件已保留',
        errorCode: 'INVALID_TASK_INDEX',
      );
      throw const CourierException('INVALID_TASK_INDEX', '任务索引损坏，原文件已保留');
    }
  }

  Future<void> _persist() {
    final file = _indexFile;
    if (file == null) return Future<void>.value();
    final payload = const JsonEncoder.withIndent('  ').convert({
      'schemaVersion': _schemaVersion,
      'updatedAt': _now(),
      'tasks': _tasks.map((task) => task.toJson()).toList(growable: false),
    });
    _persistenceChain = _persistenceChain.catchError((Object _) {}).then((_) {
      return AtomicFileWriter.writeString(
        file,
        '$payload\n',
        maxBytes: _maxIndexBytes,
      );
    });
    return _persistenceChain;
  }

  void _scheduleProgressPersistence() {
    _progressPersistenceTimer ??= Timer(const Duration(milliseconds: 300), () {
      _progressPersistenceTimer = null;
      unawaited(_persistInBackground());
    });
  }

  Future<void> _persistInBackground() async {
    try {
      await _persist();
    } catch (_) {
      _queueRunning = false;
      _lastError = '任务状态无法持久化，队列已暂停';
      await logger.error(
        'task',
        'persistence_failed',
        _lastError!,
        errorCode: 'TASK_STORAGE_FAILED',
      );
    }
  }

  Future<void> _appendTaskEvent(String taskId, String event) async {
    final file = _taskLogFile(taskId);
    final entry = {
      'timestamp': _now(),
      'event': ErrorSanitizer.redact(event, maxLength: 500),
    };
    _taskLogChain = _taskLogChain.catchError((Object _) {}).then((_) async {
      if (await file.exists() && await file.length() > _maxTaskLogBytes) {
        final previous = File('${file.path}.previous');
        if (await previous.exists()) await previous.delete();
        await file.rename(previous.path);
      }
      await file.writeAsString(
        '${jsonEncode(entry)}\n',
        mode: FileMode.append,
        flush: true,
      );
    });
    await _taskLogChain;
  }

  Future<void> _appendTaskEventSafely(String taskId, String event) async {
    try {
      await _appendTaskEvent(taskId, event);
    } catch (_) {
      await logger.warn(
        'task',
        'log_write_failed',
        '任务日志写入失败',
        requestId: taskId,
        errorCode: 'TASK_LOG_WRITE_FAILED',
      );
    }
  }

  Future<void> _cancelAllActive() async {
    final activeIds = _activeTokens.keys.toList(growable: false);
    for (final taskId in activeIds) {
      _activeTokens[taskId]?.cancel();
      await executor.cancel(taskId);
    }
    if (_activeRuns.isNotEmpty) {
      await Future.wait(
        _activeRuns.values
            .toList(growable: false)
            .map((run) => run.catchError((Object _) {})),
      );
    }
    _activeTokens.clear();
    _activeRuns.clear();
  }

  TaskItem _findTask(String taskId) {
    final normalized = taskId.trim();
    if (normalized.isEmpty) {
      throw const CourierException('TASK_NOT_FOUND', '任务不存在');
    }
    return _tasks.where((task) => task.id == normalized).firstOrNull ??
        (throw const CourierException('TASK_NOT_FOUND', '任务不存在'));
  }

  void _replaceTask(TaskItem replacement) {
    final index = _tasks.indexWhere((task) => task.id == replacement.id);
    if (index < 0) {
      throw const CourierException('TASK_NOT_FOUND', '任务不存在');
    }
    _tasks[index] = replacement;
  }

  File _taskLogFile(String taskId) {
    if (!RegExp(r'^task-[a-zA-Z0-9-]+$').hasMatch(taskId)) {
      throw const CourierException('TASK_NOT_FOUND', '任务不存在');
    }
    return File(p.join(_requireTaskDirectory().path, '$taskId.log.jsonl'));
  }

  File _taskResultFile(TaskItem task) {
    final resultPath = task.resultPath;
    if (resultPath == null || resultPath != '${task.id}.result.md') {
      throw const CourierException('TASK_RESULT_MISSING', '任务结果路径无效');
    }
    return File(p.join(_requireTaskDirectory().path, resultPath));
  }

  TaskItem _validateLoadedTask(TaskItem task) {
    if (!RegExp(r'^task-[a-zA-Z0-9-]+$').hasMatch(task.id) ||
        task.title.trim().isEmpty ||
        task.title.length > _maxTaskTitleCharacters ||
        task.markdownContent.trim().isEmpty ||
        task.markdownContent.length > _maxTaskContentCharacters ||
        !RegExp(r'^[a-z][a-z0-9_-]{1,31}$').hasMatch(task.sourceType) ||
        task.attempt < 0 ||
        task.maxAttempts < 1 ||
        task.maxAttempts > 10 ||
        task.attempt > task.maxAttempts ||
        DateTime.tryParse(task.createdAt) == null ||
        DateTime.tryParse(task.updatedAt) == null ||
        (task.startedAt != null &&
            DateTime.tryParse(task.startedAt!) == null) ||
        (task.finishedAt != null &&
            DateTime.tryParse(task.finishedAt!) == null) ||
        (task.errorCode != null && task.errorCode!.length > 128) ||
        (task.errorMessage != null && task.errorMessage!.length > 2000) ||
        (task.resultPath != null &&
            task.resultPath != '${task.id}.result.md')) {
      throw const FormatException('Invalid persisted task');
    }
    return task;
  }

  Directory _requireTaskDirectory() {
    final directory = _taskDirectory;
    if (directory == null) {
      throw const CourierException('WORKSPACE_REQUIRED', '需要先打开工作区');
    }
    return directory;
  }

  void _requireWorkspace() {
    if (_workspacePath == null || _taskDirectory == null) {
      throw const CourierException('WORKSPACE_REQUIRED', '需要先打开工作区');
    }
  }

  String _now() => DateTime.now().toUtc().toIso8601String();

  Future<void> reset() async {
    _queueRunning = false;
    _progressPersistenceTimer?.cancel();
    _progressPersistenceTimer = null;
    await _cancelAllActive();
    await _persistenceChain.catchError((Object _) {});
    await _taskLogChain.catchError((Object _) {});
    _workspacePath = null;
    _taskDirectory = null;
    _indexFile = null;
    _tasks.clear();
    _lastError = null;
    notifyListeners();
  }

  Future<void> shutdown() async {
    _queueRunning = false;
    _progressPersistenceTimer?.cancel();
    _progressPersistenceTimer = null;
    await _cancelAllActive();
    await _persistenceChain.catchError((Object _) {});
    await _taskLogChain.catchError((Object _) {});
  }

  @override
  void dispose() {
    _disposed = true;
    _queueRunning = false;
    _progressPersistenceTimer?.cancel();
    for (final entry in _activeTokens.entries) {
      final token = entry.value;
      token.cancel();
      unawaited(executor.cancel(entry.key).catchError((Object _) {}));
    }
    super.dispose();
  }
}
