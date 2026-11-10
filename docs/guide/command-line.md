# Command line report

`gruz-scan` runs the same scan as the app and prints the result in the terminal or as JSON. It is
read-only: it does not link the module that removes data, so it cannot remove anything, even by
mistake. Use it to check a new rule, to compare machines, or to feed the result into your own
scripts.

`gruz-scan` is not included in the release zip. Run it from a clone of the repository (see
[Build from source](getting-started.md#build-from-source)):

```sh
swift run gruz-scan                        # summary by category
swift run gruz-scan --children             # with nested items
swift run gruz-scan --json > scan.json     # machine-readable
swift run gruz-scan --root ~/code --root ~/work
```

## Options

| Option | Effect |
|---|---|
| `--children` | Show the items inside each group, indented. |
| `--json` | Print the whole result as JSON instead of text. |
| `--root <folder>` | A project folder to scan for artifacts and Rust targets. Repeatable. Without it, the default project folders are used (`~/Developer`, `~/workspace`, `~/Projects`, `~/code`, `~/src`, `~/dev`, `~/repos`, whichever exist). |
| `-h`, `--help` | Print the usage. |

`gruz-scan` does not read the app's settings. It uses its own project folders (above) and the default
100 MB threshold for unrecognized folders, and it does not apply age filters, so it lists data the
app may hide by default. Progress messages go to standard error, the report to standard output.

## Text output

For each category with items, the report prints a header with the reclaimable size, then each item
with its size, title, safety level and a `[permanent]` mark when its removal bypasses the Trash.
Applications and Unrecognized are printed without a reclaimable size. At the end come scan warnings,
free disk space, a note when Full Disk Access is missing, and the scan time.

```text
== Package managers (reclaimable: 8.1 GB)
  3.2 GB     Python package cache (uv) · Safe [permanent]
  2.4 GB     npm package cache · Safe
  ...

Free space: 112.4 GB
Scan time: 21.3 s
```

The text output is in English, because the command line tool has no bundle that declares other
languages.

## JSON output

`--json` prints the scan result as pretty-printed JSON with sorted keys and ISO 8601 dates. Top-level
fields:

| Field | Meaning |
|---|---|
| `items` | Top-level items of all categories (see below). |
| `warnings` | Scan warnings, for example when Docker did not respond. |
| `startedAt`, `finishedAt` | When the scan started and finished. |
| `freeBytes`, `totalBytes` | Free and total space of the home volume. |
| `hasFullDiskAccess` | Whether the scan could read TCC-protected folders. |
| `language` | Language of the item texts. |

Each item has:

| Field | Meaning |
|---|---|
| `id`, `ruleID` | Item identifier and the rule that produced it. |
| `category` | Category key, for example `docker`, `packages`, `projects` (see [Rule catalog](../reference/rules.md#categories)). |
| `title`, `app`, `description`, `regeneration`, `note` | The texts shown in the app. |
| `safety` | `safe`, `regenerable`, `caution` or `userData`. |
| `sizeBytes` | Allocated size in bytes, an estimate of what removal frees. |
| `lastModified` | Newest modification time inside the item, if known. |
| `paths` | Paths the item covers. |
| `action` | `{"type": "trash"}`, `{"type": "permanentDelete"}`, `{"type": "command", "argv": [...]}`, or absent for informational items. |
| `ownerBundleIDs`, `requiresAppClosed` | The owning apps and whether they must be closed before removal. |
| `defaultAgeDays` | The item's default age threshold, if any. |
| `children` | Nested items of a group. |
| `rustArtifact` | Extra data for Rust components (see [Rust and Cargo](rust.md)). |

For example, to list the ten largest top-level items with `jq`:

```sh
swift run gruz-scan --json 2>/dev/null \
  | jq -r '.items | sort_by(-.sizeBytes) | .[:10][] | "\(.sizeBytes) \(.category) \(.title)"'
```

The JSON format follows the app's internal model and may change between versions.
