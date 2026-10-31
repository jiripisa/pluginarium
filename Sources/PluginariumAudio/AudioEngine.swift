import AVFoundation
import CRenderCore
import Foundation
import Observation
import PluginariumCore
import os

private let logger = Logger(subsystem: "io.jp4.pluginarium", category: "engine")

public enum EngineState: Equatable, Sendable {
    case stopped
    case running(AudioDevice)
    /// The UID of the device that cannot be used, which is empty when the default output was
    /// wanted and there is none. A device that will not stop reports this too.
    case deviceMissing(String)
}

public enum AudioEngineError: Error {
    case unsupportedSettings(sampleRate: Double, bufferFrames: Int)
    case noOutputChannels(String)
    case deviceUnavailable(String)
    case osStatus(OSStatus, String)
}

extension AudioEngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedSettings(let sampleRate, let bufferFrames):
            "The engine cannot run at \(sampleRate) Hz with a buffer of \(bufferFrames) frames."
        case .noOutputChannels(let name):
            "\(name) has no output channels."
        case .deviceUnavailable(let name):
            "\(name) cannot be reached."
        case .osStatus(let status, let operation):
            "\(operation) failed with error \(status)."
        }
    }
}

/// Runs the render core on one audio device. One `PREngine` lives as long as this object, whichever
/// device it plays on.
///
/// While `start` lets a device run, the render core is marked running, so a replaced plugin waits for
/// a render instead of being disposed under one. The mark comes off only once the device has fully
/// stopped. When a stream will not stop in time it stays on, and plugins leak instead of crashing.
@MainActor
@Observable
public final class AudioEngine {

