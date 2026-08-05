# Courier Flutter 项目上下文 — AI 协作提示词

> 本文档供 courier_flutter 项目的 AI 助手使用，包含项目全貌、架构约定、已知陷阱和开发规范。
> 最后更新：2026-08-05

---

## 一、项目概述

Courier 是一个 AI 代码编辑器桌面应用，正在从 **React + Wails（Go 后端）** 迁移到 **Flutter 桌面端**。
Go 后端以动态库（DLL）形式保留，通过 `dart:ffi` 调用。

### 路径布局

| 组件 | 路径 |
|------|------|
| Flutter 项目 | `D:\00-Work\03-Code\SoM\courier_flutter` |
| Go 后端 DLL 源码 | `D:\00-Work\03-Code\SoM\Courier\courier_core\` |
| 编译后的 DLL | `D:\00-Work\03-Code\SoM\Courier\courier_core\courier_core.dll` |
| C 头文件 | `D:\00-Work\03-Code\SoM\Courier\courier_core\courier_core.h` |
| 原 React+Wails 项目 | `D:\00-Work\03-Code\SoM\Courier`（参考用，不再开发） |

### 技术栈

- **前端**：Flutter 3.44.8 (stable)，Dart SDK 3.12.2
- **后端**：Go 1.26+，编译为 `courier_core.dll`（c-shared 模式）
- **桥梁**：`dart:ffi` + `package:ffi`
- **状态管理**：Provider (`ChangeNotifier`)
- **路由**：go_router
- **窗口管理**：window_manager 0.4.3（自定义标题栏）
- **平台**：Windows 桌面（后续可能扩展 macOS/Linux）

### Flutter 依赖（pubspec.yaml）

```yaml
dependencies:
  flutter: { sdk: flutter }
  provider: ^6.1.2
  go_router: ^14.2.8
  window_manager: ^0.4.3
  ffi: ^2.1.0
  path: ^1.9.0
  file_picker: ^8.1.0
  shared_preferences: ^2.3.2
```

---

## 二、当前文件结构

```
courier_flutter/
├── lib/
│   ├── main.dart                          # 入口 + 三栏布局 + 设置页
│   └── services/
│       ├── models.dart                    # Dart 模型（与 Go JSON 一一对应）
│       ├── courier_core.dart              # FFI 绑定层（19 个导出函数）
│       └── courier_core_service.dart      # Provider 服务封装
├── test/
│   └── courier_core_test.dart             # FFI 单元测试（20 个，全部通过）
├── windows/                               # Windows 平台原生工程
├── build_flutter.bat                      # 编译打包脚本
├── pubspec.yaml
└── analysis_options.yaml
```

---

## 三、FFI 架构（核心约定）

### 3.1 Go 侧 JSON 信封

所有导出函数（除 `GetCoreVersion` 和 `FreeString`）的返回值均为 JSON 字符串：

```json
// 成功
{"ok": true, "data": <任意类型>}

