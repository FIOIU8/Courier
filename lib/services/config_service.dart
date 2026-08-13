// config_service.dart - Workspace-level Courier configuration persistence.

import 'dart:convert';
import 'dart:io';

import 'app_error.dart';
import 'app_logger.dart';
import 'atomic_file_writer.dart';
import 'models.dart';
import 'workspace_directory_guard.dart';

/// 工作区级别的 Courier 配置（.Courier/config.json）。
///
/// 存储默认任务权限级别、Codex CLI 可用状态等跨会话持久化的设置。
class ConfigService {
  static const int _schemaVersion = 1;
  static const int _maxConfigBytes = 64 * 1024; // 64 KB

  final AppLogger logger;

  File? _configFile;

  String _defaultPermission = TaskPermission.readOnly;
  bool _codexAvailable = false;
  String? _codexVersion;

  ConfigService({required this.logger});

  /// 默认任务权限级别
  String get defaultPermission => _defaultPermission;

  /// Codex CLI 是否可用
  bool get codexAvailable => _codexAvailable;

  /// Codex CLI 版本信息
  String? get codexVersion => _codexVersion;

  /// 绑定工作区，加载或创建配置文件。
  Future<void> bindWorkspace(String workspacePath) async {
    final resolvedWorkspace =
        await WorkspaceDirectoryGuard.resolveWorkspaceRoot(workspacePath);
    final directory = await WorkspaceDirectoryGuard.ensureDirectory(
      resolvedWorkspace,
      const ['.Courier'],
    );
    _configFile = File(
      '${directory.path}${Platform.pathSeparator}config.json',
    );
    await _load();
  }

  /// 检测 Codex CLI 可用性并记录结果。
  Future<bool> detectCodex() async {
    try {
      final result = await Process.run(
        'codex',
        ['--version'],
        runInShell: true,
      );
      if (result.exitCode == 0) {
        final output = (result.stdout as String).trim();
        _codexAvailable = true;
        _codexVersion = output.isEmpty ? null : output;
        await logger.info('config', 'codex_detected', 'Codex CLI 可用: $_codexVersion');
        await _persist();
        return true;
      }
    } catch (_) {
      // codex 命令不存在或执行失败
    }
    _codexAvailable = false;
    _codexVersion = null;
    await logger.warn('config', 'codex_not_found', 'Codex CLI 未检测到，请安装 codex');
    await _persist();
    return false;
  }

  /// 设置默认权限级别。
  Future<void> setDefaultPermission(String permission) async {
    if (!TaskPermission.isValid(permission)) {
      throw const CourierException('INVALID_PERMISSION', '权限级别无效');
    }
    if (permission == _defaultPermission) return;
    _defaultPermission = permission;
    await _persist();
  }

  Future<void> _load() async {
    final file = _configFile;
    if (file == null) return;
    if (!await file.exists()) {
      await _persist();
      return;
    }
    if (await file.length() > _maxConfigBytes) {
      throw const CourierException('CONFIG_TOO_LARGE', '配置文件超过大小限制');
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['schemaVersion'] != _schemaVersion) {
        throw const FormatException('Invalid config');
      }
      final permission = decoded['defaultPermission'] as String?;
      if (permission != null && TaskPermission.isValid(permission)) {
        _defaultPermission = permission;
      }
      final codexAvailable = decoded['codexAvailable'];
      if (codexAvailable is bool) {
        _codexAvailable = codexAvailable;
      }
      final codexVersion = decoded['codexVersion'];
      if (codexVersion is String) {
        _codexVersion = codexVersion;
      }
    } catch (_) {
      await logger.warn('config', 'config_load_failed', '配置文件解析失败，使用默认值');
    }
  }

  Future<void> _persist() async {
    final file = _configFile;
    if (file == null) return;
    final payload = const JsonEncoder.withIndent('  ').convert({
      'schemaVersion': _schemaVersion,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'defaultPermission': _defaultPermission,
      'codexAvailable': _codexAvailable,
      'codexVersion': _codexVersion,
    });
    try {
      await AtomicFileWriter.writeString(
        file,
        '$payload\n',
        maxBytes: _maxConfigBytes,
      );
    } catch (error) {
      await logger.warn('config', 'config_persist_failed', '配置文件写入失败: $error');
    }
  }

  Future<void> reset() async {
    _configFile = null;
    _defaultPermission = TaskPermission.readOnly;
    _codexAvailable = false;
    _codexVersion = null;
  }
}
