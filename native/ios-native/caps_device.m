// device.info: what the agent can tell about the phone it is running on, with
// no permission of any kind. Useful on its own ("is the battery low enough that
// I should stop this long job?") and the cheapest way to prove the whole
// engine -> addon -> framework path works.
#import "dsh_ios_native.h"
#import "DshNativeCapabilities.h"
#import <UIKit/UIKit.h>

/// Battery level reads -1 until monitoring is switched on, and switching it on
/// is a UIKit call, so it has to happen on the main thread.
///
/// Synchronously, though: this used to dispatch_async and then read the level
/// right away, which meant the FIRST call always reported an unknown battery —
/// and the agent normally only asks once, so "how much battery do I have" was
/// answered with "unknown" every time. Verified on an iPhone: attempt 1 nil,
/// attempts 2 and 3 correct.
///
/// Waiting is safe from Node's thread (the app never blocks the main thread on
/// the engine), and a call that already runs on the main thread just enables it
/// inline. UIKit still needs a moment after the switch before it reports a
/// level, which is what DshNativePrepare() at launch is for.
static void enable_battery_monitoring(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    void (^enable)(void) = ^{ UIDevice.currentDevice.batteryMonitoringEnabled = YES; };
    if ([NSThread isMainThread]) {
      enable();
    } else {
      dispatch_sync(dispatch_get_main_queue(), enable);
    }
  });
}

void DshNativePrepare(void) {
  // Switched on at launch so the level is ready long before an agent asks.
  enable_battery_monitoring();
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

  // Read UIDevice on the main thread, which is where UIKit expects to be asked.
  // Reading from Node's thread returned an unknown battery on the first call and
  // the real one afterwards (checked on an iPhone), so the value was not simply
  // late — it was read from the wrong thread.
  __block float level;
  __block UIDeviceBatteryState batteryState;
  __block NSString *model, *systemName, *systemVersion;
  __block BOOL isPad;
  void (^read)(void) = ^{
    UIDevice *device = UIDevice.currentDevice;
    level = device.batteryLevel;
    batteryState = device.batteryState;
    model = device.model;
    systemName = device.systemName;
    systemVersion = device.systemVersion;
    isPad = device.userInterfaceIdiom == UIUserInterfaceIdiomPad;
  };
  if ([NSThread isMainThread]) {
    read();
  } else {
    dispatch_sync(dispatch_get_main_queue(), read);
  }

  NSProcessInfo *process = NSProcessInfo.processInfo;

  reply(@{
    @"model": model ?: @"",
    @"systemName": systemName ?: @"",
    @"systemVersion": systemVersion ?: @"",
    // iPad and iPhone differ in what the agent should attempt (window layout,
    // how much work is reasonable), so name it rather than making it guess.
    @"idiom": isPad ? @"pad" : @"phone",
    @"batteryLevel": level < 0 ? (id)NSNull.null : @(roundf(level * 100)),
    @"batteryState": battery_state_name(batteryState),
    @"lowPowerMode": @(process.lowPowerModeEnabled),
    @"thermalState": @(process.thermalState),
    @"availableBytes": available_bytes(),
    @"processorCount": @(process.processorCount),
  }, nil);
}
