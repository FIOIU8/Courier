// ai_assistant_panel.dart — AI 助手面板（真实）
//
// 连接 CourierCoreService 的 AI 模块：
// aiStartSession / aiSendMessage / aiStopSession / aiGetOptions
//
// 注意：FFI 的 AISendMessage 为同步调用（当前为占位响应）。
// 为避免阻塞 UI，在 postFrameCallback 中执行，先显示 loading 状态。

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/courier_core_service.dart';
import '../services/models.dart';

class AIAssistantPanel extends StatefulWidget {
  final String workspacePath;
  final VoidCallback? onOpenSettings;

  const AIAssistantPanel({
    super.key,
    required this.workspacePath,
    this.onOpenSettings,
  });

  @override
  State<AIAssistantPanel> createState() => _AIAssistantPanelState();
}

class _AIAssistantPanelState extends State<AIAssistantPanel> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _sessionStarting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initSession());
  }

  @override
  void didUpdateWidget(AIAssistantPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 工作区变化时重建会话
    if (widget.workspacePath != oldWidget.workspacePath) {
      _initSession();
    }
  }

  void _initSession() {
    final service = context.read<CourierCoreService?>();
    if (service == null || widget.workspacePath.isEmpty) return;

    setState(() {
      _sessionStarting = true;
      _error = null;
    });

    // 加载选项（首次）
    if (service.aiOptions == null) {
      try {
        service.aiGetOptions();
      } catch (e) {
        debugPrint('[AIAssistantPanel] 加载选项失败: $e');
      }
    }

    // 在下一帧执行，让 loading 状态先渲染
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        // 先停止旧会话
        if (service.aiSession != null) {
          try {
            service.aiStopSession();
          } catch (_) {}
        }
        service.aiStartSession(workspacePath: widget.workspacePath);
        setState(() => _sessionStarting = false);
      } catch (e) {
        setState(() {
          _sessionStarting = false;
          _error = '$e';
        });
      }
    });
  }

  void _sendMessage() {
    final service = context.read<CourierCoreService?>();
    if (service == null || service.aiSession == null || service.aiSending) return;

    final text = _inputController.text.trim();
    if (text.isEmpty) return;

    _inputController.clear();

    // 在下一帧执行 FFI 同步调用，让用户消息先渲染
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        service.aiSendMessage(text: text);
        // 滚动到底部
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      } catch (e) {
        setState(() => _error = '$e');
      }
    });
  }

  void _stopSession() {
    final service = context.read<CourierCoreService?>();
    if (service == null || service.aiSession == null) return;
    try {
      service.aiStopSession();
      _initSession();
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<CourierCoreService?>();

    if (service == null) {
      return _buildNoService();
    }

    final options = service.aiOptions;
    final noProviders = options == null || options.providers.isEmpty;
    final messages = service.aiMessages;

    return Container(
      color: const Color(0xFF0C1220),
      child: Column(
        children: [
          // 供应商/模型选择栏
          if (options != null) _buildOptionBar(context, options),
          // 无供应商警告
          if (noProviders)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: const BoxDecoration(
                color: Color(0x1AF59E0B),
                border: Border(bottom: BorderSide(color: Color(0x40F59E0B))),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber, size: 12, color: Color(0xFFF59E0B)),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text('未配置 API 供应商', style: TextStyle(fontSize: 10, color: Color(0xFFFDE68A))),
                  ),
                  if (widget.onOpenSettings != null)
                    TextButton(
                      onPressed: widget.onOpenSettings,
                      child: const Text('配置', style: TextStyle(fontSize: 10, color: Color(0xFF6366F1))),
                    ),
                ],
              ),
            ),
          // 错误提示
          if (_error != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: const BoxDecoration(
                color: Color(0x1AEF4444),
                border: Border(bottom: BorderSide(color: Color(0x40EF4444))),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, size: 12, color: Color(0xFFEF4444)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(_error!, style: const TextStyle(fontSize: 10, color: Color(0xFFFCA5A5)),
                        overflow: TextOverflow.ellipsis),
                  ),
                  InkWell(
                    onTap: () => setState(() => _error = null),
                    child: const Icon(Icons.close, size: 12, color: Color(0xFFFCA5A5)),
                  ),
                ],
              ),
            ),
          // 消息列表
          Expanded(child: _buildMessageList(context, messages, service.aiSending)),
          // 输入区
          _buildInputBar(context, service),
        ],
      ),
    );
  }

  Widget _buildNoService() {
    return Container(
      color: const Color(0xFF0C1220),
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.smart_toy, size: 32, color: Colors.white24),
            SizedBox(height: 8),
            Text('核心服务未加载', style: TextStyle(fontSize: 12, color: Colors.white38)),
          ],
        ),
      ),
    );
  }

  Widget _buildOptionBar(BuildContext context, AIGetOptionsResult options) {
    final service = context.read<CourierCoreService>();
    final session = service.aiSession;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0xFF111827),
        border: Border(bottom: BorderSide(color: Color(0xFF1E2438))),
      ),
      child: Row(
        children: [
          const Icon(Icons.smart_toy, size: 14, color: Color(0xFF6366F1)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              session != null
                  ? '会话已建立 · ${session.providerId}/${session.modelId}'
                  : _sessionStarting
                      ? '正在建立会话...'
                      : '会话未建立',
              style: TextStyle(
                fontSize: 10,
                color: session != null ? const Color(0xFF818CF8) : Colors.white38,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (session != null)
            InkWell(
              onTap: _stopSession,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.refresh, size: 13, color: Colors.white38),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMessageList(BuildContext context, List<AIMessage> messages, bool sending) {
    if (_sessionStarting) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF6366F1)),
            ),
            SizedBox(height: 8),
            Text('正在建立 AI 会话...', style: TextStyle(fontSize: 11, color: Colors.white38)),
          ],
        ),
      );
    }

    if (messages.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome, size: 32, color: Colors.white24),
            SizedBox(height: 8),
            Text('AI 助手', style: TextStyle(fontSize: 13, color: Colors.white54, fontWeight: FontWeight.w500)),
            SizedBox(height: 4),
            Text(
              '输入任务，AI 将在工作区内协助工作',
              style: TextStyle(fontSize: 11, color: Colors.white24),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(12),
      itemCount: messages.length + (sending ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == messages.length) {
          return _buildThinkingIndicator();
        }
        return _MessageBubble(message: messages[index]);
      },
    );
  }

  Widget _buildThinkingIndicator() {
    return const Padding(
      padding: EdgeInsets.only(top: 8),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF6366F1)),
          ),
          SizedBox(width: 8),
          Text('AI 思考中...', style: TextStyle(fontSize: 11, color: Colors.white38)),
        ],
      ),
    );
  }

  Widget _buildInputBar(BuildContext context, CourierCoreService service) {
    final canSend = service.aiSession != null && !service.aiSending;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0xFF111827),
        border: Border(top: BorderSide(color: Color(0xFF1E2438))),
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              constraints: const BoxConstraints(maxHeight: 100),
              child: TextField(
                controller: _inputController,
                maxLines: null,
                minLines: 1,
                enabled: canSend,
                style: const TextStyle(fontSize: 12, color: Colors.white70),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  hintText: canSend ? '输入消息，Enter 发送...' : 'AI 正在处理...',
                  hintStyle: const TextStyle(fontSize: 11, color: Colors.white24),
                  enabledBorder: OutlineInputBorder(
                    borderSide: const BorderSide(color: Color(0xFF1E2438)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: const BorderSide(color: Color(0xFF6366F1)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  disabledBorder: OutlineInputBorder(
                    borderSide: const BorderSide(color: Color(0xFF1E2438)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onSubmitted: (_) => _sendMessage(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: canSend ? _sendMessage : null,
            icon: Icon(
              Icons.send,
              size: 16,
              color: canSend ? const Color(0xFF6366F1) : Colors.white24,
            ),
            style: IconButton.styleFrom(
              backgroundColor: canSend ? const Color(0xFF6366F1).withValues(alpha: 0.1) : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// _MessageBubble — 单条消息气泡。
class _MessageBubble extends StatelessWidget {
  final AIMessage message;
  const _MessageBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: const Color(0xFF6366F1).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Icon(Icons.smart_toy, size: 13, color: Color(0xFF6366F1)),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.75,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: isUser
                    ? const Color(0xFF6366F1)
                    : const Color(0xFF1E2438),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(8),
                  topRight: const Radius.circular(8),
                  bottomLeft: isUser ? const Radius.circular(8) : Radius.zero,
                  bottomRight: isUser ? Radius.zero : const Radius.circular(8),
                ),
              ),
              child: SelectableText(
                message.text,
                style: TextStyle(
                  fontSize: 12,
                  color: isUser ? Colors.white : Colors.white70,
                  height: 1.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
