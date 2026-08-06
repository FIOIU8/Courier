// ai_assistant_panel.dart - Streaming AI conversation panel.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/courier_service.dart';
import '../services/models.dart';
import '../services/settings_state.dart';
import 'animations.dart';
import 'glass.dart';

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_initializeSession());
    });
  }

  @override
  void didUpdateWidget(AIAssistantPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.workspacePath != oldWidget.workspacePath) {
      unawaited(_initializeSession());
    }
  }

  Future<void> _initializeSession() async {
    if (!mounted) return;
    final service = context.read<CourierService>();
    final settings = context.read<SettingsState>();
    if (widget.workspacePath.isEmpty || !settings.aiConfigurationReady) {
      await service.ai.stopSession(clearMessages: true, allowMissing: true);
      if (mounted) {
        setState(() {
          _sessionStarting = false;
          _error = null;
        });
      }
      return;
    }

    setState(() {
      _sessionStarting = true;
      _error = null;
    });
    try {
      await service.aiStartSession(workspacePath: widget.workspacePath);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _sessionStarting = false);
    }
  }

  Future<void> _sendMessage() async {
    final service = context.read<CourierService>();
    if (service.aiSession == null || service.aiSending) return;
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    _inputController.clear();
    setState(() => _error = null);
    try {
      await service.aiSendMessage(text: text);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
    _scrollToBottom();
  }

  Future<void> _cancelGeneration() async {
    try {
      await context.read<CourierService>().cancelAIGeneration();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: kAnimDurationFast,
        curve: kAnimCurveIn,
      );
    });
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<CourierService>();
    final settings = context.watch<SettingsState>();
    final messages = service.aiMessages;
    if (messages.isNotEmpty || service.aiSending) _scrollToBottom();

    return Column(
      children: [
        _buildHeader(service, settings),
        if (!settings.aiConfigurationReady) _buildConfigurationNotice(),
        if (_error != null) _buildErrorNotice(),
        Expanded(
          child: _sessionStarting
              ? const Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : _buildMessageList(messages),
        ),
        _buildInputBar(service, settings),
      ],
    );
  }

  Widget _buildHeader(CourierService service, SettingsState settings) {
    final session = service.aiSession;
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        color: kGlassHeaderBg,
        border: Border(bottom: BorderSide(color: kGlassBorder)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.smart_toy_outlined,
            size: 15,
            color: accentColorOf(context),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              session == null
                  ? '供应商/模型未就绪'
                  : '${settings.aiProviderId} · ${settings.aiModelId}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: session == null ? Colors.white38 : Colors.white70,
              ),
            ),
          ),
          IconButton(
            tooltip: '新建会话',
            onPressed: settings.aiConfigurationReady && !_sessionStarting
                ? _initializeSession
                : null,
            icon: const Icon(Icons.add, size: 16),
          ),
        ],
      ),
    );
  }

  Widget _buildConfigurationNotice() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: const BoxDecoration(
        color: Color(0x1AF59E0B),
        border: Border(bottom: BorderSide(color: Color(0x40F59E0B))),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber, size: 14, color: Color(0xFFF59E0B)),
          const SizedBox(width: 6),
          const Expanded(
            child: Text(
              '需要配置供应商模型与 API Key',
              style: TextStyle(fontSize: 12, color: Color(0xFFFDE68A)),
            ),
          ),
          TextButton(onPressed: widget.onOpenSettings, child: const Text('设置')),
        ],
      ),
    );
  }

  Widget _buildErrorNotice() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: const BoxDecoration(
        color: Color(0x1AEF4444),
        border: Border(bottom: BorderSide(color: Color(0x40EF4444))),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 14, color: Color(0xFFEF4444)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _error!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Color(0xFFFCA5A5)),
            ),
          ),
          IconButton(
            tooltip: '关闭错误提示',
            onPressed: () => setState(() => _error = null),
            icon: const Icon(Icons.close, size: 14),
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            padding: EdgeInsets.zero,
          ),
        ],
      ),
    );
  }

  Widget _buildMessageList(List<AIMessage> messages) {
    if (messages.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome_outlined, size: 30, color: Colors.white24),
            SizedBox(height: 8),
            Text('新会话', style: TextStyle(fontSize: 13, color: Colors.white38)),
          ],
        ),
      );
    }
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(10),
      itemCount: messages.length,
      itemBuilder: (context, index) => _MessageBubble(message: messages[index]),
    );
  }

  Widget _buildInputBar(CourierService service, SettingsState settings) {
    final canSend =
        settings.aiConfigurationReady &&
        service.aiSession != null &&
        !service.aiSending;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: const BoxDecoration(
        color: kGlassHeaderBg,
        border: Border(top: BorderSide(color: kGlassBorder)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _inputController,
              enabled: canSend,
              minLines: 1,
              maxLines: 4,
              maxLength: 32000,
              style: const TextStyle(fontSize: 13, color: Colors.white70),
              decoration: InputDecoration(
                isDense: true,
                counterText: '',
                hintText: '消息',
                filled: true,
                fillColor: const Color(0x14FFFFFF),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 9,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: const BorderSide(color: kGlassBorder),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: const BorderSide(color: kGlassBorder),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: BorderSide(color: accentColorOf(context)),
                ),
              ),
              onSubmitted: (_) => _sendMessage(),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: service.aiSending ? '停止生成' : '发送',
            onPressed: service.aiSending
                ? _cancelGeneration
                : canSend
                ? _sendMessage
                : null,
            icon: AnimatedSwitcher(
              duration: kAnimDurationFast,
              switchInCurve: kAnimCurveIn,
              switchOutCurve: kAnimCurveOut,
              transitionBuilder: kIconSwitchTransition,
              child: Icon(
                service.aiSending ? Icons.stop_circle_outlined : Icons.send,
                key: ValueKey(service.aiSending),
                size: 18,
                color: service.aiSending || canSend
                    ? accentColorOf(context)
                    : Colors.white24,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final AIMessage message;

  const _MessageBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    final accent = accentColorOf(context);
    // 新消息入场：淡入 + 轻微上移。tween 固定 0→1，流式增量更新不改变
    // 目标值不会重启动画；仅列表滚动重建时会短暂重播（时长 120ms、位移小）。
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: kAnimDurationFast,
      curve: kAnimCurveIn,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 8 * (1 - value)),
          child: child,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          mainAxisAlignment: isUser
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isUser) ...[
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Icon(Icons.smart_toy_outlined, size: 15, color: accent),
              ),
              const SizedBox(width: 7),
            ],
            Flexible(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: isUser ? accent : const Color(0xE61E2438),
                  borderRadius: BorderRadius.circular(kRadiusMd),
                  border: isUser ? null : Border.all(color: kGlassBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (isUser)
                      SelectableText(
                        message.text,
                        style: const TextStyle(fontSize: 13, height: 1.45),
                      )
                    else
                      // 统一用单个可选文本控件渲染（不做 Markdown 解析）：
                      // Markdown 分块渲染会把文本拆成多个控件，导致无法整段连续复制
                      SelectableText(
                        message.text.isEmpty ? ' ' : message.text,
                        style: const TextStyle(
                          fontSize: 13,
                          height: 1.5,
                          color: Colors.white70,
                        ),
                      ),
                    if (!isUser && message.text.isNotEmpty)
                      Align(
                        alignment: Alignment.centerRight,
                        child: IconButton(
                          tooltip: '复制回复',
                          onPressed: () => Clipboard.setData(
                            ClipboardData(text: message.text),
                          ),
                          icon: const Icon(Icons.copy, size: 13),
                          constraints: const BoxConstraints.tightFor(
                            width: 26,
                            height: 24,
                          ),
                          padding: EdgeInsets.zero,
                        ),
                      ),
                    if (message.streaming)
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 1.4),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
