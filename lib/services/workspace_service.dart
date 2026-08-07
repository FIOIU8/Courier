// workspace_service.dart - Safe workspace, file tree, and editor state.

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_error.dart';
import 'app_logger.dart';
import 'id_generator.dart';
import 'safe_file_system.dart';
import 'workspace_config_service.dart';

class FileTreeNode {
  final String name;
  final String path;
  final String relativePath;
  final bool isDir;
  final List<FileTreeNode> children;
  final int level;

  const FileTreeNode({
    required this.name,
    required this.path,
    required this.relativePath,
    required this.isDir,
    this.children = const [],
    this.level = 0,
  });
}

class EditorDocument extends ChangeNotifier {
  String id;
  String path;
  String relativePath;
  String fileName;
  String content;
  String savedContent;
  bool untitled;
  bool external;
  FileFingerprint? fingerprint;

  EditorDocument({
    required this.id,
    required this.path,
    required this.relativePath,
    required this.fileName,
    required this.content,
    required this.savedContent,
    this.untitled = false,
    this.external = false,
    this.fingerprint,
  });

  bool get isDirty => content != savedContent;

  void updateContent(String newContent) {
    if (content == newContent) return;
    content = newContent;
    notifyListeners();
  }

  void markSaved(FileFingerprint newFingerprint) {
    savedContent = content;
    fingerprint = newFingerprint;
    external = false;
    notifyListeners();
  }

  void replaceFromDisk(SafeTextFile file) {
    content = file.content;
    savedContent = file.content;
    fingerprint = file.fingerprint;
    external = false;
    notifyListeners();
  }
}

class FileDragPayload {
  final String name;
  final String path;
  final String relativePath;

  const FileDragPayload({
    required this.name,
    required this.path,
    required this.relativePath,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'path': path,
    'relativePath': relativePath,
  };

  static FileDragPayload? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final name = json['name'];
    final path = json['path'];
    final relativePath = json['relativePath'];
    if (name is! String || path is! String || relativePath is! String) {
      return null;
    }
    return FileDragPayload(name: name, path: path, relativePath: relativePath);
  }
}

class WorkspaceService extends ChangeNotifier {
  static const String _workspacePreferenceKey = 'workspace_path';
  static const String _legacyExcludeKey = 'workspace_excludes';
  static const int _maxTreeDepth = 12;

  final SafeFileSystem fileSystem;
  final WorkspaceConfigService configService;
  final AppLogger logger;
  final Future<void> Function(String workspacePath)? onWorkspaceOpened;

  String _workspacePath = '';
  String _workspaceName = '';
  List<FileTreeNode> _fileTree = [];
  final List<EditorDocument> _documents = [];
  String? _activeDocumentId;
  int _untitledCounter = 0;
  bool _scanning = false;
  String? _lastError;
  List<String> _excludePatterns = List.from(defaultWorkspaceExcludes);
  bool _showHidden = false;
  final Map<String, bool> _categoryFilter = Map<String, bool>.from(
    defaultFileFilters,
  );

  WorkspaceService({
    required this.fileSystem,
    required this.configService,
    required this.logger,
    this.onWorkspaceOpened,
  });

  String get workspacePath => _workspacePath;
  String get workspaceName => _workspaceName;
  List<FileTreeNode> get fileTree => List.unmodifiable(_fileTree);
  List<EditorDocument> get documents => List.unmodifiable(_documents);
  String? get activeDocumentId => _activeDocumentId;
  bool get hasWorkspace => _workspacePath.isNotEmpty;
  bool get scanning => _scanning;
  String? get lastError => _lastError;
  List<String> get excludePatterns => List.unmodifiable(_excludePatterns);
  bool get showHidden => _showHidden;
  Map<String, bool> get categoryFilter => Map.unmodifiable(_categoryFilter);
  bool get hasDirtyDocuments => _documents.any((document) => document.isDirty);
  List<EditorDocument> get dirtyDocuments =>
      _documents.where((document) => document.isDirty).toList(growable: false);
  int get visibleFileCount => _countFiles(_fileTree);

