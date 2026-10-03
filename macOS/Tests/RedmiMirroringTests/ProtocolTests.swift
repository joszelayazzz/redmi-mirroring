import XCTest
@testable import RedmiMirroring
final class ProtocolTests: XCTestCase {
    func testFragmentedAndCoalescedFrames() throws {
        let a = FrameParser.encode(type:1,payload:Data("hello".utf8))
        let b = FrameParser.encode(type:3,payload:Data([0,1,2,3]))
        var parser = FrameParser(); var frames = [WireFrame]()
        for byte in a + b { frames += try parser.append(Data([byte])) }
        XCTAssertEqual(frames.count,2); XCTAssertEqual(frames[0].payload,Data("hello".utf8)); XCTAssertEqual(frames[1].type,3)
        var coalesced = FrameParser(); XCTAssertEqual(try coalesced.append(a+b).count,2)
    }
    func testMaliciousLengths() {
        var parser = FrameParser(); XCTAssertThrowsError(try parser.append(Data([255,255,255,255])))
        var zero = FrameParser(); XCTAssertThrowsError(try zero.append(Data([0,0,0,0])))
    }
    func testPairingRejectsAmbiguityAndWeakSecrets() throws {
        let link = "redmimirror://pair?host=192.168.1.2&port=39817&id=EB72B468-1DBF-46E7-AE04-B52D59291C28&name=Redmi&fp=\(String(repeating:"ab",count:32))&secret=\(String(repeating:"cd",count:32))"
        XCTAssertEqual(try PairingInvitation(link:link).port,39817)
        XCTAssertThrowsError(try PairingInvitation(link:link+"&secret=xx"))
        XCTAssertThrowsError(try PairingInvitation(link:link.replacingOccurrences(of:"redmimirror",with:"http")))
        XCTAssertThrowsError(try PairingInvitation(link:link.replacingOccurrences(of:String(repeating:"cd",count:32),with:"123456")))
    }
}
