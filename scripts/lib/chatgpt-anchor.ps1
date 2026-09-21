# chatgpt-discuss 共享库：ChatGPT 会话锚点（纯函数 + 会话种类）。
#
# 会话路径种类：
#   c  = 登录会话（服务端持久身份，可用 URL 找回）
#   uc = 匿名会话（未登录；**关掉即失效**——URL 只在对话未关时有效，
#        拿它重开只会得到一条新对话，所以匿名会话绝不走"用 URL 重开"）
#
# 状态：$script:ConvKind 由本库持有（dot-source 共享作用域），
#       主脚本通过 Set-ConvKindFromUrl / Get-CanonicalConvUrl 间接触达。

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
