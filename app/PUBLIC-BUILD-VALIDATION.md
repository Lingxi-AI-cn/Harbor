# Current notarized artifact / 当前公证产物

2026-11-06 · Apple Silicon · **Developer ID 签名及苹果公证已完成；尚未发布，功能验收未关闭。**

## Identity and evidence / 身份与证据

| 对象 | SHA-256 |
|---|---|
| `Harbor-arm64-notarization.dmg`（附加票据后） | `c3282c54dd4736bb3cf973e932a25772ebd758c05e9778766c4d6d3e184cb4a9` |
| 同一 DMG 附加票据前 | `94b03bc3b7716d2c055605cc7ccce9e5e8baf522acee2579540eebe8d3ba8538` |
| 签名前 Harbor 主程序 | `1904c87096820765f30f25da46d8e3078708997c6b093ad4891c0f0b8d507417` |
| 签名前 BundleManifest.json | `c5670a34f5923e767f1b0d35d3c29d1153ccb2bffd964e63d1f75139515d163f` |
| SIGNED-BUNDLE-MANIFEST.json | `3f0e85693ba9fcf518d633ce7de2d87c295fd69fb5d51d8d062c0266fe006a91` |

公证提交 ID：`a4a0ce4b-f2b9-47fb-8eec-37b785539c7b`。用户终端日志显示 `Accepted`，`stapler staple` 和 `stapler validate` 成功。最终文件哈希已另行直接核对；文档更新环境无法挂载映像或重复票据验证，不把日志证据描述为新执行的苹果查询。

签名脚本及构建回执记录了 Developer ID Application 签名、Hardened Runtime、安全时间戳、嵌套代码和 DMG 校验。原 `BUILD-RECEIPT.json` 保留附加票据前状态；公证后对应记录单独保存，不改写历史构建证据。匹配的源码材料及哈希见 [LGPL 重建记录](LGPL-REBUILD.md)。

## Functional acceptance / 功能验收边界

当前公证包使用的是下文“历史声明修复包”的签名前构建，而非 Apple Development 本机测试 DMG 的独立重建版本。哈希已确认该对应关系；不能将不同构建的通过记录迁移到当前包。

该签名前构建曾有自检通过 26 项后失败、外观 33 项中 5 项失败、跨进程偏好保存失败的记录。OpenSSH uid 和 Launch Services 异常可能影响结果，但未证明所有失败均来自环境。仍需在正常桌面会话对最终签名应用复验自检、外观、偏好保存及基本交互。公证不替代功能验收。

DMG 内的 `READ-ME.txt` 仍保留打包时的 “NOT YET NOTARIZED” 字样；该文字已过时，以本节明确标识的产物和公证日志为准。本次文档修正没有修改已公证映像。

Intel、最低 macOS 支持版本、真实远程服务器、物理串口、长期稳定性及跨机器字节可复现仍未完成验收。当前干净源码导出包含后续文档和工具更新，不是原构建快照；对应原始源码随 LGPL 材料包保留。公开源码和正式二进制发行分别验收。

---

以下为原阶段的历史记录。其“本次”“当前”、未公证状态及检查结果仅适用于各节所列哈希，不代表上方最终产物的新结论。

# Historical Apple Development delivery / 历史本机测试交付

2026-11-06 · macOS Apple Silicon · **本机构建、签名和 DMG 校验通过；功能验收与正式发布条件尚未全部完成。**

## Build scope / 构建范围

本次使用审核后的公开源码导出，在独立目录重新编译 Ghostty、FreeRDP/WinPR、桌面 helper 和 Harbor。依赖源码复用此前已验证获取的固定提交及源码包；编译目录为本轮新建，没有复制旧引擎库、helper 或应用二进制。沿用本机工具链、SDK 和 Homebrew 库。因此这是公开源码的独立重新编译，不是新一轮匿名联网获取、操作系统从零重建或跨机器字节可复现证明。

