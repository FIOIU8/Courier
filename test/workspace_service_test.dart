import 'dart:io';

import 'package:courier_flutter/services/app_logger.dart';
import 'package:courier_flutter/services/safe_file_system.dart';
import 'package:courier_flutter/services/workspace_config_service.dart';
import 'package:courier_flutter/services/workspace_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_fakes.dart';

void main() {
  late Directory workspace;
  late Directory alternateWorkspace;
  late WorkspaceService service;
  late SafeFileSystem fileSystem;
  late WorkspaceConfigService configService;
  late String resolvedWorkspace;
  late String resolvedAlternateWorkspace;
  var rejectAlternateWorkspace = false;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    workspace = await Directory.systemTemp.createTemp('courier-workspace-');
    alternateWorkspace = await Directory.systemTemp.createTemp(
      'courier-workspace-alt-',
    );
    resolvedWorkspace = await workspace.resolveSymbolicLinks();
    resolvedAlternateWorkspace = await alternateWorkspace
        .resolveSymbolicLinks();
    final logger = AppLogger();
    fileSystem = SafeFileSystem();
    configService = WorkspaceConfigService(logger: logger);
    service = WorkspaceService(
      fileSystem: fileSystem,
      configService: configService,
      logger: logger,
      onWorkspaceOpened: (path) async {
        if (rejectAlternateWorkspace &&
            p.equals(path, resolvedAlternateWorkspace)) {
          throw StateError('workspace binding rejected');
        }
      },
    );
    await service.openWorkspace(workspace.path);
  });

  tearDown(() async {
    service.dispose();
    if (await workspace.exists()) await workspace.delete(recursive: true);
    if (await alternateWorkspace.exists()) {
      await alternateWorkspace.delete(recursive: true);
    }
  });

  test('重命名已打开文件后保持活动文档', () async {
    final file = File(p.join(workspace.path, 'before.md'));
    await file.writeAsString('内容', flush: true);
    await service.openFile(file.path);

    final renamed = await service.renameEntry(file.path, 'after.md');
    expect(service.activeDocumentId, renamed);
    expect(service.activeDocument?.path, renamed);
    expect(service.activeDocument?.fileName, 'after.md');
  });

  test('另存为后同步活动文档标识', () async {
    service.createUntitled();
    final document = service.activeDocument!;
    final oldId = document.id;
    document.updateContent('新文档');

    final saved = await service.saveAs(
      oldId,
      p.join('notes', '..', 'draft.md'),
    );
    final expectedPath = p.join(workspace.path, 'draft.md');
    expect(saved, isTrue);
    expect(service.activeDocumentId, expectedPath);
    expect(service.activeDocument?.id, expectedPath);
    expect(await File(expectedPath).readAsString(), '新文档');
  });

  test('存在未保存文档时阻止切换工作区', () async {
    service.createUntitled();
    service.activeDocument!.updateContent('未保存内容');

    await expectLater(
      service.openWorkspace(alternateWorkspace.path),
      throwsCourierCode('UNSAVED_CHANGES'),
    );
    expect(service.workspacePath, resolvedWorkspace);
    expect(service.hasDirtyDocuments, isTrue);
  });

  test('下游绑定失败时恢复原工作区服务状态', () async {
    rejectAlternateWorkspace = true;

    await expectLater(
      service.openWorkspace(alternateWorkspace.path, persist: false),
      throwsStateError,
    );

    expect(service.workspacePath, resolvedWorkspace);
    expect(fileSystem.workspaceRoot, resolvedWorkspace);
    expect(configService.workspacePath, resolvedWorkspace);
  });

  test('文件被外部删除后保存进入冲突状态', () async {
    final file = File(p.join(workspace.path, 'external.md'));
    await file.writeAsString('磁盘内容', flush: true);
    await service.openFile(file.path);
    final document = service.activeDocument!;
    document.updateContent('编辑内容');
    await file.delete();

    await expectLater(
      service.saveDocument(document.id),
      throwsCourierCode('FILE_CHANGED_EXTERNALLY'),
    );
    expect(document.external, isTrue);
    expect(await file.exists(), isFalse);
  });

  test('删除含未保存文档的路径需要显式放弃并进入隔离区', () async {
    final directory = Directory(p.join(workspace.path, 'module'));
    await directory.create();
    final file = File(p.join(directory.path, 'plan.md'));
    await file.writeAsString('磁盘内容');
    await service.openFile(file.path);
    service.activeDocument!.updateContent('未保存内容');

    await expectLater(
      service.deleteEntry(directory.path),
      throwsCourierCode('UNSAVED_CHANGES'),
    );
    final result = await service.deleteEntry(
      directory.path,
      discardUnsaved: true,
    );
    expect(await directory.exists(), isFalse);
    expect(await Directory(result.isolationPath).exists(), isTrue);
    expect(service.documents, isEmpty);
  });
}
