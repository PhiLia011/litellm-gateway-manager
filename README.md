# LiteLLM 网关管家

> 一个中文交互式控制台，把 **所有 LLM 厂商** 收敛到本机一个入口，
> 让 [Codex CLI](https://github.com/openai/codex)（以及任何 OpenAI 兼容客户端）
> 只认一个 provider。加厂商、加模型、换 key，全在菜单里点，不用改配置。

<p align="center">
  <em>Windows 10/11 · PowerShell 7 · LiteLLM</em>
</p>

---

## 它解决什么问题

用 Codex 接国产模型时，通常要维护这些东西：

- `~/.codex/config.toml` 里每家一个 `[model_providers.xxx]` 段
- 每家一个档位文件 `<名字>.config.toml`
- 每家一个环境变量存 key

于是"换一家/加一家模型"要动 **三个地方**，还容易忘。

本项目在中间加一层本机网关：

```
Codex CLI / Codex App / 任何 OpenAI 兼容客户端
      │   http://127.0.0.1:4000/v1   (只监听本机)
      ▼
LiteLLM 网关            ← 厂商/模型/key 全在这里维护
      │   原生 Responses 透传，或自动桥接到 /chat/completions
      ▼
DeepSeek │ 阿里云百炼 │ 智谱 GLM │ 月之暗面 │ 硅基流动 │ ……
```

之后 Codex 永远只认：

```toml
model_provider = "litellm"
```

**换厂商、加模型、换 key —— Codex 侧一个字都不用改。**

## 特色

- 🖱️ **中文菜单，双击就用**：不用记任何命令
- 🔑 **密钥不落盘**：只存在 Windows 用户环境变量里，配置文件里全是 `os.environ/XXX` 引用
- 🔍 **协议自动探测**：加厂商时自动试「原生 Responses」和「桥接」两种模式，告诉你哪种能用
- 🧪 **一键体检**：逐个模型发真实请求，把英文报错翻译成人话（欠费、密钥错、地址错、超时）
- 🗂️ **数据源与生成物分离**：你只维护 `providers.json`，`config.yaml` 自动生成
- 🔒 **只监听 127.0.0.1**，不对外暴露
- 📦 **可移植**：整个文件夹克隆到哪都能跑，用 `%~dp0` / `$PSScriptRoot` 定位自己

---

## 环境要求

| 依赖 | 说明 |
| --- | --- |
| Windows 10 / 11 | 目前只做了 Windows（用了 cmd + 计划任务 + 用户环境变量） |
| [PowerShell 7](https://aka.ms/powershell) | 菜单是 `.ps1`；**不要用系统自带的 5.1**（它按 GBK 读文件，中文会乱） |
| [uv](https://docs.astral.sh/uv/) 或 pip | 用来装 LiteLLM |
| [Codex CLI](https://github.com/openai/codex) | 可选；任何 OpenAI 兼容客户端都能用这个网关 |

---

## 安装

```powershell
# 1) 安装 LiteLLM
uv tool install "litellm[proxy]"

# 2) 把本仓库放到 %USERPROFILE%\.litellm
git clone https://github.com/PhiLia011/litellm-gateway-manager "$env:USERPROFILE\.litellm"

# 3) 设置厂商密钥（按你需要，变量名要和 providers.json 里的 envKey 对应）
setx DEEPSEEK_API_KEY "sk-你的key"
setx DASHSCOPE_API_KEY "sk-你的key"
setx ZAI_API_KEY "你的key"

# 4) 中文 Windows 上的两个必设开关
setx PYTHONUTF8 1
setx PYTHONIOENCODING utf-8
setx LITELLM_LOCAL_MODEL_COST_MAP True

# 4b) 如果开着代理（Clash / v2ray 等），本机地址必须绕过代理，否则 Codex 会收到 502
setx NO_PROXY "127.0.0.1,localhost"
#    原本已有值的话保留原值再补，例如：
#    setx NO_PROXY "127.0.0.1,localhost,api.deepseek.com"

# 5) 生成网关自身的鉴权 key
$k = "sk-" + (-join (1..48 | ForEach-Object { "0123456789abcdefghijklmnopqrstuvwxyz"[(Get-Random -Maximum 36)] }))
setx LITELLM_MASTER_KEY $k

# 6) 启动网关
& "$env:USERPROFILE\.litellm\start-gateway.cmd"
```

> 第 3~5 步设的是**用户级环境变量**，设完需要**重新打开终端**（或重新登录）才会生效。

然后双击 `网关管家.cmd`。

### 接上 Codex

编辑 `~/.codex/config.toml`：

```toml
model = "deepseek-chat"          # 用 providers.json 里的某个 alias
model_provider = "litellm"

[model_providers.litellm]
name = "LiteLLM Gateway"
base_url = "http://127.0.0.1:4000/v1"
wire_api = "responses"
env_key = "LITELLM_MASTER_KEY"
# 长 agent 回合容易被网关"静默"卡住，建议放宽超时和重试
stream_idle_timeout_ms = 7200000
stream_max_retries = 5
request_max_retries = 4
```

### 设置开机自启（可选）

```powershell
$dir = "$env:USERPROFILE\.litellm"
$action  = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$dir\run-hidden.vbs`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
         -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -Hidden
Register-ScheduledTask -TaskName "LiteLLM-Gateway" -Action $action -Trigger $trigger `
  -Settings $set -Description "LiteLLM 本机网关" -Force
```

`run-hidden.vbs` 的作用是把控制台窗口藏起来——否则开机后桌面上会一直挂着一个黑窗口，
而关掉它就等于杀掉网关。

---

## 使用

双击 **`网关管家.cmd`**：

```
  ╔══════════════════════════════════════════════╗
  ║            LiteLLM 网关管家                  ║
  ╚══════════════════════════════════════════════╝
     状态：● 运行中
     默认模型：deepseek-chat

    1. 查看状态和可用模型
    2. 测试每个模型能不能用（推荐先用这个）
    3. 切换 Codex 默认模型
    4. 厂商与模型管理  << 加厂商 / 加模型
    5. 密钥管理        << 加 key / 换 key
    6. 启动 / 重启网关
    7. 停止网关
    8. 查看最近日志
    9. 快速上手说明
   10. 打开配置文件夹
    0. 退出
```

### 加一家新厂商（`4` → `2`）

依次回答：厂商名称 → 接口地址 → 密钥变量名 → 模型别名 → 上游模型名。
存完自动探测协议：

```
  v 已登记 Moonshot 月之暗面 / kimi-k2
  正在自动探测协议（最多试两种，约 10~30 秒）...
    正在用【原生 Responses】重启网关并测试...

  v 探测成功，这家用【原生 Responses 协议】
    现在可以直接：codex --model kimi-k2
```

探测逻辑：先试 **原生 Responses**（`openai/` 前缀，协议不翻译，保真度最高），
失败再试 **桥接模式**（`custom_openai/` 前缀，LiteLLM 把 `/responses` 转成
`/chat/completions`）。哪种通用哪种，你不用自己判断。

### 命令行模式（脚本化用）

```powershell
pwsh gateway-menu.ps1 -Status        # 打印状态
pwsh gateway-menu.ps1 -TestAll       # 测试全部模型
pwsh gateway-menu.ps1 -Restart       # 重启网关
pwsh gateway-menu.ps1 -Regenerate    # 只重新生成 config.yaml
```

---

## 数据源与生成物

```
providers.json   ← 【数据源】厂商 / 模型 / 密钥变量名（首次运行自动从 .example 生成）
      │  网关管家自动生成
      ▼
config.yaml      ← 【生成物】喂给 LiteLLM，请勿手工修改
```

`providers.json` 里只存**环境变量名**，不存密钥明文：

```json
{
  "id": "bailian",
  "name": "阿里云百炼（Qwen）",
  "baseUrl": "https://dashscope.aliyuncs.com/compatible-mode/v1",
  "envKey": "DASHSCOPE_API_KEY",
  "wireMode": "responses",
  "models": [
    { "alias": "qwen-max", "upstream": "qwen-max" }
  ]
}
```

- `alias` —— 客户端里用的名字
- `upstream` —— 厂商文档里的真实 model id
- `wireMode` —— `responses`（原生透传）或 `chat`（桥接）；菜单会自动探测

---

## 安全说明

| 项 | 做法 |
| --- | --- |
| 密钥存放 | 只在 Windows **用户级环境变量**里；仓库和配置文件里没有任何明文 |
| 配置文件 | `config.yaml` 里全是 `os.environ/XXX` 引用 |
| 网络暴露 | 网关**只监听 `127.0.0.1`**，不对外网开放 |
| 网关鉴权 | `LITELLM_MASTER_KEY`，Codex 与网关共用同一个值 |
| 版本控制 | `.gitignore` 已排除 `providers.json` / `config.yaml` / `logs/`，你的真实厂商清单不会进仓库 |

---

## 踩坑记录（改代码前请先看）

这些都是实际踩出来的，不是理论：

1. **`start-gateway.cmd` 必须保持纯 ASCII。**
   cmd.exe 按 GBK 读 `.cmd`；UTF-8 中文会被撕碎，甚至**吃掉换行**，
   把脚本变成一堆 `'ot' 不是内部或外部命令`。中文只放在 `.ps1` 和 `.md` 里。
2. **启动器里刻意没有"端口已占用就跳过"的护栏。**
   加过，但它是灾难：菜单重启时会先杀旧进程，socket 释放有延迟，
   护栏误判成"已在运行"就**静默跳过**，表现为"重启失败"却查不到任何日志。
   现在重复启动最多是一个 bind 报错，无害。
3. **`gateway-menu.ps1` 必须用 PowerShell 7 跑。**
   Windows PowerShell 5.1 会按 GBK 解析 `.ps1`，中文注释会让脚本错乱。
   `网关管家.cmd` 已写死调用 `pwsh`，正常双击不受影响。
4. **别把脚本里的 `$GwUrl` 改成 `$baseUrl` 之类的名字。**
   PowerShell 变量名**不区分大小写**，而且函数局部变量会**遮蔽**被调用函数里
   读到的同名变量。曾经因为 `$apiBase` 撞名 `$BaseUrl`，导致加厂商时健康检查
   跑去请求 `https://api.deepseek.com/health/readiness`，轮询 77 秒全失败——
   而且函数返回后值自动恢复，事后完全看不出问题。
5. **`$ErrorActionPreference = "Stop"` + 原生程序写 stderr = PowerShell 5.1 自杀。**
   5.1 会把原生命令的 stderr 当成终止性错误。本项目因此绕开了 PowerShell 启动链路。
6. **中文 Windows 上 Python 默认用 GBK 读文件**，带中文注释的 `config.yaml`
   会抛 `UnicodeDecodeError`。所以要 `PYTHONUTF8=1`。
7. **LiteLLM 启动时会去 GitHub 拉价格表**，在国内经常失败并重试 3 次（白等约 10 秒）。
   `LITELLM_LOCAL_MODEL_COST_MAP=True` 可跳过。
8. **开了代理（Clash / v2ray 等）时，Codex 会把发往本机网关的请求也丢给代理，得到 502。**
   这个症状极其迷惑：Codex 报
   `502 Bad Gateway: url: http://127.0.0.1:4000/v1/responses`，
   但**网关日志里完全没有这条请求** —— 因为它根本没到网关，被代理拦下了。
   处理：把回环地址加进 `NO_PROXY`（本地地址永远不该走代理）：

   ```powershell
   setx NO_PROXY "127.0.0.1,localhost"
   # 若原本已有值，保留原值再补上，例如：
   # setx NO_PROXY "127.0.0.1,localhost,api.deepseek.com"
   ```

   注意环境变量是**进程启动时**读取的，设完要重开终端 / 重启 Codex。

---

## 排查

| 症状 | 原因 / 处理 |
| --- | --- |
| 菜单里测试全部失败 | 网关没运行：主菜单 `6` 启动 |
| `Invalid model name passed in model=xxx` | 该别名没登记，或改完没重启网关（菜单 `4` → `7`） |
| 401 / Unauthorized | 当前终端没有 `LITELLM_MASTER_KEY`；**新开终端**或重新登录 |
| 上游 403 `Free quota exhausted` | **厂商额度问题，不是网关问题**：充值或关掉"仅用免费额度" |
| 加厂商探测两种都失败 | 密钥不对 / 接口地址写错 / 该家不支持这两种协议 |
| **Codex 报 502，但网关日志里没有这条请求** | 代理把本机请求也拦截了 → 把 `127.0.0.1,localhost` 加进 `NO_PROXY`（见踩坑 8） |
| 启动慢约 10 秒 | `LITELLM_LOCAL_MODEL_COST_MAP=True` 丢了 |
| 启动报 `UnicodeDecodeError: 'gbk'` | `PYTHONUTF8=1` 丢了 |

---

## 文件清单

```
.
├── 网关管家.cmd          ← 【平时只碰这个】双击打开中文菜单（改名成任意 .cmd 都行）
├── gateway-menu.ps1      ← 菜单本体 + 全部管理逻辑（中文，需 PowerShell 7）
├── providers.example.json ← 厂商清单示例，首次运行会自动复制成 providers.json
├── start-gateway.cmd     ← 启动器（计划任务与手动启动共用，必须纯 ASCII）
├── run-hidden.vbs        ← 隐藏控制台窗口，供计划任务调用
└── logs/                 ← 运行日志（不入仓库）

providers.json            ← 你的真实厂商清单（不入仓库）
config.yaml               ← 自动生成（不入仓库）
```

---

## License

[MIT](LICENSE)
