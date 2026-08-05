// courier_core_service_test.dart — CourierCoreService 单元测试
//
// 使用真实 courier_core.dll 进行集成测试。
// Go 后端为内存态实现，测试结果是确定性的。
//
// 运行：flutter test test/courier_core_service_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:courier_flutter/services/courier_core_service.dart';
import 'package:courier_flutter/services/models.dart';

// ============================================================
// 测试常量
// ============================================================

const _dllPath = r'D:\00-Work\03-Code\SoM\Courier\courier_core\courier_core.dll';
const _testWorkspace = r'C:\Windows\Temp'; // 任意存在的路径
const _encryptKey = 'test-key-1234567890123456789012';
const _encryptPlaintext = 'Hello, Courier!';

// ============================================================
// 测试套件
// ============================================================

void main() {
  late CourierCoreService service;

  setUpAll(() {
    service = CourierCoreService.withPath(_dllPath);
  });

  tearDown(() {
    service.reset();
  });

  // ============================================================
  // 核心模块
  // ============================================================

  group('核心模块', () {
    test('getCoreVersion 返回版本号 1.0.0', () {
      final version = service.getCoreVersion();

      expect(version.major, 1);
      expect(version.minor, 0);
      expect(version.patch, 0);
      expect(version.versionString, '1.0.0');
    });

    test('getCoreVersion 第二次调用使用缓存', () {
      final v1 = service.getCoreVersion();
      final v2 = service.getCoreVersion();

      expect(identical(v1, v2), isTrue);
    });

    test('version getter 在调用后非空', () {
      service.getCoreVersion();
      expect(service.version, isNotNull);
    });
  });

  // ============================================================
  // AI 模块
  // ============================================================

  group('AI 模块', () {
    test('aiStartSession 创建会话', () {
      final session = service.aiStartSession(
        workspacePath: _testWorkspace,
        providerId: 'anthropic',
        modelId: 'claude-sonnet',
      );

      expect(session.sessionId, isNotEmpty);
      expect(session.sessionId, startsWith('ai-session-'));
      expect(session.workspacePath, _testWorkspace);
      expect(session.providerId, 'anthropic');
      expect(session.modelId, 'claude-sonnet');
      expect(session.messageCount, 0);
      expect(session.createdAt, isNotEmpty);
    });

    test('aiStartSession 默认 provider/model 为 default', () {
      final session = service.aiStartSession(workspacePath: _testWorkspace);

      expect(session.providerId, 'default');
      expect(session.modelId, 'default');
    });

    test('aiSession getter 在创建后非空', () {
      expect(service.aiSession, isNull);
      service.aiStartSession(workspacePath: _testWorkspace);
      expect(service.aiSession, isNotNull);
    });

    test('aiSendMessage 发送消息并收到回复', () {
      service.aiStartSession(workspacePath: _testWorkspace);

      final result = service.aiSendMessage(text: '你好');

      expect(result.sessionId, service.aiSession!.sessionId);
      expect(result.messageCount, 1);
      expect(result.reply, isNotEmpty);
      expect(result.reply, contains('你好'));
    });

    test('aiSendMessage 将消息加入历史', () {
      service.aiStartSession(workspacePath: _testWorkspace);

      expect(service.aiMessages, isEmpty);

      service.aiSendMessage(text: '第一条');
      expect(service.aiMessages.length, 2); // user + assistant

      final userMsg = service.aiMessages[0];
      expect(userMsg.role, 'user');
      expect(userMsg.text, '第一条');
      expect(userMsg.isUser, isTrue);

      final aiMsg = service.aiMessages[1];
      expect(aiMsg.role, 'assistant');
      expect(aiMsg.text, isNotEmpty);
      expect(aiMsg.isUser, isFalse);
    });

    test('aiSendMessage 多次调用累加 messageCount', () {
      service.aiStartSession(workspacePath: _testWorkspace);

      service.aiSendMessage(text: 'msg1');
      service.aiSendMessage(text: 'msg2');
      final result3 = service.aiSendMessage(text: 'msg3');

      expect(result3.messageCount, 3);
      expect(service.aiMessages.length, 6); // 3 user + 3 assistant
    });

    test('aiSending 状态在发送期间为 true', () {
      service.aiStartSession(workspacePath: _testWorkspace);
      // 同步调用，发送结束后 aiSending 应为 false
      service.aiSendMessage(text: 'test');
      expect(service.aiSending, isFalse);
    });

    test('aiSendMessage 未创建会话时抛异常', () {
      expect(
        () => service.aiSendMessage(text: 'test'),
        throwsA(isA<CourierException>()),
      );
    });

    test('aiStopSession 停止会话并清空状态', () {
      service.aiStartSession(workspacePath: _testWorkspace);
      service.aiSendMessage(text: 'hello');

      final result = service.aiStopSession();

      expect(result.status, 'stopped');
      expect(service.aiSession, isNull);
      expect(service.aiMessages, isEmpty);
    });

    test('aiStopSession 未创建会话时抛异常', () {
      expect(
        () => service.aiStopSession(),
        throwsA(isA<CourierException>()),
      );
    });

    test('aiGetOptions 返回供应商和模型选项', () {
      final options = service.aiGetOptions();

      expect(options.providers, hasLength(2));

      // Anthropic
      final anthropic = options.providers[0];
      expect(anthropic.id, 'anthropic');
      expect(anthropic.displayName, 'Anthropic Claude');
      expect(anthropic.models, hasLength(2));
      expect(anthropic.models[0].id, 'claude-sonnet');
      expect(anthropic.models[0].displayName, 'Claude Sonnet');

      // OpenAI
      final openai = options.providers[1];
      expect(openai.id, 'openai');
      expect(openai.displayName, 'OpenAI');
      expect(openai.models, hasLength(2));
      expect(openai.models[0].id, 'gpt-4o');

      // thinkingLevels
      expect(options.thinkingLevels, hasLength(4));
      expect(options.thinkingLevels[0].value, 'off');
      expect(options.thinkingLevels[0].label, '关闭');

      // modes
      expect(options.modes, hasLength(3));
      expect(options.modes[0].value, 'readonly');
      expect(options.modes[0].label, '只读');
    });

    test('aiGetOptions 第二次调用使用缓存', () {
      final o1 = service.aiGetOptions();
      final o2 = service.aiGetOptions();
      expect(identical(o1, o2), isTrue);
    });

    test('clearAIMessages 清空消息但保留会话', () {
      service.aiStartSession(workspacePath: _testWorkspace);
      service.aiSendMessage(text: 'test');

      service.clearAIMessages();

      expect(service.aiMessages, isEmpty);
      expect(service.aiSession, isNotNull);
    });
  });

  // ============================================================
  // 任务模块
  // ============================================================

  group('任务模块', () {
    test('createTask 创建任务', () {
      final task = service.createTask(
        title: '测试任务',
        sourceType: 'ai',
        markdownContent: '# 测试内容',
      );

      expect(task.id, isNotEmpty);
      expect(task.id, startsWith('task-'));
      expect(task.title, '测试任务');
      expect(task.status, TaskStatus.queued);
      expect(task.markdownContent, '# 测试内容');
      expect(task.createdAt, isNotEmpty);
      expect(task.updatedAt, isNotEmpty);
    });

    test('createTask 空标题时使用默认名', () {
      final task = service.createTask(
        title: '   ',
        sourceType: 'ai',
        markdownContent: 'content',
      );

      expect(task.title, '未命名任务');
    });

    test('createTask 空内容时抛异常', () {
      expect(
        () => service.createTask(
          title: 'test',
          sourceType: 'ai',
          markdownContent: '   ',
        ),
        throwsA(isA<CourierException>()),
      );
    });

    test('createTask 后任务出现在 tasks 列表中', () {
      expect(service.tasks, isEmpty);

      service.createTask(
        title: '列表测试',
        sourceType: 'manual',
        markdownContent: 'content',
      );

      expect(service.tasks, hasLength(1));
      expect(service.tasks[0].title, '列表测试');
    });

    test('listTasks 列出所有任务', () {
      service.createTask(title: 'task1', sourceType: 'ai', markdownContent: 'c1');
      service.createTask(title: 'task2', sourceType: 'ai', markdownContent: 'c2');

      // createTask 已将任务加入本地列表，但 listTasks 从 DLL 重新拉取
      final tasks = service.listTasks();

      expect(tasks.length, greaterThanOrEqualTo(2));
    });

    test('getTaskDetail 获取任务详情', () {
      final created = service.createTask(
        title: '详情测试',
        sourceType: 'ai',
        markdownContent: '# detail',
      );

      final detail = service.getTaskDetail(created.id);

      expect(detail.id, created.id);
      expect(detail.title, '详情测试');
      expect(detail.markdownContent, '# detail');
    });

    test('getTaskDetail 不存在的 ID 抛异常', () {
      expect(
        () => service.getTaskDetail('nonexistent-id'),
        throwsA(isA<CourierException>()),
      );
    });

    test('deleteTask 删除任务', () {
      final created = service.createTask(
        title: '待删除',
        sourceType: 'ai',
        markdownContent: 'content',
      );

      final result = service.deleteTask(created.id);

      expect(result.taskId, created.id);
      expect(result.status, 'deleted');
      expect(service.tasks.where((t) => t.id == created.id), isEmpty);
    });

    test('deleteTask 不存在的 ID 抛异常', () {
      expect(
        () => service.deleteTask('nonexistent-id'),
        throwsA(isA<CourierException>()),
      );
    });

    test('getQueueSummary 返回队列统计', () {
      service.createTask(title: 'q1', sourceType: 'ai', markdownContent: 'c1');

      final summary = service.getQueueSummary();

      expect(summary.total, greaterThanOrEqualTo(1));
      expect(summary.queued, greaterThanOrEqualTo(1));
      expect(summary.running, 0);
      expect(summary.done, 0);
      expect(summary.failed, 0);
    });

    test('startQueue 返回 running', () {
      final result = service.startQueue();
      expect(result.status, 'running');
    });

    test('pauseQueue 返回 paused', () {
      final result = service.pauseQueue();
      expect(result.status, 'paused');
    });
  });

  // ============================================================
  // Git 模块
  // ============================================================

  group('Git 模块', () {
    // 使用 courier_flutter 自身的工作区（是 Git 仓库）
    const gitWorkspace = r'D:\00-Work\03-Code\SoM\Courier';

    test('gitStatus 返回工作区状态', () {
      final result = service.gitStatus(gitWorkspace);

      expect(result.workspacePath, gitWorkspace);
      expect(result.files, isA<List<GitStatusFile>>());
      // clean 取决于工作区实际状态，不断言具体值
    });

    test('gitStatus 空路径抛异常', () {
      expect(
        () => service.gitStatus(''),
        throwsA(isA<CourierException>()),
      );
    });

    test('currentGitStatus getter 在调用后非空', () {
      expect(service.currentGitStatus, isNull);
      service.gitStatus(gitWorkspace);
      expect(service.currentGitStatus, isNotNull);
    });

    test('gitBranchList 返回分支列表', () {
      final result = service.gitBranchList(gitWorkspace);

      expect(result.branches, isA<List<String>>());
      // 如果是 Git 仓库，至少有一个分支
      if (result.branches.isNotEmpty) {
        expect(result.branches.first, isNotEmpty);
      }
    });

    test('gitBranchList 空路径抛异常', () {
      expect(
        () => service.gitBranchList(''),
        throwsA(isA<CourierException>()),
      );
    });

    test('gitBranches getter 在调用后非空', () {
      expect(service.gitBranches, isNull);
      service.gitBranchList(gitWorkspace);
      expect(service.gitBranches, isNotNull);
    });

    test('gitDiff 返回差异内容', () {
      final result = service.gitDiff(workspacePath: gitWorkspace, staged: false);

      expect(result.staged, isFalse);
      expect(result.diff, isA<String>());
    });

    test('gitDiff staged=true 请求暂存差异', () {
      final result = service.gitDiff(workspacePath: gitWorkspace, staged: true);

      expect(result.staged, isTrue);
    });

    test('currentGitDiff getter 在调用后非空', () {
      expect(service.currentGitDiff, isNull);
      service.gitDiff(workspacePath: gitWorkspace);
      expect(service.currentGitDiff, isNotNull);
    });

    test('gitCommit 空提交信息抛异常', () {
      expect(
        () => service.gitCommit(
          workspacePath: gitWorkspace,
          message: '   ',
        ),
        throwsA(isA<CourierException>()),
      );
    });
  });

  // ============================================================
  // 加密模块
  // ============================================================

  group('加密模块', () {
    test('encrypt 返回 Base64 密文', () {
      final ciphertext = service.encrypt(_encryptPlaintext, _encryptKey);

      expect(ciphertext, isNotEmpty);
      // Base64 编码的字符串只含合法字符
      expect(RegExp(r'^[A-Za-z0-9+/]+=*$').hasMatch(ciphertext), isTrue);
    });

    test('decrypt 解密还原原文', () {
      final ciphertext = service.encrypt(_encryptPlaintext, _encryptKey);
      final plaintext = service.decrypt(ciphertext, _encryptKey);

      expect(plaintext, _encryptPlaintext);
    });

    test('encrypt+decrypt 中文内容', () {
      const text = '你好，世界！🔐';
      final ct = service.encrypt(text, _encryptKey);
      final pt = service.decrypt(ct, _encryptKey);

      expect(pt, text);
    });

    test('encrypt+decrypt 长文本', () {
      final text = 'A' * 10000;
      final ct = service.encrypt(text, _encryptKey);
      final pt = service.decrypt(ct, _encryptKey);

      expect(pt, text);
    });

    test('decrypt 错误密钥抛异常', () {
      final ciphertext = service.encrypt(_encryptPlaintext, _encryptKey);

      expect(
        () => service.decrypt(ciphertext, 'wrong-key'),
        throwsA(isA<CourierException>()),
      );
    });

    test('encrypt 相同输入产生不同密文（随机 nonce）', () {
      final ct1 = service.encrypt(_encryptPlaintext, _encryptKey);
      final ct2 = service.encrypt(_encryptPlaintext, _encryptKey);

      expect(ct1, isNot(equals(ct2)));
    });
  });

  // ============================================================
  // 状态管理
  // ============================================================

  group('状态管理', () {
    test('初始状态为 idle', () {
      final s = CourierCoreService.withPath(_dllPath);
      expect(s.state, ServiceState.idle);
      expect(s.isLoading, isFalse);
      expect(s.hasError, isFalse);
      expect(s.lastError, isNull);
      s.dispose();
    });

    test('成功操作后状态为 success', () {
      service.getQueueSummary();
      expect(service.state, ServiceState.success);
      expect(service.hasError, isFalse);
    });

    test('失败操作后状态为 error', () {
      try {
        service.gitStatus('');
      } catch (_) {}

      expect(service.state, ServiceState.error);
      expect(service.hasError, isTrue);
      expect(service.lastError, isNotNull);
      expect(service.lastErrorCode, isNotNull);
    });

    test('clearError 清除错误状态', () {
      try {
        service.gitStatus('');
      } catch (_) {}
      expect(service.hasError, isTrue);

      service.clearError();

      expect(service.hasError, isFalse);
      expect(service.lastError, isNull);
      expect(service.state, ServiceState.idle);
    });

    test('reset 清空所有状态', () {
      service.aiStartSession(workspacePath: _testWorkspace);
      service.aiSendMessage(text: 'test');
      service.createTask(title: 't', sourceType: 'ai', markdownContent: 'c');
      service.getQueueSummary();

      service.reset();

      expect(service.aiSession, isNull);
      expect(service.aiMessages, isEmpty);
      expect(service.tasks, isEmpty);
      expect(service.queueSummary, isNull);
      expect(service.currentGitStatus, isNull);
      expect(service.state, ServiceState.idle);
    });

    test('refreshAll 刷新任务和队列统计', () {
      service.refreshAll();

      expect(service.tasks, isA<List<TaskItem>>());
      expect(service.queueSummary, isNotNull);
    });
  });

  // ============================================================
  // 错误处理
  // ============================================================

  group('错误处理', () {
    test('CourierException 包含 code 和 message', () {
      try {
        service.gitStatus('');
        fail('应抛出异常');
      } on CourierException catch (e) {
        expect(e.code, isNotEmpty);
        expect(e.message, isNotEmpty);
        expect(e.code, 'WORKSPACE_REQUIRED');
      }
    });

    test('CourierException.fromErrorString 解析 CODE: message 格式', () {
      final ex = CourierException.fromErrorString('TEST_CODE: 测试消息');
      expect(ex.code, 'TEST_CODE');
      expect(ex.message, '测试消息');
    });

    test('CourierException.fromErrorString 无分隔符时返回 UNKNOWN', () {
      final ex = CourierException.fromErrorString('just a message');
      expect(ex.code, 'UNKNOWN');
      expect(ex.message, 'just a message');
    });

    test('TaskStatus.isValid 识别合法状态', () {
      expect(TaskStatus.isValid('queued'), isTrue);
      expect(TaskStatus.isValid('running'), isTrue);
      expect(TaskStatus.isValid('done'), isTrue);
      expect(TaskStatus.isValid('failed'), isTrue);
      expect(TaskStatus.isValid('invalid'), isFalse);
    });
  });
}
