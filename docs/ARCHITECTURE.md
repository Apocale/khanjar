# Dagger — Architecture technique de référence

*Palette de commande type Spotlight pour Adobe Premiere Pro (macOS)*
*Version 1.0 — 2026-07-06 — Phase 3*
*Nom de code : « Dagger » (modifiable sans impact technique)*

> Document de conception de juillet, devenu Khanjar le 2026-10-06. Les passages contredits par le code
> ont été corrigés le 2026-10-09 (audit du 2026-10-08) ; le reste (arborescence, distribution en DMG,
> schémas partagés…) décrit le plan d'origine. Ce qui fait foi : `docs/PROTOCOL.md` pour le pont,
> `AGENTS.md` pour le comportement et les pièges.

---

## 0. Fondations : ce document ne repose que sur des faits validés

| Fait | Validation |
|---|---|
| Un plugin UXP headless (`hostUIContext.hideFromMenu`, sans panneau) se charge et s'exécute en continu dans Premiere 26.3 | Empirique, 2026-07-06 (`spikes/RESULTATS-SPIKES.md`) |
| WebSocket sortant du plugin vers un serveur localhost natif : stable, heartbeats 5 s sans interruption | Empirique |
| Application d'effet headless : `VideoFilterFactory.createComponent` → `createAppendComponentAction` → `executeTransaction` = **12 ms** | Empirique |
| Hotkey global sans permission macOS : Carbon `RegisterEventHotKey` ; filtrage « Premiere au premier plan » via NSWorkspace | Empirique |
| Installation/mise à jour du plugin par CLI : `UPIA --install` (ccx non signé, chargement à chaud), `--remove "Nom"` (déchargement à chaud) ; **une mise à jour ne recharge pas : remove puis install** | Empirique |
| Énumération des effets : `getMatchNames()`/`getDisplayNames()` (162 effets vidéo relevés) | Empirique |
| Presets : **aucune API** ; stockage XML lisible (`.prfpset`, profil utilisateur + `LocalizedPresets/<locale>/` dans le bundle) ; application = rejeu effet+paramètres | Doc Adobe (2× « No. » du staff) + inspection locale |
| CEP / ExtendScript / QE : fin de vie 2026 — interdits comme fondation | Doc Adobe + audit Phase 2 |
| Recherche fuzzy sur 1–5 k éléments : sub-milliseconde | Benchmarks publiés (uFuzzy) |

Les limites connues sont assumées : fidélité partielle du rejeu de presets
(masques, roues/courbes Lumetri, params opaques `ArbVideoComponentParam`),
API audio UXP asymétrique (par displayName), pas d'API transitions.

---

## 1. Vue d'ensemble

Deux processus, un protocole :

```
┌─────────────────────────────────────────────┐        ┌──────────────────────────────┐
│  DAGGER HELPER (app native Swift, menu bar) │        │  ADOBE PREMIERE PRO          │
│                                             │        │  ┌────────────────────────┐  │
│  ⌘J ──► HotkeyService                       │        │  │ DAGGER EXECUTOR        │  │
│            │ (Premiere frontmost ?)         │   WS   │  │ (plugin UXP headless)  │  │
│            ▼                                │◄───────┤  │                        │  │
│  PaletteWindow (NSPanel flottant)           │loopback│  │  WS client + reconnect │  │
│    │ frappe                                 │ :48123 │  │  CommandRouter         │  │
│    ▼                                        │        │  │  EffectApplier         │  │
│  SearchService ──► IndexStore               │        │  │  EffectEnumerator      │  │
│    ▲ Enter              ▲                   │        │  │  SelectionInspector    │  │
│    │                    │                   │        │  └────────────────────────┘  │
│  BridgeServer ──────────┼───── applyPlan ──►│        │                              │
│                         │                   │        │  Fichiers .prfpset (disque)  │
│  PresetIndexer ◄────────┴───────────────────┼────────┤  lus directement par Helper  │
│  (parse XML + FSEvents watch)               │        │                              │
└─────────────────────────────────────────────┘        └──────────────────────────────┘
```

