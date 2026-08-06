// settings_state.dart - Validated global settings and credential references.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color, Colors;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_error.dart';
import 'app_logger.dart';
import 'models.dart';
import 'secure_storage_service.dart';

typedef PreferencesLoader = Future<SharedPreferences> Function();

class SettingsState extends ChangeNotifier {
  static const supportedProviders = {'openai', 'anthropic'};
  static const int minAiMaxTokens = 256;
  static const int standardAiMaxTokens = 131072;
  static const int millionContextAiMaxTokens = 1000000;
  static const int maxSystemPromptLength = 4000;
  static const int _maxCustomProviders = 50;
  static const String _customProvidersKey = 'custom_ai_providers';
  static final Random _secureRandom = Random.secure();

  /// 默认强调色（teal，对齐原项目主色调）
  static const int defaultAccentColorValue = 0xFF23B8A4;

  /// 自定义主题的预设强调色色板
  static const List<Color> accentPalette = [
    Color(0xFF23B8A4), // teal
    Color(0xFF3B82F6), // blue
    Color(0xFF8B5CF6), // purple
    Color(0xFFF59E0B), // amber
    Color(0xFFEC4899), // pink
    Color(0xFF10B981), // green
  ];

  /// 与 [accentPalette] 一一对应的名称
  static const List<String> accentPaletteNames = [
    '青绿',
    '蓝',
    '紫',
    '琥珀',
    '粉',
    '绿',
  ];

  final SecureStorageService secureStorage;
  final PreferencesLoader _preferencesLoader;
  final Map<String, String> _environment;
  Future<void> _writeChain = Future<void>.value();

  double _aiTemperature = 0.7;
  int _aiMaxTokens = 4096;
  String _aiProviderId = 'openai';
  String _aiModelId = '';
  String _aiSystemPrompt = '';

  /// 每个供应商单独保存的请求方式；未保存时按供应商协议取默认值
  final Map<String, AIRequestMode> _aiRequestModes = {};
  bool _apiKeyConfigured = false;
  List<CustomAIProvider> _customProviders = const [];
  int _editorFontSize = 14;
  bool _autoSave = false;
  int _autoSaveDelaySeconds = 5;
  int _maxConcurrent = 3;
  bool _queueAutoStart = false;
  bool _restoreWorkspace = true;
  bool _showHiddenFiles = false;
  AppLogLevel _logLevel = AppLogLevel.info;
  int _accentColorValue = defaultAccentColorValue;

  /// 毛玻璃模糊总开关（false 时 Glass 退化为半透明圆角卡片）
  bool _glassEnabled = true;

  /// 毛玻璃模糊强度（0 = 无模糊）
  double _blurSigma = 14;
  bool _loaded = false;

  SettingsState({
    required this.secureStorage,
    PreferencesLoader? preferencesLoader,
    Map<String, String>? environment,
  }) : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
       _environment = environment ?? Platform.environment;

  double get aiTemperature => _aiTemperature;
  int get aiMaxTokens => _aiMaxTokens;
  String get aiProviderId => _aiProviderId;
  String get aiModelId => _aiModelId;

  /// 当前供应商的请求方式（供应商未单独设置时按协议取默认值）
  AIRequestMode get aiRequestMode => aiRequestModeFor(_aiProviderId);

  /// 指定供应商的请求方式（未单独设置时按协议取默认值）
  AIRequestMode aiRequestModeFor(String providerId) =>
      _aiRequestModes[providerId] ?? _defaultRequestModeFor(providerId);

  /// 当前供应商支持的请求方式（openai 兼容 → Chat Completions/Responses；
  /// anthropic 兼容 → Anthropic API）
  List<AIRequestMode> get aiRequestModes =>
      _compatibleRequestModes(_aiProviderId);

  String get aiSystemPrompt => _aiSystemPrompt;

  bool get apiKeyConfigured => _apiKeyConfigured;
  List<CustomAIProvider> get customProviders =>
      List<CustomAIProvider>.unmodifiable(_customProviders);
  int get editorFontSize => _editorFontSize;
  bool get autoSave => _autoSave;
  int get autoSaveDelaySeconds => _autoSaveDelaySeconds;
  int get maxConcurrent => _maxConcurrent;
  bool get queueAutoStart => _queueAutoStart;
  bool get restoreWorkspace => _restoreWorkspace;
  bool get showHiddenFiles => _showHiddenFiles;
  AppLogLevel get logLevel => _logLevel;
  bool get loaded => _loaded;

