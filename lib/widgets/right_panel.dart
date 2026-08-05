// right_panel.dart — 右侧功能面板（Tab 容器）
//
// 包含两个标签页：AI 助手、任务队列。
// 整个内容区域支持接收文件拖拽，自动切换到任务队列并创建任务。

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'ai_assistant_panel.dart';
import 'task_queue_panel.dart';
import '../services/courier_core_service.dart';
import '../services/workspace_service.dart';

class RightPanel extends StatefulWidget {
  final VoidCallback? onOpenSettings;

  const RightPanel({super.key, this.onOpenSettings});

  @override
  State<RightPanel> createState() => _RightPanelState();
}

class _RightPanelState extends State<RightPanel> {
  int _activeTab = 0;
  bool _isDragOver = false;

  /// 处理拖入的文件：自动切换到任务队列 Tab 并创建任务
  void _handleDroppedFile(FileDragPayload payload) {
    // 自动切换到任务队列 Tab
    setState(() {
      _activeTab = 1;
      _isDragOver = false;
    });

    final service = context.read<CourierCoreService?>();
    if (service == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('核心服务未加载，无法创建任务')),
      );
      return;
    }

    () async {
      try {
        final ws = context.read<WorkspaceService>();
        final content = await ws.readFileContent(payload.path);
        if (!mounted) return;

        service.createTask(
          title: payload.name,
          sourceType: 'plan-file',
          markdownContent: content,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('已从 ${payload.name} 创建任务'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('创建任务失败: $e')),
          );
        }
      }
    }();
  }

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WorkspaceService>();
    final service = context.watch<CourierCoreService?>();
    final taskCount = service?.queueSummary?.total ?? 0;

    return Container(
      color: const Color(0xFF0A0E1A),
      child: Column(
        children: [
          // Tab 栏
          Container(
            height: 36,
            decoration: const BoxDecoration(
              color: Color(0xFF111827),
              border: Border(bottom: BorderSide(color: Color(0xFF1E2438))),
            ),
            child: Row(
              children: [
                _TabButton(
                  label: 'AI 助手',
                  icon: Icons.smart_toy,
                  active: _activeTab == 0,
                  onTap: () => setState(() => _activeTab = 0),
                ),
                _TabButton(
                  label: '任务队列',
                  icon: Icons.queue,
                  badge: taskCount,
                  active: _activeTab == 1,
                  onTap: () => setState(() => _activeTab = 1),
                ),
              ],
            ),
          ),
          // 内容区 — 整个区域接收拖拽
          Expanded(
            child: DragTarget<FileDragPayload>(
              onAcceptWithDetails: (details) => _handleDroppedFile(details.data),
              onWillAcceptWithDetails: (details) {
                if (!_isDragOver) setState(() => _isDragOver = true);
                return true;
              },
              onLeave: (_) {
                if (_isDragOver) setState(() => _isDragOver = false);
              },
              builder: (context, candidateData, rejectedData) {
                return Stack(
                  children: [
                    _activeTab == 0
                        ? AIAssistantPanel(
                            workspacePath: ws.workspacePath,
                            onOpenSettings: widget.onOpenSettings,
                          )
                        : TaskQueuePanel(
                            onOpenSettings: widget.onOpenSettings,
                          ),
                    // 拖拽时的全屏覆盖提示
                    if (_isDragOver)
                      Positioned.fill(
                        child: Container(
                          color: const Color(0xFF6366F1).withValues(alpha: 0.1),
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                              decoration: BoxDecoration(
                                color: const Color(0xFF111827),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: const Color(0xFF6366F1).withValues(alpha: 0.5),
                                  width: 2,
                                ),
                              ),
                              child: const Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.download, size: 32, color: Color(0xFF818CF8)),
                                  SizedBox(height: 8),
                                  Text(
                                    '松开创建任务',
                                    style: TextStyle(fontSize: 14, color: Color(0xFF818CF8)),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final int badge;
  final bool active;
  final VoidCallback onTap;

  const _TabButton({
    required this.label,
    required this.icon,
    this.badge = 0,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: active ? const Color(0xFF6366F1) : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 13, color: active ? const Color(0xFF818CF8) : Colors.white38),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: active ? Colors.white : Colors.white54,
                  fontWeight: active ? FontWeight.w500 : FontWeight.normal,
                ),
              ),
              if (badge > 0) ...[
                const SizedBox(width: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: const Color(0xFF6366F1).withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '$badge',
                    style: const TextStyle(fontSize: 9, color: Color(0xFF818CF8)),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
