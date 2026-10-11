/* Journal disque du plugin (dossier de données UXP — pattern validé par les
 * spikes). Tampon mémoire réécrit intégralement à chaque flush : l'append
 * n'est pas garanti par l'API de stockage UXP. */
const uxp = require("uxp");

const MAX_LINES = 2000;

/* « khanjar-executor.log » → « khanjar-executor.prev.log ». */
function previousName(fileName) {
  return fileName.replace(/\.log$/i, "") + ".prev.log";
}

class DiskLog {
  constructor(fileName) {
    this.fileName = fileName;
    this.lines = [];
    this.file = null;
    this.nativePath = "(non résolu)";
    this.debugSink = null; // event "log" vers le Helper quand setDebug actif
    this.writing = Promise.resolve();
  }

  async init() {
    try {
      const folder = await uxp.storage.localFileSystem.getDataFolder();
      this.nativePath = `${folder.nativePath}/${this.fileName}`;
      // 2026-10-09 (audit P-04) : le journal était écrasé à chaque lancement de
      // Premiere — relancer Premiere pour « réessayer » effaçait la seule trace
      // de l'échec, et un gel suivi d'un « Forcer à quitter » ne laissait rien.
      // La session précédente est copiée dans khanjar-executor.prev.log avant
      // l'écrasement (sans gravité si elle n'existe pas).
      try {
        const previous = await folder.getEntry(this.fileName);
        if (previous && typeof previous.read === "function") {
          const text = await previous.read();
          const copy = await folder.createFile(previousName(this.fileName), { overwrite: true });
          await copy.write(text);
        }
      } catch (e) { /* pas de session précédente, ou copie impossible */ }
      this.file = await folder.createFile(this.fileName, { overwrite: true });
    } catch (err) {
      console.error(`DiskLog init failed: ${err.message}`);
    }
  }

  line(level, msg) {
    const entry = `[${new Date().toISOString()}] [${level}] ${msg}`;
    this.lines.push(entry);
    if (this.lines.length > MAX_LINES) this.lines.splice(0, this.lines.length - MAX_LINES);
    console.log(entry);
    if (this.debugSink) this.debugSink(level, entry);
  }

  info(msg) { this.line("info", msg); }
  error(msg) { this.line("error", msg); }
  debug(msg) { this.line("debug", msg); }

  /* Écritures en file (2026-10-09, audit P-04) : les états de connexion sont
   * désormais flushés à chaque changement ; sans file, une écriture plus
   * ancienne pouvait finir APRÈS une plus récente et laisser un fichier en
   * retard d'une ligne. Avant init (dossier pas encore prêt), les lignes
   * restent en mémoire et partent au premier flush. */
  async flush() {
    if (!this.file) return;
    const file = this.file;
    this.writing = this.writing.then(async () => {
      try { await file.write(this.lines.join("\n") + "\n"); } catch (e) { /* best effort */ }
    });
    return this.writing;
  }
}

module.exports = { DiskLog, previousName };
