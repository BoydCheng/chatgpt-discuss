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