**Principe directeur** (issu des spikes) : *tout ce qui touche l'utilisateur
(fenêtre, clavier, recherche, index) vit dans le Helper natif ; le plugin UXP
est un exécuteur minimal et sans état.* Ce découpage isole le produit des
faiblesses connues d'UXP (pas de raccourcis, hooks de panneau cassés, rendu
limité) et rend le plugin si simple qu'il change rarement — c'est lui qui est
pénible à mettre à jour (remove+install).

### Pourquoi pas d'autres découpages (justification)

- **Palette en panneau UXP** : réfuté en Phase 1-2 — pas de raccourci
  assignable, pas d'API show/focus, hooks cassés, moteur de rendu limité.
- **Tout natif (sans plugin), piloter Premiere par UI scripting** : fragile,
  localisé, lent, permissions Accessibilité — rejeté.
- **Electron/Tauri pour le Helper** : 100–300 Mo de RAM et un démarrage lent
  pour une fenêtre de 500×400 ; Swift/AppKit donne l'apparition < 100 ms et
  un binaire < 5 Mo. Rejeté.
- **Recherche côté plugin** : ajouterait un aller-retour IPC par frappe ;
  l'index doit vivre dans le processus qui affiche. Rejeté.

---

## 2. Processus 1 — Dagger Helper (Swift, AppKit)

