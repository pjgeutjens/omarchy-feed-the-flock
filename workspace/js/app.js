import { request } from './api.js';
import { isModalOpen, requestConfirmation, requestText } from './modal.js';
import { loadTheme } from './theme.js';

const params = new URLSearchParams(location.search);
let bucketId = params.get('bucket') || 'inbox';
const documentEl = document.querySelector('#document');
const titleEl = document.querySelector('#title');
const statusEl = document.querySelector('#status');
const workspaceControlsEl = document.querySelector('#workspace-controls');
const controlsSentinelEl = document.querySelector('#controls-sentinel');
const bucketStatsTextEl = document.querySelector('#bucket-stats-text');
const toastEl = document.querySelector('#toast');
const targetNameEl = document.querySelector('#target-name');
const feedQueueEl = document.querySelector('#feed-queue-list');
const feedToggleEl = document.querySelector('#feed-toggle');
const bucketTrainEl = document.querySelector('#bucket-train');
let selectedTargetId = 'clipboard';
let activeNoteIds = [];
let currentDocument = null;
let draggingId = null;
let draggingSectionId = null;
let editing = false;
let showSubmitted = localStorage.getItem('agent-feed-show-submitted') !== 'false';
let toastTimer = null;

const controlsObserver = new IntersectionObserver(entries => {
  workspaceControlsEl.classList.toggle('stuck', !entries[0].isIntersecting);
}, { threshold: 0 });
controlsObserver.observe(controlsSentinelEl);

async function loadBuckets(preferred = bucketId) {
  const data = await request('/api/buckets');
  const buckets = data.buckets || [];
  if (!buckets.some(bucket => bucket.id === preferred)) preferred = buckets[0]?.id || 'inbox';
  bucketId = preferred;
  bucketTrainEl.replaceChildren(...buckets.map(bucket => {
    const button = document.createElement('button');
    button.className = `bucket-chip${bucket.id === bucketId ? ' active' : ''}`;
    button.type = 'button';
    button.role = 'tab';
    button.dataset.bucketId = bucket.id;
    button.textContent = bucket.name;
    button.title = `${bucket.name} · ${bucket.count} messages`;
    button.setAttribute('aria-selected', String(bucket.id === bucketId));
    button.onclick = async () => {
      if (bucket.id === bucketId) return;
      bucketId = bucket.id;
      history.replaceState(null, '', `?bucket=${encodeURIComponent(bucketId)}`);
      await loadBuckets(bucketId);
      await load();
    };
    return button;
  }));
  history.replaceState(null, '', `?bucket=${encodeURIComponent(bucketId)}`);
  return buckets;
}

async function bucketAction(path, body, nextBucket = bucketId) {
  try {
    const result = await request(path, { method: 'POST', body: JSON.stringify(body) });
    await loadBuckets(result.id || nextBucket);
    await load();
  } catch (error) { setStatus(error.message, true); }
}

document.querySelector('#bucket-left').onclick = () =>
  bucketAction('/api/bucket/move', { id: bucketId, direction: 'left' });
document.querySelector('#bucket-right').onclick = () =>
  bucketAction('/api/bucket/move', { id: bucketId, direction: 'right' });

async function exportBucket() {
  try {
    const result = await request('/api/bucket/export', {
      method: 'POST', body: JSON.stringify({ id: bucketId })
    });
    setStatus(`Exported to ${result.displayPath}`);
    showToast('Bucket exported');
  } catch (error) { setStatus(error.message, true); }
}

function importBucket() {
  const picker = document.createElement('input');
  picker.type = 'file';
  picker.accept = '.md,text/markdown,text/plain';
  picker.onchange = async () => {
    const file = picker.files?.[0];
    if (!file) return;
    if (file.size > 2 * 1024 * 1024) {
      setStatus('Markdown imports must be at most 2 MB.', true);
      return;
    }
    try {
      const result = await request('/api/bucket/import', {
        method: 'POST', body: JSON.stringify({ markdown: await file.text() })
      });
      await loadBuckets(result.id);
      await load();
      showToast(`Imported ${result.noteCount} notes`);
    } catch (error) { setStatus(error.message, true); }
  };
  picker.click();
}

document.querySelector('#bucket-import').onclick = importBucket;
document.querySelector('#bucket-export').onclick = exportBucket;
document.querySelector('#bucket-add').onclick = async () => {
  const name = await requestText({
    title: 'Create bucket', message: 'Add a new top-level collection.',
    confirmLabel: 'Create', maxLength: 40
  });
  if (name) bucketAction('/api/bucket/create', { name });
};
document.querySelector('#bucket-rename').onclick = async () => {
  const name = await requestText({
    title: 'Rename bucket', message: 'Choose a clear name for this collection.',
    value: titleEl.textContent, confirmLabel: 'Rename', maxLength: 40
  });
  if (name) bucketAction('/api/bucket/rename', { id: bucketId, name });
};
document.querySelector('#bucket-delete').onclick = async () => {
  const confirmed = await requestConfirmation({
    title: `Delete ${titleEl.textContent}?`,
    message: 'This permanently deletes the bucket and all of its notes.',
    confirmLabel: 'Delete bucket', danger: true
  });
  if (confirmed) bucketAction('/api/bucket/delete', { id: bucketId }, null);
};

