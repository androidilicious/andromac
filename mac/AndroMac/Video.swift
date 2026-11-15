import AppKit
import AVFoundation
import CoreMedia
import SwiftUI

/// Turns incoming video frames (flags + pts + Annex B H.264) into CMSampleBuffers and fans them out to sinks.
final class H264Feed {
    private var format: CMVideoFormatDescription?
    private var sinks: [String: (CMSampleBuffer) -> Void] = [:]
    private let lock = NSLock()

    func addSink(_ name: String, _ sink: @escaping (CMSampleBuffer) -> Void) {
        lock.lock(); sinks[name] = sink; lock.unlock()
    }

    func removeSink(_ name: String) {
        lock.lock(); sinks[name] = nil; lock.unlock()
    }

    func push(_ payload: Data) {
        let bytes = [UInt8](payload)
        guard bytes.count > 9 else { return }
        let isKey = bytes[0] & 2 != 0
        let pts = bytes[1..<9].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }

        var sps: [UInt8]?
        var pps: [UInt8]?
        var avcc = [UInt8]()
        for nal in splitAnnexB(bytes[9...]) {
            guard let first = nal.first else { continue }
            switch first & 0x1f {
            case 7: sps = Array(nal)
            case 8: pps = Array(nal)
            default:
                let n = UInt32(nal.count)
                avcc += [UInt8(n >> 24), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)]
                avcc += nal
            }
        }
        if let sps, let pps { format = Self.makeFormat(sps, pps) ?? format }
        guard let format, !avcc.isEmpty,
              let sample = Self.makeSample(avcc, format: format, pts: pts, isKey: isKey) else { return }
        lock.lock(); let targets = Array(sinks.values); lock.unlock()
        for sink in targets { sink(sample) }
    }

    private func splitAnnexB(_ b: ArraySlice<UInt8>) -> [ArraySlice<UInt8>] {
        var out: [ArraySlice<UInt8>] = []
        var i = b.startIndex
        var start = -1
        let end = b.endIndex
        while i + 2 < end {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                if start >= 0 {
                    var e = i
                    while e > start, b[e - 1] == 0 { e -= 1 }
                    if e > start { out.append(b[start..<e]) }
                }
                start = i + 3
                i += 3
            } else {
                i += 1
            }
        }
        if start >= 0, start < end { out.append(b[start..<end]) }
        return out
    }

    private static func makeFormat(_ sps: [UInt8], _ pps: [UInt8]) -> CMVideoFormatDescription? {
        var out: CMVideoFormatDescription?
        sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p in
                let pointers = [s.baseAddress!, p.baseAddress!]
                let sizes = [sps.count, pps.count]
                _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &out)
            }
        }
        return out
    }

    private static func makeSample(_ avcc: [UInt8], format: CMVideoFormatDescription, pts: UInt64, isKey: Bool) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: avcc.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
            let block,
            CMBlockBufferReplaceDataBytes(with: avcc, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count) == noErr
        else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: CMTimeValue(pts), timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var size = avcc.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
            let sample else { return nil }

        // Show each frame as soon as it arrives; this is a live stream, not a timed movie.
        if let list = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(list) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(list, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !isKey {
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sample
    }
}

/// Displays a feed. When `onInput` is set it also turns mouse and keyboard events into phone input.
final class VideoNSView: NSView {
    private let display = AVSampleBufferDisplayLayer()
    var videoSize = CGSize(width: 9, height: 16)
    var onInput: (([String: Any]) -> Void)?
    private var downAt: CGPoint?
    private var downTime = Date()
    private var scrollAcc: CGFloat = 0
    private var scrollPoint = CGPoint.zero
    private var scrollFlush: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        display.videoGravity = .resizeAspect
        display.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func makeBackingLayer() -> CALayer { display }
    override var acceptsFirstResponder: Bool { onInput != nil }

