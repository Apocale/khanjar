# Protocole du pont Khanjar — v1

Transport : WebSocket texte, boucle locale uniquement : le pont écoute `127.0.0.1:48123` et, depuis
l'app 0.8.4, `[::1]:48123` (C-18), le plugin se connecte à `ws://localhost:48123` (UXP refuse les
adresses IP dans sa règle réseau, cf. AGENTS.md §3.1 item 16). Sur macOS, localhost se résout d'abord en
`::1` : l'UXP de Premiere 26.5.2 se rabat sur 127.0.0.1, un autre pourrait ne pas le faire. L'écoute
`::1` est un plus : son échec est journalisé (« Écoute IPv6 [::1] indisponible… ») et rien d'autre.
Serveur = l'app Khanjar (Swift, `BridgeServer`). Client = le plugin Khanjar (UXP, id `io.khanjar.executor`).
Encodage : JSON UTF-8, un message par frame.

Les ajouts du contrat de l'audit du 2026-10-08 (§4.1 du plan de correctifs) sont marqués
**[0.7.3]** : ils arrivent avec le plugin 0.7.3 et l'app 0.8.4 (correctifs P-08, P-06, P-02 côté plugin ;
C-02, C-10 côté app), intégrés dans le code le 2026-10-09 — **non vérifiés dans Premiere** (tests T-01,
T-04, T-06 du plan). Une app 0.8.3 ignore les champs ajoutés et affiche son message générique pour
`BUSY`/`EXPIRED` ; un plugin 0.7.2 ignore `expiresAt`.

## Poignée de main : filtre d'origine

Le serveur lit l'en-tête `Origin` de la poignée de main (`BridgeServer.isRefused(origin:)`). Règle de
l'app 0.8.4 (C-07, décision Q9 d'Isma) : refuser ce qu'un **navigateur** peut émettre, accepter le reste.
Elle ne regarde que le schéma, sans casse ni espaces autour :

- **refusé** (HTTP 400) : `http`, `https`, `data`, `blob`, tout schéma qui finit par `-extension`
  (`chrome-extension`, `moz-extension`, `safari-web-extension`…) et la valeur `null` (page dans une iframe
  « sandbox », URL `data:`). Journal : « Connexion refusée : origine web « … » — … », au plus **une ligne par
  minute et par origine**, avec le nombre de refus tus entre-temps (avant : une ligne `[error]` à chaque essai,
  toutes les 2 s, ~7 Mo par jour) ;
- **accepté** : pas d'en-tête `Origin` (un client qui n'est pas un navigateur), `file://` (ce qu'annonce le
  plugin UXP, relevé sur Premiere 26.5.2 seulement) et tout autre schéma non web (`uxp://…`). Chaque origine
  acceptée est journalisée une fois : « Client WebSocket accepté — origine annoncée : … ».

Historique : la 0.8.3 publiée n'écartait que `http`, `https` et les extensions (`null` acceptée) ; le commit
12b5fdb (jamais publié) n'acceptait que `file://` — un UXP qui annoncerait autre chose (Premiere 26.0-26.4,
2027) aurait eu un ⌘J mort. ⚠️ La règle Q9 reste à faire valider par l'audit sécurité, et à confronter à la
ligne « origine annoncée » des amis (test T-14).
Un client **sans** en-tête `Origin` est accepté sans autre contrôle : un programme du Mac, y compris sous un
autre compte macOS, peut se présenter comme le plugin (audit sécurité A6). Pas de jeton partagé — raisons
dans `AGENTS.md` §12.

Connexions (C-06, app 0.8.4) : toute connexion en échec est fermée (`cancel`), la session aussi quand elle
tombe, et une connexion qui n'a pas dit `hello` au bout de **10 s** est fermée (« Connexion sans hello depuis
10 s — fermée »). Avant, aucune n'était jamais annulée : un socket perdu par fermeture de Premiere ou par
poignée de main refusée, jusqu'au plafond de descripteurs de l'app.

## Enveloppe

