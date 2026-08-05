// file_tree_panel.dart — 文件树面板（完整实现）
//
// 功能：
// - 从 WorkspaceService 获取工作区文件树
// - 点击文件 → 调用 WorkspaceService.openFile() 加载到编辑器
// - 右键上下文菜单（空白/文件夹/文件 三种类型）
// - Markdown 文件可拖拽到右侧任务队列
// - 排除列表管理 + 文件分类过滤

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../services/courier_service.dart';
import '../services/workspace_service.dart';
import 'glass.dart';

/// 自定义 MIME 类型用于拖拽传递
const String planDropMime = 'application/vnd.courier.plan+json';

class FileTreePanel extends StatelessWidget {
  const FileTreePanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<WorkspaceService>(
      builder: (context, ws, _) {
        return _FileTreeContainer(service: ws);
      },
    );
  }
}

/// _FileTreeContainer — 文件树容器（StatefulWidget，管理右键菜单状态）
class _FileTreeContainer extends StatefulWidget {
  final WorkspaceService service;
  const _FileTreeContainer({required this.service});

  @override
  State<_FileTreeContainer> createState() => _FileTreeContainerState();
}

class _FileTreeContainerState extends State<_FileTreeContainer> {
  final TextEditingController _excludeController = TextEditingController();

  // 右键菜单状态
  Offset? _menuPosition;
  FileTreeNode? _menuTarget;
  String _menuKind = 'blank'; // blank | folder | file

  // 排除列表面板
  bool _showExcludePanel = false;

  // 分类过滤面板
  bool _showFilterPanel = false;

  // 展开状态（目录路径集合），提升到容器层统一管理，
  // 配合 ListView.builder 平铺渲染，展开/收起只重建视口内的行
  final Set<String> _expandedPaths = {};
  bool _expandedInitialized = false;
  String? _expandedWorkspacePath;

  @override
  void dispose() {
    _excludeController.dispose();
    super.dispose();
  }

  /// 展开/收起目录
  void _toggleExpand(FileTreeNode node) {
    setState(() {
      if (!_expandedPaths.remove(node.path)) {
        _expandedPaths.add(node.path);
      }
    });
  }

  /// 生成当前展开状态下的可见节点平铺列表。
  /// 纯内存遍历（不构建 Widget），一次性遍历完再交给 ListView.builder 展示。
  List<FileTreeNode> _buildVisibleNodes(WorkspaceService ws) {
    if (_expandedWorkspacePath != ws.workspacePath) {
      _expandedWorkspacePath = ws.workspacePath;
      _expandedPaths.clear();
      _expandedInitialized = false;
    }
    // 首次构建：顶层目录默认展开（保持原有行为）
    if (!_expandedInitialized && ws.fileTree.isNotEmpty) {
      _expandedInitialized = true;
      for (final root in ws.fileTree) {
        if (root.isDir) _expandedPaths.add(root.path);
      }
    }
    final visible = <FileTreeNode>[];
    void walk(FileTreeNode node) {
      visible.add(node);
      if (node.isDir && _expandedPaths.contains(node.path)) {
        for (final child in node.children) {
          walk(child);
        }
      }
    }

    for (final root in ws.fileTree) {
      walk(root);
    }
    return visible;
  }

  @override
  Widget build(BuildContext context) {
    final ws = widget.service;
    return Stack(
      children: [
        Column(
          children: [
            _buildHeader(context, ws),
            if (_showExcludePanel) _buildExcludePanel(context, ws),
            if (_showFilterPanel) _buildFilterPanel(context, ws),
            Expanded(child: _buildBody(context, ws)),
          ],
        ),
        // 右键菜单
        if (_menuPosition != null) _buildContextMenu(context, ws),
      ],
    );
  }

