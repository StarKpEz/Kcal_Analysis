# Kcal Analysis 统一设计规范 · 预览草案 A

日期：2026-10-09。状态：供用户审阅，尚未应用到正式 `index.html`。

## 产品与技术边界

面向 iPhone 日常使用的个人饮食与综合健康记录工具。沿用 HTML、CSS、JavaScript 和现有数据模型、路由、计算口径。通过统一样式整理页面，不更换框架，不引入字体服务、图表依赖、GSAP 或 UI 组件库。

优先级：用户明确偏好 > 项目既有行为与数据保护 > Apple HIG 中适用的建议 > UI UX Pro Max 的检索建议。暂不使用 Liquid Glass、玻璃卡片、夸张渐变、拟物浮雕、装饰性动画或导航图标的圆灰底。

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

底部仍只有饮食/健康两个栏目，参考用户提供的苹果标签栏改为居中浮动胶囊，透明度为100%。外层最大宽288px、左右至少16px、距底部安全区12px；内层栏目触摸高度56px，图标24px配12px文字标签。选中项使用内层胶囊底色与蓝色图标/文字，并保留 `aria-current`，不依赖颜色单独传达选中状态。浅色为白色外层、淡蓝选中项；深色为深灰外层、更深的选中项。不添加玻璃模糊、折射或新的导航栏目。

页面与健康详情预留104px加底部安全区，确保滚动到末尾的内容可位于浮动栏上方；提示消息显示在导航上方。栏目顺序、路由、返回和记忆上次健康子页的行为保持不变。返回、设置、关闭仍使用无底色图标与完整触摸区域。设置沿用独立页面和分组列表，不增加重复大标题或装饰图标。

## 反馈与适配

- 按压改变透明度或背景，不缩放整个组件、不移动周围内容。
- 微交互用120ms透明度/颜色变化，`prefers-reduced-motion`时关闭非必要动画。
- 焦点可见，返回与取消保留，表单有可见标签；触摸不能依赖hover。
- 375px、393px、320px与横屏检查布局；文字放大检查换行与内容可达。
- 普通正文与次要文本对比度目标4.5:1；大文字与有意义的非文本图形目标3:1。需要在实际页面组合上测量，不由调色表直接宣称全面合规。

## 独立预览与正式应用

预览入口：`preview/index.html`。复制页面：`preview/app.html`，由 `_tools/build-design-preview.js` 从正式页生成。

预览装在不授予同源权限的沙箱iframe中，只使用虚构演示数据与内存存储。刷新重置演示修改，不读取正式记录、不注册Service Worker、不提供添加到主屏幕的manifest。预览主题位于独立 `preview/theme.css`，可切换当前样式/新样式对照；正式HTML、CSS、JS与正式SW不修改。

每次未来应用正式样式前：更新预览 → 核对各页面与数据行为 → 用户审阅后再合并正式页。预览应联网打开；本阶段不交付预览的离线安装能力。

### 本轮验收

Chrome 独立浏览器上下文已检查 320×740、375×812、393×852 与 852×393 横屏，另检查 393×852 深色模式。饮食、健康、体重、能量、训练、睡眠、设置、导入入口均能切换；页面无横向溢出，样式比较正常。完成体重滑块键盘操作及健康/睡眠/设置 130% 文字尺寸模拟（并非 iOS Dynamic Type 真机结论）。

浮动导航补充验收：两项真实点击切换及选中语义正常，触摸区域超过44px；小屏左右边距、底部间距与不透明表面已检查；健康页最后的导入操作、体重页底部保存按钮均可滚动到导航上方。复制页和主题资源使用内容版本参数，刷新预览即可取得新样式，无需修改正式缓存或清理正式数据。

用虚构存储标记验证：预览内保存能量不会改变同站点正式存储；沙箱无法访问同源 localStorage；重置后演示修改消失。生成过程比较 SHA-256 确认正式 `index.html` 与 `sw.js` 未改变。脚本语法和复制页中无持久存储/SW调用已检查。iPhone Safari 真机效果仍由用户审阅，原有系统顶部模糊问题不在本轮修改范围内。

## 来源、检索与人工取舍

使用 [UI UX Pro Max](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill)，源提交 `50d8a7de0900119855614541f15a1a616691eb33`。本地工具位于 `.design-tools/ui-ux-pro-max/`，不作为网页依赖发布。检索不包含用户实际健康数据。

已执行：

1. `health tracker mobile minimal --design-system --density 6 --variance 2`：简洁、统一层级建议可用；宣传站结构与外部衬线字体不适用。
2. 缩小为 `health analytics dashboard --design-system`：仍推荐企业宣传入口，布局匹配不合适；没有把它保存成项目方案。本文的应用布局为按用户需求与现有页面人工制定，不能称为工具自动匹配成功。
3. `touch target size --domain ux`：命中移动端触摸目标与Web目标尺寸，明确区分原生单位与CSS像素。
4. `weight trend time series --domain chart`：命中Trend Over Time与折线图，采用真实时间轴、明细和键盘查看建议；不照搬推荐图库或强制按点数隐藏现有单点记录。
5. `safe area bottom navigation --domain web`：命中Safe Area Insets与Bottom Tabs；将建议转换为CSS安全区，保留现有两栏导航，不照搬React Native组件。
6. `bottom navigation selected state --domain ux`：命中Active State与Deep Linking；采用选中背景、清晰标签及现有hash路由。浮动外观参考用户截图，功能与信息组织参考苹果官方Tab bars；最新官方材料样式中的Liquid Glass因用户偏好未采用。

苹果官方参考：[Layout](https://developer.apple.com/design/human-interface-guidelines/layout)、[Typography](https://developer.apple.com/design/human-interface-guidelines/typography)、[Color](https://developer.apple.com/design/human-interface-guidelines/color)、[Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)、[Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars)、[Charts](https://developer.apple.com/design/human-interface-guidelines/charts)。本项目是网页对相关原则的适配，不宣称原生组件外观完全等同。
