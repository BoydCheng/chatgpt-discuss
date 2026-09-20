#!/usr/bin/env pwsh
<#
.SYNOPSIS
  与网页版 ChatGPT 完成一轮问答（真实浏览器 via Kimi WebBridge）。v2
.DESCRIPTION
  连续性设计（这是 v2 与 v1 的根本区别）:
    * 一个讨论的唯一身份 = ChatGPT 会话 URL https://chatgpt.com/c/<uuid>
      —— 持久化在 state\<session>.json，并回写进文档头的 chatgpt-discuss 注释。
    * 浏览器标签组（webbridge session）只是执行通道：标签丢了拿 convUrl 重开即可，
      连续性不受影响。
    * -New 幂等：锚点已存在时拒绝新建（exit 10），确认要开新线程必须显式 -ForceNew。
    * 标签恢复有硬上限 -MaxRecover（默认 2），绝不在轮询里反复开新标签。
    * 发送前硬校验 location.href 必须属于锚定会话（exit 11）。
    * 文档头由本脚本写（含链接），不需要也不允许 AI 手写。
.PARAMETER Question
  要问的问题（支持中文）。
.PARAMETER Session
  讨论标识（slug）。不传时: 有 -DocPath 就从文档名推导；否则复用当前工作区最近用过的讨论。
.PARAMETER DocPath
  Q&A 追加写入的 Markdown 文档。不传时: 优先复用该 session 已记录的文档（跨天不拆文件）。
.PARAMETER Title
  文档标题（仅首轮写入）。
.PARAMETER GroupTitle
  浏览器标签组显示名（仅建组时生效）。
.PARAMETER ConvUrl
  显式指定要锚定的已有会话（https://chatgpt.com/c/<uuid>）。恢复/接管时用。
.PARAMETER New
  声明"这是一个新讨论线程"。若该 session 已有锚点 → 拒绝（exit 10）。不加也能正常跑。
.PARAMETER ForceNew
  确认要放弃原线程、开一个新的（旧链接进 history 归档）。
.PARAMETER Status
  只读列出所有已记录的讨论（不碰浏览器、不加锁）后退出。
.PARAMETER CloseExtras
  关闭该 session 内所有"不属于本讨论"的 chatgpt.com 标签（清理历史残留，需配合 -Session）。
.PARAMETER NoDedupe
  保留（当前仅影响提示行为）。
.PARAMETER TimeoutSec
  单轮生成超时（秒），默认 360。
.PARAMETER MaxRecover
  单轮内"标签丢失用 convUrl 重开"的最大次数，默认 2。
.PARAMETER Daemon
  webbridge daemon 地址。留空 = 自动探测（daemon.addr → 默认 http://127.0.0.1:10086）。
.PARAMETER ListChats
  只读：列出 ChatGPT 账号里的会话（标题 / 会话 id / 更新时间 / 本地锚定情况）。不提问、不改文档。
.PARAMETER Attach
  把"已存在的会话"挂到当前讨论：给标题关键字（模糊匹配）或直接给 /c/<id>。
  配合 -Session/-DocPath 使用；不带 -Question 时只做绑定不发问。
.PARAMETER Limit
  -ListChats 显示多少条，默认 30。-Attach 按标题匹配时固定扫前 100 条。
.EXITCODES
   0  成功
   3  webbridge daemon 不可用
   5  ChatGPT 页面未就绪（登录墙/验证码/改版）
   6  有锚点却既拿不到标签、也开不出标签
   7  填入问题失败
   8  发送失败
   9  生成超时且无可用回答
  10  拒绝新建：该 session 已有讨论线程（要开新线程请加 -ForceNew）
  11  发送前校验失败：当前页面不是锚定会话
  12  同一 session 已有另一个 ask-gpt 进程在跑（防止双开导致同一对话被并发写）
  13  参数/文档冲突
.EXAMPLE
  pwsh -File ask-gpt.ps1 -Question "请介绍Modbus" -Session modbus-101 -New -Title "Modbus 入门"
.EXAMPLE
  pwsh -File ask-gpt.ps1 -Question "那 CRC 呢？" -Session modbus-101
.EXAMPLE
  pwsh -File ask-gpt.ps1 -Status
#>
param(
  [string]$Question = "",
  [string]$Session = "",
  [string]$DocPath = "",
  [string]$Title = "",
  [string]$GroupTitle = "",
  [string]$ConvUrl = "",
  [switch]$New,
  [switch]$ForceNew,
  [switch]$Status,
  [switch]$CloseExtras,
  [switch]$NoDedupe,
  [int]$TimeoutSec = 360,
  [int]$MaxRecover = 2,
  [string]$Daemon = "",   # 留空 = 自动探测（daemon.addr → 默认 10086）
  [switch]$ListChats,     # 只读：列出 ChatGPT 账号里的会话（标题 / id / 更新时间 / 本地锚定情况）
  [string]$Attach = "",   # 把"已存在的会话"挂到当前讨论：给标题关键字，或直接给 /c/<id>
  [int]$Limit = 30        # -ListChats 显示多少条
)

$ErrorActionPreference = "Stop"
# 原生命令(curl.exe)的 stderr/退出码不要升级成终止异常，否则一次瞬时抖动就会把整轮打死
$PSNativeCommandUseErrorActionPreference = $false
$CHAT_HOME  = "https://chatgpt.com/"
$SKILL_DIR  = Split-Path $PSScriptRoot -Parent
$STATE_DIR  = if ($env:CHATGPT_DISCUSS_STATE) { $env:CHATGPT_DISCUSS_STATE } else { Join-Path $env:LOCALAPPDATA "chatgpt-discuss\state" }

# ============================ 基础设施 ============================

function Ensure-Dir { param([string]$Path) if ($Path -and -not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null } }
function Write-Utf8 { param([string]$Path, [string]$Text) Ensure-Dir (Split-Path $Path -Parent); [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false))) }
function Read-Text { param([string]$Path) if (Test-Path $Path) { return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) } return $null }

$script:LockSession = $null
function Release-Lock {
  if ($script:LockSession) {
    Remove-Item (Join-Path $STATE_DIR "$($script:LockSession).lock") -Force -ErrorAction SilentlyContinue
    $script:LockSession = $null
  }
}
# 唯一的失败出口：stderr 出信息 + 释放锁 + 确定性退出码（stdout 只留给回答正文）
function Fail {
  param([int]$Code, [string]$Message)
  [Console]::Error.WriteLine("ERROR[$Code] $Message")
  Release-Lock
  exit $Code
}

# 会话路径种类：c = 登录会话（有持久身份，可用 URL 找回）；
# uc = 匿名（未登录）会话——**关掉即失效**：URL 只在对话未关时有效，
# 拿它重开只会得到一条新对话，所以匿名会话绝不能走"用 URL 重开"的恢复路径。
$script:ConvKind = 'c'
function Get-ConvKind {
  param([string]$Url)
  if ($Url -and $Url -match 'chatgpt\.com/uc/') { return 'uc' }
  return 'c'
}
function Set-ConvKindFromUrl {
  param([string]$Url)
  if ($Url) { $script:ConvKind = Get-ConvKind $Url }
}
function New-ConvUrl {
  param([string]$Id)
  return "https://chatgpt.com/$($script:ConvKind)/$Id"
}
function Get-ConvId {
  param([string]$Url)
  if (-not $Url) { return $null }
  $m = [regex]::Match($Url, 'chatgpt\.com/(?:c|uc)/([0-9a-zA-Z\-]{8,})')
  if ($m.Success) { return $m.Groups[1].Value }
  $m = [regex]::Match($Url, 'chat\.openai\.com/(?:c|uc)/([0-9a-zA-Z\-]{8,})')
  if ($m.Success) { return $m.Groups[1].Value }
  return $null
}
function Get-CanonicalConvUrl {
  param([string]$Url)
  $id = Get-ConvId $Url
  if (-not $id) { return $null }
  # 规范化锚点的同时同步会话种类（本脚本是单线程流程，锚点种类即全局事实）
  $script:ConvKind = Get-ConvKind $Url
  return "https://chatgpt.com/$($script:ConvKind)/$id"
}

