# Verification report

Development checkpoint: 2026-10-02. This report records actual evidence rather than treating compilation as functional verification. Control tests passed and the owner confirmed responsive behavior. After a subsequent HyperOS OneKeyClean system kill, the owner re-enabled Accessibility and connected/control/live-pointer/projection/audio states were verified active again. The preceding Mac 0.1.0 build passed the stalled-connection deadline, 30-second live animation/audio, and portrait/landscape checks. Mac 0.1.1 additionally passed saved-pairing launch, all native component checks, and a real capture restart with the Responsive profile retained. These bounded tests do not establish uninterrupted long-term reliability.

## Mac 0.1.1 capture-restart regression

The owner stopped and approved a fresh whole-display/audio capture while the Mac connection remained authenticated. The app re-applied its saved Responsive profile, and actual decoded video returned at 560 × 1280 with connected/control/projection/audio/hardware decoding true and no media error. No new authenticated event occurred after captureStopped. Before the patch, this scenario returned at native 720 × 1640 despite the saved Responsive preference. The 0.1.1 Mac update changes this quality lifecycle and its version metadata; the installed Android APK is unchanged. The performance measurements and other retained physical cases below were collected on the preceding Mac build, and are not new 0.1.1 benchmarks. Android system logs separately confirmed STOP_REASON_KEYGUARD for a prior capture stop; fresh consent is required.

## Test environment and build identity

- Mac: Apple Silicon arm64, macOS 27.0.1, Swift 6.4 command-line toolchain.
- Real phone: Redmi 14C, model 2409BRN2CL, Android16, HyperOS 3.0.306.0.WGTMIXM.
- Android component: Kotlin/platform APIs, target API36, minimum API29. TLS identity and storage keys use Android Keystore.
- Builds exist at `build/Redmi Mirroring.app` and `build/RedmiMirroring-companion.apk`. The Mac has a local development signature and is not notarized; the APK has a local development signature.
- The distributable Mac ZIP is `build/Redmi Mirroring-macOS.zip`, 447,350 bytes, SHA-256 `6baa19eb21fff4a4cf63f41d7cfc6b51f57176d40612d26dff472beff0395f29`. Its contents were verified as the native app and packaging metadata, without private QA artifacts.
- The current delivery APK was installed with pairing preserved. Its SHA-256 is `6e5d6c53b8738078bc186d749c796ee615b59055a1b8d93b7d75d578a93dc834`. A byte comparison verified that the installed base APK and delivered APK are identical at 836,231 bytes. The latest continuous-scroll/input timing tests, all six TLS rejection cases, and 13 host checks passed on this APK. Earlier rotation, paste, file-transfer and other physical results are retained with their scope; this report does not assert that every case was rerun after every rebuild.
- Short tests used 5 GHz Wi-Fi with reported RSSI around −39 dBm and a 433 Mb/s link rate. Android's `global.low_power` setting was temporarily changed from `1` to `0` during optimization and restored to its original `1`, which was active during the earlier control tests. During the later optimization pass, low_power=0 was observed with the phone charging at 36–41% (its transition cause was not established); these tests do not measure battery efficiency.
- Authorized phone UI changes were verified: this app's battery policy changed from Recommended to **No restrictions**, and **Background autostart** changed from disabled to enabled. Global Battery saver was not forced during the later pass. Window/transition/animator duration scales were changed from 1× (or the system default) to 0.5× and verified. Screen brightness and thermal controls were unchanged. A Recents lock was not used.

## WORKING — verified on the real phone

