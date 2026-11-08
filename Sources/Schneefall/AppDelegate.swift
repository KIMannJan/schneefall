import AppKit
import ServiceManagement
import SnowCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var engine: Engine!
    private var world: World!
    private let pauseItem = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Beim Login starten", action: #selector(toggleLogin), keyEquivalent: "")
    private let stackedItem = NSMenuItem(title: "Gestapelte Monitore: Schnee nur unten", action: #selector(toggleStacked), keyEquivalent: "")
    private let tiltItem = NSMenuItem(title: "Neigung folgen", action: #selector(toggleTilt), keyEquivalent: "")
    private var strengthItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice(), let renderer = Renderer(device: device) else {
            NSLog("Schneefall: Metal nicht verfügbar")
            NSApp.terminate(nil)
            return
        }
        world = World(seed: UInt64.random(in: 1...UInt64.max))
        world.strength = Strength(rawValue: UserDefaults.standard.object(forKey: "strength") as? Int ?? -1) ?? .medium
        world.stackedFallThrough = UserDefaults.standard.bool(forKey: "stackedFallThrough")
        engine = Engine(world: world, renderer: renderer)
        engine.followTilt = UserDefaults.standard.object(forKey: "followTilt") as? Bool ?? true
        engine.start()

        let menu = NSMenu()
        menu.delegate = self
        pauseItem.target = self
        menu.addItem(pauseItem)
        let strengthMenu = NSMenu()
        for (strength, title) in zip(Strength.allCases, ["Leicht", "Mittel", "Stark", "Schneesturm"]) {
            let item = NSMenuItem(title: title, action: #selector(setStrength(_:)), keyEquivalent: "")
            item.target = self
            item.tag = strength.rawValue
            strengthMenu.addItem(item)
            strengthItems.append(item)
        }
        let strengthItem = NSMenuItem(title: "Stärke", action: nil, keyEquivalent: "")
        strengthItem.submenu = strengthMenu
        menu.addItem(strengthItem)
        let clearItem = NSMenuItem(title: "Schnee abtauen", action: #selector(clearSnow), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)
        stackedItem.target = self
        menu.addItem(stackedItem)
        tiltItem.target = self
        tiltItem.isHidden = !TiltSensor.isAvailable      // only MacBooks with Apple silicon have the sensor
        menu.addItem(tiltItem)
        menu.addItem(.separator())
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Schneefall")
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        pauseItem.title = engine.paused ? "Weiter schneien" : "Pause"
        for item in strengthItems { item.state = item.tag == world.strength.rawValue ? .on : .off }
        stackedItem.state = world.stackedFallThrough ? .on : .off
        tiltItem.state = engine.followTilt ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func togglePause() { engine.paused.toggle() }

    @objc private func setStrength(_ sender: NSMenuItem) {
        world.strength = Strength(rawValue: sender.tag) ?? .medium
        UserDefaults.standard.set(sender.tag, forKey: "strength")
    }

    @objc private func clearSnow() { world.clearAll() }

    @objc private func toggleTilt() {
        engine.followTilt.toggle()
        UserDefaults.standard.set(engine.followTilt, forKey: "followTilt")
    }

    func applicationWillTerminate(_ notification: Notification) { engine?.shutdown() }

    @objc private func toggleStacked() {
        world.stackedFallThrough.toggle()
        UserDefaults.standard.set(world.stackedFallThrough, forKey: "stackedFallThrough")
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Autostart konnte nicht geändert werden"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}
