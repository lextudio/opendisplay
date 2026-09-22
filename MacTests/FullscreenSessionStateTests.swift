import XCTest

final class FullscreenSessionStateTests: XCTestCase {
    func testFirstWindowInSessionEntersFullscreen() {
        var state = FullscreenSessionState()

        XCTAssertTrue(state.consumeAutoEnterFullscreen())
    }

    func testReopeningWindowInSessionDoesNotReenterFullscreen() {
        var state = FullscreenSessionState()

        _ = state.consumeAutoEnterFullscreen()

        XCTAssertFalse(state.consumeAutoEnterFullscreen())
    }

    func testSessionAfterReconnectGraceRearmsFullscreen() {
        var state = FullscreenSessionState()
        _ = state.consumeAutoEnterFullscreen()

        state.beginNextSession()

        XCTAssertTrue(state.consumeAutoEnterFullscreen())
    }
}
