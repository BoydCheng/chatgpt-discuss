# chatgpt-discuss 共享库：Kimi WebBridge daemon 的 HTTP 封装。
# 依赖：lib/common.ps1（Read-Text）。
#
# 约定：调用方需先设好**脚本作用域变量 $Daemon**（daemon 基址，如 http://127.0.0.1:10086）。
# Invoke-WB 读取的是调用方脚本作用域的 $Daemon（dot-source 共享作用域），
# 因此库里**只读不写**这个变量；要改它请在调用方用 $script:Daemon = ... 显式写回。

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
