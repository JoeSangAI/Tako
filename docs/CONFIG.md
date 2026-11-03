# 高级设置

Tako 不需要任何设置就能用。想让它更懂你，在 `~/Library/Application Support/Tako/` 里放这两个文件，重启 Tako 生效。

## about-me.md

写给 Tako 看的背景：你是谁、在做什么、喜欢怎样的回答。纯文本，最多读前 6000 字。

## config.json

每一项都可选：

```json
{
  "name": "Alex",
  "model": "gpt-6.1-sol",
  "light_model": "gpt-6.1-terra",
  "timezone": "Asia/Shanghai",
  "output_root": "~/Documents/Tako",
  "background_file": "~/Documents/about-me.md",
  "extra_instructions": "回答一律用繁体中文。"
}
```

| 项 | 含义 | 不写时 |
| --- | --- | --- |
| `name` | Tako 怎么称呼你 | 用 Mac 账户名 |
| `model` | 你交代的事用哪个模型 | 跟随你的 Codex 设置 |
| `light_model` | 后台的一次性轻活用哪个模型：开场白、听课笔记、从你改过的草稿里学写法、整理反馈 | 和 `model` 一样 |
| `timezone` | Tako 用的时区：判断“今天”、问候，以及模型跑命令时的时钟 | 这台 Mac 的时区 |
| `clock_note` | 关于时间的补充说明，每轮都会告诉模型 | 无 |
| `output_root` | 做好的文件放哪 | `~/Desktop/Tako` |
| `background_file` | 背景文件的位置 | `about-me.md` |
| `extra_instructions` | 追加给模型的说明 | 无 |
| `keep_codex_log` | 排查问题时设成 `true`：Codex 的完整日志（含窗口截图和文字）留在 `codex-state/`，下次启动清空。查完记得关 | 不留 |

## 可选的本地接入

这几项给已经有对应工具的人，默认关闭，路径不存在就当没配。

| 项 | 接入什么 |
| --- | --- |
| `workbench` | 本地事项工作台：`url`、`cards` |
| `wechat_export` | 兼容 wxexport 的本地微信读取目录，你要自己准备好它，Tako 不提取密钥。接上后你开口时 Tako 能直接读对话记录，不用看截图，还能从你改过的草稿里学写法。来新消息时它不读也不说话 |
| `calls` | 别人怎么称呼你：反馈发给作者之前，这些称呼会被拦下 |
