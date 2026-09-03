import { isModalOpen, showModal } from './modal.js';
import { isRoutingOpen } from './routing.js';

export function createViewerNavigation({
  copyText,
  exportBucket,
  importBucket,
  noteEditor,
  search,
}) {
  let selectedNoteId = '';
  let selectedSectionId = '';
  let searchMatches = [];
  let searchIndex = -1;
  const { container, input, count, closeButton } = search;

  function selectNote(row, scroll = true) {
    document.querySelectorAll('section.selected').forEach(section => {
      section.classList.remove('selected');
      section.tabIndex = -1;
    });
    selectedSectionId = '';
    document.querySelectorAll('.note.selected').forEach(note => {
      note.classList.remove('selected');
      note.tabIndex = -1;
    });
    selectedNoteId = row.dataset.noteId || '';
    row.classList.add('selected');
    row.tabIndex = 0;
    row.focus({ preventScroll: true });
    if (scroll) row.scrollIntoView({ block: 'nearest' });
  }

  function navigateNotes(direction) {
    const notes = [...document.querySelectorAll('.note')].filter(note => note.checkVisibility());
    if (!notes.length) return false;
    const selected = document.querySelector('.note.selected');
    const current = selected ? notes.indexOf(selected) : -1;
    const next = current < 0
      ? direction > 0 ? 0 : notes.length - 1
      : Math.max(0, Math.min(notes.length - 1, current + direction));
    selectNote(notes[next]);
    return true;
  }

  function selectSection(section, scroll = true) {
    document.querySelectorAll('.note.selected').forEach(note => {
      note.classList.remove('selected');
      note.tabIndex = -1;
    });
    selectedNoteId = '';
    document.querySelectorAll('section.selected').forEach(candidate => {
      candidate.classList.remove('selected');
      candidate.tabIndex = -1;
    });
    selectedSectionId = section.dataset.sectionId || '';
    section.classList.add('selected');
    section.tabIndex = 0;
    section.focus({ preventScroll: true });
    if (scroll) section.querySelector('.section-heading')?.scrollIntoView({ block: 'nearest' });
  }

  function navigateSections(direction) {
    const sections = [...document.querySelectorAll('main section')]
      .filter(section => section.checkVisibility());
    if (!sections.length) return false;
    const selected = document.querySelector('section.selected');
    const current = selected ? sections.indexOf(selected) : -1;
    const next = current < 0
      ? direction > 0 ? 0 : sections.length - 1
      : Math.max(0, Math.min(sections.length - 1, current + direction));
    selectSection(sections[next]);
    return true;
  }

  function clickSelectedAction(scope, action) {
    const button = scope?.querySelector(`[data-viewer-action="${action}"]`);
    if (!button || button.disabled || button.hidden || !button.checkVisibility()) return false;
    button.click();
    return true;
  }

  function triggerSelectedAction(key) {
    const note = document.querySelector('.note.selected');
    if (note) {
      if (key === 'enter') {
        const text = note.querySelector('.text');
        if (!text) return false;
        noteEditor.begin(text);
        return true;
      }
      if (key === 'y') {
        const text = note.querySelector('.text');
        if (!text) return false;
        copyText(text.innerText);
        return true;
      }
      const action = { a: 'add', f: 'feed', r: 'requeue', delete: 'delete' }[key];
      return action ? clickSelectedAction(note, action) : false;
    }

    const section = document.querySelector('section.selected');
    if (!section) return false;
    const action = {
      a: 'add', q: 'queue', f: 'feed', r: 'rename', c: 'clear', delete: 'delete'
    }[key];
    return action ? clickSelectedAction(section, action) : false;
  }

  function clearSearchMatches() {
    document.querySelectorAll('.search-match, .search-current').forEach(element => {
      element.classList.remove('search-match', 'search-current');
    });
    searchMatches = [];
    searchIndex = -1;
    count.textContent = '0/0';
  }

  function focusSearchMatch(index) {
    if (!searchMatches.length) return;
    document.querySelector('.search-current')?.classList.remove('search-current');
    searchIndex = (index + searchMatches.length) % searchMatches.length;
    const match = searchMatches[searchIndex];
    match.classList.add('search-current');
    const note = match.closest('.note');
    if (note) selectNote(note, false);
    else {
      const section = match.closest('section');
      if (section) selectSection(section, false);
    }
    match.scrollIntoView({ block: 'center' });
    count.textContent = `${searchIndex + 1}/${searchMatches.length}`;
  }

  function updateSearchMatches(selectFirst = true) {
    clearSearchMatches();
    const query = input.value.trim().toLocaleLowerCase();
    if (!query) return;
    searchMatches = [...document.querySelectorAll('section h2, .note .text')].filter(element =>
      element.checkVisibility() && element.textContent.toLocaleLowerCase().includes(query)
    );
    searchMatches.forEach(element => element.classList.add('search-match'));
    count.textContent = searchMatches.length ? `0/${searchMatches.length}` : '0/0';
    if (selectFirst && searchMatches.length) focusSearchMatch(0);
  }

  function openSearch() {
    container.hidden = false;
    input.focus();
    input.select();
    updateSearchMatches(false);
  }

  function closeSearch() {
    container.hidden = true;
    input.value = '';
    clearSearchMatches();
    document.querySelector('.note.selected, section.selected')?.focus({ preventScroll: true });
  }

  function showKeyboardReference() {
    showModal({
      title: 'Keyboard shortcuts',
      message: 'SELECT\nJ / K  Previous / next note\nH / L  Previous / next section\n\nSELECTED NOTE\nA  Add image\nF  Feed now\nR  Requeue submitted note\nDelete  Delete note\nEnter  Edit note\nY  Copy note\n\nSELECTED SECTION\nA  Add note\nQ  Add to feed queue\nF  Feed now\nR  Rename\nC  Clear\nDelete  Delete section\n\nGLOBAL\n/  Search headings and notes\nI  Import Markdown bucket\nX  Export current bucket\n?  Open this reference\nEsc  Close search or dialog',
      confirmLabel: 'Close'
    });
  }

  function eventTargetsTextEntry(event) {
    return event.composedPath().some(target =>
      target?.matches?.('input, textarea, select, [contenteditable="true"]')
    );
  }

  function recoverSearchFocus(event) {
    if (event.key === 'Escape') {
      closeSearch();
      return true;
    }
    if (event.key.length !== 1) return false;
    input.focus();
    const start = input.selectionStart ?? input.value.length;
    const end = input.selectionEnd ?? start;
    input.setRangeText(event.key, start, end, 'end');
    updateSearchMatches(true);
    return true;
  }

  input.addEventListener('input', () => updateSearchMatches(true));
  input.addEventListener('keydown', event => {
    if (event.key === 'Escape') {
      event.preventDefault();
      closeSearch();
    } else if (event.key === 'Enter') {
      event.preventDefault();
      if (!searchMatches.length) updateSearchMatches(false);
      const next = searchIndex < 0 ? (event.shiftKey ? -1 : 0)
        : searchIndex + (event.shiftKey ? -1 : 1);
      focusSearchMatch(next);
    }
  });
  closeButton.addEventListener('click', closeSearch);

  window.addEventListener('keydown', event => {
    if (event.ctrlKey || event.altKey || event.metaKey || noteEditor.isEditing()
        || isModalOpen() || isRoutingOpen()) return;
    if (!container.hidden) {
      if (eventTargetsTextEntry(event)) return;
      if (!recoverSearchFocus(event)) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      return;
    }
    if (eventTargetsTextEntry(event)) return;
    const key = event.key.toLowerCase();
    let handled = false;
    if (['j', 'k'].includes(key)) handled = navigateNotes(key === 'j' ? 1 : -1);
    else if (['h', 'l'].includes(key)) handled = navigateSections(key === 'l' ? 1 : -1);
    else if (event.key === '/') {
      openSearch();
      handled = true;
    } else if (event.key === '?') {
      showKeyboardReference();
      handled = true;
    } else handled = triggerSelectedAction(key);
    if (!handled) return;
    event.preventDefault();
    event.stopImmediatePropagation();
  }, true);

  document.addEventListener('keydown', event => {
    if (event.defaultPrevented || event.ctrlKey || event.altKey || event.metaKey
        || noteEditor.isEditing() || isModalOpen() || isRoutingOpen()) return;
    if (!container.hidden || eventTargetsTextEntry(event)) return;
    if (event.key === 'i' || event.key === 'I') {
      event.preventDefault();
      importBucket();
    } else if (event.key === 'x' || event.key === 'X') {
      event.preventDefault();
      exportBucket();
    }
  });

  return {
    isNoteSelected: noteId => noteId === selectedNoteId,
    isSearchOpen: () => !container.hidden,
    isSectionSelected: sectionId => sectionId === selectedSectionId,
    refreshSearch: () => {
      if (!container.hidden) updateSearchMatches(false);
    },
    selectNote,
    selectSection,
  };
}
