import Combine
import UIKit

/// Dims the receiver's display while the Mac host is asleep/locked, without
/// locking the device.
///
/// iOS gives an app no way to turn the screen off or lock the device, and a
/// locked/suspended app cannot be woken remotely — its sockets are gone, so the
/// host's reconnect would fail. The one lever that both saves power and keeps
/// the session reachable is the backlight: set brightness to 0 (the dominant
/// draw on an LCD) while staying foreground and listening, and paint the screen
/// black so nothing bright shows through. When the host comes back, the
/// reconnect (or an explicit `hostAwake`) restores the brightness.
///
/// The display is deliberately never handed back to auto-lock: a locked device
/// shows the system lock screen on wake and, worse, can no longer be reached by
/// the Mac — so the screen would stay dark until a manual touch instead of being
/// woken by the host. Staying dimmed keeps the session reachable.
@MainActor
final class ScreenDim: ObservableObject {
    static let shared = ScreenDim()

    /// True while the host is away. The UI paints black over everything in this
    /// state, so the (light) idle screen never shows.
    @Published private(set) var isDimmed = false

    private let savedBrightnessKey = "screenDim.savedBrightness"
    private let activeKey = "screenDim.active"

    /// Restore a dim left behind by a previous process (e.g. iOS killed us while
    /// the host was away), so the screen does not come up black forever.
    func restoreIfNeeded() {
        guard UserDefaults.standard.bool(forKey: activeKey) else { return }
        endDim(brightness: UserDefaults.standard.double(forKey: savedBrightnessKey))
    }

    /// `deepSleepAfter` is the Mac's display-sleep delay in seconds (nil when its
    /// display never sleeps). It is only logged: the display is deliberately
    /// never handed back to auto-lock, because a locked device cannot be woken by
    /// the Mac — dimming keeps the session reachable so the host's reconnect
    /// restores the screen.
    func dim(deepSleepAfter: TimeInterval? = nil) {
        guard !isDimmed else { return }
        isDimmed = true
        let saved = UIScreen.main.brightness
        UserDefaults.standard.set(Double(saved), forKey: savedBrightnessKey)
        UserDefaults.standard.set(true, forKey: activeKey)
        UIScreen.main.brightness = 0
        // Stay awake so the host's reconnect can restore the screen.
        UIApplication.shared.isIdleTimerDisabled = true
        let hint = deepSleepAfter.map { " (Mac display sleeps after \(Int($0))s)" } ?? ""
        Log.info("screen dim: host away — dimmed, staying reachable\(hint)")
    }

    func wake() {
        guard isDimmed else { return }
        endDim(brightness: UserDefaults.standard.double(forKey: savedBrightnessKey))
    }

    private func endDim(brightness: Double) {
        isDimmed = false
        UIApplication.shared.isIdleTimerDisabled = true
        // A stored 0 means "unknown" (first run); 0.5 is a safe, visible default.
        UIScreen.main.brightness = brightness > 0.01 ? CGFloat(min(brightness, 1)) : 0.5
        UserDefaults.standard.set(false, forKey: activeKey)
        Log.info("screen dim: host back — display restored")
    }
}
