// editor_panel.dart — Markdown 编辑器面板（真实）
//
// 功能：多标签页、文件读写、编辑、保存、dirty/clean 状态、另存为。
// 文件操作通过 WorkspaceService，标签页状态通过 EditorDocument 管理。

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/workspace_service.dart';
import '../services/courier_core_service.dart';

class EditorPanel extends StatelessWidget {
  const EditorPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<WorkspaceService>(
      builder: (context, ws, _) {
        return Container(
          color: const Color(0xFF0A0E1A),
          child: Column(
            children: [
              _buildTabBar(context, ws),
              Expanded(child: _buildEditor(context, ws)),
              _buildStatusBar(context, ws),
            ],
          ),
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
              icon: const Icon(Icons.add, size: 16),
              color: Colors.white54,
              tooltip: '新建文件',
              onPressed: () => ws.createUntitled(),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            ),
            const Spacer(),
            const Padding(
              padding: EdgeInsets.only(right: 12),
              child: Text('无打开的文件', style: TextStyle(fontSize: 11, color: Colors.white24)),
            ),
          ],
        ),
      );
    }

    return Container(
      height: 36,
      decoration: const BoxDecoration(
        color: Color(0xFF111827),
        border: Border(bottom: BorderSide(color: Color(0xFF1E2438))),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.add, size: 16),
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
                  onClose: () => ws.closeDocument(doc.id),
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
          child: Container(
            width: double.infinity,
            height: double.infinity,
            color: const Color(0xFF0A0E1A),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.edit_note, size: 48, color: Colors.white12),
                  const SizedBox(height: 8),
                  const Text(
                    '选择文件或新建文件开始编辑',
                    style: TextStyle(fontSize: 13, color: Colors.white24),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '双击此处快速新建文件',
                    style: TextStyle(fontSize: 11, color: Color(0xFF3A3F4C)),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () => ws.createUntitled(),
                    icon: const Icon(Icons.add, size: 14),
                    label: const Text('新建文件', style: TextStyle(fontSize: 12)),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF6366F1),
                      minimumSize: const Size(100, 32),
                    ),
                  ),
                ],
              ),
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
        color: Color(0xFF111827),
        border: Border(top: BorderSide(color: Color(0xFF1E2438))),
      ),
      child: Row(
        children: [
          if (doc != null) ...[
            Text(doc.untitled ? '未命名' : 'Markdown',
                style: const TextStyle(fontSize: 10, color: Colors.white38)),
            const SizedBox(width: 16),
            if (doc.isDirty)
              const Row(
                children: [
                  Icon(Icons.circle, size: 6, color: Color(0xFFF59E0B)),
                  SizedBox(width: 4),
                  Text('未保存', style: TextStyle(fontSize: 10, color: Color(0xFFF59E0B))),
                ],
              )
            else
              const Text('已保存', style: TextStyle(fontSize: 10, color: Colors.white38)),
            const SizedBox(width: 16),
            Text('${doc.content.length} 字符',
                style: const TextStyle(fontSize: 10, color: Colors.white38)),
          ] else
            const Text('UTF-8', style: TextStyle(fontSize: 10, color: Colors.white38)),
          const Spacer(),
          Text(
            doc != null ? doc.fileName : '',
            style: const TextStyle(fontSize: 10, color: Colors.white24),
          ),
        ],
      ),
    );
  }
}

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
              color: isActive ? const Color(0xFF6366F1) : Colors.transparent,
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
                fontSize: 11,
                color: isActive ? Colors.white : Colors.white54,
                fontWeight: isActive ? FontWeight.w500 : FontWeight.normal,
              ),
            ),
            const SizedBox(width: 4),
            InkWell(
              onTap: onClose,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Icon(Icons.close, size: 12, color: Colors.white38),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// _EditorContent — 编辑器内容区域（含工具栏）。
class _EditorContent extends StatelessWidget {
  final EditorDocument doc;
  final TextEditingController _controller = TextEditingController();

  _EditorContent({required this.doc});

  @override
  Widget build(BuildContext context) {
    // 同步 controller 内容
    _controller.text = doc.content;
    _controller.selection = TextSelection.collapsed(offset: _controller.text.length);

    return Column(
      children: [
        // 工具栏
        Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: const BoxDecoration(
            color: Color(0xFF0D1424),
            border: Border(bottom: BorderSide(color: Color(0xFF1E2438))),
          ),
          child: Row(
            children: [
              _ToolButton(
                icon: Icons.save,
                label: '保存',
                enabled: doc.isDirty || doc.untitled,
                onTap: () => _save(context),
              ),
              _ToolButton(
                icon: Icons.send,
                label: '创建任务',
                enabled: doc.content.trim().isNotEmpty,
                onTap: () => _createTask(context),
              ),
              const Spacer(),
              if (doc.untitled)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF59E0B).withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('未命名', style: TextStyle(fontSize: 9, color: Color(0xFFF59E0B))),
                ),
            ],
          ),
        ),
        // 编辑区
        Expanded(
          child: TextField(
            controller: _controller,
            maxLines: null,
            expands: true,
            style: const TextStyle(
              fontFamily: 'Consolas',
              fontSize: 13,
              color: Colors.white70,
              height: 1.6,
            ),
            decoration: const InputDecoration(
              contentPadding: EdgeInsets.all(16),
              border: InputBorder.none,
              hintText: '在此输入 Markdown 内容...',
              hintStyle: TextStyle(color: Colors.white24),
            ),
            onChanged: (value) => doc.updateContent(value),
          ),
        ),
      ],
    );
  }

  void _save(BuildContext context) async {
    final ws = context.read<WorkspaceService>();
    if (doc.untitled) {
      // 弹出另存为对话框
      final fileName = await _showSaveAsDialog(context);
      if (fileName == null) return;
      try {
        await ws.saveAs(doc.id, fileName);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已保存为 $fileName')),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('保存失败: $e')),
          );
        }
      }
    } else {
      try {
        await ws.saveActiveDocument();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已保存'), duration: Duration(seconds: 1)),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('保存失败: $e')),
          );
        }
      }
    }
  }

  void _createTask(BuildContext context) {
    final service = context.read<CourierCoreService?>();
    if (service == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('核心服务未加载，无法创建任务')),
      );
      return;
    }
    try {
      service.createTask(
        title: doc.untitled ? '未命名任务' : doc.fileName,
        sourceType: doc.untitled ? 'manual' : 'plan-file',
        markdownContent: doc.content,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已从 ${doc.fileName} 创建任务')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('创建任务失败: $e')),
      );
    }
  }

  Future<String?> _showSaveAsDialog(BuildContext context) async {
    String fileName = doc.fileName;
    return showDialog<String>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF111827),
              title: const Text('保存新文件', style: TextStyle(fontSize: 14, color: Colors.white)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('输入文件名，文件将创建到工作区根目录',
                      style: TextStyle(fontSize: 11, color: Colors.white38)),
                  const SizedBox(height: 12),
                  TextField(
                    autofocus: true,
                    controller: TextEditingController(text: fileName),
                    style: const TextStyle(fontSize: 13, color: Colors.white),
                    decoration: const InputDecoration(
                      hintText: '未命名.md',
                      hintStyle: TextStyle(color: Colors.white24),
                      enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF1E2438)),
                      ),
                      focusedBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF6366F1)),
                      ),
                    ),
                    onChanged: (value) => fileName = value,
                    onSubmitted: (value) => Navigator.pop(context, value),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, null),
                  child: const Text('取消', style: TextStyle(color: Colors.white54)),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, fileName),
                  style: FilledButton.styleFrom(backgroundColor: const Color(0xFF6366F1)),
                  child: const Text('保存', style: TextStyle(fontSize: 12)),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

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
            Icon(icon, size: 13, color: enabled ? const Color(0xFF818CF8) : Colors.white24),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 11, color: enabled ? Colors.white70 : Colors.white24)),
          ],
        ),
      ),
    );
  }
}
