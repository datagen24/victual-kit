import Foundation

// Hand-written to match ADR-0041's `/consumption/mappings` schemas in the design
// fragment (`ConsumptionMappingInput`, `ConsumptionMapping`), like the event
// types in ConsumptionWire.swift, and replaced the same way when #700 lands.

/// A medication the person has authorized in Health, for the screens that name it.
///
/// ``displayName`` exists so the mapping and review screens can show the person
/// their own medication. It is held in memory only: never log it, persist it, or
/// send it to the server. The server gets ``ref`` and nothing else.
public struct HealthMedication: Sendable, Equatable, Identifiable {
    /// The opaque `medication_ref`.
    public var ref: String
    public var id: String { ref }
    public var displayName: String
    public var isArchived: Bool
    public var hasSchedule: Bool

    public init(ref: String, displayName: String, isArchived: Bool = false, hasSchedule: Bool = false) {
        self.ref = ref
        self.displayName = displayName
        self.isArchived = isArchived
        self.hasSchedule = hasSchedule
    }
}

/// Where the Medications screens learn which medications Health shares.
///
/// `HealthKitDoseSource` conforms; tests and previews conform with a script.
public protocol HealthMedicationSource: Sendable {
    /// The medications currently authorized, archived ones included.
    func medications() async throws -> [HealthMedication]
    /// Health's medication sheet. Always prompts, so only from an explicit tap.
    func requestMedicationAuthorization() async throws
}

/// The body of `PUT /consumption/mappings/{source_system}/{medication_ref}`.
///
/// Exactly one of ``productID`` and ``recipeID``. Optional fields are omitted when
/// `nil`: a mapping with no ``defaultQuantity`` leaves the key out, which the server
/// reads as none.
public struct ConsumptionMappingInput: Sendable, Equatable, Codable {
    public struct Location: Sendable, Equatable, Codable {
        public var mode: MappingLocation.Mode
        public var locationID: Int?

        public init(mode: MappingLocation.Mode, locationID: Int? = nil) {
            self.mode = mode
            self.locationID = locationID
        }

        enum CodingKeys: String, CodingKey {
            case mode
            case locationID = "location_id"
        }
    }

    public var productID: Int?
    public var recipeID: Int?
    /// A multiplier on the event quantity; `1` for a product target. Absent for a
    /// recipe, which takes its lines once per event.
    public var quantityFactor: Double?
    public var location: Location
    public var effectiveFrom: RFC3339Timestamp
    public var unitLabels: [String]
    public var defaultQuantity: Double?
    /// The quantity unit an event's quantity is expressed in (`qu_id`). `nil` is
    /// the product's stock unit. A product target only.
    public var unitID: Int?

    public init(
        productID: Int? = nil, recipeID: Int? = nil, quantityFactor: Double? = nil, location: Location,
        effectiveFrom: RFC3339Timestamp, unitLabels: [String] = [], defaultQuantity: Double? = nil,
        unitID: Int? = nil
    ) {
        self.productID = productID
        self.recipeID = recipeID
        self.quantityFactor = quantityFactor
        self.location = location
        self.effectiveFrom = effectiveFrom
        self.unitLabels = unitLabels
        self.defaultQuantity = defaultQuantity
        self.unitID = unitID
    }

    enum CodingKeys: String, CodingKey {
        case unitID = "qu_id"
        case productID = "product_id"
        case recipeID = "recipe_id"
        case quantityFactor = "quantity_factor"
        case location
        case effectiveFrom = "effective_from"
        case unitLabels = "unit_labels"
        case defaultQuantity = "default_quantity"
    }
}

/// A mapping as the server returns it: the input plus the key it is stored under.
public struct ConsumptionMapping: Sendable, Equatable, Codable {
    public var sourceSystem: String?
    public var medicationRef: String
    public var input: ConsumptionMappingInput

    public init(sourceSystem: String? = VictualHealth.sourceSystem, medicationRef: String, input: ConsumptionMappingInput) {
        self.sourceSystem = sourceSystem
        self.medicationRef = medicationRef
        self.input = input
    }

    private enum KeyCodingKeys: String, CodingKey {
        case sourceSystem = "source_system"
        case medicationRef = "medication_ref"
    }

    public init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: KeyCodingKeys.self)
        sourceSystem = try keys.decodeIfPresent(String.self, forKey: .sourceSystem)
        medicationRef = try keys.decode(String.self, forKey: .medicationRef)
        input = try ConsumptionMappingInput(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        var keys = encoder.container(keyedBy: KeyCodingKeys.self)
        try keys.encodeIfPresent(sourceSystem, forKey: .sourceSystem)
        try keys.encode(medicationRef, forKey: .medicationRef)
        try input.encode(to: encoder)
    }

    /// What the device needs to filter and shape events. `nil` for a mapping with
    /// neither target, which the server would not have stored.
    public var deviceMapping: Mapping? {
        let target: Mapping.Target
        if let product = input.productID {
            target = .product(product)
        } else if let recipe = input.recipeID {
            target = .recipe(recipe)
        } else {
            return nil
        }
        return Mapping(
            medicationRef: medicationRef, target: target,
            location: MappingLocation(mode: input.location.mode, locationID: input.location.locationID),
            effectiveFrom: input.effectiveFrom.date)
    }
}

/// Where a mapping is saved and read.
///
/// ADR-0041 puts mappings on the server so a second phone shares them; the device
/// holds only what ``ConsumptionMapping/deviceMapping`` needs.
public protocol ConsumptionMappingService: Sendable {
    func mappings() async throws -> [ConsumptionMapping]
    /// `PUT`. Replaces the stored mapping, including its `unit_labels`, so the
    /// caller passes the labels it read.
    func put(_ input: ConsumptionMappingInput, medicationRef: String) async throws -> ConsumptionMapping
    func delete(medicationRef: String) async throws
}

