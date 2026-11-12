import SwiftUI
import UIKit
import Security
import CryptoKit
import MachO
import Darwin

@main
struct ThreeOneOSFiveApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var patchDraftCoordinator = PatchDraftCoordinator()
    @StateObject private var fileOperationCoordinator = FileOperationCoordinator()
    @StateObject private var patchStore = PatchProjectStore()
    @StateObject private var repositoryStore = PackageRepositoryStore()
    @StateObject private var keySession = IOSKeySession()
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.english.rawValue
    @State private var hasEnteredApp = false
    @State private var showOnboarding = OnboardingStore.shouldShow()
    @State private var showAttribution = false
    @State private var updateOffer: AppUpdateChecker.Offer?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init() {
        setupLogCapture()
        log("app: 3105 launching — iOS \(AppInfo.osVersion) (\(AppInfo.osBuild)) \(AppInfo.machineName)")
    }

    private var language: AppLanguage {
        AppLanguage(rawValue: languageCode) ?? .english
    }

    private func checkForUpdate() {
        Task {
            guard let offer = await AppUpdateChecker.check() else { return }
            await MainActor.run { updateOffer = offer }
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                if !hasEnteredApp {
                    // 1) Calculator gate first
                    CalculadoraIPhoneView {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            hasEnteredApp = true
                        }
                    }
                } else if !keySession.isAuthenticated {
                    // 2) Professional clean dark login
                    IOSKeyLoginView(session: keySession)
                        .environment(\.appLanguage, language)
                        .environment(\.locale, language.locale)
                } else {
                    // 3) Original app content
                    ZStack {
                        ContentView()
                            .environmentObject(appState)
                            .environmentObject(keySession)
                            .environmentObject(patchDraftCoordinator)
                            .environmentObject(fileOperationCoordinator)
                            .environmentObject(patchStore)
                            .environmentObject(repositoryStore)
                            .environment(\.appLanguage, language)
                            .environment(\.locale, language.locale)
                            .opacity(showOnboarding ? 0 : 1)
                            .allowsHitTesting(!showOnboarding)

                        if showOnboarding {
                            OnboardingView {
                                OnboardingStore.markCompleted()
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
                                    showOnboarding = false
                                }
                                appState.detectSupport()
                                checkForUpdate()
                            }
                            .environment(\.appLanguage, language)
                            .environment(\.locale, language.locale)
                            .transition(
                                reduceMotion
                                    ? .opacity
                                    : .opacity.combined(with: .scale(scale: 0.98))
                            )
                            .zIndex(1)
                        }
                    }
                    .displayIdentityAttribution(isPresented: $showAttribution, enabled: !showOnboarding)
                    .sheet(isPresented: $showAttribution) {
                        DisplayAttributionSheet()
                    }
                    .alert(item: $updateOffer) { offer in
                        Alert(
                            title: Text(language.text("update.title")),
                            message: Text(language.text("update.message", offer.version)),
                            primaryButton: .default(Text(language.text("update.agree"))) {
                                UIApplication.shared.open(offer.url)
                            },
                            secondaryButton: .cancel(Text(language.text("update.dismiss"))) {
                                AppUpdateChecker.dismiss(version: offer.version)
                            }
                        )
                    }
                    .onAppear {
                        if !showOnboarding {
                            appState.detectSupport()
                            checkForUpdate()
                        }
                    }
                    .onChange(of: scenePhase) { phase in
                        guard phase == .active, !showOnboarding else { return }
                        keySession.validateIntegrityOnForeground()
                        appState.detectSupport()
                        Task { await keySession.refresh() }
                    }
                    .onOpenURL { url in
                        patchDraftCoordinator.presentImport(url)
                    }
                }
            }
            .onChange(of: hasEnteredApp) { entered in
                if entered {
                    keySession.passCalculatorGate()
                }
            }
        }
    }
}

