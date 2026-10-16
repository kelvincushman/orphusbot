/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. Portions (c) 2024 Based Hardware Contributors, MIT (see LICENSE-UPSTREAM). */

import Cocoa
import ServiceManagement

// MARK: - Menu Bar Manager
class MenuBarManager: NSObject {
    
    // MARK: - Notification Names
    static let toggleWindowNotification = Notification.Name("com.kelvinlee.menubar.toggleWindow")
    static let toggleFloatingChatNotification = Notification.Name("com.kelvinlee.menubar.toggleFloatingChat")
    static let openChatWindowNotification = Notification.Name("com.kelvinlee.menubar.openChatWindow")
    static let quitApplicationNotification = Notification.Name("com.kelvinlee.menubar.quitApplication")
    
    // MARK: - Singleton
    static let shared = MenuBarManager()
    
    // MARK: - Properties
    private var statusBarItem: NSStatusItem?
    private weak var mainWindow: NSWindow?
    private var isVisibleObservation: NSKeyValueObservation?
    
    // MARK: - Initialization
    private override init() {
        super.init()
    }
    
    // MARK: - Configuration
    func configure(mainWindow: NSWindow) {
        self.mainWindow = mainWindow
    }
    
    // MARK: - Setup
    func setupMenuBarItem() {
        // Create status bar item
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        guard let statusBarItem = statusBarItem else {
            print("ERROR: Failed to create status bar item")
            return
        }
        
        // Set up the button with custom icon
        if let button = statusBarItem.button {
            // Load custom icon from assets
            if let customIcon = NSImage(named: "app_launcher_icon") {
                customIcon.isTemplate = true  // Make it adapt to dark/light mode
                customIcon.size = NSSize(width: 18, height: 18)  // Appropriate menu bar size
                button.image = customIcon
            } else {
                // Fallback to system icon if custom icon fails to load
                button.image = NSImage(systemSymbolName: "mic.circle", accessibilityDescription: "KelvinLee")
                print("WARNING: Could not load custom app_launcher_icon, using fallback")
            }
            button.toolTip = "KelvinLee - Always On AI"
        }
        
        // Create menu
        let menu = NSMenu()
        
        // Open KelvinLee Window item
        let openKelvinLeeItem = NSMenuItem(title: "Open KelvinLee", action: #selector(openKelvinLeeWindow), keyEquivalent: "m")
        openKelvinLeeItem.target = self
        openKelvinLeeItem.keyEquivalentModifierMask = [.command]
        menu.addItem(openKelvinLeeItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Control Bar Toggle
        let toggleControlBarItem = NSMenuItem(title: "Toggle Control Bar", action: #selector(toggleFloatingChat), keyEquivalent: "\\")
        toggleControlBarItem.target = self
        toggleControlBarItem.keyEquivalentModifierMask = [.command]
        toggleControlBarItem.tag = 200
        menu.addItem(toggleControlBarItem)
        
        // Chat Window
        let openChatWindowItem = NSMenuItem(title: "Ask AI", action: #selector(openChatWindow), keyEquivalent: "\r")
        openChatWindowItem.target = self
        openChatWindowItem.keyEquivalentModifierMask = [.command]
        openChatWindowItem.tag = 201
        menu.addItem(openChatWindowItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Launch at Login item
        if #available(macOS 13.0, *) {
            let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            launchAtLoginItem.target = self
            updateLaunchAtLoginState(for: launchAtLoginItem)
            menu.addItem(launchAtLoginItem)
        }
        
        let aboutItem = NSMenuItem(title: "About KelvinLee", action: #selector(openKelvinLeeWebsite), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Quit item
        let quitItem = NSMenuItem(title: "Quit KelvinLee", action: #selector(quitApplication), keyEquivalent: "q")
        quitItem.target = self
        quitItem.keyEquivalentModifierMask = [.command]
        menu.addItem(quitItem)
        
        statusBarItem.menu = menu
        
        print("INFO: Menu bar item created successfully")
    }
    
    // MARK: - Public Methods
    
    func observeFloatingControlBar(_ controlBar: FloatingControlBar) {
        isVisibleObservation = controlBar.observe(\.isVisible, options: [.initial, .new]) { [weak self] _, change in
            DispatchQueue.main.async {
                self?.updateFloatingChatMenuItemState(isVisible: change.newValue ?? false)
            }
        }
    }
    
    func cleanup() {
        NotificationCenter.default.removeObserver(self)
        if let statusBarItem = statusBarItem {
            NSStatusBar.system.removeStatusItem(statusBarItem)
            self.statusBarItem = nil
        }
    }
    
    // MARK: - Private Methods
    
    private func updateFloatingChatMenuItemState(isVisible: Bool) {
        guard let menu = statusBarItem?.menu,
              let menuItem = menu.item(withTag: 200) else {
            print("WARNING: Cannot find control bar menu item with tag 200")
            return
        }
        menuItem.state = isVisible ? .on : .off
        menuItem.title = isVisible ? "Hide Control Bar" : "Show Control Bar"
    }
    
    
    
    private func updateMenuItemTitle(itemIndex: Int, to newTitle: String) {
        guard let menu = statusBarItem?.menu,
              itemIndex < menu.numberOfItems else { 
            print("WARNING: Cannot update menu item at index \(itemIndex)")
            return
        }
        
        if let menuItem = menu.item(at: itemIndex) {
            menuItem.title = newTitle
        }
    }
    
    // MARK: - Menu Actions
    
    @available(macOS 13.0, *)
    private func updateLaunchAtLoginState(for item: NSMenuItem) {
        item.state = SMAppService.mainApp.status == SMAppService.Status.enabled ? .on : .off
    }
    
    @available(macOS 13.0, *)
    private func performToggleLaunchAtLogin(for item: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == SMAppService.Status.enabled {
                try SMAppService.mainApp.unregister()
                item.state = .off
            } else {
                try SMAppService.mainApp.register()
                item.state = .on
            }
        } catch {
            print("ERROR: Failed to update Launch at Login status: \(error.localizedDescription)")
        }
    }
    
    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        if #available(macOS 13.0, *) {
            performToggleLaunchAtLogin(for: sender)
        }
    }
    
    @objc private func openKelvinLeeWindow() {
        print("INFO: Menu bar open KelvinLee window action triggered")
        NotificationCenter.default.post(name: MenuBarManager.toggleWindowNotification, object: nil)
    }

    @objc private func toggleFloatingChat() {
        NotificationCenter.default.post(name: MenuBarManager.toggleFloatingChatNotification, object: nil)
    }

    @objc private func openChatWindow() {
        NotificationCenter.default.post(name: MenuBarManager.openChatWindowNotification, object: nil)
    }
    
    @objc private func openKelvinLeeWebsite() {
        print("INFO: Menu bar about action triggered - opening example.com")
        if let url = URL(string: "https://example.com") {
            NSWorkspace.shared.open(url)
        }
    }
    
    @objc private func quitApplication() {
        print("INFO: Menu bar quit action triggered")
        NotificationCenter.default.post(name: MenuBarManager.quitApplicationNotification, object: nil)
    }
} 
