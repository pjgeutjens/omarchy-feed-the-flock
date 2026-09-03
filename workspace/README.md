# Workspace architecture

This directory contains the dependency-free browser workspace. The Python server sends these files directly; there is no build output or package-manager state in this directory.

## File map

| Concern | File |
| --- | --- |
| Document shell and accessibility labels | `index.html` |
| App state, rendering coordination, and live refresh | `js/app.js` |
| Note rows, note actions, and note drag/drop | `js/note-view.js` |
| Section rows, section actions, and section drag/drop | `js/section-view.js` |
| Keyboard selection, search, and action dispatch | `js/viewer-navigation.js` |
| Inline note edit lifecycle | `js/note-editor.js` |
| Attachment file handling | `js/attachments.js` |
| Delivery-routing dialog | `js/routing.js` |
| Shared modal and API helpers | `js/modal.js`, `js/api.js` |
| Viewport scrolling during section drag | `js/drag-autoscroll.js` |
| Omarchy theme loading | `js/theme.js`, `styles/theme.css` |
| Controls, document, notes, and overlays | `styles/*.css` |
| Workspace launcher | `../bin/feed_the_flock/workspace.py` |
| Document payloads, Markdown, and attachments | `../bin/feed_the_flock/workspace_content.py` |
| HTTP routes, SSE, and static files | `../bin/feed_the_flock/workspace_server.py` |

`js/app.js` owns browser state and composes the smaller modules. Put note behavior in `note-view.js`, section behavior in `section-view.js`, and keyboard behavior in `viewer-navigation.js`. Keep database and filesystem mutations in Python.

## Data flow

1. SQLite is the source of truth.
2. The workspace requests a bucket document from `GET /api/bucket?id=...`.
3. `app.js` renders sections through `section-view.js`, which renders notes through `note-view.js`.
4. Mutations go through `/api/*` routes and reload their result from SQLite.
5. `/api/events` emits an SSE change event after stored data changes.

Browser state is disposable. The database, managed attachments, logs, and Chromium profile belong under `~/.local/state/agent-feed`, outside this source tree.

## Product rules

- A bucket always has an undeletable fallback section.
- Only pending notes can move. Submitted notes keep delivery order until requeued.
- FIFO and LIFO come from the backend; the browser does not reconstruct queue order.
- Live refresh keeps the active editor draft, selection, and focus.
- Routing changes apply together and only while the feed is stopped.
- The current feed destination and waiting section queue are global, even while another bucket is open.
- Note text and names are untrusted plain text. Do not insert them with `innerHTML`.
- Attachment paths must remain inside the managed attachment directory.

## Installation and customization

`scripts/install-workspace.py` records hashes in `~/.local/state/agent-feed/workspace-assets.json`. On update:

- unchanged built-in files receive the new release;
- edited built-in files remain in place and get a neighboring `.upstream` copy;
- user-created files remain untouched;
- files removed from the release are deleted only when the installed copy is unchanged.

Do not replace this installer with a directory-wide copy or cleanup. `tests/test-workspace-install.sh` enforces these rules.

## Checks

Run `./scripts/validate.sh` from the repository root. It checks QML and source syntax, module-size limits, CLI behavior, workspace APIs, browser keyboard behavior, attachment safety, update preservation, and QML presentation.
