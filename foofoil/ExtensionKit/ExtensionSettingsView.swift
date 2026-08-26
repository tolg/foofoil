//  ExtensionSettingsView.swift
//  foofoil
//
//  Created by tolg on 2026/8/26.

import AppKit
import SwiftUI

struct ExtensionSettingsView: View {
    @ObservedObject var manager: ExtensionManager
    @State private var preferredProviders: [String: String] = SettingsStore.shared.preferredProvidersByDomain
    @State private var autoCheck = SettingsStore.shared.extensionAutoCheckUpdates
    @State private var autoDownload = SettingsStore.shared.extensionAutoDownloadUpdates
    @State private var autoInstallMinor = SettingsStore.shared.extensionAutoInstallCompatibleMinorUpdates
    @State private var actionError: String?

    var body: some View {
        Form {
            Section {
                Toggle(NSLocalizedString("Check for Extension Updates Automatically", comment: ""), isOn: $autoCheck)
                    .onChange(of: autoCheck) { _, value in
                        SettingsStore.shared.extensionAutoCheckUpdates = value
                    }
                Toggle(NSLocalizedString("Download Extension Updates Automatically", comment: ""), isOn: $autoDownload)
                    .onChange(of: autoDownload) { _, value in
                        SettingsStore.shared.extensionAutoDownloadUpdates = value
                    }
                Toggle(
                    NSLocalizedString("Install Compatible Minor Extension Updates Automatically", comment: ""),
                    isOn: $autoInstallMinor
                )
                .onChange(of: autoInstallMinor) { _, value in
                    SettingsStore.shared.extensionAutoInstallCompatibleMinorUpdates = value
                }
            }

            if manager.items.isEmpty {
                Section {
                    Text(NSLocalizedString("No Extensions Available", comment: ""))
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(manager.items) { item in
                Section {
                    extensionRow(item)
                }
            }

            if let lastErrorMessage = manager.lastErrorMessage ?? actionError {
                Section {
                    Text(lastErrorMessage)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsWindowMetrics.width)
        .task {
            if manager.catalog == nil || SettingsStore.shared.extensionAutoCheckUpdates {
                await manager.refreshCatalog()
            }
        }
    }

    @ViewBuilder
    private func extensionRow(_ item: ExtensionSettingsItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(localizedName(item))
                        .font(.headline)
                    Text(localizedSummary(item))
                        .foregroundStyle(.secondary)
                    if let featuresSummary = localizedFeatures(item) {
                        Text(featuresSummary)
                            .font(.callout)
                    }
                    if let capabilitiesSummary = localizedCapabilities(item) {
                        Text(capabilitiesSummary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if let size = formattedSize(item.downloadSize) {
                        Text(size)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let installedVersion = item.installedVersion {
                        Text(String(format: NSLocalizedString("Installed Version Format", comment: ""), installedVersion))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if item.hasUpdate, let availableVersion = item.availableVersion {
                        Text(String(format: NSLocalizedString("Update Available Format", comment: ""), availableVersion))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if let pending = item.pendingActivationVersion {
                        Text(String(format: NSLocalizedString("Pending Activation Format", comment: ""), pending))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if item.pendingRemoval {
                        Text(NSLocalizedString("Pending Removal Message", comment: ""))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if item.status == .revoked {
                        Text(NSLocalizedString("Revoked Extension Message", comment: ""))
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                Spacer()
                if manager.inProgressIDs.contains(item.id) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    actionButtons(item)
                }
            }

            if let domain = item.enhancementDomain, item.enabled, !item.pendingRemoval {
                defaultProviderPicker(domain: domain, name: item.name)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func actionButtons(_ item: ExtensionSettingsItem) -> some View {
        HStack {
            if item.installedVersion == nil {
                Button(NSLocalizedString("Install Extension", comment: "")) {
                    run { try await manager.install(item.id) }
                }
                .accessibilityLabel(NSLocalizedString("Install Extension", comment: ""))
            } else {
                if item.hasUpdate {
                    Button(NSLocalizedString("Update Extension", comment: "")) {
                        run { try await manager.update(item.id) }
                    }
                }
                if item.canRollback {
                    Button(NSLocalizedString("Rollback Extension", comment: "")) {
                        run { try await manager.rollback(item.id) }
                    }
                }
                Button(NSLocalizedString("Remove Extension", comment: ""), role: .destructive) {
                    confirmRemoval(item)
                }
            }
        }
    }

    private func defaultProviderPicker(domain: String, name: String) -> some View {
        let providers = ExtensionHost.shared.resolver.allDescriptors().filter {
            $0.enhancementDomain == domain
        }
        return Picker(NSLocalizedString("Default Audio Provider", comment: ""), selection: binding(for: domain)) {
            Text(NSLocalizedString("System Player", comment: "")).tag("builtin.audio")
            ForEach(providers.filter { !$0.isBuiltIn }, id: \.id) { provider in
                Text(name).tag(provider.id)
            }
        }
        .accessibilityLabel(NSLocalizedString("Default Audio Provider", comment: ""))
    }

    private func binding(for domain: String) -> Binding<String> {
        Binding(
            get: { preferredProviders[domain] ?? "builtin.audio" },
            set: { value in
                preferredProviders[domain] = value
                ExtensionHost.shared.setPreferredProvider(value, for: domain)
            }
        )
    }

    private func confirmRemoval(_ item: ExtensionSettingsItem) {
        let alert = NSAlert()
        alert.messageText = String(format: NSLocalizedString("Uninstall Extension Title Format", comment: ""), item.name)
        alert.informativeText = String(format: NSLocalizedString("Uninstall Extension Message Format", comment: ""), item.name)
        alert.addButton(withTitle: NSLocalizedString("Remove Extension", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run { try await manager.uninstall(item.id) }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        Task { @MainActor in
            do {
                actionError = nil
                try await work()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func localizedName(_ item: ExtensionSettingsItem) -> String {
        item.id == LocalTestExtension.identifier
            ? NSLocalizedString("Test Extension", comment: "")
            : item.name
    }

    private func localizedSummary(_ item: ExtensionSettingsItem) -> String {
        item.id == LocalTestExtension.identifier
            ? NSLocalizedString("Test Extension Summary", comment: "")
            : item.summary
    }

    private func localizedFeatures(_ item: ExtensionSettingsItem) -> String? {
        if item.id == LocalTestExtension.identifier {
            return NSLocalizedString("Test Extension Features", comment: "")
        }
        return item.featuresSummary
    }

    private func localizedCapabilities(_ item: ExtensionSettingsItem) -> String? {
        if item.id == LocalTestExtension.identifier {
            return NSLocalizedString("Test Extension Capabilities", comment: "")
        }
        return item.capabilitiesSummary
    }

    private func formattedSize(_ size: Int64?) -> String? {
        guard let size else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
