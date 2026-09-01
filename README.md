# Feed the Flock

An Omarchy plugin and Herdr companion for capturing, organizing, and delivering notes to agent sessions at a manageable pace. It provides:

- Voxtype recording and transcription
- persistent SQLite-backed buckets, sections, and notes
- bucket and section create, rename, reorder, and delete operations in both interfaces
- visual capture lifecycle
- note reordering, editing, deletion, section moves, and managed image attachments
- drag notes onto other notes to reorder or onto section chips to regroup
- a live, full-width document workspace with inline editing and paragraph drag/drop
- automatic adoption of the active Omarchy theme colors
- server-sent change notifications so new captures appear automatically
- Herdr agent discovery and direct delivery to idle/done agents
- read-only remote-feeder browsing over the endpoint used by `herdr --remote`
- configurable global recording and feeding shortcuts with conflict detection
- generated full-bucket Markdown for interoperability
- manual text entry for quick testing

## Install

Requirements:

- Omarchy 4.x with `omarchy-shell`
- Python 3.11 or newer
- [Voxtype](https://github.com/peteonrails/voxtype) for voice capture
- [Herdr](https://github.com/pjgeutjens/herdr) for agent discovery and delivery
  Install the lifecycle integration for each target harness, for example `herdr integration install omp`. Wait-mode feeding rejects untracked agents rather than risk steering an active turn.
- `wl-clipboard` for ordered image delivery
- `zenity` for the widget's Markdown import file picker
- `libnotify` for notifications

Install and enable the git-managed plugin:

```sh
omarchy plugin add https://github.com/pjgeutjens/omarchy-feed-the-flock.git --enable
```

Configure global capture and feed shortcuts from the keyboard button in the plugin footer. Click **Change**, press a shortcut, and explicitly approve an override only when you intend to temporarily replace another action. The optional compatibility command installs `Shift+F9` and `Shift+F10` defaults:

```sh
~/.config/omarchy/plugins/io.github.pjgeutjens.agentfeed/scripts/manage-binding.sh install
```

The plugin appears on the right side of the Omarchy bar. Open it, select a bucket, and click **Record**. Click **Finish** when done. Voxtype writes the transcription into a private capture file and Feed the Flock adds it to the selected bucket.

Create a bucket with the **+** button beside the bucket chips, or press `B`. Create a section with the **+** button beside section chips, or press `S`. Use `H/L` to switch buckets, `Tab`/`Shift+Tab` to switch sections, `R` to connect or manage a remote feeder, `N` to open the active section’s pending-note overlay, `T` to open the target dropdown, `M` to open the mode dropdown, `Q` to select FIFO/LIFO queue order, `F` to toggle the feed, and `O` to open the live workspace. In the notes overlay, use `J/K` or the arrow keys to select a note and `U/D` to move it in document order. Press `?` or click the footer’s question-mark action to open a searchable keybinding reference. The compact panel focuses on capture, destination selection, feed control, and a full-height pending-note overview; manual note entry, submitted history, editing, attachments, and drag/drop organization live in the HTML workspace. There, `Enter` submits, `Shift+Enter` inserts a newline, and `Escape` restores the saved value. Left-click a paragraph to copy it, right-click to edit, or drag the `⠿` handle to reposition it. Use **Import**/`I` to create a bucket from Markdown and **Export**/`X` to write the active bucket to `~/Downloads`; both controls are available in the widget and HTML workspace. Markdown uses `#` for the bucket, `##` for sections, `- [ ]` for pending notes, and `- [x]` for submitted notes; plain list items import as pending. Indented continuation lines preserve multiline notes. Attachments are not embedded in the Markdown export.

Global shortcuts are stored in SQLite and generated into `~/.config/hypr/agent-feed-bindings.lua`; one loader line is added to `~/.config/hypr/bindings.lua`. Conflicts are rejected unless the user explicitly chooses **Override**. Changing or removing an override restores the original owner’s binding because its source configuration is never edited. The compatibility script’s `remove` action removes both managed additions.

State is stored under `~/.local/state/agent-feed`.

Update with:

```sh
omarchy plugin update io.github.pjgeutjens.agentfeed
```

Before removing the plugin, stop its worker and workspace server and restore shared keybindings:

```sh
~/.config/omarchy/plugins/io.github.pjgeutjens.agentfeed/scripts/prepare-remove.sh
omarchy plugin remove io.github.pjgeutjens.agentfeed
```

Removal intentionally retains the SQLite database, attachments, recordings, logs, and customized workspace assets under `~/.local/state/agent-feed`. Delete that directory manually only if you also want to erase all Feed the Flock data.

For development from this repository, use `./scripts/install-local.sh`. Do not run that development installer from inside the git-managed plugin directory.

## Herdr delivery

Feed the Flock discovers agents from the default running Herdr session. Choose the delivery target with the compact dropdown in the plugin (or press `T` to open it), and the feed submits notes through Herdr's `agent prompt` API according to the selected mode. The workspace displays the selected target and provides explicit note- and section-level Feed Now actions. Clipboard remains the default. Wait-mode delivery requires a lifecycle-tracked Herdr agent and releases each next note only after Herdr records a newer lifecycle transition back to idle or done.

Press `R` to connect a read-only remote feeder. The endpoint field accepts an SSH hostname, IP, alias, or `user@host` and is prefilled from a running `herdr --remote` client when available. Both devices must have a compatible Feed the Flock version installed and batch SSH authentication must already work. Remote mode reuses the normal bucket and section trains, exposes pending notes through the notes overlay, and opens a read-only HTML workspace containing remote buckets, sections, note history, and attachment counts. Copying note text remains available; capture, feeding, CRUD, reordering, transfer, and attachment mutation are blocked. Queries use fixed, versioned plugin commands with strict endpoint validation, timeouts, output limits, and no direct access to the remote SQLite file. Disconnect with `R` to return to the untouched local view.

Delivery modes are **Active · One by one**, **Active · Batch**, **All · One by one**, and **All · Batch**; every mode waits for the selected Herdr agent to become idle. The persisted feed cursor is independent from browsing. Each section exposes **Add to queue** (`+`) and **Feed now** (`⚡︎`). Add to queue appends the section to an ordered queue; the HTML header and plugin display that queue with per-section remove controls. When the current section drains, the first queued section takes over; when all selected work drains, the feed automatically switches off. Feed now switches immediately and places an interrupted section with pending notes at the front so it can resume afterward. In the plugin, use `G` to append and `Shift+G` for Feed Now. Active modes use the current feed section, while All modes begin there and continue through section order. A background worker queues every new note, waits for the selected Herdr target to become idle, and delivers according to the selected scope, batch mode, and FIFO/LIFO order. Bucket/section selection and all feed settings are persisted in SQLite. If the feed was active when the plugin restarts, a notification counts down from 10 seconds before resuming; its **Click here to cancel** action keeps the feed off. The queue is rebuilt from current section and note positions before every submission, so reordering pending content takes effect immediately. Notes captured while the feed is off remain pending and resume when it is enabled. The compact plugin keeps its main view free of note cards and exposes pending notes through the `N` overlay. Bucket and section chips show only their total message count; the feed control provides the single queue count for the active delivery scope. The HTML workspace exposes the same bucket statistics beneath the delivery target in its sticky header, plus a compact Start/Stop control beside the section queue. Starting there explicitly uses the visible bucket and its persisted or first pending section; stopping leaves browsing unchanged. The HTML workspace shows the delivered note or batch as **Active** without a strikethrough while Herdr reports that target working; it becomes crossed-out submitted history when the target returns to idle or done, where it can be requeued with `↶`. Unsent notes expose Feed Now or Delete; there is no manual Mark Sent action. In the HTML workspace, an unsent note’s `⚡︎` action uses Herdr’s supported prompt command to submit immediately—even during a working turn—without waiting for idle. Blocked or disconnected targets still reject immediate submission. Successfully forced notes remain marked with `⚡︎`, but otherwise follow the persisted delivery sequence. The active HTML section uses one expanding timeline: submitted notes in send order, followed by the pending FIFO/LIFO queue. Individual notes retain subtle blockquote-style left edges, and submitted history can be shown or hidden with a client-side filter. The timeline has no internal scrollbar; the document page handles all scrolling. Unmarking clears the forced-delivery distinction.

Buckets and sections support create, rename, reorder, and delete operations in both the plugin and HTML workspace. Deleting a non-fallback section explicitly asks whether to move its messages to the fallback section or permanently discard them. Keyboard CRUD shortcuts are `B`/`Shift+B` for bucket creation/rename, `S`/`Shift+S` for section creation/rename, `[`/`]` for section order, `{`/`}` for bucket order, `Shift+X` for section deletion, and `Ctrl+X` for bucket deletion. Deleting a section moves its notes to the bucket's fallback Unsorted section. Unsorted can be renamed and reordered but not deleted, and every bucket always has at least one section.

Pending notes accept up to five PNG, JPEG, WebP, or GIF attachments of 8 MB each. Use the image action, drop images onto a note, or paste images while editing. The workspace shows compact image icons; hover for a thumbnail, click to open, or right-click to remove. Before text submission, delivery serially places each image on the Wayland clipboard and sends `Ctrl+V` to the Herdr target, then restores the previous clipboard content. This is portable across harnesses that support image clipboard paste, but Herdr cannot currently confirm that a harness accepted the image.

The CLI exposes the same integration:

```sh
feed-the-flock targets
feed-the-flock deliver <note-id> herdr:<pane-id>
feed-the-flock bucket export [bucket-id]
feed-the-flock bucket import <file.md>
feed-the-flock remote connect <ssh-endpoint>
feed-the-flock remote disconnect
feed-the-flock binding record set 'SHIFT + F9'
feed-the-flock binding feed set 'SHIFT + F10'
```

## Security and privacy

Feed the Flock stores note text, transcription output, delivery history, logs, and managed attachments locally under `~/.local/state/agent-feed` with a private parent directory and owner-only database/files. The workspace binds only to `127.0.0.1`, rejects foreign Host and Origin headers, caps request/response sizes, and does not use cloud services itself. Remote mode reads note content over the user-approved SSH endpoint into ephemeral panel/browser views; it does not persist a local copy or transfer attachment bytes. Herdr and the selected agent harness may have their own network or cloud behavior.

Delivery intentionally submits note text and attachments as prompts to the selected agent. That agent can act with whatever tools and approvals its harness grants. Review pending captures and imported Markdown before enabling a feed, especially when they contain text or images from an untrusted source.

## Backend layout

- `bin/feed-the-flock` — thin CLI entry point
- `bin/feed_the_flock/store.py` — SQLite schema and bucket/section/note operations
- `bin/feed_the_flock/feed.py` — Herdr discovery, delivery worker, and restart countdown
- `bin/feed_the_flock/capture.py` — Voxtype capture lifecycle
- `bin/feed_the_flock/workspace.py` — Markdown rendering and HTML workspace server/API

## Validate

```sh
./scripts/validate.sh
```
