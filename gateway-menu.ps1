param(
    [switch]$Regenerate,   # 只根据 providers.json 重新生成 config.yaml
    [switch]$Restart,      # 重启网关（会先从注册表补全环境变量）
    [switch]$Status,       # 打印状态后退出（脚本化用）
    [switch]$TestAll       # 测试全部模型后退出（脚本化用）
)

# ============================================================
#  LiteLLM 网关管家（中文交互菜单）
#
#  必须用 PowerShell 7（pwsh）运行，不要用 Windows PowerShell 5.1：
#  5.1 会按 GBK 解析本文件里的中文，直接把脚本搞乱。
#  正常用法：双击同目录下的「网关管家.cmd」
#
#  config.yaml 是【生成物】，数据源是 providers.json。
#  要加厂商 / 加模型 / 改密钥，都在本菜单里做。
# ============================================================

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$OutputEncoding = [Text.Encoding]::UTF8

# 数据目录 = 本脚本所在目录（所以整个文件夹克隆到哪都能直接跑）；
# 没有 $PSScriptRoot 时（被 dot-source / Invoke-Expression 加载）退回默认位置。
$Root      = if ($PSScriptRoot) { $PSScriptRoot } else { Join-Path $env:USERPROFILE ".litellm" }
$Registry  = Join-Path $Root "providers.json"
$CfgYaml   = Join-Path $Root "config.yaml"
$CodexToml = Join-Path $env:USERPROFILE ".codex\config.toml"
$LogFile   = Join-Path $Root "logs\gateway.log"
$Launcher  = Join-Path $Root "start-gateway.cmd"
# ★ 这个变量千万别和「用户输入的接口地址」重名（Add-Provider 里用的是 $apiBase）。
#   PowerShell 变量名不区分大小写，而且函数的局部变量会遮蔽被调用函数里读到
#   的同名变量 —— 一旦撞名，健康检查和测试会跑去请求错误的主机。
$GwUrl     = "http://127.0.0.1:4000"

# ============================================================
#  基础工具
# ============================================================

# 输出被重定向时 Clear-Host 会报「句柄无效」，包一层；真双击时照常清屏
function Clear-Screen { try { Clear-Host } catch { } }

function Get-GatewayKey {
    $k = [Environment]::GetEnvironmentVariable("LITELLM_MASTER_KEY", "Process")
    if (-not $k) { $k = [Environment]::GetEnvironmentVariable("LITELLM_MASTER_KEY", "User") }
    return $k
}

function Test-Online {
    try { return ((Invoke-WebRequest "$GwUrl/health/readiness" -TimeoutSec 3 -UseBasicParsing).StatusCode -eq 200) }
    catch { return $false }
}

function Read-Required([string]$prompt) {
    while ($true) {
        $v = Read-Host "  $prompt"
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v.Trim() }
        Write-Host "  ! 不能为空，请重新输入" -ForegroundColor Yellow
    }
}

function Read-WithDefault([string]$prompt, [string]$default) {
    $v = Read-Host "  $prompt [$default]"
    if ([string]::IsNullOrWhiteSpace($v)) { return $default }
    return $v.Trim()
}

function Confirm([string]$prompt) {
    $a = Read-Host "  $prompt (y/N)"
    return ($a -match '^[Yy]')
}

# 把上游返回的英文报错翻译成人话
function Explain-Error([string]$msg) {
    if ($msg -match 'Free quota exhausted|quota|insufficient|balance|欠费') {
        return "上游额度不足/欠费 —— 去对应厂商控制台充值，或关掉「仅用免费额度」模式"
    }
    if ($msg -match 'PERMISSION_DENIED') { return "上游拒绝访问（额度或权限问题）" }
    if ($msg -match 'Invalid model name') { return "这个模型别名没有登记（或改完没重启网关）" }
    if ($msg -match '401|Unauthorized|Invalid proxy server token|Authentication Error') {
        return "网关鉴权失败：LITELLM_MASTER_KEY 不对或没读到（重新登录后再试）"
    }
    if ($msg -match 'Connection refused|actively refused|无法连接') { return "连不上网关 —— 先用主菜单第 6 项启动它" }
    if ($msg -match 'certificate|SSL') { return "SSL 证书校验失败（网络被代理/中间人拦截）" }
    if ($msg -match 'timeout|timed out|超时') { return "请求超时：上游太慢或网络不通" }
    if ($msg -match 'NotFound|404|not found') { return "接口地址不对（base_url 写错了），或这家不支持当前协议模式" }
    if ($msg -match 'invalid_api_key|Incorrect API key|api key') { return "密钥不对：检查这家厂商填的密钥" }
    if ($msg -match 'does not exist|无此模型|model not found') { return "上游没有这个模型名（上游真实模型名写错了）" }
    return "未识别的错误，原文见下方"
}

function Test-OneModel([string]$name) {
    $key = Get-GatewayKey
    if (-not $key) { return @{ ok = $false; msg = "本终端读不到 LITELLM_MASTER_KEY（重新登录，或新开一个终端再试）" } }
    $body = @{ model = $name; input = "reply with exactly: ok"; max_output_tokens = 32 } | ConvertTo-Json -Compress
    try {
        $null = Invoke-RestMethod "$GwUrl/v1/responses" -Method Post `
                    -Headers @{ Authorization = "Bearer $key" } `
                    -ContentType "application/json" -Body $body -TimeoutSec 90
        return @{ ok = $true; msg = "正常" }
    }
    catch {
        $m = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        return @{ ok = $false; msg = $m }
    }
}

# ============================================================
#  配置数据源：providers.json  ->  config.yaml
# ============================================================

function Load-Registry {
    if (-not (Test-Path $Registry)) {
        # 首次运行：从示例文件复制一份，而不是直接报错退出
        $example = Join-Path $Root "providers.example.json"
        if (Test-Path $example) {
            Copy-Item $example $Registry -Force
            Write-Host ""
            Write-Host "  首次运行：已根据 providers.example.json 生成 providers.json" -ForegroundColor Yellow
            Write-Host "  请到「厂商与模型管理」里改成你自己的厂商和模型" -ForegroundColor Yellow
            Write-Host ""
        } else {
            throw "找不到配置文件：$Registry（也找不到 providers.example.json）"
        }
    }
    $reg = Get-Content $Registry -Raw -Encoding UTF8 | ConvertFrom-Json
    $reg.providers = @($reg.providers)
    return $reg
}

function Save-Registry($reg) {
    $reg.providers = @($reg.providers)
    foreach ($p in $reg.providers) { $p.models = @($p.models) }
    $json = $reg | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($Registry, $json, (New-Object Text.UTF8Encoding($false)))
}

function Get-ProviderById($reg, [string]$id) {
    return ($reg.providers | Where-Object { $_.id -eq $id } | Select-Object -First 1)
}

function Get-AllAliases($reg) {
    $out = @()
    foreach ($p in $reg.providers) { foreach ($m in @($p.models)) { $out += $m.alias } }
    return $out
}

function Get-AliasOwner($reg, [string]$alias) {
    foreach ($p in $reg.providers) {
        foreach ($m in @($p.models)) { if ($m.alias -eq $alias) { return $p } }
    }
    return $null
}

