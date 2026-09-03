import process from 'node:process';

const [debugPort, pageUrl] = process.argv.slice(2);
if (!debugPort || !pageUrl) throw new Error('usage: test-viewer-keyboard.mjs PORT URL');

async function targetSocket() {
  for (let attempt = 0; attempt < 60; attempt += 1) {
    try {
      const targets = await fetch(`http://127.0.0.1:${debugPort}/json/list`).then(response =>
        response.json()
      );
      const target = targets.find(value => value.type === 'page' && value.url.startsWith(pageUrl));
      if (target?.webSocketDebuggerUrl) return target.webSocketDebuggerUrl;
    } catch {}
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  throw new Error('Chromium page target did not become available');
}

const socket = new WebSocket(await targetSocket());
await new Promise((resolve, reject) => {
  socket.addEventListener('open', resolve, { once: true });
  socket.addEventListener('error', reject, { once: true });
});

let sequence = 0;
const pending = new Map();
socket.addEventListener('message', event => {
  const message = JSON.parse(String(event.data));
  if (!message.id || !pending.has(message.id)) return;
  const { resolve, reject } = pending.get(message.id);
  pending.delete(message.id);
  if (message.error) reject(new Error(message.error.message));
  else resolve(message.result);
});

function command(method, params = {}) {
  const id = ++sequence;
  socket.send(JSON.stringify({ id, method, params }));
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
}

async function evaluate(expression) {
  const result = await command('Runtime.evaluate', {
    expression,
    awaitPromise: true,
    returnByValue: true,
  });
  if (result.exceptionDetails) {
    throw new Error(result.exceptionDetails.exception?.description || 'browser evaluation failed');
  }
  return result.result.value;
}

async function waitFor(expression, label) {
  for (let attempt = 0; attempt < 60; attempt += 1) {
    if (await evaluate(expression)) return;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  throw new Error(`timed out waiting for ${label}`);
}

async function press({ key, code, keyCode, text = '', modifiers = 0 }) {
  await command('Input.dispatchKeyEvent', {
    type: 'keyDown', key, code, text, modifiers,
    windowsVirtualKeyCode: keyCode,
    nativeVirtualKeyCode: keyCode,
  });
  await command('Input.dispatchKeyEvent', {
    type: 'keyUp', key, code, modifiers,
    windowsVirtualKeyCode: keyCode,
    nativeVirtualKeyCode: keyCode,
  });
}

function assert(value, message) {
  if (!value) throw new Error(message);
}

try {
  await command('Runtime.enable');
  await command('Page.enable');
  await waitFor(
    `document.readyState === 'complete' && document.querySelectorAll('.note').length > 0`,
    'rendered notes'
  );

  await press({ key: 'j', code: 'KeyJ', keyCode: 74 });
  assert(await evaluate(`Boolean(document.querySelector('.note.selected'))`),
    'J did not select a note');

  await press({ key: 'l', code: 'KeyL', keyCode: 76 });
  assert(await evaluate(`Boolean(document.querySelector('section.selected'))`),
    'L did not select a section');

  await press({ key: '/', code: 'Slash', keyCode: 191, text: '/' });
  assert(await evaluate(`!document.querySelector('#viewer-search').hidden`),
    '/ did not open viewer search');
  assert(await evaluate(`document.activeElement?.id === 'viewer-search-input'`),
    'viewer search did not receive focus');

  await press({ key: 'H', code: 'KeyH', keyCode: 72, text: 'H', modifiers: 8 });
  assert(await evaluate(`document.querySelector('#viewer-search-input').value === 'H'`),
    'H was treated as navigation instead of search input');

  await evaluate(`(() => {
    const input = document.querySelector('#viewer-search-input');
    input.value = '';
    document.querySelector('section').focus();
  })()`);
  await press({ key: 'H', code: 'KeyH', keyCode: 72, text: 'H', modifiers: 8 });
  assert(await evaluate(`document.querySelector('#viewer-search-input').value === 'H'`),
    'search did not recover a printable key after focus lag');

  await press({ key: 'Escape', code: 'Escape', keyCode: 27 });
  assert(await evaluate(`document.querySelector('#viewer-search').hidden`),
    'Escape did not close viewer search');

  await press({ key: 'l', code: 'KeyL', keyCode: 76 });
  await evaluate(`(() => {
    window.__sectionActionCount = 0;
    const button = document.querySelector('section.selected [data-viewer-action="queue"]');
    button.disabled = false;
    button.addEventListener('click', event => {
      event.preventDefault();
      event.stopImmediatePropagation();
      window.__sectionActionCount += 1;
    }, true);
  })()`);
  await press({ key: 'q', code: 'KeyQ', keyCode: 81 });
  assert(await evaluate(`window.__sectionActionCount === 1`),
    'Q did not invoke the selected section action');

  await press({ key: 'j', code: 'KeyJ', keyCode: 74 });
  await evaluate(`(() => {
    window.__noteActionCount = 0;
    const button = document.querySelector('.note.selected [data-viewer-action="feed"]');
    button.hidden = false;
    button.disabled = false;
    button.addEventListener('click', event => {
      event.preventDefault();
      event.stopImmediatePropagation();
      window.__noteActionCount += 1;
    }, true);
  })()`);
  await press({ key: 'f', code: 'KeyF', keyCode: 70 });
  assert(await evaluate(`window.__noteActionCount === 1`),
    'F did not invoke the selected note action');
} finally {
  socket.close();
}
