# LGPL 对应源码与重建验证

2026-11-06 · 目标公开仓库：`Lingxi-AI-cn/Harbor` · 本地准备完成，尚未上传。

本页记录对应二进制的材料身份，不表示附件已经公开可下载。当前 Git 源码导出包含后续文档及打包工具更新；对应原始构建源码仍保存在 LGPL 包的 `harbor/` 快照中。

## 对应版本

| 文件 | SHA-256 |
|---|---|
| `Harbor-arm64-notarization.dmg` | `c3282c54dd4736bb3cf973e932a25772ebd758c05e9778766c4d6d3e184cb4a9` |
| `Harbor-lgpl-source-notarized-20261106.tar.gz` | `d755f13874191794cff93f3a67a42329e37f88d14ae5d1903a8843516c7d14ff` |

源码材料包包含实际构建的原始 130 文件 Harbor 导出、固定提交的 Ghostty/FreeRDP 公开源码 Git 包及浅克隆边界、27 个 Ghostty 依赖源码目录（包含 gettext 0.24）、libusb 1.0.30 官方完整源码、Homebrew 构建配方、原始许可声明、可执行重建/替换工具和验证摘要。不是只提供上游链接，也不包含 Harbor 私有维护历史或开发者私钥。

## 公证后记录更新

配套附件为上表中的 DMG、LGPL 源码材料包及两者的 `SHA256SUMS`。最终 DMG 哈希已直接核对；Accepted 及 stapler 成功状态取自用户提供的终端日志。新源码包的 `evidence/NOTARIZED-ARTIFACT.json` 保存最终对应关系。

原始源码归档、原本机测试 DMG、旧校验清单及历史验证证据均保留。签名交付目录中的 `BUILD-RECEIPT.json` 保留附加票据前的构建状态，原清单另存为 `SHA256SUMS.pre-staple`；公证后状态单独记录于 `POST-NOTARIZATION.json`。

公证 DMG 的签名前应用与旧本机测试 DMG 属于不同构建。当前构建的 50 个文件输入已与源码材料逐项匹配，helper 二进制输入与打包前的 vendor 构建输出匹配。以下替换/重链接测试仍是历史构建证据，本次没有在最终签名产物上重跑，也未完成新增功能验收。

## 历史构建实际验证

- **libusb 动态替换**：官方源码包哈希与已安装版本配方一致。修改版本描述、重新编译并替换测试副本的动态库；运行时返回修改标记，dyld 确认 helper 加载该替换库，RDP/VNC 本地协议 41 项通过。测试副本从与原 DMG 154 个文件逐字节一致的已安装应用复制而来，进行 ad-hoc 签名并通过 deep/strict 校验；没有使用原开发者私钥。
- **gettext/libintl 静态重链接**：在新工作区恢复源码，创建可编辑的本地 gettext 依赖，加入专用测试键的返回标记；重新编译 Ghostty、FreeRDP/helper 和 Harbor。实际调用修改后的 libintl 函数获得标记，最终 Harbor 可执行文件中保留标记及函数符号。重建包 151 个负载文件、33 份元数据/文本、6 个动态库和 203 个静态成员声明检查通过；另建副本做 ad-hoc 签名并通过 deep/strict 校验。
- **源码恢复**：归档解压后校验 156 个材料文件哈希，使用归档内的恢复工具重新恢复依赖；原始源码快照与上游固定提交验证通过。
- **原交付不变**：测试修改仅存在于独立副本，原签名 DMG SHA-256 保持不变。

源码快照保持原样。`tools/local-dependency-notices.patch` 是重建时应用的工具补丁，只修正声明收集器对本地依赖来源的识别；修改的 gettext 内容另有日期说明和补丁记录。原始哈希命名包及共享缓存未修改。

## 如何使用

解压源码材料包，遵循其中 README：`prepare.py` 恢复源码，`enable-gettext-override.py` 创建可编辑 libintl，`rebuild.sh` 完整重建；`build-libusb.py` 和 `replace-libusb.py` 用于动态库替换；`sign-local-copy.py` 用于自己重建的本地应用签名。工具不会安装软件、修改系统安全设置或索取原开发者私钥。

构建前提仍为原生 arm64 macOS、Apple SDK/编译工具、Zig 0.17.0、Rust/Cargo、CMake、pkg-config、make，以及现行构建要求的 Homebrew 依赖。本轮证明可修改和重建，不宣称复现 Homebrew bottle 的完全相同字节，也不替代完整 GUI/真实服务器验收。

## 发布配套要求

取得发布授权后，在**同一个 Release**提供匹配的 DMG、源码材料 `.tar.gz`、`SHA256SUMS`，并指向材料包内 README。GitHub 自动生成的顶层源码 ZIP 不包含所需子模块和 Zig 包，不能替代此配套材料。未来改变依赖、产物或签名策略时需重新评估并更新材料。

LGPL 源码材料及替换/重链接工程验证已完成，实际共同上传尚未执行。Developer ID Application 分发签名及苹果公证已完成；完整功能验收仍是独立事项；本文件不作对所有第三方组件的整体法律合规保证。
