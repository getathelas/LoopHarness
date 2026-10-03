//
//  HotkeyVisualView.swift
//  LoopMac
//
//  Animated illustration of the shift + ⌃ hold-to-talk hotkey shown during
//  onboarding's first-command step. Two key caps press down in sequence,
//  hold, then release — looping so the user can imitate it.
//

import AppKit
import QuartzCore

final class HotkeyVisualView: NSView {

    private let shiftKey = KeyCapView(glyph: "shift")
    private let ctrlKey = KeyCapView(glyph: "⌃")
    private let plusLabel = NSTextField(labelWithString: "+")
    private var cycleTimer: Timer?
    private var pendingWork: [DispatchWorkItem] = []

    /// Real-keyboard state, sampled from `NSEvent.flagsChanged`. When either
    /// is true the corresponding cap is pinned in the pressed state and the
    /// animation cycle skips over it — releasing returns control to the
    /// animation.
    private var realShiftHeld = false {
        didSet {
            guard oldValue != realShiftHeld else { return }
            shiftKey.setPressed(realShiftHeld)
        }
    }
    private var realCtrlHeld = false {
        didSet {
            guard oldValue != realCtrlHeld else { return }
            ctrlKey.setPressed(realCtrlHeld)
        }
    }
    private var flagsMonitorLocal: Any?
    private var flagsMonitorGlobal: Any?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 130))
        wantsLayer = true

        plusLabel.font = .systemFont(ofSize: 20, weight: .medium)
        plusLabel.textColor = .tertiaryLabelColor
        plusLabel.translatesAutoresizingMaskIntoConstraints = false

        let pressedRow = NSStackView(views: [shiftKey, plusLabel, ctrlKey])
        pressedRow.orientation = .horizontal
        pressedRow.alignment = .centerY
        pressedRow.spacing = 14
        pressedRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pressedRow)

        NSLayoutConstraint.activate([
            // Pressed row sits along the bottom of our bounds and is
            // horizontally centered.
            pressedRow.centerXAnchor.constraint(equalTo: centerXAnchor),
            pressedRow.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 130) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startKeyMonitoring()
            startAnimating()
        } else {
            stopAnimating()
            stopKeyMonitoring()
        }
    }

    deinit {
        stopAnimating()
        stopKeyMonitoring()
    }

    private func startAnimating() {
        stopAnimating()
        runCycle()
        // 3.6s per cycle: 0.4 idle, shift down at 0.4, ctrl down at 0.75, hold,
        // both release at 2.6, brief idle, loop.
        cycleTimer = Timer.scheduledTimer(withTimeInterval: 3.6, repeats: true) { [weak self] _ in
            self?.runCycle()
        }
    }

    private func stopAnimating() {
        cycleTimer?.invalidate()
        cycleTimer = nil
        pendingWork.forEach { $0.cancel() }
        pendingWork.removeAll()
        // Only reset caps that aren't currently being held for real. Otherwise
        // the next viewDidMoveToWindow could blip them out of the pressed
        // state while the user's finger is still on the key.
        if !realShiftHeld { shiftKey.setPressed(false, animated: false) }
        if !realCtrlHeld { ctrlKey.setPressed(false, animated: false) }
    }

    private func runCycle() {
        schedule(after: 0.40) {
            guard !self.realShiftHeld else { return }
            self.shiftKey.setPressed(true)
        }
        schedule(after: 0.75) {
            guard !self.realCtrlHeld else { return }
            self.ctrlKey.setPressed(true)
        }
        schedule(after: 2.60) {
            if !self.realShiftHeld { self.shiftKey.setPressed(false) }
            if !self.realCtrlHeld { self.ctrlKey.setPressed(false) }
        }
    }

    private func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) {
        let item = DispatchWorkItem(block: block)
        pendingWork.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: - Real-key tracking

    /// Watches modifier-flag changes so the caps mirror what the user is
    /// actually doing. Local monitor covers the case where our window is
    /// front; global monitor covers everything else (Accessibility access
    /// has already been granted by step 2 of onboarding, so this works).
    private func startKeyMonitoring() {
        stopKeyMonitoring()
        // Sync current state — flagsChanged only fires on transitions, so
        // without this a key already down when the view appears wouldn't show.
        applyFlags(NSEvent.modifierFlags)
        flagsMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.applyFlags(event.modifierFlags)
            return event
        }
        flagsMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.applyFlags(event.modifierFlags)
        }
    }

    private func stopKeyMonitoring() {
        if let m = flagsMonitorLocal { NSEvent.removeMonitor(m); flagsMonitorLocal = nil }
        if let m = flagsMonitorGlobal { NSEvent.removeMonitor(m); flagsMonitorGlobal = nil }
    }

    private func applyFlags(_ flags: NSEvent.ModifierFlags) {
        realShiftHeld = flags.contains(.shift)
        realCtrlHeld = flags.contains(.control)
    }
}

