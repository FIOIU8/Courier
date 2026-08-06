// right_panel.dart — 右侧功能面板（Tab 容器）
//
// 包含三个标签页：助手、任务队列、Git。
// 整个内容区域支持接收文件拖拽，自动切换到任务队列并创建任务。

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import 'ai_assistant_panel.dart';
import 'git_panel.dart';
import 'task_queue_panel.dart';
import '../services/courier_service.dart';
import '../services/workspace_service.dart';
import 'animations.dart';
import 'glass.dart';

class RightPanel extends StatefulWidget {
  final VoidCallback? onOpenSettings;

  const RightPanel({super.key, this.onOpenSettings});

  @override
  State<RightPanel> createState() => _RightPanelState();
}

class _RightPanelState extends State<RightPanel> {
  int _activeTab = 0;

  /// Tab 切换滑动方向：1 = 新面板从右滑入（前进）；-1 = 从左滑入（后退）
  int _slideDirection = 1;
  bool _isDragOver = false;

  /// 文件拖入位置：true = 从左侧拖入（覆盖提示从左滑入）
  bool _dragFromLeft = false;

  /// 拖入文件类型限制：仅允许 Markdown / 纯文本
  bool _isAllowedDragFile(String path) {
    final extension = p.extension(path).toLowerCase();
    return extension == '.md' || extension == '.txt';
  }

  void _switchTab(int index) {
    if (index == _activeTab) return;
    setState(() {
      _slideDirection = index > _activeTab ? 1 : -1;
      _activeTab = index;
    });
  }