Tout message porte :

| Champ | Type | Rôle |
|---|---|---|
| `v` | int | Version de protocole (actuel : `1`) |
| `kind` | `"req"` \| `"res"` \| `"event"` | Nature |
| `id` | string (uuid) | Corrélation req/res (absent des events) |
| `expiresAt` | nombre, ms depuis 1970 | **[0.7.3]** Requêtes `apply` et `addAdjustmentLayer` seulement : échéance au-delà de laquelle le plugin ne doit plus COMMENCER la commande (→ `EXPIRED`). Absent = pas d'échéance |

Les autres champs d'une requête (`cmd`, `plan`, `options`…) sont au même niveau que l'enveloppe.

Compatibilité : le plugin répond `PROTOCOL_MISMATCH` si `v` > sa version.

## Événements (plugin → app)

### `hello` — à chaque (re)connexion, obligatoire avant toute requête
```json
{ "v":1, "kind":"event", "type":"hello",
  "plugin": { "id":"io.khanjar.executor", "version":"0.7.2" },
  "host":   { "app":"premierepro", "version":"26.5.2", "uiLocale":"en_US" },
  "capabilities": { "audioEffects": false, "keyframes": true } }
```
L'app journalise `hello : <id> <version> — <app> <version> (<locale>)` : c'est la ligne que cherche le
prompt d'installation (`docs/INSTALL.md`, étape 7) — ne pas en changer le début.

- `plugin.id` = `com.dagger.executor` (ancien plugin Dagger) : refusé (socket fermée) ; l'app demande à UPIA
  de retirer « Dagger Executor », **une fois par session de l'app** (C-20 ; UPIA occupé → nouvel essai à
  +2 min). Jusqu'à la 0.8.3, un marqueur `~/Library/Application Support/Khanjar/.legacy-plugin-removed`
  rendait ce retrait définitif : il n'est plus ni lu ni écrit (un fichier resté là est sans effet) ;
- tout autre id inattendu, ou hello illisible : refusé (socket fermée) ;
- une nouvelle connexion valide remplace la session précédente **seulement si celle-ci n'a donné aucun signe
  de vie depuis 10 s** (C-19, app 0.8.4 ; tout message de la session compte : battement, réponse…). Sinon le
  nouveau venu est refusé (socket fermée), journal « Second plugin refusé (Premiere …, plugin …) : la session
  en cours bat encore — deux Premiere ouverts ? » au plus une fois par minute. Avant, deux Premiere ouverts se
  volaient la session toutes les 2 s, et ⌘J pouvait appliquer dans l'AUTRE Premiere. Un rechargement normal
  du plugin ferme d'abord l'ancienne connexion : le nouveau hello passe aussitôt ;
- à chaque hello, l'app compare `plugin.version` à la version embarquée : jusqu'à la 0.8.3, toute version
  différente déclenchait AUSSITÔT une mise à niveau UPIA (remove + install), rétrogradation comprise. App
  0.8.4 (C-01 puis M1) : un plugin plus ancien (comparaison numérique, « 0.7.10 » > « 0.7.9 ») est seulement
  NOTÉ et reste en service — même protocole v1 ; la mise à niveau se fait **Premiere fermé** (30 s après sa
  fermeture, ou 60 s après le lancement de Khanjar), si le service de fond de Creative Cloud tourne, version
  installée lue dans l'inscription d'Adobe, `--install` lancé seulement si Premiere est toujours fermé après
  le `--remove`, au plus une par 10 min (AGENTS.md §6, point 6).

### `hb` — battement toutes les 5 s, pour information
```json
{ "v":1, "kind":"event", "type":"hb", "n": 42 }
```
L'app note l'heure du dernier battement mais **ne déclare jamais une session morte faute de battements** :
c'est la fermeture de la socket (ou une erreur de réception) qui termine la session ; le plugin se reconnecte
toutes les 2 s. À ne pas « implémenter » : une longue transaction bloque les minuteries du plugin, donc ses
battements, et la session tomberait au milieu d'une grosse application (audit B3). Depuis l'app 0.8.4, le
dernier signe de vie (battement ou tout autre message) sert à une seule chose : décider si un 2ᵉ `hello` peut
remplacer la session (C-19, ci-dessus).

