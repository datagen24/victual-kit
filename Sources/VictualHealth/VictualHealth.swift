/// Medication dose sync for Victual.
///
/// Almost everything here reads no HealthKit. It holds what can be decided
/// without it — the dose model, the status translation, the outbox, anchor and
/// ledger, and the ADR-0041 wire types — so the behaviour is tested on a Mac
/// against scripted sources. `HealthKitDoseSource` and `HealthKitSpike` are the
/// only files that import the framework; they are compiled only where HealthKit
/// exists and are `@available(iOS 26, …)`, because medication types do not exist
/// earlier. Nothing else in the target needs iOS 26, and no deployment target moves.
public enum VictualHealth {
    /// The `source_system` this client sends. ADR-0041 rule 1.
    public static let sourceSystem = "healthkit"
}