App de barre de menus (`LSUIElement`), sans Dock. Cible : macOS 13+ (décision
du 2026-10-08), arm64 seulement (le build universel exige Xcode complet, cf.
`scripts/build-app.sh`). Une seule dépendance externe, Sparkle (mises à jour,
depuis l'app 0.8.0) ; le reste : Network.framework, Carbon, AppKit, SwiftUI.

### 2.1 Modules et responsabilités

| Module | Responsabilité | Ne fait PAS |
|---|---|---|
| `AppCoordinator` | Cycle de vie, câblage des modules, machine à états globale (Idle / PremiereRunning / PluginConnected) | Logique métier |
| `HotkeyService` | Enregistrer/désenregistrer le raccourci (Carbon), vérifier l'app au premier plan, émettre `summonRequested` | Afficher quoi que ce soit |
| `PaletteWindowController` | NSPanel non-activant (`.nonactivatingPanel`), niveau flottant, `canJoinAllSpaces` + `fullScreenAuxiliary` (fonctionne au-dessus de Premiere en plein écran) ; pré-créé au démarrage, affiché/masqué (jamais recréé) ; champ + liste (SwiftUI hébergé) ; Esc/flèches/Enter ; thème clair/sombre | Chercher, appliquer |
| `SearchService` | Scoring fuzzy (portage command-score : sous-séquences, bonus initiales/camelCase → « TDS » trouve « True Drop Shadow »), boost fréquence+récence d'usage, tri, top-N | I/O |
| `IndexStore` | Source de vérité en mémoire des `SearchItem` ; fusion des sources (effets, presets user, presets Adobe) ; snapshot JSON sur disque pour démarrage instantané ; invalidation ciblée | Parser |
| `PresetIndexer` | Parser `.prfpset` (XML `PremiereData`) → presets nommés + `ApplyPlan` ; surveiller le fichier profil (DispatchSource/FSEvents, debounce 2 s) ; presets Adobe du bundle (locale UI de Premiere, repli en_US) | Décider quand chercher |
| `BridgeServer` | Serveur WebSocket loopback (NWListener, port 48123 configurable) ; sessions, handshake `hello`, heartbeats, corrélation requête/réponse, timeouts | Interpréter les commandes |
| `PluginLifecycleService` | Détecter Premiere (NSWorkspace notifications) ; vérifier installation/version du plugin ; installer via UPIA, mettre à jour (remove+install) **Premiere fermé** depuis l'app 0.8.4 (M1, AGENTS.md §6) ; diagnostics | UI |
| `UsageStore` | Compteurs d'usage par item (fréquence + dernière utilisation), persistés | Scoring |
| `SettingsStore` | Raccourci (keyCode+modifiers), nombre de résultats, thème, port ; JSON dans `~/Library/Application Support/Dagger/` | — |
| `HUDController` | Retour discret post-action (toast 1,5 s : « Gaussian Blur → 3 clips », « Aucun clip sélectionné », erreurs) | Bloquer |
| `Logger` | Journal fichier rotatif + niveau debug activable ; miroir des événements bridge | — |

### 2.2 Machine à états (fiabilité)

```
Idle (Premiere absent : hotkey désenregistré, bridge en écoute)
  └─ Premiere lancé ──► WaitingPlugin (hotkey actif ; ⌘J → HUD "connexion…")
        └─ hello reçu ──► Ready (flux nominal)
        └─ 20 s sans hello ──► installation automatique du plugin par UPIA
              (pas de bouton ; reprise automatique : AGENTS.md §6 et §6bis)
  Premiere quitté ──► Idle (socket fermée proprement, index conservé)
```

Toute transition est journalisée. Le Helper ne meurt jamais sur une erreur du
bridge (isolation par session ; une connexion cassée est remplacée par la
reconnexion automatique du plugin, validée à 2 s).

### 2.3 Flux « frappe → application » (chemin critique)

1. ⌘J (Premiere frontmost) → `orderFrontRegardless` + `makeKey` du panel
   pré-créé, champ vidé et focus — **budget : < 100 ms** (pas d'I/O sur ce chemin).
2. Chaque frappe → `SearchService.query()` sur l'index mémoire — **< 5 ms**,
   premier résultat pré-sélectionné.
3. Enter → fermeture **immédiate** du panel (optimiste), puis envoi
   `apply` au plugin ; réponse (mesurée à 12 ms) → HUD de confirmation ;
   échec → HUD d'erreur explicite ; délai : 4 s + 1 s par tranche de 200
   keyframes du plan, plafond 30 s (délai doux puis dur à partir de l'app 0.8.4,
   cf. PROTOCOL.md). `UsageStore` incrémenté.
4. Esc → fermeture, aucun effet de bord.

---

## 3. Processus 2 — Dagger Executor (plugin UXP headless)

Manifest v5, `main: index.js`, **aucun panneau**, `hostUIContext.hideFromMenu:
true` (racine — syntaxe validée), permissions : `network.domains:
["ws://localhost/"]` seulement (WebSockets locaux ; ni IP ni port, mesuré le
2026-10-06, AGENTS.md §3.1 item 16 ; avant : `all`), `ipc.enablePluginCommunication`
(réservé évolutions). Host `premierepro minVersion 25.6`. JavaScript pur, bundlé en un fichier par esbuild
(pas de framework — le plugin n'a pas d'UI).

### 3.1 Modules

| Module | Responsabilité |
|---|---|
| `bridge/WsClient` | Connexion sortante `ws://localhost:48123`, reconnexion 2 s, battement 5 s (information seulement), sérialisation |
| `bridge/CommandRouter` | Dispatch des requêtes par `cmd`, corrélation `id`, capture d'erreurs → réponses typées (jamais d'exception non catchée) |
| `premiere/EffectEnumerator` | `listEffects` : matchNames + displayNames vidéo (et audio, marqués `capability`) |
| `premiere/SelectionInspector` | Sélection courante : nombre d'items, types (vidéo/audio), noms |
| `premiere/EffectApplier` | Exécuter un `ApplyPlan` : préparer les composants (async) PUIS une `lockedAccess`+`executeTransaction` nommée qui insère les effets sur tous les clips vidéo de la sélection ; les réglages suivent dans une 2ᵉ transaction (l'API n'expose un réglage qu'une fois l'effet posé) ; rapporter par clip |
| `premiere/ParamWriter` | Poser les valeurs/keyframes de paramètres (`ComponentParam.createSetValueAction` etc.) ; typé par famille de paramètres ; **rapporte la fidélité** (params appliqués / ignorés) |
| `env/Probe` | `hello` enrichi : version plugin, version Premiere, locale UI, capacités (audio ok ?, param types supportés) |
| `log/DiskLog` | Journal dans le dossier de données du plugin (pattern validé), niveau debug pilotable par le Helper |

### 3.2 Règles de conception du plugin

- **Sans état** entre deux commandes (pas de cache côté plugin) : tout état vit
  dans le Helper. Un plugin stateless se met à jour sans migration.
- **Contrat d'erreur exhaustif** : toute commande répond `ok:false` +
  `code` machine + `message` humain (taxonomie §4.4). Le Helper ne parse
  jamais de texte libre.
- **Annulation : un ⌘Z pour un effet ; deux pour un preset avec réglages**
  (insertion, puis réglages : l'API n'expose les réglages d'un effet qu'une
  fois posé). L'insertion couvre tous les clips en une transaction ; les
  réglages étaient posés clip par clip jusqu'à l'app 0.8.3 (1 + N annulations)
  et sont regroupés par le correctif P-02 de l'audit du 2026-10-08 (à vérifier
  dans Premiere, test T-01). Repli : une transaction par clip, nommées
  identiquement.