    /// What the engine calls outside itself, so a test can run it without a device or a prompt.
    struct Seams {
        var open: @MainActor (StreamRequest, OpaquePointer) throws -> any DeviceStream = { try HALStream.open($0, engine: $1) }
        var defaultOutput: @MainActor () -> AudioDevice? = DeviceCatalog.defaultOutput
        var microphoneStatus: @MainActor () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) }
        var requestMicrophone: @MainActor (@escaping @Sendable (Bool) -> Void) -> Void = {
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: $0)
        }
    }

    /// The largest block the render core takes, and the `maxFrames` of `renderEngine`.
    public nonisolated static let maxFrames: UInt32 = 4096

    public private(set) var state: EngineState = .stopped {
        didSet {
            if state != oldValue { onDeviceChange?() }
        }
    }

    /// True when the device has inputs and the microphone permission is denied. Its input channels
    /// then read as silence.
    public private(set) var inputPermissionDenied = false

    /// Called on the main actor after `state` changes, when channel counts may have changed. It can
    /// call `stop` or `start`.
    @ObservationIgnored public var onDeviceChange: (() -> Void)?

    public nonisolated(unsafe) let renderEngine: OpaquePointer

    public var dspLoad: Double { pr_engine_load(renderEngine) }

    @ObservationIgnored var seams = Seams()

    @ObservationIgnored private let devices: () -> [AudioDevice]
    @ObservationIgnored private var deviceListener: DeviceListListener?
    /// Stays set when a stream will not stop, so nothing starts while it can still render.
    @ObservationIgnored private var stream: (any DeviceStream)?
    /// What to go back to when a device returns. Nil once stopped.
    @ObservationIgnored private var lastSettings: AppSettings?

    public init(devices: @escaping () -> [AudioDevice] = DeviceCatalog.all) {
        guard let renderEngine = pr_engine_create(Self.maxFrames, AppSettings.defaults.sampleRate) else {
            fatalError("Not enough memory for the render engine")
        }
        self.renderEngine = renderEngine
        self.devices = devices
        deviceListener = DeviceListListener { [weak self] in self?.handleDeviceChange() }
    }

    deinit {
        deviceListener?.remove()
        // A render may still be inside the engine then, so it has to outlive this object.
        if let stream, !stream.stop() { return }
        pr_engine_destroy(renderEngine)
    }

    /// Plays on the device in `settings`, or on the default output when it names none, replacing
    /// what runs now. A device that is not there is not an error: `state` becomes `.deviceMissing`,
    /// and the device starts when it returns. Throws without touching what runs when the render
    /// core cannot take the settings, and with `state` at `.stopped` when the device fails.
    public func start(settings: AppSettings) throws {
        guard settings.sampleRate > 0, (1...Int(Self.maxFrames)).contains(settings.bufferFrames) else {
            throw AudioEngineError.unsupportedSettings(sampleRate: settings.sampleRate, bufferFrames: settings.bufferFrames)
        }
        lastSettings = settings
        do {
            try run(settings)
        } catch {
            state = .stopped
            throw error
        }
    }

    /// Stops audio, and forgets the device, so its return starts nothing. When the device will not
    /// stop, `state` becomes `.deviceMissing`.
    public func stop() {
        lastSettings = nil
        if stopStream() {
            state = .stopped
        } else if case .running(let device) = state {
            state = .deviceMissing(device.id)
        }
    }

    /// Follows the system's device list: stops a device that left, and restarts one that came back
    /// or whose channels changed. A wanted default output moves to the system's new default.
    public func handleDeviceChange() {
        guard let lastSettings else { return }
        switch state {
        case .stopped:
            return
        case .running(let device):
            if devices().first(where: { $0.id == device.id }) != device { restart(lastSettings) }
        case .deviceMissing:
            let wanted = wantedUID(lastSettings)
            if devices().contains(where: { $0.id == wanted }) { restart(lastSettings) }
        }
    }

    // MARK: - Private

    private func wantedUID(_ settings: AppSettings) -> String {
        settings.audioDeviceUID ?? seams.defaultOutput()?.id ?? ""
    }

    private func restart(_ settings: AppSettings) {
        do {
            try run(settings)
        } catch {
            logger.error("Cannot restart the device: \(error.localizedDescription, privacy: .public)")
            state = .deviceMissing(wantedUID(settings))
        }
    }

    private func run(_ settings: AppSettings) throws {
        let wanted = wantedUID(settings)
        guard stopStream(), let device = devices().first(where: { $0.id == wanted }) else {
            state = .deviceMissing(wanted)
            return
        }
        guard !device.outputChannels.isEmpty else { throw AudioEngineError.noOutputChannels(device.name) }

        let request = StreamRequest(
            device: device,
            settings: DeviceSettings(sampleRate: settings.sampleRate, bufferFrames: UInt32(settings.bufferFrames)),
            usesInput: canUseInput(of: device)
        )
        pr_engine_set_sample_rate(renderEngine, settings.sampleRate)
        let opened = try seams.open(request, renderEngine)

        // Before the first render, which can come any time after the stream starts.
        pr_engine_set_audio_running(renderEngine, true)
        stream = opened
        do {
            try opened.start()
        } catch {
            guard stopStream() else {
                state = .deviceMissing(wanted)
                return
            }
            throw error
        }
        state = .running(device)
    }

    /// True when nothing can render any more.
    @discardableResult
    private func stopStream() -> Bool {
        guard let stream else { return true }
        guard stream.stop() else {
            logger.error("The audio device did not stop in time")
            return false
        }
        self.stream = nil
        pr_engine_set_audio_running(renderEngine, false)
        return true
    }

    /// Input stays off until the permission is granted, and an unanswered permission is asked for
    /// while output already plays. The answer restarts the device with its input.
    private func canUseInput(of device: AudioDevice) -> Bool {
        guard !device.inputChannels.isEmpty else {
            inputPermissionDenied = false
            return false
        }
        switch seams.microphoneStatus() {
        case .authorized:
            inputPermissionDenied = false
            return true
        case .notDetermined:
            inputPermissionDenied = false
            seams.requestMicrophone { [weak self] granted in
                Task { @MainActor in self?.microphoneAnswered(granted) }
            }
            return false
        default:
            inputPermissionDenied = true
            return false
        }
    }

    private func microphoneAnswered(_ granted: Bool) {
        inputPermissionDenied = !granted
        guard granted, case .running(let device) = state, !device.inputChannels.isEmpty, let lastSettings else { return }
        restart(lastSettings)
    }
}
