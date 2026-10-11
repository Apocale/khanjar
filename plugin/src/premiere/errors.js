/* Taxonomie d'erreurs du protocole (PROTOCOL.md). Toute commande échoue via
 * CmdError : le routeur la convertit en réponse `ok:false` typée. */
class CmdError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

const CODES = {
  NO_PROJECT: "NO_PROJECT",
  NO_SEQUENCE: "NO_SEQUENCE",
  NO_SELECTION: "NO_SELECTION",
  NO_APPLICABLE_CLIP: "NO_APPLICABLE_CLIP",
  EFFECT_NOT_FOUND: "EFFECT_NOT_FOUND",
  TRANSACTION_FAILED: "TRANSACTION_FAILED",
  PARAM_WRITE_FAILED: "PARAM_WRITE_FAILED",
  ADJUSTMENT_NOT_FOUND: "ADJUSTMENT_NOT_FOUND",
  UNSUPPORTED_CMD: "UNSUPPORTED_CMD",
  PROTOCOL_MISMATCH: "PROTOCOL_MISMATCH",
  // 2026-10-09 (audit P-08, contrat §4.1) : refus AVANT toute action sur le
  // projet. BUSY = une commande qui modifie le projet tourne déjà ; EXPIRED =
  // échéance `expiresAt` de la requête dépassée avant de commencer. Dans les
  // deux cas rien n'a été fait : l'app peut le dire sans risque de doublon.
  BUSY: "BUSY",
  EXPIRED: "EXPIRED",
  INTERNAL: "INTERNAL",
};

module.exports = { CmdError, CODES };