function setStatus(message, error = false) {
  statusEl.textContent = message;
  statusEl.classList.toggle('error', error);
}

function showToast(message) {
  toastEl.textContent = message;
  toastEl.classList.remove('show');
  void toastEl.offsetWidth;
  toastEl.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toastEl.classList.remove('show'), 1200);
}

async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
  } catch (_) {
    const field = document.createElement('textarea');
    field.value = text;
    field.style.position = 'fixed';
    field.style.opacity = '0';
    document.body.append(field);
    field.select();
    document.execCommand('copy');
    field.remove();
  }
  showToast('Copied to clipboard');
}

function imageFiles(items) {
  return [...(items || [])].map(item => item instanceof File ? item : item.getAsFile?.())
    .filter(file => file && file.type.startsWith('image/'));
}

async function uploadAttachment(noteId, file) {
  if (file.size > 8 * 1024 * 1024) throw new Error('Images must be 8 MB or smaller');
  const data = await new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result).split(',', 2)[1] || '');
    reader.onerror = () => reject(new Error('Could not read the image'));
    reader.readAsDataURL(file);
  });
  await request('/api/attachment/create', {
    method: 'POST',
    body: JSON.stringify({ noteId, name: file.name || 'clipboard-image', mimeType: file.type, data })
  });
}

async function uploadAttachments(noteId, files, existingCount = 0) {
  if (!files.length) return;
  if (existingCount + files.length > 5) {
    setStatus('A note can have at most 5 images.', true);
    return;
  }
  try {
    for (const file of files) await uploadAttachment(noteId, file);
    await load();
    showToast(files.length === 1 ? 'Image attached' : `${files.length} images attached`);
  } catch (error) { setStatus(error.message, true); }
}

function updateActiveNotes() {
  const active = new Set(activeNoteIds);
  document.querySelectorAll('.note').forEach(row => {
    const isActive = row.classList.contains('sent') && active.has(row.dataset.noteId);
    row.classList.toggle('active', isActive);
    const label = row.querySelector('.active-note-label');
    if (label) label.hidden = !isActive;
  });
}

async function loadTargets() {
  try {
    const data = await request('/api/targets');
    selectedTargetId = data.selectedTargetId || 'clipboard';
    activeNoteIds = data.activeNoteIds || [];
    updateActiveNotes();
    const selected = (data.targets || []).find(target => target.id === selectedTargetId);
    targetNameEl.textContent = data.selectedTargetLabel || selected?.label || 'Disconnected target';
    targetNameEl.title = selected
      ? `${selected.label} — ${selected.status}`
      : 'Select another target in the Feed the Flock plugin';
    if (currentDocument?.feedEnabled && selected && !selected.available) {
      setStatus(`Feed waiting · ${selected.label} is ${selected.status}`);
    } else if (currentDocument?.feedEnabled && selected?.available) {
      setStatus('Feed active · target ready');
    }
  } catch (error) {
    targetNameEl.textContent = 'Target unavailable';
  }
}

function beginEditing(element, selectAll = false, provisional = false) {
  delete element.dataset.cancelEdit;
  delete element.dataset.preserveEdit;
  element.dataset.originalText = element.innerText;
  if (provisional) element.dataset.provisionalNote = 'true';
  else delete element.dataset.provisionalNote;
  element.contentEditable = 'true';
  editing = true;
  element.focus();
  if (selectAll) {
    const range = document.createRange();
    range.selectNodeContents(element);
    const selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
  }
}

function characterOffset(element, node, offset) {
  if (!node || (!element.contains(node) && node !== element)) return element.innerText.length;
  const range = document.createRange();
  range.selectNodeContents(element);
  try { range.setEnd(node, offset); } catch { return element.innerText.length; }
  return range.toString().length;
}

function editingSnapshot() {
  if (!editing) return null;
  const element = document.querySelector('.note .text[contenteditable="true"]');
  const noteId = element?.closest('.note')?.dataset.noteId;
  if (!element || !noteId) return null;
  const selection = window.getSelection();
  let start = element.innerText.length;
  let end = start;
  if (selection?.rangeCount && element.contains(selection.anchorNode)
      && element.contains(selection.focusNode)) {
    const range = selection.getRangeAt(0);
    start = characterOffset(element, range.startContainer, range.startOffset);
    end = characterOffset(element, range.endContainer, range.endOffset);
  }
  element.dataset.cancelEdit = 'true';
  element.dataset.preserveEdit = 'true';
  return {
    noteId, text: element.innerText, start, end,
    original: element.dataset.originalText ?? element.innerText,
    provisional: element.dataset.provisionalNote === 'true'
  };
}

