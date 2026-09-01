/** Accessible modal primitives shared by bucket and section actions. */
const backdrop = document.querySelector('#modal-backdrop');
const card = document.querySelector('#modal-card');
const title = document.querySelector('#modal-title');
const message = document.querySelector('#modal-message');
const input = document.querySelector('#modal-input');
const cancel = document.querySelector('#modal-cancel');
const secondary = document.querySelector('#modal-secondary');
const confirm = document.querySelector('#modal-confirm');

let open = false;
let resolveModal = null;
let inputMode = false;
let previousFocus = null;

export function isModalOpen() { return open; }

function closeModal(value) {
  if (!open) return;
  open = false;
  backdrop.hidden = true;
  const resolve = resolveModal;
  resolveModal = null;
  if (previousFocus?.isConnected) previousFocus.focus();
  if (resolve) resolve(value);
}

function showModal({ title: heading, message: detail = '', value = '', input: wantsInput = false,
                     confirmLabel = 'Confirm', danger = false, secondaryLabel = '',
                     maxLength = 50 }) {
  if (open) closeModal(null);
  open = true;
  inputMode = wantsInput;
  previousFocus = document.activeElement;
  title.textContent = heading;
  message.textContent = detail;
  message.hidden = !detail;
  input.hidden = !wantsInput;
  input.value = value;
  input.maxLength = maxLength;
  confirm.textContent = confirmLabel;
  secondary.textContent = secondaryLabel;
  secondary.hidden = !secondaryLabel;
  confirm.className = `modal-button ${danger ? 'danger' : 'primary'}`;
  backdrop.hidden = false;
  const result = new Promise(resolve => { resolveModal = resolve; });
  requestAnimationFrame(() => {
    if (wantsInput) {
      input.focus();
      input.select();
    } else confirm.focus();
  });
  return result;
}

export function requestText(options) { return showModal({ ...options, input: true }); }
export async function requestConfirmation(options) {
  return await showModal({ ...options, input: false }) === true;
}

cancel.addEventListener('click', () => closeModal(null));
secondary.addEventListener('click', () => closeModal('secondary'));
card.addEventListener('submit', event => {
  event.preventDefault();
  if (inputMode) {
    const value = input.value.trim();
    if (!value) {
      input.focus();
      return;
    }
    closeModal(value);
  } else closeModal(true);
});
backdrop.addEventListener('mousedown', event => {
  if (event.target === backdrop) closeModal(null);
});
backdrop.addEventListener('keydown', event => {
  if (event.key === 'Escape') {
    event.preventDefault();
    closeModal(null);
  } else if (event.key === 'Tab') {
    const controls = [...card.querySelectorAll(
      'input:not([hidden]), button:not([disabled]):not([hidden])')];
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
