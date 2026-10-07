# Installer Khanjar

Environ 3 minutes. [English version](INSTALL.md)

## Avant de commencer

- Un Mac avec puce Apple (M1 ou plus récent).
- Adobe Premiere Pro 2026 (26.x).
- L'app Creative Cloud, connectée à ton compte. Khanjar s'en sert pour installer son plugin dans Premiere.

## 1. Télécharger et ranger l'app

1. Télécharge `Khanjar.zip` depuis la [dernière version](https://github.com/Apocale/khanjar/releases/latest).
2. Double-clique le zip pour le décompresser.
3. Glisse **Khanjar.app** dans ton dossier **Applications**.

## 2. Premier lancement (bêta pas encore signée par Apple)

macOS bloque la première fois les apps qui ne sont pas validées par Apple. Tu confirmes une fois, plus jamais ensuite.

**macOS 15 Sequoia et plus récent**
1. Double-clique **Khanjar** dans Applications. macOS dit qu'il n'a pas pu vérifier l'app : clique **Terminé** (pas « Placer dans la corbeille »).
2. Ouvre **Réglages Système > Confidentialité et sécurité** et descends jusqu'à **Sécurité**.
3. À côté de *« Khanjar » a été bloqué*, clique **Ouvrir quand même**, puis confirme avec ton mot de passe.

**macOS 14 et plus ancien**
Clic droit sur **Khanjar** dans Applications > **Ouvrir** > **Ouvrir**.

## 3. Laisser Khanjar s'installer

1. Une icône ✦ apparaît dans la barre de menus, et une fenêtre d'accueil s'ouvre.
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
et les nouvelles versions s'installent toutes seules (signées : seules les vraies versions de Khanjar
sont acceptées). Tu peux aussi passer par l'icône de la barre de menus > **Rechercher les mises à jour…**.
Après une mise à jour, macOS peut redemander l'accès à ton dossier Documents : clique **Autoriser**
(ça disparaîtra quand Khanjar sera signé par Apple).

## En cas de souci

| Ce que tu vois | Quoi faire |
|---|---|
| « Ouvre Premiere Pro pour utiliser Khanjar » alors que Premiere est ouvert | Attends 1 minute (Khanjar réinstalle son plugin tout seul). Toujours là ? Quitte et rouvre Premiere. |
| « Creative Cloud requis pour installer le plugin Khanjar » | Installe l'app Creative Cloud, connecte-toi, puis relance Khanjar. |
| ⌘J ne fait rien | Khanjar ne réagit que quand Premiere est l'app active. Vérifie que l'icône ✦ est dans la barre de menus. |
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
