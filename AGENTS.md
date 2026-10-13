# Agent HUD 项目指引

## 工作入口

- 本项目以 `Package.swift` 为入口，`AgentHUDOpen` 是 macOS AppKit / SwiftUI 应用。
- `AgentHUDCore` 与 `AgentHUDSupport` 保持平台无关；系统界面及窗口代码放在 `AgentHUDDesktop`。
- 使用 `scripts/build-app.sh debug` 或 `scripts/build-app.sh release` 构建应用包。桌面验证运行 `.app`，日常安装目录为 `~/Applications/Agent HUD Open.app`。
- `make check` 检查源码边界与忽略规则；`swift test` 运行测试。定向改动先运行相关测试，实际登录探针按需启用。
- 修改前确认 `git status` 和 `git worktree list`。同步分支、当前工作目录与安装记录以[最近一次同步记录](docs/upstream-rebase-2026-10-13.md)及实际 Git 状态为准；保留既有未提交工作和恢复分支。

## 需要保留的行为

- HUD 抓取区域在点击、长按与拖动时均不绘制虚线框，包括 Simple 模式；保留拖动阈值、拿起手势和位置保存。
- Kiro 沿用紫色原图，不加额外描边；动画保留白色幽灵，只让黑色眼睛活动。
- Kiro credits 与 token 计数分别处理，缺失计数不表示零用量，也不从 credits 估算 token。
- 慢账户请求不能阻塞本地会话生命周期采集。账户步骤独立串行执行，并保留读取期间到达的刷新信号。
- 客户端读取沿用现有登录，采集器不刷新、改写登录凭据，不发送模型消息。登录过期时由原客户端更新后再验证。
- 替换安装包前备份旧应用、偏好设置和数据；SQLite 使用一致性备份，保留必要恢复记录。只停止安装路径对应的应用进程。

## 文档路由

- [HUD 行为](docs/hud.md)：形态、交互、会话与本地 Hub 定制。
- [数据源](docs/providers.md)与[数据访问边界](docs/data-access.md)：账户、额度、会话读取及探针。
- [分支与 worktree](docs/repositories.md)：仓库 Hub 的 Git 操作契约。
- [架构](docs/architecture.md)与[命令行](docs/command-line.md)：模块和运行入口。
- [上游同步与安装记录](docs/upstream-rebase-2026-10-13.md)：集成基线、验证结果、恢复点及交付状态。

`CHANGELOG.md` 保留版本历史；详细机制与验证结果放在对应文档，不复制到全局规则或另建兼容正文。
