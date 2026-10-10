/// Medication dose sync for Victual.
///
/// This target reads no HealthKit. It holds everything that can be decided
/// without it — the dose model, the status translation, the outbox, anchor and
/// ledger, and the ADR-0041 wire types — so that almost all of the behaviour
/// is tested on a Mac against scripted sources. A HealthKit adapter conforms
/// to ``DoseEventSource`` in a later phase and is the only code that imports
/// the framework.
///
/// Nothing here needs iOS 26: the API of this target is available on the
/// package's own platforms, and only the adapter will be `@available(iOS 26, *)`.
public enum VictualHealth {
    /// The `source_system` this client sends. ADR-0041 rule 1.
    public static let sourceSystem = "healthkit"
}
