import Foundation
import CoreGraphics

/// A mode the display can be in, in a form the enforcement loop can compare
/// against what macOS reports. `backingScale` 2 is a Retina grid (framebuffer =
/// points × 2); 1 is a non-Retina mode, where a point is a pixel — including the
/// low-resolution duplicates macOS synthesizes for the HiDPI modes.
struct ResolutionMode: Equatable {
    let pointsWide: Int
    let pointsHigh: Int
    let backingScale: Int

    var pixelWide: Int { pointsWide * backingScale }
    var pixelHigh: Int { pointsHigh * backingScale }
    var aspect: Double { pointsHigh > 0 ? Double(pointsWide) / Double(pointsHigh) : 0 }
    /// H.264 High@L5.2 single-frame macroblock budget — the same ceiling the
    /// encoder path enforces.
    var macroblocks: Int { ((pixelWide + 15) / 16) * ((pixelHigh + 15) / 16) }

    init(pointsWide: Int, pointsHigh: Int, backingScale: Int) {
        self.pointsWide = pointsWide
        self.pointsHigh = pointsHigh
        self.backingScale = backingScale
    }

    init(displayMode mode: CGDisplayMode) {
        let scale = mode.width > 0 ? Int((Double(mode.pixelWidth) / Double(mode.width)).rounded()) : 2
        self.init(pointsWide: mode.width, pointsHigh: mode.height, backingScale: max(1, scale))
    }

    /// "2224x1668x1" — persisted per device.
    var storageValue: String { "\(pointsWide)x\(pointsHigh)x\(backingScale)" }

    init?(storageValue: String) {
        let parts = storageValue.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 3, parts[0] > 0, parts[1] > 0, parts[2] > 0 else { return nil }
        self.init(pointsWide: parts[0], pointsHigh: parts[1], backingScale: parts[2])
    }
}

private let maxResolutionMacroblocks = 36_864

/// Retina point-grid scales published to System Settings → Displays. Index 0 is
/// native; the rest are progressively smaller point grids ("larger text"), each
/// still backed by a @2x framebuffer so text stays sharp. Deliberately no scales
/// above 1: macOS synthesizes a 1x duplicate of every published mode, so each
/// extra step would add a confusing non-Retina twin to the picker. The "biggest
/// desktop" is macOS's own 1x duplicate of the native mode, which needs no
/// publishing.
let resolutionSteps: [CGFloat] = [1.0, 0.85, 0.75, 0.67]

func nativeResolutionMode(pointsWide: Int, pointsHigh: Int) -> ResolutionMode {
    ResolutionMode(pointsWide: pointsWide, pointsHigh: pointsHigh, backingScale: 2)
}

/// Build the mode list handed to `CGVirtualDisplaySettings`. Pure (no I/O) so it
/// is unit-testable without a real display. Steps whose framebuffer would exceed
/// the H.264 frame budget are dropped.
func buildDisplayModes(pointsWide: Int, pointsHigh: Int) -> [CGVirtualDisplayMode] {
    resolutionSteps.compactMap { step in
        let mode = ResolutionMode(
            pointsWide: Int((CGFloat(pointsWide) * step).rounded(.toNearestOrEven)),
            pointsHigh: Int((CGFloat(pointsHigh) * step).rounded(.toNearestOrEven)),
            backingScale: 2)
        guard mode.macroblocks <= maxResolutionMacroblocks else { return nil }
        return CGVirtualDisplayMode(width: UInt(mode.pointsWide), height: UInt(mode.pointsHigh), refreshRate: 60)
    }
}

/// Whether a mode keeps the panel's aspect ratio. macOS's synthesized scaled
/// modes preserve it (0.6957 vs native 0.6949 for an iPad Air, per #158), while
/// a stale opposite-orientation restore inverts it (#29).
func keepsPanelAspect(_ mode: ResolutionMode, panelWide: Int, panelHigh: Int) -> Bool {
    guard panelHigh > 0, mode.pointsHigh > 0 else { return false }
    let panel = Double(panelWide) / Double(panelHigh)
    return abs(mode.aspect - panel) <= panel * 0.02
}