- Le plugin **ne lit pas** les `.prfpset` (le Helper le fait : plus rapide,
  pas de permission fs UXP, parsing testable hors Premiere).

---

## 4. Protocole Bridge (contrat central)

JSON texte sur WebSocket loopback. Fichier de référence : `docs/PROTOCOL.md`
+ schémas JSON dans `shared/protocol/` (source unique, testée des deux côtés).

### 4.1 Enveloppe

```json
{ "v": 1, "id": "uuid", "kind": "req" | "res" | "event", ... }
```
`v` = version de protocole. Incompatibilité majeure → le Helper propose la
mise à jour du plugin (UPIA) ; le plugin reste passif.

### 4.2 Handshake et santé

```json
// plugin → helper, à la connexion
{ "v":1, "kind":"event", "type":"hello",
  "plugin": {"id":"io.khanjar.executor","version":"0.7.2"},
  "host": {"app":"premierepro","version":"26.5.2","uiLocale":"fr_FR"},
  "capabilities": {"audioEffects":false,"keyframes":true} }

// battement plugin → helper toutes les 5 s, pour INFORMATION : le Helper ne
// déclare jamais une session morte faute de battements (une longue transaction
// bloque les minuteries du plugin) ; c'est la fermeture de la socket qui la termine
{ "v":1, "kind":"event", "type":"hb", "n":42 }
```

### 4.3 Commandes (helper → plugin)

```json
{ "v":1, "kind":"req", "id":"…", "cmd":"listEffects" }
// → res : { "video": [{"matchName":"AE.ADBE Gaussian Blur 2","displayName":"Flou gaussien"}, …],
//           "audio": [...], "generatedAt": "…" }

{ "v":1, "kind":"req", "id":"…", "cmd":"getSelection" }
// → res : { "items":[{"name":"plan_04.mov","kind":"video"}], "videoCount":2, "audioCount":1 }

{ "v":1, "kind":"req", "id":"…", "cmd":"apply",
  "plan": { "label": "True Drop Shadow",    // nom de la transaction (annulation)
            "target": "selection",
            "operations": [ … ], "existingOperations": [ … ] },
  "options": { "relativeToClip": true } }
// → res : { "applied":{"clips":3,"clipNames":[…]}, "skipped":{…},
//           "fidelity":{"paramsSet":11,"paramsSkipped":2,"detail":[…]},
//           "transaction":"single", "latencyMs":14 }
```
Format exact (réglages par index et nom, ancrage, `paramCount`, keyframes et ease, raisons de fidélité,
champs `expiresAt`, `paramsFailedClips`, `transactions` du plugin 0.7.3) : **`docs/PROTOCOL.md`**.

