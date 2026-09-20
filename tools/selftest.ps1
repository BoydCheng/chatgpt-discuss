#!/usr/bin/env pwsh
<#
.SYNOPSIS
  chatgpt-discuss 的自检（改完脚本跑这个，不依赖 AI 自己判断"改对没改对"）。
.DESCRIPTION
  三部分：
    A. 静态检查：对真实脚本跑 lint.ps1（必须 0 ERROR）
    B. 检查器自证：对故意注入坑的样本跑 lint.ps1（必须抓到 ≥6 项）
    C. 离线行为：只测不碰浏览器的路径（用不可达 daemon 逼它提前失败），校验退出码
       T1 -Status 空状态            → 0
       T2 已有锚点 + -New           → 10（拒绝新建）
       T3 非法 -ConvUrl             → 13
       T4 既无 -Question 也无模式   → 13
       T5 锁被活跃进程持有          → 12
       T6 v1 旧文档链接认领         → 3（但必须报"旧格式链接"）
  退出码 0 = 全 PASS。
.EXAMPLE
  pwsh -File selftest.ps1
#>
param(
  [string]$SkillDir = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = "Continue"
$scriptPath = Join-Path $SkillDir "scripts\ask-gpt.ps1"
$lintPath   = Join-Path $SkillDir "tools\lint.ps1"
$badSample  = Join-Path $SkillDir "tools\lint-testdata-bad.ps1"
$pwshExe    = (Get-Process -Id $PID).Path

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
  param([string]$Name, [bool]$Ok, [string]$Detail = "")
  [void]$results.Add([pscustomobject]@{ 项 = $Name; 结果 = $(if ($Ok) { "PASS" } else { "FAIL" }); 说明 = $Detail })
  $color = if ($Ok) { "Green" } else { "Red" }
  Write-Host ("  [{0}] {1}  {2}" -f $(if ($Ok) { "PASS" } else { "FAIL" }), $Name, $Detail) -ForegroundColor $color
}

