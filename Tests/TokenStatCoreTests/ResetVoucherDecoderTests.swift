import Foundation
import TokenStatCore
import XCTest

/// `/api/v1/me/reset-vouchers` 只用于读取可用券数量。
/// 字段缺失、类型异常或越界时必须返回未知（nil），不能当成 0 张。
final class ResetVoucherDecoderTests: XCTestCase {

    func testDecodeReadsNonNegativeIntegerTotal() {
        let data = Data(#"{"code":0,"message":"ok","data":{"items":[],"total":2,"page":1,"page_size":20}}"#.utf8)
        XCTAssertEqual(TokenHubResetVoucherDecoder.decode(data), 2)
    }

    func testDecodeAcceptsZero() {
        let data = Data(#"{"code":0,"message":"ok","data":{"items":[],"total":0,"page":1,"page_size":20}}"#.utf8)
        XCTAssertEqual(TokenHubResetVoucherDecoder.decode(data), 0)
    }

    func testDecodeReturnsNilForMissingOrMalformedTotal() {
        let payloads = [
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
            ""
        ]
        for payload in payloads {
            XCTAssertNil(TokenHubResetVoucherDecoder.decode(Data(payload.utf8)),
                         "payload must decode as unknown: \(payload)")
        }
    }

    func testDecodeRejectsOversizedResponse() {
        let padding = String(repeating: " ", count: 1_048_576)
        let data = Data((#"{"data":{"total":1}}"# + padding).utf8)
        XCTAssertNil(TokenHubResetVoucherDecoder.decode(data))
    }
}
