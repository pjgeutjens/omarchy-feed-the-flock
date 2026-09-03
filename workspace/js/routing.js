/** Safe, atomic delivery-routing editor for the HTML workspace. */
import { request } from './api.js';

const backdrop = document.querySelector('#routing-backdrop');
const card = document.querySelector('#routing-card');
const targetSelect = document.querySelector('#routing-target');
const targetHelp = document.querySelector('#routing-target-help');
const modeSelect = document.querySelector('#routing-mode');
const modeHelp = document.querySelector('#routing-mode-help');
const orderSelect = document.querySelector('#routing-order');
const orderHelp = document.querySelector('#routing-order-help');
const message = document.querySelector('#routing-message');
const cancel = document.querySelector('#routing-cancel');
const apply = document.querySelector('#routing-apply');

const MODES = [
  { value: 'idle-active-next', label: 'Section · One by one', description: 'Deliver one note from the active section per idle turn.' },
  { value: 'idle-active-batch', label: 'Section · Batch', description: 'Deliver all pending notes from the active section in one prompt.' },
  { value: 'idle-all-next', label: 'All · One by one', description: 'Deliver one note per idle turn, following section order.' },
  { value: 'idle-all-batch', label: 'All · Batch', description: 'Deliver all pending notes in section order as one prompt.' }
];
const ORDERS = [
  { value: 'fifo', label: 'FIFO', description: 'Deliver the oldest pending note first.' },
  { value: 'lifo', label: 'LIFO', description: 'Deliver the newest pending note first.' }
];

let open = false;
let busy = false;
let session = 0;
let targets = [];
let previousFocus = null;
let appliedCallback = null;

export function isRoutingOpen() { return open; }

function appendOptions(select, values, placeholder = '') {
  const options = [];
  if (placeholder) {
    const option = document.createElement('option');
    option.value = '';
    option.textContent = placeholder;
    option.disabled = true;
    option.selected = true;
    options.push(option);
  }
  for (const value of values) {
    const option = document.createElement('option');
    option.value = value.value;
    option.textContent = value.label;
    options.push(option);
  }
  select.replaceChildren(...options);
}

function selectedDescription(select, values) {
  return values.find(value => value.value === select.value)?.description || '';
}

function refreshHelp() {
  const target = targets.find(value => value.id === targetSelect.value);
  targetHelp.textContent = target ? `Herdr status: ${target.status}` : 'Choose a currently discovered Herdr agent.';
  modeHelp.textContent = selectedDescription(modeSelect, MODES);
  orderHelp.textContent = selectedDescription(orderSelect, ORDERS);
}

function moveSelection(select, direction) {
  const enabled = [...select.options].filter(option => !option.disabled);
  if (!enabled.length) return;
  const current = Math.max(0, enabled.indexOf(select.selectedOptions[0]));
  const next = Math.max(0, Math.min(enabled.length - 1, current + direction));
  select.value = enabled[next].value;
  select.dispatchEvent(new Event('change', { bubbles: true }));
}

function setMessage(text, kind = '') {
  message.textContent = text;
  message.className = `routing-message${kind ? ` ${kind}` : ''}`;
}

function setBusy(value) {
  busy = value;
  targetSelect.disabled = value;
  modeSelect.disabled = value;
  orderSelect.disabled = value;
  cancel.disabled = value;
  apply.disabled = value;
}

function closeRouting() {
  if (!open || busy) return;
  open = false;
  session += 1;
  backdrop.hidden = true;
  appliedCallback = null;
  if (previousFocus?.isConnected) previousFocus.focus();
}

export async function openRouting({ onApplied } = {}) {
  if (open) return;
  open = true;
  session += 1;
  const activeSession = session;
  previousFocus = document.activeElement;
  appliedCallback = onApplied || null;
  targets = [];
  appendOptions(targetSelect, [], 'Loading Herdr targets…');
  appendOptions(modeSelect, MODES);
  appendOptions(orderSelect, ORDERS);
  setMessage('Loading current routing…');
  setBusy(true);
  backdrop.hidden = false;

  try {
    const data = await request('/api/targets');
    if (!open || activeSession !== session) return;
    targets = (data.targets || []).filter(target => target.kind === 'herdr');
    appendOptions(
      targetSelect,
      targets.map(target => ({ value: target.id, label: target.label })),
      targets.length ? 'Select a Herdr target…' : 'No Herdr targets discovered'
    );
    if (targets.some(target => target.id === data.selectedTargetId)) {
      targetSelect.value = data.selectedTargetId;
    }
    modeSelect.value = MODES.some(mode => mode.value === data.deliveryMode)
      ? data.deliveryMode : MODES[0].value;
    orderSelect.value = ORDERS.some(order => order.value === data.queueOrder)
      ? data.queueOrder : ORDERS[0].value;
    const locked = Boolean(data.feedEnabled);
    setBusy(false);
    targetSelect.disabled = locked || targets.length === 0;
    modeSelect.disabled = locked;
    orderSelect.disabled = locked;
    apply.disabled = locked || !targetSelect.value;
    if (locked) setMessage('Stop the feed before changing its destination or ordering.', 'warning');
    else if (!targets.length) setMessage('No Herdr targets are currently available.', 'error');
    else setMessage('Review all three values, then apply them together.');
    refreshHelp();
    requestAnimationFrame(() => (targetSelect.disabled ? cancel : targetSelect).focus());
  } catch (error) {
    if (!open || activeSession !== session) return;
    setBusy(false);
    targetSelect.disabled = true;
    modeSelect.disabled = true;
    orderSelect.disabled = true;
    apply.disabled = true;
    setMessage(error.message, 'error');
    cancel.focus();
  }
}

targetSelect.addEventListener('change', () => {
  apply.disabled = !targetSelect.value;
  refreshHelp();
});
modeSelect.addEventListener('change', refreshHelp);
orderSelect.addEventListener('change', refreshHelp);
cancel.addEventListener('click', closeRouting);
card.addEventListener('submit', async event => {
  event.preventDefault();
  if (busy || apply.disabled || !targetSelect.value) return;
  setBusy(true);
  setMessage('Applying routing…');
  try {
    const result = await request('/api/routing', {
      method: 'POST',
      body: JSON.stringify({
        targetId: targetSelect.value,
        deliveryMode: modeSelect.value,
        queueOrder: orderSelect.value
      })
    });
    const callback = appliedCallback;
    busy = false;
    closeRouting();
    if (callback) await callback(result);
  } catch (error) {
    setBusy(false);
    setMessage(error.message, 'error');
    apply.disabled = !targetSelect.value;
  }
});
backdrop.addEventListener('mousedown', event => {
  if (event.target === backdrop) closeRouting();
});
backdrop.addEventListener('keydown', event => {
  const focusedSelect = event.target instanceof HTMLSelectElement ? event.target : null;
  const key = event.key.toLowerCase();
  if (!busy && focusedSelect && (key === 'j' || key === 'k')) {
    event.preventDefault();
    moveSelection(focusedSelect, key === 'j' ? 1 : -1);
  } else if (!busy && focusedSelect && event.key === 'Enter' && !apply.disabled) {
    event.preventDefault();
    card.requestSubmit();
  } else if (event.key === 'Escape' && !busy) {
    event.preventDefault();
    closeRouting();
  } else if (event.key === 'Tab') {
    const controls = [...card.querySelectorAll('select:not([disabled]), button:not([disabled])')];
    if (!controls.length) return;
    const first = controls[0];
    const last = controls[controls.length - 1];
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault(); last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault(); first.focus();
    }
  }
});
