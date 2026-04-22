import AppKit
import QuartzCore

// MARK: - WaveformView

/// A five-bar animated waveform rendered with CAShapeLayer rounded rectangles.
/// Bar fill color is always #4A9EFF (blue).
final class WaveformView: NSView {

    // MARK: Constants

    private enum Constants {
        static let barCount: Int = 5
        static let barWidth: CGFloat = 3
        static let barSpacing: CGFloat = 3
        static let minBarHeight: CGFloat = 4
        static let maxBarHeight: CGFloat = 28
        static let animationDuration: CFTimeInterval = 0.1
        static let barColor = CGColor(red: 74.0/255.0, green: 158.0/255.0, blue: 255.0/255.0, alpha: 1.0) // #4A9EFF
        static let breathingDuration: CFTimeInterval = 0.6
    }

    // MARK: Private state

    private var barLayers: [CAShapeLayer] = []
    private var isBreathing = false

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setupLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupLayers()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        repositionBars()
    }

    // MARK: - Public API

    /// Update bar heights from an amplitude array (clamped to 5 values, each 0.0–1.0).
    func updateAmplitudes(_ levels: [Float]) {
        let clamped = levels.prefix(Constants.barCount)
        for (index, layer) in barLayers.enumerated() {
            let amplitude: Float = index < clamped.count ? max(0.0, min(1.0, clamped[index])) : 0.0
            let height = Constants.minBarHeight + CGFloat(amplitude) * (Constants.maxBarHeight - Constants.minBarHeight)
            animateBar(layer, toHeight: height)
        }
    }

    /// Start the idle "breathing" animation — subtle oscillation while not recording.
    func startAnimating() {
        guard !isBreathing else { return }
        isBreathing = true

        let phases: [Double] = [0.0, 0.3, 0.6, 0.3, 0.0]
        for (index, layer) in barLayers.enumerated() {
            let anim = CABasicAnimation(keyPath: "bounds.size.height")
            let lowH = Constants.minBarHeight
            let highH = Constants.minBarHeight + (Constants.maxBarHeight - Constants.minBarHeight) * 0.25
            anim.fromValue = lowH
            anim.toValue = highH
            anim.duration = Constants.breathingDuration
            anim.autoreverses = true
            anim.repeatCount = .infinity
            anim.timeOffset = phases[index] * Constants.breathingDuration
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(anim, forKey: "breathing")

            // Also animate position so bar stays vertically centered
            let posAnim = CABasicAnimation(keyPath: "position.y")
            posAnim.fromValue = bounds.midY
            posAnim.toValue = bounds.midY
            posAnim.duration = Constants.breathingDuration
            posAnim.autoreverses = true
            posAnim.repeatCount = .infinity
            posAnim.timeOffset = phases[index] * Constants.breathingDuration
            posAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(posAnim, forKey: "breathingPosition")
        }
    }

    /// Stop the idle animation and reset bars to minimum height.
    func stopAnimating() {
        guard isBreathing else { return }
        isBreathing = false
        for layer in barLayers {
            layer.removeAnimation(forKey: "breathing")
            layer.removeAnimation(forKey: "breathingPosition")
            animateBar(layer, toHeight: Constants.minBarHeight)
        }
    }

    // MARK: - Private helpers

    private func setupLayers() {
        guard let hostLayer = layer else { return }
        hostLayer.masksToBounds = false

        barLayers = (0..<Constants.barCount).map { _ in
            let shape = CAShapeLayer()
            shape.fillColor = Constants.barColor
            shape.strokeColor = nil
            hostLayer.addSublayer(shape)
            return shape
        }

        // Initial positioning will happen in layout(), but do a first pass now.
        repositionBars()
    }

    private func repositionBars() {
        let totalBarsWidth = CGFloat(Constants.barCount) * Constants.barWidth
            + CGFloat(Constants.barCount - 1) * Constants.barSpacing
        let startX = (bounds.width - totalBarsWidth) / 2

        for (index, layer) in barLayers.enumerated() {
            let x = startX + CGFloat(index) * (Constants.barWidth + Constants.barSpacing)
            let height = Constants.minBarHeight
            let y = (bounds.height - height) / 2
            let rect = CGRect(x: x, y: y, width: Constants.barWidth, height: height)
            let path = CGPath(roundedRect: rect, cornerWidth: Constants.barWidth / 2, cornerHeight: Constants.barWidth / 2, transform: nil)
            layer.path = path
            layer.bounds = CGRect(origin: .zero, size: CGSize(width: Constants.barWidth, height: height))
            layer.position = CGPoint(x: x + Constants.barWidth / 2, y: bounds.midY)
        }
    }

    /// Animate a single bar to the given height, keeping it vertically centered.
    private func animateBar(_ barLayer: CAShapeLayer, toHeight height: CGFloat) {
        let x: CGFloat
        if let index = barLayers.firstIndex(of: barLayer) {
            let totalBarsWidth = CGFloat(Constants.barCount) * Constants.barWidth
                + CGFloat(Constants.barCount - 1) * Constants.barSpacing
            let startX = (bounds.width - totalBarsWidth) / 2
            x = startX + CGFloat(index) * (Constants.barWidth + Constants.barSpacing)
        } else {
            x = 0
        }

        let newRect = CGRect(x: 0, y: 0, width: Constants.barWidth, height: height)
        let newPath = CGPath(roundedRect: newRect, cornerWidth: Constants.barWidth / 2, cornerHeight: Constants.barWidth / 2, transform: nil)

        CATransaction.begin()
        CATransaction.setAnimationDuration(Constants.animationDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        barLayer.path = newPath
        barLayer.bounds = CGRect(origin: .zero, size: CGSize(width: Constants.barWidth, height: height))
        barLayer.position = CGPoint(x: x + Constants.barWidth / 2, y: bounds.midY)
        CATransaction.commit()
    }
}
