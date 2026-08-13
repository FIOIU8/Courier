// models.dart - Pure Dart application models.

class AppVersionInfo {
  final String version;
  final String buildNumber;
  final String commit;
  final String buildTime;

  const AppVersionInfo({
    required this.version,
    required this.buildNumber,
    required this.commit,
    required this.buildTime,
  });

  String get displayVersion =>
      buildNumber.isEmpty ? version : '$version+$buildNumber';
}

class AISession {
  final String sessionId;
  final String workspacePath;
  final String providerId;
  final String modelId;
  final int messageCount;
  final String createdAt;

  const AISession({
    required this.sessionId,
    required this.workspacePath,
    required this.providerId,
    required this.modelId,
    required this.messageCount,
    required this.createdAt,
  });

  AISession copyWith({String? modelId, int? messageCount}) {
    return AISession(
      sessionId: sessionId,
      workspacePath: workspacePath,
      providerId: providerId,
      modelId: modelId ?? this.modelId,
      messageCount: messageCount ?? this.messageCount,
      createdAt: createdAt,
    );
  }
}

class AIMessage {
  final String id;
  final String role;
  final String text;
  final DateTime timestamp;
  final bool streaming;
  final String? requestId;

  const AIMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.timestamp,
    this.streaming = false,
    this.requestId,
  });

  bool get isUser => role == 'user';

  AIMessage copyWith({String? text, bool? streaming, String? requestId}) {
    return AIMessage(
      id: id,
      role: role,
      text: text ?? this.text,
      timestamp: timestamp,
      streaming: streaming ?? this.streaming,
      requestId: requestId ?? this.requestId,
    );
  }
}

class AIStopSessionResult {
  final String sessionId;
  final String status;

  const AIStopSessionResult({required this.sessionId, required this.status});
}

class AIOptionItem {
  final String value;
  final String label;

  const AIOptionItem({required this.value, required this.label});
}

class AIModelOption {
  final String id;
  final String displayName;

  const AIModelOption({required this.id, required this.displayName});
}

enum ProviderProtocol { openaiCompatible, anthropicCompatible }

/// 应用 UI 样式（外观主题）。
enum AppUiStyle {
  /// Material 3 玻璃拟态风格（默认）
  material3,

  /// VSCode 暗色扁平风格
  vscode,
}

/// AI 请求方式：决定聊天端点、请求体与流式解析格式。
/// 中转站通常同时支持 [responses] 与 [chatCompletions]。
enum AIRequestMode {
  /// OpenAI 官方标准 Chat Completions 接口（兼容性最广）
  chatCompletions,

  /// OpenAI Responses API（官方 OpenAI 与多数中转站支持）
  responses,

  /// Anthropic Messages API（x-api-key 认证）
  anthropic,
}

class CustomAIProvider {
  static final RegExp idPattern = RegExp(r'^[a-z][a-z0-9_-]{1,31}$');
  static final RegExp _controlCharacters = RegExp(r'[\x00-\x1f\x7f]');
  static const int maxDisplayNameLength = 80;
  static const int maxBaseUrlLength = 2048;

  final String id;
  final String displayName;
  final String baseUrl;
  final ProviderProtocol protocol;
  final bool supportsMillionContext;
  final DateTime createdAt;

  factory CustomAIProvider({
    required String id,
    required String displayName,
    required String baseUrl,
    required ProviderProtocol protocol,
    required bool supportsMillionContext,
    required DateTime createdAt,
  }) {
    final normalizedId = id.trim().toLowerCase();
    if (!idPattern.hasMatch(normalizedId)) {
      throw const FormatException('Invalid provider id');
    }

    final normalizedDisplayName = displayName.trim();
    if (normalizedDisplayName.isEmpty ||
        normalizedDisplayName.length > maxDisplayNameLength ||
        _controlCharacters.hasMatch(normalizedDisplayName)) {
      throw const FormatException('Invalid provider display name');
    }

    return CustomAIProvider._(
      id: normalizedId,
      displayName: normalizedDisplayName,
      baseUrl: normalizeBaseUrl(baseUrl),
      protocol: protocol,
      supportsMillionContext: supportsMillionContext,
      createdAt: createdAt.toUtc(),
    );
  }

