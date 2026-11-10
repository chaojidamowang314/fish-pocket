// Objective-C the SwiftUI side needs. Keep this to headers that are free of
// Node: the addon's N-API entry is for the engine, not for the app.
#import "DshNativeCapabilities.h"
#import "DshNativeAudit.h"
#import "DshNativeBridge.h"
// alarm and weather are the capabilities whose native half is Swift: AlarmKit
// and WeatherKit have no Objective-C surface at all, so these protocols are
// what the Swift providers register against. Node-free like the rest of this list.
#import "DshAlarmBridge.h"
#import "DshWeatherBridge.h"