function textPoint(element, requestedOffset) {
  const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
  let remaining = Math.max(0, requestedOffset);
  let node = walker.nextNode();
  while (node) {
    if (remaining <= node.data.length) return { node, offset: remaining };
    remaining -= node.data.length;
    node = walker.nextNode();
  }
  if (!element.lastChild) element.append(document.createTextNode(''));
  const fallback = element.lastChild;
  return { node: fallback, offset: fallback.nodeType === Node.TEXT_NODE ? fallback.data.length : 0 };
}

function restoreEditing(snapshot) {
  if (!snapshot) return;
  const element = document.querySelector(
    `[data-note-id="${CSS.escape(snapshot.noteId)}"] .text`
  );
  if (!element) {
    editing = false;
    return;
  }
  element.textContent = snapshot.text;
  element.dataset.originalText = snapshot.original;
  if (snapshot.provisional) element.dataset.provisionalNote = 'true';
  element.contentEditable = 'true';
  editing = true;
  element.focus({ preventScroll: true });
  const start = textPoint(element, snapshot.start);
  const end = textPoint(element, snapshot.end);
  const range = document.createRange();
  range.setStart(start.node, start.offset);
  range.setEnd(end.node, end.offset);
  const selection = window.getSelection();
  selection.removeAllRanges();
  selection.addRange(range);
}

async function discardProvisionalNote(id, element) {
  editing = false;
  element.closest('.note')?.remove();
  try {
    await request('/api/note/delete', {
      method: 'POST', body: JSON.stringify({ id })
    });
    setStatus('New note discarded');
  } catch (error) {
    setStatus(error.message, true);
  }
}

async function saveNote(id, element, original) {
  const savedText = element.dataset.originalText ?? original;
  const text = element.innerText.trim();
  editing = false;
  if (!text) {
    if (element.dataset.provisionalNote === 'true') {
      await discardProvisionalNote(id, element);
      return;
    }
    element.textContent = savedText;
    setStatus('A note cannot be empty.', true);
    return;
  }
  if (text === savedText) return;
  try {
    await request('/api/note/update', { method: 'POST', body: JSON.stringify({ id, text }) });
    setStatus('Saved');
  } catch (error) {
    element.textContent = savedText;
    setStatus(error.message, true);
  }
}

async function moveSection(sectionId, beforeSectionId = null) {
  try {
    await request('/api/section/place', {
      method: 'POST', body: JSON.stringify({ sectionId, beforeSectionId })
    });
    await load();
    setStatus('Section moved');
  } catch (error) {
    setStatus(error.message, true);
    await load();
  }
}

async function moveNote(noteId, sectionId, beforeNoteId = null) {
  try {
    await request('/api/note/place', {
      method: 'POST',
      body: JSON.stringify({ noteId, sectionId, beforeNoteId })
    });
    await load();
    setStatus('Moved');
  } catch (error) {
    setStatus(error.message, true);
    await load();
  }
}