  const CustomAIProvider._({
    required this.id,
    required this.displayName,
    required this.baseUrl,
    required this.protocol,
    required this.supportsMillionContext,
    required this.createdAt,
  });

  factory CustomAIProvider.fromJson(Map<String, dynamic> json) {
    final protocolName = _requiredString(json, 'protocol');
    final protocol = ProviderProtocol.values
        .where((candidate) => candidate.name == protocolName)
        .firstOrNull;
    if (protocol == null) {
      throw const FormatException('Invalid provider protocol');
    }

    final supportsMillionContext = json['supportsMillionContext'];
    if (supportsMillionContext is! bool) {
      throw const FormatException('Invalid million context setting');
    }

    final createdAt = DateTime.tryParse(_requiredString(json, 'createdAt'));
    if (createdAt == null) {
      throw const FormatException('Invalid provider creation time');
    }

    return CustomAIProvider(
      id: _requiredString(json, 'id'),
      displayName: _requiredString(json, 'displayName'),
      baseUrl: _requiredString(json, 'baseUrl'),
      protocol: protocol,
      supportsMillionContext: supportsMillionContext,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'displayName': displayName,
    'baseUrl': baseUrl,
    'protocol': protocol.name,
    'supportsMillionContext': supportsMillionContext,
    'createdAt': createdAt.toIso8601String(),
  };

  CustomAIProvider copyWith({
    String? displayName,
    String? baseUrl,
    ProviderProtocol? protocol,
    bool? supportsMillionContext,
  }) {
    return CustomAIProvider(
      id: id,
      displayName: displayName ?? this.displayName,
      baseUrl: baseUrl ?? this.baseUrl,
      protocol: protocol ?? this.protocol,
      supportsMillionContext:
          supportsMillionContext ?? this.supportsMillionContext,
      createdAt: createdAt,
    );
  }

  static String normalizeBaseUrl(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty || normalized.length > maxBaseUrlLength) {
      throw const FormatException('Invalid provider base URL length');
    }

    final uri = Uri.tryParse(normalized);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      throw const FormatException('Invalid provider base URL');
    }

    final path = uri.path.endsWith('/') ? uri.path : '${uri.path}/';
    return uri.replace(path: path).toString();
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is CustomAIProvider &&
            id == other.id &&
            displayName == other.displayName &&
            baseUrl == other.baseUrl &&
            protocol == other.protocol &&
            supportsMillionContext == other.supportsMillionContext &&
            createdAt == other.createdAt;
  }

  @override
  int get hashCode => Object.hash(
    id,
    displayName,
    baseUrl,
    protocol,
    supportsMillionContext,
    createdAt,
  );
}

class AIProviderOption {
  final String id;
  final String displayName;
  final List<AIModelOption> models;
  final bool supportsMillionContext;

  const AIProviderOption({
    required this.id,
    required this.displayName,
    this.models = const [],
    this.supportsMillionContext = false,
  });
}

class AIGetOptionsResult {
  final List<AIProviderOption> providers;
  final List<AIOptionItem> thinkingLevels;
  final List<AIOptionItem> modes;

  const AIGetOptionsResult({
    required this.providers,
    required this.thinkingLevels,
    required this.modes,
  });
}

class AISendMessageResult {
  final String sessionId;
  final int messageCount;
  final String reply;

  const AISendMessageResult({
    required this.sessionId,
    required this.messageCount,
    required this.reply,
  });
}

class TaskStatus {
  static const queued = 'queued';
  static const running = 'running';
  static const succeeded = 'succeeded';
  static const failed = 'failed';
  static const cancelling = 'cancelling';
  static const cancelled = 'cancelled';

  static const values = {
    queued,
    running,
    succeeded,
    failed,
    cancelling,
    cancelled,
  };

  static bool isValid(String status) => values.contains(status);

  static bool isTerminal(String status) =>
      status == succeeded || status == failed || status == cancelled;

  TaskStatus._();
}

/// Codex 执行权限级别：控制 Codex CLI 可执行的操作范围。
class TaskPermission {
  /// 仅读取：Codex 只能读取文件，不能写入/创建/删除
  static const readOnly = 'readOnly';

  /// 读取与写入：Codex 可以读取、写入和删除文件
  static const readWrite = 'readWrite';

  /// YOLO：自动同意所有操作（危险，需用户确认）
  static const yolo = 'yolo';

