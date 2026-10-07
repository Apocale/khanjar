# Installing Khanjar

About 3 minutes. [Version française](INSTALL.fr.md)

## Before you start

- A Mac with Apple Silicon (M1 or later).
- Adobe Premiere Pro 2026 (26.x).
- The Creative Cloud desktop app, signed in. Khanjar uses it to install its plugin in Premiere.

## Install with Claude Code (easiest)

If you have [Claude Code](https://claude.com/claude-code) on your Mac, paste this message into it: it does the whole install. Because the download goes through the terminal, macOS does not ask you to "Open Anyway".

```text
Install Khanjar for me, a free plugin for Adobe Premiere Pro (https://github.com/Apocale/khanjar).
Don't touch any of my Premiere projects, never use sudo, and tell me each step in one line.

1. Check the requirements and stop with an explanation if one is missing:
   - Apple Silicon Mac: `uname -m` must print arm64;
   - Premiere Pro 2026 installed: /Applications/Adobe Premiere Pro 2026;
   - Creative Cloud desktop app installed: this file must exist:
     "/Library/Application Support/Adobe/Adobe Desktop Common/RemoteComponents/UPI/UnifiedPluginInstallerAgent/UnifiedPluginInstallerAgent.app/Contents/MacOS/UnifiedPluginInstallerAgent"

2. Download the latest version: get the .zip URL from
   `curl -s https://api.github.com/repos/Apocale/khanjar/releases/latest`
   (the browser_download_url ending in .zip, not appcast.xml), then download it with
   `curl -fL -o ~/Downloads/Khanjar.zip "<that url>"`.

3. Unzip it into a fresh temporary folder: `ditto -x -k ~/Downloads/Khanjar.zip "$(mktemp -d)"`.
   If Khanjar is already running, quit it first: `osascript -e 'quit app "Khanjar"'`.
   Put Khanjar.app in /Applications (replace an older version after telling me).
   If /Applications is not writable without sudo, stop and tell me.

4. Ask me to open Premiere Pro, wait for my confirmation, then run: `open /Applications/Khanjar.app`.
   Warn me that macOS may ask for access to my Documents folder: I must click "Allow"
   (that's where my presets are).

5. Check that it works: before step 4, note how many lines ~/Library/Logs/Khanjar/Khanjar.log has
   (0 if it does not exist). After step 4, a NEW line containing "hello : io.khanjar.executor"
   must appear within 3 minutes (installing the plugin can take that long).
   If nothing after 3 minutes, ask me to quit and reopen Premiere, then check again.
   If it's still stuck, show me the last 20 lines of the log.

6. Turn on launch at login:
   `/Applications/Khanjar.app/Contents/MacOS/Khanjar login-item on`

7. Finish by explaining in 4 lines: in Premiere, ⌘J opens the palette, I type the name of an effect
   or preset, Enter applies it to the selected clips; ⌘⇧J adds an adjustment layer at the playhead
   (create one once in the project first: File > New > Adjustment Layer).
```

Otherwise, follow the steps below by hand.

## 1. Download and move the app

1. Download `Khanjar-<version>.zip` (not `appcast.xml`) from the [latest release](https://github.com/Apocale/khanjar/releases/latest).
2. Double-click the zip to unpack it.
3. Drag **Khanjar.app** into your **Applications** folder.

## 2. First launch (beta not signed by Apple yet)

macOS blocks apps that are not notarized by Apple the first time. You confirm once, then never again.

**macOS 15 Sequoia and later**
1. Double-click **Khanjar** in Applications. macOS says it could not verify the app: click **Done** (not *Move to Trash*).
2. Open **System Settings > Privacy & Security** and scroll down to **Security**.
3. Next to *"Khanjar" was blocked*, click **Open Anyway**, confirm with your password, then click
   **Open Anyway** again in the dialog that appears.

**macOS 14 and earlier**
Right-click **Khanjar** in Applications > **Open** > **Open**.

## 3. Let Khanjar set itself up

1. A magic-wand icon appears in the menu bar, and a welcome window opens. Tick **Launch Khanjar at
   login** (off by default) so Khanjar is ready after a restart, then click **Get started**.
2. macOS may ask for access to your **Documents** folder: click **Allow**.
   Your own Premiere presets are stored there; without it, they are missing from the palette.
3. If Premiere is open, Khanjar installs its plugin in it automatically. If Premiere is closed, this
   happens the next time you open it.

## 4. Use it

In Premiere Pro, select one or more clips in the timeline, press **⌘J**, type a few letters, press **Enter**.

- **⌘1 … ⌘0**: apply one of your most used items straight from the empty palette.
- **⌘⇧J**: add an adjustment layer at the playhead. Create one once in your project first
  (*File > New > Adjustment Layer*): Khanjar reuses it.
- Shortcuts, theme and number of results: menu bar icon > **Settings…**

## Updates

On its second launch, Khanjar asks whether it may check for updates automatically: say yes, and Khanjar
offers each new version (tick *Automatically download and install* to skip the question; updates are signed, so only genuine Khanjar releases are accepted). You can also use
menu bar icon > **Check for Updates…**. After an update, macOS may ask again for access to your
Documents folder: click **Allow** (this goes away once Khanjar is signed by Apple).

## Troubleshooting

| What you see | What to do |
|---|---|
| "Khanjar is reconnecting to Premiere…" (or "Open Premiere Pro to use Khanjar") while Premiere is open | Wait 1 minute (Khanjar reinstalls its plugin on its own). Still there? Quit and reopen Premiere. |
| "Creative Cloud is required to install the Khanjar plugin" | Install the Creative Cloud desktop app, sign in, then relaunch Khanjar. |
| ⌘J does nothing | Khanjar only reacts when Premiere is the active app. Check the magic-wand icon is in the menu bar (after a restart, open Khanjar from Applications). |
| A preset is marked *partial* | One of its effects no longer exists in your version of Premiere, or one of its settings cannot be set through Adobe's plugin API. The rest is applied. |
| A preset is missing from the palette | It uses a mask shape, or Lumetri curves, color wheels or a LUT, which Adobe's plugin API cannot set: Khanjar leaves it out rather than apply it wrong. Lumetri presets that only move sliders are included. Audio-only presets are not supported yet. |
| Your presets are missing | System Settings > Privacy & Security > Files and Folders > Khanjar: enable **Documents**. |

Still stuck? Menu bar icon > **Open log**, and [open an issue](https://github.com/Apocale/khanjar/issues)
with the last lines (check them first for clip or project names you do not want to share).

## Uninstall

1. Menu bar icon > **Quit Khanjar**, then move **Khanjar.app** to the Trash.
2. Remove the plugin from Premiere (Premiere can stay open):
   ```bash
   "/Library/Application Support/Adobe/Adobe Desktop Common/RemoteComponents/UPI/UnifiedPluginInstallerAgent/UnifiedPluginInstallerAgent.app/Contents/MacOS/UnifiedPluginInstallerAgent" --remove "Khanjar"
   ```
3. Optional, to remove your settings and history:
   ```bash
   rm -rf ~/Library/Application\ Support/Khanjar ~/Library/Logs/Khanjar
   ```
