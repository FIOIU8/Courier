import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:courier_flutter/services/ai_service.dart';
import 'package:courier_flutter/services/app_logger.dart';
import 'package:courier_flutter/services/models.dart';
import 'package:courier_flutter/services/secure_storage_service.dart';
import 'package:courier_flutter/services/settings_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_fakes.dart';

void main() {
  late Directory workspace;
  late MemoryCredentialStore credentialStore;
  late SecureStorageService secureStorage;
  late SettingsState settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    workspace = await Directory.systemTemp.createTemp('courier-ai-');
    credentialStore = MemoryCredentialStore();
    secureStorage = SecureStorageService(store: credentialStore);
    settings = SettingsState(
      secureStorage: secureStorage,
      environment: const {},
    );
    await settings.load();
    await settings.setAiModelId('model-under-test');
  });

  tearDown(() async {
    settings.dispose();
    if (await workspace.exists()) await workspace.delete(recursive: true);
  });

  test('流式消息更新会话并返回完整回复', () async {
    final credential = generatedCredential();
    await settings.saveApiKey(credential);
    final provider = FakeAIProviderClient(chunks: const ['第一段', '第二段']);
    final service = AIService(
      settings: settings,
      secureStorage: secureStorage,
      logger: AppLogger(),
      providers: {'openai': provider},
    );
    addTearDown(service.dispose);
    await service.startSession(workspacePath: workspace.path);

    final result = await service.sendMessage('用户请求');
    expect(result.reply, '第一段第二段');
    expect(result.messageCount, 1);
    expect(service.messages, hasLength(2));
    expect(service.messages.last.text, result.reply);
    expect(service.messages.last.streaming, isFalse);
    expect(service.sending, isFalse);
    expect(provider.requests.single.apiKey, credential);
    expect(provider.requests.single.messages.single.text, '用户请求');
  });

  test('停止会话会取消进行中的请求且不会恢复旧会话', () async {
    await settings.saveApiKey(generatedCredential());
    final gate = Completer<void>();
    final provider = FakeAIProviderClient(
      chunks: const ['不会返回'],
      release: gate,
    );
    final service = AIService(
      settings: settings,
      secureStorage: secureStorage,
      logger: AppLogger(),
      providers: {'openai': provider},
    );
    addTearDown(service.dispose);
    await service.startSession(workspacePath: workspace.path);

    final pending = service.sendMessage('等待取消');
    await provider.requestStarted.future;
    final stopped = await service.stopSession();
    expect(stopped?.status, 'stopped');
    await expectLater(pending, throwsCourierCode('REQUEST_CANCELLED'));
    expect(service.session, isNull);
    expect(service.sending, isFalse);
    expect(provider.cancelledRequestIds, isNotEmpty);
  });

  test('旧请求结束不会清除新请求的活动状态', () async {
    await settings.saveApiKey(generatedCredential());
    final firstGate = Completer<void>();
    final secondGate = Completer<void>();
    final provider = FakeAIProviderClient(
      chunks: const ['新回复'],
      release: firstGate,
      completeReleaseOnCancel: false,
    );
    final service = AIService(
      settings: settings,
      secureStorage: secureStorage,
      logger: AppLogger(),
      providers: {'openai': provider},
    );
    addTearDown(service.dispose);
    await service.startSession(workspacePath: workspace.path);

    final firstRequest = service.sendMessage('旧请求');
    await provider.requestStarted.future;
    await service.stopSession();

    provider.release = secondGate;
    await service.startSession(workspacePath: workspace.path);
    final secondRequest = service.sendMessage('新请求');
    await waitForCondition(() => provider.requests.length == 2);
    final secondRequestId = provider.requests.last.requestId;

    firstGate.complete();
    await expectLater(firstRequest, throwsCourierCode('REQUEST_CANCELLED'));
    expect(service.sending, isTrue);
    expect(service.activeRequestId, secondRequestId);

    secondGate.complete();
    expect((await secondRequest).reply, '新回复');
    expect(service.sending, isFalse);
  });

  test('任务请求在首个异步边界前即可取消', () async {
    await settings.saveApiKey(generatedCredential());
    final provider = FakeAIProviderClient(chunks: const ['不应返回']);
    final service = AIService(
      settings: settings,
      secureStorage: secureStorage,
      logger: AppLogger(),
      providers: {'openai': provider},
    );
    addTearDown(service.dispose);
    const requestId = 'task-request-cancel-race';

    final pending = service.executeTask(
      workspacePath: workspace.path,
      prompt: '取消请求',
      requestId: requestId,
      onDelta: (_) {},
    );
    await service.cancelRequest(requestId);

    await expectLater(pending, throwsCourierCode('REQUEST_CANCELLED'));
    expect(provider.cancelledRequestIds, contains(requestId));
    expect(provider.requests, isEmpty);
  });

  test('未分类 Provider 异常被转换为安全错误', () async {
    await settings.saveApiKey(generatedCredential());
    final provider = FakeAIProviderClient(
      streamError: StateError('provider implementation failure'),
    );
    final service = AIService(
      settings: settings,
      secureStorage: secureStorage,
      logger: AppLogger(),
      providers: {'openai': provider},
    );
    addTearDown(service.dispose);
    await service.startSession(workspacePath: workspace.path);

    await expectLater(
      service.sendMessage('触发异常'),
      throwsCourierCode('PROVIDER_ERROR'),
    );
    expect(service.messages.last.streaming, isFalse);
    expect(service.lastError, '供应商请求失败');
  });

  test('模型刷新使用安全存储中的凭据', () async {
    final credential = generatedCredential();
    await settings.saveApiKey(credential);
    final provider = FakeAIProviderClient(
      models: const [AIModelOption(id: 'model-a', displayName: 'Model A')],
    );
    final service = AIService(
      settings: settings,
      secureStorage: secureStorage,
      logger: AppLogger(),
      providers: {'openai': provider},
    );
    addTearDown(service.dispose);

    final models = await service.refreshModels();
    expect(models.single.id, 'model-a');
    expect(service.options.providers.single.models.single.id, 'model-a');
  });

  test('缺少凭据时拒绝启动会话', () async {
    final provider = FakeAIProviderClient();
    final service = AIService(
      settings: settings,
      secureStorage: secureStorage,
      logger: AppLogger(),
      providers: {'openai': provider},
    );
    addTearDown(service.dispose);

    await expectLater(
      service.startSession(workspacePath: workspace.path),
      throwsCourierCode('AI_NOT_CONFIGURED'),
    );
  });

  test('OpenAI 兼容协议使用自定义 Base API、Bearer 与 responses 请求体', () async {
    final response = StubHttpClientResponse(
      body:
          'event: response.output_text.delta\n'
          'data: ${jsonEncode({'type': 'response.output_text.delta', 'delta': '响应'})}\n\n',
    );
    final httpClient = RecordingHttpClient(responses: [response]);
    final client = OfficialAIProviderClient(
      id: 'custom-openai',
      displayName: 'OpenAI 兼容供应商',
      baseUri: Uri.parse('https://api.openai.com/v1/custom'),
      protocol: ProviderProtocol.openaiCompatible,
      client: httpClient,
    );
    addTearDown(client.dispose);
    final credential = generatedCredential();

    final chunks = await client
        .sendMessageStream(
          AIProviderRequest(
            requestId: 'request-openai-compatible',
            modelId: 'model-openai-compatible',
            temperature: 0.4,
            maxTokens: 2048,
            messages: const [AIConversationMessage(role: 'user', text: '请求内容')],
            apiKey: credential,
          ),
        )
        .toList();

    expect(chunks, ['响应']);
    final request = httpClient.requests.single;
    expect(request.method, 'POST');
    expect(
      request.uri,
      Uri.parse('https://api.openai.com/v1/custom/responses'),
    );
    expect(
      request.recordedHeaders.value(HttpHeaders.authorizationHeader),
      'Bearer $credential',
    );
    expect(request.recordedHeaders.value('x-api-key'), isNull);
    final body = jsonDecode(request.body.toString()) as Map<String, dynamic>;
    expect(body['model'], 'model-openai-compatible');
    expect(body['max_output_tokens'], 2048);
    expect(body['input'], isA<List<dynamic>>());
  });

  test('Anthropic 兼容协议使用 x-api-key、messages 端点与请求体', () async {
    final response = StubHttpClientResponse(
      body:
          'event: content_block_delta\n'
          'data: ${jsonEncode({
            'type': 'content_block_delta',
            'delta': {'type': 'text_delta', 'text': '完成'},
          })}\n\n',
    );
    final httpClient = RecordingHttpClient(responses: [response]);
    final client = OfficialAIProviderClient(
      id: 'custom-anthropic',
      displayName: 'Anthropic 兼容供应商',
      baseUri: Uri.parse('https://api.anthropic.com/v1/'),
      protocol: ProviderProtocol.anthropicCompatible,
      client: httpClient,
    );
    addTearDown(client.dispose);
    final credential = generatedCredential();

    final chunks = await client
        .sendMessageStream(
          AIProviderRequest(
            requestId: 'request-anthropic-compatible',
            modelId: 'model-anthropic-compatible',
            temperature: 0.2,
            maxTokens: 4096,
            messages: const [AIConversationMessage(role: 'user', text: '请求内容')],
            apiKey: credential,
          ),
        )
        .toList();

    expect(chunks, ['完成']);
    final request = httpClient.requests.single;
    expect(request.uri, Uri.parse('https://api.anthropic.com/v1/messages'));
    expect(request.recordedHeaders.value('x-api-key'), credential);
    expect(request.recordedHeaders.value('anthropic-version'), '2023-06-01');
    expect(
      request.recordedHeaders.value(HttpHeaders.authorizationHeader),
      isNull,
    );
    final body = jsonDecode(request.body.toString()) as Map<String, dynamic>;
    expect(body['model'], 'model-anthropic-compatible');
    expect(body['max_tokens'], 4096);
    expect(body['messages'], isA<List<dynamic>>());
  });

  test('AIService 合并并更新自定义供应商选项与客户端生命周期', () async {
    final createdClients = <FakeAIProviderClient>[];
    final service = AIService(
      settings: settings,
      secureStorage: secureStorage,
      logger: AppLogger(),
      providers: {'openai': FakeAIProviderClient()},
      customProviderClientFactory: (provider) {
        final client = FakeAIProviderClient(
          id: provider.id,
          displayName: provider.displayName,
        );
        createdClients.add(client);
        return client;
      },
    );
    addTearDown(service.dispose);

    final provider = await settings.addCustomProvider(
      displayName: '同步供应商',
      baseUrl: 'https://api.openai.com/v1/sync/',
      supportsMillionContext: true,
    );
    var customOption = service.options.providers.last;
    expect(service.options.providers, hasLength(2));
    expect(customOption.id, provider.id);
    expect(customOption.supportsMillionContext, isTrue);
    expect(createdClients, hasLength(1));

    await settings.updateCustomProvider(
      id: provider.id,
      displayName: '同步供应商二号',
      baseUrl: 'https://api.anthropic.com/v1/sync/',
      protocol: ProviderProtocol.anthropicCompatible,
      supportsMillionContext: false,
    );
    customOption = service.options.providers.last;
    expect(customOption.displayName, '同步供应商二号');
    expect(customOption.supportsMillionContext, isFalse);
    expect(createdClients, hasLength(2));
    expect(createdClients.first.disposed, isTrue);

    await settings.deleteCustomProvider(provider.id);
    expect(service.options.providers.single.id, 'openai');
    expect(createdClients.last.disposed, isTrue);
  });
}
