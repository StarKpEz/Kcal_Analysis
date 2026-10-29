# iOS App 构建、安装与迁移

本目录将现有饮食与健康页面放入本机 iOS App，并增加原生 HealthKit 读取、文件导入/导出及本机备份。PWA 正在日常使用，App 另行开发；两端数据、构建和发布分开。网页源码是共享界面的来源，平台适配放在本目录；共用源码变更仍须分别评估两端影响。它是 Swift 原生容器内运行本地网页的 App，不是把所有页面重写为 SwiftUI，也不依赖 Expo Go。

当前交付包含源码和构建流程。Windows 上的检查不能验证 Swift 编译、iPhone 安装、HealthKit 授权或七天续签；这些都需要后续云端构建及真机验收。没有现成已签名安装包，也没有替用户开通付费服务。

## 目录与本地检查

| 文件 | 职责 |
| --- | --- |
| `project.yml` | XcodeGen 工程配置，iPhone / iOS 17 及以上；Swift，无第三方原生依赖 |
| `App/` | 原生容器、HealthKit、文件与持久化桥接、权限说明 |
| `Web/` | `_tools/build-ios.js` 生成的本地页面及资源，不手改、不提交 |
| `bridge/` | 生成时使用的 App 平台适配和同步入口源码 |
| `scripts/build-unsigned.sh` | macOS 上生成工程、编译设备版本、打包安装材料 |
| `scripts/preflight.sh`、[首次 Mac 编译检查点](FIRST-MAC-BUILD.md) | 工具/SDK 预检、源码校验、编译证据与首轮虚构数据验收 |
| `fixtures/synthetic-backup-v7.json` | 固定虚构完整备份；开发/首轮安装使用，不嵌入 App |
| `ci/ios-unsigned.yml` | 未启用的 GitHub Actions 手动构建模板 |

在项目根目录用 Windows 的 Node 生成页面：

```powershell
node _tools/build-ios.js
node _tools/test-ios-packaging.js
node _tools/test-ios.js
node _tools/test-ios-checkpoint.js
node _tools/prepare-ios-checkpoint.js
```

构建不读取手机数据，也不把 PWA 的 localStorage 或备份嵌入 App。App 专属界面变更修改桥接源文件；共用界面变更才评估正式源码，并分别验证两端，再重新生成 `Web/`。原生版本为 `1.0.0` / build `1`，独立于 PWA 资源版本；既有液态玻璃设计预览不会自动替换正式界面。

打包检查不需要 Chrome，验证精确白名单、残留文件排除及失败保留；生成器在完整临时树准备成功后替换 Web。`test-ios.js` 需要 Playwright 与 Chrome，使用固定虚构备份和模拟原生桥，不访问手机。检查点工具生成可单独复制到 Mac 的白名单源码目录，记录逐文件 SHA-256，不创建 Git 分支或提交。详见 [首次 Mac 编译检查点](FIRST-MAC-BUILD.md)。App 紧凑快照上限32MB，原生文件导入/分享上限96MB以容纳完整备份和原始恢复文件；App正常完整备份导出为紧凑JSON以保证往返。健康JSON的5MB校验单独保留。超限或保存失败不裁剪历史、不覆盖已有快照。

## Windows 的零费用安装路线