  /// 是否启用毛玻璃模糊
  bool get glassEnabled => _glassEnabled;

  /// 毛玻璃模糊强度（0~30）
  double get blurSigma => _blurSigma;

  /// 当前强调色（自定义主题）
  Color get accentColor => Color(_accentColorValue);

  /// 强调色浅色（用于高亮文本/图标）
  Color get accentLightColor =>
      Color.lerp(accentColor, Colors.white, 0.35) ?? accentColor;

  bool get aiConfigurationReady =>
      _apiKeyConfigured && _aiModelId.trim().isNotEmpty;

  bool get currentProviderSupportsMillionContext =>
      _providerSupportsMillionContext(_aiProviderId);

  int get aiMaxTokensUpperBound => currentProviderSupportsMillionContext
      ? millionContextAiMaxTokens
      : standardAiMaxTokens;

  Future<void> load() async {
    final preferences = await _preferencesLoader();
    _customProviders = _decodeCustomProviders(
      preferences.getString(_customProvidersKey),
    );
    _aiTemperature = _boundedDouble(
      preferences.getDouble('ai_temperature') ?? 0.7,
      0.0,
      2.0,
    );
    final environmentProvider = _environment['COURIER_AI_PROVIDER_ID']
        ?.trim()
        .toLowerCase();
    final storedProvider = preferences
        .getString('ai_provider')
        ?.trim()
        .toLowerCase();
    _aiProviderId = _validatedProvider(
      environmentProvider ?? storedProvider ?? 'openai',
      fallbackToDefault: true,
    );
    _aiMaxTokens = _boundedInt(
      preferences.getInt('ai_max_tokens') ?? 4096,
      minAiMaxTokens,
      _maxTokensForProvider(_aiProviderId),
    );

    final environmentModel = _environment['COURIER_AI_MODEL_ID']?.trim();
    final storedModel = preferences.getString('ai_model')?.trim();
    _aiModelId = _validatedModel(
      environmentModel ?? storedModel ?? '',
      fallbackToEmpty: true,
    );
    _aiSystemPrompt = _readSystemPrompt(
      preferences.getString('ai_system_prompt'),
    );
    _aiRequestModes
      ..clear()
      ..addAll(_readRequestModes(preferences.getString('ai_request_modes')));

    _editorFontSize = _boundedInt(
      preferences.getInt('editor_font_size') ?? 14,
      12,
      24,
    );
    _autoSave = preferences.getBool('auto_save') ?? false;
    _autoSaveDelaySeconds = _boundedInt(
      preferences.getInt('auto_save_delay_seconds') ?? 5,
      1,
      30,
    );

    final environmentConcurrency = int.tryParse(
      _environment['COURIER_TASK_MAX_CONCURRENCY'] ?? '',
    );
    _maxConcurrent = _boundedInt(
      environmentConcurrency ?? preferences.getInt('max_concurrent') ?? 3,
      1,
      10,
    );
    _queueAutoStart = preferences.getBool('queue_auto_start') ?? false;
    _restoreWorkspace = preferences.getBool('restore_workspace') ?? true;
    _showHiddenFiles = preferences.getBool('show_hidden_files') ?? false;
    _logLevel = _parseLogLevel(
      _environment['COURIER_LOG_LEVEL'] ??
          preferences.getString('log_level') ??
          AppLogLevel.info.name,
    );
    // 读盘校验：仅接受色板内的值，否则回退默认（与 setAccentColor 对称）
    final storedAccent = preferences.getInt('accent_color');
    _accentColorValue =
        accentPalette.any((item) => item.toARGB32() == storedAccent)
        ? storedAccent!
        : defaultAccentColorValue;
    _glassEnabled = preferences.getBool('glass_enabled') ?? true;
    _blurSigma = _boundedDouble(
      preferences.getDouble('blur_sigma') ?? 14,
      0.0,
      30.0,
    );
    _apiKeyConfigured = await secureStorage.hasApiKey(_aiProviderId);
    _loaded = true;
    notifyListeners();
  }

  Future<void> setAiTemperature(double value) async {
    if (!value.isFinite || value < 0.0 || value > 2.0) {
      throw const CourierException('INVALID_SETTING', '温度必须位于 0.0 到 2.0');
    }
    await _persist(
      (preferences) => preferences.setDouble('ai_temperature', value),
    );
    _aiTemperature = value;
    notifyListeners();
  }

