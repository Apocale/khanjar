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
> jamais écrasés). L'app expulse l'ancien `com.dagger.helper` et fait retirer l'ancien plugin
> « Dagger Executor » chez Adobe dès qu'il se présente au pont (refusé : id inattendu) — depuis
> l'app 0.8.4, une fois par SESSION de l'app (C-20) ; le marqueur `.legacy-plugin-removed` qui
> rendait ce retrait définitif jusqu'à la 0.8.3 n'est plus lu (un fichier resté là est sans effet).
> Les sections ci-dessous gardent « Dagger » quand elles racontent un fait daté d'avant.

> Fichier de contexte canonique. Lis-le **en entier** avant de modifier quoi que ce soit.
> Il contient du savoir empirique coûteux (des heures de débogage dans Premiere) qui
> n'est déductible ni du code ni de la documentation Adobe.
> Dernière mise à jour : 2026-10-11 — app **0.8.4** (`APP_VERSION`, publiée sur GitHub le 2026-10-11 avec
> l'accord d'Isma) / plugin **0.7.3** (`plugin/manifest.json`, livré avec cette app) —
> Premiere **26.5.2**. Le binaire exige macOS 13 (`helper/Package.swift`, comme l'Info.plist).
> **Audit du 2026-10-08** : correctifs des lots P, I, U, D et C INTÉGRÉS dans le code (2026-10-09) →
> §13 ; une partie VÉRIFIÉE dans Premiere 26.5.2 le 2026-10-09 et par l'usage réel du 2026-10-11
> (§8) ; le reste à vérifier (tests T-xx du plan, sur un projet jetable). **Relecture finale** : 1 majeur
> (M1, mise à niveau du plugin au hello) et des mineurs corrigés le 2026-10-11 (§13, fin).
> Plugin v0.7.1 / app v0.8.1 : **presets d'un Premiere d'une autre langue** — les noms de
> paramètres d'un .prfpset sont localisés, un nom différent ne fait plus sauter le réglage quand
> la structure de l'effet est identique (§3.2 item 7). Profil de presets choisi selon la version
> de Premiere qui tourne, puis le fichier le plus récent (plusieurs profils chez un ami).
> App v0.7.4 : **filet de reprise du plugin** — une mise à jour de Premiere peut effacer
> l'inscription UPIA et laisser ⌘J muet indéfiniment (§6, cas vécu).
> App v0.7.3 : **duos** — deux presets systématiquement enchaînés deviennent UN item
> applicable d'un seul geste (§4ter).
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

**Khanjar** (ex-Dagger) est une palette de commande type Spotlight pour **Adobe Premiere Pro 2026 (macOS)** :
⌘J ouvre une fenêtre de recherche floue sur tous les effets et presets ; Entrée applique au(x)
clip(s) sélectionné(s) et referme. ⌘⇧J ajoute un calque d'effets à la tête de lecture.

## 2. Architecture — et pourquoi elle est ainsi

**Deux processus, un protocole WebSocket sur la boucle locale (127.0.0.1:48123, et [::1]:48123
depuis l'app 0.8.4 — C-18).**

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
- Dossier de revue externe (PDF, très détaillé) : `docs/Dagger-Dossier-Technique.pdf` (dépôt privé,
  non exporté)

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
   par courbure) = amélioration future, non bloquante. Budget : 400 points par paramètre, comptés
   dans la seule partie VISIBLE du clip (`ease.js`, `BUDGET` ; au-delà, sous-échantillonnage) —
   les keyframes d'origine situés hors du clip sont pourtant tous posés : un shake de 12 min en
   pose ~10 000 sur un clip de 3 s (audit du 2026-10-08, B3#3). L'ancienne piste « façonneurs » (spike `ease-probe`) donnait une ease
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
   (le pont n'écoutait que 127.0.0.1 : UXP y aboutit en résolvant localhost, alors que sur ce Mac
   localhost se résout d'abord en ::1 ; depuis l'app 0.8.4 le pont écoute AUSSI [::1], C-18 — un UXP
   qui ne se rabattrait pas sur 127.0.0.1 joint quand même Khanjar). La règle sans port couvre
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
   tous les packs du commerce relevés sur le disque de l'auteur) chez un monteur dont Premiere est en français
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
| `khanjar frequents [N]` | Classement fréquence+récence tel que la palette l'affichera (hors ligne) — depuis l'app 0.8.4, EXACTEMENT les lignes de la palette (`AppCoordinator.frequentRows`), duos compris, puis les entrées écartées (disparues de l'index ou au titre changé) |
| `Khanjar.app/Contents/MacOS/Khanjar render-media <dossier>` | Images du README dessinées par les VRAIES vues (palette, réglages, accueil) avec des presets d'exemple, hors écran (aucune permission d'enregistrement d'écran). Lancer depuis l'app pour afficher sa version. Assemblage : `public/docs/media/` |
| `Khanjar.app/Contents/MacOS/Khanjar login-item on\|off\|status` | Démarrage avec la session (même mécanisme que la case de l'accueil, SMAppService) ; à lancer depuis le binaire DANS l'app |
| `khanjar plan-dump "<preset>"` | Le plan EXACT que la palette appliquerait (effets, réglages, valeurs, keyframes), hors ligne |
| `khanjar index-excluded <sortie.json>` | Chaque preset **écarté** de la palette avec sa raison (masque, couleur Lumetri, audio seul, effets absents) et le détail de ses effets/params, hors ligne |
| `khanjar crash-test` / `crash-report [fichier.ips] [--send]` | Plantage volontaire, puis impression de l'événement **anonymisé** exactement tel qu'envoyé (`--send` avec `KHANJAR_SENTRY_DSN`) |

> ⚠️ **Un seul processus peut tenir le port 48123.** Pour lancer un mode CLI, arrêter l'app :
> `pkill -x Khanjar`. Puis la relancer : `open dist/Khanjar.app`.
> `timeout` n'existe pas sur macOS : borner un mode CLI avec `perl -e 'alarm 40; exec @ARGV' -- <cmd>`.
> ⚠️ **Modes hors ligne et snapshot v7** (2026-10-09) : `search`, `index-preview`, `plan-dump`, `frequents`,
> `index-excluded` lisent `index.json` en version 7 seulement. Après la mise à jour vers l'app 0.8.4, ils
> répondent « Pas de snapshot » tant que l'app n'a pas reconstruit l'index avec Premiere (1er hello).
> L'app, elle, démarre sur un index provisoire tiré de l'ancien snapshot (§13, « Index provisoire »).
> **Tests hors Premiere : toujours dans un HOME jetable** — `CFFIXED_USER_HOME="$(mktemp -d)"
> ./.build/debug/khanjar selftest` (idem `search`, `index-preview`, `frequents`, `plan-dump`) : journal,
> usage.json et réglages vont dans ce HOME, pas dans ceux du monteur. Le mode `app` expulse toute instance
> de Khanjar en service (`forceTerminate`), même lancé dans un HOME jetable : jamais pendant qu'un monteur
> travaille.

### Hooks de test sans clavier (sur l'app en cours)
`kill -USR1 <pid>` bascule la palette · `kill -USR2 <pid>` applique un effet · `kill -WINCH <pid>` teste le calque d'effets · `kill -INFO <pid>` ouvre la fenêtre Réglages (test UI headless).
⚠️ App 0.8.4 (C-14, §13) : ces crochets ne sont installés que si l'app est lancée avec `KHANJAR_TEST_HOOKS=1`
(`open --env KHANJAR_TEST_HOOKS=1 dist/Khanjar.app`, l'app étant d'abord quittée). Avant, ils étaient actifs dans
la version publiée : SIGWINCH, qu'envoie un terminal redimensionné, posait un calque d'effets.
Capture d'une fenêtre d'app *accessory* (non frontmost sur signal) : `osascript -e 'tell application "System Events" to set frontmost of first process whose name is "Khanjar" to true'` puis `screencapture -x -o <fichier>`.

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
Depuis l'app 0.8.4 (C-11) : au-delà de 5 Mo (contrôlé au lancement puis toutes les 1 000 lignes), le
journal est RENOMMÉ `Khanjar.log.1` (l'ancien `.1` est remplacé) au lieu d'être effacé ; horodatage
toujours grégorien en chiffres latins (`en_US_POSIX`), quel que soit le réglage du Mac (sous arabe ou
thaï, les dates devenaient illisibles et l'amorçage ne reconnaissait plus aucune ligne). L'amorçage ne
relit que `Khanjar.log`.

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
Les projets réels montrent bien le flou AU-DESSUS du contour (74 clips sur 74 récents, 54 sur 55
d'archive : audit du 2026-10-08, A3#1).
⚠️ **MAIS le sens « majoritaire du journal » ne le garantit pas — faux depuis le 2026-10-04.** Un
enchaînement était compté quel que soit le clip visé : contour sur un clip puis flou sur le
SUIVANT comptait comme « flou après contour », et l'inverse aussi. Les deux sens s'équilibrent
(45/51, puis 49/54) ; le sens retenu a basculé 8 fois depuis juillet, et depuis le 04/10 ⌘2 pose
le flou SOUS le contour et les ombres, à l'inverse des projets. Chaque usage du duo renforçait le
mauvais sens (`recordCombo`). Le « 86 % » mesuré le 2026-10-02 confirmait les projets, pas la règle.
Le duo n°2 (Transform + contour) est aussi à pile ou face (projets 52/48, journal 21/20). Règle de
correction : I-01 (même clip, 3 contre 1).

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
| Journal app | `~/Library/Logs/Khanjar/Khanjar.log` (+ `Khanjar.log.1` : la génération précédente, au-delà de 5 Mo, app 0.8.4) |
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
  ⚠️ Même `--remove` + `--install`, Premiere OUVERT, n'est pas rechargé à chaud de façon fiable : le
  2026-10-09 (Premiere 26.5.2), le plugin 0.7.3 ne s'est chargé qu'à la relance de Premiere. D'où la règle
  de l'app 0.8.4 : mise à niveau Premiere FERMÉ (M1, point 6 ci-dessous).
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
- **Politique de l'app 0.8.4 (C-01, cas « 3 minutes sans hello » d'un ami — non vérifiée dans
  Premiere, tests T-09 et T-10).** Décisions pures dans `PluginInstallPolicy`, testées par le selftest :
  1. **jamais d'UPIA avant** `isFinishedLaunching` ET **60 s** depuis le lancement de Premiere
     (`launchDate`) — sinon reprogrammé au temps restant + 1 s ; Premiere < **25.6** (version lue dans son
     Info.plist) : pas d'UPIA, HUD « Premiere x est trop ancien » ;
  2. UPIA occupé → nouveau contrôle à +30 s (avant : chaîne arrêtée) ; dossier versionné déjà déposé →
     on attend le hello, réinstallation forcée si toujours rien 60 s plus tard ;
  3. le résultat d'UPIA est LU (avant : par personne) : `UPIA --install → <code> — <sortie>` en `[error]`
     en échec (code extrait de « status = -NNN », sortie bornée à 2 Ko), `[info]` en succès — préfixe
     inchangé, le support et le prompt d'installation le cherchent. Lecture de la sortie bornée à 5 s
     après la fin du processus (un enfant qui garde la sortie ouverte ne bloque plus `busy` toute la
     session) ;
  4. échec → HUD 6 s « Le plugin Khanjar ne s'est pas installé — nouvel essai dans 2 minutes », nouvel
     essai à **+2 min**, **3 essais au plus** ; après le 3ᵉ : HUD « … ouvre l'app Creative Cloud, vérifie
     que tu es connecté, puis quitte et rouvre Premiere ». Relancer Premiere ou l'entrée de menu
     **« Réinstaller le plugin dans Premiere »** (C-05) remet les essais à zéro ;
  5. succès → contrôle à **+45 s** : toujours pas de hello → lecture (seule) du registre d'Adobe
     `~/Library/Application Support/Adobe/UXP/PluginsInfo/v1/premierepro.json` et de la date du journal
     du plugin : écrit depuis le DÉBUT de l'installation → « le plugin tourne mais ne joint pas Khanjar —
     ouvre le journal », sinon → « Plugin installé — quitte et rouvre Premiere pour terminer » ;
  6. **mise à niveau Premiere FERMÉ** (M1, relecture finale, 2026-10-11). Au hello, un plugin plus ancien
     que l'embarqué est seulement NOTÉ : il reste en service (même protocole v1). La mise à niveau
     (remove+install) part 30 s après la fermeture de Premiere (une relance rapide tombe dans ce délai), ou
     60 s après le lancement de Khanjar si Premiere est fermé (mise à jour Sparkle, ouverture de session) ;
     seulement si le service de fond de Creative Cloud (`com.adobe.acc.AdobeDesktopService`) tourne. La
     version installée est lue dans l'inscription d'Adobe (`premierepro.json`, elle fait foi : un hello
     falsifié ne déclenche rien), à défaut celle du dernier hello. Les deux commandes UPIA partent l'une
     après l'autre : Premiere rouvert après le `--remove` → `--install` PAS lancé (F1, relecture du
     2026-10-11) ; le plugin retiré est alors réinstallé par la chaîne d'installation, 60 s après le
     lancement. Sans HUD : le nouveau plugin se charge au prochain lancement. Toujours vers une version **plus
     récente**, une par 10 min au plus ; échec → l'ancien plugin reste (nouvel essai à la prochaine fermeture)
     ou, s'il a été retiré, installation au prochain lancement de Premiere. Avant : remove+install
     AU HELLO (~13 s après le lancement de Premiere, la fenêtre du blocage de 3 min) et presque jamais
     rechargé à chaud → ⌘J muet en plein montage jusqu'à la relance. Le retrait de l'ancien plugin Dagger
     passe par la même porte que l'installation (60 s après le lancement de Premiere). Les contrôles à +45 s
     sont ignorés si Premiere a été relancé entre-temps (m5, pid comparé) ;
  7. gardés : UPIA hors du fil principal, plafond de 90 s par appel, refroidissement de 10 min du filet.
  L'état affiché (menu, accueil, Réglages, HUD de ⌘J) en découle (`PluginStatus`, C-05) : Premiere fermé /
  connexion / installation / échec / redémarrage nécessaire / connecté — « se reconnecte » seulement après
  une vraie déconnexion. La 2ᵉ ligne du menu garde « Connecté — Premiere … · plugin … » (citée par les guides).

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
App 0.8.4 (C-01, non vérifié dans Premiere) : le filet obéit aux mêmes conditions que l'installation
(Premiere fini de démarrer ET lancé depuis 60 s, sinon reporté — avant, il pouvait lancer UPIA pendant
un redémarrage de Premiere) ; il s'arme aussi après une 1ʳᵉ installation restée sans hello (une fois par
lancement de Premiere ; avant : seulement sur une déconnexion, donc jamais pour un plugin jamais connecté) ;
⌘J ne le relance qu'après 45 s de silence comptées depuis le lancement de CE Premiere (avant : depuis la
veille) ; le journal distingue « jamais connecté à ce Premiere (N s) » de « déconnecté depuis N s ».

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
App 0.8.4 (C-13, non vérifié en vrai) — plus de départ silencieux : une 2ᵉ copie qui trouve le verrou
pris envoie une notification distribuée (`io.khanjar.app.showSettings`) et l'instance en service ouvre ses
Réglages ; un verrou impossible à OUVRIR (dossier non inscriptible) est journalisé à part de « une autre
instance tourne » ; port 48123 toujours pris après 5 essais → fenêtre « Khanjar ne peut pas démarrer : le
port 48123 est utilisé par <app> » (nom lu par `lsof`, borné à 2 s), puis l'app quitte.

> ✅ L'ancienne copie `/Applications/Dagger.app` (root) signalée en juillet **n'existe plus**
> (constaté le 2026-09-19 et le 2026-10-06). Depuis le renommage, Khanjar expulse aussi toute
> instance de l'ancien bundle `com.dagger.helper` au démarrage.

---

## 8. État vérifié (mesures réelles, Premiere 26.3.0 sauf mention)

| Scénario | Résultat |
|---|---|
| « 2 drop shadow » sur 3 / 20 / 60 clips | 36/36, 240/240, **720/720** params, 0 sauté, 100 % des clips |
| « Appear Up » (Transform + Blur, keyframes de points) | 45 params, 0 sauté |
| Preset PiP (Motion intrinsèque seul) | 18/18 params sur le Motion existant — mesuré AVANT l'option « Adapter au cadrage » (plugin 0.6.5/0.6.6, active par défaut) : avec elle, les PiP Adobe ne bougent plus (audit du 2026-10-08, A1#1 ; P-01, test T-02) |
| Ancrage Échelle (« AP - BLUR FADE OUT ») | Blurriness 0→7.5→19.5 sur [2%,50%,98%] : anim étirée sur tout le clip ✓ |
| Ancrage Sortie (« Slide UP (OUT) », T2) | Position statique à 2%/50%, glisse (0.53;0.01) à 98% : collée à la fin ✓ |
| Recherche floue (~850 items) | ~4–9 ms/frappe ; « TDS » → « True Drop Shadow » |
| Application d'un effet | ~5–15 ms |
| **Premiere 26.5.1** (2026-09-18/19, journal d'usage réel) | hello OK, plugin 0.6.6 ; applies « Edge + 2 drop shadow », « Gaussian Blur », « TR - Appear Up »… OK en 5–17 ms |
| **Correctif audio validé en usage réel** (2026-10-02) | **0 faux « non appliqué » sur 184 applications** depuis le 21/09, contre 81 sur 959 (8,4 %) avant le correctif |
| **Bascule Dagger → Khanjar** (app 0.8.0 / plugin 0.7.0, 2026-10-06, Premiere 26.5.2, machine d'Isma) | Dagger expulsé ; réglages identiques, historique (40 items, 28 enchaînements) et raccourcis repris ; ancien plugin retiré par UPIA 3 s après le lancement ; plugin Khanjar installé à T+20 s, hello aussitôt, index reconstruit (436 items, 350 presets) |
| **Lumetri à curseurs débloqués** (app 0.8.2 / plugin 0.7.2, 2026-10-07, **Premiere 26.5.2 réel**, projet jetable) | « TR - Cinematic Forground Blur Effect » : 35/35 posés, 0 sauté ; relu en direct Exposure −2,934, Contrast 25,62, Highlights −33,06 (= preset) ; pile Lumetri puis Gaussian Blur. Le Lumetri vivant accepte l'écriture de ses curseurs par index |
| Ancrage Échelle sur « CHAT GPT » (même session) | Basic 3D lu à 2/25/50/75/98 % (`anchor-test --component "Basic 3D"`) : Tilt −8,23 → −6,30 → −4,20 → −2,09 → −0,16, soit la courbe du preset (−8,4 → 0 sur 35 s source) étirée sur le clip cible ✓. Calque d'effets lui-même non testé (impossible d'en créer un par API) |
| Duos (app 0.7.3, 2026-10-02) | 2 duos détectés sur 1172 applications rejouées (59× et 38×) ; selftest 27/27 ; ordre du duo n°1 confirmé à 86 % dans les projets — ⚠️ faux depuis le 2026-10-04 : le sens retenu bascule (§4ter, audit A3#1) |
| Classement fréquents (app 0.7.2, 2026-09-21) | 986 applications rejouées depuis le journal, 37 items classés ; selftest 15/15 ; `frequents` relit : Slide up text / Edge + 2 drop shadow / 2 drop shadow preset en tête |
| Filtre piste audio (plugin 0.6.8) | ✅ **Vérifié par 11 jours d'usage réel** (ligne ci-dessus) — plus besoin de test manuel |
| Désinscription UPIA après maj Premiere (2026-10-06) | Reproduit en vrai : plugin absent de `--list`, `--remove` → -406, `--install` seul répare, reconnexion en ~2 s. Filet 0.7.4 posé ; **le déclencheur à 45 s n'a pas été exercé bout-en-bout** (l'action de réparation, elle, l'a été à la main) |
| Alias `AE.ADBE Geometry`→`Geometry2` (app 0.7.1) | ✅ **Vérifié le 2026-10-09** (Premiere 26.5.2, plugin 0.7.3 `--dev`) : « Zoom IN - Right » → 32/32 posés, `transactions=2` (T-18) |
| **Audit 2026-10-08, tests réels** (2026-10-09, Premiere 26.5.2, app 0.8.4 + plugin 0.7.3 `--dev`, projet jetable) | Connexion (origine `file://`), index reconstruit 420 items / 323 presets perso, 4 fréquents rattachés à leur nouvel id. PiP 25 % : Scale 25 (5/6, un réglage sans nom invérifiable). « HEAVY SHAKE (12 MINS) » sur un clip de 3 s : ~105 keyframes par réglage au lieu de ~10 000, 12/12, pas de gel (P-09). « TR - Apple Appear Left » : 12/12, Position 0,5069 à 10 % ≈ 973 px contre 974 pour le modèle (1032 avant P-03). `multi-test` sur 3 images DISTINCTES : 81/81, 3/3 clips, une seule transaction (T-06). Non vérifiés : historique/⌘Z à l'œil (T-01), ⌘⇧J (T-05), BUSY (T-04), installation (T-09/T-10), accès refusé (T-11), duos (T-13) |
| **Usage réel, app 0.8.4 + plugin 0.7.3** (2026-10-11, montage d'Isma) | « Gaussian Blur » sur **144 clips** : `transactions=1`, 81 ms, 0 échec ; « 2 drop shadow preset » sur **283 clips** : `transactions=2`, 292 ms, 0 échec ; « Edge + 2 drop shadow » sur 8 clips puis 1 : `transactions=2`. Le regroupement des annulations (P-02) tient à l'échelle (le nombre de ⌘Z à l'œil n'a pas été compté) |
| Pièges du harnais (2026-10-09) | `multi-test` avec des COPIES identiques d'une image : insertion partielle dans 26.5.2 → utiliser des images distinctes. Après des imports ratés, « The script object is no longer valid » sur la moitié des réglages jusqu'à la relance de Premiere (état de Premiere, pas une régression : disparu après relance) |
| Bibliothèques d'AUTRES monteurs (2026-10-06, `index-preview <pack>`, inventaire 26.5.2) | 8 packs du commerce/de cours trouvés sur le disque de l'auteur (Finzar, Essential Motion v3, Tech Wampus, Glass Effects, Apple Style, 10 Smooth Zoom, Finzar Shake, pack de cours) : **324 presets → 260 dans la palette (253 complets)** ; écartés : 26 audio seul, 25 masques, 8 Lumetri, 5 sans effet disponible. Tous en noms ANGLAIS. Hors Premiere seulement : l'application réelle d'un pack n'a pas été rejouée |
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
  *Settings > Security & Privacy > Prevent Storing of IP Addresses*.
- ⚠️ **Aucune version publiée n'a de DSN** (0.8.3 vérifiée) : la case n'existe chez personne. Le README
  et PRIVACY.md ne parlent donc PLUS des rapports de plantage (décision d'Isma, 2026-10-08). Avant de
  publier un build qui porte un DSN : remettre leur description (ce qui part, ce qui ne part jamais,
  l'IP non stockée) ET nettoyer d'abord les noms de bibliothèques de la pile, qui partent tels quels
  (`usedImages[].name` : une dylib au nom personnel fuirait — audit sécurité A6, mineur 1).

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
  publié. Il REFUSE (2026-10-09, audit A5#14-15) : un `dist/release/<v>` déjà présent, une release `v<v>`
  déjà sur GitHub (si `gh` est là), une version pas strictement supérieure au `sparkle:version` du flux
  publié (flux illisible → refus, sauf `KHANJAR_SKIP_PUBLISHED_CHECK=1`), une app en quarantaine. Il
  affiche ensuite la séquence : `gh release create … --draft` → `gh release view` (les deux fichiers
  sont là ?) → `gh release edit v<v> --draft=false --latest` → contrôle `curl` du flux. Raison du
  brouillon : `create --latest` publiait AVANT d'envoyer les fichiers (coupure = « latest » sans appcast).
  ⚠️ **Jamais `--prerelease`** : `releases/latest/download/…` ignore les pré-versions → les apps
  installées ne verraient pas la mise à jour. La bêta se dit dans le titre. Testé avec une config
  factice (`KHANJAR_CONFIG_DIR=<dossier>`) : archive 1,6 Mo, signature vérifiée par `sign_update --verify`.
- Contrepartie de la signature ad hoc : chaque mise à jour = nouveau CDHash → macOS redemande l'accès
  Documents (§5). Disparaîtra avec un Developer ID.

## 10quater. Publication (2026-10-07)

- **Dépôt public : https://github.com/Apocale/khanjar** (compte GitHub d'Isma « Apocale », publié avec
  son accord explicite). Historique public NEUF, signé « Isma <117782129+Apocale@users.noreply.github.com> » ;
  ce dépôt-ci (« Dagger 2.0 ») reste PRIVÉ et garde tout l'historique.
- Clone local du dépôt public : `dist/public-repo` (dist/ est ignoré par git ici).
- **Publier une nouvelle version** (dans l'ordre) :
  1. monter `APP_VERSION` (`scripts/build-app.sh`), et la version du plugin si le ccx change ;
  2. commiter ici ; `scripts/export-public.sh dist/public-repo --repo Apocale/khanjar --author "Isma <117782129+Apocale@users.noreply.github.com>" --update -m "Khanjar X.Y.Z"`
     puis `git -C dist/public-repo push` (script du dépôt privé, non exporté). `--update` fait un
     `git fetch` et refuse si le clone ≠ `origin/main` (changement fait sur GitHub, ou export non
     poussé) : jamais de push forcé ;
  3. `scripts/release.sh` (lit `~/.config/khanjar/repo` = `Apocale/khanjar` et la clé EdDSA) ;
  4. suivre la séquence qu'il affiche : brouillon (`--draft`) → vérification → `gh release edit
     vX.Y.Z --draft=false --latest` → contrôle du flux — JAMAIS `--prerelease` (§10ter).
- 0.8.2 publiée et vérifiée de l'extérieur : flux `releases/latest/download/appcast.xml` → 200, version 0.8.2 ;
  archive 1 620 489 o → 200. 20 topics (maximum GitHub), wiki et projects désactivés.
- Description, topics et FAQ du README choisis pour la recherche (« command palette for Premiere Pro »,
  « keyboard shortcut to a preset », presets d'un pack acheté…). Aucun nom de produit concurrent.

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
envoie TOUJOURS l'en-tête `Origin` lors de la poignée de main. Règle de l'app 0.8.4 (C-07, **décision Q9
d'Isma**, `BridgeServer.isRefused(origin:)`) : refuser ce qu'un NAVIGATEUR peut émettre, accepter le reste.
Refusés (HTTP 400) : les schémas `http`, `https`, `data`, `blob`, tout schéma en `-extension`
(`chrome-`, `moz-`, `safari-web-extension`…) et la valeur `null` (iframe « sandbox », URL `data:`).
Acceptés : pas d'en-tête, `file://` (ce qu'annonce le plugin UXP, relevé sur **Premiere 26.5.2
seulement**) et tout autre schéma non web (`uxp://`…). Refus journalisé au plus une fois par minute et par
origine, avec le compte des refus tus (avant : une ligne `[error]` toutes les 2 s, ~7 Mo/jour). Historique :
la 0.8.3 publiée n'écartait que `http`, `https` et les extensions (`null` acceptée) ; 12b5fdb (jamais
publié) était une liste BLANCHE `file://`, abandonnée : un UXP qui annoncerait autre chose sur un autre
Premiere aurait coupé ⌘J. ⚠️ À faire valider par l'audit sécurité, et à confronter à la ligne « origine
annoncée » des amis avant de publier (T-14, plan §13). Chaque origine acceptée est journalisée une fois
(« origine annoncée »). Testé hors ligne le 2026-10-09 (selftest, puis `khanjar run --port 48199` dans un
HOME jetable + poignées de main brutes) : 101 sans `Origin`, avec `file://` et `uxp://x` ; 400 pour
`https`, `http`, `null`, ` NULL `, `moz-`/`chrome-`/`safari-web-extension`, `data:`, `blob:` — en IPv4 comme
sur [::1] ; 30 refus de la même origine = 1 ligne de journal ; connexion muette fermée à 10,5 s ; 0 socket
CLOSED/CLOSE_WAIT ensuite (C-06). Le plugin UXP réel, lui, n'a été relevé que sur Premiere 26.5.2.

**Pourquoi PAS de jeton partagé** (l'ancien plan de `PROTOCOL.md`). Un programme déjà installé sur le Mac
peut lire n'importe quel fichier de l'utilisateur, donc aussi un jeton — et il pourrait de toute façon
modifier les `.prproj` directement : le jeton ne l'arrêterait pas. Côté fragilité, le seul endroit que
le plugin sait lire, son dossier `PluginData`, **disparaît** quand Adobe désinscrit le plugin (vécu le
2026-10-06, §6bis) : un jeton stocké là aurait cassé ⌘J à chaque mise à jour de Premiere.

⚠️ **Limite de ce raisonnement (audit sécurité A6, 2026-10-08)** : il ne vaut que pour un Mac à UN
compte. La boucle locale n'est pas cloisonnée par utilisateur : un AUTRE compte macOS du même Mac peut
se connecter au pont (sans en-tête `Origin`, donc accepté) alors qu'il ne peut pas lire les fichiers du
monteur. Mesuré sur le vrai `BridgeServer` (port de test). Par le pont, il peut : remplacer la session
(son `hello` éjecte le vrai plugin : ⌘J muet) et lire les plans appliqués ; déclencher des cycles UPIA
remove+install (un `hello` d'une autre version), qui peuvent bloquer UPIA (§6) ; et, s'il prend le
port 48123 avant Khanjar (qui quitte après 5 essais), piloter le plugin : `apply`, `getSelection`,
`dumpAllSelected`… (noms des clips et du projet). Pistes d'A6 : jeton injecté dans le ccx au packaging,
ignorer un `hello` de version inattendue, ne pas remplacer une session vivante (C-19), dire quelle app
tient le port au lieu de quitter en silence (C-13). PRIVACY.md le dit aux utilisateurs.
Faits dans l'app 0.8.4 (non vérifiés en vrai) : **C-19** — un `hello` ne remplace plus une session qui a
donné signe de vie depuis moins de 10 s (il faut donc prendre la session AVANT le vrai plugin, ou la
tenir en battant) ; **C-13** — port pris : fenêtre qui nomme l'app qui écoute ; **C-06** — toute connexion
en échec est fermée et une connexion sans `hello` l'est au bout de 10 s (avant : chaque poignée de main
refusée laissait un socket, 251 après 300 refus, le plafond de descripteurs de l'app : une page web
pouvait rendre ⌘J muet en quelques secondes) ; **C-01** — mise à niveau seulement vers une version plus
récente, une par 10 min (un `hello` d'une autre version n'enchaîne plus les cycles UPIA). Restent ouverts :
jeton, `hello` de version inattendue.

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

---

## 13. Audit du 2026-10-08 : règles en place dans l'app 0.8.4 / le plugin 0.7.3

> Correctifs des lots P, I, U, D et C intégrés dans le code le 2026-10-09 (plan de correctifs, dépôt
> privé). **Aucune de ces règles n'est vérifiée dans Premiere** : elles sont testées hors Premiere
> (selftest, `node plugin/test/*.test.js`), et chacune porte le test T-xx du plan à faire sur un projet
> jetable. Pas de ligne au §8 avant ces tests ; à fondre dans les sections ci-dessus ensuite. Décisions
> d'Isma : Q1 cadrage par rapport au neutre, Q2 annulations groupées, Q3 « un ⌘Z pour un effet, deux pour
> un preset avec réglages », Q4 duos même clip / 3 contre 1 sans masquage, Q5 favoris en une ligne, Q6 partie
> visible des shakes, Q7 macOS 13, Q8 raccourcis réservés, Q9 filtre d'origine « navigateur », Q11 pas de
> mention des rapports de plantage sans adresse d'envoi, Q12 icône reportée, Q14 rien publier.

**Plugin 0.7.3 (lot P)** — non vérifié dans Premiere.
- **Adapter au cadrage (P-01, Q1).** Avant : la référence était la 1ʳᵉ valeur du preset, donc une valeur
  fixe redevenait celle du clip (les 38 PiP Adobe ne bougeaient plus) et une animation qui arrive au repos
  s'inversait (110→100 devenait 100→90,9). Règle : référence = valeur NEUTRE — Échelle 100 → facteur
  actuelle/100 ; Position et Point d'ancrage (0,5 ; 0,5) → décalage ; Rotation 0 → écart — appliquée à
  toutes les valeurs du réglage, fixes comme keyframes. Réglage laissé tel quel si : lecture impossible,
  réglage déjà animé sur le clip, facteur non fini ou ≤ 0, transformation neutre. Clip au cadrage normal =
  exactement le natif ; zoom 100→120 sur un clip à 50 % = 50→60. Test T-02.
- **Annulation (P-02 + P-06, Q2).** Avant : insertion groupée, mais réglages clip par clip (1 + 1 à 4
  annulations par clip ; avec 32 niveaux d'annulation — le réglage de Premiere chez Isma — l'ajout
  lui-même n'était plus annulable au-delà de 16 à 32 clips). Règle : lectures async hors verrou pour tous
  les clips, chaînes relues juste avant le verrou, UN `lockedAccess` : T1 = réglages de TOUS les clips
  (try/catch par clip ; un clip qui lève passe en repli seul), T2 = interpolations non linéaires seulement
  (plus aucune action pour le linéaire, mode d'un keyframe neuf). Cible : 1 ⌘Z pour un effet nu, 2 pour un
  preset avec réglages, 3 avec maintien/bézier non cuit, quel que soit le nombre de clips ;
  `fidelity.transactions` le compte, `paramsSet` n'est compté qu'après une transaction réussie,
  `paramsFailedClips` liste les clips restés aux valeurs par défaut (PROTOCOL.md). Tests T-01, T-06. C'est ce
  qui rend vraie la promesse publique « deux ⌘Z ».
- **Pas d'effets en double (P-07).** Relecture des matchNames après l'insertion : effets reçus en partie, ou
  relecture impossible → rien n'est réinséré, clip annoncé non appliqué (`PARTIAL_INSERT`,
  `READBACK_FAILED`). Test T-06.
- **Ease à l'arrivée (P-03, Q13).** Un segment est cuit dès qu'une de ses DEUX poignées s'écarte de la corde
  (avant : seul le mode du keyframe de départ comptait — « Ease In » sur le dernier keyframe restait
  linéaire) ; un HOLD au milieu d'un réglage cuit reste un palier. Ces presets passent à une image-clé par
  image dans Options d'effet. Test T-03.
- **Shakes (P-09, Q6) et ancrage (P-10).** Plus de clamp à l'in-point : les keyframes situés AVANT
  l'in-point sont remplacés par UN keyframe à l'in-point portant la valeur de la courbe à cet instant
  (§3.2 item 0ter). Au-delà de 400 keyframes pour un réglage (`KEYFRAME_BUDGET`, `ease.js`), seule la partie
  visible est posée — de l'in-point jusqu'à la fin du clip + 1 image — plus un keyframe au bord portant la
  valeur de la courbe (cuite, linéaire ou tenue) ; même règle sur le chemin non cuit ; plafond de 2 000
  actions par clip (`MAX_ACTIONS_PER_CLIP`), au-delà réglages sautés (`TOO_MANY_KEYFRAMES`). Contrepartie :
  rallonger le clip ensuite n'allonge pas le shake. Tests T-07, T-08.
- **Plus de commandes simultanées (P-08 + C-02).** Le plugin répond `BUSY` si un `apply` ou un
  `addAdjustmentLayer` tourne déjà, `EXPIRED` si `expiresAt` est dépassé avant de commencer ; l'app garde
  son verrou au délai doux et livre la réponse tardive (délai dur 120 s) — détail : PROTOCOL.md « Délais ».
  Test T-04.
- **Calque d'effets ⌘⇧J (P-05).** Chutiers : on descend dans les dossiers, on ne renvoie jamais un dossier ;
  candidat = élément de clip dont le nom normalisé est « adjustment layer » ou sa traduction (fr, de, es, it,
  pt, ja, ko, ru, zh) ; piste libre sur TOUTE la durée du calque (avant : à la tête de lecture seulement, un
  B-roll plus loin était écrasé). Test T-05.
- **Journal du plugin (P-04).** Chaque tentative de connexion, erreur et code de fermeture écrits et vidés ;
  le client démarre sans attendre le journal ; session précédente gardée dans `khanjar-executor.prev.log` ;
  « req apply » écrit AVANT d'exécuter. À relire pendant T-09.
- **Échecs de préparation (P-11).** Un clip vidéo impossible à préparer va dans `failedClips`
  (`PREPARE_FAILED`), les autres sont appliqués ; `NO_APPLICABLE_CLIP` réservé au « que de l'audio ».

**Index, presets, usage (lot I)** — non vérifié dans Premiere.
- **Duos (I-01 + C-03, Q4).** Un enchaînement ne compte que si les deux applications ont au moins un nom
  de clip en commun (`applied.clipNames`, que l'app transmet depuis C-03) et moins de 120 s d'écart ; payload
  v3 : enchaînements remis à zéro (compteurs gardés), plus aucun rejeu des paires depuis le journal ; un sens
  n'est retenu qu'avec au moins 3 fois plus d'observations que l'inverse (et 4 au minimum) ; paires de plus
  de 60 jours ignorées. Limite : deux clips différents de même nom comptent comme un seul. Test T-13.
- **Ids des presets (I-02 + C-04, Q5).** `preset:<PresetUID>` inchangé ; sans UID : `preset:h:<16 hex>`
  (SHA-1 du chemin de dossiers, du nom, des matchNames et des réglages) au lieu du numéro d'objet XML que
  Premiere renumérote à chaque réécriture ; presets Adobe : `preset:adobe:<…>` (fin des collisions) ;
  un favori Premiere identique à un preset indexé n'a plus sa ligne ; snapshot **v7**. Test T-19.
- **Accès Documents (I-03 + C-08)** : voir lot C. **Raccourcis par position physique (I-04, Q8)** : un jeton
  de `settings.json` désigne la TOUCHE (nommée comme sur un clavier US-ANSI), affichée selon la disposition
  active ; ⌘A ⌘C ⌘V ⌘X ⌘Z ⌘⇧Z ⌘S ⌘Q ⌘W refusés ; un raccourci enregistré en AZERTY avant 0.8.4 reste sur la même
  touche physique mais s'affiche honnêtement (« ⌃⌥Q ») — à réenregistrer. Test T-12.
- **Divers** : chrono activé sans image-clé → valeur fixe posée, plus de faux « partiel » (I-05, T-17) ;
  recherche tolérante aux doubles espaces, tirets, insécables, voyelles arabes, noms anglais des effets
  `AE.Impact_*` (I-06) ; `usage.json` illisible mis de côté (`usage.json.illisible-<date>`), amorçage sans
  double compte (I-07) ; `settings.json` lu clé par clé, copie `settings.json.illisible-<date>` avant toute
  écriture (I-08) ; parseur : `<!DOCTYPE`/`<!ENTITY` refusés, valeurs non finies écartées, `<Type>` absent =
  0, couleur animée non compilée (I-09) ; Lumetri à section décochée compté « partiel » (I-10, T-16).

**Interface (lot U)** — non vérifié dans Premiere (T-12, T-20). ⌘1…⌘0 décidés par la touche physique
(AZERTY, Verr. Maj, ⌘⇧, pavé ; ⌘n sans ligne consommé sans bip) ; enregistreur de raccourci par position,
⌘ ou ⌃ obligatoire, raccourcis réservés refusés, arrêté quand sa fenêtre perd le focus ; réouverture après
échec sur la ligne choisie, texte sélectionné (avec C-09) ; menu Édition invisible (⌘A ⌘C ⌘V ⌘X ⌘Z dans les
champs) ; clavier pris avant de remplir la liste ; validation refusée = palette gardée (avec C-02 point 5) ;
annonces VoiceOver ; palette jamais sous le Dock ; HUD au thème de la palette, pied « ⌘1–⌘0 » ; conflits de
raccourcis vérifiés, échec d'inscription signalé une fois.

**Cœur de l'app (lot C)** — non vérifié dans Premiere sauf mention.
- **Installation du plugin (C-01) et état affiché (C-05)** : §6 (politique) et §6bis (filet). Tests T-09,
  T-10.
- **Délai dépassé (C-02)** : PROTOCOL.md « Délais » — verrou gardé au délai doux, réponse tardive livrée,
  `expiresAt`, messages S11-S17. **Point 5** : une validation refusée parce qu'une application tourne encore
  laisse la palette ouverte (`onCommitChecked` → `apply(_:origin:) -> Bool`). Test T-04.
- **Fréquents (C-03)** : la palette demande `top(limit × 2)` et `topPairs(5)`, saute les entrées absentes de
  l'index ou dont le titre normalisé diffère du titre mémorisé (membres des duos compris), puis coupe à la
  limite et à 2 duos (`AppCoordinator.frequentRows`, partagé avec le mode `frequents`).
- **Jamais un autre preset (C-04)** : un raccourci preset n'applique l'id mémorisé que s'il porte encore le
  titre mémorisé ; sinon recherche par titre, même genre (preset/effet) : un seul id → appliqué et rattaché
  (settings.json) ; aucun → « introuvable — réassigne-le » ; plusieurs → « plusieurs presets s'appellent… »
  (rien appliqué). Après chaque reconstruction : `UsageStore.remapUnknownIds` et
  `Settings.remappingUnknownShortcutIds` (titre → un seul id DISTINCT). Test T-19.
- **Accès Documents refusé (C-08)** : index et `index.json` gardés entiers, message S19 une fois par session,
  nouvel essai à ⌘J (1 fois/min au plus) et quand Premiere revient au premier plan ; presets PERSO disparus
  (les PiP Adobe ne comptent plus) → index gardé ; 0 effet → index gardé ; profil illisible → presets perso
  précédents gardés ; pas de fichier de presets → revérifié à chaque ⌘J ; journal de chaque reconstruction
  avec « 26.0/Profile-… » (profil masqué). Index VIDE + accès refusé : effets et presets Adobe installés sans
  snapshot. Raccourci preset pendant un refus → « « X » indisponible : accès Documents ». Limite : un monteur
  qui supprime TOUS ses presets perso les verra rester dans Khanjar. Test T-11.
- **Après un échec (C-09)** : la recherche ET la ligne validées sont reproposées au ⌘J suivant, seulement
  si l'échec vient de la palette (champ vide compris : les fréquents rouvrent sur la même ligne). Test T-20.
- **HUD et journal d'une application (C-10)** : avertissement dès qu'un clip, un réglage ou les réglages d'un
  clip manquent ; « réglages non posés sur N clips » ; réglages par clip quand ils se répartissent exactement ;
  journal `transactions=<n>` (début « apply OK : <titre>, <N> clips appliqués » inchangé) ; `settings.json`
  illisible ou à valeurs abîmées → S26, enregistrement impossible → S27 (branché AVANT `settings.load()`).
- **Journal (C-11)** : §4bis (`Khanjar.log.1`, horodatage fixe). Les instances de TEST (UsageStore,
  SettingsStore, PluginLifecycleService à faux UPIA, LegacyMigration en bac à sable) écrivent dans
  `Logger.muted` : un selftest n'écrit plus rien dans le journal.
- **Filtre d'origine (C-07, Q9)** : §12. **Connexions fermées (C-06)**, **IPv6 (C-18)**, **2ᵉ plugin refusé
  (C-19)** : PROTOCOL.md. **Port pris, 2ᵉ copie (C-13)** : §7. **Crochets de test (C-14)** : signaux
  USR1/USR2/WINCH/INFO seulement avec `KHANJAR_TEST_HOOKS=1` (§4). **Sparkle (C-12)** : « aucune mise à jour »
  n'est plus une erreur ; rappel discret = point sur l'icône + entrée « Mise à jour disponible… ».
  **Argument système au lancement (C-15)** : `-psn_…` → mode app (`LaunchMode.resolveMode`). **listEffects
  raté (C-16)** : nouveaux essais à +5, +15, +30 s ; ⌘J sans index ni construction → « quitte et rouvre
  Premiere ». **Snapshot hors du fil principal (C-17)**. **Ancien plugin Dagger (C-20)** : retiré une fois par
  session (en-tête).
- **Index provisoire (intégration du 2026-10-09)** : au premier lancement de l'app 0.8.4, le snapshot v6 est
  ignoré (ids périmés) ; l'app reconstruit HORS LIGNE un index provisoire avec les effets de l'ancien
  snapshot (lus quelle que soit sa version) et les presets reparsés (langue des presets Adobe : celle du
  Mac), sans écrire le snapshot ni rattacher d'ids ; le vrai index le remplace au hello. Journal :
  « Snapshot v6 (attendu v7) — index provisoire reconstruit hors ligne… ».

**Relecture finale (2026-10-11, `audit-2026-10-08/R-relecture-finale.md`)** — corrigé hors Premiere
(selftest, tests du plugin), non vérifié dans Premiere :
- **M1** : mise à niveau du plugin Premiere FERMÉ (§6, point 6) ; retrait de Dagger derrière la porte des 60 s.
  Rend sans objet **m4** (HUD contradictoires après une mise à niveau non rechargée). 2ᵉ relecture (même jour) :
  **F1** — arrêt entre `--remove` et `--install` si Premiere est rouvert, délais 30 s / 60 s, Creative Cloud
  requis ; **F3** — un renommage n'est bloqué que par un item du MÊME genre portant l'ancien titre (un preset
  « Drop Shadow » renommé garde son raccourci même si l'effet s'appelle ainsi). `verifyUpgrade` supprimé.
- **m1** : 1er lancement de la 0.8.4 avec accès Documents refusé — un index provisoire SANS presets perso est
  remplacé par les effets de Premiere au hello (`indexUpdate(currentIsProvisional:)`). Les presets perso
  restent absents jusqu'à l'autorisation (S19 le dit).
- **m2** : `TRANSACTION_FAILED` d'une application → « vérifie la timeline avant de réessayer » (une partie a pu
  être posée ; « réessaie » faisait poser en double).
- **m3** : preset renommé dans Premiere (même id, ancien titre porté par plus aucun item) → raccourci et ligne
  ⌘n gardés, titre mémorisé mis à jour à la reconstruction (`AppCoordinator.currentItem`, `retitleRenamed`,
  `retitlingRenamedShortcuts`). Ancien titre encore porté (copie au même PresetUID) → règle C-04 inchangée.
- **m5** : contrôles à +45 s ignorés après une relance de Premiere. **m8** : README « deux ou trois ⌘Z ».
  **m9** : une valeur abîmée de settings.json → message distinct (`valuesReset`). **m10** : HUD sous la palette
  quand elle reste ouverte. **m11** (plugin) : écriture du journal attendue 500 ms au plus avant une commande.
  **m12** : ARCHITECTURE.md alignée. **m14** : « N/M paramètres » par clip seulement pour des raisons communes à
  tous les clips. usage.json v1/v2 copié (`usage.json.v2`) avant la conversion en v3.
- Non corrigés (mineurs) : m6 (rattachement par titre tous genres confondus, 0 cas chez Isma), m7 (Réglages
  ouverts pendant une réécriture des ids, se corrige seul), m13 (plafond de 2 000 actions atteignable par un
  preset long à 5-6 réglages cuits : à surveiller).

**Docs et scripts (lot D)** : prompt d'installation Claude Code refait (D-01, Premiere fermé, Q10) ; guides
(macOS 13, désinstallation, anciens testeurs, plus de rapports de plantage, Q11) ; promesses publiques
(D-03, Q3) ; `build-app.sh` macOS 13 et licences (D-06, icône reportée Q12) ; `release.sh` refuse d'écraser
une version publiée (D-07, §10ter) ; `export-public.sh --update` refuse un clone pas à jour (D-08) ;
« Build from source » complet (D-09). `APP_VERSION` 0.8.4, publiée le 2026-10-11 (Isma : « OK, publie sur
GitHub ») ; README public refait le même jour : bannière et image « un seul geste » générées par IA (GPT Image
2.5 via Atlas Cloud, à partir du visuel du site), graphique d'usage et schémas dessinés en SVG
(`public/docs/media/*.svg`), `llms.txt` à la racine pour les agents.
