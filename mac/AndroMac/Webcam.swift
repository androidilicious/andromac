import Foundation
import AVFoundation
import CoreMedia
import CoreMediaIO
import SystemExtensions
import VideoToolbox

let virtualCameraName = "AndroMac Camera"
private let cameraExtensionID = "app.andromac.AndroMac.Camera"

/// Decodes H.264 samples into 1280x720 BGRA pixel buffers, the format the camera extension advertises.
final class H264Decoder {
    private var session: VTDecompressionSession?
    var onFrame: ((CVPixelBuffer) -> Void)?

    func decode(_ sample: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return }
        if session == nil || !VTDecompressionSessionCanAcceptFormatDescription(session!, formatDescription: format) {
            if let old = session { VTDecompressionSessionInvalidate(old) }
            session = nil
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: 1280,
                kCVPixelBufferHeightKey: 720,
                kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
            ]
            VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
                                         decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary,
                                         outputCallback: nil, decompressionSessionOut: &session)
        }
        guard let session else { return }
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { _, _, image, _, _ in
            if let image { self.onFrame?(image) }
        }
    }

    func reset() {
        if let s = session { VTDecompressionSessionInvalidate(s) }
        session = nil
    }
}

/// Writes pixel buffers into the camera extension's sink stream using the CoreMediaIO C API.
final class SinkWriter {
    private var device: CMIODeviceID = 0
    private var stream: CMIOStreamID = 0
    private var queue: CMSimpleQueue?

    private func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private func ids(of object: CMIOObjectID, _ selector: Int) -> [CMIOObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == 0, size > 0 else { return [] }
        var out = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &out) == 0 else { return [] }
        return out
    }

    private func name(of object: CMIOObjectID) -> String {
        var addr = address(kCMIOObjectPropertyName)
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &value) == 0, let value else { return "" }
        return value.takeRetainedValue() as String
    }

    /// Finds the virtual camera and opens its sink stream. Returns false if the extension is not installed.
    func connect() -> Bool {
        let devices = ids(of: CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices)
        guard let d = devices.first(where: { name(of: $0) == virtualCameraName }) else { return false }
        let streams = ids(of: d, kCMIODevicePropertyStreams)
        // The extension publishes two streams: the camera output first, then the sink we write into.
        guard streams.count >= 2 else { return false }
        device = d
        stream = streams[1]
        var q: Unmanaged<CMSimpleQueue>?
        guard CMIOStreamCopyBufferQueue(stream, { _, _, _ in }, nil, &q) == 0, let q else { return false }
        queue = q.takeRetainedValue()
        return CMIODeviceStartStream(device, stream) == 0
    }

    func disconnect() {
        if device != 0 { CMIODeviceStopStream(device, stream) }
        device = 0
        stream = 0
        queue = nil
    }

    func write(_ image: CVPixelBuffer) {
        guard let queue else { return }
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
                                                 formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample, CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else { return }
        CMSimpleQueueEnqueue(queue, element: Unmanaged.passRetained(sample).toOpaque())
    }
}

/// Installs the camera extension and pipes the phone camera feed into it.
final class Webcam: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published var status = "Virtual camera not active"
    @Published var feeding = false
    private let decoder = H264Decoder()
    private let sink = SinkWriter()

    func install() {
        let r = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: cameraExtensionID, queue: .main)
        r.delegate = self
        OSSystemExtensionManager.shared.submitRequest(r)
        status = "Requesting installation"
    }

    func start(feed: H264Feed) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                guard granted else { self.status = "Camera permission denied for AndroMac"; return }
                guard self.sink.connect() else {
                    self.status = "Virtual camera not found. Install it first, then try again."
                    return
                }
                self.decoder.onFrame = { image in self.sink.write(image) }
                feed.addSink("webcam") { sample in self.decoder.decode(sample) }
                Link.shared.requestKeyframe()
                self.feeding = true
                self.status = "Feeding \(virtualCameraName). Pick it as the camera in Zoom, Meet or FaceTime."
            }
        }
    }

    func stop(feed: H264Feed) {
        feed.removeSink("webcam")
        decoder.reset()
        sink.disconnect()
        feeding = false
        status = "Virtual camera not active"
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        status = "Approve AndroMac Camera in System Settings > General > Login Items & Extensions"
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        status = result == .completed ? "Virtual camera installed" : "Restart your Mac to finish installing"
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        status = "Install failed: \(error.localizedDescription)"
    }
}
