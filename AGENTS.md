# AGENTS.md — Contexte pour agent IA (Khanjar, anciennement Dagger)

> 🔁 **RENOMMÉ le 2026-10-06 : Dagger → Khanjar** (« poignard » en arabe, persan, ourdou).
> « Dagger » est déjà le nom d'une extension Premiere commerciale de Knights of the Editing
> Table — conflit de marque pour une publication. ⚠️ Ne PAS écrire « Kanjar » sans « h » :
> en ourdou et en hindi c'est une insulte (dictionnaire Rekhta).
> Nouveaux identifiants : app `io.khanjar.app` (`Khanjar.app`), plugin `io.khanjar.executor`
> (nom « Khanjar », `khanjar-executor.ccx`), CLI `khanjar`, dossiers `~/Library/Application
> Support/Khanjar` et `~/Library/Logs/Khanjar/Khanjar.log`.
> **Reprise automatique** au 1er lancement (`LegacyMigration`) : settings.json, usage.json,
> index.json et .onboarded sont COPIÉS depuis `…/Application Support/Dagger` (jamais déplacés,
> jamais écrasés). L'app expulse l'ancien `com.dagger.helper` et fait retirer une fois l'ancien
> plugin « Dagger Executor » chez Adobe dès qu'il se présente au pont (refusé : id inattendu).
> Les sections ci-dessous gardent « Dagger » quand elles racontent un fait daté d'avant.

> Fichier de contexte canonique. Lis-le **en entier** avant de modifier quoi que ce soit.
> Il contient du savoir empirique coûteux (des heures de débogage dans Premiere) qui
> n'est déductible ni du code ni de la documentation Adobe.
> Dernière mise à jour : 2026-10-06 — app v0.8.1 (Khanjar) / plugin v0.7.1 — Premiere **26.5.2**.
> Plugin v0.7.1 / app v0.8.1 : **presets d'un Premiere d'une autre langue** — les noms de
> paramètres d'un .prfpset sont localisés, un nom différent ne fait plus sauter le réglage quand
> la structure de l'effet est identique (§3.2 item 7). Profil de presets choisi selon la version
> de Premiere qui tourne, puis le fichier le plus récent (plusieurs profils chez un ami).
> App v0.7.4 : **filet de reprise du plugin** — une mise à jour de Premiere peut effacer
> l'inscription UPIA et laisser ⌘J muet indéfiniment (§6, cas vécu).
> App v0.7.3 : **duos** — deux presets systématiquement enchaînés deviennent UN item
> applicable en une transaction (§4ter).
> App v0.7.2 : la palette s'ouvre sur le classement « fréquence + récence » des items
> réellement appliqués (§4bis), raccourcis ⌘1…⌘0.
> App v0.7.1 : UPIA hors du fil principal + politique d'installation (§6), alias d'effets renommés
> (§3.3), journal des raisons d'échec. Plugin v0.6.8 : la piste AUDIO liée d'une sélection est
> écartée avant l'apply (§3.1 item 14). Plugin 0.6.5/0.6.6 (août) : cuisson d'ease généralisée,
> adaptation au cadrage du clip, garde-fou anti-corruption paramCount.
> ⚠️ Versions DÉCOUPLÉES depuis v0.7.0 : `APP_VERSION` dans `scripts/build-app.sh` (app) ≠
> `plugin/manifest.json` (plugin). Une évolution app-only ne bump PAS le plugin (évite un réinstall
> UPIA inutile). Le bump plugin reste réservé aux changements du ccx.

---

## 1. Le produit en une phrase

**Dagger** est une palette de commande type Spotlight pour **Adobe Premiere Pro 2026 (macOS)** :
⌘J ouvre une fenêtre de recherche floue sur tous les effets et presets ; Entrée applique au(x)
clip(s) sélectionné(s) et referme. ⌘&lt; ajoute un calque d'effets à la tête de lecture.

## 2. Architecture — et pourquoi elle est ainsi

**Deux processus, un protocole WebSocket sur la boucle locale (127.0.0.1:48123).**

```
App native Swift (barre de menus)  ⇄ WebSocket ⇄  Plug-in UXP headless (dans Premiere)
   UI, raccourcis, recherche,                         exécuteur sans état :
   index, parsing des presets                         effets, sélection, apply
```

**Pourquoi pas un simple panneau UXP ?** Contraintes *vérifiées*, non contournables :
- UXP ne permet **pas** d'assigner un raccourci clavier à un panneau (staff Adobe : « no such work planned »).
- Aucune API pour qu'un plug-in **ouvre ou focalise son propre panneau** ; hooks `show()/hide()` cassés.
- Moteur de rendu HTML d'UXP limité (pas adapté à une palette instantanée).

Donc : **toute l'intelligence dans l'app native**, le plug-in n'est qu'un exécuteur. Il est
volontairement simple car il est **pénible à mettre à jour** (voir §6 UPIA).

