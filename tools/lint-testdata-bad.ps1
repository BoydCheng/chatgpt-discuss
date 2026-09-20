#!/usr/bin/env pwsh
# 负向测试样本：故意包含 lint.ps1 应该抓到的全部坑（不要修复它）
param(
  [string]$args = "bad",          # E1: $args 是自动变量
  [switch]$New,                   # 供 E2 用
  [switch]$Status,
  [string]$Path = ""
)

$ErrorActionPreference = "Stop"

function Do-Work {
  param([string]$S)
  $out = $S + "!"
  if (-not $out) { exit 3 }      # W3: 函数内直接 exit
  return $out
}

# E2: [switch]$New 被当普通变量赋值（$new 与 $New 大小写不敏感）
$new = 1

# E2: [switch]$Status 同理
$status = "running"

# E3: 调用不存在的命令
Read-MissingFile -Path $Path | Out-Null

# W2: 表达式 | Get-Content 未写 -Path
$files = Get-ChildItem -File $Path -ErrorAction SilentlyContinue
foreach ($f in $files) {
  $txt = $f.FullName | Get-Content -Raw -Encoding UTF8
}

# E4: Write-Error 后面跟 exit（exit 不可达）
if (-not $Path) {
  Write-Error "Path 必填"
  exit 13
}

Do-Work "x" | Out-Null
