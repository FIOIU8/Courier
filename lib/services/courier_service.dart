// courier_service.dart - Pure Dart application service facade.

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'ai_service.dart';
import 'app_error.dart';
import 'app_logger.dart';
import 'git_service.dart';
import 'models.dart';
import 'secure_storage_service.dart';
import 'settings_state.dart';
import 'task_service.dart';

typedef AppVersionLoader = Future<AppVersionInfo> Function();

class CourierService extends ChangeNotifier {
  final SettingsState settings;
  final AppLogger logger;
  final AIService ai;
  final TaskService taskQueue;
  final GitService git;
  final AppVersionLoader _versionLoader;

  AppVersionInfo? _version;
  String? _workspacePath;
  String? _lastError;

  factory CourierService({
    required SettingsState settings,
    required SecureStorageService secureStorage,
    required AppLogger logger,
    AIService? aiService,
    TaskService? taskService,
    GitService? gitService,
    AppVersionLoader? versionLoader,
  }) {
    final resolvedAi =
        aiService ??
        AIService(
          settings: settings,
          secureStorage: secureStorage,
          logger: logger,
        );
    return CourierService._(
      settings: settings,
      logger: logger,
      ai: resolvedAi,
      taskQueue:
          taskService ??
          TaskService(
            executor: AITaskExecutor(aiService: resolvedAi),
            logger: logger,
          ),
      git: gitService ?? GitService(logger: logger),
      versionLoader: versionLoader ?? _loadPackageVersion,
    );
  }

  CourierService._({
    required this.settings,
    required this.logger,
    required this.ai,
    required this.taskQueue,
    required this.git,
    required this._versionLoader,
  }) {
    logger.minimumLevel = settings.logLevel;
    settings.addListener(_handleSettingsChanged);
    ai.addListener(_relay);
    taskQueue.addListener(_relay);
    git.addListener(_relay);
  }

  AppVersionInfo? get version => _version;
  String? get workspacePath => _workspacePath;
  String? get lastError =>
      _lastError ?? ai.lastError ?? taskQueue.lastError ?? git.lastError;

  AISession? get aiSession => ai.session;
  List<AIMessage> get aiMessages => ai.messages;
  AIGetOptionsResult get aiOptions => ai.options;
  bool get aiSending => ai.sending;

  List<TaskItem> get tasks => taskQueue.tasks;
  QueueSummary get queueSummary => taskQueue.summary;

  GitStatusResult? get currentGitStatus => git.status;
  GitBranchListResult? get gitBranches => git.branches;
  GitDiffResult? get currentGitDiff => git.diff;
  GitLogResult? get currentGitLog => git.log;

  Future<void> initialize() async {
    _version = await _versionLoader();
    notifyListeners();
  }

