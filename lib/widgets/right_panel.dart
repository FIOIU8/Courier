// right_panel.dart — 右侧功能面板（Tab 容器）
//
// 包含三个标签页：AI 助手、任务队列、Git。
// 整个内容区域支持接收文件拖拽，自动切换到任务队列并创建任务。

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'ai_assistant_panel.dart';
import 'git_panel.dart';
import 'task_queue_panel.dart';
import '../services/courier_service.dart';
import '../services/workspace_service.dart';
import 'glass.dart';

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

    final service = context.read<CourierService>();

    () async {
      try {
        final ws = context.read<WorkspaceService>();
        final content = await ws.readFileContent(payload.path);
        if (!mounted) return;

        await service.createTask(
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
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('创建任务失败: $e')));
        }
      }
    }();
  }

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WorkspaceService>();
    final service = context.watch<CourierService>();
    final taskCount = service.queueSummary.total;

    return Column(
      children: [
        // Tab 栏（组合按钮 segmented）
        Container(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          decoration: const BoxDecoration(
            color: kGlassHeaderBg,
            border: Border(bottom: BorderSide(color: kGlassBorder)),
          ),
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: kGlassChipBg,
              borderRadius: BorderRadius.circular(kRadiusMd),
              border: Border.all(color: kGlassBorder),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _SegTab(
                    label: 'AI',
                    icon: Icons.smart_toy,
                    active: _activeTab == 0,
                    onTap: () => setState(() => _activeTab = 0),
                  ),
                ),
                Expanded(
                  child: _SegTab(
                    label: '任务',
                    icon: Icons.queue,
                    badge: taskCount,
                    active: _activeTab == 1,
                    onTap: () => setState(() => _activeTab = 1),
                  ),
                ),
                Expanded(
                  child: _SegTab(
                    label: 'Git',
                    icon: Icons.account_tree,
                    active: _activeTab == 2,
                    onTap: () => setState(() => _activeTab = 2),
                  ),
                ),
              ],
            ),
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
                  switch (_activeTab) {
                    0 => AIAssistantPanel(
                      workspacePath: ws.workspacePath,
                      onOpenSettings: widget.onOpenSettings,
                    ),
                    1 => TaskQueuePanel(onOpenSettings: widget.onOpenSettings),
                    _ => GitPanel(key: ValueKey(ws.workspacePath)),
                  },
                  // 拖拽时的全屏覆盖提示
                  if (_isDragOver)
                    Positioned.fill(
                      child: Container(
                        color: kGlassSelectedBg,
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 16,
                            ),
                            decoration: BoxDecoration(
                              color: kGlassFloatBg,
                              borderRadius: BorderRadius.circular(kRadiusLg),
                              border: Border.all(
                                color: kPrimaryLight.withValues(alpha: 0.5),
                                width: 1.5,
                              ),
                              boxShadow: kShadowLg,
                            ),
                            child: const Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.download,
                                  size: 32,
                                  color: kPrimaryLight,
                                ),
                                SizedBox(height: 8),
                                Text(
                                  '松开创建任务',
                                  style: TextStyle(
                                    fontSize: 15,
                                    color: kPrimaryLight,
                                  ),
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
    );
  }
}

class _SegTab extends StatelessWidget {
  final String label;
  final IconData icon;
  final int badge;
  final bool active;
  final VoidCallback onTap;

  const _SegTab({
    required this.label,
    required this.icon,
    this.badge = 0,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: active ? kPrimary.withValues(alpha: 0.18) : Colors.transparent,
        borderRadius: BorderRadius.circular(kRadiusSm),
        border: Border.all(
          color: active ? kPrimary.withValues(alpha: 0.45) : Colors.transparent,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(kRadiusSm),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 16,
                color: active ? kPrimaryLight : Colors.white54,
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  color: active ? Colors.white : Colors.white70,
                  fontWeight: active ? FontWeight.w500 : FontWeight.normal,
                ),
              ),
              if (badge > 0) ...[
                const SizedBox(width: 5),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: active
                        ? kPrimary.withValues(alpha: 0.3)
                        : kGlassChipBg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$badge',
                    style: const TextStyle(fontSize: 12, color: kPrimaryLight),
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
