// task_queue_panel.dart - Persistent task queue controls and detail view.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/courier_service.dart';
import '../services/models.dart';
import '../services/settings_state.dart';
import 'animations.dart';
import 'glass.dart';

class TaskQueuePanel extends StatefulWidget {
  final VoidCallback? onTotalChange;
  final VoidCallback? onOpenSettings;

  const TaskQueuePanel({super.key, this.onTotalChange, this.onOpenSettings});

  @override
  State<TaskQueuePanel> createState() => _TaskQueuePanelState();

  /// 显示执行方式选择对话框，返回 [TaskConfig] 或 null（用户取消）。
  /// 用于文件拖拽/右键菜单创建任务时让用户选择执行器和权限。
  static Future<TaskConfig?> showTaskConfigDialog(
    BuildContext context,
  ) async {
    final codexAvailable =
        context.read<CourierService>().config.codexAvailable;

    final config = await showDialog<TaskConfig>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => _TaskConfigDialog(
        codexAvailable: codexAvailable,
      ),
    );

    if (config == null) return null;

    // YOLO 模式二次确认
    if (config.executorType == TaskExecutorType.codex &&
        config.permission == TaskPermission.yolo) {
      if (!context.mounted) return null;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => CourierDialog(
          title: const Text('⚠️ 危险操作确认'),
          content: const Text(TaskPermission.yoloWarning),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFEF4444),
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('确认执行'),
            ),
          ],
        ),
      );
      if (confirmed != true) return null;
    }

    return config;
  }
}

/// 任务执行配置（执行器类型 + 权限级别）。
class TaskConfig {
  final String executorType;
  final String permission;

  const TaskConfig({required this.executorType, required this.permission});
}

/// 任务配置对话框 — 独立 StatefulWidget 确保下拉框状态正确。
class _TaskConfigDialog extends StatefulWidget {
  final bool codexAvailable;

  const _TaskConfigDialog({required this.codexAvailable});

  @override
  State<_TaskConfigDialog> createState() => _TaskConfigDialogState();
}

class _TaskConfigDialogState extends State<_TaskConfigDialog> {
  String _executor = TaskExecutorType.ai;
  String _permission = TaskPermission.readOnly;

  @override
  Widget build(BuildContext context) {
    return CourierDialog(
      title: const Text('选择执行方式'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 执行方式选择
          DropdownButtonFormField<String>(
            initialValue: _executor,
            decoration: const InputDecoration(
              labelText: '执行方式',
              isDense: true,
            ),
            items: [
              const DropdownMenuItem(
                value: TaskExecutorType.ai,
                child: Text('AI 助手'),
              ),
              DropdownMenuItem(
                value: TaskExecutorType.codex,
                child: Text(
                  widget.codexAvailable
                      ? 'Codex CLI'
                      : 'Codex CLI（未检测到）',
                ),
              ),
            ],
            onChanged: (value) {
              if (value != null) {
                setState(() => _executor = value);
              }
            },
          ),
          const SizedBox(height: 12),
          // 权限级别选择（始终显示）
          DropdownButtonFormField<String>(
            initialValue: _permission,
            decoration: InputDecoration(
              labelText: _executor == TaskExecutorType.codex
                  ? '权限级别（Codex）'
                  : '权限级别（元数据）',
              isDense: true,
            ),
            items: [
              DropdownMenuItem(
                value: TaskPermission.readOnly,
                child: Text(
                  TaskPermission.label(TaskPermission.readOnly),
                ),
              ),
              DropdownMenuItem(
                value: TaskPermission.readWrite,
                child: Text(
                  TaskPermission.label(TaskPermission.readWrite),
                ),
              ),
              DropdownMenuItem(
                value: TaskPermission.yolo,
                child: Text(
                  TaskPermission.label(TaskPermission.yolo),
                  style: const TextStyle(
                    color: Color(0xFFEF4444),
                  ),
                ),
              ),
            ],
            onChanged: (value) {
              if (value != null) {
                setState(() => _permission = value);
              }
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(
            context,
          ).pop(TaskConfig(executorType: _executor, permission: _permission)),
          child: const Text('确认'),
        ),
      ],
    );
  }
}

class _TaskQueuePanelState extends State<TaskQueuePanel> {
  String _filterStatus = 'all';
  String? _selectedTaskId;
  String _selectedLog = '';
  String _selectedResult = '';
  final Set<String> _pendingTaskIds = {};
  bool _queueActionPending = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final service = context.watch<CourierService>();
    final tasks = _filteredTasks(service.tasks);
    final displayedError = _error ?? service.taskQueue.lastError;

