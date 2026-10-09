# Kcal Analysis 统一设计规范 · 预览草案 A

日期：2026-10-09。状态：供用户审阅，尚未应用到正式 `index.html`。

## 产品与技术边界

面向 iPhone 日常使用的个人饮食与综合健康记录工具。沿用 HTML、CSS、JavaScript 和现有数据模型、路由、计算口径。通过统一样式整理页面，不更换框架，不引入字体服务、图表依赖、GSAP 或 UI 组件库。

优先级：用户明确偏好 > 项目既有行为与数据保护 > Apple HIG 中适用的建议 > UI UX Pro Max 的检索建议。根据最新用户要求，仅浮动底部导航采用接近 Liquid Glass 的网页视觉效果；内容卡片、顶部导航、表单和设置继续使用实色，不添加夸张渐变、拟物浮雕、装饰性动画或导航图标的圆灰底。

## 视觉方向

内容优先、系统字体、清晰分组、适度紧凑。关键数字突出，辅助单位与来源退到第二层；同类组件使用相同间距、圆角与字号。饮食与健康共用设计语言，颜色表达数据类别，不为每个页面重新换主题。

| 项目 | 规范 |
|---|---|
| 字体 | `-apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif`，不加载外部字体 |
| 页面标题 | 30px / 1.2，700；窄屏与文字放大时允许换行 |
| 分区标题 | 20px / 1.3，600 |
| 正文与输入 | 16px / 1.5；输入字号至少16px |
| 次要说明 | 13–14px / 1.55；避免大段说明占据首屏 |
| 主数字 | 36–40px，700；数字采用等宽数码，单位14–16px |
| 间距 | 4 / 8 / 12 / 16 / 24 / 32px；组件内16px，分区间24px |
| 页边距 | 手机16px，较宽设备24px，内容最大640px |
| 圆角 | 卡片18px、输入与分段控件10px；不为小图标加圆底 |
| 图标 | 沿用本项目SVG，统一22–24px、1.8px线宽；系统控件不使用emoji |
| 可操作区域 | 本项目手机网页主动采用至少44×44 CSS px；这是产品选择，不把CSS px称为原生pt或完整WCAG合规证明 |

## 语义颜色

| 角色 | 浅色 | 深色 |
|---|---|---|
| 页面 | `#F2F2F7` | `#000000` |
| 卡片 | `#FFFFFF` | `#1C1C1E` |
| 内层输入与分组 | `#F6F6FA` | `#2C2C2E` |
| 主文本 | `#17171B` | `#FFFFFF` |
| 次要文本 | `#636366` | `#AEAEB2` |
| 操作/焦点蓝 | `#0062CC` | `#64A8FF` |
| 图表与体重绿 | `#248A3D` | `#30D158` |
| 活动能量橙 | `#A95700` | `#FFB45B` |
| 脂肪/营养黄 | `#916A00` | `#FFD60A` |
| 危险操作 | `#C62828` | `#FF6961` |

浅色绿色略加深以改善细线与文字对比度；颜色角色与现有页面一致。主保存按钮统一蓝色配白字，次要按钮使用轻背景和蓝字。数量、状态、警告同时包含文字，不仅靠颜色区分。

## 页面与组件

### 饮食

摄入热量为主卡，保留目标与进度；餐次用分组行和无底色添加按钮。营养圆环与图例保留，减少重复视觉标记。拍照/粘贴的原有工作流保留，预览不跳转外部服务。

### 健康概览

能量与体重各为完整宽度卡片；训练与睡眠并排成两张紧凑卡片。320px下及文字放大时可恢复单列。单位、记录日期、来源保持可读。导入入口是明确的辅助操作。

### 体重

默认全部历史，保留周/月/年与前后切换、区间统计。继续使用绿色空心圆点折线、真实日期间隔和现有SVG。保留点选、键盘可操作滑块与完整记录明细；缺失日期不补值，不加入预测曲线。一次记录时不虚构区间变化。

### 训练与睡眠

