#!/usr/bin/env pwsh
<#
.SYNOPSIS
  调整 ChatGPT 网页版的模型与思考强度（只改设置，不发消息、不耗对话额度）。
.DESCRIPTION
  针对登录态的 composer-intelligence-picker（模型+思考强度合并菜单）。
  实测（2026-09-20）：
  - 该菜单是 Radix UI，合成 click 被拦（isTrusted=false）——打开/选择必须走 CDP
    Input.dispatchMouseEvent / Input.dispatchKeyEvent（可信事件）。
  - 思考强度是 role="slider"（min=0 max=4），档位名（剥离模型前缀）：
      0=即时  1=中  2=高  3=极高  4=Pro
    调整方式：slider.focus() 后用 CDP 发 ArrowLeft/ArrowRight。
  - 模型是 role="menuitemradio" 单选（最新 / GPT-5.6 Sol / GPT-5.5…），CDP 点击选项坐标。
  未登录时没有这个菜单（匿名会话无思考强度/模型选择）。
.PARAMETER Thinking
  思考强度：档位名（即时/中/高/极高/Pro）或数字 0-4。留空 = 不改。
.PARAMETER Model
  模型名（部分匹配，如 "5.6"、"Sol"、"最新"）。留空 = 不改。
.PARAMETER Session
  复用的 webbridge session（默认 cc-probe）。会复用该 session 里已有的 ChatGPT 标签。
.PARAMETER Daemon
  webbridge daemon 地址，留空自动探测。
.EXAMPLE
  pwsh -File set-intelligence.ps1                              # 只读显示当前
  pwsh -File set-intelligence.ps1 -Thinking 即时               # 切到即时
  pwsh -File set-intelligence.ps1 -Thinking 0                  # 同上（数字）
  pwsh -File set-intelligence.ps1 -Model "5.6"                 # 切到 GPT-5.6 Sol
  pwsh -File set-intelligence.ps1 -Model Sol -Thinking 中      # 两个一起
.EXITCODES
  0 成功（含只读显示）
  3 daemon 不可用
  5 页面/菜单未就绪
  6 未登录（匿名会话没有该菜单）
  7 目标档位/模型不存在
