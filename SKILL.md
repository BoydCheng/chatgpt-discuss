---
name: chatgpt-discuss
description: |
  通过真实浏览器（Edge + Kimi WebBridge daemon）用用户的 ChatGPT 登录态与网页版 GPT（GPT-5.6 Luna，免费无限文本聊天）进行**多轮讨论**，每轮 Q&A 自动追加到同一个 Markdown 文档并带回对话。触发词：用GPT讨论、问一下GPT、和ChatGPT聊聊、帮我问GPT、问问GPT的意见、和网页版ChatGPT交互、继续问GPT、追问GPT。
metadata:
  version: "2.0.0"
---

# ChatGPT 讨论（chatgpt-discuss）

## 用途

在真实浏览器（Edge，登录态或未登录匿名会话均可）里向网页版 GPT 提问、读取完整回答，并把每轮 Q&A 追加到同一个 Markdown 文档存档。相当于把网页版 GPT 当作一个"外部讨论对象"。

---

## 身份模型（先读懂这段，否则一定会开出一堆重复对话）

> **一个讨论 = 一条 ChatGPT 会话**：登录态是 `https://chatgpt.com/c/<uuid>`，未登录态是 `https://chatgpt.com/uc/<id>`。
> webbridge 的 `session` 名和浏览器标签组**只是执行通道**。

两种会话的**身份强度完全不同**，这决定了标签丢了还能不能找回来：

| | 登录会话 `/c/<uuid>` | 匿名会话 `/uc/<id>`（未登录） |
|---|---|---|
| 身份 | 服务端持久，账号会话列表里能列出 | **只在"对话没关"期间有效** |
| 标签丢了 | 按 URL 重开即恢复 | **不能重开**——重开就是一条新对话 |
| 关浏览器 / 隔天 | 恢复 | 对话作废，锚点失效 |
| 脚本行为 | 找不到标签就按 URL 重开 | **绝不重开**；标签不在就停下让你决定 |

- 会话 URL 由脚本自动捕获并持久化在两处：
  - `%LOCALAPPDATA%\chatgpt-discuss\state\<session>.json`（运行状态，SSOT）
  - 文档头的 `<!-- chatgpt-discuss: session=... conv=... -->` 注释（可移植备份）
- 续聊时脚本先读锚点：登录会话按 URL 找回或重开；**匿名会话只做原地复用、绝不导航**（导航即丢对话）。
- 没有锚点时，脚本会**认领本讨论组里已有的会话页标签**（同样不导航），所以"上一轮跑到一半"或"你手动开着的那个对话"都能接上。
- 脚本会自动写文档头（含链接）。**不要手写文档头、不要手改 session 名、不要改文档文件名。**
- **长期 / 跨天讨论请先登录**：匿名会话隔天就没了，锚点随之失效。
- 每轮脚本会先探测登录态（`/api/auth/session` 带 `user.id` 即已登录），再与锚点的会话种类交叉判定：
  锚定 `/c/` 却未登录 → **直接退出（码 14）**，不去撞登录页；未登录新建 → 走 `/uc/` 并提示易失性；
  锚定 `/uc/` 而已登录 → 仍按匿名策略（只复用、不重开）。**登录态只用于开场判断，恢复策略始终以锚点种类为准**。

---

## 决策流程（每次调用前照做）

```
① 先查现状：      pwsh -File <skill>\scripts\ask-gpt.ps1 -Status
② 已有该话题 →    续聊：不带 -New，带上原 -Session 与 -DocPath
③ 确实是新话题 →  新建：-New（脚本会捕获新链接并记录）
④ 要接管"已存在的某条对话"（你手动开的 / 历史上被撕碎的）→ 用 -ListChats 找 → 用 -Attach 挂回来
```

**判断"是不是新话题"的标准**：同一个讨论线（同一份文档、同一批上下文）→ 是同一个话题。只是"换个问法/再深入一点"→ 仍然是同一个话题 → **继续追问，不要 -New**。

