// settings_page.dart - Unified global and workspace settings.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../services/app_error.dart';
import '../services/app_logger.dart';
import '../services/courier_service.dart';
import '../services/models.dart';
import '../services/settings_state.dart';
import '../services/workspace_service.dart';
import 'animations.dart';
import 'glass.dart';

class SettingsPage extends StatefulWidget {
  final VoidCallback? onClose;

  const SettingsPage({super.key, this.onClose});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const _sections = [
    (label: '供应商', icon: Icons.storefront_outlined),
    (label: '编辑器', icon: Icons.edit_note_outlined),
    (label: '任务', icon: Icons.queue_outlined),
    (label: '通用', icon: Icons.tune_outlined),
    (label: '外观', icon: Icons.palette_outlined),
    (label: '关于', icon: Icons.info_outline),
  ];

  final TextEditingController _modelController = TextEditingController();
  final TextEditingController _apiKeyController = TextEditingController();
  int _activeSection = 0;

  /// 区块切换滑动方向：1 = 新区块从右滑入；-1 = 从左滑入
  int _sectionSlideDirection = 1;

  /// 模糊强度拖动中的临时值（null = 未在拖动）
  double? _dragBlurSigma;
  bool _initialized = false;
  bool _loadingModels = false;
  bool _savingCredential = false;
  bool _savingProvider = false;
  List<AIModelOption> _availableModels = const [];
  String? _error;
  bool _errorCopied = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _modelController.text = context.read<SettingsState>().aiModelId;
  }

  @override
  void dispose() {
    _modelController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _changeProvider(String providerId) async {
    final settings = context.read<SettingsState>();
    try {
      await settings.setAiProviderId(providerId);
      _availableModels = const [];
      _apiKeyController.clear();
      setState(() => _error = null);
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _saveModel() async {
    try {
      await context.read<SettingsState>().setAiModelId(_modelController.text);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('模型设置已保存')));
      }
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _refreshModels() async {
    final settings = context.read<SettingsState>();
    if (!settings.apiKeyConfigured) {
      _showError('请先保存 API Key 再读取模型列表');
      return;
    }

    setState(() {
      _loadingModels = true;
      _error = null;
    });
    try {
      final models = await context.read<CourierService>().refreshAIModels();
      if (mounted) setState(() => _availableModels = models);
    } on CourierException catch (error) {
      // 直接展示 API 返回的错误信息（如 "Authentication Fails, Your api key is invalid"）
      _showError(
        error.code == 'MODELS_NOT_SUPPORTED'
            ? '该供应商不支持自动获取，可在下方手动添加模型'
            : error.message,
      );
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  Future<void> _saveApiKey() async {
    final value = _apiKeyController.text;
    setState(() {
      _savingCredential = true;
      _error = null;
    });
    try {
      await context.read<SettingsState>().saveApiKey(value);
      _apiKeyController.clear();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('API Key 已保存到系统凭据存储')));
      }
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _savingCredential = false);
    }
  }

  Future<void> _deleteApiKey() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: kDialogShape,
        backgroundColor: kGlassFloatBg,
        title: const Text('删除 API Key'),
        content: const Text('删除后，当前供应商将无法发送请求。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await context.read<SettingsState>().deleteApiKey();
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _showCustomProviderDialog([
    CustomAIProvider? existingProvider,
  ]) async {
    final result = await showDialog<_CustomProviderFormValue>(
      context: context,
      builder: (dialogContext) =>
          _CustomProviderDialog(existingProvider: existingProvider),
    );
    if (result == null || !mounted) return;

    setState(() {
      _savingProvider = true;
      _error = null;
    });
    try {
      final settings = context.read<SettingsState>();
      late final CustomAIProvider savedProvider;
      if (existingProvider == null) {
        savedProvider = await settings.addCustomProvider(
          displayName: result.displayName,
          baseUrl: result.baseUrl,
          protocol: result.protocol,
          supportsMillionContext: result.supportsMillionContext,
        );
      } else {
        await settings.updateCustomProvider(
          id: existingProvider.id,
          displayName: result.displayName,
          baseUrl: result.baseUrl,
          protocol: result.protocol,
          supportsMillionContext: result.supportsMillionContext,
        );
        savedProvider = settings.customProviders.firstWhere(
          (provider) => provider.id == existingProvider.id,
        );
      }

      if (result.apiKey.trim().isNotEmpty) {
        if (savedProvider.id == settings.aiProviderId) {
          await settings.saveApiKey(result.apiKey);
        } else {
          await settings.secureStorage.saveApiKey(
            savedProvider.id,
            result.apiKey,
          );
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(existingProvider == null ? '自定义供应商已添加' : '自定义供应商已更新'),
          ),
        );
      }
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _savingProvider = false);
    }
  }

  Future<void> _deleteCustomProvider(CustomAIProvider provider) async {
    final settings = context.read<SettingsState>();
    final deletingCurrent = settings.aiProviderId == provider.id;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: kDialogShape,
        backgroundColor: kGlassFloatBg,
        title: const Text('删除自定义供应商'),
        content: Text(
          deletingCurrent
              ? '将删除该供应商及其 API Key，并回退到 OpenAI。'
              : '将删除该供应商及其 API Key。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await settings.deleteCustomProvider(provider.id);
      if (deletingCurrent) {
        _modelController.clear();
        _apiKeyController.clear();
        _availableModels = const [];
      }
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _setShowHidden(bool value) async {
    final settings = context.read<SettingsState>();
    final workspace = context.read<WorkspaceService>();
    try {
      await settings.setShowHiddenFiles(value);
      if (workspace.hasWorkspace) await workspace.setShowHidden(value);
    } catch (error) {
      _showError(error);
    }
  }

  void _showError(Object error) {
    if (!mounted) return;
    setState(() {
      _error = '$error';
      _errorCopied = false;
    });
  }

  /// 复制错误信息到剪贴板，成功后短暂显示对勾反馈。
  Future<void> _copyError() async {
    final error = _error;
    if (error == null || _errorCopied) return;
    await Clipboard.setData(ClipboardData(text: error));
    if (!mounted) return;
    setState(() => _errorCopied = true);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _errorCopied = false);
  }

  Future<void> _applySetting(Future<void> Function() update) async {
    try {
      await update();
    } catch (error) {
      _showError(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 44,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => windowManager.startDragging(),
          ),
        ),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840, maxHeight: 640),
              child: Glass(
                radius: kRadiusLg,
                color: kGlassBg,
                boxShadow: kShadowLg,
                child: Material(
                  color: Colors.transparent,
                  child: Row(
                    children: [
                      SizedBox(width: 190, child: _buildSidebar()),
                      const VerticalDivider(width: 1, color: kGlassBorder),
                      Expanded(child: _buildContent()),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSidebar() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(18, 18, 18, 14),
          child: Text(
            '设置',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
        ),
        for (var index = 0; index < _sections.length; index++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            child: ListTile(
              dense: true,
              selected: _activeSection == index,
              selectedTileColor: kGlassSelectedBg,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(kRadiusSm),
              ),
              leading: Icon(_sections[index].icon, size: 18),
              title: Text(
                _sections[index].label,
                style: const TextStyle(fontSize: 13),
              ),
              onTap: () {
                if (index == _activeSection) return;
                setState(() {
                  _sectionSlideDirection = index > _activeSection ? 1 : -1;
                  _activeSection = index;
                });
              },
            ),
          ),
      ],
    );
  }

  Widget _buildContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 10, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _sections[_activeSection].label,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: '关闭设置',
                onPressed: widget.onClose,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 36,
                  height: 36,
                ),
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
        ),
        if (_error != null)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 24),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            color: const Color(0x1AEF4444),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Icon(
                    Icons.error_outline,
                    size: 15,
                    color: Color(0xFFEF4444),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFFFCA5A5),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '复制错误信息',
                  onPressed: _copyError,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 28,
                    height: 28,
                  ),
                  icon: Icon(
                    _errorCopied ? Icons.check : Icons.copy,
                    size: 14,
                    color: _errorCopied
                        ? const Color(0xFF10B981)
                        : const Color(0xFFFCA5A5),
                  ),
                ),
                IconButton(
                  tooltip: '关闭错误提示',
                  onPressed: () => setState(() => _error = null),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 28,
                    height: 28,
                  ),
                  icon: const Icon(Icons.close, size: 14),
                ),
              ],
            ),
          ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: _VerticalSlideSwitcher(
              direction: _sectionSlideDirection,
              child: KeyedSubtree(
                key: ValueKey(_activeSection),
                child: switch (_activeSection) {
                  0 => _buildAISettings(),
                  1 => _buildEditorSettings(),
                  2 => _buildTaskSettings(),
                  3 => _buildGeneralSettings(),
                  4 => _buildAppearanceSettings(),
                  _ => _buildAboutSettings(),
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAISettings() {
    final settings = context.watch<SettingsState>();
    final options = context.watch<CourierService>().aiOptions;
    final providerIds = options.providers
        .map((provider) => provider.id)
        .toSet();
    final maxTokens = settings.aiMaxTokensUpperBound;
    return Column(
      children: [
        _settingRow(
          label: '供应商',
          control: SizedBox(
            width: 260,
            child: DropdownButtonFormField<String>(
              key: ValueKey(settings.aiProviderId),
              initialValue: providerIds.contains(settings.aiProviderId)
                  ? settings.aiProviderId
                  : null,
              decoration: const InputDecoration(isDense: true),
              items: options.providers
                  .map(
                    (provider) => DropdownMenuItem(
                      value: provider.id,
                      child: Text(provider.displayName),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (provider) {
                if (provider != null) unawaited(_changeProvider(provider));
              },
            ),
          ),
        ),
        _settingRow(
          label: '自定义供应商',
          control: FilledButton.icon(
            onPressed: _savingProvider
                ? null
                : () => _showCustomProviderDialog(),
            icon: const Icon(Icons.add_business_outlined, size: 18),
            label: const Text('添加自定义供应商'),
          ),
        ),
        if (settings.customProviders.isNotEmpty)
          _buildCustomProviderList(settings.customProviders),
        _settingRow(
          label: '模型',
          control: SizedBox(
            width: 360,
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _modelController,
                    maxLength: 128,
                    decoration: const InputDecoration(
                      isDense: true,
                      counterText: '',
                    ),
                    onSubmitted: (_) => _saveModel(),
                  ),
                ),
                IconButton(
                  tooltip: '保存模型',
                  onPressed: _saveModel,
                  icon: const Icon(Icons.save_outlined, size: 18),
                ),
                IconButton(
                  tooltip: '读取模型列表',
                  onPressed: _loadingModels ? null : _refreshModels,
                  icon: _loadingModels
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 1.5),
                        )
                      : const Icon(Icons.refresh, size: 18),
                ),
              ],
            ),
          ),
        ),
        if (_availableModels.isNotEmpty)
          _settingRow(
            label: '可用模型',
            control: SizedBox(
              width: 360,
              child: DropdownButtonFormField<String>(
                initialValue:
                    _availableModels.any(
                      (model) => model.id == settings.aiModelId,
                    )
                    ? settings.aiModelId
                    : null,
                decoration: const InputDecoration(isDense: true),
                items: _availableModels
                    .map(
                      (model) => DropdownMenuItem(
                        value: model.id,
                        child: Text(
                          model.displayName,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (model) {
                  if (model == null) return;
                  _modelController.text = model;
                  unawaited(_saveModel());
                },
              ),
            ),
          ),
        _settingRow(
          label: 'API Key',
          control: SizedBox(
            width: 360,
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _apiKeyController,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    maxLength: 2048,
                    decoration: InputDecoration(
                      isDense: true,
                      counterText: '',
                      suffixIcon: Icon(
                        settings.apiKeyConfigured
                            ? Icons.verified_user_outlined
                            : Icons.key_outlined,
                        size: 17,
                        color: settings.apiKeyConfigured
                            ? const Color(0xFF10B981)
                            : Colors.white38,
                      ),
                    ),
                    onSubmitted: (_) => _saveApiKey(),
                  ),
                ),
                IconButton(
                  tooltip: '保存 API Key',
                  onPressed: _savingCredential ? null : _saveApiKey,
                  icon: const Icon(Icons.save_outlined, size: 18),
                ),
                IconButton(
                  tooltip: '删除 API Key',
                  onPressed: settings.apiKeyConfigured ? _deleteApiKey : null,
                  icon: const Icon(Icons.delete_outline, size: 18),
                ),
              ],
            ),
          ),
        ),
        _sliderRow(
          label: '温度',
          value: settings.aiTemperature,
          min: 0,
          max: 2,
          divisions: 40,
          display: settings.aiTemperature.toStringAsFixed(1),
          onChanged: (value) =>
              unawaited(_applySetting(() => settings.setAiTemperature(value))),
        ),
        _sliderRow(
          label: '最大 Token',
          value: settings.aiMaxTokens.toDouble(),
          min: SettingsState.minAiMaxTokens.toDouble(),
          max: maxTokens.toDouble(),
          divisions: ((maxTokens - SettingsState.minAiMaxTokens) / 256).round(),
          display: '${settings.aiMaxTokens}',
          onChanged: (value) => unawaited(
            _applySetting(() => settings.setAiMaxTokens(value.round())),
          ),
        ),
        if (settings.currentProviderSupportsMillionContext)
          _settingRow(
            label: '上下文能力',
            control: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.all_inclusive,
                  size: 17,
                  color: accentLightOf(context),
                ),
                const SizedBox(width: 6),
                Text(
                  '当前供应商支持百万上下文',
                  style: TextStyle(fontSize: 12, color: accentLightOf(context)),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildCustomProviderList(List<CustomAIProvider> providers) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          const Divider(height: 1, color: kGlassBorder),
          for (var index = 0; index < providers.length; index++) ...[
            Padding(
              key: ValueKey('custom-provider-${providers[index].id}'),
              padding: const EdgeInsets.symmetric(vertical: 9),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const SizedBox(width: 12),
                  const Icon(
                    Icons.storefront_outlined,
                    size: 18,
                    color: Colors.white54,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          providers[index].displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          providers[index].baseUrl,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white54,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            Text(
                              _protocolLabel(providers[index].protocol),
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.white38,
                              ),
                            ),
                            if (providers[index].supportsMillionContext) ...[
                              const SizedBox(width: 10),
                              Icon(
                                Icons.all_inclusive,
                                size: 13,
                                color: accentLightOf(context),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '百万上下文',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: accentLightOf(context),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '编辑 ${providers[index].displayName}',
                    onPressed: _savingProvider
                        ? null
                        : () => _showCustomProviderDialog(providers[index]),
                    icon: const Icon(Icons.edit_outlined, size: 17),
                  ),
                  IconButton(
                    tooltip: '删除 ${providers[index].displayName}',
                    onPressed: _savingProvider
                        ? null
                        : () => _deleteCustomProvider(providers[index]),
                    icon: const Icon(Icons.delete_outline, size: 17),
                  ),
                ],
              ),
            ),
            if (index != providers.length - 1)
              const Divider(height: 1, color: kGlassBorder),
          ],
          const Divider(height: 1, color: kGlassBorder),
        ],
      ),
    );
  }

  static String _protocolLabel(ProviderProtocol protocol) {
    return switch (protocol) {
      ProviderProtocol.openaiCompatible => 'OpenAI 兼容',
      ProviderProtocol.anthropicCompatible => 'Anthropic 兼容',
    };
  }

  Widget _buildEditorSettings() {
    final settings = context.watch<SettingsState>();
    return Column(
      children: [
        _sliderRow(
          label: '字号',
          value: settings.editorFontSize.toDouble(),
          min: 12,
          max: 24,
          divisions: 12,
          display: '${settings.editorFontSize}',
          onChanged: (value) => unawaited(
            _applySetting(() => settings.setEditorFontSize(value.round())),
          ),
        ),
        _switchRow(
          label: '自动保存',
          value: settings.autoSave,
          onChanged: (value) =>
              unawaited(_applySetting(() => settings.setAutoSave(value))),
        ),
        _sliderRow(
          label: '自动保存延迟',
          value: settings.autoSaveDelaySeconds.toDouble(),
          min: 1,
          max: 30,
          divisions: 29,
          display: '${settings.autoSaveDelaySeconds} 秒',
          onChanged: (value) => unawaited(
            _applySetting(
              () => settings.setAutoSaveDelaySeconds(value.round()),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTaskSettings() {
    final settings = context.watch<SettingsState>();
    return Column(
      children: [
        _sliderRow(
          label: '最大并发',
          value: settings.maxConcurrent.toDouble(),
          min: 1,
          max: 10,
          divisions: 9,
          display: '${settings.maxConcurrent}',
          onChanged: (value) => unawaited(
            _applySetting(() => settings.setMaxConcurrent(value.round())),
          ),
        ),
        _switchRow(
          label: '启动后运行队列',
          value: settings.queueAutoStart,
          onChanged: (value) =>
              unawaited(_applySetting(() => settings.setQueueAutoStart(value))),
        ),
      ],
    );
  }

  Widget _buildGeneralSettings() {
    final settings = context.watch<SettingsState>();
    return Column(
      children: [
        _switchRow(
          label: '恢复上次工作区',
          value: settings.restoreWorkspace,
          onChanged: (value) => unawaited(
            _applySetting(() => settings.setRestoreWorkspace(value)),
          ),
        ),
        _switchRow(
          label: '显示隐藏文件',
          value: context.watch<WorkspaceService>().hasWorkspace
              ? context.watch<WorkspaceService>().showHidden
              : settings.showHiddenFiles,
          onChanged: (value) => unawaited(_setShowHidden(value)),
        ),
        _settingRow(
          label: '日志级别',
          control: SizedBox(
            width: 180,
            child: DropdownButtonFormField<AppLogLevel>(
              initialValue: settings.logLevel,
              decoration: const InputDecoration(isDense: true),
              items: AppLogLevel.values
                  .map(
                    (level) =>
                        DropdownMenuItem(value: level, child: Text(level.name)),
                  )
                  .toList(growable: false),
              onChanged: (level) {
                if (level != null) {
                  unawaited(_applySetting(() => settings.setLogLevel(level)));
                }
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAppearanceSettings() {
    final settings = context.watch<SettingsState>();
    final current = settings.accentColor;
    final palette = SettingsState.accentPalette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 8, bottom: 12),
          child: Text(
            '强调色',
            style: TextStyle(fontSize: 13, color: Colors.white70),
          ),
        ),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (var index = 0; index < palette.length; index++)
              _accentSwatch(
                color: palette[index],
                name: SettingsState.accentPaletteNames[index],
                selected: current.toARGB32() == palette[index].toARGB32(),
                onTap: () => unawaited(
                  _applySetting(() => settings.setAccentColor(palette[index])),
                ),
              ),
          ],
        ),
        const Padding(
          padding: EdgeInsets.only(top: 18, bottom: 4),
          child: Text(
            '主题色将应用到全界面强调元素（按钮、选中态、图标等）',
            style: TextStyle(fontSize: 11, color: Colors.white38),
          ),
        ),
        const SizedBox(height: 10),
        _switchRow(
          label: '毛玻璃模糊',
          value: settings.glassEnabled,
          onChanged: (value) =>
              unawaited(_applySetting(() => settings.setGlassEnabled(value))),
        ),
        // 模糊强度：拖动过程仅改内存（本地预览），松手时一次性持久化，
        // 避免每帧写入 SharedPreferences 并触发全树 BackdropFilter 重建。
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 9),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(
                width: 150,
                child: Text(
                  '模糊强度',
                  style: TextStyle(fontSize: 13, color: Colors.white70),
                ),
              ),
              Expanded(
                child: Slider(
                  value: (_dragBlurSigma ?? settings.blurSigma).clamp(0, 30),
                  min: 0,
                  max: 30,
                  divisions: 30,
                  onChanged: (value) => setState(() => _dragBlurSigma = value),
                  onChangeEnd: (value) {
                    unawaited(
                      _applySetting(() async {
                        await settings.setBlurSigma(value);
                        if (mounted) setState(() => _dragBlurSigma = null);
                      }),
                    );
                  },
                ),
              ),
              SizedBox(
                width: 80,
                child: Text(
                  '${(_dragBlurSigma ?? settings.blurSigma).round()}',
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 12, color: accentLightOf(context)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _accentSwatch({
    required Color color,
    required String name,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final accentLight = accentLightOf(context);
    return Tooltip(
      message: name,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(kRadiusMd),
        child: AnimatedContainer(
          duration: kAnimDurationFast,
          curve: kAnimCurveIn,
          width: 56,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(kRadiusMd),
            border: Border.all(
              color: selected ? accentLight : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white24),
                ),
                child: selected
                    ? const Icon(Icons.check, size: 14, color: Colors.white)
                    : null,
              ),
              const SizedBox(height: 5),
              Text(
                name,
                style: TextStyle(
                  fontSize: 11,
                  color: selected ? accentLight : Colors.white54,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAboutSettings() {
    final version = context.watch<CourierService>().version;
    return Column(
      children: [
        _infoRow('应用版本', version?.displayVersion ?? '读取中'),
        _infoRow(
          '构建提交',
          version == null || version.commit.isEmpty ? '本地构建' : version.commit,
        ),
        _infoRow(
          '构建时间',
          version == null || version.buildTime.isEmpty
              ? '本地构建'
              : version.buildTime,
        ),
        _infoRow('运行架构', 'Flutter-only'),
        _infoRow('许可证', 'GPL-3.0'),
      ],
    );
  }

  Widget _settingRow({required String label, required Widget control}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: const TextStyle(fontSize: 13, color: Colors.white70),
            ),
          ),
          Expanded(
            child: Align(alignment: Alignment.centerRight, child: control),
          ),
        ],
      ),
    );
  }

  Widget _switchRow({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return _settingRow(
      label: label,
      control: Switch(value: value, onChanged: onChanged),
    );
  }

  Widget _sliderRow({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double> onChanged,
  }) {
    return _settingRow(
      label: label,
      control: SizedBox(
        width: 430,
        child: Row(
          children: [
            Expanded(
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                divisions: divisions,
                onChanged: onChanged,
              ),
            ),
            SizedBox(
              width: 80,
              child: Text(
                display,
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 12, color: accentLightOf(context)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return _settingRow(
      label: label,
      control: Text(
        value,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.right,
        style: const TextStyle(fontSize: 13, color: Colors.white54),
      ),
    );
  }
}

/// 同向垂直滑动切换：新区块与旧区块沿同一方向移动。
/// direction = 1（向下切换）：新区块从下滑入、旧区块向上滑出（同向上移）；
/// direction = -1（向上切换）：新区块从上滑入、旧区块向下滑出（同向下移）。
/// 用 child 的 key 变化触发切换；旧区块直接透传保证 State 保留。
class _VerticalSlideSwitcher extends StatefulWidget {
  final Widget child;
  final int direction;

  const _VerticalSlideSwitcher({required this.child, required this.direction});

  @override
  State<_VerticalSlideSwitcher> createState() => _VerticalSlideSwitcherState();
}

class _VerticalSlideSwitcherState extends State<_VerticalSlideSwitcher>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _inAnimation;
  late final Animation<double> _outAnimation;
  Widget? _previousChild;
  int _previousDirection = 1;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: kAnimDurationMed)
      // 初始为完成态：当前区块静止在原位（position = Offset.zero）
      ..value = 1
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          // 仅移除旧区块，不复位 controller（复位会回到 begin 移出屏幕）
          setState(() => _previousChild = null);
        }
      });
    _inAnimation = CurvedAnimation(parent: _controller, curve: kAnimCurveIn);
    // 新旧区块使用同一曲线：同时起步、同步加速、同时到位（避免旧区块延迟感）
    _outAnimation = CurvedAnimation(parent: _controller, curve: kAnimCurveIn);
  }

  @override
  void didUpdateWidget(_VerticalSlideSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.child.key != oldWidget.child.key) {
      _previousChild = oldWidget.child;
      _previousDirection = widget.direction;
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shift = 0.15 * _previousDirection;
    return Stack(
      alignment: Alignment.topLeft,
      children: [
        if (_previousChild != null)
          AnimatedBuilder(
            animation: _outAnimation,
            child: _previousChild!,
            builder: (context, child) => FadeTransition(
              // 旧区块滑出时渐隐（1→0），与新区块互补透明、避免文字重叠
              opacity: Tween<double>(begin: 1, end: 0).animate(_outAnimation),
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: Offset.zero,
                  end: Offset(0, -shift),
                ).animate(_outAnimation),
                child: child,
              ),
            ),
          ),
        AnimatedBuilder(
          animation: _inAnimation,
          child: widget.child,
          builder: (context, child) => FadeTransition(
            // 新区块滑入时渐显（0→1）
            opacity: Tween<double>(begin: 0, end: 1).animate(_inAnimation),
            child: SlideTransition(
              position: Tween<Offset>(
                begin: Offset(0, shift),
                end: Offset.zero,
              ).animate(_inAnimation),
              child: child,
            ),
          ),
        ),
      ],
    );
  }
}

class _CustomProviderFormValue {
  final String displayName;
  final String baseUrl;
  final String apiKey;
  final ProviderProtocol protocol;
  final bool supportsMillionContext;

  const _CustomProviderFormValue({
    required this.displayName,
    required this.baseUrl,
    required this.apiKey,
    required this.protocol,
    required this.supportsMillionContext,
  });
}

class _CustomProviderDialog extends StatefulWidget {
  final CustomAIProvider? existingProvider;

  const _CustomProviderDialog({this.existingProvider});

  @override
  State<_CustomProviderDialog> createState() => _CustomProviderDialogState();
}

class _CustomProviderDialogState extends State<_CustomProviderDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _displayNameController;
  late final TextEditingController _baseUrlController;
  final TextEditingController _apiKeyController = TextEditingController();
  late ProviderProtocol _protocol;
  late bool _supportsMillionContext;

  @override
  void initState() {
    super.initState();
    final provider = widget.existingProvider;
    _displayNameController = TextEditingController(
      text: provider?.displayName ?? '',
    );
    _baseUrlController = TextEditingController(text: provider?.baseUrl ?? '');
    _protocol = provider?.protocol ?? ProviderProtocol.openaiCompatible;
    _supportsMillionContext = provider?.supportsMillionContext ?? false;
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existingProvider != null;
    return AlertDialog(
      shape: kDialogShape,
      backgroundColor: kGlassFloatBg,
      title: Text(editing ? '编辑自定义供应商' : '添加自定义供应商'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _displayNameController,
                  maxLength: CustomAIProvider.maxDisplayNameLength,
                  decoration: const InputDecoration(
                    labelText: '供应商名称',
                    counterText: '',
                  ),
                  validator: _validateDisplayName,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _baseUrlController,
                  keyboardType: TextInputType.url,
                  maxLength: CustomAIProvider.maxBaseUrlLength,
                  decoration: const InputDecoration(
                    labelText: 'Base API 地址',
                    counterText: '',
                  ),
                  validator: _validateBaseUrl,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _apiKeyController,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  maxLength: 2048,
                  decoration: InputDecoration(
                    labelText: editing ? '更新 API Key（可选）' : 'API Key（可选）',
                    counterText: '',
                  ),
                  validator: _validateApiKey,
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<ProviderProtocol>(
                  initialValue: _protocol,
                  decoration: const InputDecoration(labelText: '协议类型'),
                  items: ProviderProtocol.values
                      .map(
                        (protocol) => DropdownMenuItem(
                          value: protocol,
                          child: Text(
                            _SettingsPageState._protocolLabel(protocol),
                          ),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: (protocol) {
                    if (protocol != null) setState(() => _protocol = protocol);
                  },
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('支持百万上下文', style: TextStyle(fontSize: 13)),
                  value: _supportsMillionContext,
                  onChanged: (value) {
                    setState(() => _supportsMillionContext = value);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.save_outlined, size: 17),
          label: const Text('保存'),
        ),
      ],
    );
  }

  String? _validateDisplayName(String? value) {
    final normalized = value?.trim() ?? '';
    if (normalized.isEmpty) return '请输入供应商名称';
    if (normalized.length > CustomAIProvider.maxDisplayNameLength ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(normalized)) {
      return '供应商名称格式无效';
    }
    return null;
  }

  String? _validateBaseUrl(String? value) {
    try {
      CustomAIProvider.normalizeBaseUrl(value ?? '');
      return null;
    } on FormatException {
      return '请输入有效的 HTTP(S) Base API 地址';
    }
  }

  String? _validateApiKey(String? value) {
    final normalized = value?.trim() ?? '';
    if (normalized.isEmpty) return null;
    if (normalized.contains('\u0000') ||
        utf8.encode(normalized).length > 2048) {
      return 'API Key 超过允许的长度';
    }
    return null;
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop(
      _CustomProviderFormValue(
        displayName: _displayNameController.text.trim(),
        baseUrl: CustomAIProvider.normalizeBaseUrl(_baseUrlController.text),
        apiKey: _apiKeyController.text,
        protocol: _protocol,
        supportsMillionContext: _supportsMillionContext,
      ),
    );
  }
}
