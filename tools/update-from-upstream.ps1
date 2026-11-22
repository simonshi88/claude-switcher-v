<#
.SYNOPSIS
    从上游（原作者仓库）更新到指定版本，在自定义分支上重新施加 Clash V-Ninja 适配，
    更新 main（上游镜像）+ 推送自定义分支到自己的仓库。

.DESCRIPTION
    分支模型：
      main            = 上游镜像，只跟随 upstream，不放任何自定义改动
      custom/v-ninja  = 上游基线 + 1 个自定义提交（每次更新重建，可安全 force-push）

    标准流程：
      1. git fetch upstream --tags
      2. 暂存自定义文件（tools/、docs/ 里我们自己加的文件）
      3. main 重置到上游 ref 并推送（快进；必要时 force-with-lease）
      4. custom/v-ninja 重置到上游 ref、恢复自定义文件
      5. python tools\apply_vninja.py
         powershell tools\apply_vninja_windows.ps1
      6. 校验：两个执行器 -Check 必须 0 待应用、0 失败
      7. 提交并推送 custom/v-ninja

    所有自定义改动必须写在 tools\vninja-patch*.json / tools\*.ps1 / docs\ 里，
    不要手改上游文件，也不要直接往 main 提交自定义改动。

.PARAMETER Ref
    上游的 tag 或分支。默认取最新的 v* tag（例如 v1.10.0）；没有 tag 时用 upstream/main。

.PARAMETER Branch
    自定义分支名，默认 custom/v-ninja。

.PARAMETER BaseBranch
    上游镜像分支名，默认 main。

.PARAMETER Repo
    仓库根目录，默认本脚本所在目录的上一级。

.PARAMETER NoPush
    只提交，不推送（main 也不推）。

.PARAMETER DryRun
    只 fetch / 重置 / 打补丁 / 校验，不提交、不推送。

.PARAMETER SkipFetch
    跳过 fetch（离线或测试时用）。

.PARAMETER Python
    python 可执行文件，默认 python。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\update-from-upstream.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\update-from-upstream.ps1 -Ref upstream/main -NoPush
#>
[CmdletBinding()]
param(
    [string]$Ref,
    [string]$Branch = 'custom/v-ninja',
    [string]$BaseBranch = 'main',
    [string]$Repo,
    [switch]$NoPush,
    [switch]$DryRun,
    [switch]$SkipFetch,
    [string]$Python = 'python'
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) } catch {}

$UpstreamUrl = 'https://github.com/YOURSJEYO/claude-switcher.git'
$OriginUrl = 'https://github.com/simonshi88/claude-switcher-v.git'

function Fail([string]$Message) {
    Write-Host ""
    Write-Host $Message -ForegroundColor Red
    exit 1
}

function Invoke-Git([string[]]$GitArgs) {
    # git 会把进度/提示写到 stderr（如 "Reset branch 'main'"），
    # 在 $ErrorActionPreference='Stop' 下会被当成异常；这里临时放宽。
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & git -C $Repo -c core.quotepath=false @GitArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    return [pscustomobject]@{ Code = $code; Out = @($out) }
}

function Show-Git([string[]]$GitArgs) {
    $r = Invoke-Git $GitArgs
    if ($r.Out.Count) { $r.Out | ForEach-Object { Write-Host ("  " + $_) } }
    if ($r.Code -ne 0) { Fail ("git " + ($GitArgs -join ' ') + " 失败（退出码 $($r.Code)）") }
    return $r
}

function Test-Ref([string]$Name) {
    return ((Invoke-Git @('rev-parse', '--verify', ($Name + '^{commit}'))).Code -eq 0)
}

# ---- 定位仓库 ----
if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }
if (-not (Test-Path -LiteralPath (Join-Path $Repo '.git'))) { Fail "不是 git 仓库: $Repo" }
$Repo = (Resolve-Path -LiteralPath $Repo).ProviderPath
Write-Host ("仓库: {0}" -f $Repo) -ForegroundColor Cyan
if ($Branch -eq $BaseBranch) { Fail "自定义分支不能和上游镜像分支同名" }

# ---- 修正/补齐 remotes ----
$remotes = @{}
foreach ($line in @((Invoke-Git @('remote')).Out)) { if ($line) { $remotes[([string]$line).Trim()] = $true } }
if (-not $remotes.ContainsKey('upstream')) {
    Write-Host "添加 upstream: $UpstreamUrl"
    Show-Git @('remote', 'add', 'upstream', $UpstreamUrl) | Out-Null
}
$originUrlNow = [string]((Invoke-Git @('remote', 'get-url', 'origin')).Out)
if (-not $originUrlNow) {
    Write-Host "添加 origin: $OriginUrl"
    Show-Git @('remote', 'add', 'origin', $OriginUrl) | Out-Null
} elseif ($originUrlNow -match 'YOURSJEYO') {
    Write-Host "origin 指向原作者，改为你的仓库: $OriginUrl"
    Show-Git @('remote', 'set-url', 'origin', $OriginUrl) | Out-Null
} elseif ($originUrlNow.Trim() -ne $OriginUrl) {
    Write-Host ("警告: origin 当前为 {0}，脚本仍按 {1} 推送" -f $originUrlNow.Trim(), $OriginUrl) -ForegroundColor Yellow
}
Show-Git @('remote', 'set-url', 'upstream', $UpstreamUrl) | Out-Null