function noteElement(note, sectionId) {
  const row = document.createElement('div');
  row.className = `note${note.sent ? ' sent' : ''}${note.active ? ' active' : ''}${note.jumpedQueue ? ' jumped' : ''}`;
  row.dataset.noteId = note.id;

  const handle = document.createElement('button');
  handle.className = 'handle';
  handle.type = 'button';
  handle.draggable = !note.sent;
  handle.disabled = note.sent;
  handle.title = note.sent
    ? 'Submitted notes retain delivery order; requeue to move' : 'Drag paragraph';
  handle.setAttribute('aria-label', handle.title);
  handle.textContent = note.sent ? '' : '⠿';
  handle.addEventListener('dragstart', event => {
    if (note.sent) {
      event.preventDefault();
      return;
    }
    draggingId = note.id;
    row.classList.add('dragging');
    event.dataTransfer.effectAllowed = 'move';
    event.dataTransfer.setData('text/plain', note.id);
  });
  handle.addEventListener('dragend', () => {
    draggingId = null;
    row.classList.remove('dragging');
    document.querySelectorAll('.drop-before, .drop-after').forEach(el =>
      el.classList.remove('drop-before', 'drop-after'));
  });

  const text = document.createElement('div');
  text.className = 'text';
  text.contentEditable = 'false';
  text.spellcheck = true;
  text.textContent = note.text;
  row.addEventListener('click', event => {
    if (event.target.closest('.handle, .note-action') || text.isContentEditable) return;
    copyText(text.innerText);
  });
  row.addEventListener('contextmenu', event => {
    if (event.target.closest('.handle')) return;
    event.preventDefault();
    beginEditing(text);
  });
  text.addEventListener('blur', async () => {
    if (text.dataset.cancelEdit === 'true') {
      const preserve = text.dataset.preserveEdit === 'true';
      delete text.dataset.cancelEdit;
      delete text.dataset.preserveEdit;
      if (!preserve && text.dataset.provisionalNote === 'true') {
        await discardProvisionalNote(note.id, text);
        await load();
        return;
      }
      if (!preserve) {
        editing = false;
        text.contentEditable = 'false';
        setStatus('Changes discarded');
        await load();
      }
      return;
    }
    await saveNote(note.id, text, note.text);
    text.contentEditable = 'false';
    await load();
  });
  text.addEventListener('paste', event => {
    const files = imageFiles(event.clipboardData?.items);
    if (!files.length) return;
    event.preventDefault();
    uploadAttachments(note.id, files, (note.attachments || []).length);
  });
  text.addEventListener('keydown', event => {
    if (event.key === 'Escape') {
      event.preventDefault();
      event.stopPropagation();
      text.dataset.cancelEdit = 'true';
      text.textContent = text.dataset.originalText ?? note.text;
      editing = false;
      text.blur();
      return;
    }
    if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
      event.preventDefault();
      text.blur();
    }
  });

  row.addEventListener('dragover', event => {
    if (imageFiles(event.dataTransfer?.items).length) {
      event.preventDefault();
      row.classList.add('attachment-drop');
      return;
    }
    if (note.sent || !draggingId || draggingId === note.id) return;
    event.preventDefault();
    const bounds = row.getBoundingClientRect();
    const after = event.clientY >= bounds.top + bounds.height / 2;
    row.classList.toggle('drop-before', !after);
    row.classList.toggle('drop-after', after);
  });
  row.addEventListener('dragleave', () =>
    row.classList.remove('drop-before', 'drop-after', 'attachment-drop'));
  row.addEventListener('drop', event => {
    const files = imageFiles(event.dataTransfer?.files);
    if (files.length) {
      event.preventDefault();
      event.stopPropagation();
      row.classList.remove('attachment-drop');
      uploadAttachments(note.id, files, (note.attachments || []).length);
      return;
    }
    if (note.sent || !draggingId || draggingId === note.id) return;
    event.preventDefault();
    event.stopPropagation();
    const after = row.classList.contains('drop-after');
    row.classList.remove('drop-before', 'drop-after');
    let beforeNoteId = note.id;
    if (after) {
      let sibling = row.nextElementSibling;
      while (sibling && (!sibling.classList.contains('note')
             || sibling.dataset.noteId === draggingId)) sibling = sibling.nextElementSibling;
      beforeNoteId = sibling?.dataset.noteId || null;
    }
    moveNote(draggingId, sectionId, beforeNoteId);
  });

  const gutter = document.createElement('div');
  gutter.className = 'note-gutter';
  gutter.append(handle);
  const statusSlot = document.createElement('span');
  statusSlot.className = 'note-status-slot';
  if (note.deliveryError) {
    const deliveryError = document.createElement('span');
    deliveryError.className = 'delivery-error-marker';
    deliveryError.textContent = '!';
    deliveryError.title = `Last delivery failed: ${note.deliveryError}`;
    deliveryError.setAttribute('aria-label', deliveryError.title);
    statusSlot.append(deliveryError);
  } else if (note.jumpedQueue) {
    const jumpedMarker = document.createElement('span');
    jumpedMarker.className = 'jumped-marker';
    jumpedMarker.textContent = '⚡︎';
    jumpedMarker.title = 'Fed now — jumped the queue';
    jumpedMarker.setAttribute('aria-label', jumpedMarker.title);
    statusSlot.append(jumpedMarker);
  }
  gutter.append(statusSlot);
  const attachments = document.createElement('span');
  attachments.className = 'attachment-strip';
  for (const attachment of note.attachments || []) {
    const imageButton = document.createElement('button');
    imageButton.className = 'attachment-icon note-action';
    imageButton.type = 'button';
    imageButton.title = `${attachment.name} — click to preview; right-click to remove`;
    imageButton.setAttribute('aria-label', imageButton.title);
    imageButton.textContent = '󰋩';
    const preview = document.createElement('img');
    preview.className = 'attachment-preview';
    preview.src = attachment.url;
    preview.alt = '';
    imageButton.append(preview);
    imageButton.onclick = event => {
      event.stopPropagation();
      window.open(attachment.url, '_blank', 'noopener');
    };
    imageButton.oncontextmenu = async event => {
      event.preventDefault();
      event.stopPropagation();
      const confirmed = await requestConfirmation({
        title: `Remove ${attachment.name}?`,
        message: 'The managed image file will be permanently deleted.',
        confirmLabel: 'Remove image', danger: true
      });
      if (!confirmed) return;
      try {
        await request('/api/attachment/delete', {
          method: 'POST', body: JSON.stringify({ id: attachment.id })
        });
        await load();
      } catch (error) { setStatus(error.message, true); }
    };
    attachments.append(imageButton);
  }
  if (!note.sent && (note.attachments || []).length < 5) {
    const addImage = document.createElement('button');
    addImage.className = 'attachment-add-inline note-action';
    addImage.type = 'button';
    addImage.title = 'Add image';
    addImage.setAttribute('aria-label', addImage.title);
    const addImageGlyph = document.createElement('span');
    addImageGlyph.className = 'add-image-glyph';
    addImageGlyph.setAttribute('aria-hidden', 'true');
    addImageGlyph.textContent = '+';
    addImage.append(addImageGlyph);
    addImage.onclick = event => {
      event.stopPropagation();
      const picker = document.createElement('input');
      picker.type = 'file';
      picker.accept = 'image/png,image/jpeg,image/webp,image/gif';
      picker.multiple = true;
      picker.onchange = () => uploadAttachments(
        note.id, imageFiles(picker.files), (note.attachments || []).length
      );
      picker.click();
    };
    attachments.append(addImage);
  }
  const content = document.createElement('div');
  content.className = 'note-content';
  content.append(text);
  if (attachments.childElementCount) content.append(attachments);
  const activeLabel = document.createElement('span');
  activeLabel.className = 'active-note-label';
  activeLabel.textContent = 'Active';
  activeLabel.hidden = !note.active;
  content.append(activeLabel);

  const actions = document.createElement('div');
  actions.className = 'note-actions';
  const feedNow = document.createElement('button');
  feedNow.className = 'feed-now note-action';
  feedNow.type = 'button';
  feedNow.hidden = note.sent;
  feedNow.title = 'Feed now — submit immediately, even while the agent is working';
  feedNow.setAttribute('aria-label', feedNow.title);
  feedNow.textContent = '⚡︎';
  feedNow.addEventListener('click', async event => {
    event.stopPropagation();
    feedNow.disabled = true;
    try {
      await request('/api/note/feed-now', {
        method: 'POST', body: JSON.stringify({ id: note.id })
      });
      await load();
      showToast('Submitted now');
    } catch (error) {
      setStatus(error.message, true);
      feedNow.disabled = false;
    }
  });

  const sent = document.createElement('button');
  sent.className = 'sent-toggle note-action';
  sent.type = 'button';
  sent.hidden = !note.sent;
  sent.title = 'Requeue submitted note';
  sent.setAttribute('aria-label', sent.title);
  sent.textContent = '↶';
  sent.addEventListener('click', async event => {
    event.stopPropagation();
    try {
      await request('/api/note/sent', {
        method: 'POST', body: JSON.stringify({ id: note.id, sent: false })
      });
      await load();
      showToast('Requeued');
    } catch (error) { setStatus(error.message, true); }
  });

  const remove = document.createElement('button');
  remove.className = 'delete-note note-action';
  remove.type = 'button';
  remove.title = 'Delete paragraph';
  remove.setAttribute('aria-label', 'Delete paragraph');
  remove.textContent = '×';
  remove.addEventListener('click', async event => {
    event.stopPropagation();
    try {
      await request('/api/note/delete', {
        method: 'POST', body: JSON.stringify({ id: note.id })
      });
      await load();
      showToast('Note deleted');
    } catch (error) { setStatus(error.message, true); }
  });

  actions.append(feedNow, sent, remove);
  row.append(gutter, content, actions);
  return row;
}

