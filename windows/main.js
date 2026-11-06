'use strict';

/**
 * PinShot for Windows — Electron 主进程。
 *
 * 职责：
 *  - 托盘应用生命周期（单实例、无任务栏窗口、全局快捷键）
 *  - 使用 desktopCapturer 冻结帧 + 逐屏透明覆盖层完成区域截图
 *  - 标注编辑器会话编排（完成 → 贴图 / 复制 / 保存）
 *  - 贴图窗口管理（置顶 / 桌面模式、拖动、四角等比缩放、右键菜单、自动隐藏）
 *  - 设置窗口与 userData/settings.json 持久化
 *
 * 所有跨进程通信都通过 preload.js 暴露的只读桥接 API。
 */

const {
  app,
  BrowserWindow,
  Tray,
  Menu,
  globalShortcut,
  desktopCapturer,
  screen,
  ipcMain,
  clipboard,
  dialog,
  nativeImage,
  Notification,
} = require('electron');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------

const APP_NAME = 'PinShot';
const APP_VERSION = '1.0.0';
const IS_MAC = process.platform === 'darwin';
const IS_WIN = process.platform === 'win32';

const ROOT_DIR = __dirname;
const RENDERER_DIR = path.join(ROOT_DIR, 'renderer');
const ASSETS_DIR = path.join(ROOT_DIR, 'assets');

/** 标注工作台布局常量，必须与 renderer/editor.css 保持一致。 */
const EDITOR_LAYOUT = Object.freeze({
  padding: 20,
  topInset: 22,
  toolbarHeight: 44,
  toolbarGap: 14,
  hintGap: 10,
  hintHeight: 16,
  bottomInset: 20,
});

/** 贴图窗口四周透明留白（用于绘制阴影 / 缩放把手），单位 DIP。 */
const PIN_MARGIN = 12;
const MIN_CARD = 40;
const AUTO_HIDE_POLL_MS = 200;
const DRAG_POLL_MS = 16;

const HOTKEY_LABELS = Object.freeze({
  capturePin: 'Ctrl+Shift+2',
  captureCopy: 'Ctrl+Shift+1',
  clipboardPin: 'Ctrl+Shift+3',
});

const HOTKEY_ACCELERATORS = Object.freeze({
  capturePin: 'Control+Shift+2',
  captureCopy: 'Control+Shift+1',
  clipboardPin: 'Control+Shift+3',
});

const DEFAULT_SETTINGS = Object.freeze({
  autoHideEnabled: true,
  autoHideDelay: 2.0,
  ghostAlpha: 0.15,
  hideEntirely: false,
  clickThroughWhenHidden: true,
  showPinBorder: true,
  showPinShadow: true,
  defaultPinDesktop: false,
  hasCompletedOnboarding: false,
});

const SMOKE_TEST = process.argv.includes('--smoke-test');
const RENDER_UI = process.argv.includes('--render-ui');

// ---------------------------------------------------------------------------
// 通用工具
// ---------------------------------------------------------------------------

function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max);
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function log(...args) {
  console.log('[PinShot]', ...args);
}

function warn(...args) {
  console.warn('[PinShot]', ...args);
}

function formatTimestamp(date = new Date()) {
  const pad = (n) => String(n).padStart(2, '0');
  return (
    `${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}` +
    `-${pad(date.getHours())}${pad(date.getMinutes())}${pad(date.getSeconds())}`
  );
}

function toBuffer(value) {
  if (Buffer.isBuffer(value)) return value;
  if (value instanceof Uint8Array) return Buffer.from(value);
  if (ArrayBuffer.isView(value)) return Buffer.from(value.buffer, value.byteOffset, value.byteLength);
  if (value && value.type === 'Buffer' && Array.isArray(value.data)) return Buffer.from(value.data);
  return Buffer.alloc(0);
}

function sameRect(a, b) {
  return a.x === b.x && a.y === b.y && a.width === b.width && a.height === b.height;
}

// ---------------------------------------------------------------------------
// 应用状态
// ---------------------------------------------------------------------------

let settings = { ...DEFAULT_SETTINGS };
let settingsFilePath = '';
let persistTimer = null;

let tray = null;
let settingsWindow = null;
let pendingSettingsPane = null;

/** @type {null | {mode:'pin'|'copy', hiddenPins:Array, overlays:Array, snapshots:Map, done:boolean}} */
let captureSession = null;
/** webContents.id -> 编辑器会话。 */
const editorSessions = new Map();
/** id -> 贴图状态。 */
const pins = new Map();
let pinSeq = 0;
let allForcedHidden = false;

let autoHideTimer = null;
const hotkeyStatus = { capturePin: false, captureCopy: false, clipboardPin: false };
let isQuitting = false;

// ---------------------------------------------------------------------------
// 设置持久化
// ---------------------------------------------------------------------------

function settingsDefaults() {
  return { ...DEFAULT_SETTINGS };
}

function initSettingsPath() {
  settingsFilePath = path.join(app.getPath('userData'), 'settings.json');
}

function sanitizeSettings(raw) {
  const out = settingsDefaults();
  if (!raw || typeof raw !== 'object') return out;
  for (const key of Object.keys(out)) {
    if (!(key in raw)) continue;
    const value = raw[key];
    switch (key) {
      case 'autoHideDelay': {
        const n = Number(value);
        if (Number.isFinite(n)) out[key] = clamp(n, 0.5, 8);
        break;
      }
      case 'ghostAlpha': {
        const n = Number(value);
        if (Number.isFinite(n)) out[key] = clamp(n, 0.05, 0.6);
        break;
      }
      default:
        if (typeof value === 'boolean') out[key] = value;
        else if (value === 0 || value === 1) out[key] = Boolean(value);
        break;
    }
  }
  return out;
}

function loadSettings() {
  initSettingsPath();
  let existed = true;
  try {
    const raw = fs.readFileSync(settingsFilePath, 'utf8');
    settings = sanitizeSettings(JSON.parse(raw));
  } catch (error) {
    existed = false;
    settings = settingsDefaults();
    if (error && error.code !== 'ENOENT') warn('settings.json 解析失败，使用默认设置:', error.message);
  }
  if (!existed) {
    settings.hasCompletedOnboarding = false;
    writeSettingsNow();
  }
}

function writeSettingsNow() {
  if (!settingsFilePath) initSettingsPath();
  try {
    fs.mkdirSync(path.dirname(settingsFilePath), { recursive: true });
    const tmpPath = `${settingsFilePath}.tmp`;
    fs.writeFileSync(tmpPath, JSON.stringify(settings, null, 2), 'utf8');
    fs.renameSync(tmpPath, settingsFilePath);
  } catch (error) {
    warn('写入 settings.json 失败:', error.message);
  }
}

function persistSettingsDebounced() {
  if (persistTimer) clearTimeout(persistTimer);
  persistTimer = setTimeout(() => {
    persistTimer = null;
    writeSettingsNow();
  }, 150);
}

function settingsSnapshot() {
  return {
    ...settings,
    version: APP_VERSION,
    hotkeyLabels: { ...HOTKEY_LABELS },
    hotkeyStatus: { ...hotkeyStatus },
  };
}

function broadcastSettings() {
  const snapshot = settingsSnapshot();
  for (const win of BrowserWindow.getAllWindows()) {
    if (win.isDestroyed()) continue;
    try {
      win.webContents.send('settings:changed', snapshot);
    } catch (error) {
      /* 窗口可能正在销毁 */
    }
  }
}

function updateSettings(patch, options = {}) {
  if (!patch || typeof patch !== 'object') return settings;
  let changed = false;
  for (const key of Object.keys(DEFAULT_SETTINGS)) {
    if (!(key in patch)) continue;
    const value = patch[key];
    let next;
    if (key === 'autoHideDelay') {
      const n = Number(value);
      if (!Number.isFinite(n)) continue;
      next = Math.round(clamp(n, 0.5, 8) * 10) / 10;
    } else if (key === 'ghostAlpha') {
      const n = Number(value);
      if (!Number.isFinite(n)) continue;
      next = Math.round(clamp(n, 0.05, 0.6) * 100) / 100;
    } else {
      next = typeof value === 'boolean' ? value : Boolean(value);
    }
    if (settings[key] !== next) {
      settings[key] = next;
      changed = true;
    }
  }
  if (!changed) return settings;

  if (!options.skipPersist) persistSettingsDebounced();
  broadcastSettings();
  refreshTrayMenu();
  applySettingsToPins();
  return settings;
}

function resetSettings() {
  const keepOnboarding = settings.hasCompletedOnboarding;
  settings = sanitizeSettings(settingsDefaults());
  settings.hasCompletedOnboarding = keepOnboarding;
  writeSettingsNow();
  broadcastSettings();
  refreshTrayMenu();
  applySettingsToPins();
  return settings;
}

function applySettingsToPins() {
  for (const pin of pins.values()) {
    if (pin.win.isDestroyed()) continue;
    pin.lastOpacity = null;
    pin.lastClickThrough = null;
    pin.lastStateKey = null;
    applyPinVisual(pin);
  }
  pollPins(true);
}

// ---------------------------------------------------------------------------
// 窗口基座
// ---------------------------------------------------------------------------

function baseWebPreferences() {
  return {
    preload: path.join(ROOT_DIR, 'preload.js'),
    contextIsolation: true,
    nodeIntegration: false,
    sandbox: false,
    spellcheck: false,
    backgroundThrottling: false,
  };
}

function makeWindow(options = {}) {
  const win = new BrowserWindow({
    show: false,
    frame: false,
    transparent: true,
    backgroundColor: '#00000000',
    resizable: false,
    movable: true,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    skipTaskbar: true,
    hasShadow: false,
    autoHideMenuBar: true,
    webPreferences: baseWebPreferences(),
    ...options,
  });
  win.removeMenu();
  win.setMenuBarVisibility(false);
  return win;
}

function loadRenderer(win, page) {
  return win.loadFile(path.join(RENDERER_DIR, page));
}

