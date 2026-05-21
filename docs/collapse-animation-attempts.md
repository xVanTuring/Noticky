# 折叠动画尝试记录（失败归档）

> 2026-05-21。目标:把浮动便签的折叠/展开做成「从下往上折叠、从上往下展开,
> 顶边锚定,内容零挤压,无瞬移」。多轮尝试均失败,最终决定**移除折叠动画**
> (改为瞬间折叠/展开)。本文档归档所有尝试与发现,避免后人重蹈覆辙。

## 需求 / 期望视觉

- 折叠:窗口顶边不动,底边上移收起(从下往上折)。标题条始终钉在顶部不动。
- 展开:窗口顶边不动,底边下移展开(从上往下展)。编辑器从上往下显出。
- 全程内容不挤压(标题文字不变形/不位移),动画结束不「瞬间归位」。

## 症状(贯穿所有尝试)

- 折叠时**标题行向下滑动**,盒子像底边锚定一样向下塌缩;动画结束**瞬间跳回**
  正确的顶部位置。
- 展开时窗口/内容不同步,先动一点、内容再动、最后整窗瞬开。
- 后期多个版本用户反馈「完全没有变化 / 一模一样」。

## 涉及文件

`Sources/Noticky/Features/Floating/FloatingNoteWindow.swift`
- `FloatingNoteWindowController`:持有 `NSWindow`(`StickyPanel`,borderless),
  内容是 `NSHostingController`(SwiftUI `FloatingNoteView`)。
- 折叠入口:`toggleCollapse()`(双击标题 / ⋯ 菜单都走这条,已用日志确认)。

## 各次尝试

### 1. 统一 stripHeight + 推迟 isCollapsed + `animateFrame(animator)`
- 顶部 strip 高度统一成 32pt;折叠先动画再写 `isCollapsed=true`,展开先写
  `isCollapsed=false` 再动画。动画用 `window.animator().setFrame` + `NSAnimationContext`。
- 结果:内容挤压 + 标题下滑 + 瞬移。**失败**。

### 2. `layerContentsRedrawPolicy = .duringViewResize` + 去掉 `allowsImplicitAnimation`
- 想让 resize 全程逐帧重绘而非拉伸位图。
- 结果:**完全没区别**。NSHostingView 用自己内部的 layer 树,顶层 host.view 的
  redraw policy 管不到它。

### 3. 容器化 + host.view 与窗口「CA lockstep」
- 把 `contentViewController` 换成「容器 NSView 当 contentView + host.view 子视图」,
  动画期间手动把 host.view 钉在展开高度、用 `host.animator().setFrameOrigin` 跟
  `window.animator().setFrame` 在同一 `NSAnimationContext` 里一起动。
- 结果:**失败**。关键发现 ↓。

> **关键发现 A:`NSWindow` frame 动画与 `NSView`/CALayer 动画不在同一时间轴。**
> 窗口 frame 动画跑在 WindowServer(服务端),view/layer 动画跑在客户端 CA。
> 二者无法同步,任何「窗口动画 + 内容动画」并行的方案都会撕裂 = 标题滑到底再瞬移。

### 4. 手动 timer 逐帧驱动(`runFold`)
- 抛弃 `animator()`。自己用 `Timer`(1/60s)在一条 easeInOut 时间轴上,**每帧同时
  显式** `window.setFrame(...)` 和 `host.frame = ...`,零歧义同步。内容高度恒定
  (永不 resize → SwiftUI 不重排 → 理论零挤压),只平移、被窗口裁剪。
- **逐帧日志证明窗口和 host 的 frame 每帧都设得完全正确**:窗口 `maxY` 恒定
  (顶边锚定 ✓),host 顶边精确跟随。
- 结果:**视觉完全没变化**。frame 对了但屏幕不反映 → 问题在渲染层。

### 5. `CATransaction.setDisableActions(true)` 包裹每帧 setFrame
- 怀疑 NSHostingView 是 layer-backed,设 frame 触发默认 ~0.25s 隐式 position 动画,
  host 视觉位置滞后于 model = 滑动+瞬移。每帧用 CATransaction 关掉隐式 action。
- 结果:**完全没变化**。

### 6. 容器 `masksToBounds = true`(裁剪)
- 关键推算:runFold 里 host 在**屏幕坐标恒定** ——
  `窗口origin.y + host.origin.y = (topY - h) + (h - contentH) = topY - contentH` = 常数。
  也就是说只要容器不裁剪,host 那 280px 内容就一直渲染在原始展开区域、纹丝不动,
  窗口在背后默默缩小却看不出来 = 「完全没有变化」。于是给容器开
  `wantsLayer + layer.masksToBounds = true` 想裁掉伸出窗口的部分。
- 结果:**仍然完全没变化**。(裁剪没生效,或问题另有他处,未能定位。)

## 诊断手段(有效,值得复用)

- **逐帧日志**:在 `runFold` 每个 tick `NSLog` 出 `p / winFrame / hostFrame`,
  确认 timer 真在跑、值对不对。证明了逻辑层完全正确、问题在渲染层。
- **带版本号日志**:`NSLog("...BUILD-runFold-v4...")` 在折叠入口,确认跑的是新二进制
  (排除「没 build 上」的怀疑 —— 已确认每次都是新代码)。
- **ffmpeg slit-scan**:取每帧固定竖直切片(`crop=4:H:X:0,tile=Nx1`)横向拼接,
  x 轴=时间、y 轴=屏幕纵向,黄框上下边界画成曲线,一眼看清锚点行为。
  (ffmpeg 在 `/Users/xvan/Project/ffmpeg/ffmpeg`;Desktop 有 TCC 限制,需先拷到 /tmp。)
- **filmstrip**:`-start_number N -frames:v M -vf "scale=...,tile=Mx1"` 看连续帧。

## 结论 / 待解

逻辑层(窗口 frame、host frame、timer、缓动)反复验证都正确,但视觉始终是
「内容不被窗口裁剪 / 内容滞后」,根因未彻底定位(疑似 NSHostingView 在 borderless
透明窗 + 自定义 contentView 下的 layer 合成行为)。投入产出比过低,**决定移除折叠动画**,
折叠/展开改为瞬间生效(`setFrame` 不带动画)。如未来重做,建议方向:

- 用 SwiftUI 自身的高度动画(让 SwiftUI 驱动一切、窗口跟随 intrinsic size),
  而不是 AppKit 窗口动画 + 手动定位内容。
- 或对内容做快照(`NSView.dataWithPDF` / layer snapshot),用快照图层做动画,
  再换回真实内容,彻底绕开 NSHostingView 的合成行为。
