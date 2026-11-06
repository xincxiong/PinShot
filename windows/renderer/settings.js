'use strict';

/**
 * 设置窗口渲染进程：控件变化立即通过 IPC 写回主进程，
 * 主进程负责持久化到 userData/settings.json，并广播给所有窗口。
 */

(() => {
  const api = window.pinshot && window.pinshot.settings;

  const TOGGLE_KEYS = [
    'autoHideEnabled',
    'hideEntirely',
    'clickThroughWhenHidden',
    'showPinBorder',
    'showPinShadow',
    'defaultPinDesktop',
  ];

  const navItems = Array.from(document.querySelectorAll('.nav-item'));
  const panes = Array.from(document.querySelectorAll('.pane'));
  const delaySlider = document.getElementById('delaySlider');
  const ghostSlider = document.getElementById('ghostSlider');
  const delayValue = document.getElementById('delayValue');
  const ghostValue = document.getElementById('ghostValue');
  const closeBtn = document.getElementById('closeBtn');
  const resetBtn = document.getElementById('resetBtn');
  const hotkeyWarning = document.getElementById('hotkeyWarning');
  const hotkeyWarningText = document.getElementById('hotkeyWarningText');
  const sidebarVersion = document.getElementById('sidebarVersion');
  const aboutVersion = document.getElementById('aboutVersion');

  const state = {
    settings: null,
    applying: false,
    pendingDelay: null,
    pendingGhost: null,
  };

  function setSwitch(element, checked) {
    element.setAttribute('aria-checked', checked ? 'true' : 'false');
  }

  function updateSliderTrack(input) {
    const min = Number(input.min) || 0;
    const max = Number(input.max) || 100;
    const value = Number(input.value);
    const percent = max > min ? ((value - min) / (max - min)) * 100 : 0;
    input.style.setProperty('--pct', `${percent}%`);
  }

  function render(settings) {
    if (!settings) return;
    state.settings = settings;
    state.applying = true;

    for (const key of TOGGLE_KEYS) {
      const element = document.getElementById(key);
      if (element) setSwitch(element, settings[key] !== false);
    }

    const delay = Number(settings.autoHideDelay);
    if (Number.isFinite(delay)) {
      delaySlider.value = String(delay);
      updateSliderTrack(delaySlider);
      delayValue.textContent = `${delay.toFixed(1)} s`;
    }

    const ghostPercent = Math.round((Number(settings.ghostAlpha) || 0.15) * 100);
    ghostSlider.value = String(ghostPercent);
    updateSliderTrack(ghostSlider);
    ghostValue.textContent = `${ghostPercent}%`;

    if (settings.version) {
      if (sidebarVersion) sidebarVersion.textContent = `v${settings.version} · Windows`;
      if (aboutVersion) aboutVersion.textContent = `v${settings.version} · Electron MVP`;
    }

    if (settings.hotkeyStatus) {
      const failed = Object.entries(settings.hotkeyStatus)
        .filter(([, ok]) => !ok)
        .map(([key]) => {
          const map = { capturePin: 'Ctrl+Shift+2', captureCopy: 'Ctrl+Shift+1', clipboardPin: 'Ctrl+Shift+3' };
          return map[key] || key;
        });
      if (hotkeyWarning) {
        hotkeyWarning.hidden = failed.length === 0;
        if (hotkeyWarningText && failed.length > 0) {
          hotkeyWarningText.textContent = `${failed.join('、')} 可能被其他应用占用，仍可从托盘菜单触发。`;
        }
      }
    }

    state.applying = false;
  }

  function update(patch) {
    if (!api || !api.update) return;
    api.update(patch).catch((error) => console.error('保存设置失败', error));
  }

  function selectPane(pane) {
    for (const item of navItems) item.classList.toggle('active', item.dataset.pane === pane);
    for (const section of panes) section.classList.toggle('active', section.dataset.pane === pane);
    const content = document.getElementById('content');
    if (content) content.scrollTop = 0;
  }

  for (const item of navItems) {
    item.addEventListener('click', () => selectPane(item.dataset.pane));
  }

  for (const key of TOGGLE_KEYS) {
    const element = document.getElementById(key);
    if (!element) continue;
    element.addEventListener('click', () => {
      const current = state.settings ? state.settings[key] !== false : true;
      const next = !current;
      setSwitch(element, next);
      if (state.settings) state.settings[key] = next;
      update({ [key]: next });
    });
  }

  function scheduleDelayUpdate() {
    const value = Number(delaySlider.value);
    updateSliderTrack(delaySlider);
    delayValue.textContent = `${value.toFixed(1)} s`;
    if (state.settings) state.settings.autoHideDelay = value;
    if (state.pendingDelay) clearTimeout(state.pendingDelay);
    state.pendingDelay = setTimeout(() => {
      state.pendingDelay = null;
      update({ autoHideDelay: value });
    }, 60);
  }

  function scheduleGhostUpdate() {
    const percent = Number(ghostSlider.value);
    updateSliderTrack(ghostSlider);
    ghostValue.textContent = `${percent}%`;
    if (state.settings) state.settings.ghostAlpha = percent / 100;
    if (state.pendingGhost) clearTimeout(state.pendingGhost);
    state.pendingGhost = setTimeout(() => {
      state.pendingGhost = null;
      update({ ghostAlpha: percent / 100 });
    }, 60);
  }

  delaySlider.addEventListener('input', scheduleDelayUpdate);
  ghostSlider.addEventListener('input', scheduleGhostUpdate);

  closeBtn.addEventListener('click', () => api.close());
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      event.preventDefault();
      api.close();
    }
  });

  resetBtn.addEventListener('click', () => {
    if (!api || !api.reset) return;
    api
      .reset()
      .then((settings) => render(settings))
      .catch((error) => console.error('恢复默认失败', error));
  });

  // 初始化
  updateSliderTrack(delaySlider);
  updateSliderTrack(ghostSlider);

  if (api) {
    api.onInit(render);
    api.onChange(render);
    api.onFocusPane((pane) => {
      if (pane) selectPane(pane);
    });
    api
      .get()
      .then(render)
      .catch((error) => console.error('读取设置失败', error));
  }
})();
