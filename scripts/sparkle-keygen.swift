// Crée la paire de clés qui signe les mises à jour de Khanjar (EdDSA / ed25519).
//   swift scripts/sparkle-keygen.swift
//
// Pourquoi pas `generate_keys` de Sparkle : il range la clé dans le trousseau, et
// chaque signature déclenche alors une fenêtre d'autorisation macOS. Ici la clé est un
// simple fichier, au format que `sign_update --ed-key-file` lit (graine de 32 octets
// en base64 — vérifié le 2026-10-06 : signature produite par sign_update, validée par
// CryptoKit avec la clé publique).
//
// ⚠️ La clé PRIVÉE ne doit jamais être perdue ni publiée : sans elle, plus aucune mise
// à jour ne peut atteindre les gens déjà installés. Sauvegarde-la (gestionnaire de mots
// de passe). Ce script refuse d'écraser une clé existante.
import CryptoKit
import Foundation

let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/khanjar")
let privURL = dir.appendingPathComponent("sparkle-ed25519.key")
let pubURL = dir.appendingPathComponent("sparkle-ed25519.pub")
guard !FileManager.default.fileExists(atPath: privURL.path) else {
    print("Une clé existe déjà : \(privURL.path) — rien n'est modifié.")
    exit(0)
}
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
let key = Curve25519.Signing.PrivateKey()
guard FileManager.default.createFile(atPath: privURL.path,
                                     contents: Data((key.rawRepresentation.base64EncodedString() + "\n").utf8),
                                     attributes: [.posixPermissions: 0o600]) else {
    print("Impossible d'écrire \(privURL.path)"); exit(1)
}
try (key.publicKey.rawRepresentation.base64EncodedString() + "\n").write(to: pubURL, atomically: true, encoding: .utf8)
print("Clé privée : \(privURL.path) (lisible par toi seul) — À SAUVEGARDER")
print("Clé publique : \(pubURL.path) — embarquée dans l'app par build-app.sh")
