// courier_core.dart — FFI 绑定层（19 个 Go 导出函数）
//
// 通过 dart:ffi 加载 courier_core.dll，绑定全部导出函数。
// 内存管理：输入用 toNativeUtf8() + malloc.free()，返回用 toDartString() + FreeString()。
// 所有返回 char* 的函数（除 FreeString）均返回 JSON 信封，由 _parseEnvelope 解析。

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'models.dart';

// ============================================================
// 函数签名类型定义
// ============================================================

// --- Native 签名（C 侧） ---

/// C: `void FreeString(char* p)`
typedef _FreeStringNative = Void Function(Pointer<Utf8> p);

/// C: `char* Func(char* input)` — 一进一出
typedef _OneInOneOutNative = Pointer<Utf8> Function(Pointer<Utf8> input);

/// C: `char* Func(void)` — 无参返回字符串
typedef _NoInOneOutNative = Pointer<Utf8> Function();

/// C: `char* Func(char* a, char* b)` — 两进一出
typedef _TwoInOneOutNative = Pointer<Utf8> Function(
    Pointer<Utf8> a, Pointer<Utf8> b);

/// C: `VersionInfo GetCoreVersion(void)` — 无参返回结构体
typedef _GetVersionNative = VersionInfo Function();

// --- Dart 签名（Dart 侧） ---

typedef _FreeStringDart = void Function(Pointer<Utf8> p);
typedef _OneInOneOutDart = Pointer<Utf8> Function(Pointer<Utf8> input);
typedef _NoInOneOutDart = Pointer<Utf8> Function();
typedef _TwoInOneOutDart = Pointer<Utf8> Function(
    Pointer<Utf8> a, Pointer<Utf8> b);
typedef _GetVersionDart = VersionInfo Function();

// ============================================================
// CourierCore — FFI 绑定核心类
// ============================================================

/// CourierCore 封装 courier_core.dll 的全部 FFI 绑定。
///
/// 使用方式：
/// ```dart
/// final core = CourierCore();           // 默认 DLL 路径
/// final core = CourierCore.withPath('/custom/path.dll');
/// final version = core.getCoreVersion(); // → VersionInfo(1.0.0)
/// ```
class CourierCore {
  /// 默认 DLL 路径（与 Go 后端编译输出一致）。
  static const defaultDllPath =
      r'D:\00-Work\03-Code\SoM\Courier\courier_core\courier_core.dll';

  final DynamicLibrary _lib;

  // --- 绑定的 Dart 函数 ---
  late final _FreeStringDart _freeString;
  late final _OneInOneOutDart _aiStartSession;
  late final _OneInOneOutDart _aiSendMessage;
  late final _OneInOneOutDart _aiStopSession;
  late final _NoInOneOutDart _aiGetOptions;
  late final _GetVersionDart _getCoreVersion;
  late final _TwoInOneOutDart _encrypt;
  late final _TwoInOneOutDart _decrypt;
  late final _OneInOneOutDart _gitStatus;
  late final _OneInOneOutDart _gitCommit;
  late final _OneInOneOutDart _gitDiff;
  late final _OneInOneOutDart _gitBranchList;
  late final _OneInOneOutDart _createTask;
  late final _OneInOneOutDart _listTasks;
  late final _OneInOneOutDart _getTaskDetail;
  late final _OneInOneOutDart _deleteTask;
  late final _NoInOneOutDart _getQueueSummary;
  late final _NoInOneOutDart _startQueue;
  late final _NoInOneOutDart _pauseQueue;

  // ============================================================
  // 构造与初始化
  // ============================================================

  /// 使用默认 DLL 路径创建实例。
  CourierCore() : _lib = _openLib(defaultDllPath) {
    _bindFunctions();
  }

  /// 使用自定义 DLL 路径创建实例。
  CourierCore.withPath(String dllPath) : _lib = _openLib(dllPath) {
    _bindFunctions();
  }

