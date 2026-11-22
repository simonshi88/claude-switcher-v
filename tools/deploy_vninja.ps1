<#
.SYNOPSIS
    ClaudeSwitcher Windows 版 —— 把打好补丁的文件部署到当前用户安装目录

.DESCRIPTION
    上游发新版后，流程是：
      1) 解压新版本 → 2) 复制 tools\ 与 docs\ 进去 → 3) 运行 tools\apply_vninja.ps1
      4) 运行 tools\deploy_vninja.ps1 覆盖已安装的 %USERPROFILE%\.claude-switcher

    本脚本只做「用户目录」内的替换，不需要管理员：
      - 先备份现有 claude-switch.ps1 / claude-bodyguard.ps1 / SwitcherUI.ps1 与 proxy-mode.txt
      - 保留 COUNTRY_TARGET / TZ_TARGET / LOCALE_TARGET，PROXY_MODE 设为 v-ninja
      - PROXY_GROUP 默认沿用现值，可用 -Group 指定
      - version.txt 写成本次版本（避免更新器把官方新版当成可更新项而覆盖补丁）
      - 重启 ClaudeBodyguard 计划任务，让新保镖脚本生效

    系统级设置（锁时区 / 关 IPv6）仍需管理员，不在本脚本范围内。

.PARAMETER Source
    打好补丁的 windows 目录，默认取本脚本所在目录的上一层。

.PARAMETER Base
    安装目录，默认 %USERPROFILE%\.claude-switcher。

.PARAMETER Version
    写入 version.txt 的版本号，默认读取 windows\..\VERSION。

.PARAMETER Mode
    代理客户端模式，默认 v-ninja。

.PARAMETER Group
    代理组名；省略时沿用已安装脚本里的 PROXY_GROUP。

.PARAMETER SkipTaskRestart
    不重启 ClaudeBodyguard 计划任务。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\deploy_vninja.ps1
#>
[CmdletBinding()]
param(
    [string]$Source,
    [string]$Base,
    [string]$Version,
    [string]$Mode = 'v-ninja',
    [string]$Group,
    [switch]$SkipTaskRestart
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) } catch {}

function Fail([string]$Message) {
    Write-Host $Message -ForegroundColor Red
    exit 1
}

if (-not $Source) { $Source = Split-Path -Parent $PSScriptRoot }
if (-not (Test-Path -LiteralPath (Join-Path $Source 'claude-switch.ps1'))) {
    $candidate = Join-Path $Source 'windows'
    if (Test-Path -LiteralPath (Join-Path $candidate 'claude-switch.ps1')) { $Source = $candidate }
    else { Fail "在 $Source 下找不到 claude-switch.ps1" }
}
$Source = (Resolve-Path -LiteralPath $Source).ProviderPath
if (-not $Base) { $Base = Join-Path $env:USERPROFILE '.claude-switcher' }
if (-not (Test-Path -LiteralPath $Base)) { Fail "安装目录不存在: $Base（请先运行安装器 install.ps1）" }
$Base = (Resolve-Path -LiteralPath $Base).ProviderPath

$files = @('claude-switch.ps1', 'claude-bodyguard.ps1', 'SwitcherUI.ps1')
foreach ($f in $files) {
    if (-not (Test-Path -LiteralPath (Join-Path $Source $f))) { Fail "源目录缺少 $f" }
}
$coreText = [IO.File]::ReadAllText((Join-Path $Source 'claude-switch.ps1'), [Text.Encoding]::UTF8)
if ($coreText -notmatch "v-ninja") { Fail "源目录的 claude-switch.ps1 不含 v-ninja 适配，请先运行 tools\apply_vninja.ps1" }

# 版本号
if (-not $Version) {
    foreach ($vf in @((Join-Path (Split-Path -Parent $Source) 'VERSION'), (Join-Path $Source 'VERSION'))) {
        if (Test-Path -LiteralPath $vf) {
            $Version = ([IO.File]::ReadAllText($vf, [Text.Encoding]::UTF8)).Trim()
            break
        }
    }
}
if (-not $Version) {
    # 源码仓库没有 VERSION 文件时，用最近的 git tag（如 v1.10.0）。
    # 先试 $Source 本身（windows 目录也在仓库内），再试它的上一级。
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        foreach ($repoPath in @($Source, (Split-Path -Parent $Source))) {
            $tag = (& git -C $repoPath describe --tags --abbrev=0 2>$null)
            if (-not $tag) { $tag = (& git -C $repoPath describe --tags --always 2>$null) }
            if ($tag) { $Version = (([string]$tag).Trim() -replace '^[vV]', ''); break }
        }
    } finally {
        $ErrorActionPreference = $prevEap
    }
}
if (-not $Version) {
    Write-Host "[WARN] 未能确定版本号（没有 VERSION 且不是 git 仓库）；将写入 unknown，可用 -Version 1.10.0 指定" -ForegroundColor Yellow
    $Version = 'unknown'
}

