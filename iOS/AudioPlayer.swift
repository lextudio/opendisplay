import AVFoundation

/// Plays forwarded system audio (PCM s16le, 48 kHz stereo) from the Mac host.
///
/// Uses `AVAudioEngine` + `AVAudioPlayerNode`. The node is connected with a
/// `nil` format so the engine picks the hardware's own layout — passing an
/// explicit format (int16 or interleaved float) makes `AVAudioEngine.connect`
/// raise `AVAE ... SetFormat` and abort. Its actual format is then read back and
/// the incoming s16le is converted to it with an `AVAudioConverter`.
///
/// Buffers are scheduled on a dedicated queue; a latency cap resets the player
/// when it falls too far behind (dropping stale audio beats drifting behind the
/// video). The session is activated on the first frame and deactivated when the
/// host goes away so the iPad's own audio comes back.
final class AudioPlayer {
    static let shared = AudioPlayer()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let wireFormat: AVAudioFormat? = AVAudioFormat(settings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 48_000.0,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ])
    private let queue = DispatchQueue(label: "audio.player")
    private var running = false
    private var attached = false
    private var playFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var scheduledFrames: AVAudioFramePosition = 0
    private var loggedFirst = false
    private var volume: Float = 1

    /// Feed one PCM s16le interleaved stereo frame. Safe from any queue.
    func play(_ pcm: Data) {
        queue.async { [weak self] in self?.enqueue(pcm) }
    }

    /// Playback gain (0…1) driven from the Mac's menu.
    func setVolume(_ value: Float) {
        queue.async { [weak self] in
            guard let self else { return }
            self.volume = min(max(value, 0), 1)
            self.player.volume = self.volume
            Log.info("audio: volume \(self.volume)")
        }
    }

    /// Stop and release the audio session (host gone / session ended).
    func stop() {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.running = false
            self.player.stop()
            self.engine.stop()
            self.scheduledFrames = 0
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            Log.info("audio: stopped")
        }
    }

    private func enqueue(_ pcm: Data) {
        if !loggedFirst {
            loggedFirst = true
            Log.info("audio: first frame received (\(pcm.count) bytes)")
        }
        let frames = pcm.count / 4          // stereo s16 = 4 bytes per frame
        guard frames > 0 else { return }
        if !running { start() }
        guard running, let wireFormat, let playFormat, let converter,
              let input = AVAudioPCMBuffer(pcmFormat: wireFormat,
                                           frameCapacity: AVAudioFrameCount(frames)),
              let source = input.int16ChannelData?[0] else { return }
        input.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: Int16.self).baseAddress else { return }
            source.update(from: base, count: frames * 2)
        }

        let ratio = playFormat.sampleRate / wireFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(frames) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, output.frameLength > 0 else { return }

        // Cap latency: if the player is more than ~0.4s behind, restart the
        // queue instead of letting audio drift further behind the video.
        if scheduledFrames - playedFrames() > AVAudioFramePosition(playFormat.sampleRate * 0.4) {
            player.stop()
            player.play()
            scheduledFrames = 0
        }
        player.scheduleBuffer(output, completionHandler: nil)
        scheduledFrames += AVAudioFramePosition(output.frameLength)
    }

    private func playedFrames() -> AVAudioFramePosition {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return 0 }
        return playerTime.sampleTime
    }

    private func start() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            if !attached {
                engine.attach(player)
                attached = true
            }
            // nil format: the engine chooses the node's output layout. Passing
            // one explicitly is what raised in AVAudioEngine.connect.
            engine.connect(player, to: engine.mainMixerNode, format: nil)
            engine.prepare()
            try engine.start()
            player.volume = volume
            player.play()

            playFormat = player.outputFormat(forBus: 0)
            if let wire = wireFormat, let play = playFormat {
                converter = AVAudioConverter(from: wire, to: play)
                Log.info("audio: started (\(Int(play.sampleRate))Hz x\(play.channelCount))")
            } else {
                Log.info("audio: started (no converter)")
            }
            scheduledFrames = 0
            running = true
        } catch {
            Log.info("audio: failed to start: \(error.localizedDescription)")
            running = false
        }
    }
}
