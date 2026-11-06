'use strict';

/**
 * PinShot preload（contextIsolation: true / nodeIntegration: false）。
 * 只暴露窗口渲染必需的最小 IPC 面：截图、标注编辑器、贴图、设置。
 */

const { contextBridge, ipcRenderer } = require('electron');

function subscribe(channel) {
  return (callback) => {
    if (typeof callback !== 'function') return () => {};
    const listener = (_event, payload) => callback(payload);
    ipcRenderer.on(channel, listener);
    return () => ipcRenderer.removeListener(channel, listener);
  };
}

function invoke(channel, payload) {
  return ipcRenderer.invoke(channel, payload);
}

contextBridge.exposeInMainWorld('pinshot', {
  platform: process.platform,

  capture: {
    onInit: subscribe('capture:init'),
    select: (rect) => invoke('capture:select', rect),
    cancel: () => invoke('capture:cancel'),
  },

  editor: {
    onInit: subscribe('editor:init'),
    finish: (bytes, action) => invoke('editor:finish', { bytes, action }),
    cancel: () => invoke('editor:cancel'),
  },

  pin: {
    onInit: subscribe('pin:init'),
    onHover: subscribe('pin:hover'),
    onResizing: subscribe('pin:resizing'),
    onState: subscribe('pin:state'),
    onSettings: subscribe('settings:changed'),
    onToast: subscribe('pin:toast'),
    onDragging: subscribe('pin:dragging'),
    copy: () => invoke('pin:copy'),
    save: () => invoke('pin:save'),
    close: () => invoke('pin:close'),
    contextMenu: () => invoke('pin:context-menu'),
    dragStart: () => invoke('pin:drag-start'),
    dragEnd: () => invoke('pin:drag-end'),
    resizeStart: (corner) => invoke('pin:resize-start', corner),
    resizeEnd: () => invoke('pin:resize-end'),
    nudge: (dx, dy) => invoke('pin:nudge', { dx, dy }),
    toggleAutoHide: () => invoke('pin:toggle-auto-hide'),
    togglePlacement: () => invoke('pin:toggle-placement'),
  },

  settings: {
    onInit: subscribe('settings:init'),
    onChange: subscribe('settings:changed'),
    onFocusPane: subscribe('settings:focus-pane'),
    get: () => invoke('settings:get'),
    update: (patch) => invoke('settings:update', patch),
    reset: () => invoke('settings:reset'),
    close: () => invoke('settings:close'),
  },
});