# 运行脚本并取回 {code, out}
function Invoke-Target {
  param([string[]]$TargetArgs, [hashtable]$Env)
  $saved = @{}
  foreach ($k in $Env.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process'); [Environment]::SetEnvironmentVariable($k, $Env[$k], 'Process') }
  try {
    $raw = & $pwshExe -NoProfile -File $scriptPath @TargetArgs 2>&1
    return @{ code = $LASTEXITCODE; out = ($raw | ForEach-Object { $_.ToString() }) -join "`n" }
  } finally {
    foreach ($k in $Env.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') }
  }
}

$tmpRoot = Join-Path $env:TEMP ("cc-selftest-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$tmpState = Join-Path $tmpRoot "state"
$tmpWork  = Join-Path $tmpRoot "work"
$tmpDocs  = Join-Path $tmpWork "docs\gpt_qa"
New-Item -ItemType Directory -Path $tmpState, $tmpDocs -Force | Out-Null
$envMap = @{ CHATGPT_DISCUSS_STATE = $tmpState }
$deadDaemon = @("-Daemon", "http://127.0.0.1:19999")   # 不可达：逼脚本在碰浏览器之前失败

Write-Host ""
Write-Host "=== A. 静默检查（真实脚本） ===" -ForegroundColor Cyan
& $pwshExe -NoProfile -File $lintPath -Path $scriptPath | Out-Null
Add-Result "A1 lint 真实脚本 0 ERROR" ($LASTEXITCODE -eq 0) "exit=$LASTEXITCODE"

Write-Host ""
Write-Host "=== B. 检查器自证（故意注入坑的样本）===" -ForegroundColor Cyan
$badOut = (& $pwshExe -NoProfile -File $lintPath -Path $badSample) -join "`n"
$badCount = ([regex]::Matches($badOut, '(?m)^\s+(E\d|W\d) ')).Count
Add-Result "B1 样本被拦下（≥6 项）" ($badCount -ge 6 -and $LASTEXITCODE -ne 0) "抓到 $badCount 项"
foreach ($need in @('E1 ', 'E2 ', 'E3 ', 'E4 ')) {
  Add-Result "B2 抓到 $need" ($badOut -match [regex]::Escape($need)) ""
}

Write-Host ""
Write-Host "=== C. 离线行为（不碰浏览器） ===" -ForegroundColor Cyan
Push-Location $tmpWork
try {
  # T1
  $r = Invoke-Target -TargetArgs @("-Status") -Env $envMap
  Add-Result "T1 -Status 空状态 → 0" ($r.code -eq 0) "exit=$($r.code)"

  # T2：先放一个已有锚点的 state
  $docPath = Join-Path $tmpDocs "t2.md"
  @{
    session = 't2'; convUrl = 'https://chatgpt.com/c/6aa00000-0000-0000-0000-000000000000'
    convHistory = @(); docPath = $docPath; title = 't2'; groupTitle = 'GPT讨论：t2'
    rounds = 1; createdAt = '2026-09-14T00:00:00'; updatedAt = '2026-09-14T00:00:00'
  } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $tmpState "t2.json") -Encoding UTF8
  $r = Invoke-Target -TargetArgs (@("-Question", "x", "-Session", "t2", "-New", "-DocPath", $docPath) + $deadDaemon) -Env $envMap
  Add-Result "T2 已有锚点 + -New → 10" ($r.code -eq 10) "exit=$($r.code)"

  # T3
  $r = Invoke-Target -TargetArgs (@("-Question", "x", "-Session", "t3", "-ConvUrl", "not-a-url", "-DocPath", (Join-Path $tmpDocs "t3.md")) + $deadDaemon) -Env $envMap
  Add-Result "T3 非法 -ConvUrl → 13" ($r.code -eq 13) "exit=$($r.code)"

  # T4
  $r = Invoke-Target -TargetArgs @("-Session", "t4") -Env $envMap
  Add-Result "T4 既无 -Question 也无模式 → 13" ($r.code -eq 13) "exit=$($r.code)"

  # T5：伪造一个"活跃进程持有"的锁
  $lockPath = Join-Path $tmpState "t5.lock"
  @{ pid = $PID; time = (Get-Date).ToString("o"); session = 't5' } | ConvertTo-Json -Compress |
    ForEach-Object { [System.IO.File]::WriteAllText($lockPath, $_, (New-Object System.Text.UTF8Encoding($false))) }
  $r = Invoke-Target -TargetArgs (@("-Question", "x", "-Session", "t5", "-DocPath", (Join-Path $tmpDocs "t5.md")) + $deadDaemon) -Env $envMap
  Add-Result "T5 锁被活跃进程持有 → 12" ($r.code -eq 12) "exit=$($r.code)"
  Remove-Item $lockPath -Force -ErrorAction SilentlyContinue

  # T6：v1 旧文档（无标记但有 /c/ 链接）
  $legacyDoc = Join-Path $tmpDocs "legacy.md"
  @(
    "# GPT 讨论：老文档（2026-09-01）"
    "- 会话: rigol-xaxis | 模型: GPT-5.6 Luna | 链接: https://chatgpt.com/c/6aa11111-1111-1111-1111-111111111111"
    ""
    "## Q1"
    "**Q:** 老问题"
  ) -join "`r`n" | Set-Content $legacyDoc -Encoding UTF8
  $r = Invoke-Target -TargetArgs (@("-Question", "x", "-Session", "t6", "-DocPath", $legacyDoc) + $deadDaemon) -Env $envMap
  $adopted = $r.out -match '旧格式链接' -and $r.out -match '6aa11111-1111-1111-1111-111111111111'
  Add-Result "T6 v1 旧文档链接被认领" $adopted "exit=$($r.code)"
} finally {
  Pop-Location
  Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
$pass = @($results | Where-Object { $_.结果 -eq 'PASS' }).Count
$fail = @($results | Where-Object { $_.结果 -eq 'FAIL' }).Count
Write-Host "=== 汇总: $pass PASS / $fail FAIL ===" -ForegroundColor $(if ($fail -eq 0) { "Green" } else { "Red" })
$results | Format-Table -AutoSize
if ($fail -gt 0) { exit 1 }
exit 0
