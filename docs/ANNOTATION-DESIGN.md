# PinShot 标注编辑器设计（Annotation Editor）

> 需求：截图后可以用画笔标注、划线，再贴图 / 复制 / 保存。
> 目标：在「框选完成」与「贴图」之间插入一个轻量、键盘友好的标注工作台，视觉沿用 PinShot 的 Capture instrument 语言。

## 1. 用户流程

```
⇧⌘2
  → 冻结帧框选
  → 【新增】标注编辑器（窗口居中，显示截图 + 工具栏）
        ├─ 直接按 Enter / 点「完成」 → 贴图（或按截图模式复制）
        ├─ 画笔 / 直线 / 箭头 / 矩形 / 高亮 / 橡皮擦标注
        ├─ 点「复制」→ 复制标注后的图到剪贴板并关闭
        ├─ 点「保存」→ 保存 PNG 并关闭
        └─ Esc / 取消 → 放弃本次截图
  → 贴图挂件（原有自动隐藏等行为不变）
```

- 标注后的图像以**原生像素分辨率**导出（Retina 2x），贴图/复制/保存都使用标注后的结果。
- 原有 ⇧⌘1（截图并复制）同样进入编辑器，「完成」等价于复制。

## 2. 视觉与布局

编辑器使用**固定深色工作台**（不随系统浅色/深色变化），让任意截图内容都清晰可对照；工具栏为深色磨砂玻璃，延续贴图工具栏语言。

```
┌──────────────────────────────────────────────────────────────────────┐
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │ ✏ ─ ↗ ▭ ▍ ⌫ │ ● ● ● ● ● │ · · · │ ↶ ↷ │  取消  保存  复制  完成 │  │  44pt 工具栏（磨砂）
│  └────────────────────────────────────────────────────────────────┘  │
│                                                                      │
│      ┌──────────────────────────────────────────────────────┐        │
│      │                                                      │        │
│      │                 标注画布（截图，圆角 8、阴影）         │        │
│      │                                                      │        │
│      └──────────────────────────────────────────────────────┘        │
│              拖拽绘制 · P 画笔 · L 直线 · A 箭头 · ⌘Z 撤销 · Enter 完成 │  12pt 提示
└──────────────────────────────────────────────────────────────────────┘
```

- 窗口：无边框、圆角 16、可拖动、深色背景 `#141312`（带轻微透明/阴影），`level = .floating`。
- 尺寸：`窗口宽 = max(截图显示宽 + 48, 820)`，高度 = 工具栏 44 + 间距 14 + 图片高 + 提示 24 + 上下边距。
- 截图按屏幕可用区域等比缩放显示（最大 80% 屏宽/高）；显示坐标与导出像素之间按比例换算，导出仍为原生像素。
- 工具栏：`NSVisualEffectView(.hudWindow)` + 10pt 圆角 + 1px 白 12% 边框，高 44。
- 提示文字：白色 45%，11pt。

## 3. 工具

| 工具 | 图标（SF Symbol） | 行为 | 快捷键 |
| --- | --- | --- | --- |
| 画笔 | `pencil.tip` | 自由手绘，圆头圆角 | P |
| 直线 | `line.diagonal` | 拖拽起点→终点 | L |
| 箭头 | `arrow.up.right` | 直线 + 实心箭头 | A |
| 矩形 | `rectangle` | 拖拽画空心矩形（1.5pt） | R |
| 高亮 | `highlighter` | 粗半透明笔迹（白色/彩色 35% 透明） | H |
| 橡皮擦 | `eraser` | 划过/点击删除命中的笔画（可撤销） | E |

- 撤销 / 重做：`⌘Z` / `⇧⌘Z`，工具栏按钮同步禁用态；每次落笔、擦除、清空都入栈。
- 颜色：6 个圆形色板：红 `#FF453A`、橙 `#FF9F0A`、黄 `#FFD60A`、绿 `#32D74B`、蓝 `#0A84FF`、白 `#FFFFFF`；选中态外圈 2pt 白环 + 中心点。
- 粗细：3 档（细 2pt / 中 4pt / 粗 8pt），高亮固定 14pt。
- 光标：画布内十字准星；橡皮擦使用圆形光标。
- 绘制期间实时预览；鼠标松开提交一笔（写入撤销栈）。

## 4. 操作与键盘

| 操作 | 行为 |
| --- | --- |
| 完成 / Enter / ⌘↩ | 导出标注图 → 交给 CaptureCoordinator 贴图（或复制模式则复制）→ 关闭 |
| 复制 / ⌘C | 导出标注图 → 写剪贴板（PNG + TIFF）→ 关闭 |
| 保存 / ⌘S | 导出标注图 → NSSavePanel（默认桌面 `PinShot-时间戳.png`）→ 关闭 |
| Esc / 取消 / 关闭 | 放弃标注，恢复截图前状态 |
| 撤销 / 重做 | 笔画操作栈 |
| 方向键 | 不需要 |
| 窗口拖动 | 拖动深色背景（非画布/非工具栏区域） |