function New-ConfigYamlText($reg) {
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add("# ============================================================")
    $L.Add("#  本文件由「网关管家」根据 providers.json 自动生成")
    $L.Add("#  ★ 请勿手工修改 —— 下次生成会把你的改动覆盖掉")
    $L.Add("#    要加厂商 / 加模型 / 换密钥：双击 网关管家.cmd")
    $L.Add("# ============================================================")
    $L.Add("#")
    $L.Add("#  openai/ 前缀         = Responses 原生透传（协议不翻译，保真度最高）")
    $L.Add("#  custom_openai/ 前缀  = 桥接模式（/responses 自动转 /chat/completions）")
    $L.Add("#  密钥一律用 os.environ/XXX 引用环境变量，本文件不含任何明文")
    $L.Add("")
    $L.Add("model_list:")
    foreach ($p in $reg.providers) {
        $L.Add("")
        $L.Add("  # ---------- $($p.name) ----------")
        $prefix = if ($p.wireMode -eq "chat") { "custom_openai" } else { "openai" }
        foreach ($m in @($p.models)) {
            $L.Add("  - model_name: $($m.alias)")
            $L.Add("    litellm_params:")
            $L.Add("      model: $prefix/$($m.upstream)")
            $L.Add("      api_base: $($p.baseUrl)")
            $L.Add("      api_key: os.environ/$($p.envKey)")
        }
    }
    $L.Add("")
    $L.Add("general_settings:")
    $L.Add("  # 网关自身的鉴权 key（Codex 用它当 API key），两边共用同一个环境变量")
    $L.Add("  master_key: os.environ/LITELLM_MASTER_KEY")
    $L.Add("")
    $L.Add("litellm_settings:")
    $L.Add("  # 上游不认识的参数直接丢掉，而不是报 400")
    $L.Add("  drop_params: true")
    $L.Add("  # 长 agent 回合：单次请求给足时间（秒）")
    $L.Add("  request_timeout: 6000")

    # 故障转移：主模型报错（欠费、超时、上游 5xx…）时，按顺序自动改用它后面的模型
    $fb = @()
    foreach ($p in $reg.providers) {
        foreach ($m in @($p.models)) {
            if ($m.PSObject.Properties.Name -notcontains 'fallbacks') { continue }
            $list = @($m.fallbacks | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($list.Count -eq 0) { continue }
            $quoted = ($list | ForEach-Object { '"' + $_ + '"' }) -join ', '
            $fb += '{"' + $m.alias + '": [' + $quoted + ']}'
        }
    }
    if ($fb.Count -gt 0) {
        $L.Add("  # 故障转移：主模型报错时按顺序尝试这些备用模型")
        $L.Add("  fallbacks: [" + ($fb -join ', ') + "]")
    }

    $L.Add("")
    return ($L -join "`r`n")
}

function Write-ConfigYaml($reg) {
    [IO.File]::WriteAllText($CfgYaml, (New-ConfigYamlText $reg), (New-Object Text.UTF8Encoding($false)))
}

# ============================================================
#  网关启停
# ============================================================

function Stop-GatewayProcess {
    & taskkill /IM litellm.exe /F 2>&1 | Out-Null
    # 关键：taskkill 返回 ≠ 端口立刻释放。立刻启动的话，
    # 启动器的"已在运行就跳过"护栏会误判，导致网关根本没被拉起来。
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        if (-not (Test-Online)) { break }
    }
    Start-Sleep -Milliseconds 500
}

# 把 User 级环境变量补进当前进程。
# 原因：在"很久以前打开的终端"里启动的进程，拿不到后来新增的环境变量，
# 直接重启网关会导致那家厂商读不到密钥（表现为 401 或密钥为空）。
function Import-UserEnv {
    try {
        $reg = Load-Registry
        $names = @("LITELLM_MASTER_KEY") + @($reg.providers | ForEach-Object { $_.envKey })
        foreach ($n in ($names | Select-Object -Unique)) {
            if (-not [Environment]::GetEnvironmentVariable($n, "Process")) {
                $v = [Environment]::GetEnvironmentVariable($n, "User")
                if ($v) { [Environment]::SetEnvironmentVariable($n, $v, "Process") }
            }
        }
    } catch { }
}

# 用 cmd.exe 启动（而不是直接 Start-Process 那个 .cmd），
# 这样新进程一定继承本进程刚设进去的环境变量（比如新加的密钥）
function Restart-Gateway {
    Import-UserEnv
    Stop-GatewayProcess
    Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" `
                  -ArgumentList "/c", "`"$Launcher`"" -WindowStyle Hidden
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 1
        if (Test-Online) { return $true }
    }
    # 起不来时给出可诊断的线索，而不是只说一句"失败"
    Write-Host "  [诊断] 网关没起来，现场信息：" -ForegroundColor DarkYellow
    $proc = @(Get-Process -Name litellm -ErrorAction SilentlyContinue)
    Write-Host ("     litellm 进程数：{0}" -f $proc.Count) -ForegroundColor DarkYellow
    $lf = Get-LatestLogFile
    if ($lf) {
        Write-Host "     $($lf.Name) 末尾：" -ForegroundColor DarkYellow
        Get-Content $lf.FullName -Tail 6 -Encoding UTF8 | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkGray }
    }
    return $false
}

# ============================================================
#  主菜单功能
# ============================================================

function Get-DefaultModel {
    if (-not (Test-Path $CodexToml)) { return "（找不到 config.toml）" }
    foreach ($line in (Get-Content $CodexToml -Encoding UTF8)) {
        if ($line -match '^model\s*=\s*"([^"]+)"') { return $Matches[1] }
    }
    return "（未设置）"
}

function Set-DefaultModel([string]$name) {
    $raw = Get-Content $CodexToml -Raw -Encoding UTF8
    if ($raw -notmatch '(?m)^model\s*=\s*"[^"]*"') { return $false }
    $new = $raw -replace '(?m)^model\s*=\s*"[^"]*"', "model = `"$name`""
    Copy-Item $CodexToml "$CodexToml.bak" -Force
    [IO.File]::WriteAllText($CodexToml, $new, (New-Object Text.UTF8Encoding($false)))
    return $true
}

function Show-Status {
    $reg = Load-Registry
    Write-Host ""
    if (Test-Online) { Write-Host "  网关状态：  ● 运行中" -ForegroundColor Green }
    else             { Write-Host "  网关状态：  ○ 未运行" -ForegroundColor Red }
    Write-Host "  默认模型：  $(Get-DefaultModel)"
    Write-Host ""
    Write-Host "  已登记的模型（共 $((Get-AllAliases $reg).Count) 个）：" -ForegroundColor Gray
    foreach ($p in $reg.providers) {
        $mode = if ($p.wireMode -eq "chat") { "桥接" } else { "原生" }
        Write-Host ("    {0}  [{1}]" -f $p.name, $mode) -ForegroundColor Cyan
        foreach ($m in @($p.models)) {
            Write-Host ("      · {0,-20} -> {1}" -f $m.alias, $m.upstream)
        }
    }
    if (-not (Test-Online)) { Write-Host "`n  ! 网关没运行，先启动它 Codex 才能用" -ForegroundColor Yellow }
    Write-Host ""
}

