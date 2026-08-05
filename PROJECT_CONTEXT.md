# Courier Flutter 项目上下文

> 本文档用于维护当前实现边界、架构约定和验证要求。
> 最后更新：2026-08-05

## 一、项目定位

Courier Flutter 是一个 Windows 优先的桌面 AI 代码编辑器，直接操作用户选择的本地工作区。

项目采用 Flutter-only 架构：

- 运行时不依赖 Go 服务、Go 运行时或 Go 动态库。
- AI、任务队列、Git、设置、日志和文件安全均由 Dart 服务实现。
- Windows Release 只包含 Flutter 构建产物及插件运行库。

## 二、技术栈

| 领域 | 实现 |
| --- | --- |
| UI | Flutter Material 3 |
| 状态管理 | Provider 与 ChangeNotifier |
| 路由 | go_router |
| 窗口管理 | window_manager |
| 文件选择 | file_selector |
| 全局偏好 | shared_preferences |
| 系统凭据 | simple_secure_storage |
| Markdown | flutter_markdown_plus |
| 哈希 | crypto |
| Git | Dart Process 调用 Git CLI |

SDK 约束位于 <code>pubspec.yaml</code>：

- Dart：大于等于 3.12.0 且小于 4.0.0。
- Flutter：大于等于 3.44.0。

目录选择使用 Flutter 官方 <code>file_selector</code>，系统凭据通过操作系统凭据设施保存；该组合允许 <code>package_info_plus</code> 使用当前稳定的 10.x 版本，不依赖预发布包。

## 三、目录结构

~~~text
courier_flutter/
├── .github/workflows/auto-release.yml
├── docs/
├── lib/
│   ├── main.dart
│   ├── services/
│   └── widgets/
├── test/
├── windows/
├── build_flutter.bat
├── pubspec.yaml
└── README.md
~~~

## 四、服务架构

### 4.1 CourierService

<code>CourierService</code> 是 UI 使用的应用门面，负责：

- 加载应用版本信息。
- 绑定当前工作区的日志、任务和 Git 服务。
- 协调 AI 会话生命周期。
- 在子服务绑定失败时恢复原工作区状态。
- 关闭应用前停止任务、取消 AI、刷新设置和日志。

UI 不直接访问平台动态库，也不持有外部服务句柄。

### 4.2 WorkspaceService

<code>WorkspaceService</code> 管理工作区、文件树和编辑文档：

- 打开或恢复工作区。
- 切换工作区前保护未保存文档。
- 异步扫描目录、分类文件并应用排除规则。
- 管理多标签文档、另存为、重命名和活动文档标识。
- 将所有磁盘操作委托给 <code>SafeFileSystem</code>。
- 在下游绑定失败时恢复原配置和文件系统绑定。

### 4.3 SafeFileSystem

<code>SafeFileSystem</code> 是所有用户文件操作的安全边界：

- 同时执行词法路径校验和符号链接解析后校验。
- 禁止访问工作区根目录之外的目标。
- 保护 <code>.Courier/</code> 内部元数据。
- 限制文本文件大小并拒绝二进制或非 UTF-8 内容。
- 使用文件长度、修改时间和 SHA-256 指纹检测外部修改。
- 通过 <code>AtomicFileWriter</code> 执行同目录原子替换。
- 删除操作先预览影响范围，再移动到应用隔离区。

工作区根目录和 <code>.Courier/</code> 子目录不能是符号链接。

### 4.4 WorkspaceConfigService

工作区偏好保存在 <code>.Courier/prefs.json</code>：

- 包含 <code>schemaVersion</code>。
- 使用原子写入和大小限制。
- 更高版本配置以只读方式处理。
- 损坏配置保留原文件并返回明确错误。
- AI API Key 不进入该文件。

### 4.5 SettingsState

全局非敏感设置统一通过 <code>SettingsState</code> 访问：

- AI Provider、模型、温度和输出上限。
- 编辑器字号与自动保存。
- 任务并发和启动行为。
- 工作区恢复、隐藏文件和日志级别。

偏好写入串行执行。只有持久化成功后才提交内存状态。

AI API Key 由 <code>SecureStorageService</code> 写入操作系统凭据存储。应用不读取或展示已保存的密钥明文。

### 4.6 AIService

<code>AIService</code> 支持 OpenAI 和 Anthropic 官方接口：

- Provider 和模型配置校验。
- 模型列表读取。
- SSE 流式响应。
- 连接超时、响应超时、有限重试和退避。
- 请求级取消、响应大小限制和上下文裁剪。
- 当前请求所有权保护，旧请求结束不能清除新请求状态。
- 未分类 Provider 异常转换为安全错误。

