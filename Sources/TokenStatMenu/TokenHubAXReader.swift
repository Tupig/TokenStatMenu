import AppKit
import ApplicationServices
import Foundation
#if SWIFT_PACKAGE
import TokenStatCore
#endif

@MainActor
protocol TokenHubPermissionProviding {
    func isTrusted() -> Bool
    func requestOnceAndOpenSystemSettings()
}

/// Only immutable values cross the native AX actor boundary. AppKit process
/// references, AXUIElement objects and the mutable traversal map stay inside it.
struct TokenHubAXRequest: Sendable {
    let now: Date
    let permissionTrusted: Bool
    let refreshSeconds: TimeInterval
    let mode: TokenHubRunMode
    let generation: UInt64
}

actor NativeTokenHubAXWorker {
    private let reader = TokenHubAXReader()

    func scan(_ request: TokenHubAXRequest) -> TokenHubQuotaResult {
        // No suspension point while the native reader owns AX references.
        // Core still rejects an untrusted or inactive request before discovery.
        reader.scan(now: request.now, monotonicNow: { ProcessInfo.processInfo.systemUptime },
                    permissionTrusted: request.permissionTrusted,
                    refreshSeconds: request.refreshSeconds, mode: request.mode,
                    generation: request.generation)
    }
}

/// Immutable constructor injection keeps the native actor as the sole AX owner.
/// The marker survives closure wrapping so fixture launches cannot read real UI.
struct TokenHubAXSource {
    enum Kind { case native, synthetic }
    let kind: Kind
    let scan: @MainActor (TokenHubAXRequest) async -> TokenHubQuotaResult

    private init(kind: Kind, scan: @escaping @MainActor (TokenHubAXRequest) async -> TokenHubQuotaResult) {
        self.kind = kind
        self.scan = scan
    }

    @MainActor static var production: TokenHubAXSource {
        let worker = NativeTokenHubAXWorker()
        return TokenHubAXSource(kind: .native, scan: { await worker.scan($0) })
    }

    static func synthetic(_ scan: @escaping @MainActor (TokenHubAXRequest) async -> TokenHubQuotaResult) -> TokenHubAXSource {
        TokenHubAXSource(kind: .synthetic, scan: scan)
    }
}

/// Production boundary for one scan. AX objects live only in this instance's one scan call.
final class TokenHubAXReader: TokenHubQuotaScanning {
    private let tree = TokenHubNativeTreeReader()
    private let scanner = TokenHubQuotaScanner()

    func scan(now: Date, monotonicNow: () -> TimeInterval, permissionTrusted: Bool,
              refreshSeconds: TimeInterval, mode: TokenHubRunMode,
              generation: UInt64) -> TokenHubQuotaResult {
        tree.beginScan()
        defer { tree.endScan() }
        return scanner.scan(using: tree, now: now, monotonicNow: monotonicNow,
                            permissionTrusted: permissionTrusted, refreshSeconds: refreshSeconds,
                            mode: mode, generation: generation)
    }
}

@MainActor
final class TokenHubNativePermissionProvider: TokenHubPermissionProviding {
    private static var didRequestThisProcess = false
    func isTrusted() -> Bool { AXIsProcessTrusted() }

