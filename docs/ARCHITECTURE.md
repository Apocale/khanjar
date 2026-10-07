# Dagger — Architecture technique de référence

*Palette de commande type Spotlight pour Adobe Premiere Pro (macOS)*
*Version 1.0 — 2026-07-06 — Phase 3*
*Nom de code : « Dagger » (modifiable sans impact technique)*

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

App de barre de menus (`LSUIElement`), sans Dock. Cible : macOS 12+, arm64 +
x86_64 (universal). Zéro dépendance externe (Network.framework, Carbon,
AppKit, SwiftUI pour les vues internes).

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
| `PluginLifecycleService` | Détecter Premiere (NSWorkspace notifications) ; vérifier installation/version du plugin ; installer/mettre à jour via UPIA (remove+install, validé) ; diagnostics | UI |
| `UsageStore` | Compteurs d'usage par item (fréquence + dernière utilisation), persistés | Scoring |
| `SettingsStore` | Raccourci (keyCode+modifiers), nombre de résultats, thème, port ; JSON dans `~/Library/Application Support/Dagger/` | — |
| `HUDController` | Retour discret post-action (toast 1,5 s : « Gaussian Blur → 3 clips », « Aucun clip sélectionné », erreurs) | Bloquer |
| `Logger` | Journal fichier rotatif + niveau debug activable ; miroir des événements bridge | — |

### 2.2 Machine à états (fiabilité)

```
Idle (Premiere absent : hotkey désenregistré, bridge en écoute)
  └─ Premiere lancé ──► WaitingPlugin (hotkey actif ; ⌘J → HUD "connexion…")
        └─ hello reçu ──► Ready (flux nominal)
        └─ timeout 20 s ──► Degraded (⌘J → HUD diagnostic :
              plugin installé ? → proposer installation UPIA en 1 clic)
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
   échec/timeout (800 ms) → HUD d'erreur explicite. `UsageStore` incrémenté.
4. Esc → fermeture, aucun effet de bord.

---

## 3. Processus 2 — Dagger Executor (plugin UXP headless)

Manifest v5, `main: index.js`, **aucun panneau**, `hostUIContext.hideFromMenu:
true` (racine — syntaxe validée), permissions : `network.domains: all` (le
manifest UXP ne permet pas de restreindre à localhost ; le serveur n'écoute que
loopback), `ipc.enablePluginCommunication` (réservé évolutions). Host
`premierepro minVersion 25.6`. JavaScript pur, bundlé en un fichier par esbuild
(pas de framework — le plugin n'a pas d'UI).

### 3.1 Modules

| Module | Responsabilité |
|---|---|
| `bridge/WsClient` | Connexion sortante `ws://127.0.0.1:<port>`, reconnexion 2 s, heartbeat 5 s, sérialisation |
| `bridge/CommandRouter` | Dispatch des requêtes par `cmd`, corrélation `id`, capture d'erreurs → réponses typées (jamais d'exception non catchée) |
| `premiere/EffectEnumerator` | `listEffects` : matchNames + displayNames vidéo (et audio, marqués `capability`) |
| `premiere/SelectionInspector` | Sélection courante : nombre d'items, types (vidéo/audio), noms |
| `premiere/EffectApplier` | Exécuter un `ApplyPlan` : préparer les composants (async) PUIS une seule `lockedAccess`+`executeTransaction` nommée (undo unique) ; par clip vidéo de la sélection ; rapporter par-clip |
| `premiere/ParamWriter` | Poser les valeurs/keyframes de paramètres (`ComponentParam.createSetValueAction` etc.) ; typé par famille de paramètres ; **rapporte la fidélité** (params appliqués / ignorés) |
| `env/Probe` | `hello` enrichi : version plugin, version Premiere, locale UI, capacités (audio ok ?, param types supportés) |
| `log/DiskLog` | Journal dans le dossier de données du plugin (pattern validé), niveau debug pilotable par le Helper |

### 3.2 Règles de conception du plugin

- **Sans état** entre deux commandes (pas de cache côté plugin) : tout état vit
  dans le Helper. Un plugin stateless se met à jour sans migration.
