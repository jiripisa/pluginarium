import Foundation

/// Decides when the Add dialog probes a plugin. A plugin load cannot be cancelled, so: a selection
/// must rest for `delay` before it is probed, at most one load runs at a time, the latest selection
/// wins when the running load ends, nothing starts after `stop()`, and a plugin whose load failed is
/// not loaded again for the life of the scheduler.
@MainActor
public final class ProbeScheduler<Result: Sendable> {
    public typealias Sleep = @MainActor (Duration) async throws -> Void
    public typealias Load = @MainActor (PluginID) async -> Result?
    public typealias Deliver = @MainActor (PluginID, Result?) -> Void

    private let delay: Duration
    private let sleep: Sleep
    private let load: Load

    private var deliver: Deliver?
    private var latest: PluginID?
    private var generation = 0
    private var inFlight: PluginID?
    private var pending: PluginID?
    private var failed: Set<PluginID> = []

    public init(
        delay: Duration,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        load: @escaping Load
    ) {
        self.delay = delay
        self.sleep = sleep
        self.load = load
    }

    /// Probes `plugin` once the selection has rested. `deliver` gets the result, or nil when the
    /// plugin could not be loaded, now or earlier; it is not called after `stop()`.
    public func request(_ plugin: PluginID, deliver newDeliver: @escaping Deliver) {
        deliver = newDeliver
        latest = plugin
        pending = nil
        generation += 1
        let mine = generation
        if failed.contains(plugin) {
            newDeliver(plugin, nil)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            try? await sleep(delay)
            guard generation == mine, self.deliver != nil else { return }
            settle(plugin)
        }
    }

    /// The dialog is gone or nothing is selected: nothing more starts and nothing is delivered. A
    /// load already running ends by itself.
    public func stop() {
        deliver = nil
        latest = nil
        pending = nil
        generation += 1
    }

    private func settle(_ plugin: PluginID) {
        guard inFlight == nil else {
            pending = plugin
            return
        }
        inFlight = plugin
        Task { [weak self] in
            guard let self else { return }
            let result = await load(plugin)
            finish(plugin, result)
        }
    }

    private func finish(_ plugin: PluginID, _ result: Result?) {
        inFlight = nil
        if result == nil { failed.insert(plugin) }
        deliver?(plugin, result)
        if let next = pending, next == latest, !failed.contains(next) {
            pending = nil
            settle(next)
        }
    }
}
