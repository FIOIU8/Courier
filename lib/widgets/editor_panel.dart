// editor_panel.dart — Markdown 编辑器面板（真实）
//
// 功能：多标签页、文件读写、编辑、保存、dirty/clean 状态、另存为。
// 文件操作通过 WorkspaceService，标签页状态通过 EditorDocument 管理。
// 设置联动：字号取 SettingsState.editorFontSize，自动保存按设置防抖触发。

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_error.dart';
import '../services/courier_service.dart';
import '../services/settings_state.dart';
import '../services/workspace_service.dart';
import 'glass.dart';

class EditorPanel extends StatelessWidget {
  const EditorPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<WorkspaceService>(
      builder: (context, ws, _) {
        return Column(
          children: [
            _buildTabBar(context, ws),
            Expanded(child: _buildEditor(context, ws)),
            _buildStatusBar(context, ws),
          ],
        );
      },
    );
  }

  Widget _buildTabBar(BuildContext context, WorkspaceService ws) {
    if (ws.documents.isEmpty) {
      return Container(
        height: 36,
        decoration: const BoxDecoration(
          color: Color(0xFF111827),
          border: Border(bottom: BorderSide(color: Color(0xFF1E2438))),
        ),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.add, size: 17),
              color: Colors.white54,
              tooltip: '新建文件',
              onPressed: () => ws.createUntitled(),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            ),
            const Spacer(),
            const Padding(
              padding: EdgeInsets.only(right: 12),
              child: Text(
                '无打开的文件',
                style: TextStyle(fontSize: 13, color: Colors.white24),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      height: 36,
      decoration: const BoxDecoration(
        color: kGlassHeaderBg,
        border: Border(bottom: BorderSide(color: kGlassBorder)),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.add, size: 17),
            color: Colors.white54,
            tooltip: '新建文件',
            onPressed: () => ws.createUntitled(),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: ws.documents.length,
              itemBuilder: (context, index) {
                final doc = ws.documents[index];
                final isActive = doc.id == ws.activeDocumentId;
                return _EditorTab(
                  doc: doc,
                  isActive: isActive,
                  onTap: () => ws.setActiveDocument(doc.id),
                  onClose: () => unawaited(_closeDocument(context, ws, doc)),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEditor(BuildContext context, WorkspaceService ws) {
    final doc = ws.activeDocument;
    if (doc == null) {
      return GestureDetector(
        onDoubleTap: () => ws.createUntitled(),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.edit_note, size: 48, color: Colors.white12),
                const SizedBox(height: 8),
                const Text(
                  '无打开文件',
                  style: TextStyle(fontSize: 14, color: Colors.white24),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => ws.createUntitled(),
                  icon: const Icon(Icons.add, size: 15),
                  label: const Text('新建文件', style: TextStyle(fontSize: 13)),
                  style: FilledButton.styleFrom(
                    backgroundColor: kPrimary,
                    minimumSize: const Size(100, 32),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return _EditorContent(doc: doc);
  }

  Widget _buildStatusBar(BuildContext context, WorkspaceService ws) {
    final doc = ws.activeDocument;
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: kGlassHeaderBg,
        border: Border(top: BorderSide(color: kGlassBorder)),
      ),
      child: Row(
        children: [
          if (doc != null) ...[
            Text(
              doc.untitled ? '未命名' : 'Markdown',
              style: const TextStyle(fontSize: 12, color: Colors.white38),
            ),
            const SizedBox(width: 16),
            if (doc.isDirty)
              const Row(
                children: [
                  Icon(Icons.circle, size: 6, color: Color(0xFFF59E0B)),
                  SizedBox(width: 4),
                  Text(
                    '未保存',
                    style: TextStyle(fontSize: 12, color: Color(0xFFF59E0B)),
                  ),
                ],
              )
            else
              const Text(
                '已保存',
                style: TextStyle(fontSize: 12, color: Colors.white38),
              ),
            const SizedBox(width: 16),
            Text(
              '${doc.content.length} 字符',
              style: const TextStyle(fontSize: 12, color: Colors.white38),
            ),
          ] else
            const Text(
              'UTF-8',
              style: TextStyle(fontSize: 12, color: Colors.white38),
            ),
          const Spacer(),
          Text(
            doc != null ? doc.fileName : '',
            style: const TextStyle(fontSize: 12, color: Colors.white24),
          ),
        ],
      ),
    );
  }

  Future<void> _closeDocument(
    BuildContext context,
    WorkspaceService workspace,
    EditorDocument document,
  ) async {
    try {
      if (!document.isDirty) {
        await workspace.closeDocument(document.id);
        return;
      }
      final decision = await showDialog<_CloseDecision>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('未保存文档'),
          content: Text(document.fileName),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_CloseDecision.cancel),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_CloseDecision.discard),
              child: const Text('放弃更改'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_CloseDecision.save),
              child: const Text('保存'),
            ),
          ],
        ),
      );
      if (!context.mounted ||
          decision == null ||
          decision == _CloseDecision.cancel) {
        return;
      }
      if (decision == _CloseDecision.discard) {
        await workspace.closeDocument(document.id, discardUnsaved: true);
        return;
      }
      workspace.setActiveDocument(document.id);
      if (document.untitled) {
        final path = await _promptSavePath(context, document.fileName);
        if (path == null) return;
        await workspace.saveAs(document.id, path);
      } else {
        await workspace.saveDocument(document.id);
      }
      await workspace.closeDocument(document.id);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('关闭文档失败: $error')));
    }
  }

  Future<String?> _promptSavePath(
    BuildContext context,
    String initialValue,
  ) async {
    final controller = TextEditingController(text: initialValue);
    try {
      return await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('保存文档'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: '工作区相对路径'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(controller.text.trim()),
              child: const Text('保存'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }
}

enum _CloseDecision { save, discard, cancel }

/// _EditorTab — 单个标签页按钮。
class _EditorTab extends StatelessWidget {
  final EditorDocument doc;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback onClose;

  const _EditorTab({
    required this.doc,
    required this.isActive,
    required this.onTap,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.only(left: 12, right: 4),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: isActive ? kPrimary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          children: [
            if (doc.isDirty)
              const Padding(
                padding: EdgeInsets.only(right: 4),
                child: Icon(Icons.circle, size: 6, color: Color(0xFFF59E0B)),
              ),
            Text(
              doc.fileName,
              style: TextStyle(
                fontSize: 13,
                color: isActive ? Colors.white : Colors.white54,
                fontWeight: isActive ? FontWeight.w500 : FontWeight.normal,
              ),
            ),
            const SizedBox(width: 4),
            InkWell(
              onTap: onClose,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Icon(Icons.close, size: 13, color: Colors.white38),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// _EditorContent — 编辑器内容区域（含工具栏）。
class _EditorContent extends StatefulWidget {
  final EditorDocument doc;
  const _EditorContent({required this.doc});

  @override
  State<_EditorContent> createState() => _EditorContentState();
}

class _EditorContentState extends State<_EditorContent> {
  final TextEditingController _controller = TextEditingController();
  bool _saving = false;
  Timer? _autoSaveTimer;

  EditorDocument get doc => widget.doc;

  @override
  void initState() {
    super.initState();
    _attachDocument(doc);
  }

  @override
  void didUpdateWidget(_EditorContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.doc != widget.doc) {
      _autoSaveTimer?.cancel();
      _autoSaveTimer = null;
      oldWidget.doc.removeListener(_syncFromDocument);
      _attachDocument(doc);
    }
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    doc.removeListener(_syncFromDocument);
    _controller.dispose();
    super.dispose();
  }

  void _attachDocument(EditorDocument document) {
    _controller.text = document.content;
    _controller.selection = TextSelection.collapsed(
      offset: _controller.text.length,
    );
    document.addListener(_syncFromDocument);
  }

  void _syncFromDocument() {
    if (_controller.text == doc.content) return;
    final offset = _controller.selection.baseOffset.clamp(
      0,
      doc.content.length,
    );
    _controller.value = TextEditingValue(
      text: doc.content,
      selection: TextSelection.collapsed(offset: offset),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsState>();

    return Column(
      children: [
        // 工具栏
        Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: const BoxDecoration(
            color: kGlassHeaderBg,
            border: Border(bottom: BorderSide(color: kGlassBorder)),
          ),
          child: Row(
            children: [
              _ToolButton(
                icon: Icons.save,
                label: '保存',
                enabled: (doc.isDirty || doc.untitled) && !_saving,
                onTap: () => unawaited(_save(context)),
              ),
              _ToolButton(
                icon: Icons.send,
                label: '创建任务',
                enabled: doc.content.trim().isNotEmpty && !_saving,
                onTap: () => unawaited(_createTask(context)),
              ),
              const Spacer(),
              if (doc.untitled)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF59E0B).withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(kRadiusSm),
                  ),
                  child: const Text(
                    '未命名',
                    style: TextStyle(fontSize: 11, color: Color(0xFFF59E0B)),
                  ),
                ),
            ],
          ),
        ),
        // 编辑区
        Expanded(
          child: TextField(
            enableSuggestions: false,
            autocorrect: false,
            controller: _controller,
            maxLines: null,
            expands: true,
            enabled: !_saving,
            style: TextStyle(
              fontFamily: 'Consolas',
              fontSize: settings.editorFontSize.toDouble(),
              color: Colors.white70,
              height: 1.6,
            ),
            decoration: const InputDecoration(
              contentPadding: EdgeInsets.all(16),
              border: InputBorder.none,
              hintText: 'Markdown',
              hintStyle: TextStyle(color: Colors.white24),
            ),
            onChanged: (value) {
              doc.updateContent(value);
              _scheduleAutoSave();
            },
          ),
        ),
      ],
    );
  }

  /// 自动保存：开启自动保存且文档非未命名时，防抖 delay 秒后保存
  void _scheduleAutoSave() {
    final settings = context.read<SettingsState>();
    if (!settings.autoSave || doc.untitled || _saving) return;
    final scheduledDocument = doc;
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(
      Duration(seconds: settings.autoSaveDelaySeconds),
      () {
        if (!mounted || _saving || !identical(doc, scheduledDocument)) return;
        final currentSettings = context.read<SettingsState>();
        if (!currentSettings.autoSave || !scheduledDocument.isDirty) return;
        unawaited(_save(context));
      },
    );
  }

  Future<void> _save(BuildContext context) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final ws = context.read<WorkspaceService>();
      if (doc.untitled) {
        final fileName = await _showSaveAsDialog(context);
        if (fileName == null) return;
        await ws.saveAs(doc.id, fileName);
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('已保存为 $fileName')));
        }
      } else {
        try {
          await ws.saveDocument(doc.id);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('已保存'),
                duration: Duration(seconds: 1),
              ),
            );
          }
        } on CourierException catch (error) {
          if (error.code != 'FILE_CHANGED_EXTERNALLY') rethrow;
          if (!context.mounted) return;
          await _resolveExternalChange(context, ws);
        }
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存失败: $error')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _createTask(BuildContext context) async {
    final service = context.read<CourierService>();
    try {
      await service.createTask(
        title: doc.untitled ? '未命名任务' : doc.fileName,
        sourceType: doc.untitled ? 'manual' : 'plan-file',
        markdownContent: doc.content,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已从 ${doc.fileName} 创建任务')));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('创建任务失败: $e')));
    }
  }

  Future<String?> _showSaveAsDialog(BuildContext context) async {
    final controller = TextEditingController(text: doc.fileName);
    try {
      return await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('保存新文件'),
          content: TextField(
            autofocus: true,
            controller: controller,
            decoration: const InputDecoration(labelText: '工作区相对路径'),
            onSubmitted: (value) =>
                Navigator.of(dialogContext).pop(value.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(controller.text.trim()),
              child: const Text('保存'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  Future<void> _resolveExternalChange(
    BuildContext context,
    WorkspaceService workspace,
  ) async {
    final decision = await showDialog<_ExternalChangeDecision>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('文件已在外部修改'),
        content: Text(doc.fileName),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_ExternalChangeDecision.cancel),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_ExternalChangeDecision.reload),
            child: const Text('重新加载'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(
              dialogContext,
            ).pop(_ExternalChangeDecision.overwrite),
            child: const Text('覆盖'),
          ),
        ],
      ),
    );
    if (decision == _ExternalChangeDecision.reload) {
      await workspace.reloadDocument(doc.id);
    } else if (decision == _ExternalChangeDecision.overwrite) {
      await workspace.saveDocument(doc.id, force: true);
    }
  }
}

enum _ExternalChangeDecision { reload, overwrite, cancel }

/// _ToolButton — 工具栏按钮。
class _ToolButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onTap;

  const _ToolButton({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            Icon(
              icon,
              size: 14,
              color: enabled ? kPrimaryLight : Colors.white24,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: enabled ? Colors.white70 : Colors.white24,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
