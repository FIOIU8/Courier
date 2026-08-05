// settings_state.dart - Validated global settings and credential references.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_error.dart';
import 'app_logger.dart';
import 'secure_storage_service.dart';

typedef PreferencesLoader = Future<SharedPreferences> Function();

class SettingsState extends ChangeNotifier {
  static const supportedProviders = {'openai', 'anthropic'};

  final SecureStorageService secureStorage;
  final PreferencesLoader _preferencesLoader;
  final Map<String, String> _environment;
  Future<void> _writeChain = Future<void>.value();

  double _aiTemperature = 0.7;
  int _aiMaxTokens = 4096;
  String _aiProviderId = 'openai';
  String _aiModelId = '';
  bool _apiKeyConfigured = false;
  int _editorFontSize = 14;
  bool _autoSave = false;
  int _autoSaveDelaySeconds = 5;
  int _maxConcurrent = 3;
  bool _queueAutoStart = false;
  bool _restoreWorkspace = true;
  bool _showHiddenFiles = false;
  AppLogLevel _logLevel = AppLogLevel.info;
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
  bool get apiKeyConfigured => _apiKeyConfigured;
  int get editorFontSize => _editorFontSize;
  bool get autoSave => _autoSave;
  int get autoSaveDelaySeconds => _autoSaveDelaySeconds;
  int get maxConcurrent => _maxConcurrent;
  bool get queueAutoStart => _queueAutoStart;
  bool get restoreWorkspace => _restoreWorkspace;
  bool get showHiddenFiles => _showHiddenFiles;
  AppLogLevel get logLevel => _logLevel;
  bool get loaded => _loaded;

  bool get aiConfigurationReady =>
      _apiKeyConfigured && _aiModelId.trim().isNotEmpty;

  Future<void> load() async {
    final preferences = await _preferencesLoader();
    _aiTemperature = _boundedDouble(
      preferences.getDouble('ai_temperature') ?? 0.7,
      0.0,
      2.0,
    );
    _aiMaxTokens = _boundedInt(
      preferences.getInt('ai_max_tokens') ?? 4096,
      256,
      131072,
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

    final environmentModel = _environment['COURIER_AI_MODEL_ID']?.trim();
    final storedModel = preferences.getString('ai_model')?.trim();
    _aiModelId = _validatedModel(
      environmentModel ?? storedModel ?? '',
      fallbackToEmpty: true,
    );

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
    if (value < 256 || value > 131072) {
      throw const CourierException(
        'INVALID_SETTING',
        '最大 Token 必须位于 256 到 131072',
      );
    }
    await _persist((preferences) => preferences.setInt('ai_max_tokens', value));
    _aiMaxTokens = value;
    notifyListeners();
  }

  Future<void> setAiProviderId(String value) async {
    final provider = _validatedProvider(value);
    final apiKeyConfigured = await secureStorage.hasApiKey(provider);
    await _persist(
      (preferences) => preferences.setString('ai_provider', provider),
    );
    _aiProviderId = provider;
    _apiKeyConfigured = apiKeyConfigured;
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

  static String _validatedProvider(
    String value, {
    bool fallbackToDefault = false,
  }) {
    final provider = value.trim().toLowerCase();
    if (!supportedProviders.contains(provider)) {
      if (fallbackToDefault) return 'openai';
      throw const CourierException('INVALID_SETTING', 'AI Provider 标识无效');
    }
    return provider;
  }

  static String _validatedModel(String value, {bool fallbackToEmpty = false}) {
    final model = value.trim();
    if (model.length > 128 || model.contains(RegExp(r'[\x00-\x1f]'))) {
      if (fallbackToEmpty) return '';
      throw const CourierException('INVALID_SETTING', 'AI 模型标识无效');
    }
    return model;
  }

  static int _boundedInt(int value, int min, int max) => value.clamp(min, max);

  static double _boundedDouble(double value, double min, double max) =>
      value.clamp(min, max);

  static AppLogLevel _parseLogLevel(String value) {
    return AppLogLevel.values.firstWhere(
      (level) => level.name == value.trim().toLowerCase(),
      orElse: () => AppLogLevel.info,
    );
  }
}