L'**`ApplyPlan`** est le pivot : produit par le Helper (depuis un effet nu ou
un preset parsé), consommé par le plugin. Un preset multi-effets = plusieurs
`operations`. La *fidélité partielle* est un résultat de premier ordre, pas
une erreur : le HUD affiche « appliqué (2 paramètres non transférables) » et
le détail va au journal.

### 4.4 Taxonomie d'erreurs (codes machine)

`NO_PROJECT` · `NO_SEQUENCE` · `NO_SELECTION` · `NO_APPLICABLE_CLIP` (sélection
100 % audio en v1) · `EFFECT_NOT_FOUND` (matchName absent de cette install) ·
`TRANSACTION_FAILED` · `ADJUSTMENT_NOT_FOUND` · `PARAM_WRITE_FAILED` (défini,
jamais émis) · `UNSUPPORTED_CMD` · `PROTOCOL_MISMATCH` · `INTERNAL` ; plugin 0.7.3 :
`BUSY`, `EXPIRED`. Côté Helper : `PLUGIN_DISCONNECTED`, `TIMEOUT`. Chaque code
a un message HUD traduit et une entrée de journal.

### 4.5 Sécurité

Boucle locale uniquement : `127.0.0.1` et `[::1]` (app 0.8.4, C-18), port 48123.
Filtre d'origine à la poignée de main (app 0.8.4, C-07, décision Q9) : refus de ce
qu'un NAVIGATEUR peut émettre — `http`, `https`, `data`, `blob`, tout schéma en
`-extension`, la valeur `null` ; acceptés : pas d'en-tête, `file://` (le plugin UXP)
et tout autre schéma non web (détail : PROTOCOL.md, AGENTS.md §12). Le `hello` doit
porter l'id de plugin attendu ; une seule session active, et un `hello` ne remplace
plus une session qui a donné signe de vie depuis moins de 10 s (C-19) ; une
connexion sans `hello` est fermée au bout de 10 s (C-06). Pas de jeton partagé : l'idée de juillet
(jeton dans le dossier de données du plugin) est abandonnée, ce dossier
disparaît quand Adobe désinscrit le plugin (AGENTS.md §12). Surface restante :
les programmes du Mac, y compris sous un autre compte macOS (audit sécurité A6).

---

## 5. Indexation et recherche

### 5.1 Modèle d'item

```
SearchItem {
  id            // stable : "effect:AE.ADBE Gaussian Blur 2" | "preset:user:<GUID>"
  kind          // effect | preset
  title         // nom affiché (localisé)
  subtitle      // "Effet vidéo" | "Preset · dossier Effets/Ombres" | "Preset Adobe"
  keywords      // matchName, nom EN, nom du bin — tous cherchables
  applyPlan     // prêt à envoyer (pré-compilé à l'indexation, rien à faire à l'Enter)
  fidelityHint  // full | partial(n) — affichable dans la liste
  usage         // {count, lastUsedAt} → boost de tri
}
```

### 5.2 Sources et rafraîchissement

