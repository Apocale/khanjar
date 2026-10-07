/* Client WebSocket vers le app Khanjar : reconnexion 2 s, heartbeat 5 s.
 * Ne connaît pas les commandes : délègue chaque requête au routeur. */
const RECONNECT_MS = 2000;
const HEARTBEAT_MS = 5000;

class WsClient {
  /**
   * @param {object} opts
   * @param {string} opts.url
   * @param {() => object} opts.helloPayload
   * @param {(msg: object) => Promise<object>} opts.handleRequest  (retourne la réponse complète)
   * @param {{info: Function, error: Function, debug: Function}} opts.log
   */
  constructor({ url, helloPayload, handleRequest, log }) {
    this.url = url;
    this.helloPayload = helloPayload;
    this.handleRequest = handleRequest;
    this.log = log;
    this.ws = null;
    this.hbCount = 0;
    this.hbTimer = null;
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

  _connect() {
    let ws;
    try {
      ws = new WebSocket(this.url);
    } catch (err) {
      this.log.error(`WS construct failed: ${err.message}`);
      setTimeout(() => this._connect(), RECONNECT_MS);
      return;
    }
    this.ws = ws;

    ws.onopen = () => {
      this.log.info("WS connecté au Helper");
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

    ws.onclose = () => {
      this.log.debug("WS fermé — reconnexion dans 2 s");
      setTimeout(() => this._connect(), RECONNECT_MS);
    };
    ws.onerror = () => { /* onclose suit toujours */ };
  }
}

module.exports = { WsClient };