### `log` — relais du journal du plugin (debug uniquement, après `setDebug`)
```json
{ "v":1, "kind":"event", "type":"log", "level":"debug", "line":"…" }
```

## Requêtes (app → plugin) et réponses

Réponse générique :
```json
{ "v":1, "kind":"res", "id":"…", "ok":true,  "result": { … } }
{ "v":1, "kind":"res", "id":"…", "ok":false, "error": { "code":"NO_SELECTION", "message":"…" } }
```

Délais côté app — **app 0.8.3** (publiée) : `apply` = 4 s + 1 s par tranche de 200 keyframes du plan
(plafond 30 s) ; `addAdjustmentLayer` 3 s ; délai dépassé → `TIMEOUT`, l'app libère son verrou et dit
« réessaie » alors que le plugin peut encore appliquer : la réponse tardive est jetée, le nouvel essai pose
les effets EN DOUBLE (vécu les 07/07 et 11/07).

**[0.7.3] App 0.8.4 (C-02)** — délai DOUX puis délai DUR (`BridgeServer.request(cmd:payload:timeout:onSlow:
hardTimeout:completion:)`) :

| Commande | Délai doux | Délai dur |
|---|---|---|
| `apply` | 4 s + 1 s / 200 keyframes du plan (plafond 30 s) | 120 s |
| `addAdjustmentLayer` | 10 s | 60 s |
| `listEffects` | 5 s, sans délai dur (nouveaux essais à +5, +15, +30 s tant que la session vit, C-16) | — |
| modes CLI | 2 à 30 s, sans délai dur | — |

- rien après 1 s → HUD « Application en cours dans Premiere… » (S12) ;
- délai doux → `onSlow` appelé une fois : HUD « Premiere est occupé — Khanjar terminera dès qu'il répond »
  (S13), journal « <cmd> lent : pas de réponse après N ms — attente jusqu'à 120 s », **verrou gardé** et
  requête toujours en attente ; une réponse arrivée avant le délai dur est livrée NORMALEMENT (HUD, journal
  « apply OK », fréquents comptés) ;
- délai dur → `TIMEOUT`, HUD « Premiere ne répond toujours pas — vérifie la timeline avant de réessayer »
  (S14), verrou libéré. Une réponse arrivée APRÈS est tracée : « Réponse tardive de <cmd> (succès|échec)
  arrivée après le délai — ignorée ; Premiere a pu appliquer quand même » (les 20 derniers ids gardés) ;
- `expiresAt` = envoi + délai dur − 5 s : une commande que le plugin n'a pas pu COMMENCER à temps est
  refusée (`EXPIRED`, S16) avant que l'app n'abandonne l'attente ;
- une seule commande qui modifie le projet à la fois CÔTÉ APP aussi (`ProjectCommandGate`, partagé par
  `apply` et ⌘⇧J) : pendant qu'elle tourne, une 2ᵉ validation n'envoie rien, HUD « Premiere applique encore
  le précédent — patiente un instant » (S15), et la palette RESTE ouverte sur la ligne choisie
  (`onCommitChecked`). Une déconnexion libère aussitôt (`PLUGIN_DISCONNECTED`, S11 si Premiere est ouvert).

### `ping`
`{ "cmd":"ping" }` → `result: { "pong": true, "uptimeMs": 12345 }`

### `listEffects`
`{ "cmd":"listEffects" }` →
```json
"result": {
  "video": [ { "matchName":"AE.ADBE Gaussian Blur 2", "displayName":"Gaussian Blur" }, … ],
  "audio": [ { "displayName":"…" }, … ],
  "counts": { "video":108, "audio":0 }
}
```
`displayName` suit la langue de l'interface de Premiere. L'audio n'est pas appliqué (`capabilities.audioEffects`
= false) : l'inventaire remonte seulement.

