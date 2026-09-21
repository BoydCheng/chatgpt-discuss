# chatgpt-discuss 共享库：通用文件 IO（无外部依赖）。
# 由 scripts/ask-gpt.ps1 与 tools/*.ps1 通过 dot-source 引用。
# 注意：dot-source 后本文件与调用方共享 $script: 作用域（2026-09-20 实测确认），
# 因此本库**只定义无状态纯函数**，不持有任何可变状态。

function Ensure-Dir { param([string]$Path) if ($Path -and -not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null } }
function Write-Utf8 { param([string]$Path, [string]$Text) Ensure-Dir (Split-Path $Path -Parent); [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false))) }
function Read-Text { param([string]$Path) if (Test-Path $Path) { return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) } return $null }
