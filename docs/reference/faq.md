# FAQ

## Can GRUZ delete something important?

Not by itself. Nothing is preselected, every removal goes through the review sheet with exact paths
and commands, and files go to the Trash by default. A hard-coded denylist protects your home folder,
Documents, Desktop, `.git` folders, project sources and system folders regardless of any rule.
Folders no rule describes cannot be removed at all. See [Removing items](../guide/removing.md).

## I removed a lot, but free space barely changed. Why?

Most likely the files are in the Trash: empty it to get the space back. Other reasons are APFS clones
and hard links, which make sizes overestimate what removal frees, and OrbStack, which returns space
freed by Docker gradually. See [Sizes are estimates](limitations.md#sizes-are-estimates).

## How do I undo a removal?

Items moved to the Trash can be put back from the Trash in the Finder until you empty it. Permanent
operations (Docker commands, simulators, `uv cache clean`, **Skip Trash**) cannot be undone. The
[operation log](../guide/removing.md#operation-log) lists what was removed and where it was.

## Why is an item not selectable?

It has no removal action: it is **User data**, or it is in Applications or Unrecognized. These are
shown so you can see where the space is. GRUZ does not remove apps or folders it cannot describe.

## Why does the review sheet say an item will be skipped?

Usually the app that owns the data is running. Quit it and click **Check Again**. For Rust targets,
an active Cargo build, `rust-analyzer` or a debugger also blocks removal.

## Why are my Docker images missing?

GRUZ reads Docker data through the `docker` CLI, so Docker Desktop or OrbStack must be running. The
sidebar shows a warning when Docker does not respond.

## Why are recent Claude Code sessions not listed?

Some items show only data older than a threshold by default: 30 days for Claude Code and Codex
sessions, 7 days for temporary files. Change or turn off the thresholds in
[Settings > Data Age](../guide/settings.md#data-age).

## Why does GRUZ not see my projects?

It searches only the [project folders](../guide/settings.md#project-folders). Add your folders in
Settings > Scanning and click **Scan Again with New Settings**.

## Does GRUZ send data anywhere?

GRUZ has no telemetry or accounts. The scan reads your disk and the output of local tools such as
`docker` and `xcrun simctl`. The claude-mem maintenance talks to the claude-mem worker on
`127.0.0.1` and may download Python packages and an embedding model with uv on first use.
Deletions in a synchronized claude-mem installation reach cmem.ai through claude-mem itself.

## A folder in Unrecognized belongs to an app I know. Can I add it?

Yes, that is the easiest way to contribute. See the
[worked example](rules.md#worked-example-adding-a-rule) in the rule catalog.
