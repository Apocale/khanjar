# Installer Khanjar

Environ 3 minutes. [English version](INSTALL.md)

## Avant de commencer

- Un Mac avec puce Apple (M1 ou plus récent), sous macOS 13 ou plus récent.
- Adobe Premiere Pro 2026 (26.x) ou plus récent.
- L'app Creative Cloud, connectée à ton compte. Khanjar s'en sert pour installer son plugin dans Premiere.

**Tu avais l'ancienne version « Dagger » ?** Avant d'installer Khanjar, quitte Dagger, retire « Dagger » de
Réglages Système > Général > Ouverture et mets /Applications/Dagger.app à la corbeille. Ne supprime pas ses
données : Khanjar reprend tes réglages, ton historique et tes raccourcis. Il retire aussi tout seul l'ancien
plugin Dagger de Premiere (sinon : *Désinstaller*, point 4).

## Installer avec Claude Code (le plus simple)

Si tu as [Claude Code](https://claude.com/claude-code) sur ton Mac, colle-lui ce message : il fait toute l'installation, une étape après l'autre. Il te demandera une fois de quitter Premiere (enregistre ton travail avant). Le téléchargement passant par le terminal, macOS ne demande pas « Ouvrir quand même ».

```text
Installe-moi Khanjar, un plugin gratuit pour Adobe Premiere Pro (https://github.com/Apocale/khanjar).

Règles :
- Ne touche à aucun de mes projets Premiere, ne ferme jamais Premiere toi-même, n'utilise jamais sudo.
- N'écris PAS de script d'installation : lance les commandes ci-dessous une par une, recopiées telles quelles, et résume chaque étape en une ligne. Laisse à chaque commande un délai (timeout) de 5 minutes ; aucune ne devrait dépasser 2 minutes.
- Quand une étape dit « demande-moi », arrête-toi et attends ma réponse dans ce chat (pas de read ni de sleep pour m'attendre).
- Chaque commande repart d'un shell neuf : elle redéfinit elle-même les variables dont elle a besoin.
- Si une commande échoue à cause du bac à sable de Claude Code (« Operation not permitted », erreur -54…), propose-moi de la relancer hors du bac à sable.
- Si l'étape 4 installe l'app dans ~/Applications, remplace /Applications/Khanjar.app par "$HOME/Applications/Khanjar.app" dans les commandes suivantes.

1. Prérequis — arrête-toi en m'expliquant si l'un manque :
   - puce Apple : `sysctl -n hw.optional.arm64` doit répondre 1 (pas `uname -m`, qui répond x86_64 sous Rosetta) ;
   - macOS 13 ou plus récent : `sw_vers -productVersion` ;
   - Premiere Pro 2026 ou plus récent : trouve l'app avec `mdfind "kMDItemCFBundleIdentifier == 'com.adobe.PremierePro.*'"` (si rien ne sort, cherche dans /Applications un dossier « Adobe Premiere Pro 20xx ») et lis sa version avec `/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "<app>/Contents/Info.plist"`. 26.x (Premiere Pro 2026) : version testée. 27 ou plus : dis-moi qu'elle n'est pas encore testée, et continue. Moins de 26 : arrête-toi (Khanjar demande Premiere Pro 2026 ou plus récent) ;
   - Creative Cloud : le fichier "/Library/Application Support/Adobe/Adobe Desktop Common/RemoteComponents/UPI/UnifiedPluginInstallerAgent/UnifiedPluginInstallerAgent.app/Contents/MacOS/UnifiedPluginInstallerAgent" doit exister, et `ps -axo comm= | grep -E 'Adobe Desktop Service|MacOS/Creative Cloud$'` doit sortir au moins une ligne. Sinon, demande-moi d'ouvrir l'app Creative Cloud et de vérifier que je suis connecté, puis revérifie ;
   - ancienne version « Dagger » : si /Applications/Dagger.app existe, dis-le-moi ; avec mon accord, quitte-la si `pgrep -x Dagger` la trouve (`osascript -e 'quit app "Dagger"'`), demande-moi de retirer « Dagger » de Réglages Système > Général > Ouverture, puis mets-la à la corbeille (`mv /Applications/Dagger.app ~/.Trash/`). Ne touche pas à ~/Library/Application Support/Dagger : Khanjar y reprend mes réglages.

2. Télécharge la dernière version dans un dossier temporaire (pas dans Téléchargements) :
      W="${TMPDIR:-/tmp}/khanjar-install"; mkdir -p "$W"
      FEED=$(curl -fsSL --retry 3 --max-time 30 https://github.com/Apocale/khanjar/releases/latest/download/appcast.xml)
      URL=$(printf '%s' "$FEED" | sed -n 's/.*enclosure url="\([^"]*\)".*/\1/p' | head -1)
      LEN=$(printf '%s' "$FEED" | sed -n 's/.*length="\([0-9]*\)".*/\1/p' | head -1)
      echo "$URL attendu=$LEN"; curl -fL --retry 3 --max-time 90 -o "$W/Khanjar.zip" "$URL"; stat -f%z "$W/Khanjar.zip"
   La taille obtenue doit être égale à « attendu ». Si le flux ne répond pas, prends l'adresse du .zip (browser_download_url, pas appcast.xml) dans `curl -s https://api.github.com/repos/Apocale/khanjar/releases/latest`.

3. Décompresse et contrôle :
      W="${TMPDIR:-/tmp}/khanjar-install"; rm -rf "$W/x"; mkdir -p "$W/x"; ditto -x -k "$W/Khanjar.zip" "$W/x"
      /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' -c 'Print :CFBundleShortVersionString' "$W/x/Khanjar.app/Contents/Info.plist"
      codesign --verify --deep --strict "$W/x/Khanjar.app" && echo SIGNATURE-OK
   Il faut « io.khanjar.app » et SIGNATURE-OK ; sinon arrête-toi.

4. Installe l'app :
   - quitte Khanjar s'il tourne déjà :
      if pgrep -x Khanjar >/dev/null; then osascript -e 'quit app "Khanjar"'; i=0; while pgrep -x Khanjar >/dev/null && [ $i -lt 10 ]; do sleep 1; i=$((i+1)); done; pkill -x Khanjar; fi; pgrep -x Khanjar || echo KHANJAR-FERME
   - dossier : /Applications si `[ -w /Applications ]` réussit, sinon ~/Applications (crée-le) ;
   - s'il existe déjà un Khanjar.app dans /Applications ou ~/Applications, dis-moi sa version, puis mets-le à la corbeille : `mv "<dossier>/Khanjar.app" ~/.Trash/Khanjar-ancien-$(date +%s).app`. Si c'est refusé, demande-moi de le glisser moi-même à la corbeille dans le Finder ;
   - copie avec ditto (jamais cp vers un dossier qui existe) : `ditto "${TMPDIR:-/tmp}/khanjar-install/x/Khanjar.app" "<dossier>/Khanjar.app"`, puis `codesign --verify --deep --strict "<dossier>/Khanjar.app" && echo SIGNATURE-OK`.

5. Installe le plugin dans Premiere, avec Premiere FERMÉ :
   - si `ps -axo comm= | grep '/Contents/MacOS/Adobe Premiere Pro'` sort une ligne, Premiere est ouvert : demande-moi d'enregistrer mon travail et de quitter Premiere (⌘Q) ; attends ma réponse et vérifie qu'il est bien fermé (sinon redemande-moi) ;
   - liste les plugins connus d'Adobe (60 s au plus) :
      UPIA="/Library/Application Support/Adobe/Adobe Desktop Common/RemoteComponents/UPI/UnifiedPluginInstallerAgent/UnifiedPluginInstallerAgent.app/Contents/MacOS/UnifiedPluginInstallerAgent"
      perl -e 'alarm 60; exec @ARGV' -- "$UPIA" --list all
     Si « Khanjar » y figure, retire-le avec la même commande en remplaçant `--list all` par `--remove "Khanjar"` ; si « Dagger Executor » y figure, de même avec `--remove "Dagger Executor"` (une réponse -406 est sans conséquence) ;
   - puis installe le plugin (100 s au plus) :
      UPIA="/Library/Application Support/Adobe/Adobe Desktop Common/RemoteComponents/UPI/UnifiedPluginInstallerAgent/UnifiedPluginInstallerAgent.app/Contents/MacOS/UnifiedPluginInstallerAgent"
      perl -e 'alarm 100; exec @ARGV' -- "$UPIA" --install "/Applications/Khanjar.app/Contents/Resources/khanjar-executor.ccx"
     La sortie doit contenir « Successful ». Contrôle ensuite l'inscription : `grep -o '"pluginId":"io.khanjar.executor"[^}]*' "$HOME/Library/Application Support/Adobe/UXP/PluginsInfo/v1/premierepro.json"` doit montrer "status":"enabled" (s'il ne montre rien malgré « Successful », dis-le-moi et continue). Sans « Successful » : montre-moi la sortie, demande-moi de quitter puis rouvrir l'app Creative Cloud, et relance ce --install une seule fois (des essais rapprochés bloquent l'installateur d'Adobe).