  EditorDocument? get activeDocument {
    if (_activeDocumentId == null) return null;
    return _documents
        .where((document) => document.id == _activeDocumentId)
        .firstOrNull;
  }

  Future<void> loadLastWorkspace() async {
    final preferences = await SharedPreferences.getInstance();
    final path = preferences.getString(_workspacePreferenceKey);
    if (path == null || path.isEmpty || !await Directory(path).exists()) return;
    final legacyExcludes = preferences.getStringList(_legacyExcludeKey);
    await openWorkspace(path, persist: false, legacyExcludes: legacyExcludes);
    if (legacyExcludes != null && legacyExcludes.isNotEmpty) {
      final removed = await preferences.remove(_legacyExcludeKey);
      if (!removed) {
        await logger.warn(
          'workspace',
          'legacy_preferences_cleanup_failed',
          '旧版工作区排除设置未能清理',
        );
      }
    }
  }

  Future<void> pickWorkspace({bool discardUnsaved = false}) async {
    final result = await getDirectoryPath(confirmButtonText: '选择工作区');
    if (result == null || result.isEmpty) return;
    await openWorkspace(result, discardUnsaved: discardUnsaved);
  }

  Future<void> openWorkspace(
    String path, {
    bool persist = true,
    bool discardUnsaved = false,
    List<String>? legacyExcludes,
  }) async {
    if (hasDirtyDocuments && !discardUnsaved) {
      throw const CourierException(
        'UNSAVED_CHANGES',
        '存在未保存文档，切换工作区前需要保存或放弃更改',
      );
    }

    final previousRoot = _workspacePath;
    final safeRoot = await fileSystem.resolveWorkspace(path);
    late WorkspacePreferences preferences;
    try {
      preferences = await configService.bindWorkspace(safeRoot);
      if (legacyExcludes != null &&
          legacyExcludes.isNotEmpty &&
          !configService.readOnly &&
          listEquals(preferences.excludePatterns, defaultWorkspaceExcludes)) {
        final migrated = _sanitizeExcludePatterns(legacyExcludes);
        preferences = preferences.copyWith(excludePatterns: migrated);
        await configService.save(preferences);
      }

      await onWorkspaceOpened?.call(safeRoot);
      await fileSystem.bindWorkspace(safeRoot);
      if (persist) {
        final globalPreferences = await SharedPreferences.getInstance();
        final written = await globalPreferences.setString(
          _workspacePreferenceKey,
          safeRoot,
        );
        if (!written) {
          throw const CourierException(
            'PREFERENCES_WRITE_FAILED',
            '无法记录最近使用的工作区',
          );
        }
      }
    } catch (error, stackTrace) {
      if (previousRoot.isNotEmpty) {
        try {
          await configService.bindWorkspace(previousRoot);
          await onWorkspaceOpened?.call(previousRoot);
          await fileSystem.bindWorkspace(previousRoot);
        } catch (_) {
          await logger.error(
            'workspace',
            'rollback_failed',
            '工作区切换失败后无法恢复原服务状态',
            errorCode: 'WORKSPACE_ROLLBACK_FAILED',
          );
          throw const CourierException(
            'WORKSPACE_ROLLBACK_FAILED',
            '工作区切换失败，且原工作区服务状态无法恢复',
          );
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    }

    await _closeAllDocuments(discardUnsaved: true);
    _workspacePath = safeRoot;
    _workspaceName = p.basename(safeRoot);
    _excludePatterns = List<String>.from(preferences.excludePatterns);
    _showHidden = preferences.showHiddenFiles;
    _categoryFilter
      ..clear()
      ..addAll(preferences.fileFilters);
    _lastError = null;
    notifyListeners();

    await scanFileTree();

    await logger.info('workspace', 'opened', '工作区已打开');
  }

  Future<void> setExcludePatterns(List<String> patterns) async {
    _requireWorkspace();
    final sanitized = _sanitizeExcludePatterns(patterns);
    await _saveWorkspacePreferences(excludePatterns: sanitized);
    _excludePatterns = sanitized;
    notifyListeners();
    await scanFileTree();
  }

  Future<void> addExcludePattern(String pattern) async {
    final value = _sanitizeExcludePattern(pattern);
    if (_excludePatterns.contains(value)) return;
    await setExcludePatterns([..._excludePatterns, value]);
  }

  Future<void> removeExcludePattern(String pattern) async {
    await setExcludePatterns(
      _excludePatterns.where((item) => item != pattern).toList(growable: false),
    );
  }

  Future<void> resetExcludePatterns() async {
    await setExcludePatterns(defaultWorkspaceExcludes);
  }

  Future<void> toggleShowHidden() async {
    await setShowHidden(!_showHidden);
  }

  Future<void> setShowHidden(bool value) async {
    if (_showHidden == value) return;
    await _saveWorkspacePreferences(showHidden: value);
    _showHidden = value;
    notifyListeners();
    await scanFileTree();
  }

  Future<void> toggleCategoryFilter(String category, bool value) async {
    await setCategoryFilters({category: value});
  }

  Future<void> setCategoryFilters(Map<String, bool> values) async {
    if (values.keys.any((category) => !_categoryFilter.containsKey(category))) {
      throw const CourierException('INVALID_FILTER', '文件分类过滤器无效');
    }
    final filters = Map<String, bool>.from(_categoryFilter)..addAll(values);
    await _saveWorkspacePreferences(categoryFilter: filters);
    _categoryFilter
      ..clear()
      ..addAll(filters);
    notifyListeners();
    await scanFileTree();
  }

  Future<void> scanFileTree() async {
    if (_workspacePath.isEmpty || _scanning) return;
    _scanning = true;
    _lastError = null;
    notifyListeners();
    try {
      _fileTree = await _scanDirectory(_workspacePath, 0);
    } on CourierException catch (error) {
      _lastError = error.message;
      await logger.error(
        'workspace',
        'scan_failed',
        error.message,
        errorCode: error.code,
      );
      rethrow;
    } catch (_) {
      _lastError = '文件树扫描失败';
      await logger.error(
        'workspace',
        'scan_failed',
        '文件树扫描期间发生未分类错误',
        errorCode: 'WORKSPACE_SCAN_FAILED',
      );
      throw const CourierException('WORKSPACE_SCAN_FAILED', '文件树扫描失败');
    } finally {
      _scanning = false;
      notifyListeners();
    }
  }

  Future<List<FileTreeNode>> _scanDirectory(
    String directoryPath,
    int level,
  ) async {
    if (level > _maxTreeDepth) return const [];
    final entities = await fileSystem.listDirectory(directoryPath);
    entities.sort((left, right) {
      final leftDirectory = left is Directory;
      final rightDirectory = right is Directory;
      if (leftDirectory != rightDirectory) return leftDirectory ? -1 : 1;
      return p
          .basename(left.path)
          .toLowerCase()
          .compareTo(p.basename(right.path).toLowerCase());
    });

    final nodes = <FileTreeNode>[];
    for (final entity in entities) {
      final name = p.basename(entity.path);
      if (_isExcluded(name)) continue;
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type == FileSystemEntityType.link) continue;
      final relativePath = p.relative(entity.path, from: _workspacePath);

      if (type == FileSystemEntityType.directory) {
        final children = await _scanDirectory(entity.path, level + 1);
        nodes.add(
          FileTreeNode(
            name: name,
            path: entity.path,
            relativePath: relativePath,
            isDir: true,
            children: children,
            level: level,
          ),
        );
      } else if (type == FileSystemEntityType.file) {
        final category = _classifyFile(name);
        if (_categoryFilter[category] != false) {
          nodes.add(
            FileTreeNode(
              name: name,
              path: entity.path,
              relativePath: relativePath,
              isDir: false,
              level: level,
            ),
          );
        }
      }
    }
    return nodes;
  }

  Future<String> createFile(String fileName, {String? parentPath}) async {
    _requireWorkspace();
    final result = await fileSystem.createFile(
      parentPath ?? _workspacePath,
      fileName,
    );
    await logger.info('workspace', 'file_created', '已创建工作区文件');
    await scanFileTree();
    return result;
  }

  Future<String> createFolder(String folderName, {String? parentPath}) async {
    _requireWorkspace();
    final result = await fileSystem.createDirectory(
      parentPath ?? _workspacePath,
      folderName,
    );
    await logger.info('workspace', 'directory_created', '已创建工作区目录');
    await scanFileTree();
    return result;
  }

  Future<String> renameEntry(String oldPath, String newName) async {
    _requireWorkspace();
    final safeOldPath = await fileSystem.validatePath(oldPath, mustExist: true);
    final newPath = await fileSystem.renameEntry(safeOldPath, newName);
    final oldPrefix = '$safeOldPath${p.separator}';
    for (final document in _documents) {
      if (document.path == safeOldPath || document.path.startsWith(oldPrefix)) {
        final oldDocumentId = document.id;
        final suffix = document.path.substring(safeOldPath.length);
        document.path = '$newPath$suffix';
        document.id = document.path;
        document.relativePath = p.relative(document.path, from: _workspacePath);
        document.fileName = p.basename(document.path);
        if (_activeDocumentId == oldDocumentId) {
          _activeDocumentId = document.id;
        }
        document.notifyListeners();
      }
    }
    await logger.info('workspace', 'entry_renamed', '已重命名工作区条目');
    await scanFileTree();
    return newPath;
  }

  Future<DeletionPreview> previewDeletion(String path) {
    return fileSystem.previewDeletion(path);
  }

  Future<IsolationResult> deleteEntry(
    String path, {
    bool discardUnsaved = false,
  }) async {
    _requireWorkspace();
    final safePath = await fileSystem.validatePath(path, mustExist: true);
    final affected = _documents
        .where((document) {
          return p.equals(document.path, safePath) ||
              p.isWithin(safePath, document.path);
        })
        .toList(growable: false);
    if (!discardUnsaved && affected.any((document) => document.isDirty)) {
      throw const CourierException('UNSAVED_CHANGES', '删除范围包含未保存文档');
    }

    final result = await fileSystem.moveToIsolation(safePath);
    for (final document in affected) {
      await closeDocument(document.id, discardUnsaved: true);
    }
    await logger.info('workspace', 'entry_isolated', '工作区条目已移至隔离区');
    await scanFileTree();
    return result;
  }

  Future<String> readFileContent(String filePath) async {
    return (await fileSystem.readTextFile(filePath)).content;
  }

  Future<void> openFile(String filePath) async {
    final safePath = await fileSystem.validatePath(filePath, mustExist: true);
    final existing = _documents
        .where((document) => document.path == safePath)
        .firstOrNull;
    if (existing != null) {
      _activeDocumentId = existing.id;
      notifyListeners();
      return;
    }

    final file = await fileSystem.readTextFile(safePath);
    final document = EditorDocument(
      id: safePath,
      path: safePath,
      relativePath: p.relative(safePath, from: _workspacePath),
      fileName: p.basename(safePath),
      content: file.content,
      savedContent: file.content,
      fingerprint: file.fingerprint,
    );
    document.addListener(notifyListeners);
    _documents.add(document);
    _activeDocumentId = document.id;
    notifyListeners();
  }

  void createUntitled() {
    _untitledCounter++;
    final count = _untitledCounter;
    final name = count == 1 ? '未命名.md' : '未命名 $count.md';
    final document = EditorDocument(
      id: IdGenerator.create('untitled'),
      path: '',
      relativePath: '',
      fileName: name,
      content: '',
      savedContent: '',
      untitled: true,
    );
    document.addListener(notifyListeners);
    _documents.add(document);
    _activeDocumentId = document.id;
    notifyListeners();
  }

  void setActiveDocument(String documentId) {
    if (_documents.any((document) => document.id == documentId)) {
      _activeDocumentId = documentId;
      notifyListeners();
    }
  }

  Future<bool> closeDocument(
    String documentId, {
    bool discardUnsaved = false,
  }) async {
    final document = _documents
        .where((item) => item.id == documentId)
        .firstOrNull;
    if (document == null) return true;
    if (document.isDirty && !discardUnsaved) return false;

    document.removeListener(notifyListeners);
    document.dispose();
    _documents.remove(document);
    if (_activeDocumentId == documentId) {
      _activeDocumentId = _documents.firstOrNull?.id;
    }
    notifyListeners();
    return true;
  }

  Future<bool> saveActiveDocument({bool force = false}) async {
    final document = activeDocument;
    if (document == null || document.untitled) return false;
    await saveDocument(document.id, force: force);
    return true;
  }

  Future<void> saveDocument(String documentId, {bool force = false}) async {
    final document = _documents
        .where((item) => item.id == documentId)
        .firstOrNull;
    if (document == null) {
      throw const CourierException('DOCUMENT_NOT_FOUND', '文档不存在');
    }
    if (document.untitled) {
      throw const CourierException('SAVE_AS_REQUIRED', '未命名文档需要另存为');
    }
    try {
      final fingerprint = await fileSystem.atomicWriteText(
        document.path,
        document.content,
        expectedFingerprint: document.fingerprint,
        force: force,
      );
      document.markSaved(fingerprint);
      await logger.info('workspace', 'file_saved', '工作区文件已保存');
    } on CourierException catch (error) {
      if (error.code == 'FILE_CHANGED_EXTERNALLY') {
        document.external = true;
        document.notifyListeners();
      }
      rethrow;
    }
  }

  Future<void> reloadDocument(String documentId) async {
    final document = _documents
        .where((item) => item.id == documentId)
        .firstOrNull;
    if (document == null || document.untitled) {
      throw const CourierException('DOCUMENT_NOT_FOUND', '文档不存在');
    }
    final file = await fileSystem.readTextFile(document.path);
    document.replaceFromDisk(file);
    notifyListeners();
  }

  Future<bool> saveAs(
    String documentId,
    String relativePath, {
    bool overwrite = false,
  }) async {
    final document = _documents
        .where((item) => item.id == documentId)
        .firstOrNull;
    if (document == null || _workspacePath.isEmpty) return false;
    final safeRelative = _validateRelativeSavePath(relativePath);
    final fullPath = await fileSystem.validatePath(
      p.join(_workspacePath, safeRelative),
    );
    if (_documents.any(
      (item) => !identical(item, document) && p.equals(item.path, fullPath),
    )) {
      throw const CourierException('DOCUMENT_ALREADY_OPEN', '目标文件已在另一个标签中打开');
    }
    if (!overwrite &&
        await FileSystemEntity.type(fullPath, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw const CourierException('ENTRY_EXISTS', '目标文件已存在');
    }
    final fingerprint = await fileSystem.atomicWriteText(
      fullPath,
      document.content,
      force: overwrite,
    );
    final oldDocumentId = document.id;
    document.id = fullPath;
    document.path = fullPath;
    document.relativePath = safeRelative;
    document.fileName = p.basename(safeRelative);
    document.untitled = false;
    if (_activeDocumentId == oldDocumentId) {
      _activeDocumentId = document.id;
    }
    document.markSaved(fingerprint);
    notifyListeners();
    await scanFileTree();
    return true;
  }

  Future<void> _saveWorkspacePreferences({
    List<String>? excludePatterns,
    bool? showHidden,
    Map<String, bool>? categoryFilter,
  }) async {
    _requireWorkspace();
    final current = configService.preferences;
    await configService.save(
      current.copyWith(
        excludePatterns: List<String>.from(excludePatterns ?? _excludePatterns),
        showHiddenFiles: showHidden ?? _showHidden,
        fileFilters: Map<String, bool>.from(categoryFilter ?? _categoryFilter),
      ),
    );
  }

  Future<void> _closeAllDocuments({required bool discardUnsaved}) async {
    final ids = _documents
        .map((document) => document.id)
        .toList(growable: false);
    for (final id in ids) {
      await closeDocument(id, discardUnsaved: discardUnsaved);
    }
  }

  List<String> _sanitizeExcludePatterns(List<String> patterns) {
    final values = patterns
        .map(_sanitizeExcludePattern)
        .toSet()
        .take(256)
        .toList(growable: false);
    if (!values.any((item) => item.toLowerCase() == '.courier')) {
      return ['.Courier', ...values];
    }
    return values;
  }

  String _sanitizeExcludePattern(String value) {
    final pattern = value.trim();
    if (pattern.isEmpty ||
        pattern.length > 128 ||
        pattern.contains(RegExp(r'[\x00-\x1f\\/]'))) {
      throw const CourierException('INVALID_FILTER', '排除规则无效');
    }
    return pattern;
  }

  String _validateRelativeSavePath(String value) {
    final normalized = p.normalize(value.trim());
    if (normalized.isEmpty ||
        normalized == '.' ||
        p.isAbsolute(normalized) ||
        normalized == '..' ||
        normalized.startsWith('..${p.separator}')) {
      throw const CourierException('INVALID_PATH', '另存为路径无效');
    }
    for (final segment in p.split(normalized)) {
      fileSystem.validateEntryName(segment);
    }
    return normalized;
  }

  bool _isExcluded(String name) {
    if (!_showHidden && name.startsWith('.')) return true;
    final lowerName = name.toLowerCase();
    for (final pattern in _excludePatterns) {
      final lowerPattern = pattern.toLowerCase();
      if (lowerPattern.contains('*') || lowerPattern.contains('?')) {
        if (_matchGlob(lowerName, lowerPattern)) return true;
      } else if (lowerName == lowerPattern) {
        return true;
      }
    }
    return false;
  }

  bool _matchGlob(String name, String pattern) {
    final buffer = StringBuffer('^');
    for (final rune in pattern.runes) {
      final character = String.fromCharCode(rune);
      if (character == '*') {
        buffer.write('.*');
      } else if (character == '?') {
        buffer.write('.');
      } else {
        buffer.write(RegExp.escape(character));
      }
    }
    buffer.write(r'$');
    return RegExp(buffer.toString()).hasMatch(name);
  }

  String _classifyFile(String name) {
    final extension = p.extension(name).toLowerCase();
    if ({'.md', '.markdown'}.contains(extension)) return 'md';
    if ({
      '.dart',
      '.go',
      '.js',
      '.ts',
      '.py',
      '.java',
      '.c',
      '.cpp',
      '.rs',
      '.rb',
      '.kt',
      '.swift',
    }.contains(extension)) {
      return 'code';
    }
    if ({'.json', '.yaml', '.yml', '.toml', '.xml'}.contains(extension)) {
      return 'json';
    }
    if ({
      '.png',
      '.jpg',
      '.jpeg',
      '.gif',
      '.webp',
      '.svg',
      '.ico',
      '.bmp',
    }.contains(extension)) {
      return 'image';
    }
    if ({'.zip', '.tar', '.gz', '.rar', '.7z'}.contains(extension)) {
      return 'archive';
    }
    if ({'.mp3', '.wav', '.flac', '.aac', '.ogg'}.contains(extension)) {
      return 'audio';
    }
    if ({'.mp4', '.avi', '.mkv', '.mov', '.webm'}.contains(extension)) {
      return 'video';
    }
    if ({'.txt', '.log', '.csv', '.ini', '.cfg'}.contains(extension)) {
      return 'text';
    }
    return 'other';
  }

  int _countFiles(List<FileTreeNode> nodes) {
    var count = 0;
    for (final node in nodes) {
      count += node.isDir ? _countFiles(node.children) : 1;
    }
    return count;
  }

  void _requireWorkspace() {
    if (_workspacePath.isEmpty) {
      throw const CourierException('WORKSPACE_REQUIRED', '需要先打开工作区');
    }
  }

  @override
  void dispose() {
    for (final document in _documents) {
      document.removeListener(notifyListeners);
      document.dispose();
    }
    _documents.clear();
    super.dispose();
  }
}
