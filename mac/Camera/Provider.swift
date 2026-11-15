import Foundation
import CoreMediaIO
import IOKit.audio
import os

// A virtual camera with two streams:
//   source: what Zoom, Meet, FaceTime and other apps read
//   sink:   what the AndroMac app writes decoded phone-camera frames into
// Frames arriving on the sink are forwarded to the source unchanged.

private let frameDuration = CMTime(value: 1, timescale: 30)
private let log = Logger(subsystem: "app.andromac.camera", category: "extension")

final class CameraDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var source: CameraStreamSource!
    private var sink: CameraSinkSource!
    private var watchers = 0
    private var sinkRunning = false

    init(localizedName: String) {
        super.init()
        device = CMIOExtensionDevice(localizedName: localizedName,
                                     deviceID: UUID(uuidString: "6F2B7C1E-9A54-4E0B-8C3D-A1D0B5E7C001")!,
                                     legacyDeviceID: nil, source: self)
        var description: CMFormatDescription!
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                       width: 1280, height: 720, extensions: nil, formatDescriptionOut: &description)
        let format = CMIOExtensionStreamFormat(formatDescription: description, maxFrameDuration: frameDuration,
                                               minFrameDuration: frameDuration, validFrameDurations: nil)
        source = CameraStreamSource(localizedName: "AndroMac Camera Video",
                                    streamID: UUID(uuidString: "6F2B7C1E-9A54-4E0B-8C3D-A1D0B5E7C002")!,
                                    format: format, owner: self)
        sink = CameraSinkSource(localizedName: "AndroMac Camera Sink",
                                streamID: UUID(uuidString: "6F2B7C1E-9A54-4E0B-8C3D-A1D0B5E7C003")!,
                                format: format, owner: self)
        do {
            try device.addStream(source.stream) // order matters: the app expects the sink to be second
            try device.addStream(sink.stream)
        } catch {
            fatalError("Could not add streams: \(error.localizedDescription)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { p.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { p.model = "AndroMac Camera" }
        return p
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    func sourceStarted() { watchers += 1 }
    func sourceStopped() { watchers = max(0, watchers - 1) }

    func sinkStarted(client: CMIOExtensionClient) {
        sinkRunning = true
        consume(from: client)
    }

    func sinkStopped() { sinkRunning = false }

    private func consume(from client: CMIOExtensionClient) {
        guard sinkRunning else { return }
        sink.stream.consumeSampleBuffer(from: client) { buffer, sequence, _, _, _ in
            guard let buffer else {
                // Nothing queued yet. Check again shortly instead of spinning.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { self.consume(from: client) }
                return
            }
            let now = UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * Double(NSEC_PER_SEC))
            if self.watchers > 0 {
                self.source.stream.send(buffer, discontinuity: [], hostTimeInNanoseconds: now)
            }
            self.sink.stream.notifyScheduledOutputChanged(
                CMIOExtensionScheduledOutput(sequenceNumber: sequence, hostTimeInNanoseconds: now))
            self.consume(from: client)
        }
    }
}

final class CameraStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private unowned let owner: CameraDeviceSource

    init(localizedName: String, streamID: UUID, format: CMIOExtensionStreamFormat, owner: CameraDeviceSource) {
        self.format = format
        self.owner = owner
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID,
                                     direction: .source, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }
    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { p.frameDuration = frameDuration }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }
    func startStream() throws { owner.sourceStarted() }
    func stopStream() throws { owner.sourceStopped() }
}

final class CameraSinkSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private unowned let owner: CameraDeviceSource
    private var client: CMIOExtensionClient?

    init(localizedName: String, streamID: UUID, format: CMIOExtensionStreamFormat, owner: CameraDeviceSource) {
        self.format = format
        self.owner = owner
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID,
                                     direction: .sink, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }
    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { p.frameDuration = frameDuration }
        if properties.contains(.streamSinkBufferQueueSize) { p.sinkBufferQueueSize = 1 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { p.sinkBuffersRequiredForStartup = 1 }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws {
        guard let client else { log.error("sink started without a client"); return }
        owner.sinkStarted(client: client)
    }

    func stopStream() throws { owner.sinkStopped() }
}

final class CameraProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: CameraDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = CameraDeviceSource(localizedName: "AndroMac Camera")
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Could not add device: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let p = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { p.manufacturer = "AndroMac" }
        return p
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
