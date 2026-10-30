import Foundation
import AVFoundation
import UIKit

/// Keeps the FlClash main app process alive in the background when running under a
/// Personal Free Apple ID (where NEPacketTunnelProvider is unavailable).
final class BackgroundKeepAliveManager {
    private var audioPlayer: AVAudioPlayer?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var isActive = false

    func startKeepAlive() {
        guard !isActive else { return }
        isActive = true

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)

            let wavData = Self.makeSilentWavData()
            let player = try AVAudioPlayer(data: wavData, fileTypeHint: AVFileType.wav.rawValue)
            player.numberOfLoops = -1
            player.volume = 0.0
            player.prepareToPlay()
            player.play()
            self.audioPlayer = player
        } catch {
            // Audio session optional fallback
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    func stopKeepAlive() {
        guard isActive else { return }
        isActive = false
        audioPlayer?.stop()
        audioPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        endBackgroundTask()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func onEnterBackground() {
        guard isActive else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "FlClashCoreKeepAlive") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    /// Synthesizes a valid 1-second 8kHz mono 16-bit PCM silent WAV in memory (no external asset needed).
    private static func makeSilentWavData() -> Data {
        let sampleRate: UInt32 = 8000
        let numSamples: UInt32 = 8000
        let dataSize: UInt32 = numSamples * 2
        let fileSize: UInt32 = 36 + dataSize

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        data.append("WAVEfmt ".data(using: .ascii)!)
        let fmtChunkSize: UInt32 = 16
        let audioFormat: UInt16 = 1
        let numChannels: UInt16 = 1
        let byteRate: UInt32 = sampleRate * 2
        let blockAlign: UInt16 = 2
        let bitsPerSample: UInt16 = 16
        data.append(withUnsafeBytes(of: fmtChunkSize.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: audioFormat.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: numChannels.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
        data.append("data".data(using: .ascii)!)
        data.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        data.append(Data(count: Int(dataSize)))
        return data
    }
}