- Détails : `docs/ARCHITECTURE.md`
- Contrat du pont : `docs/PROTOCOL.md`
- Fidélité native des presets (format keyframes .prfpset DÉCODÉ, plafond UXP, voies
  presse-papiers/projet-donneur — recherche 2026-07-21, rien d'implémenté) :
  `docs/RECHERCHE-FIDELITE-NATIVE.md`
- Dossier de revue externe (PDF, très détaillé) : `docs/Dagger-Dossier-Technique.pdf`

---

## 3. ⚠️ PIÈGES EMPIRIQUES — À LIRE ABSOLUMENT

Ces points ont chacun coûté des heures. Ne pas les « simplifier » sans preuve.

### 3.1 API UXP 26.3

1. **Les actions de paramètres/keyframes doivent être créées À L'INTÉRIEUR du callback
   `executeTransaction`**, jamais avant. Sinon : `The script object is no longer valid`.
   Symptôme à l'échelle : ~1/3 des paramètres échouent sur 150 clips. C'était LE bug majeur.
   Motif correct :
   ```js
   project.lockedAccess(() => {
     project.executeTransaction((compoundAction) => {
       const comp = chain.getComponentAtIndex(i);   // sync, frais
       const kf = cp.createKeyframe(value);          // créé ICI
       compoundAction.addAction(cp.createSetValueAction(kf, true));
     }, label);
   });
   ```
2. **Lectures async AVANT le verrou, créations sync DANS la transaction.** Les objets UXP
   obtenus via `await` deviennent invalides à travers d'autres `await`.
3. **`createComponent` est async** et doit précéder la transaction → fenêtre de « staleness »
   inévitable. D'où le filet : vérification par clip (relecture du nombre de composants) puis
   réapplication ciblée.
4. **Position d'un keyframe = temps relatif + `await clip.getInPoint()`.**
   ⚠️ Les **images, graphiques, textes et sous-titres ont un point d'entrée par défaut de 1 HEURE**
   (les rushes vidéo = 0). Sans cet ajout, les keyframes atterrissent hors écran → « l'animation ne
   fait rien ». Cause n°1 des presets animés cassés sur les sous-titres.
5. **Mode d'interpolation : DEUX transactions obligatoires** (mesuré le 2026-07-21, v0.6.2).
   `createAddKeyframeAction` et `createSetInterpolationAtKeyframeAction` dans la MÊME action
   composée → le mode ne se pose PAS (keyframes restés linéaires = losanges au lieu de sabliers ;
   c'est la cause des captures « pas comme le natif »). On ne peut pas cibler par le temps un
   keyframe qui n'existe pas encore. Motif correct (celui de l'échantillon officiel Adobe) :
   `lockedAccess { executeTransaction(keyframes) ; executeTransaction(interpolation) }`.
   Vérification : `dumpChain` relit le mode réel (`keyframeModes`) → « bézier (sablier) ».
6. **⚠️ BEZIER ≠ courbe eased.** Mesuré : après passage réussi en bézier, la courbe reste
   **exactement linéaire** (Opacity 13,77/42,54/71,31 vs linéaire 13,78/42,56/71,34 ; Position
   idem à 3e-5 près). Les poignées par défaut sont alignées sur la corde. UXP n'expose AUCUNE API
   de poignées (influence/vitesse/tangentes) — confirmé sur les typings 26.3 ET 26.5-beta.
   Le mode bézier ne change donc que l'ICÔNE, pas le mouvement.
7. **FIDÉLITÉ NATIVE par CUISSON de courbe** (v0.6.3, 2026-07-23) — la solution retenue.
   Puisqu'on ne peut pas poser de poignées, on trace la courbe eased en **keyframes LINÉAIRES
   denses, un par frame** (`sequence.getTimebase()` = ticks/frame ; repli 30 fps). Comme Premiere
   rend frame par frame, le mouvement rendu est **identique au natif par construction**.
   La courbe cible vient du modèle d'ease AE décodé (vitesse/influence par côté, §3.2) évalué
   dans `plugin/src/premiere/ease.js` (bézier temporel pour scalaires ; progression + interp
   linéaire d'axe pour les points — chemin axial exact, courbure spatiale des tangentes différée).
   Déclenché seulement si le segment porte de l'ease ; sinon tracé keyframe-par-keyframe legacy.
   VÉRIFIÉ bout-en-bout (`anchor-test "TR - Apple Appear Up"`) : Opacity 0→14,6→82,6→97,4→100 et
   Position easée (0,505 à 53 % du segment vs 0,520 en linéaire = 7,7 px d'écart) ; les valeurs
   collent au modèle décodé, lui-même validé contre le natif (277,4 vs 277,6 px mesuré à l'écran).
   ⚠️ CONTREPARTIE : le panneau Effect Controls montre ~1 keyframe/frame (≈30 sur 1 s) au lieu de
   2 — le RENDU est natif, l'aspect du panneau non. Réduction possible (échantillonnage adaptatif
   par courbure) = amélioration future, non bloquante. Plafond dur : 240 kf/param (au-delà,
   sous-échantillonnage). L'ancienne piste « façonneurs » (spike `ease-probe`) donnait une ease
   seulement APPROXIMATIVE (21,87 au lieu de 15,6 visé) → abandonnée au profit de la cuisson exacte.
8. **`PointKeyframe` n'a ni `get` ni `setTemporalInterpolationMode`** (26.3) : le mode d'un
   paramètre de POINT (Position…) est illisible par API — seul l'échantillonnage de valeurs
   (`anchor-test <requête> f1,f2,f3`) témoigne de la forme de sa courbe.
9. **`createOverwriteItemAction` / `createInsertProjectItemAction` sont sur
   `ppro.SequenceEditor.getEditor(sequence)`, PAS sur `sequence`.**
10. **Effets intrinsèques non énumérables** : `AE.ADBE Opacity`, `AE.ADBE Motion` n'apparaissent pas
   dans `getMatchNames()` (ils existent déjà sur chaque clip). Il faut poser leurs params sur le
   composant **existant** (voir `existingOperations`). Ordre typique de la chaîne : `[0]=Opacity, [1]=Motion`.
11. **Impossible de créer un calque d'effets** par API (suivi Adobe **DVATA-710**). Dagger réutilise
   un calque existant (séquence puis chutier). Si le projet n'en a aucun → message explicite.
12. Échelles internes variables : l'opacité d'un Drop Shadow est en **0–255** (254 ≈ 100 %).
13. **Les effets se posent AU-DESSUS de tout (juste sous les intrinsèques de tête), jamais en queue.**
    Un effet en queue arrive sous les calques d'un graphique, où il n'agit pas (constaté 2026-07-21).
    On insère via `chain.createInsertComponentAction(component, index)`.
    ⚠️ **v0.6.1 (buguée) : `index` = premier composant AJOUTABLE (`getMatchNames()`).** Sur un
    graphique SANS effet utilisateur, la chaîne est `[Opacity, Motion, Vector Motion, Text]` — AUCUN
    composant n'est ajoutable → l'index retombait en QUEUE → l'effet se posait **après `Text`** → sans
    effet sur le graphique (bug retrouvé par l'utilisateur, capture 2026-07-23).
    ✅ **v0.6.4 (corrigée) : `index` = premier composant HORS intrinsèques de tête.** On saute
    explicitement `TOP_INTRINSICS` = {`AE.ADBE Opacity`, `AE.ADBE Motion`, `AE.ADBE Graphic Group`
    (= « Vector Motion »), `AE.ADBE Time Remapping`} et on insère juste après → toujours AU-DESSUS du
    `Text` (qui est en FIN de chaîne), avec ou sans effet préalable. Ordre réel d'un graphique dumpé
    empiriquement (`khanjar dump-selected`, lit la sélection live) :
    `[0]Opacity [1]Motion [2]Vector Motion(AE.ADBE Graphic Group) [3..]effets user [dernier]Text`.
    Sur un clip vidéo normal `[Opacity, Motion, …]` le résultat est identique à avant (1er non-intrinsèque
    = 1er effet user ou queue) → pas de régression. Sur un clip scratch vierge (image seule) l'index
    vaut le nombre de composants (les harnais `fidelity-test` / `anchor-test`, qui lisent le **dernier**
    composant, restent donc valides). Corollaire : les composants insérés ne sont **plus en
    queue** — `applyParamsPostInsert` les retrouve par suite de matchNames (`locateInserted`), plus
    par `total − N`. Filet : si l'insertion indexée échoue sur un clip, repli en append (tracé
    `INSERT_FELL_BACK_TO_APPEND`). Diagnostic : `khanjar dump-selected` dumpe la chaîne complète
    (index + matchName) de la sélection LIVE — indispensable pour les graphiques, non reproductibles
    en projet scratch.

14. **La sélection contient la piste AUDIO liée** (2026-09-19, 83 faux échecs dans le journal).
    Sélectionner un clip vidéo sonore (rush .mp4, séquence imbriquée) sélectionne AUSSI son
    trackItem audio, du MÊME nom. Cet item audio possède une chaîne de composants (Volume…) :
    `getComponentChain()` ne l'écarte donc pas. Avant v0.6.7 on tentait d'y insérer l'effet vidéo →
    l'insertion échouait, la transaction groupée aussi (repli par-clip = plusieurs Cmd+Z) et le HUD
    annonçait « 1 non appliqué » à chaque clip sonore (« Nested Sequence 112 », « *.wav »…).
    Fix : `classifyTrackItem` (`apply.js`) — `TrackItem.getMediaType()` comparé aux constantes
    `MediaType` (stringifiées), repli sur la chaîne (Opacity/Motion = vidéo ; que des « Internal … »
    = audio), indécis = vidéo + trace `MEDIA_TYPE_UNKNOWN`. Diagnostic : `khanjar
    dump-selected` affiche le type relevé par item.
15. **`api_config.json` n'est PAS exhaustif** (26.5.1) : `SequenceEditor` n'y liste que
    `createAddItem(s)Action`/`createRemoveItemsAction`, alors que `createOverwriteItemAction`
    (utilisé par le calque d'effets) existe toujours dans le binaire (`grep` du Mach-O). Ne jamais
    conclure à la disparition d'une API sur la seule foi de ce fichier — tester au runtime.
    26.5.1 n'apporte AUCUNE API de poignées d'ease (toujours 0 occurrence Ease/Influence/Velocity/
    Tangent) ; `ComponentParam.createRemoveKeyframeRangeAction` et `TransitionFactory` sont là.

16. **Règle réseau du manifeste : ni adresse IP, ni port** (mesuré le 2026-10-06, Premiere 26.5.2,
   mini-plugin de test). `"domains": ["ws://127.0.0.1:48199"]` → `new WebSocket("ws://127.0.0.1:48199")`
   lève « Permission denied to the url … Manifest entry not found ». `"ws://127.0.0.1/"` (sans port) :
   même refus — UXP n'accepte pas les IP. `"ws://localhost/"` → `ws://localhost:48199` s'ouvre
   (le pont n'écoute que 127.0.0.1 : UXP y aboutit en résolvant localhost). La règle sans port couvre
   tous les ports. Le plugin s'annonce avec `Origin: file://`. Détail : après `ws.close()`, l'événement
   `close` arrive ~5 s plus tard (sans conséquence, la session est longue).

### 3.2 Format `.prfpset` (XML `PremiereData`)

0. **ANCRAGE TEMPOREL `<Type>`** (mapping certifié via « Fast Blur In/Out » d'Adobe,
   implémenté et vérifié en v0.6.0) : chaque FilterPreset porte `<Type>` :
   **0 = Échelle** (défaut Adobe, majoritaire : keyframes étirés × durClip/durSource),
   **1 = Ancré à l'entrée** (offsets absolus), **2 = Ancré à la sortie** (collés à la
   fin du clip). `srcDur = AnchorOutPoint − AnchorInPoint`. Formules dans
   `apply.js::keyframeTicks()`. Ignorer Type = 135/263 presets animés faux (le grand
   « ça ne marche pas comme le natif »).
0bis. **Enum d'interpolation des keyframes** (champ 2 du CSV) = kfInterpMode
   ExtendScript : 0=linéaire, 4=hold, 5=bézier (6-8=time remap). Mapper vers les
   constantes runtime `ppro.Keyframe.INTERPOLATION_MODE_*` (valeurs non publiées —
   ne pas coder en dur). **Limite dure UXP : les poignées d'ease
   (influence/vitesse, champs 4-7) et les tangentes spatiales NE SONT PAS
   réglables** — le bézier par défaut est le max de fidélité atteignable.
0ter. **Offsets de keyframes SIGNÉS** : un keyframe peut précéder AnchorInPoint
   (rampe d'entrée) — ne jamais clamper à 0.


1. **La vraie valeur d'un paramètre est le 2ᵉ champ CSV de `<StartKeyframe>`**, PAS `<CurrentValue>`
   qui est souvent obsolète (=0). Erreur classique : Direction=0, Scale=0, Edge Type par défaut.
2. **Les effets sont stockés dans l'ordre INVERSE de la pile affichée** dans FX Control → inverser
   avant d'empiler (validé contre un glisser-déposer natif).
3. **Les valeurs de keyframes peuvent être des POINTS** `"x:y"` (Transform Position, coordonnées
   normalisées 0–1), pas seulement des nombres. Un parseur numérique les jette silencieusement.
4. **Couleurs** : entier 64 bits packé, canaux 16 bits (décodage empirique dans `IndexStore.decodePackedColor`).
5. `ArbVideoComponentParam` : l'API UXP ne sait PAS les écrire, mais ils sont LISIBLES (décodés le
   2026-10-07, `Presets/ArbDecoding.swift`) : valeur en base64 dans `<StartKeyframeValue Encoding="base64">`
   (le parser ne lisait que StartKeyframe/CurrentValue, d'où l'impression d'« opaque »). Lumetri en porte
   TOUJOURS 24, même au neutre : l'ancienne règle « Lumetri avec des Arb ⇒ exclu » écartait donc TOUT
   Lumetri. Règle actuelle (`IndexStore.isReplayableLumetri`) : exclu seulement si un Arb n'est pas à son
   état neutre (courbes, roues, LUT, Auto Tone…, voir la table par ParameterID) ou si un menu Look/Input LUT
   est choisi ; sinon on rejoue les curseurs (ct 8) et cases (ct 4), JAMAIS Color Space (pid 130, dépend
   du clip). Masques : sous-composants `AE.ADBE AEMask`/`AEMask2` ; un tracé à 0 sommet est vide et ne
   compte plus. Effet mesuré : 10 presets d'Isma débloqués (8 Lumetri à curseurs, 2 « Drop Shadow Preset »
   à masque vide), 0 nouvel exclu. Restent exclus : 10 Lumetri à courbes/LUT, 27 vrais masques, les 325
   Lumetri Adobe (ancien schéma à 98 params, ParameterID -1, index de Look ambigus). Diagnostics :
   `khanjar index-excluded`, `khanjar plan-dump "<preset>"`.
6. Structure : `TreeItem`(nom) → `FilterPresetItem` → `FilterPreset`(`FilterMatchName`) → `Component`(params).
   Deux schémas coexistent : conteneur `<FilterPresets>` (presets utilisateur) ou référence directe
   `<FilterPreset ObjectRef>` (presets Adobe du bundle).
7. **Les NOMS de paramètres sont dans la langue du Premiere qui a CRÉÉ le preset** (2026-10-06,
   vérifié sur les presets Adobe du bundle : Motion index 1 = « Scale » en_US, « Echelle » fr_FR,
   « Skalierung » de_DE, « Escala » es_ES…). `<ParameterID>` vaut -1 partout et `ComponentParam`
   n'expose que `displayName` : AUCUN identifiant de paramètre indépendant de la langue.
   Jusqu'au plugin 0.7.0, un nom ≠ suffisait à sauter le paramètre → un pack anglais (le cas de
   tous les packs du commerce relevés sur SSD 2) chez un monteur dont Premiere est en français
   n'appliquait que Position/Rotation : simulé 4/12 réglages d'un Transform, zooms et fondus
   perdus. Jamais vu chez Isma (Premiere en anglais, presets anglais : 0 `NAME_MISMATCH` dans
   le journal). Règle depuis 0.7.1 (`apply.js::buildParamActions`) : noms comparés sans casse,
   accents ni espaces ; s'ils diffèrent encore, la **structure** tranche — même nombre de
   paramètres qu'à l'enregistrement → l'index fait foi, on écrit (compté `namesDiffer`, journal
   `nomsAutreLangue=N`) ; structure différente ou inconnue → sauté comme avant. Limite restante :
   structure différente ET autre langue (ex. Motion 6 params des PiP Adobe, chargés de toute façon
   dans la langue de l'interface) → sauté. Test hors Premiere : `node plugin/test/param-names.test.js`.

### 3.3 Inventaire d'effets et versions de Premiere

- **26.5.1 a retiré 54 effets** de `VideoFilterFactory.getMatchNames()` (162 → 108 ; index 490 → 436
  items le 2026-09-18). Beaucoup de « (Legacy) » remplacés par des effets `AE.Impact_*_FX`.
  Conséquence : 20 presets utilisateur devenaient « partiels » (effet `dropped`).
- **Alias d'effets renommés** (`IndexStore.effectAliases`) : `AE.ADBE Geometry` → `AE.ADBE Geometry2`
  (les deux = « Transform », 12 paramètres identiques, vérifié dans le prfpset) et `PR.ADBE Replicate`
  → `AE.ADBE Replicate`. Appliqué seulement si l'ancien est absent ET le successeur présent ; le
  garde-fou paramCount/nom du plugin protège contre une définition différente. Hint `aliased:N`.
- `AE.ADBE Venetian Blinds` n'a pas de successeur (1 preset partiel). Aperçu sans Premiere :
  `khanjar index-preview`.

---

## 4. Construire, lancer, tester

```bash
# App native (Swift)
cd helper && swift build              # debug
./.build/debug/khanjar selftest # tests du scorer (pas de XCTest sur cette machine : CLT sans Xcode)

# Bundle complet (app + plug-in embarqué) → dist/Khanjar.app
./scripts/build-app.sh
open dist/Khanjar.app                  # l'app est en barre de menus (LSUIElement, pas de Dock)

# Plug-in seul → .ccx + installation à chaud dans Premiere
./scripts/build-plugin.sh --install
```

### Modes CLI du helper (outils de diagnostic — très utiles)

| Commande | Rôle |
|---|---|
| `khanjar app` | Mode produit (défaut) |
| `khanjar selftest` | Tests du scorer, hors ligne |
| `khanjar index-presets` | Test du parseur `.prfpset`, hors ligne |
| `khanjar index-build` | Construit l'index (requiert Premiere + plug-in) |
| `khanjar search "<requête>"` | Recherche hors ligne dans le snapshot |
| `khanjar smoke [--apply]` | Test bout-en-bout du pont |
| `khanjar multi-test "<preset>"` | **Crée N clips, les sélectionne, applique, vérifie par clip** |
| `khanjar apply-dump <media> "<preset>"` | Applique puis **vide toute la chaîne d'effets** (ordre + valeurs) |
| `khanjar adj-test` | Test du calque d'effets |
| `khanjar anchor-test "<preset>" [--component <matchName>] [f1,f2,…]` | **Vérifie l'ancrage temporel** : échantillonne le dernier composant (ou celui désigné) à 2/50/98 % de la durée du clip. Les fractions doivent contenir une virgule |
| `khanjar dump-selected` | Chaîne complète + **type de média (vidéo/audio)** de chaque item de la sélection LIVE |
| `khanjar index-preview` | Aperçu hors ligne de l'index (alias, presets partiels) sans écrire le snapshot |
| `khanjar index-preview <f.prfpset…>` | **Ce que verrait un monteur ayant CETTE bibliothèque** (pack acheté, presets d'un ami) : presets entrés dans la palette, écartés (audio, masque, Lumetri) et effets absents de ce Premiere |
| `khanjar frequents [N]` | Classement fréquence+récence tel que la palette l'affichera (hors ligne) |
| `Khanjar.app/Contents/MacOS/Khanjar login-item on\|off\|status` | Démarrage avec la session (même mécanisme que la case de l'accueil, SMAppService) ; à lancer depuis le binaire DANS l'app |
| `khanjar plan-dump "<preset>"` | Le plan EXACT que la palette appliquerait (effets, réglages, valeurs, keyframes), hors ligne |
| `khanjar index-excluded <sortie.json>` | Chaque preset **écarté** de la palette avec sa raison (masque, couleur Lumetri, audio seul, effets absents) et le détail de ses effets/params, hors ligne |
| `khanjar crash-test` / `crash-report [fichier.ips] [--send]` | Plantage volontaire, puis impression de l'événement **anonymisé** exactement tel qu'envoyé (`--send` avec `KHANJAR_SENTRY_DSN`) |

> ⚠️ **Un seul processus peut tenir le port 48123.** Pour lancer un mode CLI, arrêter l'app :
> `pkill -x Khanjar`. Puis la relancer : `open dist/Khanjar.app`.
> `timeout` n'existe pas sur macOS : borner un mode CLI avec `perl -e 'alarm 40; exec @ARGV' -- <cmd>`.

### Hooks de test sans clavier (sur l'app en cours)
`kill -USR1 <pid>` bascule la palette · `kill -USR2 <pid>` applique un effet · `kill -WINCH <pid>` teste le calque d'effets · `kill -INFO <pid>` ouvre la fenêtre Réglages (test UI headless).
Capture d'une fenêtre d'app *accessory* (non frontmost sur signal) : `osascript -e 'tell application "System Events" to set frontmost of first process whose name is "Dagger" to true'` puis `screencapture -x -o <fichier>`.

### 4bis. Fréquents : la palette à champ vide (app v0.7.2)

**Pourquoi.** Mesuré sur 982 applications réelles (2026-09-21) : l'utilisateur n'emploie que
**41 entrées sur 436**, et **3 presets font 76 %** des applications. Ouvrir la palette sur un
champ vide lui faisait retaper à chaque fois le nom de ce qu'il applique de toute façon.

**Modèle : décroissance exponentielle, demi-vie 30 jours** (`UsageStore`). Un usage d'aujourd'hui
vaut 1, le même il y a 30 j vaut 0,5, il y a 60 j 0,25. Équivalent à la somme des utilisations
pondérées par l'âge, mais en **O(1) de stockage** : on décote le score accumulé jusqu'à maintenant,
puis on ajoute 1. `count` (nombre brut) ne sert QU'À l'affichage « 418 × », jamais au tri.
Pourquoi pas la fréquence seule : la queue du classement est mince (40, 30, 27, 22 applications) —
un preset abandonné depuis juillet passerait devant celui du projet en cours. Effet vérifié :
« Edges » (18 usages, récents) passe devant un preset plus ancien (30 usages, anciens).

**Amorçage.** Au premier lancement, le classement serait vide pendant des semaines : on rejoue
`helper.log` (lignes `apply OK : <titre>, N clips appliqués`, avec leur date) contre l'index —
986 applications rejouées, 5 titres inconnus, 37 items classés. Titres résolus insensiblement à
la casse et aux espaces (plusieurs presets ont un espace final, ex. « Slide up text »).

⚠️ **PIÈGE D'ORDRE (corrigé le 2026-09-21, trouvé par lecture du journal après déploiement).**
`usage.load()` doit être la **toute première** instruction de `AppCoordinator.start()`, AVANT le
premier `installItems` — c'est lui qui déclenche `seedIfNeeded`. Chargé après, le fichier était
réamorcé et réécrit **à chaque démarrage** ; or `Logger` tronque `helper.log` au-delà de 5 Mo,
donc l'historique aurait fini par se perdre au lieu d'être conservé. Vérification : un
redémarrage ne doit produire AUCUNE ligne « Fréquents amorcés ».

**Raccourcis ⌘1…⌘9, ⌘0** (`PalettePanel.performKeyEquivalent`) : le modificateur ⌘ est
**obligatoire** — un chiffre nu doit rester saisissable, plusieurs presets s'appellent « 01 Big »,
« 10 Small », « TR - Fast Zoom In 180-100 ». Le rang est affiché à gauche de chaque ligne des
fréquents (découvrabilité) ; le raccourci fonctionne aussi sur une liste de recherche, sans marqueur.

**Fichier** : `~/Library/Application Support/Khanjar/usage.json`. Tests : `selftest` (5 cas —
décote, peu-mais-récent > beaucoup-mais-ancien, fréquence à récence égale, compteur brut).

### 4ter. Duos : deux presets enchaînés en un seul geste (app v0.7.3)

**Pourquoi.** Mesuré sur le journal (2026-10-02) : « Edge + 2 drop shadow » et « Gaussian Blur »
s'enchaînent **59 fois**, médiane **6 à 8 s** entre les deux ; « Slide up text » puis
« Edge + 2 drop shadow » **38 fois**. Soit ~23 % des applications faites en deux ⌘J au lieu d'un.

**Détection.** `UsageStore.transitions` : id appliqué → id suivant, si l'écart est < `pairWindowSeconds`
(120 s) et que les deux diffèrent. Les DEUX sens d'une paire se cumulent, le sens majoritaire est
retenu. Seuil `minPairObservations` = 4. Amorcé depuis `helper.log` comme les compteurs, avec un
drapeau SÉPARÉ `seededPairs` : un `usage.json` v1 déjà amorcé rejoue les paires **sans redoubler
les compteurs**. Payload v2 ; les champs v2 sont optionnels, un v1 reste lisible.

⚠️ **ORDRE — la règle et sa preuve.** Appliquer A puis B à la main laisse B **AU-DESSUS** de A
(§3.1 item 13). Les opérations d'un plan sont insérées consécutivement depuis le haut de la pile
utilisateur, donc **l'ordre du plan EST l'ordre haut→bas** : le plan fusionné liste **B avant A**.
Vérifié dans les projets réels, pas déduit : sur 63 clips portant flou + contour, **86 % ont le
flou au-dessus** — il est bien appliqué en dernier, ce qui confirme le sens majoritaire du journal.
⚠️ En revanche le duo n°2 (Transform + contour) est à **52/48** dans les projets : son ordre n'est
PAS établi par l'usage. On garde le majoritaire (log 20 vs 18, projets 24 vs 22), à signaler à
l'utilisateur plutôt qu'à présenter comme certain.

**Fusion refusée** (`SearchItem.combining` → nil) si : un membre est déjà un duo ; les deux plans
touchent le **même effet intrinsèque** (leurs keyframes se mélangeraient sur le composant existant
au lieu de se succéder) ; plus de 12 opérations au total.

**Placement.** Les duos occupent ⌘2 et ⌘3, **jamais ⌘1** : cette place revient à l'item le plus
appliqué (469 fois, loin devant). La déplacer ferait déclencher un duo à la place d'un geste réflexe,
donc poser deux effets au lieu d'un. `AppCoordinator.maxCombosShown` = 2.

**Comptage.** Appliquer un duo crédite ses DEUX membres et l'enchaînement (`recordCombo`), jamais
un id synthétique absent de l'index — sinon se servir du duo le ferait disparaître du classement.

**Vérification** : `khanjar frequents [N]` imprime les duos, la pile obtenue et les refus de
fusion. Tests : `selftest` (12 cas — fenêtre, seuil, fusion des deux sens, répétition du même item,
ordre du plan fusionné, refus intrinsèques/imbrication/plafond).

### Raccourcis clavier → presets (app v0.7.0)
Assigner une touche à un preset/effet qui l'applique au clip sélectionné (uniquement Premiere au 1er plan).
- **Modèle** : `settings.json` → `presetShortcuts: [{itemId, title, shortcut}]` (`itemId` = id stable du `SearchItem`).
- **Moteur** (`AppCoordinator`) : ids Carbon ≥ `HotkeyID.presetBase` (100), réenregistrés à chaud ; le fire résout l'item par id AU MOMENT du clic (secours par titre), puis `apply()`. Filtre « Premiere au 1er plan » hérité de `HotkeyService.fire`.
- **UI** (`SettingsWindow` + `PresetShortcutSheet`) : liste + « Ajouter… » (recherche floue via `searchProvider` + `ShortcutRecorder` qui capture la frappe). Garde-fous : modificateur obligatoire, refus des conflits (palette/calque/autre preset).
- **Découplage app/plugin** : feature 100 % app native, plugin inchangé.

---

## 5. Emplacements sur la machine

| Quoi | Où |
|---|---|
| Presets utilisateur | `~/Documents/Adobe/Premiere Pro/26.0/Profile-<nom>/Effect Presets and Custom Items.prfpset` |
| Presets Adobe | `/Applications/Adobe Premiere Pro 2026/…/Resources/LocalizedPresets/<locale>/Effect Presets/*.prfpset` |
| Plug-in installé | `~/Library/Application Support/Adobe/UXP/Plugins/External/io.khanjar.executor_*/` |
| Journal app | `~/Library/Logs/Khanjar/Khanjar.log` |
| Journal plug-in | `…/UXP/PluginsStorage/PPRO/26/External/io.khanjar.executor/PluginData/khanjar-executor.log` |
| Réglages | `~/Library/Application Support/Khanjar/settings.json` |
| Index (snapshot) | `~/Library/Application Support/Khanjar/index.json` |
| UPIA (installateur Adobe) | `/Library/Application Support/Adobe/Adobe Desktop Common/RemoteComponents/UPI/UnifiedPluginInstallerAgent/…/UnifiedPluginInstallerAgent` |

**Permission macOS** : l'app a besoin de l'accès **Documents** pour indexer les presets (TCC).
Un binaire CLI lancé depuis un autre dossier peut se le voir refuser — l'app, elle, l'a.
⚠️ **Chaque nouveau binaire Swift (signature ad hoc = nouveau CDHash) fait REDEMANDER l'accès par
macOS** : le dialogue bloque la reconstruction de l'index jusqu'au clic « Autoriser » (mesuré dans le
journal : hello → index 80 s le 2026-09-19, 43–555 s les jours de build en juillet/août, 2–8 s sinon).
Sans rebuild du binaire (plugin seul), aucun dialogue. Une identité Developer ID stable supprimerait ce dialogue.

---

## 6. UPIA — mise à jour du plug-in (fragile)

- Installation : `UnifiedPluginInstallerAgent --install <chemin.ccx>` (le `.ccx` **non signé** est accepté).
- Suppression : `--remove "Dagger Executor"` (**par nom d'affichage**, pas par id — l'id échoue avec -406).
- **Installer une nouvelle version par-dessus ne recharge PAS le plug-in en cours** → faire `--remove` puis `--install`.
- ⚠️ **Des cycles rapides peuvent bloquer UPIA** (`Poco::SystemException`, canal « Vulcan » vers Creative
  Cloud). Réparation : redémarrer Creative Cloud Desktop ou le Mac. Le redémarrage d'`AdobeIPCBroker`
  n'a pas suffi.
- **Contournement testé** quand UPIA est cassé : copier les fichiers du plug-in directement dans le
  dossier installé (`io.khanjar.executor_*/`), puis relancer l'app → Premiere a rechargé le nouveau code.
- ⚠️ **UPIA peut bloquer 3 minutes** (mesuré 2026-09-19 : `--install` lancé pendant le démarrage de
  Premiere, sortie `status = -642`). Jusqu'à v0.7.0 il tournait SUR LE FIL PRINCIPAL de l'app → tout
  gelait, pont WebSocket compris (le plugin bouclait « WS fermé — reconnexion dans 2 s » jusqu'au
  retour d'UPIA) → ⌘J muet 3 min après chaque lancement de Premiere. Depuis v0.7.1 :
  file dédiée + délai maximal 90 s (`PluginLifecycleService`), et politique d'installation
  (`AppCoordinator.installPluginIfPremiereRunning`) : attendre `isFinishedLaunching`, ne PAS
  réinstaller si `…/External/io.khanjar.executor_<version>/manifest.json` existe déjà, réinstallation
  forcée seulement si aucun hello 60 s après le premier contrôle.

---

### 6bis. ⚠️ Une mise à jour de Premiere peut DÉSINSCRIRE le plugin (2026-10-06)

**Ce qui s'est passé.** Premiere est passé de 26.5.1 à 26.5.2. Le plugin s'est connecté
normalement au lancement (`hello … 26.5.2` à 19:04:48) puis la session est tombée 27 s plus
tard, et il n'est **jamais revenu** — alors que la boucle de reconnexion du `WsClient` tourne
toutes les 2 s. L'utilisateur a pressé ⌘J pendant 40 minutes avec le HUD « Ouvre Premiere Pro
pour utiliser Dagger » **alors que Premiere était à l'écran**.

**Diagnostic.** `UnifiedPluginInstallerAgent --list all` ne listait plus que *Logi Options+* et
*Spell Book* pour « Premiere Pro (ver 26.5.2) » : **Dagger Executor avait disparu de
l'inscription UPIA**, et `--remove "Dagger Executor"` répondait **-406** (inconnu). Le dossier
`…/UXP/Plugins/External/com.dagger.executor_0.6.8/` existait pourtant toujours sur disque :
Premiere a chargé ce résidu une fois au démarrage, puis l'a lâché. Indice complémentaire :
`…/UXP/PluginsStorage/PPRO/*/External/com.dagger.executor` **n'existait plus du tout**, donc le
journal disque du plugin ne pouvait plus être créé (`DiskLog.init` échoue en silence) — c'est
normal après une désinscription, et ça prive du diagnostic côté plugin.

**Réparation manuelle** (ce qui a débloqué, sans toucher au projet ni redémarrer Premiere) :
`UPIA --install <ccx>` seul. Le `--remove` préalable échoue (-406) et c'est sans conséquence.
Reconnexion en ~2 s.

**Filet automatique (app v0.7.4).** `server.onDisconnect` programme
`revivePluginIfStillSilent()` à `pluginRevivalDelay` = 45 s. Si le pont n'est toujours pas prêt,
que Premiere tourne, qu'UPIA n'est pas occupé et qu'aucune tentative n'a eu lieu depuis
`pluginRevivalCooldown` = 600 s, on appelle `reconcile(installedVersion: nil, force: true)`.
45 s est large devant les 2 s de la boucle de reconnexion et devant un changement de projet.
Le refroidissement de 10 min évite les cycles UPIA rapprochés (§6).
⌘J sur un pont absent déclenche aussi ce filet au lieu d'attendre passivement.

**HUD corrigé.** `summon()` distingue désormais les deux cas : Premiere fermé → « Ouvre Premiere
Pro pour utiliser Dagger » ; Premiere ouvert mais plugin absent → « Dagger se reconnecte à
Premiere… ». L'ancien message unique envoyait chercher le problème au mauvais endroit.

**⚠️ À refaire à chaque mise à jour de Premiere** : vérifier `UPIA --list all`. Si Dagger n'y est
plus, le filet le réinstallera, mais le savoir évite de chercher ailleurs.

---

## 7. Instance unique

Deux instances de Dagger se disputent le port et les raccourcis (cause d'un ⌘&lt; « qui ne marche pas »).
Protections en place : **verrou flock** (`~/Library/Application Support/Khanjar/.instance.lock`) +
**expulsion** des autres instances au démarrage (`NSRunningApplication` / bundle `com.dagger.helper`).

> ✅ L'ancienne copie `/Applications/Dagger.app` (root) signalée en juillet **n'existe plus**
> (constaté le 2026-09-19 et le 2026-10-06). Depuis le renommage, Khanjar expulse aussi toute
> instance de l'ancien bundle `com.dagger.helper` au démarrage.

---

## 8. État vérifié (mesures réelles, Premiere 26.3.0 sauf mention)

| Scénario | Résultat |
|---|---|
| « 2 drop shadow » sur 3 / 20 / 60 clips | 36/36, 240/240, **720/720** params, 0 sauté, 100 % des clips |
| « Appear Up » (Transform + Blur, keyframes de points) | 45 params, 0 sauté |
| Preset PiP (Motion intrinsèque seul) | 18/18 params sur le Motion existant |
| Ancrage Échelle (« AP - BLUR FADE OUT ») | Blurriness 0→7.5→19.5 sur [2%,50%,98%] : anim étirée sur tout le clip ✓ |
| Ancrage Sortie (« Slide UP (OUT) », T2) | Position statique à 2%/50%, glisse (0.53;0.01) à 98% : collée à la fin ✓ |
| Recherche floue (~850 items) | ~4–9 ms/frappe ; « TDS » → « True Drop Shadow » |
| Application d'un effet | ~5–15 ms |
| **Premiere 26.5.1** (2026-09-18/19, journal d'usage réel) | hello OK, plugin 0.6.6 ; applies « Edge + 2 drop shadow », « Gaussian Blur », « TR - Appear Up »… OK en 5–17 ms |
| **Correctif audio validé en usage réel** (2026-10-02) | **0 faux « non appliqué » sur 184 applications** depuis le 21/09, contre 81 sur 959 (8,4 %) avant le correctif |
| **Bascule Dagger → Khanjar** (app 0.8.0 / plugin 0.7.0, 2026-10-06, Premiere 26.5.2, machine d'Isma) | Dagger expulsé ; réglages identiques, historique (40 items, 28 enchaînements) et raccourcis repris ; ancien plugin retiré par UPIA 3 s après le lancement ; plugin Khanjar installé à T+20 s, hello aussitôt, index reconstruit (436 items, 350 presets) |
| **Lumetri à curseurs débloqués** (app 0.8.2 / plugin 0.7.2, 2026-10-07, **Premiere 26.5.2 réel**, projet jetable) | « TR - Cinematic Forground Blur Effect » : 35/35 posés, 0 sauté ; relu en direct Exposure −2,934, Contrast 25,62, Highlights −33,06 (= preset) ; pile Lumetri puis Gaussian Blur. Le Lumetri vivant accepte l'écriture de ses curseurs par index |
| Ancrage Échelle sur « CHAT GPT » (même session) | Basic 3D lu à 2/25/50/75/98 % (`anchor-test --component "Basic 3D"`) : Tilt −8,23 → −6,30 → −4,20 → −2,09 → −0,16, soit la courbe du preset (−8,4 → 0 sur 35 s source) étirée sur le clip cible ✓. Calque d'effets lui-même non testé (impossible d'en créer un par API) |
| Duos (app 0.7.3, 2026-10-02) | 2 duos détectés sur 1172 applications rejouées (59× et 38×) ; selftest 27/27 ; ordre du duo n°1 confirmé à 86 % dans les projets |
| Classement fréquents (app 0.7.2, 2026-09-21) | 986 applications rejouées depuis le journal, 37 items classés ; selftest 15/15 ; `frequents` relit : Slide up text / Edge + 2 drop shadow / 2 drop shadow preset en tête |
| Filtre piste audio (plugin 0.6.8) | ✅ **Vérifié par 11 jours d'usage réel** (ligne ci-dessus) — plus besoin de test manuel |
| Désinscription UPIA après maj Premiere (2026-10-06) | Reproduit en vrai : plugin absent de `--list`, `--remove` → -406, `--install` seul répare, reconnexion en ~2 s. Filet 0.7.4 posé ; **le déclencheur à 45 s n'a pas été exercé bout-en-bout** (l'action de réparation, elle, l'a été à la main) |
| Alias `AE.ADBE Geometry`→`Geometry2` (app 0.7.1) | ⏳ **À vérifier** : `apply-dump <média> "Zoom IN - Right"` → Transform posé avec ses 12 params |
| Bibliothèques d'AUTRES monteurs (2026-10-06, `index-preview <pack>`, inventaire 26.5.2) | 8 packs du commerce/de cours trouvés sur SSD 2 (Finzar, Essential Motion v3, Tech Wampus, Glass Effects, Apple Style, 10 Smooth Zoom, Finzar Shake, pack de cours) : **324 presets → 260 dans la palette (253 complets)** ; écartés : 26 audio seul, 25 masques, 8 Lumetri, 5 sans effet disponible. Tous en noms ANGLAIS. Hors Premiere seulement : l'application réelle d'un pack n'a pas été rejouée |
| Presets d'une autre langue (plugin 0.7.1, 2026-10-06, **Premiere 26.5.2 réel**) | Test miroir : « 01_Zoom In » d'Essential Motion v3 aux noms français (copie du pack, seuls les `<Name>` traduits) dans le Premiere ANGLAIS d'Isma, `apply-dump <img> "01_Zoom In" --library <fichier>` : **12/12 posés, 0 sauté, `namesDiffer`=8** (preset « Point d'ancrage » / Premiere « Anchor Point » : preuve que `displayName` suit la langue de Premiere). Scale Height 100→200, 2 keyframes linéaires comme le preset. Avant (0.7.0) : ces 8 noms étaient sautés. Les presets Adobe fr_FR ne servent pas à ce test : leurs effets ont disparu de 26.5 (sauf Motion 6 params, structure ≠) |

**Non vérifié** : l'exactitude **visuelle** dans le moniteur programme. Les tests prouvent que les
paramètres attendus sont posés sans rejet — pas que le rendu est identique au natif à 100 %.
C'est à l'utilisateur de juger à l'œil.

---

## 9. Limites connues

**Définitives (plafond de l'API Adobe, communes à tous les concurrents)**
- Roues/courbes Lumetri et paramètres opaques → presets Lumetri partiels.
- Masques non transférables.
- Création d'un calque d'effets impossible (réutilisation obligatoire).

**Périmètre v1 (implémentables)**
- Effets audio (API UXP audio immature).
- Transitions (`TransitionFactory` existe dans l'API 26.3 — piste réelle, non implémentée).
- Modes d'interpolation fins (bézier/hold) — keyframes posés en linéaire.

---

## 10. Prochaines étapes suggérées

> 📋 Liste consolidée et priorisée (fidélité native) : `docs/TODO-FIDELITE-NATIVE.md` (2026-07-22).

0. **Reste à vérifier** (§8) : preset « Zoom IN - Right » → Transform posé (alias d'effet renommé) ;
   ⌘⇧J calque d'effets sous 26.5.1. Le filtre audio, lui, est validé par l'usage réel.
1. **Validation visuelle par l'utilisateur** (priorité n°1) : presets animés, presets composés, ⌘&lt;.
2. **M4.5** — modes d'interpolation des keyframes (bézier/hold) depuis le champ mode du `.prfpset`.
3. **M7 durcissement** — suppression automatique des projets de test `/tmp/dagger-*.prproj`, tests de
   chaos (tuer Premiere/le plug-in en cours d'application), revue mémoire/perf.
4. **Distribution** — signature Developer ID + notarisation (nécessite un compte Apple Developer),
   installation dans `/Applications`, lancement à l'ouverture de session.
5. **Sécurité** — ✅ fait et VÉRIFIÉ dans Premiere 26.5.2 le 2026-10-06 (voir §12 et §3.1 item 16).
6. **Transitions** — explorer `TransitionFactory`.

---

## 10bis. Rapports de plantage anonymes (app 0.8.0)

- **Opt-in strict** : `settings.json` → `crashReports` (absent = non). Case dans l'accueil et les
  Réglages, proposée SEULEMENT si le build porte un DSN (`KhanjarCrashReportDSN`, injecté par
  `build-app.sh` depuis `KHANJAR_SENTRY_DSN` ou `~/.config/khanjar/sentry-dsn` — jamais commité).
- **Source = le `.ips` écrit par macOS** (`~/Library/Logs/DiagnosticReports/Khanjar-*.ips`), relu
  au lancement suivant. Aucun gestionnaire de signaux, aucun SDK : un plantage reste ordinaire.
- **Ne part que** : versions, macOS, type d'exception, pile du fil fautif (bibliothèque + fonction +
  décalage). `scrub()` réduit les chemins au nom de fichier et masque les textes entre guillemets.
  `selftest` vérifie qu'aucune donnée personnelle ne passe (12 cas, avec un rapport piégé).
- ⚠️ **macOS 26 n'écrit PAS le message `Fatal error: …` de Swift dans le `.ips`** (vérifié par
  `crash-test` le 2026-10-06) : le diagnostic repose sur la pile. Le décalage envoyé redonne la
  ligne exacte : `atos -o Khanjar -l 0x100000000 <0x100000000 + décalage>` → `main.swift:865` ✓.
- Plateforme Sentry `other` : sans `user.ip_address`, Sentry ne déduit pas l'IP — SAUF pour les
  plateformes Apple (`cocoa`) et JavaScript, qui reçoivent `{{auto}}` par compatibilité (doc
  « identify user » de Sentry). Ne JAMAIS passer en `cocoa`. Réglage OBLIGATOIRE côté projet Sentry :
  *Settings > Security & Privacy > Prevent Storing of IP Addresses* — PRIVACY.md le promet.

## 10ter. Mises à jour automatiques — Sparkle 2.10.0 (app 0.8.0)

- **Récupération** : `scripts/fetch-sparkle.sh` télécharge `Sparkle-2.10.0.tar.xz`, vérifie l'empreinte
  SHA-256 publiée par GitHub (épinglée dans le script), range `helper/Vendor/` (gitignoré). L'archive
  fournit un `.framework` ; SwiftPM veut un `.xcframework` et `xcodebuild -create-xcframework` exige
  Xcode → l'enveloppe (Info.plist) est écrite à la main. `build-app.sh` appelle le script tout seul.
- **Liaison** : `binaryTarget` + rpath `@executable_path/../Frameworks` (app) ET `@loader_path`
  (binaire de dev : avec la toolchain 6.4, SwiftPM range les produits dans `.build/out/Products/Debug/`
  et copie le framework à côté — sans ce rpath, `khanjar selftest` plante au chargement).
- **Activation** : seulement si l'Info.plist porte `SUFeedURL` + `SUPublicEDKey`, injectés par
  `build-app.sh` depuis `~/.config/khanjar/repo` et `~/.config/khanjar/sparkle-ed25519.pub`. Flux :
  `https://github.com/<repo>/releases/latest/download/appcast.xml`. Sinon menu masqué, service éteint.
- **Clé de signature** : `swift scripts/sparkle-keygen.swift` (CryptoKit), PAS `generate_keys` de Sparkle
  qui passe par le trousseau → fenêtre d'autorisation à chaque signature. Format vérifié : graine 32 octets
  base64, lue par `sign_update -f`, signature validée par CryptoKit. ⚠️ Clé privée perdue = plus aucune
  mise à jour possible pour les gens installés : à sauvegarder.
- **`CFBundleVersion` = `APP_VERSION`** (était figé à « 1 ») : Sparkle compare ce champ.
- **VÉRIFIÉ de bout en bout** (2026-10-06, macOS 26.6.2, mini-app jetable signée AD HOC comme Khanjar,
  flux local) : 1.0 → trouve 2.0 → télécharge → vérifie → installe → relance en **1 s**, paquet installé
  à signature valide. Archive modifiée (fichier ajouté, ancienne signature) : **refusée**
  (`SUSparkleErrorDomain 4005`, « improperly signed »), l'app reste en 1.0. ⇒ la signature Apple n'est
  PAS requise par Sparkle quand la signature EdDSA est là.
- **Publication** : `scripts/release.sh` → `dist/release/<v>/Khanjar-<v>.zip` + `appcast.xml`, rien n'est
  publié ; la commande `gh release create` est affichée à la fin.
  ⚠️ **Jamais `--prerelease`** : `releases/latest/download/…` ignore les pré-versions → les apps
  installées ne verraient pas la mise à jour. La bêta se dit dans le titre. Testé avec une config
  factice (`KHANJAR_CONFIG_DIR=<dossier>`) : archive 1,6 Mo, signature vérifiée par `sign_update --verify`.
- Contrepartie de la signature ad hoc : chaque mise à jour = nouveau CDHash → macOS redemande l'accès
  Documents (§5). Disparaîtra avec un Developer ID.

## 11. Conventions de travail attendues

- **Textes de l'interface : anglais en clé, français en traduction** (app 0.8.0). Tout texte
  visible passe par `L("…")` / `LF("…", args)` (`Support/Localization.swift`) ; la clé EST le texte
  anglais (langue par défaut), la version française va dans `helper/Resources/fr.lproj/Localizable.strings`.
  `scripts/check-l10n.py` (lancé par `build-app.sh`) bloque le build si un texte n'a pas sa traduction
  ou si ses `%@`/`%ld` diffèrent. Journaux et modes CLI restent en français (outils de dev).
  ⚠️ La langue suit l'ORDRE des langues du Mac : le Mac de développement est réglé `en-US` puis `fr-FR`
  → Khanjar s'y affiche en anglais. Pour le voir en français : Réglages Système > Général > Langue
  et région > Applications > Khanjar > Français. Les thèmes se choisissent par POSITION dans le menu
  (`SettingsWindowController.themes`), jamais par titre : un titre traduit ne se compare pas.
- **Ne rien affirmer sans vérification.** Ce projet a été construit sur la règle : si une capacité de
  l'API n'est pas prouvée, on la teste (harnais `multi-test` / `apply-dump`) avant de s'en servir.
- **Tester dans le vrai Premiere**, pas seulement compiler. Les bugs de ce projet étaient tous
  invisibles à la compilation.
- **Le protocole évolue des deux côtés dans le même commit** (helper Swift + plug-in JS).
- Le plug-in reste **sans état** ; toute logique produit va dans le helper.
- Journaliser les causes racines dans le code (commentaires datés) — plusieurs pièges ci-dessus sont
  déjà documentés en commentaire à l'endroit exact où ils mordent.

---

## 12. Sécurité du pont (2026-10-06)

**Menace réelle, pas théorique.** Le pont n'écoute que `127.0.0.1`, mais une **page web** ouverte dans
le navigateur de l'utilisateur peut ouvrir un WebSocket vers `ws://127.0.0.1:48123` : pour les
WebSockets, le navigateur ne demande aucune autorisation, c'est au serveur de filtrer. Une page
pouvait donc se présenter comme le plugin, **remplacer la vraie session** (⌘J muet) et lire les plans
appliqués. C'est le seul vecteur venu de l'extérieur du Mac.

**Garde-fou retenu : refus des origines web** (`BridgeServer`, `setClientRequestHandler`). Un navigateur
envoie TOUJOURS l'en-tête `Origin` lors de la poignée de main. Refus (HTTP 400) si le schéma est
`http://`, `https://` ou une extension de navigateur ; acceptés : aucune origine, `null`. Testé hors
ligne (`khanjar run --port 48199` + poignées de main brutes) : pages et extensions refusées, client
normal accepté. ⚠️ Ce qu'envoie le **plugin UXP** n'est pas encore relevé en vrai : la première origine
acceptée est journalisée une fois, à lire au premier lancement.

**Pourquoi PAS de jeton partagé** (l'ancien plan de `PROTOCOL.md`). Un programme déjà installé sur le Mac
peut lire n'importe quel fichier de l'utilisateur, donc aussi un jeton — et il pourrait de toute façon
modifier les `.prproj` directement : le jeton ne l'arrêterait pas. Côté fragilité, le seul endroit que
le plugin sait lire, son dossier `PluginData`, **disparaît** quand Adobe désinscrit le plugin (vécu le
2026-10-06, §6bis) : un jeton stocké là aurait cassé ⌘J à chaque mise à jour de Premiere.

**Ce que le plugin publié ne sait plus faire.** Les harnais qui MODIFIENT Premiere (`testSetup`,
`testSetupMulti` : créer un projet, importer, monter une séquence ; `easeProbe` : poser des keyframes)
ne sont enregistrés que dans une construction `./scripts/build-plugin.sh --dev`. Les diagnostics en
lecture seule (`dumpChain`, `dumpAllSelected`, `readParams`, `inspectComponent`) restent, pour le support.
Le réglage vit dans `plugin/src/env/build.js` (valeurs sûres par défaut), réécrit par le script dans sa
copie de travail : les sources ne changent jamais, rien à « remettre » avant de publier.
⚠️ Les modes CLI `multi-test`, `fidelity-test`, `anchor-test`, `apply-dump`, `stack-test`, `ease-probe`,
`inspect-component` exigent un plugin `--dev` : `./scripts/build-plugin.sh --dev --install`.

**Réseau.** Le manifeste n'autorise plus que `ws://localhost/` — les WebSockets locaux (avant :
`"domains": "all"`, tout internet). Le plugin se connecte à `ws://localhost:48123`. `build-plugin.sh`
refuse de construire si le manifeste autorise autre chose. Pourquoi pas `127.0.0.1` : §3.1 item 16.
**Vérifié en vrai** (2026-10-06, plugin de test sur le port 48199 à côté de Dagger) : hello du vrai code
du plugin OK ; le plugin UXP annonce l'origine **`file://`** (acceptée) ; une origine `https://…` ou
`chrome-extension://…` est refusée (HTTP 400) sans couper la session du plugin.