// 失败
{"ok": false, "error": "ERROR_CODE: 描述信息"}
```

### 3.2 导出函数清单（19 个）

| 模块 | 函数 | C 签名 | 输入 JSON | 返回 data |
|------|------|--------|-----------|-----------|
| 核心 | `GetCoreVersion` | `VersionInfo()` | 无 | 按值结构体 {major,minor,patch} |
| 核心 | `FreeString` | `void(char*)` | C 指针 | 无 |
| AI | `AIStartSession` | `char*(char*)` | `{workspacePath, providerId, modelId}` | `{sessionId, workspacePath, providerId, modelId, messageCount, createdAt}` |
| AI | `AISendMessage` | `char*(char*)` | `{sessionId, text}` | `{sessionId, messageCount, reply}` |
| AI | `AIStopSession` | `char*(char*)` | sessionId 字符串 | `{sessionId, status:"stopped"}` |
| AI | `AIGetOptions` | `char*(void)` | 无 | `{providers:[...], thinkingLevels:[...], modes:[...]}` |
| 任务 | `CreateTask` | `char*(char*)` | `{title, sourceType, markdownContent}` | `{id, title, status, markdownContent, createdAt, updatedAt}` |
| 任务 | `ListTasks` | `char*(char*)` | `{status}` (可选) | `[TaskItem, ...]` |
| 任务 | `GetTaskDetail` | `char*(char*)` | taskId 字符串 | `TaskItem` |
| 任务 | `DeleteTask` | `char*(char*)` | taskId 字符串 | `{taskId, status:"deleted"}` |
| 任务 | `GetQueueSummary` | `char*(void)` | 无 | `{total, queued, running, done, failed}` |
| 任务 | `StartQueue` | `char*(void)` | 无 | `{status:"running"}` |
| 任务 | `PauseQueue` | `char*(void)` | 无 | `{status:"paused"}` |
| Git | `GitStatus` | `char*(char*)` | `{workspacePath}` | `{workspacePath, files:[{status,path}], clean}` |
| Git | `GitCommit` | `char*(char*)` | `{workspacePath, message, addAll}` | `{output, message}` |
| Git | `GitDiff` | `char*(char*)` | `{workspacePath, staged}` | `{diff, staged}` |
| Git | `GitBranchList` | `char*(char*)` | workspacePath 字符串 | `{branches:["main", ...]}` |
| 加密 | `Encrypt` | `char*(char*,char*)` | plaintext, key | Base64 密文字符串 |
| 加密 | `Decrypt` | `char*(char*,char*)` | ciphertext, key | 原文字符串 |

### 3.3 Dart FFI 调用模式

```dart
// 1. 分配 C 内存 → 调用 → 读取返回 → FreeString → 释放输入
String _callOneIn(_OneInOneOutDart fn, String input) {
  final inputPtr = input.toNativeUtf8();  // 注意：是 toNativeUtf8() 不是 toUtf8()
  try {
    final resultPtr = fn(inputPtr);
    return _extractAndFree(resultPtr);
  } finally {
    malloc.free(inputPtr);  // 注意：是 malloc 不是 calloc
  }
}

// 2. 提取返回值并释放
String _extractAndFree(Pointer<Utf8> resultPtr) {
  try {
    return resultPtr.toDartString();
  } finally {
    _freeString(resultPtr);  // 必须调用 Go 侧的 FreeString
  }
}

// 3. 解析 JSON 信封
FfiResult _parseEnvelope(String jsonString) {
  final json = jsonDecode(jsonString) as Map<String, dynamic>;
  return FfiResult.fromJson(json);  // ok=false 时后续调用 dataAsMap() 抛 CourierException
}
```

### 3.4 FFI 类型映射

| C 类型 | Dart FFI 类型 | 备注 |
|--------|---------------|------|
| `char*` (入参) | `Pointer<Utf8>` | 用 `toNativeUtf8()` 分配，`malloc.free()` 释放 |
| `char*` (返回) | `Pointer<Utf8>` | 用 `toDartString()` 读取，然后 `FreeString()` 释放 |
| `VersionInfo` (按值) | `extends Struct` | `@Int32()` 字段，直接通过 FFI 返回，无需释放 |
| `void` | `void` | `FreeString` 无返回值 |

### 3.5 已有 Dart 模型类

```
models.dart:
├── VersionInfo (Struct, @Int32 major/minor/patch)
├── CourierException (implements Exception, 有 code/message getter)
├── FfiResult (ok/data/error, dataAsMap/dataAsList/dataAsString)
├── AISession, AISendMessageResult, AIStopSessionResult
├── AIProviderOption, AIModelOption, AIOptionItem, AIGetOptionsResult
├── TaskStatus (静态常量), TaskItem, QueueSummary, DeleteTaskResult
├── GitStatusFile, GitStatusResult, GitCommitResult, GitDiffResult, GitBranchListResult
└── QueueControlResult
```

---

## 四、UI 架构约定

### 4.1 三栏布局

```
┌─────────────────────────────────────────────┐
│              自定义标题栏 (36px)              │
├──────────┬─────────────────┬────────────────┤
│  文件树   │     编辑器       │   任务队列     │
│  (250px) │    (flex: 1)    │    (300px)     │
│          │                 │                │
├──────────┴─────────────────┴────────────────┤
│             AI 输入框 (56px)                 │
└─────────────────────────────────────────────┘
```

### 4.2 色彩体系

| 用途 | 颜色 |
|------|------|
| 主背景 | `#0A0E1A` |
| 面板背景 | `#0C1220` |
| 头部/底部栏 | `#111827` |
| 分割线 | `#1E2438` |
| 主色调 | `#6366F1` (Indigo) |
| 主色浅 | `#818CF8` |
| 成功 | `#10B981` (绿) |
| 运行中 | `#F59E0B` (橙) |
| 失败 | `#EF4444` (红) |
| 主文字 | `Colors.white70` |
| 次要文字 | `Colors.white54` |
| 弱文字 | `Colors.white38` |
| 占位符 | `Colors.white24` |

