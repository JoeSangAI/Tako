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

独立使用时，Tako 在空闲且有新对话记录后，用无工具的临时线程整理主体和项目。判断追加到运行目录的 `ontology.jsonl`（0600），由内置本体引擎回放。旧 `judgments.jsonl` 的主体、项目、旧编号和读取进度首次启用时自动迁移，原流水保留。待办仍从对话里的托付记录读取。每个新条目按名字分配编号，重名加后缀。模型拿到最多 2,000 字的当前索引，细节按出处回查。

`ontology_source` 默认关闭。配置 `url` 后，Tako 从本机环回地址读取 `GET /api/ontology`。可选的 `snapshot` 指向生产方维护的导出文件，服务暂时不可用时回读。只接快照时可省略 `url`。

```json
{"ontology_source": {"enabled": true, "url": "http://127.0.0.1:8799", "snapshot": "~/Shared/ontology.json"}}
```

接口与快照共用 `schema_version: 1`、`items` 和可选的 `redirects`。条目包含 `id`、`kind`、`name` 和来源提供的字段及出处。原有的 `workbench.ontology` 配置也可继续使用。设 `enabled: false` 可切回独立模式。启用外部来源后，Tako 读取生产方的数据，停用自己的日志和推断。

主人可以说「纠正：剪辑项目的状态是暂停」，也可以用「更正：project:stable.status = 暂停」。同名条目可用反引号标出完整编号。支持名称、状态、下一步、目标、截止时间、位置、别名和错听。别名或错听可用顿号列出多个，写 `[]` 可清空。改名后旧名称编号仍可用，「合并：旧编号 -> 保留编号」可合并同类条目。独立模式把纠正写入本机引擎日志。外部模式将引擎格式的 owner 记录 POST 到同一环回接口，收到 200、201 或 204 才显示「记下了」。来源服务需实现该写入接口并在提交后确认。仅有 GET 的服务和文件快照仍可查阅。

其他助手会话与日历、提醒事项的记忆读取另有一次邀请，只有点“好”后才启用；这不同于只在本机比对聊天名的原有权限。会话目前只支持 Codex 与 Claude 的公开 JSONL 消息格式，不读私有数据库、工具输出、密钥或登录文件。系统来源还须已经在系统中授权。正文原地读，判断保留字段、出处和作为依据的摘录。
