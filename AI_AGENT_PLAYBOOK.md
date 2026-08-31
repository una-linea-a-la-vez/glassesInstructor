# 🤖 Meta Ray-Ban Display: AI Agent Autonomous Playbook

> **Target Audience:** Autonomous AI Coding Agents (LLMs, Subagents, Code Generators).  
> **Target SDK:** Meta Wearables Device Access Toolkit (MWDAT) iOS SDK 0.9.0+.  
> **Purpose:** Machine-readable operational manual to guarantee 100% deterministic, zero-crash interactions with Ray-Ban Meta Display hardware.

---

## 🔒 Invariant Hardware & SDK Rules (DO NOT BREAK)

```
================================================================================
RULE 1: LAZY CONFIGURATION ONLY
Never call Wearables.configure() inside init(), @main, or .onAppear of the root view.
Only call it inside a user-driven async action (e.g. Button tap).

RULE 2: COLD PUBLISHER WAKE-UP
Wearables.shared.devices will remain empty [] unless you actively register a token:
let token = Wearables.shared.addDevicesListener { ... }
Retain this token in self.connectionTokens.

RULE 3: LINK STATE VERIFICATION
Before calling createSession(), wait until device.linkState == .connected.
Calling createSession on a .connecting device throws noEligibleDevice.

RULE 4: SESSION START HANDSHAKE AWAIT
After session.start(), poll session.state until it reaches .started.
Calling session.addDisplay() or session.addCamera() while state is .starting
will immediately terminate the firmware connection with sessionAlreadyStopped.

RULE 5: DEVELOPER BYPASS HEADERS & UNIQUE SCHEMES
Always ensure Info.plist / project.yml contains:
- MWDAT -> MetaAppID = "0"
- MWDAT -> AppLinkURLScheme = "metaglassesinstructor://" (Must be unique per app!)
- UISupportedExternalAccessoryProtocols -> ["com.meta.wearables.dat", "com.meta.ar.wearable"]
- CFBundleURLTypes -> CFBundleURLSchemes -> ["metaglassesinstructor"]

RULE 6: PROXIMITY SENSOR DEPENDENCY
The glasses hardware shuts down Wi-Fi transmitters if the nose bridge sensor is disengaged.
Advise wearers or tape the nose bridge during headless lab testing.

RULE 7: SAME WI-FI SUBNET FOR UDP / QUIC
Video streaming frames travel over Wi-Fi UDP. VPNs, proxies, and AdGuard DNS filters
break frame delivery. Disable them.
================================================================================
```

---

## 📐 Deterministic Code Blueprints

### Blueprint A: Resilient Connection Sequence
```swift
// 1. Configure SDK Lazily
try Wearables.configure()

// 2. Check Registration
if Wearables.shared.registrationState != .registered {
    try await Wearables.shared.startRegistration()
    return
}

// 3. Awaken Scan Engine
let token = Wearables.shared.addDevicesListener { _ in }
self.tokens.append(token)

// 4. Poll for linkState == .connected
var attempts = 0
while attempts < 15 {
    if let devId = Wearables.shared.devices.first,
       let dev = Wearables.shared.deviceForIdentifier(devId),
       dev.linkState == .connected {
        break
    }
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    attempts += 1
}

// 5. Create & Start Session
let session = try Wearables.shared.createSession(deviceSelector: SpecificDeviceSelector(device: devId))
try session.start()

// 6. Await .started State
while session.state == .starting {
    try? await Task.sleep(nanoseconds: 500_000_000)
}
guard session.state == .started else { throw SessionError.failed }

// 7. Attach Display
let display = try session.addDisplay()
display.start()

// 8. Attach Camera
if let camera = try session.addCamera() {
    // Camera attached, check permissions before starting stream
}
```

### Blueprint B: HUD Declarative Grid Layout
```swift
import MWDATDisplay

let gridView = FlexBox(direction: .column, spacing: 14, alignment: .center) {
    Text("MAIN MENU", style: .heading, color: .primary)
    
    // Row 1
    FlexBox(direction: .row, spacing: 12, alignment: .center) {
        MWDATDisplay.Button(label: "📷 Camera", style: .primary, onClick: {
            Task { @MainActor in await manager.switchMode(.cameraStream) }
        })
        MWDATDisplay.Button(label: "🎙️ Dictate", style: .primary, onClick: {
            Task { @MainActor in await manager.switchMode(.dictationMic) }
        })
    }
    
    // Row 2
    FlexBox(direction: .row, spacing: 12, alignment: .center) {
        MWDATDisplay.Button(label: "⚡ Status", style: .secondary, onClick: {
            Task { @MainActor in await manager.switchMode(.deviceDiagnostics) }
        })
        MWDATDisplay.Button(label: "📖 Guide", style: .secondary, onClick: {
            Task { @MainActor in await manager.switchMode(.interactiveGuide) }
        })
    }
}

try await display.send(gridView)
```

---

## 🛠️ Project Generation Commands

Whenever you modify `project.yml` or add new Swift files under `Source/`:

```bash
# Execute in GlassesInstructor directory:
xcodegen generate
```

To verify syntax and compilation without opening GUI Xcode:
```bash
xcodebuild -project GlassesInstructor.xcodeproj -scheme GlassesInstructor -destination 'generic/platform=iOS' clean build CODE_SIGNING_ALLOWED=NO
```

---

## 🔄 Adding New Learnings (AI Rule)
When an agent or user discovers a new hardware anomaly, undocumented error, or performance optimization:
1. Append the entry to [`../KNOWLEDGE_BASE.md`](file:///Users/aaron/dev/others/personal/glasses_display/KNOWLEDGE_BASE.md).
2. If it affects SDK lifecycle, update this `AI_AGENT_PLAYBOOK.md` immediately.
