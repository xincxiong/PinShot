# PinShot for Windows

PinShot Windows 版：常驻系统托盘的截图贴图工具。视觉与交互沿用 macOS 版（`../Sources/`）的设计语言——暖石墨 `#24282C`、纸白 `#FBF6EF`、信号橙 `#E8551F`，大圆角、细描边、玻璃工具栏，无第三方 UI 库。

> 这是一个可用的 Windows MVP：托盘应用、冻结帧区域截图、深色标注编辑器、置顶贴图、自动隐藏、设置持久化均已实现。macOS 版源码与文档站点不受影响。

## 功能

- **托盘应用**：单实例锁；托盘图标 + 菜单；所有窗口不占任务栏。
- **区域截图**：`desktopCapturer` 抓当前屏幕冻结帧；每块显示器一个透明覆盖层，逐屏框选；按 `scaleFactor` 用原始像素裁剪。
- **标注编辑器**：画笔 / 直线 / 箭头 / 矩形 / 高亮 / 橡皮擦；6 色；3 档粗细；撤销 / 重做；Enter 完成、Ctrl+C 复制、Ctrl+S 保存、Esc 取消；导出使用 canvas 原始像素。
- **贴图窗口**：frameless 透明窗口；置顶 / 桌面模式；拖动移动；四角等比缩放 + 尺寸徽标；悬停玻璃工具栏（复制 / 保存 / 自动隐藏 / 桌面模式 / 关闭）；右键菜单（复制、存储、自动隐藏、贴桌面、缩放 100/75/50/25/适合屏幕、不透明度、关闭、全部关闭）。
- **自动隐藏**：主进程轮询鼠标位置；鼠标离开延迟后 `setOpacity(ghostAlpha)` + `setIgnoreMouseEvents(true, { forward: true })`；扫回贴图立即恢复。桌面模式关闭自动隐藏。
- **设置窗口**：自动隐藏开关 / 延迟 / 幽灵透明度、完全隐藏、点击穿透、贴图边框 / 阴影、新贴图默认放桌面；持久化到 `userData/settings.json`。
- **从剪贴板贴图**：读取系统剪贴板图片 → 标注编辑器 → 贴图。

## 快捷键

| 操作 | 快捷键 |
| --- | --- |
| 截图并贴图 | `Ctrl+Shift+2` |
| 截图并复制 | `Ctrl+Shift+1` |
| 从剪贴板贴图 | `Ctrl+Shift+3` |
| 标注：画笔 / 直线 / 箭头 / 矩形 / 高亮 / 橡皮擦 | `P` / `L` / `A` / `R` / `H` / `E` |
| 标注：撤销 / 重做 | `Ctrl+Z` / `Ctrl+Shift+Z`（或 `Ctrl+Y`） |
| 标注：完成 / 复制 / 保存 / 取消 | `Enter` / `Ctrl+C` / `Ctrl+S` / `Esc` |
| 贴图：复制 / 保存 / 关闭 | `Ctrl+C` / `Ctrl+S` / `Esc` 或 `Ctrl+W` |
| 贴图：方向键微调 | `↑` `↓` `←` `→`（按住 `Shift` 步长 10px） |

所有全局快捷键都可以从托盘菜单触发；若被其他应用占用，设置窗口「截图」页会显示提示。

## 目录结构

```
windows/
├── main.js                 主进程：托盘 / 截图 / 编辑器 / 贴图 / 自动隐藏 / 设置 / IPC
├── preload.js              contextBridge：contextIsolation:true, nodeIntegration:false
├── package.json            scripts: start / start:smoke / check / package:win
├── assets/
│   ├── app-icon.png        原始应用图标（来自 ../docs/images/app-icon.png）
│   ├── icon.png            BrowserWindow / 通知用 512px PNG
│   ├── icon.ico            Windows 可执行文件图标（16–256 多尺寸）
│   ├── tray.png / tray@2x.png  托盘图标
├── renderer/
│   ├── common.css          设计变量（浅色 / 深色）、字体、键帽
│   ├── capture.html/css/js 冻结帧 + 框选覆盖层
│   ├── editor.html/css/js  深色标注工作台 + 玻璃工具栏
│   ├── pin.html/css/js     贴图窗口 + 悬停工具栏 + 四角缩放
│   └── settings.html/css/js 设置窗口（侧边栏 + 卡片）
└── README.md
```

## 开发运行

要求：Node.js ≥ 18（开发时使用 Node 22 验证）、Windows 10/11 x64（运行时）。