    func requestOnceAndOpenSystemSettings() {
        if !Self.didRequestThisProcess {
            Self.didRequestThisProcess = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

private final class TokenHubNativeTreeReader: TokenHubBoundedTreeReading {
    private var nodes: [TokenHubNodeID: AXUIElement] = [:]
    private var roles: [TokenHubNodeID: TokenHubAXRole] = [:]
    private var nextID = 1
    private var candidates: [pid_t: NSRunningApplication] = [:]

    func beginScan() { nodes.removeAll(keepingCapacity: false); roles.removeAll(keepingCapacity: false); nextID = 1; candidates.removeAll(keepingCapacity: false) }
    func endScan() { nodes.removeAll(keepingCapacity: false); roles.removeAll(keepingCapacity: false); candidates.removeAll(keepingCapacity: false) }

    func exactBundleTargets(bundleID: String) throws -> [TokenHubIdentity] {
        guard bundleID == TokenHubTarget.bundleID else { return [] }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: TokenHubTarget.bundleID)
            .filter { !$0.isTerminated }
        candidates = Dictionary(uniqueKeysWithValues: apps.map { ($0.processIdentifier, $0) })
        let identities = apps.compactMap { self.identity(for: $0) }
        guard identities.count == apps.count else { throw TokenHubNativeReadError.identity }
        return identities
    }

    func rootNode(for identity: TokenHubIdentity, timeout: TimeInterval) throws -> TokenHubNodeID {
        guard let app = candidates[identity.pid], let current = self.identity(for: app), current == identity else {
            throw TokenHubNativeReadError.identity
        }
        let element = AXUIElementCreateApplication(identity.pid)
        return register(element)
    }

    func identity(of node: TokenHubNodeID, timeout: TimeInterval) throws -> TokenHubIdentity {
        let element = try element(for: node)
        var pid: pid_t = 0
        try prepare(element, timeout: timeout)
        guard AXUIElementGetPid(element, &pid) == .success,
              let app = NSRunningApplication(processIdentifier: pid),
              let identity = identity(for: app) else { throw TokenHubNativeReadError.identity }
        return identity
    }

    func role(of node: TokenHubNodeID, timeout: TimeInterval) throws -> TokenHubAXRole {
        let element = try element(for: node)
        let raw = try copyAttribute(element, attribute: kAXRoleAttribute as CFString, timeout: timeout)
        guard let role = raw as? String else { throw TokenHubNativeReadError.attribute }
        let value: TokenHubAXRole
        switch role {
        case kAXApplicationRole: value = .application
        case kAXWindowRole: value = .window
        case kAXGroupRole: value = .group
        case kAXStaticTextRole: value = .staticText
        case kAXProgressIndicatorRole: value = .progressIndicator
        case kAXButtonRole, kAXRadioButtonRole, kAXCheckBoxRole,
             kAXPopUpButtonRole, kAXMenuButtonRole, "AXLink":
            value = .button
        case kAXTableRole, kAXOutlineRole, kAXListRole:
            value = .table
        case kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole:
            value = .editableText
        case "AXSecureTextField": value = .secureText
        default: value = .other(role)
        }
        roles[node] = value
        return value
    }

    func groupLabel(of node: TokenHubNodeID, kind: TokenHubGroupLabelKind,
                    timeout: TimeInterval) throws -> String? {
        guard roles[node] == .group else { throw TokenHubNativeReadError.attribute }
        let attribute = kind == .description ? kAXDescriptionAttribute as CFString : kAXTitleAttribute as CFString
        return try stringAttribute(node, attribute: attribute, maximumCharacters: 257, timeout: timeout)
    }

    func children(of node: TokenHubNodeID, maximum: Int, timeout: TimeInterval) throws -> TokenHubChildrenPage {
        guard maximum >= 0, maximum <= 64,
              roles[node] != .staticText, roles[node] != .progressIndicator else { throw TokenHubNativeReadError.attribute }
        let element = try element(for: node)
        var count: CFIndex = 0
        try prepare(element, timeout: timeout)
        guard AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success else {
            throw TokenHubNativeReadError.attribute
        }
        guard count <= maximum else { return TokenHubChildrenPage(nodes: [], isTruncated: true) }
        guard count > 0 else { return TokenHubChildrenPage(nodes: [], isTruncated: false) }
        var value: CFArray?
        try prepare(element, timeout: timeout)
        guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, count, &value) == .success,
              let values = value as? [AXUIElement], values.count == count else { throw TokenHubNativeReadError.attribute }
        return TokenHubChildrenPage(nodes: values.map(register), isTruncated: false)
    }

    func staticText(of node: TokenHubNodeID, maximumCharacters: Int, timeout: TimeInterval) throws -> String? {
        guard roles[node] == .staticText else { throw TokenHubNativeReadError.attribute }
        return try stringAttribute(node, attribute: kAXValueAttribute as CFString, maximumCharacters: maximumCharacters + 1, timeout: timeout)
    }

    func progressLabel(of node: TokenHubNodeID, timeout: TimeInterval) throws -> String? {
        guard roles[node] == .progressIndicator else { throw TokenHubNativeReadError.attribute }
        return try stringAttribute(node, attribute: kAXDescriptionAttribute as CFString, maximumCharacters: 257, timeout: timeout)
    }

    func progressValue(of node: TokenHubNodeID, timeout: TimeInterval) throws -> Decimal? {
        guard roles[node] == .progressIndicator else { throw TokenHubNativeReadError.attribute }
        let element = try element(for: node)
        guard let value = try copyOptionalAttribute(element, attribute: kAXValueAttribute as CFString, timeout: timeout) else { return nil }
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return nil }
        guard let number = value as? NSNumber else { return nil }
        return Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX"))
    }

    private func identity(for app: NSRunningApplication) -> TokenHubIdentity? {
        guard !app.isTerminated, let bundleID = app.bundleIdentifier, let executable = app.executableURL?.standardizedFileURL.path else { return nil }
        return TokenHubIdentity(pid: app.processIdentifier, bundleID: bundleID, executablePath: executable)
    }
    private func register(_ element: AXUIElement) -> TokenHubNodeID {
        let id = nextID; nextID += 1; nodes[id] = element; return id
    }
    private func element(for node: TokenHubNodeID) throws -> AXUIElement {
        guard let element = nodes[node] else { throw TokenHubNativeReadError.missingNode }
        return element
    }
    private func prepare(_ element: AXUIElement, timeout: TimeInterval) throws {
        // Set timeout on this exact element before each AX message; never on the application root
        // as a substitute for an element-specific limit.
        guard AXUIElementSetMessagingTimeout(element, Float(timeout)) == .success else {
            throw TokenHubNativeReadError.timeout
        }
    }
    private func copyAttribute(_ element: AXUIElement, attribute: CFString, timeout: TimeInterval) throws -> AnyObject {
        try prepare(element, timeout: timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else { throw TokenHubNativeReadError.attribute }
        return value as AnyObject
    }
    private func stringAttribute(_ node: TokenHubNodeID, attribute: CFString,
                                 maximumCharacters: Int, timeout: TimeInterval) throws -> String? {
        guard let value = try copyOptionalAttribute(element(for: node), attribute: attribute, timeout: timeout),
              let raw = value as? String else { return nil }
        return String(raw.prefix(maximumCharacters))
    }
    private func copyOptionalAttribute(_ element: AXUIElement, attribute: CFString,
                                       timeout: TimeInterval) throws -> AnyObject? {
        try prepare(element, timeout: timeout)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        if status == .noValue || status == .attributeUnsupported { return nil }
        guard status == .success, let value else { throw TokenHubNativeReadError.attribute }
        return value as AnyObject
    }
}

private enum TokenHubNativeReadError: Error { case timeout, attribute, identity, missingNode }
