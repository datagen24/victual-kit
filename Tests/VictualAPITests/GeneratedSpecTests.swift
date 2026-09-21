import Foundation
import Testing

@testable import VictualAPI

/// Guards the shapes the generated bindings depend on. Some were produced by
/// `Scripts/update-openapi.py`'s repairs and are now supplied by upstream
/// directly; the assertions are unchanged either way, because what matters is
/// the document the generator reads. If one fails after a spec sync, the
/// upstream document changed shape and the script needs revisiting — not the
/// test.
@Suite("Generated bindings")
struct GeneratedSpecTests {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        return decoder
    }()

    @Test("The server placeholder was replaced with the API path prefix")
    func serverURLIsAPIPrefix() throws {
        #expect(try Servers.Server1.url().absoluteString == "/api")
    }

    @Test("Required-but-nullable fields decode a JSON null")
    func nullableRequiredFieldsAreOptional() throws {
        // `UserPermission.parent` and `.via_roles` are listed in `required`.
        // Unless their type is the union `["integer", "null"]` they generate as
        // non-optional, and every response where a permission has no parent
        // fails to decode. Upstream writes the union itself as of commit
        // 5995cab; before that the normalizer translated it from the OpenAPI
        // 3.0 `nullable` spelling, and still would if upstream regressed.
        let json = Data(
            """
            {
              "id": 3,
              "user_id": 1,
              "permission_id": 12,
              "has_permission": 1,
              "permission_name": "STOCK_VIEW",
              "parent": null,
              "via_roles": null
            }
            """.utf8
        )

        let permission = try decoder.decode(Components.Schemas.UserPermission.self, from: json)

        #expect(permission.id == 3)
        #expect(permission.permissionName == "STOCK_VIEW")
        #expect(permission.parent == nil)
        #expect(permission.viaRoles == nil)
    }

    @Test("The same fields still decode a present value")
    func nullableRequiredFieldsAcceptValues() throws {
        let json = Data(
            """
            {
              "id": 4, "user_id": 1, "permission_id": 13, "has_permission": 1,
              "permission_name": "STOCK_EDIT", "parent": 12, "via_roles": "ADMIN"
            }
            """.utf8
        )

        let permission = try decoder.decode(Components.Schemas.UserPermission.self, from: json)

        #expect(permission.parent == 12)
        #expect(permission.viaRoles == "ADMIN")
    }

    @Test("Label routes generated usable operations")
    func labelRoutesAreTemplatedLegally() {
        // These were written `/labels/{kind:location|product|…}/{id:[0-9]+}/print`
        // upstream, which is not legal OpenAPI path templating; the normalizer
        // reduced them to `/labels/{kind}/{id}/print`. Upstream writes the legal
        // form as of commit 5995cab. Either way the constraint lives on the
        // parameter schema, which is what the operation name below proves.
        #expect(Operations.PostLabelsByKindByIdPrint.id == "postLabelsByKindByIdPrint")
        #expect(Operations.GetLabelsByKindByIdContext.id == "getLabelsByKindByIdContext")
    }

    @Test("Hand-picked operation names came through")
    func operationIDOverridesApplied() {
        #expect(Operations.GetSystemInfo.id == "getSystemInfo")
        #expect(Operations.GetCurrentStock.id == "getCurrentStock")
        #expect(Operations.ListObjects.id == "listObjects")
        #expect(Operations.GetObject.id == "getObject")
    }

    @Test("Snake-cased response fields map to idiomatic Swift names")
    func idiomaticNaming() throws {
        let json = Data(
            """
            {"product_id": 7, "amount": 2.5, "amount_aggregated": 4.0,
             "best_before_date": "2026-01-31", "is_aggregated_amount": 0}
            """.utf8
        )

        let stock = try decoder.decode(Components.Schemas.CurrentStockResponse.self, from: json)

        #expect(stock.productId == 7)
        #expect(stock.amountAggregated == 4.0)
        #expect(stock.bestBeforeDate == "2026-01-31")
        #expect(stock.isAggregatedAmount == 0)
    }

    /// The 0/1 flags the document calls `boolean` and the server sends as
    /// numbers, retyped by `Scripts/update-openapi.py`.
    ///
    /// Confirmed against a live instance: without this, a `0` where `true` was
    /// promised fails the whole response, so all five bookings throw *after* the
    /// booking has already been written. `VictualCore` maps these back to `Bool`
    /// at its own boundary.
    @Test("Integer flags the document mistyped as boolean decode as numbers")
    func integerFlagsRetyped() throws {
        let booking = Data(#"[{"id": 1, "spoiled": 0, "transaction_id": "tx"}]"#.utf8)
        let rows = try decoder.decode([Components.Schemas.StockLogEntry].self, from: booking)
        #expect(rows.first?.spoiled == 0)

        let spoiledRow = Data(#"[{"id": 2, "spoiled": 1}]"#.utf8)
        #expect(
            try decoder.decode([Components.Schemas.StockLogEntry].self, from: spoiledRow)
                .first?.spoiled == 1
        )
    }

    /// The control for the repair above: a field that really is a boolean
    /// server-side stays one, so the retyping stayed surgical.
    ///
    /// `ProductDetailsResponse.has_childs` reaches the wire through `boolval()`,
    /// and `CurrentUserCapabilities.read_only` through a PHP comparison. Neither
    /// is a raw column, and neither is listed for repair.
    @Test("Fields that really are boolean were left alone")
    func genuineBooleansUntouched() throws {
        let detail = Data(#"{"has_childs": true, "stock_amount": 2}"#.utf8)
        let decoded = try decoder.decode(
            Components.Schemas.ProductDetailsResponse.self, from: detail
        )
        #expect(decoded.hasChilds == true)

        let capabilities = Data(
            #"{"key_type": "mcp", "read_only": true, "permissions": []}"#.utf8
        )
        #expect(
            try decoder.decode(
                Components.Schemas.CurrentUserCapabilities.self, from: capabilities
            ).readOnly == true
        )
    }
}
