import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

class RecordingHttpClient extends Fake implements HttpClient {
  final List<RecordingHttpClientRequest> requests = [];
  final List<HttpClientResponse> _responses;
  bool closed = false;

  RecordingHttpClient({required List<HttpClientResponse> responses})
    : _responses = [...responses];

  @override
  set connectionTimeout(Duration? value) {}

  @override
  set idleTimeout(Duration value) {}

  @override
  Future<HttpClientRequest> getUrl(Uri url) => _open('GET', url);

  @override
  Future<HttpClientRequest> postUrl(Uri url) => _open('POST', url);

  Future<HttpClientRequest> _open(String method, Uri url) async {
    if (_responses.isEmpty) {
      throw StateError('No HTTP response configured');
    }
    final request = RecordingHttpClientRequest(
      method: method,
      uri: url,
      response: _responses.removeAt(0),
    );
    requests.add(request);
    return request;
  }

  @override
  void close({bool force = false}) {
    closed = true;
  }
}

class RecordingHttpClientRequest extends Fake implements HttpClientRequest {
  @override
  final String method;
  @override
  final Uri uri;
  final HttpClientResponse response;
  final RecordingHttpHeaders recordedHeaders = RecordingHttpHeaders();
  final StringBuffer body = StringBuffer();
  bool aborted = false;

  RecordingHttpClientRequest({
    required this.method,
    required this.uri,
    required this.response,
  });

  @override
  HttpHeaders get headers => recordedHeaders;

  @override
  void write(Object? object) {
    body.write(object);
  }

  @override
  Future<HttpClientResponse> close() async => response;

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    aborted = true;
  }
}

class RecordingHttpHeaders extends Fake implements HttpHeaders {
  final Map<String, List<String>> values = {};

  @override
  set contentType(ContentType? value) {
    if (value == null) {
      values.remove(HttpHeaders.contentTypeHeader);
      return;
    }
    set(HttpHeaders.contentTypeHeader, value.toString());
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = [value.toString()];
  }

  @override
  String? value(String name) {
    final entries = values[name.toLowerCase()];
    if (entries == null || entries.isEmpty) return null;
    return entries.join(',');
  }
}

class StubHttpClientResponse extends Fake implements HttpClientResponse {
  @override
  final int statusCode;
  @override
  final HttpHeaders headers;
  final Stream<List<int>> _body;

  StubHttpClientResponse({
    this.statusCode = HttpStatus.ok,
    String body = '',
    HttpHeaders? headers,
  }) : headers = headers ?? RecordingHttpHeaders(),
       _body = Stream<List<int>>.value(utf8.encode(body));

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _body.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  Stream<S> transform<S>(StreamTransformer<List<int>, S> streamTransformer) {
    return _body.transform(streamTransformer);
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