# ---- 工作区必须没有已跟踪改动（允许 tools/、docs/ 下的未跟踪文件） ----
$dirtyTracked = (Invoke-Git @('diff', '--quiet')).Code -ne 0
$dirtyStaged = (Invoke-Git @('diff', '--cached', '--quiet')).Code -ne 0
if ($dirtyTracked -or $dirtyStaged) {
    Write-Host "工作区有未提交的已跟踪改动：" -ForegroundColor Yellow
    (Invoke-Git @('status', '--short')).Out | Select-Object -First 10 | ForEach-Object { Write-Host ("  " + $_) }
    Fail "请先提交/还原后再更新（脚本会重置分支）。"
}

# ---- fetch + 解析目标 ref ----
if (-not $SkipFetch) {
    Write-Host "拉取上游..." -ForegroundColor Cyan
    $r = Invoke-Git @('fetch', 'upstream', '--tags', '--prune')
    if ($r.Code -ne 0) {
        $r.Out | ForEach-Object { Write-Host ("  " + $_) }
        $proxy = [string]((Invoke-Git @('config', '--global', '--get', 'http.proxy')).Out)
        Fail "git fetch upstream 失败：确认网络/代理（git 全局 http.proxy=$proxy，Clash 未启动时先启动）"
    }
}

$resolved = $Ref
if (-not $resolved) {
    $tags = @((Invoke-Git @('tag', '--list', 'v*', '--sort=-v:refname')).Out | Where-Object { $_ })
    if ($tags.Count -gt 0) { $resolved = ([string]$tags[0]).Trim() } else { $resolved = 'upstream/main' }
}
$verify = Invoke-Git @('rev-parse', '--verify', ($resolved + '^{commit}'))
if ($verify.Code -ne 0) { Fail "找不到 ref: $resolved（先 fetch，或用 -Ref 指定）" }
$commit = ([string]$verify.Out[0]).Trim()
$subject = [string]((Invoke-Git @('log', '-1', '--format=%s', $commit)).Out[0])
Write-Host ("目标: {0}  {1}  {2}" -f $resolved, $commit.Substring(0, [Math]::Min(10, $commit.Length)), $subject) -ForegroundColor Cyan

# ---- 暂存「我们自己新增」的文件（重置会删掉它们） ----
$prevHead = ([string]((Invoke-Git @('rev-parse', 'HEAD')).Out[0])).Trim()
$preserveBase = $null
if (Test-Ref $Branch) { $preserveBase = $Branch }
elseif (Test-Ref $BaseBranch) { $preserveBase = $BaseBranch }
else { $preserveBase = 'HEAD' }
$addedByUs = @()
if ($preserveBase -ne $commit) {
    $addedByUs = @((Invoke-Git @('diff', '--name-only', '--diff-filter=A', ($commit + '..' + $preserveBase))).Out | Where-Object { $_ })
}
$untracked = @((Invoke-Git @('ls-files', '--others', '--exclude-standard')).Out | Where-Object { $_ })
$preserve = @($addedByUs + $untracked | Where-Object { $_ -match '^(tools/|docs/)' } | Sort-Object -Unique)
$stashDir = Join-Path $env:TEMP ('vninja-keep-' + [guid]::NewGuid().ToString('N'))
if ($preserve.Count -gt 0) {
    Write-Host ("暂存自定义文件 {0} 个..." -f $preserve.Count)
    foreach ($rel in $preserve) {
        $srcFile = Join-Path $Repo $rel
        if (-not (Test-Path -LiteralPath $srcFile)) { continue }
        $dstFile = Join-Path $stashDir $rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dstFile) | Out-Null
        Copy-Item -LiteralPath $srcFile -Destination $dstFile -Force
    }
}

# ---- 更新 main：上游镜像 ----
Write-Host ("重置 {0} 到 {1} ..." -f $BaseBranch, $resolved) -ForegroundColor Cyan
Show-Git @('checkout', '-B', $BaseBranch, $commit) | Out-Null
if (-not $NoPush) {
    Write-Host ("推送 {0} -> origin ..." -f $BaseBranch) -ForegroundColor Cyan
    $pushBase = Invoke-Git @('push', '--force-with-lease', 'origin', $BaseBranch)
    $pushBase.Out | ForEach-Object { Write-Host ("  " + $_) }
    if ($pushBase.Code -ne 0) { Fail "推送 $BaseBranch 失败（代理/凭据？）。本地已重置，可手工重试。" }
}

# ---- 重建自定义分支 ----
Write-Host ("重建 {0} 到 {1} ..." -f $Branch, $resolved) -ForegroundColor Cyan
Show-Git @('checkout', '-B', $Branch, $commit) | Out-Null

