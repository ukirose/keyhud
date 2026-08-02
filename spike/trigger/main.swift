// Spike 1 (rev 2): does a lone Command hold produce anything an ordinary app can see,
// on a Karabiner `lazy: true` setup?
//
// What rev 1 established:
//   - The physical HHKB cannot be read directly. IOHIDManagerOpen returns
//     kIOReturnExclusiveAccess (0xE00002C5) because Karabiner-Core-Service (pid 767,
//     root) has seized it. Reading below Karabiner is closed off by Karabiner itself.
//   - So channel C is gone, and the remaining question is answerable by channel B alone.
//
// The question now:
//   While left_command is held ALONE, does a CGEventTap see a flagsChanged carrying
//   the command flag? If not, every tool in this category (CheatSheet, KeyCue, KeyClu)
//   is structurally unable to trigger on this machine, because that event is the only
//   thing they listen for.
//
// Instrument checks carried over from rev 1: an unpermitted tap is created successfully
// and then silently receives nothing, so permissions are asserted explicitly and a run
// with a dead channel reports NO DATA rather than a confirmed hypothesis. Rev 1 also
// produced a run where the protocol was simply never performed, so the steps are now
// driven from an on-screen panel with timed windows and events are attributed to the
// step that was on screen when they arrived.

import Cocoa
import CoreGraphics
import IOKit
import IOKit.hid

// ---------------------------------------------------------------- protocol script

struct Step {
    let title: String
    let detail: String
    let seconds: Double
    /// What channel B should show if the lazy modifier is suppressing the hold.
    let expectation: String
}

let steps: [Step] = [
    Step(title: "get ready",
         detail: "hands on the keyboard — do not press anything yet",
         seconds: 4,
         expectation: "silence"),
    Step(title: "STEP 1 — hold LEFT ⌘ alone",
         detail: "press and HOLD the left command key. keep holding until the step changes.",
         seconds: 7,
         expectation: "no flagsChanged if lazy is suppressing it"),
    Step(title: "STEP 2 — tap LEFT ⌘ once",
         detail: "a single quick tap, then let go. (this should switch the IME to 英数)",
         seconds: 6,
         expectation: "eisuu keycode 102, and possibly a cmd flagsChanged pair"),
    Step(title: "STEP 3 — hold LEFT ⌘ and press A",
         detail: "hold left command, press A, release both",
         seconds: 7,
         expectation: "keyDown keycode 0 with flags=[cmd] — the lazy modifier materialises here"),
    Step(title: "STEP 4 — hold RIGHT ⌘ alone",
         detail: "press and HOLD the right command key until the step changes",
         seconds: 7,
         expectation: "same as step 1"),
    Step(title: "done",
         detail: "writing verdict to run.log — this window closes on its own",
         seconds: 3,
         expectation: ""),
]

// ---------------------------------------------------------------- logging

let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Developer/keyhud/spike/trigger/run.log")
let start = DispatchTime.now().uptimeNanoseconds
var lines: [String] = []

func ts() -> String {
    String(format: "%8.1fms", Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
}

func log(_ channel: String, _ msg: String) {
    let line = "\(ts())  [\(channel)]  \(msg)"
    lines.append(line)
    try? lines.joined(separator: "\n").appending("\n")
        .write(to: logURL, atomically: true, encoding: .utf8)
}

// ---------------------------------------------------------------- state

var stepIndex = 0
/// Events attributed to the step that was on screen when they arrived.
var perStep: [Int: [String]] = [:]
var bTrusted = false
var bEvents = 0

func record(_ desc: String) {
    bEvents += 1
    perStep[stepIndex, default: []].append(desc)
    log("B tap ", "step \(stepIndex) — \(desc)")
}

// ---------------------------------------------------------------- channel B

func tapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType,
                 _ event: CGEvent, _ ctx: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let f = event.flags
    var mods: [String] = []
    if f.contains(.maskCommand) { mods.append("cmd") }
    if f.contains(.maskShift) { mods.append("shift") }
    if f.contains(.maskControl) { mods.append("ctrl") }
    if f.contains(.maskAlternate) { mods.append("opt") }
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    let kind: String
    switch type {
    case .flagsChanged: kind = "flagsChanged"
    case .keyDown: kind = "keyDown"
    default: kind = "keyUp"
    }
    record("\(kind) keycode=\(code) flags=[\(mods.joined(separator: ","))]")
    return Unmanaged.passUnretained(event)
}

// ---------------------------------------------------------------- app

class Panel: NSPanel {
    override var canBecomeKey: Bool { false }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: Panel!
    var titleLabel = NSTextField(labelWithString: "")
    var detailLabel = NSTextField(wrappingLabelWithString: "")
    var statusLabel = NSTextField(labelWithString: "")
    var clockLabel = NSTextField(labelWithString: "")
    var stepStarted = Date()