- **Contrat d'erreur exhaustif** : toute commande répond `ok:false` +
  `code` machine + `message` humain (taxonomie §4.4). Le Helper ne parse
  jamais de texte libre.
- **Une transaction par action utilisateur** (multi-clips inclus → un seul
  Cmd+Z). Point à re-vérifier en M1 : une transaction couvrant plusieurs
  clips ; repli documenté : une transaction par clip, nommées identiquement.
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
  "plugin": {"id":"com.dagger.executor","version":"1.2.0"},
  "host": {"app":"premierepro","version":"26.3.0","uiLocale":"fr_FR"},
  "capabilities": {"audioEffects":false,"keyframes":true} }

// heartbeat plugin → helper toutes les 5 s ; le Helper marque la session
// morte après 3 manqués et attend la reconnexion
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
  "plan": {
    "label": "True Drop Shadow",            // nom de la transaction (undo)
    "target": "selection",
    "operations": [
      { "effect": {"matchName":"AE.ADBE Drop Shadow"},
        "params": [
          {"paramKey":"Opacity", "value":0.75},
          {"paramKey":"Distance","keyframes":[{"t":0,"v":5},{"t":1.0,"v":30,"interp":"bezier"}]}
        ] } ] } }
// → res : { "ok":true, "applied":{"clips":3,"clipNames":[…]},
//           "fidelity":{"paramsSet":11,"paramsSkipped":2,
//                        "skipped":[{"paramKey":"…","reason":"ARB_PARAM_UNSUPPORTED"}]},
//           "latencyMs":14 }
```

L'**`ApplyPlan`** est le pivot : produit par le Helper (depuis un effet nu ou
un preset parsé), consommé par le plugin. Un preset multi-effets = plusieurs
`operations`. La *fidélité partielle* est un résultat de premier ordre, pas
une erreur : le HUD affiche « appliqué (2 paramètres non transférables) » et
le détail va au journal.

### 4.4 Taxonomie d'erreurs (codes machine)

`NO_PROJECT` · `NO_SEQUENCE` · `NO_SELECTION` · `NO_APPLICABLE_CLIP` (sélection
100 % audio en v1) · `EFFECT_NOT_FOUND` (matchName absent de cette install) ·
`TRANSACTION_FAILED` · `PARAM_WRITE_FAILED` · `UNSUPPORTED_CMD` ·
`PROTOCOL_MISMATCH` · `INTERNAL`. Côté Helper : `PLUGIN_DISCONNECTED`,
`TIMEOUT`. Chaque code a un message HUD français dédié et une entrée de journal.

### 4.5 Sécurité

Loopback uniquement (`requiredLocalEndpoint 127.0.0.1`, validé). Le `hello`
doit porter l'id de plugin attendu ; une seule session active (nouvelle
connexion valide → remplace l'ancienne). Durcissement prévu (v1.1) : jeton
aléatoire écrit par le Helper dans le dossier de données du plugin à
l'installation, renvoyé dans `hello` — documenté dans PROTOCOL.md, non bloquant
pour v1 (surface : processus locaux du même utilisateur).

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
| macOS | 12.0 | build |
| Protocole | négocié via `v` | handshake |

### 6.3 Télémétrie : aucune

Pas de réseau sortant hors loopback. Les journaux restent locaux.

---

## 7. Gestion des erreurs et modes dégradés (récapitulatif)

| Situation | Comportement |
|---|---|
| ⌘J sans Premiere au premier plan | Ignoré silencieusement (validé) |
| ⌘J, plugin pas connecté | HUD « Connexion à Premiere… » puis diagnostic + bouton « Réparer » (réinstallation UPIA) |
| Aucun clip sélectionné | HUD discret « Aucun clip sélectionné » (exigence produit) — v1 n'applique jamais en repli |
| Sélection sans clip vidéo applicable | HUD « Sélection audio uniquement » |
| Recherche sans résultat | « Aucun résultat » dans la liste (exigence produit) |
| Preset partiellement fidèle | Appliqué + HUD « n paramètres non transférables » + détail au journal ; badge dans la liste |
| Timeout apply (800 ms) | HUD erreur + journal ; l'état Premiere reste cohérent (transaction atomique côté hôte) |
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