function Test-AllModels {
    if (-not (Test-Online)) { Write-Host "`n  网关没运行，先用主菜单里的「启动 / 重启网关」。`n" -ForegroundColor Red; return }
    $reg = Load-Registry
    Write-Host "`n  正在逐个实测（每个一次真实请求，可能要十几秒）...`n"
    $failed = @()
    foreach ($m in (Get-AllAliases $reg)) {
        $r = Test-OneModel $m
        if ($r.ok) {
            Write-Host ("  v {0,-20} 正常" -f $m) -ForegroundColor Green
        } else {
            $why = Explain-Error $r.msg
            Write-Host ("  x {0,-20} 失败" -f $m) -ForegroundColor Red
            Write-Host ("      -> {0}" -f $why) -ForegroundColor Yellow
            $failed += [PSCustomObject]@{ alias = $m; reason = $why }
        }
    }
    Write-Host ""
    if ($failed.Count -gt 0) { Invoke-FailedCleanup $failed }
}

function Switch-DefaultModel {
    $reg = Load-Registry
    $models = Get-AllAliases $reg
    if ($models.Count -eq 0) { Write-Host "`n  还没有登记任何模型`n" -ForegroundColor Red; return }
    Write-Host "`n  当前默认模型：$(Get-DefaultModel)`n"
    for ($i = 0; $i -lt $models.Count; $i++) { Write-Host ("    {0}. {1}" -f ($i + 1), $models[$i]) }
    Write-Host "    0. 取消`n"
    $pick = Read-Host "  请输入序号"
    if ($pick -eq "0" -or [string]::IsNullOrWhiteSpace($pick)) { return }
    $idx = 0
    if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $models.Count) {
        Write-Host "  输入无效" -ForegroundColor Red; return
    }
    $target = $models[$idx - 1]
    if (Set-DefaultModel $target) {
        Write-Host "  v 默认模型已改为 $target（原文件备份为 config.toml.bak）" -ForegroundColor Green
    }
}

# 日志可能因为句柄被占而退回到带时间戳的文件，所以要取最新的那个
function Get-LatestLogFile {
    return (Get-ChildItem (Join-Path $Root "logs") -Filter "gateway*.log" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1)
}

function Show-Logs {
    $file = Get-LatestLogFile
    if (-not $file) { Write-Host "`n  还没有日志文件`n" -ForegroundColor Yellow; return }
    Write-Host "`n  -- $($file.Name) 最近 30 行 --`n" -ForegroundColor DarkGray
    Get-Content $file.FullName -Tail 30 -Encoding UTF8 | ForEach-Object { "  $_" }
    Write-Host ""
}

function Show-QuickStart {
    Write-Host @"

  --------------- 快速上手 ---------------

  【平时怎么用】
    直接用 codex 就行，它自动走网关。
      codex                     默认模型
      codex -p fast             快、便宜（日常改动）
      codex -p deep             难任务，推理拉满
      codex -p plan             只读，不改文件
      codex --model glm-4.7     临时指定模型

  【加一家新厂商】
    主菜单 -> 4（厂商与模型管理）-> 2（添加新厂商）
    依次问你：名字、接口地址、密钥变量名、密钥、第一个模型。
    存好后会自动重启网关并【自动探测协议】，告诉你哪种模式能用。

  【加一个新模型】
    主菜单 -> 4 -> 3，只需填别名和上游模型名。

  【改密钥】
    主菜单 -> 5（密钥管理）-> 2，输入变量名和密钥值即可。
    密钥存在 Windows 用户环境变量里，不写进任何配置文件。

  【注意】
    · 新增密钥后本菜单会自动重启网关让它生效
    · 但已经打开的终端/Codex 要【重新打开】才能读到新密钥
    · Codex 的模型名要和 ~/.codex/models.json 里的 slug 对齐，
      否则 Codex 会用通用参数（能用，但上下文窗口等不准）

"@ -ForegroundColor Gray
}

# ============================================================
#  功能一：密钥管理
# ============================================================

function Get-VarState([string]$name) {
    $u = [Environment]::GetEnvironmentVariable($name, "User")
    if ($u) { return @{ set = $true; len = $u.Length } }
    return @{ set = $false; len = 0 }
}

function Show-Keys {
    $reg = Load-Registry
    Write-Host "`n  密钥状态（只看有没有设置，不显示内容）：`n"
    $names = @("LITELLM_MASTER_KEY") + @($reg.providers | ForEach-Object { $_.envKey })
    foreach ($n in ($names | Select-Object -Unique)) {
        $s = Get-VarState $n
        if ($s.set) { Write-Host ("  v {0,-28} 已设置（{1} 位）" -f $n, $s.len) -ForegroundColor Green }
        else        { Write-Host ("  x {0,-28} 未设置" -f $n) -ForegroundColor Red }
    }
    Write-Host ""
}

function Set-KeyInteractive {
    $reg = Load-Registry
    Write-Host "`n  已有密钥变量名："
    foreach ($n in @($reg.providers | ForEach-Object { $_.envKey } | Select-Object -Unique)) { Write-Host "    · $n" }
    Write-Host "    · LITELLM_MASTER_KEY   （网关自身鉴权，一般不用动）`n"
    $name = Read-Required "密钥的变量名（例如 MOONSHOT_API_KEY）"
    $secure = Read-Host "  密钥的值（输入时不显示）" -AsSecureString
    $plain = [System.Net.NetworkCredential]::new("", $secure).Password
    if ([string]::IsNullOrWhiteSpace($plain)) { Write-Host "  x 密钥为空，已取消`n" -ForegroundColor Red; return }

    [Environment]::SetEnvironmentVariable($name, $plain, "User")
    [Environment]::SetEnvironmentVariable($name, $plain, "Process")   # 让本次重启的网关立刻拿到
    Write-Host "  v 已写入用户环境变量：$name" -ForegroundColor Green

    $used = @($reg.providers | Where-Object { $_.envKey -eq $name })
    if ($used.Count -eq 0) {
        Write-Host "  i 目前还没有厂商使用变量 $name" -ForegroundColor Yellow
        Write-Host "    去「厂商与模型管理 -> 修改厂商」把它挂到某个厂商上" -ForegroundColor DarkGray
    }

    if (Test-Online) {
        if (Confirm "要重启网关让新密钥立即生效吗？") {
            Write-Host "  正在重启..." -ForegroundColor DarkGray
            if (Restart-Gateway) { Write-Host "  v 网关已重启`n" -ForegroundColor Green }
            else { Write-Host "  x 重启失败，看日志`n" -ForegroundColor Red }
        }
    }
    Write-Host ""
}

# ============================================================
#  功能二：厂商与模型管理
# ============================================================

