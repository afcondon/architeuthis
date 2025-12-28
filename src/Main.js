// Main.js - DOM interaction FFI

export const getPatternInput = () => {
  const el = document.getElementById('pattern-input');
  return el ? el.value : 'bd sn hh cp';
};

export const getBpmInput = () => {
  const el = document.getElementById('bpm-input');
  return el ? parseFloat(el.value) || 120 : 120;
};

export const setStatus = (msg) => () => {
  const el = document.getElementById('status');
  if (el) el.textContent = msg;
};

export const setOutputList = (names) => () => {
  const select = document.getElementById('output-select');
  if (!select) return;

  select.innerHTML = '';
  names.forEach((name, i) => {
    const opt = document.createElement('option');
    opt.value = i;
    opt.textContent = name;
    select.appendChild(opt);
  });
};

export const onPlayClick = (handler) => () => {
  const btn = document.getElementById('play-btn');
  if (btn) btn.addEventListener('click', handler);
};

export const onStopClick = (handler) => () => {
  const btn = document.getElementById('stop-btn');
  if (btn) btn.addEventListener('click', handler);
};

export const onPatternChange = (handler) => () => {
  const el = document.getElementById('pattern-input');
  if (el) {
    // Debounce pattern changes
    let timeout;
    el.addEventListener('input', () => {
      clearTimeout(timeout);
      timeout = setTimeout(handler, 300);
    });
  }
};

export const onBpmChange = (handler) => () => {
  const el = document.getElementById('bpm-input');
  if (el) el.addEventListener('input', handler);
};

export const onOutputSelect = (handler) => () => {
  const el = document.getElementById('output-select');
  if (el) {
    el.addEventListener('change', () => {
      handler(parseInt(el.value, 10))();
    });
  }
};
