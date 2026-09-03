# Contributing

Feed the Flock is developed and tested on Omarchy Quattro. Keep changes scoped to one concern and preserve the split between the QML panel, Python backend, and browser workspace.

## Repository layout

- `BarWidget.qml` and `Panel.qml` define the Omarchy entry points.
- `AgentFeedState.qml` owns panel state and helper processes.
- `bin/feed_the_flock/` contains capture, storage, delivery, keybinding, and workspace code.
- `workspace/` contains the local browser interface.
- `tests/` contains shell, Python, browser, and QML checks.

Backend modules should stay below 800 lines. Add behavior to the module that owns it instead of growing the CLI entry point or a general-purpose helper.

## Local workflow

Run the validation suite from the repository root:

```sh
./scripts/validate.sh
```

It checks the manifest, QML, Python and JavaScript syntax, plugin boundaries, command behavior, local workspace, attachments, safety cases, and QML presentation tests.

Install the working tree into the local Omarchy plugin directory with:

```sh
./scripts/install-local.sh
```

That script validates first, copies the plugin, rescans the shell, and enables the bar widget when needed. It is only for a separate development checkout; don't run it from the installed plugin directory.

## Change rules

- Treat note text, imported Markdown, filenames, Herdr data, and persisted state as untrusted input.
- Keep subprocess output, request bodies, files, queues, and image dimensions bounded before retention.
- Use argument arrays for commands. Give subprocesses a wall-clock timeout and terminate their process group on timeout.
- Use descriptor-based no-follow reads for managed files and atomic replacement for generated files.
- Keep all QML text sinks in plain-text mode unless sanitized rich text is intentional.
- Preserve user-customized workspace assets during updates.
- Update removal steps when a change creates state, processes, configuration, or files outside the plugin checkout.

Add a regression test for every bug fix. Run the full suite before committing a release candidate.
