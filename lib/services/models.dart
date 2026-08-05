// models.dart — Dart 数据模型（与 Go 后端 JSON 一一对应）
//
// 所有模型类使用 fromJson 工厂构造，字段名与 Go 侧 json tag 完全一致。
// 异常统一使用 CourierException（含 code 和 message getter）。

import 'dart:ffi';

// ============================================================
// FFI 基础类型
// ============================================================

/// VersionInfo — Go 侧按值返回的版本结构体（FFI Struct）。
/// 对应 Go: `typedef struct { int major; int minor; int patch; } VersionInfo`
final class VersionInfo extends Struct {
  @Int32()
  external int major;

  @Int32()
  external int minor;

  @Int32()
  external int patch;

  String get versionString => '$major.$minor.$patch';

  @override
  String toString() => 'VersionInfo($versionString)';
}

// ============================================================
// 异常
// ============================================================

/// CourierException — 所有 FFI 调用失败时抛出的异常。
/// error 字段格式为 "ERROR_CODE: 描述信息"，拆分为 code 和 message。
class CourierException implements Exception {
  final String code;
  final String message;

  const CourierException(this.code, this.message);

  /// 从 FFI 信封的 error 字段解析（格式 "CODE: message"）。
  factory CourierException.fromErrorString(String error) {
    final idx = error.indexOf(': ');
    if (idx == -1) {
      return CourierException('UNKNOWN', error);
    }
    return CourierException(
      error.substring(0, idx),
      error.substring(idx + 2),
    );
  }

  @override
  String toString() => 'CourierException($code): $message';
}

// ============================================================
// FFI 信封
// ============================================================

/// FfiResult — Go 侧 ffiResult 结构体的 Dart 映射。
/// 成功时 ok=true, data 为任意类型；失败时 ok=false, error 为错误信息。
class FfiResult {
  final bool ok;
  final dynamic data;
  final String error;

  const FfiResult({required this.ok, this.data, this.error = ''});

  factory FfiResult.fromJson(Map<String, dynamic> json) {
    return FfiResult(
      ok: json['ok'] as bool,
      data: json['data'],
      error: (json['error'] as String?) ?? '',
    );
  }

  /// 将 data 当作 Map 返回，ok=false 时抛 CourierException。
  Map<String, dynamic> dataAsMap() {
    if (!ok) {
      throw CourierException.fromErrorString(error);
    }
    return data as Map<String, dynamic>;
  }

  /// 将 data 当作 List 返回，ok=false 时抛 CourierException。
  List<dynamic> dataAsList() {
    if (!ok) {
      throw CourierException.fromErrorString(error);
    }
    return data as List<dynamic>;
  }

  /// 将 data 当作 String 返回，ok=false 时抛 CourierException。
  String dataAsString() {
    if (!ok) {
      throw CourierException.fromErrorString(error);
    }
    return data as String;
  }

  @override
  String toString() => ok ? 'FfiResult(ok, data=$data)' : 'FfiResult(error=$error)';
}

// ============================================================
// AI 模块模型
// ============================================================

/// AISession — AI 对话会话。
/// 对应 Go: aiSession
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

  factory AISession.fromJson(Map<String, dynamic> json) {
    return AISession(
      sessionId: json['sessionId'] as String,
      workspacePath: json['workspacePath'] as String,
      providerId: json['providerId'] as String,
      modelId: json['modelId'] as String,
      messageCount: (json['messageCount'] as num).toInt(),
      createdAt: json['createdAt'] as String,
    );
  }

  @override
  String toString() => 'AISession(id=$sessionId, provider=$providerId, model=$modelId, msgs=$messageCount)';
}

/// AISendMessageResult — 发送消息后的返回。
/// 对应 Go: AISendMessage 的 data
class AISendMessageResult {
  final String sessionId;
  final int messageCount;
  final String reply;

  const AISendMessageResult({
    required this.sessionId,
    required this.messageCount,
    required this.reply,
  });

