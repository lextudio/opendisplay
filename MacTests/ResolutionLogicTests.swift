import CoreGraphics
import XCTest

/// The resolution enforcement decision is pure, so it is testable without a real
/// display. It must undo macOS's stale 1x/wrong-orientation restores (#26/#29)
/// while leaving any aspect-correct mode the user picks alone (#9) — including
/// the 1x "biggest desktop" and macOS's own synthesized resolutions.
final class ResolutionLogicTests: XCTestCase {
    private let panelWide = 1_112
    private let panelHigh = 834

    private var native: ResolutionMode { nativeResolutionMode(pointsWide: panelWide, pointsHigh: panelHigh) }

    func testBuildDisplayModesPublishesNativeFirstAtRetinaScale() {
        let modes = buildDisplayModes(pointsWide: panelWide, pointsHigh: panelHigh)
        XCTAssertEqual(modes.count, resolutionSteps.count)
        XCTAssertEqual(Int(modes[0].width), panelWide)
        XCTAssertEqual(Int(modes[0].height), panelHigh)
        // Never publish above native: macOS adds a 1x duplicate of each mode.
        for mode in modes {
            XCTAssertLessThanOrEqual(Int(mode.width), panelWide)
        }
    }

    func testKeepsPanelAspect() {
        XCTAssertTrue(keepsPanelAspect(native, panelWide: panelWide, panelHigh: panelHigh))
        // macOS's synthesized 1x resolutions preserve the ratio.
        XCTAssertTrue(keepsPanelAspect(ResolutionMode(pointsWide: 1_280, pointsHigh: 960, backingScale: 1),
                                       panelWide: panelWide, panelHigh: panelHigh))
        // The 1x "biggest desktop" is the panel's pixel grid: also the right ratio.
        XCTAssertTrue(keepsPanelAspect(ResolutionMode(pointsWide: 2_224, pointsHigh: 1_668, backingScale: 1),
                                       panelWide: panelWide, panelHigh: panelHigh))
        // A stale opposite-orientation restore inverts the ratio (#29).
        XCTAssertFalse(keepsPanelAspect(ResolutionMode(pointsWide: 834, pointsHigh: 1_112, backingScale: 2),
                                        panelWide: panelWide, panelHigh: panelHigh))
    }

    func testStartupCorrectsTheDefault1xBackToThePersistedTarget() {
        let oneX = ResolutionMode(pointsWide: 2_224, pointsHigh: 1_668, backingScale: 1)
        XCTAssertTrue(shouldReassertMode(current: oneX, target: native,
                                         panelWide: panelWide, panelHigh: panelHigh,
                                         settled: false, missingTicks: 0))
    }

    func testStartupAcceptsThePersistedTargetImmediately() {
        XCTAssertFalse(shouldReassertMode(current: native, target: native,
                                          panelWide: panelWide, panelHigh: panelHigh,
                                          settled: false, missingTicks: 0))
    }

    func testUserPicked1xDesktopIsLeftAloneOnceSettled() {
        // The regression this fixes: picking the low-resolution 2224×1668 mode
        // used to look like the 1x relapse #26 and get bounced back in ~2s.
        let oneX = ResolutionMode(pointsWide: 2_224, pointsHigh: 1_668, backingScale: 1)
        XCTAssertFalse(shouldReassertMode(current: oneX, target: native,
                                          panelWide: panelWide, panelHigh: panelHigh,
                                          settled: true, missingTicks: 0))
    }

    func testMacOSSynthesizedModeIsAcceptedOnceSettled() {
        let synthesized = ResolutionMode(pointsWide: 1_280, pointsHigh: 960, backingScale: 1)
        XCTAssertFalse(shouldReassertMode(current: synthesized, target: native,
                                          panelWide: panelWide, panelHigh: panelHigh,
                                          settled: true, missingTicks: 0))
    }

    func testWrongOrientationModeIsRecoveredOnlyAfterDebounce() {
        let stale = ResolutionMode(pointsWide: 834, pointsHigh: 1_112, backingScale: 2)
        XCTAssertFalse(shouldReassertMode(current: stale, target: native,
                                          panelWide: panelWide, panelHigh: panelHigh,
                                          settled: true, missingTicks: 1))
        XCTAssertTrue(shouldReassertMode(current: stale, target: native,
                                         panelWide: panelWide, panelHigh: panelHigh,
                                         settled: true, missingTicks: 3))
    }

    func testResolutionStoreRoundTripsAnyModePerDevice() {
        let device = "test-device-\(UUID().uuidString)"
        XCTAssertNil(ResolutionStore.load(device: device))
        let chosen = ResolutionMode(pointsWide: 1_280, pointsHigh: 960, backingScale: 1)
        ResolutionStore.save(chosen, device: device)
        XCTAssertEqual(ResolutionStore.load(device: device), chosen)
        XCTAssertNil(ResolutionStore.load(device: "other-\(device)"))
    }
}