| Source | Quand | Coût attendu |
|---|---|---|
| Effets (plugin `listEffects`) | À chaque `hello` (Premiere (re)démarré) ; cache disque par version de Premiere | 162 items vidéo relevés ; < 100 ms |
| Presets utilisateur (`Effect Presets and Custom Items.prfpset` du profil actif) | Au démarrage (async) + FSEvents sur le fichier (debounce 2 s — Premiere réécrit le fichier à la sauvegarde d'un preset) | 15 Mo / 682 presets relevés ; parsing objectif < 1 s, hors chemin critique |
| Presets Adobe (`LocalizedPresets/<locale>/…prfpset` du bundle) | Au démarrage ; cache par (version app, locale) | ~centaines d'items |

Le snapshot JSON de l'index est relu au lancement du Helper : la palette est
utilisable immédiatement même avant la fin d'un reparse. Jamais de parsing au
moment de l'invocation (leçon Excalibur v1.0.1, confirmée Phase 1).

### 5.3 Scoring

Portage Swift de l'algorithme *command-score* (cmdk/Superhuman) : bonus début
de mot, initiales (« TDS »), séquences contiguës ; multiplié par un boost
d'usage `log(1+count)` avec décroissance temporelle. Ex æquo → alphabétique.
Testé par table de cas (« True Dr », « Drop », « Shadow », « TDS » → « True
Drop Shadow » premier). < 1 ms pour 5 k items (marge ×100 sur le budget).

### 5.4 Mémoire

Index complet estimé < 10 Mo en mémoire (plans pré-compilés inclus, chaînes
partagées). Budget Helper total : < 50 Mo résident. Pas de processus par
recherche, pas de GC : Swift/ARC.

---

## 6. Cycle de vie, installation, mises à jour

### 6.1 Distribution

- **Helper** : .app signée Developer ID + notarisée (obligatoire hors App
  Store), livrée en DMG. Login item optionnel (SMAppService) proposé au
  premier lancement.
- **Plugin** : le `.ccx` est **embarqué dans les ressources du Helper**. Le
  Helper est l'installateur : au premier lancement (ou si `hello` absent /
  version obsolète), il exécute UPIA `--install` (validé, chargement à chaud
  ~5-15 s, sans redémarrer Premiere). Mise à jour = `--remove "<nom>"` puis
  `--install` (séquence validée ; le remove à chaud a été prouvé). Si UPIA est
  introuvable (Creative Cloud absent), message explicite + doc.

### 6.2 Matrice de compatibilité

| Composant | Min | Vérifié par |
|---|---|---|
| Premiere Pro | 25.6 (UXP GA) ; cible 26.x | `hello.host.version` ; refus poli en deçà |
| macOS | 13.0 (décision du 2026-10-08) | `LSMinimumSystemVersion` (build-app.sh), repris par l'appcast |
| Protocole | négocié via `v` | handshake |

### 6.3 Télémétrie : aucune