  static DynamicLibrary _openLib(String dllPath) {
    if (!File(dllPath).existsSync()) {
      throw CourierException(
        'DLL_NOT_FOUND',
        '找不到 courier_core.dll: $dllPath',
      );
    }
    return DynamicLibrary.open(dllPath);
  }

  void _bindFunctions() {
    _freeString = _lib
        .lookupFunction<_FreeStringNative, _FreeStringDart>('FreeString');
    _aiStartSession = _lib
        .lookupFunction<_OneInOneOutNative, _OneInOneOutDart>('AIStartSession');
    _aiSendMessage = _lib
        .lookupFunction<_OneInOneOutNative, _OneInOneOutDart>('AISendMessage');
    _aiStopSession = _lib
        .lookupFunction<_OneInOneOutNative, _OneInOneOutDart>('AIStopSession');
    _aiGetOptions = _lib
        .lookupFunction<_NoInOneOutNative, _NoInOneOutDart>('AIGetOptions');
    _getCoreVersion = _lib
        .lookupFunction<_GetVersionNative, _GetVersionDart>('GetCoreVersion');
    _encrypt = _lib
        .lookupFunction<_TwoInOneOutNative, _TwoInOneOutDart>('Encrypt');
    _decrypt = _lib
        .lookupFunction<_TwoInOneOutNative, _TwoInOneOutDart>('Decrypt');
    _gitStatus = _lib
        .lookupFunction<_OneInOneOutNative, _OneInOneOutDart>('GitStatus');
    _gitCommit = _lib
        .lookupFunction<_OneInOneOutNative, _OneInOneOutDart>('GitCommit');
    _gitDiff = _lib
        .lookupFunction<_OneInOneOutNative, _OneInOneOutDart>('GitDiff');
    _gitBranchList = _lib
        .lookupFunction<_OneInOneOutNative, _OneInOneOutDart>('GitBranchList');
    _createTask = _lib
        .lookupFunction<_OneInOneOutNative, _OneInOneOutDart>('CreateTask');
    _listTasks = _lib
        .lookupFunction<_OneInOneOutNative, _OneInOneOutDart>('ListTasks');
    _getTaskDetail = _lib
        .lookupFunction<_OneInOneOutNative, _OneInOneOutDart>('GetTaskDetail');
    _deleteTask = _lib
        .lookupFunction<_OneInOneOutNative, _OneInOneOutDart>('DeleteTask');
    _getQueueSummary = _lib
        .lookupFunction<_NoInOneOutNative, _NoInOneOutDart>('GetQueueSummary');
    _startQueue = _lib
        .lookupFunction<_NoInOneOutNative, _NoInOneOutDart>('StartQueue');
    _pauseQueue = _lib
        .lookupFunction<_NoInOneOutNative, _NoInOneOutDart>('PauseQueue');
  }

  // ============================================================
  // 内部工具方法
  // ============================================================

  /// 调用一个 char* → char* 的 FFI 函数，管理内存并返回 JSON 信封。
  FfiResult _callOneIn(_OneInOneOutDart fn, String input) {
    final inputPtr = input.toNativeUtf8();
    try {
      final resultPtr = fn(inputPtr);
      return _extractAndParse(resultPtr);
    } finally {
      malloc.free(inputPtr);
    }
  }

  /// 调用一个无参 → char* 的 FFI 函数，管理内存并返回 JSON 信封。
  FfiResult _callNoIn(_NoInOneOutDart fn) {
    final resultPtr = fn();
    return _extractAndParse(resultPtr);
  }

  /// 调用两个 char* → char* 的 FFI 函数，管理内存并返回 JSON 信封。
  FfiResult _callTwoIn(_TwoInOneOutDart fn, String a, String b) {
    final ptrA = a.toNativeUtf8();
    final ptrB = b.toNativeUtf8();
    try {
      final resultPtr = fn(ptrA, ptrB);
      return _extractAndParse(resultPtr);
    } finally {
      malloc.free(ptrA);
      malloc.free(ptrB);
    }
  }