// ---------------------------------------------------------------------------
// 托盘
// ---------------------------------------------------------------------------

function trayImage() {
  const file = path.join(ASSETS_DIR, IS_WIN ? 'tray.png' : 'tray.png');
  let image = nativeImage.createFromPath(file);
  if (image.isEmpty()) {
    image = nativeImage.createFromPath(path.join(ASSETS_DIR, 'icon.png'));
  }
  if (IS_MAC) image.setTemplateImage(true);
  return image;
}

function createTray() {
  if (tray) return tray;
  tray = new Tray(trayImage());
  tray.setToolTip('PinShot · Ctrl+Shift+2 截图并贴图');
  refreshTrayMenu();
  return tray;
}

function refreshTrayMenu() {
  if (!tray) return;
  const count = pins.size;
  const anyPins = count > 0;
  const hiddenLabel = allForcedHidden ? '显示全部贴图' : '隐藏全部贴图';
  const template = [
    {
      label: `截图并贴图    ${HOTKEY_LABELS.capturePin}`,
      click: () => startCapture('pin'),
    },
    {
      label: `截图并复制    ${HOTKEY_LABELS.captureCopy}`,
      click: () => startCapture('copy'),
    },
    {
      label: `从剪贴板贴图    ${HOTKEY_LABELS.clipboardPin}`,
      click: () => pinFromClipboard(),
    },
    { type: 'separator' },
    {
      label: hiddenLabel,
      enabled: anyPins,
      click: () => toggleHideAllPins(),
    },
    {
      label: '关闭全部贴图',
      enabled: anyPins,
      click: () => closeAllPins(),
    },
    {
      label: '全部贴到桌面',
      enabled: anyPins,
      click: () => setAllPlacement('desktop'),
    },
    {
      label: '全部浮到顶层',
      enabled: anyPins,
      click: () => setAllPlacement('floating'),
    },
    { type: 'separator' },
    {
      label: '自动隐藏贴图',
      type: 'checkbox',
      checked: settings.autoHideEnabled,
      click: () => updateSettings({ autoHideEnabled: !settings.autoHideEnabled }),
    },
    { type: 'separator' },
    {
      label: '设置…',
      click: () => showSettings(),
    },
    {
      label: '关于 PinShot',
      click: () => showSettings('about'),
    },
    { type: 'separator' },
    {
      label: '退出 PinShot',
      click: () => app.quit(),
    },
  ];
  tray.setContextMenu(Menu.buildFromTemplate(template));
  tray.setToolTip(count > 0 ? `PinShot · ${count} 个贴图` : 'PinShot · Ctrl+Shift+2 截图并贴图');
}

// ---------------------------------------------------------------------------
// 通知
// ---------------------------------------------------------------------------

function notify(title, body) {
  try {
    if (Notification.isSupported()) {
      const notification = new Notification({
        title,
        body,
        icon: path.join(ASSETS_DIR, 'icon.png'),
        silent: false,
      });
      notification.show();
      return;
    }
  } catch (error) {
    warn('通知失败:', error.message);
  }
  try {
    dialog.showMessageBox({ type: 'info', title, message: title, detail: body, buttons: ['好'] });
  } catch (error) {
    warn('对话框失败:', error.message);
  }
}

// ---------------------------------------------------------------------------
// 全局快捷键
// ---------------------------------------------------------------------------

function registerGlobalShortcuts() {
  for (const [key, accelerator] of Object.entries(HOTKEY_ACCELERATORS)) {
    let ok = false;
    try {
      ok = globalShortcut.register(accelerator, () => handleHotkey(key));
    } catch (error) {
      warn(`快捷键注册异常 ${accelerator}:`, error.message);
    }
    hotkeyStatus[key] = Boolean(ok);
    if (!ok) warn(`快捷键注册失败: ${accelerator}`);
  }

  const failed = Object.entries(hotkeyStatus)
    .filter(([, ok]) => !ok)
    .map(([key]) => HOTKEY_LABELS[key]);
  if (failed.length > 0) {
    notify('部分快捷键不可用', `${failed.join('、')} 可能被其他应用占用，可继续使用托盘菜单。`);
  }

  if (settingsWindow && !settingsWindow.isDestroyed()) {
    settingsWindow.webContents.send('settings:changed', settingsSnapshot());
  }
}

function handleHotkey(key) {
  if (key === 'clipboardPin') {
    pinFromClipboard();
    return;
  }
  startCapture(key === 'capturePin' ? 'pin' : 'copy');
}

// ---------------------------------------------------------------------------
// 截图：冻结帧 + 逐屏覆盖层
// ---------------------------------------------------------------------------

function isCaptureBusy() {
  return Boolean(captureSession) || editorSessions.size > 0;
}

async function startCapture(mode) {
  if (isCaptureBusy()) return;
  const hiddenPins = hideAllForCapture();
  const session = {
    mode: mode === 'copy' ? 'copy' : 'pin',
    hiddenPins,
    overlays: [],
    snapshots: new Map(),
    done: false,
  };
  captureSession = session;

  // 等合成器把贴图窗口移出画面，保证冻结帧里没有旧贴图
  await delay(150);

  let snapshots = [];
  try {
    snapshots = await captureAllDisplays();
  } catch (error) {
    warn('抓屏失败:', error.message);
  }

  if (captureSession !== session || session.done) return;

  if (snapshots.length === 0) {
    captureSession = null;
    restoreAfterCapture(hiddenPins);
    showCaptureFailure();
    return;
  }

  for (const snapshot of snapshots) {
    session.snapshots.set(String(snapshot.displayId), snapshot);
    createCaptureOverlay(session, snapshot);
  }

  // 让鼠标所在屏幕的覆盖层拿到焦点（Esc 才能生效）
  const cursorPoint = screen.getCursorScreenPoint();
  const cursorDisplay = screen.getDisplayNearestPoint(cursorPoint);
  setTimeout(() => {
    if (captureSession !== session) return;
    const overlay = session.overlays.find((entry) => entry.displayId === cursorDisplay.id);
    if (overlay && overlay.win && !overlay.win.isDestroyed()) {
      overlay.win.moveTop();
      overlay.win.focus();
    }
  }, 120);
}

async function captureAllDisplays() {
  const displays = screen.getAllDisplays();
  const results = [];
  let lastError = null;

  for (let index = 0; index < displays.length; index += 1) {
    const display = displays[index];
    try {
      const scale = display.scaleFactor && display.scaleFactor > 0 ? display.scaleFactor : 1;
      // thumbnailSize 使用物理像素，确保裁剪时拿到原生分辨率
      const targetWidth = Math.max(1, Math.round(display.bounds.width * scale));
      const targetHeight = Math.max(1, Math.round(display.bounds.height * scale));
      const sources = await desktopCapturer.getSources({
        types: ['screen'],
        thumbnailSize: { width: targetWidth, height: targetHeight },
        fetchWindowIcons: false,
      });
      if (!sources || sources.length === 0) {
        lastError = new Error('desktopCapturer 没有返回屏幕源');
        continue;
      }

      let source =
        sources.find((entry) => entry.display_id && String(entry.display_id) === String(display.id)) || null;
      if (!source && sources.length === 1) source = sources[0];
      if (!source && sources[index]) source = sources[index];
      if (!source) continue;

      let thumbnail = source.thumbnail;
      if (!thumbnail || thumbnail.isEmpty()) {
        // Windows 上偶尔会返回空缩略图，重试一次
        const retry = await desktopCapturer.getSources({
          types: ['screen'],
          thumbnailSize: { width: targetWidth, height: targetHeight },
          fetchWindowIcons: false,
        });
        const retrySource =
          retry.find((entry) => entry.display_id && String(entry.display_id) === String(display.id)) || retry[0];
        thumbnail = retrySource ? retrySource.thumbnail : null;
      }
      if (!thumbnail || thumbnail.isEmpty()) {
        lastError = new Error(`显示器 ${display.id} 缩略图为空`);
        continue;
      }

      const png = thumbnail.toPNG();
      // 从 PNG 重新解码拿到确定性的像素尺寸（thumbnail 的 DIP/pixel 语义在不同平台有差异）
      const decoded = png && png.length > 0 ? nativeImage.createFromBuffer(png) : null;
      const actualSize = decoded ? decoded.getSize() : null;
      if (!png || png.length === 0 || !actualSize || actualSize.width < 2 || actualSize.height < 2) {
        lastError = new Error(`显示器 ${display.id} 抓屏尺寸无效`);
        continue;
      }

      results.push({
        display,
        displayId: display.id,
        png,
        pixelSize: actualSize,
      });
    } catch (error) {
      lastError = error;
      warn(`显示器 ${display.id} 抓屏失败:`, error.message);
    }
  }

  if (results.length === 0 && lastError) warn('抓屏最终失败:', lastError.message);
  return results;
}

function createCaptureOverlay(session, snapshot) {
  const display = snapshot.display;
  const win = makeWindow({
    x: display.bounds.x,
    y: display.bounds.y,
    width: display.bounds.width,
    height: display.bounds.height,
    movable: false,
    focusable: true,
    alwaysOnTop: true,
    hasShadow: false,
    skipTaskbar: true,
  });
  win.setAlwaysOnTop(true, 'screen-saver');
  if (IS_MAC) {
    try {
      win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
    } catch (error) {
      /* 某些环境不支持 */
    }
  }
  win.setBounds(display.bounds);

  const entry = {
    win,
    displayId: display.id,
    snapshot,
    ready: false,
  };
  session.overlays.push(entry);

  win.webContents.once('did-finish-load', () => {
    if (win.isDestroyed()) return;
    entry.ready = true;
    win.webContents.send('capture:init', {
      png: snapshot.png,
      display: {
        id: display.id,
        bounds: display.bounds,
        scaleFactor: display.scaleFactor,
      },
      mode: session.mode,
    });
    if (captureSession !== session) return;
    win.show();
    win.focus();
  });

  win.webContents.on('before-input-event', (event, input) => {
    if (input.type !== 'keyDown') return;
    if (input.key === 'Escape' || input.code === 'Escape') {
      event.preventDefault();
      if (captureSession === session) cancelCapture();
    }
  });

  win.on('closed', () => {
    entry.win = null;
    if (captureSession === session) {
      const anyAlive = session.overlays.some((item) => item.win && !item.win.isDestroyed());
      if (!anyAlive) cancelCapture();
    }
  });

  loadRenderer(win, 'capture.html').catch((error) => warn('抓屏覆盖层加载失败:', error.message));
}

