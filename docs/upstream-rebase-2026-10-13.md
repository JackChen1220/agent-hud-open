# Agent HUD 上游 rebase 同步记录 · 2026-10-13

已将原有定制作为一个独立补丁提交，使用 `git rebase` 重放到最新上游。原同步分支保留完整历史与恢复点，原目录的 `main` 及未提交文件保留。

## 版本与分支

- 上游仓库：[`jazzenchen/agent-hud-open`](https://github.com/jazzenchen/agent-hud-open)。
- 上次上游基线：`f60b0a22dd5c93782eec5e36c3670c77596ecf64`，0.4.39-beta.2。
- 本次上游基线：`2105309ed0317d9cbe8d83870169c96a90d018d1`，0.5.3 及其后 main 的紧凑提醒、缩放与文档调整。共新增 103 个提交，168 个文件发生变化。
- 新分支：`feat/chengang/rebase-upstream-20261013`。
- 工作目录：`/Users/assinte/.codex/worktrees/agent-hud-upstream-sync/agent-hud-open`。
- 保留分支：`feat/chengang/sync-upstream-20261009`，`76676a7b23911a30a89f1c4d6517fa10702c26cb`。
- 应用构建版本：0.5.3 / build 17。

旧分支包含上游合并提交；直接逐条重放旧提交会再次处理首次迁移前的目录结构。先从原上游基线构造仅含本地定制的提交，其 tree 与旧分支末端完全一致，再 rebase 到本次基线。这样上游提交完整成为新分支祖先，本地变更位于其后，旧分支不需要改写或强推。

## 本次上游更新

- 新增 Simple（简约）模式，额度圆环、百分比、余额与浮动面板；原 Logo 模式显示为 Dynamic（动态）。
- Logo 可变为跟随指针、眨眼的 Bot；分 Agent 模式支持悬停小卡片、点击完整面板和独立提醒。
- 支持 Codex Desktop 原生 Computer Use 审批及回合中的提问，包括只有文本输入的提问。
- 支持较长 Codex Desktop 会话的 IPC 帧，按读取耗时降低读取频率；最近日志每五秒检查追加变化。
- 账户读取频率按工作状态调整并增加随机错峰；设置可刷新账户并移除已确认退出的旧账户。
- Grok 余额、按量账单、不可用额度与 routine 子会话处理改进；提醒和图表展示细节修复。

## 定制与冲突处理

| 定制 | 迁移结果 |
| --- | --- |
| 分支 / worktree Hub 与 Git 操作 | 保留项目状态、手动进度、选定文件操作及带兼容未提交改动切换分支 |
| Kiro credits 与 CLI 元数据 | 保留精确 credits、额度池、已完成轮次、独立 credits 与原始 token 数据，兼容新可空额度与各窗口观测时间 |
| 紫色 Kiro 图标 | 保留原紫色方块和白色小幽灵；补上原生 Bot 支持，仅动画黑色眼睛，静态与动画都不附加描边 |
| 无虚线框 | 全部移除拖动边框绘制，点击、长按、拖动均透明；Simple 同样适用，保留上游 6 pt / 0.3 s 拿起手势、点击回调与光标管理 |
| Hub 操作与外观 | 保留 ⌘⇧H、可配置快捷键、固定按钮、深色 Hub 和切换标签后即时测量高度，兼容分 Agent 内容过滤 |
| 会话来源 | 保留客户端名称，WorkBuddy 等没有额度卡片的会话仍可辨认；继续按等待、运行及最近结束筛选 |
| 刘海与布局 | Dynamic 居中队列在实体刘海下方显示；Simple 初次选择仍按上游避开刘海，从左侧开始 |
| 本地采集与性能 | 账户步骤独立串行运行，慢账户请求不阻塞本地生命周期；并入上游错峰调度与近期日志检查 |
| Codex 引擎及日志 | 保留原生嵌套引擎优先、长行分段进度和无关工具输出跳过；保留压缩日志重启位置支持 |

18 个冲突文件逐处整合。新增 Bot 全量测试发现 Kiro 缺少动画描述，已补齐并沿用原图。

## 验证与交付

- `make check` 与 `git diff --check`：通过。
- 重点回归：105 项，含 2 个默认跳过的本机探针，无失败；覆盖拖动、Simple、分 Agent 面板、Hub、Kiro、分支操作与账户调度。
- Core 全量：951 项，6 个可选本机探针按默认配置跳过，无失败。记录在 `rebase-20261013-full-tests.log`；该轮发现的 Desktop 失败仅为缺失 Kiro Bot。
- 补齐 Kiro Bot 后，Desktop 全量：303 项无失败，记录在 `rebase-20261013-desktop-final.log`。Core 源码此后未改动。
- `scripts/build-app.sh debug`：0.5.3 / build 17 应用构建成功，ad-hoc 签名、资源和 macOS 14.0 部署目标 / SDK 27.0 标记检查通过。
- Bot 快照：工作、提问、完成、静止及变形 5 种图表成功渲染，实际检查 Kiro 原图、黑色眼睛和无附加描边效果。
- 原目录全部 327 个 tracked / 非忽略 untracked 源文件指纹、`main` HEAD、未提交状态及旧同步分支 HEAD 一致。

日志、快照与恢复指纹位于 `build/validation/rebase-20261013-*`。应用位于 `build/Agent HUD Open.app`。本次交付为源码同步与构建；安装目录仍为 0.4.39 / build 16。

原目录的 tracked 与非忽略 untracked 文件均用 SHA-256 比对，`main` HEAD、未提交状态及旧集成分支 HEAD 同时检查。
