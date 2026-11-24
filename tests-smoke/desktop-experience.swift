import Foundation
var input = DeviceReadinessInput()
assert(input.status == .disconnected)
input.connected = true
assert(input.status == .pairing)
input.paired = true
assert(input.status == .unverified)
input.verified = true
assert(input.status == .enroll)
input.fingerprintCount = 1
assert(input.status == .chooseFeatures)
input.features = [.ssh]
assert(input.status == .ready)
let ssh = SetupPlan(features: [.ssh])
assert(!ssh.needsPassword && !ssh.needsAccessibility && !ssh.needsPAM)
input.features = [.screenUnlock]
assert(input.status == .password)
input.hasPassword = true
assert(input.status == .accessibility)
input.accessibility = true
assert(input.status == .ready)
input.passwordSuspended = true
assert(input.status == .password)
input.features = [.administrator]
assert(input.status == .administrator)
input.pamReady = true; input.battery = 10
assert(input.status == .lowBattery)
input.battery = 80
assert(input.status == .ready)
input.poweredOff = true
assert(input.status == .bluetoothOff)
input.permissionDenied = true
assert(input.status == .bluetoothPermission)
assert(ApprovalPresentation.visible("echo\nhello\u{202E}") == "echo\\u{000A}hello\\u{202E}")
let longCommand = String(repeating: "a", count: 10000) + " --delete"
assert(ApprovalPresentation.visible(longCommand) == longCommand)
print("Desktop experience smoke checks passed")