    return Column(
      children: [
        _buildHeader(service),
        _buildSummary(service.queueSummary),
        if (displayedError != null) _buildErrorBar(displayedError),
        Expanded(child: _buildTaskList(tasks)),
      ],
    );
  }

  Widget _buildHeader(CourierService service) {
    final settings = context.watch<SettingsState>();
    final running = service.taskQueue.queueRunning;
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: glassHeaderBgOf(context),
        border: Border(bottom: BorderSide(color: glassBorderOf(context))),
      ),
      child: Row(
        children: [
          Icon(Icons.queue_outlined, size: 15, color: accentColorOf(context)),
          const SizedBox(width: 6),
          Text(
            '并发 ${settings.maxConcurrent}',
            style: const TextStyle(fontSize: 12, color: Colors.white54),
          ),
          const Spacer(),
          IconButton(
            tooltip: '新建任务',
            onPressed: _showCreateDialog,
            icon: const Icon(Icons.add, size: 17),
          ),
          IconButton(
            tooltip: running ? '暂停队列' : '启动队列',
            onPressed: _queueActionPending ? null : _toggleQueue,
            icon: AnimatedSwitcher(
              duration: kAnimDurationFast,
              switchInCurve: kAnimCurveIn,
              switchOutCurve: kAnimCurveOut,
              transitionBuilder: kIconSwitchTransition,
              child: Icon(
                running ? Icons.pause : Icons.play_arrow,
                key: ValueKey(running),
                size: 17,
                color: running
                    ? const Color(0xFFF59E0B)
                    : const Color(0xFF10B981),
              ),
            ),
          ),
          IconButton(
            tooltip: '任务设置',
            onPressed: widget.onOpenSettings,
            icon: const Icon(Icons.settings_outlined, size: 16),
          ),
        ],
      ),
    );
  }

  Widget _buildSummary(QueueSummary summary) {
    final accent = accentColorOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: glassHeaderBgOf(context),
        border: Border(bottom: BorderSide(color: glassBorderOf(context))),
      ),
      child: Row(
        children: [
          _StatChip('总', summary.total, Colors.white54),
          const SizedBox(width: 3),
          _StatChip('排队', summary.queued, accent),
          const SizedBox(width: 3),
          _StatChip('运行', summary.running, const Color(0xFFF59E0B)),
          const SizedBox(width: 3),
          _StatChip('完成', summary.succeeded, const Color(0xFF10B981)),
          const Spacer(),
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _filterStatus,
              isDense: true,
              dropdownColor: glassFloatBgOf(context),
              style: const TextStyle(fontSize: 11, color: Colors.white70),
              items: const [
                DropdownMenuItem(value: 'all', child: Text('全部')),
                DropdownMenuItem(value: TaskStatus.queued, child: Text('排队')),
                DropdownMenuItem(value: TaskStatus.running, child: Text('运行')),
                DropdownMenuItem(
                  value: TaskStatus.succeeded,
                  child: Text('完成'),
                ),
                DropdownMenuItem(value: TaskStatus.failed, child: Text('失败')),
                DropdownMenuItem(
                  value: TaskStatus.cancelled,
                  child: Text('取消'),
                ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _filterStatus = value);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBar(String error) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      color: const Color(0x1AEF4444),
      child: Row(
        children: [
          Expanded(
            child: Text(
              error,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Color(0xFFFCA5A5)),
            ),
          ),
          IconButton(
            tooltip: '关闭错误提示',
            onPressed: () {
              context.read<CourierService>().taskQueue.clearLastError();
              setState(() => _error = null);
            },
            icon: const Icon(Icons.close, size: 14),
            constraints: const BoxConstraints.tightFor(width: 26, height: 24),
            padding: EdgeInsets.zero,
          ),
        ],
      ),
    );
  }

  Widget _buildTaskList(List<TaskItem> tasks) {
    if (tasks.isEmpty) {
      return Center(
        child: IconButton(
          tooltip: '新建任务',
          onPressed: _showCreateDialog,
          icon: const Icon(Icons.add_task, size: 30, color: Colors.white38),
        ),
      );
    }
    // 仅任务增删/筛选变化时整列表淡入；状态与进度更新走行内动画，不触发列表级动画。
    final signature = tasks.map((task) => task.id).join(',');
    return AnimatedSwitcher(
      duration: kAnimDurationMed,
      switchInCurve: kAnimCurveIn,
      switchOutCurve: kAnimCurveOut,
      transitionBuilder: kPanelSwitchTransition,
      layoutBuilder: (currentChild, previousChildren) {
        return Stack(
          fit: StackFit.expand,
          children: [
            for (final child in previousChildren) IgnorePointer(child: child),
            ?currentChild,
          ],
        );
      },
      child: KeyedSubtree(
        key: ValueKey(signature),
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: tasks.length,
          separatorBuilder: (_, _) => const SizedBox(height: 4),
          itemBuilder: (context, index) {
            final task = tasks[index];
            final expanded = task.id == _selectedTaskId;
            return _TaskCard(
              task: task,
              expanded: expanded,
              pending: _pendingTaskIds.contains(task.id),
              latestOutput: expanded ? _selectedLog : '',
              result: expanded ? _selectedResult : '',
              onTap: () => _toggleTaskDetail(task.id),
              onCancel: () => _cancelTask(task.id),
              onRetry: () => _retryTask(task.id),
              onDelete: () => _confirmDelete(task),
              onReview: () => _markReviewed(task.id),
            );
          },
        ),
      ),
    );
  }

  Future<void> _toggleTaskDetail(String taskId) async {
    // 如果点击已展开的任务 → 收起
    if (_selectedTaskId == taskId) {
      setState(() {
        _selectedTaskId = null;
        _selectedLog = '';
        _selectedResult = '';
      });
      return;
    }
    // 展开新任务 → 加载详情
    setState(() {
      _selectedTaskId = taskId;
      _selectedLog = '';
      _selectedResult = '';
    });
    final service = context.read<CourierService>();
    try {
      final values = await Future.wait([
        service.getTaskLogTail(taskId),
        service.getTaskResult(taskId),
      ]);
      if (!mounted || _selectedTaskId != taskId) return;
      setState(() {
        _selectedLog = values[0];
        _selectedResult = values[1];
      });
    } catch (error) {
      _showError(error);
    }
  }

  /// 刷新已展开任务的详情数据（操作后保持展开状态）。
  Future<void> _refreshTaskDetail(String taskId) async {
    if (_selectedTaskId != taskId) return;
    final service = context.read<CourierService>();
    try {
      final values = await Future.wait([
        service.getTaskLogTail(taskId),
        service.getTaskResult(taskId),
      ]);
      if (!mounted || _selectedTaskId != taskId) return;
      setState(() {
        _selectedLog = values[0];
        _selectedResult = values[1];
      });
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _markReviewed(String taskId) async {
    await _withPendingTask(taskId, () async {
      await context.read<CourierService>().markTaskReviewed(taskId);
    });
  }

  Future<void> _toggleQueue() async {
    final service = context.read<CourierService>();
    setState(() => _queueActionPending = true);
    try {
      if (service.taskQueue.queueRunning) {
        await service.pauseQueue();
      } else {
        await service.startQueue();
      }
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _queueActionPending = false);
    }
  }

  Future<void> _cancelTask(String taskId) async {
    await _withPendingTask(taskId, () {
      return context.read<CourierService>().cancelTask(taskId);
    });
  }

  Future<void> _retryTask(String taskId) async {
    await _withPendingTask(taskId, () {
      return context.read<CourierService>().retryTask(taskId);
    });
  }

  Future<void> _confirmDelete(TaskItem task) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => CourierDialog(
        title: const Text('删除任务'),
        content: Text(task.title, maxLines: 3, overflow: TextOverflow.ellipsis),
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
    if (confirmed != true) return;
    await _withPendingTask(task.id, () async {
      await context.read<CourierService>().deleteTask(task.id);
      if (_selectedTaskId == task.id && mounted) {
        setState(() => _selectedTaskId = null);
      }
    });
  }

  Future<void> _showCreateDialog() async {
    final titleController = TextEditingController();
    final contentController = TextEditingController();
    String selectedExecutor = TaskExecutorType.ai;
    String selectedPermission = TaskPermission.readOnly;
    try {
      final submitted = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => CourierDialog(
          title: const Text('新建任务'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleController,
                  maxLength: 160,
                  decoration: const InputDecoration(
                    labelText: '标题',
                    counterText: '',
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 140,
                  child: TextField(
                    controller: contentController,
                    maxLength: 262144,
                    maxLines: null,
                    expands: true,
                    decoration: const InputDecoration(
                      labelText: '任务内容',
                      counterText: '',
                      alignLabelWithHint: true,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                // 执行器类型 + 权限级别选择
                StatefulBuilder(
                  builder: (context, setLocalState) {
                    final codexAvailable = context
                        .read<CourierService>()
                        .config
                        .codexAvailable;
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        DropdownButtonFormField<String>(
                          initialValue: selectedExecutor,
                          decoration: const InputDecoration(
                            labelText: '执行方式',
                            isDense: true,
                          ),
                          items: [
                            const DropdownMenuItem(
                              value: TaskExecutorType.ai,
                              child: Text('AI 助手'),
                            ),
                            DropdownMenuItem(
                              value: TaskExecutorType.codex,
                              child: Text(
                                codexAvailable
                                    ? 'Codex CLI'
                                    : 'Codex CLI（未检测到）',
                              ),
                            ),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              setLocalState(() => selectedExecutor = value);
                            }
                          },
                        ),
                        const SizedBox(height: 8),
                        // 权限级别选择（始终显示）
                        DropdownButtonFormField<String>(
                          initialValue: selectedPermission,
                          decoration: InputDecoration(
                            labelText:
                                selectedExecutor == TaskExecutorType.codex
                                    ? '权限级别（Codex）'
                                    : '权限级别（元数据）',
                            isDense: true,
                          ),
                          items: [
                            DropdownMenuItem(
                              value: TaskPermission.readOnly,
                              child: Text(
                                TaskPermission.label(
                                  TaskPermission.readOnly,
                                ),
                              ),
                            ),
                            DropdownMenuItem(
                              value: TaskPermission.readWrite,
                              child: Text(
                                TaskPermission.label(
                                  TaskPermission.readWrite,
                                ),
                              ),
                            ),
                            DropdownMenuItem(
                              value: TaskPermission.yolo,
                              child: Text(
                                TaskPermission.label(TaskPermission.yolo),
                                style: const TextStyle(
                                  color: Color(0xFFEF4444),
                                ),
                              ),
                            ),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              setLocalState(
                                () => selectedPermission = value,
                              );
                            }
                          },
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('创建'),
            ),
          ],
        ),
      );
      if (submitted != true || !mounted) return;

      // YOLO 模式需要二次确认
      if (selectedExecutor == TaskExecutorType.codex &&
          selectedPermission == TaskPermission.yolo) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => CourierDialog(
            title: const Text('⚠️ 危险操作确认'),
            content: const Text(TaskPermission.yoloWarning),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFEF4444),
                ),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('确认执行'),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) return;
      }

      await context.read<CourierService>().createTask(
        title: titleController.text,
        sourceType: 'manual',
        markdownContent: contentController.text,
        executorType: selectedExecutor,
        permission: selectedPermission,
      );
      widget.onTotalChange?.call();
    } catch (error) {
      _showError(error);
    } finally {
      titleController.dispose();
      contentController.dispose();
    }
  }

  Future<void> _withPendingTask(
    String taskId,
    Future<void> Function() action,
  ) async {
    setState(() => _pendingTaskIds.add(taskId));
    try {
      await action();
      if (_selectedTaskId == taskId) unawaited(_refreshTaskDetail(taskId));
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _pendingTaskIds.remove(taskId));
    }
  }

  void _showError(Object error) {
    if (mounted) setState(() => _error = '$error');
  }

  List<TaskItem> _filteredTasks(List<TaskItem> tasks) {
    final filtered = _filterStatus == 'all'
        ? [...tasks]
        : tasks.where((task) {
            if (_filterStatus == TaskStatus.running) {
              return task.status == TaskStatus.running ||
                  task.status == TaskStatus.cancelling;
            }
            return task.status == _filterStatus;
          }).toList();
    filtered.sort((left, right) => right.createdAt.compareTo(left.createdAt));
    return filtered;
  }

}

