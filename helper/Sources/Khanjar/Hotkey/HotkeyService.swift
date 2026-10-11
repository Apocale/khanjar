import AppKit
import Carbon.HIToolbox

/// Raccourcis globaux via Carbon RegisterEventHotKey (aucune permission
/// requise — validé par les spikes). Multi-raccourcis : chaque enregistrement
/// porte un id ; le handler Carbon retrouve l'id via GetEventParameter.
/// Inscrits seulement quand Premiere est au premier plan (sinon ils avaleraient
/// la frappe dans toutes les autres apps).
final class HotkeyService {
    static let shared = HotkeyService()

    struct HotkeyID {
        static let palette: UInt32 = 1
        static let adjustmentLayer: UInt32 = 2
        /// Raccourcis presets : ids alloués à partir de 100 (id = presetBase + index).
        static let presetBase: UInt32 = 100
    }

    /// Raccourcis voulus (toujours mémorisés) et raccourcis réellement inscrits chez
    /// Carbon (seulement quand Premiere est au premier plan).
    ///
    /// ⚠️ Un raccourci Carbon AVALE la frappe dans TOUTES les apps, même si on ne s'en
    /// sert pas : tant que ⌘J était inscrit, ⌘J ne marchait plus dans Chrome ni dans le
    /// Finder (audit du 2026-10-07). Le filtre « Premiere au premier plan » dans fire()
    /// ne suffisait pas : la frappe était déjà mangée. On n'inscrit donc les raccourcis
    /// que lorsque Premiere est l'app active, et on les retire dès qu'on la quitte.
    private struct Wanted { let keyCode: UInt32; let modifiers: UInt32; let action: () -> Void }
    private var wanted: [UInt32: Wanted] = [:]
    private var armed: [UInt32: EventHotKeyRef] = [:]
    private var handlerInstalled = false
    private var observing = false
    private let log = Logger.shared

    @discardableResult
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        unregister(id: id)
        installHandlerIfNeeded()
        observeActiveAppIfNeeded()
        wanted[id] = Wanted(keyCode: keyCode, modifiers: modifiers, action: action)
        log.info("Raccourci #\(id) prêt (keyCode=\(keyCode), modifiers=\(modifiers)) — actif quand Premiere est au premier plan")
        if Self.premiereIsFrontmost() { return arm(id) }
        return true
    }

    func unregister(id: UInt32) {
        disarm(id)
        wanted.removeValue(forKey: id)
    }

    private static func premiereIsFrontmost(_ app: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) -> Bool {
        app?.bundleIdentifier?.hasPrefix("com.adobe.PremierePro") == true
    }

    @discardableResult
    private func arm(_ id: UInt32) -> Bool {
        guard armed[id] == nil, let entry = wanted[id] else { return armed[id] != nil }
        let hotKeyID = EventHotKeyID(signature: 0x4B484E4A /* 'KHNJ' */, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(entry.keyCode, entry.modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else {
            log.error("RegisterEventHotKey #\(id) en échec (status \(status)) — raccourci déjà pris ?")
            // 2026-10-09 (audit A4#7) : cet échec n'était que journalisé. Le HUD de
            // l'app n'apparaissait que si Premiere était au premier plan au moment de
            // l'enregistrement — jamais le cas depuis les Réglages : le raccourci ne
            // marchait pas, sans un mot. Prévenu une fois par inscription et par session
            // (pas à chaque retour dans Premiere).
            if Self.isFirstFailure(id: id, keyCode: entry.keyCode, modifiers: entry.modifiers, reported: &reportedFailures) {
                HUD.show(L("Khanjar: one of your shortcuts is already used by another app — change it in Settings"),
                         style: .warning)
            }
            return false
        }
        armed[id] = ref
        return true
    }

    /// Inscriptions déjà signalées en échec pendant cette session (id + combinaison).
    private var reportedFailures: Set<String> = []

    /// Vrai au PREMIER échec d'une inscription (même id, même combinaison) dans la session.
    static func isFirstFailure(id: UInt32, keyCode: UInt32, modifiers: UInt32, reported: inout Set<String>) -> Bool {
        reported.insert("\(id):\(keyCode):\(modifiers)").inserted
    }

    private func disarm(_ id: UInt32) {
        if let ref = armed.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
    }

    private func observeActiveAppIfNeeded() {
        guard !observing else { return }
        observing = true
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if Self.premiereIsFrontmost(app) {
                // Ordre fixe (palette, calque, puis presets) : avant, l'ordre d'un
                // dictionnaire, qui change d'un lancement à l'autre (audit A4#7).
                self.wanted.keys.sorted().forEach { self.arm($0) }
            } else if !self.armed.isEmpty {
                self.armed.keys.forEach { self.disarm($0) }
            }
        }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            HotkeyService.shared.fire(id: hotKeyID.id)
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = true
    }

    private func fire(id: UInt32) {
        // Garde-fou : ne devrait plus arriver (raccourcis inscrits seulement dans Premiere).
        guard Self.premiereIsFrontmost() else { return }
        wanted[id]?.action()
    }
}
