# 自己编译 Tako

```bash
git clone https://github.com/JoeSangAI/Tako.git
```

```bash
cd Tako && ./run.sh
```

`run.sh` 编译后装到 `/Applications/Tako.app` 并重启它。需要 Xcode Command Line Tools。

## 签名决定权限能不能留住

macOS 的「辅助功能」和「录屏与系统录音」不是按名字认 Tako，而是按签名里的“指定要求”（designated requirement）认。

- **用证书签名**：只要证书不换，每次重新编译出来的都是同一个 Tako，开过的开关一直有效。
- **没有证书（ad hoc 签名）**：系统按这一次编译的字节认，每编一次就是一个新应用。列表里那个开着的开关属于上一次编译的 Tako，对这一次不算数，所以会出现“开关明明开着，Tako 还说没授权”（[Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements/)）。

`scripts/build_app.sh` 会自动用钥匙串里的 Apple Development 证书。没有的话，编译时会提示 `ad-hoc build`。这时 Tako 自己能处理大半：发现记录是别的编译留下的，就清掉自己那一条，你在列表里再打开一次开关就好，录屏开好后它会在没事做时自己重开。但每次重新编译都要再开一次。

### 不想每次都重开：做一张免费的签名证书

一次性操作，不需要 Apple 开发者账号：

1. 打开「钥匙串访问」，菜单 钥匙串访问 › 证书助理 › 创建证书。
2. 名称填 `Tako Local`，身份类型选「自签名根证书」，证书类型选「代码签名」，创建。
3. 在「登录」钥匙串里双击这张证书，展开「信任」，把「代码签名」设为「始终信任」，关窗口时输入一次密码。（不设这一步，`codesign` 会说找不到这个身份。）
4. 以后都这样编译：

```bash
TAKO_SIGN_IDENTITY="Tako Local" ./run.sh
```

第一次换成这张证书时，签名变了，Tako 会清掉旧记录，你把两个开关各打开一次。之后再编译就不用了。

自己编译的版本收不到一键更新：更新只装签名和正在运行的这个一致的新版本。

## 开关开着，Tako 还说没授权：怎么排查

看 `~/Library/Application Support/Tako/panel.log`，每次启动都会重写：

| 日志里的一行 | 意思 |
|---|---|
| `signing=adhoc` / `signing=certificate` | 这个 Tako 是 ad hoc 编译的，还是用证书签的 |
| `screen capture trusted=false ... record=stale` | 列表里的记录是别的编译留下的，下一行应该是 `screen capture repair cleared=true`，在列表里再开一次就好 |
| `screen capture trusted=false ... record=current` | 记录是这个 Tako 自己的，开关确实没开（或开在了别的应用上，比如终端） |
| `screen capture fresh process=yes` | 开关已经开了，只是正在运行的进程要重开才能用上；没事做时它会自己重开 |
| `relaunching for screen recording` | 它自己重开了 |

面板上的卡片也按这三种情况说：确实没开、开好了还差重开、签名变了要再开一次。

不要从终端跑 `Tako --can-capture` 来判断：从终端启动的进程，系统按终端自己的录屏权限回答，终端有权限就会说 `yes`，跟 Tako 有没有无关。日志里的 `fresh process=` 才是 Tako 自己问到的答案。

还卡着的话，在列表里选中 Tako 点「−」删掉，再打开 Tako，它会重新出现在列表里，打开开关即可。