先展示当天摘要，再展示记录/编辑表单。输入分组明确，数值与单位对齐。睡眠保留核心、深度、REM与缺失分期说明，不用清醒/卧床代替实际睡眠。计算与数据说明按需展开，不隐藏当前记录的状态或必要错误信息。

### 设置与导航

底部仍只有饮食/健康两个栏目，参考用户提供的苹果标签栏采用居中浮动胶囊。外层最大宽288px、左右至少16px、距底部安全区12px；内层栏目触摸高度56px，图标24px配12px文字标签。选中项使用内层胶囊底色与蓝色图标/文字，并保留 `aria-current`，不依赖颜色单独传达选中状态。

用户后续明确要求更通透且有切换回弹：先阅读苹果Materials、Color、Motion以及WWDC25《Meet Liquid Glass》，再调整底栏。原先78%/84%的底色和28px模糊压住了背景颜色，现改为浅色18%白色、深色24%深灰、10px模糊与180%饱和度，加薄边缘高光和阴影。玻璃透出的是正下方的内容颜色；白色卡片经过时自然仍以白色为主，不人为添加彩色装饰背景。前景文字、图标不施加模糊，使用局部光晕辅助分离。透明效果在绿色/青色/紫色色带上的渲染已人工检查。

选中项为单独的移动透镜，保留背景透色而非厚蓝底。`preview/navigation.js` 监听现有选中语义，用Web Animations让透镜滑到新栏目，轻微拉伸后回弹；选中图标短暂上弹4px再落回。透镜约420ms、图标约320ms，这些是本项目调试参数，不是苹果官方指定数值。路由立即响应，动画可被后续点击中断并从当前位置继续，不让用户等待动画结束。底栏和触摸区域保持固定；无持续循环跳动、无第二层背景模糊、无模拟折射滤镜。此处是CSS与JS视觉适配，不宣称等同苹果原生动态材质。

无背景模糊支持时使用原有实色胶囊；浏览器报告 `prefers-reduced-transparency: reduce`、`prefers-contrast: more` 或强制颜色时关闭通透和高光，恢复实色。网页能否获得对应系统偏好取决于浏览器支持，不宣称覆盖所有iOS设置。

页面与健康详情预留104px加底部安全区，确保滚动到末尾的内容可位于浮动栏上方；提示消息显示在导航上方。栏目顺序、路由、返回和记忆上次健康子页的行为保持不变。返回、设置、关闭仍使用无底色图标与完整触摸区域。设置沿用独立页面和分组列表，不增加重复大标题或装饰图标。

## 反馈与适配

- 常规按压改变透明度或背景，不移动周围内容；浮动底栏仅内部透镜与选中图标允许短暂弹性形变。
- 常规微交互用120ms透明度/颜色变化，底栏透镜使用短暂滑动/回弹；`prefers-reduced-motion`时取消Web Animations并立即对齐选中项，CSS也关闭非必要动画。
- 焦点可见，返回与取消保留，表单有可见标签；触摸不能依赖hover。
- 375px、393px、320px与横屏检查布局；文字放大检查换行与内容可达。
- 普通正文与次要文本对比度目标4.5:1；大文字与有意义的非文本图形目标3:1。需要在实际页面组合上测量，不由调色表直接宣称全面合规。

## 独立预览与正式应用

预览入口：`preview/index.html`。复制页面：`preview/app.html`，由 `_tools/build-design-preview.js` 从正式页生成。

预览装在不授予同源权限的沙箱iframe中，只使用虚构演示数据与内存存储。刷新重置演示修改，不读取正式记录、不注册Service Worker、不提供添加到主屏幕的manifest。预览主题位于独立 `preview/theme.css`，可切换当前样式/新样式对照；正式HTML、CSS、JS与正式SW不修改。

每次未来应用正式样式前：更新预览 → 核对各页面与数据行为 → 用户审阅后再合并正式页。预览应联网打开；本阶段不交付预览的离线安装能力。

### 本轮验收

