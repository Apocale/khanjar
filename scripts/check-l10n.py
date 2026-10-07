#!/usr/bin/env python3
"""Vérifie que chaque texte d'interface L("…") / LF("…") a sa traduction française.

Clé = texte anglais. Un texte ajouté au code sans traduction s'afficherait en anglais
chez un utilisateur francophone, sans aucune erreur : ce contrôle le rend bloquant.
Signale aussi les traductions orphelines (clé disparue du code) et les formats
(%@, %ld) qui ne correspondent pas entre la clé et sa traduction.
"""
import pathlib, re, sys

root = pathlib.Path(__file__).resolve().parent.parent / "helper"
call = re.compile(r'\bLF?\(\s*"((?:[^"\\]|\\.)*)"')
entry = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$')
fmt = re.compile(r'%(?:\d+\$)?(?:@|l?d|ld|f|s)')

def unescape(s):
    return s.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")

keys = {}
for f in sorted((root / "Sources").rglob("*.swift")):
    for m in call.finditer(f.read_text()):
        keys.setdefault(unescape(m.group(1)), f"{f.relative_to(root)}")

fr = {}
for line in (root / "Resources/fr.lproj/Localizable.strings").read_text(encoding="utf-8").splitlines():
    m = entry.match(line)
    if m: fr[unescape(m.group(1))] = unescape(m.group(2))

missing = sorted(k for k in keys if k not in fr)
orphans = sorted(k for k in fr if k not in keys)
badfmt = sorted(k for k in keys if k in fr and fmt.findall(k) != fmt.findall(fr[k]))

for k in missing: print(f"MANQUANT  {keys[k]} : {k!r}")
for k in badfmt:  print(f"FORMAT    {k!r} → {fr[k]!r}")
for k in orphans: print(f"ORPHELIN  {k!r}")
print(f"l10n : {len(keys)} textes, {len(fr)} traductions, "
      f"{len(missing)} manquante(s), {len(badfmt)} format(s) faux, {len(orphans)} orpheline(s)")
sys.exit(1 if missing or badfmt else 0)
