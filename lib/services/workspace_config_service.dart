// workspace_config_service.dart - Versioned .Courier workspace preferences.

import 'dart:convert';
import 'dart:io';

import 'app_error.dart';
import 'app_logger.dart';
import 'atomic_file_writer.dart';
import 'workspace_directory_guard.dart';

const defaultWorkspaceExcludes = [
  '.git',
  '.svn',
  '.hg',
  '.Courier',
  'node_modules',
  'build',
  'dist',
  '.dart_tool',
  '__pycache__',
  '.idea',
  '.vscode',
  '*.tmp',
  '*.temp',
  '*~',
  '.DS_Store',
  'Thumbs.db',
];

const defaultFileFilters = <String, bool>{
  'md': true,
  'code': true,
  'json': true,
  'image': true,
  'archive': true,
  'audio': true,
  'video': true,
  'text': true,
  'other': true,
};

class WorkspacePreferences {
  static const int currentSchemaVersion = 1;

  final int schemaVersion;
  final Map<String, bool> fileFilters;
  final List<String> excludePatterns;
  final bool showHiddenFiles;
  final Map<String, dynamic> editor;
  final Map<String, dynamic> taskQueue;

  const WorkspacePreferences({
    required this.schemaVersion,
    required this.fileFilters,
    required this.excludePatterns,
    required this.showHiddenFiles,
    required this.editor,
    required this.taskQueue,
  });

  factory WorkspacePreferences.defaults() {
    return const WorkspacePreferences(
      schemaVersion: currentSchemaVersion,
      fileFilters: defaultFileFilters,
      excludePatterns: defaultWorkspaceExcludes,
      showHiddenFiles: false,
      editor: <String, dynamic>{},
      taskQueue: <String, dynamic>{},
    );
  }

  factory WorkspacePreferences.fromJson(Map<String, dynamic> json) {
    final version = json['schemaVersion'];
    if (version is! int || version < 1) {
      throw const CourierException('INVALID_CONFIG', '工作区配置缺少有效的版本号');
    }
    if (version > currentSchemaVersion) {
      throw const CourierException(
        'CONFIG_VERSION_UNSUPPORTED',
        '工作区配置来自更高版本的 Courier，当前版本不会覆盖该文件',
      );
    }

    final rawFilters = json['fileFilters'];
    final filters = Map<String, bool>.from(defaultFileFilters);
    if (rawFilters is Map<String, dynamic>) {
      for (final entry in rawFilters.entries) {
        if (filters.containsKey(entry.key) && entry.value is bool) {
          filters[entry.key] = entry.value as bool;
        }
      }
    }

    final rawExcludes = json['excludePatterns'];
    final excludes = rawExcludes is List
        ? rawExcludes
              .whereType<String>()
              .map((item) => item.trim())
              .where((item) => item.isNotEmpty && item.length <= 128)
              .take(256)
              .toList(growable: false)
        : List<String>.from(defaultWorkspaceExcludes);

    return WorkspacePreferences(
      schemaVersion: version,
      fileFilters: filters,
      excludePatterns: excludes.isEmpty
          ? List<String>.from(defaultWorkspaceExcludes)
          : excludes,
      showHiddenFiles: json['showHiddenFiles'] == true,
      editor: _safeObject(json['editor']),
      taskQueue: _safeObject(json['taskQueue']),
    );
  }

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'fileFilters': fileFilters,
    'excludePatterns': excludePatterns,
    'showHiddenFiles': showHiddenFiles,
    'editor': editor,
    'taskQueue': taskQueue,
  };

  WorkspacePreferences copyWith({
    Map<String, bool>? fileFilters,
    List<String>? excludePatterns,
    bool? showHiddenFiles,
    Map<String, dynamic>? editor,
    Map<String, dynamic>? taskQueue,
  }) {
    return WorkspacePreferences(
      schemaVersion: schemaVersion,
      fileFilters: fileFilters ?? this.fileFilters,
      excludePatterns: excludePatterns ?? this.excludePatterns,
      showHiddenFiles: showHiddenFiles ?? this.showHiddenFiles,
      editor: editor ?? this.editor,
      taskQueue: taskQueue ?? this.taskQueue,
    );
  }

  static Map<String, dynamic> _safeObject(dynamic value) {
    if (value is! Map<String, dynamic>) return <String, dynamic>{};
    return Map<String, dynamic>.from(value);
  }
}