### 4.3 路由

```dart
GoRoute(path: '/', builder: (_, __) => const MainPage()),
GoRoute(path: '/settings', builder: (_, __) => const SettingsPage()),
```

### 4.4 Provider 注入

```dart
MultiProvider(
  providers: [
    ChangeNotifierProvider<WorkspaceState>(create: (_) => WorkspaceState()),
    ChangeNotifierProvider<CourierCoreService>.value(value: coreService),
  ],
  child: MaterialApp.router(...),
)
```

---

## 五、构建与工具链

### 5.1 环境变量 PATH

Flutter SDK 和 Git 必须在 PATH 中：

```
D:\Programs\flutter\bin;C:\Users\X\AppData\Local\hermes\git\cmd;C:\Windows\System32;C:\Windows\System32\WindowsPowerShell\v1.0;C:\Windows
```

### 5.2 编译命令

```bat
:: Flutter 编译打包（全流程）
cd D:\00-Work\03-Code\SoM\courier_flutter
build_flutter.bat

:: 跳过测试和分析
build_flutter.bat --skip-test --skip-analyze

:: 清理后全量编译
build_flutter.bat --clean
```

```bat
:: Go DLL 编译（T04）
cd D:\00-Work\03-Code\SoM\Courier\courier_core
build_core.bat
```

### 5.3 测试

```bash
flutter test                                    # 全部测试
flutter test test/courier_core_test.dart        # 仅 FFI 测试
```

---

## 六、已知陷阱与解决方案

### 6.1 Go DLL 编译相关

| 问题 | 原因 | 解决 |
|------|------|------|
| `%1 is not a valid Win32 application` (error 193) | Go 1.26 链接器将 debug 节放在 VMA 0x400000000，超出 PE 镜像范围 | 编译加 `-ldflags="-s -w"` 剥离调试信息 |
| `cannot use _cgo0 as unsafe.Pointer` | Go 1.26 类型安全改进 | `C.free(p)` 改为 `C.free(unsafe.Pointer(p))` |
| 找不到 gcc | c-shared 模式需要 mingw-w64 | 安装 TDM-GCC-64，加入 PATH |

### 6.2 Flutter 桌面相关

| 问题 | 原因 | 解决 |
|------|------|------|
| VS 2026 isComplete=false | vswhere 报告不完整 | patch `flutter/packages/flutter_tools/lib/src/windows/visual_studio.dart`，跳过 isComplete 检查 |
| `flutter run -d windows` PathAccessException | 沙箱环境限制 Temp 目录访问 | 用 `flutter build windows --release` 代替 |
| window_manager 0.4.3 无 `setFocus()` | 版本 API 差异 | 只用 `windowManager.show()`，不调用 `setFocus()` |
| flutter engine.stamp Move-Item 错误 | 缓存文件锁 | 用 .NET API 删除 engine.stamp 文件 |

### 6.3 FFI 编码相关

| 问题 | 原因 | 解决 |
|------|------|------|
| `String.toUtf8()` 不存在 | package:ffi 2.x API 变更 | 用 `String.toNativeUtf8()` |
| `calloc` 未定义 | 未导入或用错 | 用 `malloc.free()` 释放 `toNativeUtf8()` 分配的内存 |
| 内存泄漏 | 返回的 `char*` 未释放 | 必须调用 Go 侧 `FreeString(ptr)` |

---

## 七、迁移任务进度

### 已完成

| 任务 | 描述 | 状态 |
|------|------|------|
| T01 | Flutter 项目创建 + 三栏骨架 | ✅ 完成 |
| T03 | dart:ffi 调用 Go DLL 验证 | ✅ 完成 |
| T04 | 4 个 Go 模块统一编译为 courier_core.dll | ✅ 完成 |
| T05 | FFI 绑定层封装（19 个函数 + 测试） | ✅ 完成 |

### 待完成