function cancelCapture() {
  if (!captureSession) return;
  const session = captureSession;
  captureSession = null;
  session.done = true;
  for (const entry of session.overlays) {
    if (entry.win && !entry.win.isDestroyed()) entry.win.destroy();
  }
  session.overlays = [];
  restoreAfterCapture(session.hiddenPins);
  refreshTrayMenu();
}

function cropSelection(snapshot, rect) {
  const display = snapshot.display;
  const bounds = display.bounds;
  const rawX = Number(rect && rect.x);
  const rawY = Number(rect && rect.y);
  const rawW = Number(rect && rect.width);
  const rawH = Number(rect && rect.height);
  if (![rawX, rawY, rawW, rawH].every((value) => Number.isFinite(value))) return null;

  const x = clamp(rawX, 0, bounds.width);
  const y = clamp(rawY, 0, bounds.height);
  const width = clamp(rawW, 1, bounds.width - x);
  const height = clamp(rawH, 1, bounds.height - y);
  if (width < 2 || height < 2) return null;

  const image = nativeImage.createFromBuffer(snapshot.png);
  const imageSize = image.getSize();
  if (imageSize.width < 2 || imageSize.height < 2) return null;

  const ratioX = imageSize.width / Math.max(bounds.width, 1);
  const ratioY = imageSize.height / Math.max(bounds.height, 1);

  let px = clamp(Math.floor(x * ratioX), 0, imageSize.width - 1);
  let py = clamp(Math.floor(y * ratioY), 0, imageSize.height - 1);
  let pw = clamp(Math.round(width * ratioX), 1, imageSize.width - px);
  let ph = clamp(Math.round(height * ratioY), 1, imageSize.height - py);

  const cropped = image.crop({ x: px, y: py, width: pw, height: ph });
  const croppedSize = cropped.getSize();
  if (!croppedSize || croppedSize.width < 1 || croppedSize.height < 1) return null;

  const png = cropped.toPNG();
  if (!png || png.length === 0) return null;

  return {
    png,
    pixelSize: croppedSize,
    pointSize: {
      width: Math.max(1, Math.round(width)),
      height: Math.max(1, Math.round(height)),
    },
    globalRect: {
      x: Math.round(bounds.x + x),
      y: Math.round(bounds.y + y),
      width: Math.max(1, Math.round(width)),
      height: Math.max(1, Math.round(height)),
    },
  };
}

function showCaptureFailure() {
  const body = IS_MAC
    ? '无法获取屏幕画面。请在「系统设置 → 隐私与安全性 → 屏幕录制」中授权 PinShot，然后重新启动应用。'
    : '无法获取屏幕画面。请确认没有其他程序占用屏幕捕获，或重新启动 PinShot 后再试。';
  notify('截图失败', body);
}

// ---------------------------------------------------------------------------
// 标注编辑器
// ---------------------------------------------------------------------------

function openAnnotationEditor({ png, pixelSize, pointSize, anchorRect, mode, hiddenPins }) {
  const centerPoint = {
    x: (anchorRect ? anchorRect.x + anchorRect.width / 2 : 0) + 1,
    y: (anchorRect ? anchorRect.y + anchorRect.height / 2 : 0) + 1,
  };
  const display = screen.getDisplayNearestPoint(centerPoint);
  const workArea = display.workArea;

  const maxDisplayWidth = Math.max(160, Math.min(workArea.width * 0.8, workArea.width - 120));
  const maxDisplayHeight = Math.max(120, Math.min(workArea.height * 0.72, workArea.height - 240));
  const scale = Math.min(1, maxDisplayWidth / Math.max(pointSize.width, 1), maxDisplayHeight / Math.max(pointSize.height, 1));
  const displaySize = {
    width: Math.max(1, Math.round(pointSize.width * scale)),
    height: Math.max(1, Math.round(pointSize.height * scale)),
  };

  const contentWidth = Math.max(displaySize.width + EDITOR_LAYOUT.padding * 2 + 48, 880);
  const contentHeight =
    displaySize.height +
    EDITOR_LAYOUT.padding * 2 +
    EDITOR_LAYOUT.topInset +
    EDITOR_LAYOUT.toolbarHeight +
    EDITOR_LAYOUT.toolbarGap +
    EDITOR_LAYOUT.hintGap +
    EDITOR_LAYOUT.hintHeight +
    EDITOR_LAYOUT.bottomInset;

  const windowWidth = Math.min(contentWidth, workArea.width - 24);
  const windowHeight = Math.min(contentHeight, workArea.height - 24);
  const x = Math.round(workArea.x + (workArea.width - windowWidth) / 2);
  const y = Math.round(workArea.y + (workArea.height - windowHeight) / 2);

  const win = makeWindow({
    x,
    y,
    width: windowWidth,
    height: windowHeight,
    useContentSize: true,
    resizable: false,
    focusable: true,
    alwaysOnTop: true,
    skipTaskbar: true,
    title: 'PinShot 标注',
  });
  win.setAlwaysOnTop(true, 'screen-saver');

  const entry = {
    win,
    mode,
    pointSize,
    pixelSize,
    anchorRect: anchorRect || { x, y, width: windowWidth, height: windowHeight },
    hiddenPins: hiddenPins || [],
    finished: false,
    webContentsId: win.webContents.id,
  };
  editorSessions.set(entry.webContentsId, entry);

  win.webContents.once('did-finish-load', () => {
    if (win.isDestroyed()) return;
    win.webContents.send('editor:init', {
      png,
      pixelSize,
      pointSize,
      displaySize,
      layout: EDITOR_LAYOUT,
      mode,
    });
    win.show();
    win.focus();
  });

  win.webContents.on('before-input-event', (event, input) => {
    if (input.type !== 'keyDown') return;
    if (input.key === 'Escape') {
      event.preventDefault();
      finishEditor(entry, { cancel: true });
    }
  });

  win.on('closed', () => {
    editorSessions.delete(entry.webContentsId);
    if (!entry.finished) {
      entry.finished = true;
      restoreAfterCapture(entry.hiddenPins);
    }
  });

  loadRenderer(win, 'editor.html').catch((error) => {
    warn('标注编辑器加载失败:', error.message);
    finishEditor(entry, { cancel: true });
  });

  return entry;
}

function closeEditorWindow(entry) {
  if (!entry || entry.finished) return;
  entry.finished = true;
  if (entry.win && !entry.win.isDestroyed()) entry.win.destroy();
  editorSessions.delete(entry.webContentsId);
  restoreAfterCapture(entry.hiddenPins);
}

async function finishEditor(entry, payload) {
  if (!entry || entry.finished) return;
  if (payload && payload.cancel) {
    closeEditorWindow(entry);
    return;
  }

  const png = toBuffer(payload && payload.bytes);
  const action = payload && payload.action;
  if (!png || png.length === 0) {
    closeEditorWindow(entry);
    return;
  }
  if (!['finish', 'copy', 'save'].includes(action)) {
    closeEditorWindow(entry);
    return;
  }

  closeEditorWindow(entry);

  const effectiveAction = action === 'finish' && entry.mode === 'copy' ? 'copy' : action;
  if (effectiveAction === 'copy') {
    copyPngToClipboard(png);
    return;
  }
  if (effectiveAction === 'finish') {
    createPin({
      png,
      pixelSize: entry.pixelSize,
      pointSize: entry.pointSize,
      rect: entry.anchorRect,
      placement: settings.defaultPinDesktop ? 'desktop' : 'floating',
    });
    return;
  }
  if (effectiveAction === 'save') {
    await savePngWithDialog(png, null);
  }
}

function copyPngToClipboard(png) {
  try {
    const image = nativeImage.createFromBuffer(png);
    if (image.isEmpty()) {
      notify('复制失败', '无法把截图编码成图片。');
      return;
    }
    clipboard.writeImage(image);
    log('已复制截图到剪贴板');
  } catch (error) {
    warn('复制失败:', error.message);
    notify('复制失败', error.message);
  }
}

async function savePngWithDialog(png, parentWin) {
  if (!png || png.length === 0) return false;
  const options = {
    title: '存储截图',
    defaultPath: path.join(app.getPath('desktop'), `PinShot-${formatTimestamp()}.png`),
    filters: [{ name: 'PNG 图片', extensions: ['png'] }],
  };
  let result;
  try {
    result =
      parentWin && !parentWin.isDestroyed()
        ? await dialog.showSaveDialog(parentWin, options)
        : await dialog.showSaveDialog(options);
  } catch (error) {
    warn('保存对话框失败:', error.message);
    return false;
  }
  if (result.canceled || !result.filePath) return false;
  let filePath = result.filePath;
  if (!/\.png$/i.test(filePath)) filePath += '.png';
  try {
    fs.writeFileSync(filePath, png);
    log('已保存截图:', filePath);
    return true;
  } catch (error) {
    warn('保存截图失败:', error.message);
    notify('保存失败', error.message);
    return false;
  }
}

// ---------------------------------------------------------------------------
// 从剪贴板贴图
// ---------------------------------------------------------------------------