class WorkspaceConfigService {
  static const int maxConfigBytes = 64 * 1024;

  final AppLogger logger;
  String? _workspacePath;
  File? _preferencesFile;
  bool _readOnly = false;
  WorkspacePreferences _preferences = WorkspacePreferences.defaults();

  WorkspaceConfigService({required this.logger});

  WorkspacePreferences get preferences => _preferences;
  bool get readOnly => _readOnly;
  String? get workspacePath => _workspacePath;

  Directory get courierDirectory {
    final root = _workspacePath;
    if (root == null) {
      throw const CourierException('WORKSPACE_REQUIRED', '需要先打开工作区');
    }
    return Directory('$root${Platform.pathSeparator}.Courier');
  }

  Future<WorkspacePreferences> bindWorkspace(String workspacePath) async {
    final resolved = await WorkspaceDirectoryGuard.resolveWorkspaceRoot(
      workspacePath,
    );
    final previousWorkspacePath = _workspacePath;
    final previousPreferencesFile = _preferencesFile;
    final previousReadOnly = _readOnly;
    final previousPreferences = _preferences;
    try {
      _workspacePath = resolved;
      _readOnly = false;

      final courier = await WorkspaceDirectoryGuard.ensureDirectory(
        resolved,
        const ['.Courier'],
      );
      await WorkspaceDirectoryGuard.ensureDirectory(resolved, const [
        '.Courier',
        'tasks',
      ]);
      await WorkspaceDirectoryGuard.ensureDirectory(resolved, const [
        '.Courier',
        'sessions',
      ]);
      await WorkspaceDirectoryGuard.ensureDirectory(resolved, const [
        '.Courier',
        'logs',
      ]);

      _preferencesFile = File(
        '${courier.path}${Platform.pathSeparator}prefs.json',
      );
      await AtomicFileWriter.recover(_preferencesFile!);
      _preferences = await _loadPreferences(_preferencesFile!);
      return _preferences;
    } catch (_) {
      _workspacePath = previousWorkspacePath;
      _preferencesFile = previousPreferencesFile;
      _readOnly = previousReadOnly;
      _preferences = previousPreferences;
      rethrow;
    }
  }

  Future<void> save(WorkspacePreferences preferences) async {
    final file = _preferencesFile;
    if (file == null) {
      throw const CourierException('WORKSPACE_REQUIRED', '需要先打开工作区');
    }
    if (_readOnly) {
      throw const CourierException('CONFIG_READ_ONLY', '当前工作区配置为只读状态');
    }
    final encoded = const JsonEncoder.withIndent(
      '  ',
    ).convert(preferences.toJson());
    await AtomicFileWriter.writeString(
      file,
      '$encoded\n',
      maxBytes: maxConfigBytes,
    );
    _preferences = preferences;
  }

  Future<WorkspacePreferences> _loadPreferences(File file) async {
    if (!await file.exists()) {
      final defaults = WorkspacePreferences.defaults();
      await save(defaults);
      return defaults;
    }
    if (await file.length() > maxConfigBytes) {
      _readOnly = true;
      throw const CourierException('CONFIG_TOO_LARGE', '工作区配置文件超过大小限制，已停止写入');
    }
    try {
      final raw = await file.readAsString();
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) {
        throw const FormatException('Configuration root must be an object');
      }
      return WorkspacePreferences.fromJson(json);
    } on CourierException catch (error) {
      if (error.code == 'CONFIG_VERSION_UNSUPPORTED') {
        _readOnly = true;
        await logger.warn(
          'workspace_config',
          'version_unsupported',
          '工作区配置版本高于当前应用，已使用只读默认设置',
          errorCode: error.code,
        );
        return WorkspacePreferences.defaults();
      }
      rethrow;
    } catch (_) {
      await logger.error(
        'workspace_config',
        'load_failed',
        '工作区配置无法解析，已保留原文件',
        errorCode: 'INVALID_CONFIG',
      );
      throw const CourierException('INVALID_CONFIG', '工作区配置损坏，原文件已保留');
    }
  }
}
