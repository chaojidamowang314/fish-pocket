// device.info: what the agent can tell about the phone it is running on, with
// no permission of any kind. Useful on its own ("is the battery low enough that
// I should stop this long job?") and the cheapest way to prove the whole
// engine -> addon -> framework path works.
#import "dsh_ios_native.h"
#import <UIKit/UIKit.h>

/// Battery level reads -1 until monitoring is switched on, and switching it on
/// is a UIKit call, so it happens once on the main thread. A reader that lands
/// before the first enable just sees the unknown value.
static void enable_battery_monitoring(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    dsh_native_on_main(^{ UIDevice.currentDevice.batteryMonitoringEnabled = YES; });
  });
}

static NSString *battery_state_name(UIDeviceBatteryState state) {
  switch (state) {
    case UIDeviceBatteryStateUnplugged: return @"unplugged";
    case UIDeviceBatteryStateCharging: return @"charging";
    case UIDeviceBatteryStateFull: return @"full";
    case UIDeviceBatteryStateUnknown:
    default: return @"unknown";
  }
}

/// Free space on the volume the app's own container lives on — the number that
/// decides whether a clone or an install will fit.
static NSNumber *available_bytes(void) {
  NSURL *home = [NSURL fileURLWithPath:NSHomeDirectory()];
  NSDictionary *values = [home resourceValuesForKeys:@[NSURLVolumeAvailableCapacityForImportantUsageKey] error:NULL];
  NSNumber *bytes = values[NSURLVolumeAvailableCapacityForImportantUsageKey];
  return bytes ?: (id)NSNull.null;
}

void dsh_native_device(NSString *op, NSDictionary *args, DshNativeReply reply) {
  (void)op;  // the table admits only "info"
  (void)args;
  enable_battery_monitoring();

  // UIDevice's properties are safe to read off the main thread; only the
  // monitoring switch above is not.
  UIDevice *device = UIDevice.currentDevice;
  float level = device.batteryLevel;
  NSProcessInfo *process = NSProcessInfo.processInfo;

  reply(@{
    @"model": device.model ?: @"",
    @"systemName": device.systemName ?: @"",
    @"systemVersion": device.systemVersion ?: @"",
    // iPad and iPhone differ in what the agent should attempt (window layout,
    // how much work is reasonable), so name it rather than making it guess.
    @"idiom": device.userInterfaceIdiom == UIUserInterfaceIdiomPad ? @"pad" : @"phone",
    @"batteryLevel": level < 0 ? (id)NSNull.null : @(roundf(level * 100)),
    @"batteryState": battery_state_name(device.batteryState),
    @"lowPowerMode": @(process.lowPowerModeEnabled),
    @"thermalState": @(process.thermalState),
    @"availableBytes": available_bytes(),
    @"processorCount": @(process.processorCount),
  }, nil);
}
