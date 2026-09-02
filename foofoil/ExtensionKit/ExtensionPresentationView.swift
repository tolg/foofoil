//  ExtensionPresentationView.swift
//  foofoil
//
//  Created by tolg on 2026/8/25.

import FoofoilExtensionKit
import SwiftUI

struct ExtensionPresentationView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Group {
            if let session = appState.extensionSession {
                switch session.presentation {
                case .text(let titleKey, let body):
                    VStack(alignment: .leading, spacing: 12) {
                        Label(NSLocalizedString(titleKey, comment: ""), systemImage: "puzzlepiece.extension")
                            .font(.headline)
                        ScrollView {
                            Text(body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        if appState.extensionFallbackProviderID != nil {
                            Text(NSLocalizedString("Extension Provider Fallback Notice", comment: ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                case .unavailable(let titleKey, let messageKey):
                    ContentUnavailableView(
                        NSLocalizedString(titleKey, comment: ""),
                        systemImage: "puzzlepiece.extension",
                        description: Text(NSLocalizedString(messageKey, comment: ""))
                    )
                }
            }
        }
        .padding(16)
    }
}
