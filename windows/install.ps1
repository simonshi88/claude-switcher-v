# Claude 切换器 Windows 版 - 安装器
# 右键 -> 使用 PowerShell 以管理员身份运行(或在管理员 PowerShell 里执行)
$ErrorActionPreference = 'Stop'
$BASE = "$env:USERPROFILE\.claude-switcher"
# Clash 系客户端配置目录:两个 fork 各自识别,V-Ninja 优先
$CLASH_DIR_VN = @(
    "$env:APPDATA\io.github.clash-verge-ninja.clash-verge-ninja",
    "$env:LOCALAPPDATA\io.github.clash-verge-ninja.clash-verge-ninja"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
$CLASH_DIR_CV = @(
    "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev",
    "$env:LOCALAPPDATA\io.github.clash-verge-rev.clash-verge-rev"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
$CLASH_DIR = $null

Write-Host "==================================" -ForegroundColor Cyan
Write-Host "  Claude 账号切换器 · Windows 安装" -ForegroundColor Cyan
Write-Host "==================================" -ForegroundColor Cyan
Write-Host ""

# ---- 0. 前置检查 + 代理客户端探测 ----
$claudeExe = @("$env:LOCALAPPDATA\AnthropicClaude\Claude.exe", "$env:LOCALAPPDATA\Programs\Claude\Claude.exe") |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
$claudeAppx = $null
try { $claudeAppx = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue | Select-Object -First 1 } catch {}
$claudeData = Test-Path -LiteralPath "$env:APPDATA\Claude"
$msixData = @(Get-ChildItem -LiteralPath "$env:LOCALAPPDATA\Claude-Data" -Directory -Filter 'claude_*' -ErrorAction SilentlyContinue)
if (-not $claudeExe -and -not $claudeAppx -and -not $claudeData -and $msixData.Count -eq 0) {
    Write-Host "X 未找到 Claude 桌面版，请先安装 Claude 后重试；尚未修改系统设置" -ForegroundColor Red
    pause; exit 1
}

$PROXY_MODE = $null
if ($CLASH_DIR_VN) {
    $PROXY_MODE = 'v-ninja'; $CLASH_DIR = $CLASH_DIR_VN
} elseif ($CLASH_DIR_CV) {
    $PROXY_MODE = 'clash-verge'; $CLASH_DIR = $CLASH_DIR_CV
} elseif (Get-Process -Name 'FlClashCore','FlClash' -ErrorAction SilentlyContinue) {
    $PROXY_MODE = 'flclash'
} elseif (Get-Process -Name 'sing-box' -ErrorAction SilentlyContinue) {
    $PROXY_MODE = 'sing-box'
} elseif (Get-Process -Name 'ClashX' -ErrorAction SilentlyContinue) {
    $PROXY_MODE = 'clashx'
} elseif (Get-Process -Name 'Surge' -ErrorAction SilentlyContinue) {
    $PROXY_MODE = 'surge'
} elseif (Get-Service -Name 'WireGuardTunnel*' -ErrorAction SilentlyContinue | Where-Object Status -eq 'Running') {
    $PROXY_MODE = 'wireguard'
}
if (-not $PROXY_MODE) {
    Write-Host "未自动识别到代理客户端,请选择:" -ForegroundColor Yellow
    Write-Host "  1) clash-verge  2) flclash     3) sing-box  4) clashx"
    Write-Host "  5) surge        6) wireguard   7) other     8) auto"
    Write-Host "  9) v-ninja(Clash V-Ninja)"
    $pick = Read-Host "请输入序号或名称(直接回车=auto)"
    switch ($pick) {
        '1' { $PROXY_MODE = 'clash-verge' }
        '2' { $PROXY_MODE = 'flclash' }
        '3' { $PROXY_MODE = 'sing-box' }
        '4' { $PROXY_MODE = 'clashx' }
        '5' { $PROXY_MODE = 'surge' }
        '6' { $PROXY_MODE = 'wireguard' }
        '7' { $PROXY_MODE = 'other' }
        '8' { $PROXY_MODE = 'auto' }
        '9' { $PROXY_MODE = 'v-ninja' }
        'clash-verge' { $PROXY_MODE = 'clash-verge' }
        'v-ninja'     { $PROXY_MODE = 'v-ninja' }
        'clash-ninja' { $PROXY_MODE = 'v-ninja' }
        'flclash'     { $PROXY_MODE = 'flclash' }
        'sing-box'    { $PROXY_MODE = 'sing-box' }
        'clashx'      { $PROXY_MODE = 'clashx' }
        'surge'       { $PROXY_MODE = 'surge' }
        'wireguard'   { $PROXY_MODE = 'wireguard' }
        'other'       { $PROXY_MODE = 'other' }
        'auto'        { $PROXY_MODE = 'auto' }
        default       { $PROXY_MODE = 'auto' }
    }
}
$CLIENT_NAME = switch ($PROXY_MODE) {
    'v-ninja'     { 'Clash V-Ninja' }
    'clash-verge' { 'Clash Verge' }
    default       { $PROXY_MODE }
}
Write-Host "[OK] 代理客户端: $PROXY_MODE($CLIENT_NAME)" -ForegroundColor Green
Write-Host "[OK] 前置检查通过" -ForegroundColor Green

# ---- 1. 出口国家探测(多源兜底;不能是 CN,否则时区会锁错) ----
$countryTz = @{
    'US' = 'America/New_York'; 'JP' = 'Asia/Tokyo'; 'TW' = 'Asia/Taipei'
    'HK' = 'Asia/Hong_Kong'; 'SG' = 'Asia/Singapore'; 'GB' = 'Europe/London'
    'DE' = 'Europe/Berlin'; 'FR' = 'Europe/Paris'; 'KR' = 'Asia/Seoul'
    'AU' = 'Australia/Sydney'; 'CA' = 'America/Toronto'; 'MY' = 'Asia/Kuala_Lumpur'
}
$countryLocale = @{
    'US' = 'en-US'; 'JP' = 'ja-JP'; 'TW' = 'zh-TW'
    'HK' = 'zh-HK'; 'SG' = 'en-SG'; 'GB' = 'en-GB'
    'DE' = 'de-DE'; 'FR' = 'fr-FR'; 'KR' = 'ko-KR'
    'AU' = 'en-AU'; 'CA' = 'en-CA'; 'MY' = 'ms-MY'
}

function Get-GeoInfo {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ua = 'claude-switcher-installer/1.0'
    $diag = New-Object System.Collections.Generic.List[string]
    $first = $null
    $sources = @(
        @{ Name = 'ipinfo'; Url = 'https://ipinfo.io/json'; Country = 'country'; Timezone = 'timezone' },
        @{ Name = 'ipapi'; Url = 'https://ipapi.co/json/'; Country = 'country_code'; Timezone = 'timezone' },
        @{ Name = 'ifconfig'; Url = 'https://ifconfig.co/json'; Country = 'country_iso'; Timezone = 'timezone' }
    )
    foreach ($src in $sources) {
        try {
            $data = Invoke-RestMethod -Uri $src.Url -UserAgent $ua -TimeoutSec 8 -ErrorAction Stop
        } catch {
            $reason = '超时/连接失败'
            try {
                if ($_.Exception.Response) { $reason = 'HTTP ' + [int]$_.Exception.Response.StatusCode }
            } catch {}
            $diag.Add("$($src.Name) $reason")
            continue
        }
        $ccField = $src.Country
        $tzField = $src.Timezone
        $cc = [string]$data.$ccField
        $tz = [string]$data.$tzField
        if ($cc -notmatch '^[A-Z]{2}$') { $diag.Add("$($src.Name) 国家字段无效"); continue }
        if ($tz -notmatch '^[A-Za-z_]+/[A-Za-z_]+(/[A-Za-z_]+)?$') { $tz = $countryTz[$cc] }
        if (-not $tz) { $tz = 'America/New_York' }
        if (-not $first) {
            $first = [pscustomobject]@{ Country = $cc; Timezone = $tz; Source = $src.Name; Ip = [string]$data.ip }
        } elseif ($cc -ne $first.Country) {
            Write-Host "[WARN] 出口国家不一致($($first.Source)=$($first.Country) $($src.Name)=$cc),采用优先级更高的 $($first.Source)" -ForegroundColor Yellow
        }
    }
    # Cloudflare trace 兜底(无时区,按国家默认)
    try {
        $trace = Invoke-WebRequest -Uri 'https://www.cloudflare.com/cdn-cgi/trace' -UserAgent $ua -TimeoutSec 8 -UseBasicParsing -ErrorAction Stop
        $loc = $null; $tip = ''
        foreach ($line in ($trace.Content -split "`r?`n")) {
            if ($line -match '^loc=([A-Za-z]{2})$') { $loc = $Matches[1].ToUpper() }
            if ($line -match '^ip=(\S+)$') { $tip = $Matches[1] }
        }
        if ($loc -and $loc -match '^[A-Z]{2}$') {
            $tz = $countryTz[$loc]
            if (-not $tz) { $tz = 'America/New_York' }
            if (-not $first) {
                $first = [pscustomobject]@{ Country = $loc; Timezone = $tz; Source = 'cloudflare'; Ip = $tip }
            } elseif ($loc -ne $first.Country) {
                Write-Host "[WARN] 出口国家不一致($($first.Source)=$($first.Country) cloudflare=$loc),采用优先级更高的 $($first.Source)" -ForegroundColor Yellow
            }
        } else {
            $diag.Add('cloudflare loc 无效')
        }
    } catch {
        $reason = '超时/连接失败'
        try {
            if ($_.Exception.Response) { $reason = 'HTTP ' + [int]$_.Exception.Response.StatusCode }
        } catch {}
        $diag.Add("cloudflare $reason")
    }
    $outCountry = ''; $outTz = ''; $outSource = ''; $outIp = '未知'
    if ($first) {
        $outCountry = $first.Country
        $outTz = $first.Timezone
        $outSource = $first.Source
        if ($first.Ip) { $outIp = $first.Ip }
    }
    return [pscustomobject]@{
        Country = $outCountry
        Timezone = $outTz
        Source = $outSource
        Ip = $outIp
        Diagnostics = ($diag -join '; ')
    }
}

$geo = Get-GeoInfo
$country = $geo.Country
$ianaTz = $geo.Timezone
$geoSource = $geo.Source
$ip = $geo.Ip
$FORCE = $env:FORCE
if (-not $country) {
    Write-Host "[WARN] 未能识别出口国家,各源探测结果:" -ForegroundColor Yellow
    Write-Host "   $($geo.Diagnostics)" -ForegroundColor DarkGray
    if ($FORCE) {
        $country = 'US'; $ianaTz = 'America/New_York'; $geoSource = 'force'
        Write-Host "   FORCE=1,按 US / America/New_York 继续" -ForegroundColor Yellow
    } else {
        Write-Host ""
        Write-Host "请手动选择当前出口所在地区:" -ForegroundColor Yellow
        Write-Host "  1) US   2) JP   3) TW   4) HK   5) SG   6) GB"
        Write-Host "  7) DE   8) FR   9) KR  10) AU  11) CA  12) MY"
        $choices = @('US', 'JP', 'TW', 'HK', 'SG', 'GB', 'DE', 'FR', 'KR', 'AU', 'CA', 'MY')
        while ($true) {
            $pick = Read-Host "请输入序号"
            if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $choices.Count) {
                $country = $choices[[int]$pick - 1]; break
            }
            if ($pick -match '^[A-Za-z]{2}$' -and ($choices -contains $pick.ToUpper())) {
                $country = $pick.ToUpper(); break
            }
            Write-Host "未识别的选择,请重试" -ForegroundColor Yellow
        }
        $ianaTz = $countryTz[$country]
        $geoSource = 'manual'
    }
}
if ($country -eq 'CN' -and -not $FORCE) {
    Write-Host "X 当前出口在国内(CN),请先开启代理(TUN模式)并确认节点可用再运行" -ForegroundColor Red
    pause; exit 1
}
if ($country -eq 'CN') {
    $country = 'US'; $ianaTz = 'America/New_York'; $geoSource = 'force'
}
if (-not $ianaTz) { $ianaTz = 'America/New_York' }
$COUNTRY_TARGET = $country
$LOCALE_TARGET = $countryLocale[$country]
if (-not $LOCALE_TARGET) { $LOCALE_TARGET = 'en-US' }
Write-Host "[OK] 地区识别: 国家=$COUNTRY_TARGET 时区=$ianaTz 格式=$LOCALE_TARGET 来源=$geoSource" -ForegroundColor Green
Write-Host "[OK] 出口: $ip ($COUNTRY_TARGET)" -ForegroundColor Green

# Clash 系客户端的组名来源:Clash Verge 读 clash-verge.yaml;V-Ninja 的组在订阅文件里
function Get-ClashConfigYaml([string]$Mode, [string]$Dir) {
    if ($Mode -eq 'v-ninja') {
        $current = $null
        $profilesYaml = Join-Path $Dir 'profiles.yaml'
        if (Test-Path -LiteralPath $profilesYaml) {
            foreach ($line in @(Get-Content -LiteralPath $profilesYaml -Encoding UTF8 -ErrorAction SilentlyContinue)) {
                if ($line -match '^current:\s*(.+?)\s*$') { $current = $Matches[1].Trim('"',"'"); break }
            }
        }
        if ($current) {
            $profile = Join-Path (Join-Path $Dir 'profiles') ($current + '.yaml')
            if (Test-Path -LiteralPath $profile) { return $profile }
        }
        foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $Dir 'profiles') -Filter '*.yaml' -File -ErrorAction SilentlyContinue)) {
            if (Select-String -LiteralPath $f.FullName -Pattern '^proxy-groups:' -Quiet -ErrorAction SilentlyContinue) { return $f.FullName }
        }
        return (Join-Path $Dir 'config.yaml')
    }
    return (Join-Path $Dir 'clash-verge.yaml')
}