  Future<void> setAiMaxTokens(int value) async {
    final upperBound = aiMaxTokensUpperBound;
    if (value < minAiMaxTokens || value > upperBound) {
      throw CourierException(
        'INVALID_SETTING',
        '最大 Token 必须位于 $minAiMaxTokens 到 $upperBound',
      );
    }
    await _persist((preferences) => preferences.setInt('ai_max_tokens', value));
    _aiMaxTokens = value;
    notifyListeners();
  }

  Future<void> setAiProviderId(String value) async {
    final provider = _validatedProvider(value);
    final apiKeyConfigured = await secureStorage.hasApiKey(provider);
    final maxTokens = _boundedInt(
      _aiMaxTokens,
      minAiMaxTokens,
      _maxTokensForProvider(provider),
    );
    await _persist((preferences) async {
      if (maxTokens != _aiMaxTokens &&
          !await preferences.setInt('ai_max_tokens', maxTokens)) {
        return false;
      }
      return preferences.setString('ai_provider', provider);
    });
    _aiProviderId = provider;
    _aiMaxTokens = maxTokens;
    _apiKeyConfigured = apiKeyConfigured;
    notifyListeners();
  }

  /// 保存某个供应商的请求方式；不兼容的值被拒绝
  Future<void> setAiRequestModeFor(
    String providerId,
    AIRequestMode value,
  ) async {
    final normalized = _validatedProvider(providerId);
    if (!_compatibleRequestModes(normalized).contains(value)) {
      throw const CourierException('INVALID_SETTING', '当前供应商不支持该请求方式');
    }
    final next = Map<String, AIRequestMode>.of(_aiRequestModes);
    final previous = next[normalized];
    if (previous == value) return;
    next[normalized] = value;
    await _persist(
      (preferences) => preferences.setString(
        'ai_request_modes',
        jsonEncode(
          next.map((id, mode) => MapEntry(id, mode.name)),
        ),
      ),
    );
    _aiRequestModes
      ..clear()
      ..addAll(next);
    notifyListeners();
  }

  Future<void> setAiSystemPrompt(String value) async {
    final prompt = _readSystemPrompt(value);
    if (prompt == _aiSystemPrompt) return;
    await _persist(
      (preferences) => preferences.setString('ai_system_prompt', prompt),
    );
    _aiSystemPrompt = prompt;
    notifyListeners();
  }

  Future<CustomAIProvider> addCustomProvider({
    required String displayName,
    required String baseUrl,
    ProviderProtocol protocol = ProviderProtocol.openaiCompatible,
    bool supportsMillionContext = false,
  }) async {
    if (_customProviders.length >= _maxCustomProviders) {
      throw const CourierException('INVALID_SETTING', '自定义供应商数量已达到上限');
    }
    final provider = _createCustomProvider(
      displayName: displayName,
      baseUrl: baseUrl,
      protocol: protocol,
      supportsMillionContext: supportsMillionContext,
    );
    final updated = [..._customProviders, provider];
    await _persistCustomProviders(updated);
    _customProviders = List<CustomAIProvider>.unmodifiable(updated);
    notifyListeners();
    return provider;
  }

  Future<void> updateCustomProvider({
    required String id,
    required String displayName,
    required String baseUrl,
    required ProviderProtocol protocol,
    required bool supportsMillionContext,
  }) async {
    final providerId = id.trim().toLowerCase();
    final index = _customProviders.indexWhere(
      (provider) => provider.id == providerId,
    );
    if (index < 0) {
      throw const CourierException('INVALID_SETTING', '自定义供应商不存在');
    }

    final replacement = _validatedCustomProvider(
      id: providerId,
      displayName: displayName,
      baseUrl: baseUrl,
      protocol: protocol,
      supportsMillionContext: supportsMillionContext,
      createdAt: _customProviders[index].createdAt,
    );
    final updated = [..._customProviders]..[index] = replacement;
    final maxTokens = providerId == _aiProviderId
        ? _boundedInt(
            _aiMaxTokens,
            minAiMaxTokens,
            supportsMillionContext
                ? millionContextAiMaxTokens
                : standardAiMaxTokens,
          )
        : _aiMaxTokens;
    await _persist((preferences) async {
      if (maxTokens != _aiMaxTokens &&
          !await preferences.setInt('ai_max_tokens', maxTokens)) {
        return false;
      }
      return preferences.setString(
        _customProvidersKey,
        _encodeCustomProviders(updated),
      );
    });
    _customProviders = List<CustomAIProvider>.unmodifiable(updated);
    _aiMaxTokens = maxTokens;
    notifyListeners();
  }

