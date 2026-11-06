# Chrome Consent

Chrome Consent 是一个 macOS 菜单栏工具，用于自动处理 Google Chrome 的远程调试授权。它在后台识别授权对话框并点击“允许”，适合需要频繁连接本机 Chrome 的浏览器自动化与开发调试工作流。

**当前版本：1.0.1**

[发布说明](RELEASE.md) · [本地构建](#构建与发布)

## 功能

- **自动授权**：识别 Chrome 中英文远程调试对话框，完成按钮操作并确认授权结果。
- **锁屏处理**：通过一次性认证临时解锁系统会话，配合桌面保护层完成授权，再恢复原生锁屏。
- **菜单栏入口**：单色盾牌勾选图标适配系统深浅外观，点击打开操作菜单，悬停显示应用全名。
- **状态与统计**：主界面展示监测状态、最近处理结果和累计成功次数，设置与结果随重启保留。
- **登录启动**：通过菜单配置登录后自动启动，便于持续使用。
- **安装与维护**：内置安装、权限引导、更新和卸载流程，统一管理应用及配套系统组件。

## 快速开始

### 运行环境

| 项目 | 要求 |
| --- | --- |
| 设备 | Apple Silicon Mac |
| 系统 | macOS 14.4 或更新版本 |
| 浏览器 | Google 官方签名的 Chrome 稳定版 |
| 连接准备 | Chrome 已启用远程调试，供本机调试工具连接 |

### 安装

1. 在项目根目录执行 `bash build.sh`，打开生成的 `build/Chrome Consent.app`。
2. 在安装引导中选择“安装并继续”，完成系统管理员授权。
3. 安装完成后，应用自动从 `/Applications/Chrome Consent.app` 重新启动。
4. 按权限引导开启“辅助功能”和“屏幕录制”。可以将引导中的应用图标拖入对应权限列表；已有条目直接开启开关。
5. 完成系统要求的重新打开操作后，应用开始监测。随后从调试工具发起 Chrome 连接，即可触发自动授权。

### 权限用途

| 权限 | 用途 |
| --- | --- |
| 管理员授权 | 安装、更新和卸载应用、认证插件及系统授权配置 |
| 辅助功能 | 识别原生控件、操作授权按钮，以及执行锁屏流程中的界面操作 |
| 屏幕录制 | 获取窗口信息，为锁屏处理准备保护画面 |

## 日常使用

点击菜单栏中的盾牌勾选图标打开菜单。关闭主窗口后，应用继续驻留菜单栏。

| 操作 | 说明 |
| --- | --- |
| 打开 Chrome Consent | 查看监测状态、最近结果与累计成功次数 |
| 开始／暂停监测 | 切换自动授权开关，下次启动恢复上次状态 |
| 登录后自动启动 | 配置系统登录项，首次使用时默认关闭 |
| 查看日志 | 打开应用日志目录 |
| 关于 Chrome Consent | 查看应用版本与功能简介 |
| 卸载 Chrome Consent… | 打开卸载引导，选择用户数据的保留方式 |
| 退出 | 结束当前处理后退出；锁屏流程先完成会话恢复 |

## 工作流程

### 桌面解锁时

调试工具发起连接后，应用识别 Chrome 授权窗口，通过辅助功能点击“允许”，确认对话框消失，再记录处理结果。桌面保持解锁状态，调试工具继续使用建立的连接。

### 桌面锁屏时

1. 检测 Chrome 授权窗口，唤醒显示器并准备系统登录控件。
2. 为各显示器准备保护层，同时启动输入监测和独立恢复进程。
3. 认证插件批准一次性许可，临时解锁当前系统会话。
4. 完成 Chrome 授权，确认对话框消失后恢复原生锁屏。
5. 确认锁屏恢复，记录本次结果并更新成功次数。

保护层显示应用接管与恢复提示，画面优先采用系统登录窗口截图，并根据可用性使用桌面壁纸。锁屏阶段由 `Guardian` 协调，`Watchdog` 负责恢复；检测到键鼠操作或运行条件变化时，流程转入恢复锁屏阶段。

## 项目结构

```text
chrome-consent/
├── src/             应用与认证组件源码
├── build.sh         编译与签名入口
├── package.py       发布归档与内容检查
├── installer.py     系统组件安装、更新和卸载脚本
├── build/           本地生成的应用
├── outputs/         本地生成的发布包与校验文件
├── RELEASE.md       安装说明与发布结论
└── README.md
```

| 模块 | 职责 |
| --- | --- |
| `App.swift`、`Permissions.swift` | 菜单栏、主界面、权限引导与应用生命周期 |
| `Core.swift` | Chrome 身份校验、授权窗口识别、按钮操作与一次性许可 |
| `Guardian.swift`、`LoginScreen.swift`、`LockShield.swift` | 锁屏流程、登录控件准备、保护层及恢复进程 |
| `Bridge.m`、`AuthorizationPlugin.m` | 系统会话接口、进程身份校验、通信与认证插件 |
| `RunState.swift`、`ProcessLease.swift` | 运行状态、结果统计与进程互斥 |
| `main.swift`、`icon.swift` | 程序入口、诊断与预览命令、应用图标生成 |

## 构建与发布

构建需要 Xcode Command Line Tools 和 Python 3。以下命令在项目根目录执行。

### 构建应用

```sh
bash build.sh
```

默认产物为 `build/Chrome Consent.app`。构建脚本完成应用与认证插件的编译、本地 ad-hoc 签名和签名校验，并在结束后清理中间文件。源码位置由脚本目录确定，编译器将本地构建路径映射为通用路径。

可以通过目录参数指定产物位置：

```sh
bash build.sh ./build-custom
```

### 生成发布包

```sh
python3 package.py
```

默认生成 `outputs/Chrome-Consent-1.0.1.zip` 和对应的 `.sha256` 校验文件。归档内容为应用与安装说明，使用统一时间戳和标准权限。打包脚本检查用户目录、当前账户名称及归档元数据，文件内容通过 SHA-256 核对。

应用路径和发布目录支持命令行指定：

```sh
python3 package.py --app "build-custom/Chrome Consent.app" --output ./outputs
```

### 安装预检

```sh
/usr/bin/python3 -I installer.py install \
  --source "build/Chrome Consent.app" --uid "$(id -u)" --dry-run
```

安装预检根据当前用户和系统组件状态输出本次安装或升级计划。应用通过系统接口获取用户目录与 UID，安装器通过系统账户查询取得用户信息。

### 运行诊断

诊断命令以 JSON 格式输出当前环境与控件状态：

```sh
"build/Chrome Consent.app/Contents/MacOS/ChromeConsent" --diagnose
"build/Chrome Consent.app/Contents/MacOS/ChromeConsent" --login-diagnose
"build/Chrome Consent.app/Contents/MacOS/ChromeConsent" --dialog-diagnose
```

三个命令分别检查应用安装与权限、系统登录控件、Chrome 授权对话框。对话框诊断中的 `scanFailures` 提供辅助功能属性读取、遍历深度、节点数量及超时信息，便于定位识别问题。

## 维护

### 安装与数据位置

| 内容 | 位置 |
| --- | --- |
| 应用 | `/Applications/Chrome Consent.app` |
| 认证插件 | `/Library/Security/SecurityAgentPlugins/ChromeConsentAuthorizationPlugin.bundle` |
| 系统配置与恢复脚本 | `/Library/Application Support/ChromeConsent/` |
| 运行日志 | `~/Library/Logs/ChromeConsent/events.jsonl` |

系统授权分支名称为 `local.chromeconsent.unlock`。运行日志按时间记录窗口识别、认证、按钮操作、恢复锁屏及处理结果，可通过菜单中的“查看日志”打开。

### 更新与卸载

更新时打开新版应用，按安装引导完成升级。应用先结束当前处理流程，安装器随后备份旧版、校验新文件并替换应用及组件，保留用户设置、统计和日志。

卸载时从菜单选择“卸载 Chrome Consent…”。默认保留用户数据，勾选“同时清除设置、统计和日志”可一并清理。卸载流程负责移除应用、登录启动项、认证插件和对应授权分支。

命令行卸载使用随应用安装的恢复脚本。先退出应用并完成当前锁屏恢复，再在解锁桌面执行：

```sh
sudo /usr/bin/python3 -I "/Library/Application Support/ChromeConsent/installer.py" uninstall
```
