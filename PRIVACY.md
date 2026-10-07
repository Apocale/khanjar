# Privacy

Khanjar is built to keep your work on your Mac.

## What stays on your Mac

Everything you do with Khanjar: your presets, your clips, your projects, your search history and
the list of items you use most (`~/Library/Application Support/Khanjar/`). Khanjar talks to
Premiere Pro through a local connection (`127.0.0.1`) that refuses web pages.

## Update checks (optional)

On its second launch, Khanjar asks whether it may check for updates automatically. If you agree,
it downloads the list of releases (`appcast.xml`) from GitHub about once a day. Like any web request,
this reveals your IP address to GitHub; nothing else is sent. Updates are signed: Khanjar refuses
any file that was not signed with the Khanjar release key. You can also check manually from the
menu bar icon (*Check for Updates…*).

## Anonymous crash reports (optional, off by default)

If you tick **Send anonymous crash reports** (welcome window or Settings), then after Khanjar
crashes, the next launch sends a summary of the crash report that macOS wrote itself.

**Sent**: Khanjar and plugin versions, macOS version, the type of crash, and the list of code
functions that were running in the crashed thread (for example `AppCoordinator.apply(_:)`).

**Never sent**: file paths, clip, preset or project names (text in quotes is masked), your user
name, your Mac's name, model or serial number, the hardware identifiers macOS puts in crash reports,
other threads. Khanjar does not attach your IP address, and the receiving project is set to never
store IP addresses.

Reports are received by [Sentry](https://sentry.io) and only used to fix bugs. Untick the box at
any time to stop. The code that builds the report is short and readable:
[`CrashReporter.swift`](helper/Sources/Khanjar/Support/CrashReporter.swift).
