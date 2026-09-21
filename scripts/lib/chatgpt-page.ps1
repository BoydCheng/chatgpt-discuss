# chatgpt-discuss 共享库：ChatGPT 页面 DOM 事实层
# （登录态探测、会话标签发现、Edge 激活、对话框/发送键定位、DOM 兜底读答案）。
# 依赖：lib/wb.ps1（Eval-JS / Invoke-WB）。
# 全部无自有状态（只经 Eval-JS 读写页面 DOM）；dot-source 后与调用方共享 $script: 作用域。

function Get-LoginState {
  # 探测当前 ChatGPT 页面的登录态：/api/auth/session 带 user.id 即已登录。
  # 它只用于"开场判断与告知"，**不**决定恢复策略——恢复策略以锚点的会话种类
  # （/c/ 登录会话 vs /uc/ 匿名会话）为准，那是事实，而登录态可能中途变化。
  param([string]$S)
  $js = @'
(async()=>{
  try{
    const r = await fetch('/api/auth/session', {credentials:'include'});
    if(!r.ok) return 'unknown';
    const j = await r.json();
    return (j && j.user && j.user.id) ? 'in' : 'out';
  }catch(e){ return 'unknown' }
})()
'@
  try { $v = Eval-JS $js $S; if ($v) { return [string]$v } } catch {}
  return 'unknown'
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
