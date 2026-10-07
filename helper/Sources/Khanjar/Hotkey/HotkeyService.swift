import AppKit
import Carbon.HIToolbox

/// Raccourcis globaux via Carbon RegisterEventHotKey (aucune permission
/// requise — validé par les spikes). Multi-raccourcis : chaque enregistrement
/// porte un id ; le handler Carbon retrouve l'id via GetEventParameter.
/// Tous ne déclenchent que si Premiere est au premier plan.
final class HotkeyService {
    static let shared = HotkeyService()

    struct HotkeyID {
        static let palette: UInt32 = 1
        static let adjustmentLayer: UInt32 = 2
        /// Raccourcis presets : ids alloués à partir de 100 (id = presetBase + index).
        static let presetBase: UInt32 = 100
    }

    private var registrations: [UInt32: (ref: EventHotKeyRef, action: () -> Void)] = [:]
    private var handlerInstalled = false
    private let log = Logger.shared

    @discardableResult
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        unregister(id: id)
        installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: 0x4B484E4A /* 'KHNJ' */, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else {
            log.error("RegisterEventHotKey #\(id) en échec (status \(status)) — raccourci déjà pris ?")
            return false
        }
        registrations[id] = (ref, action)
        log.info("Raccourci global #\(id) enregistré (keyCode=\(keyCode), modifiers=\(modifiers))")
        return true
    }

    func unregister(id: UInt32) {
        if let entry = registrations.removeValue(forKey: id) {
            UnregisterEventHotKey(entry.ref)
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
        let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        guard bundleId.hasPrefix("com.adobe.PremierePro") else {
            log.debug("Raccourci #\(id) ignoré (premier plan : \(bundleId))")
            return
        }
        registrations[id]?.action()
    }
}