6. Lance Khanjar (Premiere toujours fermé) :
      W="${TMPDIR:-/tmp}/khanjar-install"; LOG="$HOME/Library/Logs/Khanjar/Khanjar.log"; mkdir -p "$W"
      { stat -f%z "$LOG" 2>/dev/null || echo 0; } > "$W/offset"; open "/Applications/Khanjar.app"
   (Sur un Mac neuf, le journal n'existe pas encore : c'est normal, la position notée vaut 0.)
   Préviens-moi : une fenêtre « Bienvenue dans Khanjar » (« Welcome to Khanjar » si mon Mac est en anglais) s'ouvre, je peux cliquer « Commencer » ; et macOS peut demander l'accès à mon dossier Documents : je clique « Autoriser » (mes presets y sont).

7. Demande-moi d'ouvrir Premiere Pro et de te répondre quand sa fenêtre principale est affichée (le tout premier lancement sur un Mac neuf peut prendre plusieurs minutes). Puis vérifie la connexion avec cette commande, recopiée telle quelle (90 s au plus ; relance-la tant qu'elle répond ATTENTE, 3 fois maximum) :
      W="${TMPDIR:-/tmp}/khanjar-install"; LOG="$HOME/Library/Logs/Khanjar/Khanjar.log"
      OFF=$(cat "$W/offset" 2>/dev/null || echo 0); R=ATTENTE; i=0
      while [ $i -lt 18 ]; do i=$((i+1))
        S=$( { stat -f%z "$LOG" 2>/dev/null || echo 0; } ); [ "$S" -lt "$OFF" ] && OFF=0
        NEW=$(tail -c +$((OFF+1)) "$LOG" 2>/dev/null)
        if printf '%s\n' "$NEW" | grep -q 'hello : io\.khanjar\.executor'; then R=CONNECTE; break; fi
        sleep 5
      done
      echo "$R"; printf '%s\n' "$NEW" | grep -E 'hello : |UPIA|Plugin |Dagger|refusée|origine|invalide|Bridge|Listener|instance' | tail -8
   CONNECTE : passe à l'étape 9. Toujours ATTENTE après 3 essais : étape 8.
   (Le motif « hello : » a une espace avant les deux-points : ne la retire pas.)

