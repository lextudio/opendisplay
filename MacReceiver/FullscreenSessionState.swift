/// Controls the receiver's one-time fullscreen default for each sender session.
/// The controller starts the next session after its reconnect grace period, so
/// repeated window presentation within a session preserves the user's fullscreen
/// choice.
struct FullscreenSessionState {
    private var shouldAutoEnterFullscreen = true

    mutating func consumeAutoEnterFullscreen() -> Bool {
        guard shouldAutoEnterFullscreen else { return false }
        shouldAutoEnterFullscreen = false
        return true
    }

    mutating func beginNextSession() {
        shouldAutoEnterFullscreen = true
    }
}
