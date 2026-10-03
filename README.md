# Redmi Mirroring

Native Swift/AppKit/SwiftUI mirroring for a Redmi phone, with a Kotlin Android companion. Real LAN pairing, portrait/landscape streaming, live mouse dragging, keyboard/paste, audio, file transfer, and reconnect have been exercised on a Redmi 14C. See [TEST-REPORT.md](TEST-REPORT.md) for the distinction between physical-device results, component fixtures, and unverified features.

Mac 0.1.1 preserves the selected quality when a new owner-approved capture starts on an already paired connection. A real stop/start test retained Responsive at 560 × 1280 with screen, control and audio active. The Android APK is unchanged.

## Downloads

Get the Apple Silicon Mac app ZIP and Android companion APK from [GitHub Releases](https://github.com/joszelayazzz/redmi-mirroring/releases). This is an early development release; review the platform limits and test report before use.

## Deliverables

- macOS app: `build/Redmi Mirroring.app`
- macOS distribution ZIP: `build/Redmi Mirroring-macOS.zip`
- Android companion: `build/RedmiMirroring-companion.apk`
- Native source: `macOS/` and `android/`
- Optional self-hosted relay: `relay/`
- Architecture and platform boundaries: [ARCHITECTURE.md](ARCHITECTURE.md)
- Dependency licenses: `THIRD-PARTY-NOTICES.txt`

The source tree contains the native macOS app, Android companion, wire protocol, optional relay, validation fixtures and build scripts.

The supplied Mac build is Apple Silicon, requires macOS 14+, and uses a local ad-hoc development signature. It is not notarized. The APK is signed with this workspace's private development key, rather than distributed through Google Play. The installed APK was byte-verified against the delivery APK; current control and security tests passed. The build identity and individual physical-test scope are recorded in the test report.

## Open and pair

1. Open `build/Redmi Mirroring.app` in Finder; it may be copied to Applications like an ordinary Mac app.
2. With the phone owner's approval, install the companion APK and open it. Choose **Make available**, then **Pair a Mac**. Share its invitation privately with this Mac.
3. Choose **Pair your Redmi** in the Mac app, paste the invitation, and approve that Mac in the phone companion. Invitations expire after five minutes.
4. On the phone, enable the disclosed **Redmi Mirroring control** Accessibility permission. Choose **Start sharing** and approve Android's screen-sharing dialog. Choose the whole display for coordinate control.
5. Return to the phone's Home screen or another app. The companion's own setup screen intentionally blocks capture to protect pairing credentials.

Allow macOS Local Network access when its system prompt appears. Ordinary use needs no USB connection or ADB. A paired Mac automatically reconnects while the phone's companion and approved sharing session remain active. If Android stops sharing, reopen the companion and approve a new session.

For ongoing HyperOS use, open the companion's **Open app settings** and review **Battery saver → No restrictions/Unrestricted** and **Background autostart**. Avoid clearing the companion or running a memory cleaner while mirroring. Use a Recents lock only if your actual firmware exposes one; Xiaomi's Redmi 14C FAQ says background app lock is unsupported. Recorded system kills interrupted Accessibility control during testing; whether the cleaner was invoked manually or automatically is unknown. If control remains unavailable while Accessibility is enabled, the owner may need to toggle its permission off/on. These settings cannot guarantee uninterrupted operation or preserve capture after force-stop/reboot. A standard Android Doze exemption alone does not establish protection against HyperOS cleanup. [Redmi 14C FAQ](https://www.mi.com/pk/support/faq/details/KA-426105/)

On the tested phone, the owner restored Accessibility control, and authorized UI changes to **No restrictions** and **Background autostart** were verified. Global Battery saver was not forced off in the final optimization pass; its later observed state changed during charging. Control, screen sharing, and audio were active again; long-term background reliability still needs testing.

The phone display is the main interaction surface: click to tap, drag to swipe, scroll to move supported Android content, and type into a focused field. Continuous scrolling keeps one held Android touch moving as Mac events arrive; the latest real Settings test passed and the user confirmed that control now responds well. The **Phone** menu contains Back/Home/Recents, volume, lock, paste, file transfer, screenshot, and fullscreen actions. Settings selects quality, supported playback audio, explicit clipboard sharing, and connection details. Files up to 32 MiB are saved under Android **Downloads / Redmi Mirroring**.

Audio capture and native Mac playback were verified with a 660 Hz tone. After buffering fixes, the user confirmed continuous, clean output; the final 30-second animation/audio test played 1,440,960 samples without additional queue resets. Source apps can prohibit audio capture. Pasting Unicode text from the Mac clipboard into a focused Android field passed. Phone-to-Mac clipboard sharing still needs physical verification, and continuous background Android clipboard reading is unavailable to an ordinary companion.

## Remote access

Configure an existing private VPN route or the included outbound TLS relay on infrastructure you explicitly control. Both devices must use the same relay host, port, certificate fingerprint, and random 256-bit room token. The phone's original authenticated TLS session remains encrypted inside the relay tunnel.

The implemented remote path is a TCP relay. Direct remote P2P negotiation, ICE/STUN/TURN, and a managed relay service are not included. No Internet relay endpoint, external account, or paid service has been provisioned, and separate-network operation remains untested. See [relay/README.md](relay/README.md). Never expose ADB publicly.

## Rebuild and validate

Run these commands from this project folder:

```sh
zsh scripts/build-macos.sh
bash android/build-apk.sh
zsh scripts/test-macos.sh
bash android/test-wire.sh
python3 relay/relay.py --self-test
```

macOS uses Swift Package Manager and Apple's frameworks, with no external Swift package dependency. Building requires compatible Xcode command-line tools/Swift. This Mac has arm64 macOS 27.0.1 and the Swift 6.4 toolchain; the package's minimum macOS version is 14.

Android uses the installed Android Studio JDK/Kotlin compiler, Android SDK `android-36.1`, build tools `36.0.0`, and compatible D8. The direct build avoids Gradle downloads. Its minimum Android version is 10/API29 and target is Android16/API36. Override the environment variables documented in [android/README.md](android/README.md) when using another SDK location. Build intermediates default to `.build-work/` and are excluded from Git. Set `REDMI_BUILD_WORK_DIR` to relocate them, and `REDMI_SIGNING_DIR` to reuse an existing Android development signing key. Keep that signing directory private and retain it for future APK updates; it is not included in the deliverables. Python 3.11+ and OpenSSL support relay fixture tests.

## Platform limits

On Android16, each new projection session requires system consent, and lock ends projection. This companion also stops capture when the phone screen turns off. It cannot bypass the lock screen, recover an expired permission silently, or restart capture after a force-stop/reboot. A short transport interruption can recover an existing projection, as tested. HyperOS background settings may require adjustment on the actual phone. [MediaProjection rules](https://developer.android.com/media/grow/media-projection), [foreground-service rules](https://developer.android.com/develop/background-work/services/fgs/service-types)

The real Redmi streamed at 720 × 1640 portrait and 1640 × 720 landscape. The current Responsive build also passed 560 × 1280 ↔ 1280 × 560 rotation with screen/control/audio active. Its 30-second test averaged 57.8 decoded fps with 1.14 ms median hardware decode, zero additional decoder drops, two display drops, and zero additional audio queue resets during that interval. Later diagnostics recorded additional drops, so uninterrupted zero-drop performance is not claimed. The latest input-to-decoded-feedback sets passed 12/12 trials: Balanced median 122.6 ms, Responsive median 109.1 ms with a 60 fps/4 Mb/s setting. The Balanced set included a first-trial 498.7 ms outlier of unknown cause. These are short software measurements; guaranteed 1080p60, glass-to-glass latency, long unattended use, Mac sleep/wake, and lock/reapproval remain unverified. Frame arrival also depends on how often Android content changes. The eight-second stalled-connection deadline and phone reconnect passed.

## License

Project source is licensed under MIT. Bundled dependency notices are in [THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt). Redmi Mirroring is independent and is not affiliated with Xiaomi, Google, or Apple.
