// settings_page.dart - Unified global and workspace settings.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../services/app_logger.dart';
import '../services/courier_service.dart';
import '../services/models.dart';
import '../services/settings_state.dart';
import '../services/workspace_service.dart';
import 'glass.dart';

class SettingsPage extends StatefulWidget {
  final VoidCallback? onClose;

  const SettingsPage({super.key, this.onClose});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const _sections = [
    (label: 'AI', icon: Icons.smart_toy_outlined),
    (label: '编辑器', icon: Icons.edit_note_outlined),
    (label: '任务', icon: Icons.queue_outlined),
    (label: '通用', icon: Icons.tune_outlined),
    (label: '关于', icon: Icons.info_outline),
  ];

  final TextEditingController _modelController = TextEditingController();
  final TextEditingController _apiKeyController = TextEditingController();
  int _activeSection = 0;
  bool _initialized = false;
  bool _loadingModels = false;
  bool _savingCredential = false;
  List<AIModelOption> _availableModels = const [];
  String? _error;

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
    setState(() {
      _loadingModels = true;
      _error = null;
    });
    try {
      final models = await context.read<CourierService>().refreshAIModels();
      if (mounted) setState(() => _availableModels = models);
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
        title: const Text('删除 API Key'),
        content: const Text('删除后，当前 Provider 将无法发送请求。'),
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
    setState(() => _error = '$error');
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
              constraints: const BoxConstraints(maxWidth: 960, maxHeight: 760),
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
              onTap: () => setState(() => _activeSection = index),
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
              children: [
                const Icon(
                  Icons.error_outline,
                  size: 15,
                  color: Color(0xFFEF4444),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _error!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFFFCA5A5),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '关闭错误提示',
                  onPressed: () => setState(() => _error = null),
                  icon: const Icon(Icons.close, size: 14),
                ),
              ],
            ),
          ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: switch (_activeSection) {
              0 => _buildAISettings(),
              1 => _buildEditorSettings(),
              2 => _buildTaskSettings(),
              3 => _buildGeneralSettings(),
              _ => _buildAboutSettings(),
            },
          ),
        ),
      ],
    );
  }

  Widget _buildAISettings() {
    final settings = context.watch<SettingsState>();
    final options = context.watch<CourierService>().aiOptions;
    return Column(
      children: [
        _settingRow(
          label: 'Provider',
          control: SizedBox(
            width: 260,
            child: DropdownButtonFormField<String>(
              initialValue: settings.aiProviderId,
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
                    maxLength: 16384,
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
          min: 256,
          max: 131072,
          divisions: 511,
          display: '${settings.aiMaxTokens}',
          onChanged: (value) => unawaited(
            _applySetting(() => settings.setAiMaxTokens(value.round())),
          ),
        ),
      ],
    );
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
                style: const TextStyle(fontSize: 12, color: kPrimaryLight),
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