function Show-ProviderList {
    $reg = Load-Registry
    Write-Host "`n  当前登记（$($reg.providers.Count) 家厂商）：`n"
    $i = 1
    foreach ($p in $reg.providers) {
        $mode = if ($p.wireMode -eq "chat") { "桥接模式" } else { "原生 Responses" }
        $s = Get-VarState $p.envKey
        $kstate = if ($s.set) { "已设置" } else { "未设置" }
        Write-Host ("  {0}. {1}" -f $i, $p.name) -ForegroundColor Cyan
        Write-Host ("       地址   {0}" -f $p.baseUrl)
        Write-Host ("       密钥   {0}  [{1}]" -f $p.envKey, $kstate)
        Write-Host ("       协议   {0}" -f $mode)
        Write-Host  "       模型"
        foreach ($m in @($p.models)) {
            $fb = @()
            if ($m.PSObject.Properties.Name -contains 'fallbacks') { $fb = @($m.fallbacks | Where-Object { $_ }) }
            $tag = if ($fb.Count -gt 0) { "   [备用: " + ($fb -join ' -> ') + "]" } else { "" }
            Write-Host ("         · {0,-20} -> {1}{2}" -f $m.alias, $m.upstream, $tag)
        }
        Write-Host ""
        $i++
    }
}

function New-ProviderId([string]$name) {
    $slug = ($name -replace '[^a-zA-Z0-9]', '').ToLower()
    if ($slug.Length -ge 3) { return $slug.Substring(0, [Math]::Min(12, $slug.Length)) }
    return "p" + [guid]::NewGuid().ToString("N").Substring(0, 6)
}

# 自动探测：先试原生 Responses，失败再试桥接，返回最终可用的模式
function Invoke-AutoProbe([string]$providerId, [string]$alias) {
    $last = ""
    foreach ($mode in @("responses", "chat")) {
        $reg = Load-Registry
        (Get-ProviderById $reg $providerId).wireMode = $mode
        Save-Registry $reg
        Write-ConfigYaml $reg
        $label = if ($mode -eq "chat") { "桥接模式" } else { "原生 Responses" }
        Write-Host ("    正在用【{0}】重启网关并测试..." -f $label) -ForegroundColor DarkGray
        if (-not (Restart-Gateway)) { return @{ ok = $false; mode = $mode; msg = "网关重启失败" } }
        $r = Test-OneModel $alias
        if ($r.ok) { return @{ ok = $true; mode = $mode; msg = "正常" } }
        $last = $r.msg
    }
    # 两种都不行：退回默认的原生模式，避免留下奇怪的半成品状态
    $reg = Load-Registry
    (Get-ProviderById $reg $providerId).wireMode = "responses"
    Save-Registry $reg
    Write-ConfigYaml $reg
    return @{ ok = $false; mode = "responses"; msg = $last }
}

function Add-Provider {
    Write-Host "`n  -- 添加新厂商 --`n" -ForegroundColor Cyan
    Write-Host "  接口地址填厂商文档里的 base_url，按文档原样填即可" -ForegroundColor DarkGray
    Write-Host "  （不确定协议没关系，存完会自动探测）`n" -ForegroundColor DarkGray

    $name = Read-Required "厂商名称（自己看得懂就行，如 Moonshot 月之暗面）"
    $apiBase = (Read-Required "接口地址 base_url").TrimEnd('/')
    $envKey = Read-WithDefault "密钥的环境变量名" ((New-ProviderId $name).ToUpper() + "_API_KEY")

    $cur = Get-VarState $envKey
    if ($cur.set) {
        Write-Host "  i 环境变量 $envKey 已经存在（$($cur.len) 位），沿用" -ForegroundColor Yellow
    } else {
        if (Confirm "现在设置密钥 $envKey 吗？（选 n 可以稍后在密钥管理里设）") {
            $secure = Read-Host "  粘贴密钥（不显示）" -AsSecureString
            $plain = [System.Net.NetworkCredential]::new("", $secure).Password
            if (-not [string]::IsNullOrWhiteSpace($plain)) {
                [Environment]::SetEnvironmentVariable($envKey, $plain, "User")
                [Environment]::SetEnvironmentVariable($envKey, $plain, "Process")
                Write-Host "  v 密钥已写入用户环境变量" -ForegroundColor Green
            } else {
                Write-Host "  ! 空密钥，跳过（记得稍后补上）" -ForegroundColor Yellow
            }
        }
    }

    Write-Host "`n  再登记这家厂商的第一个模型：" -ForegroundColor Cyan
    Write-Host "    · 别名：在 Codex 里用的名字，随便起，建议和官方模型名一致" -ForegroundColor DarkGray
    Write-Host "    · 上游真实模型名：厂商文档里的 model id，和别名一样就直接回车" -ForegroundColor DarkGray
    $alias = Read-Required "模型的别名（在 Codex 里用它）"
    $upstream = Read-WithDefault "上游真实模型名" $alias

    $reg = Load-Registry
    if (Get-AliasOwner $reg $alias) {
        Write-Host "  x 别名 $alias 已存在，已取消（换个名字，或去「给已有厂商添加模型」）`n" -ForegroundColor Red
        return
    }

    $newProvider = [PSCustomObject]@{
        id       = New-ProviderId $name
        name     = $name
        baseUrl  = $apiBase
        envKey   = $envKey
        wireMode = "responses"
        models   = @([PSCustomObject]@{ alias = $alias; upstream = $upstream })
    }
    $reg.providers = @($reg.providers) + $newProvider
    Save-Registry $reg

    Write-Host "`n  v 已登记 $name / $alias" -ForegroundColor Green
    Write-Host "  正在自动探测协议（最多试两种，约 10~30 秒）..." -ForegroundColor Cyan
    $probe = Invoke-AutoProbe $newProvider.id $alias
    if ($probe.ok) {
        $label = if ($probe.mode -eq "chat") { "桥接模式（/responses 转 /chat/completions）" } else { "原生 Responses 协议" }
        Write-Host "`n  v 探测成功，这家用【$label】" -ForegroundColor Green
        Write-Host "    现在可以直接：codex --model $alias" -ForegroundColor Gray
    } else {
        Write-Host "`n  x 两种模式都没测通，配置已保留（暂用原生模式）" -ForegroundColor Red
        Write-Host ("    原因：{0}" -f (Explain-Error $probe.msg)) -ForegroundColor Yellow
        Write-Host "    原文：" -ForegroundColor DarkGray
        Write-Host ("    " + $probe.msg) -ForegroundColor DarkGray
        Write-Host "`n    常见原因：密钥不对 / 接口地址写错 / 这家不支持这两种协议" -ForegroundColor DarkGray
    }
    Write-Host ""
}

function Add-Model {
    $reg = Load-Registry
    if ($reg.providers.Count -eq 0) { Write-Host "`n  还没有厂商，请先添加厂商`n" -ForegroundColor Red; return }
    Write-Host "`n  给哪家厂商加模型？`n"
    for ($i = 0; $i -lt $reg.providers.Count; $i++) { Write-Host ("    {0}. {1}" -f ($i + 1), $reg.providers[$i].name) }
    Write-Host "    0. 取消`n"
    $pick = Read-Host "  请输入序号"
    if ($pick -eq "0" -or [string]::IsNullOrWhiteSpace($pick)) { return }
    $idx = 0
    if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $reg.providers.Count) {
        Write-Host "  输入无效" -ForegroundColor Red; return
    }
    $p = $reg.providers[$idx - 1]

    $alias = Read-Required "模型的别名（在 Codex 里用它）"
    if (Get-AliasOwner $reg $alias) { Write-Host "  x 别名 $alias 已存在`n" -ForegroundColor Red; return }
    $upstream = Read-WithDefault "上游真实模型名" $alias

    $p.models = @($p.models) + [PSCustomObject]@{ alias = $alias; upstream = $upstream }
    Save-Registry $reg
    Write-ConfigYaml $reg
    Write-Host "  v 已添加 $alias（属于 $($p.name)）" -ForegroundColor Green
    Write-Host "  正在重启网关..." -ForegroundColor DarkGray
    if (Restart-Gateway) {
        $r = Test-OneModel $alias
        if ($r.ok) { Write-Host "  v 实测通过，可以用了：codex --model $alias`n" -ForegroundColor Green }
        else {
            Write-Host "  ! 网关起来了，但这个模型没测通" -ForegroundColor Yellow
            Write-Host ("    -> {0}" -f (Explain-Error $r.msg)) -ForegroundColor Yellow
            Write-Host "    若提示地址不对，可能这家要用桥接模式：去「修改厂商」把协议改成桥接`n" -ForegroundColor DarkGray
        }
    } else { Write-Host "  x 网关重启失败，看日志`n" -ForegroundColor Red }
}

