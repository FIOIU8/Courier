// ai_service.dart - Secure multi-provider streaming AI integration.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'app_error.dart';
import 'app_logger.dart';
import 'id_generator.dart';
import 'models.dart';
import 'secure_storage_service.dart';
import 'settings_state.dart';

class AIConversationMessage {
  final String role;
  final String text;

  const AIConversationMessage({required this.role, required this.text});
}

class AIProviderRequest {
  final String requestId;
  final String modelId;
  final double temperature;
  final int maxTokens;
  final List<AIConversationMessage> messages;
  final String apiKey;

  const AIProviderRequest({
    required this.requestId,
    required this.modelId,
    required this.temperature,
    required this.maxTokens,
    required this.messages,
    required this.apiKey,
  });
}

abstract interface class AIProviderClient {
  String get id;
  String get displayName;

  Future<List<AIModelOption>> listModels(String apiKey);

  Stream<String> sendMessageStream(AIProviderRequest request);

  Future<void> cancel(String requestId);

  void dispose();
}

typedef CustomAIProviderClientFactory =
    AIProviderClient Function(CustomAIProvider provider);

class OfficialAIProviderClient implements AIProviderClient {
  static const Duration _connectionTimeout = Duration(seconds: 20);
  static const Duration _responseTimeout = Duration(seconds: 90);
  static const int _maxErrorBodyBytes = 4096;
  static const int _maxModelBodyBytes = 1024 * 1024;
  static const int _maxAttempts = 3;

  @override
  final String id;
  @override
  final String displayName;
  final Uri baseUri;
  final ProviderProtocol protocol;
  final HttpClient _client;
  final Map<String, HttpClientRequest> _activeRequests = {};
  final Set<String> _cancelledRequests = {};

  OfficialAIProviderClient({
    required this.id,
    required this.displayName,
    required Uri baseUri,
    ProviderProtocol? protocol,
    HttpClient? client,
  }) : baseUri = Uri.parse(CustomAIProvider.normalizeBaseUrl('$baseUri')),
       protocol = protocol ?? _defaultProtocol(id),
       _client = client ?? HttpClient() {
    _client.connectionTimeout = _connectionTimeout;
    _client.idleTimeout = _responseTimeout;
  }

  factory OfficialAIProviderClient.openAI({HttpClient? client}) {
    return OfficialAIProviderClient(
      id: 'openai',
      displayName: 'OpenAI',
      baseUri: Uri.parse('https://api.openai.com/v1/'),
      protocol: ProviderProtocol.openaiCompatible,
      client: client,
    );
  }

  factory OfficialAIProviderClient.anthropic({HttpClient? client}) {
    return OfficialAIProviderClient(
      id: 'anthropic',
      displayName: 'Anthropic',
      baseUri: Uri.parse('https://api.anthropic.com/v1/'),
      protocol: ProviderProtocol.anthropicCompatible,
      client: client,
    );
  }

