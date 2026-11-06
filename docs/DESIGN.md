# PinShot 截图挂件 — 设计文档

> macOS 菜单栏小工具：一键框选截图 → 图片变成置顶「挂件」浮在所有窗口之上 → 鼠标离开自动淡出/隐藏，悬停即恢复。
> 目标平台：macOS 14+（开发机 macOS 26.6.2 / Apple Silicon）。无 Dock 图标，常驻菜单栏。

---

## 1. 产品定位

**一句话**：把截图从「文件」变成「可随时看的浮层」，像便利贴一样钉在屏幕最上层。

典型场景：

- 对着参考图写代码 / 做设计，截图钉在角落随时瞄一眼；
- 对照文档填表，把表单钉在窗口旁边；
- 开会时把关键数字钉在屏幕角落；
- 不想让截图挡住正在看的窗口 —— 鼠标一移开就自动淡出，甚至完全隐藏、点击穿透。

与系统截图（⇧⌘3/4/5）的差异：系统截图产出文件或剪贴板；PinShot 产出**置顶浮窗**，并带自动隐藏。

## 2. 核心体验

```
按下 ⇧⌘2
   ↓ 屏幕冻结（已有贴图先隐去）
拖动框选区域（半透明遮罩 + 尺寸徽标 + ESC 取消）
   ↓
松开鼠标 → 截图以置顶挂件出现在原位置（无位移、所见即所得）
   ↓
鼠标移开 2 秒 → 淡出到 12% 透明度并点击穿透
   ↓
鼠标扫过原位置 → 0.15 秒内恢复 100%
```

一次截图的完整操作是：**热键 → 拖一下 → 松手**，共 3 个动作。

## 3. 功能清单

### P0（本次交付）

| 模块 | 功能 |
| --- | --- |
| 截图 | 全局热键 ⇧⌘2 框选截图；⇧⌘1 框选截图并写入剪贴板（不贴图）；菜单栏也可触发 |
| 选区 | 冻结帧框选（不会把遮罩截进去）；半透明遮罩挖孔；实时尺寸徽标；ESC / 右键取消；多显示器；Retina 原生像素 |
| 贴图 | 无边框置顶浮窗，出现在选区原位；拖拽移动；右下角等比缩放；悬停工具栏（复制 / 保存 / 自动隐藏 / 关闭）；右键菜单；⌘C / ⌘S / ⌘W / 方向键微调 / Esc 关闭 |
| 自动隐藏 | 鼠标离开 → 延迟淡出到幽灵透明度并点击穿透 → 悬停恢复；可整体暂停；可切换「完全隐藏」 |
| 菜单栏 | 截图并贴图、截图并复制、全部贴图 显示/隐藏、自动隐藏开关、设置、关于、退出 |
| 设置 | 自动隐藏开关/延迟/幽灵透明度/完全隐藏/隐藏时点击穿透；两个全局快捷键可自定义录制；开机启动；屏幕录制权限状态与一键跳转 |
| 工程 | `make build` 产出 `PinShot.app`（ad-hoc 签名、LSUIElement）；`make run` / `make install`；`make test` 单元测试；`--render-test` 视觉自检产物 |

### P1（预留，本次不做）

- 窗口/控件级截图（空格选窗）、滚动截图
- 标注（箭头/马赛克/文字）、OCR 取字
- 贴图跨启动持久化、贴图分组/命名
- 贴边自动折叠（Dock 式）、多选批量关闭

### 非目标

- 录屏、GIF、云同步、剪贴板历史

## 4. 交互细节

### 4.1 截图状态机

```
idle ──(热键/菜单)──► capturing(隐藏贴图, SCK 抓全屏)
     ──(失败)──────► permissionGuide ──► idle
     ──(成功)──────► selecting(每个屏幕一个冻结帧覆盖窗)
                        ├─ 拖拽 ≥ 3pt ──► 松手 → annotating(标注编辑器)
                        │                      ├─ Enter/完成 → pinning / clipboard → idle
                        │                      ├─ 复制/保存 → clipboard / file → idle
                        │                      └─ Esc/取消 → restore → idle
                        └─ ESC/右键/无效点击 ──► cancel → 恢复贴图 → idle
```

### 4.1.1 放置模式