function pinFromClipboard() {
  if (isCaptureBusy()) return;
  let image;
  try {
    image = clipboard.readImage();
  } catch (error) {
    warn('读取剪贴板失败:', error.message);
    image = null;
  }
  if (!image || image.isEmpty()) {
    notify('剪贴板里没有图片', '先用系统截图（Win+Shift+S）把图片复制到剪贴板，再按 Ctrl+Shift+3。');
    return;
  }

  const size = image.getSize();
  if (!size || size.width < 2 || size.height < 2) {
    notify('剪贴板图片无效', '剪贴板里的图片尺寸太小。');
    return;
  }

  const cursorPoint = screen.getCursorScreenPoint();
  const display = screen.getDisplayNearestPoint(cursorPoint);
  const workArea = display.workArea;
  const fitScale = Math.min(
    1,
    (workArea.width * 0.7) / size.width,
    (workArea.height * 0.7) / size.height,
  );
  const pointSize = {
    width: Math.max(1, Math.round(size.width * fitScale)),
    height: Math.max(1, Math.round(size.height * fitScale)),
  };
  const anchorRect = {
    x: Math.round(workArea.x + (workArea.width - pointSize.width) / 2),
    y: Math.round(workArea.y + (workArea.height - pointSize.height) / 2),
    width: pointSize.width,
    height: pointSize.height,
  };

  try {
    openAnnotationEditor({
      png: image.toPNG(),
      pixelSize: size,
      pointSize,
      anchorRect,
      mode: 'pin',
      hiddenPins: [],
    });
  } catch (error) {
    warn('打开剪贴板贴图失败:', error.message);
    notify('从剪贴板贴图失败', error.message);
  }
}

// ---------------------------------------------------------------------------
// 贴图窗口
// ---------------------------------------------------------------------------

function fitCardToWorkArea(pointSize, workArea) {
  const scale = Math.min(
    1,
    (workArea.width * 0.7) / Math.max(pointSize.width, 1),
    (workArea.height * 0.7) / Math.max(pointSize.height, 1),
  );
  let width = Math.max(MIN_CARD, Math.round(pointSize.width * scale));
  let height = Math.max(MIN_CARD, Math.round(pointSize.height * scale));
  const ratio = pointSize.width / Math.max(pointSize.height, 1);
  if (width / height > ratio) width = Math.max(MIN_CARD, Math.round(height * ratio));
  else height = Math.max(MIN_CARD, Math.round(width / ratio));
  return { width, height };
}

function clampPinBounds(bounds, workArea) {
  const width = Math.min(Math.round(bounds.width), Math.round(workArea.width));
  const height = Math.min(Math.round(bounds.height), Math.round(workArea.height));
  const x = clamp(Math.round(bounds.x), Math.round(workArea.x), Math.round(workArea.x + workArea.width - width));
  const y = clamp(Math.round(bounds.y), Math.round(workArea.y), Math.round(workArea.y + workArea.height - height));
  return { x, y, width, height };
}

function pinBoundsForCard(card, cardLeft, cardTop) {
  return {
    x: Math.round(cardLeft - PIN_MARGIN),
    y: Math.round(cardTop - PIN_MARGIN),
    width: Math.round(card.width) + PIN_MARGIN * 2,
    height: Math.round(card.height) + PIN_MARGIN * 2,
  };
}

function createPin({ png, pixelSize, pointSize, rect, placement }) {
  const centerPoint = rect
    ? { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 }
    : screen.getCursorScreenPoint();
  const display = screen.getDisplayNearestPoint(centerPoint);
  const workArea = display.workArea;

  const card = fitCardToWorkArea(pointSize, workArea);
  let cardLeft;
  let cardTop;
  if (rect) {
    cardLeft = rect.x;
    cardTop = rect.y;
  } else {
    cardLeft = workArea.x + (workArea.width - card.width) / 2;
    cardTop = workArea.y + (workArea.height - card.height) / 2;
  }

  const resolvedPlacement = placement === 'desktop' ? 'desktop' : 'floating';
  const bounds = clampPinBounds(pinBoundsForCard(card, cardLeft, cardTop), workArea);

  const win = makeWindow({
    x: bounds.x,
    y: bounds.y,
    width: bounds.width,
    height: bounds.height,
    resizable: false,
    movable: true,
    focusable: true,
    alwaysOnTop: resolvedPlacement !== 'desktop',
    skipTaskbar: true,
    hasShadow: false,
    title: 'PinShot 贴图',
  });
  if (resolvedPlacement === 'desktop') {
    win.setAlwaysOnTop(false);
  } else {
    win.setAlwaysOnTop(true, 'floating');
  }

  const id = ++pinSeq;
  const pin = {
    id,
    win,
    png,
    pixelSize,
    pointSize,
    card,
    placement: resolvedPlacement,
    forcedHidden: false,
    autoHidden: false,
    hovered: false,
    leaveAt: null,
    interacting: false,
    userAlpha: 1,
    drag: null,
    dragTimer: null,
    resize: null,
    resizeTimer: null,
    lastOpacity: null,
    lastClickThrough: null,
    lastStateKey: null,
  };
  pins.set(id, pin);

  if (allForcedHidden) {
    allForcedHidden = false;
    for (const other of pins.values()) {
      if (other !== pin && other.forcedHidden) setPinForcedHidden(other, false);
    }
  }

  win.webContents.once('did-finish-load', () => {
    if (win.isDestroyed()) return;
    sendPinInit(pin);
    win.showInactive();
    pin.lastOpacity = null;
    pin.lastClickThrough = null;
    applyPinVisual(pin);
    startAutoHideLoop();
    pollPins(true);
  });

  win.webContents.on('before-input-event', (event, input) => {
    handlePinKeyboard(pin, event, input);
  });

  win.on('blur', () => {
    if (pin.drag) endPinDrag(pin);
    if (pin.resize) endPinResize(pin);
  });

  win.on('hide', () => {
    if (pin.drag) endPinDrag(pin, { silent: true });
    if (pin.resize) endPinResize(pin, { silent: true });
  });

  win.on('closed', () => {
    clearPinTimers(pin);
    pins.delete(id);
    if (pins.size === 0) {
      allForcedHidden = false;
      stopAutoHideLoop();
    }
    refreshTrayMenu();
  });

  loadRenderer(win, 'pin.html').catch((error) => warn('贴图窗口加载失败:', error.message));
  refreshTrayMenu();
  startAutoHideLoop();
  return pin;
}

function sendPinInit(pin) {
  if (!pin || pin.win.isDestroyed()) return;
  pin.win.webContents.send('pin:init', {
    png: pin.png,
    pixelSize: pin.pixelSize,
    pointSize: pin.pointSize,
    card: pin.card,
    margin: PIN_MARGIN,
    placement: pin.placement,
    settings: settingsSnapshot(),
  });
}

function applyPinVisual(pin) {
  if (!pin || pin.win.isDestroyed()) return;
  const autoHidden = pin.autoHidden && !pin.forcedHidden && pin.placement !== 'desktop';
  let opacity = pin.userAlpha;
  if (autoHidden) opacity *= settings.hideEntirely ? 0 : settings.ghostAlpha;
  opacity = clamp(opacity, 0, 1);

  if (pin.lastOpacity !== opacity) {
    pin.lastOpacity = opacity;
    try {
      pin.win.setOpacity(opacity);
    } catch (error) {
      warn('setOpacity 失败:', error.message);
    }
  }

  const clickThrough = autoHidden && settings.clickThroughWhenHidden;
  if (pin.lastClickThrough !== clickThrough) {
    pin.lastClickThrough = clickThrough;
    try {
      pin.win.setIgnoreMouseEvents(clickThrough, { forward: true });
    } catch (error) {
      warn('setIgnoreMouseEvents 失败:', error.message);
    }
  }

  const stateKey = `${autoHidden ? 1 : 0}|${pin.placement}|${settings.autoHideEnabled ? 1 : 0}`;
  if (pin.lastStateKey !== stateKey) {
    pin.lastStateKey = stateKey;
    sendPinEvent(pin, 'pin:state', {
      autoHidden,
      placement: pin.placement,
      autoHideEnabled: settings.autoHideEnabled,
    });
  }
}

function sendPinEvent(pin, channel, payload) {
  if (!pin || pin.win.isDestroyed()) return;
  try {
    pin.win.webContents.send(channel, payload);
  } catch (error) {
    /* 忽略销毁中的窗口 */
  }
}

function setPinAutoHidden(pin, hidden) {
  if (!pin || pin.autoHidden === hidden) return;
  pin.autoHidden = hidden;
  if (!hidden) pin.leaveAt = null;
  applyPinVisual(pin);
}

function updatePinHover(pin, inside) {
  if (!pin || pin.hovered === inside) return;
  pin.hovered = inside;
  sendPinEvent(pin, 'pin:hover', { inside });
}

function setPinForcedHidden(pin, hidden) {
  if (!pin || pin.win.isDestroyed()) return;
  pin.forcedHidden = hidden;
  if (hidden) {
    pin.autoHidden = false;
    pin.leaveAt = null;
    updatePinHover(pin, false);
    pin.win.hide();
    applyPinVisual(pin);
  } else {
    pin.autoHidden = false;
    pin.leaveAt = null;
    pin.win.showInactive();
    pin.lastOpacity = null;
    pin.lastClickThrough = null;
    applyPinVisual(pin);
  }
}

function toggleHideAllPins() {
  if (pins.size === 0) return;
  allForcedHidden = !allForcedHidden;
  for (const pin of pins.values()) setPinForcedHidden(pin, allForcedHidden);
  refreshTrayMenu();
}

function closePin(pin) {
  if (!pin || pin.win.isDestroyed()) return;
  pin.win.close();
}

function closeAllPins() {
  const current = Array.from(pins.values());
  for (const pin of current) {
    if (!pin.win.isDestroyed()) pin.win.close();
  }
  allForcedHidden = false;
  refreshTrayMenu();
  stopAutoHideLoop();
}

function setAllPlacement(placement) {
  for (const pin of pins.values()) setPinPlacement(pin, placement);
}

