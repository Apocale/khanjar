# TODO — Fidélité native (« comme un effet posé à la main »)

> Liste d'actions consolidée et priorisée (2026-07-22). **Objectif** : qu'un effet
> ou preset appliqué par Dagger se comporte comme un effet posé à la main (glisser-déposer
> natif) dans Premiere Pro 2026.
>
> Ce document ne contient QUE le « quoi faire ». La recherche et le pourquoi (format
> keyframes .prfpset décodé, plafond d'API, voies presse-papiers / projet-donneur) vivent
> dans `docs/RECHERCHE-FIDELITE-NATIVE.md`. Les statuts vérifiés et les limites connues sont
> dans `AGENTS.md` §8 (« État vérifié » / « Non vérifié »), §9 (« Limites ») et §10
> (« Prochaines étapes »). Les jalons M0–M7 sont dans `README.md`.
>
> Convention : chaque item de rejeu porte **Quoi / Où (fichier:ligne) / Comment vérifier**
> (harnais CLI du helper, cf `AGENTS.md` §4). Les numéros de ligne renvoient à l'arbre de
> travail v0.6.2 en cours (non committé).

---

## P0 — Validations utilisateur en attente (bloquent le jugement de fidélité)

Ces points ne sont pas du code : ce sont des jugements ou des actions qui n'appartiennent
qu'à l'utilisateur. Tant qu'ils ne sont pas faits, on ne peut pas affirmer « c'est fidèle ».

1. **Test visuel des presets animés (v0.6.0) sur de vrais clips.** Les harnais prouvent que les
   paramètres attendus se posent sans rejet, **pas** que le rendu dans le moniteur programme est
   identique au natif — cf `AGENTS.md` §8 (« Non vérifié », lignes 239-241) et §10.1. Cas d'étude
   documenté : « TR - Apple Appear Up » (Transform + Blur, 45 params, 0 sauté — `AGENTS.md` §8)
   et « Headline Logan » (preset utilisateur, présent dans `Effect Presets and Custom Items.prfpset`
   du profil Premiere — hors dépôt). À juger à l'œil : fondus, glissements, courbes.
2. **Test ⌘⇧J (calque d'effets) avec un adjustment layer présent dans le projet.** L'API ne permet
   PAS d'en créer (DVATA-710) : Dagger réutilise un calque existant (séquence active puis chutier)
   et affiche un message HUD explicite s'il n'y en a aucun — `AGENTS.md` §3.1 item 11 + §10.1,
   `README.md` (jalon « Raccourci calque d'effets »).
3. **Décision produit : ordre de pile.** Dagger insère les effets en **HAUT** de la pile
   utilisateur (v0.6.1, `AGENTS.md` §3.1 item 13) ; le natif drag-drop les **appose en BAS**
   (append). « Exactement natif » et « toujours en haut » sont mutuellement exclusifs — cf
   `RECHERCHE` §5. Recommandation de la recherche : garder « haut » par défaut, en faire une
   politique (par preset / type de clip). **À confirmer par l'utilisateur.**
4. **Supprimer `/Applications/Dagger.app`** (copie root, `sudo rm -rf /Applications/Dagger.app`).
   Sans ça, une ancienne instance peut ressusciter des doublons (dispute du port 48123 et des
   raccourcis) — `AGENTS.md` §7 (« Action utilisateur en attente », lignes 222-223).

---

## P1 — Fidélité du rejeu (Palier 1, ~90 % du rendu visuel via UXP)

Rangés du plus visible au plus marginal. Chaque item est **Quoi / Où / Comment vérifier**.

### 1. Intrinsèques : REMPLACER les keyframes existants au lieu de les FUSIONNER

- **Quoi** : le natif *remplace* l'animation d'un intrinsèque (Opacity/Motion) quand on
  réapplique un preset ; Dagger ne fait qu'*ajouter* des keyframes par-dessus ceux déjà présents.
  Divergence visible sur un clip déjà keyframé ou en cas de double application.
- **Où** : `plugin/src/premiere/apply.js` — `buildParamActions` (lignes 137-198) n'émet que
  `createSetTimeVaryingAction(true)` (l.177) puis `createAddKeyframeAction` (l.182) ; il ne
  supprime jamais l'existant. Point de correction : dans `applyExistingOps` (lignes 328-391),
  énumérer les keyframes présents via `cp.getKeyframeListAsTickTimes()` (déjà utilisé dans
  `plugin/src/premiere/harness.js` l.194 et l.335) puis `cp.createRemoveKeyframeAction(...)`
  (déjà utilisé dans `harness.js` l.317) **avant** de poser ceux du preset. À décider : nettoyer
  seulement les params ciblés par le preset, jamais toute la chaîne.
- **Comment vérifier** : `dagger-helper apply-dump <média> "<preset>"` puis **réappliquer** et
  redumper — le nombre de keyframes ne doit pas doubler. Complément : `dagger-helper fidelity-test`.

### 2. Ease sculpting « keyframes façonneurs » derrière un flag de fidélité

- **Quoi** : c'est **LA** divergence visuelle principale (RECHERCHE §1). Les poignées d'ease
  (influence/vitesse) NE SONT PAS réglables par l'API UXP (26.3 ET 26.5-beta) : un keyframe posé
  en BEZIER reçoit des poignées auto (Catmull-Rom, alignées sur la corde) → la courbe reste
  linéaire, seule l'icône change (`AGENTS.md` §3.1 item 6, RECHERCHE §3). Contournement **validé**
  (spike `ease-probe`, 2026-07-21) : poser un keyframe intermédiaire « façonneur » sur la courbe
  voulue, tout passer en bézier, puis le supprimer — les poignées calculées **persistent**. Ease
  obtenue PARTIELLE (mesuré 21,87 au lieu de 15,6 visé) → calibrage/itération à faire, sous un flag.
- **Où** : `AGENTS.md` §3.1 item 7 (lignes 83-89) ; prototype `easeProbe` dans
  `plugin/src/premiere/harness.js` (lignes 269-337, commentaire 254-268) ; CLI `ease-probe` dans
  `helper/Sources/DaggerHelper/main.swift` (lignes 601-639). À productiser : intégrer le calcul
  du façonneur dans le pipeline de pose (`apply.js`), derrière un flag, en réutilisant les données
  d'ease une fois l'item P1.3 fait.
- **Comment vérifier** : `dagger-helper ease-probe [--keep-shaper]` (mesure de contrôle vs test réel).

### 3. Parser TOUS les champs keyframe (3–13), pas seulement 0–2

- **Quoi** : prérequis (coût données pur) du façonneur d'ease (P1.2) et du Palier 2 (P3). Le parser
  ne lit aujourd'hui que le temps (champ 0), la valeur (champ 1) et le mode (champ 2) et **jette**
  les champs 3–13 : verrou de poignées, vélocité/influence entrante et sortante (scalaires) et
  tangentes spatiales (points) — cf RECHERCHE §2 (schémas 8 et 14 champs) et §3.
- **Où** : `helper/Sources/DaggerHelper/Presets/PrfpsetParser.swift` — `parseKeyframes`
  (lignes 174-194 ; l.183 lit `fields[2]`, rien au-delà). Stocker ces champs dans l'ApplyPlan
  (`PresetKeyframe`) pour les propager au plugin.
- **Comment vérifier** : `dagger-helper index-presets` (test du parseur hors ligne) — confirmer que
  les nouveaux champs apparaissent dans l'index compilé.

### 4. Intrinsèques manquants du set (`AE.ADBE Vector Motion` et cousins)

- **Quoi** : `AE.ADBE Vector Motion` est cité comme intrinsèque dans un commentaire de `apply.js`
  (l.47) mais est **ABSENT** de la liste `intrinsicMatchNames`. Conséquence : un preset qui l'anime
  n'est ni ajoutable ni reconnu comme intrinsèque → il tombe en `trulyMissing` (silencieusement
  ignoré). Auditer aussi les autres intrinsèques non-ajoutables (Geometry, crop…).
- **Où** : `helper/Sources/DaggerHelper/Index/IndexStore.swift` — `intrinsicMatchNames`
  (lignes 47-49 : contient seulement Opacity, Motion, Time Remapping, MotionBlur) ; catégorisation
  `trulyMissing` en l.108.
- **Comment vérifier** : `dagger-helper index-presets` (compte des `trulyMissing`) puis
  `dagger-helper apply-dump <média> "<preset animant Vector Motion>"`.

### 5. Keyframes de COULEUR silencieusement perdus

- **Quoi** : `parseKeyframes` renvoie `nil` pour toute valeur qui n'est ni numérique ni un point
  `"x:y"` → les animations de couleur keyframées sont **supprimées sans avertissement**. (Les
  valeurs de couleur *statiques* sont, elles, gérées via `decodePackedColor`.)
- **Où** : `PrfpsetParser.swift` l.192 (`return nil // couleur/valeur non gérée en keyframe pour
  l'instant`). Lié à P1.3 (élargir `parseKeyframes`).
- **Comment vérifier** : `dagger-helper index-presets` sur un preset à couleur animée, puis
  `dagger-helper apply-dump`.

### 6. Ancrage temporel — cas limites, dégrader avec AVERTISSEMENT plutôt qu'en silence

- **Quoi** : `keyframeTicks` (`apply.js` lignes 113-123) gère les 3 types d'ancre, mais :
  - Type 2 (Sortie) clampe via `Math.max` (l.120) → un clip plus court que le preset empile les
    keyframes sur l'in-point ;
  - `srcDur == 0` ou `durTicks == 0` → dégradation **SILENCIEUSE** en Type 1 (l.116, l.119, l.122) ;
  - `timeCtx` illisible → repli `{inTicks:0, durTicks:0}` (posé en l.264/l.330, catch l.272/l.337).
  Décision : émettre un détail de fidélité (avertissement) au lieu de dégrader en silence.
- **Où** : `apply.js` `keyframeTicks` (113-123) ; contexte temporel dans `applyParamsPostInsert`
  (l.264-272) et `applyExistingOps` (l.330-337).
- **Comment vérifier** : `dagger-helper anchor-test "<preset>"` (échantillonne à 2/50/98 % de la
  durée du clip) sur un clip plus court que la source du preset.

### 7. Robustesse du filet verify+retry

- **Quoi** : `receivedEffect` ne vérifie que le **nombre** de composants, pas les matchNames — un
  clip peut « compter juste » avec le mauvais effet. Et la pose des paramètres n'a **AUCUN retry** :
  un readback raté saute les params en silence.
- **Où** : `apply.js` — `receivedEffect` (lignes 475-480, l.478 : `getComponentCount() >= baseline
  + N`) ; absence de retry dans `applyParamsPostInsert` (détails `POST_INSERT_READBACK_FAILED` l.278,
  `INSERTED_RUN_NOT_FOUND` l.283) et `applyExistingOps` (`EXISTING_READBACK_FAILED` l.340).
- **Comment vérifier** : `dagger-helper multi-test "<preset>"` (vérification par clip à l'échelle) +
  `dagger-helper fidelity-test`.

### 8. Interpolation en deux transactions — ✅ FAIT en v0.6.2 (à committer)

- **Statut** : **DÉJÀ IMPLÉMENTÉ** dans l'arbre de travail — ce n'est plus un TODO. Le mode
  d'interpolation (bézier/hold) est posé dans une **2ᵉ** transaction, après que les keyframes
  existent : `buildInterpolationActions` (`apply.js` lignes 203-216), appelé en T2 dans
  `applyParamsPostInsert` (l.306-316) et `applyExistingOps` (l.376-385) ; motif documenté
  `AGENTS.md` §3.1 item 5 (lignes 71-77). Reste à **committer** (cf Dette documentaire ci-dessous).
- **Sous-lacune restante** : sur les paramètres de **POINT** (Position…), `PointKeyframe` n'expose
  ni `get`- ni `setTemporalInterpolationMode` (26.3) — le mode posé n'est **pas relisible** : le
  harnais `readKeyframeModes` le marque « non lisible (PointKeyframe) » (`harness.js` lignes
  201-207 ; `AGENTS.md` §3.1 item 8). Le chemin `INTERP_REJECTED` (`apply.js` l.211-212) capte les
  refus. *À confirmer par mesure* : si le mode est effectivement rejeté sur les points ou seulement
  invérifiable — seul l'échantillonnage de valeurs témoigne alors de la forme de la courbe.
- **Comment vérifier** : `dagger-helper apply-dump` / `dagger-helper stack-test` (relisent
  `keyframeModes` → « bézier (sablier) ») ; `dagger-helper anchor-test` pour la forme des params
  de point.

---

## P2 — Parité de périmètre (ce que le natif fait, pas encore Dagger)

1. **Transitions.** `TransitionFactory` existe dans l'API 26.3 mais **aucun code ne l'utilise**
   (vérifié : zéro occurrence dans `plugin/` et `helper/`) — piste réelle, spike à faire.
   `AGENTS.md` §9 et §10.6.
   *Vérif du spike* : à définir (aucun harnais existant).
2. **Effets audio.** Capability annoncée `audioEffects: false` (`plugin/src/env/probe.js` l.19) ;
   les clips audio sont sautés à l'apply (compteur `skippedNonVideo`, `apply.js` l.445/454/457/525).
   *Vérif* : `dagger-helper multi-test` sur une sélection incluant un clip audio.
3. **Effets master clip.** Aucun chemin master-clip (vérifié : zéro `getMasterClip`/« master clip »
   dans le code) — tout l'apply passe par le `componentChain` du `trackItem` (`item.getComponentChain()`).
   *Vérif* : `dagger-helper apply-dump`.
4. **Presets d'usine (Adobe).** Chemin codé en dur `en_US` + « Adobe Premiere Pro 2026 »
   (`IndexStore.swift` lignes 183-186 ; identique dans `main.swift` l.143) → installations
   non-anglaises ou versions futures = **0 preset d'usine indexé**.
   *Vérif* : `dagger-helper index-build` (requiert Premiere + plugin) ou `index-presets`.

---

## P3 — Palier 2 (plafond 100 %)

**Spike presse-papiers / projet-donneur** (exploratoire, item unique). Chiffrer la voie « vraiment
native » : copier/coller d'effets depuis un projet donneur préparé (même schéma XML `PremiereData`
que le .prfpset, CSV ease/tangentes embarqué octet pour octet), importé silencieusement, sélection
pilotée par UXP, puis ⌘C / ⌥⌘V (Coller les attributs). Fidélité totale (InstanceName compris) mais
coût UX ~1–2 s + permission Accessibilité — cf `RECHERCHE` §4. Ne livrer que si le spike confirme.
*Aucun harnais existant : le spike doit d'abord dumper les flavors `NSPasteboard`.*

---

## Plafonds API (non actionnables — à documenter, PAS à coder)

| Limite | Preuve | Effet sur la fidélité |
|---|---|---|
| Poignées d'ease (influence/vitesse) NON réglables | `AGENTS.md` §3.2 item 0bis (l.126-128), §3.1 item 6 | Bézier auto (corde) ≠ ease stocké → objet du contournement P1.2 |
| Tangentes spatiales NON réglables | RECHERCHE §3 ; `AGENTS.md` §3.2 item 0bis | Trajectoires de Position approximées |
| Roues/courbes Lumetri & params opaques (`isArb` filtrés) | `IndexStore.swift` l.57 ; `AGENTS.md` §3.2 item 5, §9 | Presets Lumetri partiels |
| Masques non transférables | `AGENTS.md` §9 | Perdus |
| Création d'un calque d'effets impossible (DVATA-710) | `AGENTS.md` §3.1 item 11, §9 | Réutilisation d'un existant obligatoire (P0.2) |
| `InstanceName` « (Preset) » non réglable | RECHERCHE §1 (l.21-25), §3 | Cosmétique : titre `Transform` nu vs `Transform (nom)` |

---

## Dette documentaire / hygiène (liée à la fidélité)

1. **Capability `keyframes` incohérente entre docs.** `plugin/src/env/probe.js` l.20 et
   `docs/PROTOCOL.md` l.27 annoncent `keyframes: false` alors que les keyframes SONT implémentés
   (M4). `docs/ARCHITECTURE.md` l.182 dit déjà `keyframes:true` → les docs se contredisent ; le
   payload `hello` envoyé au runtime (probe.js) est la source de vérité et affiche `false`.
2. **`README.md` (jalon M4.2, lignes 65-66)** décrit un bug d'interpolation (« bezier/hold →
   linéaire », `createSetInterpolationAtKeyframeAction` écrase le kf t=0) **corrigé depuis** par la
   2ᵉ transaction (cf P1.8). À rapprocher du code actuel — de même que `AGENTS.md` §9/§10.2 et la
   case `M4.5` restée cochable.
3. **Committer le travail en cours.** Un seul commit existe (`651df15`, v0.6.1). L'arbre porte des
   modifications v0.6.2 non committées (`apply.js`, `harness.js`, `main.swift`, `probe.js`,
   `manifest.json`, `index.js`, `AGENTS.md`) + le fichier `docs/RECHERCHE-FIDELITE-NATIVE.md`
   non suivi. À figer en commit(s).

---

## Hors périmètre de ce document

Le **M7 durcissement** (tests de chaos — tuer Premiere/le plugin en cours d'apply —, teardown des
projets de test `/tmp/dagger-*.prproj`, revue mémoire/perf ; `AGENTS.md` §10.3, `README.md`) relève
de la robustesse, **pas** de la fidélité native. Idem : distribution (signature/notarisation),
sécurité du pont WebSocket.