| 模式 | 层级 | 行为 |
| --- | --- | --- |
| floating（默认） | floatingWindow + 1 | 浮在所有窗口上方；自动隐藏生效；可浮在全屏应用上 |
| desktop | desktopIconWindow + 1 | 位于桌面图标之上、普通窗口之下；自动隐藏关闭；像桌面便签，移开窗口/显示桌面时可见 |

- 每个贴图可独立切换；设置里可设置新贴图默认模式。
- 桌面模式下窗口保持可拖动、可缩放，只是不参与窗口层级竞争。

### 4.2 挂件窗口状态

| 状态 | 显示 | 可点击 | 进入条件 | 离开条件 |
| --- | --- | --- | --- | --- |
| normal | 100% + 工具栏可悬停 | 是 | 新建；鼠标进入 | 鼠标离开 ≥ 延迟 |
| ghost | `ghostAlpha`（默认 12%），无工具栏 | 否（点击穿透，默认开） | 自动隐藏开启且鼠标离开超时 | 鼠标回到窗口范围（全局轮询） |
| hidden | 0% | 否 | 开启「完全隐藏」 | 同上 |
| paused | normal | 是 | 菜单/设置暂停自动隐藏 | 恢复自动隐藏 |

轮询：共享 `AutoHideManager` 每 0.2s 读 `NSEvent.mouseLocation`（无需辅助功能权限），按窗口 frame 判定悬停；显隐用 0.15~0.25s Core Animation 淡入淡出。鼠标离开后不立即隐藏，避免「刚截完就消失」。

### 4.3 默认参数

| 参数 | 默认值 |
| --- | --- |
| 截图并贴图 | ⇧⌘2 |
| 截图并复制 | ⇧⌘1 |
| 自动隐藏 | 开 |
| 隐藏延迟 | 2.0 s |
| 幽灵透明度 | 12% |
| 完全隐藏 | 关 |
| 隐藏时点击穿透 | 开 |
| 贴图边框 | 1px 半透明白（深色下自适应） |
| 圆角 | 8 pt |
| 最小贴图尺寸 | 40×40 pt |

### 4.4 鼠标 / 键盘

| 操作 | 行为 |
| --- | --- |
| 拖拽图片 | 移动挂件（`performDrag`，无闪烁） |
| 拖拽右下角 16pt 内 | 等比缩放（保持宽高比） |
| 悬停 | 浮出工具栏 |
| 右键 | 上下文菜单 |
| ⌘C | 复制图片到剪贴板 |
| ⌘S | 另存为 PNG（默认文件名 `PinShot-时间戳.png`，默认目录桌面） |
| ⌘W / Esc | 关闭当前挂件 |
| 方向键 | 1pt 微调（⇧ 为 10pt） |
| 滚轮 | 不拦截（直接滚给下方应用；缩放走右下角） |

## 5. 技术架构

### 5.1 约束

- 开发机只有 **Command Line Tools**（无 Xcode / 无 xcodebuild），因此**不用 SwiftPM 也不建 xcodeproj**：`swiftc` 直接编译，Makefile 组装 `.app`、写 Info.plist、ad-hoc `codesign`。
- 不使用 Storyboard / SwiftUI 的 app lifecycle；纯 AppKit 代码布局，方便无 Xcode 构建与渲染自检。
- 签名：本机无开发者证书，用 ad-hoc（`codesign -s -`）。系统不要求「屏幕录制」权限由证书决定，首次截图会弹 TCC 授权；若重新构建导致签名变化，可能需要在「系统设置 → 隐私与安全性 → 屏幕录制」中重新勾选。

### 5.2 模块与文件

