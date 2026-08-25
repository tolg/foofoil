# ExtensionKit Phase 0 部署验证

Phase 0 的跨进程样机是 `foofoilTestExtensionService.xpc`。它和 Host 只交换 JSON `Data`，并通过
`ContentRequest` 传递 security-scoped bookmark；不传递 SwiftUI、`NSView` 或进程内对象。

发布条件验证：

```sh
xcodebuild archive \
  -project foofoil.xcodeproj \
  -scheme foofoil \
  -configuration Release \
  -archivePath build/foofoil.xcarchive

scripts/validate-phase0-extension-deployment \
  build/foofoil.xcarchive/Products/Applications/foofoil.app \
  RFQ56XLHXJ
```

公证并 staple 后，追加 `--require-notarization` 再执行一次。脚本会严格检查全部 architecture、
nested code、Host 与 XPC 的 Hardened Runtime、App Sandbox、Team ID、Library Validation、Gatekeeper
和 notarization ticket。公证提交本身应继续由拥有公证凭据的 Release CI 执行，凭据不进入仓库。

手动样机：创建 UTF-8 文本文件 `Test.foo` 并用 foofoil 打开。窗口应显示 Test Extension Host
Presentation；菜单栏出现“扩展”，执行“添加测试标记”后正文追加标记。单元测试中的
`sandboxedXPCServiceNegotiatesAPIAndTransfersBookmarkMessage` 验证真实 XPC 握手和 bookmark 值消息往返。