  Widget _buildHeader(BuildContext context, WorkspaceService ws) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: kGlassHeaderBg,
        border: Border(bottom: BorderSide(color: kGlassBorder)),
      ),
      child: Row(
        children: [
          const Icon(Icons.folder_open, size: 17, color: kPrimary),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  ws.hasWorkspace ? ws.workspaceName : '未打开工作区',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  ws.hasWorkspace ? ws.workspacePath : '尚未选择工作区',
                  style: const TextStyle(fontSize: 12, color: Colors.white38),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.filter_list, size: 17),
            color: _showFilterPanel ? kPrimary : Colors.white54,
            tooltip: '文件过滤',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: ws.hasWorkspace
                ? () => setState(() {
                    _showFilterPanel = !_showFilterPanel;
                    _showExcludePanel = false;
                  })
                : null,
          ),
          IconButton(
            icon: const Icon(Icons.block, size: 17),
            color: _showExcludePanel ? kPrimary : Colors.white54,
            tooltip: '排除列表',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: ws.hasWorkspace
                ? () => setState(() {
                    _showExcludePanel = !_showExcludePanel;
                    _showFilterPanel = false;
                  })
                : null,
          ),
          IconButton(
            icon: const Icon(Icons.folder_open_outlined, size: 17),
            color: Colors.white54,
            tooltip: '打开文件夹',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: () => unawaited(_pickWorkspace(context, ws)),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 17),
            color: Colors.white54,
            tooltip: '刷新文件树',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: ws.hasWorkspace && !ws.scanning
                ? () =>
                      unawaited(_runAction(context, ws.scanFileTree, '刷新文件树失败'))
                : null,
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, WorkspaceService ws) {
    if (!ws.hasWorkspace) {
      return _buildEmpty(context, ws);
    }
    if (ws.scanning) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: kPrimary),
            ),
            SizedBox(height: 8),
            Text(
              '扫描文件中...',
              style: TextStyle(fontSize: 13, color: Colors.white38),
            ),
          ],
        ),
      );
    }
    if (ws.fileTree.isEmpty) {
      return GestureDetector(
        onSecondaryTapDown: (details) =>
            _showContextMenu(details, null, 'blank'),
        onDoubleTap: () => _showCreateDialog(context, 'file', null),
        child: const Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '工作区为空',
              style: TextStyle(fontSize: 13, color: Colors.white38),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    final visibleNodes = _buildVisibleNodes(ws);
    return GestureDetector(
      onSecondaryTapDown: (details) {
        // 仅在空白区域触发
        _showContextMenu(details, null, 'blank');
      },
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: visibleNodes.length,
        itemBuilder: (context, index) {
          final node = visibleNodes[index];
          return _FileTreeTile(
            node: node,
            isExpanded: _expandedPaths.contains(node.path),
            onToggleExpand: () => _toggleExpand(node),
          );
        },
      ),
    );
  }

  Widget _buildEmpty(BuildContext context, WorkspaceService ws) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.folder_open, size: 32, color: Colors.white24),
            const SizedBox(height: 12),
            const Text(
              '未打开工作区',
              style: TextStyle(fontSize: 13, color: Colors.white38),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => unawaited(_pickWorkspace(context, ws)),
              icon: const Icon(Icons.folder_open, size: 15),
              label: const Text('打开工作区', style: TextStyle(fontSize: 13)),
              style: FilledButton.styleFrom(
                backgroundColor: kPrimary,
                minimumSize: const Size(120, 32),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 排除列表面板
  // ============================================================

  Widget _buildExcludePanel(BuildContext context, WorkspaceService ws) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 200),
      decoration: const BoxDecoration(
        color: kGlassHeaderBg,
        border: Border(bottom: BorderSide(color: kGlassBorder)),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                const Icon(Icons.block, size: 13, color: kPrimary),
                const SizedBox(width: 4),
                const Text(
                  '排除列表',
                  style: TextStyle(fontSize: 13, color: Colors.white54),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => unawaited(
                    _runAction(context, ws.resetExcludePatterns, '重置排除列表失败'),
                  ),
                  icon: const Icon(Icons.restore, size: 13),
                  label: const Text('重置', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(50, 24),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: kGlassBorder),
          Expanded(
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: ws.excludePatterns.length,
              itemBuilder: (context, index) {
                final pattern = ws.excludePatterns[index];
                final isDefault = _defaultExcludePatterns.contains(pattern);
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 1,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isDefault ? Icons.lock : Icons.circle,
                        size: isDefault ? 10 : 6,
                        color: isDefault ? Colors.white24 : kPrimary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          pattern,
                          style: TextStyle(
                            fontSize: 13,
                            color: isDefault ? Colors.white38 : Colors.white70,
                            fontFamily: 'Consolas',
                          ),
                        ),
                      ),
                      if (!isDefault)
                        InkWell(
                          onTap: () => unawaited(
                            _runAction(
                              context,
                              () => ws.removeExcludePattern(pattern),
                              '移除排除项失败',
                            ),
                          ),
                          child: const Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(
                              Icons.close,
                              size: 13,
                              color: Colors.white38,
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
          // 添加排除项
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _excludeController,
                    enableSuggestions: false,
                    autocorrect: false,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Colors.white70,
                      fontFamily: 'Consolas',
                    ),
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: '排除模式',
                      hintStyle: TextStyle(fontSize: 12, color: Colors.white24),
                      enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF1E2438)),
                      ),
                      focusedBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: kPrimary),
                      ),
                    ),
                    onSubmitted: (_) =>
                        unawaited(_addExcludePattern(context, ws)),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add, size: 15),
                  color: kPrimary,
                  constraints: const BoxConstraints(
                    minWidth: 24,
                    minHeight: 24,
                  ),
                  padding: EdgeInsets.zero,
                  tooltip: '添加排除模式',
                  onPressed: () => unawaited(_addExcludePattern(context, ws)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 文件分类过滤面板
  // ============================================================

  Widget _buildFilterPanel(BuildContext context, WorkspaceService ws) {
    final categories = [
      ('md', 'Markdown', kPrimary, Icons.description),
      ('code', '代码', const Color(0xFF10B981), Icons.code),
      ('json', '配置', const Color(0xFFF59E0B), Icons.settings),
      ('image', '图片', const Color(0xFFEC4899), Icons.image),
      ('archive', '压缩包', const Color(0xFF8B5CF6), Icons.archive),
      ('text', '文本', const Color(0xFF06B6D4), Icons.text_snippet),
      ('other', '其他', const Color(0xFF64748B), Icons.insert_drive_file),
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: const BoxDecoration(
        color: kGlassHeaderBg,
        border: Border(bottom: BorderSide(color: kGlassBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.filter_list, size: 13, color: kPrimary),
              const SizedBox(width: 4),
              const Text(
                '文件过滤',
                style: TextStyle(fontSize: 13, color: Colors.white54),
              ),
              const Spacer(),
              InkWell(
                onTap: () => unawaited(
                  _runAction(
                    context,
                    () => ws.setCategoryFilters({
                      for (final category in categories) category.$1: true,
                    }),
                    '更新文件过滤失败',
                  ),
                ),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    '全选',
                    style: TextStyle(fontSize: 12, color: kPrimary),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: categories.map((cat) {
              final isEnabled = ws.categoryFilter[cat.$1] ?? true;
              return _CategoryChip(
                label: cat.$2,
                icon: cat.$4,
                color: cat.$3,
                enabled: isEnabled,
                onTap: () => unawaited(
                  _runAction(
                    context,
                    () => ws.toggleCategoryFilter(cat.$1, !isEnabled),
                    '更新文件过滤失败',
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 4),
          InkWell(
            onTap: () => unawaited(
              _runAction(context, ws.toggleShowHidden, '更新隐藏文件设置失败'),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(
                    ws.showHidden ? Icons.visibility : Icons.visibility_off,
                    size: 13,
                    color: ws.showHidden ? kPrimary : Colors.white38,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    ws.showHidden ? '显示隐藏文件' : '隐藏点文件',
                    style: TextStyle(
                      fontSize: 12,
                      color: ws.showHidden ? kPrimary : Colors.white38,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _runAction(
    BuildContext context,
    Future<void> Function() action,
    String failureMessage,
  ) async {
    try {
      await action();
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$failureMessage: $error')));
    }
  }

  Future<void> _addExcludePattern(
    BuildContext context,
    WorkspaceService workspace,
  ) async {
    final pattern = _excludeController.text.trim();
    if (pattern.isEmpty) return;
    try {
      await workspace.addExcludePattern(pattern);
      _excludeController.clear();
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('添加排除项失败: $error')));
    }
  }

  Future<void> _pickWorkspace(
    BuildContext context,
    WorkspaceService workspace,
  ) async {
    var discardUnsaved = false;
    if (workspace.hasDirtyDocuments) {
      final decision = await showDialog<_WorkspaceSwitchDecision>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('存在未保存文档'),
          content: Text('共有 ${workspace.dirtyDocuments.length} 个文档尚未保存。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(_WorkspaceSwitchDecision.cancel),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(_WorkspaceSwitchDecision.discard),
              child: const Text('放弃更改'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(_WorkspaceSwitchDecision.save),
              child: const Text('保存后切换'),
            ),
          ],
        ),
      );
      if (!context.mounted ||
          decision == null ||
          decision == _WorkspaceSwitchDecision.cancel) {
        return;
      }
      if (decision == _WorkspaceSwitchDecision.save) {
        final saved = await _saveDirtyDocuments(context, workspace);
        if (!saved || !context.mounted) return;
      } else {
        discardUnsaved = true;
      }
    }

    try {
      await workspace.pickWorkspace(discardUnsaved: discardUnsaved);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('打开工作区失败: $error')));
    }
  }

  Future<bool> _saveDirtyDocuments(
    BuildContext context,
    WorkspaceService workspace,
  ) async {
    final documents = workspace.dirtyDocuments.toList(growable: false);
    try {
      for (final document in documents) {
        workspace.setActiveDocument(document.id);
        if (document.untitled) {
          final relativePath = await _promptSavePath(
            context,
            document.fileName,
          );
          if (relativePath == null || !context.mounted) return false;
          final saved = await workspace.saveAs(document.id, relativePath);
          if (!saved) {
            throw StateError('文档不存在或工作区不可用');
          }
        } else {
          await workspace.saveDocument(document.id);
        }
      }
      return true;
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存文档失败: $error')));
      }
      return false;
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
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('保存文档'),
          content: TextField(
            controller: controller,
            autofocus: true,
            enableSuggestions: false,
            autocorrect: false,
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

  // ============================================================
  // 右键上下文菜单
  // ============================================================

  void _showContextMenu(
    TapDownDetails details,
    FileTreeNode? target,
    String kind,
  ) {
    final overlay = MediaQuery.of(context).size;
    const menuWidth = 176.0;
    const menuHeight = 140.0;

    // 全局坐标 → 容器局部坐标（容器可能不在窗口左上角，直接混用会错位）
    var local = details.globalPosition;
    final renderObject = context.findRenderObject();
    if (renderObject is RenderBox) {
      local = renderObject.globalToLocal(details.globalPosition);
    }

    setState(() {
      _menuPosition = Offset(
        local.dx.clamp(8.0, overlay.width - menuWidth - 8),
        local.dy.clamp(8.0, overlay.height - menuHeight - 8),
      );
      _menuTarget = target;
      _menuKind = kind;
    });
  }

  void _closeContextMenu() {
    setState(() {
      _menuPosition = null;
      _menuTarget = null;
    });
  }

  Widget _buildContextMenu(BuildContext context, WorkspaceService ws) {
    return Stack(
      children: [
        // 透明遮罩，点击关闭菜单
        GestureDetector(
          onTap: _closeContextMenu,
          onSecondaryTap: _closeContextMenu,
          child: Container(
            color: Colors.transparent,
            width: double.infinity,
            height: double.infinity,
          ),
        ),
        Positioned(
          left: _menuPosition!.dx,
          top: _menuPosition!.dy,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 176,
              decoration: BoxDecoration(
                color: kGlassFloatBg,
                borderRadius: BorderRadius.circular(kRadiusMd),
                border: Border.all(color: kGlassBorder),
                boxShadow: kShadowLg,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: _buildMenuItems(context, ws),
              ),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildMenuItems(BuildContext context, WorkspaceService ws) {
    final items = <_MenuItem>[];

    // 创建文件 — blank 和 folder 可用
    items.add(
      _MenuItem(
        icon: Icons.note_add,
        label: '创建文件',
        enabled: _menuKind == 'blank' || _menuKind == 'folder',
        onTap: () {
          _closeContextMenu();
          _showCreateDialog(context, 'file', _menuTarget);
        },
      ),
    );

    // 创建文件夹
    items.add(
      _MenuItem(
        icon: Icons.create_new_folder,
        label: '创建文件夹',
        enabled: _menuKind == 'blank' || _menuKind == 'folder',
        onTap: () {
          _closeContextMenu();
          _showCreateDialog(context, 'folder', _menuTarget);
        },
      ),
    );

    // 重命名 — folder 和 file 可用
    if (_menuKind != 'blank') {
      items.add(
        _MenuItem(
          icon: Icons.edit,
          label: '重命名',
          enabled: true,
          onTap: () {
            final target = _menuTarget;
            _closeContextMenu();
            if (target != null) _showRenameDialog(context, target);
          },
        ),
      );
    }

    // 删除 — folder 和 file 可用
    if (_menuKind != 'blank') {
      items.add(
        _MenuItem(
          icon: Icons.delete_outline,
          label: '删除',
          enabled: true,
          isDanger: true,
          onTap: () {
            final target = _menuTarget;
            _closeContextMenu();
            if (target != null) {
              unawaited(_showDeleteConfirm(context, target));
            }
          },
        ),
      );
    }

    // 从文件创建任务 — 仅 file 可用
    if (_menuKind == 'file' && _menuTarget != null) {
      items.add(
        _MenuItem(
          icon: Icons.add_task,
          label: '创建任务',
          enabled: true,
          onTap: () {
            final target = _menuTarget;
            _closeContextMenu();
            if (target != null) {
              unawaited(_createTaskFromFile(context, target));
            }
          },
        ),
      );
    }

    final widgets = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      // 分隔线
      if (i > 0 && (items[i - 1].isDanger != item.isDanger)) {
        widgets.add(const Divider(height: 1, color: kGlassBorder));
      }
      widgets.add(_MenuItemWidget(item: item));
    }
    return widgets;
  }

  // ============================================================
  // 对话框
  // ============================================================

  void _showCreateDialog(
    BuildContext context,
    String type,
    FileTreeNode? parent,
  ) {
    final ws = context.read<WorkspaceService>();
    String name = '';

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kGlassFloatBg,
        shape: kDialogShape,
        title: Text(
          type == 'file' ? '创建文件' : '创建文件夹',
          style: const TextStyle(fontSize: 15, color: Colors.white),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              parent != null ? '在 ${parent.name} 中创建' : '在工作区根目录创建',
              style: const TextStyle(fontSize: 13, color: Colors.white38),
            ),
            const SizedBox(height: 12),
            TextField(
              enableSuggestions: false,
              autocorrect: false,
              autofocus: true,
              style: const TextStyle(fontSize: 14, color: Colors.white),
              decoration: InputDecoration(
                labelText: type == 'file' ? '文件名' : '文件夹名称',
                enabledBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF1E2438)),
                ),
                focusedBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: kPrimary),
                ),
              ),
              onChanged: (value) => name = value,
              onSubmitted: (value) {
                name = value;
                Navigator.pop(ctx, true);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: Colors.white54)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: kPrimary),
            child: const Text('创建', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    ).then((confirmed) async {
      if (confirmed == true && name.trim().isNotEmpty && context.mounted) {
        try {
          final parentPath = parent?.path;
          String fullPath;
          if (type == 'file') {
            fullPath = await ws.createFile(name, parentPath: parentPath);
          } else {
            fullPath = await ws.createFolder(name, parentPath: parentPath);
          }
          if (type == 'file' && context.mounted) {
            await ws.openFile(fullPath);
          }
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('创建失败: $e')));
          }
        }
      }
    });
  }

  void _showRenameDialog(BuildContext context, FileTreeNode node) {
    final ws = context.read<WorkspaceService>();
    String name = node.name;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kGlassFloatBg,
        shape: kDialogShape,
        title: const Text(
          '重命名',
          style: TextStyle(fontSize: 15, color: Colors.white),
        ),
        content: TextField(
          enableSuggestions: false,
          autocorrect: false,
          autofocus: true,
          controller: TextEditingController(text: node.name),
          style: const TextStyle(fontSize: 14, color: Colors.white),
          decoration: const InputDecoration(
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Color(0xFF1E2438)),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: kPrimary),
            ),
          ),
          onChanged: (value) => name = value,
          onSubmitted: (value) {
            name = value;
            Navigator.pop(ctx, true);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: Colors.white54)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: kPrimary),
            child: const Text('重命名', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    ).then((confirmed) async {
      if (confirmed == true &&
          name.trim().isNotEmpty &&
          name != node.name &&
          context.mounted) {
        try {
          await ws.renameEntry(node.path, name.trim());
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('重命名失败: $e')));
          }
        }
      }
    });
  }

  Future<void> _showDeleteConfirm(
    BuildContext context,
    FileTreeNode node,
  ) async {
    final ws = context.read<WorkspaceService>();
    try {
      final preview = await ws.previewDeletion(node.path);
      if (!context.mounted) return;
      final dirtyCount = ws.dirtyDocuments.where((document) {
        return p.equals(document.path, node.path) ||
            p.isWithin(node.path, document.path);
      }).length;
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: kGlassFloatBg,
          shape: kDialogShape,
          title: const Text(
            '移至隔离区',
            style: TextStyle(fontSize: 15, color: Colors.white),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                preview.relativePath,
                style: const TextStyle(fontSize: 13, color: Colors.white70),
              ),
              const SizedBox(height: 10),
              Text(
                '文件 ${preview.fileCount} 个，目录 ${preview.directoryCount} 个，'
                '大小 ${_formatBytes(preview.totalBytes)}。',
                style: const TextStyle(fontSize: 13, color: Colors.white54),
              ),
              const SizedBox(height: 8),
              const Text(
                '内容将移动到 .Courier/trash，不会直接删除。',
                style: TextStyle(fontSize: 13, color: Colors.white54),
              ),
              if (dirtyCount > 0) ...[
                const SizedBox(height: 8),
                Text(
                  '包含 $dirtyCount 个未保存文档，继续将放弃这些更改。',
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFFF59E0B),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消', style: TextStyle(color: Colors.white54)),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFEF4444),
              ),
              child: const Text('确认移动', style: TextStyle(fontSize: 13)),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
      final result = await ws.deleteEntry(
        node.path,
        discardUnsaved: dirtyCount > 0,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已移至隔离区: ${result.originalRelativePath}'),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('移动失败: $error')));
    }
  }
}