| Capability | Direct evidence |
|---|---|
| Native app launch and live screen | App launched; user directly confirmed the real phone screen was visible and responded. No development mock supplied the screen. |
| Pairing and secure LAN stream | Phone explicitly approved pairing. Actual encrypted stream decoded at 720 × 1640, with VideoToolbox hardware decoding reported active. |
| Mouse click | Native Mac click opened the real Android Settings search field. |
| Unicode typing | `Redmi test café` forwarded from the Mac matched the real focused Android field exactly in UI inspection. |
| Scrolling and live drag | Native Mac pointer-down and move produced real decoded feedback before pointer-up. A continuous-scroll test sent 24 native scroll events over 0.5 seconds and moved the real Settings list, with 17 completed movement segments and zero rejected segments. A later native-event test on the QA canvas recorded 20 movements and pointer UP after the normal Ended event. The owner confirmed that control now responds well. |
| Held touch and stale-touch recovery | A stationary Mac pointer remained held for more than four seconds, with the real decoded canvas showing DOWN. Suspending only the Mac app for 2.5 seconds caused the phone's 1,250 ms stale-touch watchdog to release the touch; an independent phone screenshot showed UP. The Mac app resumed and streaming reconnected within seconds. This tests an app stall, not whole-network loss or Mac sleep. |
| Physical rotation | Full-resolution 720 × 1640 portrait ↔ 1640 × 720 landscape passed earlier. On the current Responsive build, visually inspected real decoded images changed to 1280 × 560 landscape in 2.855 s and back to 560 × 1280 portrait in 1.226 s. Connected/projection/control/audio/hardware decoding remained active, with no media error in either record. Temporary rotation-test settings were restored exactly. |
| Paste from Mac clipboard | `Redmi clipboard café ✓` matched the actual focused Android field exactly. The test restored the Mac's original clipboard formats afterward. This does not establish Android-to-Mac clipboard sharing. |
| Window resizing | Streaming continued at Mac window sizes 450 × 850, 700 × 700, and 410 × 820. |
| Screenshot | Native decoded-frame screenshot was produced at 720 × 1640. |
| File transfer | Received `Download/Redmi Mirroring/transfer-test.txt` matched the original bytes exactly. |
| App relaunch | Mac relaunched and reconnected using saved pairing while the existing phone capture session continued. |
| Controlled TCP interruption | State progressed Reconnecting → Connecting securely → Connected in about four seconds; video and PCM resumed without fresh phone approval. This was a transport interruption, not a Wi-Fi/router-outage test. |
| Accessibility recovery after system kill | The owner physically re-enabled the control permission. Connected, control, live-pointer support, projection, and playback audio were all verified active afterward. This was assisted recovery; automatic permission rebinding after HyperOS cleanup is not claimed. |
| Audio capture/playback pipeline | A native Mac click started a 660 Hz tone in a local test page. Non-silent PCM arrived and played. After queue/startup fixes, the user explicitly confirmed continuous, clean audio. The final 30-second animation/tone run played 1,440,960 samples with zero additional audio queue resets. This is a bounded test, not a guarantee under all workloads. |
| Final animation/audio run | Over 30.004 seconds at 560 × 1280, 1,735 video frames decoded. All 31 samples reported connected/control/projection/audio/hardware decoding active. There were zero additional decoder drops, two display drops, and zero additional audio queue resets. |
| Unauthorized client rejection | Six physical-phone tests covered unpaired credentials, empty framing, and oversized initial authentication under both TLS1.2 and TLS1.3. Connections closed without capabilities or media disclosure. |

## Measurements and their limits

The final live animation/audio run lasted **30.004 seconds** at **560 × 1280**. It decoded **1,735 frames**, averaging **57.82 fps**. Median smoothed VideoToolbox decode duration was **1.141 ms**; median clock-adjusted capture-packet age was **25.69 ms**, maximum 88.79 ms; median network RTT was **10.23 ms**. All 31 samples reported connected, control, projection, audio, and hardware decoding active.

Quiet 660 Hz test tones ran near seconds 1, 11, and 21. The native pipeline received **1,442,880 audio samples** and played **1,440,960**, approximately **48,000 samples/s**; peak measured PCM RMS was 0.021325. There were **zero additional decoder drops**, **two display drops**, and **zero additional audio queue resets** during the measured interval. An earlier Mac build recorded additional decoder/display drops outside its measured interval. A later fix releases actual decoder capacity on the codec callback thread instead of waiting for UI delivery; this fixes a reproduced false-backpressure case. The latest 30-second run reported zero additional decoder drops. Occasional display drops and audio-queue resets outside the bounded run still occur; uninterrupted long-term operation is not established. These are counter deltas within this run, not global lifetime zero-drop/reset claims. Counters restart with the media pipeline. The audio queue uses an adaptive 80–120 ms startup cushion and a 240 ms cap, excluding output-device latency. This bounded QA run is not long-term stability, thermal profiling, or a battery benchmark.

The latest two sets confirmed decoded feedback for **12 of 12 real native input trials**:

| Quality | Confirmed trials | Median feedback delay | Observed range |
|---|---:|---:|---:|
| Balanced | 6/6 | 122.61 ms | 103.46–498.69 ms |
| Responsive, 560 × 1280, 60 fps, 4 Mb/s | 6/6 | 109.10 ms | 95.86–133.86 ms |

The 498.69 ms Balanced outlier was the first trial; its cause was not established. The remaining five Balanced trials had median 121.13 ms. These small sets measure software input-to-decoded feedback, not glass-to-glass latency or uniform performance under every workload. Earlier timeout-heavy results were collected across a recorded HyperOS system kill of the companion; they are not a stable-session baseline. Whether the cleaner was invoked manually or automatically was not established.

Phone instrumentation observed encoded-presentation-timestamp age around 23–24 ms, writer queue residence about 0.16–0.22 ms, and socket write duration about 0.60–0.75 ms. The encoder was asked for one-frame latency but reported **three frames**, so successful configuration does not establish that the one-frame hint was honored. One 109 ms gesture API call measured elapsed wall time, including possible CPU descheduling; it does not identify Binder as the cause.

