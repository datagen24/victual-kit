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
             "best_before_date": "2026-01-31", "is_aggregated_amount": false}
            """.utf8
        )

        let stock = try decoder.decode(Components.Schemas.CurrentStockResponse.self, from: json)

        #expect(stock.productId == 7)
        #expect(stock.amountAggregated == 4.0)
        #expect(stock.bestBeforeDate == "2026-01-31")
        #expect(stock.isAggregatedAmount == false)
    }

    /// The flags the document calls `boolean` decode as booleans.
    ///
    /// Before Victual 0.2.0-MVP the server sent `stock_log.spoiled` as `0`/`1`
    /// and `Scripts/update-openapi.py` retyped it to `integer`; without that, all
    /// five bookings threw *after* the booking had been written. Issue #230 made
    /// the server send `true`/`false` instead, so the retype was removed. This
    /// pins that it stays removed: an `integer` here would refuse every booking
    /// response again.
    @Test("Documented boolean flags decode as booleans")
    func documentedBooleansAreBooleans() throws {
        let booking = Data(#"[{"id": 1, "spoiled": false, "transaction_id": "tx"}]"#.utf8)
        let rows = try decoder.decode([Components.Schemas.StockLogEntry].self, from: booking)
        #expect(rows.first?.spoiled == false)

        let spoiledRow = Data(#"[{"id": 2, "spoiled": true}]"#.utf8)
        #expect(
            try decoder.decode([Components.Schemas.StockLogEntry].self, from: spoiledRow)
                .first?.spoiled == true
        )
    }

    /// The control for the test above: fields that were booleans before issue
    /// #230 stay booleans.
    ///
    /// `ProductDetailsResponse.has_childs` reaches the wire through `boolval()`,
    /// and `CurrentUserCapabilities.read_only` through a PHP comparison. Neither
    /// is a raw column, and neither was ever listed for repair.
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
