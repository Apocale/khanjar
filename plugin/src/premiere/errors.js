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
  INTERNAL: "INTERNAL",
};

module.exports = { CmdError, CODES };
