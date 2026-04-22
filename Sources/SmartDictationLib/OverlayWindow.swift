import AppKit
import QuartzCore
import os.log
private let owLogger = Logger(subsystem: "com.pravingayal.smart-dictation", category: "OverlayWindow")

// MARK: - OverlayState

enum OverlayState {
    case recording(partialText: String)
    case correcting
    case done(finalText: String)
    case llmOffline
    case warmingUp   // shown during LLM startup
}

// MARK: - OverlayWindow

@MainActor
final class OverlayWindow: NSPanel {

    // MARK: Layout constants

    private enum Layout {
        static let windowWidth: CGFloat = 500
        static let windowHeight: CGFloat = 72
        static let cornerRadius: CGFloat = 36
        static let leftPadding: CGFloat = 20
        static let rightPadding: CGFloat = 20
        static let dotSize: CGFloat = 14
        static let dotLeftOffset: CGFloat = 14
        static let waveformWidth: CGFloat = 40
        static let gapDotWaveform: CGFloat = 10
        static let gapWaveformLabel: CGFloat = 10
        static let fadeDuration: CFTimeInterval = 0.2
        static let bottomMargin: CGFloat = 48
        static let rightMargin: CGFloat = 48
    }

    // MARK: Colors

    private enum DotColor {
        static let blue   = NSColor(red: 74/255,  green: 158/255, blue: 255/255, alpha: 1) // #4A9EFF
        static let green  = NSColor(red: 76/255,  green: 217/255, blue: 100/255, alpha: 1) // #4CD964
        static let orange = NSColor(red: 255/255, green: 149/255, blue: 0/255,   alpha: 1) // #FF9500
        static let yellow = NSColor(red: 245/255, green: 200/255, blue: 66/255,  alpha: 1) // #F5C842
    }

    // MARK: Subviews

    private var effectView: NSVisualEffectView!
    private var darkOverlayLayer: CALayer!
    private var statusDotView: NSView!
    private var waveformView: WaveformView!
    private var textLabel: NSTextField!

    // MARK: Timers

    private var dismissTimer: DispatchWorkItem?

    // MARK: - Init

    init() {
        let contentRect = NSRect(x: 0, y: 0, width: Layout.windowWidth, height: Layout.windowHeight)
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        configure()
        buildContentView()
        positionOnScreen()
    }

    // MARK: - NSPanel configuration

    private func configure() {
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        alphaValue = 0
    }

    // MARK: - Content layout

    private func buildContentView() {
        guard let contentView = contentView else { return }
        contentView.wantsLayer = true

        // --- Visual effect (vibrancy) ---
        effectView = NSVisualEffectView(frame: contentView.bounds)
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.autoresizingMask = [.width, .height]
        contentView.addSubview(effectView)

        // Rounded pill mask for the effect view
        if let effLayer = effectView.layer {
            effLayer.cornerRadius = Layout.cornerRadius
            effLayer.masksToBounds = true
        }

        // --- Dark overlay on top of vibrancy ---
        darkOverlayLayer = CALayer()
        darkOverlayLayer.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        darkOverlayLayer.cornerRadius = Layout.cornerRadius
        darkOverlayLayer.masksToBounds = true
        darkOverlayLayer.frame = contentView.bounds
        darkOverlayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        effectView.layer?.addSublayer(darkOverlayLayer)

        let midY = Layout.windowHeight / 2

        // --- Status dot ---
        let dotFrame = NSRect(
            x: Layout.leftPadding + Layout.dotLeftOffset - Layout.dotSize / 2,
            y: midY - Layout.dotSize / 2,
            width: Layout.dotSize,
            height: Layout.dotSize
        )
        statusDotView = NSView(frame: dotFrame)
        statusDotView.wantsLayer = true
        statusDotView.layer?.cornerRadius = Layout.dotSize / 2
        statusDotView.layer?.masksToBounds = true
        statusDotView.layer?.backgroundColor = DotColor.blue.cgColor
        contentView.addSubview(statusDotView)

        // --- Waveform ---
        let dotRightEdge = dotFrame.maxX
        let waveformX = dotRightEdge + Layout.gapDotWaveform
        let waveformFrame = NSRect(
            x: waveformX,
            y: midY - Layout.windowHeight * 0.4,
            width: Layout.waveformWidth,
            height: Layout.windowHeight * 0.8
        )
        waveformView = WaveformView(frame: waveformFrame)
        waveformView.wantsLayer = true
        contentView.addSubview(waveformView)

        // --- Text label ---
        let labelX = waveformFrame.maxX + Layout.gapWaveformLabel
        let labelWidth = Layout.windowWidth - labelX - Layout.rightPadding
        let labelFrame = NSRect(
            x: labelX,
            y: 0,
            width: labelWidth,
            height: Layout.windowHeight
        )
        textLabel = NSTextField(frame: labelFrame)
        textLabel.isEditable = false
        textLabel.isSelectable = false
        textLabel.isBordered = false
        textLabel.isBezeled = false
        textLabel.drawsBackground = false
        textLabel.textColor = .white
        textLabel.font = NSFont.systemFont(ofSize: 16, weight: .regular)
        textLabel.alignment = .left
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.maximumNumberOfLines = 1
        textLabel.cell?.truncatesLastVisibleLine = true
        contentView.addSubview(textLabel)
    }

