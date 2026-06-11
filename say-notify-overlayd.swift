// say-notify-overlayd.swift — PERSISTENT overlay daemon for the RTS "incoming
// transmission" cards. One borderless, click-through, non-activating window is
// created ONCE and left ordered-front; each alert is a subview faded in/out.
// Because no window is created or re-ordered per alert, the Ghostty/cmux text
// input is never blurred (the focus theft came from orderFront-ing a fresh
// window each time). The hook talks to the daemon by dropping tiny files in a
// watched dir: "<id>.card" (TSV: text, portrait, tealHex) to show, "<id>.dismiss"
// to remove. Idempotent: a second launch exits if one is already running.
//   swiftc -O say-notify-overlayd.swift -o say-notify-overlayd
//   say-notify-overlayd            # run the daemon (the hook launches it)
import Cocoa
import Darwin

final class FloatPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
func envS(_ k: String) -> String? { let v = ProcessInfo.processInfo.environment[k]; return (v?.isEmpty ?? true) ? nil : v }
func envF(_ k: String, _ d: CGFloat) -> CGFloat { envS(k).flatMap { Double($0) }.map { CGFloat($0) } ?? d }
func hexColor(_ hex: String?, _ d: NSColor) -> NSColor {
    guard var h = hex, !h.isEmpty else { return d }
    if h.hasPrefix("#") { h.removeFirst() }
    guard h.count == 6, let n = Int(h, radix: 16) else { return d }
    return NSColor(calibratedRed: CGFloat((n>>16)&255)/255, green: CGFloat((n>>8)&255)/255, blue: CGFloat(n&255)/255, alpha: 1)
}

// single-instance guard via a pidfile + flock-style mkdir lock
let lockDir = NSTemporaryDirectory() + "say-notify-overlayd.lock"
if mkdir(lockDir, 0o755) != 0 {
    // someone holds it — but verify they're alive (stale lock after a crash)
    let pf = lockDir + "/pid"
    if let s = try? String(contentsOfFile: pf, encoding: .utf8), let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)), kill(pid, 0) == 0 {
        exit(0)   // a live daemon already runs
    }
    // stale: take it over
}
try? String(ProcessInfo.processInfo.processIdentifier).write(toFile: lockDir + "/pid", atomically: true, encoding: .utf8)

// ---- look (read once at launch; SN_* env) --------------------------------
let W = envF("SN_W", 132), IMG = envF("SN_IMG", 104), HDR: CGFloat = 15, MSG: CGFloat = 30
let H = HDR + IMG + MSG
let amber = hexColor(envS("SN_AMBER"), NSColor(calibratedRed: 1.0, green: 0.81, blue: 0.42, alpha: 1))
let bg    = hexColor(envS("SN_BG"), NSColor(calibratedRed: 0.039, green: 0.063, blue: 0.063, alpha: 1)).withAlphaComponent(0.97)
let borderW = envF("SN_BORDER", 0.5), radius = envF("SN_RADIUS", 16)
let staticRest = envF("SN_STATIC", 0.10)
let corner = envS("SN_CORNER") ?? "br"
let M: CGFloat = 14, GAP: CGFloat = 8
let fadeDur = 0.22, safetySec: TimeInterval = 90
let scriptDir = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
let staticGif = scriptDir + "/say-notify-static.gif"
let noiseImg = NSImage(contentsOfFile: staticGif)

// ---- the one persistent window -------------------------------------------
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
let panel = FloatPanel(contentRect: screen, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
panel.isFloatingPanel = true; panel.becomesKeyOnlyIfNeeded = true; panel.hidesOnDeactivate = false
panel.level = NSWindow.Level(rawValue: Int(envF("SN_LEVEL", 25)))
panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
panel.ignoresMouseEvents = true
panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .stationary, .ignoresCycle]
let root = NSView(frame: screen); root.wantsLayer = true
panel.contentView = root
panel.orderFrontRegardless()   // the ONE and only orderFront, at daemon start

// ---- active cards --------------------------------------------------------
final class Card {
    let id: String; let view: NSView; let teal: NSColor; let text: String; let portrait: NSImage?
    var dismissAt: Date
    init(id: String, teal: NSColor, text: String, portrait: NSImage?) {
        self.id = id; self.teal = teal; self.text = text; self.portrait = portrait
        self.view = NSView(); self.dismissAt = Date().addingTimeInterval(safetySec)
    }
}
var cards: [Card] = []