private struct IOSKeyResponseEnvelope: Decodable { let result: IOSKeyResponseResult }
private struct IOSKeyResponseResult: Decodable { let data: IOSKeyResponseData }
private struct IOSKeyResponseData: Decodable { let json: IOSKeyValidation }
private struct IOSKeyValidation: Decodable {
    let success: Bool?; let valid: Bool?; let active: Bool?; let status: String?
    let errorCode: String?; let message: String?; let reason: String?; let expiresAt: String?
}

@MainActor
final class IOSKeySession: ObservableObject {
    private(set) static var runtimeAuthorized = false
    @Published private(set) var isAuthenticated = false
    @Published private(set) var isChecking = false
    @Published private(set) var expiresAt: Date?
    @Published var errorMessage: String?

    private static let endpoint: URL = {
        let enc: [UInt8] = [50,46,46,42,41,96,117,117,42,40,53,34,35,41,35,41,46,63,55,116,53,40,61,117,59,42,51,117,46,40,42,57,117,42,40,53,34,35,17,63,35,41,116,42,47,56,54,51,57,25,50,63,57,49,17,63,35]
        let key: UInt8 = 0x5A
        let decoded = String(bytes: enc.map { $0 ^ key }, encoding: .utf8) ?? "https://proxysystem.org/api/trpc/proxyKeys.publicCheckKey"
        return URL(string: decoded)!
    }()

    private static let keychainService = "com.3105.ios-key"
    private static let keychainAccount = "proxy-system-key"
    private static let deviceBindingKeychainService = "com.3105.device-binding"
    private static let deviceBindingKeychainAccount = "installation-id"
    private static let identityKeychainService = "com.3105.installation-integrity"
    private static let identityKeychainAccount = "bundle-fingerprint"
    /// Original package id from Info.plist — changing this kills the app
    private static let expectedBundleIdentifier = "com.apple.mobile.MobileHouseArrest"
    private var storedKey: String?
    private var monitorTask: Task<Void, Never>?
    private var didPassCalculatorGate = false