# 解析 proxy-groups 里的 select 组名,兼容 "- name: X" 与 "-" 换行 "name: X" 两种 YAML 写法
function Get-SelectProxyGroups([string]$Path) {
    $groups = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    function Add-SelectGroup([string]$Name, [string]$Type) {
        if (-not $Name -or -not $Type) { return }
        $t = ($Type -replace '\s+#.*$', '').Trim().Trim('"',"'").ToLowerInvariant()
        if ($t -ne 'select') { return }
        $g = ($Name -replace '\s+#.*$', '').Trim().Trim('"',"'").Trim()
        if ($g) { $groups.Add($g) }
    }
    $inGroups = $false
    $name = $null; $type = $null
    foreach ($line in @(Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if (-not $inGroups) {
            if ($line -match '^proxy-groups:\s*(?:#.*)?$') { $inGroups = $true }
            continue
        }
        if ($line -match '^[A-Za-z]') { break }
        if ($line -match '^\s*-\s*name:\s*(.+?)\s*$') {
            Add-SelectGroup $name $type
            $name = $Matches[1]; $type = $null
            continue
        }
        if ($line -match '^\s*-\s*(?:#.*)?$') {
            Add-SelectGroup $name $type
            $name = $null; $type = $null
            continue
        }
        if (-not $name -and $line -match '^\s+name:\s*(.+?)\s*$') { $name = $Matches[1]; continue }
        if (-not $type -and $line -match '^\s+type:\s*(.+?)\s*$') { $type = $Matches[1]; continue }
    }
    Add-SelectGroup $name $type
    return @($groups)
}

# ---- 2. 自动识别代理组名(仅 Clash 系;多个 select 组时让用户选,避免静默选错专线) ----
$grp = 'GLOBAL'
if (($PROXY_MODE -eq 'clash-verge' -or $PROXY_MODE -eq 'v-ninja') -and $CLASH_DIR) {
    $clashYaml = Get-ClashConfigYaml $PROXY_MODE $CLASH_DIR
    $groups = @(Get-SelectProxyGroups $clashYaml)
    if ($groups.Count -eq 1) {
        $grp = $groups[0]
    } elseif ($groups.Count -gt 1) {
        Write-Host "识别到多个 select 代理组,请选择:" -ForegroundColor Yellow
        for ($i = 0; $i -lt $groups.Count; $i++) { Write-Host ("  {0}) {1}" -f ($i + 1), $groups[$i]) }
        $pick = Read-Host "请输入序号(直接回车=第一个)"
        if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $groups.Count) { $grp = $groups[[int]$pick - 1] }
        else { $grp = $groups[0] }
    } else {
        $grp = Read-Host "未能自动识别代理组名,请打开 $CLIENT_NAME 查看后输入"
        if (-not $grp) { $grp = 'GLOBAL' }
    }
    Write-Host "[OK] 代理组: $grp (来源: $(Split-Path -Leaf $clashYaml))" -ForegroundColor Green
    if ($grp -match '[,\r\n]') {
        Write-Host "[WARN] 代理组名包含逗号或换行,规则模式可能无法写入;请改名后重跑安装器" -ForegroundColor Yellow
    }
}