    func applicationDidFinishLaunching(_ note: Notification) {
        buildPanel()
        checkPermissions()
        startTap()
        advance()
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in self.tick() }
    }

    func buildPanel() {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 240),
                      styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                      backing: .buffered, defer: false)
        panel.title = "KeyHUD trigger spike"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titlebarAppearsTransparent = true

        titleLabel.font = .monospacedSystemFont(ofSize: 22, weight: .bold)
        detailLabel.font = .systemFont(ofSize: 14)
        detailLabel.textColor = .secondaryLabelColor
        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        clockLabel.font = .monospacedSystemFont(ofSize: 40, weight: .thin)
        clockLabel.textColor = .tertiaryLabelColor

        let text = NSStackView(views: [titleLabel, detailLabel, statusLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 10

        let row = NSStackView(views: [text, clockLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 20
        row.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 28, right: 28)
        row.translatesAutoresizingMaskIntoConstraints = false

        panel.contentView = row
        panel.center()
        panel.orderFrontRegardless()
    }

    func checkPermissions() {
        bTrusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        log("perm  ", "Accessibility (CGEventTap): \(bTrusted ? "granted" : "DENIED")")

        // Recorded for the file, but rev 1 already settled this: the physical device is
        // seized by Karabiner-Core-Service, so channel C is unavailable by design.
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey as String: 1278,
                                          kIOHIDProductIDKey as String: 33] as CFDictionary)
        let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        log("C hid ", r == kIOReturnSuccess
            ? "physical HHKB open OK (unexpected — rev 1 got ExclusiveAccess)"
            : String(format: "physical HHKB open FAILED (0x%08X)%@", r,
                     r == kIOReturnExclusiveAccess ? " ExclusiveAccess — seized by Karabiner" : ""))
    }

    func startTap() {
        let mask = (1 << CGEventType.flagsChanged.rawValue)
                 | (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: CGEventMask(mask),
                                          callback: tapCallback, userInfo: nil) else {
            log("B tap ", "tapCreate returned nil")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(),
                           CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("B tap ", "port created (reception still unproven until events arrive)")
    }

    func advance() {
        let s = steps[stepIndex]
        stepStarted = Date()
        titleLabel.stringValue = s.title
        detailLabel.stringValue = s.detail
        log("step  ", "\(stepIndex): \(s.title)  — expecting: \(s.expectation)")
    }

    func tick() {
        let s = steps[stepIndex]
        let elapsed = Date().timeIntervalSince(stepStarted)
        clockLabel.stringValue = String(format: "%.0f", max(0, s.seconds - elapsed))
        statusLabel.stringValue = "events this step: \(perStep[stepIndex]?.count ?? 0)   total: \(bEvents)"
        guard elapsed >= s.seconds else { return }
        if stepIndex + 1 < steps.count {
            stepIndex += 1
            advance()
        } else {
            finish()
        }
    }

    func finish() {
        log("──────", "")
        for (i, s) in steps.enumerated() {
            let evs = perStep[i] ?? []
            log("result", "step \(i) \(s.title) — \(evs.count) event(s)")
            for e in evs { log("      ", "    \(e)") }
        }
        log("──────", "")

        if !bTrusted || bEvents == 0 {
            log("VERDICT", "NO DATA — channel B \(bTrusted ? "saw nothing at all" : "was not permitted"). Nothing established.")
            exit(0)
        }

        // Step 3 is the control: cmd+A must be visible to any working tap. If it is
        // absent, the user did not perform the protocol and the run says nothing.
        let step3 = perStep[3] ?? []
        let sawCmdA = step3.contains { $0.contains("keycode=0") && $0.contains("cmd") }
        // Steps 1 and 4 are the measurement: a lone hold.
        let holds = (perStep[1] ?? []) + (perStep[4] ?? [])
        let sawCmdDuringHold = holds.contains { $0.contains("flagsChanged") && $0.contains("cmd") }

        if !sawCmdA {
            log("VERDICT", "NO DATA — control failed: step 3 (⌘+A) produced no cmd keyDown, so the protocol was not performed as scripted.")
        } else if sawCmdDuringHold {
            log("VERDICT", "HYPOTHESIS REFUTED — a lone ⌘ hold DID produce a cmd flagsChanged. The lazy modifier is not blocking it, and a conventional hold trigger works here.")
        } else {
            log("VERDICT", "HYPOTHESIS CONFIRMED — ⌘+A was visible (control ok) but a lone ⌘ hold produced no cmd flagsChanged across \(holds.count) event(s) in steps 1 and 4. Every tool that triggers on that event is structurally blind on this setup.")
        }
        exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