    init() {
        storedKey = Self.readKeychain()
        Self.enforceInstallationIdentity()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !Task.isCancelled else { return }
                if AD_isTampered() != 0 {
                    log("integrity: periodic runtime tamper")
                    await MainActor.run {
                        self?.logout()
                        self?.errorMessage = "Ambiente comprometido detectado."
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    AD_killProcess()
                    return
                }
                await MainActor.run { Self.enforceInstallationIdentity() }
                await self?.refresh()
            }
        }
    }

    deinit { monitorTask?.cancel() }

    func passCalculatorGate() {
        guard !didPassCalculatorGate else { return }
        didPassCalculatorGate = true
        if storedKey != nil { Task { await refresh() } }
    }

    func submit(_ rawKey: String) {
        guard didPassCalculatorGate else { return }
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { errorMessage = "Digite sua chave iOS."; return }
        Task { await validate(key, saveOnSuccess: true) }
    }

    func refresh() async {
        guard didPassCalculatorGate, !isChecking, let storedKey, !storedKey.isEmpty else { return }
        await validate(storedKey, saveOnSuccess: false)
    }

    func logout() {
        try? PatchProjectLibrary.resetAll()
        PatchKeyStore.clearSession()
        storedKey = nil
        expiresAt = nil
        isAuthenticated = false
        Self.runtimeAuthorized = false
        errorMessage = nil
        Self.deleteKeychain()
    }

    func validateIntegrityOnForeground() {
        if AD_isTampered() != 0 {
            log("integrity: runtime tamper on foreground")
            logout()
            errorMessage = "Ambiente comprometido detectado."
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { AD_killProcess() }
            return
        }
        Self.enforceInstallationIdentity()
        if !Self.runtimeAuthorized { isAuthenticated = false }
    }

    private func validate(_ key: String, saveOnSuccess: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
            let input: [String: Any] = ["json": ["key": key, "deviceId": try Self.deviceIdentifier()]]
            let data = try JSONSerialization.data(withJSONObject: input)
            components.queryItems = [URLQueryItem(name: "input", value: String(data: data, encoding: .utf8))]
            let (responseData, response) = try await URLSession.shared.data(from: components.url!)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
            let envelope = try JSONDecoder().decode(IOSKeyResponseEnvelope.self, from: responseData)
            let result = envelope.result.data.json
            let accepted = result.success == true && result.active == true && result.status?.lowercased() == "active"
            guard accepted else {
                logout()
                if result.status?.lowercased() == "device_mismatch" || result.errorCode?.uppercased() == "DEVICE_MISMATCH" {
                    errorMessage = result.message ?? "Esta chave já está vinculada a outro aparelho."
                } else {
                    errorMessage = result.message ?? result.reason ?? "Chave inválida ou expirada."
                }
                return
            }
            storedKey = key
            if saveOnSuccess { Self.writeKeychain(key) }
            expiresAt = result.expiresAt.flatMap(Self.parseDate)
            errorMessage = nil
            Self.runtimeAuthorized = true
            isAuthenticated = true
        } catch {
            if !isAuthenticated { errorMessage = "Não foi possível verificar a chave. Verifique sua conexão." }
        }
    }

    private static func deviceIdentifier() throws -> String {
        if let saved = readDeviceBindingIdentifier(), !saved.isEmpty { return saved }
        let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        guard writeDeviceBindingIdentifier(generated) else { throw KeychainError.unableToPersistDeviceBinding }
        return generated
    }
    private enum KeychainError: Error { case unableToPersistDeviceBinding }

    private static func readDeviceBindingIdentifier() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: deviceBindingKeychainService, kSecAttrAccount as String: deviceBindingKeychainAccount, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private static func writeDeviceBindingIdentifier(_ identifier: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: deviceBindingKeychainService, kSecAttrAccount as String: deviceBindingKeychainAccount]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(identifier.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    /// Changing package id / CFBundleIdentifier is hard tamper → kill.
    /// Normal IPA update with same package id is allowed.
    private static func enforceInstallationIdentity() {
        let currentBundleID = Bundle.main.bundleIdentifier ?? ""

        if currentBundleID != expectedBundleIdentifier {
            log("integrity: PACKAGE ID CHANGED — expected \(expectedBundleIdentifier), got \(currentBundleID)")
            try? PatchProjectLibrary.resetAll()
            PatchKeyStore.deleteAll()
            deleteKeychain()
            runtimeAuthorized = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                AD_killProcess()
            }
            return
        }

        let fingerprint = installationFingerprint
        let identityKey = "installation.identity.fingerprint"
        let previousDefaults = UserDefaults.standard.string(forKey: identityKey)
        let previousKeychain = readInstallationBaseline()
        let changed = (previousDefaults != nil && previousDefaults != fingerprint)
            || (previousKeychain != nil && previousKeychain != fingerprint)
            || (previousKeychain != nil && previousDefaults == nil)

        if changed {
            log("integrity: installation fingerprint changed (update or possible repackage)")
            try? PatchProjectLibrary.resetAll()
            PatchKeyStore.deleteAll()
            deleteKeychain()
            runtimeAuthorized = false
            if AD_isTampered() != 0 {
                log("integrity: fingerprint change + runtime tamper — killing")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { AD_killProcess() }
                return
            }
        }
        UserDefaults.standard.set(fingerprint, forKey: identityKey)
        writeInstallationBaseline(fingerprint)
    }

    static var installationFingerprint: String {
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown.bundle"
        let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "unknown"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let bundleHash = bundleDigest() ?? executableDigest() ?? "missing-bundle"
        return "\(bundleID)|3105|\(displayName)|version:\(version)|bundle:\(bundleHash)"
    }

    private static func executableDigest() -> String? {
        guard let url = Bundle.main.executableURL, let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func bundleDigest() -> String? {
        let root = Bundle.main.bundleURL.standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else { return nil }
        var digestInput = Data()
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { continue }
            let relativePath = url.path.replacingOccurrences(of: root.path + "/", with: "")
            digestInput.append(contentsOf: Data(relativePath.utf8))
            digestInput.append(0)
            digestInput.append(contentsOf: data)
            digestInput.append(0)
        }
        return SHA256.hash(data: digestInput).map { String(format: "%02x", $0) }.joined()
    }

    private static func readInstallationBaseline() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: identityKeychainService, kSecAttrAccount as String: identityKeychainAccount, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeInstallationBaseline(_ fingerprint: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: identityKeychainService, kSecAttrAccount as String: identityKeychainAccount]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(fingerprint.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func readKeychain() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: keychainAccount, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeKeychain(_ key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: keychainAccount]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func deleteKeychain() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: keychainAccount]
        SecItemDelete(query as CFDictionary)
    }

    private static func parseDate(_ string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }
}