function Edit-Provider {
    $reg = Load-Registry
    if ($reg.providers.Count -eq 0) { Write-Host "`n  还没有厂商`n" -ForegroundColor Red; return }
    Write-Host "`n  修改哪家？`n"
    for ($i = 0; $i -lt $reg.providers.Count; $i++) { Write-Host ("    {0}. {1}" -f ($i + 1), $reg.providers[$i].name) }
    Write-Host "    0. 取消`n"
    $pick = Read-Host "  请输入序号"
    if ($pick -eq "0" -or [string]::IsNullOrWhiteSpace($pick)) { return }
    $idx = 0
    if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $reg.providers.Count) {
        Write-Host "  输入无效" -ForegroundColor Red; return
    }
    $p = $reg.providers[$idx - 1]

    Write-Host "`n  直接回车 = 保持原值`n" -ForegroundColor DarkGray
    $p.name    = Read-WithDefault "厂商名称" $p.name
    $p.baseUrl = (Read-WithDefault "接口地址" $p.baseUrl).TrimEnd('/')
    $p.envKey  = Read-WithDefault "密钥的环境变量名" $p.envKey
    $modeNow   = if ($p.wireMode -eq "chat") { "2" } else { "1" }
    Write-Host "  协议模式：  1 = 原生 Responses（推荐）   2 = 桥接（/responses 转 /chat）"
    $mode = Read-WithDefault "协议模式" $modeNow
    $p.wireMode = if ($mode -eq "2") { "chat" } else { "responses" }

    Save-Registry $reg
    Write-ConfigYaml $reg
    Write-Host "  v 已保存" -ForegroundColor Green
    if (Confirm "现在重启网关并测试这家厂商吗？") {
        Write-Host "  正在重启..." -ForegroundColor DarkGray
        if (Restart-Gateway) {
            foreach ($m in @($p.models)) {
                $r = Test-OneModel $m.alias
                if ($r.ok) { Write-Host ("  v {0,-20} 正常" -f $m.alias) -ForegroundColor Green }
                else {
                    Write-Host ("  x {0,-20} 失败" -f $m.alias) -ForegroundColor Red
                    Write-Host ("      -> {0}" -f (Explain-Error $r.msg)) -ForegroundColor Yellow
                }
            }
        } else { Write-Host "  x 重启失败`n" -ForegroundColor Red }
    }
    Write-Host ""
}

function Remove-Model {
    $reg = Load-Registry
    $aliases = Get-AllAliases $reg
    if ($aliases.Count -eq 0) { Write-Host "`n  还没有模型`n" -ForegroundColor Red; return }
    Write-Host "`n  删除哪个模型？`n"
    for ($i = 0; $i -lt $aliases.Count; $i++) { Write-Host ("    {0}. {1}" -f ($i + 1), $aliases[$i]) }
    Write-Host "    0. 取消`n"
    $pick = Read-Host "  请输入序号"
    if ($pick -eq "0" -or [string]::IsNullOrWhiteSpace($pick)) { return }
    $idx = 0
    if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $aliases.Count) {
        Write-Host "  输入无效" -ForegroundColor Red; return
    }
    $target = $aliases[$idx - 1]
    if (-not (Confirm "确定删除模型 $target 吗？")) { return }

    foreach ($p in $reg.providers) {
        $p.models = @(@($p.models) | Where-Object { $_.alias -ne $target })
    }
    Save-Registry $reg
    Write-ConfigYaml $reg
    Write-Host "  v 已删除 $target" -ForegroundColor Green
    if ((Get-DefaultModel) -eq $target) {
        Write-Host "  ! 注意：它正是 Codex 当前的默认模型，记得去主菜单第 3 项换一个" -ForegroundColor Yellow
    }
    if (Confirm "现在重启网关让改动生效吗？") { Restart-Gateway | Out-Null; Write-Host "  v 已重启`n" -ForegroundColor Green }
    Write-Host ""
}

function Remove-Provider {
    $reg = Load-Registry
    if ($reg.providers.Count -eq 0) { Write-Host "`n  还没有厂商`n" -ForegroundColor Red; return }
    Write-Host "`n  删除哪家厂商？（它下面的模型会一起删掉）`n"
    for ($i = 0; $i -lt $reg.providers.Count; $i++) {
        Write-Host ("    {0}. {1}   （{2} 个模型）" -f ($i + 1), $reg.providers[$i].name, @($reg.providers[$i].models).Count)
    }
    Write-Host "    0. 取消`n"
    $pick = Read-Host "  请输入序号"
    if ($pick -eq "0" -or [string]::IsNullOrWhiteSpace($pick)) { return }
    $idx = 0
    if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $reg.providers.Count) {
        Write-Host "  输入无效" -ForegroundColor Red; return
    }
    $p = $reg.providers[$idx - 1]
    if (-not (Confirm "确定删除厂商 $($p.name) 及其 $(@($p.models).Count) 个模型吗？")) { return }

    $reg.providers = @($reg.providers | Where-Object { $_.id -ne $p.id })
    Save-Registry $reg
    Write-ConfigYaml $reg
    Write-Host "  v 已删除 $($p.name)" -ForegroundColor Green
    Write-Host "  i 它用的环境变量 $($p.envKey) 仍然保留在系统里，没有删除" -ForegroundColor DarkGray
    if (Confirm "现在重启网关让改动生效吗？") { Restart-Gateway | Out-Null; Write-Host "  v 已重启`n" -ForegroundColor Green }
    Write-Host ""
}

