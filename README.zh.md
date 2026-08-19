# dsh-fork — DeepSeek Harness 个人分叉

[English](README.md) | 中文

这是 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（`dsh`）的个人分叉。dsh 是由 [DeepSeek AI](https://deepseek.com) 开发的开源 agent harness（智能体框架），采用**一切皆插件**的架构，由 [Cordis](https://github.com/cordiverse/cordis) 驱动。

## 与上游的差异

### 启用 LAN 访问 / 远程部署

去掉了上游禁止 `--host 0.0.0.0` 的安全开关。现在可以在所有网络接口上启动 Web UI，用于局域网或隧道访问：

```sh
pnpm dsh web --host 0.0.0.0 --port 34567 --trusted-host dsh.example.com
```

默认端口从 `3080` 改为 `34567`，避免与本地开发服务器冲突。

### Windows GUI 启动器

- **`dsh-web.pyw`** — 可双击运行的 Python/tkinter 图形启动器，提供主机/端口/信任主机配置和启动/停止控制。需要 Python 3.10+（内置 tkinter）。
- **`dsh-web.ps1`** — PowerShell/WinForms 启动器，支持系统托盘图标、气泡通知和后台进程管理。需要 Windows 和 PowerShell 5.1+。
- **`test-launch.ps1`** — 诊断脚本，用于验证启动器管道。
- **`replace-node.ps1`** — 辅助脚本，将全局 Node.js 替换为特定版本（需要管理员权限）。

### Windows 开发者体验

- Windows 上跳过 lefthook 安装（平台不支持）；自动恢复锁文件。
- `package.json` 脚本适配 Windows 兼容性。

### LLM 重试修复

- 配额超限错误（`429`）现在会重试而不是立即失败。
- 限流优先级修复，确保正确的错误类型触发退避。
- 整体重试预算增加，提高生产环境鲁棒性。

### Subagent 模型继承

Subagent 现在从**父级的请求日志配置**（所有模型选择瀑布覆盖生效后的持久记录）继承其有效的 provider/model，而不是从过时的创建时 `AgentOptions` 继承。这修复了父级在 Web UI 中通过 `session.selectModel()` 切换模型后，子级仍使用旧模型的问题。

### 浏览器兼容性

在浏览器端代码中将 `crypto.randomUUID()` 替换为 `crypto.getRandomValues()`，修复了非安全上下文或代理环境中的崩溃问题。

## 运行

### 从源码运行

```sh
git clone https://github.com/ID-VerNe/dsh-fork.git
cd dsh-fork
pnpm install
pnpm run build
pnpm dsh web
```

或者双击 `dsh-web.pyw`（Windows）使用图形启动器。

## 许可证

[MIT](LICENSE)

第三方依赖及其许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