### `getSelection`
`{ "cmd":"getSelection" }` →
```json
"result": { "items":[ { "name":"plan_04.mov" } ], "count":1,
            "project":"Montage.prproj", "hasSequence":true }
```

### `apply`
```json
{ "v":1, "kind":"req", "id":"…", "cmd":"apply", "expiresAt": 1791572119706,
  "plan": {
    "label": "Zoom 100-120",
    "target": "selection",
    "operations": [
      { "effect": { "matchName": "AE.ADBE Geometry2" },
        "anchor": { "type": 0, "srcDur": "254016000000" },
        "paramCount": 12,
        "params": [
          { "index": 1, "name": "Position", "value": { "x": 0.5, "y": 0.5 }, "keyframes": [] },
          { "index": 3, "name": "Scale Height", "value": 100,
            "keyframes": [ { "t": "0", "value": 100, "i": 0 },
                           { "t": "127008000000", "value": 120, "i": 5,
                             "iv": 0, "ii": 0.33, "ov": 0, "oi": 0.33 } ] } ] } ],
    "existingOperations": [
      { "effect": { "matchName": "AE.ADBE Opacity" },
        "anchor": { "type": 1, "srcDur": "0" }, "paramCount": 0,
        "params": [ { "index": 0, "name": "Opacity", "value": 100, "keyframes": [] } ] } ] },
  "options": { "relativeToClip": true } }
```
(Exemple : Transform, 12 réglages ; 254 016 000 000 ticks = 1 s.)
- `operations` : effets AJOUTÉS, dans l'ordre haut → bas de la pile (le `.prfpset` les stocke à l'envers) ;
  `existingOperations` : réglages posés sur les effets intrinsèques DÉJÀ présents (Opacity, Motion…).
- `anchor.type` : 0 = Échelle (étiré sur le clip), 1 = Entrée, 2 = Sortie ; `srcDur` et `t` en ticks, en
  texte (précision). `paramCount` : nombre de réglages de l'effet à l'enregistrement du preset (0 = inconnu) ;
  s'il diffère de l'effet installé, un nom qui ne correspond pas fait sauter le réglage (AGENTS.md §3.2 item 7).
- `value` : nombre, booléen, point `{x,y}` (0–1), couleur `{r,g,b,a}` ou `null`. Keyframe : `t` (offset depuis
  l'ancre), `value`, `i` (mode d'interpolation du `.prfpset` : 0 linéaire, 4 maintien, 5 bézier), ease
  facultative `iv`/`ii`/`ov`/`oi` (vitesse et influence par côté : le plugin « cuit » la courbe).
- `options.relativeToClip` (défaut true) : transposition des presets Motion/Transform sur le cadrage courant
  du clip (règle revue par P-01, décision Q1).

→
```json
"result": {
  "applied":  { "clips": 3, "clipNames": ["plan_04.mov", "…"] },
  "skipped":  { "items": 1, "reason": "NON_VIDEO", "failedClips": [] },
  "fidelity": { "paramsSet": 27, "paramsSkipped": 0, "namesDiffer": 0, "detail": [],
                "paramsFailedClips": [], "transactions": 2 },
  "transaction": "single",
  "latencyMs": 14 }
```
- `transaction` : `single` si l'insertion groupée a servi tous les clips, `per-clip` si un clip a dû être
  repris seul (vérification par relecture du nombre de composants, puis réinsertion).
- `skipped.items` = pistes audio liées écartées + clips vidéo en échec ; `skipped.reason` = `EFFECT_NOT_RECEIVED`
  dès qu'un clip vidéo a échoué (liste dans `failedClips`), sinon `NON_VIDEO` (pistes audio liées de la sélection,
  écartées par `classifyTrackItem`), absent sinon.
- `fidelity.namesDiffer` : réglages écrits malgré un nom différent, à structure identique (preset d'une autre
  langue).
