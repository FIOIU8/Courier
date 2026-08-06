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
    final selected = _selectedTaskId == null
        ? null
        : service.tasks.where((task) => task.id == _selectedTaskId).firstOrNull;
    final displayedError = _error ?? service.taskQueue.lastError;

    return Column(
      children: [
        _buildHeader(service),
        _buildSummary(service.queueSummary),
        if (displayedError != null) _buildErrorBar(displayedError),
        Expanded(child: _buildTaskList(tasks)),
        // 详情区展开/收起：AnimatedSize 平滑高度过渡（0↔内容高），
        // 宽度固定为面板宽，仅高度变化；收起时高度即时开始收缩，
        // 不会出现"先淡出再收缩"的串行空白。
        AnimatedSize(
          duration: kAnimDurationMed,
          curve: kAnimCurveIn,
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: double.infinity,
            child: selected != null ? _buildTaskDetail(selected) : null,
          ),
        ),
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
            // 旧列表淡出期间不可交互，避免误触
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
          separatorBuilder: (_, _) =>
              const Divider(height: 1),
          itemBuilder: (context, index) {
            final task = tasks[index];
            return _TaskRow(
              task: task,
              selected: task.id == _selectedTaskId,
              pending: _pendingTaskIds.contains(task.id),
              onSelect: () => _selectTask(task.id),
              onCancel: () => _cancelTask(task.id),
              onRetry: () => _retryTask(task.id),
              onDelete: () => _confirmDelete(task),
            );
          },
        ),
      ),
    );
  }

  Widget _buildTaskDetail(TaskItem task) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 310),
      decoration: BoxDecoration(
        color: glassHeaderBgOf(context),
        border: Border(top: BorderSide(color: glassBorderOf(context))),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 36,
            child: Row(
              children: [
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    task.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '关闭详情',
                  onPressed: () => setState(() => _selectedTaskId = null),
                  icon: const Icon(Icons.close, size: 14),
                ),
              ],
            ),
          ),
          LinearProgressIndicator(
            value:
                task.status == TaskStatus.running ||
                    task.status == TaskStatus.cancelling
                ? task.progress
                : null,
            minHeight: 2,
            backgroundColor: kGlassChipBg,
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _detailRow('状态', _statusLabel(task.status)),
                  _detailRow('进度', '${(task.progress * 100).round()}%'),
                  _detailRow('尝试', '${task.attempt}/${task.maxAttempts}'),
                  _detailRow('创建', _formatDateTime(task.createdAt)),
                  if (task.startedAt != null)
                    _detailRow('开始', _formatDateTime(task.startedAt!)),
                  if (task.finishedAt != null)
                    _detailRow('结束', _formatDateTime(task.finishedAt!)),
                  if (task.errorMessage != null)
                    _detailSection('错误', task.errorMessage!),
                  _detailSection('任务内容', task.markdownContent),
                  if (_selectedLog.isNotEmpty)
                    _detailSection('日志', _selectedLog),
                  if (_selectedResult.isNotEmpty)
                    _detailSection('结果', _selectedResult),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _selectTask(String taskId) async {
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

  Future<void> _toggleQueue() async {
    final service = context.read<CourierService>();
    final settings = context.read<SettingsState>();
    if (!service.taskQueue.queueRunning && !settings.aiConfigurationReady) {
      widget.onOpenSettings?.call();
      _showError('启动队列前需要配置供应商模型与 API Key');
      return;
    }
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
      builder: (dialogContext) => AlertDialog(
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
    try {
      final submitted = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
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
                  height: 220,
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
      await context.read<CourierService>().createTask(
        title: titleController.text,
        sourceType: 'manual',
        markdownContent: contentController.text,
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
      if (_selectedTaskId == taskId) unawaited(_selectTask(taskId));
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

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 52,
            child: Text(
              label,
              style: const TextStyle(fontSize: 11, color: Colors.white38),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 11, color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailSection(String label, String value) {
    final display = value.length > 12000
        ? value.substring(value.length - 12000)
        : value;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Colors.white38),
          ),
          const SizedBox(height: 4),
          SelectableText(
            display,
            style: const TextStyle(
              fontSize: 11,
              height: 1.4,
              fontFamily: 'Consolas',
              color: Colors.white60,
            ),
          ),
        ],
      ),
    );
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

  String _formatDateTime(String iso) {
    final parsed = DateTime.tryParse(iso)?.toLocal();
    if (parsed == null) return iso;
    return '${parsed.month.toString().padLeft(2, '0')}/'
        '${parsed.day.toString().padLeft(2, '0')} '
        '${parsed.hour.toString().padLeft(2, '0')}:'
        '${parsed.minute.toString().padLeft(2, '0')}';
  }
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

class _TaskRow extends StatelessWidget {
  final TaskItem task;
  final bool selected;
  final bool pending;
  final VoidCallback onSelect;
  final VoidCallback onCancel;
  final VoidCallback onRetry;
  final VoidCallback onDelete;

  const _TaskRow({
    required this.task,
    required this.selected,
    required this.pending,
    required this.onSelect,
    required this.onCancel,
    required this.onRetry,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final accent = accentColorOf(context);
    final (color, icon, label) = _statusInfo(task.status, accent);
    final cancellable =
        task.status == TaskStatus.queued ||
        task.status == TaskStatus.running ||
        task.status == TaskStatus.cancelling;
    final retryable =
        task.status == TaskStatus.failed && task.attempt < task.maxAttempts;
    final deletable = TaskStatus.isTerminal(task.status);

    return AnimatedContainer(
      duration: kAnimDurationFast,
      curve: kAnimCurveIn,
      color: selected ? glassSelectedBgOf(context) : Colors.transparent,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onSelect,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
            child: Row(
              children: [
                AnimatedSwitcher(
                  duration: kAnimDurationFast,
                  switchInCurve: kAnimCurveIn,
                  switchOutCurve: kAnimCurveOut,
                  transitionBuilder: kIconSwitchTransition,
                  child: Icon(
                    icon,
                    key: ValueKey('${task.id}-${task.status}'),
                    size: 15,
                    color: color,
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white70,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          AnimatedDefaultTextStyle(
                            duration: kAnimDurationFast,
                            curve: kAnimCurveIn,
                            style: TextStyle(fontSize: 10, color: color),
                            child: Text(label),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: LinearProgressIndicator(
                              value: task.progress,
                              minHeight: 2,
                              backgroundColor: kGlassChipBg,
                              color: color,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (pending)
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(strokeWidth: 1.4),
                    ),
                  )
                else if (cancellable)
                  IconButton(
                    tooltip: '取消任务',
                    onPressed: task.status == TaskStatus.cancelling
                        ? null
                        : onCancel,
                    icon: const Icon(Icons.stop_circle_outlined, size: 15),
                  )
                else if (retryable)
                  IconButton(
                    tooltip: '重试任务',
                    onPressed: onRetry,
                    icon: const Icon(Icons.replay, size: 15),
                  )
                else if (deletable)
                  IconButton(
                    tooltip: '删除任务',
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete_outline, size: 15),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  (Color, IconData, String) _statusInfo(String status, Color accent) =>
      switch (status) {
        TaskStatus.succeeded => (
          const Color(0xFF10B981),
          Icons.check_circle_outline,
          '完成',
        ),
        TaskStatus.running => (
          const Color(0xFFF59E0B),
          Icons.play_circle_outline,
          '运行',
        ),
        TaskStatus.queued => (accent, Icons.schedule, '排队'),
        TaskStatus.failed => (
          const Color(0xFFEF4444),
          Icons.error_outline,
          '失败',
        ),
        TaskStatus.cancelling => (
          const Color(0xFFF59E0B),
          Icons.pending_outlined,
          '取消中',
        ),
        TaskStatus.cancelled => (Colors.white38, Icons.cancel_outlined, '已取消'),
        _ => (Colors.white38, Icons.circle_outlined, status),
      };
}
