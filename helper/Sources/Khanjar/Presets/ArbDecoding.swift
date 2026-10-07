import Foundation

/// Lecture des paramètres « Arb » (ArbVideoComponentParam) d'un .prfpset.
///
/// On a longtemps cru ces blocs illisibles : un preset contenant Lumetri ou un masque
/// était donc retiré de la palette en bloc. Décodés le 2026-10-07 (analyse des presets
/// d'Isma, de ses .prproj et des presets Adobe), ce sont des formats structurés, rangés
/// en base64 dans `<StartKeyframeValue Encoding="base64">` :
///  - Lumetri : un état « neutre » existe pour chacun de ses 24 paramètres Arb. Un preset
///    dont TOUS les Arb sont neutres ne fait que bouger des curseurs (Exposure, Contrast,
///    Vignette…), que le pipeline actuel rejoue déjà. Ceux qui touchent aux courbes, roues,
///    LUT restent exclus : l'API UXP ne permet pas d'écrire un Arb.
///  - Masques : un sous-composant AE.ADBE AEMask / AEMask2 dont le tracé a 0 sommet est
///    vide (constaté sur les deux « Drop Shadow Preset » d'Isma) et ne change pas l'image.
/// L'API ne permettant ni d'écrire un Arb ni de créer un masque, rien de ce qui est décodé
/// ici n'est REJOUÉ : ça sert uniquement à ne plus exclure à tort.
enum ArbDecoding {

    /// Décode la valeur base64 d'un paramètre Arb. nil si absente ou illisible.
    static func bytes(fromBase64 text: String?) -> Data? {
        guard let text, !text.isEmpty else { return nil }
        return Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines),
                    options: .ignoreUnknownCharacters)
    }

    // MARK: - Lumetri

    /// Valeur vide d'un Arb Lumetri : FE FE.
    private static let empty = Data([0xFE, 0xFE])
    /// Clé HSL secondaire par défaut (identique dans les 363 Lumetri analysés).
    private static let defaultHSLKey = Data(hex: "000000003f0000000000000000010000003f0000000000000000010000003f000000000000000001")
    /// GUID d'espace colorimétrique du Look par défaut.
    private static let defaultLookColorSpace = Data(hex: "3491c4cd1e212af09af0a4e119768173")

    /// Paramètres Arb de Lumetri (ParameterID → rôle), schéma 26.x à 130 paramètres.
    /// true = neutre (le preset ne s'en sert pas), false = utilisé, nil = inconnu.
    /// Un ParameterID absent de cette liste, ou à -1 (ancien schéma des presets Adobe),
    /// renvoie nil : par prudence le preset reste exclu.
    static func isNeutralLumetriArb(parameterID: Int, bytes: Data) -> Bool? {
        switch parameterID {
        case 1, 4, 24, 60, 95, 96, 98, 100, 125, 126:   // chaînes : pipeline, LUT, Look, LUT embarquée
            return bytes == empty
        case 32:                                          // teintes Creative ombres / hautes lumières
            return bytes.allSatisfy { $0 == 0 }
        case 39:                                          // courbes RGB : chaque point sur y = x
            return curvePoints(bytes).allSatisfy { abs($0.y - $0.x) < 1e-9 }
        case 42, 106, 108, 110, 112:                      // courbes Teinte/Sat… : tous les y à 0
            return curvePoints(bytes).allSatisfy { abs($0.y) < 1e-9 }
        case 47, 85:                                      // roues : triplets (0, 0.5, 0)
            guard bytes.count % 24 == 0 else { return false }
            let values = doubles(bytes)
            return stride(from: 0, to: values.count, by: 3).allSatisfy {
                abs(values[$0]) < 1e-9 && abs(values[$0 + 1] - 0.5) < 1e-9 && abs(values[$0 + 2]) < 1e-9
            }
        case 73:                                          // clé HSL secondaire
            return bytes == defaultHSLKey
        case 93, 99:
            return bytes == Data(count: 4)
        case 122:                                         // Auto Tone (JSON en UTF-16)
            guard let text = String(data: bytes, encoding: .utf16LittleEndian)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0")),
                  let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return false }
            guard json["mAutoTonePressed"] as? Bool == false else { return false }
            return json.allSatisfy { key, value in
                key == "mLastPressedAutoToneButton" || (value as? NSNumber).map { $0.doubleValue == 0 } == true
            }
        case 129:                                         // espace colorimétrique du Look
            return bytes == empty || bytes == defaultLookColorSpace
        default:
            return nil
        }
    }

    /// Courbes : blocs de 520 octets [u32 tag][u32 n][n × (f64 x, f64 y)].
    static func curvePoints(_ bytes: Data) -> [(x: Double, y: Double)] {
        var points: [(x: Double, y: Double)] = []
        var block = 0
        while block + 8 <= bytes.count {
            let n = Int(bytes.u32(at: block + 4) ?? 0)
            for i in 0..<min(n, 32) {
                let offset = block + 8 + 16 * i
                guard let x = bytes.f64(at: offset), let y = bytes.f64(at: offset + 8) else { break }
                points.append((x, y))
            }
            block += 520
        }
        return points
    }

    private static func doubles(_ bytes: Data) -> [Double] {
        stride(from: 0, to: bytes.count - 7, by: 8).compactMap { bytes.f64(at: $0) }
    }

    // MARK: - Masques

    /// Nombre de sommets du tracé d'un masque. nil si le format n'est pas reconnu
    /// (le masque est alors compté comme présent, par prudence).
    ///  - AE.ADBE AEMask (ancien) : signature « 2cin », puis u32 version, u32 fermé, u32 N.
    ///  - AE.ADBE AEMask2 (Premiere 26) : 8 octets ou moins = vide ; sinon N en u32 à l'octet 17.
    static func maskVertexCount(_ bytes: Data) -> Int? {
        if bytes.starts(with: Array("2cin".utf8)) {
            return bytes.u32(at: 12).map(Int.init)
        }
        if bytes.count <= 8 { return 0 }
        return bytes.u32(at: 17).map(Int.init)
    }
}

extension Data {
    init(hex: String) {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            if let byte = UInt8(hex[index..<next], radix: 16) { data.append(byte) }
            index = next
        }
        self = data
    }

    func u32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return withUnsafeBytes { raw in
            UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }

    func f64(at offset: Int) -> Double? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        return withUnsafeBytes { raw in
            Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)))
        }
    }
}