  static const values = {readOnly, readWrite, yolo};

  static bool isValid(String permission) => values.contains(permission);

  /// 权限级别的中文显示标签
  static String label(String permission) => switch (permission) {
    readOnly => '仅读取',
    readWrite => '读取与写入',
    yolo => 'YOLO（全自动）',
    _ => permission,
  };

  /// 权限级别的说明文字
  static String description(String permission) => switch (permission) {
    readOnly => 'Codex 只能读取文件，不会修改工作区',
    readWrite => 'Codex 可以读取、写入和删除文件',
    yolo => '危险：Codex 将自动同意所有操作，可能导致不可逆的数据丢失',
    _ => '',
  };

  /// YOLO 模式的警告弹窗内容
  static const yoloWarning = 'YOLO 模式下 Codex 将自动同意所有操作（包括删除、'
      '覆盖文件等），可能导致不可逆的数据丢失。\n\n确定要继续吗？';

  TaskPermission._();
}

/// 任务执行器类型：决定任务由哪个后端执行。
class TaskExecutorType {
  /// AI 助手执行（通过配置的 AI 供应商 API）
  static const ai = 'ai';

  /// Codex CLI 执行（通过本地 codex 命令行工具）
  static const codex = 'codex';

  static const values = {ai, codex};

  static bool isValid(String type) => values.contains(type);

  static String label(String type) => switch (type) {
    ai => 'AI 助手',
    codex => 'Codex CLI',
    _ => type,
  };

  TaskExecutorType._();
}

const _unset = Object();

class TaskItem {
  final String id;
  final String title;
  final String sourceType;
  final String executorType;
  final String permission;
  final String status;
  final bool reviewed;
  final String markdownContent;
  final double progress;
  final String createdAt;
  final String updatedAt;
  final String? startedAt;
  final String? finishedAt;
  final String? errorCode;
  final String? errorMessage;
  final int attempt;
  final int maxAttempts;
  final String? resultPath;

  const TaskItem({
    required this.id,
    required this.title,
    required this.sourceType,
    this.executorType = TaskExecutorType.ai,
    this.permission = TaskPermission.readOnly,
    required this.status,
    this.reviewed = false,
    required this.markdownContent,
    required this.progress,
    required this.createdAt,
    required this.updatedAt,
    this.startedAt,
    this.finishedAt,
    this.errorCode,
    this.errorMessage,
    required this.attempt,
    required this.maxAttempts,
    this.resultPath,
  });