# 给某个模型写入 fallbacks（列表为空 = 清除）。
# 用 Add-Member 是因为老数据里可能根本没有这个字段，直接赋值不保险。
function Set-ModelFallbacks($m, [string[]]$list) {
    $clean = @($list | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($m.PSObject.Properties.Name -contains 'fallbacks') {
        $m.fallbacks = $clean
    } else {
        $m | Add-Member -NotePropertyName fallbacks -NotePropertyValue $clean -Force
    }
}

function Get-ModelFallbacks($reg, [string]$alias) {
    foreach ($p in $reg.providers) {
        foreach ($m in @($p.models)) {
            if ($m.alias -eq $alias -and $m.PSObject.Properties.Name -contains 'fallbacks') {
                return @($m.fallbacks | Where-Object { $_ })
            }
        }
    }
    return @()
}

# 给一个指定模型配置备用模型（主模型报错时按顺序顶上）
function Set-FallbackInteractive([string]$alias) {
    $reg   = Load-Registry
    $owner = Get-AliasOwner $reg $alias
    if (-not $owner) { Write-Host "  x 找不到模型 $alias" -ForegroundColor Red; return }

    $cur    = Get-ModelFallbacks $reg $alias
    $others = @(Get-AllAliases $reg | Where-Object { $_ -ne $alias })

    Write-Host ("`n  给【{0}】设备用模型：它报错（欠费/超时/上游 5xx）时自动按顺序改用后面的。`n" -f $alias) -ForegroundColor Cyan
    Write-Host ("  当前：{0}" -f $(if ($cur.Count) { $cur -join '  ->  ' } else { '（没配）' })) -ForegroundColor DarkGray
    Write-Host ""
    for ($i = 0; $i -lt $others.Count; $i++) { Write-Host ("    {0}. {1}" -f ($i + 1), $others[$i]) }
    Write-Host "`n  输入序号（多个用逗号分隔，按输入顺序生效）；直接回车 = 清除备用模型"
    $ans = Read-Host "  请选择"

    $picked = @()
    if (-not [string]::IsNullOrWhiteSpace($ans)) {
        foreach ($t in ($ans -split '[,\s]+' | Where-Object { $_ -match '^\d+$' })) {
            $n = [int]$t
            if ($n -ge 1 -and $n -le $others.Count) { $picked += $others[$n - 1] }
        }
        if ($picked.Count -eq 0) { Write-Host "  没有选中任何模型，已取消`n" -ForegroundColor Yellow; return }
    }

    foreach ($p in $reg.providers) {
        foreach ($m in @($p.models)) { if ($m.alias -eq $alias) { Set-ModelFallbacks $m $picked } }
    }
    Save-Registry $reg
    Write-ConfigYaml $reg

    if ($picked.Count -eq 0) { Write-Host "  v 已清除 $alias 的备用模型`n" -ForegroundColor Green }
    else { Write-Host ("  v 已设置：{0}  ->  {1}" -f $alias, ($picked -join '  ->  ')) -ForegroundColor Green }

    if (Test-Online) {
        if (Confirm "现在重启网关让改动生效吗？") {
            Write-Host "  正在重启..." -ForegroundColor DarkGray
            if (Restart-Gateway) { Write-Host "  v 网关已重启`n" -ForegroundColor Green }
            else { Write-Host "  x 重启失败，看日志`n" -ForegroundColor Red }
        }
    }
    Write-Host ""
}

function Manage-Fallbacks {
    $reg = Load-Registry
    $aliases = Get-AllAliases $reg
    if ($aliases.Count -lt 2) { Write-Host "`n  至少要登记两个模型才能配故障转移`n" -ForegroundColor Red; return }
    Write-Host "`n  给哪个模型设备用模型？（它挂了就用备用的顶上）`n"
    for ($i = 0; $i -lt $aliases.Count; $i++) {
        $fb = Get-ModelFallbacks $reg $aliases[$i]
        $tag = if ($fb.Count) { "  [备用: $($fb -join ' -> ')]" } else { "" }
        Write-Host ("    {0}. {1,-20}{2}" -f ($i + 1), $aliases[$i], $tag)
    }
    Write-Host "    0. 取消`n"
    $pick = Read-Host "  请选择"
    if ($pick -eq "0" -or [string]::IsNullOrWhiteSpace($pick)) { return }
    $idx = 0
    if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $aliases.Count) {
        Write-Host "  输入无效" -ForegroundColor Red; return
    }
    Set-FallbackInteractive $aliases[$idx - 1]
}

function Show-ProviderMenu {
    while ($true) {
        Clear-Screen
        Write-Host ""
        Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "  ║            厂商与模型管理                    ║" -ForegroundColor Cyan
        Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "    1. 查看所有厂商和模型"
        Write-Host "    2. 添加新厂商（含第一个模型，自动探测协议）"
        Write-Host "    3. 给已有厂商添加模型"
        Write-Host "    4. 修改厂商（名称 / 地址 / 密钥变量 / 协议）"
        Write-Host "    5. 删除模型"
        Write-Host "    6. 删除厂商"
        Write-Host "    7. 重新生成配置并重启网关"
        Write-Host "    8. 设置故障转移  << 主模型挂了自动换备用" -ForegroundColor White
        Write-Host "    0. 返回主菜单"
        Write-Host ""
        $c = Read-Host "  请选择"
        switch ($c) {
            "1" { Show-ProviderList; Read-Host "  按回车返回" | Out-Null }
            "2" { Add-Provider;      Read-Host "  按回车返回" | Out-Null }
            "3" { Add-Model;         Read-Host "  按回车返回" | Out-Null }
            "4" { Edit-Provider;     Read-Host "  按回车返回" | Out-Null }
            "5" { Remove-Model;      Read-Host "  按回车返回" | Out-Null }
            "6" { Remove-Provider;   Read-Host "  按回车返回" | Out-Null }
            "8" { Manage-Fallbacks;  Read-Host "  按回车返回" | Out-Null }
            "7" {
                $reg = Load-Registry
                Write-ConfigYaml $reg
                Write-Host "`n  v config.yaml 已重新生成，正在重启网关..." -ForegroundColor Green
                if (Restart-Gateway) { Write-Host "  v 网关已重启`n" -ForegroundColor Green }
                else { Write-Host "  x 重启失败，看日志`n" -ForegroundColor Red }
                Read-Host "  按回车返回" | Out-Null
            }
            "0" { return }
            default { }
        }
    }
}

function Show-KeyMenu {
    while ($true) {
        Clear-Screen
        Write-Host ""
        Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "  ║               密钥管理                       ║" -ForegroundColor Cyan
        Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "    1. 查看密钥状态（只看有没有设置，不显示内容）"
        Write-Host "    2. 添加 / 更新密钥"
        Write-Host "    3. 测试某个模型（验证密钥真的能用）"
        Write-Host "    0. 返回主菜单"
        Write-Host ""
        $c = Read-Host "  请选择"
        switch ($c) {
            "1" { Show-Keys;           Read-Host "  按回车返回" | Out-Null }
            "2" { Set-KeyInteractive;  Read-Host "  按回车返回" | Out-Null }
            "3" { Test-AllModels;      Read-Host "  按回车返回" | Out-Null }
            "0" { return }
            default { }
        }
    }
}

# ============================================================
#  功能三：清理用不了的模型 / 同步 Codex 的模型列表
# ============================================================