#>
param(
  [string]$Thinking = "",
  [string]$Model = "",
  [string]$Session = "cc-probe",
  [string]$Daemon = ""
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false
. "$PSScriptRoot\..\scripts\lib\common.ps1"
. "$PSScriptRoot\..\scripts\lib\wb.ps1"

# 思考强度档位（实测，剥离模型前缀）
$THINKING_LEVELS = [ordered]@{ '即时'=0; '中'=1; '高'=2; '极高'=3; 'Pro'=4 }

function Fail { param([int]$Code, [string]$Message) [Console]::Error.WriteLine("ERROR[$Code] $Message"); exit $Code }

function CDP-Click([double]$X, [double]$Y) {
  foreach ($t in @('mousePressed','mouseReleased')) {
    Invoke-WB "cdp" @{ method='Input.dispatchMouseEvent'; params=@{ type=$t; x=$X; y=$Y; button='left'; clickCount=1 } } $Session | Out-Null
  }
}
function CDP-Key([string]$Key, [string]$Code, [int]$Vk) {
  foreach ($t in @('keyDown','keyUp')) {
    Invoke-WB "cdp" @{ method='Input.dispatchKeyEvent'; params=@{ type=$t; key=$Key; code=$Code; windowsVirtualKeyCode=$Vk; nativeVirtualKeyCode=$Vk } } $Session | Out-Null
  }
}

# 登录态探测（匿名会话没有该菜单）
function Get-LoggedIn {
  $js = '(async()=>{try{const r=await fetch("/api/auth/session",{credentials:"include"});const j=await r.json();return (j&&j.user&&j.user.id)?"in":"out"}catch(e){return "unknown"}})()'
  try { $v = Eval-JS $js $Session; if ($v) { return [string]$v } } catch {}
  return 'unknown'
}
# 确保有一个登录态的 ChatGPT 标签（复用优先，没有再开）
function Ensure-LoggedInTab {
  $tabs = @()
  try { $r = Invoke-WB "list_tabs" @{} $Session; if ($r -and $r.tabs) { $tabs = @($r.tabs | Where-Object { $_.url -like "*chatgpt.com/*" }) } } catch {}
  if ($tabs.Count -gt 0) {
    try { Invoke-WB "find_tab" @{ url = $tabs[0].url } $Session | Out-Null } catch {}
  } else {
    Invoke-WB "navigate" @{ url = "https://chatgpt.com/"; newTab = $true; group_title = "模型与思考强度调整" } $Session | Out-Null
    Start-Sleep -Seconds 5
  }
  $login = Get-LoggedIn
  if ($login -eq 'out') { Fail 6 "当前是匿名会话（未登录）——模型/思考强度选择器只在登录态可用。请先在 Edge 登录 ChatGPT。" }
  if ($login -ne 'in') { Fail 5 "登录态探测失败（unknown）——页面可能没加载完" }
}
# composer 里"模型+强度"菜单按钮的坐标
function Get-IntelligenceBtnPoint {
  $js = @'
(()=>{
  const form=document.querySelector('form.group')||document.querySelector('form');
  if(!form) return '';
  const b=[...form.querySelectorAll('button[aria-haspopup="menu"]')].find(x=>x.getAttribute('data-testid')!=='composer-plus-btn');
  if(!b) return '';
  const r=b.getBoundingClientRect();
  return JSON.stringify({x:Math.round(r.x+r.width/2), y:Math.round(r.y+r.height/2), text:(b.textContent||'').trim()});
})()
'@
  try { $v = Eval-JS $js $Session; if ($v) { return ($v | ConvertFrom-Json) } } catch {}
  return $null
}
# 读当前状态：模型（选中的 radio）+ 滑块值
function Read-IntelligenceState {
  $js = @'
(()=>{
  const vis=e=>{try{const r=e.getBoundingClientRect();return r.width>0&&r.height>0}catch(_){return false}};
  const radios=[...document.querySelectorAll('[role="menuitemradio"]')].filter(vis);
  const model = (radios.find(r=>r.getAttribute('aria-checked')==='true')||{}).textContent||'';
  const s=[...document.querySelectorAll('[role="slider"]')].filter(vis)[0];
  return JSON.stringify({ model: model.trim(), thinking: s ? s.getAttribute('aria-valuenow') : null });
})()
'@
  try { $v = Eval-JS $js $Session; if ($v) { return ($v | ConvertFrom-Json) } } catch {}
  return $null
}

# ---------- 主流程 ----------
if (-not $Daemon) { $Daemon = Resolve-DaemonAddr }
$ds = Get-DaemonStatus -Base $Daemon -Attempts 6
if (-not $ds) { Fail 3 (Get-DaemonDiag -Base $Daemon) }

Ensure-LoggedInTab

# 打开菜单（CDP 真实点击；合成 click 被 Radix 拦截）
$pt = Get-IntelligenceBtnPoint
if (-not $pt) { Fail 5 "没找到模型/思考强度菜单按钮（页面结构可能变了）" }
CDP-Click $pt.x $pt.y
Start-Sleep -Seconds 2

$cur = Read-IntelligenceState
if (-not $cur) { Fail 5 "菜单没打开或读不到状态" }
Write-Host ("当前: 模型={0} | 思考强度={1}({2})" -f $cur.model, $cur.thinking, $(if ($cur.thinking -ne $null) { @($THINKING_LEVELS.GetEnumerator())[$cur.thinking].Key } else { '?' }))

$changed = $false

# ---- 调思考强度（先调，避免选模型后菜单关闭） ----
if ($Thinking -ne "") {
  $target = $null
  if ($Thinking -match '^\d$') { $target = [int]$Thinking }
  elseif ($THINKING_LEVELS.Contains($Thinking)) { $target = $THINKING_LEVELS[$Thinking] }
  else { Fail 7 "未知思考强度 '$Thinking'。可选：$($THINKING_LEVELS.Keys -join ' / ')（或 0-4）" }
  if ($target -lt 0 -or $target -gt 4) { Fail 7 "思考强度档位超界（0-4）: $target" }
  if ($cur.thinking -ne $null -and [int]$cur.thinking -ne $target) {
    # 聚焦滑块（JS focus 不改值），再按方向键步进
    $fjs = '(()=>{const s=[...document.querySelectorAll("[role=\"slider\"]")].filter(e=>{try{const r=e.getBoundingClientRect();return r.width>0&&r.height>0}catch(_){return false}})[0]; if(!s) return "no"; s.focus(); return "ok"})()'
    try { Eval-JS $fjs $Session | Out-Null } catch {}
    $nowV = [int]$cur.thinking
    while ($nowV -lt $target) { CDP-Key 'ArrowRight' 'ArrowRight' 39; $nowV++; Start-Sleep -Milliseconds 350 }
    while ($nowV -gt $target) { CDP-Key 'ArrowLeft' 'ArrowLeft' 37; $nowV--; Start-Sleep -Milliseconds 350 }
    $changed = $true
    Write-Host "思考强度 → $target ($($THINKING_LEVELS.Keys | Select-Object -Index $target))"
  } else { Write-Host "思考强度已是目标档，无需调整" }
}

# ---- 选模型 ----
if ($Model -ne "") {
  if ($cur.model -notlike "*$Model*") {
    $xy = @"
(()=>{
  const vis=e=>{try{const r=e.getBoundingClientRect();return r.width>0&&r.height>0}catch(_){return false}};
  const items=[...document.querySelectorAll('[role="menuitemradio"]')].filter(vis);
  const t=items.find(i=>(i.textContent||'').includes('$Model'));
  if(!t) return '';
  const r=t.getBoundingClientRect();
  return JSON.stringify({x:Math.round(r.x+r.width/2), y:Math.round(r.y+r.height/2)});
})()
"@
    $pt2 = $null
    try { $v = Eval-JS $xy $Session; if ($v) { $pt2 = ($v | ConvertFrom-Json) } } catch {}
    if (-not $pt2) { Fail 7 "模型选项里找不到含 '$Model' 的项" }
    CDP-Click $pt2.x $pt2.y
    Start-Sleep -Seconds 1
    $changed = $true
    Write-Host "模型 → $Model"
  } else { Write-Host "模型已是目标，无需调整" }
}

# 读回确认 + 关闭菜单
Start-Sleep -Milliseconds 600
$final = Read-IntelligenceState
try { Eval-JS '(()=>{document.activeElement.dispatchEvent(new KeyboardEvent("keydown",{key:"Escape",bubbles:true}));return "ok"})()' $Session | Out-Null } catch {}

$finalThinkingName = if ($final -and $final.thinking -ne $null) { @($THINKING_LEVELS.GetEnumerator())[[int]$final.thinking].Key } else { '?' }
Write-Host ""
Write-Host ("结果: 模型={0} | 思考强度={1}({2})" -f $(if ($final) { $final.model } else { '?' }), $(if ($final) { $final.thinking } else { '?' }), $finalThinkingName)
if ($changed) { Write-Host "已调整。" } else { Write-Host "未做改动（只读显示）。" }
exit 0
