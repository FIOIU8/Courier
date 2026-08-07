// safe_file_system.dart - Workspace-bounded file operations.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'app_error.dart';
import 'atomic_file_writer.dart';
import 'workspace_directory_guard.dart';

class FileFingerprint {
  final int byteLength;
  final DateTime modifiedAt;
  final String sha256Digest;

  const FileFingerprint({
    required this.byteLength,
    required this.modifiedAt,
    required this.sha256Digest,
  });

  bool matches(FileFingerprint other) =>
      byteLength == other.byteLength &&
      modifiedAt.toUtc() == other.modifiedAt.toUtc() &&
      sha256Digest == other.sha256Digest;
}

class SafeTextFile {
  final String path;
  final String content;
  final FileFingerprint fingerprint;

  const SafeTextFile({
    required this.path,
    required this.content,
    required this.fingerprint,
  });
}

class DeletionPreview {
  final String relativePath;
  final int fileCount;
  final int directoryCount;
  final int totalBytes;

  const DeletionPreview({
    required this.relativePath,
    required this.fileCount,
    required this.directoryCount,
    required this.totalBytes,
  });
}

class IsolationResult {
  final String originalRelativePath;
  final String isolationPath;

  const IsolationResult({
    required this.originalRelativePath,
    required this.isolationPath,
  });
}

class SafeFileSystem {
  static const int maxTextFileBytes = 5 * 1024 * 1024;
  static const int maxDeletionEntries = 100000;

  final Random _random = Random.secure();
  String? _workspaceRoot;
  String? _comparisonRoot;

  String? get workspaceRoot => _workspaceRoot;

  Future<String> resolveWorkspace(String path) {
    return WorkspaceDirectoryGuard.resolveWorkspaceRoot(path);
  }

  Future<String> bindWorkspace(String path) async {
    final resolved = await resolveWorkspace(path);
    _workspaceRoot = resolved;
    _comparisonRoot = _comparisonPath(resolved);
    return resolved;
  }

  Future<String> validatePath(
    String path, {
    bool mustExist = false,
    bool allowRoot = false,
    bool allowCourierInternal = false,
  }) async {
    final root = _requireRoot();
    final candidate = p.normalize(
      p.isAbsolute(path) ? path : p.join(root, path),
    );
    _ensureLexicallyWithin(candidate, allowRoot: allowRoot);

    final resolved = await _resolveSafely(candidate, mustExist: mustExist);
    _ensureResolvedWithin(resolved, allowRoot: allowRoot);
    if (!allowCourierInternal && _isCourierInternal(resolved)) {
      throw const CourierException('PROTECTED_PATH', '应用工作区元数据目录不允许通过编辑器修改');
    }
    return resolved;
  }

  Future<List<FileSystemEntity>> listDirectory(String path) async {
    final safePath = await validatePath(path, mustExist: true, allowRoot: true);
    final type = await FileSystemEntity.type(safePath, followLinks: false);
    if (type != FileSystemEntityType.directory) {
      throw const CourierException('NOT_A_DIRECTORY', '目标不是目录');
    }
    return Directory(safePath).list(followLinks: false).toList();
  }

  Future<SafeTextFile> readTextFile(String path) async {
    final safePath = await validatePath(path, mustExist: true);
    final type = await FileSystemEntity.type(safePath, followLinks: false);
    if (type != FileSystemEntityType.file) {
      throw const CourierException('NOT_A_FILE', '目标不是普通文件');
    }
    final file = File(safePath);
    final length = await file.length();
    if (length > maxTextFileBytes) {
      throw const CourierException('FILE_TOO_LARGE', '文件超过 5 MiB，已阻止在编辑器中打开');
    }
    final bytes = await file.readAsBytes();
    if (bytes.any((byte) => byte == 0)) {
      throw const CourierException('BINARY_FILE', '检测到二进制内容，不能作为文本文件打开');
    }

    late final String content;
    try {
      content = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw const CourierException('UNSUPPORTED_ENCODING', '文件不是有效的 UTF-8 文本');
    }
    final stat = await file.stat();
    return SafeTextFile(
      path: safePath,
      content: content.startsWith('\ufeff') ? content.substring(1) : content,
      fingerprint: FileFingerprint(
        byteLength: bytes.length,
        modifiedAt: stat.modified,
        sha256Digest: sha256.convert(bytes).toString(),
      ),
    );
  }