  @override
  Future<List<AIModelOption>> listModels(String apiKey) async {
    HttpClientRequest? request;
    try {
      request = await _client.getUrl(baseUri.resolve('models'));
      _applyHeaders(request, apiKey, stream: false);
      final response = await request.close().timeout(_responseTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw await _responseException(response);
      }
      final body = await _readTextBody(response, _maxModelBodyBytes);
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic> || decoded['data'] is! List) {
        throw const CourierException(
          'INVALID_PROVIDER_RESPONSE',
          '供应商返回了无法识别的模型列表',
        );
      }
      final models = <AIModelOption>[];
      for (final item in decoded['data'] as List<dynamic>) {
        if (item is! Map<String, dynamic>) continue;
        final modelId = item['id'];
        if (modelId is String && modelId.trim().isNotEmpty) {
          final display = item['display_name'];
          models.add(
            AIModelOption(
              id: modelId,
              displayName: display is String && display.trim().isNotEmpty
                  ? display
                  : modelId,
            ),
          );
        }
      }
      models.sort((a, b) => a.displayName.compareTo(b.displayName));
      return models;
    } on CourierException {
      rethrow;
    } on FormatException {
      throw const CourierException(
        'INVALID_PROVIDER_RESPONSE',
        '供应商返回了无法识别的模型列表',
      );
    } on TimeoutException {
      request?.abort();
      throw const CourierException('PROVIDER_TIMEOUT', '供应商响应超时');
    } on SocketException {
      throw const CourierException('PROVIDER_UNREACHABLE', '无法连接供应商');
    } on HttpException {
      throw const CourierException('PROVIDER_CONNECTION_FAILED', '供应商连接异常');
    }
  }

  @override
  Stream<String> sendMessageStream(AIProviderRequest request) async* {
    CourierException? lastError;
    try {
      for (var attempt = 1; attempt <= _maxAttempts; attempt++) {
        if (_cancelledRequests.contains(request.requestId)) {
          throw const CourierException('REQUEST_CANCELLED', '助手请求已取消');
        }

        HttpClientRequest? httpRequest;
        try {
          httpRequest = await _client.postUrl(
            baseUri.resolve(
              protocol == ProviderProtocol.openaiCompatible
                  ? 'responses'
                  : 'messages',
            ),
          );
          if (_cancelledRequests.contains(request.requestId)) {
            httpRequest.abort();
            throw const CourierException('REQUEST_CANCELLED', '助手请求已取消');
          }
          _activeRequests[request.requestId] = httpRequest;
          _applyHeaders(httpRequest, request.apiKey, stream: true);
          httpRequest.write(jsonEncode(_requestBody(request)));
          final response = await httpRequest.close().timeout(_responseTimeout);

          if (_isRetryable(response.statusCode) && attempt < _maxAttempts) {
            await response.drain<void>();
            await Future<void>.delayed(_retryDelay(response, attempt));
            continue;
          }
          if (response.statusCode < 200 || response.statusCode >= 300) {
            throw await _responseException(response);
          }

          await for (final event in _decodeSse(
            response,
          ).timeout(_responseTimeout)) {
            if (_cancelledRequests.contains(request.requestId)) {
              throw const CourierException('REQUEST_CANCELLED', '助手请求已取消');
            }
            final delta = _extractDelta(event);
            if (delta != null && delta.isNotEmpty) {
              yield delta;
            }
          }
          return;
        } on CourierException {
          rethrow;
        } on FormatException {
          throw const CourierException(
            'INVALID_PROVIDER_RESPONSE',
            '供应商返回了无法识别的数据',
          );
        } on TimeoutException {
          httpRequest?.abort();
          lastError = const CourierException('PROVIDER_TIMEOUT', '供应商响应超时');
          if (attempt >= _maxAttempts) throw lastError;
        } on SocketException {
          lastError = const CourierException('PROVIDER_UNREACHABLE', '无法连接供应商');
          if (attempt >= _maxAttempts) throw lastError;
        } on HttpException {
          if (_cancelledRequests.contains(request.requestId)) {
            throw const CourierException('REQUEST_CANCELLED', '助手请求已取消');
          }
          lastError = const CourierException(
            'PROVIDER_CONNECTION_FAILED',
            '供应商连接异常',
          );
          if (attempt >= _maxAttempts) throw lastError;
        } finally {
          _activeRequests.remove(request.requestId);
        }
        if (_cancelledRequests.contains(request.requestId)) {
          throw const CourierException('REQUEST_CANCELLED', '助手请求已取消');
        }
        await Future<void>.delayed(
          Duration(milliseconds: 250 * attempt * attempt),
        );
      }
      throw lastError ?? const CourierException('PROVIDER_ERROR', '供应商请求失败');
    } finally {
      _activeRequests.remove(request.requestId);
      _cancelledRequests.remove(request.requestId);
    }
  }

  @override
  Future<void> cancel(String requestId) async {
    _cancelledRequests.add(requestId);
    final request = _activeRequests[requestId];
    if (request != null) {
      request.abort();
    }
  }

  @override
  void dispose() {
    for (final request in _activeRequests.values) {
      request.abort();
    }
    _activeRequests.clear();
    _cancelledRequests.clear();
    _client.close(force: true);
  }

  void _applyHeaders(
    HttpClientRequest request,
    String apiKey, {
    required bool stream,
  }) {
    request.headers.contentType = ContentType.json;
    request.headers.set(
      HttpHeaders.acceptHeader,
      stream ? 'text/event-stream' : 'application/json',
    );
    if (protocol == ProviderProtocol.openaiCompatible) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    } else {
      request.headers.set('x-api-key', apiKey);
      request.headers.set('anthropic-version', '2023-06-01');
    }
  }

  Map<String, dynamic> _requestBody(AIProviderRequest request) {
    if (protocol == ProviderProtocol.openaiCompatible) {
      return {
        'model': request.modelId,
        'input': request.messages
            .map((message) => {'role': message.role, 'content': message.text})
            .toList(growable: false),
        'temperature': request.temperature,
        'max_output_tokens': request.maxTokens,
        'stream': true,
      };
    }
    return {
      'model': request.modelId,
      'messages': request.messages
          .map((message) => {'role': message.role, 'content': message.text})
          .toList(growable: false),
      'temperature': request.temperature,
      'max_tokens': request.maxTokens,
      'stream': true,
    };
  }

  String? _extractDelta(_SseEvent event) {
    if (event.data.isEmpty || event.data == '[DONE]') return null;
    final decoded = jsonDecode(event.data);
    if (decoded is! Map<String, dynamic>) return null;
    final type = (decoded['type'] as String?) ?? event.name;

    if (type == 'error') {
      final error = decoded['error'];
      final message = error is Map<String, dynamic>
          ? error['message'] as String?
          : null;
      throw CourierException(
        'PROVIDER_ERROR',
        ErrorSanitizer.redact(message ?? '供应商返回错误'),
      );
    }

    if (protocol == ProviderProtocol.openaiCompatible) {
      if (type == 'response.output_text.delta') {
        return decoded['delta'] as String?;
      }
      final delta = decoded['delta'];
      if (delta is Map<String, dynamic>) {
        return delta['text'] as String?;
      }
      return null;
    }

    if (type == 'content_block_delta') {
      final delta = decoded['delta'];
      if (delta is Map<String, dynamic> && delta['type'] == 'text_delta') {
        return delta['text'] as String?;
      }
    }
    return null;
  }

  Stream<_SseEvent> _decodeSse(HttpClientResponse response) async* {
    var eventName = '';
    final dataLines = <String>[];
    await for (final line
        in response.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.isEmpty) {
        if (dataLines.isNotEmpty) {
          yield _SseEvent(name: eventName, data: dataLines.join('\n'));
        }
        eventName = '';
        dataLines.clear();
        continue;
      }
      if (line.startsWith(':')) continue;
      if (line.startsWith('event:')) {
        eventName = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        dataLines.add(line.substring(5).trimLeft());
      }
    }
    if (dataLines.isNotEmpty) {
      yield _SseEvent(name: eventName, data: dataLines.join('\n'));
    }
  }

  bool _isRetryable(int statusCode) =>
      statusCode == 429 ||
      statusCode == 500 ||
      statusCode == 502 ||
      statusCode == 503 ||
      statusCode == 504;

  Duration _retryDelay(HttpClientResponse response, int attempt) {
    final retryAfter = int.tryParse(
      response.headers.value(HttpHeaders.retryAfterHeader) ?? '',
    );
    if (retryAfter != null) {
      return Duration(seconds: retryAfter.clamp(1, 10));
    }
    return Duration(milliseconds: 500 * attempt * attempt);
  }

  Future<CourierException> _responseException(
    HttpClientResponse response,
  ) async {
    final bytes = <int>[];
    await for (final chunk in response) {
      final remaining = _maxErrorBodyBytes - bytes.length;
      if (remaining <= 0) break;
      bytes.addAll(chunk.take(remaining));
    }
    var message = '供应商请求失败，状态码 ${response.statusCode}';
    if (bytes.isNotEmpty) {
      try {
        final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
        if (decoded is Map<String, dynamic>) {
          final error = decoded['error'];
          if (error is Map<String, dynamic> && error['message'] is String) {
            message = error['message'] as String;
          } else if (decoded['message'] is String) {
            message = decoded['message'] as String;
          }
        }
      } catch (_) {
        // The status code remains sufficient when the body is not JSON.
      }
    }
    return CourierException(
      'PROVIDER_HTTP_${response.statusCode}',
      ErrorSanitizer.redact(message),
    );
  }

  Future<String> _readTextBody(HttpClientResponse response, int limit) async {
    final bytes = <int>[];
    await for (final chunk in response) {
      if (bytes.length + chunk.length > limit) {
        throw const CourierException(
          'INVALID_PROVIDER_RESPONSE',
          '供应商响应超过允许的大小限制',
        );
      }
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes, allowMalformed: false);
  }

  static ProviderProtocol _defaultProtocol(String providerId) {
    return providerId.trim().toLowerCase() == 'anthropic'
        ? ProviderProtocol.anthropicCompatible
        : ProviderProtocol.openaiCompatible;
  }
}