function setPinPlacement(pin, placement) {
  if (!pin || pin.win.isDestroyed()) return;
  const next = placement === 'desktop' ? 'desktop' : 'floating';
  if (pin.placement === next) return;
  pin.placement = next;
  if (next === 'desktop') {
    pin.win.setAlwaysOnTop(false);
    pin.autoHidden = false;
    pin.leaveAt = null;
  } else {
    pin.win.setAlwaysOnTop(true, 'floating');
    pin.win.moveTop();
  }
  pin.lastOpacity = null;
  pin.lastClickThrough = null;
  pin.lastStateKey = null;
  applyPinVisual(pin);
  pollPins(true);
}

function setPinScale(pin, factor) {
  if (!pin || pin.win.isDestroyed()) return;
  const bounds = pin.win.getBounds();
  const center = { x: bounds.x + bounds.width / 2, y: bounds.y + bounds.height / 2 };
  const display = screen.getDisplayNearestPoint(center);
  const workArea = display.workArea;
  const base = pin.pointSize;
  const ratio = base.width / Math.max(base.height, 1);

  let cardWidth;
  if (factor <= 0) {
    const maxWidth = workArea.width * 0.8;
    const maxHeight = workArea.height * 0.8;
    cardWidth = Math.min(base.width, maxWidth, maxHeight * ratio);
  } else {
    cardWidth = base.width * factor;
  }
  cardWidth = Math.max(MIN_CARD, cardWidth);
  let cardHeight = cardWidth / ratio;
  if (cardHeight < MIN_CARD) {
    cardHeight = MIN_CARD;
    cardWidth = cardHeight * ratio;
  }
  const maxCardWidth = workArea.width - PIN_MARGIN * 2;
  const maxCardHeight = workArea.height - PIN_MARGIN * 2;
  if (cardWidth > maxCardWidth) {
    cardWidth = maxCardWidth;
    cardHeight = cardWidth / ratio;
  }
  if (cardHeight > maxCardHeight) {
    cardHeight = maxCardHeight;
    cardWidth = cardHeight * ratio;
  }

  const card = { width: Math.round(cardWidth), height: Math.round(cardHeight) };
  const nextBounds = clampPinBounds(
    pinBoundsForCard(card, center.x - card.width / 2, center.y - card.height / 2),
    workArea,
  );
  pin.card = card;
  pin.win.setBounds(nextBounds);
  sendPinEvent(pin, 'pin:toast', { text: factor <= 0 ? '适合屏幕' : `${Math.round(factor * 100)}%` });
}

function beginPinDrag(pin) {
  if (!pin || pin.win.isDestroyed() || pin.forcedHidden) return;
  endPinDrag(pin, { silent: true });
  try {
    pin.win.focus();
  } catch (error) {
    /* 忽略 */
  }
  const startCursor = screen.getCursorScreenPoint();
  const startBounds = pin.win.getBounds();
  pin.drag = { startCursor, startBounds };
  pin.interacting = true;
  pin.leaveAt = null;
  pin.autoHidden = false;
  applyPinVisual(pin);
  updatePinHover(pin, true);
  sendPinEvent(pin, 'pin:dragging', { active: true });

  pin.dragTimer = setInterval(() => {
    if (!pin.drag || pin.win.isDestroyed()) return;
    const cursor = screen.getCursorScreenPoint();
    const dx = cursor.x - pin.drag.startCursor.x;
    const dy = cursor.y - pin.drag.startCursor.y;
    const display = screen.getDisplayNearestPoint(cursor);
    const nextBounds = clampPinBounds(
      {
        x: pin.drag.startBounds.x + dx,
        y: pin.drag.startBounds.y + dy,
        width: pin.drag.startBounds.width,
        height: pin.drag.startBounds.height,
      },
      display.workArea,
    );
    if (!sameRect(pin.win.getBounds(), nextBounds)) pin.win.setBounds(nextBounds);
  }, DRAG_POLL_MS);
}

function endPinDrag(pin, options = {}) {
  if (!pin || !pin.drag) return;
  if (pin.dragTimer) {
    clearInterval(pin.dragTimer);
    pin.dragTimer = null;
  }
  pin.drag = null;
  pin.interacting = false;
  pin.leaveAt = null;
  if (!options.silent) {
    sendPinEvent(pin, 'pin:dragging', { active: false });
    pollPins(true);
  }
}

function beginPinResize(pin, corner) {
  if (!pin || pin.win.isDestroyed() || pin.forcedHidden) return;
  if (!['top-left', 'top-right', 'bottom-left', 'bottom-right'].includes(corner)) return;
  endPinResize(pin, { silent: true });
  try {
    pin.win.focus();
  } catch (error) {
    /* 忽略 */
  }
  const startCursor = screen.getCursorScreenPoint();
  const startBounds = pin.win.getBounds();
  const startCard = { width: Math.round(pin.card.width), height: Math.round(pin.card.height) };
  const ratio = startCard.width / Math.max(startCard.height, 1);
  const display = screen.getDisplayNearestPoint({
    x: startBounds.x + startBounds.width / 2,
    y: startBounds.y + startBounds.height / 2,
  });

  const cardLeft = startBounds.x + PIN_MARGIN;
  const cardTop = startBounds.y + PIN_MARGIN;
  const anchor = {
    x: corner.includes('left') ? cardLeft + startCard.width : cardLeft,
    y: corner.includes('top') ? cardTop + startCard.height : cardTop,
  };

  pin.resize = {
    corner,
    startCursor,
    startCard,
    ratio,
    anchor,
    workArea: display.workArea,
  };
  pin.interacting = true;
  pin.leaveAt = null;
  pin.autoHidden = false;
  applyPinVisual(pin);
  updatePinHover(pin, true);

  pin.resizeTimer = setInterval(() => updatePinResize(pin), DRAG_POLL_MS);
}

function updatePinResize(pin) {
  const resize = pin.resize;
  if (!resize || pin.win.isDestroyed()) return;
  const cursor = screen.getCursorScreenPoint();
  const dx = cursor.x - resize.startCursor.x;
  const dy = cursor.y - resize.startCursor.y;
  const horizontalSign = resize.corner.includes('right') ? 1 : -1;
  const verticalSign = resize.corner.includes('top') ? -1 : 1;

  let proposedWidth;
  if (Math.abs(dx) >= Math.abs(dy)) {
    proposedWidth = resize.startCard.width + dx * horizontalSign;
  } else {
    proposedWidth = (resize.startCard.height + dy * verticalSign) * resize.ratio;
  }

  const workArea = resize.workArea;
  const maxWidthX =
    horizontalSign > 0 ? workArea.x + workArea.width - resize.anchor.x : resize.anchor.x - workArea.x;
  const maxHeightY =
    verticalSign > 0 ? workArea.y + workArea.height - resize.anchor.y : resize.anchor.y - workArea.y;
  const maxWidth = Math.max(MIN_CARD, Math.min(maxWidthX, maxHeightY * resize.ratio));
  let cardWidth = clamp(proposedWidth, MIN_CARD, maxWidth);
  let cardHeight = cardWidth / resize.ratio;
  if (cardHeight < MIN_CARD) {
    cardHeight = MIN_CARD;
    cardWidth = cardHeight * resize.ratio;
  }
  const maxCardWidth = workArea.width - PIN_MARGIN * 2;
  const maxCardHeight = workArea.height - PIN_MARGIN * 2;
  if (cardWidth > maxCardWidth) {
    cardWidth = maxCardWidth;
    cardHeight = cardWidth / resize.ratio;
  }
  if (cardHeight > maxCardHeight) {
    cardHeight = maxCardHeight;
    cardWidth = cardHeight * resize.ratio;
  }

  const width = Math.max(MIN_CARD, Math.round(cardWidth));
  const height = Math.max(MIN_CARD, Math.round(cardHeight));
  const cardLeft = horizontalSign > 0 ? resize.anchor.x : resize.anchor.x - width;
  const cardTop = verticalSign > 0 ? resize.anchor.y : resize.anchor.y - height;
  const nextBounds = {
    x: Math.round(cardLeft - PIN_MARGIN),
    y: Math.round(cardTop - PIN_MARGIN),
    width: width + PIN_MARGIN * 2,
    height: height + PIN_MARGIN * 2,
  };
  pin.card = { width, height };
  pin.win.setBounds(nextBounds);
  sendPinEvent(pin, 'pin:resizing', { width, height });
}

function endPinResize(pin, options = {}) {
  if (!pin || !pin.resize) return;
  if (pin.resizeTimer) {
    clearInterval(pin.resizeTimer);
    pin.resizeTimer = null;
  }
  pin.resize = null;
  pin.interacting = false;
  pin.leaveAt = null;
  if (!options.silent) {
    sendPinEvent(pin, 'pin:resizing', null);
    pollPins(true);
  }
}

function clearPinTimers(pin) {
  if (!pin) return;
  if (pin.dragTimer) clearInterval(pin.dragTimer);
  if (pin.resizeTimer) clearInterval(pin.resizeTimer);
  pin.dragTimer = null;
  pin.resizeTimer = null;
  pin.drag = null;
  pin.resize = null;
}

function nudgePin(pin, dx, dy) {
  if (!pin || pin.win.isDestroyed()) return;
  const bounds = pin.win.getBounds();
  const display = screen.getDisplayNearestPoint({
    x: bounds.x + bounds.width / 2,
    y: bounds.y + bounds.height / 2,
  });
  const nextBounds = clampPinBounds(
    { x: bounds.x + dx, y: bounds.y + dy, width: bounds.width, height: bounds.height },
    display.workArea,
  );
  pin.win.setBounds(nextBounds);
}