# ---- 3. IANA 时区 -> Windows 时区ID ----
function ConvertTo-WindowsTimeZone([string]$iana) {
    $map = @{
        'America/New_York'    = 'Eastern Standard Time'
        'America/Chicago'     = 'Central Standard Time'
        'America/Denver'      = 'Mountain Standard Time'
        'America/Los_Angeles' = 'Pacific Standard Time'
        'America/Toronto'     = 'Eastern Standard Time'
        'America/Vancouver'   = 'Pacific Standard Time'
        'Asia/Singapore'      = 'Singapore Standard Time'
        'Asia/Tokyo'          = 'Tokyo Standard Time'
        'Asia/Seoul'          = 'Korea Standard Time'
        'Asia/Taipei'         = 'Taipei Standard Time'
        'Asia/Hong_Kong'      = 'China Standard Time'
        'Europe/London'       = 'GMT Standard Time'
        'Europe/Berlin'       = 'W. Europe Standard Time'
        'Europe/Paris'        = 'Romance Standard Time'
        'Australia/Sydney'    = 'AUS Eastern Standard Time'
        'Australia/Melbourne' = 'AUS Eastern Standard Time'
        'Asia/Kuala_Lumpur'   = 'Singapore Standard Time'
    }
    if ($map.ContainsKey($iana)) { return $map[$iana] }
    return $null
}
$tzId = ConvertTo-WindowsTimeZone $ianaTz
if (-not $tzId) {
    Write-Host "[WARN] 时区 $ianaTz 无 Windows 映射,回退 Eastern Standard Time" -ForegroundColor Yellow
    $tzId = 'Eastern Standard Time'
}
$TZ_TARGET = $tzId
Write-Host "[OK] 锁定时区: $TZ_TARGET (按出口IP识别)" -ForegroundColor Green