- 编辑器激活时抢占键盘；关闭后焦点归还截图前应用（沿用 CaptureCoordinator 逻辑）。
- 禁止双击窗口标题等系统行为（无标题栏）。

## 5. 数据与导出

```swift
struct AnnotationStroke {
    enum Tool { case pen, line, arrow, rectangle, highlighter, eraser }
    var tool: Tool
    var points: [CGPoint]       // 画布显示坐标（pt）
    var color: NSColor
    var lineWidth: CGFloat      // pt
}
```

- 画布显示尺寸 `displaySize` 与图片 `pointSize` 可能不同（大图缩放显示）。导出时：
  `scale = cgImage.pixelWidth / displaySize.width`，把画布坐标 × scale 绘制到像素画布。
- 导出顺序：原图 → 所有笔画（按时间顺序）→ 得到 `PinnedImage(cgImage, pointSize: 原图 pointSize)`。
- 文字/马赛克/序号等暂不做（后续可扩展）。

## 6. 对外的接口（CaptureCoordinator 依赖，必须严格一致）

文件：`Sources/UI/AnnotationEditor.swift`（可再拆 `AnnotationCanvasView.swift`，同一负责人）。

```swift
enum AnnotationEditorAction {
    case finish     // 完成（按截图模式贴图或复制）
    case copy       // 复制到剪贴板
    case save       // 保存 PNG
}

enum AnnotationEditorOutcome {
    case completed(PinnedImage, action: AnnotationEditorAction)
    case cancelled
}

@MainActor
final class AnnotationEditorController: NSWindowController {
    init(image: PinnedImage, onFinish: @escaping (AnnotationEditorOutcome) -> Void)
    func present()
    func dismiss()

    // 离屏渲染自检 / 文档截图
    func debugPrepareForRendering(appearance: NSAppearance) -> NSView?
    func debugApplySampleAnnotations()
}
```

- `init` 只构建 UI，不激活；`present()` 居中、激活、makeKey。
- `onFinish` 恰好调用一次；先 `orderOut` 再回调。
- `.completed` 返回的 `PinnedImage` 必须是**标注合成后的原生像素图**，`pointSize` 与原图一致。
- 所有 UI 用 AppKit；不要用 SwiftUI；不改 Theme.swift / Controls.swift / 其他文件。

## 7. 集成

- `CaptureCoordinator` 在选区裁剪出 `PinnedImage` 后，不再直接贴图，而是弹出 `AnnotationEditorController`：
  - `.completed(image, .finish)` → 按原模式贴图 / 复制
  - `.completed(image, .copy)` → 复制
  - `.completed(image, .save)` → NSSavePanel 保存
  - `.cancelled` → 恢复截图前状态
- 标注期间保持 `isCapturing = true`，贴图挂件保持隐藏；结束后统一 `finishCapture()` 恢复。
- 新增调试参数 `--demo-annotate`：用合成截图打开编辑器（无需屏幕录制权限），用于真机目检。
- `--render-ui` 增加编辑器浅/深色（工作台固定深色）渲染图，含示例笔画。
- 关闭编辑器 / 完成 / 取消后焦点归还截图前应用。

## 8. 验收

1. `make typecheck` / `make build` 通过。
2. `--render-ui` 产出 `ui-annotation-light.png` / `ui-annotation-dark.png`：工具栏、色板、画布、示例笔画均正确。
3. `--demo-annotate` 真机：窗口出现、可画笔画/直线/箭头/矩形/高亮、可撤销；「完成」生成贴图，位置与尺寸正确。
4. 导出像素检查：400×300pt 选区（@2x）导出 PNG 800×600，标注线条清晰无模糊。
5. 不影响原有截图 / 自动隐藏 / 复制 / 保存 / 菜单流程。


## 9. 实现状态

- ✅ 编辑器、画布、全部工具、撤销/重做、原生像素导出、离屏渲染接口均已实现。
- ✅ 已接入 CaptureCoordinator：框选 → 标注 → 完成贴图 / 复制 / 保存 / 取消。
- ✅ 真机用合成截图 + 合成鼠标验证：画出笔迹，Enter 后贴图尺寸/内容正确。
- 取舍：固定深色工作台；窗口固定尺寸不可缩放；橡皮擦为整笔删除；离屏工具栏磨砂为叠层模拟，真机为 HUD 磨砂。
- 文件：`Sources/UI/AnnotationEditor.swift`、`Sources/UI/AnnotationCanvasView.swift`。


## 8. OCR 文字识别（Shottr 借鉴）

- 标注编辑器打开时后台调用 macOS Vision（`VNRecognizeTextRequest`，accurate + 中英混合）自动识别原图文字；识别完成后底部右侧按钮显示「文字 N 字 · ⌘T」。
- 点击按钮或 `⌘T` 打开 `OCRPanelController`：可选中文本、`⌘C` 复制、按钮「复制全文」；面板单例复用、Esc 关闭。
- 贴图窗口工具栏新增「识别文字」按钮（`text.viewfinder`），右键菜单也有「识别文字…」；识别已贴图的图片。
- 识别完全本地离线，不上传图片；Vision 坐标按列聚类后按阅读顺序输出，避免多栏截图文字交错。
