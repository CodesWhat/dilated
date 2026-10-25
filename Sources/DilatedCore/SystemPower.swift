import Foundation
import IOKit.ps

public enum SystemPower {
  public static func read() -> PowerState {
    var state = PowerState(lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return state }
    state.onBattery =
      IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
      == kIOPSBatteryPowerValue
    let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
    for source in sources {
      guard
        let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
          as? [String: Any],
        description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
        let current = description[kIOPSCurrentCapacityKey] as? Int,
        let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
      else { continue }
      state.batteryPercent = min(100, max(0, current * 100 / maximum))
      break
    }
    return state
  }
}
