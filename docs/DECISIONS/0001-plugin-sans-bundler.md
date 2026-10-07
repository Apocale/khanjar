# ADR 0001 — Plugin sans bundler (v0)

Date : 2026-07-07 · Statut : accepté

## Contexte
L'architecture (§3) prévoyait esbuild pour bundler le plugin UXP en un fichier.

## Décision
v0 : pas de bundler. UXP supporte `require()` relatif (CommonJS) ; les sources
multi-fichiers sont zippées telles quelles dans le .ccx.

## Justification
- Zéro dépendance npm, build = `zip` (reproductible, auditable).
- Le plugin n'a ni UI ni TypeScript ; le bundler n'apporte rien aujourd'hui.

## Conséquences / réversibilité
On introduira esbuild le jour où TypeScript ou la minification deviennent
utiles (M4+). Le script `scripts/build-plugin.sh` isole déjà l'étape de build :
le changement sera invisible pour le reste du dépôt.