function handlePinKeyboard(pin, event, input) {
  if (!pin || input.type !== 'keyDown') return;
  const modifier = IS_MAC ? input.meta : input.control;
  const key = (input.key || '').toLowerCase();
  const step = input.shift ? 10 : 1;

  if (modifier && key === 'c') {
    event.preventDefault();
    copyPin(pin);
    return;
  }
  if (modifier && key === 's') {
    event.preventDefault();
    savePin(pin);
    return;
  }
  if (modifier && key === 'w') {
    event.preventDefault();
    closePin(pin);
    return;
  }
  if (input.key === 'Escape') {
    event.preventDefault();
    closePin(pin);
    return;
  }
  if (input.key === 'ArrowLeft') {
    event.preventDefault();
    nudgePin(pin, -step, 0);
  } else if (input.key === 'ArrowRight') {
    event.preventDefault();
    nudgePin(pin, step, 0);
  } else if (input.key === 'ArrowUp') {
    event.preventDefault();
    nudgePin(pin, 0, -step);
  } else if (input.key === 'ArrowDown') {
    event.preventDefault();
    nudgePin(pin, 0, step);
  }
}

function copyPin(pin) {
  if (!pin) return;
  copyPngToClipboard(pin.png);
  sendPinEvent(pin, 'pin:toast', { text: '已复制' });
}

async function savePin(pin) {
  if (!pin) return;
  const ok = await savePngWithDialog(pin.png, pin.win);
  if (ok) sendPinEvent(pin, 'pin:toast', { text: '已保存' });
}

function showPinContextMenu(pin) {
  if (!pin || pin.win.isDestroyed()) return;
  try {
    pin.win.focus();
  } catch (error) {
    /* 忽略 */
  }
  const factor = pin.card.width / Math.max(pin.pointSize.width, 1);
  const scaleItem = (label, percent) => ({
    label,
    type: 'radio',
    checked: percent > 0 && Math.abs(factor - percent / 100) < 0.02,
    click: () => setPinScale(pin, percent > 0 ? percent / 100 : 0),
  });
  const opacityItem = (percent) => ({
    label: `${percent}%`,
    type: 'radio',
    checked: Math.abs(pin.userAlpha - percent / 100) < 0.01,
    click: () => {
      pin.userAlpha = percent / 100;
      pin.lastOpacity = null;
      applyPinVisual(pin);
    },
  });

  const template = [
    { label: '复制图片', accelerator: 'CmdOrCtrl+C', click: () => copyPin(pin) },
    { label: '存储为…', accelerator: 'CmdOrCtrl+S', click: () => savePin(pin) },
    { type: 'separator' },
    {
      label: '自动隐藏',
      type: 'checkbox',
      checked: settings.autoHideEnabled,
      click: () => updateSettings({ autoHideEnabled: !settings.autoHideEnabled }),
    },
    {
      label: '贴在桌面',
      type: 'checkbox',
      checked: pin.placement === 'desktop',
      click: () => setPinPlacement(pin, pin.placement === 'desktop' ? 'floating' : 'desktop'),
    },
    {
      label: '缩放',
      submenu: [
        scaleItem('100%', 100),
        scaleItem('75%', 75),
        scaleItem('50%', 50),
        scaleItem('25%', 25),
        scaleItem('适合屏幕', 0),
      ],
    },
    {
      label: '不透明度',
      submenu: [opacityItem(100), opacityItem(80), opacityItem(60), opacityItem(40)],
    },
    { type: 'separator' },
    { label: '关闭', accelerator: 'Esc', click: () => closePin(pin) },
    { label: '全部关闭', click: () => closeAllPins() },
  ];
  Menu.buildFromTemplate(template).popup({ window: pin.win });
}

// ---------------------------------------------------------------------------
// 自动隐藏轮询
// ---------------------------------------------------------------------------

function startAutoHideLoop() {
  if (autoHideTimer) return;
  autoHideTimer = setInterval(() => pollPins(false), AUTO_HIDE_POLL_MS);
}

function stopAutoHideLoop() {
  if (!autoHideTimer) return;
  clearInterval(autoHideTimer);
  autoHideTimer = null;
}

function pinContainsCursor(pin, cursor) {
  const bounds = pin.win.getBounds();
  return (
    cursor.x >= bounds.x - 2 &&
    cursor.x <= bounds.x + bounds.width + 2 &&
    cursor.y >= bounds.y - 2 &&
    cursor.y <= bounds.y + bounds.height + 2
  );
}

function pollPins(immediate) {
  if (pins.size === 0) {
    stopAutoHideLoop();
    return;
  }
  const cursor = screen.getCursorScreenPoint();
  const now = Date.now();

  for (const pin of pins.values()) {
    if (pin.win.isDestroyed()) continue;
    if (pin.forcedHidden) {
      updatePinHover(pin, false);
      continue;
    }
    if (pin.drag || pin.resize) {
      pin.interacting = true;
      pin.leaveAt = null;
      pin.autoHidden = false;
      applyPinVisual(pin);
      updatePinHover(pin, true);
      continue;
    }
    pin.interacting = false;
    const inside = pinContainsCursor(pin, cursor);

    if (pin.placement === 'desktop') {
      pin.leaveAt = null;
      pin.autoHidden = false;
      applyPinVisual(pin);
      updatePinHover(pin, inside);
      continue;
    }

    if (!settings.autoHideEnabled) {
      pin.leaveAt = null;
      pin.autoHidden = false;
      applyPinVisual(pin);
      updatePinHover(pin, inside);
      continue;
    }

    if (inside) {
      pin.leaveAt = null;
      setPinAutoHidden(pin, false);
      updatePinHover(pin, true);
    } else {
      updatePinHover(pin, false);
      if (pin.leaveAt == null) pin.leaveAt = now;
      if (now - pin.leaveAt >= settings.autoHideDelay * 1000) setPinAutoHidden(pin, true);
    }
  }

  if (immediate) {
    // 仅用于设置变化 / 交互结束时立即刷新，不需要额外行为
  }
}

// ---------------------------------------------------------------------------
// 截图会话：隐藏 / 恢复已有贴图
// ---------------------------------------------------------------------------

function hideAllForCapture() {
  const hidden = [];
  for (const pin of pins.values()) {
    if (pin.forcedHidden) continue;
    if (pin.win.isDestroyed() || !pin.win.isVisible()) continue;
    pin.win.hide();
    hidden.push(pin);
  }
  return hidden;
}

function restoreAfterCapture(hiddenPins) {
  if (!Array.isArray(hiddenPins)) return;
  for (const pin of hiddenPins) {
    if (!pins.has(pin.id) || pin.win.isDestroyed() || pin.forcedHidden) continue;
    pin.autoHidden = false;
    pin.leaveAt = null;
    pin.lastOpacity = null;
    pin.lastClickThrough = null;
    pin.win.showInactive();
    applyPinVisual(pin);
  }
  refreshTrayMenu();
  pollPins(true);
}

// ---------------------------------------------------------------------------
// 设置窗口
// ---------------------------------------------------------------------------

function showSettings(pane) {
  pendingSettingsPane = pane || null;
  if (settingsWindow && !settingsWindow.isDestroyed()) {
    settingsWindow.show();
    settingsWindow.focus();
    if (pendingSettingsPane) {
      settingsWindow.webContents.send('settings:focus-pane', pendingSettingsPane);
      pendingSettingsPane = null;
    }
    return;
  }

  const display = screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
  const workArea = display.workArea;
  const width = Math.min(860, workArea.width - 40);
  const height = Math.min(620, workArea.height - 40);
  const x = Math.round(workArea.x + (workArea.width - width) / 2);
  const y = Math.round(workArea.y + (workArea.height - height) / 2);

  settingsWindow = makeWindow({
    x,
    y,
    width,
    height,
    resizable: false,
    minimizable: false,
    maximizable: false,
    alwaysOnTop: false,
    skipTaskbar: true,
    title: 'PinShot 设置',
  });

  settingsWindow.once('ready-to-show', () => {
    if (!settingsWindow || settingsWindow.isDestroyed()) return;
    settingsWindow.show();
    settingsWindow.focus();
  });

  settingsWindow.webContents.once('did-finish-load', () => {
    if (!settingsWindow || settingsWindow.isDestroyed()) return;
    settingsWindow.webContents.send('settings:init', settingsSnapshot());
    if (pendingSettingsPane) {
      settingsWindow.webContents.send('settings:focus-pane', pendingSettingsPane);
      pendingSettingsPane = null;
    }
  });

  settingsWindow.on('closed', () => {
    settingsWindow = null;
    pendingSettingsPane = null;
  });

  loadRenderer(settingsWindow, 'settings.html').catch((error) =>
    warn('设置窗口加载失败:', error.message),
  );
}

function closeSettings() {
  if (settingsWindow && !settingsWindow.isDestroyed()) settingsWindow.close();
}

// ---------------------------------------------------------------------------
// IPC
// ---------------------------------------------------------------------------

function pinForEvent(event) {
  for (const pin of pins.values()) {
    if (!pin.win.isDestroyed() && pin.win.webContents.id === event.sender.id) return pin;
  }
  return null;
}

function editorForEvent(event) {
  return editorSessions.get(event.sender.id) || null;
}

function overlayForEvent(event) {
  if (!captureSession) return null;
  return captureSession.overlays.find((entry) => entry.win && entry.win.webContents.id === event.sender.id) || null;
}

