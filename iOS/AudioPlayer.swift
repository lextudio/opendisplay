import AVFoundation
import AudioToolbox

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

    // Forwarded-audio codec, announced by the host just before the first frame.
    // `pcm_s16le` is the default so a host that never announces stays working.
    private var codec = "pcm_s16le"
    private var aacConverter: AudioConverterRef?
    private var aacCookie: Data?
    private var aacSourceRate: Double = 48_000
    private var aacChannels: UInt32 = 2

    /// One AAC access unit handed to `AudioConverterFillComplexBuffer` through
    /// its user-data pointer (a C callback cannot capture context). The packet
    /// description is required: AAC is variable-rate, so the decoder cannot
    /// infer the access unit's size from the buffer alone.
    private struct AACInput {
        var data: UnsafeRawPointer
        var size: UInt32
        var channels: UInt32
        var consumed: Bool
        var descriptionPtr: UnsafeMutablePointer<AudioStreamPacketDescription>?
    }

    private static let aacInputProc: AudioConverterComplexInputDataProc = {
        _, ioNumberDataPackets, ioData, outDescription, inUserData in
        guard let inUserData else { ioNumberDataPackets.pointee = 0; return noErr }
        let input = inUserData.assumingMemoryBound(to: AACInput.self)
        guard !input.pointee.consumed else {
            ioNumberDataPackets.pointee = 0
            return noErr
        }
        input.pointee.consumed = true
        ioNumberDataPackets.pointee = 1
        let list = UnsafeMutableAudioBufferListPointer(ioData)
        list[0].mNumberChannels = input.pointee.channels
        list[0].mDataByteSize = input.pointee.size
        list[0].mData = UnsafeMutableRawPointer(mutating: input.pointee.data)
        if let descriptionPtr = input.pointee.descriptionPtr, let outDescription {
            outDescription.pointee = descriptionPtr
        }
        return noErr
    }

    /// Set the wire codec for forwarded audio. Safe from any queue.
    func configure(codec: String, sampleRate: Int, channels: Int, cookie: Data?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.codec = codec
            self.aacSourceRate = Double(sampleRate)
            self.aacChannels = UInt32(max(1, channels))
            self.aacCookie = cookie
            if let converter = self.aacConverter {
                AudioConverterDispose(converter)
                self.aacConverter = nil
            }
            Log.info("audio: codec \(codec) \(sampleRate)Hz x\(channels)"
                + (cookie.map { " cookie=\($0.count)B" } ?? ""))
        }
    }

    /// Feed one forwarded-audio frame (PCM s16le or one AAC access unit,
    /// depending on the last `configure`). Safe from any queue.
    func play(_ data: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.codec == "aac" {
                self.decodeAAC(data)
            } else {
                self.enqueue(data)
            }
        }
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

    /// Lazily build the AAC -> s16le converter from the host's magic cookie.
    /// The wire carries raw access units (the length prefix frames them), so
    /// the cookie is the only out-of-band configuration the decoder needs.
    private func ensureAACConverter() -> Bool {
        if aacConverter != nil { return true }
        var source = AudioStreamBasicDescription(
            mSampleRate: aacSourceRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 2,   // kMPEG4Object_AAC_LC (not exposed to Swift)
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: aacChannels,
            mBitsPerChannel: 0,
            mReserved: 0)
        var destination = AudioStreamBasicDescription(
            mSampleRate: aacSourceRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2 * aacChannels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2 * aacChannels,
            mChannelsPerFrame: aacChannels,
            mBitsPerChannel: 16,
            mReserved: 0)
        var converter: AudioConverterRef?
        guard AudioConverterNew(&source, &destination, &converter) == noErr,
              let converter else {
            Log.info("audio: AAC decoder unavailable")
            return false
        }
        if let cookie = aacCookie, !cookie.isEmpty {
            var bytes = [UInt8](cookie)
            let status = AudioConverterSetProperty(converter,
                                                   kAudioConverterDecompressionMagicCookie,
                                                   UInt32(bytes.count), &bytes)
            if status != noErr { Log.info("audio: AAC cookie rejected (\(status))") }
        }
        aacConverter = converter
        return true
    }

    /// Decode one AAC access unit to s16le and hand it to the PCM path.
    private func decodeAAC(_ frame: Data) {
        guard ensureAACConverter(), let converter = aacConverter else { return }
        let maxFrames = 1024
        var pcm = Data()
        frame.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var description = AudioStreamPacketDescription(
                mStartOffset: 0, mVariableFramesInPacket: 1024,
                mDataByteSize: UInt32(frame.count))
            var outputFrames = UInt32(maxFrames)
            var samples = [Int16](repeating: 0, count: maxFrames * Int(aacChannels))
            withUnsafeMutablePointer(to: &description) { descriptionPtr in
                var input = AACInput(data: base, size: UInt32(frame.count),
                                     channels: aacChannels, consumed: false,
                                     descriptionPtr: descriptionPtr)
                samples.withUnsafeMutableBytes { outRaw in
                    var list = AudioBufferList(
                        mNumberBuffers: 1,
                        mBuffers: AudioBuffer(
                            mNumberChannels: aacChannels,
                            mDataByteSize: UInt32(outRaw.count),
                            mData: outRaw.baseAddress))
                    let status = withUnsafeMutablePointer(to: &input) { inputPtr in
                        AudioConverterFillComplexBuffer(converter, Self.aacInputProc, inputPtr,
                                                        &outputFrames, &list, nil)
                    }
                    if status == noErr, outputFrames > 0, let base = outRaw.baseAddress {
                        pcm = Data(bytes: base, count: Int(outputFrames) * 2 * Int(aacChannels))
                    } else if status != noErr {
                        Log.info("audio: AAC decode failed (\(status))")
                    }
                }
            }
        }
        if !pcm.isEmpty { enqueue(pcm) }
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