enum _WorkspaceSwitchDecision { save, discard, cancel }

String _formatBytes(int bytes) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble();
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }
  final digits = unitIndex == 0 || value >= 10 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unitIndex]}';
}

Future<void> _createTaskFromFile(
  BuildContext context,
  FileTreeNode node,
) async {
  try {
    final workspace = context.read<WorkspaceService>();
    final content = await workspace.readFileContent(node.path);
    if (!context.mounted) return;
    await context.read<CourierService>().createTask(
      title: node.name,
      sourceType: 'plan-file',
      markdownContent: content,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已从 ${node.name} 创建任务')));
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('创建任务失败: $error')));
  }
}

Future<void> _openFile(
  BuildContext context,
  WorkspaceService workspace,
  FileTreeNode node,
) async {
  try {
    await workspace.openFile(node.path);
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('打开文件失败: $error')));
  }
}

/// 默认排除列表（用于判断是否可删除）
const _defaultExcludePatterns = [
  '.git',
  '.svn',
  '.hg',
  '.courier-*',
  'node_modules',
  'build',
  'dist',
  '.dart_tool',
  '__pycache__',
  '.idea',
  '.vscode',
  '*.tmp',
  '*.temp',
  '*~',
  '.DS_Store',
  'Thumbs.db',
];