function sectionElement(section) {
  const sectionEl = document.createElement('section');
  sectionEl.dataset.sectionId = section.id;
  sectionEl.classList.toggle('feed-current', Boolean(section.feedActive));
  sectionEl.classList.toggle('feed-queued', section.feedQueuePosition >= 0 && !section.feedActive);
  const headingRow = document.createElement('div');
  headingRow.className = 'section-heading';
  const sectionHandle = document.createElement('button');
  sectionHandle.className = 'section-handle';
  sectionHandle.type = 'button';
  sectionHandle.draggable = !section.feedCurrent && section.feedQueuePosition < 0;
  sectionHandle.title = section.feedCurrent || section.feedQueuePosition >= 0
    ? 'Pinned while part of the active feed queue' : 'Drag section';
  sectionHandle.setAttribute('aria-label', 'Drag section');
  sectionHandle.textContent = '⠿';
  sectionHandle.addEventListener('dragstart', event => {
    draggingSectionId = section.id;
    event.dataTransfer.effectAllowed = 'move';
    event.dataTransfer.setData('text/plain', section.id);
  });
  sectionHandle.addEventListener('dragend', () => {
    draggingSectionId = null;
    document.querySelectorAll('.section-drop').forEach(el => el.classList.remove('section-drop'));
  });
  const heading = document.createElement('h2');
  heading.textContent = section.name;
  const feedLabel = document.createElement('span');
  feedLabel.className = `feed-section-label${section.feedActive ? ' active' : ''}`;
  feedLabel.textContent = section.feedLabel;
  feedLabel.hidden = !section.feedCurrent && section.feedQueuePosition < 0;
  const sectionActions = document.createElement('div');
  sectionActions.className = 'section-actions';
  const queueSection = document.createElement('button');
  queueSection.className = `section-action queue-add${section.feedQueuePosition >= 0 ? ' active' : ''}`;
  queueSection.type = 'button';
  queueSection.title = section.feedCurrent ? 'This section is currently feeding'
    : (section.feedQueuePosition >= 0 ? `Queued at position ${section.feedQueuePosition + 1}` : 'Add section to feed queue');
  queueSection.disabled = section.feedCurrent || section.feedQueuePosition >= 0;
  queueSection.textContent = '+';
  queueSection.onclick = async () => {
    try {
      await request('/api/section/queue', {
        method: 'POST', body: JSON.stringify({ id: section.id })
      });
      await load();
      showToast(`${section.name} added to feed queue`);
    } catch (error) { setStatus(error.message, true); }
  };
  const feedSectionNow = document.createElement('button');
  feedSectionNow.className = `section-action feed-now${section.feedCurrent ? ' active' : ''}`;
  feedSectionNow.type = 'button';
  feedSectionNow.title = section.feedCurrent ? 'This section is currently feeding' : 'Switch the feed to this section now';
  feedSectionNow.disabled = section.feedCurrent;
  const sectionBolt = document.createElement('span');
  sectionBolt.className = 'bolt-icon';
  sectionBolt.setAttribute('aria-hidden', 'true');
  sectionBolt.textContent = '󱐋';
  feedSectionNow.append(sectionBolt);
  feedSectionNow.setAttribute('aria-label', feedSectionNow.title);
  feedSectionNow.onclick = async () => {
    try {
      await request('/api/section/feed-now', {
        method: 'POST', body: JSON.stringify({ id: section.id })
      });
      await load();
      showToast(`${section.name} is now feeding`);
    } catch (error) { setStatus(error.message, true); }
  };
  const renameSection = document.createElement('button');
  renameSection.className = 'section-action';
  renameSection.type = 'button';
  renameSection.title = 'Rename section';
  renameSection.textContent = '✎';
  renameSection.onclick = async () => {
    const name = await requestText({
      title: 'Rename section', message: 'Change this document heading.',
      value: section.name, confirmLabel: 'Rename', maxLength: 50
    });
    if (!name) return;
    try {
      await request('/api/section/rename', {
        method: 'POST', body: JSON.stringify({ id: section.id, name })
      });
      await load();
    } catch (error) { setStatus(error.message, true); }
  };
  const deleteSection = document.createElement('button');
  deleteSection.className = 'section-action delete';
  deleteSection.type = 'button';
  deleteSection.title = section.systemKind === 'unsorted'
    ? 'Fallback section cannot be deleted' : 'Delete section; move notes to Unsorted';
  deleteSection.textContent = '×';
  deleteSection.disabled = section.systemKind === 'unsorted';
  deleteSection.onclick = async () => {
    const choice = await showModal({
      title: `Delete ${section.name}?`,
      message: `${section.notes.length} messages are in this section. Move them to the fallback section, or permanently delete them with the section.`,
      confirmLabel: 'Move messages and delete',
      secondaryLabel: 'Delete messages and section'
    });
    if (choice === null) return;
    try {
      await request('/api/section/delete', {
        method: 'POST', body: JSON.stringify({
          id: section.id, notes: choice === 'secondary' ? 'discard' : 'move'
        })
      });
      await load();
    } catch (error) { setStatus(error.message, true); }
  };
  sectionActions.append(queueSection, feedSectionNow, renameSection, deleteSection);
  headingRow.append(sectionHandle, heading, feedLabel, sectionActions);
  const notes = document.createElement('div');
  notes.className = 'notes';
  notes.dataset.sectionId = section.id;

  if (section.feedCurrent) {
    const monitor = document.createElement('div');
    monitor.className = 'feed-monitor';
    const submitted = section.notes.filter(note => note.sent)
      .sort((left, right) => Number(left.deliverySequence || 0) - Number(right.deliverySequence || 0));
    const pending = section.notes.filter(note => !note.sent);
    const activeCount = submitted.filter(note => note.active).length;
    const toolbar = document.createElement('div');
    toolbar.className = 'feed-timeline-toolbar';
    toolbar.innerHTML = `<strong>Bucket timeline</strong> · ${activeCount ? `${activeCount} active · ` : ''}${submitted.length - activeCount} submitted · ${pending.length} pending`;
    const toggleSubmitted = document.createElement('button');
    toggleSubmitted.className = 'submitted-toggle';
    toggleSubmitted.type = 'button';
    toggleSubmitted.textContent = showSubmitted ? 'Hide submitted' : 'Show submitted';
    toggleSubmitted.onclick = () => {
      showSubmitted = !showSubmitted;
      localStorage.setItem('agent-feed-show-submitted', String(showSubmitted));
      timeline.classList.toggle('hide-submitted', !showSubmitted);
      toggleSubmitted.textContent = showSubmitted ? 'Hide submitted' : 'Show submitted';
    };
    toolbar.append(toggleSubmitted);

    const timeline = document.createElement('div');
    timeline.className = 'feed-timeline';
    timeline.classList.toggle('hide-submitted', !showSubmitted);
    timeline.dataset.sectionId = section.id;
    submitted.forEach(note => timeline.append(noteElement(note, section.id)));
    const boundary = document.createElement('div');
    boundary.className = 'queue-boundary';
    boundary.textContent = pending.length
      ? `Next up · ${pending.length} pending · first ${Math.min(3, pending.length)} highlighted`
      : 'Queue complete';
    timeline.append(boundary);
    if (pending.length) {
      pending.forEach((note, index) => {
        const noteEl = noteElement(note, section.id);
        if (index < 3) noteEl.classList.add('imminent');
        timeline.append(noteEl);
      });
    } else {
      const empty = document.createElement('div');
      empty.className = 'empty';
      empty.textContent = 'No pending notes.';
      timeline.append(empty);
    }
    monitor.append(toolbar, timeline);
    notes.append(monitor);
  } else if (!section.notes.length) {
    const empty = document.createElement('div');
    empty.className = 'empty';
    empty.textContent = 'No notes yet.';
    notes.append(empty);
  } else {
    section.notes.forEach(note => notes.append(noteElement(note, section.id)));
  }

  sectionEl.addEventListener('dragover', event => {
    if (!draggingSectionId) return;
    event.preventDefault();
    sectionEl.classList.add('section-drop');
  });
  sectionEl.addEventListener('dragleave', event => {
    if (!sectionEl.contains(event.relatedTarget)) sectionEl.classList.remove('section-drop');
  });
  sectionEl.addEventListener('drop', event => {
    if (!draggingSectionId) return;
    event.preventDefault();
    event.stopPropagation();
    const after = event.clientY >= sectionEl.getBoundingClientRect().top + sectionEl.offsetHeight / 2;
    const next = after ? sectionEl.nextElementSibling : sectionEl;
    moveSection(draggingSectionId, next?.dataset.sectionId || null);
  });

  notes.addEventListener('dragover', event => {
    if (!draggingId) return;
    event.preventDefault();
  });
  notes.addEventListener('drop', event => {
    if (!draggingId || event.target.closest('.note')) return;
    event.preventDefault();
    moveNote(draggingId, section.id, null);
  });

  const add = document.createElement('button');
  add.className = 'add';
  add.type = 'button';
  add.textContent = '+ Add Note';
  add.addEventListener('click', async () => {
    try {
      const result = await request('/api/note/create', {
        method: 'POST',
        body: JSON.stringify({ sectionId: section.id, text: 'New note' })
      });
      await load();
      const newText = document.querySelector(`[data-note-id="${CSS.escape(result.id)}"] .text`);
      if (newText) {
        newText.textContent = '';
        beginEditing(newText, false, true);
      }
    } catch (error) { setStatus(error.message, true); }
  });

  sectionEl.append(headingRow, notes, add);
  return sectionEl;
}

