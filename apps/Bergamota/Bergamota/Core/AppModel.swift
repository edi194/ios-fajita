import Foundation
import Observation

@Observable
@MainActor
final class AppModel {
    let settings: AppSettings
    let monitor: PhoneMonitor
    let logs: LogStore
    let ci: CIModel
    let build: BuildModel
    let queue: BootQueue
    let remote: RemoteControl
    let tools: PhoneTools
    let flasher: UserdataFlasher
    let hooks = ControlPlaneHooks()

    init() {
        let s = AppSettings()
        settings = s
        let m = PhoneMonitor(settings: s)
        monitor = m
        logs = LogStore(settings: s)
        ci = CIModel(settings: s)
        build = BuildModel(settings: s)
        let t = PhoneTools(settings: s, monitor: m)
        tools = t
        let f = UserdataFlasher(settings: s, monitor: m)
        flasher = f
        let q = BootQueue(settings: s, monitor: m, tools: t, flasher: f)
        queue = q
        remote = RemoteControl(settings: s, monitor: m, queue: q, build: build, logs: logs)
    }

    func start() {
        remote.tools = tools
        remote.bannerProvider = { [unowned self] in self.activityBanner() }
        hooks.rebootToFastboot = { [unowned self] in await self.tools.rebootIOS(to: "fastboot").1 }
        hooks.rebootToBergamota = { [unowned self] in await self.tools.rebootIOS(to: "bergamota").1 }
        build.rescan()
        if DesignPreview.active { DesignPreview.apply(self); return }   // sample states only: no polling, listener or inbox
        monitor.start()
        logs.start()
        remote.start()
    }
}
