# iOS App 构建、安装与迁移

当前本地源码为 **SwiftUI 全部页面的 iOS 1.1.0（3）**：系统标签栏、饮食与健康页面、授权同步、设置和文件导入导出均由 SwiftUI/Swift 实现。Swift 通过系统 JavaScriptCore 复用既有纯业务算法，保留完整备份/导入口径；不在 WebView 中展示页面。PWA 正在日常使用，两端数据、构建和发布分开。详见 [本轮迁移](SWIFTUI-MIGRATION.md)。

**1.1 本地源码尚待本轮授权后的 Xcode 编译和模拟器验收；下述 1.0.x 构建记录是历史证据。** 用户已确认 DeepSeek 唤醒成功，但健康仍未出现系统权限页；不能宣称真机 HealthKit 问题已验证解决。原 Web 容器源码保留作历史参照，并已从 1.1 编译源排除。

2026-10-29 首包 `1.0.0/1` 已由用户安装；修正版 `1.0.1/2` 已在独立分支 `ios/first-native-build / e5061ac` 通过 Xcode 26.3 编译、24 项原生测试并打包，[成功记录](https://github.com/StarKpEz/Kcal_Analysis/actions/runs/40883670412)。新版 IPA、校验、测试结果及三张模拟器截图位于本地忽略目录 `docs/ios-builds/2026-10-29/build-2/`。Sideloadly 已安装，新版仍由用户以同一 Apple ID/最终 Bundle ID 覆盖签名安装；HealthKit 真机读取及续签保留待验收。没有付费服务、Computer Use 或真实数据迁移。

## 目录与本地检查

| 文件 | 职责 |
| --- | --- |
| `project.yml` | XcodeGen 工程配置，iPhone / iOS 17 及以上；Swift，无第三方原生依赖 |
| `App/` | SwiftUI 页面、HealthKit、原子快照、文件操作、权限说明；旧 Web 容器源排除编译 |
| `domain/` | 无 DOM 的离线业务算法；domain.js 与 manifest.json 由工具生成，不提交 |
| `Web/`、`bridge/` | 保留的 1.0.x 网页容器及其生成资源，不参与 1.1 打包 |
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

上组 Web 检查针对保留的 1.0.x 容器。1.1 活动源码执行：

```powershell
node _tools/build-native-domain.js
node _tools/test-native-domain.js
node _tools/test-native-project.js
node _tools/test-ios-checkpoint.js
```

`scripts/prepare-project.sh` 生成 `domain.js` 并运行算法回归；新 scheme 运行 NativeDomain、健康流程/原生页面、DeepSeek 单元测试和 SwiftUI XCUITest。通过模拟器门槛后，设备包校验只允许离线算法 JS，不包含 Web UI 或测试记录。以下 1.0.x 的资源数量与版本号不适用于 1.1。

构建不读取手机数据，也不把 PWA 的 localStorage 或备份嵌入 App。App 专属界面修改 `App/` 中的 SwiftUI 源文件；纯业务适配修改 `domain/adapter.js`，再生成算法资源。共用算法变更才修改正式网页源码，并分别验证两端。当前源码为 `1.1.0` / build `3`，独立于 PWA 资源版本。

## 首次安装后的修复（2026-10-29，已编译，待真机验收）

用户已安装首包，反馈健康同步按钮完全无变化。当前本地修复包含：

- DeepSeek：默认用官方关联域名 `https://applink.deepseek.com/`，通过 `universalLinksOnly` 请求已安装 App；失败再尝试其官方网页客户端使用的 `dpsk://chat/new`，最后打开网页。有效自定义链接仍优先，旧默认网页设置也使用 App 优先。Scheme 是实现证据，不承诺长期稳定；不传递照片、健康记录或登录凭据。
- 健康：启动握手、8 秒连接超时；按钮立即展示检查/授权/读取阶段，存储异常或冲突显示原因。保留主框架、文档 URL、WebView 身份及 securityOrigin 校验。空结果和错误保留旧记录，预览确认后一次保存。手机问题的最终原因仍待真实 WKWebView 与重签后的设备验证。
- 底栏：仅 App 使用 `UIHostingController` 承载 SwiftUI `.glassEffect(.regular.interactive(), in: Capsule())`；iOS 26+ 使用真实材质，旧系统/减少透明度实色回退。网页路由确认后才替换 HTML 底栏；弹窗/键盘/加载期间隐藏，实际高度用于内容和提示避让。握手失败恢复 HTML 并关闭原生栏，迟到消息不能重开。PWA 底栏不变。

2026-10-29 重新读取 Apple 当前文档：[glassEffect](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:))（iOS 26+）、[健康授权](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data)、[Universal Links only](https://developer.apple.com/documentation/uikit/uiapplication/openexternalurloptionskey/universallinksonly)。DeepSeek 关联证据见其 [AASA](https://applink.deepseek.com/.well-known/apple-app-site-association)。授权流程完成不表示获准读取；没有样本也不能推断没有历史记录。

本地 Chrome 整页回归覆盖空库、授权等待、存储保护反馈、消息失败/超时、取消、整批保存、备份、路由/弹窗及窄屏/深浅色/文字放大。Xcode 26.3 / SDK 26.2 在新建 iPhone 16 / iOS 26.2 模拟器通过 24 项 XCTest（14 项外链、10 项真实 WKWebView 集成），健康和外链使用虚构替身。三张原生截图已检查窄屏、深色及最大辅助字体下布局。设备 Release 编译、16 项 Web 清单/字节、版本、arm64、ZIP CRC、产物摘要及 HealthKit 声明均通过；不等于免费重签后的真实健康读取已通过。

新版要求完整 Xcode 26+。CI 固定标准 `macos-15` 的 Xcode 26.3；设备打包前必须通过新建空白 iPhone 模拟器 XCTest，保留日志、截图附件和 `.xcresult`。后续上传/触发仍需明确授权，手机安装与 HealthKit 核对由用户完成。

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

模板仍保留在 `native-ios/ci/`。本次经用户明确授权，已仅在 `ios/first-native-build` 分支创建 `.github/workflows/ios-unsigned.yml` 并用显式标签触发构建；当前检出的 `main` 未增加活动工作流，PWA 源码与版本不变。后续不因首次授权而自动推送、定期编译或发布。

首次可将代码上传到独立分支，在需要构建的提交上明确创建并推送一个 `ios-build-*` 标签触发编译；普通分支 push、PR 或定时任务都不会启动构建。这允许保留当前 main 与网页发布不变，也不会创建 GitHub Release。

如果将来模板经审阅进入默认分支，还可以在 GitHub 的 **Actions → Build iOS installation package (manual) → Run workflow** 手动构建指定分支。GitHub 的 `workflow_dispatch` 要求工作流先存在于默认分支，因此只上传新分支后不能直接假定会出现 Run workflow 按钮；首次使用上面的显式构建标签。见 [GitHub 触发规则](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_dispatch)。

流程只读检出源码，用 macOS 15 标准运行器和指定 Xcode 26.3，安装 XcodeGen，不用 Apple 账号、证书、描述文件、付费构建服务或签名密钥。

构建产物保留 **1 天**；及时下载并保留 IPA 和校验值。七天续签通常复用同一安装包，不需要每七天云编译。公开仓库的标准托管运行器可免费使用；私有仓库有账户配额，制品存储另有免费限制。保持无付费预算，不启用大型运行器，并在实际启用时核对 [GitHub Actions 计费说明](https://docs.github.com/en/billing/concepts/product-billing/github-actions)。

有 macOS + Xcode 环境时，也可在仓库根执行：

```bash
brew install xcodegen
bash native-ios/scripts/preflight.sh
bash native-ios/scripts/build-unsigned.sh
```

脚本检查权限 plist、生成 `KcalAnalysis.xcodeproj`，通过原生模拟器测试后用 `iphoneos` SDK 编译 Release，并核对纯算法资源、App 版本和权限声明，拒绝 Web 页面与测试数据进入包。每次输出独立位于 `native-ios/build/runs/<UTC时间>-<进程号>/`，包含 `build.log`、编译阶段生成的 `Build.xcresult` 与成功后的 `artifacts/`，失败不会复用旧 IPA。编译检查仍不能代替签名后真机运行；无 Apple 描述文件时，`codesign --verify` 只验证 ad-hoc 文件结构。

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
