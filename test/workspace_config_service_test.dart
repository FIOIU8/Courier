import 'dart:convert';
import 'dart:io';

import 'package:courier_flutter/services/app_logger.dart';
import 'package:courier_flutter/services/workspace_config_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/test_fakes.dart';

void main() {
  late Directory workspace;
  late AppLogger logger;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('courier-config-');
    logger = AppLogger();
  });

  tearDown(() async {
    if (await workspace.exists()) {
      await workspace.delete(recursive: true);
    }
  });

  test('创建并重新加载版本化工作区设置', () async {
    final service = WorkspaceConfigService(logger: logger);
    final defaults = await service.bindWorkspace(workspace.path);
    expect(defaults.schemaVersion, WorkspacePreferences.currentSchemaVersion);
    expect(await service.courierDirectory.exists(), isTrue);
    expect(
      await Directory(p.join(service.courierDirectory.path, 'tasks')).exists(),
      isTrue,
    );

    final changed = defaults.copyWith(
      showHiddenFiles: true,
      fileFilters: {...defaults.fileFilters, 'image': false},
      excludePatterns: [...defaults.excludePatterns, '*.cache'],
    );
    await service.save(changed);

    final reloaded = WorkspaceConfigService(logger: logger);
    final preferences = await reloaded.bindWorkspace(workspace.path);
    expect(preferences.showHiddenFiles, isTrue);
    expect(preferences.fileFilters['image'], isFalse);
    expect(preferences.excludePatterns, contains('*.cache'));
  });

  test('更高版本配置以只读默认设置打开且不覆盖原文件', () async {
    final courier = Directory(p.join(workspace.path, '.Courier'));
    await courier.create();
    final preferencesFile = File(p.join(courier.path, 'prefs.json'));
    final original = jsonEncode({
      'schemaVersion': WorkspacePreferences.currentSchemaVersion + 1,
      'fileFilters': const <String, bool>{},
      'excludePatterns': const <String>[],
      'showHiddenFiles': true,
      'editor': const <String, dynamic>{},
      'taskQueue': const <String, dynamic>{},
    });
    await preferencesFile.writeAsString(original, flush: true);

    final service = WorkspaceConfigService(logger: logger);
    final preferences = await service.bindWorkspace(workspace.path);
    expect(service.readOnly, isTrue);
    expect(preferences.showHiddenFiles, isFalse);
    await expectLater(
      service.save(preferences),
      throwsCourierCode('CONFIG_READ_ONLY'),
    );
    expect(await preferencesFile.readAsString(), original);
  });

  test('损坏配置保留原文件并恢复先前绑定状态', () async {
    final first = await Directory.systemTemp.createTemp(
      'courier-config-first-',
    );
    addTearDown(() async {
      if (await first.exists()) await first.delete(recursive: true);
    });
    final service = WorkspaceConfigService(logger: logger);
    await service.bindWorkspace(first.path);

    final courier = Directory(p.join(workspace.path, '.Courier'));
    await courier.create();
    final preferencesFile = File(p.join(courier.path, 'prefs.json'));
    await preferencesFile.writeAsString('{invalid-json', flush: true);

    await expectLater(
      service.bindWorkspace(workspace.path),
      throwsCourierCode('INVALID_CONFIG'),
    );
    expect(service.workspacePath, await first.resolveSymbolicLinks());
    expect(await preferencesFile.readAsString(), '{invalid-json');
  });

  test('拒绝将元数据路径绑定到普通文件', () async {
    await File(p.join(workspace.path, '.Courier')).writeAsString('blocked');
    final service = WorkspaceConfigService(logger: logger);
    await expectLater(
      service.bindWorkspace(workspace.path),
      throwsCourierCode('COURIER_DIRECTORY_UNSAFE'),
    );
  });
}
