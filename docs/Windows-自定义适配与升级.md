# Windows 版自定义适配与升级指南（Clash V-Ninja）

> 适用场景：上游发布新的 Windows 版（`windows/` 目录）后，把「Clash V-Ninja 支持」这套自定义改动快速补回去。
>
> 核心原则与 macOS 版一致：**一个客户端 = 一个 `$PROXY_MODE`；改动可重复施加，升级后不用凭记忆重改一遍。**
>
> 当前基准：**上游 v1.10.0（2026-11-22 迁移）**。1.10.0 新增了 4 项 IP 信誉检查（`IP纯净度` / `IP代理标记` / `IP机房属性` / `IP黑名单`），Windows 的模式列表没有变化；规则表已按 1.10.0 原文重新对齐。

> 仓库分支模型（main 跟上游 / custom/v-ninja 放适配）与更新命令见 [从上游更新并推送.md](从上游更新并推送.md)。

## 0. 为什么需要这套东西

上游 Windows 包是按 Clash Verge 写死的：配置目录、内核进程名、运行时配置文件名、代理组来源都只认 Verge。Clash V-Ninja 是 Clash Verge 的 fork，目录/内核/配置文件名都不同，所以必须多一个模式分支。

直接手改上游文件的问题是：每次升级都得重来，而且很容易漏。漏了保镖判活，内核明明在跑也会被当成离线，保镖就会误杀 Claude；漏了控制接口候选，规则就无法验证。

所以把改动收敛成规则表 + 执行器：

| 文件 | 作用 |
| --- | --- |
| `tools/vninja-patch-windows.json` | 46 条规则：文件 / 上游原文锚点 / 改后内容 / 预期次数 / 说明 |
| `tools/apply_vninja_windows.ps1` | 补丁执行器（幂等，支持 `-Check` / `-DryRun` / `-Revert` / `-Root`） |
| `tools/deploy_vninja.ps1` | 把打好补丁的文件部署到 `%USERPROFILE%\.claude-switcher`，保留本机配置 |
| `docs/Windows-自定义适配与升级.md` | 本文件：流程、规则清单、失败处理、验证 |

群规则表在仓库里叫 `vninja-patch-windows.json`，与 macOS 的 `tools/vninja-patch.json` 区分开；两个执行器都在 `tools/` 下。

## 1. 快速流程

```powershell
# 在仓库根目录（含 windows\ 的那一层）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\apply_vninja_windows.ps1

# 确认（可反复跑，幂等；全部 SKIP、退出码 0 即完成）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\apply_vninja_windows.ps1 -Check
```

正常输出：

```
[ OK ] 1.1   claude-switch.ps1       模式列表加 v-ninja，并加 clash-ninja 模式名别名
...
--------------------------------------------------------------------
成功 46 · 跳过 0 · 失败 0

语法检查：
  ✓ claude-switch.ps1
  ✓ claude-bodyguard.ps1
  ✓ install.ps1
  ✓ SwitcherUI.ps1
```

再次运行只会输出 `[SKIP]`，不会重复改写。

## 2. 规则清单（46 条）

### windows/claude-switch.ps1（核心）