1. 在 Windows 完成代码与页面检查；由标准 macOS 云端运行器执行 Xcode 编译。
2. 下载 `KcalAnalysis-unprovisioned.ipa` 及同一构建的签名说明。它没有 Apple 签名身份或描述文件，不能直接点开安装。构建末尾的 ad-hoc 签名只保留请求 HealthKit 的能力元数据，不授予任何权限。
3. 在 Windows 从 [Sideloadly 官网](https://sideloadly.io/) 安装工具，按官方说明准备 iTunes/iCloud 驱动及 USB 连接。Apple ID、密码和验证码只在你自己的签名工具中输入，不发到聊天、源码或 GitHub Secrets。
4. 用自己的免费 Apple ID 重签并安装。免费账号有七天有效期及设备/App 数量限制，见 [Apple 账号说明](https://developer.apple.com/help/account/basics/about-your-developer-account/)。在手机按系统提示开启开发者模式、信任开发者；菜单以实际 iOS 显示为准。
5. 固定本次使用的 Apple ID 和最终 Bundle ID。默认源码 ID 为 `com.starkpez.kcalanalysis`；如果签名工具首次调整了它，记录调整后的最终值，后续安装和续签保持一致。不要每次生成随机 ID。
6. 打开 App，先用虚构记录和测试备份验证离线页面、保存与恢复；再验证健康授权、读取及续签保留。App 完成真机验收后，由用户确认最终迁移，期间日常记录仍写在 PWA。

Apple 的 [能力表](https://developer.apple.com/help/account/reference/supported-capabilities-ios/) 列出了 HealthKit 的账号支持。**账号具备能力不等于任意重签工具都会正确保留能力。** 最终 App 签名及描述文件都必须允许 `com.apple.developer.healthkit = true`；CI 提供的 `KcalAnalysis.entitlements` 和 `requested-entitlements.plist` 只是声明。无 Apple 账号的云构建不能代签名工具完成这一步。

若能安装但 HealthKit 报能力/授权错误，先核对重签工具是否移除了 HealthKit，及生成的描述文件是否允许它；不要用卸载 App 排障，不要把读取不到当作零值。Sideloadly 官方文档没有保证本项目的 HealthKit 重签链路已经成功，仍需真机验证。如果当前工具无法保留所需能力，应保留现有 PWA 和 App 内手动/JSON 导入，继续排查签名流程，不能声称健康直读已可用。

## 启用云编译前的最后步骤

模板当前位于 `native-ios/ci/`，GitHub 不会执行它。授权上传并启用后，才将它复制到仓库根的 `.github/workflows/ios-unsigned.yml` 并上传相应代码；本轮不自动提交、推送、发布或触发运行。

首次可将代码上传到独立分支，在需要构建的提交上明确创建并推送一个 `ios-build-*` 标签触发编译；普通分支 push、PR 或定时任务都不会启动构建。这允许保留当前 main 与网页发布不变，也不会创建 GitHub Release。

如果将来模板经审阅进入默认分支，还可以在 GitHub 的 **Actions → Build iOS installation package (manual) → Run workflow** 手动构建指定分支。GitHub 的 `workflow_dispatch` 要求工作流先存在于默认分支，因此只上传新分支后不能直接假定会出现 Run workflow 按钮；首次使用上面的显式构建标签。见 [GitHub 触发规则](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_dispatch)。

流程只读检出源码，用 macOS 15 标准运行器和系统 Xcode，安装 XcodeGen，不用 Apple 账号、证书、描述文件、付费构建服务或签名密钥。

构建产物保留 **1 天**；及时下载并保留 IPA 和校验值。七天续签通常复用同一安装包，不需要每七天云编译。公开仓库的标准托管运行器可免费使用；私有仓库有账户配额，制品存储另有免费限制。保持无付费预算，不启用大型运行器，并在实际启用时核对 [GitHub Actions 计费说明](https://docs.github.com/en/billing/concepts/product-billing/github-actions)。

有 macOS + Xcode 环境时，也可在仓库根执行：

```bash
brew install xcodegen
bash native-ios/scripts/preflight.sh
bash native-ios/scripts/build-unsigned.sh
```

脚本检查权限 plist、生成 `KcalAnalysis.xcodeproj`、用 `iphoneos` SDK 编译 Release，并逐文件核对 Web 打包结果、App 版本和权限声明。每次输出独立位于 `native-ios/build/runs/<UTC时间>-<进程号>/`，包含 `build.log`、编译阶段生成的 `Build.xcresult` 与成功后的 `artifacts/`，失败不会复用旧 IPA。编译检查仍不能代替签名后真机运行；无 Apple 描述文件时，`codesign --verify` 只验证 ad-hoc 文件结构。

## 首次从 PWA 迁移

**以下步骤仅在 App 开发与真机验收完成、用户确认迁移后执行。** 开发阶段先用虚构记录和测试备份验证，不把真实完整历史提前搬入 App。HealthKit 真机读取测试也须由用户操作并核对，不能把模拟桥测试当作已授权或已验收。

App 与 Safari/PWA 属于不同沙箱，**不会自动共享记录**。PWA 本身继续保留；不要清除网页数据、删除主屏幕入口或卸载旧版本来迁移。

1. 在目前实际使用的 PWA 中导出 **完整备份**，确认 JSON 已保存到「文件」。同时保留一份在你控制的本地位置；不把真实记录上传到 GitHub。
2. 在已验收 App 的设置恢复入口选择这份最新完整备份。先核对 App 内测试记录，按恢复预览选择合适的覆盖/合并方式再确认；不要把健康 JSON 导入当成完整备份恢复。
3. 核对几天饮食、体重历史、训练、睡眠、消耗和设置；关闭后重新打开，断网重开，再导出一份 App 完整备份确认可落盘。
4. 数据核对后，进入健康同步入口，检查已验收的读取权限，选择读取范围并检查预览后保存。HealthKit 是读取来源，已有应用记录继续由原保存入口处理。
5. 对照「健康/健身」App 检查实际存在的多次训练、步行/HIIT/游泳、能量及睡眠；缺少的类型标为未实测。权限拒绝、无可见记录与真正零值不可混为一谈；无返回的类别保留现有记录。用户核对完成后再将 App 作为日常记录端，保留 PWA 和原备份。

饮食数据、手动补充及设置不会来自 HealthKit；它们依靠完整备份迁移。开始日期归档训练，实际运动时长优先于起止差值；训练热量用于展示，不再次加入“活动 + 静息”总消耗。未记录坡度或训练部位时，App 不能自动推断爬坡、胸背腿等内容。

## 续签、升级与保留数据

[Sideloadly FAQ](https://sideloadly.io/faq.html) 说明免费账号有效期、同 Apple ID/Bundle ID 覆盖安装，以及电脑可通过 USB 或已配置的 Wi-Fi 为设备自动刷新。是否能自动完成取决于电脑和手机的连接状态；不要把它当成不需要电脑的永久安装。

固定使用相同 Apple ID 和最终 Bundle ID 覆盖安装/续签；**不要先卸载**，否则本机沙箱和未导出的记录可能丢失。更新前导出完整备份。续签后需要实测页面数据仍在、HealthKit 仍可读取；遇到过期打不开时先恢复原身份的签名，不以更换 ID 或删除 App 绕过。

PWA 与 App 后续各自保存，编辑一边不会自动写到另一边。需要搬回网页时，用 App 完整备份在网页恢复，并先检查恢复预览；当前没有云同步或双向自动合并。

## 首轮真机验收

| 环节 | 验收点 |
| --- | --- |
| 编译 | macOS 工作流成功；设备 App 含本地 Web；没有用户数据和凭据进入产物 |
| 安装 | Windows 免费重签后可安装，签名/Profile 均保留 HealthKit，拒绝权限时能安全返回 |
| 数据 | 先用虚构完整 v7 备份恢复、重启及断网保留、再次导出并恢复；真实 PWA 历史留待 App 验收后迁移 |
| 健康 | 授权读取、预览取消不保存、确认保存、缺失保留、重复同步不累加 |
| 续签 | 使用相同 Apple ID/Bundle ID 覆盖后，记录、权限和读取能力仍正常 |

只有完成这些实机检查，才能把“源码已迁移”升级为“手机上可长期使用”。