Network RTT, decoder duration, capture-packet age, and software feedback delay measure different stages; none is a high-speed-camera glass-to-glass benchmark. Controlled motion/thermal profiling and battery measurement remain unverified.

## WORKING — component and fixture verification

- Android host suite: 13 framing, truncation, timestamp, admission-size, and filename-safety checks passed.
- A regression fixture completed 24 genuine VideoToolbox decodes while main delivery was deliberately blocked, with all hardware slots released and zero false-overload/keyframe-recovery drops. Main-loop heartbeat/reconnect/diagnostic timers now use common modes so menus and resizing do not intentionally pause them; actual menu-duration lifecycle testing remains pending.
- Latest native Mac component validation passed actual H.264 encode/decode: 90/90 synthetic 1080 × 1920 frames at 60 fps with zero drops and only two frame-related UI notifications. Landscape reconfiguration, screenshots, Unicode composition, coordinate mapping, live pointer/continuous-scroll sequencing, reset cancellation, parser/reset behavior, and 960-frame AVAudioEngine silence completion passed. Synthetic codec frames are explicitly test sources; they do not establish 1080p60 performance from the Redmi.
- Native audio burst fixture after warmup: 240,000 frames received, scheduled, and played over five seconds, with zero resets across 50 batches of five packets arriving at 80–120 ms intervals. This is Mac component evidence, separate from the real phone and audible user confirmation.
- Relay suite: 13 genuine TLS cases passed, including malformed/short credentials, wrong room, duplicate roles, pre-admission data, size/rate/capacity limits, timeout, bidirectional bytes, reconnect, and nested inner TLS.
- Actual Swift remote bridge passed a loopback nested TLS echo and reconnect fixture; wrong relay and wrong inner phone fingerprints were rejected. Echo RTT was roughly 0.6–1.1 ms. This measures local transport QA only.
- Native app connection deadline passed against a local listener that accepted TCP but never answered TLS: Connecting at 0.548 s → Reconnecting at 8.419 s → Connecting at 10.451 s → Connected to the real phone at 11.465 s. Projection, control, and audio were active after recovery. No authentication credentials were sent to the stalled listener. This verifies the eight-second connection deadline and subsequent phone reconnect, not a real Wi-Fi/router outage or Internet relay failure.

## IMPLEMENTED BUT UNVERIFIED / pending

- Real Wi-Fi loss/network changes, Mac sleep/wake, sustained background/HyperOS behavior, lock/reapproval, and long-duration thermal/battery behavior.
- Android-to-Mac clipboard sharing, Android system clipboard synchronization beyond the verified focused-field paste, all navigation/volume/lock shortcuts, multitouch gestures, and file interruption cleanup on the real phone.
- Relay operation between separate Internet networks, Internet performance, and deployed relay certificate/room revocation. The outbound encrypted relay code is implemented; no Internet endpoint or ICE/STUN/TURN service is deployed.
- Remaining regression cases not repeated after the current APK installation.

## BLOCKED / PLATFORM LIMITATION

Android16 cannot silently reuse a stopped projection session. Phone lock stops projection; this app also stops capture on screen-off. No root, lock bypass, or permission bypass is used. Protected applications may block screen/audio capture; Android background clipboard access is restricted. The remote relay cannot remove these restrictions. [Android projection](https://developer.android.com/media/grow/media-projection), [audio capture policy](https://developer.android.com/media/platform/av-capture), [clipboard privacy](https://developer.android.com/about/versions/10/privacy/changes)

Android's process-exit evidence recorded HyperOS `GarbageClean` and later `OneKeyClean`, reason 13 / **OTHER KILLS BY SYSTEM**. This establishes system termination, not an application Java exception; whether someone invoked the cleaner or it ran automatically is unknown. After the latter kill, Accessibility remained enabled in settings but unbound and marked crashed by Android, while video/audio recovered. The owner re-enabled Accessibility, restoring control. Authorized UI changes to **No restrictions** and **Background autostart** were verified afterward; their long-term protection remains untested. Avoid clearing the companion or running memory cleaners during mirroring. Recents locking is optional only if the actual firmware exposes it: Xiaomi's Redmi 14C FAQ says background app lock is unsupported. Android's standard Doze exemption alone does not establish protection from these vendor kills, force-stop, reboot, or memory pressure. Fresh screen-sharing consent is still required when capture has stopped. [Xiaomi background autostart](https://dev.mi.com/xiaomihyperos/documentation/detail?pId=1624), [Redmi 14C FAQ](https://www.mi.com/pk/support/faq/details/KA-426105/)

The evidence files under workspace `work/` are internal QA artifacts. Source-level build/test commands and server setup are documented in [README.md](README.md), [android/README.md](android/README.md), and [relay/README.md](relay/README.md).