function registerIpc() {
  ipcMain.handle('capture:select', async (event, rect) => {
    const session = captureSession;
    if (!session) return { ok: false };
    const overlay = overlayForEvent(event);
    if (!overlay) return { ok: false };

    const cropped = cropSelection(overlay.snapshot, rect);
    if (!cropped) {
      cancelCapture();
      return { ok: false };
    }

    // 关闭覆盖层，但保留已隐藏的贴图，等编辑器结束后再恢复
    captureSession = null;
    session.done = true;
    for (const entry of session.overlays) {
      if (entry.win && !entry.win.isDestroyed()) entry.win.destroy();
    }
    session.overlays = [];

    try {
      openAnnotationEditor({
        png: cropped.png,
        pixelSize: cropped.pixelSize,
        pointSize: cropped.pointSize,
        anchorRect: cropped.globalRect,
        mode: session.mode,
        hiddenPins: session.hiddenPins,
      });
    } catch (error) {
      warn('打开标注编辑器失败:', error.message);
      restoreAfterCapture(session.hiddenPins);
      return { ok: false };
    }
    return { ok: true };
  });

  ipcMain.handle('capture:cancel', async () => {
    cancelCapture();
    return { ok: true };
  });

  ipcMain.handle('editor:finish', async (event, payload) => {
    const entry = editorForEvent(event);
    if (!entry) return { ok: false };
    await finishEditor(entry, payload || {});
    return { ok: true };
  });

  ipcMain.handle('editor:cancel', async (event) => {
    const entry = editorForEvent(event);
    if (!entry) return { ok: false };
    closeEditorWindow(entry);
    return { ok: true };
  });

  ipcMain.handle('pin:copy', async (event) => {
    const pin = pinForEvent(event);
    if (!pin) return { ok: false };
    copyPin(pin);
    return { ok: true };
  });

  ipcMain.handle('pin:save', async (event) => {
    const pin = pinForEvent(event);
    if (!pin) return { ok: false };
    await savePin(pin);
    return { ok: true };
  });

  ipcMain.handle('pin:close', async (event) => {
    const pin = pinForEvent(event);
    if (!pin) return { ok: false };
    closePin(pin);
    return { ok: true };
  });

  ipcMain.handle('pin:context-menu', async (event) => {
    const pin = pinForEvent(event);
    if (!pin) return { ok: false };
    showPinContextMenu(pin);
    return { ok: true };
  });

  ipcMain.handle('pin:drag-start', async (event) => {
    const pin = pinForEvent(event);
    if (!pin) return { ok: false };
    beginPinDrag(pin);
    return { ok: true };
  });

  ipcMain.handle('pin:drag-end', async (event) => {
    const pin = pinForEvent(event);
    if (!pin) return { ok: false };
    endPinDrag(pin);
    return { ok: true };
  });

  ipcMain.handle('pin:resize-start', async (event, corner) => {
    const pin = pinForEvent(event);
    if (!pin) return { ok: false };
    beginPinResize(pin, corner);
    return { ok: true };
  });

  ipcMain.handle('pin:resize-end', async (event) => {
    const pin = pinForEvent(event);
    if (!pin) return { ok: false };
    endPinResize(pin);
    return { ok: true };
  });

  ipcMain.handle('pin:nudge', async (event, payload) => {
    const pin = pinForEvent(event);
    if (!pin) return { ok: false };
    const dx = Number(payload && payload.dx) || 0;
    const dy = Number(payload && payload.dy) || 0;
    nudgePin(pin, dx, dy);
    return { ok: true };
  });

  ipcMain.handle('pin:toggle-auto-hide', async () => {
    updateSettings({ autoHideEnabled: !settings.autoHideEnabled });
    return { ok: true, enabled: settings.autoHideEnabled };
  });

  ipcMain.handle('pin:toggle-placement', async (event) => {
    const pin = pinForEvent(event);
    if (!pin) return { ok: false };
    setPinPlacement(pin, pin.placement === 'desktop' ? 'floating' : 'desktop');
    return { ok: true, placement: pin.placement };
  });

  ipcMain.handle('settings:get', async () => settingsSnapshot());

  ipcMain.handle('settings:update', async (event, patch) => {
    if (!patch || typeof patch !== 'object' || Array.isArray(patch)) return settingsSnapshot();
    const filtered = {};
    for (const key of Object.keys(DEFAULT_SETTINGS)) {
      if (key in patch) filtered[key] = patch[key];
    }
    return updateSettings(filtered);
  });

  ipcMain.handle('settings:reset', async () => resetSettings());

  ipcMain.handle('settings:close', async () => {
    closeSettings();
    return { ok: true };
  });
}

// ---------------------------------------------------------------------------
// 冒烟测试
// ---------------------------------------------------------------------------

function waitForLoad(win, timeoutMs = 8000) {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (value) => {
      if (settled) return;
      settled = true;
      resolve(value);
    };
    const timer = setTimeout(() => finish(false), timeoutMs);
    win.webContents.once('did-finish-load', () => {
      clearTimeout(timer);
      finish(true);
    });
    win.webContents.once('did-fail-load', () => {
      clearTimeout(timer);
      finish(false);
    });
  });
}

async function runSmokeTest() {
  const results = {
    tray: false,
    settingsWindow: false,
    settingsRenderer: false,
    settingsFile: false,
    hotkeysRegistered: 0,
    rendererPages: {},
    errors: [],
  };

  const trackErrors = (win, name) => {
    win.webContents.on('console-message', (...args) => {
      let level = args[1];
      let message = args[2];
      if (args[1] && typeof args[1] === 'object') {
        level = args[1].level;
        message = args[1].message;
      }
      if (level === 'error' || level === 3) results.errors.push(`${name}: ${message}`);
    });
  };

  try {
    loadSettings();
    createTray();
    results.tray = Boolean(tray);
    registerGlobalShortcuts();
    results.hotkeysRegistered = Object.values(hotkeyStatus).filter(Boolean).length;

    settingsWindow = makeWindow({ width: 860, height: 620, title: 'PinShot 设置' });
    trackErrors(settingsWindow, 'settings');
    const settingsLoadPromise = waitForLoad(settingsWindow);
    loadRenderer(settingsWindow, 'settings.html').catch(() => {});
    const loadedSettings = await settingsLoadPromise;
    if (loadedSettings && !settingsWindow.isDestroyed()) {
      settingsWindow.webContents.send('settings:init', settingsSnapshot());
      await delay(350);
      results.settingsWindow = true;
      results.settingsRenderer = await settingsWindow.webContents
        .executeJavaScript(
          "Boolean(document.querySelector('.settings-window')) && document.querySelectorAll('.nav-item').length >= 2",
        )
        .catch(() => false);
    }

    // 逐个加载其余 renderer 页面，确保没有语法错误 / 初始化异常
    for (const page of ['capture', 'editor', 'pin']) {
      const win = makeWindow({ width: 640, height: 480, title: `smoke-${page}` });
      trackErrors(win, page);
      const pageLoadPromise = waitForLoad(win);
      await loadRenderer(win, `${page}.html`).catch(() => {});
      const loaded = await pageLoadPromise;
      if (loaded) {
        await delay(150);
        const okPage = await win.webContents
          .executeJavaScript(`document.body && document.body.dataset.page === '${page}'`)
          .catch(() => false);
        results.rendererPages[page] = Boolean(okPage);
      } else {
        results.rendererPages[page] = false;
      }
      if (!win.isDestroyed()) win.destroy();
    }

    // 验证设置持久化
    updateSettings({ autoHideDelay: 2.5 }, { skipPersist: true });
    writeSettingsNow();
    const raw = JSON.parse(fs.readFileSync(settingsFilePath, 'utf8'));
    results.settingsFile = raw.autoHideDelay === 2.5;
  } catch (error) {
    results.errors.push(`smoke: ${error && error.message ? error.message : error}`);
  }

  const ok =
    results.tray &&
    results.settingsWindow &&
    results.settingsRenderer &&
    results.settingsFile &&
    Object.values(results.rendererPages).every(Boolean) &&
    results.errors.length === 0;

  console.log(`[smoke] ${JSON.stringify(results)}`);
  console.log(ok ? 'SMOKE_OK' : 'SMOKE_FAIL');
  setTimeout(() => app.exit(ok ? 0 : 1), 200);
}

// ---------------------------------------------------------------------------
// 开发期 UI 截图（--render-ui，仅供本地视觉验收）
// ---------------------------------------------------------------------------

async function captureWindowToFile(win, name, outputDir) {
  try {
    await delay(260);
    const image = await win.webContents.capturePage();
    const png = image.toPNG();
    fs.mkdirSync(outputDir, { recursive: true });
    const file = path.join(outputDir, `${name}.png`);
    fs.writeFileSync(file, png);
    log(`[render-ui] ${name} -> ${file} (${image.getSize().width}x${image.getSize().height})`);
    return image;
  } catch (error) {
    warn(`[render-ui] capture ${name} failed:`, error.message);
    return null;
  }
}

