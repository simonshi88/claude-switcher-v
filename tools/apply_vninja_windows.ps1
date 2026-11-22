<#
.SYNOPSIS
    ClaudeSwitcher Windows 版 —— Clash V-Ninja 适配补丁执行器

.DESCRIPTION
    把 tools\vninja-patch.json 里的规则应用到 windows\*.ps1 与 windows\README.md。
    上游每次发新版时：把 tools\ 复制到新版本目录，运行本脚本即可。

    规则语义与 macOS 版的 tools\apply_vninja.py 一致：
      - old 为上游原文锚点，new 为改后内容，count 为 old 在上游文件中的预期出现次数
      - 幂等：再次运行只会输出 [SKIP]
      - 首次改写前生成 <文件>.vninja.bak（上游原文，用于 -Revert）
      - 所有 .ps1 写回时保持 UTF-8 with BOM（Windows PowerShell 5.1 需要）
      - 行尾保持原样（LF 仍 LF，CRLF 仍 CRLF）

.PARAMETER Root
    仓库根目录（含 windows\ 的那一层）。默认取本脚本所在目录的上一层。

.PARAMETER Check
    只检查不写文件；有待应用项时退出码为 1。

.PARAMETER DryRun
    只显示将要做什么，不落盘。

.PARAMETER Revert
    从 <文件>.vninja.bak 还原。

.PARAMETER RulesFile
    规则表路径，默认 tools\vninja-patch-windows.json（缺失时回退 vninja-patch.json）。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\apply_vninja.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\apply_vninja.ps1 -Check
#>
[CmdletBinding()]
param(
    [string]$Root,
    [switch]$Check,
    [switch]$DryRun,
    [switch]$Revert,
    [string]$RulesFile
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) } catch {}

function Fail([string]$Message) {
    Write-Host $Message -ForegroundColor Red
    exit 1
}

