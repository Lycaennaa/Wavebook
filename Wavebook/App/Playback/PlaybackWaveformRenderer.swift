import AppKit
import WavebookCore

enum PlaybackWaveformSegmentEdge: Equatable {
    case start
    case end
}

struct PlaybackWaveformSegmentHandle: Equatable {
    let id: UUID
    let edge: PlaybackWaveformSegmentEdge
}

struct PlaybackWaveformDrawOptions {
    let duration: TimeInterval
    let elapsed: TimeInterval
    let viewportStart: TimeInterval
    let viewportEnd: TimeInterval
    let skipSegments: [AudioSkipSegment]
    let draftStart: TimeInterval?
    let draftEnd: TimeInterval?
    let activeHandle: PlaybackWaveformSegmentHandle?
    let isLoading: Bool
    let loadFailed: Bool
}

private struct PlaybackWaveformSkipContext {
    let segments: [AudioSkipSegment]
    let duration: TimeInterval
    let viewportStart: TimeInterval
    let viewportEnd: TimeInterval
    let activeHandle: PlaybackWaveformSegmentHandle?
    let plotRect: NSRect
}

enum PlaybackWaveformRenderer {

    static func draw(in plotRect: NSRect, peaks: [Float], options: PlaybackWaveformDrawOptions) {
        let duration = options.duration
        let elapsed = options.elapsed
        let viewportStart = options.viewportStart
        let viewportEnd = options.viewportEnd
        let skipSegments = options.skipSegments
        let draftStart = options.draftStart
        let draftEnd = options.draftEnd
        let activeHandle = options.activeHandle
        let isLoading = options.isLoading
        let loadFailed = options.loadFailed
        if peaks.isEmpty {
            let message = isLoading
                ? "Loading waveform…"
                : loadFailed ? "Waveform unavailable" : "No waveform data"
            drawStatus(message, in: plotRect)
        } else {
            drawPeaks(
                peaks,
                duration: duration,
                viewportStart: viewportStart,
                viewportEnd: viewportEnd,
                in: plotRect
            )
        }
        drawSkipSegments(
            PlaybackWaveformSkipContext(
                segments: skipSegments,
                duration: duration,
                viewportStart: viewportStart,
                viewportEnd: viewportEnd,
                activeHandle: activeHandle,
                plotRect: plotRect
            )
        )
        drawDraftSegment(
            start: draftStart,
            end: draftEnd,
            viewportStart: viewportStart,
            viewportEnd: viewportEnd,
            in: plotRect
        )
        drawPlayhead(
            elapsed: elapsed,
            duration: duration,
            viewportStart: viewportStart,
            viewportEnd: viewportEnd,
            in: plotRect
        )
        drawTimeLabels(viewportStart: viewportStart, viewportEnd: viewportEnd, in: plotRect)
    }

    private static func drawSkipSegments(_ context: PlaybackWaveformSkipContext) {
        let segments = context.segments
        let duration = context.duration
        let viewportStart = context.viewportStart
        let viewportEnd = context.viewportEnd
        let activeHandle = context.activeHandle
        let plotRect = context.plotRect
        guard duration > 0 else { return }
        for segment in segments {
            let start = max(segment.startTime, viewportStart)
            let end = min(segment.endTime, viewportEnd)
            guard end > start else { continue }
            let startX = x(for: start, viewportStart: viewportStart, viewportEnd: viewportEnd, in: plotRect)
            let endX = x(for: end, viewportStart: viewportStart, viewportEnd: viewportEnd, in: plotRect)
            AppTheme.skipSegment.withAlphaComponent(0.3).setFill()
            NSBezierPath(
                rect: NSRect(
                    x: startX,
                    y: plotRect.minY,
                    width: endX - startX,
                    height: plotRect.height
                )
            ).fill()
            if segment.startTime >= viewportStart, segment.startTime <= viewportEnd {
                drawHandle(
                    at: x(for: segment.startTime, viewportStart: viewportStart, viewportEnd: viewportEnd, in: plotRect),
                    id: segment.id,
                    edge: .start,
                    activeHandle: activeHandle,
                    in: plotRect
                )
            }
            if segment.endTime >= viewportStart, segment.endTime <= viewportEnd {
                drawHandle(
                    at: x(for: segment.endTime, viewportStart: viewportStart, viewportEnd: viewportEnd, in: plotRect),
                    id: segment.id,
                    edge: .end,
                    activeHandle: activeHandle,
                    in: plotRect
                )
            }
        }
    }

