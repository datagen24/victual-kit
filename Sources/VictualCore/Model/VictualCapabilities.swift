import Foundation
import VictualAPI

/// What the authenticating key's owner is allowed to do, as
/// `GET /user/capabilities` reports it.
///
/// A key inherits its owner's permissions exactly; it is not a narrower
/// credential. An MCP key may additionally be ``isReadOnly``, which refuses
/// anything but `GET`, `HEAD` and `OPTIONS` regardless of what
/// ``permissions`` says.
///
/// These are a courtesy, not a guarantee. Permissions can change between this
/// fetch and the next booking, so a `403` must still be handled on every write.
public struct VictualCapabilities: Hashable, Sendable {
    /// `"default"` or `"mcp"`, or `nil` when the request was not authenticated
    /// by a key at all.
    public var keyType: String?

    /// Whether the key refuses every write, whatever the permissions say.
    public var isReadOnly: Bool

    /// The acting user's resolved permission names.
    public var permissions: Set<String>

    public init(keyType: String? = nil, isReadOnly: Bool = false, permissions: Set<String> = []) {
        self.keyType = keyType
        self.isReadOnly = isReadOnly
        self.permissions = permissions
    }

    /// Whether the user holds a permission.
    ///
    /// The server sends *resolved* names, so a role's permissions are already
    /// expanded. `ADMIN` is honoured as a superuser marker anyway: if an
    /// instance ever stops expanding it, the cost of being wrong here is a
    /// control that is offered and then answered `403` — which the write path
    /// handles — rather than a household administrator staring at controls
    /// they are entitled to use.
    public func allows(_ permission: String) -> Bool {
        permissions.contains(permission) || permissions.contains(VictualPermission.admin)
    }

    /// Whether a write naming `permission` is worth attempting at all.
    public func canWrite(_ permission: String) -> Bool {
        !isReadOnly && allows(permission)
    }

    /// What is standing in the way of `permission`, phrased for a tooltip, or
    /// `nil` when nothing is.
    public func obstacle(to permission: String) -> String? {
        if isReadOnly {
            return "This API key is read-only and cannot change anything."
        }
        if !allows(permission) {
            return "Requires the \(permission) permission, which this account does not have."
        }
        return nil
    }
}

extension VictualCapabilities {
    init(_ schema: Components.Schemas.CurrentUserCapabilities) {
        self.init(
            keyType: schema.keyType,
            isReadOnly: schema.readOnly,
            permissions: Set(schema.permissions)
        )
    }
}

/// The permission names this application checks.
///
/// Spelled out rather than inlined so a rename upstream is one edit, and so a
/// tooltip can name the permission the user is missing.
public enum VictualPermission {
    public static let admin = "ADMIN"
    public static let stockView = "STOCK_VIEW"
    public static let stockConsume = "STOCK_CONSUME"
    public static let stockPurchase = "STOCK_PURCHASE"
    public static let stockOpen = "STOCK_OPEN"
    public static let stockInventory = "STOCK_INVENTORY"
    public static let stockTransfer = "STOCK_TRANSFER"
    public static let stockPricesView = "STOCK_PRICES_VIEW"
    public static let stockUndo = "STOCK_UNDO"
}