/// The runtime mode a `ResolutionMode` refers to, matched on both the point and
/// the pixel size so a 1x and its @2x twin are not confused.
func runtimeDisplayMode(_ modes: [CGDisplayMode], matching mode: ResolutionMode) -> CGDisplayMode? {
    modes.first { $0.width == UInt(mode.pointsWide) && $0.pixelWidth == UInt(mode.pixelWide) }
}

/// Decision for the lifetime mode-enforcement loop. That loop undoes macOS
/// asynchronously restoring a *stale* saved mode — the startup 1x default (#26)
/// or a wrong-orientation mode pillarboxing the framebuffer (#29). But any mode
/// the user picks that keeps the panel's aspect ratio must be LEFT ALONE (#9),
/// including the 1x "biggest desktop" and macOS's own synthesized resolutions.
/// So:
///   - not settled              → re-assert unless already on the persisted
///     target (the startup race)
///   - settled, aspect-correct  → leave it (user choice)
///   - settled, aspect-wrong    → only after `missingTicks` consecutive ticks
///     (debounce, so a transient wipe during a neighbour's reconfiguration heals
///     on its own, #29)
func shouldReassertMode(current: ResolutionMode, target: ResolutionMode,
                        panelWide: Int, panelHigh: Int,
                        settled: Bool, missingTicks: Int) -> Bool {
    if !settled { return current != target }
    if keepsPanelAspect(current, panelWide: panelWide, panelHigh: panelHigh) { return false }
    return missingTicks >= 3
}

/// Per-device resolution memory (#9 "persist per device"). Keyed by the same
/// install id used for arrangement (#116), so each physical device keeps its
/// chosen mode across sessions and transports.
enum ResolutionStore {
    private static func key(for device: String) -> String { "resolution.\(device)" }

    static func save(_ mode: ResolutionMode, device: String) {
        UserDefaults.standard.set(mode.storageValue, forKey: key(for: device))
    }

    static func load(device: String) -> ResolutionMode? {
        guard let raw = UserDefaults.standard.string(forKey: key(for: device)) else { return nil }
        return ResolutionMode(storageValue: raw)
    }
}

/// Wraps the private CGVirtualDisplay API: makes macOS believe a real monitor
/// is attached. Sized in points at HiDPI (@2x), so a phone with native pixels
/// W×H gets a virtual display of (W/2)×(H/2) points backed by a W×H framebuffer.
final class VirtualDisplay {

    // CGVirtualDisplay's descriptor ceiling is immutable even though its mode
    // list can be replaced. Keep defensive 8K headroom in addition to the
    // requested capacity supplied by the canvas plan.
    private static let reservedPixelsPerAxis = 8_192

    private let display: CGVirtualDisplay
    private var settings: CGVirtualDisplaySettings
    private let maxPointsPerAxis: Int
    private(set) var pointsWide: Int
    private(set) var pointsHigh: Int

    private var restoreTarget: CGPoint?
    private var restoreUntil: Date
    private var lastReportedOrigin: CGPoint?
    private let onOriginChange: ((CGPoint, CGSize) -> Void)?
    /// Install id, per #116/#26 — keys the per-device resolution memory so a
    /// chosen scaled mode is reapplied and persisted (#9).
    private let deviceKey: String?
    /// Consecutive enforcement ticks where a published @2x mode was absent.
    /// Drives the debounced recovery (`shouldReassertMode`), #29 point 2.
    private var missingTicks = 0

    var displayID: CGDirectDisplayID { display.displayID }