    private static func drawHandle(
        at xPosition: CGFloat,
        id: UUID,
        edge: PlaybackWaveformSegmentEdge,
        activeHandle: PlaybackWaveformSegmentHandle?,
        in plotRect: NSRect
    ) {
        let isActive = activeHandle?.id == id && activeHandle?.edge == edge
        let handleColor: NSColor
        if isActive {
            handleColor = AppTheme.primaryText
        } else {
            handleColor = edge == .start ? NSColor.systemYellow : AppTheme.skipSegment
        }
        handleColor.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: xPosition, y: plotRect.minY))
        path.line(to: NSPoint(x: xPosition, y: plotRect.maxY))
        path.lineWidth = isActive ? 2.5 : 2
        path.stroke()
        handleColor.setFill()
        NSBezierPath(
            ovalIn: NSRect(x: xPosition - 4, y: plotRect.midY - 4, width: 8, height: 8)
        ).fill()
    }

    private static func drawDraftSegment(
        start: TimeInterval?,
        end: TimeInterval?,
        viewportStart: TimeInterval,
        viewportEnd: TimeInterval,
        in plotRect: NSRect
    ) {
        if let start, let end, end > start {
            let visibleStart = max(start, viewportStart)
            let visibleEnd = min(end, viewportEnd)
            if visibleEnd > visibleStart {
                AppTheme.accent.withAlphaComponent(0.18).setFill()
                let rect = NSRect(
                    x: x(for: visibleStart, viewportStart: viewportStart, viewportEnd: viewportEnd, in: plotRect),
                    y: plotRect.minY,
                    width: x(for: visibleEnd, viewportStart: viewportStart, viewportEnd: viewportEnd, in: plotRect)
                        - x(for: visibleStart, viewportStart: viewportStart, viewportEnd: viewportEnd, in: plotRect),
                    height: plotRect.height
                )
                NSBezierPath(rect: rect).fill()
            }
        }
        if let start {
            drawDraftBoundary(start, viewportStart: viewportStart, viewportEnd: viewportEnd, in: plotRect)
        }
        if let end {
            drawDraftBoundary(end, viewportStart: viewportStart, viewportEnd: viewportEnd, in: plotRect)
        }
    }

    private static func drawDraftBoundary(
        _ seconds: TimeInterval,
        viewportStart: TimeInterval,
        viewportEnd: TimeInterval,
        in plotRect: NSRect
    ) {
        guard seconds >= viewportStart, seconds <= viewportEnd else { return }
        let xPosition = x(for: seconds, viewportStart: viewportStart, viewportEnd: viewportEnd, in: plotRect)
        AppTheme.accent.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: xPosition, y: plotRect.minY))
        path.line(to: NSPoint(x: xPosition, y: plotRect.maxY))
        path.lineWidth = 2
        path.stroke()
        AppTheme.accent.setFill()
        NSBezierPath(
            ovalIn: NSRect(x: xPosition - 4, y: plotRect.midY - 4, width: 8, height: 8)
        ).fill()
    }

    static func drawPeaks(
        _ peaks: [Float],
        duration: TimeInterval,
        viewportStart: TimeInterval,
        viewportEnd: TimeInterval,
        in plotRect: NSRect
    ) {
        guard duration > 0, !peaks.isEmpty else { return }
        let startIndex = min(
            max(Int((viewportStart / duration * Double(peaks.count)).rounded(.down)), 0),
            peaks.count - 1
        )
        let endIndex = min(
            max(Int((viewportEnd / duration * Double(peaks.count)).rounded(.up)), startIndex + 1),
            peaks.count
        )
        let visiblePeaks = peaks[startIndex..<endIndex]
        let step = plotRect.width / CGFloat(visiblePeaks.count)
        let barWidth = max(1, step * 0.72)
        let centerY = plotRect.midY
        let maximumHeight = plotRect.height * 0.44
        let overlapGroupCount = max(1, Int(barWidth / step) + 1)
        AppTheme.accent.withAlphaComponent(0.78).setFill()
        // Separate overlapping translucent bars, batch disjoint bars.
        for groupIndex in 0..<overlapGroupCount {
            let path = NSBezierPath()
            var pendingRectangles = 0
            for index in stride(from: groupIndex, to: visiblePeaks.count, by: overlapGroupCount) {
                let peak = visiblePeaks[index]
                let height = max(2, CGFloat(max(0, min(peak, 1))) * maximumHeight)
                let rect = NSRect(
                    x: plotRect.minX + CGFloat(index) * step,
                    y: centerY - height,
                    width: barWidth,
                    height: height * 2
                )
                path.appendRoundedRect(rect, xRadius: barWidth / 2, yRadius: barWidth / 2)
                pendingRectangles += 1
                if pendingRectangles == 8 {
                    path.fill()
                    path.removeAllPoints()
                    pendingRectangles = 0
                }
            }
            if pendingRectangles > 0 {
                path.fill()
            }
        }
    }

    private static func drawPlayhead(
        elapsed: TimeInterval,
        duration: TimeInterval,
        viewportStart: TimeInterval,
        viewportEnd: TimeInterval,
        in plotRect: NSRect
    ) {
        guard duration > 0, elapsed >= viewportStart, elapsed <= viewportEnd else { return }
        let xPosition = x(for: elapsed, viewportStart: viewportStart, viewportEnd: viewportEnd, in: plotRect)
        AppTheme.primaryText.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: xPosition, y: plotRect.minY))
        path.line(to: NSPoint(x: xPosition, y: plotRect.maxY))
        path.lineWidth = 1.5
        path.stroke()
    }

    private static func drawTimeLabels(viewportStart: TimeInterval, viewportEnd: TimeInterval, in plotRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: AppTheme.secondaryText
        ]
        PlaybackTimecode.string(from: viewportStart, includingFractionalSeconds: false)
            .draw(at: NSPoint(x: plotRect.minX, y: 3), withAttributes: attributes)
        let endLabel = PlaybackTimecode.string(from: viewportEnd, includingFractionalSeconds: false)
        let size = endLabel.size(withAttributes: attributes)
        endLabel.draw(at: NSPoint(x: plotRect.maxX - size.width, y: 3), withAttributes: attributes)
    }
    private static func drawStatus(_ message: String, in rect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: AppTheme.secondaryText
        ]
        let size = message.size(withAttributes: attributes)
        message.draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    private static func x(
        for seconds: TimeInterval,
        viewportStart: TimeInterval,
        viewportEnd: TimeInterval,
        in plotRect: NSRect
    ) -> CGFloat {
        guard viewportEnd > viewportStart else { return plotRect.minX }
        return plotRect.minX + plotRect.width * CGFloat((seconds - viewportStart) / (viewportEnd - viewportStart))
    }
}
