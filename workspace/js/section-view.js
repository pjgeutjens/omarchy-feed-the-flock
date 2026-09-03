import { request } from './api.js';
import { requestText, showModal } from './modal.js';

export function createSectionRenderer({
  dragState,
  getBucketId,
  load,
  moveNote,
  moveSection,
  navigation,
  noteEditor,
  noteElement,
  setStatus,
  showToast,
}) {
  let showSubmitted = localStorage.getItem('agent-feed-show-submitted') !== 'false';

  function sectionElement(section) {
    const sectionEl = document.createElement('section');
    sectionEl.dataset.sectionId = section.id;
    sectionEl.tabIndex = navigation.isSectionSelected(section.id) ? 0 : -1;
    if (navigation.isSectionSelected(section.id)) sectionEl.classList.add('selected');
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
      dragState.sectionId = section.id;
      event.dataTransfer.effectAllowed = 'move';
      event.dataTransfer.setData('text/plain', section.id);
    });
    sectionHandle.addEventListener('dragend', () => {
      dragState.sectionId = null;
      document.querySelectorAll('.section-drop').forEach(element =>
        element.classList.remove('section-drop'));
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
    queueSection.dataset.viewerAction = 'queue';
    queueSection.title = section.feedCurrent ? 'This section is currently feeding'
      : (section.feedQueuePosition >= 0
        ? `Queued at position ${section.feedQueuePosition + 1}`
        : 'Add section to feed queue (Q)');
    queueSection.setAttribute('aria-keyshortcuts', 'Q');
    queueSection.disabled = section.feedCurrent || section.feedQueuePosition >= 0;
    queueSection.textContent = '+';
    queueSection.onclick = async () => {
      try {
        await request('/api/section/queue', {
          method: 'POST', body: JSON.stringify({ id: section.id })
        });
        await load();
        showToast(`${section.name} added to feed queue`);
      } catch (error) {
        setStatus(error.message, true);
      }
    };

    const feedSectionNow = document.createElement('button');
    feedSectionNow.className = `section-action feed-now${section.feedCurrent ? ' active' : ''}`;
    feedSectionNow.type = 'button';
    feedSectionNow.dataset.viewerAction = 'feed';
    feedSectionNow.title = section.feedCurrent
      ? 'This section is currently feeding' : 'Switch the feed to this section now (F)';
    feedSectionNow.setAttribute('aria-keyshortcuts', 'F');
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
      } catch (error) {
        setStatus(error.message, true);
      }
    };

    const renameSection = document.createElement('button');
    renameSection.className = 'section-action';
    renameSection.type = 'button';
    renameSection.dataset.viewerAction = 'rename';
    renameSection.title = 'Rename section (R)';
    renameSection.setAttribute('aria-keyshortcuts', 'R');
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
      } catch (error) {
        setStatus(error.message, true);
      }
    };

    const clearSection = document.createElement('button');
    clearSection.className = 'section-action clear';
    clearSection.type = 'button';
    clearSection.dataset.viewerAction = 'clear';
    clearSection.title = section.notes.length
      ? 'Clear all notes from this section (C)' : 'Section is already empty';
    clearSection.setAttribute('aria-keyshortcuts', 'C');
    clearSection.textContent = '⌫';
    clearSection.disabled = section.notes.length === 0;
    clearSection.setAttribute('aria-label', clearSection.title);
    clearSection.onclick = async () => {
      let notesMode = 'discard';
      if (section.systemKind !== 'unsorted') {
        const choice = await showModal({
          title: `Clear ${section.name}`,
          message: `${section.notes.length} notes`,
          confirmLabel: 'Move to Unsorted',
          secondaryLabel: 'Delete all notes'
        });
        if (choice === null) return;
        notesMode = choice === 'secondary' ? 'discard' : 'move';
      }
      try {
        const result = await request('/api/section/clear', {
          method: 'POST', body: JSON.stringify({ id: section.id, notes: notesMode })
        });
        await load();
        showToast(notesMode === 'move'
          ? `Moved ${result.movedNotes} notes to Unsorted`
          : `Deleted ${result.deletedNotes} notes`);
      } catch (error) {
        setStatus(error.message, true);
      }
    };
    sectionActions.append(queueSection, feedSectionNow, renameSection, clearSection);

    if (section.systemKind !== 'unsorted') {
      const deleteSection = document.createElement('button');
      deleteSection.className = 'section-action delete';
      deleteSection.type = 'button';
      deleteSection.dataset.viewerAction = 'delete';
      deleteSection.title = 'Delete section (Delete); move notes to Unsorted';
      deleteSection.setAttribute('aria-keyshortcuts', 'Delete');
      deleteSection.textContent = '×';
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
        } catch (error) {
          setStatus(error.message, true);
        }
      };
      sectionActions.append(deleteSection);
    }

    headingRow.append(sectionHandle, heading, feedLabel, sectionActions);
    headingRow.addEventListener('click', event => {
      if (!event.target.closest('button')) navigation.selectSection(sectionEl, false);
    });
    const notes = document.createElement('div');
    notes.className = 'notes';
    notes.dataset.sectionId = section.id;

    if (section.feedCurrent) {
      const monitor = document.createElement('div');
      monitor.className = 'feed-monitor';
      const submitted = section.notes.filter(note => note.sent)
        .sort((left, right) => Number(left.deliverySequence || 0)
          - Number(right.deliverySequence || 0));
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
      if (!dragState.sectionId) return;
      event.preventDefault();
      sectionEl.classList.add('section-drop');
    });
    sectionEl.addEventListener('dragleave', event => {
      if (!sectionEl.contains(event.relatedTarget)) sectionEl.classList.remove('section-drop');
    });
    sectionEl.addEventListener('drop', event => {
      if (!dragState.sectionId) return;
      event.preventDefault();
      event.stopPropagation();
      const after = event.clientY >= sectionEl.getBoundingClientRect().top
        + sectionEl.offsetHeight / 2;
      const next = after ? sectionEl.nextElementSibling : sectionEl;
      moveSection(dragState.sectionId, next?.dataset.sectionId || null);
    });

    notes.addEventListener('dragover', event => {
      if (!dragState.noteId) return;
      event.preventDefault();
    });
    notes.addEventListener('drop', event => {
      if (!dragState.noteId || event.target.closest('.note')) return;
      event.preventDefault();
      moveNote(dragState.noteId, section.id, null);
    });

    const add = document.createElement('button');
    add.className = 'add';
    add.type = 'button';
    add.dataset.viewerAction = 'add';
    add.title = 'Add note (A)';
    add.setAttribute('aria-keyshortcuts', 'A');
    add.textContent = '+ Add Note';
    add.addEventListener('click', async () => {
      try {
        const result = await request('/api/note/create', {
          method: 'POST',
          body: JSON.stringify({ sectionId: section.id, text: 'New note' })
        });
        await load();
        const newText = document.querySelector(
          `[data-note-id="${CSS.escape(result.id)}"] .text`
        );
        if (newText) {
          newText.textContent = '';
          noteEditor.begin(newText, false, true);
        }
      } catch (error) {
        setStatus(error.message, true);
      }
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
          method: 'POST', body: JSON.stringify({ bucketId: getBucketId(), name })
        });
        await load();
      } catch (error) {
        setStatus(error.message, true);
      }
    };
    return button;
  }

  return { addSectionControl, sectionElement };
}
