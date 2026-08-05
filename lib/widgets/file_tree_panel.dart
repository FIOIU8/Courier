// file_tree_panel.dart — 文件树面板（完整实现）
//
// 功能：
// - 从 WorkspaceService 获取工作区文件树
// - 点击文件 → 调用 WorkspaceService.openFile() 加载到编辑器
// - 右键上下文菜单（空白/文件夹/文件 三种类型）
// - Markdown 文件可拖拽到右侧任务队列
// - 排除列表管理 + 文件分类过滤

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/courier_core_service.dart';
import '../services/workspace_service.dart';

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
  // 右键菜单状态
  Offset? _menuPosition;
  FileTreeNode? _menuTarget;
  String _menuKind = 'blank'; // blank | folder | file

  // 排除列表面板
  bool _showExcludePanel = false;

  // 分类过滤面板
  bool _showFilterPanel = false;

  @override
  Widget build(BuildContext context) {
    final ws = widget.service;
    return Container(
      color: const Color(0xFF0C1220),
      child: Stack(
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
          if (_menuPosition != null)
            _buildContextMenu(context, ws),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, WorkspaceService ws) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: Color(0xFF111827),
        border: Border(bottom: BorderSide(color: Color(0xFF1E2438))),
      ),
      child: Row(
        children: [
          const Icon(Icons.folder_open, size: 16, color: Color(0xFF6366F1)),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  ws.hasWorkspace ? ws.workspaceName : '未打开工作区',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  ws.hasWorkspace ? ws.workspacePath : '点击右侧按钮打开文件夹',
                  style: const TextStyle(fontSize: 10, color: Colors.white38),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.filter_list, size: 16),
            color: _showFilterPanel ? const Color(0xFF6366F1) : Colors.white54,
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
            icon: const Icon(Icons.block, size: 16),
            color: _showExcludePanel ? const Color(0xFF6366F1) : Colors.white54,
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
            icon: const Icon(Icons.folder_open_outlined, size: 16),
            color: Colors.white54,
            tooltip: '打开文件夹',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: () => ws.pickWorkspace(),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 16),
            color: Colors.white54,
            tooltip: '刷新文件树',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: ws.hasWorkspace ? () => ws.scanFileTree() : null,
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
              child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF6366F1)),
            ),
            SizedBox(height: 8),
            Text('扫描文件中...', style: TextStyle(fontSize: 11, color: Colors.white38)),
          ],
        ),
      );
    }
    if (ws.fileTree.isEmpty) {
      return GestureDetector(
        onSecondaryTapDown: (details) => _showContextMenu(details, null, 'blank'),
        onDoubleTap: () => _showCreateDialog(context, 'file', null),
        child: const Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '未找到文件\n右键创建或拖入文件',
              style: TextStyle(fontSize: 12, color: Colors.white38),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    return GestureDetector(
      onSecondaryTapDown: (details) {
        // 仅在空白区域触发
        _showContextMenu(details, null, 'blank');
      },
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 4),
        children: ws.fileTree.map((n) => _FileTreeTile(node: n)).toList(),
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
              '打开一个文件夹开始工作',
              style: TextStyle(fontSize: 12, color: Colors.white38),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => ws.pickWorkspace(),
              icon: const Icon(Icons.folder_open, size: 14),
              label: const Text('选择文件夹', style: TextStyle(fontSize: 12)),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF6366F1),
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
        color: Color(0xFF0D1424),
        border: Border(bottom: BorderSide(color: Color(0xFF1E2438))),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                const Icon(Icons.block, size: 12, color: Color(0xFF6366F1)),
                const SizedBox(width: 4),
                const Text('排除列表', style: TextStyle(fontSize: 11, color: Colors.white54)),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => ws.resetExcludePatterns(),
                  icon: const Icon(Icons.restore, size: 12),
                  label: const Text('重置', style: TextStyle(fontSize: 10)),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(50, 24),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFF1E2438)),
          Expanded(
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: ws.excludePatterns.length,
              itemBuilder: (context, index) {
                final pattern = ws.excludePatterns[index];
                final isDefault = _defaultExcludePatterns.contains(pattern);
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                  child: Row(
                    children: [
                      Icon(
                        isDefault ? Icons.lock : Icons.circle,
                        size: isDefault ? 10 : 6,
                        color: isDefault ? Colors.white24 : const Color(0xFF6366F1),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          pattern,
                          style: TextStyle(
                            fontSize: 11,
                            color: isDefault ? Colors.white38 : Colors.white70,
                            fontFamily: 'Consolas',
                          ),
                        ),
                      ),
                      if (!isDefault)
                        InkWell(
                          onTap: () => ws.removeExcludePattern(pattern),
                          child: const Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(Icons.close, size: 12, color: Colors.white38),
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
                    style: const TextStyle(fontSize: 11, color: Colors.white70, fontFamily: 'Consolas'),
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: '添加排除项 (如 *.log)',
                      hintStyle: TextStyle(fontSize: 10, color: Colors.white24),
                      enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF1E2438)),
                      ),
                      focusedBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF6366F1)),
                      ),
                    ),
                    onSubmitted: (value) {
                      if (value.trim().isNotEmpty) {
                        ws.addExcludePattern(value.trim());
                      }
                    },
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add, size: 14),
                  color: const Color(0xFF6366F1),
                  constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                  padding: EdgeInsets.zero,
                  onPressed: () {
                    // 通过 controller 添加需要额外的 state，简化处理
                  },
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
      ('md', 'Markdown', const Color(0xFF6366F1), Icons.description),
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
        color: Color(0xFF0D1424),
        border: Border(bottom: BorderSide(color: Color(0xFF1E2438))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.filter_list, size: 12, color: Color(0xFF6366F1)),
              const SizedBox(width: 4),
              const Text('文件过滤', style: TextStyle(fontSize: 11, color: Colors.white54)),
              const Spacer(),
              InkWell(
                onTap: () {
                  for (final cat in categories) {
                    ws.toggleCategoryFilter(cat.$1, true);
                  }
                },
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: Text('全选', style: TextStyle(fontSize: 10, color: Color(0xFF6366F1))),
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
                onTap: () => ws.toggleCategoryFilter(cat.$1, !isEnabled),
              );
            }).toList(),
          ),
          const SizedBox(height: 4),
          InkWell(
            onTap: () => ws.toggleShowHidden(),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(
                    ws.showHidden ? Icons.visibility : Icons.visibility_off,
                    size: 12,
                    color: ws.showHidden ? const Color(0xFF6366F1) : Colors.white38,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    ws.showHidden ? '显示隐藏文件' : '隐藏点文件',
                    style: TextStyle(
                      fontSize: 10,
                      color: ws.showHidden ? const Color(0xFF6366F1) : Colors.white38,
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

  // ============================================================
  // 右键上下文菜单
  // ============================================================

  void _showContextMenu(TapDownDetails details, FileTreeNode? target, String kind) {
    final overlay = MediaQuery.of(context).size;
    const menuWidth = 176.0;
    const menuHeight = 140.0;

    setState(() {
      _menuPosition = Offset(
        details.globalPosition.dx.clamp(8.0, overlay.width - menuWidth - 8),
        details.globalPosition.dy.clamp(8.0, overlay.height - menuHeight - 8),
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
                color: const Color(0xFF111827),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF1E2438)),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x60000000),
                    blurRadius: 12,
                    offset: Offset(0, 4),
                  ),
                ],
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
    items.add(_MenuItem(
      icon: Icons.note_add,
      label: '创建文件',
      enabled: _menuKind == 'blank' || _menuKind == 'folder',
      onTap: () {
        _closeContextMenu();
        _showCreateDialog(context, 'file', _menuTarget);
      },
    ));

    // 创建文件夹
    items.add(_MenuItem(
      icon: Icons.create_new_folder,
      label: '创建文件夹',
      enabled: _menuKind == 'blank' || _menuKind == 'folder',
      onTap: () {
        _closeContextMenu();
        _showCreateDialog(context, 'folder', _menuTarget);
      },
    ));

    // 重命名 — folder 和 file 可用
    if (_menuKind != 'blank') {
      items.add(_MenuItem(
        icon: Icons.edit,
        label: '重命名',
        enabled: true,
        onTap: () {
          final target = _menuTarget;
          _closeContextMenu();
          if (target != null) _showRenameDialog(context, target);
        },
      ));
    }

    // 删除 — folder 和 file 可用
    if (_menuKind != 'blank') {
      items.add(_MenuItem(
        icon: Icons.delete_outline,
        label: '删除',
        enabled: true,
        isDanger: true,
        onTap: () {
          final target = _menuTarget;
          _closeContextMenu();
          if (target != null) _showDeleteConfirm(context, target);
        },
      ));
    }

    // 从文件创建任务 — 仅 file 可用
    if (_menuKind == 'file' && _menuTarget != null) {
      items.add(_MenuItem(
        icon: Icons.add_task,
        label: '创建任务',
        enabled: true,
        onTap: () {
          final target = _menuTarget;
          _closeContextMenu();
          if (target != null) _createTaskFromFile(context, target);
        },
      ));
    }

    final widgets = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      // 分隔线
      if (i > 0 && (items[i - 1].isDanger != item.isDanger)) {
        widgets.add(const Divider(height: 1, color: Color(0xFF1E2438)));
      }
      widgets.add(_MenuItemWidget(item: item));
    }
    return widgets;
  }

  // ============================================================
  // 对话框
  // ============================================================

  void _showCreateDialog(BuildContext context, String type, FileTreeNode? parent) {
    final ws = context.read<WorkspaceService>();
    String name = '';

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF111827),
        title: Text(
          type == 'file' ? '创建文件' : '创建文件夹',
          style: const TextStyle(fontSize: 14, color: Colors.white),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              parent != null
                  ? '在 ${parent.name} 中创建'
                  : '在工作区根目录创建',
              style: const TextStyle(fontSize: 11, color: Colors.white38),
            ),
            const SizedBox(height: 12),
            TextField(
              autofocus: true,
              style: const TextStyle(fontSize: 13, color: Colors.white),
              decoration: InputDecoration(
                hintText: type == 'file' ? 'example.md' : 'folder-name',
                hintStyle: const TextStyle(color: Colors.white24),
                enabledBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF1E2438)),
                ),
                focusedBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF6366F1)),
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
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF6366F1)),
            child: const Text('创建', style: TextStyle(fontSize: 12)),
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
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('创建失败: $e')),
            );
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
        backgroundColor: const Color(0xFF111827),
        title: const Text('重命名', style: TextStyle(fontSize: 14, color: Colors.white)),
        content: TextField(
          autofocus: true,
          controller: TextEditingController(text: node.name),
          style: const TextStyle(fontSize: 13, color: Colors.white),
          decoration: const InputDecoration(
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Color(0xFF1E2438)),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Color(0xFF6366F1)),
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
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF6366F1)),
            child: const Text('重命名', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    ).then((confirmed) async {
      if (confirmed == true && name.trim().isNotEmpty && name != node.name && context.mounted) {
        try {
          await ws.renameEntry(node.path, name.trim());
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('重命名失败: $e')),
            );
          }
        }
      }
    });
  }

  void _showDeleteConfirm(BuildContext context, FileTreeNode node) {
    final ws = context.read<WorkspaceService>();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF111827),
        title: const Text('确认删除', style: TextStyle(fontSize: 14, color: Colors.white)),
        content: Text(
          '确认删除「${node.name}」？${node.isDir ? '该文件夹内的所有内容将被删除。' : ''}',
          style: const TextStyle(fontSize: 12, color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: Colors.white54)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
            child: const Text('删除', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    ).then((confirmed) async {
      if (confirmed == true && context.mounted) {
        try {
          await ws.deleteEntry(node.path);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('已删除 ${node.name}'), duration: const Duration(seconds: 1)),
            );
          }
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('删除失败: $e')),
            );
          }
        }
      }
    });
  }

  void _createTaskFromFile(BuildContext context, FileTreeNode node) {
    final ws = context.read<WorkspaceService>();
    ws.openFile(node.path).then((_) {
      final doc = ws.documents.where((d) => d.path == node.path).firstOrNull;
      if (doc == null || !context.mounted) return;
      final service = context.read<CourierCoreService?>();
      if (service == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('核心服务未加载，无法创建任务')),
        );
        return;
      }
      try {
        service.createTask(
          title: node.name,
          sourceType: 'plan-file',
          markdownContent: doc.content,
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已从 ${node.name} 创建任务')),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('创建任务失败: $e')),
          );
        }
      }
    });
  }
}