```bash
cd windows
npm install
npm start            # 启动托盘应用
npm run start:smoke  # 冒烟测试：托盘 + 设置窗口 + 4 个 renderer 页面 + 配置读写，输出 SMOKE_OK 后退出
npm run check        # node --check 所有 js
```

如果 Electron 二进制下载慢或失败，可以使用镜像（macOS 上验证时使用）：

```bash
export ELECTRON_MIRROR=https://npmmirror.com/mirrors/electron/
# 或 Windows PowerShell: $env:ELECTRON_MIRROR="https://npmmirror.com/mirrors/electron/"
npm install
```

## 打包 Windows 便携版

在 `windows/` 目录下：

```bash
npm run package:win
```

等价于：

```bash
npx electron-packager . PinShot \
  --platform=win32 --arch=x64 \
  --out=dist --overwrite \
  --icon=assets/icon.ico \
  --app-version=1.0.0 \
  --asar --prune \
  --win32metadata.CompanyName=PinShot \
  --win32metadata.FileDescription=PinShot \
  --win32metadata.ProductName=PinShot
```

产物：

```
windows/dist/PinShot-win32-x64/PinShot.exe
```

`dist/PinShot-win32-x64/` 整个目录即绿色便携版，可压缩为 zip 分发（不依赖安装器）。`node_modules/`、`dist/`、`out/` 已被 `windows/.gitignore` 忽略，不要提交。

> 交叉打包说明：在 macOS 上打包 win32-x64 时，`@electron/packager` 需要下载 Windows 版 Electron 预编译包（默认来自 GitHub、可通过 `ELECTRON_MIRROR` 走镜像）。如果网络受限，先完成代码与 `node --check`，在网络可用环境重试同一命令即可。

## settings.json

路径：`app.getPath('userData')/settings.json`。Windows 上通常是：

```
%APPDATA%\PinShot\settings.json
```

字段与默认值：

```json
{
  "autoHideEnabled": true,
  "autoHideDelay": 2,
  "ghostAlpha": 0.15,
  "hideEntirely": false,
  "clickThroughWhenHidden": true,
  "showPinBorder": true,
  "showPinShadow": true,
  "defaultPinDesktop": false,
  "hasCompletedOnboarding": true
}
```

设置窗口的每次改动即时生效，主进程以 150ms 防抖写盘；退出时再强制写一次。

## 已知限制（MVP）

1. **桌面模式**：Electron 在 Windows 上无法把窗口真正插到桌面图标层级，当前实现为 `alwaysOnTop = false` + `skipTaskbar = true` 并关闭自动隐藏。贴图不会置顶，但仍可能位于其他普通窗口之上，取决于 Z 序。
2. **多显示器 / 混合 DPI**：逐屏覆盖层使用 `display.bounds`（DIP）定位，裁剪比例以实际冻结帧像素尺寸 / DIP 宽高反推，因此裁剪像素正确；Windows 在混合 DPI 下偶尔会有 1px 级别的覆盖层偏移，属于 Electron/OS DPI 虚拟化限制。
3. **截图权限**：Windows 不需要屏幕录制权限；macOS 上仅做冒烟启动验证（托盘 / 设置窗口），`desktopCapturer` 需要系统「屏幕录制」授权。
4. **右键菜单 / 托盘菜单**：使用 Electron 原生 `Menu`，在 Windows 上呈现为系统菜单，不自定义样式。
5. **拖拽 / 缩放**：拖动由主进程 16ms 轮询光标实现；四角缩放为等比缩放，不提供自由拉伸。
6. **自动隐藏**：主进程 200ms 轮询鼠标，幽灵状态恢复可能有最多 ~200ms 延迟；隐藏时若开启点击穿透，鼠标点击会直接落到下层窗口。
7. **窗口圆角 / 阴影**：使用透明窗口 + CSS 圆角/阴影；Windows 10 上透明窗口的系统投影与圆角表现可能与 Windows 11 略有差异。
8. **未包含**：开机自启、自动更新、代码签名、安装器（NSIS）、多语言。全局快捷键固定为 `Ctrl+Shift+1/2/3`，暂不支持自定义。
9. **图标**：`assets/icon.ico` 由 `docs/images/app-icon.png` 缩放并通过 PNG 内嵌方式生成（16/24/32/48/64/128/256 多尺寸），未额外手工绘制 Windows 专用图标。

## 验证记录

见仓库根目录的发布说明 / 交接记录；`npm run check` 与 `npm run start:smoke` 均可在无显示器的开发机上复现。

## License

MIT（与仓库根目录 `LICENSE` 一致）。