### 首轮（新话题）

```powershell
pwsh -File "$env:USERPROFILE\.agents\skills\chatgpt-discuss\scripts\ask-gpt.ps1" `
  -Question "你的问题（支持中文）" `
  -Session "任务slug" `
  -Title "讨论标题" `
  -New `
  -DocPath "D:\MyProjects\...\docs\gpt_qa\<slug>.md"
```

### 后续轮次（同一话题，**这是最常用的形态**）

**和首轮完全一样，只去掉 `-New`**：

```powershell
pwsh -File "$env:USERPROFILE\.agents\skills\chatgpt-discuss\scripts\ask-gpt.ps1" `
  -Question "追问的内容" `
  -Session "任务slug" `
  -DocPath "D:\MyProjects\...\docs\gpt_qa\<slug>.md"
```

脚本会：读锚点 → 在**原会话**里追问 → 追加 `## Q<n>` 到**同一份文档** → stdout 只输出回答全文。
`-DocPath` 不传也行（会复用 state 里记录的文档），但**显式传更稳**。

### 接管"已存在的对话"（-ListChats / -Attach）

历史上被撕碎的那些对话（同一话题开出多条、或你在网页里手动开的），**不用重开，直接挂回来**：

```powershell
# ① 列出账号里的会议（只读，不提问、不改文档）
pwsh -File ...\ask-gpt.ps1 -ListChats -Limit 30
#    输出：标题 / 更新时间 / 会话 id /（若已锚定）← 已锚定: <session>

# ② 挂到某个讨论（三选一：标题关键字 / 完整链接 / 裸 id）
pwsh -File ...\ask-gpt.ps1 -Attach "RK3399读取优化建议" -Session rigol-perf
pwsh -File ...\ask-gpt.ps1 -Attach https://chatgpt.com/c/<uuid> -Session rigol-perf
pwsh -File ...\ask-gpt.ps1 -Attach <uuid> -Session rigol-perf
```

- **不带 `-Question` = 只绑定**：写好 state 与文档标记后退出（stdout 输出该会话链接）
- **带 `-Question` = 绑定 + 立刻追问**，直接落在那条原对话里（**带完整历史上下文**）
- 标题匹配到多条时**会拒绝**并列候选让你选（不会瞎猜）——你账号里 `评审降采样架构` 就有两条一模一样的
- 扫描用的标签在独立的「GPT讨论：会话浏览」组里，不干扰各讨论自己的标签组

### ⚠️ 怎么判断"这一轮到底落进哪条会话"——**别看它记不记得**

用户账号开了 **ChatGPT 的 web 记忆**。因此：

- **不能**用"GPT 还记不记得上一轮"来判断是否续到了原会话 —— 记忆功能会让它在**新会话里也答得出**上文。
- 这会掩盖失败：脚本万一开了新对话，回答看起来依然"有上下文"，**你根本察觉不到**（历史上那批重复会话就是这么静默产生的）。
- **唯一可靠的判据 = 翻会话记录**：接口 `/backend-api/conversation/<id>` 返回的消息列表里，
  这一轮的提问是否物理出现在目标会话中。也可以直接看 `-Status` 记录的 `convUrl` 再打开核对。
- 所以文档头那行 `链接: https://chatgpt.com/c/<uuid>` 是**审计依据**，别手改、别删。

---

## 硬约束（违反 = 制造重复对话，历史上就是这么坏的）