- Ghostty: `83fb95624b0439ee660c2679b43b38c8b63769cd` (1.4.0)
- FreeRDP: `5a10d7b6b79a2fbc62e8eba77085cd356dc303a6` (3.33.0)
- 构建输入的 SOURCE-MANIFEST.json SHA-256: `02dddc6307cc1225f542f3231a11867f7e79358f3a2016424a94c9b02357932e`

该源码清单标识实际构建快照；本次文档更新发生在构建完成后，不修改已构建快照或已签名产物。

## Results / 本轮结果

| 检查 | 结果及适用范围 |
|---|---|
| Ghostty、FreeRDP/helper、Harbor 独立编译 | 通过 |
| 签名前精确包清单 | 151 个负载文件通过 |
| 签名前本机路径扫描 | 33 份元数据/文本及全部负载字节通过 |
| 实际链接组件声明 | 6 个非系统动态库、203 个链接器选中的静态成员通过；静态来源歧义采用保守候选覆盖 |
| 新构建 helper 的本地 RDP/VNC 协议夹具 | 41 项通过；尚未验证真实远程服务器 |
| 嵌套动态库、helper、应用签名 | 用户正常终端中使用 Apple Development 身份完成；非临时 ad-hoc 签名 |
| 应用签名及证书 | deep/strict 校验通过；提取的叶证书指纹与用户指定身份一致 |
| DMG 签名与映像完整性 | 签名校验和 hdiutil verify 通过 |
| DMG 只读挂载复核 | 应用签名、叶证书指纹及全部 154 个签名后应用文件哈希通过，映像随后正常卸载 |
| 交付文件复核 | 实际 DMG、签名前/后清单及源码清单的 SHA-256 与构建记录一致 |

签名及挂载校验结果来自用户终端成功执行的脚本日志和产物回执；文档更新时另行读取文件核对哈希，没有重复签名或重建映像。

## Artifact identity / 产物身份

本机测试文件：`Harbor-arm64-local-test.dmg`。各阶段身份如下，不能混用签名前后哈希：

| 对象 | SHA-256 |
|---|---|
| 签名前 Harbor 主程序 | `64d3b0d81c310ce8f2623853e6c873556ad953d9e54ab2c7ec6eb577b01072e8` |
| 签名前 BundleManifest.json | `dc4779c16af21b3b75f097e66387e54ecc6ed6e886bb2b472cc58f5968c4113b` |
| 签名后 Harbor 主程序 | `74f56e3e28f40158075f4e502d580ddbb3d2bd1eae008bb1cf5459a76c4f059a` |
| SIGNED-BUNDLE-MANIFEST.json | `34aa577d33954195a2aabc91d622687583494fa71aeaefdcf4c497b8215aeb99` |
| 最终 DMG | `91d3e28ffc0d3139236a3a8239bacac86a8613c483b81d9934ec14abd4c40b43` |

签名改变主程序、动态库和签名资源的字节。历史签名前清单保存在应用内 `Contents/Resources/UnsignedBuildEvidence/BundleManifest.json`；签名后的精确清单位于 DMG 内及交付目录的 `SIGNED-BUNDLE-MANIFEST.json`。不要对签名包直接使用仅适用于未签名包的 `verify-bundle.py` 或原先按未签名主程序哈希核验的声明检查入口。

## Remaining boundaries / 未关闭的验收与发布条件

- 本次是 Apple Development 本机测试签名，不是 Developer ID Application 对外分发签名；未公证、未发布、未推送。
- 新签名 DMG 的应用自检、外观、跨进程偏好保存及用户实际启动/交互尚无本轮通过记录。此前另一个包在代理环境中自检通过 26 项后失败，外观 33 项中 5 项失败，跨进程保存失败；保留这些历史结果，但不套用为新包的结果。系统 OpenSSH 的 uid 错误及 Launch Services 异常仍需正常桌面会话复验；未证明所有 UI 失败均来自环境。
- LGPL 对应源码材料及修改后组件替换/重链接验证已完成，见 [LGPL 重建记录](LGPL-REBUILD.md)。材料与当前 DMG 的配套上传仍待发布授权；这不等于对所有第三方组件的完整法律合规结论。
- Intel、最低 macOS 版本、跨机器可复现、真实服务器和物理串口验收仍未完成。

