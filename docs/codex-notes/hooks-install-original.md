# Codex Desktop 手动安装 orch-lite 钩子

## 结论

orch-lite 插件的钩子本体不需要复制到哪里去，Codex 会从插件包的 `hooks/hooks.json` 自动发现。真正需要手动处理的，是把这两个钩子标记为「trusted」，否则 Codex 会把它们识别为 `untrusted`，然后拒绝执行。

正确安装后，`~/.codex/config.toml` 里会新增下面两项：

```toml
[hooks]

[hooks.state."orch-lite@orch-lite:hooks/hooks.json:pre_tool_use:0:0"]
trusted_hash = "sha256:978e3ec0000beda699376b74e2c71c7292ebfbb26716dbdb0f3c1ccea13d822a"

[hooks.state."orch-lite@orch-lite:hooks/hooks.json:session_start:0:0"]
trusted_hash = "sha256:633ce887845a96bf39783d20c0a6dc8ba4e99b25bec8d2352f081d327e1241aa"
```

## 对应钩子

| Hook | 作用 |
|---|---|
| `sessionStart` | 运行插件里的 `session-init.py`，在会话开始时注入 orch-lite 的路由说明和状态摘要 |
| `preToolUse` | 匹配 `spawn_agent|Agent|Task`，运行 `dispatch-validate.py`，校验子代理派发包是否符合协议 |

## 插件位置

本机插件缓存路径是：

```text
C:\Users\LIN YU JIAN\.codex\plugins\cache\orch-lite\orch-lite\1.1.2
```

插件内部相关文件：

```text
hooks\hooks.json
hooks\session-init.py
hooks\dispatch-validate.py
```

## 安装方式

我生成过一个幂等脚本，位置：

```text
C:\Users\LIN YU JIAN\Documents\Codex\2026-09-16\orch-lite-orch-lite-c-users\outputs\materialize-orch-lite-hooks.ps1
```

在 PowerShell 里运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\LIN YU JIAN\Documents\Codex\2026-09-16\orch-lite-orch-lite-c-users\outputs\materialize-orch-lite-hooks.ps1"
```

这个脚本会：

1. 先备份 `~/.codex/config.toml`
2. 检查目标 hook 是否已经存在
3. 幂等地追加两条 `trusted_hash` 配置
4. 提示需要重启 Codex Desktop 或开启新 CLI 会话

## 验证

安装后可以检查：

```powershell
Get-Content "$env:USERPROFILE\.codex\config.toml" | Select-String "orch-lite"
```

也可以开一个新的交互式 Codex 会话，然后输入：

```text
/hooks
```

注意：Desktop UI 不一定展示已信任的插件钩子。更可靠的验证是开新会话，看会话开头是否出现 orch-lite 的注入内容。`sessionStart` 在会话开始时生效；`preToolUse` 只有在真正派发子代理时才会触发。

## 注意事项

- 钩子快照在会话开始时加载，改完配置后必须重启 Codex Desktop 或新开会话。
- `hooks.state` 是 Codex 的持久化信任状态，不是普通项目配置。
- 如果插件版本升级，钩子内容或 hash 可能变化，Codex 可能会把状态显示为 `modified`，需要重新 review。
- 如果需要回滚，用脚本生成的 `config.toml.bak-orch-lite-*` 备份文件还原即可。
