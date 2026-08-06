import 'dart:convert';

import 'package:courier_flutter/services/app_error.dart';
import 'package:courier_flutter/services/app_logger.dart';
import 'package:courier_flutter/services/courier_service.dart';
import 'package:courier_flutter/services/models.dart';
import 'package:courier_flutter/services/secure_storage_service.dart';
import 'package:courier_flutter/services/settings_state.dart';
import 'package:flutter/material.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_fakes.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('加载时约束数值并安全回退无效标识', () async {
    SharedPreferences.setMockInitialValues({
      'ai_temperature': 8.0,
      'ai_max_tokens': 1,
      'ai_provider': 'unsupported-provider',
      'ai_model': 'stored-model',
      'editor_font_size': 80,
      'max_concurrent': 40,
    });
    final settings = SettingsState(
      secureStorage: SecureStorageService(store: MemoryCredentialStore()),
      environment: const {'COURIER_AI_MODEL_ID': 'invalid\u0000model'},
    );
    addTearDown(settings.dispose);

    await settings.load();
    expect(settings.aiTemperature, 2.0);
    expect(settings.aiMaxTokens, 256);
    expect(settings.aiProviderId, 'openai');
    expect(settings.aiModelId, isEmpty);
    expect(settings.editorFontSize, 24);
    expect(settings.maxConcurrent, 10);
  });

  test('设置器拒绝非法值并将密钥仅写入凭据存储', () async {
    final credentialStore = MemoryCredentialStore();
    final settings = SettingsState(
      secureStorage: SecureStorageService(store: credentialStore),
      environment: const {},
    );
    addTearDown(settings.dispose);
    await settings.load();

    await expectLater(
      settings.setAiProviderId('unsupported-provider'),
      throwsCourierCode('INVALID_SETTING'),
    );
    await expectLater(
      settings.setAiTemperature(double.nan),
      throwsCourierCode('INVALID_SETTING'),
    );

    final credential = generatedCredential();
    await settings.saveApiKey(credential);
    expect(settings.apiKeyConfigured, isTrue);
    expect(credentialStore.values.values, contains(credential));
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getKeys().any((key) => key.contains('key')), isFalse);

    await settings.deleteApiKey();
    expect(settings.apiKeyConfigured, isFalse);
    expect(credentialStore.values, isEmpty);
  });

  test('CourierService 实时同步日志级别', () async {
    final secureStorage = SecureStorageService(store: MemoryCredentialStore());
    final settings = SettingsState(
      secureStorage: secureStorage,
      environment: const {},
    );
    await settings.load();
    final logger = AppLogger();
    final service = CourierService(
      settings: settings,
      secureStorage: secureStorage,
      logger: logger,
    );
    addTearDown(() {
      service.dispose();
      settings.dispose();
    });

    expect(logger.minimumLevel, AppLogLevel.info);
    await settings.setLogLevel(AppLogLevel.debug);
    expect(logger.minimumLevel, AppLogLevel.debug);
  });

  test('主题强调色持久化、校验与回退', () async {
    final settings = SettingsState(
      secureStorage: SecureStorageService(store: MemoryCredentialStore()),
      environment: const {},
    );
    addTearDown(settings.dispose);
    await settings.load();
    expect(
      settings.accentColor.toARGB32(),
      SettingsState.defaultAccentColorValue,
    );

    await settings.setAccentColor(SettingsState.accentPalette[1]);
    expect(
      settings.accentColor.toARGB32(),
      SettingsState.accentPalette[1].toARGB32(),
    );

    // 非法色（不在色板内）应被拒绝
    await expectLater(
      settings.setAccentColor(const Color(0xFFFF0000)),
      throwsA(isA<CourierException>()),
    );
    expect(
      settings.accentColor.toARGB32(),
      SettingsState.accentPalette[1].toARGB32(),
      reason: '非法色不应改变当前主题色',
    );

    // 重新加载后保持已持久化的主题色
    final reloaded = SettingsState(
      secureStorage: SecureStorageService(store: MemoryCredentialStore()),
      environment: const {},
    );
    addTearDown(reloaded.dispose);
    await reloaded.load();
    expect(
      reloaded.accentColor.toARGB32(),
      SettingsState.accentPalette[1].toARGB32(),
    );
  });

  test('毛玻璃开关与强度持久化并限制范围', () async {
    final settings = SettingsState(
      secureStorage: SecureStorageService(store: MemoryCredentialStore()),
      environment: const {},
    );
    addTearDown(settings.dispose);
    await settings.load();
    expect(settings.glassEnabled, isTrue);
    expect(settings.blurSigma, 14);

    await settings.setGlassEnabled(false);
    await settings.setBlurSigma(22);
    expect(settings.glassEnabled, isFalse);
    expect(settings.blurSigma, 22);

    // 超出范围的值被钳制
    await settings.setBlurSigma(99);
    expect(settings.blurSigma, 30);
    await settings.setBlurSigma(-5);
    expect(settings.blurSigma, 0);

    // 重新加载后保持
    final reloaded = SettingsState(
      secureStorage: SecureStorageService(store: MemoryCredentialStore()),
      environment: const {},
    );
    addTearDown(reloaded.dispose);
    await reloaded.load();
    expect(reloaded.glassEnabled, isFalse);
    expect(reloaded.blurSigma, 0);
  });

  test('偏好写入失败时不提交内存状态', () async {
    var rejectPreferenceAccess = false;
    Future<SharedPreferences> loadPreferences() async {
      if (rejectPreferenceAccess) {
        throw StateError('preferences unavailable');
      }
      return SharedPreferences.getInstance();
    }

    final settings = SettingsState(
      secureStorage: SecureStorageService(store: MemoryCredentialStore()),
      preferencesLoader: loadPreferences,
      environment: const {},
    );
    addTearDown(settings.dispose);
    await settings.load();
    expect(settings.autoSave, isFalse);

    rejectPreferenceAccess = true;
    await expectLater(settings.setAutoSave(true), throwsStateError);
    expect(settings.autoSave, isFalse);
  });

  test('自定义供应商支持增改查、JSON 持久化往返与 URL 校验', () async {
    final credentialStore = MemoryCredentialStore();
    final secureStorage = SecureStorageService(store: credentialStore);
    final settings = SettingsState(
      secureStorage: secureStorage,
      environment: const {},
    );
    addTearDown(settings.dispose);
    await settings.load();

    final provider = await settings.addCustomProvider(
      displayName: '企业供应商',
      baseUrl: 'https://api.openai.com/v1/custom',
      protocol: ProviderProtocol.openaiCompatible,
      supportsMillionContext: true,
    );
    expect(CustomAIProvider.idPattern.hasMatch(provider.id), isTrue);
    expect(provider.baseUrl, 'https://api.openai.com/v1/custom/');
    expect(settings.customProviders.single, provider);

    await settings.updateCustomProvider(
      id: provider.id,
      displayName: '企业供应商二号',
      baseUrl: 'https://api.anthropic.com/v1/gateway',
      protocol: ProviderProtocol.anthropicCompatible,
      supportsMillionContext: false,
    );
    expect(settings.customProviders.single.displayName, '企业供应商二号');
    expect(
      settings.customProviders.single.protocol,
      ProviderProtocol.anthropicCompatible,
    );

    final reloaded = SettingsState(
      secureStorage: secureStorage,
      environment: const {},
    );
    addTearDown(reloaded.dispose);
    await reloaded.load();
    expect(reloaded.customProviders, settings.customProviders);

    final preferences = await SharedPreferences.getInstance();
    final persisted = jsonDecode(preferences.getString('custom_ai_providers')!);
    expect(persisted, isA<List<dynamic>>());

    await expectLater(
      settings.addCustomProvider(
        displayName: '无效地址供应商',
        baseUrl: 'urn:provider:api',
      ),
      throwsCourierCode('INVALID_SETTING'),
    );
  });

  test('百万上下文上限动态切换并在删除当前供应商时清理关联状态', () async {
    final credentialStore = MemoryCredentialStore();
    final secureStorage = SecureStorageService(store: credentialStore);
    final settings = SettingsState(
      secureStorage: secureStorage,
      environment: const {},
    );
    addTearDown(settings.dispose);
    await settings.load();

    final provider = await settings.addCustomProvider(
      displayName: '长上下文供应商',
      baseUrl: 'https://api.openai.com/v1/extended/',
      supportsMillionContext: true,
    );
    await settings.setAiProviderId(provider.id);
    await settings.setAiModelId('long-context-model');
    await settings.saveApiKey(generatedCredential());
    await settings.setAiMaxTokens(SettingsState.millionContextAiMaxTokens);

    expect(settings.currentProviderSupportsMillionContext, isTrue);
    expect(
      settings.aiMaxTokensUpperBound,
      SettingsState.millionContextAiMaxTokens,
    );
    final reloaded = SettingsState(
      secureStorage: secureStorage,
      environment: const {},
    );
    addTearDown(reloaded.dispose);
    await reloaded.load();
    expect(reloaded.aiProviderId, provider.id);
    expect(reloaded.currentProviderSupportsMillionContext, isTrue);
    expect(reloaded.aiMaxTokens, SettingsState.millionContextAiMaxTokens);
    await expectLater(
      settings.setAiMaxTokens(SettingsState.millionContextAiMaxTokens + 1),
      throwsCourierCode('INVALID_SETTING'),
    );

    await settings.updateCustomProvider(
      id: provider.id,
      displayName: provider.displayName,
      baseUrl: provider.baseUrl,
      protocol: provider.protocol,
      supportsMillionContext: false,
    );
    expect(settings.aiMaxTokens, SettingsState.standardAiMaxTokens);

    await settings.deleteCustomProvider(provider.id);
    expect(settings.customProviders, isEmpty);
    expect(settings.aiProviderId, 'openai');
    expect(settings.aiModelId, isEmpty);
    expect(settings.apiKeyConfigured, isFalse);
    expect(
      credentialStore.values.containsKey('courier.ai.${provider.id}.api_key'),
      isFalse,
    );
  });

  test('损坏或非法标识的自定义供应商配置被忽略并安全回退', () async {
    SharedPreferences.setMockInitialValues({
      'ai_provider': '9invalid',
      'ai_max_tokens': SettingsState.millionContextAiMaxTokens,
      'custom_ai_providers': jsonEncode([
        {
          'id': '9invalid',
          'displayName': '非法供应商',
          'baseUrl': 'https://api.openai.com/v1/',
          'protocol': ProviderProtocol.openaiCompatible.name,
          'supportsMillionContext': true,
          'createdAt': DateTime.utc(2026).toIso8601String(),
        },
      ]),
    });
    final settings = SettingsState(
      secureStorage: SecureStorageService(store: MemoryCredentialStore()),
      environment: const {},
    );
    addTearDown(settings.dispose);

    await settings.load();

    expect(settings.customProviders, isEmpty);
    expect(settings.aiProviderId, 'openai');
    expect(settings.aiMaxTokens, SettingsState.standardAiMaxTokens);
  });
}
