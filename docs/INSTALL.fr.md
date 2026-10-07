# Installer Khanjar

Environ 3 minutes. [English version](INSTALL.md)

## Avant de commencer

- Un Mac avec puce Apple (M1 ou plus récent).
- Adobe Premiere Pro 2026 (26.x).
- L'app Creative Cloud, connectée à ton compte. Khanjar s'en sert pour installer son plugin dans Premiere.

## Installer avec Claude Code (le plus simple)

Si tu as [Claude Code](https://claude.com/claude-code) sur ton Mac, colle-lui ce message : il fait toute l'installation. Le téléchargement passant par le terminal, macOS ne demande pas « Ouvrir quand même ».

```text
Installe-moi Khanjar, un plugin gratuit pour Adobe Premiere Pro (https://github.com/Apocale/khanjar).
Ne touche à aucun de mes projets Premiere, n'utilise jamais sudo, et dis-moi chaque étape en une ligne.

1. Vérifie les prérequis et arrête-toi en m'expliquant si l'un manque :
   - Mac Apple Silicon : `uname -m` doit répondre arm64 ;
   - Premiere Pro 2026 installé : /Applications/Adobe Premiere Pro 2026 ;
   - app Creative Cloud installée : ce fichier doit exister :
     "/Library/Application Support/Adobe/Adobe Desktop Common/RemoteComponents/UPI/UnifiedPluginInstallerAgent/UnifiedPluginInstallerAgent.app/Contents/MacOS/UnifiedPluginInstallerAgent"

2. Télécharge la dernière version : récupère l'adresse du .zip avec
   `curl -s https://api.github.com/repos/Apocale/khanjar/releases/latest`
   (champ browser_download_url qui finit par .zip, pas appcast.xml), puis télécharge-le avec
   `curl -fL -o ~/Downloads/Khanjar.zip "<cette adresse>"`.

3. Décompresse-le dans un dossier temporaire neuf : `ditto -x -k ~/Downloads/Khanjar.zip "$(mktemp -d)"`.
   Si Khanjar tourne déjà, quitte-le d'abord : `osascript -e 'quit app "Khanjar"'`.
   Place Khanjar.app dans /Applications (remplace une ancienne version après me l'avoir dit).
   Si /Applications n'est pas modifiable sans sudo, arrête-toi et dis-le-moi.

4. Demande-moi d'ouvrir Premiere Pro, attends ma confirmation, puis lance : `open /Applications/Khanjar.app`.
   Préviens-moi que macOS peut demander l'accès à mon dossier Documents : je dois cliquer « Autoriser »
   (c'est là que sont mes presets).

5. Vérifie que ça marche : avant l'étape 4, note le nombre de lignes de ~/Library/Logs/Khanjar/Khanjar.log
   (0 s'il n'existe pas). Après l'étape 4, une NOUVELLE ligne contenant « hello : io.khanjar.executor »
   doit apparaître dans les 3 minutes (l'installation du plugin peut prendre ce temps).
   Si rien après 3 minutes, demande-moi de quitter et rouvrir Premiere, puis revérifie.
   Si ça bloque encore, montre-moi les 20 dernières lignes du journal.

6. Active le démarrage automatique :
   `/Applications/Khanjar.app/Contents/MacOS/Khanjar login-item on`

7. Termine en m'expliquant en 4 lignes : dans Premiere, ⌘J ouvre la palette, je tape le nom d'un effet
   ou d'un preset, Entrée l'applique aux clips sélectionnés ; ⌘⇧J pose un calque d'effets à la tête de
   lecture (il faut en avoir créé un une fois dans le projet : Fichier > Nouveau > Calque d'effets).
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
3. Si Premiere est ouvert, Khanjar y installe son plugin tout seul. Sinon, ça se fera à sa prochaine ouverture.

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
(ça disparaîtra quand Khanjar sera signé par Apple).

## En cas de souci

| Ce que tu vois | Quoi faire |
|---|---|
| « Khanjar se reconnecte à Premiere… » (ou « Ouvre Premiere Pro pour utiliser Khanjar ») alors que Premiere est ouvert | Attends 1 minute (Khanjar réinstalle son plugin tout seul). Toujours là ? Quitte et rouvre Premiere. |
| « Creative Cloud requis pour installer le plugin Khanjar » | Installe l'app Creative Cloud, connecte-toi, puis relance Khanjar. |
| ⌘J ne fait rien | Khanjar ne réagit que quand Premiere est l'app active. Vérifie que l'icône en forme de baguette magique est dans la barre de menus (après un redémarrage, ouvre Khanjar depuis Applications). |
| Un preset est marqué *partiel* | Un de ses effets n'existe plus dans ta version de Premiere, ou un de ses réglages ne peut pas être posé par l'API d'Adobe. Le reste est appliqué. |
| Un preset manque dans la palette | Il utilise une forme de masque, ou des courbes, roues ou LUT Lumetri, que l'API d'Adobe ne permet pas de poser : Khanjar l'écarte plutôt que de l'appliquer de travers. Les presets Lumetri qui ne bougent que des curseurs sont bien là. Les presets uniquement audio ne sont pas encore gérés. |
| Tes presets n'apparaissent pas | Réglages Système > Confidentialité et sécurité > Fichiers et dossiers > Khanjar : active **Documents**. |

Toujours bloqué ? Icône de la barre de menus > **Ouvrir le journal**, et [ouvre un ticket](https://github.com/Apocale/khanjar/issues)
avec les dernières lignes (relis-les d'abord : elles peuvent contenir des noms de clips ou de projets).

## Désinstaller

1. Icône de la barre de menus > **Quitter Khanjar**, puis mets **Khanjar.app** à la corbeille.
2. Retire le plugin de Premiere (Premiere peut rester ouvert) :
   ```bash
   "/Library/Application Support/Adobe/Adobe Desktop Common/RemoteComponents/UPI/UnifiedPluginInstallerAgent/UnifiedPluginInstallerAgent.app/Contents/MacOS/UnifiedPluginInstallerAgent" --remove "Khanjar"
   ```
3. Facultatif, pour effacer tes réglages et ton historique :
   ```bash
   rm -rf ~/Library/Application\ Support/Khanjar ~/Library/Logs/Khanjar
   ```
