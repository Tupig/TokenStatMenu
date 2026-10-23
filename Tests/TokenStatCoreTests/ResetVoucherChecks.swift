import Foundation
import TokenStatCore

extension CoreChecks {
    static func resetVoucherChecks() {
        check(TokenHubResetVoucherDecoder.decode(
            json(#"{"code":0,"message":"ok","data":{"items":[],"total":2,"page":1,"page_size":20}}"#)) == 2,
              "reset voucher total decodes")
        check(TokenHubResetVoucherDecoder.decode(json(#"{"data":{"total":0}}"#)) == 0,
              "reset voucher zero is preserved")

        let malformed = [
            #"{"data":{}}"#,
            #"{"data":{"total":null}}"#,
            #"{"data":{"total":-1}}"#,
            #"{"data":{"total":1.5}}"#,
            #"{"data":{"total":"2"}}"#,
            #"{"data":{"total":true}}"#,
            #"{"data":{"total":1000001}}"#,
            #"{"data":[]}"#,
            #"[]"#,
            #"{}"#,
            "",
        ]
        for payload in malformed {
            check(TokenHubResetVoucherDecoder.decode(json(payload)) == nil,
                  "reset voucher malformed payload rejected: \(payload)")
        }

        let padding = String(repeating: " ", count: 1_048_576)
        check(TokenHubResetVoucherDecoder.decode(json(#"{"data":{"total":1}}"# + padding)) == nil,
              "reset voucher oversized response rejected")
    }
}
