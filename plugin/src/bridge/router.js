/* Routeur de commandes : dispatch, capture d'erreurs, réponses typées.
 * Invariant : toute requête reçoit exactement une réponse.
 *
 * Chaque requête laisse une ligne `usage cmd=… ms=… ok=…` dans le journal
 * disque : c'est la seule trace qui dise quelles commandes servent vraiment,
 * ce qu'elles coûtent et lesquelles échouent. Coût nul (le log est déjà là),
 * aucune donnée client : uniquement le nom de la commande et sa durée. */
const { CmdError, CODES } = require("../premiere/errors");

const PROTOCOL_VERSION = 1;

/* UNE SEULE COMMANDE QUI MODIFIE LE PROJET À LA FOIS (2026-10-09, audit P-08).
 *
 * CAUSE : chaque message était traité dès réception, sans verrou. Après un
 * délai dépassé, l'app invitait à réessayer alors que Premiere appliquait
 * encore : la 2ᵉ application s'entrelaçait avec la 1ʳᵉ à chaque `await`
 * (simulation de l'audit, vrai WsClient + Router + apply sur 200 clips :
 * 6 effets au lieu de 3, et 67 à 81 clips avec une copie aux valeurs par
 * défaut, irrécupérable par ⌘Z sur un gros lot).
 *
 * CORRECTION (contrat §4.1) : si `apply` ou `addAdjustmentLayer` tourne déjà,
 * toute autre commande de cette liste reçoit aussitôt BUSY ; le verrou est
 * libéré dans un `finally`, quoi qu'il arrive. Une requête dont l'échéance
 * `expiresAt` (ms depuis 1970, horloge du Mac) est passée au moment de
 * COMMENCER reçoit EXPIRED sans que la commande soit appelée — l'app a déjà
 * abandonné cette demande, l'exécuter maintenant surprendrait le monteur.
 * Les commandes de lecture (ping, listEffects, dumpChain…) ne sont pas
 * concernées. */
const MUTATING = new Set(["apply", "addAdjustmentLayer"]);

/* Attente maximale de l'écriture du journal avant une commande (m11). */
const FLUSH_WAIT_MS = 500;

class Router {
  constructor(log) {
    this.log = log;
    this.handlers = new Map();
    this.startedAt = Date.now();
    this.running = null; // { cmd, id, since } de la commande qui modifie le projet
  }

  register(cmd, handler) {
    this.handlers.set(cmd, handler);
  }

  /* Relecture finale (m11, 2026-10-11) : jamais plus de FLUSH_WAIT_MS d'attente.
   * Une écriture du stockage UXP qui ne rendrait pas la main gardait le verrou
   * pris : BUSY pour toutes les applications suivantes, jusqu'à la relance de
   * Premiere. La trace reste écrite dès que le disque répond. */
  async _flushLog() {
    if (!this.log || typeof this.log.flush !== "function") return;
    let timer = null;
    const waited = new Promise((resolve) => { timer = setTimeout(resolve, FLUSH_WAIT_MS); });
    try {
      await Promise.race([Promise.resolve(this.log.flush()).catch(() => {}), waited]);
    } catch (e) {
      /* journal indisponible : on continue */
    } finally {
      clearTimeout(timer);
    }
  }

  async handle(msg) {
    const id = msg.id;
    const cmd = msg.cmd || "?";
    const t0 = Date.now();
    let holdsLock = false;
    try {
      if (msg.v > PROTOCOL_VERSION) {
        throw new CmdError(CODES.PROTOCOL_MISMATCH, `Protocole v${msg.v} non supporté (max v${PROTOCOL_VERSION})`);
      }
      const handler = this.handlers.get(msg.cmd);
      if (!handler) {
        throw new CmdError(CODES.UNSUPPORTED_CMD, `Commande inconnue : ${msg.cmd}`);
      }
      if (MUTATING.has(msg.cmd)) {
        // Tout ce bloc est synchrone jusqu'à la prise du verrou : une 2ᵉ
        // requête arrivée pendant un `await` de la 1ʳᵉ voit forcément le verrou.
        if (this.running) {
          throw new CmdError(CODES.BUSY,
            `${this.running.cmd} (${this.running.id}) en cours depuis ${Date.now() - this.running.since} ms — rien n'a été fait`);
        }
        this.running = { cmd: msg.cmd, id, since: t0 };
        holdsLock = true;
        // 2026-10-09 (audit P-04) : trace écrite sur disque AVANT d'exécuter.
        // Le journal n'était écrit qu'après chaque commande : après un gel de
        // Premiere et un « Forcer à quitter », rien ne disait ce qui tournait.
        this.log.info(`req ${msg.cmd} (${id})`);
        await this._flushLog();
        if (typeof msg.expiresAt === "number" && isFinite(msg.expiresAt) && Date.now() > msg.expiresAt) {
          throw new CmdError(CODES.EXPIRED,
            `échéance dépassée de ${Date.now() - msg.expiresAt} ms avant de commencer — rien n'a été fait`);
        }
      } else {
        this.log.debug(`req ${msg.cmd} (${id})`);
      }
      const result = await handler(msg);
      this.log.info(`usage cmd=${cmd} ms=${Date.now() - t0} ok=1`);
      return { v: PROTOCOL_VERSION, kind: "res", id, ok: true, result };
    } catch (err) {
      const code = err instanceof CmdError ? err.code : CODES.INTERNAL;
      const message = err.message || String(err);
      this.log.error(`req ${msg.cmd} (${id}) → ${code}: ${message}`);
      this.log.info(`usage cmd=${cmd} ms=${Date.now() - t0} ok=0 code=${code}`);
      return { v: PROTOCOL_VERSION, kind: "res", id, ok: false, error: { code, message } };
    } finally {
      if (holdsLock) this.running = null;
    }
  }
}

module.exports = { Router, PROTOCOL_VERSION, MUTATING };