class AIService extends ChangeNotifier {
  static const int _maxInputCharacters = 32000;
  static const int _maxContextCharacters = 80000;
  static const int _maxResponseCharacters = 1024 * 1024;

  final SettingsState settings;
  final SecureStorageService secureStorage;
  final AppLogger logger;
  final Map<String, AIProviderClient> _providers;
  final CustomAIProviderClientFactory _customProviderClientFactory;
  late final Set<String> _builtInProviderIds;
  final Map<String, CustomAIProvider> _customProviderConfigurations = {};
  final Map<String, List<AIModelOption>> _models = {};
  final Map<String, String> _requestProviders = {};
  final Set<String> _cancelledRequests = {};

  AISession? _session;
  final List<AIMessage> _messages = [];
  bool _sending = false;
  String? _activeRequestId;
  String? _lastError;

  AIService({
    required this.settings,
    required this.secureStorage,
    required this.logger,
    Map<String, AIProviderClient>? providers,
    CustomAIProviderClientFactory? customProviderClientFactory,
  }) : _providers = Map<String, AIProviderClient>.of(
         providers ??
             {
               'openai': OfficialAIProviderClient.openAI(),
               'anthropic': OfficialAIProviderClient.anthropic(),
             },
       ),
       _customProviderClientFactory =
           customProviderClientFactory ?? _createCustomProviderClient {
    _builtInProviderIds = Set<String>.unmodifiable(_providers.keys);
    applyCustomProviders(settings.customProviders);
  }