/// _FileTreeTile — 文件树单行节点（平铺渲染，支持拖拽和右键）。
/// 展开状态由容器统一管理，本组件不递归子树，只渲染当前行。
class _FileTreeTile extends StatefulWidget {
  final FileTreeNode node;
  final bool isExpanded;
  final VoidCallback onToggleExpand;

  const _FileTreeTile({
    required this.node,
    required this.isExpanded,
    required this.onToggleExpand,
  });

  @override
  State<_FileTreeTile> createState() => _FileTreeTileState();
}

class _FileTreeTileState extends State<_FileTreeTile> {
  bool _isDragging = false;

  @override
  Widget build(BuildContext context) {
    final ws = context.read<WorkspaceService>();
    final isActive = ws.activeDocument?.path == widget.node.path;
    final isDir = widget.node.isDir;

    final row = _TileRow(
      node: widget.node,
      isDir: isDir,
      isActive: isActive,
      isExpanded: widget.isExpanded,
      isDragging: _isDragging,
      onToggleExpand: widget.onToggleExpand,
      onOpenFile: () => unawaited(_openFile(context, ws, widget.node)),
      onContextMenu: (details) {
        // 在文件树容器层面显示右键菜单
        final containerState = context
            .findAncestorStateOfType<_FileTreeContainerState>();
        containerState?._showContextMenu(
          details,
          widget.node,
          isDir ? 'folder' : 'file',
        );
      },
      onCreateTask: () => unawaited(_createTaskFromFile(context, widget.node)),
    );

    // 目录：直接渲染行；文件：包拖拽支持
    if (isDir) return row;

    return Draggable<FileDragPayload>(
      data: FileDragPayload(
        name: widget.node.name,
        path: widget.node.path,
        relativePath: widget.node.relativePath,
      ),
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: kPrimary,
            borderRadius: BorderRadius.circular(kRadiusSm),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.description, size: 14, color: Colors.white),
              const SizedBox(width: 4),
              Text(
                widget.node.name,
                style: const TextStyle(fontSize: 13, color: Colors.white),
              ),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: row),
      onDragStarted: () => setState(() => _isDragging = true),
      onDragEnd: (_) => setState(() => _isDragging = false),
      onDragCompleted: () => setState(() => _isDragging = false),
      child: row,
    );
  }
}

