# 液态玻璃：官方阅读与预览取舍

2026-10-09。范围仅为预览版的浮动底部导航，保留HTML/CSS/JS。

已阅读官方资料：[Materials](https://developer.apple.com/design/human-interface-guidelines/materials)、[Color](https://developer.apple.com/design/Human-Interface-Guidelines/color)、[Motion](https://developer.apple.com/design/human-interface-guidelines/motion)、[WWDC25 Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/)。以下为概括，非原文引用。

| 官方原则 | 本项目取舍 |
|---|---|
| 材质用于功能与导航层，内容保持清晰 | 仅底部胶囊使用玻璃，卡片、表单和设置仍为实色 |
| `regular`偏向可读性，`clear`用于丰富媒体背景 | 本页是记录工具，不能把高透明外观称为官方推荐的原生`clear`；按用户要求制作较通透的网页适配 |
| 玻璃吸收背后的颜色，按背景调整材质 | 减少固定底色与过强模糊，让直接位于底栏下方的颜色可见；不把整栏染成固定蓝色 |
| 触摸时有形变和光感，动效需短促、可中断 | 选中透镜滑动、拉伸、回弹，图标轻微上弹；立即切换路由，快速点击从当前动画位置衔接 |
| 减少动态效果时关闭弹性反馈 | 监听浏览器的减少动态效果偏好并取消动画；增加对比度/降低透明度时回到实色 |

苹果没有在这些设计指南中指定网页的RGBA透明度、CSS模糊半径或回弹时长。预览采用的18%/24%底色、10px模糊、420ms透镜和320ms图标动效均是项目调试选择。

浏览器的背景模糊、阴影与动画能接近这种视觉语言，但不提供苹果原生材质的完整实时折射、自适应光学与系统触感。仅对当前页面及支持的浏览器效果作承诺。

验证：彩色色带透色、真实内容滚动、浅色/深色、小屏、快速连续切换、减少动态效果、底部遮挡和正式存储隔离。测试色带只用于临时截图，线上页面使用正常演示记录。
