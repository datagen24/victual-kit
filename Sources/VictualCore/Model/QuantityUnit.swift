import Foundation
import VictualAPI

/// A unit stock is counted in.
///
/// Amounts cannot be rendered without one: `2` is meaningless where `2 packs`
/// is not, which is why the stock list fetches these up front rather than per
/// product.
public struct QuantityUnit: Hashable, Sendable, Identifiable, Codable {
    public var id: Int
    public var name: String
    /// The plural form, when the instance defines one.
    public var namePlural: String?
    public var details: String?

    public init(id: Int, name: String, namePlural: String? = nil, details: String? = nil) {
        self.id = id
        self.name = name
        self.namePlural = namePlural
        self.details = details
    }

    /// The name to use for `amount` of this unit.
    ///
    /// Falls back to the singular when the instance defined no plural, which is
    /// common for units like `g` where there is no plural to define.
    public func name(for amount: Double) -> String {
        amount == 1 ? name : (namePlural ?? name)
    }

    /// `"2.5 packs"`, or just the number when no unit is known.
    public static func describe(_ amount: Double, in unit: QuantityUnit?) -> String {
        let number = amount.formatted(.number.precision(.fractionLength(0...3)))
        guard let unit else { return number }
        return "\(number) \(unit.name(for: amount))"
    }

    /// `GET /objects/quantity_units` is read directly rather than through the
    /// generated response type; see ``VictualClient/listObjects(_:as:)``.
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case namePlural = "name_plural"
        case details = "description"
    }
}

extension QuantityUnit {
    init?(_ schema: Components.Schemas.QuantityUnit) {
        guard let id = schema.id else { return nil }
        self.init(
            id: id,
            name: schema.name ?? "",
            namePlural: schema.namePlural,
            details: schema.description
        )
    }
}