    /// Must be called on the main thread. `serialNum` must be unique per
    /// concurrent display AND stable per device — macOS keys saved display
    /// arrangement on vendor/product/serial, so a stable serial means each
    /// device keeps its position in System Settings across sessions.
    /// `restoreOrigin` overrides that saved arrangement (see manageOrigin);
    /// `onOriginChange` reports where the display sits afterwards, so the
    /// caller can persist user drags.
    /// `deviceKey` (install id, #116/#26) keys per-device resolution memory so
    /// a chosen scaled mode is reapplied and persisted (#9).
    init?(name: String, pointsWide: Int, pointsHigh: Int,
          descriptorMaxPixelsPerAxis: Int, sizeInMillimeters: CGSize,
          serialNum: UInt32 = 0x0001, productID: UInt32 = 0x4F53,
          restoreOrigin: CGPoint? = nil,
          onOriginChange: ((CGPoint, CGSize) -> Void)? = nil,
          deviceKey: String? = nil) {
        self.pointsWide = pointsWide
        self.pointsHigh = pointsHigh
        // Reserve the longer orientation on both axes. The fixed headroom also
        // covers later receiver scaling changes (for example Larger Text to
        // More Space) without destroying and recreating the virtual display.
        let initialPixelsPerAxis = max(pointsWide, pointsHigh) * 2
        let maximumPixelsPerAxis = max(initialPixelsPerAxis,
                                       descriptorMaxPixelsPerAxis,
                                       Self.reservedPixelsPerAxis)
        maxPointsPerAxis = (maximumPixelsPerAxis + 1) / 2
        self.restoreTarget = restoreOrigin
        self.restoreUntil = restoreOrigin == nil ? .distantPast : Date().addingTimeInterval(6)
        self.onOriginChange = onOriginChange
        self.deviceKey = deviceKey

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(maxPointsPerAxis * 2)
        descriptor.maxPixelsHigh = UInt32(maxPointsPerAxis * 2)
        descriptor.sizeInMillimeters = sizeInMillimeters
        descriptor.productID = productID   // base 0x4F53 "OS"; moves with the
                                           // serial when an identity is
                                           // abandoned (see MacSender)
        descriptor.vendorID = 0x5043       // "PC"
        descriptor.serialNum = serialNum
        descriptor.terminationHandler = { _, _ in
            Log.info("virtual display terminated by the system")
        }

        display = CGVirtualDisplay(descriptor: descriptor)

        settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        // Publish every scaled HiDPI step (#9) so System Settings → Displays
        // offers a resolution the user can actually pick and keep.
        settings.modes = buildDisplayModes(pointsWide: pointsWide, pointsHigh: pointsHigh)
        guard display.apply(settings) else {
            Log.info("CGVirtualDisplay applySettings FAILED")
            return nil
        }
        Log.info("virtual display created: id=\(display.displayID) \(pointsWide)x\(pointsHigh)pt @2x")

        // macOS defaults the new display to its 1x mode AND can restore a
        // stale saved mode for this serial asynchronously, seconds after the
        // display appears (observed: a display checked as @2x at creation
        // sitting at 1x later, and a rotated rebuild pillarboxed by the
        // previous orientation's mode). So mode selection is enforcement,
        // not a one-shot. But a user picking a scaled mode we published must
        // stick (#9), while macOS's async 1x/wrong-orientation relapses
        // (#26/#29) must still be undone — `enforceMode` discriminates.
        Task { @MainActor [weak self] in
            var settled = false
            while true {
                // Scoped strong ref: a rotation rebuild relies on release
                // removing the display — never hold it across the sleep.
                do {
                    guard let self else { return }
                    self.ensureNotMirrored()
                    if self.enforceMode(settled: settled) { settled = true }
                    self.manageOrigin()
                }
                try? await Task.sleep(for: .milliseconds(settled ? 2000 : 200))
            }
        }
    }

