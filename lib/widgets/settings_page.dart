// settings_page.dart — 设置页面（真实）
//
// 显示核心库版本、AI 供应商/模型选项（从 aiGetOptions 加载）。
// 偏好通过 shared_preferences 持久化。

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/courier_core_service.dart';

class SettingsPage extends StatefulWidget {
  final VoidCallback onBack;

  const SettingsPage({super.key, required this.onBack});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String _selectedProvider = '';
  String _selectedModel = '';
  bool _autoSave = false;
  int _maxConcurrent = 3;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _loadOptions();
  }

  void _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _selectedProvider = prefs.getString('ai_provider') ?? '';
      _selectedModel = prefs.getString('ai_model') ?? '';
      _autoSave = prefs.getBool('auto_save') ?? false;
      _maxConcurrent = prefs.getInt('max_concurrent') ?? 3;
    });
  }

  void _loadOptions() {
    final service = context.read<CourierCoreService?>();
    if (service == null) return;
    try {
      if (service.aiOptions == null) {
        service.aiGetOptions();
      }
    } catch (e) {
      debugPrint('[SettingsPage] 加载选项失败: $e');
    }
  }

  void _saveProvider(String providerId) async {
    setState(() => _selectedProvider = providerId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ai_provider', providerId);
  }

  void _saveModel(String modelId) async {
    setState(() => _selectedModel = modelId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ai_model', modelId);
  }

  void _saveAutoSave(bool value) async {
    setState(() => _autoSave = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_save', value);
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<CourierCoreService?>();

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      body: Column(
        children: [
          // 头部
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: const BoxDecoration(
              color: Color(0xFF111827),
              border: Border(bottom: BorderSide(color: Color(0xFF1E2438))),
            ),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, size: 18, color: Colors.white54),
                  onPressed: widget.onBack,
                ),
                const SizedBox(width: 8),
                const Text('设置', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white)),
              ],
            ),
          ),
          // 内容
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 核心库版本
                      _buildSection('核心库', [
                        if (service != null) ...[
                          _buildInfoRow('版本', service.version?.versionString ?? '未知'),
                          _buildInfoRow('状态', '已加载'),
                        ] else
                          _buildInfoRow('状态', '未加载（DLL 缺失）'),
                      ]),
                      const SizedBox(height: 24),
                      // AI 模型
                      _buildSection('AI 模型', _buildAIModelSettings(service)),
                      const SizedBox(height: 24),
                      // 编辑器
                      _buildSection('编辑器', [
                        _buildToggle('自动保存', _autoSave, _saveAutoSave),
                        _buildSlider('最大并发任务数', _maxConcurrent, (value) {
                          setState(() => _maxConcurrent = value.round());
                        }),
                      ]),
                      const SizedBox(height: 24),
                      // 关于
                      _buildSection('关于', [
                        _buildInfoRow('应用', 'Courier Flutter'),
                        _buildInfoRow('描述', '本地计划执行引擎 - Flutter 桌面端'),
                      ]),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildAIModelSettings(CourierCoreService? service) {
    final options = service?.aiOptions;
    if (options == null) {
      return [
        _buildInfoRow('供应商', '加载中...'),
      ];
    }

    final providers = options.providers;
    final currentProvider = providers.where((p) => p.id == _selectedProvider).firstOrNull;
    final models = currentProvider?.models ?? [];

    return [
      // 供应商选择
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            const Text('默认供应商', style: TextStyle(fontSize: 13, color: Colors.white70)),
            const Spacer(),
            DropdownButton<String>(
              value: _selectedProvider.isEmpty && providers.isNotEmpty
                  ? providers.first.id
                  : _selectedProvider,
              underline: const SizedBox(),
              style: const TextStyle(fontSize: 13, color: Colors.white70),
              dropdownColor: const Color(0xFF111827),
              items: providers
                  .map((p) => DropdownMenuItem(
                        value: p.id,
                        child: Text(p.displayName),
                      ))
                  .toList(),
              onChanged: (value) {
                if (value != null) {
                  _saveProvider(value);
                  // 重置模型为第一个
                  final provider = providers.where((p) => p.id == value).first;
                  if (provider.models.isNotEmpty) {
                    _saveModel(provider.models.first.id);
                  }
                }
              },
            ),
          ],
        ),
      ),
      // 模型选择
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            const Text('默认模型', style: TextStyle(fontSize: 13, color: Colors.white70)),
            const Spacer(),
            DropdownButton<String>(
              value: _selectedModel.isEmpty && models.isNotEmpty
                  ? models.first.id
                  : (_selectedModel.isNotEmpty && models.any((m) => m.id == _selectedModel)
                      ? _selectedModel
                      : null),
              underline: const SizedBox(),
              style: const TextStyle(fontSize: 13, color: Colors.white70),
              dropdownColor: const Color(0xFF111827),
              items: models
                  .map((m) => DropdownMenuItem(
                        value: m.id,
                        child: Text(m.displayName),
                      ))
                  .toList(),
              onChanged: (value) {
                if (value != null) _saveModel(value);
              },
            ),
          ],
        ),
      ),
      // 思考级别（只读展示）
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            const Text('思考级别', style: TextStyle(fontSize: 13, color: Colors.white70)),
            const Spacer(),
            Text(
              options.thinkingLevels.map((t) => t.label).join(' / '),
              style: const TextStyle(fontSize: 12, color: Colors.white38),
            ),
          ],
        ),
      ),
      // 模式（只读展示）
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            const Text('模式', style: TextStyle(fontSize: 13, color: Colors.white70)),
            const Spacer(),
            Text(
              options.modes.map((m) => m.label).join(' / '),
              style: const TextStyle(fontSize: 12, color: Colors.white38),
            ),
          ],
        ),
      ),
    ];
  }

  Widget _buildSection(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 12, color: Colors.white38, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        ...children,
      ],
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Text(label, style: const TextStyle(fontSize: 13, color: Colors.white70)),
          const Spacer(),
          Text(value, style: const TextStyle(fontSize: 13, color: Colors.white38)),
        ],
      ),
    );
  }

  Widget _buildToggle(String label, bool value, ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Text(label, style: const TextStyle(fontSize: 13, color: Colors.white70)),
          const Spacer(),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  Widget _buildSlider(String label, int value, ValueChanged<double> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Text(label, style: const TextStyle(fontSize: 13, color: Colors.white70)),
          Expanded(
            child: Slider(
              value: value.toDouble(),
              min: 1,
              max: 10,
              divisions: 9,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 30,
            child: Text('$value', style: const TextStyle(fontSize: 13, color: Color(0xFF6366F1))),
          ),
        ],
      ),
    );
  }
}