| 禁止 | 原因 / 正确做法 |
|---|---|
| **标签找不到时加 `-New` 重跑** | 标签丢失**不是**会话丢失。脚本自己会用会话 URL 重开（上限 2 次）。加 `-New` 只会被判 `exit 10` 拒绝。 |
| **每轮改 session 名**（`xaxis` → `xaxis2` → `rx3`） | 这是历史上开出多条重复对话的**头号原因**。同一个话题永远用同一个 `-Session`。 |
| **每轮改 `-Title` / `-GroupTitle`** | 会在浏览器里**多长出一个标签分组**（同话题出现「…X轴与降采样」「…X轴降采样」两个分组就是这么来的）。分组名和标题一旦建立就粘在 state 里，别动。 |
| **同一个话题换文档**（`wedge.md` → `wedge2.md`） | 档案被撕碎。续聊必须复用同一份文档（脚本默认也会复用）。 |
| **并发调用 / 超时后重发** | 会双开并互相写坏同一对话。脚本有锁（`exit 12`），别绕。 |
| **手写文档头 / 手改文档里的 `conv=` 标记** | 会破坏锚点，导致下一轮认不出原对话。 |
| **绕过脚本手工 curl webbridge 做多轮** | 手工路径**没有状态**，必然开新对话。脚本坏了就报错，不要自己发明流程。 |

---

## 常用参数

| 参数 | 说明 |
|---|---|
| `-Question` | 问题正文（必填，除非 `-Status`） |
| `-Session` | 讨论 slug。不传时：有 `-DocPath` 就从文档名推导；否则复用当前工作区**最近用过**的讨论 |
| `-DocPath` | Q&A 文档。不传时优先复用 state 里记录的（跨天不拆文件） |
| `-Title` | 文档标题（仅首轮写入；之后从 state 粘住，别改） |
| `-New` | 声明"新讨论"。已有锚点时会被拒绝（`exit 10`） |
| `-ForceNew` | 确认放弃原线程、开新的（旧链接归档进 `convHistory`） |
| `-Status` | 只读列出所有讨论（session / 轮数 / 会话链接 / 文档），不碰浏览器 |
| `-CloseExtras` | 清理该 session 内不属于本讨论的 chatgpt 标签（清理历史残留用） |
| `-ConvUrl` | 显式指定要锚定的已有会话（接管/恢复用） |
| `-ListChats` | **只读**列出 ChatGPT 账号里的会话（标题 / id / 更新时间 / 本地锚定情况）。不提问、不改文档 |
| `-Attach` | 把**已存在的会话**挂到当前讨论：标题关键字（模糊）、完整链接、或裸 id 都行。不带 `-Question` 时只绑定 |
| `-Limit` | `-ListChats` 显示条数，默认 30 |
| `-Daemon` | daemon 地址。**留空即自动探测**（读 `~/.kimi-webbridge/daemon.addr` → 退回 10086） |
| `-TimeoutSec` | 单轮生成超时，默认 360 |
| `-MaxRecover` | 单轮内用会话 URL 重开标签的最大次数，默认 2 |

> **接管 v1 老文档**：v1 写的文档没有 `chatgpt-discuss` 标记，但只要正文头部有 `chatgpt.com/c/<uuid>` 链接，
> 脚本会**自动认领为锚点**（报 `锚点来自文档(旧格式链接)`）——老讨论可以直接续聊，不必新开。

---

## 退出码表（脚本真实会返回的；**按表行动，不要自己猜**）

| 码 | 含义 | 你该做什么 |
|---|---|---|
| 0 | 成功 | — |
| 3 | webbridge daemon 不可用 | 跑 `"%USERPROFILE%\.kimi-webbridge\bin\kimi-webbridge.exe" start` 后重试**同样**命令 |
| 5 | 页面未就绪（登录墙/验证码/改版） | 提示用户手动在 Edge 里处理 |
| 6 | 有锚点但拿不到也开不出标签 | **不要 `-New`**。先用 `-Status` 看链接，确认 Edge 能打开该链接 |
| 7 | 填入问题失败 | 页面可能改版，看 `snapshot` 找输入框 |
| 8 | 发送失败 | 用 `snapshot` 找发送按钮 |
| 9 | 生成超时且无回答 | 会话链接已记录，**重跑同一条命令**即可续聊 |
| 10 | 已有讨论线程，拒绝新建 | 去掉 `-New` 重跑；确实要新线程才加 `-ForceNew` |
| 11 | 发送前校验：当前页面不是锚定会话 | 标签被手动导航走了。不要 `-New`，用 `-ConvUrl` 指回原链接 |
| 12 | 同一 session 已有进程在跑 | 等它跑完，**不要**并发/不要换 session 名绕开 |
| 13 | 参数/文档冲突 | 按报错信息修正参数 |
| 14 | 登录态与会话种类不匹配（锚定 `/c/` 登录会话，但当前未登录） | 先在 Edge 登录 ChatGPT 再重试；或 `-New` 开一条匿名讨论（易失） |