/// 格式化 ISO 时间为本地简短格式。
String _formatTaskDateTime(String iso) {
  final parsed = DateTime.tryParse(iso)?.toLocal();
  if (parsed == null) return iso;
  return '${parsed.month.toString().padLeft(2, '0')}/'
      '${parsed.day.toString().padLeft(2, '0')} '
      '${parsed.hour.toString().padLeft(2, '0')}:'
      '${parsed.minute.toString().padLeft(2, '0')}';
}

/// 计算任务运行时长（用于 UI 显示）。
String _formatTaskElapsed(TaskItem task) {
  final start = task.startedAt;
  if (start == null) return '—';
  final startTime = DateTime.tryParse(start);
  if (startTime == null) return '—';
  final end = task.finishedAt != null
      ? DateTime.tryParse(task.finishedAt!)
      : DateTime.now();
  if (end == null) return '—';
  final duration = end.difference(startTime);
  if (duration.inSeconds < 60) return '${duration.inSeconds}s';
  if (duration.inMinutes < 60) {
    return '${duration.inMinutes}m ${duration.inSeconds % 60}s';
  }
  return '${duration.inHours}h ${duration.inMinutes % 60}m';
}

class _StatChip extends StatelessWidget {
  final String label;
  final int count;
  final Color color;

  const _StatChip(this.label, this.count, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(kRadiusSm),
      ),
      child: Text(
        '$label $count',
        style: TextStyle(fontSize: 10, color: color),
      ),
    );
  }
}

