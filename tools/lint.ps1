#!/usr/bin/env pwsh
<#
.SYNOPSIS
  PowerShell 工具脚本的 AST 级静态检查器（专治 ask-gpt 这类长脚本的"反复踩坑"）。
.DESCRIPTION
  检查项（E=必须修，W=需确认）：

  E1  参数名与 PowerShell 自动变量/关键字冲突（$args / $input / $error / $host ...）
      → 参数被静默吃掉（实测：navigate 报 "url is required"，被误判成网络抖动）
  E2  [switch] 参数被当普通变量赋值（$new vs -New、$status vs -Status）
      → 变量名大小写不敏感 → metadata 异常崩溃
  E3  调用未定义的命令（函数被删/改名后的残留调用）
  E4  Write-Error 之后跟 exit → exit 不可达（EAP=Stop 时 Write-Error 先抛异常）
      → 所有文档化的退出码都会变成 1
  W1  脚本级参数在别处被重新赋值（可能是有意，但常是大小写撞名）
  W2  `$x | Get-Content` 未显式写 -Path（PS7 下绑不到，报 input object cannot be bound）
  W3  函数内直接 exit（绕过统一失败出口）→ 持锁时会残留 .lock
.PARAMETER Path
  要检查的脚本路径。
.PARAMETER Strict
  W 级也视为失败（退出码非 0）。
.EXAMPLE
  pwsh -File lint.ps1 -Path ..\scripts\ask-gpt.ps1
#>
param(
  [Parameter(Mandatory = $true)][string]$Path,
  [switch]$Strict
)

$ErrorActionPreference = "Continue"
if (-not (Test-Path $Path)) { Write-Host "找不到文件: $Path" -ForegroundColor Red; exit 2 }
$Path = (Resolve-Path $Path).Path

# 注意：下面所有变量名都刻意错开大小写不再冲突（本检查器的 v1 就栽在 $e/$E 上）
$errs = New-Object System.Collections.Generic.List[string]
$warns = New-Object System.Collections.Generic.List[string]

$tokens = $null; $parseErrors = $null
$tree = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
foreach ($perr in $parseErrors) {
  [void]$errs.Add("E0 行$($perr.Extent.StartLineNumber) 语法错误: $($perr.Message)")
}

$RESERVED = @(
  'args', 'input', 'error', 'host', 'home', 'pid', 'true', 'false', 'null', 'matches', 'psitem',
  'this', '_', 'pscmdlet', 'psboundparameters', 'myinvocation', 'executioncontext', 'stacktrace',
  'psculture', 'psuiculture', 'psscriptroot', 'pscommandpath', 'pwd', '?', '^', '$',
  'foreach', 'switch', 'function', 'if', 'else', 'return'
)

function Get-OwnerFunctionName {
  param($NodeAst)
  $cursor = $NodeAst.Parent
  while ($cursor) {
    if ($cursor -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $cursor.Name }
    $cursor = $cursor.Parent
  }
  return '<script>'
}

# ---------- 收集参数声明（区分脚本级 / 函数级） ----------
$scriptParam = @{}    # lower(name) -> @{type;name;line}
$funcParam = @{}      # "fn|lower(name)" -> @{type;name;line;fn}
foreach ($pbAst in $tree.FindAll({ param($n) $n -is [System.Management.Automation.Language.ParamBlockAst] }, $true)) {
  $owner = Get-OwnerFunctionName $pbAst
  foreach ($prm in $pbAst.Parameters) {
    $typeName = if ($prm.StaticType) { $prm.StaticType.Name } else { 'Object' }
    $rawName = $prm.Name.VariablePath.UserPath
    $keyName = $rawName.ToLower()
    $rec = @{ type = $typeName; name = $rawName; line = $prm.Extent.StartLineNumber; fn = $owner }
    if ($owner -eq '<script>') {
      if (-not $scriptParam.ContainsKey($keyName)) { $scriptParam[$keyName] = $rec }
    } else {
      $fk = "$owner|$keyName"
      if (-not $funcParam.ContainsKey($fk)) { $funcParam[$fk] = $rec }
    }
    # E1
    if ($RESERVED -contains $keyName) {
      [void]$errs.Add("E1 行$($prm.Extent.StartLineNumber) 参数名 `$$rawName 与 PowerShell 自动变量/关键字冲突 → 参数会被静默吃掉")
    }
  }
}

