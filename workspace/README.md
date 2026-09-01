# Workspace architecture

This directory is the dependency-free HTML viewer for Feed the Flock. It is served directly by `bin/feed_the_flock/workspace.py`; there is no bundler, package manager, framework, or generated output.

## Find the right file

| Concern | File |
| --- | --- |
| Semantic document shell and accessibility labels | `index.html` |
| Theme variables and global typography | `styles/theme.css` |
| Sticky bucket, target, queue, and status controls | `styles/controls.css` |
| Toast and modal presentation | `styles/overlays.css` |
| Section cards, active queue timeline, and section actions | `styles/document.css` |
| Note rows, editing, delivery actions, and drag handles | `styles/notes.css` |
| Narrow-screen adaptations | `styles/responsive.css` |
| API transport and HTTP error handling | `js/api.js` |
| Accessible modal behavior and focus trapping | `js/modal.js` |
| Atomic target, mode, and order routing dialog | `js/routing.js` |
| Omarchy color loading | `js/theme.js` |
| Workspace state, controls, rendering, drag/drop, and live refresh | `js/app.js` |
| JSON endpoints, SQLite mutations, SSE, and static serving | `../bin/feed_the_flock/workspace.py` |

Start with `js/app.js` when changing behavior. Its main render boundaries are `noteElement`, `sectionElement`, `renderFeedQueue`, and `load`. Keep API transport in `api.js` and modal mechanics in `modal.js` rather than duplicating them.

## Data flow

1. SQLite is canonical.
2. `workspace.py` returns bucket documents from `GET /api/bucket?id=…`.
3. `app.js` renders the returned bucket, sections, notes, feed destination, and section queue.
4. Mutations use the `/api/bucket/*`, `/api/section/*`, `/api/note/*`, and `/api/deliver` endpoints.
5. `/api/events` emits an SSE `change` event after SQLite changes; the viewer reloads its document.
6. `/api/theme` maps the active Omarchy theme into CSS variables.

The important section fields are `feedCurrent` (persisted selection), `feedActive` (currently running), `feedQueuePosition`, `feedLabel`, and `notes`. Notes expose `sent`, `active`, `jumpedQueue`, `deliveredAt`, `deliverySequence`, and an ordered `attachments` list in addition to their ID and text. Attachment records provide `id`, `name`, `mimeType`, and a local authenticated-by-loopback `url`.

## Product invariants

- SQLite remains the source of truth; browser state is disposable.
- Markdown export uses `#` bucket titles, `##` section titles, and task-list notes (`[ ]` pending, `[x]` submitted). Import creates a new bucket and never replaces an existing one.
- Left-clicking a note copies it. Delivery requires an explicit Feed Now action.
- Notes may have up to five managed image attachments; never render full images inline.
- Every note reserves four control/status slots so text always starts in one column; up to five attachment icons appear at the end of the text area.
- Multiple attachments retain their order and are pasted into the target before note text is submitted.
- Attachment delivery must fail visibly if clipboard setup or Herdr key injection fails; never silently omit images.
- Pending notes expose Feed Now and Delete. Submitted notes expose Requeue and Delete.
- Only pending notes can be dragged or reordered. Submitted notes retain immutable delivery-sequence order until requeued.
- A delivered note or batch remains Active while its Herdr target is working, then becomes ordinary submitted history when the target returns to idle or done.
- There is no manual Mark Sent action.
- Enter submits edits, Shift+Enter inserts a newline, and Escape restores the saved value.
- Escape must restore the editor’s explicit canonical original before blur; cancelling a provisional “New note” deletes it instead of persisting the placeholder.
- Live SSE refreshes must preserve the active editor’s draft, selection, and focus while showing externally captured notes.
- A bucket always retains its undeletable fallback section.
- Deleting another section must explicitly choose moving notes to the fallback or discarding them.
- Clearing retains the section but requires its exact name, removes all pending and submitted notes, and unlinks only attachment files managed inside the attachment directory.
- A section is promoted visually only while its feed is active; after draining it returns to document order.
- Starting from the viewer targets the visible bucket without changing the compact panel's browsing selection.
- Workspace routing changes require an explicit Apply, update target/mode/order atomically, and are rejected while feeding is active.
- FIFO/LIFO order is provided by the backend and must not be reconstructed differently in the browser.
- Use specific component selectors such as `.section-action.feed-now` or `.note-action.feed-now`; avoid broad class selectors that can collide.

## Common changes

- **Change colors or typography:** edit `styles/theme.css`; preserve the CSS variables populated by `js/theme.js`.
- **Change sticky controls:** edit `index.html`, `styles/controls.css`, and the control bindings near the top of `js/app.js`. Feed Start/Stop uses `viewerFeedSection` and `POST /api/feed`.
- **Change a note or attachment UI:** edit `noteElement`, `uploadAttachment`, and `uploadAttachments` in `js/app.js`, plus `styles/notes.css`.
- **Change a section or queue timeline:** edit `sectionElement` in `js/app.js` and `styles/document.css`.
- **Add an operation:** add the endpoint in `workspace.py`, call it through `request()` from `js/api.js`, then reload from SQLite rather than assuming the mutation succeeded locally.
- **Add a dialog:** use `requestText` or `requestConfirmation` from `js/modal.js`.

## Installation and customization

`scripts/install-workspace.py` records shipped SHA-256 hashes in `~/.local/state/agent-feed/workspace-assets.json`. On a later install:

- unchanged shipped files update automatically;
- locally modified installed files are preserved;
- the new shipped copy is written beside a conflict as `<name>.upstream`;
- the installer prints every preserved path.

An agent can then compare the customized file with its `.upstream` counterpart and merge deliberately. Source-tree changes made in this repository are normal shipped changes and are installed when the installed copy still matches its previous hash.

## Validation

Run:

```sh
./scripts/validate.sh
./scripts/install-local.sh
```

Validation checks Python, QML, CLI behavior, and JavaScript module syntax. After installation, open the workspace and test copying, editing/cancelling, section deletion choices, drag/drop, Feed Now, queue promotion, and live updates.