/// 任务卡片 — 紧凑行 + 展开详情。
class _TaskCard extends StatelessWidget {
  final TaskItem task;
  final bool expanded;
  final bool pending;
  final String latestOutput;
  final String result;
  final VoidCallback onTap;
  final VoidCallback onCancel;
  final VoidCallback onRetry;
  final VoidCallback onDelete;
  final VoidCallback onReview;

  const _TaskCard({
    required this.task,
    required this.expanded,
    required this.pending,
    required this.latestOutput,
    required this.result,
    required this.onTap,
    required this.onCancel,
    required this.onRetry,
    required this.onDelete,
    required this.onReview,
  });

  @override
  Widget build(BuildContext context) {
    final accent = accentColorOf(context);
    final status = _taskStatus(task, accent);
    final (color, icon, label) = status;

    return AnimatedContainer(
      duration: kAnimDurationFast,
      curve: kAnimCurveIn,
      decoration: BoxDecoration(
        color: expanded
            ? glassSelectedBgOf(context)
            : glassSurfaceSolidColor(context),
        borderRadius: BorderRadius.circular(kRadiusMd),
        border: Border.all(
          color: expanded ? accent.withValues(alpha: 0.3) : glassBorderOf(context),
        ),
      ),
      margin: const EdgeInsets.symmetric(horizontal: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(kRadiusMd),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 第一行：图标 + 标题 + 复制 + 状态 + 操作
                _buildHeader(context, color, icon, label, accent),
                const SizedBox(height: 6),
                // 第二行：元数据（执行器 · 权限 · 时长）
                _buildMetaLine(context, accent),
                const SizedBox(height: 4),
                // 第三行：最新输出预览
                if (latestOutput.isNotEmpty) ...[
                  _buildOutputPreview(context),
                  const SizedBox(height: 4),
                ],
                // 第四行：进度条
                _buildProgressBar(context, color),
                const SizedBox(height: 6),
                // 第五行：操作按钮（右下角）
                _buildActionBar(context, accent),
                // 展开详情
                if (expanded) ...[
                  const SizedBox(height: 10),
                  Divider(height: 1, color: glassBorderOf(context)),
                  const SizedBox(height: 10),
                  _buildExpandedDetail(context, accent),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 标题行：图标 + 标题 + 复制按钮 + 状态标签 + 操作按钮
  Widget _buildHeader(
    BuildContext context,
    Color color,
    IconData icon,
    String label,
    Color accent,
  ) {
    return Row(
      children: [
        AnimatedSwitcher(
          duration: kAnimDurationFast,
          transitionBuilder: kIconSwitchTransition,
          child: Icon(
            icon,
            key: ValueKey('${task.id}-${task.status}'),
            size: 16,
            color: color,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            task.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Colors.white70,
            ),
          ),
        ),
        // 复制标题按钮
        Tooltip(
          message: '复制标题',
          child: InkWell(
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('标题已复制'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.copy, size: 13, color: Colors.white38),
            ),
          ),
        ),
        const SizedBox(width: 4),
        // 状态标签
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(kRadiusSm),
          ),
          child: Text(
            label,
            style: TextStyle(fontSize: 10, color: color),
          ),
        ),
      ],
    );
  }