  /// 提取返回字符串，调用 FreeString 释放 C 内存，然后解析 JSON 信封。
  FfiResult _extractAndParse(Pointer<Utf8> resultPtr) {
    String jsonString;
    try {
      jsonString = resultPtr.toDartString();
    } finally {
      _freeString(resultPtr);
    }
    return _parseEnvelope(jsonString);
  }

  /// 解析 JSON 信封为 FfiResult。
  static FfiResult _parseEnvelope(String jsonString) {
    final json = jsonDecode(jsonString) as Map<String, dynamic>;
    return FfiResult.fromJson(json);
  }

  // ============================================================
  // 核心模块
  // ============================================================

  /// 获取核心库版本（按值返回结构体，无需释放）。
  /// 对应 Go: `GetCoreVersion() VersionInfo`
  VersionInfo getCoreVersion() {
    return _getCoreVersion();
  }

  // ============================================================
  // AI 模块
  // ============================================================

  /// 创建 AI 对话会话。
  /// 输入 JSON: `{workspacePath, providerId, modelId}`
  /// 返回 data: `{sessionId, workspacePath, providerId, modelId, messageCount, createdAt}`
  AISession aiStartSession({
    required String workspacePath,
    String providerId = 'default',
    String modelId = 'default',
  }) {
    final input = jsonEncode({
      'workspacePath': workspacePath,
      'providerId': providerId,
      'modelId': modelId,
    });
    final result = _callOneIn(_aiStartSession, input);
    return AISession.fromJson(result.dataAsMap());
  }

  /// 向 AI 会话发送消息。
  /// 输入 JSON: `{sessionId, text}`
  /// 返回 data: `{sessionId, messageCount, reply}`
  AISendMessageResult aiSendMessage({
    required String sessionId,
    required String text,
  }) {
    final input = jsonEncode({
      'sessionId': sessionId,
      'text': text,
    });
    final result = _callOneIn(_aiSendMessage, input);
    return AISendMessageResult.fromJson(result.dataAsMap());
  }

  /// 停止 AI 会话。
  /// 输入: sessionId 字符串（非 JSON）
  /// 返回 data: `{sessionId, status:"stopped"}`
  AIStopSessionResult aiStopSession(String sessionId) {
    final result = _callOneIn(_aiStopSession, sessionId);
    return AIStopSessionResult.fromJson(result.dataAsMap());
  }

  /// 获取 AI 供应商/模型选项。
  /// 无输入，返回 data: `{providers:[...], thinkingLevels:[...], modes:[...]}`
  AIGetOptionsResult aiGetOptions() {
    final result = _callNoIn(_aiGetOptions);
    return AIGetOptionsResult.fromJson(result.dataAsMap());
  }

  // ============================================================
  // 任务模块
  // ============================================================

  /// 创建任务。
  /// 输入 JSON: `{title, sourceType, markdownContent}`
  /// 返回 data: `{id, title, status, markdownContent, createdAt, updatedAt}`
  TaskItem createTask({
    required String title,
    required String sourceType,
    required String markdownContent,
  }) {
    final input = jsonEncode({
      'title': title,
      'sourceType': sourceType,
      'markdownContent': markdownContent,
    });
    final result = _callOneIn(_createTask, input);
    return TaskItem.fromJson(result.dataAsMap());
  }