# ---- 定位目录与规则表 ----
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
if (-not (Test-Path -LiteralPath $Root)) { Fail "目录不存在: $Root" }
$Root = (Resolve-Path -LiteralPath $Root).ProviderPath
if (Test-Path -LiteralPath (Join-Path $Root 'windows\claude-switch.ps1')) {
    $WinDir = Join-Path $Root 'windows'
} elseif (Test-Path -LiteralPath (Join-Path $Root 'claude-switch.ps1')) {
    $WinDir = $Root
} else {
    Fail "在 $Root 下找不到 windows\claude-switch.ps1（也不是 windows 目录本身）"
}
if (-not $RulesFile) {
    $RulesFile = Join-Path $PSScriptRoot 'vninja-patch-windows.json'
    if (-not (Test-Path -LiteralPath $RulesFile)) { $RulesFile = Join-Path $PSScriptRoot 'vninja-patch.json' }
}
if (-not (Test-Path -LiteralPath $RulesFile)) { Fail "规则表不存在: $RulesFile" }
$rulesDoc = [IO.File]::ReadAllText($RulesFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
$rules = @($rulesDoc.rules)
if ($rules.Count -eq 0) { Fail "规则表为空: $RulesFile" }

# ---- 文件读写（保留 BOM 与行尾） ----
function Read-Source([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $skip = if ($hasBom) { 3 } else { 0 }
    $text = [Text.Encoding]::UTF8.GetString($bytes, $skip, $bytes.Length - $skip)
    $eol = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    [pscustomobject]@{
        Path   = $Path
        Bom    = $hasBom
        Eol    = $eol
        Text   = $text.Replace("`r`n", "`n")
        Changed = $false
    }
}

function Write-Source($Source) {
    $text = $Source.Text
    if ($Source.Eol -eq "`r`n") { $text = $text.Replace("`n", "`r`n") }
    $wantBom = $Source.Bom -or ($Source.Path -like '*.ps1')
    [IO.File]::WriteAllText($Source.Path, $text, (New-Object Text.UTF8Encoding([bool]$wantBom)))
}

function Get-OccurrenceCount([string]$Text, [string]$Needle) {
    if ([string]::IsNullOrEmpty($Needle)) { return 0 }
    $n = 0; $i = 0
    while (($i = $Text.IndexOf($Needle, $i, [StringComparison]::Ordinal)) -ge 0) {
        $n++
        $i += $Needle.Length
    }
    return $n
}

# ---- -Revert：从 .bak 还原 ----
if ($Revert) {
    $restored = 0
    foreach ($file in @($rules | ForEach-Object { $_.file } | Select-Object -Unique)) {
        $target = Join-Path $WinDir $file
        $bak = "$target.vninja.bak"
        if (-not (Test-Path -LiteralPath $bak)) {
            Write-Host ("[SKIP] {0,-22} 没有 .vninja.bak" -f $file)
            continue
        }
        Copy-Item -LiteralPath $bak -Destination $target -Force
        $restored++
        Write-Host ("[ OK ] {0,-22} 已从 .vninja.bak 还原" -f $file)
    }
    Write-Host ""
    Write-Host ("还原 {0} 个文件。.vninja.bak 保留，可再次还原。" -f $restored)
    exit 0
}

# ---- 主流程 ----
$stats = @{ ok = 0; skip = 0; fail = 0; pending = 0 }
$failures = New-Object System.Collections.Generic.List[string]
$sources = @{}
$fileOrder = @($rules | ForEach-Object { $_.file } | Select-Object -Unique)
foreach ($file in $fileOrder) {
    $path = Join-Path $WinDir $file
    if (-not (Test-Path -LiteralPath $path)) { Fail "缺少文件: $path" }
    $sources[$file] = Read-Source $path
}

Write-Host ("规则表: {0}" -f $RulesFile)
Write-Host ("目标目录: {0}" -f $WinDir)
Write-Host ("模式: {0}" -f $(if ($Check) { '检查' } elseif ($DryRun) { '试运行' } else { '应用' }))
Write-Host ""

foreach ($rule in $rules) {
    $id = [string]$rule.id
    $file = [string]$rule.file
    $old = [string]$rule.old
    $new = [string]$rule.new
    $expected = if ($null -ne $rule.count) { [int]$rule.count } else { 1 }
    $note = [string]$rule.note
    $src = $sources[$file]

    if ([string]::IsNullOrEmpty($old)) {
        $stats.fail++
        $failures.Add("[$id] $file 规则 old 为空，无法定位")
        Write-Host ("[FAIL] {0,-5} {1,-22} {2}" -f $id, $file, $note) -ForegroundColor Red
        continue
    }
    if ($old -eq $new) {
        $stats.skip++
        Write-Host ("[SKIP] {0,-5} {1,-22} {2}" -f $id, $file, $note) -ForegroundColor DarkGray
        continue
    }

    $oldCount = Get-OccurrenceCount $src.Text $old
    $newCount = Get-OccurrenceCount $src.Text $new
    $isAppend = $new.Contains($old)

    if ($isAppend) {
        if ($newCount -ge $expected) {
            $stats.skip++
            Write-Host ("[SKIP] {0,-5} {1,-22} {2}（已应用）" -f $id, $file, $note) -ForegroundColor DarkGray
            continue
        }
        if ($oldCount -ne $expected) {
            $stats.fail++
            $msg = "[$id] $file 找不到锚点或部分匹配：旧串出现 $oldCount 处（预期 $expected），上游这段可能已重写"
            $failures.Add($msg)
            Write-Host ("[FAIL] {0,-5} {1,-22} {2}" -f $id, $file, $msg) -ForegroundColor Red
            continue
        }
    } else {
        if ($oldCount -eq 0 -and $newCount -ge 1) {
            $stats.skip++
            Write-Host ("[SKIP] {0,-5} {1,-22} {2}（已应用）" -f $id, $file, $note) -ForegroundColor DarkGray
            continue
        }
        if ($oldCount -eq 0) {
            $stats.fail++
            $msg = "[$id] $file 找不到锚点（上游这段可能已重写）"
            $failures.Add($msg)
            Write-Host ("[FAIL] {0,-5} {1,-22} {2}" -f $id, $file, $msg) -ForegroundColor Red
            continue
        }
        if ($oldCount -ne $expected) {
            $stats.fail++
            $msg = "[$id] $file 部分匹配：旧串仍有 $oldCount 处（预期 $expected），上游可能已改动"
            $failures.Add($msg)
            Write-Host ("[FAIL] {0,-5} {1,-22} {2}" -f $id, $file, $msg) -ForegroundColor Red
            continue
        }
    }

    # 需要应用
    if ($Check) {
        $stats.pending++
        Write-Host ("[TODO] {0,-5} {1,-22} {2}" -f $id, $file, $note) -ForegroundColor Yellow
        continue
    }
    if ($DryRun) {
        $stats.pending++
        Write-Host ("[DRY ] {0,-5} {1,-22} {2}" -f $id, $file, $note) -ForegroundColor Cyan
        continue
    }
    $src.Text = $src.Text.Replace($old, $new)
    $src.Changed = $true
    $stats.ok++
    Write-Host ("[ OK ] {0,-5} {1,-22} {2}" -f $id, $file, $note) -ForegroundColor Green
}

# ---- 语法检查（.ps1 解析，内存中先校验再落盘） ----
$parseResults = @()
foreach ($file in $fileOrder) {
    if ($file -notlike '*.ps1') { continue }
    $src = $sources[$file]
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($src.Text, [ref]$tokens, [ref]$errors)
    $parseResults += [pscustomobject]@{ File = $file; Errors = @($errors) }
}

Write-Host ("-" * 68)
if ($Check) {
    Write-Host ("待应用 {0} · 已应用 {1} · 失败 {2}" -f $stats.pending, $stats.skip, $stats.fail)
} elseif ($DryRun) {
    Write-Host ("将应用 {0} · 已应用 {1} · 失败 {2}" -f $stats.pending, $stats.skip, $stats.fail)
} else {
    Write-Host ("成功 {0} · 跳过 {1} · 失败 {2}" -f $stats.ok, $stats.skip, $stats.fail)
}

$syntaxBad = @($parseResults | Where-Object { $_.Errors.Count -gt 0 })
Write-Host ""
Write-Host "语法检查："
foreach ($r in $parseResults) {
    if ($r.Errors.Count -gt 0) {
        Write-Host ("  ✗ {0}（第 {1} 行: {2}）" -f $r.File, $r.Errors[0].Extent.StartLineNumber, $r.Errors[0].Message) -ForegroundColor Red
    } else {
        Write-Host ("  ✓ {0}" -f $r.File) -ForegroundColor Green
    }
}

if ($stats.fail -gt 0 -or $syntaxBad.Count -gt 0) {
    Write-Host ""
    Write-Host "需要人工处理：" -ForegroundColor Yellow
    foreach ($f in $failures) { Write-Host "  - $f" -ForegroundColor Yellow }
    if ($syntaxBad.Count -gt 0) { Write-Host "  - 语法检查失败，未写入任何文件；请按文档手工核对" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "提示: 打开 docs\Windows-自定义适配与升级.md 的「改动清单」按编号对照修改。" -ForegroundColor Yellow
    exit 1
}
if ($Check -and $stats.pending -gt 0) { exit 1 }

# ---- 落盘（仅在内存中全部通过后） ----
$written = @()
foreach ($file in $fileOrder) {
    $src = $sources[$file]
    if (-not $src.Changed) { continue }
    $bak = "$($src.Path).vninja.bak"
    if (-not (Test-Path -LiteralPath $bak)) {
        Copy-Item -LiteralPath $src.Path -Destination $bak -Force
    }
    Write-Source $src
    $written += $file
}
if ($written.Count -gt 0) {
    Write-Host ""
    Write-Host ("已写入: {0}" -f ($written -join ', ')) -ForegroundColor Green
    Write-Host "上游原文已备份为 <文件>.vninja.bak（需要回退时运行 -Revert）"
}
exit 0
