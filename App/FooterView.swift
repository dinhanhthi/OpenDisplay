import AppKit
import os
import ServiceManagement
import SwiftUI

/// What the About block shows and the DEBUG line logs.
private enum AboutInfo {
    static let author = "Anh-Thi DINH"
    static let linkText = "github.com/dinhanhthi/OpenDisplay"
    static let urlString = "https://github.com/dinhanhthi/OpenDisplay"

    /// "<CFBundleShortVersionString> (<CFBundleVersion>)".
    static var version: String {
        "\(info("CFBundleShortVersionString")) (\(info("CFBundleVersion")))"
    }

    private static func info(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "?"
    }
}

/// The popover's footer: launch at login, updates, About and Quit.
struct FooterView: View {
    let updater: Updater

    /// Collapsed on every launch, so screenshots show the display area.
    @State private var showsAbout = false
    #if DEBUG
    @State private var loggedAbout = false
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LaunchAtLoginRow()
            Button {
                // No animation: the block shows in the same frame.
                showsAbout.toggle()
            } label: {
                HStack {
                    Text("About OpenDisplay")
                    Spacer()
                    Image(systemName: showsAbout ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showsAbout { AboutBlock() }
            HStack {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        #if DEBUG
        .onAppear {
            // Once, not at every opening of the popover.
            guard !loggedAbout else { return }
            loggedAbout = true
            debugLog("About", "version=\(AboutInfo.version) author=\(AboutInfo.author) url=\(AboutInfo.urlString) "
                + "logo=\(NSImage(named: "Logo") != nil)")
        }
        #endif
    }
}

/// The inline About block: logo, name, version, author and the repository link.
private struct AboutBlock: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(decorative: "Logo")
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("OpenDisplay")
                    .font(.headline)
                Text("Version \(AboutInfo.version)")
                    .foregroundStyle(.secondary)
                Text("by \(AboutInfo.author)")
                    .foregroundStyle(.secondary)
                Button(AboutInfo.linkText) {
                    if let url = URL(string: AboutInfo.urlString) { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.link)
            }
        }
    }
}

/// Launch at login through `SMAppService.mainApp`. The switch follows the login item's real status, which can also
/// change in System Settings > General > Login Items.
private struct LaunchAtLoginRow: View {
    @State private var isOn = false

    var body: some View {
        HStack {
            Text("Launch at login")
            Spacer()
            Toggle("Launch at login", isOn: Binding(get: { isOn }, set: { set($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .onAppear(perform: sync)
        // Catch a change made in System Settings when the app comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in sync() }
    }

    private func set(_ enabled: Bool) {
        // The switch moves now; the service call follows.
        isOn = enabled
        Task {
            do {
                try await Self.apply(enabled)
                if enabled, SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            } catch {
                Logger(subsystem: "com.math2it.opendisplay", category: "LaunchAtLogin")
                    .error("Launch at login failed: \(error.localizedDescription)")
            }
            // The real status: this reverts the switch when the call threw.
            sync()
        }
    }

    /// Off the main actor: the service call is synchronous.
    @concurrent
    private nonisolated static func apply(_ enabled: Bool) async throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            // In an async context Swift picks the async `unregister()`.
            try await SMAppService.mainApp.unregister()
        }
    }

    private func sync() {
        let status = SMAppService.mainApp.status
        isOn = status == .enabled || status == .requiresApproval
    }
}
