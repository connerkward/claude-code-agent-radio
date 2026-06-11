// say-notify-overlay.swift — RTS "incoming transmission" overlay (non-activating panel,
// never steals focus). Stacks down a corner; cards reflow up to close gaps AND shrink
// so that however many are up, they all fit on screen. Look is env-driven (SN_*).
//   say-notify-overlay "<message>" <portrait.gif> [seconds] [static.gif]
import Cocoa
import Darwin

final class FloatPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

func envS(_ k: String) -> String? { let v = ProcessInfo.processInfo.environment[k]; return (v?.isEmpty ?? true) ? nil : v }
func envF(_ k: String, _ d: CGFloat) -> CGFloat { envS(k).flatMap { Double($0) }.map { CGFloat($0) } ?? d }
func hexColor(_ hex: String?, _ d: NSColor) -> NSColor {
    guard var h = hex else { return d }
    if h.hasPrefix("#") { h.removeFirst() }
    guard h.count == 6, let n = Int(h, radix: 16) else { return d }
    return NSColor(calibratedRed: CGFloat((n>>16)&255)/255, green: CGFloat((n>>8)&255)/255, blue: CGFloat(n&255)/255, alpha: 1)
}

// registration + rank among live cards
let slotBase = NSTemporaryDirectory() + "say-notify-slots"
let myPid = ProcessInfo.processInfo.processIdentifier
let myName = String(format: "%020.6f", Date().timeIntervalSince1970) + "-\(myPid)"
let slotPath = slotBase + "/" + myName
try? FileManager.default.createDirectory(atPath: slotBase, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(atPath: slotPath, withIntermediateDirectories: false)
func liveSortedNames() -> [String] {
    let fm = FileManager.default
    var live: [String] = []
    for name in (try? fm.contentsOfDirectory(atPath: slotBase)) ?? [] {
        guard let dash = name.lastIndex(of: "-"), let pid = Int32(name[name.index(after: dash)...]) else { continue }
        if pid == myPid || kill(pid, 0) == 0 { live.append(name) } else { try? fm.removeItem(atPath: slotBase + "/" + name) }
    }
    return live.sorted()
}

let args = CommandLine.arguments
let message = args.count > 1 ? args[1] : "Incoming transmission."
let dir = (args[0] as NSString).deletingLastPathComponent
let gif = args.count > 2 ? args[2] : dir + "/say-notify-portrait.gif"
let seconds = args.count > 3 ? (Double(args[3]) ?? 5.0) : 5.0
let staticGif = args.count > 4 ? args[4] : dir + "/say-notify-static.gif"

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// design dimensions (env-driven) — cards scale DOWN from these to fit.
// Small by default (glanceable HUD chips, not big panels); tune in the lookdev.
let W = envF("SN_W", 132), IMG = envF("SN_IMG", 104), HDR: CGFloat = 15, MSG: CGFloat = 30
let H = HDR + IMG + MSG
let teal  = hexColor(envS("SN_TEAL"),  NSColor(calibratedRed: 0.37, green: 0.88, blue: 0.84, alpha: 1))
let amber = hexColor(envS("SN_AMBER"), NSColor(calibratedRed: 1.0,  green: 0.81, blue: 0.42, alpha: 1))
let bg    = hexColor(envS("SN_BG"),    NSColor(calibratedRed: 0.039, green: 0.063, blue: 0.063, alpha: 1)).withAlphaComponent(0.97)
let borderW = envF("SN_BORDER", 0.5), radius = envF("SN_RADIUS", 20)
let staticRest = envF("SN_STATIC", 0.10)
let crtOn = envF("SN_CRTON", 220)/1000.0, crtOff = envF("SN_CRTOFF", 240)/1000.0
let corner = envS("SN_CORNER") ?? "br"   // bottom-right; cards stack upward
let M: CGFloat = 14, GAP: CGFloat = 8
let portraitImg = NSImage(contentsOfFile: gif)
let noiseImg = NSImage(contentsOfFile: staticGif)

let panel = FloatPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
panel.isFloatingPanel = true; panel.becomesKeyOnlyIfNeeded = true; panel.hidesOnDeactivate = false
// Window level: keep the HUD above normal app windows but NOT at the shielding
// `.screenSaver` (1000) level — that high a level triggers an occlusion-state change in
// Chromium/Electron terminals (cmux) that blurs the focused input, forcing a click-back to
// resume typing. `.statusBar` (25) floats above all ordinary windows without that side
// effect. Override with SN_LEVEL (raw NSWindow.Level rawValue) if a different stack is needed.
let lvl = Int(envF("SN_LEVEL", 25))
panel.level = NSWindow.Level(rawValue: lvl)
panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
panel.ignoresMouseEvents = true
// .moveToActiveSpace (not .canJoinAllSpaces): an all-spaces window can trigger a
// space/focus event in the foreground app when it's ordered in. Move to the
// active space instead, and never participate in cycling/activation.
panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .stationary, .ignoresCycle]