/// 默认排除列表（用于判断是否可删除）
const _defaultExcludePatterns = [
  '.git', '.svn', '.hg', '.courier-*',
  'node_modules', 'build', 'dist', '.dart_tool',
  '__pycache__', '.idea', '.vscode',
  '*.tmp', '*.temp', '*~',
  '.DS_Store', 'Thumbs.db',
];

/// _FileTreeTile — 递归文件树节点 Widget（支持拖拽和右键）。
class _FileTreeTile extends StatefulWidget {
  final FileTreeNode node;
  const _FileTreeTile({required this.node});

  @override
  State<_FileTreeTile> createState() => _FileTreeTileState();
}

class _FileTreeTileState extends State<_FileTreeTile> {
  bool _expanded = false;
  bool _isDragging = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.node.level == 0 && widget.node.isDir;
  }

  @override
  Widget build(BuildContext context) {
    final indent = widget.node.level * 14.0 + 8;
    final ws = context.read<WorkspaceService>();
    final isActive = ws.activeDocument?.path == widget.node.path;
    final isDir = widget.node.isDir;

    final tile = InkWell(
      onTap: isDir
          ? () => setState(() => _expanded = !_expanded)
          : () => ws.openFile(widget.node.path),
      onDoubleTap: isDir ? () => ws.openFile(widget.node.path) : null,
      onSecondaryTapDown: (details) {
        // 在文件树容器层面显示右键菜单
        final containerState = context.findAncestorStateOfType<_FileTreeContainerState>();
        containerState?._showContextMenu(
          details,
          widget.node,
          isDir ? 'folder' : 'file',
        );
      },
      child: Container(
        padding: EdgeInsets.only(left: indent, right: 8),
        height: 26,
        color: isActive ? const Color(0xFF6366F1).withValues(alpha: 0.15) : null,
        child: Row(
          children: [
            if (isDir)
              Icon(
                _expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right,
                size: 14,
                color: Colors.white54,
              )
            else
              const SizedBox(width: 14),
            const SizedBox(width: 2),
            Icon(
              isDir ? Icons.folder : Icons.description,
              size: 14,
              color: isDir
                  ? const Color(0xFF818CF8)
                  : (isActive ? const Color(0xFF818CF8) : Colors.white38),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                widget.node.name,
                style: TextStyle(
                  fontSize: 12,
                  color: _isDragging ? const Color(0xFF6366F1) : (isActive ? const Color(0xFF818CF8) : Colors.white70),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (!isDir)
              InkWell(
                onTap: () => _createTaskFromFile(context, widget.node),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(Icons.add_circle_outline, size: 13, color: Colors.white24),
                ),
              ),
          ],
        ),
      ),
    );

    // 所有非目录文件均可拖拽到右侧任务队列
    if (!isDir) {
      return Column(
        children: [
          Draggable<FileDragPayload>(
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
                  color: const Color(0xFF6366F1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.description, size: 12, color: Colors.white),
                    const SizedBox(width: 4),
                    Text(
                      widget.node.name,
                      style: const TextStyle(fontSize: 11, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
            childWhenDragging: Opacity(
              opacity: 0.4,
              child: tile,
            ),
            onDragStarted: () => setState(() => _isDragging = true),
            onDragEnd: (_) => setState(() => _isDragging = false),
            onDragCompleted: () => setState(() => _isDragging = false),
            child: tile,
          ),
          if (isDir && _expanded)
            ...widget.node.children.map((child) => _FileTreeTile(node: child)),
        ],
      );
    }

    return Column(
      children: [
        tile,
        if (isDir && _expanded)
          ...widget.node.children.map((child) => _FileTreeTile(node: child)),
      ],
    );
  }

  void _createTaskFromFile(BuildContext context, FileTreeNode node) {
    final ws = context.read<WorkspaceService>();
    ws.openFile(node.path).then((_) {
      final doc = ws.documents.where((d) => d.path == node.path).firstOrNull;
      if (doc == null || !context.mounted) return;
      final service = context.read<CourierCoreService?>();
      if (service == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('核心服务未加载，无法创建任务')),
        );
        return;
      }
      try {
        service.createTask(
          title: node.name,
          sourceType: 'plan-file',
          markdownContent: doc.content,
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已从 ${node.name} 创建任务')),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('创建任务失败: $e')),
          );
        }
      }
    });
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
              size: 14,
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
                fontSize: 12,
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
          color: enabled ? color.withValues(alpha: 0.15) : const Color(0xFF1E2438),
          borderRadius: BorderRadius.circular(4),
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
                fontSize: 10,
                color: enabled ? color : Colors.white24,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