AI 只返回文本，不直接写入用户工作区。由用户触发的文件操作仍必须经过 <code>WorkspaceService</code>。

### 4.7 TaskService

任务索引、日志和结果保存在 <code>.Courier/tasks/</code>：

- 状态包含 queued、running、succeeded、failed、cancelling 和 cancelled。
- 支持最大并发、暂停、取消和失败后手动重试。
- 应用重启后将中断中的任务标记为失败。
- 任务结果路径只允许使用由任务 ID 派生的文件名。
- 索引和日志写入串行化。
- 后台持久化失败会暂停队列并向 UI 暴露错误，不产生未处理 Future。
- 切换工作区或关闭应用前等待活动任务取消完成。

### 4.8 GitService

Git 功能使用 <code>Process.start</code>，并设置 <code>runInShell: false</code>：

- 工作目录固定为当前工作区根目录。
- 工作区必须是仓库顶层目录。
- 文件参数经过相对路径和边界校验，并通过 <code>--</code> 分隔。
- 命令具有超时和输出上限。
- 暂存、取消暂存、提交和分支切换串行执行。
- 分支切换同时要求编辑器无未保存文档且 Git 工作树干净。

### 4.9 AppLogger

结构化 JSON Lines 日志保存在 <code>.Courier/logs/</code>：

- 字段包含时间、级别、请求 ID、模块、事件、消息和错误码。
- 常见 Authorization 与 API Key 格式会被脱敏。
- 日志文件达到上限后轮转。
- 日志写入串行化，并在切换工作区时保持目标文件隔离。
- 日志失败不得中断用户操作。

## 五、界面结构

主界面保持三栏桌面布局：

- 左侧：文件树、搜索、过滤和文件操作。
- 中间：多标签编辑器。
- 右侧：AI、任务和 Git 分段标签。
- 设置：覆盖式面板，不卸载主界面状态。

项目使用 Flutter Material 内置图标和现有玻璃组件，没有引入额外 UI 或图标库。

所有异步操作必须满足：

- 按钮或手势触发的 Future 必须被等待或显式管理。
- 异常必须转换为可理解的界面提示。
- Widget 销毁后不得调用 setState。
- 多次并发请求必须验证结果所有权。

## 六、本地状态

~~~text
.Courier/
├── prefs.json
├── logs/
│   ├── app-log-current.jsonl
│   └── app-log-previous.jsonl
├── sessions/
├── tasks/
│   ├── task-index.json
│   ├── task-*.log.jsonl
│   └── task-*.result.md
└── trash/
~~~

<code>.Courier/</code> 是工作区本地运行状态，必须保持在 Git 忽略列表中。

## 七、构建与验证

标准验证顺序：

~~~powershell
flutter pub get
flutter analyze
flutter test
flutter build windows --release
~~~

本地构建脚本：

~~~powershell
.\build_flutter.bat
~~~

Windows CMake 从 Flutter 生成的插件清单读取依赖，并在配置阶段解析 Pub 缓存链接目标，以兼容限制跨卷符号链接遍历的环境。仓库不得写入开发机缓存绝对路径或固定插件版本。

脚本不得：

- 搜索开发机特定的 Flutter 安装路径。
- 构建或复制 Go 产物。
- 只运行单个历史测试文件。
- 在默认发布流水线中省略分析或完整测试。

## 八、自动发布

<code>.github/workflows/auto-release.yml</code>：

- 每 6 小时运行，也支持手动触发。
- 仅在默认分支执行。
- 获取完整 Git 历史和 Tag。
- 没有新提交时正常退出。
- 发布前执行分析、完整测试和 Windows Release 构建。
- 第三方 Action 固定完整提交 SHA。
- 通过 GitHub Release API 创建 Tag 和 Release，不在脚本中调用 <code>git push</code>。
- Release Notes 包含更新内容和完整历史贡献列表。
- 发布前扫描提交信息中的高风险凭据格式。

## 九、Git 约定

- 提交信息使用英文 Conventional Commits。
- 每个提交保持单一、可验证的功能边界。
- 提交前运行与改动风险相匹配的分析、测试和构建。
- 本地维护操作不得执行远程推送。
- 不回退或覆盖来源不明的工作区改动。

## 十、安全约束

- 不在源码、测试、文档、日志或工作流中写入真实凭据。
- 不把用户文件全文写入应用日志。
- 不允许未校验的绝对路径进入文件或 Git 操作。
- 不直接递归删除用户内容。
- 不允许旧 AI 请求、后台任务或 Git 操作在工作区切换后修改新工作区状态。
- 配置或任务索引损坏时保留原文件，不静默覆盖。