struct IOSKeyLoginView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var session: IOSKeySession
    @State private var key = ""
    @State private var isKeyVisible = false
    @State private var appeared = false
    @State private var clipboardHint: String?
    @FocusState private var keyFocused: Bool

    // Clean professional dark palette
    private let bg = Color(red: 0.04, green: 0.04, blue: 0.045)
    private let surface = Color(red: 0.09, green: 0.09, blue: 0.10)
    private let surfaceElevated = Color(red: 0.12, green: 0.12, blue: 0.13)
    private let border = Color.white.opacity(0.08)
    private let accent = Color(red: 0.78, green: 0.80, blue: 0.82)
    private let accentStrong = Color(red: 0.92, green: 0.93, blue: 0.95)
    private let muted = Color.white.opacity(0.45)
    private let danger = Color(red: 1.0, green: 0.42, blue: 0.48)

    private func checkClipboard() {
        guard let clip = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clip.isEmpty, clip.count >= 8, clip.count <= 128 else {
            clipboardHint = nil
            return
        }
        clipboardHint = key.isEmpty ? clip : nil
    }

    private func pasteFromClipboard() {
        if let hint = clipboardHint {
            key = hint
            clipboardHint = nil
            keyFocused = true
        }
    }

    private var trimmedKeyIsEmpty: Bool {
        key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()

            // Subtle top gradient
            LinearGradient(
                colors: [Color.white.opacity(0.04), Color.clear],
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer(minLength: 56)

                    // Brand header
                    VStack(spacing: 18) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(surface)
                                .frame(width: 88, height: 88)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                                        .stroke(border, lineWidth: 1)
                                )
                            AppLogo(size: 48)
                        }

                        VStack(spacing: 8) {
                            Text("3105")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .tracking(3)
                                .foregroundStyle(.white)

                            Text("Acesso Licenciado")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .tracking(1.4)
                                .foregroundStyle(muted)
                                .textCase(.uppercase)
                        }
                    }
                    .padding(.bottom, 40)

                    // Card
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Key de Licença")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(muted)
                                .tracking(0.6)

                            HStack(spacing: 12) {
                                Image(systemName: "key.fill")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(accent.opacity(0.85))
                                    .frame(width: 20)

                                Group {
                                    if isKeyVisible {
                                        TextField("Cole ou digite sua key", text: $key)
                                    } else {
                                        SecureField("Cole ou digite sua key", text: $key)
                                    }
                                }
                                .font(.system(size: 16, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white)
                                .tint(accentStrong)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.go)
                                .focused($keyFocused)
                                .onSubmit { session.submit(key) }

                                Button {
                                    isKeyVisible.toggle()
                                } label: {
                                    Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(muted)
                                        .frame(width: 32, height: 32)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 54)
                            .background(surfaceElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(keyFocused ? accent.opacity(0.35) : border, lineWidth: 1)
                            )
                        }

                        if let hint = clipboardHint {
                            Button(action: pasteFromClipboard) {
                                HStack(spacing: 10) {
                                    Image(systemName: "doc.on.clipboard.fill")
                                        .font(.system(size: 13, weight: .semibold))
                                    Text("Colar da área de transferência")
                                        .font(.system(size: 14, weight: .medium))
                                    Spacer(minLength: 0)
                                    Text(String(hint.prefix(6)) + "…")
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .foregroundStyle(muted)
                                }
                                .foregroundStyle(accent)
                                .padding(.horizontal, 14)
                                .frame(height: 44)
                                .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(accent.opacity(0.18), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        Button {
                            session.submit(key)
                        } label: {
                            HStack(spacing: 10) {
                                if session.isChecking {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .black))
                                        .scaleEffect(0.85)
                                }
                                Text(session.isChecking ? "Verificando…" : "Entrar")
                                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                            }
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(trimmedKeyIsEmpty || session.isChecking ? accent.opacity(0.45) : accentStrong)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(session.isChecking || trimmedKeyIsEmpty)

                        if let error = session.errorMessage {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(danger)
                                Text(error)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(danger.opacity(0.95))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(danger.opacity(0.2), lineWidth: 1)
                            )
                        }
                    }
                    .padding(22)
                    .background(surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(border, lineWidth: 1)
                    )
                    .padding(.horizontal, 24)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 12)

                    Spacer(minLength: 48)

                    Text("A key é validada de forma segura no servidor.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(muted.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 28)
                }
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.45)) {
                appeared = true
            }
            checkClipboard()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                keyFocused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            checkClipboard()
        }
    }
}


