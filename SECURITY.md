# Security policy

GRUZ moves files to the Trash and, when the user explicitly chooses so, deletes them permanently. A bug that removes data the user did not review is the most serious kind of bug this project can have.

## What to report privately

- Any way to make GRUZ remove, move or overwrite a path that was not listed in the review sheet.
- A rule, symlink, path pattern or race that lets a removal reach a protected location (home folder, Documents, Desktop, `.git`, project sources, system folders).
- Any way to trigger cleaning without the GUI confirmation (CLI, URL scheme, Apple Events, files dropped on disk).
- Command execution beyond the allow-list in `CommandPolicy`.

## How to report

Use GitHub's private vulnerability reporting: open the repository's **Security** tab and choose **Report a vulnerability**. Please include the macOS version, GRUZ version, and the smallest reproduction you can build with throwaway folders. Do not attach real user data.

You will get an answer within a week. Fixes for data-loss bugs are released as soon as they are verified, with credit to the reporter unless you prefer otherwise.

## Supported versions

Only the latest release receives fixes.
