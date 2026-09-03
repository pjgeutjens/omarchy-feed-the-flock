import { request } from './api.js';
import { imageFiles } from './attachments.js';
import { requestConfirmation } from './modal.js';

export function createNoteRenderer({
  copyText,
  dragState,
  load,
  moveNote,
  navigation,
  noteEditor,
  setStatus,
  showToast,
  uploadAttachments,
}) {
  return function noteElement(note, sectionId) {
    const row = document.createElement('div');
    row.className = `note${note.sent ? ' sent' : ''}${note.active ? ' active' : ''}${note.jumpedQueue ? ' jumped' : ''}`;
    row.dataset.noteId = note.id;
    row.tabIndex = navigation.isNoteSelected(note.id) ? 0 : -1;
    if (navigation.isNoteSelected(note.id)) row.classList.add('selected');

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
      dragState.noteId = note.id;
      row.classList.add('dragging');
      event.dataTransfer.effectAllowed = 'move';
      event.dataTransfer.setData('text/plain', note.id);
    });
    handle.addEventListener('dragend', () => {
      dragState.noteId = null;
      row.classList.remove('dragging');
      document.querySelectorAll('.drop-before, .drop-after').forEach(element =>
        element.classList.remove('drop-before', 'drop-after'));
    });

    const text = document.createElement('div');
    text.className = 'text';
    text.contentEditable = 'false';
    text.spellcheck = true;
    text.textContent = note.text;
    row.addEventListener('click', event => {
      if (event.target.closest('.handle, .note-action') || text.isContentEditable) return;
      navigation.selectNote(row, false);
      copyText(text.innerText);
    });
    row.addEventListener('contextmenu', event => {
      if (event.target.closest('.handle')) return;
      event.preventDefault();
      navigation.selectNote(row, false);
      noteEditor.begin(text);
    });
    text.addEventListener('blur', async () => {
      if (text.dataset.cancelEdit === 'true') {
        const preserve = text.dataset.preserveEdit === 'true';
        delete text.dataset.cancelEdit;
        delete text.dataset.preserveEdit;
        if (!preserve && text.dataset.provisionalNote === 'true') {
          await noteEditor.discardProvisional(note.id, text);
          await load();
          return;
        }
        if (!preserve) {
          noteEditor.stop();
          text.contentEditable = 'false';
          setStatus('Changes discarded');
          await load();
        }
        return;
      }
      await noteEditor.save(note.id, text, note.text);
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
        noteEditor.stop();
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
      if (note.sent || !dragState.noteId || dragState.noteId === note.id) return;
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
      if (note.sent || !dragState.noteId || dragState.noteId === note.id) return;
      event.preventDefault();
      event.stopPropagation();
      const after = row.classList.contains('drop-after');
      row.classList.remove('drop-before', 'drop-after');
      let beforeNoteId = note.id;
      if (after) {
        let sibling = row.nextElementSibling;
        while (sibling && (!sibling.classList.contains('note')
               || sibling.dataset.noteId === dragState.noteId)) sibling = sibling.nextElementSibling;
        beforeNoteId = sibling?.dataset.noteId || null;
      }
      moveNote(dragState.noteId, sectionId, beforeNoteId);
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
        } catch (error) {
          setStatus(error.message, true);
        }
      };
      attachments.append(imageButton);
    }
    if (!note.sent && (note.attachments || []).length < 5) {
      const addImage = document.createElement('button');
      addImage.className = 'attachment-add-inline note-action';
      addImage.type = 'button';
      addImage.dataset.viewerAction = 'add';
      addImage.title = 'Add image (A)';
      addImage.setAttribute('aria-keyshortcuts', 'A');
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
    feedNow.dataset.viewerAction = 'feed';
    feedNow.hidden = note.sent;
    feedNow.title = 'Feed now (F) — submit immediately, even while the agent is working';
    feedNow.setAttribute('aria-keyshortcuts', 'F');
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
    sent.dataset.viewerAction = 'requeue';
    sent.hidden = !note.sent;
    sent.title = 'Requeue submitted note (R)';
    sent.setAttribute('aria-keyshortcuts', 'R');
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
      } catch (error) {
        setStatus(error.message, true);
      }
    });

    const remove = document.createElement('button');
    remove.className = 'delete-note note-action';
    remove.type = 'button';
    remove.dataset.viewerAction = 'delete';
    remove.title = 'Delete paragraph (Delete)';
    remove.setAttribute('aria-label', remove.title);
    remove.setAttribute('aria-keyshortcuts', 'Delete');
    remove.textContent = '×';
    remove.addEventListener('click', async event => {
      event.stopPropagation();
      try {
        await request('/api/note/delete', {
          method: 'POST', body: JSON.stringify({ id: note.id })
        });
        await load();
        showToast('Note deleted');
      } catch (error) {
        setStatus(error.message, true);
      }
    });

    actions.append(feedNow, sent, remove);
    row.append(gutter, content, actions);
    return row;
  };
}