    func enqueue(_ sample: CMSampleBuffer) {
        if display.status == .failed { display.flush() }
        display.enqueue(sample)
    }

    /// Window point -> 0..1 within the picture, origin top-left. Nil when outside the picture.
    private func normalised(_ event: NSEvent) -> CGPoint? {
        let p = convert(event.locationInWindow, from: nil)
        let r = AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
        guard r.width > 0, r.height > 0 else { return nil }
        let x = (p.x - r.minX) / r.width
        let y = 1 - (p.y - r.minY) / r.height
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return CGPoint(x: x, y: y)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        downAt = normalised(event)
        downTime = Date()
    }

    override func mouseUp(with event: NSEvent) {
        guard let a = downAt, let send = onInput else { return }
        downAt = nil
        let b = normalised(event) ?? a
        if hypot(a.x - b.x, a.y - b.y) < 0.015 {
            send(["k": "tap", "x": a.x, "y": a.y])
        } else {
            let ms = Int(min(max(Date().timeIntervalSince(downTime) * 1000, 60), 1500))
            send(["k": "swipe", "x": a.x, "y": a.y, "x2": b.x, "y2": b.y, "ms": ms])
        }
    }

    /// Trackpad or wheel scrolling becomes a short swipe at the pointer position.
    override func scrollWheel(with event: NSEvent) {
        guard onInput != nil, let p = normalised(event) else { return }
        scrollPoint = p
        scrollAcc += event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 12)
        scrollFlush?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushScroll() }
        scrollFlush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    private func flushScroll() {
        let r = AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
        guard r.height > 0, abs(scrollAcc) > 2 else { scrollAcc = 0; return }
        let dy = max(-0.6, min(0.6, scrollAcc / r.height))
        scrollAcc = 0
        let y2 = max(0.02, min(0.98, scrollPoint.y + dy))
        onInput?(["k": "swipe", "x": scrollPoint.x, "y": scrollPoint.y, "x2": scrollPoint.x, "y2": y2, "ms": 120])
    }

    override func keyDown(with event: NSEvent) {
        guard let send = onInput else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 51: send(["k": "key", "key": "del"])
        case 36, 76: send(["k": "key", "key": "enter"])
        case 53: send(["k": "key", "key": "back"])
        default:
            if event.modifierFlags.contains(.command) {
                // Cmd+V types the Mac clipboard into the phone's focused field.
                if event.charactersIgnoringModifiers == "v", let s = NSPasteboard.general.string(forType: .string) {
                    send(["k": "text", "text": s])
                }
                return
            }
            guard let s = event.characters, !s.isEmpty,
                  s.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 && !(0xF700...0xF8FF).contains($0.value) })
            else { return }
            send(["k": "text", "text": s])
        }
    }
}

struct VideoView: NSViewRepresentable {
    let feed: H264Feed
    let sinkName: String
    var videoSize = CGSize(width: 16, height: 9)
    var onInput: (([String: Any]) -> Void)?

    final class Coordinator {
        let feed: H264Feed
        let sinkName: String
        init(feed: H264Feed, sinkName: String) { self.feed = feed; self.sinkName = sinkName }
    }

    func makeCoordinator() -> Coordinator { Coordinator(feed: feed, sinkName: sinkName) }

    func makeNSView(context: Context) -> VideoNSView {
        let v = VideoNSView(frame: .zero)
        v.videoSize = videoSize
        v.onInput = onInput
        feed.addSink(sinkName) { [weak v] sample in v?.enqueue(sample) }
        Link.shared.requestKeyframe() // a new viewer needs a keyframe before anything can be drawn
        return v
    }

    func updateNSView(_ v: VideoNSView, context: Context) {
        v.videoSize = videoSize
        v.onInput = onInput
    }

    static func dismantleNSView(_ v: VideoNSView, coordinator: Coordinator) {
        coordinator.feed.removeSink(coordinator.sinkName)
    }
}