| # | 上游 1.10.0 位置 | 作用 |
| --- | --- | --- |
| 1.1 | L4-15 | 模式列表加 v-ninja，并加 clash-ninja 模式名别名 |
| 1.2 | L36-46 | 配置目录改为按模式派生（Get-ClashDirCandidates / Get-ClashDirForMode） |
| 1.3 | L329-338 | 新增 Test-IsClashMode / Test-ClashCoreUp；Get-ProxyName 加 v-ninja |
| 1.4 | L347-353 | Test-ProxyAlive 的 Clash 系分支改用 Test-ClashCoreUp |
| 1.5 | L355-377 | auto 判活纳入 ninja-mihomo；get-client / set-client 列表与用法 |
| 1.6 | L391-398 | set-client 切换后重算 CLASH_DIR，提示按模式区分 |
| 1.7 | L788-805 | Find-ClashVerge → Find-ProxyApp（进程 → 注册表 → 安装目录，认 clash-ninja.exe） |
| 1.8 | L962-971 | 新增 Get-ClashConfigCandidates，Get-ClashApi 按模式选运行时配置 |
| 1.9 | L1017-1024 | 控制接口提示改用当前客户端名 |
| 1.10 | L1042-1048 | Get-ClashMode 的 YAML 回退改用候选列表 |
| 1.11 | L1074-1080 | Test-PinnedRules 注释补充 DstPort 形式 |
| 1.12 | L1085-1095 | Test-PinnedRules 兼容 AND(...DstPort...) 展开形式 |
| 1.13 | L1287-1298 | Restart-ClashVerge → Restart-ProxyClient |
| 1.14 | L1338-1344 | 规则置顶成功时带明细 |
| 1.15 | L1573-1579 | TUN 网卡成功时带明细 |
| 1.16 | L1592-1607 | IP 一致 / 时区 / 地区明细 + IPv6 判定（忽略 TUN/Wintun，检查真实 IPv6 出口） |
| 1.17 | L1621-1627 | 保镖成功时带明细 |
| 1.18 | L1798-1819 | 一键修复：取客户端名、Clash 系判定、启动文案 |
| 1.19 | L1836-1843 | 一键修复：非 Clash 分支文案用客户端名 |
| 1.20 | L1851-1864 | 一键修复：全局/直连分支改用 Restart-ProxyClient |
| 1.21 | L1878-1888 | 一键修复：写规则失败分支文案 |
| 1.22 | L1894-1900 | 一键修复：重启验证分支改用 Restart-ProxyClient |
| 1.23 | L1904-1915 | 一键修复：回滚分支改用 Restart-ProxyClient |
| 1.24 | L3055-3061 | rules-status 未配置提示用客户端名 |
| 1.25 | L1107-1125 | 规则写入器：UDP 优先 + AND 形式（对齐 mac 规范 9.2） |
| 1.26 | L1128-1155 | 规则写入器：包装 main 并校验代理组（对齐 mac 规范 9.1） |

> 1.9.0 曾有一条 1.27「出口探测兜底」；1.10.0 上游已经把多源探测和空响应降级做进 `Get-Egress`，所以 1.10.0 规则表不再包含它。

### windows/claude-bodyguard.ps1（保镖）

| # | 上游 1.10.0 位置 | 作用 |
| --- | --- | --- |
| 2.1 | L11-16 | 保镖读取模式后归一化 clash-ninja → v-ninja |
| 2.2 | L26-31 | 保镖存活判定加 v-ninja（ninja-mihomo） |
| 2.3 | L33-39 | 保镖兜底分支兼容两种内核 |
| 2.4 | L41-46 | 保镖循环内重读模式时同样归一化 |

### windows/install.ps1（安装器）

| # | 上游 1.10.0 位置 | 作用 |
| --- | --- | --- |
| 3.1 | L2-11 | 双客户端配置目录识别（V-Ninja 优先） |
| 3.2 | L25-32 | 自动探测顺序：V-Ninja → Clash Verge → 其他 |
| 3.3 | L42-47 | 手动菜单加 9) v-ninja |
| 3.4 | L52-58 | 菜单分支加 9 / v-ninja / clash-ninja |
| 3.5 | L63-69 | 客户端显示名 CLIENT_NAME |
| 3.6 | L202-221 | 组名来源与解析（订阅文件、两种 YAML 写法、多组可选） |
| 3.7 | L286-292 | 安装输出带客户端名 |
| 3.8 | L298-308 | 安装器「不改规则」提示放开到 Clash 系 |
| 3.9 | L325-336 | 重启客户端（仅 Clash 系，用运行中进程的真实路径） |

### windows/SwitcherUI.ps1（界面）

| # | 上游 1.10.0 位置 | 作用 |
| --- | --- | --- |
| 4.1 | L255-264 | 下拉菜单加 Clash V-Ninja |
| 4.2 | L379-385 | clientModes 加 v-ninja（锚点已包含 1.10.0 新增的 4 个 IP 检查项） |

### windows/README.md（文档）

