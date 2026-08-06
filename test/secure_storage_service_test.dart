import 'package:courier_flutter/services/secure_storage_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('平台凭据存储初始化命名空间并委托系统存储', () async {
    const channel = MethodChannel('fr.skyost.simple_secure_storage');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    final values = <String, String>{};
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final arguments = (call.arguments as Map?)?.cast<Object?, Object?>();
      switch (call.method) {
        case 'initialize':
          expect(arguments?['appName'], 'Courier');
          expect(arguments?['namespace'], 'courier_flutter');
          return true;
        case 'write':
          values[arguments?['key']! as String] = arguments?['value']! as String;
          return true;
        case 'has':
          return values.containsKey(arguments?['key']);
        case 'read':
          return values[arguments?['key']];
        case 'delete':
          values.remove(arguments?['key']);
          return true;
      }
      fail('Unexpected secure storage method: ${call.method}');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final store = PlatformCredentialStore();
    final credential = generatedCredential();
    const key = 'courier.ai.openai.api_key';

    await store.write(key, credential);
    expect(await store.containsKey(key), isTrue);
    expect(await store.read(key), credential);
    await store.delete(key);
    expect(await store.containsKey(key), isFalse);
    expect(calls.where((call) => call.method == 'initialize'), hasLength(1));
  });

  test('API Key 写入前会规范化并使用 Provider 隔离键', () async {
    final store = MemoryCredentialStore();
    final service = SecureStorageService(store: store);
    final credential = generatedCredential();

    await service.saveApiKey('OpenAI', '  $credential  ');

    expect(store.values['courier.ai.openai.api_key'], credential);
    expect(await service.readApiKey('openai'), credential);
  });

  test('自定义供应商 API Key 使用独立凭据键完成读写删除', () async {
    final store = MemoryCredentialStore();
    final service = SecureStorageService(store: store);
    final credential = generatedCredential();
    const providerId = 'custom-provider';

    await service.saveApiKey(providerId, credential);

    expect(await service.hasApiKey(providerId), isTrue);
    expect(await service.readApiKey(providerId), credential);
    expect(store.values['courier.ai.$providerId.api_key'], credential);

    await service.deleteApiKey(providerId);
    expect(await service.hasApiKey(providerId), isFalse);
  });

  test('API Key 拒绝空值、空字符和超过系统存储限制的内容', () async {
    final service = SecureStorageService(store: MemoryCredentialStore());

    await expectLater(
      service.saveApiKey('openai', '   '),
      throwsCourierCode('INVALID_CREDENTIAL'),
    );
    await expectLater(
      service.saveApiKey('openai', '${generatedCredential()}\u0000'),
      throwsCourierCode('INVALID_CREDENTIAL'),
    );
    await expectLater(
      service.saveApiKey('openai', List<String>.filled(2049, 'A').join()),
      throwsCourierCode('INVALID_CREDENTIAL'),
    );
  });
}
