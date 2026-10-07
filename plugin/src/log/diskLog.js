/* Journal disque du plugin (dossier de données UXP — pattern validé par les
 * spikes). Tampon mémoire réécrit intégralement à chaque flush : l'append
 * n'est pas garanti par l'API de stockage UXP. */
const uxp = require("uxp");

const MAX_LINES = 2000;

class DiskLog {
  constructor(fileName) {
    this.fileName = fileName;
    this.lines = [];
    this.file = null;
    this.nativePath = "(non résolu)";
    this.debugSink = null; // event "log" vers le Helper quand setDebug actif
  }

  async init() {
    try {
      const folder = await uxp.storage.localFileSystem.getDataFolder();
      this.nativePath = `${folder.nativePath}/${this.fileName}`;
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

  async flush() {
    if (!this.file) return;
    try { await this.file.write(this.lines.join("\n") + "\n"); } catch (e) { /* best effort */ }
  }
}

module.exports = { DiskLog };
