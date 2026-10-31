# SwiftUI 原生界面迁移 · 1.1.0（3）

2026-10-30。用户已确认整个 iOS App 页面迁移到 SwiftUI。此前 1.0.1（2）真机反馈：DeepSeek 已能唤醒，健康按钮闪一下但从未出现系统权限页，日期输入框重叠，底栏效果仍不满意。

## 当前实现与证据

当前为本地待编译源码，不是已验证可安装的新 IPA。1.0.1（2）的成功构建不能作为本次原生重写的编译证据。

| 范围 | 实现 |
| --- | --- |
| App 根界面 | `UIHostingController` 承载 SwiftUI `TabView`，两项系统标签栏、各自 `NavigationStack`；不覆盖系统栏材质 |
| 饮食 | 共享日期、目标与营养进度、分餐、DeepSeek 提问词/唤醒、回答解析预览、手动录入、编辑、克数换算、移动/删除、历史统计 |
| 健康 | 原生概览、14 天能量图表与明细、体重全部/周/月/年真实日期曲线、训练编辑、睡眠分期与手动记录 |
| 健康同步 | 原生 Form、独立日期行、检查/授权/读取/预览/保存状态，显示实际 NSError 域与错误码，超时和迟到回调保护，确认后一次保存 |
| 设置与文件 | 原生设置表单、JSON 文件选择/预览/合并或覆盖、完整备份与原始恢复文件、CSV 导出 |
| 存储 | 沿用 App Support/KcalAnalysis/snapshot.json，原子写入及 CAS；只读浏览不改快照；保存失败不发布新内存状态 |
| 计算兼容 | Swift `NativeDomain` 调用系统 JavaScriptCore 的本地纯函数。算法从既有 PWA 确定边界提取，保留 v1–v7 恢复、健康归并和能量口径；无 DOM、WebView、网络或 JavaScript 文件 I/O |

所有可见页面、交互、文件操作和 HealthKit 调用使用 SwiftUI/Swift。旧 WebViewController/NativeBridge/NativeTabBar 和桥接源码保留供历史追溯，已从 1.1 的编译源中排除，旧 WKWebView 测试亦从当前 scheme 排除。设备包只含生成的 `domain.js` 算法资源，不打包 HTML/CSS/Web 目录、虚构 fixture 或真实快照。这里不把“全部页面原生化”描述为“所有既有算法都已改写为 Swift”。

## Apple 文档与设计取舍

