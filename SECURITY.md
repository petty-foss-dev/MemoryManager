# Security Policy

## Reporting a vulnerability

Do not open a public issue for an unpatched vulnerability. Use [GitHub's private vulnerability reporting](https://github.com/petty-foss-dev/MemoryManager/security/advisories/new) or email `enve.audiobook@gmail.com`.

Include the affected version, reproduction steps, impact, and any suggested mitigation. Remove personal file names, folder paths, and other private details from logs or screenshots.

You should receive an acknowledgement within seven days. Fix timing depends on severity and reproducibility.

## Supported versions

Security fixes target the current public `main` branch and latest release. Older releases may receive a fix when practical but are not guaranteed long-term support.

## Security boundaries

Memory Manager runs entirely as the signed-in user and has no network code.

- It never requests administrator privileges, installs helper tools, or uses private APIs.
- Pause, resume, quit, and force quit only signal processes whose start time still matches the listed process, so a reused PID is never targeted. Core macOS processes such as loginwindow and the Dock cannot be controlled.
- Processes paused by Memory Manager are recorded and resumed on normal exit or after a crash.
- Storage cleanup only moves confirmed items inside the user's home folder to the Trash. Whole standard folders, the Trash itself, keychains, preferences, accounts, and mail, messages, and iCloud data are never offered for removal.
- Changes touching process signaling, file removal, or these boundaries need focused tests and careful review.
