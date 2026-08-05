import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:courier_flutter/services/app_logger.dart';
import 'package:courier_flutter/services/models.dart';
import 'package:courier_flutter/services/task_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/test_fakes.dart';

void main() {
  late Directory workspace;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('courier-task-');
  });

  tearDown(() async {
    if (await workspace.exists()) await workspace.delete(recursive: true);
  });

  test('执行任务并持久化结果与状态', () async {
    final executor = ControllableTaskExecutor(output: '执行完成');
    final service = TaskService(executor: executor, logger: AppLogger());
    await service.bindWorkspace(workspace.path);
    final task = await service.createTask(
      title: '持久化任务',
      sourceType: 'manual',
      markdownContent: '执行内容',
    );
    await service.startQueue(maxConcurrent: 1);
    await waitForCondition(
      () => service.getTaskDetail(task.id).status == TaskStatus.succeeded,
    );

    expect(await service.getTaskResult(task.id), '执行完成');
    expect(service.summary.succeeded, 1);
    expect(await service.getTaskLogTail(task.id), contains('任务执行成功'));
    await service.shutdown();
    service.dispose();

    final reloaded = TaskService(
      executor: ControllableTaskExecutor(),
      logger: AppLogger(),
    );
    addTearDown(reloaded.dispose);
    await reloaded.bindWorkspace(workspace.path);
    expect(reloaded.getTaskDetail(task.id).status, TaskStatus.succeeded);
    expect(await reloaded.getTaskResult(task.id), '执行完成');
  });

  test('取消运行中任务会持久化取消状态', () async {
    final gate = Completer<void>();
    final executor = ControllableTaskExecutor(release: gate);
    final service = TaskService(executor: executor, logger: AppLogger());
    addTearDown(service.dispose);
    await service.bindWorkspace(workspace.path);
    final task = await service.createTask(
      title: '取消任务',
      sourceType: 'manual',
      markdownContent: '等待取消',
    );
    await service.startQueue(maxConcurrent: 1);
    await executor.started.future;

    await service.cancelTask(task.id);
    await waitForCondition(
      () => service.getTaskDetail(task.id).status == TaskStatus.cancelled,
    );
    expect(executor.cancelledTaskIds, contains(task.id));
    expect(service.summary.cancelled, 1);
    await service.shutdown();
  });

  test('切换工作区前等待活跃任务取消完成', () async {
    final secondWorkspace = await Directory.systemTemp.createTemp(
      'courier-task-second-',
    );
    addTearDown(() async {
      if (await secondWorkspace.exists()) {
        await secondWorkspace.delete(recursive: true);
      }
    });
    final gate = Completer<void>();
    final executor = ControllableTaskExecutor(release: gate);
    final service = TaskService(executor: executor, logger: AppLogger());
    addTearDown(service.dispose);
    await service.bindWorkspace(workspace.path);
    final task = await service.createTask(
      title: '工作区切换任务',
      sourceType: 'manual',
      markdownContent: '运行中切换',
    );
    await service.startQueue(maxConcurrent: 1);
    await executor.started.future;

    await service.bindWorkspace(secondWorkspace.path);
    expect(service.tasks, isEmpty);
    expect(executor.cancelledTaskIds, contains(task.id));

    final oldWorkspaceView = TaskService(
      executor: ControllableTaskExecutor(),
      logger: AppLogger(),
    );
    addTearDown(oldWorkspaceView.dispose);
    await oldWorkspaceView.bindWorkspace(workspace.path);
    expect(
      oldWorkspaceView.getTaskDetail(task.id).status,
      TaskStatus.cancelled,
    );
    await service.shutdown();
    await oldWorkspaceView.shutdown();
  });

  test('拒绝包含越界结果路径的任务索引', () async {
    final taskDirectory = Directory(
      p.join(workspace.path, '.Courier', 'tasks'),
    );
    await taskDirectory.create(recursive: true);
    final now = DateTime.now().toUtc().toIso8601String();
    final index = {
      'schemaVersion': 1,
      'updatedAt': now,
      'tasks': [
        {
          'id': 'task-123',
          'title': '受损任务',
          'sourceType': 'manual',
          'status': TaskStatus.succeeded,
          'markdownContent': '任务内容',
          'progress': 1,
          'createdAt': now,
          'updatedAt': now,
          'startedAt': now,
          'finishedAt': now,
          'errorCode': null,
          'errorMessage': null,
          'attempt': 1,
          'maxAttempts': 3,
          'resultPath': p.join('..', 'outside.md'),
        },
      ],
    };
    await File(
      p.join(taskDirectory.path, 'task-index.json'),
    ).writeAsString(jsonEncode(index), flush: true);

    final service = TaskService(
      executor: ControllableTaskExecutor(),
      logger: AppLogger(),
    );
    addTearDown(service.dispose);
    await expectLater(
      service.bindWorkspace(workspace.path),
      throwsCourierCode('INVALID_TASK_INDEX'),
    );
  });

  test('任务启动持久化失败时停止队列且不执行任务', () async {
    final executor = ControllableTaskExecutor();
    final service = TaskService(executor: executor, logger: AppLogger());
    addTearDown(service.dispose);
    await service.bindWorkspace(workspace.path);
    final task = await service.createTask(
      title: '存储失败任务',
      sourceType: 'manual',
      markdownContent: '验证后台错误处理',
    );
    final taskDirectory = Directory(
      p.join(workspace.path, '.Courier', 'tasks'),
    );
    final preservedDirectory = Directory('${taskDirectory.path}.preserved');
    await taskDirectory.rename(preservedDirectory.path);
    await File(taskDirectory.path).writeAsString('blocked');

    await service.startQueue(maxConcurrent: 1);
    await waitForCondition(
      () => service.getTaskDetail(task.id).status == TaskStatus.failed,
    );

    expect(executor.executionCount, 0);
    expect(service.queueRunning, isFalse);
    expect(service.lastError, isNotEmpty);
    await service.shutdown();
  });
}