8. Dépannage, dans l'ordre, en relançant la vérification de l'étape 7 après chaque action :
   a. demande-moi de cliquer dans la fenêtre de Premiere puis de presser ⌘J une fois (Khanjar relance alors sa propre réparation) ;
   b. demande-moi d'enregistrer, de quitter Premiere (⌘Q), de le rouvrir et de te dire quand sa fenêtre est affichée ;
   c. toujours rien : lance ce diagnostic et montre-moi tout le résultat (je l'enverrai à Isma après l'avoir relu : il peut contenir des noms de presets, de dossiers ou mon nom d'utilisateur) :
      LOG="$HOME/Library/Logs/Khanjar/Khanjar.log"; AS="$HOME/Library/Application Support/Adobe"
      UPIA="/Library/Application Support/Adobe/Adobe Desktop Common/RemoteComponents/UPI/UnifiedPluginInstallerAgent/UnifiedPluginInstallerAgent.app/Contents/MacOS/UnifiedPluginInstallerAgent"
      echo "== Mac"; sw_vers -productVersion; sysctl -n hw.optional.arm64
      echo "== Khanjar"; for a in /Applications/Khanjar.app "$HOME/Applications/Khanjar.app"; do [ -d "$a" ] && echo "$a $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$a/Contents/Info.plist")"; done; pgrep -lx Khanjar
      echo "== Premiere"; ps -axo pid=,comm= | grep '/Contents/MacOS/Adobe Premiere Pro' | cut -c1-120
      echo "== Port"; lsof -nP -iTCP:48123
      echo "== Journal de Khanjar"; grep -E 'UPIA|Plugin |hello|Dagger|Bridge|Listener|Port|refusée|origine|invalide|Creative|instance|Expulsion|Premiere|prêt' "$LOG" | tail -40
      echo "== Journal d'UPIA"; tail -40 "$AS/UPI/Log/Upia.log"
      echo "== Registre des plugins"; cat "$AS/UXP/PluginsInfo/v1/premierepro.json"; echo; ls "$AS/UXP/Plugins/External/"
      echo "== Journal du plugin"; find "$AS/UXP/PluginsStorage" -name 'khanjar-executor*.log' -print -exec tail -15 {} \;
      echo "== Adobe"; perl -e 'alarm 60; exec @ARGV' -- "$UPIA" --list all 2>&1 | head -60
      echo "== Creative Cloud"; ps -axo pid=,comm= | grep -E 'Adobe Desktop Service|MacOS/Creative Cloud$' | cut -c1-120
      echo "== localhost"; grep -i localhost /etc/hosts