Chrome 独立浏览器上下文已检查 320×740、375×812、393×852 与 852×393 横屏，另检查 393×852 深色模式。饮食、健康、体重、能量、训练、睡眠、设置、导入入口均能切换；页面无横向溢出，样式比较正常。完成体重滑块键盘操作及健康/睡眠/设置 130% 文字尺寸模拟（并非 iOS Dynamic Type 真机结论）。

浮动导航补充验收：两项真实点击切换及选中语义正常，触摸区域超过44px；小屏左右边距和底部间距已检查；健康页最后的导入操作、体重页底部保存按钮均可滚动到导航上方。检查背景模糊只用于外层底栏、内容层与栏目自身无背景模糊，以及增加对比度时关闭模糊。检查滑动动画实际运行、连续快速点击后正确落位、减少动态效果时无运行的弹性动画；深浅色彩色色带用于检验透色，测试色带不进入产品页面。复制页、主题及导航脚本使用内容版本参数，刷新预览即可取得新效果，无需修改正式缓存或清理正式数据。

用虚构存储标记验证：预览内保存能量不会改变同站点正式存储；沙箱无法访问同源 localStorage；重置后演示修改消失。生成过程比较 SHA-256 确认正式 `index.html` 与 `sw.js` 未改变。脚本语法和复制页中无持久存储/SW调用已检查。iPhone Safari 真机效果仍由用户审阅，原有系统顶部模糊问题不在本轮修改范围内。

## 来源、检索与人工取舍

使用 [UI UX Pro Max](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill)，源提交 `50d8a7de0900119855614541f15a1a616691eb33`。本地工具位于 `.design-tools/ui-ux-pro-max/`，不作为网页依赖发布。检索不包含用户实际健康数据。

已执行：

1. `health tracker mobile minimal --design-system --density 6 --variance 2`：简洁、统一层级建议可用；宣传站结构与外部衬线字体不适用。
2. 缩小为 `health analytics dashboard --design-system`：仍推荐企业宣传入口，布局匹配不合适；没有把它保存成项目方案。本文的应用布局为按用户需求与现有页面人工制定，不能称为工具自动匹配成功。
3. `touch target size --domain ux`：命中移动端触摸目标与Web目标尺寸，明确区分原生单位与CSS像素。
4. `weight trend time series --domain chart`：命中Trend Over Time与折线图，采用真实时间轴、明细和键盘查看建议；不照搬推荐图库或强制按点数隐藏现有单点记录。
5. `safe area bottom navigation --domain web`：命中Safe Area Insets与Bottom Tabs；将建议转换为CSS安全区，保留现有两栏导航，不照搬React Native组件。
6. `bottom navigation selected state --domain ux`：命中Active State与Deep Linking；采用选中背景、清晰标签及现有hash路由。浮动外观参考用户截图，功能与信息组织参考苹果官方Tab bars。
7. `glass navigation readability --domain ux`未命中针对玻璃的可读性指导；缩小为 `text contrast transparency --domain ux` 命中Contrast Readability与Color Contrast，只采用其一般文字对比度建议。具体材质与导航层边界依据[苹果Materials](https://developer.apple.com/design/human-interface-guidelines/materials)：只在导航层使用玻璃，克制效果并优先保证文字可读性；用户最新要求覆盖此前全局避免玻璃的偏好，仅开放浮动底栏。
8. `spring animation reduced motion --domain ux`命中Reduced Motion与Excessive Motion：仅移动透镜和选中图标使用弹性反馈，减少动态效果时关闭。深入官方阅读与本项目取舍见[液态玻璃阅读记录](liquid-glass-notes.md)。

苹果官方参考：[Layout](https://developer.apple.com/design/human-interface-guidelines/layout)、[Typography](https://developer.apple.com/design/human-interface-guidelines/typography)、[Color](https://developer.apple.com/design/human-interface-guidelines/color)、[Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)、[Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars)、[Charts](https://developer.apple.com/design/human-interface-guidelines/charts)。本项目是网页对相关原则的适配，不宣称原生组件外观完全等同。
