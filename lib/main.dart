// Courier Flutter desktop application.
//
// 架构：
// - CourierService: pure Dart AI, task, and Git services
// - WorkspaceService: workspace-bounded file operations
// - UI: FileTreePanel | EditorPanel | RightPanel(AI+Task)
//
// 路由：主页 / + 设置页 /settings

import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'services/app_error.dart';
import 'services/app_logger.dart';
import 'services/courier_service.dart';
import 'services/safe_file_system.dart';
import 'services/secure_storage_service.dart';
import 'services/settings_state.dart';
import 'services/workspace_config_service.dart';
import 'services/workspace_service.dart';
import 'widgets/file_tree_panel.dart';
import 'widgets/animations.dart';
import 'widgets/glass.dart';
import 'widgets/editor_panel.dart';
import 'widgets/right_panel.dart';
import 'widgets/settings_page.dart';

// ============================================================
// 入口
// ============================================================
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  try {
    if (isDesktop) {
      await windowManager.ensureInitialized();
      await windowManager.waitUntilReadyToShow(
        const WindowOptions(
          title: 'Courier',
          size: Size(1440, 900),
          minimumSize: Size(1024, 720),
          titleBarStyle: TitleBarStyle.hidden,
          backgroundColor: Color(0xFF0C1220),
        ),
        () async {
          await windowManager.show();
        },
      );
    }

    final secureStorage = SecureStorageService();
    final settings = SettingsState(secureStorage: secureStorage);
    await settings.load();
    final logger = AppLogger(minimumLevel: settings.logLevel);
    final courierService = CourierService(
      settings: settings,
      secureStorage: secureStorage,
      logger: logger,
    );
    await courierService.initialize();
    final workspaceService = WorkspaceService(
      fileSystem: SafeFileSystem(),
      configService: WorkspaceConfigService(logger: logger),
      logger: logger,
      onWorkspaceOpened: courierService.bindWorkspace,
    );

    // Enable close interception only after every required service is ready.
    if (isDesktop) {
      await windowManager.setPreventClose(true);
    }

    runApp(
      CourierApp(
        courierService: courierService,
        workspaceService: workspaceService,
        settings: settings,
      ),
    );
  } catch (error, stackTrace) {
    final errorCode = error is CourierException ? error.code : 'STARTUP_FAILED';
    final message = error is CourierException
        ? ErrorSanitizer.redact(error.message, maxLength: 500)
        : '应用服务初始化失败，请关闭应用后重试。';
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: CourierException(errorCode, message),
        stack: stackTrace,
        library: 'courier_flutter',
        context: ErrorDescription('while initializing Courier'),
      ),
    );
    runApp(
      StartupFailureApp(
        errorCode: errorCode,
        message: message,
        onClose: _closeAfterStartupFailure,
      ),
    );
    if (isDesktop) {
      try {
        await windowManager.show();
      } catch (_) {
        // The failure screen may still be visible through the Flutter runner.
      }
    }
  }
}

Future<void> _closeAfterStartupFailure() async {
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    try {
      await windowManager.setPreventClose(false);
    } catch (_) {
      // Close must still be attempted when the window plugin initialized partly.
    }
    try {
      await windowManager.destroy();
      return;
    } catch (_) {
      // A fatal startup failure has no application state that requires cleanup.
    }
  }
  exit(1);
}

class StartupFailureApp extends StatelessWidget {
  final String errorCode;
  final String message;
  final Future<void> Function() onClose;

