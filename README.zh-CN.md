# Harbor

**面向 macOS 的原生终端、远程文件与桌面会话工作区。**

[English](README.md) · [项目状态](app/PROJECT-STATUS.md) · [构建与验证](app/VERIFICATION.md)

Harbor 将本地 Shell、SSH、SFTP、串口、RDP、VNC 和 SSH 隧道整合到 Swift/AppKit 原生应用中。主要终端后端使用 Ghostty，同时提供轻量 Legacy 回退后端。Rust 启动器负责构建并嵌入原生可执行文件。

项目仍处于早期开发阶段，已在 Apple Silicon 上验证本地构建和部分工作流。它尚不能完整替代 MobaXterm，也不保证兼容所有服务器或设备。Harbor 与 MobaXterm、Mobatek 没有关联。

## 功能

- **终端：** 本地 PTY Shell、标签、分屏、滚动历史、搜索、字体和快捷键设置。
- **连接管理：** SSH、多跳、文件夹、收藏、最近会话，以及显式保存和恢复工作区。
- **远程文件：** SFTP 浏览、上传下载、多选、递归传输，以及带冲突检查的 UTF-8 文件编辑。
- **远程桌面：** 内嵌 RDP/VNC、键鼠输入、显式文本剪贴板操作，也可交给外部客户端。
- **设备访问：** 可配置串口，以及本地、远程和 SOCKS SSH 隧道。
- **效率工具：** 命令片段、向选定会话广播输入、会话日志、历史导出、宏录制与回放。
- **迁移：** Harbor JSON、部分 SSH config 配置和部分 MobaXterm 书签；不导入密码库。
- **原生界面：** 英文与简体中文，浅色、深色与自动跟随系统外观。

已实现范围与边界见[功能矩阵](app/PROJECT-STATUS.md)。

## 环境要求

- macOS 和 Xcode Command Line Tools，包含 `xcrun`、Swift、Clang。
- `PATH` 中可用的 Rust/Cargo 与 Python 3。
- 运行应用和界面测试需要正常登录的 macOS 桌面会话。Apple Silicon 上应使用原生 arm64 终端，避免 Rosetta Shell。
- 完整应用还需要 **Zig 0.17.0**、CMake、pkg-config 和 OpenSSL 3。

完整构建脚本当前要求 Homebrew OpenSSL 位于 `/opt/homebrew/opt/openssl@3`。已验证目标为 Apple Silicon，尚未验证完整 Intel 构建路径，也尚未确定最低支持的 macOS 版本。

## 从源码构建

在克隆目录的根目录执行以下命令。构建不需要原 Windows 应用。

### 最小 Legacy 终端

```sh
cargo build --offline --release
./target/release/harbor-terminal
```

此路径不需要 Ghostty 或 FreeRDP 子模块，也不会打包 Ghostty 引擎和内嵌桌面 helper；这些功能需要下方的完整构建。离线构建仍要求编译器等工具已安装。

### 完整 Ghostty 与内嵌桌面应用

初始化固定版本的依赖：

```sh
bash scripts/fetch-dependencies.sh
python3 scripts/verify-ghostty.py
```

安装好所需工具后执行：

```sh
export ZIG="$(command -v zig)"
bash scripts/build-ghostty.sh
mkdir -p checks
bash app/package-ghostty.sh
python3 scripts/verify-bundle.py dist/Harbor.app
python3 scripts/verify-package-metadata.py dist/Harbor.app
open dist/Harbor.app
```

产物为 `dist/Harbor.app`。脚本不会安装 Zig，`ZIG` 必须指向 0.17.0。引擎构建可能下载上游依赖；打包过程会构建 FreeRDP helper、复制其动态库依赖，并收集第三方声明。

Ghostty 固定为未经修改的上游 **1.4.0**。引擎构建会重新生成 `vendor/ghostty-build.json`，其中的本地哈希不代表跨机器字节可复现保证。

## 语言和外观

- **Harbor → 语言：** 跟随系统、English 或简体中文；选择保存后，下次启动生效。
- **Harbor → 外观：** 跟随系统、浅色或深色；立即生效，系统模式自动响应 macOS 外观变化。
- 新终端配置默认跟随界面外观，已有明确保存的独立主题保留。Ghostty 的 **终端引擎 → 终端偏好 → 颜色** 可选择「跟随界面外观」，作用于新终端。

终端输出、用户命名、路径和协议标识不翻译。详见[国际化](app/LOCALIZATION.md)与[外观支持](app/APPEARANCE.md)。

## 验证

```sh
./target/release/harbor-terminal --self-test
python3 scripts/check-localization.py
```

完成完整应用构建后，可在正常 macOS 桌面会话中运行外观检查：

```sh
bash app/tests/appearance/build.sh
python3 app/tests/appearance/run.py
```

较早的本地构建曾通过 33 项外观检查、独立的跨进程偏好保存检查，以及 77 项应用自检。这些历史结果不能作为当前公证产物的验收结论：其对应的签名前构建仍有未关闭的自检、外观及偏好保存结果，需要在正常桌面会话复验。验证范围、产物身份与复现命令见[验证记录](app/VERIFICATION.md)。

生成的应用、日志、截图及 `checks/` 下的验收产物不纳入 Git，也不随源码提供。已从公开源码及新获取的 Ghostty/FreeRDP 依赖完成本地完整构建，见[公开源码构建验证](app/PUBLIC-BUILD-VALIDATION.md)。尚未宣称 GitHub CI 通过、Developer ID 正式发布或跨机器字节可复现。

## 限制与数据处理

- 内嵌桌面不支持音频、磁盘/设备重定向或桌面分屏恢复；VNC 的认证和编码支持有限，见[内嵌桌面说明](app/P3-EMBEDDED-DESKTOP.md)。
- 不包含 X server，X11 工作流需要另外安装 XQuartz 等软件。
- 批量文件传输不具备事务性，失败后可能留下部分上传文件；远程编辑无法消除与其他写入方之间的所有竞态。
- 宏回放按时间发送输入，不判断命令是否执行完成。
- SSH 认证使用系统 OpenSSH。Harbor 不实现密码库，桌面凭据用于对应连接；保存的会话、主动录制的日志、导出和宏仍可能包含敏感信息，分享前需检查。
- 已有 Developer ID 签名、苹果公证及票据附加完成的 DMG，尚未发布；功能验收仍未关闭，见[产物身份与待验证项](app/PUBLIC-BUILD-VALIDATION.md)。

## 参与贡献

较大改动请先与维护者讨论范围。保持修改集中，并提供相关构建或测试结果。不要提交真实凭据、私有会话导出、原专有软件二进制或生成的依赖/构建目录。

翻译文案位于 `app/Resources/zh-Hans.json`，修改后运行 `python3 scripts/generate-localization.py` 并一并提交生成词库。修改集成代码前，请阅读[应用文档](app/README.md)与[第三方致谢](app/CREDITS.md)。

## 许可证

Harbor 使用 [MIT 许可证](LICENSE)。Copyright (c) 2026 Lingxi-AI。

Ghostty 使用 MIT，FreeRDP/WinPR 使用 Apache-2.0；打包的字体、库和其他依赖保留各自许可证。详见[第三方致谢](app/CREDITS.md)及生成的第三方声明。

当前公证 DMG 对应的 LGPL 源码材料与替换／重链接验证已完成，见 [LGPL 重建记录](app/LGPL-REBUILD.md)；发布二进制时须一并提供匹配材料。

使用 Developer ID 签名并生成公证候选 DMG，见[公证打包说明](app/NOTARIZATION.md)。