---

# Earlier notice-repair package / 历史声明修复包

2026-11-06 · Apple Silicon · development package · **partial / 尚未全部通过**

This round rebuilt the application with a linker map, packaged the icon and expanded notices, and reused the previously verified Ghostty archive. It is not a new clean public-input engine rebuild. The earlier full-build result below applies only to its recorded executable and source snapshot.

| Check / 检查 | Result for this earlier package / 该历史包结果 |
|---|---|
| Package build and exact manifest | Passed: 152 payload files |
| Local-path scan | Passed: 33 metadata/text files plus all payload bytes |
| Linked dependency notices | Passed: 6 non-system dynamic libraries and 203 selected static archive members; Mach-O load resolution and notice hashes checked |
| Negative notice checks | Passed: missing libusb notice, added unreviewed library, stale executable all rejected |
| Path-leak regressions | Passed: portable identifier accepted, 7 leakage cases rejected |
| Packaged RDP/VNC helper | 41 passed, local fixtures; no real remote credentials |
| Final app self-tests | Incomplete: 26 passed, then OpenSSH configuration check failed |
| Appearance harness rebuilt from current source | 33 assertions, 5 failures; not accepted |
| Cross-process appearance persistence | Failed; not accepted |

The current execution context reports `No user exists for uid 501` from system OpenSSH even with `-G -F /dev/null` (no network connection). Launch Services also fails to open the desktop test launcher (`kLSNoExecutableErr`). Direct-launch UI/persistence failures require a rerun in a normal logged-in desktop session; their cause is not established as exclusively environmental. These failures are retained, not replaced by historical passes.

Earlier package SHA-256:

- Harbor executable: `1904c87096820765f30f25da46d8e3078708997c6b093ad4891c0f0b8d507417`
- Desktop helper: `7c7ceb6ab95637b328a6f961afd7aac48170801fce4c1aebd1905fc2e7155988`
- BundleManifest.json: `c5670a34f5923e767f1b0d35d3c29d1153ccb2bffd964e63d1f75139515d163f`

## Notice coverage and remaining binary-release requirements

libusb COPYING/AUTHORS, FreeType FTL and driver notices, simdutf MIT and embedded notices, MPack/stb notices, and Zig runtime notices are retained. `LinkedComponents.json` binds the evidence to the executable and static archive hashes. Basename matching can yield multiple source candidates; monolithic Zig code retains a conservative set of fetched notices. It is not a function-level SBOM or blanket licensing clearance.

The bundled declaration inventory now has 50 fetched records and 11 unfetched declarations. Unfetched/build-only/platform-specific declarations are not automatically runtime gaps. LGPL corresponding source delivery and rebuild/relink materials for static gettext/libintl and dynamic libusb remain required before binary publication. No Developer ID signing or notarization was performed.

Recheck notices with `python3 scripts/verify-linked-notices.py dist/Harbor.app`; exercise rejection cases with `python3 app/tests/linked-notices/run.py`. Use the full reproduction commands below for the other acceptance checks.

---

# Historical public-source build validation / 历史公开源码构建验证

2026-11-06 · macOS Apple Silicon · local development build

The exported source was built with Ghostty and the embedded desktop helper. Ghostty 1.4.0 and FreeRDP 3.33.0 were fetched from their public HTTPS repositories at the commits in `DEPENDENCIES.json`. Zig packages were fetched by the upstream build and checked against its declared package hashes. No prior Ghostty archive, desktop helper, or application executable was copied into this build.