  Future<void> deleteCustomProvider(String id) async {
    final providerId = id.trim().toLowerCase();
    if (!CustomAIProvider.idPattern.hasMatch(providerId)) {
      throw const CourierException('INVALID_SETTING', '供应商标识无效');
    }
    final index = _customProviders.indexWhere(
      (provider) => provider.id == providerId,
    );
    if (index < 0) {
      throw const CourierException('INVALID_SETTING', '自定义供应商不存在');
    }

    final updated = [..._customProviders]..removeAt(index);
    final deletingCurrent = providerId == _aiProviderId;
    final fallbackApiKeyConfigured = deletingCurrent
        ? await secureStorage.hasApiKey('openai')
        : _apiKeyConfigured;
    final existingCredential = await secureStorage.readApiKey(providerId);
    await secureStorage.deleteApiKey(providerId);
    final nextRequestModes = Map<String, AIRequestMode>.of(_aiRequestModes)
      ..remove(providerId);

    try {
      await _persist((preferences) async {
        if (deletingCurrent) {
          final maxTokens = _boundedInt(
            _aiMaxTokens,
            minAiMaxTokens,
            standardAiMaxTokens,
          );
          if (!await preferences.setInt('ai_max_tokens', maxTokens)) {
            return false;
          }
          if (!await preferences.setString('ai_model', '')) return false;
          if (!await preferences.setString('ai_provider', 'openai')) {
            return false;
          }
        }
        final requestModesChanged =
            nextRequestModes.length != _aiRequestModes.length;
        if (requestModesChanged &&
            !await preferences.setString(
              'ai_request_modes',
              jsonEncode(
                nextRequestModes
                    .map((id, mode) => MapEntry(id, mode.name)),
              ),
            )) {
          return false;
        }
        return preferences.setString(
          _customProvidersKey,
          _encodeCustomProviders(updated),
        );
      });
    } catch (error, stackTrace) {
      if (existingCredential != null) {
        try {
          await secureStorage.saveApiKey(providerId, existingCredential);
        } catch (_) {
          throw const CourierException(
            'CREDENTIAL_ROLLBACK_FAILED',
            '删除供应商失败，且无法恢复原凭据状态',
          );
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    }

    _customProviders = List<CustomAIProvider>.unmodifiable(updated);
    _aiRequestModes
      ..clear()
      ..addAll(nextRequestModes);
    if (deletingCurrent) {
      _aiProviderId = 'openai';
      _aiModelId = '';
      _aiMaxTokens = _boundedInt(
        _aiMaxTokens,
        minAiMaxTokens,
        standardAiMaxTokens,
      );
      _apiKeyConfigured = fallbackApiKeyConfigured;
    }
    notifyListeners();
  }

  Future<void> setAiModelId(String value) async {
    final model = _validatedModel(value);
    await _persist((preferences) => preferences.setString('ai_model', model));
    _aiModelId = model;
    notifyListeners();
  }

  Future<void> saveApiKey(String value) async {
    await secureStorage.saveApiKey(_aiProviderId, value);
    _apiKeyConfigured = true;
    notifyListeners();
  }

  Future<void> deleteApiKey() async {
    await secureStorage.deleteApiKey(_aiProviderId);
    _apiKeyConfigured = false;
    notifyListeners();
  }

  Future<void> setEditorFontSize(int value) async {
    if (value < 12 || value > 24) {
      throw const CourierException('INVALID_SETTING', '编辑器字号必须位于 12 到 24');
    }
    await _persist(
      (preferences) => preferences.setInt('editor_font_size', value),
    );
    _editorFontSize = value;
    notifyListeners();
  }

  Future<void> setAutoSave(bool value) async {
    await _persist((preferences) => preferences.setBool('auto_save', value));
    _autoSave = value;
    notifyListeners();
  }

  Future<void> setAutoSaveDelaySeconds(int value) async {
    if (value < 1 || value > 30) {
      throw const CourierException('INVALID_SETTING', '自动保存延迟必须位于 1 到 30 秒');
    }
    await _persist(
      (preferences) => preferences.setInt('auto_save_delay_seconds', value),
    );
    _autoSaveDelaySeconds = value;
    notifyListeners();
  }

  Future<void> setMaxConcurrent(int value) async {
    if (value < 1 || value > 10) {
      throw const CourierException('INVALID_SETTING', '任务并发数必须位于 1 到 10');
    }
    await _persist(
      (preferences) => preferences.setInt('max_concurrent', value),
    );
    _maxConcurrent = value;
    notifyListeners();
  }

  Future<void> setQueueAutoStart(bool value) async {
    await _persist(
      (preferences) => preferences.setBool('queue_auto_start', value),
    );
    _queueAutoStart = value;
    notifyListeners();
  }

  Future<void> setRestoreWorkspace(bool value) async {
    await _persist(
      (preferences) => preferences.setBool('restore_workspace', value),
    );
    _restoreWorkspace = value;
    notifyListeners();
  }

  Future<void> setShowHiddenFiles(bool value) async {
    await _persist(
      (preferences) => preferences.setBool('show_hidden_files', value),
    );
    _showHiddenFiles = value;
    notifyListeners();
  }

  Future<void> setLogLevel(AppLogLevel value) async {
    await _persist(
      (preferences) => preferences.setString('log_level', value.name),
    );
    _logLevel = value;
    notifyListeners();
  }

  /// 设置自定义主题强调色（需在 [accentPalette] 范围内）
  Future<void> setAccentColor(Color color) async {
    final value = color.toARGB32();
    if (!accentPalette.any((item) => item.toARGB32() == value)) {
      throw const CourierException('INVALID_SETTING', '不支持的主题色');
    }
    if (value == _accentColorValue) return;
    await _persist((preferences) => preferences.setInt('accent_color', value));
    _accentColorValue = value;
    notifyListeners();
  }

  /// 设置毛玻璃模糊总开关
  Future<void> setGlassEnabled(bool value) async {
    if (value == _glassEnabled) return;
    await _persist(
      (preferences) => preferences.setBool('glass_enabled', value),
    );
    _glassEnabled = value;
    notifyListeners();
  }

  /// 设置毛玻璃模糊强度（0~30）
  Future<void> setBlurSigma(double value) async {
    final clamped = _boundedDouble(value, 0.0, 30.0);
    if (clamped == _blurSigma) return;
    await _persist(
      (preferences) => preferences.setDouble('blur_sigma', clamped),
    );
    _blurSigma = clamped;
    notifyListeners();
  }

  Future<void> flush() => _writeChain;

  Future<void> _persist(
    Future<bool> Function(SharedPreferences preferences) write,
  ) {
    _writeChain = _writeChain.catchError((Object _) {}).then((_) async {
      final preferences = await _preferencesLoader();
      final written = await write(preferences);
      if (!written) {
        throw const CourierException('PREFERENCES_WRITE_FAILED', '应用设置写入失败');
      }
    });
    return _writeChain;
  }

  String _validatedProvider(String value, {bool fallbackToDefault = false}) {
    final provider = value.trim().toLowerCase();
    final valid =
        CustomAIProvider.idPattern.hasMatch(provider) &&
        (supportedProviders.contains(provider) ||
            _customProviders.any((custom) => custom.id == provider));
    if (!valid) {
      if (fallbackToDefault) return 'openai';
      throw const CourierException('INVALID_SETTING', '供应商标识无效');
    }
    return provider;
  }

  /// 读取按供应商保存的请求方式；未知值或与协议不兼容的条目被丢弃
  Map<String, AIRequestMode> _readRequestModes(String? stored) {
    if (stored == null || stored.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(stored);
      if (decoded is! Map) return const {};
      final modes = <String, AIRequestMode>{};
      for (final entry in decoded.entries) {
        if (entry.key is! String || entry.value is! String) continue;
        final parsed = AIRequestMode.values
            .where((mode) => mode.name == entry.value)
            .firstOrNull;
        if (parsed == null) continue;
        final providerId = entry.key as String;
        if (!CustomAIProvider.idPattern.hasMatch(providerId) ||
            !_compatibleRequestModes(providerId).contains(parsed)) {
          continue;
        }
        modes[providerId] = parsed;
      }
      return modes;
    } on FormatException {
      return const {};
    }
  }

  /// 读取系统提示词：去除控制字符（保留换行/制表）并限制长度
  static String _readSystemPrompt(String? value) {
    final prompt = (value ?? '')
        .replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'), '');
    return prompt.length > maxSystemPromptLength
        ? prompt.substring(0, maxSystemPromptLength)
        : prompt;
  }

  /// 供应商协议允许的请求方式（openai 兼容 → Chat Completions/Responses；
  /// anthropic 兼容 → Anthropic API）
  List<AIRequestMode> _compatibleRequestModes(String providerId) {
    final custom = _customProviders
        .where((provider) => provider.id == providerId)
        .firstOrNull;
    final protocol = custom?.protocol ??
        (providerId == 'anthropic'
            ? ProviderProtocol.anthropicCompatible
            : ProviderProtocol.openaiCompatible);
    return protocol == ProviderProtocol.anthropicCompatible
        ? const [AIRequestMode.anthropic]
        : const [AIRequestMode.chatCompletions, AIRequestMode.responses];
  }

  AIRequestMode _defaultRequestModeFor(String providerId) =>
      _compatibleRequestModes(providerId).first;

  static String _validatedModel(String value, {bool fallbackToEmpty = false}) {
    final model = value.trim();
    if (model.length > 128 || model.contains(RegExp(r'[\x00-\x1f]'))) {
      if (fallbackToEmpty) return '';
      throw const CourierException('INVALID_SETTING', '供应商模型标识无效');
    }
    return model;
  }

  static int _boundedInt(int value, int min, int max) => value.clamp(min, max);

  static double _boundedDouble(double value, double min, double max) =>
      value.clamp(min, max);

  int _maxTokensForProvider(String providerId) =>
      _providerSupportsMillionContext(providerId)
      ? millionContextAiMaxTokens
      : standardAiMaxTokens;

  bool _providerSupportsMillionContext(String providerId) {
    return _customProviders
            .where((provider) => provider.id == providerId)
            .firstOrNull
            ?.supportsMillionContext ??
        false;
  }

  CustomAIProvider _createCustomProvider({
    required String displayName,
    required String baseUrl,
    required ProviderProtocol protocol,
    required bool supportsMillionContext,
  }) {
    for (var attempt = 0; attempt < 32; attempt++) {
      final timestamp = DateTime.now()
          .toUtc()
          .microsecondsSinceEpoch
          .toRadixString(36);
      final random = _secureRandom
          .nextInt(0x7fffffff)
          .toRadixString(36)
          .padLeft(6, '0');
      final id = 'custom-$timestamp-$random';
      if (_customProviders.every((provider) => provider.id != id)) {
        return _validatedCustomProvider(
          id: id,
          displayName: displayName,
          baseUrl: baseUrl,
          protocol: protocol,
          supportsMillionContext: supportsMillionContext,
          createdAt: DateTime.now().toUtc(),
        );
      }
    }
    throw const CourierException('ID_GENERATION_FAILED', '无法生成供应商标识');
  }

  CustomAIProvider _validatedCustomProvider({
    required String id,
    required String displayName,
    required String baseUrl,
    required ProviderProtocol protocol,
    required bool supportsMillionContext,
    required DateTime createdAt,
  }) {
    if (supportedProviders.contains(id)) {
      throw const CourierException('INVALID_SETTING', '供应商标识与内置供应商冲突');
    }
    try {
      return CustomAIProvider(
        id: id,
        displayName: displayName,
        baseUrl: baseUrl,
        protocol: protocol,
        supportsMillionContext: supportsMillionContext,
        createdAt: createdAt,
      );
    } on FormatException {
      throw const CourierException('INVALID_SETTING', '供应商名称或 Base API 地址无效');
    }
  }

  Future<void> _persistCustomProviders(List<CustomAIProvider> providers) {
    return _persist(
      (preferences) => preferences.setString(
        _customProvidersKey,
        _encodeCustomProviders(providers),
      ),
    );
  }

  static String _encodeCustomProviders(List<CustomAIProvider> providers) {
    return jsonEncode(
      providers.map((provider) => provider.toJson()).toList(growable: false),
    );
  }

  static List<CustomAIProvider> _decodeCustomProviders(String? value) {
    if (value == null || value.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(value);
      if (decoded is! List) return const [];
      final providers = <CustomAIProvider>[];
      final ids = <String>{};
      for (final item in decoded.take(_maxCustomProviders)) {
        if (item is! Map) continue;
        try {
          final provider = CustomAIProvider.fromJson(
            Map<String, dynamic>.from(item),
          );
          if (supportedProviders.contains(provider.id) ||
              !ids.add(provider.id)) {
            continue;
          }
          providers.add(provider);
        } on FormatException {
          continue;
        }
      }
      return List<CustomAIProvider>.unmodifiable(providers);
    } on FormatException {
      return const [];
    }
  }

  static AppLogLevel _parseLogLevel(String value) {
    return AppLogLevel.values.firstWhere(
      (level) => level.name == value.trim().toLowerCase(),
      orElse: () => AppLogLevel.info,
    );
  }
}