| # | 上游 1.10.0 位置 | 作用 |
| --- | --- | --- |
| 5.1 | L7-13 | 系统要求加 V-Ninja 条目 |
| 5.2 | L51-56 | 多客户端表加 V-Ninja 行 |
| 5.3 | L59-76 | 新增「Clash 系客户端」小节 + TUN 明细文案 |
| 5.4 | L94-100 | 控制接口提示改为 Clash 系 |
| 5.5 | L240-246 | 已知限制改为 Clash 系 |

> 「上游位置」是 v1.10.0 原始文件里的行号，只用于定位，换版本后会变；以 `vninja-patch-windows.json` 里的 `old` 原文为准。

## 3. 规则语义

- 每条规则是**字面替换**：`old` → `new`，`count` 是 `old` 在上游文件中的预期出现次数；不做正则解释，中文与符号原样匹配。
- **幂等**：已经应用过的规则输出 `[SKIP]`，不会重复插入。
- **判定方式**（与 macOS 的 `apply_vninja.py` 一致）：
  - `new` 包含 `old`（追加型）：`new` 出现次数 ≥ `count` 即视为已应用；
  - 其它（替换型）：`old` 归零且 `new` 已就位才算已应用。
- **失败不落盘**：全部规则在内存中执行完、并且 4 个 `.ps1` 语法解析通过后，才统一写文件。任何一条 `[FAIL]` 都退出码 1 且不写。
- **编码与行尾**：`.ps1` 一律写回 UTF-8 with BOM（Windows PowerShell 5.1 需要）；`README.md` 沿用原状；原文件是 LF 就 LF，是 CRLF 就 CRLF（仓库工作区因 `core.autocrlf=true` 通常是 CRLF）。
- **备份**：首次改写前生成 `<文件>.vninja.bak`（上游原文），`-Revert` 从它还原。用 git 管理时也可以 `git checkout`。

## 4. 失败怎么办

两类提示：

1. **锚点整段找不到**（上游重写了这段）：

   ```
   [FAIL] 1.1   claude-switch.ps1   [1.1] claude-switch.ps1 找不到锚点（上游这段可能已重写）
   ```

2. **只改了其中几处 / 部分回退**：

   ```
   [FAIL] 1.12  claude-switch.ps1   [1.12] claude-switch.ps1 部分匹配：旧串仍有 1 处（预期 2）
   ```

处理步骤：

1. 按 `id` 到第 2 节找「作用」，打开上游文件定位同类代码；
2. 手工改成与「作用」描述一致的行为；
3. 把 `vninja-patch-windows.json` 里该条规则的 `old`/`new` 更新为新版原文；
4. 再跑 `-Check`，直到全部 `[SKIP]`。

上游常见变动与重点规则：

| 上游变动 | 重点看 |
| --- | --- |
| 函数改名 / 重构 | 按「作用」列找同一逻辑，必要时拆成多条规则 |
| 规则校验的 payload 形式（`DST-PORT,` / `AND(...DstPort...)` / `DstPort`） | 1.11 / 1.12 |
| 安装器组名解析重写 | 3.6 |
| 新增检查项 / 界面行 | 4.2（`$checkNames` 是锚点的一部分） |
| 新增客户端 / 新增模式判断 | 1.3 / 1.4 / 4.1 / 4.2 |

## 5. 部署与环境侧

`deploy_vninja.ps1` 做的事（不需要管理员）：