function addSectionControl() {
  const button = document.createElement('button');
  button.className = 'add';
  button.type = 'button';
  button.textContent = '+ Add section';
  button.onclick = async () => {
    const name = await requestText({
      title: 'Create section', message: 'Add a new heading to this bucket.',
      confirmLabel: 'Create', maxLength: 50
    });
    if (!name) return;
    try {
      await request('/api/section/create', {
        method: 'POST', body: JSON.stringify({ bucketId, name })
      });
      await load();
    } catch (error) { setStatus(error.message, true); }
  };
  return button;
}

function viewerFeedSection(data) {
  const sections = data.sections || [];
  const persisted = data.feedBucketId === data.id
    ? sections.find(section => section.id === data.feedSectionId) : null;
  if (persisted?.notes?.some(note => !note.sent)) return persisted.id;
  return sections.find(section => section.notes?.some(note => !note.sent))?.id
    || persisted?.id || sections[0]?.id || '';
}

feedToggleEl.addEventListener('click', async () => {
  if (!currentDocument) return;
  const action = currentDocument.feedEnabled ? 'stop' : 'start';
  const sectionId = action === 'start' ? viewerFeedSection(currentDocument) : '';
  if (action === 'start' && !sectionId) {
    setStatus('This bucket has no section to feed.', true);
    return;
  }
  feedToggleEl.disabled = true;
  try {
    await request('/api/feed', {
      method: 'POST',
      body: JSON.stringify({ action, bucketId: currentDocument.id, sectionId })
    });
    await load();
    showToast(action === 'start' ? 'Feed started' : 'Feed stopped');
  } catch (error) {
    setStatus(error.message, true);
  } finally {
    feedToggleEl.disabled = false;
  }
});