公开源码已完成 Ghostty、FreeRDP/WinPR 桌面 helper 与 Harbor 应用的完整构建。引擎和桌面源码从公开仓库获取，版本固定且无源码补丁。Zig、Cargo 和 CMake 使用本轮独立目录；沿用机器上已安装的编译器、SDK、OpenSSL 及 libusb，因此不是操作系统或全部依赖的从零重建，也不是跨机器字节可复现验证。

| Check / 检查 | Result / 结果 |
|---|---|
| Ghostty 1.4.0 source build / 引擎源码构建 | Passed / 通过 |
| FreeRDP 3.33.0 + helper + application / 桌面组件与应用 | Passed / 通过 |
| Final app self-checks / 最终应用自检 | 77 passed |
| Native appearance + cross-process preference / 原生外观及跨进程保存 | 33 + 1 passed |
| Packaged RDP/VNC helper, local fixtures / 打包 helper 的本地协议夹具 | 41 passed |
| Exact package file manifest / 精确包文件清单 | 127 payload files passed |
| Metadata/text checks / 元数据与文本检查 | 18 files passed |
| Home/workspace identifiers and Mach-O load paths / 本机路径及动态库加载路径 | Passed / 通过 |
| Path-leak regression / 路径泄露回归 | Portable identifier accepted; 7 leakage cases rejected |

The app executable SHA-256 / 应用主程序 SHA-256:

`86fadc84ed4266a1e25444cde97b37fc4f29563d0b44168d481282aa8f9aa1dd`

## Packaging changes / 打包修复

- Dependency inventories use portable dependency identifiers rather than absolute input paths. Their hashes identify the input libraries; the bundle manifest identifies the relocated/signed payload.
- Mach-O debug maps are stripped from the application executable. Compiler-only `pkgconfig` files are not shipped in runtime resources.
- FreeRDP uses a generic `/usr/local` installation prefix and `DESTDIR` staging. Installation is staged locally, not written into the machine's `/usr/local` tree.
- Packaging rejects detected home/workspace paths across all payload bytes, and applies additional path checks to structured metadata/text before replacing the generated app.

依赖清单不再记录本机绝对路径；主程序移除携带构建路径的调试信息；应用资源不包含开发用 pkg-config 文件。FreeRDP 的安装前缀不再绑定构建目录，实际安装写入临时目录。动态库引用保留系统路径或可重定位路径。系统运行时目录及公开示例路径不等同于构建机身份信息。

## Reproduce / 复现

Use a native arm64 terminal on Apple Silicon, with the README prerequisites installed. A Rosetta-launched build can select x86_64 dependencies and conflict with arm64 Homebrew libraries.

```sh
bash scripts/fetch-dependencies.sh
export ZIG="$(command -v zig)"
bash scripts/build-ghostty.sh
bash app/package-ghostty.sh
python3 scripts/verify-bundle.py dist/Harbor.app
python3 scripts/verify-package-metadata.py dist/Harbor.app
python3 app/tests/package-metadata/run.py
./dist/Harbor.app/Contents/MacOS/Harbor --self-test
bash app/tests/appearance/build.sh
python3 app/tests/appearance/run.py
python3 app/tests/workflows/build-rdp-fixture.py
HARBOR_DESKTOP_HELPER="$PWD/dist/Harbor.app/Contents/MacOS/harbor-desktop-engine" python3 app/tests/workflows/protocol.py
```

Toolchain used: Zig 0.17.0, Swift 6.1.2, Cargo 1.99.1, CMake 4.4.3, macOS 15.5 SDK. Temporary download failures were retried using this run's verified package cache. A translated test launcher initially selected x86_64; its CMake directory was discarded and rebuilt natively for arm64.

本轮涉及网络失败重试；仅复用本轮已下载的包和本轮构建缓存，没有从旧验收目录复制库文件。尚未验证 Intel、其他 macOS 版本、真实远程服务器或物理串口。

The notice inventory contains 48 fetched declaration records and 12 unfetched declarations, including optional/platform-specific dependencies. It is not a linked-component SBOM or licensing clearance. This remains a local development package, with no Developer ID release signing, notarization, GitHub push, or publication.
