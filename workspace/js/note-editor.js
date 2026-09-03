import { request } from './api.js';

export function createNoteEditor({ setStatus }) {
  let editing = false;

  function begin(element, selectAll = false, provisional = false) {
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
    try {
      range.setEnd(node, offset);
    } catch {
      return element.innerText.length;
    }
    return range.toString().length;
  }

  function snapshot() {
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
    return {
      node: fallback,
      offset: fallback.nodeType === Node.TEXT_NODE ? fallback.data.length : 0
    };
  }

  function restore(value) {
    if (!value) return;
    const element = document.querySelector(
      `[data-note-id="${CSS.escape(value.noteId)}"] .text`
    );
    if (!element) {
      editing = false;
      return;
    }
    element.textContent = value.text;
    element.dataset.originalText = value.original;
    if (value.provisional) element.dataset.provisionalNote = 'true';
    element.contentEditable = 'true';
    editing = true;
    element.focus({ preventScroll: true });
    const start = textPoint(element, value.start);
    const end = textPoint(element, value.end);
    const range = document.createRange();
    range.setStart(start.node, start.offset);
    range.setEnd(end.node, end.offset);
    const selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
  }

  async function discardProvisional(noteId, element) {
    editing = false;
    element.closest('.note')?.remove();
    try {
      await request('/api/note/delete', {
        method: 'POST', body: JSON.stringify({ id: noteId })
      });
      setStatus('New note discarded');
    } catch (error) {
      setStatus(error.message, true);
    }
  }

  async function save(noteId, element, original) {
    const savedText = element.dataset.originalText ?? original;
    const text = element.innerText.trim();
    editing = false;
    if (!text) {
      if (element.dataset.provisionalNote === 'true') {
        await discardProvisional(noteId, element);
        return;
      }
      element.textContent = savedText;
      setStatus('A note cannot be empty.', true);
      return;
    }
    if (text === savedText) return;
    try {
      await request('/api/note/update', {
        method: 'POST', body: JSON.stringify({ id: noteId, text })
      });
      setStatus('Saved');
    } catch (error) {
      element.textContent = savedText;
      setStatus(error.message, true);
    }
  }

  return {
    begin,
    discardProvisional,
    isEditing: () => editing,
    restore,
    save,
    snapshot,
    stop: () => { editing = false; }
  };
}
