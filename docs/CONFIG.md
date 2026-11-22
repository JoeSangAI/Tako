# 高级设置

Tako 不需要任何设置就能用。想让它更懂你，在 `~/Library/Application Support/Tako/` 里放这两个文件，重启 Tako 生效。

## about-me.md

写给 Tako 看的背景：你是谁、在做什么、喜欢怎样的回答。纯文本，最多读前 6000 字。

## config.json

每一项都可选：

```json
{
  "name": "Alex",
  "timezone": "Asia/Shanghai",
  "model": "gpt-6.1-sol",
  "light_model": "gpt-6.1-terra",
  "output_root": "~/Documents/Tako",
  "background_file": "~/Documents/about-me.md",
  "extra_instructions": "回答一律用繁体中文。"
}
```

| 项 | 含义 | 不写时 |
| --- | --- | --- |
| `name` | Tako 怎么称呼你 | 用 Mac 账户名 |
| `timezone` | 主人使用的时区，采用 IANA 时区名称 | Mac 的系统时区 |
| `model` | 你交代的事用哪个模型 | 跟随你的 Codex 设置 |
| `light_model` | 后台的一次性轻活用哪个模型：开场白、听课笔记、从你改过的草稿里学写法、整理反馈 | 和 `model` 一样 |
| `clock_note` | 关于时间的补充说明，每轮都会告诉模型 | 无 |
| `per_conversation_threads` | 设为 `false` 时，所有窗口和聊天共用一条模型线程（以前的做法） | 每个窗口、每个聊天、桌面各一条，互不等待 |
| `conversation_threads_max` | 最多同时留几条对话线程，再多就退订闲得最久的那条 | 6 |
| `conversation_thread_idle_minutes` | 一段对话多少分钟没动静就退订它的线程，下次从对话记录续上 | 30 |
| `look_dedup` | 设为 `false` 时，重复看同一窗口仍每次发送完整结果 | 不变的窗口不重复发送 |
| `output_root` | Tako 的文件夹：`对话记录/` 和 `产出文件/` 放在这里。也可以右键小章鱼 →“做过的事…”→“换位置…”来选 | `~/Desktop/Tako` |
| `background_file` | 背景文件的位置 | `about-me.md` |
| `extra_instructions` | 追加给模型的说明 | 无 |
| `keep_codex_log` | 排查问题时设成 `true`：Codex 的完整日志（含窗口截图和文字）留在 `codex-state/`，下次启动清空。查完记得关 | 不留 |

## 可选的本地接入

这几项给已经有对应工具的人，默认关闭，路径不存在就当没配。

| 项 | 接入什么 |
| --- | --- |
| `workbench` | 外部事项服务：`url`、`cards` |
| `wechat_export` | 兼容 wxexport 的本地微信读取目录，你要自己准备好它，Tako 不提取密钥。接上后你开口时 Tako 能直接读对话记录，不用看截图，还能从你改过的草稿里学写法。来新消息时它不读也不说话 |
| `calls` | 别人怎么称呼你：反馈发给作者之前，这些称呼会被拦下 |

## 本体来源

未接外部本体时，Tako 在空闲且有新对话记录时，用无工具的一次性线程追加结构化判断到运行目录的 `judgments.jsonl`（0600）。代码折成主体、项目、行动；线程首次开口或判断流水更新后带最多 2,000 字的索引，详细内容按出处读原话。模型不重写本体，编号只在新建行分配，主人的确认和纠正优先；本体不触发主动行为。

`ontology_source` 默认关闭。启用后优先从明确配置的本机环回地址读取 `/api/ontology`。服务停机、超时或返回无效内容时，读取来源维护的最后一份快照。只接快照时可省略 `url`。

```json
{"ontology_source": {"enabled": true, "url": "http://127.0.0.1:8799", "snapshot": "~/Shared/ontology.json"}}
```

接口与快照共用 `schema_version: 1`、`items` 和可选的 `redirects`。条目包含稳定编号、`kind`（`subject`、`project` 或 `action`）及来源提供的字段和出处。已明确配置的旧 `ontology_source.snapshot` 和 `workbench.ontology.snapshot` 仍可用。设 `enabled: false` 可关闭读取、恢复本机推断。启用后，即使两个入口都不可用也停掉本机推断。生产方原子更换导出文件。Tako 只读取，主人的显式纠正保存在既有本机判断流水，按稳定编号及来源的旧编号映射应用。例如「纠正：剪辑项目的状态是暂停」，也可写「更正：project:stable.status = 暂停」。支持名称、状态、下一步、目标、截止时间和位置字段。本机条目可用「合并：旧编号 -> 保留编号」合并同类条目。

其他助手会话与日历、提醒事项的记忆读取另有一次邀请，只有点“好”后才启用；这不同于只在本机比对聊天名的原有权限。会话目前只支持 Codex 与 Claude 的公开 JSONL 消息格式，不读私有数据库、工具输出、密钥或登录文件。系统来源还须已经在系统中授权。正文原地读，判断只留字段和出处。
