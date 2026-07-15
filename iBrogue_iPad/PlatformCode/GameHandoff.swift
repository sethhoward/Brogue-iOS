//
//  GameHandoff.swift
//  Brogue
//
//  Continuity Handoff: advertises an in-progress CE / Brogue SE run to the user's
//  other nearby devices and streams the recording across to resume it. Extracted
//  verbatim from BrogueViewController.swift as part of splitting that file by function.
//

import Foundation

/// Owns the Continuity **Handoff** `NSUserActivity` that advertises an in-progress
/// CE / Brogue SE run to the user's other nearby devices (same Apple ID).
///
/// Phase 1 (current): advertise only — the Handoff affordance appears on a second device
/// while a game is in play. Phases 2–3 add the receive/route handler (`SceneDelegate`) and
/// the continuation-stream transfer + deep-ACK relinquish. Classic is never advertised (its
/// recordings are desync-prone and unsafe to replay). See docs/design/game-handoff.md.
final class GameHandoff: NSObject, NSUserActivityDelegate {
    /// Reverse-DNS activity type. Must exactly match the `NSUserActivityTypes` entry in
    /// Info.plist and be identical across devices (one app) for Handoff to pair.
    static let activityType = "SethHoward.iBrogue.continueGame"

    /// Posted when a Handoff pickup arrives; the payload is also stashed in `pendingReceive` so a
    /// cold launch (no live observer yet) can drain it once the receiving VC appears.
    static let didReceiveNotification = Notification.Name("GameHandoffDidReceive")

    /// The most recent incoming pickup's activity, awaiting processing. Retained so the receiver can
    /// call `getContinuationStreams`; read-and-cleared by the VC.
    static var pendingActivity: NSUserActivity?

    /// The app's version+build — the pre-transfer compatibility proxy carried in the payload. Two
    /// devices on the same app build run the same engine, so matching versions ⟹ replay-compatible.
    /// (The engine's own load-time version check is the exact backstop once the recording streams.)
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"
        return "\(short) (\(build))"
    }

    /// The engine's recording/save-compatibility version for `lineage` — identical across all builds of
    /// the same source (unlike the app version+build), so it's the correct cross-device handoff guard
    /// token. See docs/design/game-handoff.md.
    static func recordingVersion(lineage: String) -> String {
        guard let c = (lineage == "se") ? se_recordingVersion() : ce_recordingVersion() else { return "?" }
        return String(cString: c)
    }

    /// Deliver an incoming Handoff activity (from `scene(_:continue:)` or a cold launch). Validates
    /// the type, stashes the payload, and notifies any live receiver.
    static func deliver(_ activity: NSUserActivity) {
        guard activity.activityType == activityType else { return }
        pendingActivity = activity
        NotificationCenter.default.post(name: didReceiveNotification, object: nil)
    }

    /// Called (on main) when the source begins serving a pickup — freeze the run until it resolves.
    var onServeBegan: (() -> Void)?

    /// Called (on main) after the source finishes serving a pickup — `ok` true if the receiver ACKed;
    /// `detail` carries the failure reason otherwise (for diagnosing device-only bugs).
    var onServeComplete: ((_ ok: Bool, _ detail: String) -> Void)?

    private var activity: NSUserActivity?
    /// Lineage ("ce"/"se") of the run being advertised — tells the source-side stream delegate which
    /// engine's recording to flush. Set in `advertise`.
    private var currentLineage = "se"

    /// Begin/refresh advertising the current run. `lineage` is "ce" or "se". `seed`/`depth`/
    /// `turn` are display + (future) routing metadata; the recording bytes themselves are
    /// streamed live at pickup, not stored here. Must be called on the main thread.
    func advertise(lineage: String, seed: UInt64, depth: Int, turn: Int) {
        currentLineage = lineage
        let activity = self.activity ?? NSUserActivity(activityType: Self.activityType)
        activity.isEligibleForHandoff = true
        activity.supportsContinuationStreams = true   // Phase 3: the receiver pulls the payload over these
        activity.delegate = self                      // source side: userActivity(_:didReceive:outputStream:)
        activity.userInfo = [
            "lineage": lineage,
            "version": Self.recordingVersion(lineage: lineage),   // engine save-compat token (stable across builds)
            "seed": String(seed),          // string to preserve full 64-bit fidelity across the plist round-trip
            "depth": depth,
            "turn": turn,
        ]
        activity.title = Self.bannerTitle(lineage: lineage, depth: depth)
        self.activity = activity
        activity.becomeCurrent()
    }

    /// Stop advertising — returned to title, game over, or nothing resumable.
    /// Must be called on the main thread.
    func stop() {
        activity?.invalidate()
        activity = nil
    }

    // MARK: NSUserActivityDelegate (source side)

    /// The receiver called `getContinuationStreams`; serve the payload over the pair. Phase 3a sends a
    /// placeholder to prove the channel end-to-end; Phase 3b streams the flushed recording bytes.
    func userActivity(_ userActivity: NSUserActivity, didReceive inputStream: InputStream, outputStream: OutputStream) {
        DispatchQueue.main.async { [weak self] in self?.onServeBegan?() }   // freeze the source run
        // Flushing the recording is engine-thread work + a file read, so do it off the main thread,
        // then stream the exact-state bytes to the receiver.
        let lineage = currentLineage
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data = (lineage == "se") ? se_flushRecordingForHandoff() : ce_flushRecordingForHandoff()
            guard let data = data, !data.isEmpty else {
                // No live recording to send; the receiver's watchdog times out and it keeps nothing.
                DispatchQueue.main.async { self?.onServeComplete?(false, "couldn't read the current recording") }
                return
            }
            HandoffTransfer.send(data, input: inputStream, output: outputStream) { result in
                let ok: Bool; let detail: String
                switch result {
                case .success: ok = true; detail = ""
                case .failure(let e): ok = false; detail = "\(e)"
                }
                DispatchQueue.main.async { self?.onServeComplete?(ok, detail) }
            }
        }
    }

    private static func bannerTitle(lineage: String, depth: Int) -> String {
        let engine = (lineage == "se") ? "Brogue SE" : "Brogue CE"
        return depth > 0 ? "\(engine) — Depth \(depth)" : engine
    }
}