    /// Change orientation without changing the virtual monitor's identity.
    /// Releasing a CGVirtualDisplay makes WindowServer redistribute every
    /// window on it before the replacement appears; with multiple devices,
    /// it may choose a sibling virtual display. Applying a new mode avoids
    /// that reassignment entirely.
    ///
    /// Must be called on the main thread.
    @discardableResult
    func resize(pointsWide: Int, pointsHigh: Int, movingTo origin: CGPoint?) -> Bool {
        guard pointsWide <= maxPointsPerAxis, pointsHigh <= maxPointsPerAxis else {
            Log.info("virtual display \(display.displayID) cannot resize beyond its descriptor")
            return false
        }

        let newSettings = CGVirtualDisplaySettings()
        newSettings.hiDPI = 1
        newSettings.modes = buildDisplayModes(pointsWide: pointsWide, pointsHigh: pointsHigh)
        guard display.apply(newSettings) else {
            Log.info("virtual display \(display.displayID) applySettings FAILED during resize")
            return false
        }
        settings = newSettings
        self.pointsWide = pointsWide
        self.pointsHigh = pointsHigh
        // A new mode gets a fresh chance: refusals belonged to the old size.
        hidpiRefusals = 0
        hidpiRetryAfter = .distantPast
        missingTicks = 0

        if let origin {
            var config: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&config) == .success {
                CGConfigureDisplayOrigin(config, display.displayID, Int32(origin.x), Int32(origin.y))
                let err = CGCompleteDisplayConfiguration(config, .permanently)
                // A mode change is a display reconfiguration, so macOS may
                // restore ITS arrangement for this identity a moment later,
                // exactly as it does after creation. Re-arm the same window so
                // that gets overridden, and adopt whatever WindowServer settled
                // on: a snap is system state, and persisting it as if it were a
                // user drag is the ratchet #203 is about.
                let settled = CGDisplayBounds(display.displayID).origin
                restoreTarget = settled
                restoreUntil = Date().addingTimeInterval(6)
                lastReportedOrigin = settled
                Log.info("virtual display \(display.displayID) resized to \(pointsWide)x\(pointsHigh)pt "
                    + "at (\(Int(origin.x)),\(Int(origin.y))), settled "
                    + "(\(Int(settled.x)),\(Int(settled.y))) (result \(err.rawValue))")
            }
        } else {
            Log.info("virtual display \(display.displayID) resized to \(pointsWide)x\(pointsHigh)pt")
        }
        return true
    }

    /// Returns true when the display has settled (a mode is standing, or there
    /// is nothing left to try for now). Runs every 2s as enforcement.
    ///
    /// Enforcement undoes macOS asynchronously restoring a *stale* saved mode —
    /// a 1x/blurry relapse (#26) or a wrong-orientation mode pillarboxing the
    /// framebuffer (#29) — but a scaled mode the user picked from the list we
    /// published must be left alone (#9). `shouldReassertMode` is that
    /// discriminator; recovery is debounced (`missingTicks`) so a transient wipe
    /// during a neighbour display's reconfiguration heals on its own.
    ///
    /// macOS also lists but refuses some small @2x modes (a 750×1334 phone panel
    /// asks for 374×666pt and gets kCGErrorFailure every time; the display then
    /// runs at 1x). Without the back-off the settling loop would issue a failing
    /// permanent reconfiguration five times a second for the whole session and
    /// flood the log, which is what happened before this counter existed. After
    /// a few refusals we report it once, let the loop settle, and probe again
    /// only occasionally in case the mode list changes.
    @discardableResult
    private func enforceMode(settled: Bool) -> Bool {
        guard Date() >= hidpiRetryAfter else { return true }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let runtimeModes = CGDisplayCopyAllDisplayModes(display.displayID, opts) as? [CGDisplayMode] else {
            // Whole mode list gone. Before settling it is usually just not ready
            // yet, so republish quietly; afterwards treat it like a refusal.
            missingTicks += 1
            if settled { return republishAfterWipe() }
            _ = display.apply(settings)
            return false
        }
        guard let current = CGDisplayCopyDisplayMode(display.displayID) else { return false }

        let currentMode = ResolutionMode(displayMode: current)
        let native = nativeResolutionMode(pointsWide: pointsWide, pointsHigh: pointsHigh)
        let target = deviceKey.flatMap { ResolutionStore.load(device: $0) } ?? native

        if keepsPanelAspect(currentMode, panelWide: pointsWide, panelHigh: pointsHigh) {
            missingTicks = 0
            // Remember whatever the user landed on — Retina or not — so it
            // survives a reconnect.
            if let key = deviceKey { ResolutionStore.save(currentMode, device: key) }
        } else {
            missingTicks += 1
        }

        guard shouldReassertMode(current: currentMode, target: target,
                                 panelWide: pointsWide, panelHigh: pointsHigh,
                                 settled: settled, missingTicks: missingTicks) else {
            hidpiRefusals = 0   // a standing mode: forget past refusals
            return true
        }

        // Restore the persisted target, falling back to native when macOS no
        // longer offers it.
        let descriptor = runtimeDisplayMode(runtimeModes, matching: target) != nil ? target : native
        let label = "\(descriptor.pointsWide)x\(descriptor.pointsHigh)"
            + (descriptor.backingScale == 2 ? "@2x" : " @1x")
        guard let targetMode = runtimeDisplayMode(runtimeModes, matching: descriptor) else {
            Log.info("mode re-assert target \(label) not in the runtime list — republishing")
            _ = display.apply(settings)
            return false
        }

        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        CGConfigureDisplayWithDisplayMode(config, display.displayID, targetMode, nil)
        let err = CGCompleteDisplayConfiguration(config, .permanently)
        if err == .success {
            hidpiRefusals = 0
            missingTicks = 0
            Log.info("mode re-asserted: \(label) (result 0)")
            return true
        }
        hidpiRefusals += 1
        if hidpiRefusals < Self.hidpiRefusalsBeforeBackoff {
            Log.info("mode re-asserted: \(label) (result \(err.rawValue))")
            return false
        }
        if hidpiRefusals == Self.hidpiRefusalsBeforeBackoff {
            Log.info("macOS refused the \(label) mode "
                + "\(hidpiRefusals) times (result \(err.rawValue)) — leaving display "
                + "\(display.displayID) alone, probing again every \(Int(Self.hidpiRetryInterval))s")
        }
        hidpiRetryAfter = Date().addingTimeInterval(Self.hidpiRetryInterval)
        return true
    }

    /// Re-publish `settings` after the runtime mode list vanished, with the same
    /// back-off as a refusal so a list that stays gone does not get re-applied
    /// and logged every 2s for the display's lifetime.
    private func republishAfterWipe() -> Bool {
        hidpiRefusals += 1
        if hidpiRefusals <= Self.hidpiRefusalsBeforeBackoff {
            Log.info("@2x modes vanished from display \(display.displayID) — re-applying settings"
                + (hidpiRefusals == Self.hidpiRefusalsBeforeBackoff
                   ? " (probing again every \(Int(Self.hidpiRetryInterval))s from now)" : ""))
        }
        _ = display.apply(settings)
        if hidpiRefusals >= Self.hidpiRefusalsBeforeBackoff {
            hidpiRetryAfter = Date().addingTimeInterval(Self.hidpiRetryInterval)
            return true
        }
        return false
    }

    /// Consecutive `CGCompleteDisplayConfiguration` failures for the @2x mode.
    private var hidpiRefusals = 0
    /// While in the future, `enforceMode` does nothing and reports settled.
    private var hidpiRetryAfter = Date.distantPast
    private static let hidpiRefusalsBeforeBackoff = 5
    private static let hidpiRetryInterval: TimeInterval = 30

    /// Arrangement restore + observation (#116). For the first few seconds,
    /// assert `restoreTarget`: macOS restores ITS saved arrangement for this
    /// display identity asynchronously, seconds after creation, and that
    /// record is stale or default whenever the identity is fresh (rotation
    /// swaps the serial, transport switches change it) — the caller's
    /// device-keyed record must win. Afterwards, origin changes are the user
    /// rearranging: report them so the caller can persist the new spot.
    private func manageOrigin() {
        let id = display.displayID
        let origin = CGDisplayBounds(id).origin
        if let target = restoreTarget, Date() < restoreUntil {
            // Initial arrangement is system state, not a user drag. Mark it
            // observed so it cannot overwrite the saved device placement
            // when the restore window expires (#203).
            guard origin != target else {
                lastReportedOrigin = origin
                return
            }
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success else { return }
            CGConfigureDisplayOrigin(config, id, Int32(target.x), Int32(target.y))
            let err = CGCompleteDisplayConfiguration(config, .permanently)
            // WindowServer snaps the requested origin to the nearest valid
            // arrangement — adopt what it settled on, or every remaining
            // tick of the window would re-apply against the snap.
            restoreTarget = CGDisplayBounds(id).origin
            // A snap is also system state. Keep observing from the settled
            // point, but only a later origin change may be a user drag.
            lastReportedOrigin = restoreTarget
            Log.info("display \(id) origin (\(Int(origin.x)),\(Int(origin.y))) → restored "
                + "(\(Int(target.x)),\(Int(target.y))), settled "
                + "(\(Int(restoreTarget!.x)),\(Int(restoreTarget!.y))) (result \(err.rawValue))")
            return
        }
        if origin != lastReportedOrigin {
            lastReportedOrigin = origin
            onOriginChange?(origin, CGSize(width: pointsWide, height: pointsHigh))
        }
    }

    /// An extend-mode virtual display must never sit in a system mirror set.
    /// macOS can drop it there on its own — e.g. when it misclassifies the
    /// display as a TV, whose arrangement default is "Mirror Entire Screen"
    /// (issue #100) — and that arrangement is saved per vendor/product/serial,
    /// so a stable serial means it's restored every session and the device is
    /// stuck mirroring. Detaching is enforcement, not a one-shot: like the
    /// HiDPI mode, re-break it whenever macOS re-mirrors it. Mirror mode never
    /// builds a VirtualDisplay (it captures the main display instead), so a
    /// VirtualDisplay in a mirror set is always wrong — safe to always undo.
    private func ensureNotMirrored() {
        let id = display.displayID
        // boolean_t is Int32: CoreGraphics returns 1 for mirrored, 0 for not mirrored,
        // and -1 for unknown/unregistered display IDs. Checking `!= 0` treats missing
        // displays as mirrored (issue #142) — compare explicitly against 1.
        guard CGDisplayIsInMirrorSet(id) == 1 else { return }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        // Detach the virtual display itself (covers "macOS mirrors the VD onto
        // the main display")...
        CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay)
        // ...and any display currently mirroring the VD (covers the reporter's
        // arrangement: the device set as Main, with the built-in mirroring it).
        var n: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &n)
        var list = [CGDirectDisplayID](repeating: 0, count: Int(n))
        CGGetActiveDisplayList(n, &list, &n)
        for other in list where other != id && CGDisplayMirrorsDisplay(other) == id {
            CGConfigureDisplayMirrorOfDisplay(config, other, kCGNullDirectDisplay)
        }
        // Session scope, NOT permanent: permanent mirror reconfiguration of the
        // private virtual display is rejected (kCGErrorIllegalArgument) and
        // silently leaves it mirrored despite a "success" from the mirror call.
        // Session scope actually dissolves the set, and this runs every ~2s for
        // the display's lifetime, so it re-overrides whatever mirror arrangement
        // macOS restores — continuous enforcement, like the HiDPI mode above.
        let err = CGCompleteDisplayConfiguration(config, .forSession)
        Log.info("virtual display \(id) was in a mirror set — detached to extend (result \(err.rawValue))")
    }
}