  factory AISendMessageResult.fromJson(Map<String, dynamic> json) {
    return AISendMessageResult(
      sessionId: json['sessionId'] as String,
      messageCount: (json['messageCount'] as num).toInt(),
      reply: json['reply'] as String,
    );
  }

  @override
  String toString() => 'AISendMessageResult(sessionId=$sessionId, count=$messageCount)';
}

/// AIStopSessionResult — 停止会话的返回。
/// 对应 Go: AIStopSession 的 data
class AIStopSessionResult {
  final String sessionId;
  final String status;

  const AIStopSessionResult({
    required this.sessionId,
    required this.status,
  });

  factory AIStopSessionResult.fromJson(Map<String, dynamic> json) {
    return AIStopSessionResult(
      sessionId: json['sessionId'] as String,
      status: json['status'] as String,
    );
  }
}

/// AIOptionItem — 通用键值对选项（thinkingLevels / modes）。
class AIOptionItem {
  final String value;
  final String label;

  const AIOptionItem({required this.value, required this.label});

  factory AIOptionItem.fromJson(Map<String, dynamic> json) {
    return AIOptionItem(
      value: json['value'] as String,
      label: json['label'] as String,
    );
  }
}

/// AIModelOption — 单个模型选项。
class AIModelOption {
  final String id;
  final String displayName;

  const AIModelOption({required this.id, required this.displayName});

  factory AIModelOption.fromJson(Map<String, dynamic> json) {
    return AIModelOption(
      id: json['id'] as String,
      displayName: json['displayName'] as String,
    );
  }
}

/// AIProviderOption — 单个供应商选项（含模型列表）。
class AIProviderOption {
  final String id;
  final String displayName;
  final List<AIModelOption> models;

  const AIProviderOption({
    required this.id,
    required this.displayName,
    required this.models,
  });