function renderFeedQueue(data) {
  const children = [];
  if (data.feedEnabled) {
    const current = document.createElement('span');
    current.className = 'feed-queue-chip current';
    current.textContent = data.feedBucketId === data.id
      ? `Now · ${data.feedSectionName}`
      : `Now · ${data.feedBucketName} / ${data.feedSectionName}`;
    current.title = `${data.feedBucketName} / ${data.feedSectionName}`;
    children.push(current);
  }
  const queue = data.feedQueue || [];
  queue.forEach((item, index) => {
    const chip = document.createElement('span');
    chip.className = 'feed-queue-chip';
    const position = document.createElement('span');
    position.className = 'feed-queue-index';
    position.textContent = String(index + 1);
    const label = document.createElement('span');
    label.textContent = item.bucketId === data.id
      ? item.sectionName : `${item.bucketName} / ${item.sectionName}`;
    label.title = `${item.bucketName} / ${item.sectionName}`;
    const remove = document.createElement('button');
    remove.className = 'feed-queue-remove';
    remove.type = 'button';
    remove.textContent = '×';
    remove.title = `Remove ${item.sectionName} from feed queue`;
    remove.onclick = async () => {
      try {
        await request('/api/section/dequeue', {
          method: 'POST', body: JSON.stringify({ id: item.sectionId })
        });
        await load();
      } catch (error) { setStatus(error.message, true); }
    };
    chip.append(position, label, remove);
    children.push(chip);
  });
  if (!queue.length) {
    const empty = document.createElement('span');
    empty.className = 'feed-queue-empty';
    empty.textContent = 'No waiting sections';
    children.push(empty);
  }
  feedQueueEl.replaceChildren(...children);
}

