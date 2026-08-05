// courier_core_service.dart — Provider 服务封装（ChangeNotifier）
//
// 连接 FFI 绑定层与 UI 层，提供响应式状态管理。
// 所有 FFI 调用通过此服务中转，自动管理状态和 notifyListeners()。
// UI 组件通过 Provider.of<CourierCoreService>(context) 消费状态。

import 'package:flutter/foundation.dart';

import 'courier_core.dart';
import 'models.dart';

// ============================================================
// 本地辅助模型
// ============================================================

/// AIMessage — 本地维护的对话消息（Go 侧不存储历史）。
@immutable
class AIMessage {
  final String role; // 'user' | 'assistant'
  final String text;
  final DateTime timestamp;

  const AIMessage({
    required this.role,
    required this.text,
    required this.timestamp,
  });

  bool get isUser => role == 'user';

  @override
  String toString() => 'AIMessage($role: ${text.length} chars)';
}

/// ServiceOperationState — 异步操作状态。
enum ServiceState { idle, loading, success, error }

// ============================================================
// CourierCoreService — 核心服务
// ============================================================

/// CourierCoreService 是 UI 层访问 Go 后端的唯一入口。
///
/// 使用方式：
/// ```dart
/// // main.dart 中注入
/// final coreService = CourierCoreService();
/// ChangeNotifierProvider<CourierCoreService>.value(value: coreService)
///
/// // Widget 中消费
/// final service = context.read<CourierCoreService>();
/// service.aiStartSession(workspacePath: '/path');
/// ```
class CourierCoreService extends ChangeNotifier {
  final CourierCore _core;

  // ---- 版本信息 ----
  VersionInfo? _version;
  VersionInfo? get version => _version;

  // ---- AI 会话状态 ----
  AISession? _aiSession;
  AISession? get aiSession => _aiSession;

  final List<AIMessage> _aiMessages = [];
  List<AIMessage> get aiMessages => List.unmodifiable(_aiMessages);

  AIGetOptionsResult? _aiOptions;
  AIGetOptionsResult? get aiOptions => _aiOptions;

  bool _aiSending = false;
  bool get aiSending => _aiSending;

  // ---- 任务队列状态 ----
  List<TaskItem> _tasks = [];
  List<TaskItem> get tasks => List.unmodifiable(_tasks);

  QueueSummary? _queueSummary;
  QueueSummary? get queueSummary => _queueSummary;

  // ---- Git 状态 ----
  GitStatusResult? _gitStatus;
  GitStatusResult? get currentGitStatus => _gitStatus;

  GitBranchListResult? _gitBranches;
  GitBranchListResult? get gitBranches => _gitBranches;

  GitDiffResult? _gitDiff;
  GitDiffResult? get currentGitDiff => _gitDiff;

  // ---- 通用状态 ----
  ServiceState _state = ServiceState.idle;
  ServiceState get state => _state;

  String? _lastError;
  String? get lastError => _lastError;

  String? _lastErrorCode;
  String? get lastErrorCode => _lastErrorCode;

  bool get isLoading => _state == ServiceState.loading;
  bool get hasError => _state == ServiceState.error;

  // ============================================================
  // 构造函数
  // ============================================================

  /// 使用默认 DLL 路径创建服务。
  CourierCoreService() : _core = CourierCore();

  /// 使用自定义 CourierCore 实例创建服务（用于测试注入）。
  CourierCoreService.withCore(this._core);

  /// 使用自定义 DLL 路径创建服务。
  CourierCoreService.withPath(String dllPath) : _core = CourierCore.withPath(dllPath);

  // ============================================================
  // 内部工具
  // ============================================================

