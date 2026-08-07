// git_panel.dart - Safe Git status, history, diff, commit, and branch UI.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/courier_service.dart';
import '../services/models.dart';
import '../services/settings_state.dart';
import '../services/workspace_service.dart';
import 'glass.dart';

enum _GitPanelView { changes, history }

/// 变更列表的状态筛选：全部 / 已暂存 / 未暂存 / 未跟踪。
enum _GitStatusFilter { all, staged, unstaged, untracked }

class GitPanel extends StatefulWidget {
  const GitPanel({super.key});

  @override
  State<GitPanel> createState() => _GitPanelState();
}

class _GitPanelState extends State<GitPanel> {
  final TextEditingController _commitController = TextEditingController();
  _GitPanelView _view = _GitPanelView.changes;
  _GitStatusFilter _statusFilter = _GitStatusFilter.all;
  String? _selectedPath;
  String? _selectedCommitHash;
  String? _commitDetail;
  bool _stagedDiff = false;
  bool _refreshing = false;
  bool _loadingCommitDetail = false;

  /// 提交详情是否展开（默认隐藏，右键点击提交弹出）
  bool _detailExpanded = false;

  /// 提交详情面板高度（可拖动调整占用空间）
  double _detailHeight = 200;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final service = context.read<CourierService>();
      if (service.currentGitStatus == null ||
          service.gitBranches == null ||
          service.currentGitLog == null) {
        unawaited(_refresh());
      }
    });
  }

  @override
  void dispose() {
    _commitController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final workspace = context.read<WorkspaceService>();
    final service = context.read<CourierService>();
    if (!workspace.hasWorkspace || !service.git.repositoryAvailable) return;
    setState(() {
      _refreshing = true;
      _error = null;
    });
    try {
      await Future.wait([
        service.gitStatus(workspace.workspacePath),
        service.gitBranchList(workspace.workspacePath),
        service.gitLog(),
      ]);
      if (_selectedPath != null) {
        await service.gitDiff(
          workspacePath: workspace.workspacePath,
          path: _selectedPath,
          staged: _stagedDiff,
        );
      }
      final selectedCommitHash = _selectedCommitHash;
      if (mounted &&
          selectedCommitHash != null &&
          !(service.currentGitLog?.entries.any(
                (entry) => entry.fullHash == selectedCommitHash,
              ) ??
              false)) {
        setState(() {
          _selectedCommitHash = null;
          _commitDetail = null;
          _loadingCommitDetail = false;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _toggleStage(GitStatusFile file, bool stage) async {
    final service = context.read<CourierService>();
    try {
      if (stage) {
        await service.gitStage(file.path);
      } else {
        await service.gitUnstage(file.path);
      }
      await _refresh();
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _stageAll() async {
    final service = context.read<CourierService>();
    try {
      await service.gitStageAll();
      await _refresh();
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _unstageAll() async {
    final service = context.read<CourierService>();
    try {
      await service.gitUnstageAll();
      await _refresh();
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _loadDiff(GitStatusFile file, {required bool staged}) async {
    final workspace = context.read<WorkspaceService>();
    final service = context.read<CourierService>();
    setState(() {
      _selectedPath = file.path;
      _stagedDiff = staged;
      _error = null;
    });
    try {
      await service.gitDiff(
        workspacePath: workspace.workspacePath,
        path: file.path,
        staged: staged,
      );
    } catch (error) {
      _showError(error);
    }
  }

  /// 左键点击提交：选中并展开提交详情
  Future<void> _loadCommitDetail(GitCommitEntry entry) async {
    setState(() => _detailExpanded = true);
    final service = context.read<CourierService>();
    setState(() {
      _selectedCommitHash = entry.fullHash;
      _commitDetail = null;
      _loadingCommitDetail = true;
      _error = null;
    });
    try {
      final detail = await service.gitCommitDetail(entry.fullHash);
      if (!mounted || _selectedCommitHash != entry.fullHash) return;
      setState(() => _commitDetail = detail);
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted && _selectedCommitHash == entry.fullHash) {
        setState(() => _loadingCommitDetail = false);
      }
    }
  }

  Future<void> _commit() async {
    final message = _commitController.text.trim();
    if (message.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('确认提交'),
        content: Text(message, maxLines: 4, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('提交'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final workspace = context.read<WorkspaceService>();
    final service = context.read<CourierService>();
    try {
      await service.gitCommit(
        workspacePath: workspace.workspacePath,
        message: message,
      );
      _commitController.clear();
      _showSnack('提交成功');
      await _refresh();
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _switchBranch(String branch) async {
    final workspace = context.read<WorkspaceService>();
    if (workspace.hasDirtyDocuments) {
      _showError('存在未保存文档，不能切换分支');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('切换分支'),
        content: Text('切换到 $branch？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('切换'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await context.read<CourierService>().gitSwitchBranch(branch);
      if (mounted) {
        setState(() {
          _selectedPath = null;
          _selectedCommitHash = null;
          _commitDetail = null;
          _loadingCommitDetail = false;
          _detailExpanded = false;
        });
      }
      await _refresh();
    } catch (error) {
      _showError(error);
    }
  }

  /// 新建分支：弹出输入框，可选"创建后切换"。
  Future<void> _createBranch() async {
    final workspace = context.read<WorkspaceService>();
    final service = context.read<CourierService>();
    final canSwitchNow =
        !workspace.hasDirtyDocuments &&
        (service.currentGitStatus?.clean ?? false);
    final controller = TextEditingController();
    var switchTo = false;
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('新建分支'),
        content: StatefulBuilder(
          builder: (dialogContext, setDialogState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                maxLength: 100,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  isDense: true,
                  counterText: '',
                  hintText: '分支名称',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) =>
                    Navigator.of(dialogContext).pop(controller.text.trim()),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text(
                  '创建后切换',
                  style: TextStyle(fontSize: 12),
                ),
                value: switchTo,
                onChanged: canSwitchNow
                    ? (value) =>
                          setDialogState(() => switchTo = value ?? false)
                    : null,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(null),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    try {
      await service.gitCreateBranch(name, switchTo: switchTo);
      if (!mounted) return;
      _showSnack(switchTo ? '已创建并切换到 $name' : '已创建分支 $name');
      if (switchTo) {
        setState(() {
          _selectedPath = null;
          _selectedCommitHash = null;
          _commitDetail = null;
          _loadingCommitDetail = false;
          _detailExpanded = false;
        });
      }
      await _refresh();
    } catch (error) {
      _showError(error);
    }
  }

  void _showError(Object error) {
    if (!mounted) return;
    setState(() => _error = '$error');
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$error')));
  }

  /// 成功操作的轻提示；[gitSuccessNotifications] 关闭时不展示。
  void _showSnack(String message) {
    if (!mounted) return;
    if (!context.read<SettingsState>().gitSuccessNotifications) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final workspace = context.watch<WorkspaceService>();
    final service = context.watch<CourierService>();
    final git = service.git;

    if (!workspace.hasWorkspace) {
      return const _GitEmptyState(
        icon: Icons.folder_off_outlined,
        label: '未打开工作区',
      );
    }
    if (!git.gitAvailable) {
      return const _GitEmptyState(
        icon: Icons.account_tree_outlined,
        label: '未检测到 Git CLI',
      );
    }
    if (!git.repositoryAvailable) {
      return const _GitEmptyState(
        icon: Icons.source_outlined,
        label: '当前工作区不是仓库根目录',
      );
    }

    final status = service.currentGitStatus;
    final branches = service.gitBranches;
    final files = status?.files ?? const <GitStatusFile>[];
    final diff = service.currentGitDiff;
    final log = service.currentGitLog;
    final busy = _refreshing || git.loading;

    return Column(
      children: [
        _buildToolbar(branches, busy),
        _buildViewSelector(),
        if (_error != null) _buildErrorBar(),
        // 变更/历史视图直接切换（无过渡动画）
        Expanded(
          child: _view == _GitPanelView.changes
              ? _buildChangesView(files, diff, busy)
              : _buildHistoryView(log),
        ),
      ],
    );
  }

  Widget _buildViewSelector() {
    return Container(
      height: 44,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: glassBorderOf(context))),
      ),
      alignment: Alignment.centerLeft,
      child: SegmentedButton<_GitPanelView>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(
            value: _GitPanelView.changes,
            icon: Icon(Icons.edit_note, size: 15),
            label: Text('变更'),
          ),
          ButtonSegment(
            value: _GitPanelView.history,
            icon: Icon(Icons.history, size: 15),
            label: Text('历史'),
          ),
        ],
        selected: {_view},
        onSelectionChanged: (selection) {
          setState(() => _view = selection.first);
          if (_view == _GitPanelView.history &&
              context.read<CourierService>().currentGitLog == null &&
              !_refreshing) {
            unawaited(_refresh());
          }
        },
        style: const ButtonStyle(
          visualDensity: VisualDensity.compact,
          textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 11)),
        ),
      ),
    );
  }

  Widget _buildChangesView(
    List<GitStatusFile> files,
    GitDiffResult? diff,
    bool busy,
  ) {
    final visibleFiles = files
        .where(_matchesStatusFilter)
        .toList(growable: false);
    return Column(
      children: [
        _buildCommitBar(files, busy),
        _buildFilterBar(),
        SizedBox(
          height: 160,
          child: files.isEmpty
              ? const Center(
                  child: Text(
                    '工作区无变更',
                    style: TextStyle(fontSize: 12, color: Colors.white38),
                  ),
                )
              : visibleFiles.isEmpty
              ? const Center(
                  child: Text(
                    '无符合条件的变更',
                    style: TextStyle(fontSize: 12, color: Colors.white38),
                  ),
                )
              : ListView.builder(
                  itemCount: visibleFiles.length,
                  itemBuilder: (context, index) =>
                      _buildFileRow(visibleFiles[index], busy),
                ),
        ),
        const Divider(height: 1),
        _buildDiffMode(),
        Expanded(child: _buildDiffArea(diff)),
      ],
    );
  }

  /// diff 展示区：未选择时提示"未选择差异"；选中后无差异提示"无差异"；
  /// 有差异时按行前缀做轻量语法高亮。
  Widget _buildDiffArea(GitDiffResult? diff) {
    if (diff == null || diff.diff.isEmpty) {
      return Center(
        child: Text(
          _selectedPath == null ? '未选择差异' : '无差异',
          style: const TextStyle(fontSize: 12, color: Colors.white38),
        ),
      );
    }
    final text = diff.truncated ? '${diff.diff}\n[输出已截断]' : diff.diff;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(10),
      child: SelectableText.rich(
        TextSpan(children: _highlightDiff(text)),
        style: const TextStyle(
          fontSize: 11,
          height: 1.45,
          fontFamily: 'Consolas',
          color: Colors.white70,
        ),
      ),
    );
  }

  /// 按 diff 行前缀着色：新增行 + 绿色、删除行 - 红色、@@ 头青色、
  /// 文件头（diff --git / --- / +++ / index 等）弱色、其余默认色。
  List<TextSpan> _highlightDiff(String diff) {
    const defaultColor = Colors.white70;
    const headerColor = Colors.white38;
    const hunkColor = Color(0xFF6EC1E4);
    const addColor = Color(0xFF7DD3A8);
    const removeColor = Color(0xFFF2A0A0);
    final spans = <TextSpan>[];
    for (final line in const LineSplitter().convert(diff)) {
      Color color = defaultColor;
      if (line.startsWith('+++') ||
          line.startsWith('---') ||
          line.startsWith('diff --git') ||
          line.startsWith('index ') ||
          line.startsWith('new file') ||
          line.startsWith('deleted file') ||
          line.startsWith('similarity ') ||
          line.startsWith('rename ') ||
          line.startsWith('copy ') ||
          line.startsWith('old mode') ||
          line.startsWith('new mode') ||
          line.startsWith('Binary files')) {
        color = headerColor;
      } else if (line.startsWith('@@')) {
        color = hunkColor;
      } else if (line.startsWith('+')) {
        color = addColor;
      } else if (line.startsWith('-')) {
        color = removeColor;
      }
      spans.add(TextSpan(text: '$line\n', style: TextStyle(color: color)));
    }
    return spans;
  }

  Widget _buildHistoryView(GitLogResult? log) {
    final entries = log?.entries ?? const <GitCommitEntry>[];
    return Column(
      key: const Key('git-history-view'),
      children: [
        SizedBox(
          height: 190,
          child: log == null && _refreshing
              ? const Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
                )
              : entries.isEmpty
              ? const Center(
                  child: Text(
                    '仓库暂无提交记录',
                    style: TextStyle(fontSize: 12, color: Colors.white38),
                  ),
                )
              : ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, index) =>
                      _buildCommitRow(entries[index]),
                ),
        ),
        const Divider(height: 1),
        // 提交详情默认隐藏；右键点击提交弹出，可拖动上边缘调整占用高度
        if (_detailExpanded && _selectedCommitHash != null)
          SizedBox(
            height: _detailHeight,
            child: Column(
              children: [
                _buildDetailDragHandle(),
                _buildCommitDetailHeader(),
                Expanded(child: _buildCommitDetail()),
              ],
            ),
          ),
      ],
    );
  }

  /// 详情面板上边缘的拖拽手柄：上下拖动调整详情占用高度
  Widget _buildDetailDragHandle() {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeUpDown,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (details) {
          setState(() {
            _detailHeight = (_detailHeight - details.delta.dy).clamp(
              120.0,
              340.0,
            );
          });
        },
        child: SizedBox(
          height: 10,
          child: Center(
            child: Container(
              width: 36,
              height: 3,
              decoration: BoxDecoration(
                color: kGlassChipBg,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCommitRow(GitCommitEntry entry) {
    final selected = entry.fullHash == _selectedCommitHash;
    final accent = accentColorOf(context);
    final accentLight = accentLightOf(context);
    return Material(
      key: ValueKey('git-commit-${entry.fullHash}'),
      color: selected ? glassSelectedBgOf(context) : Colors.transparent,
      child: InkWell(
        onTap: () => _loadCommitDetail(entry),
        child: SizedBox(
          height: 58,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              children: [
                SizedBox(
                  width: 70,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        entry.shortHash,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'Consolas',
                          color: accentLight,
                        ),
                      ),
                      if (entry.isHead) ...[
                        const SizedBox(height: 3),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            'HEAD',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                              color: accentLight,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        entry.subject,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: entry.isHead
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: Tooltip(
                              message:
                                  '${entry.authorName} <${entry.authorEmail}>',
                              child: Text(
                                entry.authorName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: Colors.white54,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 94,
                            child: Text(
                              _formatAuthorDate(entry.authorDate),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.right,
                              style: const TextStyle(
                                fontSize: 10,
                                color: Colors.white38,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCommitDetailHeader() {
    final accent = accentColorOf(context);
    return SizedBox(
      height: 38,
      child: Row(
        children: [
          const SizedBox(width: 10),
          Icon(Icons.article_outlined, size: 15, color: accent),
          const SizedBox(width: 6),
          const Text(
            '提交详情',
            style: TextStyle(fontSize: 11, color: Colors.white70),
          ),
          const Spacer(),
          if (_loadingCommitDetail)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            ),
          IconButton(
            tooltip: '收起详情',
            onPressed: () => setState(() => _detailExpanded = false),
            icon: const Icon(Icons.close, size: 14),
            constraints: const BoxConstraints.tightFor(width: 26, height: 26),
            padding: EdgeInsets.zero,
          ),
          const SizedBox(width: 6),
        ],
      ),
    );
  }

  Widget _buildCommitDetail() {
    if (_selectedCommitHash == null) {
      return const Center(
        child: Text(
          '未选择提交',
          style: TextStyle(fontSize: 12, color: Colors.white38),
        ),
      );
    }
    if (_loadingCommitDetail) return const SizedBox.shrink();
    final detail = _commitDetail;
    if (detail == null || detail.isEmpty) {
      return const Center(
        child: Text(
          '提交详情为空',
          style: TextStyle(fontSize: 12, color: Colors.white38),
        ),
      );
    }
    return SingleChildScrollView(
      key: const Key('git-commit-detail'),
      padding: const EdgeInsets.all(10),
      child: SelectableText(
        detail,
        style: const TextStyle(
          fontSize: 11,
          height: 1.45,
          fontFamily: 'Consolas',
          color: Colors.white70,
        ),
      ),
    );
  }

  String _formatAuthorDate(String value) {
    final parsed = DateTime.tryParse(value)?.toLocal();
    if (parsed == null) return value;
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    return '${parsed.year}-${twoDigits(parsed.month)}-'
        '${twoDigits(parsed.day)} ${twoDigits(parsed.hour)}:'
        '${twoDigits(parsed.minute)}';
  }

  Widget _buildToolbar(GitBranchListResult? branches, bool busy) {
    final current = branches?.current ?? '';
    final branchItems = branches?.branches ?? const <String>[];
    final selectedBranch = branchItems.contains(current) ? current : null;
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: glassHeaderBgOf(context),
        border: Border(bottom: BorderSide(color: glassBorderOf(context))),
      ),
      child: Row(
        children: [
          Icon(Icons.account_tree, size: 15, color: accentColorOf(context)),
          const SizedBox(width: 6),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: selectedBranch,
                isExpanded: true,
                isDense: true,
                dropdownColor: glassFloatBgOf(context),
                hint: Text(
                  current.isEmpty ? '分支' : current,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Colors.white38),
                ),
                items: branchItems
                    .map(
                      (branch) => DropdownMenuItem(
                        value: branch,
                        child: Text(
                          branch == current ? '$branch（当前）' : branch,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: branch == current
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (branch) {
                  if (branch != null && branch != current) {
                    _switchBranch(branch);
                  }
                },
              ),
            ),
          ),
          IconButton(
            tooltip: '新建分支',
            onPressed: busy ? null : _createBranch,
            icon: const Icon(Icons.add, size: 16),
          ),
          IconButton(
            tooltip: '刷新 Git 状态',
            onPressed: _refreshing ? null : _refresh,
            icon: _refreshing
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                : const Icon(Icons.refresh, size: 16),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      color: const Color(0x1AEF4444),
      child: Text(
        _error!,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11, color: Color(0xFFFCA5A5)),
      ),
    );
  }

  Widget _buildCommitBar(List<GitStatusFile> files, bool busy) {
    final hasStageable = files.any(
      (file) => file.untracked || file.workTreeStatus.trim().isNotEmpty,
    );
    final hasStaged = files.any((file) => file.staged);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 6, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          IconButton(
            tooltip: '全部暂存',
            onPressed: (busy || !hasStageable) ? null : _stageAll,
            icon: const Icon(Icons.select_all, size: 17),
            constraints: const BoxConstraints.tightFor(width: 30, height: 30),
            padding: EdgeInsets.zero,
          ),
          IconButton(
            tooltip: '全部取消暂存',
            onPressed: (busy || !hasStaged) ? null : _unstageAll,
            icon: const Icon(Icons.deselect, size: 17),
            constraints: const BoxConstraints.tightFor(width: 30, height: 30),
            padding: EdgeInsets.zero,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Focus(
              onKeyEvent: (node, event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.enter &&
                    (HardwareKeyboard.instance.isControlPressed ||
                        HardwareKeyboard.instance.isMetaPressed)) {
                  _commit();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: TextField(
                controller: _commitController,
                maxLength: 200,
                minLines: 1,
                maxLines: 3,
                keyboardType: TextInputType.multiline,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  isDense: true,
                  counterText: '',
                  hintText: '提交信息（Ctrl+Enter 提交）',
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 8,
                  ),
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: '提交已暂存变更',
            onPressed: (busy || !hasStaged) ? null : _commit,
            icon: const Icon(Icons.commit, size: 17),
          ),
        ],
      ),
    );
  }

  /// 变更列表的状态筛选条（纯前端过滤）。
  Widget _buildFilterBar() {
    const options = <(_GitStatusFilter, String)>[
      (_GitStatusFilter.all, '全部'),
      (_GitStatusFilter.staged, '已暂存'),
      (_GitStatusFilter.unstaged, '未暂存'),
      (_GitStatusFilter.untracked, '未跟踪'),
    ];
    return SizedBox(
      height: 34,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        children: [
          for (final (value, label) in options)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(label, style: const TextStyle(fontSize: 11)),
                selected: _statusFilter == value,
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                onSelected: (_) => setState(() => _statusFilter = value),
              ),
            ),
        ],
      ),
    );
  }

  bool _matchesStatusFilter(GitStatusFile file) {
    switch (_statusFilter) {
      case _GitStatusFilter.all:
        return true;
      case _GitStatusFilter.staged:
        return file.staged;
      case _GitStatusFilter.unstaged:
        return !file.staged &&
            (file.untracked || file.workTreeStatus.trim().isNotEmpty);
      case _GitStatusFilter.untracked:
        return file.untracked;
    }
  }

  Widget _buildFileRow(GitStatusFile file, bool busy) {
    final canStage = file.untracked || file.workTreeStatus.trim().isNotEmpty;
    final canUnstage = file.staged;
    final selected = file.path == _selectedPath;
    return Material(
      color: selected ? glassSelectedBgOf(context) : Colors.transparent,
      child: InkWell(
        onTap: () => _loadDiff(
          file,
          staged: file.staged && file.workTreeStatus.trim().isEmpty,
        ),
        child: SizedBox(
          height: 34,
          child: Row(
            children: [
              const SizedBox(width: 10),
              SizedBox(
                width: 24,
                child: Text(
                  file.status,
                  style: TextStyle(fontSize: 11, color: accentLightOf(context)),
                ),
              ),
              Expanded(
                child: Text(
                  file.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Colors.white70),
                ),
              ),
              if (canStage)
                IconButton(
                  tooltip: '暂存',
                  onPressed: busy ? null : () => _toggleStage(file, true),
                  icon: const Icon(Icons.add, size: 14),
                  constraints: const BoxConstraints.tightFor(
                    width: 28,
                    height: 28,
                  ),
                  padding: EdgeInsets.zero,
                ),
              if (canUnstage)
                IconButton(
                  tooltip: '取消暂存',
                  onPressed: busy ? null : () => _toggleStage(file, false),
                  icon: const Icon(Icons.remove, size: 14),
                  constraints: const BoxConstraints.tightFor(
                    width: 28,
                    height: 28,
                  ),
                  padding: EdgeInsets.zero,
                ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDiffMode() {
    return SizedBox(
      height: 38,
      child: Row(
        children: [
          const SizedBox(width: 10),
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: false, label: Text('工作区')),
              ButtonSegment(value: true, label: Text('已暂存')),
            ],
            selected: {_stagedDiff},
            onSelectionChanged: (selection) {
              final selectedPath = _selectedPath;
              if (selectedPath == null) return;
              final service = context.read<CourierService>();
              final file = service.currentGitStatus?.files
                  .where((item) => item.path == selectedPath)
                  .firstOrNull;
              if (file != null) {
                _loadDiff(file, staged: selection.first);
              }
            },
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 11)),
            ),
          ),
        ],
      ),
    );
  }
}

class _GitEmptyState extends StatelessWidget {
  final IconData icon;
  final String label;

  const _GitEmptyState({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 30, color: Colors.white24),
          const SizedBox(height: 8),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: Colors.white38),
          ),
        ],
      ),
    );
  }
}