  const StartupFailureApp({
    super.key,
    required this.errorCode,
    required this.message,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Courier',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: kPrimary,
        useMaterial3: true,
        fontFamily: 'Microsoft YaHei UI',
      ),
      home: Scaffold(
        backgroundColor: const Color(0xFF101216),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 48,
                      color: Color(0xFFF87171),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'Courier 无法启动',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      message,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 14,
                        height: 1.5,
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '错误代码: $errorCode',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white38,
                      ),
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: () => unawaited(onClose()),
                      icon: const Icon(Icons.close),
                      label: const Text('关闭应用'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// 路由配置
// ============================================================
final _router = GoRouter(
  initialLocation: '/',
  routes: [GoRoute(path: '/', builder: (_, _) => const MainPage())],
);

// ============================================================
// App 根
// ============================================================
class CourierApp extends StatelessWidget {
  final CourierService courierService;
  final WorkspaceService workspaceService;
  final SettingsState settings;

  const CourierApp({
    super.key,
    required this.courierService,
    required this.workspaceService,
    required this.settings,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<WorkspaceService>.value(value: workspaceService),
        ChangeNotifierProvider<CourierService>.value(value: courierService),
        ChangeNotifierProvider<SettingsState>.value(value: settings),
      ],
      // 主题强调色跟随 SettingsState（自定义主题），变化时重建 MaterialApp
      child: Consumer<SettingsState>(
        builder: (context, settings, _) => MaterialApp.router(
          title: 'Courier',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            brightness: Brightness.dark,
            colorSchemeSeed: settings.accentColor,
            useMaterial3: true,
            fontFamily: 'Microsoft YaHei UI',
          ),
          routerConfig: _router,
        ),
      ),
    );
  }
}

// ============================================================
// 自定义标题栏
// ============================================================
class TitleBar extends StatelessWidget {
  final VoidCallback? onOpenSettings;

  const TitleBar({super.key, this.onOpenSettings});

