'use strict';

/**
 * 标注编辑器渲染进程。
 *
 * - 画布内部尺寸 = 截图的原始像素尺寸；CSS 显示尺寸 = 主进程算好的 DIP 尺寸。
 * - 笔画坐标统一使用画布像素坐标；线宽使用 DIP，绘制时乘以 pixelRatio。
 * - 导出时直接 canvas.toBlob('image/png')，保持原始像素。
 */

(() => {
  const api = window.pinshot && window.pinshot.editor;

  const canvas = document.getElementById('canvas');
  const shell = document.getElementById('canvasShell');
  const ctx = canvas.getContext('2d');
  const eraserCursor = document.getElementById('eraserCursor');
  const busyEl = document.getElementById('busy');
  const undoBtn = document.getElementById('undoBtn');
  const redoBtn = document.getElementById('redoBtn');
  const toolButtons = Array.from(document.querySelectorAll('.tool'));
  const swatchButtons = Array.from(document.querySelectorAll('.swatch'));
  const widthButtons = Array.from(document.querySelectorAll('.width'));

  const COLORS = ['#FF453A', '#FF9F0A', '#FFD60A', '#32D74B', '#0A84FF', '#FFFFFF'];
  const DEFAULT_COLOR = COLORS[0];
  const DEFAULT_WIDTH = 4;
  const HIGHLIGHTER_WIDTH = 14;
  const RECTANGLE_WIDTH = 1.5;
  const MAX_UNDO = 80;
  const TOOL_KEYS = { p: 'pen', l: 'line', a: 'arrow', r: 'rectangle', h: 'highlighter', e: 'eraser' };

  const state = {
    ready: false,
    mode: 'pin',
    tool: 'pen',
    color: DEFAULT_COLOR,
    width: DEFAULT_WIDTH,
    pixelSize: { width: 1, height: 1 },
    displaySize: { width: 1, height: 1 },
    ratio: 1,
    strokes: [],
    current: null,
    undoStack: [],
    redoStack: [],
    drawing: false,
    erasing: false,
    eraseBackup: null,
    pointerId: null,
    exportBusy: false,
    sourceImage: null,
    objectUrl: null,
    rafPending: false,
  };

  // -------------------------------------------------------------------------
  // 渲染
  // -------------------------------------------------------------------------

  function render() {
    if (!ctx) return;
    const { width, height } = state.pixelSize;
    ctx.clearRect(0, 0, width, height);
    if (state.sourceImage) {
      ctx.drawImage(state.sourceImage, 0, 0, width, height);
    }
    for (const stroke of state.strokes) drawStroke(stroke);
    if (state.current) drawStroke(state.current);
  }

  function scheduleRender() {
    if (state.rafPending) return;
    state.rafPending = true;
    requestAnimationFrame(() => {
      state.rafPending = false;
      render();
    });
  }

  function drawStroke(stroke) {
    if (!stroke || !stroke.points || stroke.points.length === 0) return;
    const ratio = state.ratio;
    const first = stroke.points[0];
    const lineWidthPx = Math.max(stroke.lineWidth * ratio, 1);
    ctx.save();
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    ctx.strokeStyle = stroke.color;
    ctx.fillStyle = stroke.color;

    switch (stroke.tool) {
      case 'pen':
      case 'highlighter': {
        ctx.globalAlpha = stroke.tool === 'highlighter' ? 0.35 : 1;
        ctx.lineWidth = lineWidthPx;
        if (stroke.points.length < 2) {
          ctx.beginPath();
          ctx.arc(first.x, first.y, lineWidthPx / 2, 0, Math.PI * 2);
          ctx.fill();
        } else {
          ctx.beginPath();
          ctx.moveTo(first.x, first.y);
          for (let index = 1; index < stroke.points.length; index += 1) {
            ctx.lineTo(stroke.points[index].x, stroke.points[index].y);
          }
          ctx.stroke();
        }
        break;
      }
      case 'line':
      case 'arrow': {
        if (stroke.points.length < 2) break;
        const last = stroke.points[stroke.points.length - 1];
        ctx.lineWidth = lineWidthPx;
        ctx.beginPath();
        ctx.moveTo(first.x, first.y);
        ctx.lineTo(last.x, last.y);
        ctx.stroke();
        if (stroke.tool === 'arrow') drawArrowHead(first, last, lineWidthPx);
        break;
      }
      case 'rectangle': {
        if (stroke.points.length < 2) break;
        const last = stroke.points[stroke.points.length - 1];
        const rect = {
          x: Math.min(first.x, last.x),
          y: Math.min(first.y, last.y),
          width: Math.abs(last.x - first.x),
          height: Math.abs(last.y - first.y),
        };
        if (rect.width < 1 || rect.height < 1) break;
        ctx.lineWidth = Math.max(RECTANGLE_WIDTH * ratio, 1);
        const inset = ctx.lineWidth / 2;
        ctx.strokeRect(rect.x + inset, rect.y + inset, Math.max(rect.width - inset * 2, 0.5), Math.max(rect.height - inset * 2, 0.5));
        break;
      }
      default:
        break;
    }
    ctx.restore();
  }

  function drawArrowHead(start, tip, lineWidthPx) {
    const dx = tip.x - start.x;
    const dy = tip.y - start.y;
    const length = Math.hypot(dx, dy);
    if (length < 0.5) return;
    const angle = Math.atan2(dy, dx);
    const headLength = Math.max(lineWidthPx * 3.2, 10 * state.ratio);
    const headWidth = Math.max(lineWidthPx * 2.4, 8 * state.ratio);
    const baseX = tip.x - Math.cos(angle) * headLength;
    const baseY = tip.y - Math.sin(angle) * headLength;
    const perpendicular = angle + Math.PI / 2;
    const offsetX = Math.cos(perpendicular) * (headWidth / 2);
    const offsetY = Math.sin(perpendicular) * (headWidth / 2);
    ctx.beginPath();
    ctx.moveTo(tip.x, tip.y);
    ctx.lineTo(baseX + offsetX, baseY + offsetY);
    ctx.lineTo(baseX - offsetX, baseY - offsetY);
    ctx.closePath();
    ctx.fill();
  }

  // -------------------------------------------------------------------------
  // 坐标 / 命中检测
  // -------------------------------------------------------------------------

  function pointFromEvent(event) {
    const rect = canvas.getBoundingClientRect();
    if (rect.width < 1 || rect.height < 1) return { x: 0, y: 0 };
    const x = ((event.clientX - rect.left) / rect.width) * state.pixelSize.width;
    const y = ((event.clientY - rect.top) / rect.height) * state.pixelSize.height;
    return {
      x: Math.min(Math.max(x, 0), state.pixelSize.width),
      y: Math.min(Math.max(y, 0), state.pixelSize.height),
    };
  }

  function displayDistanceToPixel(distance) {
    return distance * state.ratio;
  }

  function effectiveLineWidth(tool) {
    switch (tool) {
      case 'highlighter':
        return HIGHLIGHTER_WIDTH;
      case 'rectangle':
        return RECTANGLE_WIDTH;
      default:
        return state.width;
    }
  }

  function distanceToSegment(point, a, b) {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const lengthSquared = dx * dx + dy * dy;
    if (lengthSquared < 0.0001) return Math.hypot(point.x - a.x, point.y - a.y);
    let t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared;
    t = Math.min(Math.max(t, 0), 1);
    const projection = { x: a.x + t * dx, y: a.y + t * dy };
    return Math.hypot(point.x - projection.x, point.y - projection.y);
  }

  function hitTest(stroke, point) {
    const points = stroke.points;
    if (!points || points.length === 0) return false;
    const threshold = Math.max(stroke.lineWidth / 2 + 3, 6) * state.ratio;
    const first = points[0];

    switch (stroke.tool) {
      case 'pen':
      case 'highlighter': {
        if (points.length === 1) return Math.hypot(point.x - first.x, point.y - first.y) <= threshold;
        for (let index = 1; index < points.length; index += 1) {
          if (distanceToSegment(point, points[index - 1], points[index]) <= threshold) return true;
        }
        return false;
      }
      case 'line':
      case 'arrow': {
        const last = points[points.length - 1];
        if (!last) return false;
        return distanceToSegment(point, first, last) <= threshold;
      }
      case 'rectangle': {
        const last = points[points.length - 1];
        if (!last) return false;
        const x1 = Math.min(first.x, last.x);
        const y1 = Math.min(first.y, last.y);
        const x2 = Math.max(first.x, last.x);
        const y2 = Math.max(first.y, last.y);
        const corners = [
          { x: x1, y: y1 },
          { x: x2, y: y1 },
          { x: x2, y: y2 },
          { x: x1, y: y2 },
        ];
        for (let index = 0; index < 4; index += 1) {
          if (distanceToSegment(point, corners[index], corners[(index + 1) % 4]) <= threshold) return true;
        }
        return false;
      }
      default:
        return false;
    }
  }

  // -------------------------------------------------------------------------
  // 编辑历史
  // -------------------------------------------------------------------------

  function pushUndoSnapshot() {
    state.undoStack.push(state.strokes.slice());
    if (state.undoStack.length > MAX_UNDO) state.undoStack.shift();
    state.redoStack = [];
    updateHistoryButtons();
  }

  function updateHistoryButtons() {
    undoBtn.disabled = state.undoStack.length === 0;
    redoBtn.disabled = state.redoStack.length === 0;
  }

  function undo() {
    if (state.undoStack.length === 0) return;
    state.redoStack.push(state.strokes);
    state.strokes = state.undoStack.pop();
    state.current = null;
    updateHistoryButtons();
    scheduleRender();
  }

  function redo() {
    if (state.redoStack.length === 0) return;
    state.undoStack.push(state.strokes);
    state.strokes = state.redoStack.pop();
    state.current = null;
    updateHistoryButtons();
    scheduleRender();
  }

  // -------------------------------------------------------------------------
  // 笔画提交 / 擦除
  // -------------------------------------------------------------------------

  function commitStroke() {
    const stroke = state.current;
    state.current = null;
    state.drawing = false;
    if (!stroke || stroke.points.length === 0) {
      scheduleRender();
      return;
    }

    const first = stroke.points[0];
    const last = stroke.points[stroke.points.length - 1];
    const distance = Math.hypot(last.x - first.x, last.y - first.y);
    if (stroke.tool === 'pen' || stroke.tool === 'highlighter') {
      if (stroke.points.length < 2 || distance < displayDistanceToPixel(1)) {
        scheduleRender();
        return;
      }
    } else if (distance < displayDistanceToPixel(2)) {
      scheduleRender();
      return;
    }

    pushUndoSnapshot();
    state.strokes.push(stroke);
    scheduleRender();
  }

  function beginErase(point) {
    state.erasing = true;
    state.eraseBackup = state.strokes.slice();
    state.eraseChanged = false;
    eraseAt(point);
  }

  function eraseAt(point) {
    if (state.strokes.length === 0) return;
    const remaining = state.strokes.filter((stroke) => !hitTest(stroke, point));
    if (remaining.length !== state.strokes.length) {
      state.strokes = remaining;
      state.eraseChanged = true;
      scheduleRender();
    }
  }

  function endErase() {
    if (!state.erasing) return;
    state.erasing = false;
    if (state.eraseChanged && state.eraseBackup) {
      state.undoStack.push(state.eraseBackup);
      if (state.undoStack.length > MAX_UNDO) state.undoStack.shift();
      state.redoStack = [];
      updateHistoryButtons();
    }
    state.eraseBackup = null;
    state.eraseChanged = false;
  }

  // -------------------------------------------------------------------------
  // 指针事件
  // -------------------------------------------------------------------------

  function updateEraserCursor(event) {
    if (state.tool !== 'eraser') {
      eraserCursor.hidden = true;
      return;
    }
    const rect = shell.getBoundingClientRect();
    const x = event.clientX - rect.left;
    const y = event.clientY - rect.top;
    if (x < 0 || y < 0 || x > rect.width || y > rect.height) {
      eraserCursor.hidden = true;
      return;
    }
    eraserCursor.hidden = false;
    eraserCursor.style.left = `${x}px`;
    eraserCursor.style.top = `${y}px`;
  }

  function onPointerDown(event) {
    if (!state.ready || state.exportBusy) return;
    if (event.button !== 0) return;
    event.preventDefault();
    state.pointerId = event.pointerId;
    try {
      canvas.setPointerCapture(event.pointerId);
    } catch (error) {
      /* 忽略 */
    }
    const point = pointFromEvent(event);

    if (state.tool === 'eraser') {
      beginErase(point);
      return;
    }
    state.current = {
      tool: state.tool,
      points: [point],
      color: state.color,
      lineWidth: effectiveLineWidth(state.tool),
    };
    state.drawing = true;
    scheduleRender();
  }

  function onPointerMove(event) {
    updateEraserCursor(event);
    if (!state.ready || state.exportBusy) return;

    if (state.erasing) {
      eraseAt(pointFromEvent(event));
      return;
    }
    if (!state.drawing || !state.current) return;

    const point = pointFromEvent(event);
    const stroke = state.current;
    switch (stroke.tool) {
      case 'pen':
      case 'highlighter': {
        const last = stroke.points[stroke.points.length - 1];
        if (last && Math.hypot(point.x - last.x, point.y - last.y) < displayDistanceToPixel(0.4)) return;
        stroke.points.push(point);
        break;
      }
      case 'line':
      case 'arrow':
      case 'rectangle': {
        if (stroke.points.length === 1) stroke.points.push(point);
        else stroke.points[stroke.points.length - 1] = point;
        break;
      }
      default:
        break;
    }
    scheduleRender();
  }

  function onPointerUp(event) {
    if (state.erasing) {
      endErase();
      return;
    }
    if (!state.drawing) return;
    if (event && event.pointerId != null) {
      try {
        canvas.releasePointerCapture(event.pointerId);
      } catch (error) {
        /* 忽略 */
      }
    }
    commitStroke();
  }

  function onPointerCancel() {
    if (state.erasing) endErase();
    if (state.drawing) commitStroke();
  }

  // -------------------------------------------------------------------------
  // 工具栏状态
  // -------------------------------------------------------------------------

  function setTool(tool) {
    if (!['pen', 'line', 'arrow', 'rectangle', 'highlighter', 'eraser'].includes(tool)) return;
    state.tool = tool;
    for (const button of toolButtons) button.classList.toggle('selected', button.dataset.tool === tool);
    canvas.classList.toggle('erasing', tool === 'eraser');
    if (tool !== 'eraser') eraserCursor.hidden = true;
  }

  function setColor(color) {
    if (!COLORS.includes(color)) return;
    state.color = color;
    for (const button of swatchButtons) {
      button.classList.toggle('selected', button.dataset.color.toUpperCase() === color.toUpperCase());
    }
  }

  function setWidth(width) {
    if (![2, 4, 8].includes(width)) return;
    state.width = width;
    for (const button of widthButtons) {
      button.classList.toggle('selected', Number(button.dataset.width) === width);
    }
  }

  function setBusy(busy) {
    state.exportBusy = busy;
    busyEl.hidden = !busy;
  }

  // -------------------------------------------------------------------------
  // 导出 / 取消
  // -------------------------------------------------------------------------

  async function exportAction(action) {
    if (!state.ready || state.exportBusy) return;
    setBusy(true);
    try {
      const blob = await new Promise((resolve) => canvas.toBlob(resolve, 'image/png'));
      if (!blob) throw new Error('无法编码 PNG');
      const buffer = await blob.arrayBuffer();
      const bytes = new Uint8Array(buffer);
      await api.finish(bytes, action);
    } catch (error) {
      console.error('导出失败', error);
      setBusy(false);
    }
  }

  function cancel() {
    if (state.exportBusy) return;
    try {
      api.cancel();
    } catch (error) {
      console.error('取消失败', error);
    }
  }

  // -------------------------------------------------------------------------
  // 初始化
  // -------------------------------------------------------------------------

  function init(payload) {
    if (!payload || !payload.png) return;
    state.mode = payload.mode === 'copy' ? 'copy' : 'pin';
    state.pixelSize = {
      width: Math.max(1, Math.round(payload.pixelSize.width)),
      height: Math.max(1, Math.round(payload.pixelSize.height)),
    };
    state.displaySize = {
      width: Math.max(1, Math.round(payload.displaySize.width)),
      height: Math.max(1, Math.round(payload.displaySize.height)),
    };
    state.ratio = state.pixelSize.width / state.displaySize.width;

    canvas.width = state.pixelSize.width;
    canvas.height = state.pixelSize.height;
    shell.style.width = `${state.displaySize.width}px`;
    shell.style.height = `${state.displaySize.height}px`;

    const bytes = payload.png instanceof Uint8Array ? payload.png : new Uint8Array(payload.png);
    const blob = new Blob([bytes], { type: 'image/png' });
    if (state.objectUrl) URL.revokeObjectURL(state.objectUrl);
    state.objectUrl = URL.createObjectURL(blob);

    const image = new Image();
    image.onload = () => {
      state.sourceImage = image;
      state.ready = true;
      render();
    };
    image.onerror = () => {
      console.error('截图解码失败');
    };
    image.src = state.objectUrl;

    setTool('pen');
    setColor(DEFAULT_COLOR);
    setWidth(DEFAULT_WIDTH);
    updateHistoryButtons();
    // 标签适配模式：复制模式主按钮仍是「完成」，完成后走复制
    const finishBtn = document.getElementById('finishBtn');
    if (finishBtn) finishBtn.textContent = '完成';
    if (state.mode === 'copy') finishBtn.title = '完成并复制到剪贴板 (Enter)';
  }

  // -------------------------------------------------------------------------
  // 事件绑定
  // -------------------------------------------------------------------------

  for (const button of toolButtons) {
    button.addEventListener('click', () => setTool(button.dataset.tool));
  }
  for (const button of swatchButtons) {
    button.addEventListener('click', () => setColor(button.dataset.color));
  }
  for (const button of widthButtons) {
    button.addEventListener('click', () => setWidth(Number(button.dataset.width)));
  }
  undoBtn.addEventListener('click', undo);
  redoBtn.addEventListener('click', redo);
  document.getElementById('cancelBtn').addEventListener('click', cancel);
  document.getElementById('saveBtn').addEventListener('click', () => exportAction('save'));
  document.getElementById('copyBtn').addEventListener('click', () => exportAction('copy'));
  document.getElementById('finishBtn').addEventListener('click', () => exportAction('finish'));

  canvas.addEventListener('pointerdown', onPointerDown);
  canvas.addEventListener('pointermove', onPointerMove);
  canvas.addEventListener('pointerup', onPointerUp);
  canvas.addEventListener('pointercancel', onPointerCancel);
  canvas.addEventListener('pointerleave', () => {
    eraserCursor.hidden = true;
  });
  canvas.addEventListener('contextmenu', (event) => event.preventDefault());

  window.addEventListener('keydown', (event) => {
    const modifier = event.ctrlKey || event.metaKey;
    if (event.key === 'Escape') {
      event.preventDefault();
      cancel();
      return;
    }
    if (event.key === 'Enter') {
      event.preventDefault();
      exportAction('finish');
      return;
    }
    if (modifier) {
      const key = event.key.toLowerCase();
      if (key === 'z') {
        event.preventDefault();
        if (event.shiftKey) redo();
        else undo();
        return;
      }
      if (key === 'y') {
        event.preventDefault();
        redo();
        return;
      }
      if (key === 'c') {
        event.preventDefault();
        exportAction('copy');
        return;
      }
      if (key === 's') {
        event.preventDefault();
        exportAction('save');
        return;
      }
      if (key === 'w') {
        event.preventDefault();
        cancel();
        return;
      }
      return;
    }
    if (event.altKey) return;
    const key = event.key.toLowerCase();
    if (TOOL_KEYS[key]) {
      event.preventDefault();
      setTool(TOOL_KEYS[key]);
    }
  });

  if (api && typeof api.onInit === 'function') {
    api.onInit(init);
  }
})();