  /// 处理拖入的文件：自动切换到任务队列 Tab 并创建任务
  void _handleDroppedFile(FileDragPayload payload) {
    // 自动切换到任务队列 Tab（拖入视为前进，新面板从右滑入）
    setState(() {
      _slideDirection = 1;
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
          decoration: BoxDecoration(
            color: glassHeaderBgOf(context),
            border: Border(bottom: BorderSide(color: glassBorderOf(context))),
          ),
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: kGlassChipBg,
              borderRadius: BorderRadius.circular(kRadiusMd),
              border: Border.all(color: glassBorderOf(context)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _SegTab(
                    label: '助手',
                    icon: Icons.smart_toy,
                    active: _activeTab == 0,
                    onTap: () => _switchTab(0),
                  ),
                ),
                Expanded(
                  child: _SegTab(
                    label: '任务',
                    icon: Icons.queue,
                    badge: taskCount,
                    active: _activeTab == 1,
                    onTap: () => _switchTab(1),
                  ),
                ),
                Expanded(
                  child: _SegTab(
                    label: 'Git',
                    icon: Icons.account_tree,
                    active: _activeTab == 2,
                    onTap: () => _switchTab(2),
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
              // 仅接受 md / txt 文件；其余类型直接拒绝（不显示拖入提示）
              if (!_isAllowedDragFile(details.data.path)) return false;
              if (!_isDragOver) {
                // 记录拖入位置，决定覆盖提示的滑入方向
                final box = context.findRenderObject() as RenderBox?;
                final local = box != null
                    ? box.globalToLocal(details.offset)
                    : details.offset;
                setState(() {
                  _dragFromLeft =
                      local.dx < (box?.size.width ?? double.infinity) / 2;
                  _isDragOver = true;
                });
              }
              return true;
            },
            onLeave: (_) {
              if (_isDragOver) setState(() => _isDragOver = false);
            },
            builder: (context, candidateData, rejectedData) {
              return Stack(
                children: [
                  // 内容区切换动画：反向推入。
                  // 前进（如 助手→任务）时新面板从右滑入、旧面板向左滑出；
                  // 后退时新面板从左滑入、旧面板向右滑出（方向相反不重叠）。
                  // 位于外层 Glass 内部，不影响毛玻璃模糊。
                  _SlideSwitcher(
                    direction: _slideDirection,
                    child: switch (_activeTab) {
                      0 => AIAssistantPanel(
                        key: const ValueKey('assistant-panel'),
                        workspacePath: ws.workspacePath,
                        onOpenSettings: widget.onOpenSettings,
                      ),
                      1 => TaskQueuePanel(
                        key: const ValueKey('task-panel'),
                        onOpenSettings: widget.onOpenSettings,
                      ),
                      _ => GitPanel(
                        key: ValueKey('git-panel-${ws.workspacePath}'),
                      ),
                    },
                  ),
                  // 拖拽时的全屏覆盖提示：从文件拖入的方向滑入/滑出
                  Positioned.fill(
                    child: AnimatedSwitcher(
                      duration: kAnimDurationMed,
                      switchInCurve: kAnimCurveIn,
                      switchOutCurve: kAnimCurveOut,
                      transitionBuilder: (child, animation) {
                        return SlideTransition(
                          position: Tween<Offset>(
                            begin: Offset(_dragFromLeft ? -1 : 1, 0),
                            end: Offset.zero,
                          ).animate(animation),
                          child: child,
                        );
                      },
                      child: _isDragOver
                          ? Container(
                              key: const ValueKey('drag-overlay'),
                              color: glassSelectedBgOf(context),
                              child: Center(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 24,
                                    vertical: 16,
                                  ),
                                  decoration: BoxDecoration(
                                    color: glassFloatBgOf(context),
                                    borderRadius: BorderRadius.circular(
                                      kRadiusLg,
                                    ),
                                    border: Border.all(
                                      color: accentLightOf(
                                        context,
                                      ).withValues(alpha: 0.5),
                                      width: 1.5,
                                    ),
                                    boxShadow: kShadowLg,
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.download,
                                        size: 32,
                                        color: accentLightOf(context),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        '松开创建任务',
                                        style: TextStyle(
                                          fontSize: 15,
                                          color: accentLightOf(context),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            )
                          : const SizedBox.shrink(
                              key: ValueKey('drag-overlay-none'),
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

/// 反向推入式面板切换容器：
/// 新面板从 [direction] 一侧滑入，旧面板向相反一侧滑出（方向相反、互不重叠）。
/// 用 child 的 key 变化触发切换；动画期间旧面板不可交互。
class _SlideSwitcher extends StatefulWidget {
  final Widget child;

  /// 切换方向：1 = 前进（新面板从右滑入、旧面板向左滑出）；
  /// -1 = 后退（新面板从左滑入、旧面板向右滑出）。
  final int direction;

  const _SlideSwitcher({required this.child, required this.direction});

  @override
  State<_SlideSwitcher> createState() => _SlideSwitcherState();
}

class _SlideSwitcherState extends State<_SlideSwitcher>
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
      // 初始为完成态：当前面板静止在原位（position = Offset.zero），
      // 避免初始 value=0 时 SlideTransition 停在 begin 导致首屏空白。
      ..value = 1
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          // 仅移除旧面板，不复位 controller：复位会让新面板的
          // SlideTransition 回到 begin（移出屏幕）导致内容空白。
          setState(() => _previousChild = null);
        }
      });
    _inAnimation = CurvedAnimation(parent: _controller, curve: kAnimCurveIn);
    _outAnimation = CurvedAnimation(parent: _controller, curve: kAnimCurveOut);
  }

  @override
  void didUpdateWidget(_SlideSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.child.key != oldWidget.child.key) {
      // 固化本次切换方向：旧面板向相反一侧滑出（前进时向左、后退时向右）
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
    // 切换动画期间在页面层下方铺一层不透明面板底色：面板主体是透明的，
    // 若不加遮盖，滑动时新旧页面并排会直接露出背后的背景图片；
    // 切换完成后淡出遮盖，恢复面板的实际透明度。
    final covering = _previousChild != null;
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: AnimatedOpacity(
            opacity: covering ? 1.0 : 0.0,
            duration: covering ? Duration.zero : kAnimDurationFast,
            curve: kAnimCurveIn,
            child: ColoredBox(color: glassSurfaceSolidColor(context)),
          ),
        ),
        if (_previousChild != null)
          AnimatedBuilder(
            animation: _outAnimation,
            // 直接传递旧面板 widget（不额外包装），保证同 key 时 Element 复用、
            // State 保留；Stack 上层的新面板会挡住对旧面板的点击，无需 IgnorePointer。
            child: _previousChild!,
            builder: (context, child) => SlideTransition(
              position: Tween<Offset>(
                begin: Offset.zero,
                end: Offset(-_previousDirection.toDouble(), 0),
              ).animate(_outAnimation),
              child: child,
            ),
          ),
        AnimatedBuilder(
          animation: _inAnimation,
          child: widget.child,
          builder: (context, child) => SlideTransition(
            position: Tween<Offset>(
              begin: Offset(widget.direction.toDouble(), 0),
              end: Offset.zero,
            ).animate(_inAnimation),
            child: child,
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
    final accent = accentColorOf(context);
    final accentLight = accentLightOf(context);
    return AnimatedContainer(
      duration: kAnimDurationFast,
      curve: kAnimCurveIn,
      decoration: BoxDecoration(
        color: active ? accent.withValues(alpha: 0.18) : Colors.transparent,
        borderRadius: BorderRadius.circular(kRadiusSm),
        border: Border.all(
          color: active ? accent.withValues(alpha: 0.45) : Colors.transparent,
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
                color: active ? accentLight : Colors.white54,
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
                        ? accent.withValues(alpha: 0.3)
                        : kGlassChipBg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$badge',
                    style: TextStyle(fontSize: 12, color: accentLight),
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
