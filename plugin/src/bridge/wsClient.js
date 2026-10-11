/* Client WebSocket vers le app Khanjar : reconnexion 2 s, heartbeat 5 s.
 * Ne connaît pas les commandes : délègue chaque requête au routeur.
 *
 * 2026-10-09 (audit P-04 ; cas d'un ami dont le plugin ne joignait pas l'app).
 * CAUSE : les fermetures étaient écrites en `debug` sans jamais être écrites
 * sur disque, `onerror` était ignoré, un échec du constructeur n'atteignait le
 * disque qu'une fois : après 3 minutes et ≈ 90 tentatives, le journal ne
 * contenait que « Khanjar démarré » — impossible de distinguer « rien
 * n'écoute », « refusé à la poignée de main » et « jamais essayé ».
 * CORRECTION : chaque changement d'état (tentative n°, ouverture, fermeture
 * avec code et raison, erreur, échec du constructeur) est écrit en clair puis
 * flushé, avec un plafond (les 5 premières tentatives, puis 1 sur 30) ; une
 * socket restée « en connexion » plus de 10 s est abandonnée et relancée. Une
 * seule chaîne de reconnexion : la fermeture tardive d'une socket abandonnée
 * ne relance rien (après ws.close(), UXP envoie `close` ≈ 5 s plus tard,
 * AGENTS §3.1 item 16). */
const RECONNECT_MS = 2000;
const HEARTBEAT_MS = 5000;
const CONNECTING_TIMEOUT_MS = 10000;
const LOG_FIRST_ATTEMPTS = 5;
const LOG_EVERY_ATTEMPTS = 30;

class WsClient {
  /**
   * @param {object} opts
   * @param {string} opts.url
   * @param {() => object} opts.helloPayload
   * @param {(msg: object) => Promise<object>} opts.handleRequest  (retourne la réponse complète)
   * @param {{info: Function, error: Function, debug: Function, flush?: Function}} opts.log
   * @param {number} [opts.reconnectMs]          (tests)
   * @param {number} [opts.connectingTimeoutMs]  (tests)
   */
  constructor({ url, helloPayload, handleRequest, log, reconnectMs, connectingTimeoutMs }) {
    this.url = url;
    this.helloPayload = helloPayload;
    this.handleRequest = handleRequest;
    this.log = log;
    this.ws = null;
    this.hbCount = 0;
    this.hbTimer = null;
    this.reconnectMs = reconnectMs || RECONNECT_MS;
    this.connectingTimeoutMs = connectingTimeoutMs || CONNECTING_TIMEOUT_MS;
    this.reconnectTimer = null;
    this.attempt = 0; // tentatives depuis la dernière connexion réussie
  }

  start() {
    this._connect();
    this.hbTimer = setInterval(() => this._heartbeat(), HEARTBEAT_MS);
  }

  send(obj) {
    try {
      if (this.ws && this.ws.readyState === 1) {
        this.ws.send(JSON.stringify(obj));
        return true;
      }
    } catch (e) { /* la reconnexion suivra */ }
    return false;
  }

  _heartbeat() {
    this.hbCount += 1;
    this.send({ v: 1, kind: "event", type: "hb", n: this.hbCount });
  }

  /* Écrit une ligne d'état et la pousse sur disque. Plafond : les 5 premières
   * tentatives, puis 1 sur 30 (sauf `always`). */
  _state(level, message, always) {
    const n = this.attempt;
    if (!always && n > LOG_FIRST_ATTEMPTS && (n - LOG_FIRST_ATTEMPTS) % LOG_EVERY_ATTEMPTS !== 0) return;
    if (level === "error") this.log.error(message); else this.log.info(message);
    if (typeof this.log.flush === "function") {
      try {
        const pending = this.log.flush();
        if (pending && typeof pending.catch === "function") pending.catch(() => {});
      } catch (e) { /* journal indisponible : la connexion continue */ }
    }
  }

  _scheduleReconnect() {
    if (this.reconnectTimer) return; // une seule chaîne de reconnexion
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this._connect();
    }, this.reconnectMs);
  }

  _connect() {
    this.attempt += 1;
    const n = this.attempt;
    let ws;
    try {
      ws = new WebSocket(this.url);
    } catch (err) {
      this._state("error", `WS tentative ${n} : construction refusée — ${err.message}`);
      this._scheduleReconnect();
      return;
    }
    this.ws = ws;
    let opened = false;

    // Socket restée « en connexion » trop longtemps : abandonnée, nouvel essai.
    const watchdog = setTimeout(() => {
      if (this.ws !== ws || ws.readyState !== 0) return;
      this._state("error", `WS tentative ${n} : toujours en connexion après ${Math.round(this.connectingTimeoutMs / 1000)} s — abandonnée, nouvel essai`);
      this.ws = null;
      try { ws.close(); } catch (e) { /* déjà fermée */ }
      this._scheduleReconnect();
    }, this.connectingTimeoutMs);

    ws.onopen = () => {
      clearTimeout(watchdog);
      if (this.ws !== ws) return;
      opened = true;
      this._state("info", `WS connecté au Helper (tentative ${n})`, true);
      this.attempt = 0;
      this.send(this.helloPayload());
    };

    ws.onmessage = async (event) => {
      let msg;
      try { msg = JSON.parse(event.data); } catch (e) {
        this.log.error("Message non-JSON ignoré");
        return;
      }
      if (msg.kind !== "req") return; // le Helper n'émet que des requêtes
      const response = await this.handleRequest(msg);
      this.send(response);
    };

    ws.onclose = (event) => {
      clearTimeout(watchdog);
      if (this.ws !== ws) return; // socket abandonnée : rien à relancer
      this.ws = null;
      const code = event && event.code != null ? event.code : "?";
      const reason = event && event.reason ? ` « ${event.reason} »` : "";
      this._state("info", `WS fermé (code ${code}${reason}, tentative ${n}) — reconnexion dans ${Math.round(this.reconnectMs / 1000)} s`, opened);
      this._scheduleReconnect();
    };

    ws.onerror = (event) => {
      if (this.ws !== ws) return;
      const detail = (event && (event.message || event.type)) || "erreur";
      this._state("error", `WS tentative ${n} : erreur — ${detail}`, opened); // onclose suit
    };
  }
}

module.exports = { WsClient };
