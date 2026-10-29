# 首次 macOS 编译检查点

本文保留源码检查点与 Mac 手动构建流程。2026-10-29 已在 `ios/first-native-build / bd145cd` 完成首次编译及用户安装，IPA/日志位于本地 `docs/ios-builds/2026-10-29/`；健康与完整真机验收尚未通过。首次包为 `1.0.0 / 1`，当前本地修复源码为 `1.0.1 / 2`，尚未原生编译，后续不自动构建。PWA 业务基线仍为 `f26a175 / 2026-10-18.1 / kcal-v17`。下述源码检查点不能作为 IPA 安装；main 混合工作树仍保留。

## Windows 生成独立源码材料

在仓库根执行：

```powershell
node _tools/test-ios-packaging.js
node _tools/test-ios.js
node _tools/test-ios-checkpoint.js
node _tools/prepare-ios-checkpoint.js
```

第二条需要 Playwright 与 Chrome，沿用交接中的 `NODE_PATH`。第三条验证复制完整性、篡改检测与工作流禁用保护；最后一条只读固定文件清单，生成 `native-ios/build/checkpoint-<源码摘要>-<随机后缀>/`，每次生成新目录，不覆盖旧材料。目录含 Swift、桥接、构建脚本、共用页面、公开文档及虚构备份，`ios-checkpoint.json` 记录实际 HEAD、分支、PWA 版本和逐文件 SHA-256。它不包含 `.git/`、预览草案、真实数据、签名凭据、生成的 Web/Xcode 工程或可执行的 `.github/workflows/`；CI 模板仍只在 `native-ios/ci/`。

复制**整个检查点目录**到 macOS，命令都在该目录根运行。校验同时拒绝额外源码（包括 App 下的新 Swift 文件），只允许已知 Web/工程/build 输出和生成图标。校验失败则重新复制或生成材料，不略过校验继续编译。在该目录编辑源码后原校验必然失效；修复应带回主工作树审阅、验证并生成新的检查点，以便辨认编译的具体版本。

## macOS 环境与编译

需要完整 Xcode 26+、设备/模拟器 SDK 26+、已安装的 iOS 26+ iPhone 模拟器运行时、Node 和 XcodeGen；仅有 Command Line Tools 不够。安装工具、首次 Xcode 许可与组件准备由 Mac 使用者操作，不需要提供 Apple ID 或开发团队。已有工具时：

```bash
node _tools/prepare-ios-checkpoint.js --verify
bash native-ios/scripts/preflight.sh
bash native-ios/scripts/build-unsigned.sh
```

预检只检查工具、SDK、plist 和检查点校验，不安装依赖、不签 Apple 身份、不联网。若缺 XcodeGen，可由 Mac 使用者执行 `brew install xcodegen`；如需多个 Xcode，先由使用者选择正确 Developer 目录再重跑预检。Shell 文件固定 LF，复制后用 `bash` 调用，无需依赖可执行位。

每次构建写入独立 `native-ios/build/runs/<UTC时间>-<进程号>/`：

| 路径 | 用途 |
| --- | --- |
| `build.log` | 含预检、工程生成、Xcode 和打包输出；失败也保留 |
| `Build.xcresult/` | Xcode 构建结果；仅在进入相应编译阶段后存在 |
| `artifacts/KcalAnalysis-unprovisioned.ipa` | 成功编译后的未配置 Apple 身份安装材料 |
| `artifacts/requested-entitlements.plist` | ad-hoc 签名实际携带的 HealthKit 声明 |
| `artifacts/BUILD-INFO.txt`、`SHA256SUMS.txt` | 工具版本、构建身份及产物校验 |
| `artifacts/ios-checkpoint.json` | 若从检查点构建，保留该材料的源文件摘要 |

脚本先在新建空白 iPhone 模拟器运行 hosted XCTest，再编译设备包；模拟器结果位于 `native-ios/build/simulator-runs/<时间-进程>/`，含 `test.log`、`Tests.xcresult`（含截图）、`test-summary.json` 与运行时选择证据，结束只清理本轮新建模拟器。设备阶段检查 Bundle ID、版本/构建号、健康读取说明、隐私清单、Web 清单/字节及 ad-hoc HealthKit 声明。只有测试通过、脚本 exit 0 且本次目录含完整材料才记录成功。失败中间文件不能作为 IPA；Windows 检查不等于 Swift 编译成功。

没有 Mac 时停在源码检查点。后续需要云编译，仍须用户明确授权提交/上传及启用；不要把本检查点复制到 `.github/workflows/`，也不要自动推 `ios-build-*` 标签。未启用模板保留失败诊断制品 1 天，规则参见 [构建与迁移说明](README.md)。

## 首轮安装只用虚构备份

`fixtures/synthetic-backup-v7.json` 是固定虚构数据，覆盖 2026-10-03 至 2026-10-05：3 天饮食、2 天体重、3 天能量/训练/睡眠，其中 10 月 4 日有两次训练；目标为 2100 kcal。文件经过现有完整备份恢复及重开/再导出各类别一致检查，不来自手机或个人记录。不要把它放入 Web 资源；通过系统文件选择恢复，测试迁移的真实入口。

安装与 HealthKit 能力仍按 [README](README.md) 用本人账号验证。先逐项完成：

1. 空库启动、全页面、连续手填及取消；同步存储 prompt 首屏可用，保存后重开/断网保留。自定义 `kcalapp` 来源及桥接请求在真实 WKWebView 可用；失败不放宽来源判断。
2. 恢复虚构备份时取消不保存、确认整批保存；核对上述日期/数量/两次训练，导出到“文件”，再恢复及重开。实际看到文件才记落盘成功。
3. 由用户选择是否进行 HealthKit 试读；核对权限拒绝/无返回保留、预览取消、确认单次保存、重复不累加、手动冲突保护，以及实际存在的运动/睡眠来源与日期。未测到的类型标未实测。
4. 同一 Apple ID 与最终 Bundle ID 覆盖升级及跨七天续签；先导出备份，不卸载，核对记录与健康读取仍在。

这些通过后才请求最终迁移确认。真实数据继续留在在用 PWA，届时再导出最新完整备份；本阶段不迁移、不删除、不自动双向同步。