9. Active le démarrage automatique : `"/Applications/Khanjar.app/Contents/MacOS/Khanjar" login-item on`, et répète-moi la fin de la dernière ligne (« activé » ; si elle dit « en attente de ton accord », guide-moi dans Réglages Système > Général > Ouverture).

10. Vérification visible : demande-moi de cliquer l'icône baguette magique en haut à droite de l'écran : la 2ᵉ ligne du menu doit dire « Connecté — Premiere … · plugin … » (« Connected — … » si mon Mac est en anglais). Puis, dans Premiere, de presser ⌘J : la palette doit s'ouvrir (Échap la referme).

11. Supprime le dossier temporaire (`rm -rf "${TMPDIR:-/tmp}/khanjar-install"`), puis termine en m'expliquant en 4 lignes : dans Premiere, ⌘J ouvre la palette, je tape le nom d'un effet ou d'un preset, Entrée l'applique aux clips sélectionnés ; ⌘⇧J pose un calque d'effets à la tête de lecture (il faut en avoir créé un une fois dans le projet : Fichier > Nouveau > Calque d'effets) ; au prochain lancement, Khanjar demandera s'il peut vérifier les mises à jour tout seul : je réponds oui.
```

Sinon, suis les étapes ci-dessous à la main.

## 1. Télécharger et ranger l'app

1. Télécharge `Khanjar-<version>.zip` (pas `appcast.xml`) depuis la [dernière version](https://github.com/Apocale/khanjar/releases/latest).
2. Double-clique le zip pour le décompresser.
3. Glisse **Khanjar.app** dans ton dossier **Applications**.

## 2. Premier lancement (bêta pas encore signée par Apple)

macOS bloque la première fois les apps qui ne sont pas validées par Apple. Tu confirmes une fois, plus jamais ensuite.

**macOS 15 Sequoia et plus récent**
1. Double-clique **Khanjar** dans Applications. macOS dit qu'il n'a pas pu vérifier l'app : clique **Terminé** (pas « Placer dans la corbeille »).
2. Ouvre **Réglages Système > Confidentialité et sécurité** et descends jusqu'à **Sécurité**.
3. À côté de *« Khanjar » a été bloqué*, clique **Ouvrir quand même**, confirme avec ton mot de passe,
   puis reclique sur **Ouvrir quand même** dans la fenêtre qui s'ouvre.

**macOS 14 et plus ancien**
Clic droit sur **Khanjar** dans Applications > **Ouvrir** > **Ouvrir**.

## 3. Laisser Khanjar s'installer

1. Une icône en forme de baguette magique apparaît dans la barre de menus, et une fenêtre d'accueil s'ouvre.
   Coche **Lancer Khanjar au démarrage de la session** (décochée par défaut), pour que Khanjar soit prêt
   après un redémarrage, puis clique **Commencer**.
2. macOS peut demander l'accès à ton dossier **Documents** : clique **Autoriser**.
   Tes propres presets Premiere y sont rangés ; sans cet accès, ils manquent dans la palette.
3. Si Premiere est ouvert, Khanjar y installe son plugin tout seul : en deux minutes au plus, la 2ᵉ ligne
   du menu de l'icône baguette magique affiche *Connecté — Premiere … · plugin …*. Sinon, enregistre ton
   travail, quitte Premiere (⌘Q) et rouvre-le. Si Premiere est fermé, ça se fera à sa prochaine ouverture.

## 4. L'utiliser

Dans Premiere Pro, sélectionne un ou plusieurs clips dans la timeline, presse **⌘J**, tape quelques lettres, presse **Entrée**.

- **⌘1 … ⌘0** : applique directement un de tes items les plus utilisés, depuis la palette vide.
- **⌘⇧J** : ajoute un calque d'effets à la tête de lecture. Crées-en un une fois dans ton projet
  (*Fichier > Nouveau > Calque d'effets*) : Khanjar le réutilise.
- Raccourcis, thème, nombre de résultats : icône de la barre de menus > **Réglages…**

## Mises à jour

Au deuxième lancement, Khanjar demande s'il peut vérifier les mises à jour automatiquement : dis oui,
et Khanjar te propose chaque nouvelle version (coche *Télécharger et installer automatiquement* pour ne plus
avoir la question ; les mises à jour sont signées : seules les vraies versions de Khanjar
sont acceptées). Tu peux aussi passer par l'icône de la barre de menus > **Rechercher les mises à jour…**.
Après une mise à jour, macOS peut redemander l'accès à ton dossier Documents : clique **Autoriser**
(ça disparaîtra quand Khanjar sera signé par Apple). Quand une mise à jour apporte aussi un nouveau
plugin pour Premiere, Khanjar l'installe pendant que Premiere est fermé : tu continues avec l'actuel, et
le nouveau est là au prochain lancement de Premiere.

Une copie de Khanjar antérieure à 0.8.2 (1ʳᵉ ligne du menu : « Khanjar 0.8.0 » ou « Khanjar 0.8.1 ») ne sait
pas se mettre à jour : réinstalle-la avec le prompt Claude Code ou les étapes ci-dessus. Les anciennes
versions « Dagger » non plus (voir *Avant de commencer*).

## En cas de souci

| Ce que tu vois | Quoi faire |
|---|---|
| Deux minutes après l'installation, le menu de l'icône n'affiche toujours pas *Connecté — Premiere …* | Enregistre, quitte Premiere (⌘Q) et rouvre-le. Toujours rien 2 minutes après ? Icône de la barre de menus > **Ouvrir le journal**, et envoie les lignes qui contiennent « UPIA » ou « hello ». |
| « Khanjar se reconnecte à Premiere… » (ou « Ouvre Premiere Pro pour utiliser Khanjar ») alors que Premiere est ouvert | Attends 1 minute (Khanjar réinstalle son plugin tout seul). Toujours là ? Quitte et rouvre Premiere. |
| « Creative Cloud requis pour installer le plugin Khanjar » | Installe l'app Creative Cloud, connecte-toi, puis relance Khanjar. |
| ⌘J ne fait rien | Khanjar ne réagit que quand Premiere est l'app active. Vérifie que l'icône en forme de baguette magique est dans la barre de menus (après un redémarrage, ouvre Khanjar depuis Applications). |
| Un preset est marqué *partiel* | Un de ses effets n'existe plus dans ta version de Premiere, ou un de ses réglages ne peut pas être posé par l'API d'Adobe. Le reste est appliqué. |
| Un preset manque dans la palette | Il utilise une forme de masque, ou des courbes, roues ou LUT Lumetri, que l'API d'Adobe ne permet pas de poser : Khanjar l'écarte plutôt que de l'appliquer de travers. Les presets Lumetri qui ne bougent que des curseurs sont bien là. Les presets uniquement audio ne sont pas encore gérés. |
| Tes presets n'apparaissent pas | Réglages Système > Confidentialité et sécurité > Fichiers et dossiers > Khanjar : active **Documents**. |

Toujours bloqué ? Icône de la barre de menus > **Ouvrir le journal**, et [ouvre un ticket](https://github.com/Apocale/khanjar/issues)
avec les dernières lignes (relis-les d'abord : elles peuvent contenir des noms de clips ou de projets).

## Désinstaller

1. Icône de la barre de menus > **Quitter Khanjar**. Désactive le lancement à l'ouverture de session, puis
   mets **Khanjar.app** à la corbeille :
   ```bash
   /Applications/Khanjar.app/Contents/MacOS/Khanjar login-item off
   ```
   (Si Khanjar est dans ~/Applications, remplace /Applications par ~/Applications.)
2. Retire le plugin de Premiere (Premiere peut rester ouvert) :
   ```bash
   "/Library/Application Support/Adobe/Adobe Desktop Common/RemoteComponents/UPI/UnifiedPluginInstallerAgent/UnifiedPluginInstallerAgent.app/Contents/MacOS/UnifiedPluginInstallerAgent" --remove "Khanjar"
   ```
   S'il répond -406 (plugin déjà inconnu d'Adobe), supprime son dossier :
   ```bash
   rm -rf ~/Library/Application\ Support/Adobe/UXP/Plugins/External/io.khanjar.executor_*
   ```
3. Facultatif, pour effacer réglages, historique et données de mise à jour :
   ```bash
   rm -rf ~/Library/Application\ Support/Khanjar ~/Library/Logs/Khanjar ~/Library/Caches/io.khanjar.app ~/Library/HTTPStorages/io.khanjar.app ~/Library/HTTPStorages/io.khanjar.app.binarycookies
   rm -rf ~/Library/Application\ Support/Adobe/UXP/PluginsStorage/PPRO/*/External/io.khanjar.executor
   defaults delete io.khanjar.app
   tccutil reset SystemPolicyDocumentsFolder io.khanjar.app
   ```
4. Tu avais l'ancienne version « Dagger » ? Retire « Dagger » de Réglages Système > Général > Ouverture, mets
   /Applications/Dagger.app à la corbeille, lance la commande du point 2 avec `--remove "Dagger Executor"`, et
   supprime `~/Library/Application Support/Dagger` et `~/Library/Logs/Dagger`.
