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

  assert(await evaluate(`document.querySelector('.feed-queue-chip.current')?.textContent
    === 'Now · Inbox / Unsorted'`),
    'current feed destination is not globally identified');
  assert(await evaluate(`[...document.querySelectorAll('.feed-queue-chip')]
    .some(chip => chip.textContent.includes('Ideas / Cross bucket queue'))`),
    'waiting section from another bucket is not visible');

  assert(await evaluate(`document.querySelector('.feed-current .section-handle')?.draggable === true`),
    'the actively feeding section cannot be dragged');
  await evaluate(`(() => {
    const sections = [...document.querySelectorAll('section')];
    const source = sections.find(section => section.querySelector('h2')?.textContent === 'Unsorted');
    const target = sections.find(section => section.querySelector('h2')?.textContent === 'Drag last');
    const transfer = new DataTransfer();
    source.querySelector('.section-handle').dispatchEvent(new DragEvent('dragstart', {
      bubbles: true, cancelable: true, dataTransfer: transfer
    }));
    const bounds = target.querySelector('.section-heading').getBoundingClientRect();
    target.querySelector('.section-heading').dispatchEvent(new DragEvent('dragover', {
      bubbles: true, cancelable: true, clientY: bounds.bottom - 1, dataTransfer: transfer
    }));
    window.__sectionDrag = { source, target, transfer };
  })()`);
  assert(await evaluate(`window.__sectionDrag.target.classList.contains('section-drop-after')`),
    'the lower half of a heading did not expose an after drop target');
  await evaluate(`(() => {
    const { source, target, transfer } = window.__sectionDrag;
    const bounds = target.querySelector('.section-heading').getBoundingClientRect();
    target.querySelector('.section-heading').dispatchEvent(new DragEvent('drop', {
      bubbles: true, cancelable: true, clientY: bounds.bottom - 1, dataTransfer: transfer
    }));
    source.querySelector('.section-handle').dispatchEvent(new DragEvent('dragend', {
      bubbles: true, cancelable: true, dataTransfer: transfer
    }));
  })()`);
  await waitFor(
    `[...document.querySelectorAll('section h2')].map(heading => heading.textContent).join('|') === 'Drag middle|Drag last|Unsorted'`,
    'active section moved after the last heading'
  );

  await evaluate(`(() => {
    const sections = [...document.querySelectorAll('section')];
    const source = sections.find(section => section.querySelector('h2')?.textContent === 'Unsorted');
    const target = sections.find(section => section.querySelector('h2')?.textContent === 'Drag middle');
    const transfer = new DataTransfer();
    source.querySelector('.section-handle').dispatchEvent(new DragEvent('dragstart', {
      bubbles: true, cancelable: true, dataTransfer: transfer
    }));
    const bounds = target.querySelector('.section-heading').getBoundingClientRect();
    target.querySelector('.section-heading').dispatchEvent(new DragEvent('dragover', {
      bubbles: true, cancelable: true, clientY: bounds.top + 1, dataTransfer: transfer
    }));
    window.__sectionDrag = { source, target, transfer };
  })()`);
  assert(await evaluate(`window.__sectionDrag.target.classList.contains('section-drop-before')`),
    'the upper half of the first heading did not expose a before drop target');
  await evaluate(`(() => {
    const { source, target, transfer } = window.__sectionDrag;
    const bounds = target.querySelector('.section-heading').getBoundingClientRect();
    target.querySelector('.section-heading').dispatchEvent(new DragEvent('drop', {
      bubbles: true, cancelable: true, clientY: bounds.top + 1, dataTransfer: transfer
    }));
    source.querySelector('.section-handle').dispatchEvent(new DragEvent('dragend', {
      bubbles: true, cancelable: true, dataTransfer: transfer
    }));
  })()`);
  await waitFor(
    `[...document.querySelectorAll('section h2')].map(heading => heading.textContent).join('|') === 'Unsorted|Drag middle|Drag last'`,
    'active section moved before the first heading'
  );

  await evaluate(`(() => {
    window.scrollTo(0, 0);
    document.querySelector('main').style.minHeight = '3000px';
    const source = [...document.querySelectorAll('section')]
      .find(section => section.querySelector('h2')?.textContent === 'Unsorted');
    const transfer = new DataTransfer();
    source.querySelector('.section-handle').dispatchEvent(new DragEvent('dragstart', {
      bubbles: true, cancelable: true, dataTransfer: transfer
    }));
    document.dispatchEvent(new DragEvent('dragover', {
      bubbles: true, cancelable: true, clientY: window.innerHeight - 1, dataTransfer: transfer
    }));
    window.__autoScrollDrag = { source, transfer };
  })()`);
  await waitFor(`window.scrollY > 0`, 'section drag viewport autoscroll');
  await evaluate(`(() => {
    const { source, transfer } = window.__autoScrollDrag;
    source.querySelector('.section-handle').dispatchEvent(new DragEvent('dragend', {
      bubbles: true, cancelable: true, dataTransfer: transfer
    }));
    document.querySelector('main').style.minHeight = '';
    window.scrollTo(0, 0);
  })()`);

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

  await evaluate(`(() => {
    window.__imageActionCount = 0;
    const button = document.querySelector('.note.selected [data-viewer-action="add-image"]');
    button.addEventListener('click', event => {
      event.preventDefault();
      event.stopImmediatePropagation();
      window.__imageActionCount += 1;
    }, true);
  })()`);
  await press({ key: 'P', code: 'KeyP', keyCode: 80, text: 'P', modifiers: 8 });
  assert(await evaluate(`window.__imageActionCount === 1`),
    'P did not invoke add image on the selected note');

  const moveState = await evaluate(`(() => {
    const selected = document.querySelector('.note.selected');
    const pending = [...selected.closest('section').querySelectorAll('.note:not(.sent)')]
      .filter(note => note.checkVisibility());
    return { selected: selected.dataset.noteId, first: pending[0].dataset.noteId,
      second: pending[1].dataset.noteId };
  })()`);
  assert(moveState.selected === moveState.first && Boolean(moveState.second),
    'move-key test requires the first of at least two pending notes');
  await press({ key: 'D', code: 'KeyD', keyCode: 68, text: 'D', modifiers: 8 });
  await waitFor(
    `document.querySelector('.note.selected')?.dataset.noteId === '${moveState.selected}'
      && [...document.querySelector('.note.selected').closest('section').querySelectorAll('.note:not(.sent)')]
        .filter(note => note.checkVisibility())[0]?.dataset.noteId === '${moveState.second}'`,
    'D moved the selected note down'
  );
  await press({ key: 'U', code: 'KeyU', keyCode: 85, text: 'U', modifiers: 8 });
  await waitFor(
    `document.querySelector('.note.selected')?.dataset.noteId === '${moveState.selected}'
      && [...document.querySelector('.note.selected').closest('section').querySelectorAll('.note:not(.sent)')]
        .filter(note => note.checkVisibility())[0]?.dataset.noteId === '${moveState.selected}'`,
    'U moved the selected note up'
  );

  const noteCount = await evaluate(`document.querySelectorAll('.note').length`);
  await press({ key: 'a', code: 'KeyA', keyCode: 65 });
  await waitFor(
    `Boolean(document.querySelector('.note .text[data-provisional-note="true"]'))`,
    'new note editor opened by A'
  );
  assert(await evaluate(`document.querySelectorAll('.note').length === ${noteCount + 1}`),
    'A did not create a note in the selected note section');
  assert(await evaluate(`!document.querySelector('input[type="file"]')`),
    'A opened an attachment picker instead of adding a note');
  await press({ key: 'Escape', code: 'Escape', keyCode: 27 });
  await waitFor(`document.querySelectorAll('.note').length === ${noteCount}`,
    'provisional note cleanup');

  await press({ key: 'l', code: 'KeyL', keyCode: 76 });
  assert(await evaluate(`Boolean(document.querySelector('section.selected'))`),
    'section selection was unavailable before testing S');
  const selectedSection = await evaluate(`document.querySelector('section.selected').dataset.sectionId`);
  await press({ key: 'D', code: 'KeyD', keyCode: 68, text: 'D', modifiers: 8 });
  await waitFor(
    `[...document.querySelectorAll('section')].findIndex(section => section.dataset.sectionId === '${selectedSection}') === 1`,
    'D moved the selected section down'
  );
  await press({ key: 'U', code: 'KeyU', keyCode: 85, text: 'U', modifiers: 8 });
  await waitFor(
    `[...document.querySelectorAll('section')].findIndex(section => section.dataset.sectionId === '${selectedSection}') === 0`,
    'U moved the selected section up'
  );
  assert(await evaluate(`(() => {
    const button = document.querySelector('[data-viewer-action="add-section"]');
    return Boolean(button && !button.disabled && button.checkVisibility());
  })()`), 'Add section button is unavailable');
  await press({ key: 's', code: 'KeyS', keyCode: 83 });
  await waitFor(`!document.querySelector('#modal-backdrop').hidden`,
    'section creation dialog opened by S');
  assert(await evaluate(`document.querySelector('#modal-title').textContent === 'Create section'`),
    'S opened the wrong action');
  await press({ key: 'Escape', code: 'Escape', keyCode: 27 });

  await evaluate(`fetch('/api/feed', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ action: 'stop' })
  })`);
  await command('Page.reload', { ignoreCache: true });
  await new Promise(resolve => setTimeout(resolve, 300));
  await waitFor(`document.readyState === 'complete'`, 'viewer reload after stopping feed');
  await waitFor(`document.querySelector('.feed-queue-chip.current')?.textContent
    === 'Current · Inbox / Unsorted'`, 'persistent stopped feed destination');
  assert(await evaluate(`[...document.querySelectorAll('.feed-queue-chip')]
    .some(chip => chip.textContent.includes('Ideas / Cross bucket queue'))`),
    'global waiting queue disappeared when the feed stopped');

  await press({ key: 't', code: 'KeyT', keyCode: 84 });
  await waitFor(`!document.querySelector('#routing-backdrop').hidden`,
    'routing dialog opened by T');
  await waitFor(`document.activeElement?.id === 'routing-target'`,
    'routing target received focus');
  await press({ key: 'Tab', code: 'Tab', keyCode: 9 });
  assert(await evaluate(`document.activeElement?.id === 'routing-mode'`),
    'Tab did not move from target to mode');
  const routingMode = await evaluate(`document.querySelector('#routing-mode').value`);
  await press({ key: 'j', code: 'KeyJ', keyCode: 74, text: 'j' });
  assert(await evaluate(`document.querySelector('#routing-mode').value !== '${routingMode}'`),
    'J did not change the focused routing choice');
  await press({ key: 'Enter', code: 'Enter', keyCode: 13 });
  await waitFor(`document.querySelector('#routing-backdrop').hidden`,
    'Enter did not apply and close routing');

  await evaluate(`(() => {
    window.__routingFetch = window.fetch;
    window.fetch = (...arguments_) => String(arguments_[0]).includes('/api/targets')
      ? new Promise(() => {}) : window.__routingFetch(...arguments_);
  })()`);
  await press({ key: 't', code: 'KeyT', keyCode: 84 });
  await waitFor(`!document.querySelector('#routing-backdrop').hidden`,
    'routing dialog did not open for loading-state cancellation');
  await waitFor(`document.activeElement?.id === 'routing-cancel'`,
    'routing Cancel did not receive focus while targets were loading');
  assert(await evaluate(`!document.querySelector('#routing-cancel').disabled`),
    'routing Cancel was disabled while targets were loading');
  await evaluate(`document.querySelector('#routing-cancel').click()`);
  await waitFor(`document.querySelector('#routing-backdrop').hidden`,
    'Cancel did not close routing while targets were loading');
  await press({ key: 't', code: 'KeyT', keyCode: 84 });
  await waitFor(`!document.querySelector('#routing-backdrop').hidden`,
    'routing dialog did not reopen for loading-state Escape');
  await press({ key: 'Escape', code: 'Escape', keyCode: 27 });
  await waitFor(`document.querySelector('#routing-backdrop').hidden`,
    'Escape did not close routing while targets were loading');
  await evaluate(`window.fetch = window.__routingFetch; delete window.__routingFetch`);

  await command('Emulation.setDeviceMetricsOverride', {
    width: 900, height: 480, deviceScaleFactor: 1, mobile: false
  });
  await press({ key: '?', code: 'Slash', keyCode: 191, text: '?', modifiers: 8 });
  await waitFor(`!document.querySelector('#modal-backdrop').hidden`,
    'keyboard reference opened by ?');
  assert(await evaluate(`(() => {
    const card = document.querySelector('#modal-card');
    const bounds = card.getBoundingClientRect();
    const style = getComputedStyle(card);
    return bounds.top >= 0 && bounds.bottom <= window.innerHeight
      && style.overflowY === 'auto' && card.scrollHeight > card.clientHeight;
  })()`), 'keyboard reference is not viewport-bounded and scrollable');
  assert(await evaluate(`parseFloat(getComputedStyle(
    document.querySelector('#modal-message')).fontSize) <= 13`),
    'keyboard reference did not use compact text');
  await press({ key: 'Escape', code: 'Escape', keyCode: 27 });
  await command('Emulation.clearDeviceMetricsOverride');
} finally {
  socket.close();
}
