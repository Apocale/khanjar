# Recherche — Fidélité native des presets (2026-07-21)

> Rapport de recherche **sans code** : pourquoi le résultat Dagger diffère du drag-and-drop
> natif de Premiere, et quels mécanismes permettent de reproduire le comportement natif.
> Cas d'étude : preset « TR - Apple Appear Up » (captures Effect Controls natif vs Dagger).
> Statut : AUCUNE implémentation faite — décisions en attente (voir §6).

---

## 1. Constat (captures + fichier .prfpset)

Le preset « TR - Apple Appear Up » contient **UN seul effet** : Transform (`AE.ADBE Geometry2`).
Le Gaussian Blur visible sur les deux captures est un état **préexistant des clips** (statique 25
sur l'un, keyframé 59 sur l'autre) — c'est du bruit, pas un défaut Dagger.

| # | Natif | Dagger | Gravité |
|---|---|---|---|
| 1 | Keyframes **Bézier avec ease** : icônes sablier, vélocité 0 aux extrémités, influence 33 %/100 %, courbe en S | Keyframes **Linéaires** (icône losange = linéaire, sémantique officielle Adobe) | Différence visuelle principale |
| 2 | Position `277,6` au playhead — colle à la courbe stockée du preset à 0,2 px près | Position `289,3` — **hors de la plage de valeurs permise par les keyframes** → une 2ᵉ erreur de rejeu distincte | À confirmer empiriquement |
| 3 | Effet ajouté en **BAS** de la pile (le drag-and-drop natif fait un append) | Inséré en **HAUT** (choix v0.6.1, demandé par l'utilisateur pour les graphiques) | Divergence délibérée — décision produit à trancher |
| 4 | Titre `Transform (TR - Apple Appear Up)` | `Transform` nu | Cosmétique |

Le suffixe entre parenthèses vient du **nom du TreeItem du preset au moment de l'application**
(Premiere écrit ce nom dans l'InstanceName du composant à l'apply) — l'InstanceName stocké
dans le .prfpset est un instantané périmé et est ignoré à l'application.

## 2. Format CSV des keyframes .prfpset — DÉCODÉ (validation : 33 085 keyframes du fichier réel)

> Aucune documentation publique n'existe ; décodage auto-validé empiriquement.
> Ticks/seconde = 254 016 000 000. StartKeyframe : même layout, temps sentinelle
> −91 445 760 000 000 000 (= −360 000 s), ease à zéro.

### Scalaires (`VideoComponentParam` / `AudioComponentParam`) — toujours 8 champs

| # | Sens | Confiance |
|---|---|---|
| 0 | temps, ticks absolus | certaine |
| 1 | valeur | certaine |
| 2 | mode d'interpolation temporelle (`kfInterpMode`) : 0 Linéaire, 4 Hold, 5 Bézier (1–3 = Ease obsolètes, 6–8 = time-remap) | certaine |
| 3 | verrouillage des poignées : **0 = libres, 2 = Auto Bézier, 4 = Bézier Continu** | haute |
| 4 | **vélocité entrante** (unités/s) — sur segment linéaire = pente exacte de la corde | certaine |
| 5 | **influence entrante** (fraction 0–1 ; 1/6 = placeholder linéaire, 1/3 = défaut bézier 33,33 %, 1 = 100 %) | haute |
| 6 | **vélocité sortante** (unités/s) | certaine |
| 7 | **influence sortante** (fraction 0–1) | haute |

C'est exactement le modèle `KeyframeEase` d'After Effects (vitesse + influence par côté).
Points de contrôle temporels : x = `t0 + outInf·Δt` / `t1 − inInf·Δt` ; y = `v0 + outVel·(outInf·Δs)` / `v1 − inVel·(inInf·Δs)`.

### Points (`PointComponentParam`, ex. Position) — toujours 14 champs

Champs 0–7 idem (les vélocités sont une **vitesse scalaire le long du chemin**, en unités
d'image normalisées/s), puis :

| # | Sens | Confiance |
|---|---|---|
| 8 | mode d'interpolation spatiale (5 = Bézier, seule valeur observée) | moyenne-haute |
| 9 | verrouillage spatial (4 = lié/miroir — 16 177/16 181 ; 0 = cassé) | moyenne |
| 10–11 | **tangente spatiale entrante** (x, y), offset relatif au keyframe, coords normalisées | haute |
| 12–13 | **tangente spatiale sortante** (x, y) | haute |

Validation clé : pour les keyframes intérieurs « auto », la tangente stockée = construction
Catmull-Rom exacte `(P_next − P_prev)/6` ; keyframes lisses : inTan = −outTan (15 970/15 997).

**Vérification numérique sur le preset étudié** : l'intégration de la courbe décodée prédit
Position y ≈ **277,4 px** au playhead de la capture native (mesuré : 277,6). Le 289,3 de
Dagger est **hors plage** → erreur supplémentaire au rejeu, indépendante de l'ease.

## 3. Causes racines (3, indépendantes)

1. **Le parser jette l'ease au parsing.** `PrfpsetParser.parseKeyframes` ne lit que les champs
   0–2 ; vélocités/influences/tangentes n'atteignent jamais l'ApplyPlan (vérifié dans
   `index.json` : les keyframes compilés = `{t, value, i}` seulement).
2. **Même le MODE bézier ne se pose pas** (losanges = linéaire). Suspect n° 1 : Dagger groupe
   `createAddKeyframeAction` + `createSetInterpolationAtKeyframeAction` dans **UNE** transaction
   composée ; l'échantillon officiel Adobe (`keyframe.ts`) fait **DEUX `executeTransaction`
   séparées** sous un même `lockedAccess` (on ne peut pas cibler un keyframe qui n'existe pas
   encore au moment de la création de l'action). Pièges secondaires documentés : l'enum TS
   `Constants.InterpolationMode` est déclaré par ordre ALPHABÉTIQUE (le vrai BEZIER natif = 5,
   pas 0 — toujours passer les constantes runtime, jamais des littéraux) ; la base de temps doit
   inclure l'in-point du clip (déjà géré par Dagger).
3. **Plafond d'API réel, côté Adobe.** Surface 26.3.0 ET 26.5-beta intégralement extraites et
   diffées (`@adobe/premierepro` sur npm) : **AUCUNE API** pour poignées d'ease
   (vélocité/influence), tangentes spatiales, ni InstanceName. Adobe l'a publiquement différé
   (« parité CEP d'abord »). Un BEZIER posé par API reçoit des poignées **auto-calculées
   (Catmull-Rom)** ≠ l'ease stockée du preset ; dépassement (overshoot) possible.
   ExtendScript/CEP/QE : rien de plus + EOL ~sept. 2026. Rejeté.

## 4. Mécanismes pour reproduire le natif

### Palier 1 — corriger le rejeu UXP (~90 % du rendu visuel)

1. **Interpolation en 2ᵉ transaction** (motif officiel Adobe) pour que BEZIER se pose vraiment.
   Vérifier par relecture `getKeyframePtr` → `getTemporalInterpolationMode` (le harnais ne le
   fait pas encore).
2. **Parser les 8/14 champs** et les préserver dans le plan (prérequis de tout le reste, coût nul).
3. **Technique des « keyframes façonneurs »** (shaper keyframes, documentée par ZoomAssist Pro) :
   poser temporairement des keyframes intermédiaires sur la courbe eased exacte (calculable —
   on a maintenant les données), passer en BEZIER pour que Premiere dérive ses poignées de ces
   voisins, puis les supprimer — **les poignées calculées persistent**. Ease quasi native, 100 %
   API publique.
4. Option de secours : cuire des keyframes linéaires denses (rendu exact, UI moche).

### Palier 2 — voie réellement native (plafond 100 %, spike de validation requis)

Premiere sérialise les effets copiés via le **presse-papiers système** (famille de flavors
`PProAE/Exchange/…`, ex. `VideoComponent2`, trouvée dans le binaire 26.3 ; l'équivalent Windows
a déjà été dumpé/rejoué par des tiers — sebinside/PremiereClipboard).

- **Variante projet-donneur (risque moindre)** : Dagger écrit un `.prproj` donneur (même schéma
  XML PremiereData que le .prfpset → CSV ease/tangentes embarqué **octet pour octet**), l'importe
  silencieusement via `importSequences`, pilote la sélection par UXP, et n'injecte que
  ⌘C puis ⌥⌘V+Entrée (Coller les attributs). Premiere fait toute la sérialisation ; fidélité
  totale, InstanceName compris. Coût : ~1–2 s, flicker de séquence, permission Accessibilité.
- **Variante presse-papiers direct (plus rapide, plus fragile)** : forger le payload nous-mêmes.
  Spike préalable : copier un effet dans Premiere, dumper les types/octets de `NSPasteboard`,
  confirmer le schéma.
- Veille : le binaire 26.3 contient des docstrings d'API **non publiées** `copyItems`/`pasteItems`
  → des API presse-papiers UXP arrivent ; revérifier `api_config.json` à chaque beta.

### Rejetés après enquête

ExtendScript/QE (même plafond + EOL) ; double-clic/raccourci (n'existe PAS pour les presets —
effets seulement) ; drag AX sur le panneau Effets (panneaux dvaui quasi opaques à
l'accessibilité) ; MOGRT/AE (ne décore pas un clip existant).

## 5. Ordre de la pile — décision produit en attente

Les captures prouvent que le natif **append en BAS** ; l'insert-en-HAUT v0.6.1 (demandé, et qui
règle le cas des graphiques) est une divergence délibérée. « Exactement natif » et « toujours en
haut » sont mutuellement exclusifs par apply. Recommandation : garder haut par défaut, en faire
une politique (par preset ou par type de clip) — **à confirmer par l'utilisateur**.

## 6. Séquence recommandée à l'implémentation (rien n'est fait)

1. Fix interpolation 2-transactions + relecture du mode dans le harnais (petit, immédiat).
2. Parsing complet 8/14 champs → format de plan (travail données pur).
3. Sculptage d'ease par keyframes façonneurs derrière un flag de fidélité ; mesurer vs natif
   avec le harnais d'échantillonnage existant.
4. En parallèle : spike dump du presse-papiers pour chiffrer le Palier 2 ; ne livrer la voie
   projet-donneur que si le spike confirme et que le coût UX (~1–2 s) est accepté.

## Sources principales

- Typings officiels : `@adobe/premierepro` 26.3.0 / 26.5.0-beta.61 (npm) — copies locales du
  scratchpad de session (re-télécharger au besoin).
- Échantillon officiel : AdobeDocs/uxp-premiere-pro-samples `sample-panels/premiere-api/src/keyframe.ts`.
- Fils communauté : « custom bezier keyframe interpolation » (1417205), « unable to set multiple
  keyframes with UXP » (1548880), « setInterpolationTypeAtKey » (10987274).
- Icônes keyframes : guide Adobe interpolation (losange=linéaire, sablier=bézier/ease,
  cercle=auto-bézier, demi-carré=hold).
- Technique shaper : documentation ZoomAssist Pro.
- Presse-papiers : github.com/sebinside/PremiereClipboard ; strings du binaire 26.3
  (`PProAE/Exchange/VideoComponent2`, `copyItems`/`pasteItems`).
- Fichier analysé : `~/Documents/Adobe/Premiere Pro/26.0/Profile-<nom>/Effect Presets and Custom Items.prfpset`.