  @override
  Widget build(BuildContext context) {
    final accent = accentColorOf(context);
    return GestureDetector(
      onPanStart: (_) =>
          unawaited(_runWindowCommand(context, windowManager.startDragging)),
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        height: 36,
        child: Row(
          children: [
            const SizedBox(width: 12),
            // Logo
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Icon(
                Icons.local_shipping,
                size: 13,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              'Courier',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.white70,
              ),
            ),
            const SizedBox(width: 12),
            // 工作区名称
            Consumer<WorkspaceService>(
              builder: (context, ws, _) {
                if (!ws.hasWorkspace) return const SizedBox();
                return Row(
                  children: [
                    const Icon(
                      Icons.folder_open,
                      size: 13,
                      color: Colors.white24,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      ws.workspaceName,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Colors.white38,
                      ),
                    ),
                  ],
                );
              },
            ),
            // 应用版本
            Consumer<CourierService>(
              builder: (context, service, _) {
                if (service.version == null) return const SizedBox();
                return Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    'v${service.version!.displayVersion}',
                    style: const TextStyle(fontSize: 12, color: Colors.white24),
                  ),
                );
              },
            ),
            const Spacer(),
            // 设置按钮
            IconButton(
              icon: const Icon(Icons.settings, size: 15),
              color: Colors.white38,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              tooltip: '设置',
              onPressed: onOpenSettings,
            ),
            const SizedBox(width: 4),
            // 窗口控制按钮
            SizedBox(
              width: 108,
              child: Row(
                children: [
                  _buildButton(context, Icons.minimize, windowManager.minimize),
                  _buildButton(context, Icons.crop_square, () async {
                    if (await windowManager.isMaximized()) {
                      await windowManager.unmaximize();
                    } else {
                      await windowManager.maximize();
                    }
                  }),
                  _buildButton(
                    context,
                    Icons.close,
                    windowManager.close,
                    isClose: true,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildButton(
    BuildContext context,
    IconData icon,
    Future<void> Function() onTap, {
    bool isClose = false,
  }) {
    return Expanded(
      child: HoverCard(
        onTap: () => unawaited(_runWindowCommand(context, onTap)),
        radius: 0,
        hoverColor: isClose ? const Color(0x33EF4444) : kGlassHoverBg,
        child: SizedBox(
          height: 36,
          child: Icon(icon, size: 15, color: Colors.white60),
        ),
      ),
    );
  }

  Future<void> _runWindowCommand(
    BuildContext context,
    Future<void> Function() command,
  ) async {
    try {
      await command();
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('窗口操作失败: $error')));
    }
  }
}

// ============================================================
// 主页 — 三栏布局
// ============================================================
enum _UnsavedDecision { save, discard, cancel }

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> with WindowListener {
  /// 设置弹窗是否显示（悬浮覆盖层，主界面始终保持挂载）
  bool _showSettings = false;
  bool _closing = false;

  void _openSettings() => setState(() => _showSettings = true);

  void _closeSettings() => setState(() => _showSettings = false);

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_restoreStartupState());
    });
  }

  Future<void> _restoreStartupState() async {
    final workspace = context.read<WorkspaceService>();
    final settings = context.read<SettingsState>();
    try {
      if (settings.restoreWorkspace) {
        await workspace.loadLastWorkspace();
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('启动恢复失败: $error')));
    }
  }

  @override
  void onWindowClose() {
    unawaited(_handleWindowClose());
  }

  Future<void> _handleWindowClose() async {
    if (_closing) return;
    _closing = true;
    var preventCloseReleased = false;
    try {
      final workspace = context.read<WorkspaceService>();
      final courierService = context.read<CourierService>();
      if (workspace.hasDirtyDocuments) {
        final decision = await showDialog<_UnsavedDecision>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            title: const Text('存在未保存文档'),
            content: Text('共有 ${workspace.dirtyDocuments.length} 个文档尚未保存。'),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(_UnsavedDecision.cancel),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(_UnsavedDecision.discard),
                child: const Text('放弃更改'),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(_UnsavedDecision.save),
                child: const Text('保存并退出'),
              ),
            ],
          ),
        );
        if (decision == null || decision == _UnsavedDecision.cancel) return;
        if (decision == _UnsavedDecision.save &&
            !await _saveAllDirtyDocuments()) {
          return;
        }
      }
      await courierService.shutdown();
      await windowManager.setPreventClose(false);
      preventCloseReleased = true;
      await windowManager.close();
    } catch (error) {
      if (preventCloseReleased) {
        try {
          await windowManager.setPreventClose(true);
        } catch (_) {
          // The original close error remains the actionable failure.
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('退出失败: $error')));
      }
    } finally {
      _closing = false;
    }
  }

  Future<bool> _saveAllDirtyDocuments() async {
    final workspace = context.read<WorkspaceService>();
    final documents = workspace.dirtyDocuments.toList(growable: false);
    try {
      for (final document in documents) {
        if (document.untitled) {
          final path = await _promptSavePath(document.fileName);
          if (path == null) return false;
          await workspace.saveAs(document.id, path);
        } else {
          await workspace.saveDocument(document.id);
        }
      }
      return true;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存失败: $error')));
      }
      return false;
    }
  }

  Future<String?> _promptSavePath(String initialValue) async {
    final controller = TextEditingController(text: initialValue);
    try {
      return await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('保存文档'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: '工作区相对路径'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(controller.text.trim()),
              child: const Text('保存'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // 背景：深色渐变 + 光晕（毛玻璃的透光/折射来源）
          const Positioned.fill(child: _Background()),
          // 标题栏与状态栏贴边，中间三栏保留悬浮毛玻璃卡片。
          Column(
            children: [
              Container(
                key: const ValueKey('window-title-bar'),
                width: double.infinity,
                decoration: const BoxDecoration(
                  color: kGlassHeaderBg,
                  border: Border(bottom: BorderSide(color: kGlassBorder)),
                ),
                child: TitleBar(onOpenSettings: _openSettings),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // ---- 左栏：文件树 ----
                      const SizedBox(
                        width: 250,
                        child: Glass(child: FileTreePanel()),
                      ),
                      const SizedBox(width: 12),
                      // ---- 中栏：编辑器 ----
                      const Expanded(child: Glass(child: EditorPanel())),
                      const SizedBox(width: 12),
                      // ---- 右栏：AI 助手 + 任务队列 ----
                      SizedBox(
                        width: 320,
                        child: Glass(
                          child: RightPanel(onOpenSettings: _openSettings),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const DecoratedBox(
                key: ValueKey('window-status-bar'),
                decoration: BoxDecoration(
                  color: kGlassHeaderBg,
                  border: Border(top: BorderSide(color: kGlassBorder)),
                ),
                child: SizedBox(width: double.infinity, child: _StatusBar()),
              ),
            ],
          ),
          // 设置遮罩：脱离动画层即时显示（模糊立即生效）。
          // 注意：不能用 FadeTransition/Opacity 包裹 BackdropFilter，
          // 否则动画期间透明度 < 1 时模糊渲染失效，出现"动画完才模糊"的割裂感。
          if (_showSettings)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _closeSettings,
                child: ClipRect(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                    child: Container(color: const Color(0x66070A14)),
                  ),
                ),
              ),
            ),
          // 设置卡片：位移（上浮 / 下沉）+ 轻微缩放，不用 opacity，
          // 避免玻璃卡片在动画期间模糊失效。主界面不卸载、状态完整保留。
          Positioned.fill(
            child: AnimatedSwitcher(
              duration: kAnimDurationSlow,
              switchInCurve: kAnimCurveIn,
              switchOutCurve: kAnimCurveOut,
              transitionBuilder: (child, animation) {
                return SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.08),
                    end: Offset.zero,
                  ).animate(animation),
                  child: ScaleTransition(
                    scale: Tween<double>(
                      begin: 0.96,
                      end: 1.0,
                    ).animate(animation),
                    child: child,
                  ),
                );
              },
              child: _showSettings
                  ? SettingsPage(
                      key: const ValueKey('settings'),
                      onClose: _closeSettings,
                    )
                  : const SizedBox.shrink(key: ValueKey('main')),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// 背景
// ============================================================
class _Background extends StatelessWidget {
  const _Background();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(color: Color(0xFF101216)),
    );
  }
}

// ============================================================
// 底栏：状态栏
// ============================================================
class _StatusBar extends StatelessWidget {
  const _StatusBar();

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WorkspaceService>();
    final service = context.watch<CourierService>();

    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          // 工作区状态
          Icon(
            ws.hasWorkspace ? Icons.check_circle : Icons.info,
            size: 10,
            color: ws.hasWorkspace ? const Color(0xFF10B981) : Colors.white24,
          ),
          const SizedBox(width: 4),
          Text(
            ws.hasWorkspace ? ws.workspaceName : '未打开工作区',
            style: const TextStyle(fontSize: 12, color: Colors.white38),
          ),
          const SizedBox(width: 16),
          // 文件数
          if (ws.hasWorkspace)
            Text(
              '${ws.visibleFileCount} 个文件',
              style: const TextStyle(fontSize: 12, color: Colors.white24),
            ),
          const SizedBox(width: 16),
          // 打开标签数
          if (ws.documents.isNotEmpty)
            Text(
              ws.hasDirtyDocuments
                  ? '${ws.documents.length} 个标签 · ${ws.dirtyDocuments.length} 个未保存'
                  : '${ws.documents.length} 个标签',
              style: const TextStyle(fontSize: 12, color: Colors.white24),
            ),
          const Spacer(),
          Text(
            service.git.repositoryAvailable
                ? 'Git: ${service.currentGitStatus?.currentBranch ?? '可用'}'
                : service.git.gitAvailable
                ? 'Git: 当前工作区不可用'
                : 'Git: 未检测到 CLI',
            style: TextStyle(
              fontSize: 12,
              color: service.git.repositoryAvailable
                  ? const Color(0xFF10B981)
                  : Colors.white38,
            ),
          ),
        ],
      ),
    );
  }
}