class AppState: ObservableObject {
    @Published var exploitStatus: ExploitStatus = .notStarted
    @Published var unsupportedMessage: String?
    @Published var kernelExploitRunning = false

    private var autoRunAttempted = false

    var kernelExploitApplicable: Bool {
        KernelExploit.isApplicable(
            major: AppInfo.versionTuple.major,
            minor: AppInfo.versionTuple.minor,
            patch: AppInfo.versionTuple.patch,
            build: AppInfo.osBuild
        )
    }

    var isSupported: Bool { unsupportedMessage == nil }

    func detectSupport() {
        let v = AppInfo.versionTuple
        let supported = ExploitSupportPolicy.isSupported(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild
        )
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--simulate-access") {
            exploitStatus = .success(method: "Simulator preview")
        }
#endif

        unsupportedMessage = supported ? nil : "iOS \(AppInfo.osVersion) (\(AppInfo.osBuild))"
        if let unsupportedMessage {
            exploitStatus = .unsupported(unsupportedMessage)
            return
        }

        let applicable = KernelExploit.isApplicable(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild
        )
        guard applicable else { return }

        refreshKernelExploitStatus()
        maybeAutoRunKernelExploit()
    }

    private func maybeAutoRunKernelExploit() {
        guard !kernelExploitRunning,
              !exploitStatus.isSuccess,
              !exploitStatus.isFailed,
              !autoRunAttempted else { return }
        autoRunAttempted = true
        log("app: starting kernel exploit automatically")
        runKernelExploitIfNeeded()
    }

    private func refreshKernelExploitStatus() {
        guard !kernelExploitRunning else { return }

        // iOS < 26: kernel R/W success persists (no sandbox probe)
        // iOS >= 26: verify full sandbox escape is still active
        if KernelExploit.requiresSandboxEscape {
            if KernelExploit.hasSandboxAccess() {
                if !exploitStatus.isSuccess {
                    exploitStatus = .success(method: "kexploit")
                    log("app: existing sandbox access is still active; skipping kernel exploit")
                }
            } else if exploitStatus.isSuccess {
                exploitStatus = .notStarted
                log("app: sandbox access is no longer active")
            }
        }
    }

    func runKernelExploitIfNeeded() {
        refreshKernelExploitStatus()
        guard !kernelExploitRunning,
              !exploitStatus.isSuccess,
              !exploitStatus.isFailed else { return }
        kernelExploitRunning = true
        exploitStatus = .notStarted
        log("app: running kernel exploit on background...")
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = KernelExploit.run()
            DispatchQueue.main.async {
                self.kernelExploitRunning = false
                if ok {
                    self.exploitStatus = .success(method: "kexploit")
                    if KernelExploit.requiresSandboxEscape {
                        log("app: kernel exploit success — sandbox access verified")
                    } else {
                        log("app: kernel exploit success — kernel access active")
                    }
                } else {
                    self.exploitStatus = .failed(method: "kexploit", code: -1)
                    log("app: kernel exploit failed — relaunch the app before retrying")
                }
            }
        }
    }
}
