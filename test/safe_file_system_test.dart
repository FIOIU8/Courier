import 'dart:convert';
import 'dart:io';

import 'package:courier_flutter/services/atomic_file_writer.dart';
import 'package:courier_flutter/services/safe_file_system.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/test_fakes.dart';

void main() {
  late Directory workspace;
  late SafeFileSystem fileSystem;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('courier-safe-fs-');
    fileSystem = SafeFileSystem();
    await fileSystem.bindWorkspace(workspace.path);
  });

  tearDown(() async {
    if (await workspace.exists()) {
      await workspace.delete(recursive: true);
    }
  });

  test('拒绝工作区外路径和应用元数据路径', () async {
    await expectLater(
      fileSystem.validatePath(p.join('..', 'outside.txt')),
      throwsCourierCode('PATH_TRAVERSAL'),
    );
    await expectLater(
      fileSystem.validatePath(p.join('.Courier', 'prefs.json')),
      throwsCourierCode('PROTECTED_PATH'),
    );
  });

  test('只读取受限大小的 UTF-8 文本', () async {
    final binary = File(p.join(workspace.path, 'binary.dat'));
    await binary.writeAsBytes([1, 0, 2], flush: true);
    await expectLater(
      fileSystem.readTextFile(binary.path),
      throwsCourierCode('BINARY_FILE'),
    );

    final invalidUtf8 = File(p.join(workspace.path, 'invalid.txt'));
    await invalidUtf8.writeAsBytes([0xff, 0xfe, 0xfd], flush: true);
    await expectLater(
      fileSystem.readTextFile(invalidUtf8.path),
      throwsCourierCode('UNSUPPORTED_ENCODING'),
    );

    final bom = File(p.join(workspace.path, 'bom.txt'));
    await bom.writeAsBytes([...utf8.encode('\ufeff'), ...utf8.encode('正文')]);
    final text = await fileSystem.readTextFile(bom.path);
    expect(text.content, '正文');
  });

  test('原子保存检测外部修改和外部删除', () async {
    final file = File(p.join(workspace.path, 'document.md'));
    await file.writeAsString('初始内容', flush: true);
    final opened = await fileSystem.readTextFile(file.path);

    await file.writeAsString('外部修改', flush: true);
    await expectLater(
      fileSystem.atomicWriteText(
        file.path,
        '编辑器内容',
        expectedFingerprint: opened.fingerprint,
      ),
      throwsCourierCode('FILE_CHANGED_EXTERNALLY'),
    );

    await file.delete();
    await expectLater(
      fileSystem.atomicWriteText(
        file.path,
        '编辑器内容',
        expectedFingerprint: opened.fingerprint,
      ),
      throwsCourierCode('FILE_CHANGED_EXTERNALLY'),
    );

    await fileSystem.atomicWriteText(
      file.path,
      '确认覆盖',
      expectedFingerprint: opened.fingerprint,
      force: true,
    );
    expect(await file.readAsString(), '确认覆盖');
  });

  test('同一目标的并发原子写入保持文件完整', () async {
    final file = File(p.join(workspace.path, 'concurrent.json'));
    final values = List<String>.generate(
      20,
      (index) => jsonEncode({
        'write': index,
        'payload': List<String>.filled(index + 1, 'x').join(),
      }),
      growable: false,
    );
    await Future.wait(
      values.map((value) => AtomicFileWriter.writeString(file, value)),
    );

    final content = await file.readAsString();
    expect(values, contains(content));
    final leftovers = await file.parent
        .list()
        .where((entity) => entity.path.contains('concurrent.json.swap-'))
        .toList();
    expect(leftovers, isEmpty);
  });

  test('删除预览统计范围并移动到隔离区', () async {
    final target = Directory(p.join(workspace.path, 'remove-me'));
    final nested = Directory(p.join(target.path, 'nested'));
    await nested.create(recursive: true);
    await File(p.join(target.path, 'one.txt')).writeAsString('1234');
    await File(p.join(nested.path, 'two.txt')).writeAsString('56789');

    final preview = await fileSystem.previewDeletion(target.path);
    expect(preview.relativePath, 'remove-me');
    expect(preview.fileCount, 2);
    expect(preview.directoryCount, 2);
    expect(preview.totalBytes, 9);

    final result = await fileSystem.moveToIsolation(target.path);
    expect(await target.exists(), isFalse);
    expect(await Directory(result.isolationPath).exists(), isTrue);
    expect(
      p.isWithin(
        p.join(workspace.path, '.Courier', 'trash'),
        result.isolationPath,
      ),
      isTrue,
    );
    expect(
      await File('${result.isolationPath}.courier-trash.json').exists(),
      isTrue,
    );
  });

  test('拒绝无效名称和非目录父路径', () async {
    expect(
      () => fileSystem.validateEntryName('CON.txt'),
      throwsCourierCode('INVALID_NAME'),
    );
    final parentFile = File(p.join(workspace.path, 'parent.txt'));
    await parentFile.writeAsString('content');
    await expectLater(
      fileSystem.createFile(parentFile.path, 'child.txt'),
      throwsCourierCode('NOT_A_DIRECTORY'),
    );
  });
}
