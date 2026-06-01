import Foundation

/// Holds carbs/notes received from 10BE CarbCam via the carbcam-iaps://
/// URL scheme until the AddCarbs sheet is opened and consumes them.
///
/// Main-thread only. Set by FreeAPSApp.handleCarbCamURL, consumed by
/// AddCarbsStateModel.subscribe().
enum ExternalCarbsPrefill {
    static var carbs: Decimal?
    static var notes: String?
    static var source: String?

    /// Returns the pending prefill (if any) and clears the holder.
    static func consume() -> (carbs: Decimal, notes: String, source: String)? {
        guard let c = carbs else { return nil }
        let result = (c, notes ?? "", source ?? "")
        carbs = nil
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
