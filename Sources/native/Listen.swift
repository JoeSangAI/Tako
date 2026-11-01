// Listening to a class: the sound of the one app it is stuck to, cut into short pieces for listen_worker.py to turn
// into words on this Mac, in whatever language is being spoken. A piece is deleted once it has been read; nothing leaves the machine.
// It starts only when the owner says so and stops when they say so or peels it off.
import AVFoundation
import Foundation
import ScreenCaptureKit

final class Listener: NSObject, SCStreamOutput, SCStreamDelegate {
    private static let rate = 16000
    private let queue = DispatchQueue(label: "tako.listen")
    private let folder: URL
    private var stream: SCStream?
    private var samples: [Float] = []
    private var pieces = 0
    private let onPiece: (String) -> Void
    private let onEnd: (String) -> Void

    init(folder: URL, onPiece: @escaping (String) -> Void, onEnd: @escaping (String) -> Void) {
        self.folder = folder
        self.onPiece = onPiece
        self.onEnd = onEnd
    }

    func start(pid: pid_t) async -> String? {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let app = content.applications.first(where: { $0.processID == pid }), let display = content.displays.first else { return "找不到这个应用的声音" }
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = Listener.rate
            config.channelCount = 1
            // The stream has to have a picture; this one costs next to nothing and nobody reads it.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let stream = SCStream(filter: SCContentFilter(display: display, including: [app], exceptingWindows: []), configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await stream.startCapture()
            self.stream = stream
            return nil
        } catch {
            return "没能开始听：\(error.localizedDescription)"
        }
    }

    func stop() {
        stream?.stopCapture(completionHandler: nil)
        stream = nil
        queue.async { [self] in cut(at: samples.count) }
    }

    /// Hands over what has been heard so far. Cutting in a pause keeps a word from being split between two pieces.
    private func cut(at end: Int) {
        guard end > Listener.rate else { samples.removeAll(); return }
        pieces += 1
        let file = folder.appendingPathComponent("\(UUID().uuidString).f32")
        let data = samples[..<end].withUnsafeBufferPointer { Data(buffer: $0) }
        samples.removeFirst(end)
        if (try? data.write(to: file, options: .atomic)) != nil { onPiece(file.path) }
    }

    private func quietestPoint(from: Int, to: Int) -> Int {
        let frame = Listener.rate / 10
        var best = to, lowest = Float.infinity, at = from
        while at + frame <= to {
            let energy = samples[at..<(at + frame)].reduce(0) { $0 + $1 * $1 }
            if energy < lowest { lowest = energy; best = at + frame / 2 }
            at += frame
        }
        return best
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sample.isValid, self.stream != nil, let buffer = Listener.pcm(sample), let channel = buffer.floatChannelData?[0] else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        if samples.count >= Listener.rate * 32 { cut(at: quietestPoint(from: Listener.rate * 24, to: Listener.rate * 32)) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        queue.async { [self] in cut(at: samples.count) }
        onEnd("声音采集断了：\(error.localizedDescription)")
    }

    private static func pcm(_ sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sample.formatDescription, let basic = description.audioStreamBasicDescription else { return nil }
        var stream = basic
        guard let format = AVAudioFormat(streamDescription: &stream) else { return nil }
        let frames = AVAudioFrameCount(sample.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else { return nil }
        return buffer
    }
}

extension Controller {
    /// The sound of a window's app, from now until told to stop. Calls and meetings are not its to listen to.
    @MainActor
    func startListening(_ win: Win) async -> [String: Any] {
        if listener != nil { return ["ok": true, "title": win.title, "already": true] }
        let lowered = (win.app + " " + win.bundle).lowercased()
        if messagingNames.contains(where: { lowered.contains($0) }) || ["腾讯会议", "wemeet", "zoom", "teams", "在场"].contains(where: { lowered.contains($0) }) {
            return ["ok": false, "refused": true, "error": "\(win.app) 是聊天或会议软件，Tako 不听通话和会议"]
        }
        let folder = takoHome.appendingPathComponent("listening")
        let ear = Listener(folder: folder, onPiece: { [weak self] path in
            self?.post(path: "/listen/piece", body: ["path": path])
        }, onEnd: { [weak self] why in
            DispatchQueue.main.async { self?.listener = nil }
            self?.post(path: "/listen/ended", body: ["why": why])
        })
        if let problem = await ear.start(pid: win.pid) { return ["ok": false, "error": problem] }
        listener = ear
        log("listening to \(win.bundle)")
        return ["ok": true, "title": win.title, "app": win.app]
    }

    @MainActor
    func stopListening() {
        listener?.stop()
        listener = nil
    }
}
