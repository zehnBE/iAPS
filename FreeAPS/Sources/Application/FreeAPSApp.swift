import ActivityKit
import CoreData
import Foundation
import SwiftUI
import Swinject

@main struct FreeAPSApp: App {
    @Environment(\.scenePhase) var scenePhase

    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject var dataController = CoreDataStack.shared

    // Dependencies Assembler
    // contain all dependencies Assemblies
    // TODO: Remove static key after update "Use Dependencies" logic
    private static let assembler = Assembler([
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

    // TODO: do we want this? will this work with the Router?
    // can be shared with the rest of the views with @EnvironmentObject
    @StateObject private var appServices = AppServices(assembler: assembler)

    init() {
        debug(
            .default,
            "iAPS Started: v\(Bundle.main.releaseVersionNumber ?? "")(\(Bundle.main.buildVersionNumber ?? "")) [buildDate: \(Bundle.main.buildDate)] [buildExpires: \(Bundle.main.profileExpiration ?? "")]"
        )
        isNewVersion()
        AppearanceManager.setupGlobalAppearance()
    }

    var body: some Scene {
        WindowGroup {
            Main.RootView(resolver: FreeAPSApp.resolver)
                .environment(\.managedObjectContext, dataController.persistentContainer.viewContext)
                .environmentObject(Icons())
                .onOpenURL(perform: handleURL)
                .environmentObject(appServices)
        }
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

    /// Handles `carbcam-iaps://carbs?value=N&notes=...&source=...` URLs
    /// from 10BE CarbCam. Stores the prefill in ExternalCarbsPrefill and
    /// posts the openAddCarbsFromCarbCam notification. HomeStateModel
    /// listens and opens the AddCarbs sheet which then consumes the prefill.
    /// User always confirms via Save - no silent CoreData writes.
    private func handleCarbCamURL(components: URLComponents?) {
        guard let items = components?.queryItems else { return }
        guard let valueStr = items.first(where: { $0.name == "value" })?.value,
              let value = Int(valueStr), value >= 1, value <= 80
        else { return }

        let notes = (items.first(where: { $0.name == "notes" })?.value ?? "")
            .prefix(200)
            .description

        let source = (items.first(where: { $0.name == "source" })?.value ?? "")
            .prefix(50)
            .description

        // Optional fat/protein/fiber - each clamped to 0..80 g, missing/invalid -> 0
        func parseOptional(_ name: String) -> Decimal {
            guard let s = items.first(where: { $0.name == name })?.value,
                  let v = Int(s), v >= 0, v <= 80 else { return 0 }
            return Decimal(v)
        }
        let fat = parseOptional("fat")
        let protein = parseOptional("protein")
        let fiber = parseOptional("fiber")

        ExternalCarbsPrefill.carbs = Decimal(value)
        ExternalCarbsPrefill.fat = fat
        ExternalCarbsPrefill.protein = protein
        ExternalCarbsPrefill.fiber = fiber
        ExternalCarbsPrefill.notes = notes
        ExternalCarbsPrefill.source = source

        Foundation.NotificationCenter.default
            .post(name: Notification.Name.openAddCarbsFromCarbCam, object: nil)
    }

    private func isNewVersion() {
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

// MARK: - CarbCam URL prefill support

/// Holds carbs/notes/source received from 10BE CarbCam via the
/// carbcam-iaps:// URL scheme until the AddCarbs sheet is opened and
/// consumes them.
///
/// Main-thread only. Set by FreeAPSApp.handleCarbCamURL, consumed by
/// AddCarbsStateModel.subscribe().
enum ExternalCarbsPrefill {
    static var carbs: Decimal?
    static var fat: Decimal?
    static var protein: Decimal?
    static var fiber: Decimal?
    static var notes: String?
    static var source: String?

    /// Returns the pending prefill (if any) and clears the holder.
    static func consume() -> (carbs: Decimal, fat: Decimal, protein: Decimal, fiber: Decimal, notes: String, source: String)? {
        guard let c = carbs else { return nil }
        let result = (c, fat ?? 0, protein ?? 0, fiber ?? 0, notes ?? "", source ?? "")
        carbs = nil
        fat = nil
        protein = nil
        fiber = nil
        notes = nil
        source = nil
        return result
    }
}

extension Notification.Name {
    /// Posted by FreeAPSApp.handleCarbCamURL once the prefill has been
    /// stored in ExternalCarbsPrefill. HomeStateModel listens and opens
    /// the AddCarbs sheet which then consumes the prefill.
    static let openAddCarbsFromCarbCam = Notification.Name("openAddCarbsFromCarbCam")
}
