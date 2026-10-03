import Foundation
@main struct ProtocolValidation {
    static func main() throws {
        let a = FrameParser.encode(type:1,payload:Data("hello".utf8))
        let b = FrameParser.encode(type:3,payload:Data([0,1,2,3]))
        var parser = FrameParser(); var frames = [WireFrame]()
        for byte in a+b { frames += try parser.append(Data([byte])) }
        precondition(frames.count == 2 && frames[0].payload == Data("hello".utf8) && frames[1].type == 3)
        var coalesced = FrameParser(); let together = try coalesced.append(a+b); precondition(together.count == 2)
        for bad in [Data([255,255,255,255]),Data([0,0,0,0]),Data([1,0,0,1])] {
            var parser = FrameParser(); var rejected = false
            do { _ = try parser.append(bad) } catch { rejected = true }; precondition(rejected)
        }
        let link = "redmimirror://pair?host=192.168.1.2&port=39817&id=EB72B468-1DBF-46E7-AE04-B52D59291C28&name=Redmi&fp=\(String(repeating:"ab",count:32))&secret=\(String(repeating:"cd",count:32))"
        let invite = try PairingInvitation(link:link); precondition(invite.port == 39817)
        for bad in [link+"&secret=xx",link.replacingOccurrences(of:"redmimirror",with:"http"),link.replacingOccurrences(of:String(repeating:"cd",count:32),with:"123456")] {
            var rejected = false; do { _ = try PairingInvitation(link:bad) } catch { rejected = true }; precondition(rejected)
        }
        print("PASS: fragmented/coalesced framing, malicious sizes, pinned invitation parser, duplicate/weak credential rejection")
    }
}
