// git_panel.dart - Safe Git status, staging, diff, commit, and branch UI.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/courier_service.dart';
import '../services/models.dart';
import '../services/workspace_service.dart';
import 'glass.dart';

class GitPanel extends StatefulWidget {
  const GitPanel({super.key});

  @override
  State<GitPanel> createState() => _GitPanelState();
}

class _GitPanelState extends State<GitPanel> {
  final TextEditingController _commitController = TextEditingController();
  String? _selectedPath;
  bool _stagedDiff = false;
  bool _refreshing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final service = context.read<CourierService>();
      if (service.currentGitStatus == null || service.gitBranches == null) {
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
      ]);
      if (_selectedPath != null) {
        await service.gitDiff(
          workspacePath: workspace.workspacePath,
          path: _selectedPath,
          staged: _stagedDiff,
        );
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

    return Column(
      children: [
        _buildToolbar(branches),
        if (_error != null) _buildErrorBar(),
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

  Widget _buildToolbar(GitBranchListResult? branches) {
    final current = branches?.current ?? '';
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
                value: current.isEmpty ? null : current,
                isExpanded: true,
                isDense: true,
                dropdownColor: kGlassFloatBg,
                hint: const Text(
                  '分支',
                  style: TextStyle(fontSize: 12, color: Colors.white38),
                ),
                items: (branches?.branches ?? const <String>[])
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