func buildCardView(_ c: Card, _ s: CGFloat) -> NSView {
    let w = W*s, h = H*s, hh = HDR*s, mm = MSG*s, ii = IMG*s
    let v = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h)); v.wantsLayer = true
    v.layer?.backgroundColor = bg.cgColor
    v.layer?.borderColor = c.teal.withAlphaComponent(0.85).cgColor
    v.layer?.borderWidth = max(0.5, borderW*s); v.layer?.cornerRadius = radius*s; v.layer?.masksToBounds = true
    let dot = NSView(frame: NSRect(x: 8*s, y: h-hh+4*s, width: 7*s, height: 7*s)); dot.wantsLayer = true
    dot.layer?.backgroundColor = NSColor(calibratedRed: 1, green: 0.36, blue: 0.30, alpha: 1).cgColor
    dot.layer?.cornerRadius = 3.5*s; v.addSubview(dot)
    let hdr = NSTextField(labelWithString: "TRANSMISSION")
    hdr.frame = NSRect(x: 21*s, y: h-hh+2*s, width: w-28*s, height: hh-3*s)
    hdr.font = NSFont(name: "Courier New Bold", size: 9*s) ?? .boldSystemFont(ofSize: 9*s)
    hdr.textColor = c.teal; v.addSubview(hdr)
    let pic = NSImageView(frame: NSRect(x: 2*s, y: mm, width: w-4*s, height: ii))
    pic.imageScaling = .scaleProportionallyUpOrDown; pic.image = c.portrait; pic.animates = true; v.addSubview(pic)
    let noise = NSImageView(frame: pic.frame)
    noise.imageScaling = .scaleAxesIndependently; noise.image = noiseImg; noise.animates = true
    noise.alphaValue = staticRest; v.addSubview(noise)
    let msg = NSTextField(wrappingLabelWithString: c.text)
    msg.frame = NSRect(x: 8*s, y: 5*s, width: w-16*s, height: mm-7*s)
    msg.font = NSFont(name: "Courier New", size: 11*s) ?? .monospacedSystemFont(ofSize: 11*s, weight: .regular)
    msg.textColor = amber; msg.maximumNumberOfLines = 2; v.addSubview(msg)
    return v
}

func scaleFor(_ n: Int) -> CGFloat {
    let vf = NSScreen.main?.visibleFrame ?? screen
    let perCard = (vf.height - 2*M - CGFloat(max(0, n-1))*GAP) / CGFloat(max(1, n))
    return min(1.0, max(0.35, perCard / H))
}
func frameFor(_ rank: Int, _ s: CGFloat) -> NSRect {
    let w = W*s, h = H*s
    let vf = NSScreen.main?.visibleFrame ?? screen
    let x = (corner == "tl" || corner == "bl") ? vf.minX + M : vf.maxX - w - M
    let top = (corner == "tl" || corner == "tr")
    let y = top ? vf.maxY - M - h - CGFloat(rank)*(h+GAP) : vf.minY + M + CGFloat(rank)*(h+GAP)
    return NSRect(x: x, y: y, width: w, height: h)
}

func relayout(animated: Bool) {
    let s = scaleFor(cards.count)
    for (rank, c) in cards.enumerated() {
        let tf = frameFor(rank, s)
        // rebuild the inner card at the current scale, keep the wrapper (c.view)
        c.view.subviews.forEach { $0.removeFromSuperview() }
        let inner = buildCardView(c, s)
        inner.frame = NSRect(x: 0, y: 0, width: tf.width, height: tf.height)
        c.view.addSubview(inner)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = fadeDur; c.view.animator().frame = tf }
        } else { c.view.frame = tf }
    }
}

func addCard(id: String, text: String, portrait: NSImage?, teal: NSColor) {
    if cards.contains(where: { $0.id == id }) { return }
    let c = Card(id: id, teal: teal, text: text, portrait: portrait)
    c.view.alphaValue = 0; c.view.wantsLayer = true
    root.addSubview(c.view)
    cards.append(c)
    relayout(animated: false)
    NSAnimationContext.runAnimationGroup { ctx in ctx.duration = fadeDur; c.view.animator().alphaValue = 1 }
}
func removeCard(id: String) {
    guard let idx = cards.firstIndex(where: { $0.id == id }) else { return }
    let c = cards.remove(at: idx)
    NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = fadeDur; c.view.animator().alphaValue = 0 },
        completionHandler: { c.view.removeFromSuperview() })
    relayout(animated: true)
}

// ---- watch the request dir ----------------------------------------------
let cardDir = NSTemporaryDirectory() + "say-notify-cards"
try? FileManager.default.createDirectory(atPath: cardDir, withIntermediateDirectories: true)
let fm = FileManager.default
Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
    // expire safety-timed-out cards
    let now = Date()
    for c in cards where c.dismissAt < now { removeCard(id: c.id) }
    // process request files
    guard let names = try? fm.contentsOfDirectory(atPath: cardDir) else { return }
    for name in names.sorted() {
        let path = cardDir + "/" + name
        if name.hasSuffix(".card") {
            let id = String(name.dropLast(5))
            if let raw = try? String(contentsOfFile: path, encoding: .utf8) {
                let f = raw.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\t")
                let text = f.count > 0 ? f[0] : "Incoming transmission."
                let portPath = f.count > 1 ? f[1] : ""
                let tealHex = f.count > 2 ? f[2] : ""
                addCard(id: id, text: text,
                        portrait: portPath.isEmpty ? nil : NSImage(contentsOfFile: portPath),
                        teal: hexColor(tealHex, NSColor(calibratedRed: 0.37, green: 0.88, blue: 0.84, alpha: 1)))
            }
            try? fm.removeItem(atPath: path)
        } else if name.hasSuffix(".dismiss") {
            removeCard(id: String(name.dropLast(8)))
            try? fm.removeItem(atPath: path)
        }
    }
}

// exit cleanly if asked
signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler { try? FileManager.default.removeItem(atPath: lockDir); exit(0) }
term.resume()
app.run()