- 备份到 `%USERPROFILE%\.claude-switcher\backup-<旧版本>-<时间戳>\`（三个脚本 + `proxy-mode.txt` + `version.txt`）
- 替换 `claude-switch.ps1` / `claude-bodyguard.ps1` / `SwitcherUI.ps1`
- 保留 `COUNTRY_TARGET` / `TZ_TARGET` / `LOCALE_TARGET`；`PROXY_MODE` 设为 `v-ninja`
- `PROXY_GROUP`：默认沿用现值，也可 `-Group "💬 Ai平台"` 指定
- `proxy-mode.txt` = `v-ninja`；`version.txt` = 当前版本（源码仓库没有 `VERSION` 时取 `git describe --tags`）；删除 `update-check.json` 缓存
- 重启 `ClaudeBodyguard` 计划任务；最后跑 `get-client` + `check` 自检

仍需管理员、不在脚本范围内：锁时区、设置地区格式、关闭 IPv6、重注册计划任务。

**`version.txt` 必须写成本次上游版本。**部署脚本会优先读 VERSION，其次用 git describe --tags（源码仓库）；仍取不到时可用 -Version 1.10.0 显式指定。 如果系统里是旧版本号，界面会提示更新；点「一键更新」会下载官方原版，把 v-ninja 适配覆盖掉。

### 5.1 可选：IP 信誉四联检（1.10.0 新增）

1.10.0 新增 `IP纯净度` / `IP代理标记` / `IP机房属性` / `IP黑名单` 四项检查，数据来自外部信誉接口。**默认没有配置数据源**，所以显示 `warn:未配置信誉数据源`（黄色「警」），不是故障，也不影响 `check` 通过。

- **想启用**：在 `checks.json` 里加 `ipReputation`（URL 必须 https；接口返回 JSON 里带 `fraud_score` / `is_proxy` / `is_datacenter` / `blacklist` 一类字段即可，解析器兼容多种命名）：

  ```json
  {
    "ipReputation": {
      "url": "https://example.com/api/ip/{ip}",
      "key": "你的密钥",
      "threshold": 70,
      "cacheDays": 7
    }
  }
  ```

- **想关闭**：设置页取消勾选，或在 `disabled` 里加这四项：

  ```json
  {"disabled":["IP纯净度","IP代理标记","IP机房属性","IP黑名单"]}
  ```

- 界面只提供开关，不提供 URL/Key 编辑；用 `checks.json`（或 `set-check-config`）写入。中文参数走命令行容易被控制台编码破坏，建议直接编辑 `checks.json`（UTF-8，无 BOM）。
### 5.2 IPv6 怎么判定

- **旧逻辑**：`Get-NetAdapterBinding -ComponentID ms_tcpip6` 里只要有一块网卡 `Enabled`，就输出 `IPv6=fail:未关闭`。
- **问题**：Clash 的 TUN 网卡（`Meta`，Wintun）在每次客户端启动/重启时重建，默认带 `ms_tcpip6` 绑定，但通常只有 `fe80::` 链路本地地址、没有 `::/0` 路由，实际出不了 IPv6。结果就是关掉后一重启又报“未关”。
- **新逻辑**（已包含在规则 1.16）：
  1. 存在**非链路本地** IPv6 地址（`fe80:` / `::1` 之外）或 `::/0` 默认路由 → `IPv6=fail:仍有 IPv6 出口(...)`；
  2. 否则只看**非隧道网卡**（排除 `Tunnel|Wintun|TAP|Tailscale|VPN`）的 `ms_tcpip6`：有启用 → `IPv6=fail:未关闭(网卡名)`；
  3. 只剩隧道网卡启用 → `IPv6=ok:已关闭(仅 TUN 网卡启用)`。

想真正关闭物理网卡的 IPv6（管理员 PowerShell）：

```powershell
Get-NetAdapterBinding -ComponentID ms_tcpip6 | Where-Object Enabled | Disable-NetAdapterBinding -Confirm:$false
```

TUN 网卡（`Meta`）不用管：它会被客户端重建，检查也已忽略它。
## 6. 验证清单

```powershell
$core = "$env:USERPROFILE\.claude-switcher\claude-switch.ps1"
& powershell -NoProfile -ExecutionPolicy Bypass -File $core get-client      # client=v-ninja
& powershell -NoProfile -ExecutionPolicy Bypass -File $core rules-status    # pinned=yes
& powershell -NoProfile -ExecutionPolicy Bypass -File $core check           # OK:环境检查通过
& powershell -NoProfile -ExecutionPolicy Bypass -File $core checkdetail     # 每项都带明细
```

客户端侧：

- `%APPDATA%\io.github.clash-verge-ninja.clash-verge-ninja\config.yaml` 能读到 `external-controller` / `secret`
- `profiles\Script.js` 含 `// >>> claude-switcher managed rules >>>` 托管块（包装 `main`、校验代理组、UDP 优先）
- 内核 `/rules` 前 16 条 = 3 个 UDP 端口 + 13 个域名，且目标组正确

