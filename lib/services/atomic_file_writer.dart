// atomic_file_writer.dart - Recoverable same-directory file replacement.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'app_error.dart';

class AtomicFileWriter {
  static final Random _random = Random.secure();
  static final Map<String, Future<void>> _operations = {};

  static Future<void> writeString(
    File target,
    String contents, {
    int? maxBytes,
  }) {
    final bytes = utf8.encode(contents);
    if (maxBytes != null && bytes.length > maxBytes) {
      return Future<void>.error(
        const CourierException('CONTENT_TOO_LARGE', '写入内容超过允许的大小限制'),
      );
    }
    return _serialize(target, () => _writeBytes(target, bytes));
  }

  static Future<void> _writeBytes(File target, List<int> bytes) async {
    await target.parent.create(recursive: true);
    await _recoverUnlocked(target);

    final suffix = _uniqueSuffix();
    final temp = File('${target.path}.tmp-$suffix');
    final swap = File('${target.path}.swap-$suffix');
    final backup = File('${target.path}.bak');

    try {
      await temp.writeAsBytes(bytes, flush: true);
      if (!await target.exists()) {
        await temp.rename(target.path);
        return;
      }

      await target.rename(swap.path);
      try {
        await temp.rename(target.path);
      } catch (_) {
        if (!await target.exists() && await swap.exists()) {
          await swap.rename(target.path);
        }
        rethrow;
      }

      if (await backup.exists()) {
        await backup.delete();
      }
      if (await swap.exists()) {
        await swap.rename(backup.path);
      }
    } finally {
      if (await temp.exists()) {
        await temp.delete();
      }
    }
  }

  static Future<void> recover(File target) {
    return _serialize(target, () => _recoverUnlocked(target));
  }

  static Future<void> _recoverUnlocked(File target) async {
    final parent = target.parent;
    if (!await parent.exists()) return;

    final prefix = '${target.path}.swap-';
    final swaps = <File>[];
    await for (final entity in parent.list(followLinks: false)) {
      if (entity is File && entity.path.startsWith(prefix)) {
        swaps.add(entity);
      }
    }

    swaps.sort((a, b) => b.path.compareTo(a.path));
    final backup = File('${target.path}.bak');

    if (!await target.exists()) {
      if (swaps.isNotEmpty) {
        await swaps.first.rename(target.path);
        swaps.removeAt(0);
      } else if (await backup.exists()) {
        await backup.copy(target.path);
      }
    }

    for (final swap in swaps) {
      if (!await swap.exists()) continue;
      if (!await backup.exists()) {
        await swap.rename(backup.path);
      } else if (await swap.exists()) {
        await swap.delete();
      }
    }
  }

  static String _uniqueSuffix() {
    final now = DateTime.now().microsecondsSinceEpoch;
    final random = _random.nextInt(0x7fffffff);
    return '$now-$random';
  }

  static Future<void> _serialize(
    File target,
    Future<void> Function() operation,
  ) {
    final key = _operationKey(target.path);
    final previous = _operations[key] ?? Future<void>.value();
    late final Future<void> current;
    current = previous.catchError((Object _) {}).then((_) => operation());
    _operations[key] = current;
    unawaited(
      current.then<void>(
        (_) => _removeOperation(key, current),
        onError: (Object _, StackTrace _) => _removeOperation(key, current),
      ),
    );
    return current;
  }

  static void _removeOperation(String key, Future<void> operation) {
    if (identical(_operations[key], operation)) {
      _operations.remove(key);
    }
  }

  static String _operationKey(String path) {
    final absolute = File(path).absolute.path;
    return Platform.isWindows ? absolute.toLowerCase() : absolute;
  }

  AtomicFileWriter._();
}
