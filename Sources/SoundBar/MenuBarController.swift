import AppKit

/// SoundBar's menu bar item.
///
/// The two things the user changes most — the pattern and the colour — are submenus at the top, each
/// with a live checkmark. Below them is the on/off switch, which matters because the Touch Bar long
/// press can stop the visualiser and there needs to be a way back that does not involve the terminal.
final class MenuBarController: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private let coordinator: Coordinator
    private let btt: BTTController
    private let audio: AudioActivityMonitor
    private let settings = Settings.shared

    init(coordinator: Coordinator, btt: BTTController, audio: AudioActivityMonitor) {
        self.coordinator = coordinator
        self.btt = btt
        self.audio = audio
        super.init()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.item = item
        refreshIcon()
    }

    /// The icon carries state at a glance: solid while visualising, dim when idle, slashed when
    /// SoundBar is switched off, and a muted speaker when the output is muted.
    func refreshIcon() {
        guard let button = item?.button else { return }
        if !settings.enabled {
            button.image = Self.symbolIcon("music.note.slash")
        } else if VolumeController.isOutputMuted() {
            button.image = Self.symbolIcon("speaker.slash.fill")
        } else {
            button.image = Self.noteIcon()
        }
        button.alphaValue = coordinator.isVisualising ? 1.0 : 0.6
        button.toolTip = "SoundBar — \(settings.style.displayName), \(settings.paletteName)"
    }

    /// Bold weight so the glyph reads at menu-bar size, and blank space on the trailing edge so it
    /// doesn't sit flush against whatever status item is next to it. Used for the off/muted states,
    /// which stay as SF Symbols — a slash pictogram sheared to match the note's italic would just
    /// read as broken.
    private static func symbolIcon(_ symbolName: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 0, weight: .bold)
        guard let glyph = NSImage(systemSymbolName: symbolName, accessibilityDescription: "SoundBar")?
            .withSymbolConfiguration(config) else { return nil }

        let trailingPadding: CGFloat = 8
        let size = NSSize(width: glyph.size.width + trailingPadding, height: glyph.size.height)
        let padded = NSImage(size: size)
        padded.lockFocus()
        glyph.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        padded.unlockFocus()
        padded.isTemplate = true
        return padded
    }

    /// The idle/active icon: a bundled vector note (Resources/MenuBarNote.svg) rather than a drawn
    /// glyph — a real bold illustration reads better at menu-bar size than any synthesised weight or
    /// shear did. The source file has ~30pt of dead margin baked in on each side of its 512×512
    /// canvas (measured directly from its rendered alpha), which is cropped away here so our own
    /// padding is the only padding, keeping the note centred with equal space on both sides.
    private static let noteTemplate: NSImage = {
        guard let path = Bundle.main.path(forResource: "MenuBarNote", ofType: "svg"),
              let source = NSImage(contentsOfFile: path) else {
            Log.error("app", "MenuBarNote.svg missing from the bundle; falling back to SF Symbol")
            return symbolIcon("music.note") ?? NSImage()
        }

        let inkRect = NSRect(x: 30, y: 0, width: source.size.width - 60, height: source.size.height)
        let height: CGFloat = 16
        let width = height * inkRect.width / inkRect.height
        let padding: CGFloat = 8
        let canvasSize = NSSize(width: width + padding * 2, height: height)

        let image = NSImage(size: canvasSize)
        image.lockFocus()
        source.draw(in: NSRect(x: padding, y: 0, width: width, height: height),
                    from: inkRect, operation: .sourceOver, fraction: 1)
        image.unlockFocus()
        image.isTemplate = true
        return image
    }()

    private static func noteIcon() -> NSImage { noteTemplate }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = !settings.enabled ? "Off"
            : (coordinator.isVisualising ? "Visualising" : "Idle")
        menu.addItem(header("SoundBar — \(status)"))
        menu.addItem(header("Audio: \(coordinator.currentReason)"))
        if coordinator.isOverridden {
            menu.addItem(header("Paused by long press until audio restarts"))
        }

        menu.addItem(.separator())
        menu.addItem(styleMenuItem())
        menu.addItem(paletteMenuItem())

        menu.addItem(.separator())
        // The way back after a long press or an accidental switch-off.
        let power = action(settings.enabled ? "Turn SoundBar Off" : "Turn SoundBar On",
                           #selector(toggleEnabled))
        power.attributedTitle = NSAttributedString(
            string: power.title,
            attributes: [.font: NSFontManager.shared.convert(NSFont.menuFont(ofSize: 0),
                                                             toHaveTrait: .boldFontMask)])
        menu.addItem(power)

        if settings.enabled {
            menu.addItem(action(coordinator.isVisualising ? "Stop Visualiser Now" : "Start Visualiser Now",
                                #selector(toggleVisualiser)))
        }
        menu.addItem(check(VolumeController.isOutputMuted() ? "Muted" : "Mute Output",
                           #selector(toggleMute), VolumeController.isOutputMuted()))

        menu.addItem(.separator())
        menu.addItem(behaviourMenuItem())
        menu.addItem(gesturesMenuItem())
        menu.addItem(excludedSourcesMenuItem())

        let players = audio.currentOutputSources()
        if !players.isEmpty {
            menu.addItem(.separator())
            menu.addItem(header("Counted as playing:"))
            for player in players {
                // Clicking a source ignores it, which is the fix when an app holds an output stream
                // open while idle and keeps the visualiser awake.
                let entry = NSMenuItem(title: "    \(player)  — click to ignore",
                                       action: #selector(excludeSource(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = player
                menu.addItem(entry)
            }
        }

        menu.addItem(.separator())
        for warning in permissionWarnings() {
            let entry = NSMenuItem(title: warning.title, action: #selector(openPermission(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = warning.paneURL
            menu.addItem(entry)
        }
        menu.addItem(action("Check BetterTouchTool Touch Bar…", #selector(checkBTT)))
        menu.addItem(action("Open Log", #selector(openLog)))
        menu.addItem(.separator())
        menu.addItem(action("Quit SoundBar", #selector(quit)))

        refreshIcon()
    }

    // MARK: - Submenus

    /// The patterns, in the order a two-finger tap cycles through them.
    private func styleMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Pattern  ▸  \(settings.style.displayName)",
                                action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for style in VisualStyle.allCases {
            let item = NSMenuItem(title: style.displayName, action: #selector(chooseStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.state = settings.style == style ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    /// The colour ramps, including the ones imported from AVTouchBar's colour manager. Each carries a
    /// swatch drawn from the ramp itself, so the list can be read without trying them all.
    private func paletteMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Colour  ▸  \(settings.paletteName)", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for palette in PaletteLibrary.all() {
            let item = NSMenuItem(title: palette.name, action: #selector(choosePalette(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = palette.name
            item.state = settings.paletteName.caseInsensitiveCompare(palette.name) == .orderedSame ? .on : .off
            item.image = swatch(for: palette)
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    /// A little gradient chip of the ramp, so the list can be read at a glance.
    private func swatch(for palette: Palette) -> NSImage {
        let size = NSSize(width: 44, height: 12)
        let image = NSImage(size: size)
        image.lockFocus()
        let steps = 22
        for step in 0..<steps {
            palette.color(at: Double(step) / Double(steps - 1)).setFill()
            NSRect(x: CGFloat(step) * size.width / CGFloat(steps), y: 0,
                   width: size.width / CGFloat(steps) + 1, height: size.height).fill()
        }
        image.unlockFocus()
        return image
    }

    /// What the strip shows when a microphone is live — the interesting case being a call, where the
    /// app holds an output stream open at the same time.
    private func inputModeMenuItem() -> NSMenuItem {
        let current = settings.inputMode
        let parent = NSMenuItem(title: "Input Meter  ▸  \(current.displayName)",
                                action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for mode in InputMode.allCases {
            let item = NSMenuItem(title: mode.displayName, action: #selector(chooseInputMode(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = current == mode ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    @objc private func chooseInputMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = InputMode(rawValue: raw) else { return }
        settings.setInputMode(mode)
        Log.info("app", "input meter mode set to '\(mode.displayName)'")
        coordinator.settingsChanged()
        refreshIcon()
    }

    private func behaviourMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Behaviour", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(check("Fullscreen Touch Bar", #selector(toggleFullscreen), settings.fullscreen))
        submenu.addItem(check("Keep Touch Bar Awake (not working on this macOS)", #selector(toggleKeepAwake), settings.keepTouchBarAwake))
        submenu.addItem(check("Start on Playback", #selector(toggleWatchOutput), settings.watchOutput))
        submenu.addItem(check("Start on Microphone Use", #selector(toggleWatchInput), settings.watchInput))
        submenu.addItem(inputModeMenuItem())
        parent.submenu = submenu
        return parent
    }

    /// Not settings so much as a reminder of what the Touch Bar does, with switches underneath.
    private func gesturesMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Touch Bar Gestures", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(header("One-finger tap — next colour"))
        submenu.addItem(header("Two-finger tap — next pattern"))
        submenu.addItem(header("Double tap — mute"))
        submenu.addItem(header("Long press — stop visualiser"))
        submenu.addItem(header("One-finger slide — volume"))
        submenu.addItem(.separator())
        submenu.addItem(check("Taps Change Colour and Pattern", #selector(toggleTapCycles), settings.tapCyclesStyle))
        submenu.addItem(check("Double Tap Mutes", #selector(toggleDoubleTapMutes), settings.doubleTapMutes))
        submenu.addItem(check("Long Press Stops", #selector(toggleLongPress), settings.longPressStopsATB))
        submenu.addItem(check("Slide Controls Volume", #selector(toggleSlideVolume), settings.slideVolume))
        parent.submenu = submenu
        return parent
    }

    /// Sources dismissed with "click to ignore" below, or added by hand with `defaults write
    /// com.ryoji.SoundBar extraExcludedBundleIDs`. Kept separate from the live "Counted as playing"
    /// list further down: this one is the persistent, editable record, and stays visible even when
    /// nothing is currently making sound.
    private func excludedSourcesMenuItem() -> NSMenuItem {
        let extra = (settings.defaults.array(forKey: Settings.Key.extraExcludedBundleIDs) as? [String]) ?? []
        let parent = NSMenuItem(
            title: extra.isEmpty ? "Excluded Sources" : "Excluded Sources  ▸  \(extra.count)",
            action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if extra.isEmpty {
            submenu.addItem(header("No sources excluded"))
        } else {
            for bundleID in extra.sorted() {
                let entry = NSMenuItem(title: "    \(bundleID)  — click to restore",
                                       action: #selector(restoreSource(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = bundleID
                submenu.addItem(entry)
            }
            submenu.addItem(.separator())
            submenu.addItem(action("Restore All", #selector(restoreAllSources)))
        }
        parent.submenu = submenu
        return parent
    }

    private struct PermissionWarning {
        let title: String
        let paneURL: String
    }

    /// Only surfaced when actually missing. SoundBar needs no Accessibility permission: it draws the
    /// Touch Bar itself rather than driving another app's menus.
    private func permissionWarnings() -> [PermissionWarning] {
        var warnings: [PermissionWarning] = []
        if settings.inputMode != .off, MicrophoneCapture.firstRealMicrophone() != nil,
           !coordinator.microphoneAvailable {
            warnings.append(PermissionWarning(
                title: "⚠︎ Grant Microphone (only to visualise mic input)…",
                paneURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"))
        }
        return warnings
    }

    // MARK: - Item builders

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    private func check(_ title: String, _ selector: Selector, _ on: Bool) -> NSMenuItem {
        let item = action(title, selector)
        item.state = on ? .on : .off
        return item
    }

    // MARK: - Actions

    @objc private func toggleVisualiser() { coordinator.toggleManually(); refreshIcon() }
    @objc private func toggleEnabled() { coordinator.setEnabled(!settings.enabled); refreshIcon() }
    @objc private func toggleMute() { VolumeController.toggleMute(); refreshIcon() }

    @objc private func toggleFullscreen() { flip(Settings.Key.fullscreen) }
    @objc private func toggleKeepAwake() { flip(Settings.Key.keepTouchBarAwake) }
    @objc private func toggleWatchOutput() { flip(Settings.Key.watchOutput) }
    @objc private func toggleWatchInput() { flip(Settings.Key.watchInput) }
    @objc private func toggleLongPress() { flip(Settings.Key.longPressStopsATB) }
    @objc private func toggleSlideVolume() { flip(Settings.Key.slideVolume) }
    @objc private func toggleTapCycles() { flip(Settings.Key.tapCyclesStyle) }
    @objc private func toggleDoubleTapMutes() { flip(Settings.Key.doubleTapMutes) }

    private func flip(_ key: String) {
        let defaults = settings.defaults
        defaults.set(!defaults.bool(forKey: key), forKey: key)
        coordinator.settingsChanged()
        refreshIcon()
    }

    @objc private func chooseStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = VisualStyle(rawValue: raw) else { return }
        coordinator.setStyle(style)
        refreshIcon()
    }

    @objc private func choosePalette(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        settings.defaults.set(name, forKey: Settings.Key.paletteName)
        Log.info("app", "palette set to '\(name)'")
        coordinator.settingsChanged()
        refreshIcon()
    }

    @objc private func excludeSource(_ sender: NSMenuItem) {
        guard let source = sender.representedObject as? String else { return }
        let defaults = settings.defaults
        var list = defaults.array(forKey: Settings.Key.extraExcludedBundleIDs) as? [String] ?? []
        guard !list.contains(source) else { return }
        list.append(source)
        defaults.set(list, forKey: Settings.Key.extraExcludedBundleIDs)
        Log.info("app", "user excluded audio source \(source)")
        coordinator.settingsChanged()
    }

    @objc private func restoreSource(_ sender: NSMenuItem) {
        guard let source = sender.representedObject as? String else { return }
        let defaults = settings.defaults
        var list = defaults.array(forKey: Settings.Key.extraExcludedBundleIDs) as? [String] ?? []
        list.removeAll { $0 == source }
        if list.isEmpty {
            defaults.removeObject(forKey: Settings.Key.extraExcludedBundleIDs)
        } else {
            defaults.set(list, forKey: Settings.Key.extraExcludedBundleIDs)
        }
        Log.info("app", "user restored audio source \(source)")
        coordinator.settingsChanged()
    }

    @objc private func restoreAllSources() {
        settings.defaults.removeObject(forKey: Settings.Key.extraExcludedBundleIDs)
        Log.info("app", "user restored all excluded audio sources")
        coordinator.settingsChanged()
    }

    @objc private func openPermission(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func checkBTT() {
        btt.verifyOwnsTouchBar { state in
            let alert = NSAlert()
            alert.messageText = "BetterTouchTool Touch Bar"
            alert.informativeText = state.description
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc private func openLog() { NSWorkspace.shared.open(Log.fileURL) }
    @objc private func quit() { NSApp.terminate(nil) }
}