  AISession? get session => _session;
  List<AIMessage> get messages => List.unmodifiable(_messages);
  bool get sending => _sending;
  String? get activeRequestId => _activeRequestId;
  String? get lastError => _lastError;

  AIGetOptionsResult get options {
    _synchronizeCustomProviders();
    final customProviders = {
      for (final provider in settings.customProviders) provider.id: provider,
    };
    final providerIds = <String>[
      ..._builtInProviderIds,
      ...settings.customProviders.map((provider) => provider.id),
    ];
    return AIGetOptionsResult(
      providers: providerIds
          .map((providerId) => _providers[providerId])
          .whereType<AIProviderClient>()
          .map(
            (provider) => AIProviderOption(
              id: provider.id,
              displayName: provider.displayName,
              models: _models[provider.id] ?? const [],
              supportsMillionContext:
                  customProviders[provider.id]?.supportsMillionContext ?? false,
            ),
          )
          .toList(growable: false),
      thinkingLevels: const [AIOptionItem(value: 'standard', label: '标准')],
      modes: const [AIOptionItem(value: 'readonly', label: '只读')],
    );
  }

  void applyCustomProviders(List<CustomAIProvider> providers) {
    final nextConfigurations = <String, CustomAIProvider>{};
    for (final provider in providers) {
      if (_builtInProviderIds.contains(provider.id) ||
          nextConfigurations.containsKey(provider.id)) {
        throw const CourierException('INVALID_PROVIDER', '自定义供应商配置包含冲突标识');
      }
      nextConfigurations[provider.id] = provider;
    }

    final activeProviderIds = _requestProviders.values.toSet();
    final replacements = <String, AIProviderClient>{};
    try {
      for (final entry in nextConfigurations.entries) {
        final current = _customProviderConfigurations[entry.key];
        if (current == entry.value || activeProviderIds.contains(entry.key)) {
          continue;
        }
        final client = _customProviderClientFactory(entry.value);
        if (client.id != entry.key) {
          client.dispose();
          throw const CourierException(
            'INVALID_PROVIDER_CLIENT',
            '自定义供应商客户端标识无效',
          );
        }
        replacements[entry.key] = client;
      }
    } catch (_) {
      for (final client in replacements.values) {
        client.dispose();
      }
      rethrow;
    }

    final removedIds = _customProviderConfigurations.keys
        .where(
          (id) =>
              !nextConfigurations.containsKey(id) &&
              !activeProviderIds.contains(id),
        )
        .toList(growable: false);
    for (final id in removedIds) {
      _providers.remove(id)?.dispose();
      _customProviderConfigurations.remove(id);
      _models.remove(id);
    }

    for (final entry in replacements.entries) {
      _providers.remove(entry.key)?.dispose();
      _providers[entry.key] = entry.value;
      _customProviderConfigurations[entry.key] = nextConfigurations[entry.key]!;
      _models.remove(entry.key);
    }
  }