/// A product or recipe the person can map a medication to.
public struct CatalogItem: Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

/// A unit a medication can be counted in, for one product.
public struct CatalogUnit: Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    /// How many of the product's stock unit one of this unit is: `1` for the stock
    /// unit itself, the conversion factor otherwise. Shown to the person; the server
    /// converts from the unit's id.
    public var factorToStockUnit: Double
    /// Whether this is the product's own stock unit, which a mapping sends as no unit.
    public var isStockUnit: Bool

    public init(id: Int, name: String, factorToStockUnit: Double, isStockUnit: Bool? = nil) {
        self.id = id
        self.name = name
        self.factorToStockUnit = factorToStockUnit
        self.isStockUnit = isStockUnit ?? (factorToStockUnit == 1)
    }
}

/// A storage location (an organizer, usually) a mapping may book from.
public struct CatalogLocation: Sendable, Equatable, Identifiable {
    public var id: Int
    public var name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

/// What the mapping editor reads from the server, and nothing it writes.
///
/// Backed by endpoints that exist today under `STOCK_VIEW`: the product list,
/// `quantity_unit_conversions_resolved` filtered by product, and
/// `/stock/products/{id}/locations`. The client never matches a medication name to
/// anything here: the person picks.
public protocol MappingCatalog: Sendable {
    func products() async throws -> [CatalogItem]
    func recipes() async throws -> [CatalogItem]
    /// The stock unit and every unit with a conversion to it.
    func units(forProduct id: Int) async throws -> [CatalogUnit]
    /// The locations holding the product, or every location when `id` is `nil`
    /// (a recipe has no single product).
    func locations(forProduct id: Int?) async throws -> [CatalogLocation]
}

/// The editor's state for one medication's mapping, and the rules that decide
/// whether it can be saved.
public struct MappingDraft: Sendable, Equatable {
    public enum TargetKind: String, CaseIterable, Sendable { case product, recipe }

    public var targetKind: TargetKind = .product
    public var productID: Int?
    public var recipeID: Int?
    /// The unit conversion chosen for a product target.
    public var unit: CatalogUnit?
    public var locationMode: MappingLocation.Mode = .fixed
    /// The organizer for `fixed`. `single` takes whichever one location holds enough
    /// and `explicit` names it per event, so neither stores one (the server refuses it).
    public var locationID: Int?
    /// Text as typed, so "0." is not rejected mid-keystroke. Empty means none.
    public var defaultQuantityText = ""
    public var effectiveFrom: Date
    /// The confirmed unit strings, carried through an edit untouched.
    public var unitLabels: [String] = []
    /// When editing: the unit the stored mapping names (`nil` is the stock unit), for
    /// the editor to select once the product's units have loaded.
    public private(set) var storedUnitID: Int?

    public init(effectiveFrom: Date) {
        self.effectiveFrom = effectiveFrom
    }

    /// A draft that edits an existing mapping. The unit is restored from `qu_id`
    /// once the product's units are known: see ``selectStoredUnit(from:)``.
    public init(editing mapping: ConsumptionMapping) {
        let input = mapping.input
        self.targetKind = input.recipeID == nil ? .product : .recipe
        self.productID = input.productID
        self.recipeID = input.recipeID
        self.locationMode = input.location.mode
        self.locationID = input.location.locationID
        self.defaultQuantityText = input.defaultQuantity.map { String($0) } ?? ""
        self.effectiveFrom = input.effectiveFrom.date
        self.unitLabels = input.unitLabels
        self.storedUnitID = input.unitID
    }

    /// Picks the unit a stored mapping named, from the product's unit list.
    public mutating func selectStoredUnit(from units: [CatalogUnit]) {
        guard unit == nil else { return }
        unit = units.first { $0.id == storedUnitID } ?? (storedUnitID == nil ? units.first(where: \.isStockUnit) : nil)
    }

    /// The parsed default quantity: `nil` for none, and for text that is not a
    /// positive number (see ``problem``).
    public var defaultQuantity: Double? {
        let text = defaultQuantityText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let value = Double(text.replacingOccurrences(of: ",", with: ".")), value > 0 else { return nil }
        return value
    }

    /// Why the draft cannot be saved yet, phrased for the person; `nil` when it can.
    public var problem: String? {
        switch targetKind {
        case .product:
            if productID == nil { return "Choose the Victual product." }
            if unit == nil { return "Choose the unit a dose is counted in." }
        case .recipe:
            if recipeID == nil { return "Choose the consumption recipe." }
        }
        if locationMode == .fixed && locationID == nil { return "Choose the organizer to take from." }
        let text = defaultQuantityText.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty && defaultQuantity == nil { return "A default quantity must be a number above zero." }
        return nil
    }

    /// The request body, or `nil` while ``problem`` is non-nil.
    public func input(in zone: TimeZone = .current) -> ConsumptionMappingInput? {
        guard problem == nil else { return nil }
        return ConsumptionMappingInput(
            productID: targetKind == .product ? productID : nil,
            recipeID: targetKind == .recipe ? recipeID : nil,
            quantityFactor: targetKind == .product ? 1 : nil,
            // Only `fixed` carries a location: the server refuses one with `single` or `explicit`.
            location: .init(mode: locationMode, locationID: locationMode == .fixed ? locationID : nil),
            effectiveFrom: RFC3339Timestamp(effectiveFrom, in: zone),
            unitLabels: unitLabels,
            defaultQuantity: defaultQuantity,
            unitID: targetKind == .product && unit?.isStockUnit == false ? unit?.id : nil)
    }
}