  factory AIProviderOption.fromJson(Map<String, dynamic> json) {
    return AIProviderOption(
      id: json['id'] as String,
      displayName: json['displayName'] as String,
      models: (json['models'] as List<dynamic>)
          .map((m) => AIModelOption.fromJson(m as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// AIGetOptionsResult — AIGetOptions 返回的完整选项集。
class AIGetOptionsResult {
  final List<AIProviderOption> providers;
  final List<AIOptionItem> thinkingLevels;
  final List<AIOptionItem> modes;

  const AIGetOptionsResult({
    required this.providers,
    required this.thinkingLevels,
    required this.modes,
  });

  factory AIGetOptionsResult.fromJson(Map<String, dynamic> json) {
    return AIGetOptionsResult(
      providers: (json['providers'] as List<dynamic>)
          .map((p) => AIProviderOption.fromJson(p as Map<String, dynamic>))
          .toList(),
      thinkingLevels: (json['thinkingLevels'] as List<dynamic>)
          .map((t) => AIOptionItem.fromJson(t as Map<String, dynamic>))
          .toList(),
      modes: (json['modes'] as List<dynamic>)
          .map((m) => AIOptionItem.fromJson(m as Map<String, dynamic>))
          .toList(),
    );
  }
}

// ============================================================
// 任务模块模型
// ============================================================

/// TaskStatus — 任务状态常量。
class TaskStatus {
  static const queued = 'queued';
  static const running = 'running';
  static const done = 'done';
  static const failed = 'failed';

  static bool isValid(String status) {
    return status == queued || status == running || status == done || status == failed;
  }

  TaskStatus._();
}

/// TaskItem — 单个任务。
/// 对应 Go: taskItem
class TaskItem {
  final String id;
  final String title;
  final String status;
  final String markdownContent;
  final String createdAt;
  final String updatedAt;

  const TaskItem({
    required this.id,
    required this.title,
    required this.status,
    required this.markdownContent,
    required this.createdAt,
    required this.updatedAt,
  });

  factory TaskItem.fromJson(Map<String, dynamic> json) {
    return TaskItem(
      id: json['id'] as String,
      title: json['title'] as String,
      status: json['status'] as String,
      markdownContent: json['markdownContent'] as String,
      createdAt: json['createdAt'] as String,
      updatedAt: json['updatedAt'] as String,
    );
  }

  @override
  String toString() => 'TaskItem(id=$id, title=$title, status=$status)';
}

/// DeleteTaskResult — 删除任务的返回。
class DeleteTaskResult {
  final String taskId;
  final String status;

  const DeleteTaskResult({required this.taskId, required this.status});

  factory DeleteTaskResult.fromJson(Map<String, dynamic> json) {
    return DeleteTaskResult(
      taskId: json['taskId'] as String,
      status: json['status'] as String,
    );
  }
}

/// QueueSummary — 队列统计。
/// 对应 Go: GetQueueSummary 的 data
class QueueSummary {
  final int total;
  final int queued;
  final int running;
  final int done;
  final int failed;

  const QueueSummary({
    required this.total,
    required this.queued,
    required this.running,
    required this.done,
    required this.failed,
  });

  factory QueueSummary.fromJson(Map<String, dynamic> json) {
    return QueueSummary(
      total: (json['total'] as num).toInt(),
      queued: (json['queued'] as num).toInt(),
      running: (json['running'] as num).toInt(),
      done: (json['done'] as num).toInt(),
      failed: (json['failed'] as num).toInt(),
    );
  }

  @override
  String toString() => 'QueueSummary(total=$total, queued=$queued, running=$running, done=$done, failed=$failed)';
}

/// QueueControlResult — 队列控制（StartQueue / PauseQueue）的返回。
class QueueControlResult {
  final String status;

  const QueueControlResult({required this.status});

  factory QueueControlResult.fromJson(Map<String, dynamic> json) {
    return QueueControlResult(status: json['status'] as String);
  }
}

// ============================================================
// Git 模块模型
// ============================================================

/// GitStatusFile — 单个文件的 Git 状态。
class GitStatusFile {
  final String status;
  final String path;

  const GitStatusFile({required this.status, required this.path});

  factory GitStatusFile.fromJson(Map<String, dynamic> json) {
    return GitStatusFile(
      status: json['status'] as String,
      path: json['path'] as String,
    );
  }
}

/// GitStatusResult — GitStatus 的返回。
class GitStatusResult {
  final String workspacePath;
  final List<GitStatusFile> files;
  final bool clean;

  const GitStatusResult({
    required this.workspacePath,
    required this.files,
    required this.clean,
  });

  factory GitStatusResult.fromJson(Map<String, dynamic> json) {
    return GitStatusResult(
      workspacePath: json['workspacePath'] as String,
      files: (json['files'] as List<dynamic>)
          .map((f) => GitStatusFile.fromJson(f as Map<String, dynamic>))
          .toList(),
      clean: json['clean'] as bool,
    );
  }
}

/// GitCommitResult — GitCommit 的返回。
class GitCommitResult {
  final String output;
  final String message;

  const GitCommitResult({required this.output, required this.message});

  factory GitCommitResult.fromJson(Map<String, dynamic> json) {
    return GitCommitResult(
      output: json['output'] as String,
      message: json['message'] as String,
    );
  }
}

/// GitDiffResult — GitDiff 的返回。
class GitDiffResult {
  final String diff;
  final bool staged;

  const GitDiffResult({required this.diff, required this.staged});

  factory GitDiffResult.fromJson(Map<String, dynamic> json) {
    return GitDiffResult(
      diff: json['diff'] as String,
      staged: json['staged'] as bool,
    );
  }
}

/// GitBranchListResult — GitBranchList 的返回。
class GitBranchListResult {
  final List<String> branches;

  const GitBranchListResult({required this.branches});

  factory GitBranchListResult.fromJson(Map<String, dynamic> json) {
    return GitBranchListResult(
      branches: (json['branches'] as List<dynamic>).cast<String>(),
    );
  }
}
