// workspace_service.dart — 工作区与文件系统服务（ChangeNotifier）
//
// 管理：工作区目录选择、Markdown 文件树扫描、文件读写、标签页状态。
// 所有文件系统操作通过 dart:io 直接访问（桌面端拥有完整文件系统权限）。
// 工作区路径通过 shared_preferences 持久化。
// 排除列表通过 shared_preferences 持久化，支持用户自定义。

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ============================================================
// 数据模型
// ============================================================

/// FileTreeNode — 文件树节点（目录或文件）。
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

/// EditorDocument — 编辑器中的单个文档标签页。
class EditorDocument extends ChangeNotifier {
  String id;
  String path;
  String relativePath;
  String fileName;
  String content;
  String savedContent;
  bool untitled;
  bool external;

  EditorDocument({
    required this.id,
    required this.path,
    required this.relativePath,
    required this.fileName,
    required this.content,
    required this.savedContent,
    this.untitled = false,
    this.external = false,
  });

  bool get isDirty => content != savedContent;

  void updateContent(String newContent) {
    content = newContent;
    notifyListeners();
  }

  void markSaved() {
    savedContent = content;
    notifyListeners();
  }
}

/// 拖拽载荷 — 文件树节点拖拽时传递的数据。
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
    if (name is! String || path is! String || relativePath is! String) return null;
    return FileDragPayload(name: name, path: path, relativePath: relativePath);
  }
}

// ============================================================
// WorkspaceService — 工作区服务
// ============================================================