  Future<FileFingerprint> atomicWriteText(
    String path,
    String content, {
    FileFingerprint? expectedFingerprint,
    bool force = false,
  }) async {
    final safePath = await validatePath(path);
    final parentPath = await validatePath(
      p.dirname(safePath),
      mustExist: true,
      allowRoot: true,
    );
    final parentType = await FileSystemEntity.type(
      parentPath,
      followLinks: false,
    );
    if (parentType != FileSystemEntityType.directory) {
      throw const CourierException('PARENT_NOT_FOUND', '目标父目录不存在');
    }

    final file = File(safePath);
    if (expectedFingerprint != null && !force) {
      if (!await file.exists()) {
        throw const CourierException(
          'FILE_CHANGED_EXTERNALLY',
          '文件已被其他程序修改，请重新加载或确认覆盖',
        );
      }
      final current = await _fingerprint(file);
      if (!expectedFingerprint.matches(current)) {
        throw const CourierException(
          'FILE_CHANGED_EXTERNALLY',
          '文件已被其他程序修改，请重新加载或确认覆盖',
        );
      }
    }

    await AtomicFileWriter.writeString(
      file,
      content,
      maxBytes: maxTextFileBytes,
    );
    return _fingerprint(file);
  }

  Future<String> createFile(String parentPath, String fileName) async {
    final name = validateEntryName(fileName);
    final parent = await validatePath(
      parentPath,
      mustExist: true,
      allowRoot: true,
    );
    if (await FileSystemEntity.type(parent, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const CourierException('NOT_A_DIRECTORY', '目标父路径不是目录');
    }
    final target = await validatePath(p.join(parent, name));
    if (await FileSystemEntity.type(target, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const CourierException('ENTRY_EXISTS', '同名文件或文件夹已存在');
    }
    final file = File(target);
    await file.create(exclusive: true);
    return target;
  }

  Future<String> createDirectory(
    String parentPath,
    String directoryName,
  ) async {
    final name = validateEntryName(directoryName);
    final parent = await validatePath(
      parentPath,
      mustExist: true,
      allowRoot: true,
    );
    if (await FileSystemEntity.type(parent, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const CourierException('NOT_A_DIRECTORY', '目标父路径不是目录');
    }
    final target = await validatePath(p.join(parent, name));
    if (await FileSystemEntity.type(target, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const CourierException('ENTRY_EXISTS', '同名文件或文件夹已存在');
    }
    await Directory(target).create();
    return target;
  }

  Future<String> renameEntry(String oldPath, String newName) async {
    final source = await validatePath(oldPath, mustExist: true);
    final name = validateEntryName(newName);
    final target = await validatePath(p.join(p.dirname(source), name));
    if (await FileSystemEntity.type(target, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const CourierException('ENTRY_EXISTS', '同名文件或文件夹已存在');
    }
    final type = await FileSystemEntity.type(source, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      return (await Directory(source).rename(target)).path;
    }
    if (type == FileSystemEntityType.file) {
      return (await File(source).rename(target)).path;
    }
    throw const CourierException('UNSUPPORTED_ENTRY', '目标类型不受支持');
  }

  Future<DeletionPreview> previewDeletion(String path) async {
    final target = await validatePath(path, mustExist: true);
    final relative = p.relative(target, from: _requireRoot());
    var fileCount = 0;
    var directoryCount = 0;
    var totalBytes = 0;
    var entries = 0;

    Future<void> visit(String currentPath) async {
      entries++;
      if (entries > maxDeletionEntries) {
        throw const CourierException('DELETE_SCOPE_TOO_LARGE', '删除范围超过安全检查上限');
      }
      final type = await FileSystemEntity.type(currentPath, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw const CourierException('LINK_NOT_ALLOWED', '删除范围包含符号链接，操作已阻止');
      }
      if (type == FileSystemEntityType.file) {
        fileCount++;
        totalBytes += await File(currentPath).length();
        return;
      }
      if (type == FileSystemEntityType.directory) {
        directoryCount++;
        await for (final entity in Directory(
          currentPath,
        ).list(followLinks: false)) {
          await visit(entity.path);
        }
      }
    }

    await visit(target);
    return DeletionPreview(
      relativePath: relative,
      fileCount: fileCount,
      directoryCount: directoryCount,
      totalBytes: totalBytes,
    );
  }

  Future<IsolationResult> moveToIsolation(String path) async {
    final root = _requireRoot();
    final target = await validatePath(path, mustExist: true);
    final relative = p.relative(target, from: root);
    final trashRoot = await WorkspaceDirectoryGuard.ensureDirectory(
      root,
      const ['.Courier', 'trash'],
    );

    final suffix =
        '${DateTime.now().toUtc().microsecondsSinceEpoch}'
        '-${_random.nextInt(0x7fffffff)}';
    final destination = p.join(trashRoot.path, '$suffix-${p.basename(target)}');
    final type = await FileSystemEntity.type(target, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await Directory(target).rename(destination);
    } else if (type == FileSystemEntityType.file) {
      await File(target).rename(destination);
    } else {
      throw const CourierException('UNSUPPORTED_ENTRY', '目标类型不受支持');
    }

    final metadata = File('$destination.courier-trash.json');
    await AtomicFileWriter.writeString(
      metadata,
      '${jsonEncode({'originalRelativePath': relative, 'movedAt': DateTime.now().toUtc().toIso8601String()})}\n',
      maxBytes: 16 * 1024,
    );
    return IsolationResult(
      originalRelativePath: relative,
      isolationPath: destination,
    );
  }

  String validateEntryName(String value) {
    final name = value.trim();
    if (name.isEmpty || name == '.' || name == '..') {
      throw const CourierException('INVALID_NAME', '名称不能为空或使用保留路径');
    }
    if (name.length > 255 ||
        name.contains(RegExp(r'[\x00-\x1f\\/:*?"<>|]')) ||
        name.endsWith('.') ||
        name.endsWith(' ')) {
      throw const CourierException('INVALID_NAME', '名称包含不允许的字符');
    }
    final stem = name.split('.').first.toUpperCase();
    final reserved = RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$');
    if (reserved.hasMatch(stem)) {
      throw const CourierException('INVALID_NAME', '名称为操作系统保留名称');
    }
    return name;
  }

  Future<FileFingerprint> _fingerprint(File file) async {
    final bytes = await file.readAsBytes();
    final stat = await file.stat();
    return FileFingerprint(
      byteLength: bytes.length,
      modifiedAt: stat.modified,
      sha256Digest: sha256.convert(bytes).toString(),
    );
  }

  Future<String> _resolveSafely(
    String candidate, {
    required bool mustExist,
  }) async {
    var ancestor = candidate;
    final tail = <String>[];
    var type = await FileSystemEntity.type(ancestor, followLinks: false);
    while (type == FileSystemEntityType.notFound) {
      final parent = p.dirname(ancestor);
      if (parent == ancestor) break;
      tail.insert(0, p.basename(ancestor));
      ancestor = parent;
      type = await FileSystemEntity.type(ancestor, followLinks: false);
    }

    if (type == FileSystemEntityType.notFound) {
      throw const CourierException('PARENT_NOT_FOUND', '目标父目录不存在');
    }
    if (mustExist && tail.isNotEmpty) {
      throw const CourierException('ENTRY_NOT_FOUND', '目标不存在');
    }
    if (type == FileSystemEntityType.link) {
      throw const CourierException('LINK_NOT_ALLOWED', '符号链接不允许作为文件操作目标');
    }

    return p.normalize(p.joinAll([ancestor, ...tail]));
  }

  void _ensureLexicallyWithin(String candidate, {required bool allowRoot}) {
    _ensureWithin(candidate, allowRoot: allowRoot, resolved: false);
  }

  void _ensureResolvedWithin(String candidate, {required bool allowRoot}) {
    _ensureWithin(candidate, allowRoot: allowRoot, resolved: true);
  }

  void _ensureWithin(
    String candidate, {
    required bool allowRoot,
    required bool resolved,
  }) {
    final root = _comparisonRoot;
    if (root == null) {
      throw const CourierException('WORKSPACE_REQUIRED', '需要先打开工作区');
    }
    final compared = _comparisonPath(candidate);
    final inside =
        compared == root || compared.startsWith('$root${p.separator}');
    if (!inside || (!allowRoot && compared == root)) {
      throw CourierException(
        resolved ? 'PATH_ESCAPES_WORKSPACE' : 'PATH_TRAVERSAL',
        '文件操作目标不在当前工作区允许范围内',
      );
    }
  }

  bool _isCourierInternal(String path) {
    final relative = p.relative(path, from: _requireRoot());
    if (relative == '.') return false;
    final first = p.split(relative).first;
    return Platform.isWindows
        ? first.toLowerCase() == '.courier'
        : first == '.Courier';
  }

  String _comparisonPath(String value) {
    final normalized = p.normalize(p.absolute(value));
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  String _requireRoot() {
    final root = _workspaceRoot;
    if (root == null) {
      throw const CourierException('WORKSPACE_REQUIRED', '需要先打开工作区');
    }
    return root;
  }
}