/// Single key cap. The cap layer sits raised above a darker base; on press
/// it slides down to flush with the base, mimicking a keyboard keycap being
/// held down. The text glyph lives inside the cap so it tracks the motion.
private final class KeyCapView: NSView {

    private let intrinsicWidth: CGFloat = 56
    private let intrinsicHeight: CGFloat = 56
    private let liftAmount: CGFloat = 4

    private let baseLayer = CALayer()
    private let capLayer = CALayer()
    private let textLayer = CATextLayer()
    private var pressed = false

    init(glyph: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 56, height: 56))
        wantsLayer = true
        layer?.masksToBounds = false

        baseLayer.cornerRadius = 8
        layer?.addSublayer(baseLayer)

        capLayer.cornerRadius = 8
        capLayer.borderWidth = 1
        layer?.addSublayer(capLayer)

        textLayer.string = glyph
        textLayer.font = NSFont.systemFont(ofSize: 18, weight: .medium)
        textLayer.fontSize = 18
        textLayer.alignmentMode = .center
        textLayer.truncationMode = .none
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        capLayer.addSublayer(textLayer)

        applyColorsForState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: intrinsicWidth, height: intrinsicHeight)
    }

    override func layout() {
        super.layout()
        let capH = max(0, bounds.height - liftAmount)
        let capW = bounds.width

        // Disable implicit animations so layout is instantaneous; press
        // animations have their own transaction in setPressed.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        baseLayer.frame = CGRect(x: 0, y: 0, width: capW, height: capH)
        capLayer.frame = CGRect(x: 0, y: pressed ? 0 : liftAmount, width: capW, height: capH)
        let textHeight: CGFloat = 22
        textLayer.frame = CGRect(
            x: 0,
            y: (capH - textHeight) / 2,
            width: capW,
            height: textHeight
        )
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        textLayer.contentsScale = window?.backingScaleFactor ?? 2.0
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyColorsForState()
        CATransaction.commit()
    }

    /// Paints the cap for the current `pressed` value using appearance-aware
    /// colors. Idle = system control surface. Pressed = light accent (blue
    /// on a default macOS install) so the held keys read as "active".
    private func applyColorsForState() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            baseLayer.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
            if pressed {
                let accent = NSColor.controlAccentColor
                capLayer.backgroundColor = accent.withAlphaComponent(0.22).cgColor
                capLayer.borderColor = accent.withAlphaComponent(0.70).cgColor
                textLayer.foregroundColor = accent.cgColor
            } else {
                capLayer.backgroundColor = NSColor.controlBackgroundColor.cgColor
                capLayer.borderColor = NSColor.separatorColor.cgColor
                textLayer.foregroundColor = NSColor.labelColor.cgColor
            }
        }
    }

    func setPressed(_ pressed: Bool, animated: Bool = true) {
        self.pressed = pressed
        let capH = max(0, bounds.height - liftAmount)
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.18)
            CATransaction.setAnimationTimingFunction(
                CAMediaTimingFunction(name: pressed ? .easeIn : .easeOut)
            )
        } else {
            CATransaction.setDisableActions(true)
        }
        capLayer.frame = CGRect(
            x: 0,
            y: pressed ? 0 : liftAmount,
            width: bounds.width,
            height: capH
        )
        applyColorsForState()
        CATransaction.commit()
    }
}