async function runRenderUi() {
  const outputDir = path.join(ROOT_DIR, '.scratch', 'ui');
  fs.rmSync(outputDir, { recursive: true, force: true });
  loadSettings();

  // 1) 设置窗口
  const settingsWin = makeWindow({ width: 860, height: 620, x: 40, y: 40, title: 'render-settings' });
  settingsWin.webContents.once('did-finish-load', () =>
    settingsWin.webContents.send('settings:init', settingsSnapshot()),
  );
  const settingsLoaded = waitForLoad(settingsWin);
  loadRenderer(settingsWin, 'settings.html').catch(() => {});
  await settingsLoaded;
  settingsWin.showInactive();
  await delay(320);
  const settingsImage = await captureWindowToFile(settingsWin, 'settings', outputDir);
  if (!settingsImage) {
    app.exit(1);
    return;
  }

  // 用设置窗口截图作为后续页面的真实截图素材
  const sourceDips = settingsImage.getSize();
  const cropWidth = Math.min(780, sourceDips.width - 40);
  const cropHeight = Math.min(470, sourceDips.height - 120);
  const cropped = settingsImage.crop({ x: 30, y: 100, width: cropWidth, height: cropHeight });
  const sourcePng = cropped.toPNG();
  const sourcePixelSize = nativeImage.createFromBuffer(sourcePng).getSize();
  const sourcePointSize = cropped.getSize();

  // 2) 标注编辑器（含示例标注）
  const editorDisplay = { width: sourcePointSize.width, height: sourcePointSize.height };
  const editorWindowWidth = editorDisplay.width + EDITOR_LAYOUT.padding * 2 + 48;
  const editorWindowHeight =
    editorDisplay.height +
    EDITOR_LAYOUT.padding * 2 +
    EDITOR_LAYOUT.topInset +
    EDITOR_LAYOUT.toolbarHeight +
    EDITOR_LAYOUT.toolbarGap +
    EDITOR_LAYOUT.hintGap +
    EDITOR_LAYOUT.hintHeight +
    EDITOR_LAYOUT.bottomInset;
  const editorWin = makeWindow({
    width: editorWindowWidth,
    height: editorWindowHeight,
    x: 60,
    y: 60,
    title: 'render-editor',
  });
  const editorLoaded = waitForLoad(editorWin);
  loadRenderer(editorWin, 'editor.html').catch(() => {});
  await editorLoaded;
  editorWin.webContents.send('editor:init', {
    png: sourcePng,
    pixelSize: sourcePixelSize,
    displaySize: editorDisplay,
    layout: EDITOR_LAYOUT,
    mode: 'pin',
  });
  editorWin.showInactive();
  await delay(420);
  try {
    await editorWin.webContents.executeJavaScript(`
      (() => {
        const canvas = document.getElementById('canvas');
        const rect = canvas.getBoundingClientRect();
        const at = (rx, ry) => ({ clientX: rect.left + rx * rect.width, clientY: rect.top + ry * rect.height });
        const fire = (target, type, p, button) => target.dispatchEvent(new PointerEvent(type, {
          clientX: p.clientX, clientY: p.clientY, button: button == null ? 0 : button,
          buttons: 1, pointerId: 1, bubbles: true, cancelable: true, isPrimary: true,
        }));
        const draw = (tool, from, to, steps) => {
          const button = document.querySelector('.tool[data-tool="' + tool + '"]');
          if (button) button.click();
          fire(canvas, 'pointerdown', at(from[0], from[1]));
          const n = steps || 12;
          for (let i = 1; i <= n; i++) {
            const x = from[0] + (to[0] - from[0]) * (i / n);
            const y = from[1] + (to[1] - from[1]) * (i / n);
            fire(canvas, 'pointermove', at(x, y));
          }
          fire(canvas, 'pointerup', at(to[0], to[1]));
        };
        const wave = (tool, y, amp, colorIndex) => {
          const swatch = document.querySelectorAll('.swatch')[colorIndex || 0];
          if (swatch) swatch.click();
          const button = document.querySelector('.tool[data-tool="' + tool + '"]');
          if (button) button.click();
          fire(canvas, 'pointerdown', at(0.08, y));
          for (let i = 1; i <= 26; i++) {
            const t = i / 26;
            fire(canvas, 'pointermove', at(0.08 + 0.3 * t, y + Math.sin(t * Math.PI * 2) * amp));
          }
          fire(canvas, 'pointerup', at(0.38, y));
        };
        wave('pen', 0.25, 0.05, 0);
        const lineBtn = document.querySelector('.tool[data-tool="line"]');
        if (lineBtn) lineBtn.click();
        const orange = document.querySelectorAll('.swatch')[1]; if (orange) orange.click();
        fire(canvas, 'pointerdown', at(0.45, 0.22));
        fire(canvas, 'pointermove', at(0.68, 0.22));
        fire(canvas, 'pointerup', at(0.68, 0.22));
        const arrowBtn = document.querySelector('.tool[data-tool="arrow"]');
        if (arrowBtn) arrowBtn.click();
        const green = document.querySelectorAll('.swatch')[3]; if (green) green.click();
        fire(canvas, 'pointerdown', at(0.5, 0.7));
        fire(canvas, 'pointermove', at(0.78, 0.4));
        fire(canvas, 'pointerup', at(0.78, 0.4));
        const rectBtn = document.querySelector('.tool[data-tool="rectangle"]');
        if (rectBtn) rectBtn.click();
        const blue = document.querySelectorAll('.swatch')[4]; if (blue) blue.click();
        fire(canvas, 'pointerdown', at(0.55, 0.5));
        fire(canvas, 'pointermove', at(0.85, 0.82));
        fire(canvas, 'pointerup', at(0.85, 0.82));
        const hlBtn = document.querySelector('.tool[data-tool="highlighter"]');
        if (hlBtn) hlBtn.click();
        const yellow = document.querySelectorAll('.swatch')[2]; if (yellow) yellow.click();
        fire(canvas, 'pointerdown', at(0.1, 0.42));
        fire(canvas, 'pointermove', at(0.42, 0.42));
        fire(canvas, 'pointerup', at(0.42, 0.42));
        const penBtn = document.querySelector('.tool[data-tool="pen"]');
        if (penBtn) penBtn.click();
      })();
    `);
  } catch (error) {
    warn('[render-ui] editor sample annotations failed:', error.message);
  }
  await delay(260);
  await captureWindowToFile(editorWin, 'editor', outputDir);
  if (!editorWin.isDestroyed()) editorWin.destroy();

  // 3) 贴图窗口（悬停工具栏）
  const pinCard = { width: Math.min(560, sourcePointSize.width), height: 0 };
  pinCard.height = Math.round((pinCard.width * sourcePointSize.height) / sourcePointSize.width);
  const pinWin = makeWindow({
    width: pinCard.width + PIN_MARGIN * 2,
    height: pinCard.height + PIN_MARGIN * 2,
    x: 100,
    y: 100,
    title: 'render-pin',
  });
  const pinLoaded = waitForLoad(pinWin);
  loadRenderer(pinWin, 'pin.html').catch(() => {});
  await pinLoaded;
  pinWin.webContents.send('pin:init', {
    png: sourcePng,
    pixelSize: sourcePixelSize,
    pointSize: sourcePointSize,
    card: pinCard,
    margin: PIN_MARGIN,
    placement: 'floating',
    settings: settingsSnapshot(),
  });
  pinWin.showInactive();
  await delay(520);
  pinWin.webContents.send('pin:hover', { inside: true });
  await delay(220);
  await captureWindowToFile(pinWin, 'pin', outputDir);
  if (!pinWin.isDestroyed()) pinWin.destroy();

  // 4) 截图覆盖层（模拟一次框选）
  const captureW = 1180;
  const captureH = 720;
  const captureWin = makeWindow({
    width: captureW,
    height: captureH,
    x: 20,
    y: 20,
    title: 'render-capture',
    movable: false,
  });
  const captureLoaded = waitForLoad(captureWin);
  loadRenderer(captureWin, 'capture.html').catch(() => {});
  await captureLoaded;
  const captureSource = settingsImage.crop({
    x: 20,
    y: 20,
    width: Math.min(sourceDips.width - 40, captureW),
    height: Math.min(sourceDips.height - 40, captureH),
  });
  captureWin.webContents.send('capture:init', {
    png: captureSource.toPNG(),
    display: { id: 1, bounds: { x: 0, y: 0, width: captureW, height: captureH }, scaleFactor: 1 },
    mode: 'pin',
  });
  captureWin.showInactive();
  await delay(420);
  try {
    await captureWin.webContents.executeJavaScript(`
      (() => {
        const screenEl = document.getElementById('screen');
        const fire = (type, x, y) => screenEl.dispatchEvent(new PointerEvent(type, {
          clientX: x, clientY: y, button: 0, buttons: 1, pointerId: 1,
          bubbles: true, cancelable: true, isPrimary: true,
        }));
        fire('pointermove', 420, 250);
        fire('pointerdown', 220, 160);
        fire('pointermove', 620, 360);
        fire('pointermove', 900, 560);
      })();
    `);
  } catch (error) {
    warn('[render-ui] capture selection simulation failed:', error.message);
  }
  await delay(260);
  await captureWindowToFile(captureWin, 'capture', outputDir);
  if (!captureWin.isDestroyed()) captureWin.destroy();

  if (!settingsWin.isDestroyed()) settingsWin.destroy();
  await delay(200);
  console.log(`[render-ui] done -> ${outputDir}`);
  app.exit(0);
}

// ---------------------------------------------------------------------------
// 应用启动
// ---------------------------------------------------------------------------

app.setName(APP_NAME);
if (IS_WIN) {
  app.setAppUserModelId('com.kuxin.pinshot');
}
if (SMOKE_TEST || RENDER_UI) {
  try {
    app.setPath('userData', path.join(os.tmpdir(), `pinshot-${SMOKE_TEST ? 'smoke' : 'ui'}-${process.pid}`));
  } catch (error) {
    warn('设置测试 userData 失败:', error.message);
  }
}

const gotSingleInstanceLock = app.requestSingleInstanceLock();
if (!gotSingleInstanceLock) {
  app.quit();
} else {
  app.on('second-instance', () => {
    if (SMOKE_TEST) return;
    showSettings();
  });

  app.whenReady().then(async () => {
    if (IS_MAC) {
      try {
        app.dock.hide();
      } catch (error) {
        /* 忽略 */
      }
    }
    app.on('activate', () => {
      if (!SMOKE_TEST) showSettings();
    });

    registerIpc();

    if (SMOKE_TEST) {
      await runSmokeTest();
      return;
    }

    if (RENDER_UI) {
      await runRenderUi();
      return;
    }

    loadSettings();
    createTray();
    registerGlobalShortcuts();
    startAutoHideLoop();
    log(`已启动 v${APP_VERSION} · userData=${app.getPath('userData')}`);

    if (!settings.hasCompletedOnboarding) {
      settings.hasCompletedOnboarding = true;
      writeSettingsNow();
      setTimeout(() => {
        showSettings('pin');
        notify('PinShot 已在系统托盘运行', 'Ctrl+Shift+2 截图并贴图，Ctrl+Shift+1 截图并复制，Ctrl+Shift+3 从剪贴板贴图。');
      }, 500);
    }
  });

  app.on('window-all-closed', (event) => {
    // 托盘应用：窗口全部关闭后不退出
    if (event && typeof event.preventDefault === 'function') event.preventDefault();
  });

  app.on('before-quit', () => {
    isQuitting = true;
    if (persistTimer) {
      clearTimeout(persistTimer);
      persistTimer = null;
    }
    writeSettingsNow();
    stopAutoHideLoop();
    for (const pin of pins.values()) {
      clearPinTimers(pin);
      if (!pin.win.isDestroyed()) pin.win.destroy();
    }
    pins.clear();
  });

  app.on('will-quit', () => {
    globalShortcut.unregisterAll();
  });
}
