import 'dart:async';

import 'package:courier_flutter/services/ai_service.dart';
import 'package:courier_flutter/services/app_error.dart';
import 'package:courier_flutter/services/models.dart';
import 'package:courier_flutter/services/secure_storage_service.dart';
import 'package:courier_flutter/services/task_service.dart';
import 'package:flutter_test/flutter_test.dart';

class MemoryCredentialStore implements CredentialStore {
  final Map<String, String> values = {};

  @override
  Future<bool> containsKey(String key) async => values.containsKey(key);

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

class FakeAIProviderClient implements AIProviderClient {
  @override
  final String id;
  @override
  final String displayName;
  List<AIModelOption> models;
  List<String> chunks;
  Object? streamError;
  Completer<void>? release;
  bool completeReleaseOnCancel;
  final Completer<void> requestStarted = Completer<void>();
  final List<AIProviderRequest> requests = [];
  final Set<String> cancelledRequestIds = {};
  bool disposed = false;

  FakeAIProviderClient({
    this.id = 'openai',
    this.displayName = 'OpenAI',
    this.models = const [],
    this.chunks = const [],
    this.streamError,
    this.release,
    this.completeReleaseOnCancel = true,
  });

  @override
  Future<void> cancel(String requestId) async {
    cancelledRequestIds.add(requestId);
    final gate = release;
    if (completeReleaseOnCancel && gate != null && !gate.isCompleted) {
      gate.complete();
    }
  }

  @override
  void dispose() {
    disposed = true;
  }

  @override
  Future<List<AIModelOption>> listModels(String apiKey) async => models;

  @override
  Stream<String> sendMessageStream(AIProviderRequest request) async* {
    requests.add(request);
    if (!requestStarted.isCompleted) requestStarted.complete();
    final gate = release;
    if (gate != null) await gate.future;
    if (cancelledRequestIds.contains(request.requestId)) {
      throw const CourierException('REQUEST_CANCELLED', 'AI 请求已取消');
    }
    for (final chunk in chunks) {
      yield chunk;
    }
    final error = streamError;
    if (error != null) throw error;
  }
}

class ControllableTaskExecutor implements TaskExecutor {
  final String output;
  final Completer<void>? release;
  final Completer<void> started = Completer<void>();
  final Set<String> cancelledTaskIds = {};
  int executionCount = 0;

  ControllableTaskExecutor({this.output = 'task output', this.release});

  @override
  Future<void> cancel(String taskId) async {
    cancelledTaskIds.add(taskId);
    final gate = release;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  Future<TaskExecutionResult> execute(
    TaskItem task, {
    required String workspacePath,
    required TaskCancellationToken cancellationToken,
    required void Function(double progress) onProgress,
    required void Function(String event) onEvent,
  }) async {
    executionCount++;
    if (!started.isCompleted) started.complete();
    onEvent('executor started');
    onProgress(0.5);
    final gate = release;
    if (gate != null) await gate.future;
    cancellationToken.throwIfCancelled();
    onProgress(1);
    return TaskExecutionResult(output: output);
  }
}

Matcher throwsCourierCode(String code) {
  return throwsA(
    isA<CourierException>().having((error) => error.code, 'code', code),
  );
}

Future<void> waitForCondition(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Condition was not met before timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

String generatedCredential() {
  return List<String>.generate(
    48,
    (index) => String.fromCharCode(65 + (index % 26)),
    growable: false,
  ).join();
}