# ============================ 状态（SSOT） ============================

function Get-StatePath { param([string]$S) Join-Path $STATE_DIR "$S.json" }
function Read-DiscussState {
  param([string]$S)
  $p = Get-StatePath $S
  $raw = Read-Text $p
  if (-not $raw) { return $null }
  try { return ($raw | ConvertFrom-Json) } catch { return $null }
}
function Write-DiscussState {
  param([string]$S, $Obj)
  Ensure-Dir $STATE_DIR
  Write-Utf8 (Get-StatePath $S) ($Obj | ConvertTo-Json -Depth 8)
}
function Get-AllStates {
  if (-not (Test-Path $STATE_DIR)) { return @() }
  $out = @()
  foreach ($f in (Get-ChildItem $STATE_DIR -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
    $raw = Read-Text $f.FullName
    if (-not $raw) { continue }
    try { $out += ($raw | ConvertFrom-Json) }
    catch { Write-Warning "state 文件解析失败，已跳过: $($f.Name) — $($_.Exception.Message)" }
  }
  return $out
}

function Acquire-Lock {
  param([string]$S)
  Ensure-Dir $STATE_DIR
  $p = Join-Path $STATE_DIR "$S.lock"
  if (Test-Path $p) {
    $info = $null
    try { $info = (Read-Text $p) | ConvertFrom-Json } catch {}
    $stale = $true
    if ($info -and $info.pid) {
      $alive = $false
      try { $alive = [bool](Get-Process -Id ([int]$info.pid) -ErrorAction Stop) } catch { $alive = $false }
      $ageMin = 999
      try { $ageMin = ((Get-Date) - ([datetime]$info.time)).TotalMinutes } catch {}
      if ($alive -and $ageMin -lt 20) { $stale = $false }
    }
    if (-not $stale) { return $false }
    Write-Warning "发现陈旧锁文件（持有进程已退出），清理后继续"
    Remove-Item $p -Force -ErrorAction SilentlyContinue
  }
  Write-Utf8 $p (@{ pid = $PID; time = (Get-Date).ToString("o"); session = $S } | ConvertTo-Json -Compress)
  $script:LockSession = $S
  return $true
}

# ============================ 文档 ============================

$META_RE = '<!--\s*chatgpt-discuss:\s*([^>]*?)-->'
function Get-DocMarker {
  param([string]$Path)
  $txt = Read-Text $Path
  if (-not $txt) { return $null }
  $m = [regex]::Match($txt, $META_RE)
  if (-not $m.Success) { return $null }
  $out = @{}
  foreach ($kv in ($m.Groups[1].Value -split '\s+')) {
    if ($kv -match '^([^=]+)=(.*)$') { $out[$matches[1]] = $matches[2] }
  }
  return $out
}
function Get-DocRoundCount {
  param([string]$Path)
  if (-not (Test-Path $Path)) { return 0 }
  return (Select-String -Path $Path -Pattern '^## Q\d+' -ErrorAction SilentlyContinue | Measure-Object).Count
}
function Write-DocHeader {
  param([string]$Path, [string]$Title, [string]$S, [string]$Curl)
  $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $h = @()
  $h += "# GPT 讨论：$Title（$(Get-Date -Format yyyy-MM-dd)）"
  $h += ""
  $h += "<!-- chatgpt-discuss: session=$S conv=$Curl created=$now updated=$now rounds=0 -->"
  $h += "- 会话: $S | 链接: $Curl"
  $h += ""
  Write-Utf8 $Path ($h -join "`r`n")
}
function Update-DocMarker {
  param([string]$Path, [string]$S, [string]$Curl, [int]$Rounds)
  $txt = Read-Text $Path
  if (-not $txt) { return }
  $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $newMarker = '<!-- chatgpt-discuss: session=' + $S + ' conv=' + $Curl + ' updated=' + $now + ' rounds=' + $Rounds + ' -->'
  if ([regex]::IsMatch($txt, $META_RE)) {
    $txt = $txt -replace $META_RE, $newMarker
  } else {
    # 老文档没有标记：插在标题之后
    $lines = $txt -split "`r?`n"
    $ins = $newMarker
    $head = @($lines[0], "", $ins)
    $txt = ($head + ($lines | Select-Object -Skip 1)) -join "`r`n"
  }
  # 链接行同步
  $txt = [regex]::Replace($txt, '(?m)^- 会话: .*$', ("- 会话: $S | 链接: $Curl"))
  Write-Utf8 $Path $txt
}

# ============================ webbridge ============================

function Resolve-DaemonAddr {
  # 原版硬编码 10086：用户一旦把 daemon 挪到别的端口，整条链路全废。
  # webbridge 官方约定：真实地址以 daemon.addr / `status` 输出为准，配置文件只用来搬端口。
  $p = Join-Path $env:USERPROFILE ".kimi-webbridge\daemon.addr"
  $raw = Read-Text $p
  if ($raw) {
    $a = $raw.Trim()
    if ($a -match '^[A-Za-z0-9\.\-]+:\d+$') { return "http://$a" }
  }
  return "http://127.0.0.1:10086"
}
function Get-DaemonStatus {
  # 带重试：瞬时抖动不该判死（历史上一次抖动就把整轮打进"手工 curl"的无状态邪路）
  param([string]$Base, [int]$Attempts = 6)
  for ($i = 1; $i -le $Attempts; $i++) {
    $raw = $null
    try { $raw = (& curl.exe -s --noproxy "*" --max-time 6 "$Base/status" 2>$null) } catch {}
    if ($raw) { try { $o = $raw | ConvertFrom-Json; if ($o -and $o.running) { return $o } } catch {} }
    if ($i -lt $Attempts) { Start-Sleep -Milliseconds (300 * $i) }
  }
  return $null
}
function Get-DaemonDiag {
  param([string]$Base)
  $u = [Uri]$Base
  $tcp = "closed"
  try { $c = New-Object System.Net.Sockets.TcpClient; $c.Connect($u.Host, $u.Port); $tcp = "open"; $c.Close() } catch { $tcp = "closed" }
  $raw = ""
  try { $raw = ((& curl.exe -s -S --noproxy "*" --max-time 6 "$Base/status" 2>&1) | Select-Object -First 2) -join " | " } catch {}
  return ("webbridge daemon 不可用（$Base）。TCP $($u.Host):$($u.Port)=$tcp。curl 说: $raw  " +
          "先跑: `"$env:USERPROFILE\.kimi-webbridge\bin\kimi-webbridge.exe`" start")
}

function Invoke-WB {
  param([string]$Action, [hashtable]$WBArgs, [string]$SessionName)
  $body = @{ action = $Action; args = $WBArgs; session = $SessionName } | ConvertTo-Json -Depth 12 -Compress
  $tmp = Join-Path $env:TEMP ("wb-req-" + [guid]::NewGuid().ToString("N") + ".json")
  [System.IO.File]::WriteAllText($tmp, $body, (New-Object System.Text.UTF8Encoding($false)))
  try {
    $raw = & curl.exe -s --noproxy "*" --max-time 120 -X POST "$Daemon/command" -H "Content-Type: application/json" --data-binary "@$tmp" 2>$null
    if ($LASTEXITCODE -ne 0) { throw "curl exit $LASTEXITCODE" }
    if (-not $raw) { throw "empty response for action $Action" }
    $resp = $raw | ConvertFrom-Json
    if (-not $resp.ok) { throw "webbridge error: $($resp.error.message)" }
    return $resp.data
  } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}
function Eval-JS {
  param([string]$Code, [string]$SessionName)
  $d = Invoke-WB "evaluate" @{ code = $Code } $SessionName
  return $d.value
}
function Get-SessionChatGptTabs {
  param([string]$S)
  try {
    $r = Invoke-WB "list_tabs" @{} $S
    if ($r -and $r.tabs) { return @($r.tabs | Where-Object { $_.url -like "*chatgpt.com/*" -or $_.url -like "*chat.openai.com/*" }) }
  } catch {}
  return @()
}
function Activate-EdgeWindow {
  # 浏览器进程名未必是 msedge（Chrome / 其它 Chromium 分支）——逐个试，别硬编码一个
  foreach ($name in @('msedge', 'chrome', 'brave', 'vivaldi')) {
    try {
      $ws = New-Object -ComObject WScript.Shell
      if ($ws.AppActivate($name)) { Start-Sleep -Milliseconds 500; return $true }
    } catch {}
  }
  return $false
}
function Get-ConversationState {
  # 从 ChatGPT 后端接口读权威消息体（而不是抓 DOM）
  # 实测(2026-09-14)：DOM innerText 只拿到第一段（27/163、52/582），丢 80~95% 正文；
  # 接口有干净的完成信号：end_turn=true && content_type='text' && status='finished_successfully'
  param([string]$S, [string]$ConvId)
  $js = @"
(async()=>{
  try{
    if(!window.__ccTok){ try{ const s=await (await fetch('/api/auth/session')).json(); window.__ccTok=s&&s.accessToken; }catch(e){} }
    const h={Authorization:'Bearer '+(window.__ccTok||'')};
    const r=await fetch('/backend-api/conversation/$ConvId',{headers:h,credentials:'include'});
    if(!r.ok) return JSON.stringify({error:'HTTP '+r.status});
    const j=await r.json();
    const all=Object.values(j.mapping||{}).map(n=>n&&n.message).filter(m=>m&&m.author&&m.author.role==='assistant');
    const fin=all.filter(m=>m.end_turn===true && m.content && m.content.content_type==='text' && m.status==='finished_successfully');
    const last=fin[fin.length-1];
    const txt=last?(last.content.parts||[]).join(''):'';
    return JSON.stringify({n:fin.length,len:txt.length,text:txt});
  }catch(e){ return JSON.stringify({error:String(e)}) }
})()
"@
  try {
    $v = Eval-JS $js $S
    if (-not $v) { return $null }
    return ($v | ConvertFrom-Json)
  } catch { return $null }
}

function Get-LastAnswerText {
  param([string]$S)
  try { return Eval-JS '(()=>{const els=document.querySelectorAll("[data-message-author-role=\"assistant\"]");const el=els[els.length-1];return el?el.innerText:""})()' $S }
  catch { return $null }
}
function Resolve-ComposerTarget {
  # 定位对话框并打标记 data-cc-composer，返回命中描述（空串 = 没找到）。
  # 不押单一选择器：composer 在登录/未登录、新旧版之间结构不同
  # （textarea#prompt-textarea ↔ ProseMirror contenteditable），写死一个必然脆。
  # 候选按"最具体 → 最通用"排序；全落空时退到"页面上最后一个可见可编辑元素"。
  param([string]$S)
  $js = @'
(()=>{
  const vis = e => { try { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0 } catch(_) { return false } };
  document.querySelectorAll('[data-cc-composer]').forEach(e => e.removeAttribute('data-cc-composer'));
  const ok = e => e && vis(e) && !e.disabled && !e.readOnly;
  const cands = [
    '#prompt-textarea',
    'div[contenteditable="true"]#prompt-textarea',
    'form .ProseMirror[contenteditable="true"]',
    'form [contenteditable="true"]',
    'main [contenteditable="true"]',
    'form textarea',
    'textarea'
  ];
  let el = null;
  for (const c of cands) {
    try { const e = document.querySelector(c); if (ok(e)) { el = e; break } } catch(_) {}
  }
  if (!el) {
    const all = [...document.querySelectorAll('[contenteditable="true"],textarea')].filter(ok);
    el = all.length ? all[all.length - 1] : null;
  }
  if (!el) return '';
  el.setAttribute('data-cc-composer', '1');
  return el.tagName.toLowerCase() + (el.getAttribute('contenteditable') === 'true' ? '/ce' : '/val');
})()
'@
  try { $v = Eval-JS $js $S; if ($v) { return [string]$v } } catch {}
  return ''
}
function Resolve-SendTarget {
  # 定位发送按钮并打标记 data-cc-send，返回命中描述（空串 = 没找到）。
  # **必须在填完内容之后调用**：输入框为空时 ChatGPT 把发送键换成语音按钮，
  # 那一刻"最后一个按钮"并不是发送键。
  param([string]$S)
  $js = @'
(()=>{
  const vis = e => { try { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0 } catch(_) { return false } };
  document.querySelectorAll('[data-cc-send]').forEach(e => e.removeAttribute('data-cc-send'));
  const cands = [
    'button[data-testid="send-button"]',
    'button[aria-label*="Send"]',
    'button[aria-label*="发送"]',
    'form button[type="submit"]'
  ];
  let el = null;
  for (const c of cands) {
    try { const e = document.querySelector(c); if (e && vis(e) && !e.disabled) { el = e; break } } catch(_) {}
  }
  if (!el) {
    const comp = document.querySelector('[data-cc-composer]') || document.querySelector('#prompt-textarea');
    const scope = comp ? (comp.closest('form') || comp.parentElement) : null;
    if (scope) {
      const skip = /voice|dictat|microphone|attach|upload|tool|语音|话筒|附件|上传|工具/i;
      const btns = [...scope.querySelectorAll('button')].filter(b =>
        vis(b) && !b.disabled && !skip.test(b.getAttribute('aria-label') || ''));
      el = btns.length ? btns[btns.length - 1] : null;
    }
  }
  if (!el) return '';
  el.setAttribute('data-cc-send', '1');
  return (el.getAttribute('aria-label') || el.getAttribute('data-testid') || el.tagName.toLowerCase());
})()
'@
  try { $v = Eval-JS $js $S; if ($v) { return [string]$v } } catch {}
  return ''
}
function Wait-Composer {
  param([string]$S, [int]$Seconds = 45)
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    if (Resolve-ComposerTarget $S) { return $true }
    Start-Sleep -Milliseconds 1500
  }
  return $false
}
function Wait-ConvUrl {
  param([string]$S, [int]$Seconds = 30)
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    try {
      $href = Eval-JS "location.href" $S
      $c = Get-CanonicalConvUrl $href
      if ($c) { return $c }
    } catch {}
    Start-Sleep -Milliseconds 1200
  }
  return $null
}
# 用 convUrl 找回/重开标签：**切换后必须校验 location.href**（原来不校验，
# list_tabs 一次性抖动就会误判"标签丢了"→ 重开 → 同一 session 堆标签 → 歧义）
function Resolve-ConvTab {
  param([string]$S, [string]$ConvId, [int]$MaxRecover, [string]$Group)
  for ($round = 0; $round -le $MaxRecover; $round++) {
    foreach ($t in (Get-SessionChatGptTabs $S)) {
      if ((Get-ConvId $t.url) -ne $ConvId) { continue }
      try { Invoke-WB "find_tab" @{ url = $t.url } $S | Out-Null } catch { continue }
      try { $href = Eval-JS "location.href" $S; if ((Get-ConvId $href) -eq $ConvId) { return $t } } catch {}
    }
    if ($round -lt $MaxRecover) {
      if ($script:ConvKind -eq 'uc') {
        # 匿名会话的 URL 不是身份：拿它重开只会得到一条新对话，
        # 那正是本 skill 最忌讳的"把同一条讨论撕成两条"。到此为止，由调用方报错。
        Write-Warning "匿名会话的标签已不在，且匿名会话无法用 URL 找回（关掉即新对话）"
        return $null
      }
      Write-Warning "没有可用的锚定标签，用 convUrl 重开（$($round + 1)/$MaxRecover）"
      # 不传 newTab：让 webbridge 复用当前标签（没有才新建），避免标签堆积
      try { Invoke-WB "navigate" @{ url = (New-ConvUrl $ConvId); group_title = $Group } $S | Out-Null } catch {}
      $dl = (Get-Date).AddSeconds(30)
      while ((Get-Date) -lt $dl) {
        Start-Sleep -Milliseconds 1200
        try { $h = Eval-JS "location.href" $S; if ((Get-ConvId $h) -eq $ConvId) { return @{ url = (New-ConvUrl $ConvId); tabId = $null } } } catch {}
      }
    }
  }
  return $null
}
# 清掉本讨论标签组里"不属于本会话"的游离 chatgpt 标签（多标签=歧义来源）
function Close-StrayTabs {
  param([string]$S, [string]$KeepConvId, [int]$Max = 5)
  $n = 0
  foreach ($t in (Get-SessionChatGptTabs $S)) {
    if ($n -ge $Max) { break }
    if ($KeepConvId -and (Get-ConvId $t.url) -eq $KeepConvId) { continue }
    try {
      Invoke-WB "find_tab" @{ url = $t.url } $S | Out-Null
      Invoke-WB "close_tab" @{} $S | Out-Null
      $n++
      Write-Warning ("  清理游离标签: " + $t.url)
    } catch {}
  }
  if ($n -gt 0) { Write-Warning "已清理 $n 个游离标签（本讨论组内非本会话的 chatgpt 标签）" }
  return $n
}

# ============================ 服务器端会话列表（-ListChats / -Attach 共用） ============================

function Get-ChatListJs {
  # 在 ChatGPT 页面里用它的后端接口取会话列表（走页面自身的登录态 + accessToken）
  param([int]$Limit = 30)
  @"
(async()=>{
  try{
    let tk=null;
    try{ const s=await (await fetch('/api/auth/session',{credentials:'include'})).json(); tk=s&&s.accessToken; }catch(e){}
    const h = tk ? {Authorization:'Bearer '+tk} : {};
    let out=[], off=0, total=null;
    while(out.length < $Limit){
      const r = await fetch('/backend-api/conversations?offset='+off+'&limit=28&order=updated',{headers:h,credentials:'include'});
      if(!r.ok) return JSON.stringify({error:'HTTP '+r.status});
      const j = await r.json();
      if(total===null) total=(typeof j.total==='number')?j.total:null;
      const items=j.items||[];
      if(!items.length) break;
      for(const i of items) out.push({id:i.id, title:i.title, upd:i.update_time});
      off += items.length;
      if(out.length >= $Limit) break;
      if(total!==null && off>=total) break;
    }
    return JSON.stringify({total:total, count:out.length, items:out.slice(0,$Limit)});
  }catch(e){ return JSON.stringify({error:String(e)}); }
})()
"@
}

$script:ScanSession = "cc-browse"
function Get-ScanTab {
  # 复用/打开一个"会话浏览"标签（固定 session，不干扰各讨论自己的标签组）
  param([string]$S)
  foreach ($t in (Get-SessionChatGptTabs $S)) {
    try { $ft = Invoke-WB "find_tab" @{ url = $t.url } $S; if ($ft.success) { if (Wait-Composer $S 30) { return $true } } } catch {}
  }
  Write-Warning "打开会话浏览标签（组: GPT讨论：会话浏览）"
  try { Invoke-WB "navigate" @{ url = $CHAT_HOME; newTab = $true; group_title = "GPT讨论：会话浏览" } $S | Out-Null } catch { return $false }
  return (Wait-Composer $S 45)
}
function Get-ServerChats {
  param([string]$S, [int]$Limit = 30)
  $raw = Eval-JS (Get-ChatListJs -Limit $Limit) $S
  if (-not $raw) { return $null }
  try { return ($raw | ConvertFrom-Json) } catch { return $null }
}
function Get-LocalAnchorMap {
  $map = @{}
  foreach ($st in (Get-AllStates)) {
    if ($st.convUrl -and $st.session) { $cid = Get-ConvId $st.convUrl; if ($cid) { $map[$cid] = $st.session } }
  }
  return $map
}
function Format-ChatsTable {
  param($Items, $Map)
  Write-Output ("{0,-34} {1,-20} {2}" -f "标题", "更新时间", "会话 id")
  foreach ($c in $Items) {
    $mark = if ($Map -and $Map.ContainsKey($c.id)) { "  ← 已锚定: " + $Map[$c.id] } else { "" }
    $t = if ($c.title) { $c.title } else { "(无标题)" }
    if ($t.Length -gt 32) { $t = $t.Substring(0, 31) + "…" }
    Write-Output ("{0,-34} {1,-20} {2}{3}" -f $t, $c.upd, $c.id, $mark)
  }
}
function Connect-ChatList {
  param([string]$Base, [string]$Reason)
  if (-not $Base) { $Base = Resolve-DaemonAddr }
  # 必须写回脚本作用域：Invoke-WB 用的是 $Daemon，函数里赋值只改局部变量（踩过这个坑）
  $script:Daemon = $Base
  $ds = Get-DaemonStatus -Base $Base -Attempts 6
  if (-not $ds) { Fail 3 (Get-DaemonDiag -Base $Base) }
  Activate-EdgeWindow | Out-Null
  if (-not (Get-ScanTab $script:ScanSession)) { Fail 5 "$Reason 需要 ChatGPT 页面，但会话浏览标签未就绪（登录墙/验证码/改版？）" }
  return $Base
}

# ============================ -ListChats（只读，列服务端会话） ============================

if ($ListChats) {
  Connect-ChatList -Base $Daemon -Reason "-ListChats" | Out-Null
  $chats = Get-ServerChats -S $script:ScanSession -Limit $Limit
  if (-not $chats) { Fail 9 "取会话列表失败（返回为空）" }
  if ($chats.error) { Fail 5 ("取会话列表失败: " + $chats.error) }
  $tot = if ($null -ne $chats.total) { $chats.total } else { "?" }
  Write-Output ("ChatGPT 账号内共 $tot 条会话，按更新时间倒序显示前 $($chats.count) 条：")
  Write-Output ""
  Format-ChatsTable -Items $chats.items -Map (Get-LocalAnchorMap)
  Write-Output ""
  Write-Output "想接管其中某条：ask-gpt.ps1 -Attach <标题关键字 或 会话id> -Session <你的讨论slug>"
  exit 0
}

# ============================ -Attach（把已有会话挂到当前讨论） ============================

if ($Attach) {
  Connect-ChatList -Base $Daemon -Reason "-Attach" | Out-Null
  $aid = Get-ConvId $Attach
  if (-not $aid -and $Attach -match '^[0-9a-zA-Z][0-9a-zA-Z\-]{15,}$') { $aid = $Attach }   # 允许直接给裸 id
  if ($aid) {
    Write-Warning "Attach: 直接使用给出的会话 id $aid"
  } else {
    $chats = Get-ServerChats -S $script:ScanSession -Limit 100
    if (-not $chats -or $chats.error) { Fail 9 "取会话列表失败，无法按标题匹配" }
    $hits = @($chats.items | Where-Object { $_.title -and $_.title -like "*$Attach*" })
    if ($hits.Count -eq 0) { Fail 13 "没有标题包含 '$Attach' 的会话。先跑 -ListChats 看列表，或直接用 /c/<id>" }
    if ($hits.Count -gt 1) {
      Write-Output "标题 '$Attach' 匹配到 $($hits.Count) 条，请给更精确的关键字或直接给 /c/<id>："
      Write-Output ""
      Format-ChatsTable -Items $hits -Map (Get-LocalAnchorMap)
      Fail 13 "Attach 目标不唯一"
    }
    $aid = $hits[0].id
    Write-Warning "Attach: '$Attach' → $($hits[0].title)  [$aid]"
  }
  # 直接给 URL 时保留其路径种类（/uc/ 匿名会话不能被改写成 /c/）；
  # 裸 id 与标题匹配只可能来自登录会话（匿名会话不在账号列表里），故默认 /c/。
  $ConvUrl = if ($Attach -match 'chatgpt\.com/(?:c|uc)/') { (Get-CanonicalConvUrl $Attach) } else { "https://chatgpt.com/c/$aid" }   # 交给下面的锚点解析（优先级最高）
}

# ============================ -Status（只读） ============================

if ($Status) {
  $all = Get-AllStates | Where-Object { $_ -and $_.session }
  if (-not $all) {
    Write-Output "（还没有任何已记录的讨论）"
    Write-Output "state 目录: $STATE_DIR"
    exit 0
  }
  Write-Output ("state 目录: " + $STATE_DIR)
  Write-Output ""
  Write-Output ("{0,-22} {1,6}  {2,-19}  {3}" -f "session", "rounds", "updatedAt", "conv / doc")
  foreach ($s in ($all | Sort-Object updatedAt -Descending)) {
    Write-Output ("{0,-22} {1,6}  {2,-19}  {3}" -f $s.session, $s.rounds, $s.updatedAt, $s.convUrl)
    if ($s.docPath) { Write-Output ("{0,-22} {1,6}  {2,-19}  {3}" -f "", "", "", $s.docPath) }
  }
  exit 0
}

# ============================ 0. 解析 session / 文档 / 锚点 ============================

if (-not $Question -and -not $CloseExtras -and -not $Attach) { Fail 13 "-Question 必填（或改用 -Status / -ListChats / -Attach / -CloseExtras）" }

function Get-SlugFromDoc {
  param([string]$P)
  $n = [IO.Path]::GetFileNameWithoutExtension($P)
  $n = $n -replace '^\d{4}-\d{2}-\d{2}[-_]', ''
  $n = $n.Trim('-', '_')
  if (-not $n) { $n = "chatgpt-discuss" }
  return $n
}
function New-SessionSlugFromCwd {
  $raw = Split-Path (Get-Location) -Leaf
  $slug = ($raw.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
  if (-not $slug) { $slug = "chatgpt-discuss" }
  return $slug
}

# 未指定 session：先按文档推导，再按"当前工作区最近用过的讨论"复用
if (-not $Session) {
  if ($DocPath) { $Session = Get-SlugFromDoc $DocPath }
  else {
    $cwd = (Get-Location).Path
    $cands = @(Get-AllStates | Where-Object { $_.session -and $_.docPath -and $_.docPath.StartsWith($cwd, [StringComparison]::OrdinalIgnoreCase) } | Sort-Object updatedAt -Descending)
    if ($cands.Count -gt 0 -and -not ($New -or $ForceNew)) {
      $Session = $cands[0].session
      if ($cands.Count -gt 1) {
        Write-Warning "当前工作区有 $($cands.Count) 个讨论，已复用最近使用的 '$Session'；如需指定请显式传 -Session"
        foreach ($c in ($cands | Select-Object -Skip 1)) { Write-Warning "  候选: $($c.session)  $($c.convUrl)" }
      } else {
        Write-Warning "未指定 -Session，复用当前工作区最近使用的讨论 '$Session'"
      }
    } else {
      $Session = New-SessionSlugFromCwd
      Write-Warning "未指定 -Session，按工作区新建讨论 '$Session'"
    }
  }
}
if ($Session -notmatch '^[A-Za-z0-9._-]+$') { Fail 13 "-Session 只允许字母/数字/._-（当前: $Session）" }

$state = Read-DiscussState $Session

# 文档路径：显式 > state 记录（跨天不拆文件）> 目录内同名文档 > 新建
if (-not $DocPath) {
  if ($state -and $state.docPath) { $DocPath = $state.docPath }
  else {
    $qaDir = Join-Path (Get-Location) "docs/gpt_qa"
    if (Test-Path $qaDir) {
      $pat = "(^|[-_])" + [regex]::Escape($Session) + "$"
      $ex = Get-ChildItem $qaDir -Filter "*.md" -File -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -match $pat } | Select-Object -First 1
      if ($ex) { $DocPath = $ex.FullName }
    }
    if (-not $DocPath) { $DocPath = Join-Path (Get-Location) ("docs/gpt_qa/{0}-{1}.md" -f (Get-Date -Format "yyyy-MM-dd"), $Session) }
  }
}
$DocPath = [IO.Path]::GetFullPath($DocPath)

# 锚点解析优先级: -ConvUrl > 文档标记 > state
$anchor = $null; $anchorSrc = $null
if ($ConvUrl) {
  $anchor = Get-CanonicalConvUrl $ConvUrl
  if (-not $anchor) { Fail 13 "-ConvUrl 不是合法的 chatgpt.com/c/<id> 链接: $ConvUrl" }
  $anchorSrc = "参数"
}
if (-not $anchor) {
  $mk = Get-DocMarker $DocPath
  if ($mk -and $mk['conv'] -and $mk['conv'] -ne 'none') {
    $anchor = Get-CanonicalConvUrl $mk['conv']; if ($anchor) { $anchorSrc = "文档" }
  }
}
if (-not $anchor -and $state -and $state.convUrl) {
  $anchor = Get-CanonicalConvUrl $state.convUrl; if ($anchor) { $anchorSrc = "state" }
}
# 旧格式文档（v1 产物：没有 chatgpt-discuss 标记，但正文里留了链接）→ 认领它，救回老讨论
if (-not $anchor) {
  $txt = Read-Text $DocPath
  if ($txt) {
    $head = if ($txt.Length -gt 2000) { $txt.Substring(0, 2000) } else { $txt }
    $m = [regex]::Match($head, 'chatgpt\.com/(c|uc)/([0-9a-zA-Z\-]{8,})')
    if ($m.Success) {
      $anchor = "https://chatgpt.com/$($m.Groups[1].Value)/$($m.Groups[2].Value)"
      $anchorSrc = "文档(旧格式链接)"
      Write-Warning "该文档无 chatgpt-discuss 标记（v1 产物），已从正文认领会话链接作锚点: $anchor"
    }
  }
}
# 冲突自愈：文档与 state 不一致时以文档为准并告警
if ($anchor -and $state -and $state.convUrl) {
  $sc = Get-CanonicalConvUrl $state.convUrl
  if ($sc -and $sc -ne $anchor) {
    Write-Warning "文档标记($anchor) 与 state($sc) 不一致，以 $anchorSrc 为准，已自愈 state"
  }
}

if ($anchor -and ($New -and -not $ForceNew)) {
  Fail 10 @"
讨论 '$Session' 已经有一条会话线程，拒绝新建。
  现有会话: $anchor
  要接着聊（推荐）: 去掉 -New 重跑同样的命令
  确实要开新线程  : 加 -ForceNew（旧链接会归档进 state 的 convHistory）
  想看看都有哪些   : pwsh -File ask-gpt.ps1 -Status
"@
}

# 无锚点时，先认领本讨论组里已有的 chatgpt 标签：匿名会话**离开即失效**，
# 导航到根路径等于把上一轮丢掉。显式 -New / -ForceNew 才表示"确实要开新对话"。
$script:ReuseTab = $null
if (-not $anchor -and -not $New -and -not $ForceNew) {
  foreach ($t in (Get-SessionChatGptTabs $Session)) {
    if (Get-ConvId $t.url) {
      $anchor = Get-CanonicalConvUrl $t.url
      $anchorSrc = "已有标签(未导航)"
      Write-Warning "本讨论组已有会话标签，认作锚点（不导航，保持对话）: $anchor"
    } else {
      $anchorSrc = "已有标签(新对话页)"
      Write-Warning "本讨论组已有 chatgpt 标签但尚未产生会话，原地复用不导航: $($t.url)"
    }
    $script:ReuseTab = $t.url
    break
  }
}

$creating = (-not $anchor) -or $ForceNew
# 标题/分组名一旦建立就"粘住"：每轮换个 -Title 就会在浏览器里多出一个分组
# （你截图里同话题出现两个分组「…X轴与降采样」「…X轴降采样」就是这么来的）
if ($state) {
  if (-not $GroupTitle -and $state.groupTitle) { $GroupTitle = $state.groupTitle }
  if (-not $Title -and $state.title) { $Title = $state.title }
}
if (-not $Title) { $Title = if ($GroupTitle) { $GroupTitle -replace '^GPT讨论[：:]\s*', '' } else { $Session } }
if (-not $GroupTitle) { $GroupTitle = "GPT讨论：$Title" }
if ($Title.Length -gt 60) { $Title = $Title.Substring(0, 60) }

# 残余风险闸门：要新建时，先看看本工作区是不是已经有别的讨论（防止 AI 换个 slug 就偷偷开了新对话）
if ($creating) {
  $qaDir = Split-Path $DocPath -Parent
  $others = @()
  if (Test-Path $qaDir) {
    foreach ($f in (Get-ChildItem $qaDir -Filter "*.md" -File -ErrorAction SilentlyContinue)) {
      if ($f.FullName -eq $DocPath) { continue }
      $mk = Get-DocMarker $f.FullName
      if ($mk -and $mk['conv'] -and $mk['conv'] -ne 'none') {
        $others += [pscustomobject]@{ session = $mk['session']; conv = $mk['conv']; file = $f.Name }
      }
    }
  }
  if ($others.Count -gt 0) {
    Write-Warning "注意：本工作区已有 $($others.Count) 个讨论，你现在要新建第 $($others.Count + 1) 个。"
    foreach ($o in ($others | Select-Object -First 5)) { Write-Warning ("  已有: session=$($o.session)  $($o.conv)  ($($o.file))") }
    Write-Warning "如果这其实是同一个话题，请立刻改用 -Session <上面某个> 或 -ConvUrl <链接>；只有确实是新话题才继续。"
  }
}

# -Attach 且没给问题 = 纯绑定：写 state + 文档标记，不发问
if ($Attach -and -not $Question) {
  if (-not $anchor) { Fail 13 "-Attach 已解析但没拿到有效锚点" }
  $hist = @(); if ($state -and $state.convHistory) { $hist = @($state.convHistory) }
  # 改指到别的对话时，旧锚点归档（别静默丢）
  if ($state -and $state.convUrl) {
    $oc = Get-CanonicalConvUrl $state.convUrl
    if ($oc -and $oc -ne $anchor -and $hist -notcontains $oc) { $hist += $oc; Write-Warning "旧锚点已归档进 convHistory: $oc" }
  }
  $rd = Get-DocRoundCount $DocPath
  Write-DiscussState $Session (@{
    session = $Session; convUrl = $anchor; convHistory = $hist; docPath = $DocPath
    title = $Title; groupTitle = $GroupTitle; rounds = $rd
    createdAt = $(if ($state -and $state.createdAt) { $state.createdAt } else { (Get-Date).ToString("s") })
    updatedAt = (Get-Date).ToString("s")
  })
  if (-not (Test-Path $DocPath)) { Write-DocHeader -Path $DocPath -Title $Title -S $Session -Curl $anchor }
  Update-DocMarker -Path $DocPath -S $Session -Curl $anchor -Rounds $rd
  Write-Warning "已绑定（本轮未发问）: session=$Session → $anchor"
  Write-Warning "文档: $DocPath （已有 $rd 轮）"
  $anchor
  exit 0
}

Write-Warning "session=$Session | 文档=$DocPath"
Write-Warning "分组=$GroupTitle | 标题=$Title"
Write-Warning ("模式=" + $(if ($creating) { "新建会话线程" } else { "续聊（锚点来自$anchorSrc）" }) + $(if ($anchor) { " | $anchor" } else { "" }))

# ============================ 1. 加锁 + 健康检查 ============================

if (-not (Acquire-Lock $Session)) {
  Fail 12 "session '$Session' 已有另一个 ask-gpt 进程在运行（锁文件未过期）。等它跑完再试——不要并发/不要用 -New 绕开。"
}

if (-not $Daemon) {
  $Daemon = Resolve-DaemonAddr
  Write-Warning "未指定 -Daemon，自动探测到: $Daemon"
}
$daemonStatus = Get-DaemonStatus -Base $Daemon -Attempts 6
if (-not $daemonStatus) {
  $bin = Join-Path $env:USERPROFILE ".kimi-webbridge\bin\kimi-webbridge.exe"
  if (Test-Path $bin) {
    Write-Warning "daemon 连续 6 次探测不通，尝试启动..."
    try { & $bin start 2>&1 | Out-Null } catch {}
    Start-Sleep -Seconds 4
    $daemonStatus = Get-DaemonStatus -Base $Daemon -Attempts 6
  }
  if (-not $daemonStatus) { Fail 3 (Get-DaemonDiag -Base $Daemon) }
}
if (-not $daemonStatus.extension_connected) { Write-Warning "扩展未连接，仍尝试执行" }

Activate-EdgeWindow | Out-Null

# ============================ 2. 找到 / 建立会话页 ============================

$convId = $null
if ($creating) {
  if ($ForceNew -and $state -and $state.convUrl) {
    Write-Warning "ForceNew: 旧会话 $($state.convUrl) 归档进 convHistory"
  }
  Write-Warning "打开 chatgpt.com 新建对话（标签组: $GroupTitle）"
  # 本 session 已有标签就复用（不传 newTab），避免同一讨论组里堆出多个标签
  $existing = Get-SessionChatGptTabs $Session
  if ($script:ReuseTab) {
    # 已有 chatgpt 标签（还没产生会话）：**原地复用，不导航**——匿名会话离开即变新对话
    Write-Warning "复用已有标签（不导航）: $($script:ReuseTab)"
    try { Invoke-WB "find_tab" @{ url = $script:ReuseTab } $Session | Out-Null } catch {}
  } else {
    $navArgs = @{ url = $CHAT_HOME }
    if ($existing.Count -eq 0) { $navArgs.newTab = $true; $navArgs.group_title = $GroupTitle }
    else { Write-Warning "（复用本讨论已有标签，未新开）" }
    try { Invoke-WB "navigate" $navArgs $Session | Out-Null } catch { Fail 6 "navigate 失败: $($_.Exception.Message)" }
  }
  if (-not (Wait-Composer $Session 45)) { Fail 5 "ChatGPT 页面未就绪（45s 内没看到输入框）——可能是登录墙/验证码/改版" }
  # 只有在"落在某条已有会话上"时才点新对话；根路径本身就是新对话，点了反而多余
  try {
    $path = Eval-JS "location.pathname" $Session
    if ("$path" -like "/c/*") {
      Eval-JS '(()=>{const t=["新对话","New chat"];const els=[...document.querySelectorAll("a,button")];const el=els.find(e=>t.includes((e.getAttribute("aria-label")||"").trim())||t.includes((e.textContent||"").trim()));if(el){el.click();return true}return false})()' $Session | Out-Null
      Start-Sleep -Seconds 2
      # 兜底：点不中（界面语言不是中/英）就直接跳根路径，否则"新讨论"的第一问会被写进旧对话
      $path2 = $null
      try { $path2 = Eval-JS "location.pathname" $Session } catch {}
      if ("$path2" -like "/c/*") {
        Write-Warning "未能点到「新对话」按钮（界面语言？），改为直接跳根路径"
        try { Invoke-WB "navigate" @{ url = $CHAT_HOME; group_title = $GroupTitle } $Session | Out-Null } catch {}
        Start-Sleep -Seconds 3
      }
    }
  } catch {}
} else {
  $convId = Get-ConvId $anchor
  # ① 优先"接管你已经开着的那个标签"——不新开、不导航、绝不碰别的页面。
  #    实测：find_tab(active:true) 自带 URL 匹配，只有你当前看的标签就是目标会话时才借，
  #    否则干净失败（ok=false: no foreground tab matching ...），什么都不碰 → 这个优先路径是安全的。
  $tab = $null
  $borrowedThisRound = $false
  try {
    $bt = Invoke-WB "find_tab" @{ url = (New-ConvUrl $convId); active = $true } $Session
    if ($bt.ok -and $bt.data.success) {
      Start-Sleep -Milliseconds 400
      $href = Eval-JS "location.href" $Session
      if ((Get-ConvId $href) -eq $convId) {
        Write-Warning "接管了你已打开的标签（未新开）: $href"
        $tab = @{ url = $href; tabId = $bt.data.tabId; borrowed = $true }
        $borrowedThisRound = $true
      } else {
        Write-Warning "借到的标签是 '$href'，不是本讨论——放弃借用"
      }
    }
  } catch {}
  # ② 退回：本 session 自己的标签 → 用 convUrl 重开
  if (-not $tab) { $tab = Resolve-ConvTab -S $Session -ConvId $convId -MaxRecover $MaxRecover -Group $GroupTitle }
  if (-not $tab) { Fail 6 "有锚点 $anchor，但既找不到标签也开不出标签。不要用 -New！可先跑 -Status 看记录，或确认 Edge 里能打开该链接" }
  # 清理游离标签（消除"多个 chatgpt 标签 → 可能发错对话"的歧义）。
  # 本轮若是借用来的标签就跳过清理——那可能是你正在看的页面，绝不能去关。
  if (-not $NoDedupe -and -not $borrowedThisRound) {
    $closed = Close-StrayTabs -S $Session -KeepConvId $convId
    if ($closed -gt 0) {
      $tab = Resolve-ConvTab -S $Session -ConvId $convId -MaxRecover 1 -Group $GroupTitle
      if (-not $tab) { Fail 6 "清理游离标签后无法回到锚定会话（不要用 -New）" }
    }
  }
  if (-not (Wait-Composer $Session 45)) { Fail 5 "ChatGPT 页面未就绪（45s 内没看到输入框）" }
}

if ($CloseExtras) {
  if (-not $convId) { $convId = Get-ConvId $anchor }
  Write-Warning "CloseExtras: 关闭该 session 内不属于本讨论的 chatgpt 标签"
  $closed = 0
  foreach ($t in (Get-SessionChatGptTabs $Session)) {
    if ($closed -ge 20) { break }
    if ((Get-ConvId $t.url) -eq $convId) { continue }
    try { Invoke-WB "find_tab" @{ url = $t.url } $Session | Out-Null; Invoke-WB "close_tab" @{} $Session | Out-Null; $closed++ } catch {}
  }
  Write-Warning "CloseExtras: 关闭 $closed 个"
}

# ============================ 3. 发送前硬校验 ============================

if ($convId) {
  $deadline = (Get-Date).AddSeconds(30)
  $ok = $false; $href = ""
  while ((Get-Date) -lt $deadline) {
    try { $href = Eval-JS "location.href" $Session } catch {}
    if ($href -and (Get-ConvId $href) -eq $convId) { $ok = $true; break }
    Start-Sleep -Milliseconds 1200
  }
  if (-not $ok) {
    Fail 11 "发送前校验失败：当前页面 '$href' 不是锚定会话 $anchor。已中止，避免把问题发进别的对话。请检查该标签是否被手动导航走了（不要用 -New 绕开）"
  }
}

# ============================ 4. 填入 + 发送 ============================

# 发送前记下"当前最后一条回答"：仅用于接口失效时退回 DOM 的兜底比对
$a0text = ''
try { $t0 = Get-LastAnswerText $Session; if ($t0) { $a0text = [string]$t0 } } catch {}

$compSel = '[data-cc-composer="1"]'
$fill = $null
if (Resolve-ComposerTarget $Session) {
  try { $fill = Invoke-WB "fill" @{ selector = $compSel; value = $Question } $Session } catch {}
}
if (-not $fill -or -not $fill.success) {
  # 首填失败：重新探测一次（标记可能被重渲染冲掉），聚焦后再填
  if (Resolve-ComposerTarget $Session) {
    try { Invoke-WB "click" @{ selector = $compSel } $Session | Out-Null } catch {}
    Start-Sleep -Milliseconds 800
    try { $fill = Invoke-WB "fill" @{ selector = $compSel; value = $Question } $Session } catch {}
  }
}
if (-not $fill -or -not $fill.success) { Fail 7 "填入问题失败（对话框定位不到，可能是页面改版）" }

$sendSel = '[data-cc-send="1"]'
$sent = $false
if (Resolve-SendTarget $Session) {
  try { $clk = Invoke-WB "click" @{ selector = $sendSel } $Session; $sent = [bool]$clk.success } catch {}
}
if (-not $sent) {
  # 重探一次：填字后按钮可能刚从"语音"换成"发送"，重渲染会冲掉上一次标记
  if (Resolve-SendTarget $Session) {
    try { $v = Eval-JS '(()=>{const b=document.querySelector("[data-cc-send=\"1\"]");if(b){b.click();return true}return false})()' $Session; $sent = ($v -eq $true -or "$v" -eq "true") } catch {}
  }
}
if (-not $sent) { Fail 8 "点发送按钮失败（按钮定位不到，可能是页面改版）" }

Activate-EdgeWindow | Out-Null

# 发送后立刻把真实会话 URL 钉下来（新建模式靠这一步才拿到锚点）
if (-not $convId) {
  $captured = Wait-ConvUrl $Session 30
  if ($captured) { $convId = Get-ConvId $captured; $anchor = $captured; Write-Warning "已捕获会话链接: $captured" }
  else { Write-Warning "30s 内没捕获到 /c/<id> 链接，本轮照常记录；下一轮会自动从 session 标签里认领该对话" }
}

# ============================ 5. 等待生成完成 ============================
#
# 实测（2026-09-14）—— 这一节原本的做法是错的：
#   ① 旧版要求"短回答等 send-button 回来"，但输入框为空时 ChatGPT 把发送键换成语音按钮
#      → 条件永不成立 → 每轮白烧 3 次 reload-refetch（~40s + 冷加载）
#   ② "文本连续不变"也不可靠：占位块 ~2s 就连续同长，真答案随后替换（长度还会变小）
#   ③ 最致命：DOM innerText 只拿到第一段（27/163、52/582），丢 80~95% 正文
# 现在改为**直接读后端接口**：以 end_turn=true 且 content_type='text' 的最后一条为准。
# 只有跳转 URL 还依赖 DOM（读 location.href 是可靠的）。

$answer = $null
$baseN = 0
if ($convId) {
  $st0 = Get-ConversationState -S $Session -ConvId $convId
  if ($st0 -and -not $st0.error) { $baseN = [int]$st0.n }
}
$recoverCount = 0; $lastRecover = (Get-Date).AddMinutes(-10)
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$iter = 0; $apiErr = 0; $stallWarned = $false
$tStart = Get-Date

while ((Get-Date) -lt $deadline) {
  $iter++
  $ms = if ($iter -le 40) { 1200 } else { 2500 }
  Start-Sleep -Milliseconds $ms

  # 新建轮：先用 location.href 把会话 id 钉下来（URL 读取可靠，不受渲染影响）
  if (-not $convId) {
    $c = $null
    try { $c = Get-CanonicalConvUrl (Eval-JS "location.href" $Session) } catch {}
    if ($c) { $convId = Get-ConvId $c; $anchor = $c; $baseN = 0; Write-Warning "已捕获会话链接: $c" }
    elseif (-not $stallWarned -and $iter -ge 45) { $stallWarned = $true; Write-Warning "45s 还没跳转到 /c/<id>，继续等" }
    continue
  }

  $st = Get-ConversationState -S $Session -ConvId $convId
  if (-not $st -or $st.error) {
    $apiErr++
    if ($apiErr -le 2) { Write-Warning ("读取会话失败: " + $(if ($st) { $st.error } else { "无响应" })) }
    # 读不到（标签丢了 / 页面在导航）→ 限量恢复，绝不在循环里反复开标签
    if ($script:ConvKind -eq 'uc') {
      # 匿名会话的 URL 不是身份：重开只会得到一条新对话，所以只报告、不恢复
      if ($apiErr -le 3) { Write-Warning "读取会话失败；匿名会话无法用 URL 找回（关掉即新对话），不重开标签" }
    } elseif ($recoverCount -lt $MaxRecover -and ((Get-Date) - $lastRecover).TotalSeconds -gt 20) {
      $recoverCount++; $lastRecover = Get-Date
      Write-Warning "标签读不到，用 convUrl 重开（$recoverCount/$MaxRecover）"
      try { Invoke-WB "navigate" @{ url = (New-ConvUrl $convId); group_title = $GroupTitle } $Session | Out-Null } catch {}
      Start-Sleep -Seconds 2
    }
    continue
  }

  if ([int]$st.n -gt $baseN -and "$($st.text)".Length -gt 0) { $answer = [string]$st.text; break }
  if (-not $stallWarned -and $iter -ge 60) {
    $stallWarned = $true
    Write-Warning "60s 仍未出现新的完成消息（生成很慢？）——继续等，不刷新"
  }
}
$elapsedWait = [int]((Get-Date) - $tStart).TotalSeconds

if (-not $answer) {
  # 正常路径永不刷新；超时也只再问一次接口
  Write-Warning "生成超时（已等 ${elapsedWait}s），最后再读一次接口"
  if ($convId) {
    $st = Get-ConversationState -S $Session -ConvId $convId
    if ($st -and -not $st.error -and [int]$st.n -gt $baseN -and "$($st.text)".Length -gt 0) { $answer = [string]$st.text }
  }
}
if (-not $answer) {
  if ($creating) {
    # 新建轮即使没拿到回答，也要把锚点固化，避免下一轮又开新对话
      $captured = if ($convId) { (New-ConvUrl $convId) } else { $null }
      if ($captured) {
        Write-Utf8 (Get-StatePath $Session) (@{
          session = $Session; convUrl = $captured; convHistory = @(); docPath = $DocPath; title = $Title
          groupTitle = $GroupTitle; rounds = 0; createdAt = (Get-Date).ToString("s"); updatedAt = (Get-Date).ToString("s")
        } | ConvertTo-Json -Depth 8)
        if (-not (Test-Path $DocPath)) { Write-DocHeader -Path $DocPath -Title $Title -S $Session -Curl $captured }
        Update-DocMarker -Path $DocPath -S $Session -Curl $captured -Rounds 0
      }
    }
  $hint = if ($convId) { '；会话链接已记录，重跑同一命令即可续聊' } else { '' }
  # 最后兜底：接口读不到时退回 DOM 文本（已知会缺段，务必告警）
  $domTxt = $null
  try { $domTxt = Get-LastAnswerText $Session } catch {}
  if ($domTxt -and $domTxt.Length -gt 0 -and $domTxt -ne $a0text) {
    Write-Warning "接口读取失败，退回 DOM 文本（可能不完整）: $($domTxt.Length) 字符"
    $answer = $domTxt
    $answerFromDom = $true
  } else {
    Fail 9 ("生成超时（$TimeoutSec s）且无可用回答" + $hint)
  }
}

# ============================ 6. 写文档 + 固化状态 ============================

$anchorFinal = if ($convId) { (New-ConvUrl $convId) } elseif ($anchor) { $anchor } else { "unknown" }

Ensure-Dir (Split-Path $DocPath -Parent)
$round = (Get-DocRoundCount $DocPath) + 1
if (-not (Test-Path $DocPath)) {
  Write-DocHeader -Path $DocPath -Title $Title -S $Session -Curl $anchorFinal
  $round = 1
}
$ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
# 来源标注：只有从断言接口读到正文才不加标记；DOM 兜底必须在文档里留痕，禁止静默写残缺
$srcNote = if ($answerFromDom) { "`r`n`r`n> ⚠️ **本段来自 DOM 兜底（接口读取失败），可能不完整** —— 用 tools\verify-docs.ps1 复核" } else { "" }
$entry = "`r`n## Q$round $ts`r`n**Q:** $Question`r`n`r`n**A:**`r`n$answer$srcNote`r`n"
[System.IO.File]::AppendAllText($DocPath, $entry, (New-Object System.Text.UTF8Encoding($false)))
Update-DocMarker -Path $DocPath -S $Session -Curl $anchorFinal -Rounds $round

$hist = @()
if ($state -and $state.convHistory) { $hist = @($state.convHistory) }
# 锚点发生变化（-ForceNew 或 -Attach 改指）→ 归档旧链接
if ($state -and $state.convUrl) {
  $oc = Get-CanonicalConvUrl $state.convUrl
  if ($oc -and $oc -ne $anchorFinal -and $hist -notcontains $oc) { $hist += $oc }
}
Write-DiscussState $Session (@{
  session = $Session; convUrl = $anchorFinal; convHistory = $hist; docPath = $DocPath
  title = $Title; groupTitle = $GroupTitle; rounds = $round
  createdAt = $(if ($state -and $state.createdAt) { $state.createdAt } else { (Get-Date).ToString("s") })
  updatedAt = (Get-Date).ToString("s")
})

Write-Warning "Q&A 已追加: $DocPath (Q$round) | 会话: $anchorFinal"
Release-Lock
$answer