# Codex 的模型清单来自 config.toml 里 model_catalog_json 指向的文件；
# App 的模型选择器就是照着它列的。所以"删掉 App 里的旧模型"= 删这个文件里的条目。
function Get-CodexCatalogPath {
    if (Test-Path $CodexToml) {
        foreach ($line in (Get-Content $CodexToml -Encoding UTF8)) {
            if ($line -match '^\s*model_catalog_json\s*=\s*"([^"]+)"') {
                return ($Matches[1] -replace '/', '\')
            }
        }
    }
    return (Join-Path (Split-Path $CodexToml) "models.json")
}

function Read-CodexCatalog([string]$path) {
    $j = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    return @($j.models)
}

# 写回前先备份，写回后立刻校验；校验不过就回滚到本次快照
function Save-CodexCatalog([string]$path, $models) {
    # 每次都留一份带时间戳的快照；.bak 只在第一次创建，
    # 这样 .bak 永远是"改动前"最原始的那一份，不会被后续写入覆盖
    $stamp    = Get-Date -Format "yyyyMMdd-HHmmss"
    $snapshot = "$path.$stamp.bak"
    Copy-Item $path $snapshot -Force
    if (-not (Test-Path "$path.bak")) { Copy-Item $path "$path.bak" -Force }

    $obj  = [PSCustomObject]@{ models = @($models) }
    $json = $obj | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding($false)))

    # 校验：Codex 会因为"字段根本不存在"而拒绝整个文件。
    # 注意必须判断【字段是否存在】，不能判断"值是否非空" ——
    # 空字符串 base_instructions 是完全合法的（本项目里就有 10 个是这样的）。
    try {
        $check = Read-CodexCatalog $path
        if (@($check).Count -ne @($models).Count) { throw "写入后条目数不一致" }
        foreach ($m in @($check)) {
            $hasBase = $m.PSObject.Properties.Name -contains 'base_instructions'
            $hasTmpl = $false
            if ($m.model_messages) { $hasTmpl = $m.model_messages.PSObject.Properties.Name -contains 'instructions_template' }
            if (-not $hasBase -and -not $hasTmpl) { throw "条目 $($m.slug) 两个字段都没有，Codex 会拒绝加载整个文件" }
        }
    } catch {
        Copy-Item $snapshot $path -Force
        throw "$($_.Exception.Message)；已回滚（快照：$snapshot）"
    }
    return $true
}

function Remove-CatalogSlugs([string]$path, [string[]]$slugs) {
    $models = Read-CodexCatalog $path
    $keep = @($models | Where-Object { $_.slug -notin $slugs })
    $removed = @($models).Count - @($keep).Count
    if ($removed -le 0) { Write-Host "  （模型列表里没有这些条目，无需改动）" -ForegroundColor DarkGray; return 0 }
    Save-CodexCatalog $path $keep | Out-Null
    Write-Host ("  v 已从 Codex 模型列表移除 {0} 个条目（原文件备份为 models.json.bak）" -f $removed) -ForegroundColor Green
    return $removed
}

# 给网关里有、但 Codex 列表里没有的模型补条目（否则 Codex 用通用参数兜底）
function Add-CatalogEntries([string]$path, [string[]]$aliases) {
    $models = Read-CodexCatalog $path
    if (@($models).Count -eq 0) { Write-Host "  x 列表为空，没有可参照的模板，已跳过" -ForegroundColor Red; return 0 }
    $reg = Load-Registry
    $added = 0
    foreach ($a in $aliases) {
        $owner = Get-AliasOwner $reg $a
        $template = $null
        if ($owner) {
            foreach ($m in @($owner.models)) {
                $t = $models | Where-Object { $_.slug -eq $m.alias } | Select-Object -First 1
                if ($t) { $template = $t; break }
            }
        }
        if (-not $template) { $template = @($models)[0] }
        $copy = $template | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $copy.slug = $a
        $copy.display_name = $a
        $copy.description = "由网关管家自动生成：参数沿用 $($template.slug)，可按需修改"
        $models = @($models) + $copy
        Write-Host ("  v 已补充条目 {0}（参数模板：{1}）" -f $a, $template.slug) -ForegroundColor Green
        $added++
    }
    if ($added -gt 0) { Save-CodexCatalog $path $models | Out-Null }
    return $added
}

# 从网关移除若干模型；顺带清掉已经没有模型的厂商
function Remove-GatewayModels([string[]]$aliases) {
    $reg = Load-Registry
    $before = @(Get-AllAliases $reg).Count
    foreach ($p in $reg.providers) {
        $p.models = @(@($p.models) | Where-Object { $_.alias -notin $aliases })
    }
    $emptied = @($reg.providers | Where-Object { @($_.models).Count -eq 0 })
    $reg.providers = @($reg.providers | Where-Object { @($_.models).Count -gt 0 })
    # 被删掉的模型不能再当别人的备用模型，否则配置里会指向一个不存在的名字
    foreach ($p in $reg.providers) {
        foreach ($m in @($p.models)) {
            if ($m.PSObject.Properties.Name -notcontains 'fallbacks') { continue }
            $m.fallbacks = @($m.fallbacks | Where-Object { $_ -notin $aliases })
        }
    }
    Save-Registry $reg
    Write-ConfigYaml $reg
    $after = @(Get-AllAliases $reg).Count
    Write-Host ("  v 已从网关移除 {0} 个模型（{1} -> {2}）" -f ($before - $after), $before, $after) -ForegroundColor Green
    foreach ($e in $emptied) {
        Write-Host ("  i 厂商「{0}」已没有模型，一并移除（它用的环境变量保留，没有删）" -f $e.name) -ForegroundColor DarkGray
    }
    return $after
}

# 测试失败后的处理入口
function Invoke-FailedCleanup($failed) {
    Write-Host ("  ! 有 {0} 个模型用不了：" -f @($failed).Count) -ForegroundColor Yellow
    for ($i = 0; $i -lt @($failed).Count; $i++) {
        Write-Host ("   {0}. {1,-20} {2}" -f ($i + 1), $failed[$i].alias, $failed[$i].reason) -ForegroundColor DarkYellow
    }
    Write-Host ""
    Write-Host "    1. 全部删除（从网关移除，Codex 里也就选不到了）"
    Write-Host "    2. 选择要删的"
    Write-Host "    3. 不删，给它们配个备用模型（挂了自动顶上）" -ForegroundColor White
    Write-Host "    0. 都不删"
    Write-Host ""
    $c = Read-Host "  请选择"

    if ($c -eq "3") {
        foreach ($f in @($failed)) {
            Write-Host ""
            if (@($failed).Count -eq 1 -or (Confirm "给 $($f.alias) 配备用模型吗？")) {
                Set-FallbackInteractive $f.alias
            }
        }
        return
    }

    $targets = @()
    switch ($c) {
        "1" { $targets = @($failed | ForEach-Object { $_.alias }) }
        "2" {
            $ans = Read-Host "  输入要删的序号（多个用逗号分隔，如 1,3,5）"
            foreach ($t in ($ans -split '[,\s]+' | Where-Object { $_ -match '^\d+$' })) {
                $n = [int]$t
                if ($n -ge 1 -and $n -le @($failed).Count) { $targets += $failed[$n - 1].alias }
            }
            if (@($targets).Count -eq 0) { Write-Host "  没有选中任何模型，已取消`n" -ForegroundColor Yellow; return }
        }
        default { return }
    }
    if (@($targets).Count -eq 0) { return }

    Write-Host ""
    Write-Host ("  将要删除：{0}" -f ($targets -join ', ')) -ForegroundColor Yellow
    if (-not (Confirm "确定吗？（删掉的只是网关里的登记项，随时可以再加回来）")) { return }

    $left = Remove-GatewayModels $targets
    if ($left -eq 0) {
        Write-Host "  ! 网关里一个模型都不剩了，Codex 会全部报错，请尽快到「厂商与模型管理」加回来" -ForegroundColor Red
    }

    # 同步 Codex App 的模型列表，否则 App 里还显示这些、选了报错
    $path = Get-CodexCatalogPath
    if (Test-Path $path) {
        if (Confirm "同时从 Codex App 的模型列表(models.json)里也移除它们吗？") {
            try { Remove-CatalogSlugs $path $targets | Out-Null }
            catch { Write-Host "  x 写模型列表失败：$($_.Exception.Message)" -ForegroundColor Red }
        }
    }

    if (Confirm "现在重启网关让改动生效吗？") {
        Write-Host "  正在重启..." -ForegroundColor DarkGray
        if (Restart-Gateway) { Write-Host "  v 网关已重启`n" -ForegroundColor Green }
        else { Write-Host "  x 重启失败，看日志`n" -ForegroundColor Red }
    }
    Write-Host ""
}