  Future<List<AIModelOption>> refreshModels() async {
    final provider = _provider(settings.aiProviderId);
    final apiKey = await _requireApiKey(provider.id);
    final models = await provider.listModels(apiKey);
    _models[provider.id] = models;
    notifyListeners();
    return models;
  }

  Future<AISession> startSession({required String workspacePath}) async {
    if (workspacePath.trim().isEmpty ||
        !await Directory(workspacePath).exists()) {
      throw const CourierException('WORKSPACE_REQUIRED', '需要先打开有效工作区');
    }
    _validateConfiguration();
    await _requireApiKey(settings.aiProviderId);
    await stopSession(clearMessages: true, allowMissing: true);
    _session = AISession(
      sessionId: IdGenerator.create('ai-session'),
      workspacePath: workspacePath,
      providerId: settings.aiProviderId,
      modelId: settings.aiModelId,
      messageCount: 0,
      createdAt: DateTime.now().toUtc().toIso8601String(),
    );
    _lastError = null;
    notifyListeners();
    return _session!;
  }

  Future<AISendMessageResult> sendMessage(String value) async {
    final currentSession = _session;
    if (currentSession == null) {
      throw const CourierException('NO_SESSION', '助手会话尚未建立');
    }
    if (_sending) {
      throw const CourierException('REQUEST_IN_PROGRESS', '已有助手请求正在进行');
    }
    final text = value.trim();
    if (text.isEmpty || text.length > _maxInputCharacters) {
      throw const CourierException('INVALID_MESSAGE', '消息为空或超过允许的长度');
    }

    final requestId = IdGenerator.create('ai-request');
    final userMessage = AIMessage(
      id: IdGenerator.create('message'),
      role: 'user',
      text: text,
      timestamp: DateTime.now(),
    );
    final assistantMessage = AIMessage(
      id: IdGenerator.create('message'),
      role: 'assistant',
      text: '',
      timestamp: DateTime.now(),
      streaming: true,
      requestId: requestId,
    );
    _messages.add(userMessage);
    _messages.add(assistantMessage);
    _sending = true;
    _activeRequestId = requestId;
    _lastError = null;
    notifyListeners();

    final buffer = StringBuffer();
    try {
      final provider = _provider(currentSession.providerId);
      _requestProviders[requestId] = provider.id;
      final apiKey = await _requireApiKey(provider.id);
      if (_cancelledRequests.contains(requestId)) {
        throw const CourierException('REQUEST_CANCELLED', '助手请求已取消');
      }
      final providerRequest = AIProviderRequest(
        requestId: requestId,
        modelId: currentSession.modelId,
        temperature: settings.aiTemperature,
        maxTokens: settings.aiMaxTokens,
        messages: _contextMessages(),
        apiKey: apiKey,
      );

      var lastNotification = DateTime.fromMillisecondsSinceEpoch(0);
      await for (final delta in provider.sendMessageStream(providerRequest)) {
        if (_cancelledRequests.contains(requestId)) {
          throw const CourierException('REQUEST_CANCELLED', '助手请求已取消');
        }
        if (buffer.length + delta.length > _maxResponseCharacters) {
          await provider.cancel(requestId);
          throw const CourierException('RESPONSE_TOO_LARGE', '助手回复超过应用允许的大小限制');
        }
        buffer.write(delta);
        _replaceMessage(
          assistantMessage.id,
          assistantMessage.copyWith(text: buffer.toString()),
        );
        final now = DateTime.now();
        if (now.difference(lastNotification) >=
            const Duration(milliseconds: 32)) {
          lastNotification = now;
          notifyListeners();
        }
      }

      if (_cancelledRequests.contains(requestId) ||
          _session?.sessionId != currentSession.sessionId) {
        throw const CourierException('REQUEST_CANCELLED', '助手请求已取消');
      }

      _replaceMessage(
        assistantMessage.id,
        assistantMessage.copyWith(text: buffer.toString(), streaming: false),
      );
      _session = currentSession.copyWith(
        messageCount: currentSession.messageCount + 1,
      );
      await logger.info(
        'ai',
        'request_completed',
        '助手请求完成',
        requestId: requestId,
      );
      return AISendMessageResult(
        sessionId: currentSession.sessionId,
        messageCount: _session!.messageCount,
        reply: buffer.toString(),
      );
    } on CourierException catch (error) {
      if (_activeRequestId == requestId) {
        _lastError = error.code == 'REQUEST_CANCELLED' ? null : error.message;
      }
      _replaceMessage(
        assistantMessage.id,
        assistantMessage.copyWith(text: buffer.toString(), streaming: false),
      );
      if (error.code == 'REQUEST_CANCELLED') {
        await logger.info(
          'ai',
          'request_cancelled',
          '助手请求已取消',
          requestId: requestId,
        );
      } else {
        await logger.error(
          'ai',
          'request_failed',
          error.message,
          requestId: requestId,
          errorCode: error.code,
        );
      }
      rethrow;
    } catch (_) {
      const error = CourierException('PROVIDER_ERROR', '供应商请求失败');
      if (_activeRequestId == requestId) {
        _lastError = error.message;
      }
      _replaceMessage(
        assistantMessage.id,
        assistantMessage.copyWith(text: buffer.toString(), streaming: false),
      );
      await logger.error(
        'ai',
        'request_failed',
        error.message,
        requestId: requestId,
        errorCode: error.code,
      );
      throw error;
    } finally {
      _requestProviders.remove(requestId);
      _cancelledRequests.remove(requestId);
      if (_activeRequestId == requestId) {
        _sending = false;
        _activeRequestId = null;
      }
      notifyListeners();
    }
  }

