# Protocole Bridge Dagger — v1

Transport : WebSocket texte, loopback uniquement : le pont écoute `127.0.0.1:48123`, le plugin se
connecte à `ws://localhost:48123` (UXP refuse les adresses IP dans sa règle réseau, cf. AGENTS.md §3.1).
Le serveur **refuse toute poignée de main portant une origine web** (`Origin` en `http://`,
`https://` ou extension de navigateur) : une page ouverte dans un navigateur ne peut pas se faire
passer pour le plugin. Pas de jeton partagé — raisons dans `AGENTS.md` §12.
Serveur = Dagger Helper (natif). Client = Dagger Executor (plugin UXP).
Encodage : JSON UTF-8, un message par frame.

## Enveloppe

Tout message porte :

| Champ | Type | Rôle |
|---|---|---|
| `v` | int | Version de protocole (actuel : `1`) |
| `kind` | `"req"` \| `"res"` \| `"event"` | Nature |
| `id` | string (uuid) | Corrélation req/res (absent des events) |

Compatibilité : le plugin répond `PROTOCOL_MISMATCH` si `v` > sa version ;
le Helper propose alors la mise à jour du plugin (UPIA).

## Événements (plugin → helper)

### `hello` — à chaque (re)connexion, obligatoire avant toute requête
```json
{ "v":1, "kind":"event", "type":"hello",
  "plugin": { "id":"com.dagger.executor", "version":"0.1.0" },
  "host":   { "app":"premierepro", "version":"26.3.0", "uiLocale":"fr_FR" },
  "capabilities": { "audioEffects": false, "keyframes": true } }
```
Le Helper rejette (ferme la socket) si `plugin.id` inattendu. Une nouvelle
connexion valide remplace la session précédente.

### `hb` — heartbeat toutes les 5 s
```json
{ "v":1, "kind":"event", "type":"hb", "n": 42 }
```
Session considérée morte après 3 heartbeats manqués (~15 s) → attente de
reconnexion (le plugin retente toutes les 2 s).

### `log` — relai de journal plugin (debug uniquement)
```json
{ "v":1, "kind":"event", "type":"log", "level":"debug", "line":"…" }
```

## Requêtes (helper → plugin) et réponses

Réponse générique :
```json
{ "v":1, "kind":"res", "id":"…", "ok":true,  "result": { … } }
{ "v":1, "kind":"res", "id":"…", "ok":false, "error": { "code":"NO_SELECTION", "message":"…" } }
```
Timeout côté Helper : `apply` = 4 s + 1 s par tranche de 200 keyframes du plan (plafond 30 s) ;
5 s (`listEffects`) ; 2–3 s (autres).

### `ping`
`{ "cmd":"ping" }` → `result: { "pong": true, "uptimeMs": 12345 }`

### `listEffects`
`{ "cmd":"listEffects" }` →
```json
"result": {
  "video": [ { "matchName":"AE.ADBE Gaussian Blur 2", "displayName":"Flou gaussien" }, … ],
  "audio": [ … ],                  // vide si capability audioEffects=false
  "counts": { "video":162, "audio":0 }
}
```

### `getSelection`
`{ "cmd":"getSelection" }` →
```json
"result": { "items":[ { "name":"plan_04.mov" } ], "count":1,
            "project":"LHaj.prproj", "hasSequence":true }
```

### `apply`
```json
{ "v":1, "kind":"req", "id":"…", "cmd":"apply",
  "plan": {
    "label": "True Drop Shadow",
    "target": "selection",
    "operations": [
      { "effect": { "matchName": "AE.ADBE Drop Shadow" },
        "params":  [ /* M4 — vide pour un effet nu */ ] }
    ] } }
```
→
```json
"result": {
  "applied":  { "clips": 3, "clipNames": ["plan_04.mov","…"] },
  "skipped":  { "items": 1, "reason": "NON_VIDEO" },
  "fidelity": { "paramsSet": 0, "paramsSkipped": 0, "detail": [] },
  "transaction": "single" | "per-clip",
  "latencyMs": 14 }
```
Contrat : préparation asynchrone AVANT la transaction ; une seule transaction
nommée `plan.label` (repli automatique par-clip si la transaction groupée
échoue, signalé par `transaction`). `target:"selection"` uniquement en v1 —
jamais de repli sur un clip non sélectionné.

`skipped.items` = items audio écartés + clips vidéo en échec ; `skipped.reason` =
`EFFECT_NOT_RECEIVED` dès qu'un clip vidéo a échoué (liste dans `failedClips`),
sinon `NON_VIDEO` (les pistes audio liées de la sélection, écartées par
`classifyTrackItem` — plugin ≥ 0.6.7). Entrées de `fidelity.detail` liées :
`{ reason:"EFFECT_NOT_RECEIVED", clip, kind, via, mediaType }` et
`{ reason:"MEDIA_TYPE_UNKNOWN", clip, mediaType, via }` (item indécis, traité
comme vidéo). `options.relativeToClip` (défaut true) : transposition des presets
sur le cadrage courant du clip.

### `setDebug`
`{ "cmd":"setDebug", "enabled": true }` → active les events `log`.

## Codes d'erreur

| Code | Émis par | Sens |
|---|---|---|
| `NO_PROJECT` | plugin | Aucun projet actif |
| `NO_SEQUENCE` | plugin | Aucune séquence active |
| `NO_SELECTION` | plugin | Sélection timeline vide |
| `NO_APPLICABLE_CLIP` | plugin | Sélection sans clip vidéo applicable |
| `EFFECT_NOT_FOUND` | plugin | matchName inconnu de cette installation |
| `TRANSACTION_FAILED` | plugin | `executeTransaction` en échec (groupée ET par-clip) |
| `PARAM_WRITE_FAILED` | plugin | Pose de paramètre en échec (M4) |
| `UNSUPPORTED_CMD` | plugin | `cmd` inconnue |
| `PROTOCOL_MISMATCH` | plugin | `v` non supportée |
| `INTERNAL` | plugin | Exception inattendue (message = diagnostic) |
| `PLUGIN_DISCONNECTED` | helper | Pas de session active |
| `TIMEOUT` | helper | Pas de réponse dans le budget |

## Invariants

1. Le plugin ne parle jamais en premier (hormis `hello`/`hb`/`log`).
2. Toute requête reçoit exactement une réponse (même en cas d'exception).
3. Les réponses sont sans état : rien à nettoyer côté plugin entre deux commandes.
4. Le texte destiné à l'humain (`message`) n'est jamais parsé par le Helper.