  Future<void> bindWorkspace(String workspacePath) async {
    final previousWorkspace = _workspacePath;
    _lastError = null;
    try {
      await logger.bindWorkspace(workspacePath);
      await taskQueue.bindWorkspace(workspacePath);
      await git.bindWorkspace(workspacePath);
      await ai.stopSession(clearMessages: true, allowMissing: true);
      _workspacePath = workspacePath;
      if (settings.queueAutoStart) {
        await taskQueue.startQueue(maxConcurrent: settings.maxConcurrent);
      }
      notifyListeners();
    } catch (error, stackTrace) {
      try {
        if (previousWorkspace == null) {
          await taskQueue.reset();
          await git.reset();
          await logger.unbind();
        } else {
          await logger.bindWorkspace(previousWorkspace);
          await taskQueue.bindWorkspace(previousWorkspace);
          await git.bindWorkspace(previousWorkspace);
        }
      } catch (_) {
        _workspacePath = null;
        _lastError = '工作区服务绑定失败，且无法恢复原服务状态';
        notifyListeners();
        throw const CourierException(
          'SERVICE_ROLLBACK_FAILED',
          '工作区服务绑定失败，且无法恢复原服务状态',
        );
      }
      _workspacePath = previousWorkspace;
      _lastError = error is CourierException ? error.message : '工作区服务绑定失败';
      notifyListeners();
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<AISession> aiStartSession({required String workspacePath}) {
    return ai.startSession(workspacePath: workspacePath);
  }

  Future<AISendMessageResult> aiSendMessage({required String text}) {
    return ai.sendMessage(text);
  }

  Future<AIStopSessionResult?> aiStopSession() {
    return ai.stopSession();
  }

  Future<void> aiSetSessionModel(String modelId) => ai.setSessionModel(modelId);

  AIGetOptionsResult aiGetOptions() => ai.options;

  Future<List<AIModelOption>> refreshAIModels() => ai.refreshModels();

  Future<void> cancelAIGeneration() => ai.cancelGeneration();

  void clearAIMessages() => ai.clearMessages();

  Future<TaskItem> createTask({
    required String title,
    required String sourceType,
    required String markdownContent,
  }) {
    return taskQueue.createTask(
      title: title,
      sourceType: sourceType,
      markdownContent: markdownContent,
    );
  }

  List<TaskItem> listTasks({String status = ''}) {
    return taskQueue.listTasks(status: status);
  }

  TaskItem getTaskDetail(String taskId) => taskQueue.getTaskDetail(taskId);

  Future<String> getTaskLogTail(String taskId) =>
      taskQueue.getTaskLogTail(taskId);

  Future<String> getTaskResult(String taskId) =>
      taskQueue.getTaskResult(taskId);

  Future<DeleteTaskResult> deleteTask(String taskId) =>
      taskQueue.deleteTask(taskId);

  Future<void> cancelTask(String taskId) => taskQueue.cancelTask(taskId);

  Future<void> retryTask(String taskId) => taskQueue.retryTask(taskId);

  Future<QueueControlResult> startQueue() {
    return taskQueue.startQueue(maxConcurrent: settings.maxConcurrent);
  }

  Future<QueueControlResult> pauseQueue() => taskQueue.pauseQueue();

  Future<GitStatusResult> gitStatus(String workspacePath) async {
    _ensureBoundWorkspace(workspacePath);
    return git.refreshStatus();
  }

  Future<GitBranchListResult> gitBranchList(String workspacePath) async {
    _ensureBoundWorkspace(workspacePath);
    return git.refreshBranches();
  }

  Future<GitDiffResult> gitDiff({
    required String workspacePath,
    String? path,
    bool staged = false,
  }) async {
    _ensureBoundWorkspace(workspacePath);
    return git.loadDiff(path: path, staged: staged);
  }

  Future<GitLogResult> gitLog() => git.refreshLog();

  Future<String> gitCommitDetail(String hash) => git.loadCommitDetail(hash);

  Future<void> gitStage(String path) => git.stage(path);

  Future<void> gitUnstage(String path) => git.unstage(path);

  Future<GitCommitResult> gitCommit({
    required String workspacePath,
    required String message,
  }) async {
    _ensureBoundWorkspace(workspacePath);
    return git.commit(message);
  }

  Future<void> gitSwitchBranch(String branch) => git.switchBranch(branch);

  Future<void> refreshAll() async {
    final workspace = _workspacePath;
    if (workspace == null) return;
    await Future.wait([
      git.refreshStatus(),
      git.refreshBranches(),
      git.refreshLog(),
    ]);
    notifyListeners();
  }

  Future<void> reset() async {
    await taskQueue.reset();
    await git.reset();
    await ai.stopSession(clearMessages: true, allowMissing: true);
    await logger.unbind();
    _workspacePath = null;
    _lastError = null;
    notifyListeners();
  }

  Future<void> shutdown() async {
    await taskQueue.shutdown();
    await ai.stopSession(clearMessages: false, allowMissing: true);
    await settings.flush();
    await logger.flush();
  }

  void _ensureBoundWorkspace(String workspacePath) {
    if (_workspacePath == null || workspacePath != _workspacePath) {
      throw const CourierException('WORKSPACE_NOT_BOUND', '服务尚未绑定当前工作区');
    }
  }

  void _relay() => notifyListeners();

  void _handleSettingsChanged() {
    logger.minimumLevel = settings.logLevel;
    notifyListeners();
  }

  static Future<AppVersionInfo> _loadPackageVersion() async {
    final package = await PackageInfo.fromPlatform();
    return AppVersionInfo(
      version: package.version,
      buildNumber: package.buildNumber,
      commit: const String.fromEnvironment('COURIER_BUILD_COMMIT'),
      buildTime: const String.fromEnvironment('COURIER_BUILD_TIME'),
    );
  }

  @override
  void dispose() {
    settings.removeListener(_handleSettingsChanged);
    ai.removeListener(_relay);
    taskQueue.removeListener(_relay);
    git.removeListener(_relay);
    ai.dispose();
    taskQueue.dispose();
    git.dispose();
    super.dispose();
  }
}