---

## 前置条件

- Kimi WebBridge daemon 运行中（`kimi-webbridge start` 启动）。地址**自动探测**：
  读 `~/.kimi-webbridge/daemon.addr`，读不到才退回 `http://127.0.0.1:10086`（端口被改过也能用）
- Edge 里已打开 ChatGPT。**登录与否都能用**：未登录走匿名会话 `/uc/`（见「身份模型」）——
  但匿名会话**关掉即失效**，跨天或长期讨论请先登录
- **运行前激活 Edge 窗口**（脚本内置 AppActivate）。读取答案已改走后端接口、不再依赖 DOM 渲染，
  激活主要影响"输入/点击"的即时性）
- ⚠️ daemon 的扩展槽位**只能被一个浏览器实例占用**。若日志出现
  `[ws] refused extension ... slot held by ...`，说明另有 Edge 实例连着 daemon，
  命令可能落到错误的窗口里 → 此时先让用户关掉多余实例，否则会出现"找不到标签"的假象

## 文档存放规则

- **默认位置**：当前工作区 `docs/gpt_qa/<日期>-<session>.md`（自动创建目录）
- **项目规则优先**：若工作区 AGENTS.md 规定了文档目录，用 `-DocPath` 显式指定
- 同一话题所有轮次自动追加到同一份文档（`## Q<n>` 递增）
- 文档头由脚本写（标题 + `chatgpt-discuss` 注释 + 链接行），**AI 不要手写**
- 用户明确要求关闭时调用 `close_session`；**不主动关闭**
- 模型：不切换，用 ChatGPT 当前默认（Luna）

## 文档格式（脚本自动生成）

```markdown
# GPT 讨论：<标题>（<日期>）

<!-- chatgpt-discuss: session=<s> conv=https://chatgpt.com/c/<uuid> updated=<ts> rounds=<n> -->
- 会话: <s> | 链接: https://chatgpt.com/c/<uuid>

## Q1 <时间戳>
**Q:** <问题>

**A:**
<GPT 回答全文>
```

## 手工兜底（**仅在脚本彻底不可用时**，且必须带锚点）

Windows 下中文必须走文件体（shell 内联会损坏非 ASCII）。手工路径**没有状态管理**，
所以每一条 navigate 都必须使用**已记录的会话链接**，**绝对不要** navigate 到 `https://chatgpt.com/` 根路径（那是"新对话"）：

```powershell
# 0) 先拿锚点（二选一）
pwsh -File <skill>\scripts\ask-gpt.ps1 -Status              # 从 state 读
Select-String -Path <文档> -Pattern 'chatgpt-discuss: .*conv=(\S+)'   # 从文档头读
# 1) 健康检查
curl.exe -s --noproxy "*" http://127.0.0.1:10086/status
# 2) 回到原会话（用上面拿到的链接；group_title 用原值）
#    {"action":"navigate","args":{"url":"https://chatgpt.com/c/<uuid>","newTab":true},"session":"<session>"}
# 3) 定位对话框：**不要写死 #prompt-textarea**（未登录/新版页面没有它，见「限制」）。先探测：
#    evaluate "(()=>{const v=e=>{try{const r=e.getBoundingClientRect();return r.width>0&&r.height>0}catch(_){return false}};for(const s of ['#prompt-textarea','form [contenteditable=\"true\"]','form textarea','textarea']){const e=document.querySelector(s);if(e&&v(e))return s}return ''})()"
#    再用它返回的选择器 fill: {"action":"fill","args":{"selector":"<探测结果>","value":"<问题>"},"session":"<session>"}
# 4) 发送: {"action":"click","args":{"selector":"button[aria-label*=\"发送\"]"},"session":"<session>"}
#    （未登录/新版页面没有 button[data-testid="send-button"]；中文界面用「发送」，英文界面换 Send）
# 5) 等完成: 轮询 evaluate "!!document.querySelector('button[data-testid=\"stop-button\"]')" 直到 false
# 6) 取答:   evaluate "[...document.querySelectorAll('[data-message-author-role=\"assistant\"]')].pop()?.innerText"
```

