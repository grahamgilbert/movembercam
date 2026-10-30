import AVFoundation
import SwiftUI

@MainActor
final class VideoPreviewFeed: ObservableObject {
    @Published var sample: CMSampleBuffer?
}

/// Only this small view observes video updates; the settings window and menu do not redraw per frame.
struct VideoPreviewSurface: View {
    @ObservedObject var feed: VideoPreviewFeed
    var body: some View {
        if let sample = feed.sample { SampleBufferPreview(sample: sample) }
    }
}

/// Display composited IOSurface-backed video frames directly instead of round-tripping through CGImage.
struct SampleBufferPreview: NSViewRepresentable {
    let sample: CMSampleBuffer
    func makeNSView(context: Context) -> VideoPreviewView { VideoPreviewView() }
    func updateNSView(_ view: VideoPreviewView, context: Context) { view.display(sample) }
}

final class VideoPreviewView: NSView {
    private let videoLayer = AVSampleBufferDisplayLayer()
    private var lastSample: CMSampleBuffer?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        videoLayer.videoGravity = .resizeAspect
        layer?.addSublayer(videoLayer)
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }

    func display(_ sample: CMSampleBuffer) {
        guard sample !== lastSample else { return }
        lastSample = sample
        let renderer = videoLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        guard renderer.isReadyForMoreMediaData else { return }
        var preview: CMSampleBuffer?
        guard CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                                      sampleBufferOut: &preview) == noErr, let preview else { return }
        // This copy owns its attachments; the sample sent to Zoom keeps its host timestamps.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(preview, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        renderer.enqueue(preview)
    }
}