# ---- 4. 安装文件 ----
New-Item -ItemType Directory -Force -Path $BASE | Out-Null
Copy-Item "$PSScriptRoot\claude-switch.ps1"   "$BASE\claude-switch.ps1" -Force
Copy-Item "$PSScriptRoot\SwitcherUI.ps1"      "$BASE\SwitcherUI.ps1" -Force
Copy-Item "$PSScriptRoot\claude-bodyguard.ps1" "$BASE\claude-bodyguard.ps1" -Force

# 写入探测到的客户端模式/代理组名/国家/时区/地区格式(替换串里的 $ 用 $$ 转义,避免被当作捕获组)
$core = Get-Content "$BASE\claude-switch.ps1" -Raw
$modeEsc = $PROXY_MODE.Replace('$', '$$')
$countryEsc = $COUNTRY_TARGET.Replace('$', '$$')
$tzEsc = $TZ_TARGET.Replace('$', '$$')
$localeEsc = $LOCALE_TARGET.Replace('$', '$$')
$grpEsc = $grp.Replace('$', '$$')
$core = $core -replace '\$PROXY_MODE = "[^"]*"', ('$$PROXY_MODE = "' + $modeEsc + '"')
$core = $core -replace '\$COUNTRY_TARGET = "[^"]*"', ('$$COUNTRY_TARGET = "' + $countryEsc + '"')
$core = $core -replace '\$TZ_TARGET = "[^"]*"', ('$$TZ_TARGET = "' + $tzEsc + '"')
$core = $core -replace '\$LOCALE_TARGET = "[^"]*"', ('$$LOCALE_TARGET = "' + $localeEsc + '"')
$core = $core -replace '\$PROXY_GROUP = "[^"]*"', ('$$PROXY_GROUP = "' + $grpEsc + '"')
# 强制写回 UTF-8 BOM:计划任务用 powershell.exe 5.1 读取,无 BOM 会把中文读成乱码
$utf8Bom = New-Object System.Text.UTF8Encoding -ArgumentList $true
[System.IO.File]::WriteAllText("$BASE\claude-switch.ps1", $core, $utf8Bom)
$PROXY_MODE | Out-File -Encoding ascii -NoNewline "$BASE\proxy-mode.txt"