Pas de télémétrie ; les journaux restent locaux. Seul réseau sortant : la
vérification des mises à jour (Sparkle, avec l'accord de l'utilisateur). Les
rapports de plantage n'existent que dans un build qui porte une adresse d'envoi
(aucune version publiée n'en a).

---

## 7. Gestion des erreurs et modes dégradés (récapitulatif)

| Situation | Comportement |
|---|---|
| ⌘J sans Premiere au premier plan | Ignoré silencieusement (validé) |
| ⌘J, plugin pas connecté | HUD selon l'état (`PluginStatus`, C-05) : « Ouvre Premiere Pro pour utiliser Khanjar » (fermé), « Connexion à Premiere… » (jamais connecté), « Khanjar se reconnecte à Premiere… » (après une vraie déconnexion), installation en cours / échouée / Premiere à relancer ; plugin muet depuis plus de 45 s → réinstallation automatique par UPIA, jamais dans la minute qui suit le lancement de Premiere (AGENTS.md §6, §6bis). Entrée de menu « Réinstaller le plugin dans Premiere » (C-05) |
| Aucun clip sélectionné | HUD discret « Aucun clip sélectionné » (exigence produit) — v1 n'applique jamais en repli |
| Sélection sans clip vidéo applicable | HUD « Sélection audio uniquement » |
| Recherche sans résultat | « Aucun résultat » dans la liste (exigence produit) |
| Preset partiellement fidèle | Appliqué + HUD « n paramètres non transférables » + détail au journal ; badge dans la liste |
| Délai d'apply dépassé (4 s + 1 s / 200 keyframes, plafond 30 s) | App 0.8.4 (C-02, P-08) : le délai doux ne déclenche qu'un message d'attente, le verrou est GARDÉ jusqu'au délai dur (120 s) et la réponse tardive est livrée ; pendant ce temps une nouvelle validation reçoit « Premiere applique encore le précédent » (rien n'est envoyé), et le plugin répond `BUSY`/`EXPIRED` sans rien faire. Au délai dur : « Premiere ne répond toujours pas — vérifie la timeline avant de réessayer » (PROTOCOL.md « Délais ») |
| Fichier prfpset corrompu/illisible | Source ignorée, reste de l'index intact, erreur journalisée, badge dans Réglages |
| Raccourci déjà pris (RegisterEventHotKey ≠ noErr) | Réglages ouverts avec message, saisie d'un autre raccourci |

---

## 8. Arborescence du dépôt

```
dagger/
├── docs/
│   ├── ARCHITECTURE.md          ← ce document
│   ├── PROTOCOL.md              ← contrat bridge, versionné, exemples
│   └── DECISIONS/               ← ADRs (une décision = un fichier daté)
├── shared/
│   └── protocol/                ← schémas JSON + fixtures de test communes
├── helper/                      ← Swift Package + projet app
│   ├── Sources/DaggerHelper/
│   │   ├── App/                 (AppCoordinator, états)
│   │   ├── Hotkey/
│   │   ├── Palette/             (WindowController, vues, HUD)
│   │   ├── Search/              (scorer + tests de pertinence)
│   │   ├── Index/               (IndexStore, sources, snapshot)
│   │   ├── Presets/             (parser prfpset + fixtures)
│   │   ├── Bridge/              (serveur WS, sessions, protocole)
│   │   ├── Lifecycle/           (UPIA, NSWorkspace, updates)
│   │   ├── Settings/
│   │   └── Support/             (Logger, extensions)
│   └── Tests/DaggerHelperTests/ (unitaires : parser, scorer, protocole)
├── plugin/                      ← UXP Executor
│   ├── src/ (bridge/, premiere/, env/, log/)
│   ├── manifest.json
│   └── build.mjs                (esbuild → dist/ + ccx)
├── scripts/                     (package-ccx.sh, upia-install.sh, dev-loop.sh, notarize.sh)
└── spikes/                      ← conservés en référence historique
```

Un seul dépôt : le protocole évolue toujours des deux côtés dans le même
commit, avec `shared/protocol/` comme garde-fou testé.

---

## 9. Testabilité

- **Parser prfpset** : testé hors Premiere sur fixtures réelles (dont le fichier
  15 Mo/682 presets de cette machine, anonymisé) — pur, déterministe.
- **Scorer** : table de vérité de pertinence (cas « TDS », accents, préfixes).
- **Protocole** : les schémas de `shared/protocol/` valident les fixtures des
  deux implémentations (test Swift + test node du plugin).
- **Plugin** : testable sans UI — le harnais de dev est le Helper lui-même en
  mode debug + `scripts/dev-loop.sh` (rebuild ccx → UPIA remove+install,
  séquence validée ~20 s) ; smoke tests pilotés par commandes bridge
  (`listEffects`, `apply` sur projet de test dédié).
- **E2E reproductible** : projet Premiere de test versionné (`plugin/test/`),
  scénario scripté via SIGUSR1/commandes (méthode des spikes).

---

## 10. Performances (budgets contractuels)

| Étape | Budget | Marge démontrée |
|---|---|---|
| ⌘J → palette visible et focus | < 100 ms | panel pré-créé ; à mesurer M3 |
| Frappe → résultats affichés | < 16 ms (1 frame) | scoring < 1 ms démontré par benchmarks |
| Enter → fermeture perçue | < 16 ms | fermeture optimiste avant l'IPC |
| Enter → effet appliqué (arrière-plan) | < 200 ms | **12 ms mesurés** |
| Démarrage Helper → palette utilisable | < 500 ms | snapshot d'index, parsing différé |
| RAM Helper | < 50 Mo | index < 10 Mo estimé |
| CPU au repos | ~0 % | pas de polling : FSEvents + notifications système |

Chaque budget devient un test/benchmark en Phase 5 ; un dépassement est un bug.

---

## 11. Évolutions prévues (l'architecture les absorbe sans refonte)

| Évolution | Point d'extension prévu |
|---|---|
| Effets audio (quand l'API UXP mûrira) | `capabilities` du hello + `kind` d'item ; `ParamWriter` audio |
| Chaînes/macros (plusieurs presets d'un coup) | `ApplyPlan.operations` est déjà une liste |
| Autres déclencheurs (Stream Deck, URL scheme) | Nouveaux producteurs de `summonRequested`/`apply` dans le Helper — le protocole ne change pas |
| Windows | Protocole, plugin et index inchangés ; réécrire HotkeyService/PaletteWindow (raison du cloisonnement plateforme) |
| Amélioration fidélité presets | Isolée dans `ParamWriter` + `fidelityHint` recalculé |
| Marketplace Adobe pour le plugin | Le ccx est déjà le format ; signature/notarisation du Helper inchangée |
| Autres hôtes Adobe (AE) | Nouveau plugin executor par hôte, même protocole (champ `host`) |

Non-objectifs v1 (explicites) : transitions (aucune API), presets de
transition (idem — limite Excalibur confirmée), application audio, Windows,
télémétrie, localisation de l'UI du Helper (français d'abord).

---

## 12. Ordre d'implémentation (vue macro — détail en Phase 4)

| Jalon | Contenu | Critère de sortie |
|---|---|---|
| **M0** | Squelette dépôt, PROTOCOL.md, schémas partagés, CI locale (build helper + plugin) | Les deux processus se serrent la main (hello/hb) via le protocole définitif |
| **M1** | Executor complet : listEffects, getSelection, apply (effets nus), taxonomie d'erreurs ; vérif « une transaction multi-clips » | Smoke tests bridge verts sur projet de test ; 12 ms confirmés en multi-clips |
| **M2** | PresetIndexer (parser + fixtures + FSEvents) ; IndexStore + snapshot ; compilation des ApplyPlans presets | 682 presets réels parsés < 1 s ; plans conformes aux schémas |
| **M3** | PaletteWindow + SearchService + HotkeyService ; HUD | ⌘J → recherche → Enter applique ; budgets §10 mesurés |
| **M4** | ParamWriter (rejeu paramètres/keyframes) + rapport de fidélité | Presets réels appliqués ; écarts documentés par famille de params |
| **M5** | Réglages (raccourci, nb résultats, thème) ; UsageStore | Personnalisation complète sans redémarrage |
| **M6** | PluginLifecycleService (install/update UPIA embarqué), signature/notarisation, DMG | Installation « double-clic » de zéro sur machine vierge |
| **M7** | Durcissement : chaos tests (kill plugin/Premiere/Helper), journaux, revue perf/mémoire | Tous les modes dégradés §7 vérifiés |

Chaque jalon est livrable et testable indépendamment (exigence Phase 4).

---

## 13. Risques résiduels et parades

| Risque | Prob. | Parade |
|---|---|---|
| Transaction unique multi-clips non supportée | Faible | Repli : N transactions nommées identiquement (M1, testé en premier) |
| Rejeu de certains types de paramètres impossible (Arb/Lumetri) | **Certain** (borné) | `fidelityHint` + badge + HUD ; c'est la limite du marché entier (Excalibur inclus) — assumée produit |
| Adobe change UPIA ou le chargement à chaud | Faible | Repli : installation ccx par double-clic (flux CC standard) + redémarrage Premiere ; PluginLifecycleService encapsule tout |
| Évolution du schéma .prfpset dans une future version | Moyen | Parser tolérant + tests fixtures par version ; échec = source ignorée, jamais de crash |
| `hideFromMenu` retiré/modifié par Adobe | Faible | Le plugin resterait listé au menu (cosmétique) ; le chargement du plugin installé n'en dépend pas (prouvé : le nôtre charge à chaud) |
| Port 48123 occupé | Faible | Port configurable + découverte : le Helper écrit le port réel dans le dossier de données du plugin |