    private func positionOnScreen() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.maxX - Layout.windowWidth - Layout.rightMargin
        let y = screenFrame.minY + Layout.bottomMargin
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Public API

    func show(state: OverlayState) {
        cancelDismissTimer()
        positionOnScreen()
        applyState(state)
        fadeIn()
    }

    func updatePartialText(_ text: String) {
        textLabel.stringValue = text
    }

    func updateWaveform(_ levels: [Float]) {
        waveformView.updateAmplitudes(levels)
    }

    func dismiss(animated: Bool) {
        cancelDismissTimer()
        if animated {
            fadeOut()
        } else {
            alphaValue = 0
            orderOut(nil)
        }
    }

    // MARK: - State rendering

    private func applyState(_ state: OverlayState) {
        // Remove all existing dot animations
        statusDotView.layer?.removeAllAnimations()

        switch state {
        case .recording(let partialText):
            setDotColor(DotColor.blue)
            pulseDot()
            textLabel.stringValue = partialText
            textLabel.font = NSFont.systemFont(ofSize: 16, weight: .regular)
            waveformView.isHidden = false
            waveformView.startAnimating()

        case .correcting:
            setDotColor(DotColor.blue)
            textLabel.stringValue = "Correcting…"
            textLabel.font = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 13), toHaveTrait: .italicFontMask)
            waveformView.stopAnimating()
            waveformView.isHidden = false

        case .done(let finalText):
            setDotColor(DotColor.green)
            textLabel.stringValue = finalText
            textLabel.font = NSFont.systemFont(ofSize: 16, weight: .regular)
            waveformView.stopAnimating()
            waveformView.isHidden = true
            scheduleDismiss(after: Double(Config.overlayDismissDelayMs) / 1000.0)

        case .llmOffline:
            setDotColor(DotColor.orange)
            textLabel.stringValue = "LLM offline — pasting raw text"
            textLabel.font = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 13), toHaveTrait: .italicFontMask)
            waveformView.stopAnimating()
            waveformView.isHidden = true
            scheduleDismiss(after: 2.0)

        case .warmingUp:
            setDotColor(DotColor.yellow)
            pulseDot()
            textLabel.stringValue = "LLM warming up…"
            textLabel.font = NSFont.systemFont(ofSize: 16, weight: .regular)
            waveformView.stopAnimating()
            waveformView.isHidden = true
        }
    }

    // MARK: - Dot helpers

    private func setDotColor(_ color: NSColor) {
        statusDotView.layer?.backgroundColor = color.cgColor
    }

    private func pulseDot() {
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 0.5
        anim.toValue = 1.0
        anim.duration = 1.0
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        statusDotView.layer?.add(anim, forKey: "pulse")
    }

    // MARK: - Animation helpers

    private func fadeIn() {
        owLogger.info("fadeIn: frame=\(NSStringFromRect(self.frame), privacy: .public) screen=\(NSStringFromRect(NSScreen.main?.frame ?? .zero), privacy: .public) alpha=\(self.alphaValue, privacy: .public) level=\(self.level.rawValue, privacy: .public)")
        orderFront(nil)
        alphaValue = 1.0  // set immediately, no animation, for debugging
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Layout.fadeDuration
            animator().alphaValue = 1.0
        }
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Layout.fadeDuration
            animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }

    // MARK: - Auto-dismiss

    private func scheduleDismiss(after seconds: Double) {
        cancelDismissTimer()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.dismiss(animated: true)
            }
        }
        dismissTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func cancelDismissTimer() {
        dismissTimer?.cancel()
        dismissTimer = nil
    }
}
