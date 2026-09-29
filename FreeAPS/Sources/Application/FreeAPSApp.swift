import ActivityKit
import CoreData
import Foundation
import SwiftUI
import Swinject
import UIKit

@main struct FreeAPSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // Dependencies Assembler
    // contain all dependencies Assemblies
    // TODO: Remove static key after update "Use Dependencies" logic
    fileprivate static let assembler = Assembler([
        StorageAssembly(),
        ServiceAssembly(),
        APSAssembly(),
        NetworkAssembly(),
        UIAssembly(),
        SecurityAssembly()
    ], parent: nil, defaultObjectScope: .container)

    // Temp static var
    // Use to backward compatibility with old Dependencies logic on Logger
    // TODO: Remove var after update "Use Dependencies" logic in Logger
    static let resolver: Resolver = FreeAPSApp.assembler.resolver

    init() {
        debug(
            .default,
            "iAPS Started: v\(Bundle.main.releaseVersionNumber ?? "")(\(Bundle.main.buildVersionNumber ?? "")) [buildDate: \(Bundle.main.buildDate)] [buildExpires: \(Bundle.main.profileExpiration ?? "")]"
        )
        AppearanceManager.setupGlobalAppearance()
    }

    var body: some Scene {
        WindowGroup {
            LaunchGateView()
        }
    }

    fileprivate static func runVersionCheckOnce() {
        guard !didRunVersionCheck else { return }
        didRunVersionCheck = true
        isNewVersion()
    }

    private static var didRunVersionCheck = false

    private static func isNewVersion() {
        let userDefaults = UserDefaults.standard
        var version = userDefaults.string(forKey: IAPSconfig.version) ?? ""
        userDefaults.set(false, forKey: IAPSconfig.inBolusView)

        guard version.count > 1, version == (Bundle.main.releaseVersionNumber ?? "") else {
            version = Bundle.main.releaseVersionNumber ?? ""
            userDefaults.set(version, forKey: IAPSconfig.version)
            userDefaults.set(true, forKey: IAPSconfig.newVersion)
            debug(.default, "Running new version: \(version)")
            return
        }
    }
}

final class AppLauncher: ObservableObject {
    static let shared = AppLauncher()

    @Published private(set) var services: AppServices?

    private var isBuilding = false

    private init() {}

    func startIfNeeded() {
        guard services == nil else { return }
        guard !isBuilding else {
            warning(.default, "AppServices construction re-entered - ignoring the nested request")
            return
        }
        guard ProtectedDataGate.isAvailable() else {
            debug(.default, "Launch deferred: protected data is not available (no unlock since boot)")
            return
        }

        isBuilding = true
        defer { isBuilding = false }

        FreeAPSApp.runVersionCheckOnce()
        services = AppServices(assembler: FreeAPSApp.assembler)
    }
}

/// Holds the launch until the app can actually read its own files.
private struct LaunchGateView: View {
    @StateObject private var launcher = AppLauncher.shared

    var body: some View {
        Group {
            // if everything is ready - render the app
            if let appServices = launcher.services {
                LaunchedAppView(appServices: appServices)
            } else {
                WaitingForUnlockView()
            }
        }
        .onAppear {
            launcher.startIfNeeded()
        }
        .onReceive(
            Foundation.NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
        ) { _ in
            launcher.startIfNeeded()
        }
    }
}

/// The real app - reached only once `ProtectedDataGate` confirms our files are readable.
private struct LaunchedAppView: View {
    let appServices: AppServices

    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var dataController = CoreDataStack.shared

    init(appServices: AppServices) {
        self.appServices = appServices
    }

    var body: some View {
        Main.RootView(resolver: FreeAPSApp.resolver)
            .environment(\.managedObjectContext, dataController.persistentContainer.viewContext)
            .environmentObject(Icons())
            .onOpenURL(perform: handleURL)
            .environmentObject(appServices)
            .onChange(of: scenePhase) {
                debug(.default, "APPLICATION PHASE: \(scenePhase)")
                if scenePhase == .active {
                    appServices.deviceManager.didBecomeActive()
                }
            }
    }