  factory TaskItem.fromJson(Map<String, dynamic> json) {
    final status = json['status'];
    if (status is! String || !TaskStatus.isValid(status)) {
      throw const FormatException('Invalid task status');
    }
    final executorType = json['executorType'] as String?;
    if (executorType != null && !TaskExecutorType.isValid(executorType)) {
      throw const FormatException('Invalid task executor type');
    }
    final permission = json['permission'] as String?;
    if (permission != null && !TaskPermission.isValid(permission)) {
      throw const FormatException('Invalid task permission');
    }
    final reviewed = json['reviewed'];
    if (reviewed != null && reviewed is! bool) {
      throw const FormatException('Invalid task reviewed flag');
    }
    return TaskItem(
      id: _requiredString(json, 'id'),
      title: _requiredString(json, 'title'),
      sourceType: _requiredString(json, 'sourceType'),
      executorType: executorType ?? TaskExecutorType.ai,
      permission: permission ?? TaskPermission.readOnly,
      status: status,
      reviewed: reviewed ?? false,
      markdownContent: _requiredString(json, 'markdownContent'),
      progress: _requiredNumber(json, 'progress').clamp(0.0, 1.0).toDouble(),
      createdAt: _requiredString(json, 'createdAt'),
      updatedAt: _requiredString(json, 'updatedAt'),
      startedAt: json['startedAt'] as String?,
      finishedAt: json['finishedAt'] as String?,
      errorCode: json['errorCode'] as String?,
      errorMessage: json['errorMessage'] as String?,
      attempt: _requiredNumber(json, 'attempt').toInt(),
      maxAttempts: _requiredNumber(json, 'maxAttempts').toInt(),
      resultPath: json['resultPath'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'sourceType': sourceType,
    'executorType': executorType,
    'permission': permission,
    'status': status,
    'reviewed': reviewed,
    'markdownContent': markdownContent,
    'progress': progress,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'startedAt': startedAt,
    'finishedAt': finishedAt,
    'errorCode': errorCode,
    'errorMessage': errorMessage,
    'attempt': attempt,
    'maxAttempts': maxAttempts,
    'resultPath': resultPath,
  };

  TaskItem copyWith({
    String? title,
    String? sourceType,
    String? executorType,
    String? permission,
    String? status,
    bool? reviewed,
    double? progress,
    String? updatedAt,
    Object? startedAt = _unset,
    Object? finishedAt = _unset,
    Object? errorCode = _unset,
    Object? errorMessage = _unset,
    int? attempt,
    int? maxAttempts,
    Object? resultPath = _unset,
  }) {
    return TaskItem(
      id: id,
      title: title ?? this.title,
      sourceType: sourceType ?? this.sourceType,
      executorType: executorType ?? this.executorType,
      permission: permission ?? this.permission,
      status: status ?? this.status,
      reviewed: reviewed ?? this.reviewed,
      markdownContent: markdownContent,
      progress: (progress ?? this.progress).clamp(0.0, 1.0),
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      startedAt: identical(startedAt, _unset)
          ? this.startedAt
          : startedAt as String?,
      finishedAt: identical(finishedAt, _unset)
          ? this.finishedAt
          : finishedAt as String?,
      errorCode: identical(errorCode, _unset)
          ? this.errorCode
          : errorCode as String?,
      errorMessage: identical(errorMessage, _unset)
          ? this.errorMessage
          : errorMessage as String?,
      attempt: attempt ?? this.attempt,
      maxAttempts: maxAttempts ?? this.maxAttempts,
      resultPath: identical(resultPath, _unset)
          ? this.resultPath
          : resultPath as String?,
    );
  }
}

class DeleteTaskResult {
  final String taskId;
  final String status;

  const DeleteTaskResult({required this.taskId, required this.status});
}

class QueueSummary {
  final int total;
  final int queued;
  final int running;
  final int succeeded;
  final int failed;
  final int cancelled;

  const QueueSummary({
    required this.total,
    required this.queued,
    required this.running,
    required this.succeeded,
    required this.failed,
    required this.cancelled,
  });

  int get done => succeeded;
}

class QueueControlResult {
  final String status;

  const QueueControlResult({required this.status});
}

class GitStatusFile {
  final String indexStatus;
  final String workTreeStatus;
  final String path;

  const GitStatusFile({
    required this.indexStatus,
    required this.workTreeStatus,
    required this.path,
  });

  String get status => '$indexStatus$workTreeStatus';
  bool get staged => indexStatus.trim().isNotEmpty && indexStatus != '?';
  bool get untracked => indexStatus == '?' && workTreeStatus == '?';
}

class GitStatusResult {
  final String workspacePath;
  final List<GitStatusFile> files;
  final bool clean;
  final String currentBranch;

  const GitStatusResult({
    required this.workspacePath,
    required this.files,
    required this.clean,
    required this.currentBranch,
  });
}

class GitCommitResult {
  final String output;
  final String message;

  const GitCommitResult({required this.output, required this.message});
}

class GitCommitEntry {
  final String shortHash;
  final String fullHash;
  final String subject;
  final String authorName;
  final String authorEmail;
  final String authorDate;
  final bool isHead;

  const GitCommitEntry({
    required this.shortHash,
    required this.fullHash,
    required this.subject,
    required this.authorName,
    required this.authorEmail,
    required this.authorDate,
    required this.isHead,
  });
}

class GitLogResult {
  final String workspacePath;
  final List<GitCommitEntry> entries;
  final bool truncated;

  const GitLogResult({
    required this.workspacePath,
    required this.entries,
    required this.truncated,
  });
}

class GitDiffResult {
  final String diff;
  final bool staged;
  final String? path;
  final bool truncated;

  const GitDiffResult({
    required this.diff,
    required this.staged,
    this.path,
    this.truncated = false,
  });
}

class GitBranchListResult {
  final List<String> branches;
  final String current;

  const GitBranchListResult({required this.branches, required this.current});
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('Invalid $key');
  }
  return value;
}

num _requiredNumber(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! num) {
    throw FormatException('Invalid $key');
  }
  return value;
}
