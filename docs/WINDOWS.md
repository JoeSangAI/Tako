# Windows 开发预览

此实现保留 Swift/macOS 宿主，在 `windows/` 新增 WPF 原生宿主，继续使用 `Sources/brain` 的对话、配置、任务和数据代码。目前不是与 Mac 功能对齐的正式发行版，也不走 Mac 自动更新。

## 构建与运行

拿到预编译 ZIP 的试用者：将整个压缩包解压到一个文件夹，双击 `Tako.exe`，保留旁边的文件和目录。先观察模型连接面板能否正常打开，再连接自己的账号，把章鱼拖到记事本窗口，试一次读文字和填字。发送动作始终由你完成。反馈请附 Windows 版本、失败步骤和截图，不发送账号密钥或私人对话。只有源码包时才需要执行下面的构建步骤。

需要 Windows 11 x64、.NET 10 SDK，以及 Microsoft Edge WebView2 Runtime。已测试的构建工具为 .NET SDK 10.0.404。运行打包后的程序不需要 .NET SDK 或另装 Python。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build_windows.ps1
.build/windows/Tako.exe
```

构建脚本发布自包含程序，并下载 Python 3.14.10 官方嵌入包；校验固定 SHA-256 后才解压。`-Python` 可指定已有的官方嵌入式 Python 目录。`-Output` 改变输出目录。WebView2 Runtime 缺失时，启动会显示原因；本预览尚未接入自动安装。

首次打开使用原有接模型面板。ChatGPT 入口会下载完整官方 Windows Codex 包，核对 GitHub 提供的 SHA-256，再由用户自行登录。密钥入口沿用原有账户流程。不要把其他人的登录、密钥或数据打入安装包。

数据默认位于 `%LOCALAPPDATA%/Tako`，`TAKO_HOME` 可用于隔离测试。打包内置 Python 使用 UTF-8；原有 Mac 路径保持不变。关闭宿主会关闭 stdin，并用 Windows Job Object 终止所属后台进程。

## 当前边界

已实现原生章鱼窗口、拖到窗口及跟随、Ctrl+Alt+T、WebView2 对话面板、Windows 窗口枚举、UI Automation 读取和后台填字。填入后读回核对，不注入鼠标或键盘，不触发发送。密码字段跳过；系统操作及有后果的按钮要求确认；窗口内容变化或不支持辅助功能时返回明确失败。

窗口工具暂时只返回辅助功能树，没有截图/OCR。画圈、旁听、微信数据库/搜群/文件投递、Office 登录通道、AppleScript 和自动更新未接入。Windows 预览禁用模型 shell、统一命令工具和第三方插件；原生命令审批也拒绝 shell，待 Windows 隔离验收完成再开放。不能把它当成已具备完整文件制作能力的 Mac 版。

## 验证方式

```powershell
$env:TAKO_HOME = "$env:TEMP/Tako-Windows-check"
Tako.exe --self-test "$env:TEMP/Tako-native-check"
Tako.exe --smoke-test "$env:TEMP/Tako-startup-check"
```

`--self-test` 只操作自己创建的窗口，验证读取、填字和发送拦截，生成 JSON 与图片。`--smoke-test` 验证真实后台、WebView2 面板及未授权 HTTP 请求拦截；使用全新数据目录和空的 `CODEX_HOME`，不要继承已配置的模型或账户。两种测试均不要求发起模型请求。

无登录用户的 Windows 会话可能把原生窗口标为不可见；此时窗口测试应报告失败，不能绕过生产环境的可见窗口规则来制造通过。真实桌面拖拽、多显示器和第三方应用仍须在可登录的 Windows 桌面验收。