    private func handleURL(_ url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        switch components?.host {
        case "device-select-resp":
            FreeAPSApp.resolver.resolve(NotificationCenter.self)!.post(name: .openFromGarminConnect, object: url)
        case "carbs":
            handleCarbCamURL(components: components)
        default: break
        }
    }

    /// Handles `carbcam-iaps://carbs?value=N&fat=X&protein=Y&fiber=Z&notes=...&source=...`
    /// URLs from 10BE CarbCam. Stores the prefill in ExternalCarbsPrefill and posts
    /// openAddCarbsFromCarbCam. HomeStateModel listens and opens AddCarbs which
    /// consumes the prefill. User always confirms via Save.
    private func handleCarbCamURL(components: URLComponents?) {
        guard let items = components?.queryItems else { return }
        guard let valueStr = items.first(where: { $0.name == "value" })?.value,
              let value = Int(valueStr), value >= 1, value <= 80
        else { return }

        let notes = (items.first(where: { $0.name == "notes" })?.value ?? "")
            .prefix(200).description
        let source = (items.first(where: { $0.name == "source" })?.value ?? "")
            .prefix(50).description

        func parseOptional(_ name: String) -> Decimal {
            guard let s = items.first(where: { $0.name == name })?.value,
                  let v = Int(s), v >= 0, v <= 80 else { return 0 }
            return Decimal(v)
        }

        ExternalCarbsPrefill.carbs = Decimal(value)
        ExternalCarbsPrefill.fat = parseOptional("fat")
        ExternalCarbsPrefill.protein = parseOptional("protein")
        ExternalCarbsPrefill.fiber = parseOptional("fiber")
        ExternalCarbsPrefill.notes = notes
        ExternalCarbsPrefill.source = source

        Foundation.NotificationCenter.default
            .post(name: Notification.Name.openAddCarbsFromCarbCam, object: nil)
    }
}

private struct WaitingForUnlockView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "hourglass")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Starting iAPS")
                .font(.headline)
            Text(
                "iAPS is waiting for access to its data. Normally this finishes on its own once you have unlocked your phone for the first time after a restart."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
        }
    }
}

enum ProtectedDataGate {
    private static let probeName = "protection.test"

    private static var didBecomeAvailable = false

    static func isAvailable() -> Bool {
        if didBecomeAvailable {
            return true
        }
        didBecomeAvailable = probe()
        return didBecomeAvailable
    }

    private static func probe() -> Bool {
        let fileManager = FileManager.default
        guard let documents = try? fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else {
            return false
        }

        let probeURL = documents.appendingPathComponent(probeName)

        if !fileManager.fileExists(atPath: probeURL.path) {
            try? Data("iAPS".utf8).write(to: probeURL, options: .completeFileProtectionUntilFirstUserAuthentication)
        }

        return (try? Data(contentsOf: probeURL)) != nil
    }
}

// MARK: - CarbCam URL prefill support (fat/protein/fiber included)

enum ExternalCarbsPrefill {
    static var carbs: Decimal?
    static var fat: Decimal?
    static var protein: Decimal?
    static var fiber: Decimal?
    static var notes: String?
    static var source: String?

    static func consume() -> (carbs: Decimal, fat: Decimal, protein: Decimal, fiber: Decimal, notes: String, source: String)? {
        guard let c = carbs else { return nil }
        let result = (c, fat ?? 0, protein ?? 0, fiber ?? 0, notes ?? "", source ?? "")
        carbs = nil; fat = nil; protein = nil; fiber = nil; notes = nil; source = nil
        return result
    }
}

extension Notification.Name {
    static let openAddCarbsFromCarbCam = Notification.Name("openAddCarbsFromCarbCam")
}
