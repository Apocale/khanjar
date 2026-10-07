/* Routeur de commandes : dispatch, capture d'erreurs, réponses typées.
 * Invariant : toute requête reçoit exactement une réponse.
 *
 * Chaque requête laisse une ligne `usage cmd=… ms=… ok=…` dans le journal
 * disque : c'est la seule trace qui dise quelles commandes servent vraiment,
 * ce qu'elles coûtent et lesquelles échouent. Coût nul (le log est déjà là),
 * aucune donnée client : uniquement le nom de la commande et sa durée. */
const { CmdError, CODES } = require("../premiere/errors");

const PROTOCOL_VERSION = 1;

class Router {
  constructor(log) {
    this.log = log;
    this.handlers = new Map();
    this.startedAt = Date.now();
  }

  register(cmd, handler) {
    this.handlers.set(cmd, handler);
  }

  async handle(msg) {
    const id = msg.id;
    const cmd = msg.cmd || "?";
    const t0 = Date.now();
    try {
      if (msg.v > PROTOCOL_VERSION) {
        throw new CmdError(CODES.PROTOCOL_MISMATCH, `Protocole v${msg.v} non supporté (max v${PROTOCOL_VERSION})`);
      }
      const handler = this.handlers.get(msg.cmd);
      if (!handler) {
        throw new CmdError(CODES.UNSUPPORTED_CMD, `Commande inconnue : ${msg.cmd}`);
      }
      this.log.debug(`req ${msg.cmd} (${id})`);
      const result = await handler(msg);
      this.log.info(`usage cmd=${cmd} ms=${Date.now() - t0} ok=1`);
      return { v: PROTOCOL_VERSION, kind: "res", id, ok: true, result };
    } catch (err) {
      const code = err instanceof CmdError ? err.code : CODES.INTERNAL;
      const message = err.message || String(err);
      this.log.error(`req ${msg.cmd} (${id}) → ${code}: ${message}`);
      this.log.info(`usage cmd=${cmd} ms=${Date.now() - t0} ok=0 code=${code}`);
      return { v: PROTOCOL_VERSION, kind: "res", id, ok: false, error: { code, message } };
    }
  }
}

module.exports = { Router, PROTOCOL_VERSION };
