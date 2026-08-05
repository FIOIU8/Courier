// Courier Flutter 桌面端 — 三栏布局 + 真实业务逻辑
//
// 架构：
// - CourierCoreService: FFI 绑定 Go 核心库（AI/Task/Git/Crypto）
// - WorkspaceService: dart:io 文件系统操作（工作区/文件树/编辑器）
// - UI: FileTreePanel | EditorPanel | RightPanel(AI+Task)
//
// 路由：主页 / + 设置页 /settings

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'services/courier_core_service.dart';
import 'services/workspace_service.dart';
import 'widgets/file_tree_panel.dart';
import 'widgets/editor_panel.dart';
import 'widgets/right_panel.dart';
import 'widgets/settings_page.dart';

// ============================================================
// 入口
// ============================================================
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
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

  // 初始化 FFI 核心服务（DLL 加载失败时仍启动 UI）
  CourierCoreService? coreService;
  try {
    coreService = CourierCoreService();
    // 获取版本信息，验证 DLL 可用
    coreService.getCoreVersion();
  } catch (e) {
    debugPrint('警告: courier_core.dll 加载失败 — $e');
    coreService = null;
  }

  // 初始化工作区服务
  final workspaceService = WorkspaceService();

  runApp(CourierApp(
    coreService: coreService,
    workspaceService: workspaceService,
  ));
}

// ============================================================
// 路由配置
// ============================================================
final _router = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (_, __) => const MainPage()),
    GoRoute(
      path: '/settings',
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: SettingsPage(onBack: () => GoRouter.of(context).go('/')),
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 250),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(1.0, 0.0),
              end: Offset.zero,
            ).animate(curved),
            child: FadeTransition(
              opacity: Tween<double>(begin: 0.0, end: 1.0).animate(curved),
              child: child,
            ),
          );
        },
      ),
    ),
  ],
);

// ============================================================
// App 根
// ============================================================
class CourierApp extends StatelessWidget {
  final CourierCoreService? coreService;
  final WorkspaceService workspaceService;

  const CourierApp({
    super.key,
    this.coreService,
    required this.workspaceService,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<WorkspaceService>.value(value: workspaceService),
        // 始终注册 nullable provider，DLL 缺失时值为 null
        ChangeNotifierProvider<CourierCoreService?>.value(value: coreService),
      ],
      child: MaterialApp.router(
        title: 'Courier',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          colorSchemeSeed: const Color(0xFF6366F1),
          useMaterial3: true,
          fontFamily: 'Microsoft YaHei UI',
        ),
        routerConfig: _router,
      ),
    );
  }
}

// ============================================================
// 自定义标题栏
// ============================================================
class TitleBar extends StatelessWidget {
  const TitleBar({super.key});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanStart: (_) => windowManager.startDragging(),
      child: Container(
        height: 36,
        color: const Color(0xFF0A0E1A),
        child: Row(
          children: [
            const SizedBox(width: 12),
            // Logo
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: const Color(0xFF6366F1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Icon(Icons.local_shipping, size: 12, color: Colors.white),
            ),
            const SizedBox(width: 8),
            const Text(
              'Courier',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white70),
            ),
            const SizedBox(width: 12),
            // 工作区名称
            Consumer<WorkspaceService>(
              builder: (context, ws, _) {
                if (!ws.hasWorkspace) return const SizedBox();
                return Row(
                  children: [
                    const Icon(Icons.folder_open, size: 12, color: Colors.white24),
                    const SizedBox(width: 4),
                    Text(
                      ws.workspaceName,
                      style: const TextStyle(fontSize: 11, color: Colors.white38),
                    ),
                  ],
                );
              },
            ),
            // 核心库版本
            Consumer<CourierCoreService?>(
              builder: (context, service, _) {
                if (service == null || service.version == null) return const SizedBox();
                return Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    'v${service.version!.versionString}',
                    style: const TextStyle(fontSize: 10, color: Colors.white24),
                  ),
                );
              },
            ),
            const Spacer(),
            // 设置按钮
            IconButton(
              icon: const Icon(Icons.settings, size: 14),
              color: Colors.white38,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              tooltip: '设置',
              onPressed: () => context.go('/settings'),
            ),
            const SizedBox(width: 4),
            // 窗口控制按钮
            SizedBox(
              width: 108,
              child: Row(
                children: [
                  _buildButton(Icons.minimize, () => windowManager.minimize()),
                  _buildButton(Icons.crop_square, () async {
                    if (await windowManager.isMaximized()) {
                      windowManager.unmaximize();
                    } else {
                      windowManager.maximize();
                    }
                  }),
                  _buildButton(Icons.close, () => windowManager.close(), isClose: true),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildButton(IconData icon, VoidCallback onTap, {bool isClose = false}) {
    return Expanded(
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            color: Colors.transparent,
            child: Icon(icon, size: 14, color: Colors.white60),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// 主页 — 三栏布局
// ============================================================
class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  @override
  void initState() {
    super.initState();
    // 启动后加载上次工作区
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<WorkspaceService>().loadLastWorkspace();
    });
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Column(
        children: [
          TitleBar(),
          Expanded(
            child: Row(
              children: [
                // ---- 左栏：文件树 ----
                SizedBox(
                  width: 250,
                  child: FileTreePanel(),
                ),
                VerticalDivider(width: 1, color: Color(0xFF1E2438)),
                // ---- 中栏：编辑器 ----
                Expanded(
                  flex: 1,
                  child: EditorPanel(),
                ),
                VerticalDivider(width: 1, color: Color(0xFF1E2438)),
                // ---- 右栏：AI 助手 + 任务队列 ----
                SizedBox(
                  width: 320,
                  child: RightPanel(),
                ),
              ],
            ),
          ),
          // ---- 底栏：状态栏 ----
          _StatusBar(),
        ],
      ),
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
    final service = context.watch<CourierCoreService?>();

    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: Color(0xFF0A0E1A),
        border: Border(top: BorderSide(color: Color(0xFF1E2438))),
      ),
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
            style: const TextStyle(fontSize: 10, color: Colors.white38),
          ),
          const SizedBox(width: 16),
          // 文件数
          if (ws.hasWorkspace)
            Text(
              '${ws.fileTree.where((n) => !n.isDir).length} 个文件',
              style: const TextStyle(fontSize: 10, color: Colors.white24),
            ),
          const SizedBox(width: 16),
          // 打开标签数
          if (ws.documents.isNotEmpty)
            Text(
              '${ws.documents.length} 个标签',
              style: const TextStyle(fontSize: 10, color: Colors.white24),
            ),
          const Spacer(),
          // 核心服务状态
          Text(
            service != null ? 'Core: 已连接' : 'Core: 未连接',
            style: TextStyle(
              fontSize: 10,
              color: service != null ? const Color(0xFF10B981) : const Color(0xFFEF4444),
            ),
          ),
        ],
      ),
    );
  }
}
