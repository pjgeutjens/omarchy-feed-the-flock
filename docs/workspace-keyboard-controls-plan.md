# Vim-like workspace keyboard controls

## Summary

Add a dependency-free keyboard command mode to the HTML workspace. It follows the Omarchy panel where the panel already has a shortcut. Keyboard navigation selects a bucket, section, and note without entering edit mode. A visible selection ring and scrolling show the current target. No backend or API change is needed.

## Key changes

- Store the selection as bucket, section, and note IDs in `workspace/js/app.js`. Restore it after SSE reloads. If an item no longer exists, select the nearest remaining note, section, or bucket.
- Ignore workspace commands while a modal, native input, file picker, or inline editor has focus. Keep the editor keys unchanged: `Enter` saves, `Shift+Enter` inserts a line, and `Esc` restores the saved value.
- Use panel-consistent navigation:
  - `H` and `L`: previous and next bucket.
  - `Tab` and `Shift+Tab`: next and previous section.
  - `J` and `K`: next and previous visible note in the selected section.
  - `Home` and `End`: first and last note in the selected section.
- Add selected-note actions:
  - `Y`: copy note text.
  - `E`: edit the selected note.
  - `A`: add a note to the selected section and edit it.
  - `X`: delete the selected note through the existing confirmation dialog.
  - `U` and `D`: move a pending selected note up or down within its section. Submitted notes cannot move.
  - `R`: requeue a selected submitted note.
- Keep section and feed commands consistent with the panel:
  - `F`: start or stop the feed.
  - `G`: queue the selected section.
  - `Shift+G`: feed the selected section immediately.
  - `B` and `Shift+B`: create and rename a bucket.
  - `S` and `Shift+S`: create and rename a section.
  - `[` and `]`: move the selected section left or right.
  - `{` and `}`: move the current bucket left or right.
  - `Shift+X` and `Ctrl+X`: keep section and bucket deletion, with the existing confirmation flow.
- Add a `?` help overlay in the workspace. It lists the keymap and closes with `?` or `Esc`.
- Add theme-aware `.keyboard-selected` styles for sections and notes, an accessible selected-state label, and `scrollIntoView({ block: 'nearest' })` when selection changes.

## Test plan

- Run the existing JavaScript syntax checks and workspace tests.
- Verify navigation in empty, populated, active-feed, and submitted-history sections.
- Verify selection survives SSE refreshes and falls back after the selected item is deleted.
- Verify global shortcuts do not fire while editing or using modal and standard form controls.
- Verify deletion still requires confirmation and submitted notes cannot be reordered.

## Assumptions

- Safe actions run directly from the keyboard. Permanent deletion always requires confirmation.
- The workspace follows the panel's shortcut vocabulary and uses `J` and `K` plus `Y`, `E`, `A`, `X`, and `R` for note-specific work.
- Mouse controls and ordinary browser Tab navigation remain available.