  /// 包装同步 FFI 调用，自动管理状态和错误处理。
  T _run<T>(String operationName, T Function() action) {
    _state = ServiceState.loading;
    _lastError = null;
    _lastErrorCode = null;
    notifyListeners();
    try {
      final result = action();
      _state = ServiceState.success;
      notifyListeners();
      return result;
    } on CourierException catch (e) {
      _state = ServiceState.error;
      _lastError = e.message;
      _lastErrorCode = e.code;
      debugPrint('[$operationName] CourierException: ${e.code}: ${e.message}');
      notifyListeners();
      rethrow;
    } catch (e) {
      _state = ServiceState.error;
      _lastError = e.toString();
      _lastErrorCode = 'UNKNOWN';
      debugPrint('[$operationName] Error: $e');
      notifyListeners();
      rethrow;
    }
  }

  /// 清除错误状态。
  void clearError() {
    _lastError = null;
    _lastErrorCode = null;
    _state = ServiceState.idle;
    notifyListeners();
  }

  // ============================================================
  // 核心模块
  // ============================================================

  /// 获取核心库版本。首次调用后缓存结果。
  VersionInfo getCoreVersion() {
    if (_version != null) return _version!;
    return _run('getCoreVersion', () {
      _version = _core.getCoreVersion();
      return _version!;
    });
  }

  // ============================================================
  // AI 模块
  // ============================================================

  /// 创建 AI 对话会话。
  /// 成功后更新 _aiSession，清空历史消息。
  AISession aiStartSession({
    required String workspacePath,
    String providerId = 'default',
    String modelId = 'default',
  }) {
    return _run('aiStartSession', () {
      final session = _core.aiStartSession(
        workspacePath: workspacePath,
        providerId: providerId,
        modelId: modelId,
      );
      _aiSession = session;
      _aiMessages.clear();
      return session;
    });
  }

  /// 向 AI 发送消息。
  /// 将用户消息和 AI 回复加入历史记录。
  /// aiSending 状态在调用期间为 true。
  AISendMessageResult aiSendMessage({required String text}) {
    if (_aiSession == null) {
      throw const CourierException('NO_SESSION', 'AI 会话未创建，请先调用 aiStartSession');
    }

    _aiSending = true;
    _state = ServiceState.loading;
    notifyListeners();

    try {
      // 立即添加用户消息到历史
      _aiMessages.add(AIMessage(
        role: 'user',
        text: text,
        timestamp: DateTime.now(),
      ));

      final result = _core.aiSendMessage(
        sessionId: _aiSession!.sessionId,
        text: text,
      );

      // 添加 AI 回复到历史
      _aiMessages.add(AIMessage(
        role: 'assistant',
        text: result.reply,
        timestamp: DateTime.now(),
      ));

      _aiSending = false;
      _state = ServiceState.success;
      _lastError = null;
      notifyListeners();
      return result;
    } on CourierException catch (e) {
      _aiSending = false;
      _state = ServiceState.error;
      _lastError = e.message;
      _lastErrorCode = e.code;
      debugPrint('[aiSendMessage] CourierException: ${e.code}: ${e.message}');
      notifyListeners();
      rethrow;
    } catch (e) {
      _aiSending = false;
      _state = ServiceState.error;
      _lastError = e.toString();
      _lastErrorCode = 'UNKNOWN';
      debugPrint('[aiSendMessage] Error: $e');
      notifyListeners();
      rethrow;
    }
  }

  /// 停止当前 AI 会话。
  /// 清空会话和消息历史。
  AIStopSessionResult aiStopSession() {
    if (_aiSession == null) {
      throw const CourierException('NO_SESSION', 'AI 会话未创建');
    }
    return _run('aiStopSession', () {
      final result = _core.aiStopSession(_aiSession!.sessionId);
      _aiSession = null;
      _aiMessages.clear();
      _aiSending = false;
      return result;
    });
  }

  /// 获取 AI 选项（供应商/模型/思考级别/模式）。首次调用后缓存。
  AIGetOptionsResult aiGetOptions() {
    if (_aiOptions != null) return _aiOptions!;
    return _run('aiGetOptions', () {
      _aiOptions = _core.aiGetOptions();
      return _aiOptions!;
    });
  }

  /// 清空 AI 对话历史（不影响会话本身）。
  void clearAIMessages() {
    _aiMessages.clear();
    notifyListeners();
  }

  // ============================================================
  // 任务模块
  // ============================================================