做完后请**手工补文档与 state**，否则下一轮还会丢锚点。

## 维护：改脚本后**必须**跑自检（不要靠肉眼/AI 自己判断）

这个脚本踩过一批"文档约束不住、只能靠工具拦"的坑，所以现在有机械化的防护：

```powershell
# 一条命令跑完：静态检查 + 检查器自证 + 离线行为回归（约 47s，不碰浏览器）
pwsh -File "$env:USERPROFILE\.agents\skills\chatgpt-discuss\tools\selftest.ps1"
# 只想静态检查单个脚本：
pwsh -File "$env:USERPROFILE\.agents\skills\chatgpt-discuss\tools\lint.ps1" -Path <脚本路径>
```

`lint.ps1` 抓的是**这类语言级陷阱**（都是真实踩过的）：

| 代号 | 陷阱 | 曾经的后果 |
|---|---|---|
| E1 | 参数名撞 PowerShell 自动变量（`$args`/`$input`/`$error`…） | 参数被静默吃掉，报 `url is required`，被误判成网络抖动 |
| E2 | `[switch]` 参数被当普通变量赋值（`$new` vs `-New`、`$status` vs `-Status`） | 变量名大小写不敏感 → metadata 异常，脚本直接崩 |
| E3 | 调用已删/改名的函数 | 运行时才炸 |
| E4 | `Write-Error` 后跟 `exit` | exit 不可达，**所有退出码都变成 1**（历史上就是这么坏的） |
| W2 | `$x \| Get-Content` 未写 `-Path` | PS7 下绑不到，异常又被 `catch {}` 吞掉 |

**AI 不要"顺手改脚本"**：优先用现有参数（`-Status` / `-ListChats` / `-Attach` / `-ConvUrl` / `-ForceNew` / `-CloseExtras`）解决问题。
确需改代码时，改完**必须**跑 `selftest.ps1` 且 12 项全 PASS 才算完成。

### 验证纪律：**不要拿"被告的证词"当证据**

webbridge 的 `list_tabs` / `find_tab` 返回的是**它自己的认知**，不是浏览器事实。实测（2026-09-14，用 kimi-cu 独立复核）：

- 浏览器里明明有 **12+ 个「GPT讨论：…」标签组，每组还挂着活着的 ChatGPT 标签**
- 而 webbridge 对这些 session **全部报 `0 标签`**
- 原因：daemon 重启（日志 `sig: terminated`）/ 运行中 `stale tab` 判定，会让 session→标签映射丢失，
  **但浏览器里的标签不会跟着关** → 恢复分支只能再开一个新标签 → 旧标签永久滞留 → 越用越多
- 补充：webbridge 的 `cdp` 是**标签级**附加，`Target.getTargets` 直接返回 `Not allowed`
  —— 它**结构上枚举不了别的标签**，别指望用它清理孤儿标签

**凡是要下"验证结论"的，必须换独立通道复核**：

| 想验证什么 | ❌ 别用 | ✅ 该用 |
|---|---|---|
| 这一轮落进哪条会话 | "它记不记得上文"（你开了 web 记忆，新会话照样答得出） | 翻会话记录：`/backend-api/conversation/<id>` 的消息列表里有没有这次提问 |
| 标签/分组是否存在 | webbridge `list_tabs`（自述） | 人眼看浏览器，或 kimi-cu（Windows UI 自动化，独立通道） |
| 答案是否完整 | DOM `innerText`（只渲染第一段，丢 80~95%） | 后端接口 `end_turn=true` 的消息体 |

