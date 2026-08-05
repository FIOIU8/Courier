# Courier Flutter

Courier Flutter 是一个面向本地工作区的 Windows 桌面 AI 代码编辑器。应用使用 Flutter 和 Dart 实现文件编辑、AI 对话、任务队列与 Git 操作，不依赖 Go 运行时、Go 服务或外部动态库。

## 功能

- 工作区文件树：异步扫描、分类过滤、排除规则、隐藏文件设置和文件拖放。
- 安全文件操作：工作区边界校验、符号链接保护、UTF-8 与大小检查、原子保存和外部修改冲突检测。
- 多标签编辑器：新建、打开、另存为、自动保存、未保存关闭确认和删除影响保护。
- AI 助手：OpenAI 与 Anthropic Provider、系统凭据存储、模型列表、流式响应、取消生成和 Markdown 渲染。
- 本地任务队列：工作区级持久化、并发执行、进度、日志、结果、取消与受限重试。
- Git 面板：状态、按文件差异、暂存、取消暂存、提交、分支列表与安全切换。
- 工作区配置：偏好、任务、日志和隔离区统一保存在 <code>.Courier/</code>。

## 平台

| 平台 | 状态 |
| --- | --- |
| Windows Desktop | 当前发布目标 |
| macOS Desktop | 尚未纳入发布流水线 |
| Linux Desktop | 尚未纳入发布流水线 |

## 安装

从 [GitHub Releases](https://github.com/FIOIU8/Courier/releases) 下载最新的 Windows 压缩包，完整解压后运行 <code>courier_flutter.exe</code>。

发布包中的可执行文件、Flutter 引擎和插件库必须保持在同一目录结构中。应用运行不需要额外的 Go 产物。

## 本地开发

环境要求：

- Flutter 3.44.0 或更高稳定版本。
- Dart 3.12.0 或更高版本。
- Windows 10 或更高版本。
- Visual Studio 的 Desktop development with C++ 工作负载。
- Git CLI，用于应用内 Git 面板和仓库测试。

安装依赖并执行质量检查：

~~~powershell
flutter pub get
flutter analyze
flutter test
~~~

运行桌面应用：

~~~powershell
flutter run -d windows
~~~

构建 Windows Release：

~~~powershell
flutter build windows --release
~~~

也可以使用仓库内的构建脚本执行完整流水线：

~~~powershell
.\build_flutter.bat
~~~

需要重新生成 Flutter 构建产物时使用：

~~~powershell
.\build_flutter.bat --clean
~~~

## 配置

全局非敏感设置使用平台偏好存储。以下环境变量可覆盖对应的启动设置：

| 变量 | 用途 |
| --- | --- |
| <code>COURIER_AI_PROVIDER_ID</code> | 选择受支持的 AI Provider |
| <code>COURIER_AI_MODEL_ID</code> | 选择 AI 模型 |
| <code>COURIER_TASK_MAX_CONCURRENCY</code> | 设置任务最大并发数 |
| <code>COURIER_LOG_LEVEL</code> | 设置日志级别 |

AI API Key 只能通过应用设置页写入操作系统凭据存储，不会写入工作区配置、SharedPreferences、日志或仓库文件。

每个已打开工作区会创建以下本地状态：

~~~text
.Courier/
├── prefs.json
├── logs/
├── sessions/
├── tasks/
└── trash/
~~~

<code>.Courier/</code> 已加入 Git 忽略规则。删除文件或目录时，内容先移动到 <code>.Courier/trash/</code>，不会直接递归删除。

## 自动发布

<code>.github/workflows/auto-release.yml</code> 每 6 小时检查默认分支，也支持手动触发。只有相对最新 Tag 存在新提交时，工作流才会执行分析、测试、Windows Release 构建、压缩和 GitHub Release 发布。

版本规则：

- 仓库没有 Tag 时使用 <code>v0.1.0</code>。
- 最新 Tag 符合 SemVer 时递增 patch 版本。
- 最新 Tag 不符合 SemVer 时使用包含 UTC 时间和提交短哈希的预发布版本。

Release Notes 包含“更新内容”和“贡献列表”。贡献列表从完整 Git 历史生成并去重。工作流会在发布前检查提交信息中疑似泄露的凭据格式。

## 安全边界

- 文件创建、读取、保存、重命名和隔离操作必须位于当前工作区。
- 工作区根目录和 <code>.Courier/</code> 内部目录不接受符号链接替换。
- 编辑器只打开大小受限的 UTF-8 文本，检测到二进制内容时拒绝加载。
- 保存采用同目录临时文件替换，并通过文件指纹阻止静默覆盖外部修改。
- AI 请求设置连接与响应超时、有限重试、输出大小上限和取消标识。
- Git 命令不通过 shell 执行，工作目录固定为当前仓库根目录。
- 日志会脱敏常见凭据格式，且不记录完整用户文件内容。

## 项目结构

| 路径 | 职责 |
| --- | --- |
| <code>lib/services/</code> | 文件安全、设置、AI、任务、Git、日志和应用服务 |
| <code>lib/widgets/</code> | 文件树、编辑器、AI、任务、Git 与设置界面 |
| <code>test/</code> | 单元测试、Widget 测试和安全回归测试 |
| <code>windows/</code> | Flutter Windows Runner |
| <code>docs/</code> | 系统总结与升级计划 |

## 贡献

提交前必须运行 <code>flutter analyze</code>、<code>flutter test</code>，并在涉及 Windows 插件或发布链路时运行 <code>flutter build windows --release</code>。

提交信息采用英文 Conventional Commits，例如 <code>feat: add workspace isolation recovery</code> 或 <code>fix: preserve active request ownership</code>。Pull Request 应说明行为变化、验证命令和用户数据风险。

## 许可证

本项目采用 [GNU General Public License v3.0](LICENSE)。