  /// 列出任务（可按状态过滤）。
  /// 输入 JSON: `{status}` （status 可选，空或 "all" 表示全部）
  /// 返回 data: `[TaskItem, ...]`
  List<TaskItem> listTasks({String status = ''}) {
    final input = jsonEncode({'status': status});
    final result = _callOneIn(_listTasks, input);
    return result.dataAsList()
        .map((item) => TaskItem.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  /// 获取任务详情。
  /// 输入: taskId 字符串（非 JSON）
  /// 返回 data: `TaskItem`
  TaskItem getTaskDetail(String taskId) {
    final result = _callOneIn(_getTaskDetail, taskId);
    return TaskItem.fromJson(result.dataAsMap());
  }

  /// 删除任务。
  /// 输入: taskId 字符串（非 JSON）
  /// 返回 data: `{taskId, status:"deleted"}`
  DeleteTaskResult deleteTask(String taskId) {
    final result = _callOneIn(_deleteTask, taskId);
    return DeleteTaskResult.fromJson(result.dataAsMap());
  }

  /// 获取队列统计。
  /// 无输入，返回 data: `{total, queued, running, done, failed}`
  QueueSummary getQueueSummary() {
    final result = _callNoIn(_getQueueSummary);
    return QueueSummary.fromJson(result.dataAsMap());
  }

  /// 启动任务队列。
  /// 无输入，返回 data: `{status:"running"}`
  QueueControlResult startQueue() {
    final result = _callNoIn(_startQueue);
    return QueueControlResult.fromJson(result.dataAsMap());
  }

  /// 暂停任务队列。
  /// 无输入，返回 data: `{status:"paused"}`
  QueueControlResult pauseQueue() {
    final result = _callNoIn(_pauseQueue);
    return QueueControlResult.fromJson(result.dataAsMap());
  }

  // ============================================================
  // Git 模块
  // ============================================================

  /// 获取工作区 Git 状态。
  /// 输入 JSON: `{workspacePath}`
  /// 返回 data: `{workspacePath, files:[{status,path}], clean}`
  GitStatusResult gitStatus(String workspacePath) {
    final input = jsonEncode({'workspacePath': workspacePath});
    final result = _callOneIn(_gitStatus, input);
    return GitStatusResult.fromJson(result.dataAsMap());
  }

  /// 提交 Git 变更。
  /// 输入 JSON: `{workspacePath, message, addAll}`
  /// 返回 data: `{output, message}`
  GitCommitResult gitCommit({
    required String workspacePath,
    required String message,
    bool addAll = false,
  }) {
    final input = jsonEncode({
      'workspacePath': workspacePath,
      'message': message,
      'addAll': addAll,
    });
    final result = _callOneIn(_gitCommit, input);
    return GitCommitResult.fromJson(result.dataAsMap());
  }

  /// 获取 Git 差异。
  /// 输入 JSON: `{workspacePath, staged}`
  /// 返回 data: `{diff, staged}`
  GitDiffResult gitDiff({
    required String workspacePath,
    bool staged = false,
  }) {
    final input = jsonEncode({
      'workspacePath': workspacePath,
      'staged': staged,
    });
    final result = _callOneIn(_gitDiff, input);
    return GitDiffResult.fromJson(result.dataAsMap());
  }

  /// 列出本地 Git 分支。
  /// 输入: workspacePath 字符串（非 JSON）
  /// 返回 data: `{branches:["main", ...]}`
  GitBranchListResult gitBranchList(String workspacePath) {
    final result = _callOneIn(_gitBranchList, workspacePath);
    return GitBranchListResult.fromJson(result.dataAsMap());
  }

  // ============================================================
  // 加密模块
  // ============================================================

  /// 加密明文。
  /// 输入: plaintext, key（均为字符串，非 JSON）
  /// 返回 data: Base64 密文字符串
  String encrypt(String plaintext, String key) {
    final result = _callTwoIn(_encrypt, plaintext, key);
    return result.dataAsString();
  }

  /// 解密密文。
  /// 输入: ciphertext, key（均为字符串，非 JSON）
  /// 返回 data: 原文字符串
  String decrypt(String ciphertext, String key) {
    final result = _callTwoIn(_decrypt, ciphertext, key);
    return result.dataAsString();
  }
}
