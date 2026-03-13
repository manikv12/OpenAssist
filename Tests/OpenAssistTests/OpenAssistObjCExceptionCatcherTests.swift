import Foundation
import XCTest
import OpenAssistObjCInterop

final class OpenAssistObjCExceptionCatcherTests: XCTestCase {
    func testPerformReturnsTrueWhenBlockSucceeds() {
        var executed = false
        
        XCTAssertNoThrow(try OpenAssistObjCExceptionCatcher.perform({
            executed = true
        }))
        XCTAssertTrue(executed)
    }

    func testPerformConvertsNSExceptionIntoNSError() {
        do {
            try OpenAssistObjCExceptionCatcher.perform({
                NSException(name: .genericException, reason: "boom", userInfo: nil).raise()
            })
            XCTFail("Expected an Objective-C exception to be bridged as an error.")
        } catch {
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "OpenAssist.ObjCException")
            XCTAssertEqual(nsError.localizedDescription, "boom")
        }
    }
}