```
PinShot/
├── Makefile                    # build / run / install / test / clean
├── Resources/Info.plist        # LSUIElement=1, CFBundleIdentifier=com.kuxin.pinshot
├── scripts/build.sh            # swiftc 编译 + 组装 .app + 生成图标 + ad-hoc 签名
├── scripts/typecheck.sh        # 全量类型检查（开发期快速反馈）
├── docs/DESIGN.md              # 本文档
├── Sources/
│   ├── App/
│   │   ├── main.swift              # NSApplication 启动、--render-test 分流
│   │   ├── AppDelegate.swift       # 状态栏、菜单、权限引导、捕获流程编排
│   │   └── CaptureCoordinator.swift# 热键→隐藏贴图→抓屏→选区→贴图/复制
│   ├── Core/
│   │   ├── Models.swift            # ScreenSnapshot / PinnedImage / 常量
│   │   ├── CaptureGeometry.swift   # 坐标/像素/裁剪/等比换算（纯函数，可单测）
│   │   ├── ScreenCapturer.swift    # ScreenCaptureKit 抓全屏（fallback: screencapture CLI）
│   │   ├── AppSettings.swift       # UserDefaults 设置 + 变更通知
│   │   ├── GlobalHotKey.swift      # Carbon 全局热键注册/注销
│   │   ├── PinManager.swift        # 贴图生命周期、全部显示/隐藏
│   │   └── LaunchAtLogin.swift     # 开机启动（SMAppService，失败回退 LaunchAgent）
│   ├── UI/
│   │   ├── SelectionOverlay.swift  # 冻结帧全屏覆盖窗 + 框选交互
│   │   ├── PinWindow.swift         # 置顶挂件 Panel + 内容视图 + 工具栏
│   │   ├── PinWindowController.swift# 拖动/缩放/菜单/快捷键 + 自动隐藏宿主
│   │   ├── AutoHideManager.swift   # 全局悬停轮询、淡入淡出状态机
│   │   └── SettingsWindow.swift    # 设置面板 + 快捷键录制
│   └── Support/
│       └── SelfTest.swift          # --render-test：离屏渲染选区/挂件 PNG + 单元测试入口
└── Tests/TestMain.swift        # 纯逻辑单测（坐标换算、裁剪、设置、热键描述）
```

### 5.3 截图数据流

```
GlobalHotKey(⇧⌘2)
  → CaptureCoordinator.capture(.pin)
      → PinManager.hideAllForCapture()      // orderOut + 120ms
      → ScreenCapturer.captureScreens()     // 每屏一张原生分辨率 CGImage
          └ ScreenCaptureKit: SCShareableContent → SCContentFilter(display) →
            SCScreenshotManager.captureImage(
              config.width/height = filter.contentRect × filter.pointPixelScale  // 原生像素，
              config.captureResolution = .best, showsCursor = false)              // 避免 SCDisplay.width 是「点」时退化成 1x
          └ 失败回退: /usr/sbin/screencapture -x -D <displayID> <tmp.png>
      → SelectionOverlayController.present([ScreenSnapshot])   // 每屏一个覆盖窗
          → 用户拖拽 → .region(snapshot, rectInScreenPoints)
      → CaptureGeometry.crop(image, rect, screen, scale)       // 点 → 像素，y 翻转
      → AnnotationEditorController（画笔/直线/箭头/矩形/高亮/橡皮擦，原生像素合成）
      → PinManager.add(annotatedImage, at: 选区全局 frame) 或 NSPasteboard / PNG
      → PinManager.restoreAfterCapture()
```

### 5.4 关键技术点

**冻结帧选区**：先把整屏抓下来，再用覆盖窗显示这张图 + 遮罩。好处：选区内容与最终贴图逐像素一致，遮罩永远不会被截进去，且可以做「遮罩挖孔」的精致效果。覆盖窗 `level = CGShieldingWindowLevel()`，盖住菜单栏与 Dock；`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`。

**坐标换算**（易错点，集中在 `CaptureGeometry` 并用单测锁死）：

- NSScreen.frame / NSWindow.frame：全局 Cocoa 坐标，**原点左下、y 向上**。
- CGImage：**左上原点**像素数据。
- `pixelX = (selectionInScreen.minX - screen.frame.minX) * scale`
- `pixelY = (screen.frame.maxY - selectionInScreen.maxY) * scale`
- `pixelW = selection.width * scale`，`pixelH = selection.height * scale`
- 选区是屏幕局部坐标（覆盖窗 bounds）；贴图窗口 frame = `screen.frame.origin + 选区.origin`（全局 Cocoa，直接可用）。
- 多屏：选区只在起始屏内生效（一次拖拽不跨屏），其余屏正常显示冻结帧，ESC 统一取消。

**全局热键**：Carbon `RegisterEventHotKey`（无需辅助功能授权，不受 Secure Input 之外的场景限制），事件在 `GetApplicationEventTarget()` 的 handler 中回调；快捷键变更时先 `UnregisterEventHotKey` 再注册。

**自动隐藏**：轮询 `NSEvent.mouseLocation`（全局鼠标位置，无需任何隐私权限）而不是全局事件监听；窗口隐藏时 `ignoresMouseEvents = true` 实现点击穿透，悬停由轮询判定后恢复。