# 版本号由 release 打包时写入 zip 根的 VERSION;开发目录没有该文件则记为 unknown
$versionSrc = Join-Path $PSScriptRoot '..\VERSION'
if (-not (Test-Path -LiteralPath $versionSrc)) { $versionSrc = Join-Path $PSScriptRoot 'VERSION' }
$appVersion = 'unknown'
if (Test-Path -LiteralPath $versionSrc) {
    $rawVersion = Get-Content -LiteralPath $versionSrc -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($null -ne $rawVersion -and ([string]$rawVersion).Trim()) { $appVersion = ([string]$rawVersion).Trim() }
}
[System.IO.File]::WriteAllText((Join-Path $BASE 'version.txt'), $appVersion, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "[OK] 版本: $appVersion" -ForegroundColor Green
Write-Host "[OK] 核心文件已安装到 $BASE (代理模式: $PROXY_MODE / $CLIENT_NAME)" -ForegroundColor Green

# ---- 5. 桌面快捷方式 ----
$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut("$env:USERPROFILE\Desktop\Claude切换器.lnk")
$sc.TargetPath = "powershell.exe"
$sc.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$BASE\SwitcherUI.ps1`""
$sc.WorkingDirectory = $BASE
$sc.Save()
Write-Host "[OK] 桌面快捷方式已创建" -ForegroundColor Green

# ---- 6. 置顶规则:安装阶段不再写 Merge.yaml/Script.js ----
if ($PROXY_MODE -eq 'clash-verge' -or $PROXY_MODE -eq 'v-ninja') {
    Write-Host "[OK] 未改动 Clash 规则;请安装后打开切换器点一次「一键修复」完成规则配置" -ForegroundColor Yellow
    Write-Host "     修复会先识别 Clash 模式:全局/直连模式跳过规则,规则模式写入 profiles\Script.js" -ForegroundColor Yellow
} else {
    Write-Host "[OK] 非 Clash 客户端:请在 $CLIENT_NAME 中为 Claude 域名添加置顶/直连规则" -ForegroundColor Yellow
}

# ---- 7. 系统级配置 ----
Set-TimeZone -Id $TZ_TARGET
try {
    Set-Culture -CultureInfo $LOCALE_TARGET -ErrorAction Stop
    Write-Host "[OK] 地区格式已设置为 $LOCALE_TARGET" -ForegroundColor Green
} catch {
    Write-Host "[WARN] 地区格式未设置,请安装后运行 set-region 或手动在「区域格式」中选择 $LOCALE_TARGET" -ForegroundColor Yellow
}
Get-NetAdapterBinding -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue | Where-Object { $_.Enabled } | Disable-NetAdapterBinding -Confirm:$false
Clear-DnsClientCache
Write-Host "[OK] 时区已锁定 / IPv6 已关闭 / DNS 缓存已刷新" -ForegroundColor Green

# ---- 8. 注册保镖计划任务 ----
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$BASE\claude-bodyguard.ps1`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
Register-ScheduledTask -TaskName 'ClaudeBodyguard' -Action $action -Trigger $trigger -Force | Out-Null
Stop-ScheduledTask -TaskName 'ClaudeBodyguard' -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName 'ClaudeBodyguard'
Write-Host "[OK] 保镖已注册并启动(计划任务,登录自动运行)" -ForegroundColor Green

# ---- 9. 重启客户端使规则生效(仅 Clash 系) ----
if ($PROXY_MODE -eq 'clash-verge' -or $PROXY_MODE -eq 'v-ninja') {
    $appNames = if ($PROXY_MODE -eq 'v-ninja') { @('clash-ninja','Clash V-Ninja','clash-verge-ninja') } else { @('clash-verge','Clash Verge') }
    $exePatterns = if ($PROXY_MODE -eq 'v-ninja') { @('clash-ninja*.exe','Clash V-Ninja*.exe') } else { @('Clash Verge*.exe','clash-verge*.exe') }
    # 先记下运行中进程的真实路径(客户端可能装在 D: 等非默认目录)
    $exePath = $null
    foreach ($appName in $appNames) {
        $p = Get-Process -Name $appName -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1
        if ($p -and -not $exePath) { $exePath = $p.Path }
    }
    foreach ($appName in $appNames) {
        Get-Process -Name $appName -ErrorAction SilentlyContinue | Stop-Process -Force
    }
    Start-Sleep 2
    if (-not $exePath) {
        $cv = foreach ($pattern in $exePatterns) {
            Get-ChildItem "$env:LOCALAPPDATA\Programs" -Recurse -Filter $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        $cv = $cv | Select-Object -First 1
        if ($cv) { $exePath = $cv.FullName }
    }
    if ($exePath) { Start-Process $exePath }
}

Write-Host ""
Write-Host "==================================" -ForegroundColor Green
Write-Host "  安装完成! 双击桌面「Claude切换器」使用" -ForegroundColor Green
Write-Host "  首次使用: 打开后选账号A(自动收编当前登录)" -ForegroundColor Green
Write-Host "==================================" -ForegroundColor Green
pause