/// Drives one side of a Handoff continuation-stream transfer on a private background-thread runloop
/// (continuation streams need a live runloop to pump their events). Retains itself for the duration,
/// so callers fire-and-forget. Phase 3a proves the bidirectional channel + a 1-byte ACK with a
/// placeholder payload; Phase 3b/3c carry the real recording bytes and the destination save/load.
/// See docs/design/game-handoff.md.
final class HandoffTransfer: NSObject, StreamDelegate {
    enum TransferError: Error, CustomStringConvertible {
        case timeout(String), closedEarly(String), stream(String), declined
        var description: String {
            switch self {
            case .timeout(let s):     return "timeout — \(s)"
            case .closedEarly(let s): return "closed early — \(s)"
            case .stream(let s):      return "stream error — \(s)"
            case .declined:           return "receiver declined (it kept its own run)"
            }
        }
    }

    private enum Mode { case send, receive }
    private static let ackByte: UInt8 = 0x06
    private static let nakByte: UInt8 = 0x15
    private static let timeoutSeconds: TimeInterval = 15
    private static var active = Set<HandoffTransfer>()   // main-thread only

    private let input: InputStream
    private let output: OutputStream
    private let mode: Mode
    private let completion: ((Result<Data, Error>) -> Void)?
    // receive: called (main) once the full payload arrives. The caller installs it, then calls the
    // supplied commit closure — true → ACK (source relinquishes), false → NAK (source keeps its run).
    // This is the DEEP ACK: the source only lets go after the destination commits to resuming.
    private let onReady: ((Data, @escaping (Bool) -> Void) -> Void)?

    // send: framed [UInt32 big-endian length][payload], consumed as it's written; then read the reply byte.
    private var outbox: Data
    private var sentAll = false
    // receive: accumulate raw bytes, parse the length prefix, assemble the payload; reply (ACK/NAK) is
    // sent only after the caller commits.
    private var inbox = Data()
    private var expectedLen: Int?
    private var payload = Data()
    private var delivered = false
    private var reply: UInt8?          // ACK/NAK to send, set by commit(); drained in tryWriteReply()

    private var finished = false
    private var watchdog: Timer?

    private init(input: InputStream, output: OutputStream, mode: Mode, framed: Data,
                 completion: ((Result<Data, Error>) -> Void)?,
                 onReady: ((Data, @escaping (Bool) -> Void) -> Void)?) {
        self.input = input
        self.output = output
        self.mode = mode
        self.outbox = framed
        self.completion = completion
        self.onReady = onReady
        super.init()
    }

    /// Source: write a length-prefixed `payload`, then read a 1-byte reply (ACK → success, NAK → the
    /// receiver kept nothing). Framing by length (not stream close) so completion never depends on EOF
    /// propagating across the continuation-stream pair.
    static func send(_ payload: Data, input: InputStream, output: OutputStream,
                     completion: @escaping (Result<Data, Error>) -> Void) {
        var len = UInt32(payload.count).bigEndian
        var framed = Data()
        withUnsafeBytes(of: &len) { framed.append(contentsOf: $0) }
        framed.append(payload)
        launch(HandoffTransfer(input: input, output: output, mode: .send, framed: framed, completion: completion, onReady: nil))
    }

