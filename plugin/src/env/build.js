/* Réglages de construction du plugin.
 *
 * Ce fichier porte les valeurs SÛRES par défaut (version publiée). Le script
 * scripts/build-plugin.sh le réécrit dans sa copie de travail avant de zipper
 * le .ccx — jamais dans les sources :
 *   - DEV_HARNESS : commandes de harnais qui CRÉENT des projets, importent des
 *     médias ou posent des keyframes de test. Utiles en développement (modes CLI
 *     multi-test, fidelity-test…), à ne JAMAIS livrer : n'importe quel
 *     programme connecté au pont pourrait s'en servir. `--dev` les active.
 *   - HELPER_URL : adresse du pont. Le manifeste n'autorise QUE les WebSockets
 *     locaux (requiredPermissions.network.domains = ["ws://localhost/"]) : le
 *     plugin ne peut parler à rien d'autre, ni sur le Mac ni sur internet.
 *     ⚠️ « localhost », PAS « 127.0.0.1 » (mesuré le 2026-10-06, Premiere 26.5.2) :
 *     UXP refuse toute règle réseau en adresse IP (« Manifest entry not found »,
 *     avec ou sans port), et la règle ne porte PAS de port. Le pont écoute sur
 *     127.0.0.1 ; UXP y aboutit en résolvant localhost. */
module.exports = {
  DEV_HARNESS: false,
  HELPER_URL: "ws://localhost:48123",
};