  Future<String> executeTask({
    required String workspacePath,
    required String prompt,
    required String requestId,
    required void Function(String delta) onDelta,
  }) async {
    _validateConfiguration();
    final normalizedPrompt = prompt.trim();
    if (normalizedPrompt.isEmpty ||
        normalizedPrompt.length > _maxContextCharacters) {
      throw const CourierException('INVALID_TASK_INPUT', '任务输入为空或超过允许的长度');
    }
    final provider = _provider(settings.aiProviderId);
    _requestProviders[requestId] = provider.id;
    final buffer = StringBuffer();
    try {
      if (workspacePath.trim().isEmpty ||
          !await Directory(workspacePath).exists()) {
        throw const CourierException('WORKSPACE_REQUIRED', '任务工作区不存在');
      }
      final apiKey = await _requireApiKey(provider.id);
      if (_cancelledRequests.contains(requestId)) {
        throw const CourierException('REQUEST_CANCELLED', '助手请求已取消');
      }
      final request = AIProviderRequest(
        requestId: requestId,
        modelId: settings.aiModelId,
        temperature: settings.aiTemperature,
        maxTokens: settings.aiMaxTokens,
        messages: [AIConversationMessage(role: 'user', text: normalizedPrompt)],
        apiKey: apiKey,
      );
      await for (final delta in provider.sendMessageStream(request)) {
        if (_cancelledRequests.contains(requestId)) {
          throw const CourierException('REQUEST_CANCELLED', '助手请求已取消');
        }
        if (buffer.length + delta.length > _maxResponseCharacters) {
          await provider.cancel(requestId);
          throw const CourierException('RESPONSE_TOO_LARGE', '任务输出超过应用允许的大小限制');
        }
        buffer.write(delta);
        onDelta(delta);
      }
      if (_cancelledRequests.contains(requestId)) {
        throw const CourierException('REQUEST_CANCELLED', '助手请求已取消');
      }
      return buffer.toString();
    } finally {
      _requestProviders.remove(requestId);
      _cancelledRequests.remove(requestId);
    }
  }