func buildCard(_ s: CGFloat) -> NSView {
    let w = W*s, h = H*s, hh = HDR*s, mm = MSG*s, ii = IMG*s
    let v = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h)); v.wantsLayer = true
    v.layer?.backgroundColor = bg.cgColor
    v.layer?.borderColor = teal.withAlphaComponent(0.85).cgColor
    v.layer?.borderWidth = max(0.5, borderW*s); v.layer?.cornerRadius = radius*s; v.layer?.masksToBounds = true
    let dot = NSView(frame: NSRect(x: 8*s, y: h-hh+4*s, width: 7*s, height: 7*s)); dot.wantsLayer = true
    dot.layer?.backgroundColor = NSColor(calibratedRed: 1, green: 0.36, blue: 0.30, alpha: 1).cgColor
    dot.layer?.cornerRadius = 3.5*s; v.addSubview(dot)
    let hdr = NSTextField(labelWithString: "TRANSMISSION")
    hdr.frame = NSRect(x: 21*s, y: h-hh+2*s, width: w-28*s, height: hh-3*s)
    hdr.font = NSFont(name: "Courier New Bold", size: 9*s) ?? .boldSystemFont(ofSize: 9*s)
    hdr.textColor = teal; v.addSubview(hdr)
    let pic = NSImageView(frame: NSRect(x: 2*s, y: mm, width: w-4*s, height: ii))
    pic.imageScaling = .scaleProportionallyUpOrDown; pic.image = portraitImg; pic.animates = true; v.addSubview(pic)
    let noise = NSImageView(frame: pic.frame)
    noise.imageScaling = .scaleAxesIndependently; noise.image = noiseImg; noise.animates = true
    noise.alphaValue = staticRest; v.addSubview(noise)
    let msg = NSTextField(wrappingLabelWithString: message)
    msg.frame = NSRect(x: 8*s, y: 5*s, width: w-16*s, height: mm-7*s)
    msg.font = NSFont(name: "Courier New", size: 11*s) ?? .monospacedSystemFont(ofSize: 11*s, weight: .regular)
    msg.textColor = amber; msg.maximumNumberOfLines = 2; v.addSubview(msg)
    return v
}

// rank, count, and the scale that lets N cards fit the screen height
func layoutInfo() -> (rank: Int, scale: CGFloat) {
    let names = liveSortedNames(); let n = max(1, names.count)
    let rank = names.firstIndex(of: myName) ?? 0
    let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let perCard = (vf.height - 2*M - CGFloat(n-1)*GAP) / CGFloat(n)
    let scale = min(1.0, max(0.35, perCard / H))   // shrink to fit; floor so never invisible
    return (rank, scale)
}
func frameFor(_ rank: Int, _ s: CGFloat) -> NSRect {
    let w = W*s, h = H*s
    let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let x = (corner == "tl" || corner == "bl") ? vf.minX + M : vf.maxX - w - M
    let top = (corner == "tl" || corner == "tr")
    let y = top ? vf.maxY - M - h - CGFloat(rank)*(h+GAP) : vf.minY + M + CGFloat(rank)*(h+GAP)
    return NSRect(x: x, y: y, width: w, height: h)
}
func lineFrame(_ f: NSRect) -> NSRect { NSRect(x: f.minX, y: f.midY - 2, width: f.width, height: 4) }

var (rank0, curScale) = layoutInfo()
panel.contentView = buildCard(curScale)
let cur = frameFor(rank0, curScale)
panel.setFrame(lineFrame(cur), display: true); panel.alphaValue = 1
panel.orderFrontRegardless()
NSAnimationContext.runAnimationGroup { c in c.duration = crtOn; panel.animator().setFrame(cur, display: true) }

var dismissing = false
func dismiss() {
    if dismissing { return }; dismissing = true
    NSAnimationContext.runAnimationGroup({ c in c.duration = crtOff; panel.animator().setFrame(lineFrame(panel.frame), display: true) },
        completionHandler: { try? FileManager.default.removeItem(atPath: slotPath); app.terminate(nil) })
}
// reflow + rescale: keep this card at its rank, resized so all live cards fit
Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
    if dismissing { return }
    let (rank, scale) = layoutInfo()
    if abs(scale - curScale) > 0.01 { curScale = scale; panel.contentView = buildCard(scale) }   // rebuild at new size
    let tf = frameFor(rank, scale)
    if abs(tf.minY - panel.frame.minY) > 1 || abs(tf.width - panel.frame.width) > 1 {
        NSAnimationContext.runAnimationGroup { c in c.duration = 0.22; panel.animator().setFrame(tf, display: true) }
    }
}
signal(SIGUSR1, SIG_IGN)
let sig = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
sig.setEventHandler { dismiss() }; sig.resume()
Timer.scheduledTimer(withTimeInterval: max(0.8, seconds), repeats: false) { _ in dismiss() }
app.run()