  /// 操作栏：右下角对齐的操作按钮
  Widget _buildActionBar(BuildContext context, Color accent) {
    final buttons = <Widget>[];

    // 重新执行按钮（始终可用，除了运行中）
    if (task.status != TaskStatus.running &&
        task.status != TaskStatus.cancelling) {
      buttons.add(
        IconButton(
          tooltip: '重新执行',
          onPressed: onRetry,
          icon: const Icon(Icons.replay, size: 16),
          constraints: const BoxConstraints.tightFor(width: 30, height: 30),
          padding: EdgeInsets.zero,
          color: Colors.white54,
        ),
      );
    }

    // 暂停/取消按钮（排队/运行中）
    if (task.status == TaskStatus.queued ||
        task.status == TaskStatus.running ||
        task.status == TaskStatus.cancelling) {
      buttons.add(
        IconButton(
          tooltip: '暂停任务',
          onPressed: task.status == TaskStatus.cancelling ? null : onCancel,
          icon: const Icon(Icons.pause_circle_outline, size: 16),
          constraints: const BoxConstraints.tightFor(width: 30, height: 30),
          padding: EdgeInsets.zero,
          color: const Color(0xFFF59E0B),
        ),
      );
    }

    // 标记审查按钮（已完成未审查）
    if (task.status == TaskStatus.succeeded && !task.reviewed) {
      buttons.add(
        IconButton(
          tooltip: '标记已审查',
          onPressed: onReview,
          icon: const Icon(Icons.fact_check, size: 16),
          constraints: const BoxConstraints.tightFor(width: 30, height: 30),
          padding: EdgeInsets.zero,
          color: const Color(0xFF10B981),
        ),
      );
    }

    // 删除按钮（终态）
    if (TaskStatus.isTerminal(task.status)) {
      buttons.add(
        IconButton(
          tooltip: '删除任务',
          onPressed: onDelete,
          icon: const Icon(Icons.delete_outline, size: 16),
          constraints: const BoxConstraints.tightFor(width: 30, height: 30),
          padding: EdgeInsets.zero,
          color: const Color(0xFFEF4444),
        ),
      );
    }

    if (buttons.isEmpty) return const SizedBox.shrink();

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: buttons,
    );
  }

  /// 元数据行：执行器 · 权限 · 运行时长
  Widget _buildMetaLine(BuildContext context, Color accent) {
    final parts = <String>[
      TaskExecutorType.label(task.executorType),
      if (task.executorType == TaskExecutorType.codex)
        TaskPermission.label(task.permission),
      _formatTaskElapsed(task),
    ];

    return Row(
      children: [
        Icon(Icons.label_outline, size: 11, color: Colors.white24),
        const SizedBox(width: 4),
        Text(
          parts.join(' · '),
          style: const TextStyle(fontSize: 10, color: Colors.white38),
        ),
      ],
    );
  }

  /// 最新输出预览
  Widget _buildOutputPreview(BuildContext context) {
    final lastLine = latestOutput
        .trim()
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .lastOrNull;
    if (lastLine == null) return const SizedBox.shrink();

    final display = lastLine.length > 120
        ? '${lastLine.substring(0, 120)}...'
        : lastLine;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(kRadiusSm),
      ),
      child: Text(
        display,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 10,
          fontFamily: 'Consolas',
          color: Colors.white54,
        ),
      ),
    );
  }

  /// 进度条：按状态显示固定值或跑马灯
  /// 排队中 20% | 执行中 跑马灯 | 待审查 80% | 已完成 100% | 失败 0%
  Widget _buildProgressBar(BuildContext context, Color color) {
    final double? progressValue = switch (task.status) {
      TaskStatus.queued => 0.2,
      TaskStatus.running || TaskStatus.cancelling => null, // 跑马灯
      TaskStatus.succeeded => task.reviewed ? 1.0 : 0.8,
      TaskStatus.failed => 0.0,
      TaskStatus.cancelled => 0.0,
      _ => null,
    };
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: LinearProgressIndicator(
        value: progressValue,
        minHeight: 3,
        backgroundColor: kGlassChipBg,
        color: color,
      ),
    );
  }

  /// 展开详情面板
  Widget _buildExpandedDetail(BuildContext context, Color accent) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 元数据网格
        _detailGrid(context, accent),
        const SizedBox(height: 8),
        // 任务内容
        if (task.markdownContent.isNotEmpty) ...[
          _detailSection('任务内容', task.markdownContent),
          const SizedBox(height: 6),
        ],
        // 错误信息
        if (task.errorMessage != null) ...[
          _detailSection('错误', task.errorMessage!),
          const SizedBox(height: 6),
        ],
        // 日志
        if (latestOutput.isNotEmpty) ...[
          _detailSection('日志', latestOutput),
          const SizedBox(height: 6),
        ],
        // 结果
        if (result.isNotEmpty) ...[
          _detailSection('结果', result),
          const SizedBox(height: 6),
        ],
        // 操作按钮
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (task.status == TaskStatus.succeeded && !task.reviewed)
              TextButton.icon(
                onPressed: onReview,
                icon: const Icon(Icons.fact_check, size: 14),
                label: const Text('标记审查'),
              ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline, size: 14),
              label: const Text('删除任务'),
              style: TextButton.styleFrom(foregroundColor: const Color(0xFFEF4444)),
            ),
          ],
        ),
      ],
    );
  }

  /// 元数据网格
  Widget _detailGrid(BuildContext context, Color accent) {
    final rows = <List<String>>[
      ['状态', _statusLabel(task.status)],
      ['执行器', TaskExecutorType.label(task.executorType)],
      ['进度', '${(task.progress * 100).round()}%'],
      ['尝试', '${task.attempt}/${task.maxAttempts}'],
      ['创建', _formatTaskDateTime(task.createdAt)],
    ];
    if (task.startedAt != null) {
      rows.add(['开始', _formatTaskDateTime(task.startedAt!)]);
    }
    if (task.finishedAt != null) {
      rows.add(['结束', _formatTaskDateTime(task.finishedAt!)]);
    }
    if (task.executorType == TaskExecutorType.codex) {
      rows.add(['权限', TaskPermission.label(task.permission)]);
    }

    return Column(
      children: rows.map((row) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 1.5),
          child: Row(
            children: [
              SizedBox(
                width: 48,
                child: Text(
                  row[0],
                  style: const TextStyle(fontSize: 10, color: Colors.white30),
                ),
              ),
              Expanded(
                child: Text(
                  row[1],
                  style: const TextStyle(fontSize: 10, color: Colors.white60),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  /// 详情区块（可折叠文本）
  Widget _detailSection(String label, String value) {
    final display = value.length > 8000
        ? '${value.substring(0, 8000)}...'
        : value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 10, color: Colors.white30),
        ),
        const SizedBox(height: 3),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.black26,
            borderRadius: BorderRadius.circular(kRadiusSm),
          ),
          child: SelectableText(
            display,
            style: const TextStyle(
              fontSize: 10,
              height: 1.5,
              fontFamily: 'Consolas',
              color: Colors.white54,
            ),
          ),
        ),
      ],
    );
  }

  /// 状态标签（中文 + 颜色 + 图标）
  (Color, IconData, String) _taskStatus(TaskItem task, Color accent) {
    return switch (task.status) {
      TaskStatus.succeeded when !task.reviewed => (
        const Color(0xFFF59E0B),
        Icons.pending_outlined,
        '待审查',
      ),
      TaskStatus.succeeded => (
        const Color(0xFF10B981),
        Icons.check_circle_outline,
        '已完成',
      ),
      TaskStatus.running => (
        const Color(0xFF3B82F6),
        Icons.play_circle_outline,
        '待完成',
      ),
      TaskStatus.queued => (accent, Icons.schedule, '排队中'),
      TaskStatus.failed => (
        const Color(0xFFEF4444),
        Icons.error_outline,
        '未完成',
      ),
      TaskStatus.cancelling => (
        const Color(0xFFF59E0B),
        Icons.pending_outlined,
        '取消中',
      ),
      TaskStatus.cancelled => (Colors.white38, Icons.cancel_outlined, '已取消'),
      _ => (Colors.white38, Icons.circle_outlined, task.status),
    };
  }

  String _statusLabel(String status) => switch (status) {
    TaskStatus.queued => '排队中',
    TaskStatus.running => '执行中',
    TaskStatus.succeeded => '已完成',
    TaskStatus.failed => '失败',
    TaskStatus.cancelling => '正在取消',
    TaskStatus.cancelled => '已取消',
    _ => status,
  };
}
