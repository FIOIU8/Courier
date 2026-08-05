// workspace_directory_guard.dart - Safe creation of Courier metadata paths.

import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_error.dart';

class WorkspaceDirectoryGuard {
  static Future<String> resolveWorkspaceRoot(String workspacePath) async {
    final directory = Directory(workspacePath);
    if (!await directory.exists()) {
      throw const CourierException('WORKSPACE_NOT_FOUND', '工作区目录不存在');
    }
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.link) {
      throw const CourierException(
        'WORKSPACE_LINK_NOT_ALLOWED',
        '工作区根目录不能是符号链接',
      );
    }
    if (type != FileSystemEntityType.directory) {
      throw const CourierException('WORKSPACE_NOT_FOUND', '工作区路径不是目录');
    }
    return p.normalize(await directory.resolveSymbolicLinks());
  }

  static Future<Directory> ensureDirectory(
    String workspacePath,
    List<String> relativeSegments,
  ) async {
    final root = await resolveWorkspaceRoot(workspacePath);
    var current = root;
    for (final segment in relativeSegments) {
      if (segment.isEmpty ||
          segment == '.' ||
          segment == '..' ||
          p.basename(segment) != segment) {
        throw const CourierException('INVALID_INTERNAL_PATH', '应用内部目录路径无效');
      }

      final candidate = p.join(current, segment);
      var type = await FileSystemEntity.type(candidate, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        await Directory(candidate).create();
        type = await FileSystemEntity.type(candidate, followLinks: false);
      }
      if (type == FileSystemEntityType.link) {
        throw const CourierException(
          'COURIER_DIRECTORY_UNSAFE',
          '应用元数据目录不能是符号链接',
        );
      }
      if (type != FileSystemEntityType.directory) {
        throw const CourierException('COURIER_DIRECTORY_UNSAFE', '应用元数据路径不是目录');
      }

      final resolved = p.normalize(
        await Directory(candidate).resolveSymbolicLinks(),
      );
      if (!_isWithin(root, resolved)) {
        throw const CourierException(
          'COURIER_DIRECTORY_UNSAFE',
          '应用元数据目录超出工作区边界',
        );
      }
      current = resolved;
    }
    return Directory(current);
  }

  static bool _isWithin(String root, String candidate) {
    final comparedRoot = _comparisonPath(root);
    final comparedCandidate = _comparisonPath(candidate);
    return comparedCandidate == comparedRoot ||
        comparedCandidate.startsWith('$comparedRoot${p.separator}');
  }

  static String _comparisonPath(String value) {
    final normalized = p.normalize(p.absolute(value));
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  WorkspaceDirectoryGuard._();
}
