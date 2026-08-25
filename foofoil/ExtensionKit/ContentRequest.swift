//  ContentRequest.swift
//  foofoil
//
//  Created by tolg on 2026/8/25.

import Foundation

struct ExtensionResource: Codable, Equatable, Sendable {
    let url: URL
    let securityScopedBookmark: Data?

    init(url: URL, securityScopedBookmark: Data? = nil) {
        self.url = url
        self.securityScopedBookmark = securityScopedBookmark
    }

    static func sandboxed(url: URL) -> ExtensionResource {
        let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return ExtensionResource(url: url, securityScopedBookmark: bookmark)
    }
}

enum ContentRequest: Codable, Equatable, Sendable {
    case singleFile(ExtensionResource)
    case fileCollection([ExtensionResource])
    case restoredSession(extensionID: String, stateReference: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case resource
        case resources
        case extensionID
        case stateReference
    }

    private enum Kind: String, Codable {
        case singleFile
        case fileCollection
        case restoredSession
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .singleFile:
            self = .singleFile(try container.decode(ExtensionResource.self, forKey: .resource))
        case .fileCollection:
            self = .fileCollection(try container.decode([ExtensionResource].self, forKey: .resources))
        case .restoredSession:
            self = .restoredSession(
                extensionID: try container.decode(String.self, forKey: .extensionID),
                stateReference: try container.decode(String.self, forKey: .stateReference)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .singleFile(let resource):
            try container.encode(Kind.singleFile, forKey: .kind)
            try container.encode(resource, forKey: .resource)
        case .fileCollection(let resources):
            try container.encode(Kind.fileCollection, forKey: .kind)
            try container.encode(resources, forKey: .resources)
        case .restoredSession(let extensionID, let stateReference):
            try container.encode(Kind.restoredSession, forKey: .kind)
            try container.encode(extensionID, forKey: .extensionID)
            try container.encode(stateReference, forKey: .stateReference)
        }
    }

    var resources: [ExtensionResource] {
        switch self {
        case .singleFile(let resource): [resource]
        case .fileCollection(let resources): resources
        case .restoredSession: []
        }
    }

    var primaryFileURL: URL? {
        resources.first?.url
    }
}

/// 在一次扩展调用期间成组持有安全范围授权，避免多文件会话漏停或过早释放。
final class ExtensionResourceAccessScope {
    private var accessedURLs: [URL] = []

    init(request: ContentRequest) {
        for resource in request.resources {
            let resolvedURL: URL
            if let bookmark = resource.securityScopedBookmark {
                var stale = false
                resolvedURL = (try? URL(
                    resolvingBookmarkData: bookmark,
                    options: .withSecurityScope,
                    bookmarkDataIsStale: &stale
                )) ?? resource.url
            } else {
                resolvedURL = resource.url
            }
            if resolvedURL.startAccessingSecurityScopedResource() {
                accessedURLs.append(resolvedURL)
            }
        }
    }

    deinit {
        stop()
    }

    func stop() {
        for url in accessedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        accessedURLs.removeAll()
    }
}
