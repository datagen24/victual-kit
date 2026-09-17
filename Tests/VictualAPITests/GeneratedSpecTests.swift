import Foundation
import Testing

@testable import VictualAPI

/// Guards the normalizations `Scripts/update-openapi.py` applies to the upstream
/// specification. If one of these fails after a spec sync, the upstream document
/// changed shape and the script needs revisiting — not the test.
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
        // `UserPermission.parent` and `.via_roles` are listed in `required` and
        // marked `nullable` upstream, using the OpenAPI 3.0 spelling inside a
        // 3.1 document. Without the normalizer's translation to a `["integer",
        // "null"]` type union they generate as non-optional, and every response
        // where a permission has no parent fails to decode.
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

    @Test("Routes carrying Slim constraints generated usable operations")
    func routeConstraintsWereStripped() {
        // `/labels/{kind:location|product|…}/{id:[0-9]+}/print` is not legal
        // OpenAPI path templating; the normalizer reduces it to
        // `/labels/{kind}/{id}/print`, and the enum survives on the parameter.
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
}
