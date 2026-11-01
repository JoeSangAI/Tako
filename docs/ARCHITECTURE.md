# 架构

Tako 是两个进程：**原生 app**（Swift）有系统权限，管小章鱼、窗口和动手；**大脑**（Python）管会话、模型和规则。面板是大脑提供的一个网页，显示在原生 app 的窗口里。

```
             ┌──────────────── 原生 app（Sources/native）────────────────┐
             │ 小章鱼   窗口跟随   挪窗口让位   填入/操作   听声音   更新 │
             └───┬───────────────────────┬──────────────────────────────┘
       网页里的面板 │              /native/next 取命令，/native/result 回结果
                 ▼                       ▼
             ┌──────────────── 大脑（Sources/brain）────────────────────┐
             │ routes → Companion（chats + turns + hands + lecture）    │
             └───────────────────────┬──────────────────────────────────┘
                            codex_runtime（标准输入输出）
                                     ▼
                              Codex app-server → 模型
```

大脑永远不直接碰窗口：要点、要填、要看，都发一条命令给原生 app。原生 app 不判断该不该做这件事，只判断这一下能不能按。

## 两种线程

判断改动能不能这样写，先看它跑在哪种线程上：

- **大脑线程**：所有窗口共用一条，只跑主人在面板里说的话，有工具、有 shell。
- **一次性线程**（`Turns._reader`）：别人的新消息、点开对话、听课笔记、从改动里学、开场白、反馈提炼。没有任何工具，用完就退订（`thread/unsubscribe`），Tako 这边不再保留它的事件。所以窗口或消息里写的话，什么也动不了。

主人的工具调用只认大脑线程（`Hands.on_server_request`）。给一次性线程加工具，就是拆掉这条防线。

## 大脑（Sources/brain）

依赖只往下走：下面的文件不知道上面的文件。

| 文件 | 管什么 | 要改这些时来这里 |
|---|---|---|
| `tako_server.py` | 共享状态 `Companion`、发给面板的快照、启动 | 加一项全局状态 |
| `routes.py` | 本机 HTTP 路由，都要带令牌 | 面板或 app 要一个新接口 |
| `chats.py` | 粘窗口、认微信对话、新消息、主动开口、学写法 | 什么时候读、什么时候开口 |
| `turns.py` | 跑一轮、一次性线程、压缩、掉线恢复、停止、失败说明 | 模型交互和报错文案 |
| `hands.py` | 工具实现、审批卡片、发命令给原生 app | 新增或修改工具 |
| `lecture.py` | 听课：声音分段、转写、笔记 | 听课 |
| `prompts.py` | 所有提示词、工具声明、两种线程的配置 | 模型被告知什么、能用什么 |
| `guards.py` | 无状态的底线规则：脚本检查、工作台只收原话、标题核对 | 一条“不管模型怎么说都要成立”的规则 |
| `outputs.py` | 作品目录、备份、替换文件 | 文件写到哪 |
| `knowledge.py` | 系统代跑的那一次只读资料查询 | 资料库 |
| `first_run.py` | 找 Codex、安装、登录 | 新用户第一次打开 |
| `feedback.py` | 回传给作者的数字和固定词 | 改了就要同步改 `docs/PRIVACY.md` |
| `greetings.py` | 开场白 | 彩蛋 |
| `wechat_reader.py` | 可选的本机微信读取 | 微信数据库 |
| `codex_runtime.py` | 和 Codex 的连接 | 协议 |
| `settings.py` | 这台 Mac 的配置和路径，其他文件都从这里取 | 新增一项配置 |
| `side.html` | 面板网页，每隔一会儿拉 `/state` 并画出来 | 面板界面 |

`Companion` 由 `Chats`、`Turns`、`Hands`、`Lectures` 四部分组成，共用一份状态，字段都在 `tako_server.py` 的 `__init__` 里写明了用途。

## 原生 app（Sources/native）

| 文件 | 管什么 |
|---|---|
| `Controller.swift` | app 持有的状态、启动退出、每帧循环、右键菜单 |
| `Goo.swift`、`GooPhysics.swift`、`GooDrawing.swift` | 小章鱼：状态和情绪、运动、绘制 |
| `Enchant.swift` | 窗口四周的墨边和墨圈 |
| `Windows.swift` | 粘在哪个窗口、跟随、找回、层级；不能粘的应用名单 |
| `SidePanel.swift` | 面板窗口，以及网页发给 app 的全部消息 |
| `MakeRoom.swift` | 挪窗口让位、全屏、挪回去、崩溃后恢复 |
| `WeChatHeader.swift` | 读微信顶部标题 |
| `Hands.swift` | 大脑命令的入口 `run`、填入、看窗口、关开文档、取皮肤 |
| `Operate.swift` | 操作任意窗口；发送、回车、密码框的防线都在这里 |
| `Listen.swift` | 采集应用的声音 |
| `Update.swift` | 检查更新、下载、验签、替换 |
| `Backend.swift` | 拉起并看管大脑 |
| `SelfTest.swift` | `--selftest`，跑一遍小章鱼的生命周期 |

## 加一个工具

1. `prompts.py`：在 `TOOLS` 里声明，`STEP_NAMES` 里起名字，需要时在 `PROMPT` 里说明。
2. `hands.py`：在 `_run_tool` 里实现。收不回来的事走 `_card`。出异常不用管，模型会收到一次失败，这一轮继续。
3. 要动窗口时：在 `Hands.swift` 的 `run` 里加一条命令。
4. 测试：`tests/test_turns.py` 里写一个主人看得到的场景。

## 测试

```bash
python3 tests/test_guards.py
```

```bash
python3 tests/test_turns.py
```

- `test_guards.py`：底线规则。规则能直接调用就直接调用，只有 Swift 和“某段代码不能用某个东西”才查源码。
- `test_turns.py`：真的启动大脑，一头是它的 HTTP 路由，一头是 `tests/fake_codex.py`（和真 Codex 一样的消息，不用模型、不联网），测试自己扮演原生 app。场景写在问句里，比如模型中途失败、工具卡住时按停止。
- `--selftest`：小章鱼的动作和帧率。要看屏幕，不进 CI。

## 隔离运行

设了 `TAKO_HOME`，所有状态都写到那个目录，回传也关掉。原生 app 和大脑都认它，正式版绝不能设。

```bash
open -n dist/Tako.app --env TAKO_HOME=/tmp/tako-test --args --selftest
```

面板打开时可能挪动真实窗口，自测不会打开面板，也不检查更新。