### 续聊时怎么找标签（**会优先接管你已打开的那个**）

目标会话的标签按这个顺序找，**能复用就绝不新开**：

| 顺序 | 手段 | 说明 |
|---|---|---|
| ① | `find_tab(url, active=true)` | **接管你当前正在看的标签** —— 只有你正开着的那个标签**就是目标会话**时才生效（webbridge 自带 URL 匹配，不匹配就干净失败，绝不会抢走你在看的别的页面）。**不新开、不导航** |
| ② | `find_tab(url)` | 复用本 session 自己已有的标签 |
| ③ | `navigate(url)` | 兜底：用会话链接重开 |

三条路都指向**同一条服务端会话**，所以连续性只看 `convUrl`，与标签无关。

- 借用来的标签会在本轮跳过"清理游离标签"（那是你可能正在看的页面，不能去关）
- 借用的副作用：该标签会被挂上 `chrome.debugger` → 浏览器顶部出现「已开始调试此浏览器」信息栏。
  **这是正常的**，别点那条信息栏上的「取消」——点了会断开调试、webbridge 对该标签即失效

## 限制

- **对话框与发送键走多候选定位，不押单一选择器**（2026-09-20 实测修正）。composer 依次试
  `#prompt-textarea` → `div[contenteditable]#prompt-textarea` → `form .ProseMirror[contenteditable]`
  → `form`/`main [contenteditable]` → `form textarea` → `textarea`，全落空时退到"页面上最后一个可见可编辑元素"；
  发送键依次试 `button[data-testid="send-button"]` → `aria-label` 含 Send/发送 → `form button[type=submit]`，
  兜底取 composer 所在容器内最后一个可见且未禁用的按钮（排除语音/附件/工具键）。
  命中后打 `data-cc-composer` / `data-cc-send` 标记再操作。**改版时只需扩充这两个候选列表**
  （`Resolve-ComposerTarget` / `Resolve-SendTarget`）。
  实测：未登录首页的 composer 是 `textarea#mobile-composer-prompt`，既无 `#prompt-textarea` 也无
  `button[data-testid="send-button"]` —— 写死选择器的旧版在该页面必然失败
- **发送键必须在填完内容之后再定位**：输入框为空时 ChatGPT 把发送键换成语音按钮，那一刻"最后一个按钮"不是发送键
- **匿名会话不可恢复**：未登录时走 `/uc/<id>`，它**只在对话未关期间有效**——标签一关、浏览器一重启、
  隔一天再来，都变成新对话，锚点随之失效。脚本因此对匿名会话**只做原地复用，绝不导航或重开**；
  标签不在时直接停下报错，而不是偷偷开一条新对话。
  实测（2026-09-20）：未登录**能读到完整答案**（`/backend-api/conversation/<id>` 靠 cookie 认证即可，
  不需要 accessToken），所以匿名模式下多轮讨论成立，前提是**标签不关**
- 仅文本问答；不做图像生成/上传文件
- **答案读取走后端接口，不抓 DOM**（2026-09-14 实测修正）：DOM `innerText` 只拿得到第一段
  （27/163、52/582 字符），会**丢掉 80~95% 正文**。脚本改为读
  `/backend-api/conversation/<id>`，取 `end_turn=true` 且 `content_type='text'` 的最后一条。
  好处：**不需要刷新页面**、不受后台节流/DOM 渲染/占位块影响，也不会误判完成。
  典型一轮 8~20s（旧版同场景 ~117s）。DOM 文本只作为接口失效时的兜底（会告警"可能不完整"）。
- **扩展重连**：Kimi WebBridge 扩展更新/重连会重置标签页，脚本用会话 URL 自动恢复（有上限，不会刷标签）