/// _TileRow — 文件树单行（独立 StatefulWidget，hover 只重建自身，
/// 避免鼠标扫过时整棵子树反复重建导致的卡顿）。
class _TileRow extends StatefulWidget {
  final FileTreeNode node;
  final bool isDir;
  final bool isActive;
  final bool isExpanded;
  final bool isDragging;
  final VoidCallback onToggleExpand;
  final VoidCallback onOpenFile;
  final void Function(TapDownDetails) onContextMenu;
  final VoidCallback onCreateTask;

  const _TileRow({
    required this.node,
    required this.isDir,
    required this.isActive,
    required this.isExpanded,
    required this.isDragging,
    required this.onToggleExpand,
    required this.onOpenFile,
    required this.onContextMenu,
    required this.onCreateTask,
  });

  @override
  State<_TileRow> createState() => _TileRowState();
}

class _TileRowState extends State<_TileRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final indent = widget.node.level * 14.0 + 8;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: InkWell(
        onTap: widget.isDir ? widget.onToggleExpand : widget.onOpenFile,
        onDoubleTap: widget.isDir ? widget.onOpenFile : null,
        onSecondaryTapDown: widget.onContextMenu,
        child: Container(
          padding: EdgeInsets.only(left: indent, right: 8),
          height: 28,
          decoration: BoxDecoration(
            color: widget.isActive
                ? kGlassSelectedBg
                : (_hover ? kGlassHoverBg : null),
            borderRadius: BorderRadius.circular(kRadiusSm),
          ),
          child: Row(
            children: [
              if (widget.isDir)
                Icon(
                  widget.isExpanded
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_right,
                  size: 17,
                  color: Colors.white54,
                )
              else
                const SizedBox(width: 16),
              const SizedBox(width: 2),
              Icon(
                widget.isDir ? Icons.folder : Icons.description,
                size: 16,
                color: widget.isDir
                    ? kPrimaryLight
                    : (widget.isActive ? kPrimaryLight : Colors.white38),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.node.name,
                  style: TextStyle(
                    fontSize: 13,
                    color: widget.isDragging
                        ? kPrimary
                        : (widget.isActive ? kPrimaryLight : Colors.white70),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!widget.isDir)
                InkWell(
                  onTap: widget.onCreateTask,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: Icon(
                      Icons.add_circle_outline,
                      size: 15,
                      color: Colors.white24,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// 辅助 Widget
// ============================================================

/// _MenuItem — 菜单项数据
class _MenuItem {
  final IconData icon;
  final String label;
  final bool enabled;
  final bool isDanger;
  final VoidCallback onTap;

  const _MenuItem({
    required this.icon,
    required this.label,
    this.enabled = true,
    this.isDanger = false,
    required this.onTap,
  });
}

/// _MenuItemWidget — 菜单项渲染
class _MenuItemWidget extends StatelessWidget {
  final _MenuItem item;
  const _MenuItemWidget({required this.item});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: item.enabled ? item.onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(
              item.icon,
              size: 15,
              color: !item.enabled
                  ? Colors.white12
                  : item.isDanger
                  ? const Color(0xFFEF4444)
                  : Colors.white54,
            ),
            const SizedBox(width: 8),
            Text(
              item.label,
              style: TextStyle(
                fontSize: 13,
                color: !item.enabled
                    ? Colors.white12
                    : item.isDanger
                    ? const Color(0xFFEF4444)
                    : Colors.white70,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// _CategoryChip — 分类过滤标签
class _CategoryChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool enabled;
  final VoidCallback onTap;

  const _CategoryChip({
    required this.label,
    required this.icon,
    required this.color,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: enabled ? color.withValues(alpha: 0.18) : kGlassChipBg,
          borderRadius: BorderRadius.circular(kRadiusSm),
          border: Border.all(
            color: enabled ? color.withValues(alpha: 0.4) : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 10, color: enabled ? color : Colors.white24),
            const SizedBox(width: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: enabled ? color : Colors.white24,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
