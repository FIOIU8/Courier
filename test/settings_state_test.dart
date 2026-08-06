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

  test('请求方式按供应商保存、校验与读盘回退', () async {
    SharedPreferences.setMockInitialValues({
      'ai_request_modes': jsonEncode({
        'openai': 'responses',
        'anthropic': 'responses', // 与 anthropic 协议不兼容 → 读盘丢弃
        'unknown-provider': 'responses', // 非已知供应商 → 丢弃
      }),
    });
    final settings = SettingsState(
      secureStorage: SecureStorageService(store: MemoryCredentialStore()),
      environment: const {},
    );
    addTearDown(settings.dispose);
    await settings.load();

    expect(settings.aiRequestMode, AIRequestMode.responses);
    expect(settings.aiRequestModes, [
      AIRequestMode.chatCompletions,
      AIRequestMode.responses,
    ]);

    // anthropic 供应商：不兼容方式被拒绝，未保存时按协议取默认
    await expectLater(
      settings.setAiRequestModeFor('anthropic', AIRequestMode.responses),
      throwsCourierCode('INVALID_SETTING'),
    );
    await settings.setAiProviderId('anthropic');
    expect(settings.aiRequestMode, AIRequestMode.anthropic);
    expect(settings.aiRequestModes, [AIRequestMode.anthropic]);

    // openai 的保存值不受 anthropic 切换影响
    await settings.setAiProviderId('openai');
    expect(settings.aiRequestMode, AIRequestMode.responses);

    // 重新加载后保留上次选择
    final reloaded = SettingsState(
      secureStorage: SecureStorageService(store: MemoryCredentialStore()),
      environment: const {},
    );
    addTearDown(reloaded.dispose);
    await reloaded.load();
    expect(reloaded.aiRequestMode, AIRequestMode.responses);
  });

  test('自定义供应商协议决定请求方式选项并随删除清理', () async {
    final settings = SettingsState(
      secureStorage: SecureStorageService(store: MemoryCredentialStore()),
      environment: const {},
    );
    addTearDown(settings.dispose);
    await settings.load();

    final provider = await settings.addCustomProvider(
      displayName: '中转站',
      baseUrl: 'https://api.example.com/',
      supportsMillionContext: true,
    );
    await settings.setAiProviderId(provider.id);
    expect(settings.aiRequestModes, contains(AIRequestMode.responses));
    await settings.setAiRequestModeFor(provider.id, AIRequestMode.responses);
    expect(settings.aiRequestMode, AIRequestMode.responses);

    // 删除当前供应商后其请求方式记录被清理，回退 openai 默认
    await settings.deleteCustomProvider(provider.id);
    expect(settings.aiProviderId, 'openai');
    expect(settings.aiRequestMode, AIRequestMode.chatCompletions);
  });

  test('系统提示词持久化、去控制字符并限制长度', () async {
    final settings = SettingsState(
      secureStorage: SecureStorageService(store: MemoryCredentialStore()),
      environment: const {},
    );
    addTearDown(settings.dispose);
    await settings.load();

    expect(settings.aiSystemPrompt, isEmpty);
    await settings.setAiSystemPrompt('你是代码助手\n保持简洁。');
    expect(settings.aiSystemPrompt, '你是代码助手\n保持简洁。');

    // 超长截断，控制字符（除换行/制表外）被清除
    await settings.setAiSystemPrompt('${'a' * 5000}\u0000');
    expect(settings.aiSystemPrompt, 'a' * 4000);

    // 重新加载后保留
    final reloaded = SettingsState(
      secureStorage: SecureStorageService(store: MemoryCredentialStore()),
      environment: const {},
    );
    addTearDown(reloaded.dispose);
    await reloaded.load();
    expect(reloaded.aiSystemPrompt, 'a' * 4000);
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

  test('模型集合支持增删、去重、非法标识拒绝与持久化往返', () async {
    final settings = SettingsState(
      secureStorage: SecureStorageService(store: MemoryCredentialStore()),
      environment: const {},
    );
    addTearDown(settings.dispose);
    await settings.load();
    expect(settings.aiModelIds, isEmpty);

    await settings.addAiModel('gpt-4o');
    await settings.addAiModel('gpt-4o'); // 去重：已存在视为成功
    await settings.addAiModel('claude-sonnet-4-5');
    expect(settings.aiModelIds, ['gpt-4o', 'claude-sonnet-4-5']);

    // 非法标识被拒绝且不改变集合
    await expectLater(
      settings.addAiModel('invalid\u0000model'),
      throwsCourierCode('INVALID_SETTING'),
    );
    await expectLater(
      settings.addAiModel(''),
      throwsCourierCode('INVALID_SETTING'),
    );
    expect(settings.aiModelIds, hasLength(2));

    // ai_model_ids 持久化往返
    final reloaded = SettingsState(
      secureStorage: SecureStorageService(store: MemoryCredentialStore()),
      environment: const {},
    );
    addTearDown(reloaded.dispose);
    await reloaded.load();
    expect(reloaded.aiModelIds, ['gpt-4o', 'claude-sonnet-4-5']);

    // 移除非默认模型；移除不存在模型为无操作
    await settings.removeAiModel('gpt-4o');
    expect(settings.aiModelIds, ['claude-sonnet-4-5']);
    await settings.removeAiModel('not-exists');
    expect(settings.aiModelIds, ['claude-sonnet-4-5']);
  });

  test('模型集合数量上限为 maxAiModels', () async {
    final settings = SettingsState(
      secureStorage: SecureStorageService(store: MemoryCredentialStore()),
      environment: const {},
    );
    addTearDown(settings.dispose);
    await settings.load();

    for (var index = 0; index < SettingsState.maxAiModels; index++) {
      await settings.addAiModel('model-$index');
    }
    expect(settings.aiModelIds.length, SettingsState.maxAiModels);
    await expectLater(
      settings.addAiModel('overflow-model'),
      throwsCourierCode('INVALID_SETTING'),
    );
    expect(settings.aiModelIds.length, SettingsState.maxAiModels);
  });

  test('默认模型约束：隐式加入集合、删除回退与置空', () async {
    final settings = SettingsState(
      secureStorage: SecureStorageService(store: MemoryCredentialStore()),
      environment: const {},
    );
    addTearDown(settings.dispose);
    await settings.load();

    // 设置默认模型时自动加入集合（隐式 addAiModel）
    await settings.setAiModelId('default-model');
    expect(settings.aiModelIds, ['default-model']);
    expect(settings.aiModelId, 'default-model');

    await settings.addAiModel('second-model');
    await settings.setAiModelId('second-model');
    expect(settings.aiModelIds, ['default-model', 'second-model']);
    expect(settings.aiModelId, 'second-model');

    // 删除默认模型 → 回退为集合第一个
    await settings.removeAiModel('second-model');
    expect(settings.aiModelId, 'default-model');
    expect(settings.aiModelIds, ['default-model']);

    // 删除集合最后一个模型 → 默认模型置空并清除 ai_model
    await settings.removeAiModel('default-model');
    expect(settings.aiModelId, isEmpty);
    expect(settings.aiModelIds, isEmpty);
    expect(settings.aiConfigurationReady, isFalse);

    // 置空默认模型时集合保留
    await settings.addAiModel('keep-me');
    await settings.setAiModelId('');
    expect(settings.aiModelId, isEmpty);
    expect(settings.aiModelIds, ['keep-me']);
  });

  test('旧数据迁移：仅有 ai_model 时初始化为单元素集合', () async {
    SharedPreferences.setMockInitialValues({
      'ai_provider': 'openai',
      'ai_model': 'legacy-model',
    });
    final settings = SettingsState(
      secureStorage: SecureStorageService(store: MemoryCredentialStore()),
      environment: const {},
    );
    addTearDown(settings.dispose);
    await settings.load();

    expect(settings.aiModelId, 'legacy-model');
    expect(settings.aiModelIds, ['legacy-model']);
  });

  test('load 时 ai_model 不在集合内则补入（环境变量模型）', () async {
    SharedPreferences.setMockInitialValues({
      'ai_model_ids': jsonEncode(['existing-model']),
    });
    final settings = SettingsState(
      secureStorage: SecureStorageService(store: MemoryCredentialStore()),
      environment: const {'COURIER_AI_MODEL_ID': 'env-model'},
    );
    addTearDown(settings.dispose);
    await settings.load();

    expect(settings.aiModelId, 'env-model');
    expect(settings.aiModelIds, containsAll(['existing-model', 'env-model']));
  });

  test('load 时集合已满则替换首位保证默认模型在集合内且不超上限', () async {
    final storedIds = List<String>.generate(
      SettingsState.maxAiModels,
      (index) => 'stored-$index',
      growable: false,
    );
    SharedPreferences.setMockInitialValues({
      'ai_model_ids': jsonEncode(storedIds),
      'ai_model': 'stored-0',
    });
    final settings = SettingsState(
      secureStorage: SecureStorageService(store: MemoryCredentialStore()),
      environment: const {'COURIER_AI_MODEL_ID': 'env-model'},
    );
    addTearDown(settings.dispose);
    await settings.load();

    expect(settings.aiModelId, 'env-model');
    expect(settings.aiModelIds, hasLength(SettingsState.maxAiModels));
    expect(settings.aiModelIds.first, 'env-model');
    expect(settings.aiModelIds.contains('env-model'), isTrue);
  });

  test('主题设置持久化往返：路径、透明度与 UI 样式', () async {
    SharedPreferences.setMockInitialValues({
      'theme_background_image': r'C:\images\wallpaper.png',
      'theme_background_opacity': 0.85,
      'theme_ui_style': 'vscode',
    });
    final settings = SettingsState(
      secureStorage: SecureStorageService(store: MemoryCredentialStore()),
      environment: const {},
    );
    addTearDown(settings.dispose);
    await settings.load();

    expect(settings.backgroundImagePath, r'C:\images\wallpaper.png');
    expect(settings.backgroundOpacity, 0.85);
    expect(settings.uiStyle, AppUiStyle.vscode);

    await settings.setBackgroundImagePath(r'D:\new\bg.jpg');
    await settings.setBackgroundOpacity(0.5);
    await settings.setUiStyle(AppUiStyle.material3);
    expect(settings.backgroundOpacity, 0.5);
    expect(settings.uiStyle, AppUiStyle.material3);

    // 清空路径视为"无背景图"
    await settings.setBackgroundImagePath('   ');
    expect(settings.backgroundImagePath, isEmpty);

    final reloaded = SettingsState(
      secureStorage: SecureStorageService(store: MemoryCredentialStore()),
      environment: const {},
    );
    addTearDown(reloaded.dispose);
    await reloaded.load();
    expect(reloaded.backgroundImagePath, isEmpty);
    expect(reloaded.backgroundOpacity, 0.5);
    expect(reloaded.uiStyle, AppUiStyle.material3);
  });

  test('主题字段读盘钳制：透明度越界、样式未知、路径非法', () async {
    SharedPreferences.setMockInitialValues({
      'theme_background_opacity': 5.0,
      'theme_ui_style': 'unknown-style',
      'theme_background_image': 'x' * (SettingsState.maxBackgroundImagePathLength + 1),
    });
    final settings = SettingsState(
      secureStorage: SecureStorageService(store: MemoryCredentialStore()),
      environment: const {},
    );
    addTearDown(settings.dispose);
    await settings.load();

    expect(settings.backgroundOpacity, 1.0);
    expect(settings.uiStyle, AppUiStyle.material3);
    expect(settings.backgroundImagePath, isEmpty);

    // 负透明度钳制到 0
    SharedPreferences.setMockInitialValues({
      'theme_background_opacity': -1.0,
    });
    final negative = SettingsState(
      secureStorage: SecureStorageService(store: MemoryCredentialStore()),
      environment: const {},
    );
    addTearDown(negative.dispose);
    await negative.load();
    expect(negative.backgroundOpacity, 0.0);
    expect(negative.backgroundImagePath, isEmpty);
    expect(negative.uiStyle, AppUiStyle.material3);

    // setter 拒绝越界透明度
    await expectLater(
      negative.setBackgroundOpacity(1.5),
      throwsCourierCode('INVALID_SETTING'),
    );
    await expectLater(
      negative.setBackgroundOpacity(double.nan),
      throwsCourierCode('INVALID_SETTING'),
    );
  });

  test('主题字段默认值与非法路径 setter 处理', () async {
    final settings = SettingsState(
      secureStorage: SecureStorageService(store: MemoryCredentialStore()),
      environment: const {},
    );
    addTearDown(settings.dispose);
    await settings.load();

    expect(settings.backgroundImagePath, isEmpty);
    expect(settings.backgroundOpacity, SettingsState.defaultBackgroundOpacity);
    expect(settings.uiStyle, AppUiStyle.material3);

    // 非法路径（含控制字符）按空值处理
    await settings.setBackgroundImagePath('bad\u0000path');
    expect(settings.backgroundImagePath, isEmpty);

    // 同值设置不触发持久化也不报错
    await settings.setUiStyle(AppUiStyle.material3);
    await settings.setBackgroundOpacity(SettingsState.defaultBackgroundOpacity);
  });

  test('模糊强度/透明度：persist:false 实时更新内存但不写盘', () async {
    final settings = SettingsState(
      secureStorage: SecureStorageService(store: MemoryCredentialStore()),
      environment: const {},
    );
    addTearDown(settings.dispose);
    await settings.load();
    final prefs = await SharedPreferences.getInstance();

    // 模糊强度：拖动实时更新内存，未持久化
    await settings.setBlurSigma(20, persist: false);
    expect(settings.blurSigma, 20);
    expect(prefs.getDouble('blur_sigma'), isNull, reason: 'persist:false 不应写盘');

    // 松手持久化
    await settings.setBlurSigma(8);
    expect(settings.blurSigma, 8);
    expect(prefs.getDouble('blur_sigma'), 8);

    // 透明度：同上
    await settings.setBackgroundOpacity(0.5, persist: false);
    expect(settings.backgroundOpacity, 0.5);
    expect(
      prefs.getDouble('theme_background_opacity'),
      isNull,
      reason: 'persist:false 不应写盘',
    );
    await settings.setBackgroundOpacity(0.7);
    expect(settings.backgroundOpacity, 0.7);
    expect(prefs.getDouble('theme_background_opacity'), 0.7);

    // persist:false 仍拒绝越界值
    await expectLater(
      settings.setBackgroundOpacity(1.5, persist: false),
      throwsCourierCode('INVALID_SETTING'),
    );
  });

  test('背景图片历史：加入、去重置顶、上限截断与重载保留', () async {
    final settings = SettingsState(
      secureStorage: SecureStorageService(store: MemoryCredentialStore()),
      environment: const {},
    );
    addTearDown(settings.dispose);
    await settings.load();
    expect(settings.backgroundImageHistory, isEmpty);

    // 依次设置，最新在前；重复路径去重置顶
    await settings.setBackgroundImagePath('a.png');
    await settings.setBackgroundImagePath('b.png');
    await settings.setBackgroundImagePath('a.png');
    expect(settings.backgroundImagePath, 'a.png');
    expect(settings.backgroundImageHistory, ['a.png', 'b.png']);

    // 上限截断：保留最新的 N 条
    for (var i = 0; i < SettingsState.maxBackgroundImageHistory; i++) {
      await settings.setBackgroundImagePath('img-$i.png');
    }
    expect(
      settings.backgroundImageHistory,
      hasLength(SettingsState.maxBackgroundImageHistory),
    );
    expect(
      settings.backgroundImageHistory.first,
      'img-${SettingsState.maxBackgroundImageHistory - 1}.png',
    );

    // 清空背景不清除历史
    await settings.setBackgroundImagePath('');
    expect(settings.backgroundImagePath, isEmpty);
    expect(settings.backgroundImageHistory, isNotEmpty);

    // 重载后保留
    final reloaded = SettingsState(
      secureStorage: SecureStorageService(store: MemoryCredentialStore()),
      environment: const {},
    );
    addTearDown(reloaded.dispose);
    await reloaded.load();
    expect(reloaded.backgroundImageHistory, settings.backgroundImageHistory);
  });

  test('背景图片历史读盘过滤非法项并去重', () async {
    SharedPreferences.setMockInitialValues({
      'theme_background_image_history': jsonEncode([
        'valid.png',
        'bad\u0000path', // 含控制字符 → 丢弃
        'x' * (SettingsState.maxBackgroundImagePathLength + 1), // 超长 → 丢弃
        42, // 非字符串 → 丢弃
        'valid.png', // 重复 → 去重
      ]),
    });
    final settings = SettingsState(
      secureStorage: SecureStorageService(store: MemoryCredentialStore()),
      environment: const {},
    );
    addTearDown(settings.dispose);
    await settings.load();
    expect(settings.backgroundImageHistory, ['valid.png']);
  });
}
