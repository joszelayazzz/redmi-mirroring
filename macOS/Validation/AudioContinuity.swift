import AppKit
import Foundation

@main struct AudioContinuity {
    @MainActor static func main() async {
        let media = MediaPipeline()
        var pts:UInt64 = 0
        func packet() -> Data {
            pts += 20_000
            var timestamp = pts.bigEndian
            var data = withUnsafeBytes(of:&timestamp){Data($0)}
            for i in 0..<960 {
                let sample = Int16(sin(Double(i) * 660 * 2 * .pi / 48_000) * 300).littleEndian
                withUnsafeBytes(of:sample){data.append(contentsOf:$0)}
            }
            return data
        }
        media.playAudio(packet())
        try? await Task.sleep(nanoseconds:400_000_000)
        let beforeReceived=media.audioFramesReceived, beforePlayed=media.audioFramesPlayed, beforeResets=media.audioQueueResets
        let intervals:[UInt64] = [80,120,90,110,100]
        for burst in 0..<50 {
            for _ in 0..<5 { media.playAudio(packet()) }
            try? await Task.sleep(nanoseconds:intervals[burst % intervals.count]*1_000_000)
        }
        try? await Task.sleep(nanoseconds:500_000_000)
        let received=media.audioFramesReceived-beforeReceived, played=media.audioFramesPlayed-beforePlayed, resets=media.audioQueueResets-beforeResets
        print("Audio burst fixture: received=\(received), played=\(played), resets=\(resets), pending=\(media.audioQueuedFrames)")
        guard received==240_000, played==received, resets==0, media.audioQueuedFrames==0, media.errorMessage==nil else {
            print("FAIL: \(media.errorMessage ?? "Audio continuity counters differ")");exit(1)
        }
        print("PASS: five-second 48kHz PCM playback with 80–120ms five-packet bursts, no sample discard after engine warmup.")
        media.reset()
    }
}