  Future<void> cancelRequest(String requestId) {
    _cancelledRequests.add(requestId);
    final providerId = _requestProviders[requestId];
    if (providerId == null) {
      _cancelledRequests.remove(requestId);
      return Future<void>.value();
    }
    final provider = _providers[providerId];
    if (provider == null) {
      _cancelledRequests.remove(requestId);
      return Future<void>.value();
    }
    return provider.cancel(requestId);
  }

  Future<void> cancelGeneration() async {
    final requestId = _activeRequestId;
    if (requestId == null) return;
    await cancelRequest(requestId);
  }

  Future<AIStopSessionResult?> stopSession({
    bool clearMessages = true,
    bool allowMissing = false,
  }) async {
    final current = _session;
    if (current == null) {
      if (allowMissing) return null;
      throw const CourierException('NO_SESSION', '助手会话尚未建立');
    }
    await cancelGeneration();
    _session = null;
    _sending = false;
    _activeRequestId = null;
    if (clearMessages) _messages.clear();
    notifyListeners();
    return AIStopSessionResult(sessionId: current.sessionId, status: 'stopped');
  }

  void clearMessages() {
    _messages.clear();
    notifyListeners();
  }

  void _validateConfiguration() {
    _synchronizeCustomProviders();
    if (!_providers.containsKey(settings.aiProviderId)) {
      throw const CourierException('AI_NOT_CONFIGURED', '供应商配置无效');
    }
    if (settings.aiModelId.trim().isEmpty) {
      throw const CourierException('AI_NOT_CONFIGURED', '需要先配置供应商模型');
    }
  }

  Future<String> _requireApiKey(String providerId) async {
    final value = await secureStorage.readApiKey(providerId);
    if (value == null) {
      throw const CourierException('AI_NOT_CONFIGURED', '需要先配置供应商 API Key');
    }
    return value;
  }

  AIProviderClient _provider(String providerId) {
    _synchronizeCustomProviders();
    final provider = _providers[providerId];
    if (provider == null) {
      throw const CourierException('INVALID_PROVIDER', '供应商不受支持');
    }
    return provider;
  }

  void _synchronizeCustomProviders() {
    applyCustomProviders(settings.customProviders);
  }

  static AIProviderClient _createCustomProviderClient(
    CustomAIProvider provider,
  ) {
    return OfficialAIProviderClient(
      id: provider.id,
      displayName: provider.displayName,
      baseUri: Uri.parse(provider.baseUrl),
      protocol: provider.protocol,
    );
  }

  List<AIConversationMessage> _contextMessages() {
    final selected = <AIConversationMessage>[];
    var totalCharacters = 0;
    for (final message in _messages.reversed) {
      if (message.streaming || message.text.isEmpty) continue;
      if (selected.length >= 40) break;
      if (totalCharacters + message.text.length > _maxContextCharacters &&
          selected.isNotEmpty) {
        break;
      }
      selected.add(
        AIConversationMessage(role: message.role, text: message.text),
      );
      totalCharacters += message.text.length;
    }
    return selected.reversed.toList(growable: false);
  }

  void _replaceMessage(String id, AIMessage replacement) {
    final index = _messages.indexWhere((message) => message.id == id);
    if (index >= 0) _messages[index] = replacement;
  }

  @override
  void dispose() {
    for (final provider in _providers.values) {
      provider.dispose();
    }
    super.dispose();
  }
}

class _SseEvent {
  final String name;
  final String data;

  const _SseEvent({required this.name, required this.data});
}
