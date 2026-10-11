# Installing Khanjar

About 3 minutes. [Version française](INSTALL.fr.md)

## Before you start

- A Mac with Apple Silicon (M1 or later) running macOS 13 or later.
- Adobe Premiere Pro 2026 (26.x) or later.
- The Creative Cloud desktop app, signed in. Khanjar uses it to install its plugin in Premiere.

**Had the old "Dagger" version?** Before installing Khanjar, quit Dagger, remove "Dagger" from System
Settings > General > Login Items and move /Applications/Dagger.app to the Trash. Don't delete its data:
Khanjar picks up your settings, history and shortcuts. It also removes the old Dagger plugin from
Premiere by itself (otherwise: *Uninstall*, step 4).

## Install with Claude Code (easiest)

If you have [Claude Code](https://claude.com/claude-code) on your Mac, paste this message into it: it does the whole install, one step at a time. It will ask you once to quit Premiere (save your work first). Because the download goes through the terminal, macOS does not ask you to "Open Anyway".

```text
Install Khanjar for me, a free plugin for Adobe Premiere Pro (https://github.com/Apocale/khanjar).

Rules:
- Don't touch any of my Premiere projects, never quit Premiere yourself, never use sudo.
- Do NOT write an install script: run the commands below one at a time, copied exactly as written, and sum up each step in one line. Give each command a 5-minute timeout; none should take more than 2 minutes.
- When a step says "ask me", stop and wait for my reply in this chat (no read or sleep to wait for me).
- Every command starts in a fresh shell: it redefines the variables it needs itself.
- If a command fails because of Claude Code's sandbox ("Operation not permitted", error -54…), offer to run it outside the sandbox.
- If step 4 installs the app in ~/Applications, replace /Applications/Khanjar.app with "$HOME/Applications/Khanjar.app" in the later commands.

1. Requirements — stop and explain if one is missing:
   - Apple chip: `sysctl -n hw.optional.arm64` must print 1 (not `uname -m`, which prints x86_64 under Rosetta);
   - macOS 13 or later: `sw_vers -productVersion`;
   - Premiere Pro 2026 or later: find the app with `mdfind "kMDItemCFBundleIdentifier == 'com.adobe.PremierePro.*'"` (if nothing comes out, look in /Applications for an "Adobe Premiere Pro 20xx" folder) and read its version with `/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "<app>/Contents/Info.plist"`. 26.x (Premiere Pro 2026): tested. 27 or later: tell me it is not tested yet, and go on. Below 26: stop (Khanjar needs Premiere Pro 2026 or later);
   - Creative Cloud: the file "/Library/Application Support/Adobe/Adobe Desktop Common/RemoteComponents/UPI/UnifiedPluginInstallerAgent/UnifiedPluginInstallerAgent.app/Contents/MacOS/UnifiedPluginInstallerAgent" must exist, and `ps -axo comm= | grep -E 'Adobe Desktop Service|MacOS/Creative Cloud$'` must print at least one line. Otherwise ask me to open the Creative Cloud app and check I'm signed in, then check again;
   - old "Dagger" version: if /Applications/Dagger.app exists, tell me; with my OK, quit it if `pgrep -x Dagger` finds it (`osascript -e 'quit app "Dagger"'`), ask me to remove "Dagger" from System Settings > General > Login Items, then move it to the Trash (`mv /Applications/Dagger.app ~/.Trash/`). Don't touch ~/Library/Application Support/Dagger: Khanjar picks up my settings from there.

2. Download the latest version into a temporary folder (not Downloads):
      W="${TMPDIR:-/tmp}/khanjar-install"; mkdir -p "$W"
      FEED=$(curl -fsSL --retry 3 --max-time 30 https://github.com/Apocale/khanjar/releases/latest/download/appcast.xml)
      URL=$(printf '%s' "$FEED" | sed -n 's/.*enclosure url="\([^"]*\)".*/\1/p' | head -1)
      LEN=$(printf '%s' "$FEED" | sed -n 's/.*length="\([0-9]*\)".*/\1/p' | head -1)
      echo "$URL expected=$LEN"; curl -fL --retry 3 --max-time 90 -o "$W/Khanjar.zip" "$URL"; stat -f%z "$W/Khanjar.zip"
   The size must equal "expected". If the feed does not answer, take the .zip address (browser_download_url, not appcast.xml) from `curl -s https://api.github.com/repos/Apocale/khanjar/releases/latest`.

3. Unzip and check:
      W="${TMPDIR:-/tmp}/khanjar-install"; rm -rf "$W/x"; mkdir -p "$W/x"; ditto -x -k "$W/Khanjar.zip" "$W/x"
      /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' -c 'Print :CFBundleShortVersionString' "$W/x/Khanjar.app/Contents/Info.plist"
      codesign --verify --deep --strict "$W/x/Khanjar.app" && echo SIGNATURE-OK
   You need "io.khanjar.app" and SIGNATURE-OK; otherwise stop.

4. Install the app:
   - quit Khanjar if it is already running:
      if pgrep -x Khanjar >/dev/null; then osascript -e 'quit app "Khanjar"'; i=0; while pgrep -x Khanjar >/dev/null && [ $i -lt 10 ]; do sleep 1; i=$((i+1)); done; pkill -x Khanjar; fi; pgrep -x Khanjar || echo KHANJAR-CLOSED
   - folder: /Applications if `[ -w /Applications ]` succeeds, otherwise ~/Applications (create it);
   - if a Khanjar.app already exists in /Applications or ~/Applications, tell me its version, then move it to the Trash: `mv "<folder>/Khanjar.app" ~/.Trash/Khanjar-old-$(date +%s).app`. If that is refused, ask me to drag it to the Trash in Finder myself;
   - copy with ditto (never cp onto an existing folder): `ditto "${TMPDIR:-/tmp}/khanjar-install/x/Khanjar.app" "<folder>/Khanjar.app"`, then `codesign --verify --deep --strict "<folder>/Khanjar.app" && echo SIGNATURE-OK`.

5. Install the plugin in Premiere, with Premiere CLOSED:
   - if `ps -axo comm= | grep '/Contents/MacOS/Adobe Premiere Pro'` prints a line, Premiere is open: ask me to save my work and quit Premiere (⌘Q); wait for my reply and check it is really closed (otherwise ask me again);
   - list the plugins Adobe knows (60 s at most):
      UPIA="/Library/Application Support/Adobe/Adobe Desktop Common/RemoteComponents/UPI/UnifiedPluginInstallerAgent/UnifiedPluginInstallerAgent.app/Contents/MacOS/UnifiedPluginInstallerAgent"
      perl -e 'alarm 60; exec @ARGV' -- "$UPIA" --list all
     If "Khanjar" is listed, remove it with the same command, replacing `--list all` with `--remove "Khanjar"`; if "Dagger Executor" is listed, do the same with `--remove "Dagger Executor"` (a -406 answer is harmless);
   - then install the plugin (100 s at most):
      UPIA="/Library/Application Support/Adobe/Adobe Desktop Common/RemoteComponents/UPI/UnifiedPluginInstallerAgent/UnifiedPluginInstallerAgent.app/Contents/MacOS/UnifiedPluginInstallerAgent"
      perl -e 'alarm 100; exec @ARGV' -- "$UPIA" --install "/Applications/Khanjar.app/Contents/Resources/khanjar-executor.ccx"
     The output must contain "Successful". Then check the registration: `grep -o '"pluginId":"io.khanjar.executor"[^}]*' "$HOME/Library/Application Support/Adobe/UXP/PluginsInfo/v1/premierepro.json"` must show "status":"enabled" (if it shows nothing despite "Successful", tell me and go on). No "Successful": show me the output, ask me to quit and reopen the Creative Cloud app, and run this --install again once only (back-to-back attempts jam Adobe's installer).

6. Launch Khanjar (Premiere still closed):
      W="${TMPDIR:-/tmp}/khanjar-install"; LOG="$HOME/Library/Logs/Khanjar/Khanjar.log"; mkdir -p "$W"
      { stat -f%z "$LOG" 2>/dev/null || echo 0; } > "$W/offset"; open "/Applications/Khanjar.app"
   (On a new Mac the log does not exist yet: that's normal, the recorded position is 0.)
   Warn me: a "Welcome to Khanjar" window opens ("Bienvenue dans Khanjar" if my Mac is in French), I can click "Get started"; and macOS may ask for access to my Documents folder: I click "Allow" (my presets are there).

7. Ask me to open Premiere Pro and to reply when its main window is showing (the very first launch on a new Mac can take several minutes). Then check the connection with this command, copied exactly (90 s at most; run it again while it prints WAITING, 3 times at most):
      W="${TMPDIR:-/tmp}/khanjar-install"; LOG="$HOME/Library/Logs/Khanjar/Khanjar.log"
      OFF=$(cat "$W/offset" 2>/dev/null || echo 0); R=WAITING; i=0
      while [ $i -lt 18 ]; do i=$((i+1))
        S=$( { stat -f%z "$LOG" 2>/dev/null || echo 0; } ); [ "$S" -lt "$OFF" ] && OFF=0
        NEW=$(tail -c +$((OFF+1)) "$LOG" 2>/dev/null)
        if printf '%s\n' "$NEW" | grep -q 'hello : io\.khanjar\.executor'; then R=CONNECTED; break; fi
        sleep 5
      done
      echo "$R"; printf '%s\n' "$NEW" | grep -E 'hello : |UPIA|Plugin |Dagger|refusée|origine|invalide|Bridge|Listener|instance' | tail -8
   CONNECTED: go to step 9. Still WAITING after 3 runs: step 8.
   (The "hello :" pattern has a space before the colon: keep it. Khanjar writes its log in French; the lines above are the ones that matter.)

8. Troubleshooting, in this order, running the step 7 check again after each action:
   a. ask me to click in Premiere's window and press ⌘J once (Khanjar then restarts its own repair);
   b. ask me to save, quit Premiere (⌘Q), reopen it and tell you when its window is showing;
   c. still nothing: run this diagnostic and show me the whole output (I'll send it to Isma after reading it: it may contain preset or folder names, or my user name):
      LOG="$HOME/Library/Logs/Khanjar/Khanjar.log"; AS="$HOME/Library/Application Support/Adobe"
      UPIA="/Library/Application Support/Adobe/Adobe Desktop Common/RemoteComponents/UPI/UnifiedPluginInstallerAgent/UnifiedPluginInstallerAgent.app/Contents/MacOS/UnifiedPluginInstallerAgent"
      echo "== Mac"; sw_vers -productVersion; sysctl -n hw.optional.arm64
      echo "== Khanjar"; for a in /Applications/Khanjar.app "$HOME/Applications/Khanjar.app"; do [ -d "$a" ] && echo "$a $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$a/Contents/Info.plist")"; done; pgrep -lx Khanjar
      echo "== Premiere"; ps -axo pid=,comm= | grep '/Contents/MacOS/Adobe Premiere Pro' | cut -c1-120
      echo "== Port"; lsof -nP -iTCP:48123
      echo "== Khanjar log"; grep -E 'UPIA|Plugin |hello|Dagger|Bridge|Listener|Port|refusée|origine|invalide|Creative|instance|Expulsion|Premiere|prêt' "$LOG" | tail -40
      echo "== UPIA log"; tail -40 "$AS/UPI/Log/Upia.log"
      echo "== Plugin registry"; cat "$AS/UXP/PluginsInfo/v1/premierepro.json"; echo; ls "$AS/UXP/Plugins/External/"
      echo "== Plugin log"; find "$AS/UXP/PluginsStorage" -name 'khanjar-executor*.log' -print -exec tail -15 {} \;
      echo "== Adobe"; perl -e 'alarm 60; exec @ARGV' -- "$UPIA" --list all 2>&1 | head -60
      echo "== Creative Cloud"; ps -axo pid=,comm= | grep -E 'Adobe Desktop Service|MacOS/Creative Cloud$' | cut -c1-120
      echo "== localhost"; grep -i localhost /etc/hosts

9. Turn on launch at login: `"/Applications/Khanjar.app/Contents/MacOS/Khanjar" login-item on`, and repeat the end of the last line to me (it answers in French: « activé » means on; « en attente de ton accord » means I must approve it: guide me to System Settings > General > Login Items).

10. Visible check: ask me to click the magic-wand icon at the top right of the screen: the menu's second line must read "Connected — Premiere … · plugin …" ("Connecté — …" if my Mac is in French). Then, in Premiere, to press ⌘J: the palette must open (Esc closes it).

11. Delete the temporary folder (`rm -rf "${TMPDIR:-/tmp}/khanjar-install"`), then finish by explaining in 4 lines: in Premiere, ⌘J opens the palette, I type the name of an effect or preset, Enter applies it to the selected clips; ⌘⇧J adds an adjustment layer at the playhead (create one once in the project first: File > New > Adjustment Layer); at its next launch Khanjar will ask whether it may check for updates automatically: I say yes.
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
3. If Premiere is open, Khanjar installs its plugin in it automatically: within two minutes, the second
   line of the magic-wand icon's menu reads *Connected — Premiere … · plugin …*. If it doesn't, save your
   work, quit Premiere (⌘Q) and reopen it. If Premiere is closed, this happens the next time you open it.

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
Documents folder: click **Allow** (this goes away once Khanjar is signed by Apple). When an update
also brings a new Premiere plugin, Khanjar installs it while Premiere is closed: you keep working with
the current one, and the new one is there the next time you open Premiere.

A copy of Khanjar older than 0.8.2 (first line of the menu: "Khanjar 0.8.0" or "Khanjar 0.8.1") cannot
update itself: reinstall it with the Claude Code prompt or the steps above. Neither can the old "Dagger"
versions (see *Before you start*).

## Troubleshooting

| What you see | What to do |
|---|---|
| Two minutes after installing, the icon's menu still does not show *Connected — Premiere …* | Save, quit Premiere (⌘Q) and reopen it. Still nothing 2 minutes later? Menu bar icon > **Open log**, and send the lines containing "UPIA" or "hello". |
| "Khanjar is reconnecting to Premiere…" (or "Open Premiere Pro to use Khanjar") while Premiere is open | Wait 1 minute (Khanjar reinstalls its plugin on its own). Still there? Quit and reopen Premiere. |
| "Creative Cloud is required to install the Khanjar plugin" | Install the Creative Cloud desktop app, sign in, then relaunch Khanjar. |
| ⌘J does nothing | Khanjar only reacts when Premiere is the active app. Check the magic-wand icon is in the menu bar (after a restart, open Khanjar from Applications). |
| A preset is marked *partial* | One of its effects no longer exists in your version of Premiere, or one of its settings cannot be set through Adobe's plugin API. The rest is applied. |
| A preset is missing from the palette | It uses a mask shape, or Lumetri curves, color wheels or a LUT, which Adobe's plugin API cannot set: Khanjar leaves it out rather than apply it wrong. Lumetri presets that only move sliders are included. Audio-only presets are not supported yet. |
| Your presets are missing | System Settings > Privacy & Security > Files and Folders > Khanjar: enable **Documents**. |

Still stuck? Menu bar icon > **Open log**, and [open an issue](https://github.com/Apocale/khanjar/issues)
with the last lines (check them first for clip or project names you do not want to share).

## Uninstall

1. Menu bar icon > **Quit Khanjar**. Turn off launch at login, then move **Khanjar.app** to the Trash:
   ```bash
   /Applications/Khanjar.app/Contents/MacOS/Khanjar login-item off
   ```
   (If Khanjar is in ~/Applications, replace /Applications with ~/Applications.)
2. Remove the plugin from Premiere (Premiere can stay open):
   ```bash
   "/Library/Application Support/Adobe/Adobe Desktop Common/RemoteComponents/UPI/UnifiedPluginInstallerAgent/UnifiedPluginInstallerAgent.app/Contents/MacOS/UnifiedPluginInstallerAgent" --remove "Khanjar"
   ```
   If it answers -406 (the plugin is already unknown to Adobe), delete its folder:
   ```bash
   rm -rf ~/Library/Application\ Support/Adobe/UXP/Plugins/External/io.khanjar.executor_*
   ```
3. Optional, to remove settings, history and update data:
   ```bash
   rm -rf ~/Library/Application\ Support/Khanjar ~/Library/Logs/Khanjar ~/Library/Caches/io.khanjar.app ~/Library/HTTPStorages/io.khanjar.app ~/Library/HTTPStorages/io.khanjar.app.binarycookies
   rm -rf ~/Library/Application\ Support/Adobe/UXP/PluginsStorage/PPRO/*/External/io.khanjar.executor
   defaults delete io.khanjar.app
   tccutil reset SystemPolicyDocumentsFolder io.khanjar.app
   ```
4. Had the old "Dagger" version? Remove "Dagger" from System Settings > General > Login Items, move
   /Applications/Dagger.app to the Trash, run the command of step 2 with `--remove "Dagger Executor"`, and
   delete `~/Library/Application Support/Dagger` and `~/Library/Logs/Dagger`.
