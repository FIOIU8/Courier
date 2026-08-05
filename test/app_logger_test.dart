import 'dart:convert';
import 'dart:io';

import 'package:courier_flutter/services/app_logger.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_fakes.dart';

void main() {
  test('结构化日志脱敏凭据并遵守日志级别', () async {
    final workspace = await Directory.systemTemp.createTemp('courier-logger-');
    addTearDown(() async {
      if (await workspace.exists()) await workspace.delete(recursive: true);
    });
    final logger = AppLogger(minimumLevel: AppLogLevel.info);
    await logger.bindWorkspace(workspace.path);
    final credential = generatedCredential();

    await logger.debug('test', 'ignored', 'debug message');
    await logger.error(
      'test',
      'redaction',
      'Authorization: Bearer $credential, api_key=$credential',
      errorCode: 'TEST_ERROR',
    );
    await logger.flush();

    final lines = await logger.currentLogFile!.readAsLines();
    expect(lines, hasLength(1));
    final entry = jsonDecode(lines.single) as Map<String, dynamic>;
    expect(entry['level'], 'error');
    expect(entry['message'], contains('[REDACTED]'));
    expect(entry['message'], isNot(contains(credential)));
    expect(entry['errorCode'], 'TEST_ERROR');
  });

  test('切换工作区不会把排队日志写入新工作区', () async {
    final firstWorkspace = await Directory.systemTemp.createTemp(
      'courier-logger-first-',
    );
    final secondWorkspace = await Directory.systemTemp.createTemp(
      'courier-logger-second-',
    );
    addTearDown(() async {
      if (await firstWorkspace.exists()) {
        await firstWorkspace.delete(recursive: true);
      }
      if (await secondWorkspace.exists()) {
        await secondWorkspace.delete(recursive: true);
      }
    });
    final logger = AppLogger(minimumLevel: AppLogLevel.info);
    await logger.bindWorkspace(firstWorkspace.path);
    final firstLog = logger.currentLogFile!;

    final pendingWrites = List<Future<void>>.generate(
      96,
      (index) => logger.info(
        'test',
        'queued_$index',
        List<String>.filled(1200, 'x').join(),
      ),
    );
    await logger.bindWorkspace(secondWorkspace.path);
    await Future.wait(pendingWrites);
    await logger.info('test', 'second_workspace', '第二个工作区日志');
    await logger.flush();

    final firstLines = await firstLog.readAsLines();
    final secondLines = await logger.currentLogFile!.readAsLines();
    expect(firstLines, hasLength(96));
    expect(secondLines, hasLength(1));
    expect(secondLines.single, contains('second_workspace'));
  });
}