/// 默认排除列表
const _defaultExcludes = [
  '.git',
  '.svn',
  '.hg',
  '.courier-*',
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

class WorkspaceService extends ChangeNotifier {
  static const _prefKey = 'workspace_path';
  static const _excludeKey = 'workspace_excludes';

  String _workspacePath = '';
  String _workspaceName = '';
  List<FileTreeNode> _fileTree = [];
  final List<EditorDocument> _documents = [];
  String? _activeDocumentId;
  int _untitledCounter = 0;
  bool _scanning = false;

  /// 排除列表（用户可自定义）
  List<String> _excludePatterns = List.from(_defaultExcludes);

  /// 是否显示隐藏文件（以 . 开头的文件）
  bool _showHidden = false;

  /// 文件分类过滤开关
  final Map<String, bool> _categoryFilter = {
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

  String get workspacePath => _workspacePath;
  String get workspaceName => _workspaceName;
  List<FileTreeNode> get fileTree => List.unmodifiable(_fileTree);
  List<EditorDocument> get documents => List.unmodifiable(_documents);
  String? get activeDocumentId => _activeDocumentId;
  bool get hasWorkspace => _workspacePath.isNotEmpty;
  bool get scanning => _scanning;
  List<String> get excludePatterns => List.unmodifiable(_excludePatterns);
  bool get showHidden => _showHidden;
  Map<String, bool> get categoryFilter => Map.unmodifiable(_categoryFilter);

  EditorDocument? get activeDocument {
    if (_activeDocumentId == null) return null;
    return _documents.where((d) => d.id == _activeDocumentId).firstOrNull;
  }

  /// 从持久化存储加载上次的工作区路径。
  Future<void> loadLastWorkspace() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_prefKey);
    // 加载排除列表
    final excludes = prefs.getStringList(_excludeKey);
    if (excludes != null && excludes.isNotEmpty) {
      _excludePatterns = excludes;
    }
    if (path != null && path.isNotEmpty && Directory(path).existsSync()) {
      await openWorkspace(path, persist: false);
    }
  }

  /// 通过文件选择器选取工作区目录。
  Future<void> pickWorkspace() async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择工作区文件夹',
    );
    if (result == null || result.isEmpty) return;
    await openWorkspace(result);
  }

  /// 打开指定路径的工作区。
  Future<void> openWorkspace(String path, {bool persist = true}) async {
    final dir = Directory(path);
    if (!dir.existsSync()) {
      debugPrint('[WorkspaceService] 目录不存在: $path');
      return;
    }

    // 关闭所有已打开的文档
    for (final doc in _documents) {
      doc.dispose();
    }
    _documents.clear();
    _activeDocumentId = null;

    _workspacePath = path;
    _workspaceName = p.basename(path);
    notifyListeners();

    await scanFileTree();

    if (persist) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, path);
    }
  }

  // ============================================================
  // 排除列表管理
  // ============================================================

  /// 更新排除列表
  Future<void> setExcludePatterns(List<String> patterns) async {
    _excludePatterns = patterns;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_excludeKey, patterns);
    if (_workspacePath.isNotEmpty) {
      await scanFileTree();
    }
  }

  /// 添加排除项
  Future<void> addExcludePattern(String pattern) async {
    if (pattern.trim().isEmpty || _excludePatterns.contains(pattern)) return;
    _excludePatterns = [..._excludePatterns, pattern.trim()];
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_excludeKey, _excludePatterns);
    notifyListeners();
    if (_workspacePath.isNotEmpty) await scanFileTree();
  }

  /// 移除排除项
  Future<void> removeExcludePattern(String pattern) async {
    _excludePatterns = _excludePatterns.where((p) => p != pattern).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_excludeKey, _excludePatterns);
    notifyListeners();
    if (_workspacePath.isNotEmpty) await scanFileTree();
  }

  /// 重置排除列表为默认值
  Future<void> resetExcludePatterns() async {
    _excludePatterns = List.from(_defaultExcludes);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_excludeKey, _excludePatterns);
    notifyListeners();
    if (_workspacePath.isNotEmpty) await scanFileTree();
  }

  /// 切换显示/隐藏隐藏文件
  void toggleShowHidden() {
    _showHidden = !_showHidden;
    notifyListeners();
    if (_workspacePath.isNotEmpty) scanFileTree();
  }

  /// 切换文件分类过滤
  void toggleCategoryFilter(String category, bool value) {
    _categoryFilter[category] = value;
    notifyListeners();
    if (_workspacePath.isNotEmpty) scanFileTree();
  }

  /// 判断名称是否被排除列表过滤
  bool _isExcluded(String name) {
    final lowerName = name.toLowerCase();
    for (final pattern in _excludePatterns) {
      final lowerPattern = pattern.toLowerCase();
      if (lowerPattern.contains('*')) {
        // 通配符匹配
        if (_matchGlob(lowerName, lowerPattern)) return true;
      } else if (lowerName == lowerPattern) {
        return true;
      } else if (lowerPattern.endsWith('-*') &&
          lowerName.startsWith(lowerPattern.substring(0, lowerPattern.length - 1))) {
        return true;
      }
    }
    // 隐藏文件
    if (!_showHidden && name.startsWith('.')) return true;
    return false;
  }

  /// 简单的 glob 匹配
  bool _matchGlob(String name, String pattern) {
    // 将 glob 模式转为正则
    final regexPattern = pattern
        .replaceAll('.', r'\.')
        .replaceAll('*', '.*')
        .replaceAll('?', '.');
    try {
      return RegExp('^$regexPattern\$').hasMatch(name);
    } catch (_) {
      return false;
    }
  }

  /// 文件分类
  String _classifyFile(String name) {
    final ext = p.extension(name).toLowerCase();
    if ({'.md', '.markdown'}.contains(ext)) return 'md';
    if ({'.dart', '.go', '.js', '.ts', '.py', '.java', '.c', '.cpp', '.rs', '.rb', '.kt', '.swift'}.contains(ext)) return 'code';
    if ({'.json', '.yaml', '.yml', '.toml', '.xml'}.contains(ext)) return 'json';
    if ({'.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg', '.ico', '.bmp'}.contains(ext)) return 'image';
    if ({'.zip', '.tar', '.gz', '.rar', '.7z'}.contains(ext)) return 'archive';
    if ({'.mp3', '.wav', '.flac', '.aac', '.ogg'}.contains(ext)) return 'audio';
    if ({'.mp4', '.avi', '.mkv', '.mov', '.webm'}.contains(ext)) return 'video';
    if ({'.txt', '.log', '.csv', '.ini', '.cfg'}.contains(ext)) return 'text';
    return 'other';
  }

  /// 扫描工作区中的 Markdown 文件，构建文件树。
  Future<void> scanFileTree() async {
    if (_workspacePath.isEmpty) return;
    _scanning = true;
    notifyListeners();

    try {
      _fileTree = await _scanDirectory(_workspacePath, 0);
    } catch (e) {
      debugPrint('[WorkspaceService] 扫描文件树失败: $e');
    } finally {
      _scanning = false;
      notifyListeners();
    }
  }

  /// 递归扫描目录，返回子节点列表。
  /// 应用排除列表过滤。
  Future<List<FileTreeNode>> _scanDirectory(String dirPath, int level) async {
    if (level > 8) return []; // 深度限制

    final dir = Directory(dirPath);
    final entities = await dir.list().toList();
    entities.sort((a, b) {
      // 目录优先，再按名称排序
      final aDir = a is Directory;
      final bDir = b is Directory;
      if (aDir != bDir) return aDir ? -1 : 1;
      return p.basename(a.path).compareTo(p.basename(b.path));
    });

    final nodes = <FileTreeNode>[];
    for (final entity in entities) {
      final name = p.basename(entity.path);

      // 应用排除列表
      if (_isExcluded(name)) continue;

      // 跳过符号链接
      final stat = await entity.stat();
      if (stat.type == FileSystemEntityType.link) continue;

      final relativePath = _workspacePath.isNotEmpty
          ? p.relative(entity.path, from: _workspacePath)
          : name;

      if (entity is Directory) {
        final children = await _scanDirectory(entity.path, level + 1);
        // 如果目录有子节点，或者层级较浅，则保留
        if (children.isNotEmpty || level < 3) {
          nodes.add(FileTreeNode(
            name: name,
            path: entity.path,
            relativePath: relativePath,
            isDir: true,
            children: children,
            level: level,
          ));
        }
      } else if (entity is File) {
        // 应用分类过滤
        final category = _classifyFile(name);
        if (_categoryFilter[category] != false) {
          nodes.add(FileTreeNode(
            name: name,
            path: entity.path,
            relativePath: relativePath,
            isDir: false,
            level: level,
          ));
        }
      }
    }
    return nodes;
  }

  // ============================================================
  // 文件操作
  // ============================================================

  /// 在指定目录中创建新文件
  Future<String> createFile(String fileName, {String? parentPath}) async {
    final parent = parentPath ?? _workspacePath;
    final trimmed = fileName.trim();
    if (trimmed.isEmpty) throw ArgumentError('文件名不能为空');

    final fullPath = p.join(parent, trimmed);
    final file = File(fullPath);
    if (await file.exists()) {
      throw FileSystemException('文件已存在', fullPath);
    }
    await file.create();
    await scanFileTree();
    return fullPath;
  }

  /// 在指定目录中创建新文件夹
  Future<String> createFolder(String folderName, {String? parentPath}) async {
    final parent = parentPath ?? _workspacePath;
    final trimmed = folderName.trim();
    if (trimmed.isEmpty) throw ArgumentError('文件夹名不能为空');

    final fullPath = p.join(parent, trimmed);
    final dir = Directory(fullPath);
    if (await dir.exists()) {
      throw FileSystemException('文件夹已存在', fullPath);
    }
    await dir.create();
    await scanFileTree();
    return fullPath;
  }

  /// 重命名文件或文件夹
  Future<String> renameEntry(String oldPath, String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) throw ArgumentError('新名称不能为空');

    final dir = p.dirname(oldPath);
    final newPath = p.join(dir, trimmed);

    final oldEntity = FileSystemEntity.typeSync(oldPath) == FileSystemEntityType.directory
        ? Directory(oldPath)
        : File(oldPath);

    if (oldEntity is Directory) {
      await oldEntity.rename(newPath);
    } else if (oldEntity is File) {
      await oldEntity.rename(newPath);
    }

    // 如果重命名的是当前打开的文档，更新路径
    final doc = _documents.where((d) => d.path == oldPath).firstOrNull;
    if (doc != null) {
      doc.path = newPath;
      doc.relativePath = p.relative(newPath, from: _workspacePath);
      doc.fileName = trimmed;
      doc.notifyListeners();
    }

    await scanFileTree();
    return newPath;
  }

  /// 删除文件或文件夹
  Future<void> deleteEntry(String path) async {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.directory) {
      final dir = Directory(path);
      await dir.delete(recursive: true);
    } else if (type == FileSystemEntityType.file) {
      await File(path).delete();
    }

    // 如果删除的是当前打开的文档，关闭它
    final doc = _documents.where((d) => d.path == path).firstOrNull;
    if (doc != null) {
      await closeDocument(doc.id);
    }

    await scanFileTree();
  }

  /// 读取文件内容（不打开标签页）。
  Future<String> readFileContent(String filePath) async {
    final file = File(filePath);
    return await file.readAsString();
  }

  /// 读取文件内容并作为新标签页打开。
  /// 如果文件已打开，则激活对应标签。
  Future<void> openFile(String filePath) async {
    // 检查是否已打开
    final existing = _documents.where((d) => d.path == filePath).firstOrNull;
    if (existing != null) {
      _activeDocumentId = existing.id;
      notifyListeners();
      return;
    }

    try {
      final file = File(filePath);
      final content = await file.readAsString();
      final relativePath = _workspacePath.isNotEmpty
          ? p.relative(filePath, from: _workspacePath)
          : filePath;
      final doc = EditorDocument(
        id: filePath,
        path: filePath,
        relativePath: relativePath,
        fileName: p.basename(filePath),
        content: content,
        savedContent: content,
      );
      doc.addListener(notifyListeners);
      _documents.add(doc);
      _activeDocumentId = doc.id;
      notifyListeners();
    } catch (e) {
      debugPrint('[WorkspaceService] 打开文件失败: $e');
      rethrow;
    }
  }

  /// 创建新的未命名文档。
  void createUntitled() {
    _untitledCounter++;
    final count = _untitledCounter;
    final name = count == 1 ? '未命名.md' : '未命名 $count.md';
    final doc = EditorDocument(
      id: 'untitled-$count-${DateTime.now().millisecondsSinceEpoch}',
      path: '',
      relativePath: '',
      fileName: name,
      content: '',
      savedContent: '',
      untitled: true,
    );
    doc.addListener(notifyListeners);
    _documents.add(doc);
    _activeDocumentId = doc.id;
    notifyListeners();
  }

  /// 激活指定文档标签。
  void setActiveDocument(String docId) {
    if (_documents.any((d) => d.id == docId)) {
      _activeDocumentId = docId;
      notifyListeners();
    }
  }

  /// 关闭文档标签。
  Future<bool> closeDocument(String docId) async {
    final doc = _documents.where((d) => d.id == docId).firstOrNull;
    if (doc == null) return true;

    doc.removeListener(notifyListeners);
    doc.dispose();
    _documents.remove(doc);

    if (_activeDocumentId == docId) {
      final index = _documents.isNotEmpty ? 0 : null;
      _activeDocumentId =
          index != null ? _documents[index].id : null;
    }
    notifyListeners();
    return true;
  }

  /// 保存当前激活的文档。
  Future<bool> saveActiveDocument() async {
    final doc = activeDocument;
    if (doc == null) return false;

    if (doc.untitled) {
      return false;
    }

    try {
      final file = File(doc.path);
      await file.writeAsString(doc.content);
      doc.markSaved();
      return true;
    } catch (e) {
      debugPrint('[WorkspaceService] 保存文件失败: $e');
      rethrow;
    }
  }

  /// 将未命名文档另存为工作区内的新文件。
  Future<bool> saveAs(String docId, String fileName) async {
    final doc = _documents.where((d) => d.id == docId).firstOrNull;
    if (doc == null || _workspacePath.isEmpty) return false;

    final trimmed = fileName.trim();
    if (trimmed.isEmpty) return false;

    try {
      final fullPath = p.join(_workspacePath, trimmed);
      final file = File(fullPath);
      await file.writeAsString(doc.content);

      doc.path = fullPath;
      doc.relativePath = trimmed;
      doc.fileName = trimmed;
      doc.untitled = false;
      doc.markSaved();
      notifyListeners();

      await scanFileTree();
      return true;
    } catch (e) {
      debugPrint('[WorkspaceService] 另存为失败: $e');
      rethrow;
    }
  }

  @override
  void dispose() {
    for (final doc in _documents) {
      doc.removeListener(notifyListeners);
      doc.dispose();
    }
    _documents.clear();
    super.dispose();
  }
}