## 7. 常见坑

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 中文乱码 / 脚本报错 | `.ps1` 存成了 UTF-8 无 BOM | 重新加 BOM；执行器会自动补 |
| `代理内核=fail:...未运行` | 只认 `verge-mihomo` | 规则 1.4 / 2.2 |
| `未找到控制接口` | 候选配置文件名不含 `config.yaml` | 规则 1.8 |
| 组名解析不到 / 组名对不上 | V-Ninja 的组在订阅文件里，且组名必须完全一致 | 规则 3.6；`$PROXY_GROUP` 从订阅里复制 |
| `规则置顶=fail` | 内核把 `DST-PORT` 展开成 `AND(...DstPort...)` | 规则 1.12 |
| 保镖把 Claude 关了 | 保镖模式/内核名不匹配 | 规则 2.2 / 2.3；确认 `proxy-mode.txt` 与核心 `$PROXY_MODE` 一致 |
| IPv6 一直提示未关 | Clash TUN（Meta，Wintun）网卡启用 IPv6 但没有 IPv6 出口 | 已在新判定里忽略隧道网卡，详见 5.2 |
| 升级后又得改一遍 | 手改上游文件、没进规则表 | 用本套规则表；新改动先补 JSON |
| 官方一键更新后适配没了 | 官方包不含 v-ninja，且会保留 `PROXY_MODE=v-ninja` | 先打补丁再部署；或升级后重跑本流程 |

## 8. 与 macOS 规范的对应

| macOS 触点 | Windows 对应 | 规则 |
| --- | --- | --- |
| `clash_dir_for_mode()` | `Get-ClashDirCandidates` / `Get-ClashDirForMode` | 1.2 |
| `proxy_name` / `proxy_app_name` | `Get-ProxyName` / `Get-ProxyAppProcessNames` | 1.3 / 1.7 |
| `proxy_alive()` | `Test-ClashCoreUp` / `Test-ProxyAlive` | 1.3 / 1.4 |
| `is_clash_mode()` | `Test-IsClashMode` | 1.3 |
| `controller_config()` 候选文件 | `Get-ClashConfigCandidates` | 1.8 / 1.10 |
| `set_client()` / `get_client()` | `Set-ClientMode` / `Get-Client` | 1.5 / 1.6 |
| 保镖 `case "$MODE"` | `Test-ClientAlive` | 2.2 / 2.3 |
| `installer/安装.command` | `install.ps1` | 3.1–3.9 |
| `app/main.swift` 的 `clientChoices` | `SwitcherUI.ps1` 下拉 | 4.1 / 4.2 |
| 自检明细（TUN/时区/地区/规则置顶） | `Invoke-CheckDetail` | 1.14–1.17 |

## 9. 本次适配记录（v1.10.0）

- 上游：ClaudeSwitcher v1.10.0 源码（`windows/`）
- 1.10.0 变化：新增 4 项 IP 信誉检查、`Get-Egress` 多源兜底；Windows 模式列表未变
- 新增模式：`v-ninja`（显示名 Clash V-Ninja）；兼容旧版用过的模式名 `clash-ninja`
- 配置目录：`%APPDATA%\io.github.clash-verge-ninja.clash-verge-ninja`（`%LOCALAPPDATA%` 兜底）
- 内核进程：`ninja-mihomo`；界面进程：`clash-ninja`；可执行文件：`clash-ninja.exe`
- 运行时配置：`config.yaml`（V-Ninja）→ `clash-verge.yaml` → `verge.yaml`
- 组名来源：`profiles.yaml` 的 `current:` → `profiles/<uid>.yaml`；兼容两种 YAML 写法；多个 select 组时让用户选
- 规则写入：`profiles\Script.js` 托管块（包装 `main` + 校验代理组；前 3 条 UDP 用 `AND,((NETWORK,UDP),(DST-PORT,port))`，后 13 条域名）
- 验证：干净 v1.10.0 + 两套 tools = 当前工作区 10 个文件逐字节一致；`-Check` 全部 SKIP、退出码 0
