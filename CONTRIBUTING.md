# Contributing to Khanjar

Thanks for helping. A few rules keep the project reliable:

1. **Test in the real Premiere Pro.** Most bugs in this project were invisible at compile time.
   The `khanjar` command-line modes (`multi-test`, `apply-dump`, `anchor-test`, `dump-selected`)
   exist for that — see [AGENTS.md](AGENTS.md) §4.
2. **Read [AGENTS.md](AGENTS.md) §3 before touching `plugin/src/premiere/`.** Each item there cost
   hours of debugging; do not "simplify" one without proof.
3. **The protocol changes on both sides in the same commit** (Swift app + JS plugin).
4. **Interface text goes through `L("…")`**, with the English text as key and the French
   translation in `helper/Resources/fr.lproj/Localizable.strings`. `scripts/check-l10n.py`
   fails the build when a translation is missing.
5. Run `./.build/debug/khanjar selftest` before opening a pull request.

By contributing, you agree that your contribution is licensed under the GPL-3.0.
