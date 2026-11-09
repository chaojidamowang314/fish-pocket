// Objective-C the SwiftUI side needs. Keep this to headers that are free of
// Node: the addon's N-API entry is for the engine, not for the app.
#import "DshNativeCapabilities.h"
#import "DshNativeAudit.h"
#import "DshNativeBridge.h"
// alarm is the one capability whose native half is Swift: AlarmKit has no
// Objective-C surface at all, so this protocol is what the Swift provider
// registers against. Node-free like the rest of this list.
#import "DshAlarmBridge.h"
