import { request } from './api.js';
import { createAttachmentService } from './attachments.js';
import { isModalOpen, requestConfirmation, requestText } from './modal.js';
import { createNoteEditor } from './note-editor.js';
import { createNoteRenderer } from './note-view.js';
import { isRoutingOpen, openRouting } from './routing.js';
import { createSectionRenderer } from './section-view.js';
import { loadTheme } from './theme.js';
import { createViewerNavigation } from './viewer-navigation.js';

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
const resetAllEl = document.querySelector('#reset-all');
const viewerSearchEl = document.querySelector('#viewer-search');
const viewerSearchInputEl = document.querySelector('#viewer-search-input');
const viewerSearchCountEl = document.querySelector('#viewer-search-count');
const viewerSearchCloseEl = document.querySelector('#viewer-search-close');
let selectedTargetId = '';
let activeNoteIds = [];
let currentDocument = null;
const dragState = { noteId: null, sectionId: null };
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

resetAllEl.onclick = async () => {
  resetAllEl.disabled = true;
  try {
    const result = await request('/api/notes/reset-all', {
      method: 'POST', body: '{}'
    });
    await loadBuckets(bucketId);
    await load();
    showToast(result.resetCount
      ? `${result.resetCount} notes reset to unsent`
      : 'All notes are already unsent');
  } catch (error) {
    setStatus(error.message, true);
  } finally {
    resetAllEl.disabled = false;
  }
};

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

const { uploadAttachments } = createAttachmentService({ load, setStatus, showToast });

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
    selectedTargetId = data.selectedTargetId || '';
    activeNoteIds = data.activeNoteIds || [];
    updateActiveNotes();
    const selected = (data.targets || []).find(target => target.id === selectedTargetId);
    targetNameEl.textContent = data.selectedTargetLabel || selected?.label || 'Disconnected target';
    targetNameEl.title = selected
      ? `${selected.label} — ${selected.status} · Click to configure routing`
      : 'Click to configure delivery routing';
    if (currentDocument?.feedEnabled && selected && !selected.available) {
      setStatus(`Feed waiting · ${selected.label} is ${selected.status}`);
    } else if (currentDocument?.feedEnabled && selected?.available) {
      setStatus('Feed active · target ready');
    }
  } catch (error) {
    targetNameEl.textContent = 'Target unavailable';
  }
}

targetNameEl.addEventListener('click', () => openRouting({
  onApplied: async () => {
    await loadTargets();
    await load();
    showToast('Routing updated');
  }
}));

const noteEditor = createNoteEditor({ setStatus });
const navigation = createViewerNavigation({
  copyText,
  exportBucket,
  importBucket,
  noteEditor,
  search: {
    container: viewerSearchEl,
    input: viewerSearchInputEl,
    count: viewerSearchCountEl,
    closeButton: viewerSearchCloseEl,
  },
});
const noteElement = createNoteRenderer({
  copyText,
  dragState,
  load,
  moveNote,
  navigation,
  noteEditor,
  setStatus,
  showToast,
  uploadAttachments,
});
const { addSectionControl, sectionElement } = createSectionRenderer({
  dragState,
  getBucketId: () => bucketId,
  load,
  moveNote,
  moveSection,
  navigation,
  noteEditor,
  noteElement,
  setStatus,
  showToast,
});

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
  if (isModalOpen() || isRoutingOpen() || dragState.noteId || dragState.sectionId) return;
  try {
    const data = await request(`/api/bucket?id=${encodeURIComponent(bucketId)}`);
    const draft = noteEditor.snapshot();
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
    noteEditor.restore(draft);
    navigation.refreshSearch();
    setStatus('Live');
  } catch (error) {
    setStatus(error.message, true);
  }
}

loadTheme();
loadBuckets().then(load);
loadTargets();
setInterval(loadTheme, 5000);
setInterval(loadTargets, 5000);
const events = new EventSource(`/api/events?bucket=${encodeURIComponent(bucketId)}`);
events.addEventListener('change', load);
events.onerror = () => setStatus('Reconnecting live view…');
setInterval(load, 30000);
