'use strict';

/**
 * 区域截图覆盖层。
 *
 * 主进程会为每块显示器创建一个覆盖层，并把该屏的冻结帧以 PNG 字节发过来；
 * 用户拖拽框选后，把「显示器局部 DIP 坐标」回传主进程做像素裁剪。
 */

(() => {
  const api = window.pinshot && window.pinshot.capture;

  const screenEl = document.getElementById('screen');
  const frozenEl = document.getElementById('frozen');
  const dimEl = document.getElementById('dim');
  const selectionEl = document.getElementById('selection');
  const brightEl = document.getElementById('bright');
  const badgeEl = document.getElementById('sizeBadge');
  const hintEl = document.getElementById('hint');
  const guideX = document.getElementById('guideX');
  const guideY = document.getElementById('guideY');
  const crosshair = document.getElementById('crosshair');
  const crosshairH = crosshair ? crosshair.querySelector('.h') : null;
  const crosshairV = crosshair ? crosshair.querySelector('.v') : null;

  const MIN_SELECTION = 8;

  let objectUrl = null;
  let initialized = false;
  let dragging = false;
  let submitted = false;
  let startX = 0;
  let startY = 0;
  let currentRect = null;
  let displaySize = { width: window.innerWidth, height: window.innerHeight };

  function clamp(value, min, max) {
    return Math.min(Math.max(value, min), max);
  }

  function localPoint(event) {
    return {
      x: clamp(event.clientX, 0, window.innerWidth),
      y: clamp(event.clientY, 0, window.innerHeight),
    };
  }

  function rectFromPoints(a, b) {
    const x = Math.min(a.x, b.x);
    const y = Math.min(a.y, b.y);
    return {
      x: Math.round(x),
      y: Math.round(y),
      width: Math.round(Math.abs(b.x - a.x)),
      height: Math.round(Math.abs(b.y - a.y)),
    };
  }

  function syncBrightSize() {
    displaySize = { width: window.innerWidth, height: window.innerHeight };
    if (brightEl) {
      brightEl.style.width = `${displaySize.width}px`;
      brightEl.style.height = `${displaySize.height}px`;
    }
  }

  function paintSelection(rect) {
    currentRect = rect;
    if (!rect || rect.width < 1 || rect.height < 1) {
      selectionEl.hidden = true;
      badgeEl.hidden = true;
      return;
    }
    selectionEl.hidden = false;
    selectionEl.style.left = `${rect.x}px`;
    selectionEl.style.top = `${rect.y}px`;
    selectionEl.style.width = `${rect.width}px`;
    selectionEl.style.height = `${rect.height}px`;
    brightEl.style.transform = `translate(${-rect.x}px, ${-rect.y}px)`;

    badgeEl.textContent = `${rect.width} × ${rect.height}`;
    badgeEl.hidden = false;
    const badgeWidth = badgeEl.offsetWidth || 80;
    const badgeHeight = badgeEl.offsetHeight || 24;
    let badgeX = rect.x + rect.width + 8;
    let badgeY = rect.y + rect.height + 8;
    if (badgeX + badgeWidth > window.innerWidth - 8) badgeX = rect.x + rect.width - badgeWidth;
    if (badgeX < 8) badgeX = 8;
    if (badgeY + badgeHeight > window.innerHeight - 8) badgeY = rect.y + rect.height - badgeHeight - 8;
    if (badgeY < 8) badgeY = 8;
    badgeEl.style.left = `${Math.round(badgeX)}px`;
    badgeEl.style.top = `${Math.round(badgeY)}px`;

    crosshair.hidden = true;
    guideX.hidden = true;
    guideY.hidden = true;
  }

  function resetSelection() {
    dragging = false;
    currentRect = null;
    selectionEl.hidden = true;
    badgeEl.hidden = true;
    crosshair.hidden = false;
    guideX.hidden = false;
    guideY.hidden = false;
    hintEl.style.opacity = '1';
  }

  function cancel() {
    if (submitted) return;
    submitted = true;
    if (api && api.cancel) api.cancel().catch(() => {});
  }

  function submit(rect) {
    if (submitted) return;
    submitted = true;
    if (api && api.select) {
      api.select({
        x: rect.x,
        y: rect.y,
        width: rect.width,
        height: rect.height,
      }).catch(() => {});
    }
  }

  function updateCrosshair(event) {
    const point = localPoint(event);
    guideX.style.top = `${point.y}px`;
    guideY.style.left = `${point.x}px`;
    if (crosshairH) crosshairH.style.top = `${point.y}px`;
    if (crosshairV) crosshairV.style.left = `${point.x}px`;
    guideX.hidden = false;
    guideY.hidden = false;
    crosshair.hidden = false;
  }

  function onPointerDown(event) {
    if (submitted) return;
    if (event.button !== 0) {
      cancel();
      return;
    }
    event.preventDefault();
    const point = localPoint(event);
    dragging = true;
    startX = point.x;
    startY = point.y;
    hintEl.style.opacity = '0';
    try {
      screenEl.setPointerCapture(event.pointerId);
    } catch (error) {
      /* 某些环境不支持，忽略 */
    }
    paintSelection(rectFromPoints({ x: startX, y: startY }, point));
  }

  function onPointerMove(event) {
    if (submitted) return;
    if (!dragging) {
      updateCrosshair(event);
      return;
    }
    event.preventDefault();
    const point = localPoint(event);
    paintSelection(rectFromPoints({ x: startX, y: startY }, point));
  }

  function onPointerUp(event) {
    if (submitted) return;
    if (!dragging) return;
    dragging = false;
    const point = localPoint(event);
    const rect = rectFromPoints({ x: startX, y: startY }, point);
    try {
      screenEl.releasePointerCapture(event.pointerId);
    } catch (error) {
      /* 忽略 */
    }
    if (rect.width >= MIN_SELECTION && rect.height >= MIN_SELECTION) {
      submit(rect);
    } else {
      resetSelection();
    }
  }

  function onPointerCancel() {
    dragging = false;
    resetSelection();
  }

  function init(payload) {
    if (!payload || !payload.png) return;
    initialized = true;
    const bytes = payload.png instanceof Uint8Array ? payload.png : new Uint8Array(payload.png);
    const blob = new Blob([bytes], { type: 'image/png' });
    if (objectUrl) URL.revokeObjectURL(objectUrl);
    objectUrl = URL.createObjectURL(blob);
    frozenEl.src = objectUrl;
    brightEl.src = objectUrl;
    syncBrightSize();
    paintSelection(null);
    hintEl.innerHTML =
      '拖拽框选区域 · <span class="key">Esc</span> / 右键取消';
    hintEl.style.opacity = '1';
    try {
      frozenEl.decode && frozenEl.decode().catch(() => {});
    } catch (error) {
      /* 忽略 */
    }
  }

  window.addEventListener('resize', syncBrightSize);
  screenEl.addEventListener('pointerdown', onPointerDown);
  screenEl.addEventListener('pointermove', onPointerMove);
  screenEl.addEventListener('pointerup', onPointerUp);
  screenEl.addEventListener('pointercancel', onPointerCancel);
  screenEl.addEventListener('contextmenu', (event) => {
    event.preventDefault();
    cancel();
  });
  window.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      event.preventDefault();
      cancel();
    }
  });

  if (api && typeof api.onInit === 'function') {
    api.onInit(init);
  }

  // 覆盖层如果 5 秒内没收到冻结帧，提示抓屏异常（主进程通常已经处理空源）
  setTimeout(() => {
    if (!initialized && !submitted) {
      hintEl.textContent = '正在抓取屏幕… 若长时间无响应，请按 Esc 取消重试';
    }
  }, 5000);
})();