async function load() {
  if (isModalOpen() || draggingId || draggingSectionId) return;
  try {
    const data = await request(`/api/bucket?id=${encodeURIComponent(bucketId)}`);
    const draft = editingSnapshot();
    currentDocument = data;
    activeNoteIds = data.activeNoteIds || activeNoteIds;
    feedToggleEl.textContent = data.feedEnabled ? '■ Stop' : '▶ Start';
    feedToggleEl.classList.toggle('active', Boolean(data.feedEnabled));
    feedToggleEl.title = data.feedEnabled
      ? 'Stop delivery after the current submission'
      : `Start delivery from ${data.name}`;
    titleEl.textContent = data.name;
    document.title = `${data.name} — Feed the Flock`;
    bucketStatsTextEl.textContent = `${data.submittedCount}/${data.noteCount} submitted, ${data.queuedCount} queued`;
    const activeChip = bucketTrainEl.querySelector(
      `[data-bucket-id="${CSS.escape(bucketId)}"]`
    );
    if (activeChip) activeChip.textContent = data.name;
    renderFeedQueue(data);
    documentEl.replaceChildren(addSectionControl(), ...data.sections.map(sectionElement));
    updateActiveNotes();
    restoreEditing(draft);
    setStatus('Live');
  } catch (error) {
    setStatus(error.message, true);
  }
}

document.addEventListener('keydown', event => {
  if (event.defaultPrevented || event.ctrlKey || event.altKey || event.metaKey
      || editing || isModalOpen()) return;
  const active = document.activeElement;
  if (active?.matches('input, textarea, select, [contenteditable="true"]')) return;
  if (event.key === 'i' || event.key === 'I') {
    event.preventDefault();
    importBucket();
  } else if (event.key === 'x' || event.key === 'X') {
    event.preventDefault();
    exportBucket();
  }
});

loadTheme();
loadBuckets().then(load);
loadTargets();
setInterval(loadTheme, 5000);
setInterval(loadTargets, 5000);
const events = new EventSource(`/api/events?bucket=${encodeURIComponent(bucketId)}`);
events.addEventListener('change', load);
events.onerror = () => setStatus('Reconnecting live view…');
setInterval(load, 30000);
