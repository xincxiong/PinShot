'use strict';

/**
 * 贴图窗口渲染进程。
 *
 * 主进程负责窗口移动 / 缩放 / 自动隐藏 / 右键菜单；渲染进程负责：
 *  - 显示截图 + 自适应描边 + 阴影 + 圆角
 *  - 悬停时显示玻璃工具栏与四角缩放手柄
 *  - 把拖拽 / 缩放手势转成 IPC，并在缩放时显示尺寸徽标
 */

(() => {
  const api = window.pinshot && window.pinshot.pin;

  const pinWindow = document.getElementById('pinWindow');
  const card = document.getElementById('card');
  const pinImage = document.getElementById('pinImage');
  const toolbar = document.getElementById('toolbar');
  const copyBtn = document.getElementById('copyBtn');
  const saveBtn = document.getElementById('saveBtn');
  const autoHideBtn = document.getElementById('autoHideBtn');
  const placementBtn = document.getElementById('placementBtn');
  const closeBtn = document.getElementById('closeBtn');
  const sizeBadge = document.getElementById('sizeBadge');
  const toastEl = document.getElementById('toast');
  const handles = Array.from(document.querySelectorAll('.handle'));

  const state = {
    ready: false,
    settings: null,
    placement: 'floating',
    autoHidden: false,
    mainHover: false,
    localHover: false,
    dragging: false,
    resizing: false,
    activePointerId: null,
    toastTimer: null,
    objectUrl: null,
  };

  function updateHoverClass() {
    const hover = (state.mainHover || state.localHover) && !state.autoHidden;
    pinWindow.classList.toggle('hover', hover);
  }

  function applySettings(settings) {
    if (!settings) return;
    state.settings = settings;
    pinWindow.classList.toggle('show-border', settings.showPinBorder !== false);
    pinWindow.classList.toggle('show-shadow', settings.showPinShadow !== false);
    updateAutoHideButton(settings.autoHideEnabled !== false);
  }

  function updateAutoHideButton(enabled) {
    autoHideBtn.classList.toggle('active', enabled);
    autoHideBtn.classList.toggle('disabled-eye', !enabled);
    autoHideBtn.title = enabled ? '自动隐藏：开（点击关闭）' : '自动隐藏：关（点击开启）';
  }

  function updatePlacementButton(placement) {
    const isDesktop = placement === 'desktop';
    placementBtn.classList.toggle('is-desktop', isDesktop);
    placementBtn.classList.toggle('active', isDesktop);
    placementBtn.title = isDesktop ? '挂在桌面（点击浮于顶层）' : '浮于顶层（点击挂到桌面）';
  }

  function updateAutoHiddenState(autoHidden) {
    state.autoHidden = Boolean(autoHidden);
    pinWindow.classList.toggle('auto-hidden', state.autoHidden);
    if (!state.autoHidden) updateHoverClass();
  }

  function showToast(text) {
    if (!text) return;
    toastEl.textContent = text;
    toastEl.hidden = false;
    if (state.toastTimer) clearTimeout(state.toastTimer);
    state.toastTimer = setTimeout(() => {
      toastEl.hidden = true;
      state.toastTimer = null;
    }, 1400);
  }

  function sampleAdaptiveBorder(image) {
    try {
      const canvas = document.createElement('canvas');
      canvas.width = 1;
      canvas.height = 1;
      const ctx = canvas.getContext('2d', { willReadFrequently: true });
      if (!ctx) return;
      ctx.drawImage(image, 0, 0, 1, 1);
      const data = ctx.getImageData(0, 0, 1, 1).data;
      const luminance = (0.299 * data[0] + 0.587 * data[1] + 0.114 * data[2]) / 255;
      pinWindow.style.setProperty(
        '--pin-border',
        luminance > 0.6 ? 'rgba(0, 0, 0, 0.35)' : 'rgba(255, 255, 255, 0.45)',
      );
    } catch (error) {
      console.warn('采样图像亮度失败', error);
    }
  }

  function init(payload) {
    if (!payload || !payload.png) return;
    state.placement = payload.placement === 'desktop' ? 'desktop' : 'floating';
    applySettings(payload.settings);
    updatePlacementButton(state.placement);

    const bytes = payload.png instanceof Uint8Array ? payload.png : new Uint8Array(payload.png);
    const blob = new Blob([bytes], { type: 'image/png' });
    if (state.objectUrl) URL.revokeObjectURL(state.objectUrl);
    state.objectUrl = URL.createObjectURL(blob);
    pinImage.onload = () => {
      state.ready = true;
      sampleAdaptiveBorder(pinImage);
    };
    pinImage.src = state.objectUrl;
  }

  // -------------------------------------------------------------------------
  // 悬停
  // -------------------------------------------------------------------------

  pinWindow.addEventListener('pointerenter', () => {
    state.localHover = true;
    updateHoverClass();
  });
  pinWindow.addEventListener('pointerleave', () => {
    state.localHover = false;
    updateHoverClass();
  });

  // -------------------------------------------------------------------------
  // 拖动 / 缩放
  // -------------------------------------------------------------------------

  function endInteractions() {
    if (state.dragging) {
      state.dragging = false;
      api.dragEnd();
    }
    if (state.resizing) {
      state.resizing = false;
      sizeBadge.hidden = true;
      api.resizeEnd();
    }
    pinWindow.classList.remove('interacting', 'dragging');
  }

  card.addEventListener('pointerdown', (event) => {
    if (event.button !== 0) return;
    if (event.target.closest && event.target.closest('.toolbar')) return;
    if (state.autoHidden) return;
    event.preventDefault();
    state.dragging = true;
    state.activePointerId = event.pointerId;
    pinWindow.classList.add('interacting', 'dragging');
    try {
      card.setPointerCapture(event.pointerId);
    } catch (error) {
      /* 忽略 */
    }
    api.dragStart();
  });

  for (const handle of handles) {
    handle.addEventListener('pointerdown', (event) => {
      if (event.button !== 0) return;
      if (state.autoHidden) return;
      event.preventDefault();
      event.stopPropagation();
      state.resizing = true;
      state.activePointerId = event.pointerId;
      pinWindow.classList.add('interacting');
      try {
        handle.setPointerCapture(event.pointerId);
      } catch (error) {
        /* 忽略 */
      }
      api.resizeStart(handle.dataset.corner);
    });
  }

  window.addEventListener('pointerup', (event) => {
    if (!state.dragging && !state.resizing) return;
    if (state.activePointerId != null && event.pointerId !== state.activePointerId) return;
    state.activePointerId = null;
    endInteractions();
  });

  window.addEventListener('pointercancel', () => {
    if (!state.dragging && !state.resizing) return;
    state.activePointerId = null;
    endInteractions();
  });

  window.addEventListener('blur', () => {
    if (state.dragging || state.resizing) {
      state.activePointerId = null;
      endInteractions();
    }
  });

  // -------------------------------------------------------------------------
  // 工具栏 / 右键菜单
  // -------------------------------------------------------------------------

  copyBtn.addEventListener('click', () => api.copy());
  saveBtn.addEventListener('click', () => api.save());
  closeBtn.addEventListener('click', () => api.close());
  autoHideBtn.addEventListener('click', () => api.toggleAutoHide());
  placementBtn.addEventListener('click', () => api.togglePlacement());

  pinWindow.addEventListener('contextmenu', (event) => {
    event.preventDefault();
    if (state.dragging || state.resizing) return;
    api.contextMenu();
  });

  // 双击内容区域：复制图片（对齐 macOS 常见操作习惯）
  card.addEventListener('dblclick', (event) => {
    if (event.target.closest && event.target.closest('.toolbar')) return;
    api.copy();
  });

  // -------------------------------------------------------------------------
  // IPC 订阅
  // -------------------------------------------------------------------------

  if (api && typeof api.onInit === 'function') {
    api.onInit(init);
    api.onHover((payload) => {
      state.mainHover = Boolean(payload && payload.inside);
      updateHoverClass();
    });
    api.onState((payload) => {
      if (!payload) return;
      updateAutoHiddenState(payload.autoHidden);
      if (payload.placement) {
        state.placement = payload.placement;
        updatePlacementButton(payload.placement);
      }
      if (typeof payload.autoHideEnabled === 'boolean') updateAutoHideButton(payload.autoHideEnabled);
    });
    api.onResizing((payload) => {
      if (!payload) {
        sizeBadge.hidden = true;
        return;
      }
      sizeBadge.textContent = `${Math.round(payload.width)} × ${Math.round(payload.height)}`;
      sizeBadge.hidden = false;
    });
    api.onToast((payload) => {
      if (payload && payload.text) showToast(payload.text);
    });
    api.onDragging((payload) => {
      pinWindow.classList.toggle('dragging', Boolean(payload && payload.active));
    });
    api.onSettings((settings) => {
      applySettings(settings);
      if (settings && typeof settings.autoHideEnabled === 'boolean') {
        updateAutoHideButton(settings.autoHideEnabled);
      }
    });
  }
})();
