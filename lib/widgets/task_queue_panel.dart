// task_queue_panel.dart — 任务队列面板（真实）
//
// 连接 CourierCoreService 的任务模块：
// listTasks / getQueueSummary / createTask / deleteTask / startQueue / pauseQueue / getTaskDetail

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/courier_core_service.dart';
import '../services/models.dart';

class TaskQueuePanel extends StatefulWidget {
  final VoidCallback? onTotalChange;
  final VoidCallback? onOpenSettings;

  const TaskQueuePanel({
    super.key,
    this.onTotalChange,
    this.onOpenSettings,
  });

  @override
  State<TaskQueuePanel> createState() => _TaskQueuePanelState();
}

class _TaskQueuePanelState extends State<TaskQueuePanel> {
  String _filterStatus = 'all';
  final String _sortBy = 'createdAt';
  final String _sortDirection = 'desc';
  String? _selectedTaskId;
  TaskItem? _selectedTask;
  bool _actionPending = false;
  bool _manualOpen = false;
  String _manualTitle = '';
  String _manualContent = '';

  @override
  void initState() {
    super.initState();
    // 延迟加载，确保 Service 已注入
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadSnapshot());
  }

  Future<void> _loadSnapshot() async {
    final service = context.read<CourierCoreService?>();
    if (service == null) return;
    try {
      service.listTasks(status: _filterStatus == 'all' ? '' : _filterStatus);
      service.getQueueSummary();
      if (_selectedTaskId != null) {
        try {
          _selectedTask = service.getTaskDetail(_selectedTaskId!);
        } catch (_) {
          _selectedTaskId = null;
          _selectedTask = null;
        }
      }
    } catch (e) {
      debugPrint('[TaskQueuePanel] 加载失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<CourierCoreService?>();
    if (service == null) {
      return _buildNoService(context);
    }

    final tasks = _applySort(service.tasks);
    final summary = service.queueSummary;

    return Container(
      color: const Color(0xFF0C1220),
      child: Column(
        children: [
          _buildHeader(context, summary),
          _buildFilterBar(context),
          Expanded(child: _buildTaskList(context, tasks)),
          if (_selectedTask != null) _buildTaskDetail(context, _selectedTask!),
          if (_manualOpen) _buildManualDialog(context),
        ],
      ),
    );
  }

  Widget _buildNoService(BuildContext context) {
    return Container(
      color: const Color(0xFF0C1220),
      child: const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.warning, size: 32, color: Colors.amber),
              SizedBox(height: 8),
              Text('核心服务未加载', style: TextStyle(fontSize: 12, color: Colors.white38)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, QueueSummary? summary) {
    final s = summary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0xFF111827),
        border: Border(bottom: BorderSide(color: Color(0xFF1E2438))),
      ),
      child: Row(
        children: [
          const Icon(Icons.queue, size: 14, color: Colors.white54),
          const SizedBox(width: 6),
          const Text('任务队列', style: TextStyle(fontSize: 11, color: Colors.white54, fontWeight: FontWeight.w500)),
          const Spacer(),
          if (s != null)
            Text(
              '${s.total}',
              style: const TextStyle(fontSize: 10, color: Color(0xFF818CF8)),
            ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.refresh, size: 14),
            color: Colors.white54,
            tooltip: '刷新',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: _actionPending ? null : () => _loadSnapshot(),
          ),
          IconButton(
            icon: const Icon(Icons.play_arrow, size: 14),
            color: const Color(0xFF10B981),
            tooltip: '启动队列',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: _actionPending ? null : () => _runAction('startQueue'),
          ),
          IconButton(
            icon: const Icon(Icons.pause, size: 14),
            color: const Color(0xFFF59E0B),
            tooltip: '暂停队列',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: _actionPending ? null : () => _runAction('pauseQueue'),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: const BoxDecoration(
        color: Color(0xFF0D1424),
        border: Border(bottom: BorderSide(color: Color(0xFF1E2438))),
      ),
      child: Row(
        children: [
          // 统计
          Expanded(
            child: Consumer<CourierCoreService?>(
              builder: (context, service, _) {
                final s = service?.queueSummary;
                return Row(
                  children: [
                    _StatChip('总', s?.total ?? 0, Colors.white54),
                    const SizedBox(width: 4),
                    _StatChip('排队', s?.queued ?? 0, const Color(0xFF6366F1)),
                    const SizedBox(width: 4),
                    _StatChip('完成', s?.done ?? 0, const Color(0xFF10B981)),
                    const SizedBox(width: 4),
                    _StatChip('失败', s?.failed ?? 0, const Color(0xFFEF4444)),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskList(BuildContext context, List<TaskItem> tasks) {
    if (tasks.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.inbox, size: 32, color: Colors.white24),
            const SizedBox(height: 8),
            const Text('任务队列为空', style: TextStyle(fontSize: 12, color: Colors.white38)),
            const SizedBox(height: 4),
            const Text(
              '从左侧拖入文件或手动创建',
              style: TextStyle(fontSize: 10, color: Colors.white24),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => setState(() => _manualOpen = true),
              icon: const Icon(Icons.add, size: 14),
              label: const Text('手动创建', style: TextStyle(fontSize: 12)),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF6366F1),
                minimumSize: const Size(100, 32),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              FilledButton.icon(
                onPressed: () => setState(() => _manualOpen = true),
                icon: const Icon(Icons.add, size: 12),
                label: const Text('手动创建', style: TextStyle(fontSize: 10)),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF6366F1),
                  minimumSize: const Size(80, 28),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
              const Spacer(),
              _buildFilterDropdown(),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            itemCount: tasks.length,
            separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFF1E2438)),
            itemBuilder: (context, index) => _TaskTile(
              task: tasks[index],
              selected: _selectedTaskId == tasks[index].id,
              actionPending: _actionPending,
              onSelect: () => _selectTask(tasks[index].id),
              onDelete: () => _deleteTask(tasks[index]),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFilterDropdown() {
    return DropdownButton<String>(
      value: _filterStatus,
      underline: const SizedBox(),
      isDense: true,
      style: const TextStyle(fontSize: 10, color: Colors.white54),
      dropdownColor: const Color(0xFF111827),
      items: const [
        DropdownMenuItem(value: 'all', child: Text('全部', style: TextStyle(fontSize: 10))),
        DropdownMenuItem(value: 'queued', child: Text('排队中', style: TextStyle(fontSize: 10))),
        DropdownMenuItem(value: 'running', child: Text('执行中', style: TextStyle(fontSize: 10))),
        DropdownMenuItem(value: 'done', child: Text('已完成', style: TextStyle(fontSize: 10))),
        DropdownMenuItem(value: 'failed', child: Text('失败', style: TextStyle(fontSize: 10))),
      ],
      onChanged: (value) {
        if (value != null) {
          setState(() => _filterStatus = value);
          _loadSnapshot();
        }
      },
    );
  }

  Widget _buildTaskDetail(BuildContext context, TaskItem task) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 300),
      decoration: const BoxDecoration(
        color: Color(0xFF0D1424),
        border: Border(top: BorderSide(color: Color(0xFF6366F1), width: 1)),
      ),
      child: Column(
        children: [
          // 详情头部
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: const BoxDecoration(
              color: Color(0xFF111827),
              border: Border(bottom: BorderSide(color: Color(0xFF1E2438))),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline, size: 12, color: Color(0xFF6366F1)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(task.title,
                      style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w500),
                      overflow: TextOverflow.ellipsis),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 12),
                  color: Colors.white38,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                  onPressed: () => setState(() {
                    _selectedTaskId = null;
                    _selectedTask = null;
                  }),
                ),
              ],
            ),
          ),
          // 详情内容
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _detailRow('任务 ID', task.id),
                  _detailRow('状态', _statusLabel(task.status)),
                  _detailRow('创建时间', _formatDateTime(task.createdAt)),
                  _detailRow('更新时间', _formatDateTime(task.updatedAt)),
                  const SizedBox(height: 8),
                  const Text('Markdown 摘要', style: TextStyle(fontSize: 10, color: Colors.white38)),
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 120),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0A0E1A),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: SingleChildScrollView(
                      child: Text(
                        task.markdownContent.length > 500
                            ? '${task.markdownContent.substring(0, 500)}...'
                            : task.markdownContent,
                        style: const TextStyle(
                          fontFamily: 'Consolas',
                          fontSize: 10,
                          color: Colors.white54,
                          height: 1.4,
                        ),
                      ),
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

  Widget _buildManualDialog(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF111827),
      title: const Text('手动创建任务', style: TextStyle(fontSize: 14, color: Colors.white)),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('任务标题', style: TextStyle(fontSize: 11, color: Colors.white38)),
            const SizedBox(height: 4),
            TextField(
              style: const TextStyle(fontSize: 12, color: Colors.white),
              decoration: const InputDecoration(
                isDense: true,
                enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1E2438))),
                focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF6366F1))),
              ),
              onChanged: (value) => _manualTitle = value,
            ),
            const SizedBox(height: 12),
            const Text('Markdown 内容', style: TextStyle(fontSize: 11, color: Colors.white38)),
            const SizedBox(height: 4),
            SizedBox(
              height: 200,
              child: TextField(
                maxLines: null,
                expands: true,
                style: const TextStyle(fontFamily: 'Consolas', fontSize: 11, color: Colors.white, height: 1.4),
                decoration: const InputDecoration(
                  isDense: true,
                  enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1E2438))),
                  focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF6366F1))),
                ),
                onChanged: (value) => _manualContent = value,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => setState(() => _manualOpen = false),
          child: const Text('取消', style: TextStyle(color: Colors.white54)),
        ),
        FilledButton(
          onPressed: _actionPending || _manualContent.trim().isEmpty
              ? null
              : () => _createManualTask(),
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF6366F1)),
          child: const Text('创建', style: TextStyle(fontSize: 12)),
        ),
      ],
    );
  }

  // ---- 操作 ----

  void _selectTask(String taskId) {
    final service = context.read<CourierCoreService?>();
    if (service == null) return;
    setState(() => _selectedTaskId = taskId);
    try {
      _selectedTask = service.getTaskDetail(taskId);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('加载任务详情失败: $e')),
      );
    }
  }

  void _deleteTask(TaskItem task) {
    final service = context.read<CourierCoreService?>();
    if (service == null) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF111827),
        title: const Text('确认删除', style: TextStyle(fontSize: 14, color: Colors.white)),
        content: Text('确认删除任务「${task.title}」？', style: const TextStyle(fontSize: 12, color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(color: Colors.white54)),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _performDelete(task.id);
            },
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
            child: const Text('删除', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  void _performDelete(String taskId) {
    final service = context.read<CourierCoreService?>();
    if (service == null) return;
    setState(() => _actionPending = true);
    try {
      service.deleteTask(taskId);
      if (_selectedTaskId == taskId) {
        _selectedTaskId = null;
        _selectedTask = null;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('任务已删除'), duration: Duration(seconds: 1)),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除失败: $e')),
      );
    } finally {
      setState(() => _actionPending = false);
    }
  }

  void _createManualTask() {
    final service = context.read<CourierCoreService?>();
    if (service == null) return;
    setState(() => _actionPending = true);
    try {
      service.createTask(
        title: _manualTitle.trim().isEmpty ? '未命名任务' : _manualTitle.trim(),
        sourceType: 'manual',
        markdownContent: _manualContent,
      );
      setState(() {
        _manualOpen = false;
        _manualTitle = '';
        _manualContent = '';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('任务已创建')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('创建失败: $e')),
      );
    } finally {
      setState(() => _actionPending = false);
    }
  }

  void _runAction(String action) {
    final service = context.read<CourierCoreService?>();
    if (service == null) return;
    setState(() => _actionPending = true);
    try {
      switch (action) {
        case 'startQueue':
          service.startQueue();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('队列已启动'), duration: Duration(seconds: 1)),
          );
          break;
        case 'pauseQueue':
          service.pauseQueue();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('队列已暂停'), duration: Duration(seconds: 1)),
          );
          break;
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('操作失败: $e')),
      );
    } finally {
      setState(() => _actionPending = false);
    }
  }

  // ---- 辅助 ----

  List<TaskItem> _applySort(List<TaskItem> tasks) {
    final sorted = [...tasks];
    if (_filterStatus != 'all') {
      sorted.removeWhere((t) => t.status != _filterStatus);
    }
    sorted.sort((a, b) {
      int cmp;
      switch (_sortBy) {
        case 'status':
          const rank = {'running': 0, 'queued': 1, 'failed': 2, 'done': 3};
          cmp = (rank[a.status] ?? 4).compareTo(rank[b.status] ?? 4);
          break;
        case 'updatedAt':
          cmp = a.updatedAt.compareTo(b.updatedAt);
          break;
        default:
          cmp = a.createdAt.compareTo(b.createdAt);
      }
      return _sortDirection == 'desc' ? -cmp : cmp;
    });
    return sorted;
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 60,
            child: Text(label, style: const TextStyle(fontSize: 10, color: Colors.white38)),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 10, color: Colors.white70))),
        ],
      ),
    );
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'queued':
        return '排队中';
      case 'running':
        return '执行中';
      case 'done':
        return '已完成';
      case 'failed':
        return '失败';
      default:
        return '未知';
    }
  }

  String _formatDateTime(String iso) {
    try {
      final dt = DateTime.parse(iso);
      return '${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return iso;
    }
  }
}