| 任务 | 描述 | 优先级 |
|------|------|--------|
| T02 | 文件系统操作（文件树、读写文件） | 高 |
| T06 | Markdown 编辑器（CodeMirror/Monaco 替代方案） | 高 |
| T07a | AI 对话 UI（Markdown 渲染 + 流式输出） | 高 |
| T07b | AI Provider 对接（HTTP SSE） | 高 |
| T07c | AI 代码操作（编辑/创建/删除文件） | 中 |
| T08 | 任务面板完整实现（进度条、取消、详情） | 中 |
| T09 | Git 自动化面板（staging/diff/branch 可视化） | 中 |
| T10 | 端到端加密集成（文件保存 + AI 消息存储） | 中 |
| T11 | 设置页面完整实现 | 中 |
| T12 | .Courier 工作区配置（prefs.json, 文件过滤） | 中 |
| T13 | 自定义标题栏功能完善 | 低 |
| T14 | 性能优化（--split-debug-info, AOT, 资源压缩） | 低 |
| T15 | 应用图标 + 启动画面 | 低 |
| T16 | 打包分发（MSIX/NSIS 安装包） | 低 |
| T17 | macOS/Linux 平台适配 | 低 |
| T18 | 验收测试（1:1 功能对齐 React 版） | 低 |

---

## 八、编码规范

### 8.1 Dart 代码

- 文件头部注释格式：`// 模块名 — 简要描述`
- 分区注释：`// ============================================================`
- 所有 FFI 相关代码集中在 `lib/services/` 目录
- 模型类使用 `fromJson` 工厂构造 + `const` 构造函数
- 异常使用自定义 `CourierException`（含 `code` 和 `message` getter）
- 使用 `Provider` + `ChangeNotifier` 管理状态，不用 Riverpod/Bloc
- UI 组件使用 `StatelessWidget` 优先，需要状态时用 `StatefulWidget`
- 颜色使用 `Color(0xFFXXXXXX)` 格式，不使用 `Colors.xxx`（除 white 系列透明度外）

### 8.2 Go 代码

- 所有导出函数必须有 `//export FuncName` 注释
- 输入统一为 `*C.char`（JSON 字符串），输出统一为 `*C.char`（JSON 信封）
- 使用 `okResult(data)` / `errResult(code, msg)` 构造返回值
- 使用 `parseInput(input, &target)` 解析输入
- 线程安全用 `sync.Mutex` / `sync.RWMutex`
- 编译命令必须包含 `-ldflags="-s -w"`

### 8.3 命名约定

- Dart 类：PascalCase（`TaskItem`, `AISession`）
- Dart 方法：camelCase（`aiStartSession`, `getCoreVersion`）
- Go 导出函数：PascalCase（`AIStartSession`, `CreateTask`）
- Go 内部函数：camelCase（`okResult`, `parseInput`）
- JSON 字段：camelCase（`sessionId`, `workspacePath`, `markdownContent`）

---

## 九、Go 后端模块说明

### 9.1 AI 助手 (`ai.go`)
- 内存态会话管理（`aiSessionRegistry`，`sync.RWMutex`）
- 当前为占位实现（`AISendMessage` 返回固定回复），待 T07b 对接真实 AI API
- `AIGetOptions` 返回硬编码的 Provider 列表（Anthropic/OpenAI）

### 9.2 任务管理 (`task.go`)
- 内存态任务队列（`taskQueueInstance`，`sync.Mutex`）
- 任务状态：`queued` → `running` → `done` / `failed`
- `StartQueue` / `PauseQueue` 为占位实现，待 T08 对接执行器

### 9.3 Git 自动化 (`git.go`)
- 通过 `os/exec` 调用系统 `git` 命令
- 支持 status、commit、diff、branch 四个操作

### 9.4 加密 (`crypto.go`)
- AES-256-GCM 算法
- 密钥派生：不足 32 字节用零填充，超过截断
- 输出格式：Base64(nonce + ciphertext)

---

## 十、参考：原 React+Wails 项目功能清单

迁移时需 1:1 对齐的功能（来自 `D:\00-Work\03-Code\SoM\Courier` 原项目）：

1. **文件树**：支持 9 种文件类型过滤、隐藏文件开关、`.Courier` 文件夹保护、未保存标记
2. **编辑器**：多 Tab、未保存指示器、右键菜单、Markdown 预览
3. **AI 对话**：Markdown 渲染、代码高亮、流式输出、停止生成
4. **任务面板**：状态图标、进度条、取消按钮、可展开详情
5. **Git 面板**：暂存/取消暂存、提交、分支切换、diff 可视化
6. **设置页**：通用设置、AI 模型配置、任务队列配置
7. **加密**：文件保存加密、AI 消息存储加密、密钥管理
8. **.Courier 配置**：`prefs.json`（原子写入 0o600 权限，64KB 限制）、400ms 防抖持久化
9. **性能**：<50MB 包大小、<1.5s 启动时间