已阅读 Apple 当前 [Liquid Glass 采用指南](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)、[SwiftUI TabView](https://developer.apple.com/documentation/swiftui/tabview)、[DatePicker](https://developer.apple.com/documentation/swiftui/datepicker)、[HealthKit 授权](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data)，并参考用户提供的 [Apple 设计资源](https://developer.apple.com/cn/design/resources/)。设计资源首页持续更新，不能把最新套件版本当作 iOS 26 API 的兼容性证明；构建仍要求 Xcode 26+，当前模板选择 Xcode 26.3。

系统 TabView 自动采用 iOS 26 的导航材质和交互；`.glassEffect` 加到自制按钮组上不会自动变成系统标签栏。本次移除自定义浮动胶囊，保留文字标签与系统安全区。内容表单使用实色系统分组；字体使用系统动态字型，图标使用 SF Symbols，避免定高文本、并排日期压缩、额外模糊层和自制透明度。

UI/UX Pro Max 从本地已校验归档恢复所需文件（原源提交 `50d8a7de0900119855614541f15a1a616691eb33`）。已读取 SKILL.md、quick-reference.md、pro-rules.md，执行 `personal health tracker native --design-system`、`health dashboard minimal --design-system`、`form validation date picker --stack swiftui`、`error persistent feedback --domain ux` 和 `navigation tabs accessibility --stack swiftui`。两次整站模式偏宣传网站，未采用其页面结构、外部字体与全局玻璃；具体 Form、触控、就近错误与辅助功能建议符合本项目并采用。Apple 系统控件指导和用户偏好优先。

## 健康问题的诊断边界

`isHealthDataAvailable` 仅说明设备支持健康数据；`getRequestStatusForAuthorization` 仅预测是否还需询问；`requestAuthorization` 成功仅表示授权流程完成。这些接口都不能证明每项读取已获授权。空结果不清空旧记录，也不直接显示“拒绝权限”。

目前未取得用户手机的真实错误码，不能断言根因已经证明是签名或免费账号。新流程直接在原生界面发起 HealthKit，并保留各阶段及实际错误域/码。检查用途说明、可用性和授权请求状态；不调用私有 entitlement API，不把包内声明误当作重签后的授权。最终签名及描述文件是否允许 HealthKit，仍以重签包和手机实际系统响应为准。

## 验证与交付门槛

2026-10-30 本地收尾：原生业务接口 16 项契约/兼容场景通过；原有能量、基础存储、导航、健康日汇总/样本/能量边界、体重、离线 8 组回归通过。源包检查识别 13 个活动 Swift 文件，旧 WebView 文件不参与编译；正式 PWA 与 `f26a175` 无差异。

已准备 59 个原生测试方法：NativeDomain 11、健康手动/自动流程及日期布局 23、健康页面 8、外链 14、真实系统控件 XCUITest 3。预期生成 20 个截图附件，覆盖 5 个健康页面、同步日期布局、两栏导航及手动保存。2026-10-30 第二轮已通过 Swift 编译，原有 58 个测试中两个界面案例失败；其余通过。2026-10-31 已根据实际结果修正大字号日期宽度及屏幕外按钮定位，新增原生滚轮选择器的宽度/绑定测试；最终通过状态须以新构建结果为准。

标准字号使用分行的原生紧凑 DatePicker；辅助大字号使用可换行日期按钮，并打开全宽原生滚轮选择器，避免 UIKit 紧凑控件固有宽度超过 320 pt，不缩小全局字号。失败构建也导出原生截图，便于在交付 IPA 前检查布局。

第三轮 `49a9034 / run41160378602` 实际通过 58/59 项；日期宽度和选择绑定均通过，唯一失败是大字号 UI 测试的弹层仍收到普通字号。截图与控件日志确认其实际使用紧凑 DatePicker。DEBUG 测试改从 scene 设置 `preferredContentSizeCategory`，让所有弹层与 UIKit 控件继承最大字号，保留滚轮断言并明确要求日期按钮分支；正式版本仍完全采用用户的系统字号。依据 [Apple UIKit trait 传播说明](https://developer.apple.com/videos/play/wwdc2023/10057/)（iOS 17+，兼容本项目最低版本）。

原来的 `kcal.native.autoSync` 与睡眠来源偏好保留。明确启用后，前台空闲页面最多每分钟读取最近 7 天；编辑、弹层或退到后台时使旧结果失效，不自动弹授权页，保存前重新检查手动记录冲突及磁盘 CAS。测试启动使用独立虚构快照并禁用持久偏好，避免测试触发真实健康读取。

完整快照磁盘上限仍为 32 MiB。导入文件的 96 MiB 限制和调用时约 96 MiB 的合并传输限制分别检查；转义内容、当前快照与请求头也占传输空间。超限显示原因并保留原数据，不裁剪历史；大文件可先仅压缩 JSON 空白再重试。

Windows 执行：

```powershell
node _tools/test-native-domain.js
node _tools/test-native-project.js
node _tools/test-ios-checkpoint.js
```

旧 PWA 的能量、基础存储、导航、健康日汇总/样本/边界、体重和离线回归均需保持通过。正式 `index.html`、`app.css`、`navigation.js`、`sw.js`、manifest 和 icons 与 `f26a175` 保持一致。

macOS 构建门槛：真实 JavaScriptCore/临时文件的 XCTest、健康异步状态及日期布局测试、全部健康页原生截图、系统 TabView 和手动录入的 XCUITest；通过后才编译设备 Release 和 IPA。截图需覆盖 320/393 宽度、深浅色、最大动态字体；Windows 源码检查不能代替这些结果。

用户已另行明确授权本轮：仅上传 iOS 改动到独立分支，以显式标签触发免费标准 macOS 运行器，修复必要编译/测试问题，核对截图后下载新版 IPA。该授权覆盖本轮迭代，不扩展为后续自动构建或发布。main、在用 PWA、既有整理内容、真实数据和 Apple 账号保持独立。
