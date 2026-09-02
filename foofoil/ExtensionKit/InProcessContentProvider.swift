import Foundation

/// 把稳定 C ABI 的 JSON 值消息适配为宿主内部 Provider；插件对象不会跨越 ABI 边界。
final class InProcessContentProvider: ContentProvider {
    let descriptor: ProviderDescriptor

    private let declaration: ExtensionProviderDeclaration
    private let runtime: InProcessExtensionInterface

    init(
        extensionID: String,
        declaration: ExtensionProviderDeclaration,
        runtime: InProcessExtensionInterface
    ) {
        self.declaration = declaration
        self.runtime = runtime
        descriptor = ProviderDescriptor(
            id: declaration.id,
            extensionID: extensionID,
            role: declaration.role,
            fallbackProviderID: declaration.fallbackProvider,
            enhancementDomain: declaration.enhancementDomain,
            isEnabled: true,
            isRuntimeAvailable: true
        )
    }

    func match(_ request: ContentRequest) -> ProviderMatch? {
        ProviderContentMatcher.match(request, declarations: declaration.contentTypes)
    }

    func makeSession(for request: ContentRequest, negotiatedAPI: UInt32) async throws -> ContentSession {
        let runtime = runtime
        return try await Task.detached(priority: .userInitiated) {
            try runtime.createSession(for: request)
        }.value
    }

    func perform(commandID: String, session: ContentSession) async throws -> ContentSession {
        let runtime = runtime
        return try await Task.detached(priority: .userInitiated) {
            try runtime.perform(commandID: commandID, session: session)
        }.value
    }
}
