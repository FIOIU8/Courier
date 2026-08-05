// app_logger.dart - Structured workspace-local logging with redaction.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_error.dart';
import 'workspace_directory_guard.dart';

enum AppLogLevel { error, warn, info, debug }

class AppLogger {
  static const int _maxLogBytes = 2 * 1024 * 1024;

  File? _currentFile;
  AppLogLevel minimumLevel;
  Future<void> _pendingWrite = Future<void>.value();

  AppLogger({this.minimumLevel = AppLogLevel.info});

  Future<void> bindWorkspace(String workspacePath) async {
    await flush();
    final directory = await WorkspaceDirectoryGuard.ensureDirectory(
      workspacePath,
      const ['.Courier', 'logs'],
    );
    _currentFile = File(
      '${directory.path}${Platform.pathSeparator}app-log-current.jsonl',
    );
  }

  Future<void> unbind() async {
    await flush();
    _currentFile = null;
  }

  Future<void> error(
    String module,
    String event,
    String message, {
    String? requestId,
    String? errorCode,
  }) {
    return _write(
      AppLogLevel.error,
      module,
      event,
      message,
      requestId: requestId,
      errorCode: errorCode,
    );
  }

  Future<void> warn(
    String module,
    String event,
    String message, {
    String? requestId,
    String? errorCode,
  }) {
    return _write(
      AppLogLevel.warn,
      module,
      event,
      message,
      requestId: requestId,
      errorCode: errorCode,
    );
  }

  Future<void> info(
    String module,
    String event,
    String message, {
    String? requestId,
  }) {
    return _write(
      AppLogLevel.info,
      module,
      event,
      message,
      requestId: requestId,
    );
  }

  Future<void> debug(
    String module,
    String event,
    String message, {
    String? requestId,
  }) {
    return _write(
      AppLogLevel.debug,
      module,
      event,
      message,
      requestId: requestId,
    );
  }

  Future<void> flush() => _pendingWrite;

  File? get currentLogFile => _currentFile;

  Future<void> _write(
    AppLogLevel level,
    String module,
    String event,
    String message, {
    String? requestId,
    String? errorCode,
  }) {
    final targetFile = _currentFile;
    if (level.index > minimumLevel.index || targetFile == null) {
      return Future<void>.value();
    }

    final entry = <String, dynamic>{
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'level': level.name,
      'requestId': requestId,
      'module': module,
      'event': event,
      'message': ErrorSanitizer.redact(message),
      'errorCode': errorCode,
    };

    _pendingWrite = _pendingWrite
        .then((_) async {
          await _rotateIfNeeded(targetFile);
          await targetFile.writeAsString(
            '${jsonEncode(entry)}\n',
            mode: FileMode.append,
            flush: true,
          );
        })
        .catchError((Object _) {
          // Logging must not interrupt user operations.
        });
    return _pendingWrite;
  }

  Future<void> _rotateIfNeeded(File file) async {
    if (!await file.exists() || await file.length() < _maxLogBytes) return;
    final previous = File(
      '${file.parent.path}${Platform.pathSeparator}app-log-previous.jsonl',
    );
    if (await previous.exists()) {
      await previous.delete();
    }
    await file.rename(previous.path);
  }
}
