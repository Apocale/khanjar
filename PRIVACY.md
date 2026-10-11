# Privacy

Khanjar is built to keep your work on your Mac.

## What stays on your Mac

Everything you do with Khanjar: your presets, your clips, your projects, your search history and
the list of items you use most (`~/Library/Application Support/Khanjar/`).

## The local connection to Premiere

Khanjar and its plugin inside Premiere Pro talk over a local connection (port 48123 on the loopback
addresses `127.0.0.1` and `::1`) that nothing outside your Mac can reach. Khanjar refuses every connection that announces a web
origin, which covers anything a web page or a browser extension can open (browsers always announce
one).

It does not identify the other programs on your Mac: a program that announces no origin is
accepted, including one running under another macOS user account on the same Mac. Such a program
could see which presets you apply and stop ⌘J from working; if it took the connection before
Khanjar starts, it could also send commands to the plugin in Premiere (read the names of the
selected clips, add effects). On a Mac shared by several people, keep this in mind.

## Update checks (optional)

On its second launch, Khanjar asks whether it may check for updates automatically. If you agree,
it downloads the list of releases (`appcast.xml`) from GitHub about once a day. Like any web request,
this reveals your IP address to GitHub; nothing else is sent. Updates are signed: Khanjar refuses
any file that was not signed with the Khanjar release key. You can also check manually from the
menu bar icon (*Check for Updates…*).
