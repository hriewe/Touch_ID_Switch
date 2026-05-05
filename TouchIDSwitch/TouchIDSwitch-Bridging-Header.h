// Bridging header: exposes IOBluetooth Objective-C symbols to Swift.
// IOBluetoothDevice, IOBluetoothDeviceInquiry, and helpers live here.
// The private -removeFromFavorites method is not declared in any public header;
// we call it via perform(Selector) with a runtime check (responds(to:)) in BluetoothManager.swift.

#import <IOBluetooth/IOBluetooth.h>