# 旧配置
$oldCorePath = Join-Path $Base 'claude-switch.ps1'
$oldCore = [IO.File]::ReadAllText($oldCorePath, [Text.Encoding]::UTF8)
function OldValue([string]$name) {
    $m = [regex]::Match($oldCore, '(?m)^\$' + $name + '\s*=\s*"([^"]*)"')
    if ($m.Success) { return $m.Groups[1].Value } else { return $null }
}
$oldVersion = 'unknown'
$verPath = Join-Path $Base 'version.txt'
if (Test-Path -LiteralPath $verPath) {
    $v = ([IO.File]::ReadAllText($verPath, [Text.Encoding]::UTF8)).Trim()
    if ($v) { $oldVersion = $v }
}
$country = OldValue 'COUNTRY_TARGET'
$tz      = OldValue 'TZ_TARGET'
$locale  = OldValue 'LOCALE_TARGET'
$oldGrp  = OldValue 'PROXY_GROUP'
if (-not $country) { Fail '无法从已安装脚本读取 COUNTRY_TARGET' }
if (-not $tz)      { Fail '无法从已安装脚本读取 TZ_TARGET' }
if (-not $locale)  { Fail '无法从已安装脚本读取 LOCALE_TARGET' }
if (-not $Group)   { $Group = $oldGrp }
if (-not $Group)   { Fail '无法确定 PROXY_GROUP，请用 -Group 指定（例如 -Group "💬 Ai平台"）' }

# 备份
$stamp = Get-Date -Format 'yyyyMMddHHmmss'
$backup = Join-Path $Base ("backup-" + $oldVersion + "-" + $stamp)
New-Item -ItemType Directory -Path $backup -Force | Out-Null
foreach ($f in $files) { Copy-Item -LiteralPath (Join-Path $Base $f) -Destination (Join-Path $backup $f) -Force }
if (Test-Path -LiteralPath (Join-Path $Base 'proxy-mode.txt')) {
    Copy-Item -LiteralPath (Join-Path $Base 'proxy-mode.txt') -Destination (Join-Path $backup 'proxy-mode.txt') -Force
}
if (Test-Path -LiteralPath $verPath) { Copy-Item -LiteralPath $verPath -Destination (Join-Path $backup 'version.txt') -Force }

# 写新核心（保留配置，PROXY_MODE 设为 -Mode）
$newText = $coreText
$pairs = [ordered]@{
    'PROXY_MODE'     = $Mode
    'COUNTRY_TARGET' = $country
    'TZ_TARGET'      = $tz
    'LOCALE_TARGET'  = $locale
    'PROXY_GROUP'    = $Group
}
foreach ($name in $pairs.Keys) {
    $value = [string]$pairs[$name]
    $pattern = '(?m)^(\$' + $name + '\s*=\s*")[^"]*(")'
    $newText = [regex]::Replace($newText, $pattern, { param($m) $m.Groups[1].Value + $value + $m.Groups[2].Value })
}
if ($newText -eq $coreText -and $Mode -ne 'v-ninja') { Fail '核心配置行未更新' }
[IO.File]::WriteAllText($oldCorePath, $newText, (New-Object Text.UTF8Encoding($true)))
foreach ($f in @('claude-bodyguard.ps1', 'SwitcherUI.ps1')) {
    Copy-Item -LiteralPath (Join-Path $Source $f) -Destination (Join-Path $Base $f) -Force
}
[IO.File]::WriteAllText((Join-Path $Base 'proxy-mode.txt'), $Mode, [Text.Encoding]::ASCII)
[IO.File]::WriteAllText($verPath, $Version, (New-Object Text.UTF8Encoding($false)))
Remove-Item -LiteralPath (Join-Path $Base 'update-check.json') -Force -ErrorAction SilentlyContinue

Write-Host ("源目录  : {0}" -f $Source)
Write-Host ("安装目录: {0}" -f $Base)
Write-Host ("备份    : {0}" -f $backup) -ForegroundColor DarkGray
Write-Host ("版本    : {0} -> {1}" -f $oldVersion, $Version)
Write-Host ("模式    : {0}   代理组: {1}" -f $Mode, $Group)
Write-Host ("保留    : COUNTRY_TARGET={0} TZ_TARGET={1} LOCALE_TARGET={2}" -f $country, $tz, $locale)

# 重启保镖任务
if (-not $SkipTaskRestart) {
    try {
        Stop-ScheduledTask -TaskName 'ClaudeBodyguard' -ErrorAction Stop
        Start-Sleep -Seconds 1
        Start-ScheduledTask -TaskName 'ClaudeBodyguard' -ErrorAction Stop
        Write-Host ("保镖任务: {0}" -f (Get-ScheduledTask -TaskName 'ClaudeBodyguard').State) -ForegroundColor Green
    } catch {
        Write-Host ("保镖任务未重启（可稍后手动重启）: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
}

# 部署后自检（只读命令）
Write-Host ""
Write-Host "部署后自检：" -ForegroundColor Cyan
try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Base 'claude-switch.ps1') get-client
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Base 'claude-switch.ps1') check
    if ($LASTEXITCODE -ne 0) { Write-Host "check 未通过，请看上面的检查明细（claude-switch.ps1 checkdetail）" -ForegroundColor Yellow }
} catch {
    Write-Host ("自检命令执行失败: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
}

Write-Host ""
Write-Host "完成。需要回滚时，把备份目录里的文件复制回安装目录，并恢复 version.txt。" -ForegroundColor Green