    /// Destination: read the length-prefixed payload, deliver it via `onReady`, and hold the channel
    /// open. The caller invokes the commit closure once it has committed to resuming (true → ACK) or
    /// can't (false → NAK). Deep ACK — no auto-ACK on receipt, so a destination that can't resume never
    /// makes the source relinquish.
    static func receive(input: InputStream, output: OutputStream,
                        onReady: @escaping (Data, @escaping (Bool) -> Void) -> Void) {
        launch(HandoffTransfer(input: input, output: output, mode: .receive, framed: Data(), completion: nil, onReady: onReady))
    }

    private static func launch(_ t: HandoffTransfer) {
        // Pump on the MAIN runloop (always live under UIKit), NOT a private-thread runloop.
        DispatchQueue.main.async {
            active.insert(t)
            t.input.delegate = t
            t.output.delegate = t
            t.input.schedule(in: .main, forMode: .common)
            t.output.schedule(in: .main, forMode: .common)
            t.input.open()
            t.output.open()
            t.watchdog = Timer.scheduledTimer(withTimeInterval: timeoutSeconds, repeats: false) { [weak t] _ in
                guard let t = t else { return }
                t.finish(.failure(TransferError.timeout(t.progress)))
            }
        }
    }

    /// Human-readable transfer state — surfaced in failure alerts so a device-only bug is diagnosable.
    private var progress: String {
        mode == .send
            ? "send sentAll=\(sentAll) remaining=\(outbox.count)"
            : "recv len=\(expectedLen.map(String.init) ?? "nil") payload=\(payload.count) raw=\(inbox.count)"
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasSpaceAvailable where aStream === output: pumpOutput()
        case .hasBytesAvailable where aStream === input:  pumpInput()
        case .endEncountered where aStream === input:     inputEnded()
        case .errorOccurred:
            finish(.failure(TransferError.stream("\(aStream.streamError?.localizedDescription ?? "?") [\(progress)]")))
        default: break
        }
    }

    private func pumpOutput() {
        switch mode {
        case .send:
            guard !outbox.isEmpty else { sentAll = true; return }
            let n = outbox.withUnsafeBytes { raw in
                output.write(raw.bindMemory(to: UInt8.self).baseAddress!, maxLength: outbox.count)
            }
            if n > 0 { outbox.removeFirst(n) }
            else if n < 0 { finish(.failure(TransferError.stream("write [\(progress)]"))); return }
            if outbox.isEmpty { sentAll = true }
        case .receive:
            tryWriteReply()   // drains a pending ACK/NAK once the caller has committed
        }
    }

    private func pumpInput() {
        switch mode {
        case .send:
            var b: UInt8 = 0
            let n = input.read(&b, maxLength: 1)
            if n == 1 {
                if b == HandoffTransfer.ackByte { finish(.success(Data())) }
                else { finish(.failure(TransferError.declined)) }   // NAK: receiver kept its own run
            } else if n < 0 { finish(.failure(TransferError.stream("read reply [\(progress)]"))) }
        case .receive:
            var buf = [UInt8](repeating: 0, count: 8192)
            let n = input.read(&buf, maxLength: buf.count)
            if n > 0 { inbox.append(buf, count: n) }
            else if n < 0 { finish(.failure(TransferError.stream("read [\(progress)]"))); return }
            parseReceive()
        }
    }

    private func parseReceive() {
        if expectedLen == nil, inbox.count >= 4 {
            expectedLen = Int(inbox.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        }
        if let len = expectedLen, inbox.count >= 4 + len, !delivered {
            delivered = true
            payload = inbox.subdata(in: 4 ..< 4 + len)
            onReady?(payload) { [weak self] ok in self?.commit(ok) }   // caller installs, then commits
        }
    }

    /// Caller's decision after installing the payload: true → ACK (source relinquishes), false → NAK
    /// (source keeps its run). Sends the reply byte, then finishes.
    private func commit(_ ok: Bool) {
        guard !finished, reply == nil else { return }
        reply = ok ? HandoffTransfer.ackByte : HandoffTransfer.nakByte
        tryWriteReply()
    }

    private func tryWriteReply() {
        guard var b = reply, !finished, output.hasSpaceAvailable else { return }
        if output.write(&b, maxLength: 1) == 1 {
            finish(b == HandoffTransfer.ackByte ? .success(payload) : .failure(TransferError.declined))
        }
    }

    private func inputEnded() {
        // Length-framed, so EOF isn't our completion signal; seeing it before we're done is an early close.
        if mode == .send { finish(.failure(TransferError.closedEarly("no reply [\(progress)]"))) }
        else if !delivered { finish(.failure(TransferError.closedEarly(progress))) }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard !finished else { return }
        finished = true
        watchdog?.invalidate(); watchdog = nil
        input.close(); output.close()
        input.remove(from: .main, forMode: .common)
        output.remove(from: .main, forMode: .common)
        completion?(result)
        HandoffTransfer.active.remove(self)
    }
}