/// _StatChip — 统计小标签。
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
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '$label $count',
        style: TextStyle(fontSize: 9, color: color),
      ),
    );
  }
}

/// _TaskTile — 单个任务卡片。
class _TaskTile extends StatelessWidget {
  final TaskItem task;
  final bool selected;
  final bool actionPending;
  final VoidCallback onSelect;
  final VoidCallback onDelete;

  const _TaskTile({
    required this.task,
    required this.selected,
    required this.actionPending,
    required this.onSelect,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final (color, icon, label) = _statusInfo(task.status);
    return InkWell(
      onTap: onSelect,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF6366F1).withValues(alpha: 0.1) : null,
          borderRadius: BorderRadius.circular(4),
          border: selected ? Border.all(color: const Color(0xFF6366F1).withValues(alpha: 0.3)) : null,
        ),
        child: Row(
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.title,
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    task.id.length > 16 ? '${task.id.substring(0, 16)}...' : task.id,
                    style: const TextStyle(fontSize: 9, color: Colors.white24),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(label, style: TextStyle(fontSize: 9, color: color)),
            ),
            const SizedBox(width: 4),
            InkWell(
              onTap: actionPending ? null : onDelete,
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.delete_outline, size: 12, color: Colors.white38),
              ),
            ),
          ],
        ),
      ),
    );
  }

  (Color, IconData, String) _statusInfo(String status) {
    return switch (status) {
      'done' => (const Color(0xFF10B981), Icons.check_circle, '完成'),
      'running' => (const Color(0xFFF59E0B), Icons.play_circle, '运行中'),
      'queued' => (const Color(0xFF6366F1), Icons.schedule, '排队'),
      'failed' => (const Color(0xFFEF4444), Icons.error, '失败'),
      _ => (Colors.white38, Icons.circle, '未知'),
    };
  }
}