- **[0.7.3]** `fidelity.paramsFailedClips` : clips dont les réglages n'ont pas été écrits (effets présents, aux
  valeurs par défaut) ; `fidelity.transactions` : nombre de transactions réussies (cible P-02 : 1 pour un effet
  nu, 2 pour un preset avec réglages, 3 avec maintien/bézier non cuit, quel que soit le nombre de clips).
  `paramsSet` n'est plus compté qu'après une transaction réussie (P-06).

Ce que l'app 0.8.4 en fait (C-03, C-10) :
- `applied.clipNames` → `UsageStore.record(…clips:)` / `recordCombo(…clips:)` : un enchaînement (duo) ne
  compte que si les deux applications touchent au moins un clip de même nom (I-01). Absent = aucun
  enchaînement compté ;
- HUD en avertissement dès que `skipped.failedClips`, `fidelity.paramsFailedClips` ou `paramsSkipped` ne
  sont pas vides/nuls ; `paramsFailedClips` → « — réglages non posés sur N clips » (S22/S23) ; réglages
  affichés par clip quand posés ET prévus se divisent exactement par le nombre de clips (et aucun clip sans
  réglages), sinon en totaux ;
- journal : `apply OK : <titre>, <N> clips appliqués, skipped=… reason=… failed=[…] [sansRéglages=[…]]
  transactions=<n> [(repli par clip)] <latence> ms [nomsAutreLangue=N]` — le DÉBUT jusqu'à « clips
  appliqués » ne change jamais (relu par l'amorçage des fréquents) ; `transactions=?` avec un plugin 0.7.2.
  Ligne « apply détail » (6 raisons au plus) dès qu'une raison autre que `NAME_DIFFERS_SAME_STRUCTURE`
  apparaît.

Raisons de `fidelity.detail` (une entrée = un objet `{ reason, … }`) :
- effets : `EFFECT_MISSING` (absent de cette installation de Premiere ; le reste du plan s'applique),
  `EFFECT_NOT_RECEIVED` (`clip`, `kind`, `via`, `mediaType`), `INSERT_FELL_BACK_TO_APPEND`,
  `INSERTED_RUN_NOT_FOUND`, `POST_INSERT_READBACK_FAILED`, `INTRINSIC_NOT_ON_CLIP`, `MEDIA_TYPE_UNKNOWN`
  (item indécis, traité comme vidéo) ;
- réglages : `PARAM_STRUCTURE_MISMATCH`, `INDEX_OUT_OF_RANGE`, `NAME_MISMATCH`, `NAME_DIFFERS_SAME_STRUCTURE`
  (écrit quand même, une fois par application), `UNVERIFIABLE_PARAM`, `VALUE_REJECTED`, `INTERP_REJECTED`,
  `PRE_INSERT_PARAMS_UNSUPPORTED`, `PARAM_TRANSACTION_FAILED`, `EXISTING_READBACK_FAILED`,
  `EXISTING_SCAN_FAILED`, `EXISTING_TRANSACTION_FAILED` ;
- **[0.7.3]** `PARAMS_NOT_SET` (transaction de réglages refusée), `PARTIAL_INSERT` (une partie des effets
  seulement : clip en échec, rien réinséré), `READBACK_FAILED` (relecture impossible : rien réinséré),
  `PREPARE_FAILED` (clip vidéo impossible à préparer), `IN_POINT_UNREADABLE` (réglages animés non posés),
  `TOO_MANY_KEYFRAMES` (plafond d'actions par clip dépassé).

Contrat : lectures asynchrones AVANT le verrou ; actions créées DANS la transaction (AGENTS.md §3.1) ; une
transaction d'insertion nommée `plan.label` pour tous les clips (repli par clip) ; `target:"selection"`
uniquement — jamais de repli sur un clip non sélectionné.

### `addAdjustmentLayer`
`{ "cmd":"addAdjustmentLayer" }` (**[0.7.3]** avec `expiresAt`) → `result: { "trackIndex": 2, "atTicks": "…" }`.
Pose un calque d'effets existant du projet (séquence active, puis chutier) à la tête de lecture, sur la
première piste vidéo libre au-dessus du contenu. Erreurs : `ADJUSTMENT_NOT_FOUND`, `TRANSACTION_FAILED`.
App 0.8.4 : même verrou que `apply` (C-02) ; `ADJUSTMENT_NOT_FOUND` → « Aucun calque d'effets trouvé — crées-en
un (Fichier > Nouveau > Calque d'effets) et glisse-le une fois dans la timeline » (S18) ; `TRANSACTION_FAILED`
→ « Impossible de poser le calque d'effets — ajoute une piste vidéo vide au-dessus de tes clips » (S17).

### Diagnostics en lecture seule (toujours présents)
`readParams`, `dumpChain`, `dumpAllSelected`, `inspectComponent` : servent aux modes CLI (`khanjar
dump-selected`…). Ils ne modifient rien mais renvoient des noms de clips et de projet.

### Harnais qui modifient Premiere (construction `--dev` seulement)
`testSetup`, `testSetupMulti`, `easeProbe` : absents du plugin publié (`plugin/src/env/build.js`,
`DEV_HARNESS: false`) → `UNSUPPORTED_CMD`.

### `setDebug`
`{ "cmd":"setDebug", "enabled": true }` → `result: { "enabled": true }` ; active les events `log`.

## Codes d'erreur

| Code | Émis par | Sens |
|---|---|---|
| `NO_PROJECT` | plugin | Aucun projet actif |
| `NO_SEQUENCE` | plugin | Aucune séquence active |
| `NO_SELECTION` | plugin | Sélection timeline vide |
| `NO_APPLICABLE_CLIP` | plugin | Sélection sans clip vidéo applicable |
| `EFFECT_NOT_FOUND` | plugin | Aucun effet du plan n'existe dans cette installation |
| `TRANSACTION_FAILED` | plugin | Aucun clip n'a reçu l'effet (groupée ET par clip), ou pose du calque refusée |
| `ADJUSTMENT_NOT_FOUND` | plugin | Aucun calque d'effets dans le projet (`addAdjustmentLayer`) |
| `BUSY` | plugin | **[0.7.3]** Une commande qui modifie le projet (`apply`, `addAdjustmentLayer`) tourne déjà ; rien n'a été fait |
| `EXPIRED` | plugin | **[0.7.3]** `expiresAt` dépassé avant de commencer ; rien n'a été fait |
| `PARAM_WRITE_FAILED` | plugin | Défini, jamais émis : un réglage refusé est compté dans `fidelity`, pas en erreur |
| `UNSUPPORTED_CMD` | plugin | `cmd` inconnue (dont les harnais absents d'une version publiée) |
| `PROTOCOL_MISMATCH` | plugin | `v` non supportée |
| `INTERNAL` | plugin | Exception inattendue, ou plan invalide (message = diagnostic) |
| `PLUGIN_DISCONNECTED` | app | Pas de session active, ou session perdue pendant la requête |
| `TIMEOUT` | app | Pas de réponse dans le délai (app 0.8.4 : le délai DUR ; le plugin peut encore travailler, voir « Délais ») |

## Invariants

1. Le plugin ne parle jamais en premier (hormis `hello`/`hb`/`log`).
2. Toute requête reçoit exactement une réponse (même en cas d'exception).
3. Les réponses sont sans état : rien à nettoyer côté plugin entre deux commandes.
4. Le texte destiné à l'humain (`message`) n'est jamais lu par l'app : elle affiche son propre texte traduit
   selon le `code`.
5. **[0.7.3]** Une seule commande qui modifie le projet à la fois dans le plugin (`BUSY`), libérée même en cas
   d'exception — et dans l'app 0.8.4 (`ProjectCommandGate`), libérée à la réponse, à la déconnexion ou au
   délai dur.
6. Le protocole évolue des deux côtés dans le même commit (app Swift + plugin JS).