# 独立的"同步 Codex 模型列表"入口
function Sync-CodexCatalog {
    $path = Get-CodexCatalogPath
    Write-Host "`n  Codex 模型列表：$path"
    if (-not (Test-Path $path)) { Write-Host "  x 文件不存在（config.toml 里没有 model_catalog_json？）`n" -ForegroundColor Red; return }

    $models  = Read-CodexCatalog $path
    $aliases = Get-AllAliases (Load-Registry)
    $slugs   = @($models | ForEach-Object { $_.slug })

    Write-Host ("  文件里 {0} 个条目，网关里 {1} 个模型`n" -f @($models).Count, @($aliases).Count)

    $dead    = @($slugs | Where-Object { $_ -notin $aliases })
    $missing = @($aliases | Where-Object { $_ -notin $slugs })

    if ($dead.Count -gt 0) {
        Write-Host "  【多余的】App 里能选、网关里没有（选了必然失败）：" -ForegroundColor Yellow
        $dead | ForEach-Object { Write-Host ("    - {0}" -f $_) -ForegroundColor DarkYellow }
        if (Confirm "  把它们从 Codex 模型列表里移除吗？") {
            try { Remove-CatalogSlugs $path $dead | Out-Null }
            catch { Write-Host "  x 失败：$($_.Exception.Message)" -ForegroundColor Red }
        }
    } else {
        Write-Host "  v 没有多余的条目" -ForegroundColor Green
    }

    if ($missing.Count -gt 0) {
        Write-Host "`n  【缺少的】网关里有、App 列表里没有（Codex 会用通用参数兜底）：" -ForegroundColor Yellow
        $missing | ForEach-Object { Write-Host ("    - {0}" -f $_) -ForegroundColor DarkYellow }
        if (Confirm "  要给它们补上条目吗？（参数复制自同厂商的其它模型，可自行修改）") {
            try { Add-CatalogEntries $path $missing | Out-Null }
            catch { Write-Host "  x 失败：$($_.Exception.Message)" -ForegroundColor Red }
        }
    } else {
        Write-Host "`n  v 没有缺少的条目" -ForegroundColor Green
    }

    Write-Host "`n  i 改完后 Codex App 可能需要重启才会刷新模型选择器" -ForegroundColor DarkGray
    Write-Host ""
}

# ============================================================
#  非交互模式（脚本化 / 自动化测试用）
# ============================================================

if ($Regenerate) {
    $reg = Load-Registry
    Write-ConfigYaml $reg
    Write-Host "config.yaml 已根据 providers.json 重新生成"
    exit 0
}
if ($Restart) {
    if (Restart-Gateway) { Write-Host "网关已重启"; exit 0 }
    Write-Host "网关重启失败"; exit 1
}
if ($Status) { Show-Status; exit 0 }
if ($TestAll) { Test-AllModels; exit 0 }

# ============================================================
#  主循环
# ============================================================

while ($true) {
    $online  = Test-Online
    $default = Get-DefaultModel
    Clear-Screen
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║            LiteLLM 网关管家                  ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    if ($online) { Write-Host "     状态：● 运行中" -ForegroundColor Green }
    else         { Write-Host "     状态：○ 未运行" -ForegroundColor Red }
    Write-Host "     默认模型：$default" -ForegroundColor Gray
    Write-Host ""
    Write-Host "    1. 查看状态和可用模型"
    Write-Host "    2. 测试每个模型能不能用（失败的可当场清理）"
    Write-Host "    3. 切换 Codex 默认模型"
    Write-Host "    4. 厂商与模型管理  << 加厂商 / 加模型" -ForegroundColor White
    Write-Host "    5. 密钥管理        << 加 key / 换 key" -ForegroundColor White
    Write-Host "    6. 清理 Codex App 里的旧模型  << 同步模型列表" -ForegroundColor White
    Write-Host "    7. 启动 / 重启网关"
    Write-Host "    8. 停止网关"
    Write-Host "    9. 查看最近日志"
    Write-Host "   10. 快速上手说明"
    Write-Host "   11. 打开配置文件夹"
    Write-Host "    0. 退出"
    Write-Host ""

    $choice = Read-Host "  请选择"

    switch ($choice) {
        "1"  { Show-Status;         Read-Host "  按回车返回" | Out-Null }
        "2"  { Test-AllModels;      Read-Host "  按回车返回" | Out-Null }
        "3"  { Switch-DefaultModel; Read-Host "  按回车返回" | Out-Null }
        "4"  { Show-ProviderMenu }
        "5"  { Show-KeyMenu }
        "6"  { Sync-CodexCatalog;   Read-Host "  按回车返回" | Out-Null }
        "7"  {
            if (Test-Online) {
                Write-Host "`n  网关正在运行。" -ForegroundColor Yellow
                if (Confirm "要重启它吗？") {
                    Write-Host "  正在重启..." -ForegroundColor DarkGray
                    if (Restart-Gateway) { Write-Host "  v 已重启`n" -ForegroundColor Green }
                    else { Write-Host "  x 重启失败，看日志`n" -ForegroundColor Red }
                }
            } else {
                Write-Host "`n  正在启动..." -ForegroundColor DarkGray
                if (Restart-Gateway) { Write-Host "  v 已启动`n" -ForegroundColor Green }
                else { Write-Host "  x 启动失败，看日志`n" -ForegroundColor Red }
            }
            Read-Host "  按回车返回" | Out-Null
        }
        "8"  {
            if (-not (Test-Online)) { Write-Host "`n  网关本来就没运行。`n" -ForegroundColor Yellow }
            elseif (Confirm "确定停止网关吗？Codex 会立刻用不了") {
                Stop-GatewayProcess
                if (Test-Online) { Write-Host "  x 停止失败`n" -ForegroundColor Red }
                else { Write-Host "  v 已停止`n" -ForegroundColor Green }
            }
            Read-Host "  按回车返回" | Out-Null
        }
        "9"  { Show-Logs;           Read-Host "  按回车返回" | Out-Null }
        "10" { Show-QuickStart;     Read-Host "  按回车返回" | Out-Null }
        "11" { Invoke-Item $Root }
        # 注意：这里必须用 return，不能用 break。
        # break 在 switch 里只跳出 switch，外层 while 会继续转，变成死循环。
        "0"  { return }
        default { }
    }
}