if ($preserve.Count -gt 0) {
    foreach ($rel in $preserve) {
        $srcFile = Join-Path $stashDir $rel
        if (-not (Test-Path -LiteralPath $srcFile)) { continue }
        $dstFile = Join-Path $Repo $rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dstFile) | Out-Null
        Copy-Item -LiteralPath $srcFile -Destination $dstFile -Force
    }
}
Remove-Item -LiteralPath $stashDir -Recurse -Force -ErrorAction SilentlyContinue

# ---- 施加补丁 ----
$macTool = Join-Path $Repo 'tools\apply_vninja.py'
$winTool = Join-Path $Repo 'tools\apply_vninja_windows.ps1'
if (-not (Test-Path $macTool)) { Fail "缺少 $macTool（tools 必须随自定义分支一起保留）" }
if (-not (Test-Path $winTool)) { Fail "缺少 $winTool" }

Write-Host "施加 mac 补丁..." -ForegroundColor Cyan
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $Python $macTool --root $Repo
$pyCode = $LASTEXITCODE
$ErrorActionPreference = $prevEap
if ($pyCode -ne 0) { Fail "mac 补丁有失败项：按 docs\新增代理客户端适配规范.md 第 2 节（规则表 id）修正 old/new 后重跑。未提交任何改动。" }

Write-Host "施加 windows 补丁..." -ForegroundColor Cyan
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& powershell -NoProfile -ExecutionPolicy Bypass -File $winTool -Root $Repo
$winCode = $LASTEXITCODE
$ErrorActionPreference = $prevEap
if ($winCode -ne 0) { Fail "windows 补丁有失败项：按 docs\Windows-自定义适配与升级.md 第 2 节修正 tools\vninja-patch-windows.json 后重跑。未提交任何改动。" }

Write-Host "校验..." -ForegroundColor Cyan
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $Python $macTool --root $Repo --check | Out-Null
$pyCheck = $LASTEXITCODE
& powershell -NoProfile -ExecutionPolicy Bypass -File $winTool -Root $Repo -Check | Out-Null
$winCheck = $LASTEXITCODE
$ErrorActionPreference = $prevEap
if ($pyCheck -ne 0) { Fail "mac 侧 -check 未通过（仍有待应用或失败项）。" }
if ($winCheck -ne 0) { Fail "windows 侧 -Check 未通过（仍有待应用或失败项）。" }

# 打补丁会生成 <文件>.vninja.bak；git 里用基线恢复即可，不提交这些备份
Get-ChildItem -LiteralPath $Repo -Recurse -File -Filter '*.vninja.bak' -ErrorAction SilentlyContinue | Remove-Item -Force

# 确保 .gitignore 忽略补丁备份（首次添加后随自定义提交保留）
$gitignore = Join-Path $Repo '.gitignore'
if (Test-Path -LiteralPath $gitignore) {
    $gi = [IO.File]::ReadAllText($gitignore, [Text.Encoding]::UTF8)
    if ($gi -notmatch '(?m)^\*\.vninja\.bak\s*$') {
        [IO.File]::WriteAllText($gitignore, $gi.TrimEnd() + "`n*.vninja.bak`n", (New-Object Text.UTF8Encoding($false)))
    }
}
$stat = @((Invoke-Git @('status', '--porcelain')).Out | Where-Object { $_ })
if ($stat.Count -eq 0) {
    Write-Host "没有产生改动：当前基线已包含全部适配？" -ForegroundColor Yellow
    exit 0
}
Write-Host ("改动 {0} 个文件：" -f $stat.Count)
$stat | Select-Object -First 20 | ForEach-Object { Write-Host ("  " + $_) }
Write-Host ""
& git -C $Repo --no-pager diff --stat

if ($DryRun) {
    Write-Host ""
    Write-Host "DryRun：未提交、未推送（main 可能已本地重置）。确认无误后去掉 -DryRun 重跑。" -ForegroundColor Yellow
    exit 0
}

# ---- 提交自定义分支 ----
Show-Git @('add', '-A') | Out-Null
$message = "custom: Clash V-Ninja 适配（$resolved）"
Show-Git @('commit', '-m', $message) | Out-Null
$newHead = ([string]((Invoke-Git @('rev-parse', '--short', 'HEAD')).Out[0])).Trim()
Write-Host ("已提交 {0}: {1}" -f $newHead, $message) -ForegroundColor Green

if ($NoPush) {
    Write-Host "NoPush：未推送。" -ForegroundColor Yellow
    exit 0
}

Write-Host ("推送 {0} -> origin ..." -f $Branch) -ForegroundColor Cyan
$push = Invoke-Git @('push', '--force-with-lease', 'origin', $Branch)
$push.Out | ForEach-Object { Write-Host ("  " + $_) }
if ($push.Code -ne 0) {
    $proxy = [string]((Invoke-Git @('config', '--global', '--get', 'http.proxy')).Out)
    Fail "推送失败：检查代理（http.proxy=$proxy，Clash 未启动时先启动）与 GitHub 凭据；本地提交已保留，可手工重试 git push --force-with-lease origin $Branch"
}
Write-Host ("完成：{0} = {1} + 自定义提交 {2}" -f $Branch, $resolved, $newHead) -ForegroundColor Green
Write-Host "需要安装到本机时运行：powershell -File tools\deploy_vninja.ps1" -ForegroundColor Cyan