**多屏 / Retina**：`SCDisplay.width/height` 在部分系统/缩放下返回的是「点」，直接作为 `SCStreamConfiguration` 尺寸会得到 1x 截图（已实测踩坑）。改为用 `SCContentFilter.contentRect × pointPixelScale` 计算原生像素尺寸，并设置 `captureResolution = .best`；`PinnedImage.pointSize = 像素 / 实际 scale`，贴图窗口尺寸用点，Retina 屏自动使用全分辨率。

**权限**：`CGPreflightScreenCaptureAccess()` 预检；`CGRequestScreenCaptureAccess()` 首次触发系统授权；失败时弹引导（打开系统设置 + 重启提示）。首帧黑屏的常见原因就是授权后未重启，设置页提供「重新检查」。

**渲染自检**（本机没有屏幕录制权限也能验收视觉）：`PinShot --render-test <outdir>` 用合成屏幕图离屏渲染「选区遮罩」「挂件 + 工具栏」PNG，供开发与回归使用。

### 5.5 打包与运行

```
scripts/build.sh:
  swiftc -swift-version 5 -O Sources/**/*.swift -o build/PinShot.app/Contents/MacOS/PinShot \
         -framework AppKit -framework ScreenCaptureKit -framework Carbon -framework ServiceManagement
  cp Resources/Info.plist  build/PinShot.app/Contents/
  (可选) 生成 AppIcon.icns → Resources/
  codesign --force --deep --sign - build/PinShot.app
```

Info.plist 关键项：`LSUIElement=1`（无 Dock 图标）、`LSMinimumSystemVersion=14.0`、`NSHighResolutionCapable=true`、`CFBundleIdentifier=com.kuxin.pinshot`。

分发：`make install` 拷贝到 `~/Applications/PinShot.app`（TCC 对路径变化敏感，固定路径更稳），`open ~/Applications/PinShot.app`。

## 6. 验收标准

> 本次集成验收的实际结果见 [ACCEPTANCE.md](ACCEPTANCE.md)。

### 6.1 自动化

- `make build` 0 error（本机 CLT 环境）。
- `make test` 全部通过：坐标换算（单屏/Retina/副屏负坐标）、裁剪边界、等比缩放、设置持久化、热键描述符、自动隐藏判定。
- `--render-test` 产出 PNG，人工检查：遮罩挖孔正确、尺寸徽标、挂件圆角/边框/工具栏/阴影无异常。
- 启动冒烟：进程存活、状态栏项存在、无崩溃日志。

### 6.2 真机人工验收（需要用户授权屏幕录制）

1. 按 ⇧⌘2 出现冻结帧选区，拖拽有遮罩挖孔和尺寸徽标；
2. 松手后贴图精确落在原位，Retina 下清晰；
3. 拖动、右下角缩放正常，工具栏按钮生效；
4. 鼠标移开 2s 淡出到 12% 且点击穿透，回到原位置恢复；
5. 菜单栏可暂停自动隐藏、可隐藏/显示全部；
6. 设置修改延迟/透明度立即生效，快捷键可录制，开机启动可切换；
7. 多显示器各自框选正常，负坐标副屏位置正确。

## 7. 风险与对策

| 风险 | 对策 |
| --- | --- |
| 无 Xcode，SwiftPM 被沙箱阻止 | Makefile + swiftc；已验证可行（~60s 冷编译） |
| TCC 屏幕录制首启弹窗/黑屏 | 预检 + 引导面板 + 设置页重新检查 + README 说明；SCK 失败回退 CLI |
| ad-hoc 签名重建后权限失效 | 固定安装路径 `~/Applications`，README 说明重新勾选流程 |
| 自动隐藏误伤（刚截图就消失） | 离开延迟默认 2s；悬停恢复 0.15s；可暂停 |
| 覆盖窗被截进图 | 冻结帧方案从根上避免；截图前先隐藏已有贴图 |
| 多屏坐标/负坐标 | 全部换算集中在 `CaptureGeometry` 并有单测 |

## 8. 后续演进

1. 标注层（箭头/框/文字/马赛克）与 OCR；
2. 贴图持久化 + 恢复上次会话；
3. 窗口/控件级截图（空格选窗）与滚动截图；
4. 贴边折叠、贴图透明度滚轮调节；
5. 签名分发（Developer ID + 公证）。