  /// 创建任务并刷新任务列表。
  TaskItem createTask({
    required String title,
    required String sourceType,
    required String markdownContent,
  }) {
    return _run('createTask', () {
      final task = _core.createTask(
        title: title,
        sourceType: sourceType,
        markdownContent: markdownContent,
      );
      _tasks.insert(0, task);
      return task;
    });
  }

  /// 刷新任务列表。
  List<TaskItem> listTasks({String status = ''}) {
    return _run('listTasks', () {
      _tasks = _core.listTasks(status: status);
      return _tasks;
    });
  }

  /// 获取任务详情。
  TaskItem getTaskDetail(String taskId) {
    return _run('getTaskDetail', () {
      return _core.getTaskDetail(taskId);
    });
  }

  /// 删除任务并从本地列表移除。
  DeleteTaskResult deleteTask(String taskId) {
    return _run('deleteTask', () {
      final result = _core.deleteTask(taskId);
      _tasks.removeWhere((t) => t.id == taskId);
      return result;
    });
  }

  /// 刷新队列统计。
  QueueSummary getQueueSummary() {
    return _run('getQueueSummary', () {
      _queueSummary = _core.getQueueSummary();
      return _queueSummary!;
    });
  }

  /// 启动任务队列。
  QueueControlResult startQueue() {
    return _run('startQueue', () {
      return _core.startQueue();
    });
  }

  /// 暂停任务队列。
  QueueControlResult pauseQueue() {
    return _run('pauseQueue', () {
      return _core.pauseQueue();
    });
  }

  // ============================================================
  // Git 模块
  // ============================================================

  /// 获取 Git 状态。
  GitStatusResult gitStatus(String workspacePath) {
    return _run('gitStatus', () {
      _gitStatus = _core.gitStatus(workspacePath);
      return _gitStatus!;
    });
  }

  /// 提交 Git 变更。
  GitCommitResult gitCommit({
    required String workspacePath,
    required String message,
    bool addAll = false,
  }) {
    return _run('gitCommit', () {
      return _core.gitCommit(
        workspacePath: workspacePath,
        message: message,
        addAll: addAll,
      );
    });
  }

  /// 获取 Git 差异。
  GitDiffResult gitDiff({
    required String workspacePath,
    bool staged = false,
  }) {
    return _run('gitDiff', () {
      _gitDiff = _core.gitDiff(
        workspacePath: workspacePath,
        staged: staged,
      );
      return _gitDiff!;
    });
  }

  /// 列出 Git 分支。
  GitBranchListResult gitBranchList(String workspacePath) {
    return _run('gitBranchList', () {
      _gitBranches = _core.gitBranchList(workspacePath);
      return _gitBranches!;
    });
  }

  // ============================================================
  // 加密模块
  // ============================================================

  /// 加密明文。
  String encrypt(String plaintext, String key) {
    return _run('encrypt', () {
      return _core.encrypt(plaintext, key);
    });
  }

  /// 解密密文。
  String decrypt(String ciphertext, String key) {
    return _run('decrypt', () {
      return _core.decrypt(ciphertext, key);
    });
  }

  // ============================================================
  // 批量刷新
  // ============================================================

  /// 刷新所有与工作区相关的状态（任务列表 + 队列统计）。
  /// 用于页面切换或手动刷新时调用。
  void refreshAll() {
    _run('refreshAll', () {
      _tasks = _core.listTasks();
      _queueSummary = _core.getQueueSummary();
      return null;
    });
  }

  /// 重置所有状态（用于切换工作区）。
  void reset() {
    _aiSession = null;
    _aiMessages.clear();
    _aiSending = false;
    _tasks = [];
    _queueSummary = null;
    _gitStatus = null;
    _gitBranches = null;
    _gitDiff = null;
    _lastError = null;
    _lastErrorCode = null;
    _state = ServiceState.idle;
    notifyListeners();
  }

  @override
  void dispose() {
    _aiSession = null;
    _aiMessages.clear();
    super.dispose();
  }
}