# ---------- E2 / W1 ----------
foreach ($asg in $tree.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
  $lhsAst = $asg.Left
  if ($lhsAst -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
  $varName = $lhsAst.VariablePath.UserPath
  $varKey = $varName.ToLower()
  $ownerFn = Get-OwnerFunctionName $asg

  # 函数自己的参数在自己函数体内赋值 → 正常
  $isOwnFuncParam = $funcParam.ContainsKey("$ownerFn|$varKey")

  if ($scriptParam.ContainsKey($varKey)) {
    $info = $scriptParam[$varKey]
    if ($info.type -eq 'SwitchParameter') {
      [void]$errs.Add("E2 行$($asg.Extent.StartLineNumber) `$$varName 是【脚本级 switch 参数】却被赋值 —— 大小写不敏感，会抛 metadata 异常（典型：`$new vs -New、`$status vs -Status）")
    } else {
      [void]$warns.Add("W1 行$($asg.Extent.StartLineNumber) `$$varName 是脚本级参数（$($info.type)）在此被重新赋值，确认不是大小写撞名")
    }
  } elseif ($funcParam.ContainsKey($varKey) -and -not $isOwnFuncParam) {
    # 用了别处函数参数同名的变量（跨函数），只在 switch 型时报
    foreach ($fk in $funcParam.Keys) {
      if ($fk.EndsWith("|$varKey") -and $funcParam[$fk].type -eq 'SwitchParameter') {
        [void]$errs.Add("E2 行$($asg.Extent.StartLineNumber) `$$varName 与函数 '$($funcParam[$fk].fn)' 的 switch 参数同名并被赋值 → 大小写不敏感，可能抛 metadata 异常")
        break
      }
    }
  }
}

# ---------- E3 ----------
$definedFns = @{}
foreach ($fnAst in $tree.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
  $definedFns[$fnAst.Name.ToLower()] = $true
}
$resolvedCache = @{}
foreach ($cmdAst in $tree.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
  $cmdName = $cmdAst.GetCommandName()
  if (-not $cmdName) { continue }
  if ($cmdName -notmatch '^[A-Za-z][A-Za-z0-9]*-[A-Za-z][A-Za-z0-9]*$') { continue }
  if ($definedFns.ContainsKey($cmdName.ToLower())) { continue }
  if (-not $resolvedCache.ContainsKey($cmdName)) {
    $resolvedCache[$cmdName] = [bool](Get-Command $cmdName -ErrorAction SilentlyContinue)
  }
  if (-not $resolvedCache[$cmdName]) {
    [void]$errs.Add("E3 行$($cmdAst.Extent.StartLineNumber) 调用了未定义的命令 '$cmdName'（函数已删/改名？）")
  }
}

# ---------- E4 ----------
foreach ($blockAst in $tree.FindAll({ param($n) $n -is [System.Management.Automation.Language.StatementBlockAst] }, $true)) {
  $stmtList = $blockAst.Statements
  for ($si = 0; $si -lt $stmtList.Count; $si++) {
    $weHits = $stmtList[$si].FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Write-Error'
      }, $true)
    if ($weHits.Count -eq 0) { continue }
    for ($sj = $si + 1; $sj -lt $stmtList.Count; $sj++) {
      $exitHits = $stmtList[$sj].FindAll({ param($n) $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true)
      if ($exitHits.Count -gt 0) {
        [void]$errs.Add("E4 行$($exitHits[0].Extent.StartLineNumber) 该 exit 不可达 —— 前面的 Write-Error 在 `$ErrorActionPreference='Stop' 下会先抛异常（退出码变成 1）")
        break
      }
    }
  }
}

# ---------- W2 ----------
foreach ($pipeAst in $tree.FindAll({ param($n) $n -is [System.Management.Automation.Language.PipelineAst] }, $true)) {
  $elemList = $pipeAst.PipelineElements
  for ($pi = 1; $pi -lt $elemList.Count; $pi++) {
    $curEl = $elemList[$pi]
    if ($curEl -isnot [System.Management.Automation.Language.CommandAst]) { continue }
    if ($curEl.GetCommandName() -ne 'Get-Content') { continue }
    $prevEl = $elemList[$pi - 1]
    if ($prevEl -is [System.Management.Automation.Language.CommandAst]) { continue }
    $pathParamHit = @($curEl.CommandElements | Where-Object {
        $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
        @('Path', 'LiteralPath', 'PSPath') -contains $_.ParameterName
      }).Count -gt 0
    if (-not $pathParamHit) {
      [void]$warns.Add("W2 行$($curEl.Extent.StartLineNumber) 表达式 | Get-Content 未显式写 -Path → PS7 下绑不到；请用 -Path，或改用 [IO.File]::ReadAllText")
    }
  }
}

# ---------- W3 ----------
foreach ($exitAst in $tree.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true)) {
  $ownFn = Get-OwnerFunctionName $exitAst
  if ($ownFn -eq '<script>' -or $ownFn -eq 'Fail') { continue }
  [void]$warns.Add("W3 行$($exitAst.Extent.StartLineNumber) 函数 '$ownFn' 内直接 exit（绕过统一失败出口）→ 持锁时会残留 .lock")
}

# ---------- 输出 ----------
Write-Host ""
Write-Host "=== lint: $(Split-Path $Path -Leaf) ===" -ForegroundColor Cyan
if ($errs.Count -eq 0) {
  Write-Host "ERROR  0" -ForegroundColor Green
} else {
  Write-Host "ERROR  $($errs.Count)" -ForegroundColor Red
  foreach ($errText in $errs) { Write-Host "  $errText" -ForegroundColor Red }
}
if ($warns.Count -eq 0) {
  Write-Host "WARN   0" -ForegroundColor Green
} else {
  Write-Host "WARN   $($warns.Count)" -ForegroundColor Yellow
  foreach ($warnText in $warns) { Write-Host "  $warnText" -ForegroundColor Yellow }
}
Write-Host ""

if ($errs.Count -gt 0) { exit 1 }
if ($Strict -and $warns.Count -gt 0) { exit 1 }
exit 0
