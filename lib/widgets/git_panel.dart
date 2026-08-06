// git_panel.dart - Safe Git status, history, diff, commit, and branch UI.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/courier_service.dart';
import '../services/models.dart';
import '../services/workspace_service.dart';
import 'glass.dart';

enum _GitPanelView { changes, history }

class GitPanel extends StatefulWidget {
  const GitPanel({super.key});

  @override
  State<GitPanel> createState() => _GitPanelState();
}

class _GitPanelState extends State<GitPanel> {
  final TextEditingController _commitController = TextEditingController();
  _GitPanelView _view = _GitPanelView.changes;
  String? _selectedPath;
  String? _selectedCommitHash;
  String? _commitDetail;
  bool _stagedDiff = false;
  bool _refreshing = false;
  bool _loadingCommitDetail = false;
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

  Future<void> _loadCommitDetail(GitCommitEntry entry) async {
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

    return Column(
      children: [
        _buildToolbar(branches),
        _buildViewSelector(),
        if (_error != null) _buildErrorBar(),
        Expanded(
          child: _view == _GitPanelView.changes
              ? _buildChangesView(files, diff)
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
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: kGlassBorder)),
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

  Widget _buildChangesView(List<GitStatusFile> files, GitDiffResult? diff) {
    return Column(
      children: [
        _buildCommitBar(),
        SizedBox(
          height: 190,
          child: files.isEmpty
              ? const Center(
                  child: Text(
                    '工作区无变更',
                    style: TextStyle(fontSize: 12, color: Colors.white38),
                  ),
                )
              : ListView.builder(
                  itemCount: files.length,
                  itemBuilder: (context, index) => _buildFileRow(files[index]),
                ),
        ),
        const Divider(height: 1, color: kGlassBorder),
        _buildDiffMode(),
        Expanded(
          child: diff == null || diff.diff.isEmpty
              ? const Center(
                  child: Text(
                    '未选择差异',
                    style: TextStyle(fontSize: 12, color: Colors.white38),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(10),
                  child: SelectableText(
                    diff.truncated ? '${diff.diff}\n[输出已截断]' : diff.diff,
                    style: const TextStyle(
                      fontSize: 11,
                      height: 1.45,
                      fontFamily: 'Consolas',
                      color: Colors.white70,
                    ),
                  ),
                ),
        ),
      ],
    );
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
        const Divider(height: 1, color: kGlassBorder),
        _buildCommitDetailHeader(),
        Expanded(child: _buildCommitDetail()),
      ],
    );
  }

  Widget _buildCommitRow(GitCommitEntry entry) {
    final selected = entry.fullHash == _selectedCommitHash;
    return Material(
      key: ValueKey('git-commit-${entry.fullHash}'),
      color: selected ? kGlassSelectedBg : Colors.transparent,
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
                        style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'Consolas',
                          color: kPrimaryLight,
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
                            color: kPrimary.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: const Text(
                            'HEAD',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                              color: kPrimaryLight,
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
    return SizedBox(
      height: 38,
      child: Row(
        children: [
          const SizedBox(width: 10),
          const Icon(Icons.article_outlined, size: 15, color: kPrimary),
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
          const SizedBox(width: 10),
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

  Widget _buildToolbar(GitBranchListResult? branches) {
    final current = branches?.current ?? '';
    final branchItems = branches?.branches ?? const <String>[];
    final selectedBranch = branchItems.contains(current) ? current : null;
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        color: kGlassHeaderBg,
        border: Border(bottom: BorderSide(color: kGlassBorder)),
      ),
      child: Row(
        children: [
          const Icon(Icons.account_tree, size: 15, color: kPrimary),
          const SizedBox(width: 6),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: selectedBranch,
                isExpanded: true,
                isDense: true,
                dropdownColor: kGlassFloatBg,
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
                          branch,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
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

  Widget _buildCommitBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _commitController,
              maxLength: 200,
              maxLines: 1,
              style: const TextStyle(fontSize: 12),
              decoration: const InputDecoration(
                isDense: true,
                counterText: '',
                hintText: '提交信息',
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 9,
                  vertical: 8,
                ),
                border: OutlineInputBorder(),
              ),
            ),
          ),
          IconButton(
            tooltip: '提交已暂存变更',
            onPressed: _commit,
            icon: const Icon(Icons.commit, size: 17),
          ),
        ],
      ),
    );
  }

  Widget _buildFileRow(GitStatusFile file) {
    final canStage = file.untracked || file.workTreeStatus.trim().isNotEmpty;
    final canUnstage = file.staged;
    final selected = file.path == _selectedPath;
    return Material(
      color: selected ? kGlassSelectedBg : Colors.transparent,
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
                  style: const TextStyle(fontSize: 11, color: kPrimaryLight),
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
                  onPressed: () => _toggleStage(file, true),
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
                  onPressed: () => _toggleStage(file, false),
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
