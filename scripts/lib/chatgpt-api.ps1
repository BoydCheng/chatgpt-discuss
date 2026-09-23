# chatgpt-discuss 共享库：ChatGPT 后端接口层（会话正文、账号会话列表）。
# 依赖：lib/wb.ps1（Eval-JS）。
# 防重复加载的依赖声明（让本文件可被单独 dot-source / lint）：
if (-not (Get-Command Eval-JS -ErrorAction SilentlyContinue)) { . "$PSScriptRoot\wb.ps1" }
# 说明：未登录时这些接口靠 cookie 认证即可（实测 2026-09-20，匿名会话也能读），
# accessToken 不是必需——所以这里"有 token 才发 Authorization"，不发空的 Bearer。

function Get-ConversationState {
  # 从 ChatGPT 后端接口读权威消息体（而不是抓 DOM）
  # 实测(2026-09-14)：DOM innerText 只拿到第一段（27/163、52/582），丢 80~95% 正文；
  # 接口有干净的完成信号：end_turn=true && content_type='text' && status='finished_successfully'
  param([string]$S, [string]$ConvId)
  $js = @"
(async()=>{
  try{
    if(!window.__ccTok){ try{ const s=await (await fetch('/api/auth/session')).json(); window.__ccTok=s&&s.accessToken; }catch(e){} }
    const h=window.__ccTok?{Authorization:'Bearer '+window.__ccTok}:{};
    const r=await fetch('/backend-api/conversation/$ConvId',{headers:h,credentials:'include'});
    if(!r.ok) return JSON.stringify({error:'HTTP '+r.status});
    const j=await r.json();
    const all=Object.values(j.mapping||{}).map(n=>n&&n.message).filter(m=>m&&m.author&&m.author.role==='assistant');
    const fin=all.filter(m=>m.end_turn===true && m.content && m.content.content_type==='text' && m.status==='finished_successfully');
    const last=fin[fin.length-1];
    const txt=last?(last.content.parts||[]).join(''):'';
    // 历史生成耗时样本（2026-09-23 加）：用于给轮询节奏与耐心上限提供依据。
    // 实测同一会话内生成耗时可从 4.5s 到 274s（方差极大），所以它**不能用来预测**
    // 本轮要多久，只能用来判断"已经等得比历史最久还长了"这类异常。
    const us=Object.values(j.mapping||{}).map(n=>n&&n.message)
             .filter(m=>m&&m.author&&m.author.role==='user'&&typeof m.create_time==='number')
             .map(m=>m.create_time).sort((a,b)=>a-b);
    const as=fin.filter(m=>typeof m.create_time==='number').map(m=>m.create_time).sort((a,b)=>a-b);
    const gen=[];
    for(let i=0;i<Math.min(us.length,as.length);i++){ const d=as[i]-us[i]; if(d>0) gen.push(+d.toFixed(1)); }
    return JSON.stringify({n:fin.length,len:txt.length,text:txt,gen_seconds:gen});
  }catch(e){ return JSON.stringify({error:String(e)}) }
})()
"@
  try {
    $v = Eval-JS $js $S
    if (-not $v) { return $null }
    return ($v | ConvertFrom-Json)
  } catch { return $null }
}

function Test-NewAnswer {
  # 判定"接口读到的最后一条完成回答"是不是**本轮新产生的**。纯函数（不碰浏览器），
  # 由 tools\selftest.ps1 表驱动覆盖。
  #
  # 为什么要有这个函数（2026-09-23 实测缺陷，连续两轮命中）：
  #   ask-gpt.ps1 原先把基线 `$baseN` 默认为 0，且只在**发送之后**才去读它；
  #   后端返回 HTTP 429 时那次读取失败 → `$baseN` 静默留 0 → 轮询里
  #   `n > baseN` 对**任何已存在**的回答都成立 → 把上一轮的回答当成这一轮的结果
  #   写进文档，而且**不报错**（Q2 记成了 Q1 的逐字副本、Q3 记成了 Q2 的副本）。
  #   根因不是"读失败"，而是"读失败被当成了基线为 0"。
  #
  # 因此本函数把基线是否可信（BaseKnown）作为一等输入：基线不可信时**任何** n 都
  # 不能判为 new。调用方（ask-gpt.ps1）另有一条更硬的约束——续聊模式下基线是
  # **发送的前置条件**，拿不到就 Fail 16，压根不发问。
  param(
    [int]$BaseN,
    [string]$BaseText = '',
    [bool]$BaseKnown = $true,
    [int]$N,
    [string]$Text = ''
  )
  if (-not $BaseKnown) { return 'unknown-baseline' }
  if ($N -le $BaseN) { return 'not-yet' }
  if (-not $Text -or $Text.Length -eq 0) { return 'empty' }
  # 条数涨了但正文与基线正文逐字相同 → 不是新回答（陈旧响应 / 上一轮迟到完成）。
  if ($BaseText -and $Text -eq $BaseText) { return 'stale-same-text' }
  return 'new'
}

function Get-PollDelayMs {
  # 下一次轮询前应该等多久（纯函数，不碰浏览器，由 tools\selftest.ps1 表驱动覆盖）。
  #
  # 为什么要改（2026-09-23）：原实现是"前 40 次固定 1.2s、之后固定 2.5s"，
  # 默认 TimeoutSec=360 时**一轮要打约 165 次接口请求**；而生成耗时方差极大
  # （本会话实测 4.5s / 7.3s / 50.5s / 274s），其中绝大多数请求注定读到"还没好"。
  # 一旦后端开始限流（429），仍按原速重试会把压力放大，现象是**会话页本身
  # 加载不出来**（另开一个聊天页反而正常）。
  #
  # 设计：**几何退避**。早期必须仍然快——最快的答案 4.5s 就出现了，不能被拖慢；
  # 之后每两次翻一倍直到上限。按此节奏，360s 内约 25 次请求（原 165 次，降约 85%），
  # 而命中快答案的时间几乎不变。
  #
  # 为什么**不用**历史耗时去"预测"本轮要多久：实测方差 4.5s~274s，均值没有预测力；
  # 按均值把早期轮询推迟，反而会拖慢快答案。历史耗时只用于判断异常（见 ask-gpt.ps1
  # 里"超过历史最久还没出"的告警）。
  param(
    [int]$Iter,
    [int]$BackoffMs = 0,
    [int]$StartMs = 1000,
    [int]$CapMs = 20000
  )
  if ($BackoffMs -gt 0) { return [int][Math]::Min($BackoffMs, $CapMs) }   # 429 退避优先，且不超上限
  if ($Iter -lt 1) { $Iter = 1 }
  $step = [Math]::Floor(($Iter - 1) / 2)      # 1,1,2,2,4,4,8,8,16,16,20,20,…
  return [int][Math]::Min($StartMs * [Math]::Pow(2, $step), $CapMs)
}

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
