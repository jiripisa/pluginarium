import Testing
@testable import PluginariumCore

/// Holds whoever waits on it until `open()`.
@MainActor
private final class Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        let current = waiters
        waiters = []
        current.forEach { $0.resume() }
    }
}

private func id(_ name: String) -> PluginID { PluginID(type: "aumu", subtype: name, manufacturer: "Test") }

@MainActor
private func settle() async {
    for _ in 0..<50 { await Task.yield() }
}

/// A scheduler whose sleep and loads are held until the test lets them go.
@MainActor
private final class Rig {
    let sleeping = Gate()
    var loadGates: [String: Gate] = [:]
    var loads: [String] = []
    var running = 0
    var maxRunning = 0
    var failing: Set<String> = []
    var delivered: [String] = []
    var scheduler: ProbeScheduler<Int>!

    init() {
        scheduler = ProbeScheduler<Int>(
            delay: .milliseconds(300),
            sleep: { [sleeping] _ in await sleeping.wait() },
            load: { [unowned self] plugin in
                loads.append(plugin.subtype)
                running += 1
                maxRunning = max(maxRunning, running)
                let gate = loadGates[plugin.subtype, default: Gate()]
                loadGates[plugin.subtype] = gate
                await gate.wait()
                running -= 1
                return failing.contains(plugin.subtype) ? nil : 1
            }
        )
    }

    func request(_ name: String) {
        scheduler.request(id(name)) { [unowned self] plugin, result in
            delivered.append("\(plugin.subtype):\(result == nil ? "failed" : "ok")")
        }
    }

    func rest() async {
        await settle()
        sleeping.open()
        await settle()
    }

    func finishLoad(_ name: String) async {
        await settle()
        loadGates[name]?.open()
        await settle()
    }
}

@MainActor
@Suite("ProbeScheduler")
struct ProbeSchedulerTests {

    @Test("Rapid selection changes load only the one that settled")
    func debounce() async {
        let rig = Rig()
        rig.request("A")
        rig.request("B")
        rig.request("C")
        await rig.rest()
        #expect(rig.loads == ["C"])
        await rig.finishLoad("C")
        #expect(rig.delivered == ["C:ok"])
    }

    @Test("Nothing loads before the selection has rested")
    func nothingBeforeRest() async {
        let rig = Rig()
        rig.request("A")
        await settle()
        #expect(rig.loads.isEmpty)
    }

    @Test("One load at a time, and the latest selection wins when it ends")
    func oneAtATimeLatestWins() async {
        let rig = Rig()
        rig.request("A")
        await rig.rest()
        #expect(rig.loads == ["A"])
        rig.request("B")
        await rig.rest()
        rig.request("C")
        await rig.rest()
        #expect(rig.loads == ["A"])
        await rig.finishLoad("A")
        #expect(rig.loads == ["A", "C"])
        await rig.finishLoad("C")
        #expect(rig.maxRunning == 1)
        #expect(rig.delivered == ["A:ok", "C:ok"])
    }

    @Test("A queued plugin that is no longer selected is not loaded")
    func staleQueueDropped() async {
        let rig = Rig()
        rig.request("A")
        await rig.rest()
        rig.request("B")
        await rig.rest()
        rig.request("C")
        await settle()
        await rig.finishLoad("A")
        #expect(rig.loads == ["A"])
    }

    @Test("A plugin that failed is not loaded again")
    func failedNotReloaded() async {
        let rig = Rig()
        rig.failing = ["A"]
        rig.request("A")
        await rig.rest()
        await rig.finishLoad("A")
        #expect(rig.delivered == ["A:failed"])
        rig.request("A")
        await rig.rest()
        #expect(rig.loads == ["A"])
        #expect(rig.delivered == ["A:failed", "A:failed"])
    }

    @Test("Nothing starts or is delivered after stop")
    func stopped() async {
        let rig = Rig()
        rig.request("A")
        await settle()
        rig.scheduler.stop()
        await rig.rest()
        #expect(rig.loads.isEmpty)

        rig.request("B")
        await rig.rest()
        rig.request("C")
        await rig.rest()
        rig.scheduler.stop()
        await rig.finishLoad("B")
        #expect(rig.loads == ["B"])
        #expect(rig.delivered.isEmpty)
    }
}
