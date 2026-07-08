# immurok for macOS

Menu bar companion app for the immurok fingerprint authenticator.

## What It Does

- **Screen unlock** — Detects lock screen, types your password on fingerprint match
- **sudo / system auth** — PAM module lets you authenticate with a touch instead of typing passwords
- **SSH agent** — Forwards signing requests to the device for on-device ECDSA signing
- **Fingerprint management** — Enroll, delete, and rename fingerprints
- **Device pairing** — ECDH P-256 key exchange over BLE
- **OTA firmware update** — Push firmware updates to the device wirelessly
- **Key & TOTP management** — Store SSH keys, TOTP secrets, and API credentials on the device
- **Quick Fill OTP** — Press `Ctrl+\` to auto-type the current TOTP code (hotkey customizable)

## Requirements

- macOS 13 (Ventura) or later
- Swift 5.7+
- Xcode Command Line Tools
- Accessibility permission (for keyboard simulation)
- Bluetooth permission

## Build

```bash
swift build -c release
```

Two executables are produced:

| Target | Description |
|--------|-------------|
| `immurokApp` | Menu bar app (GUI) |
| `imk` | CLI tool for terminal workflows |

## Install

### Quick (build + sign + deploy)

From the project root:

```bash
./build-deploy.sh -a -s
```

### Manual

```bash
swift build -c release

# Create app bundle
mkdir -p immurok.app/Contents/{MacOS,Resources}
cp .build/release/immurokApp immurok.app/Contents/MacOS/immurok
cp Resources/Info.plist immurok.app/Contents/
cp Resources/AppIcon.icns immurok.app/Contents/Resources/

# Sign
codesign --force --deep --sign "Your Identity" \
    --entitlements immurok.entitlements \
    --options runtime \
    immurok.app

# Deploy
cp -r immurok.app /Applications/
```

### PAM Module

```bash
cd pam
make
sudo cp pam_immurok.so /usr/lib/pam/
```

Then add to `/etc/pam.d/sudo_local`:

```
auth sufficient pam_immurok.so
```

## Architecture

```
immurokApp (Menu Bar)
├── BLEManager         BLE GATT communication with device
├── PAMSocketServer     Unix socket server for PAM module
├── SSHAgentServer      SSH agent (signs with on-device keys)
├── ImmurokSecurity     ECDH pairing, HMAC verification, Keychain
├── AppDelegate         Screen unlock, fingerprint match handling
├── AppViewModel        UI state, pairing & fingerprint operations
└── SetupManager        First-run wizard

imk (CLI)
├── CLIClient           Communicates with app via Unix socket
└── EnvScanner          Detects environment for context-aware auth

pam/
└── pam_immurok.c       PAM module, talks to app via Unix socket
```

## Source Files

| File | Purpose |
|------|---------|
| `immurokApp.swift` | App entry point, MenuBarExtra + settings window |
| `AppDelegate.swift` | BLE/PAM init, screen unlock, fingerprint match handler |
| `AppViewModel.swift` | UI state management, pairing & fingerprint operations |
| `BLEManager.swift` | BLE GATT communication (custom service + HID) |
| `PAMSocketServer.swift` | Unix socket server at `~/.immurok/pam.sock` |
| `SSHAgentServer.swift` | SSH agent protocol, forwards signing to device |
| `ImmurokSecurity.swift` | ECDH P-256 pairing, HKDF, HMAC verification, Keychain |
| `ContentView.swift` | Settings window UI |
| `FingerprintView.swift` | Fingerprint enrollment & management UI |
| `SetupWizardView.swift` | First-run setup wizard |
| `GlobalHotKey.swift` | System-wide hotkey registration |
| `LocalizationManager.swift` | i18n support (English, Chinese, Japanese) |

## How Authentication Works

### Screen Unlock

1. App detects lock screen via `CGSessionCopyCurrentDictionary`.
2. User touches fingerprint sensor on device.
3. Device sends HMAC-signed notification (`0x21`) over BLE.
4. App verifies HMAC using shared key from ECDH pairing.
5. App loads password from Keychain, simulates keystrokes via `CGEvent`.

### sudo / System Auth

1. `sudo` triggers `pam_immurok.so`.
2. PAM module connects to `~/.immurok/pam.sock`.
3. App receives request, prompts for fingerprint via BLE.
4. On match, app responds `OK` to PAM module.

### Pre-authorization

If a fingerprint match arrives with no pending PAM request, the app stores a pre-auth token. When a PAM request arrives shortly after, the token is consumed immediately — no second touch needed.

## Configuration

Settings are stored in `UserDefaults` and accessible from the menu bar icon:

- **Unlock password** — Stored in macOS Keychain (`com.immurok.password`)
- **sudo auth** — Enable/disable PAM authentication
- **System auth** — Enable/disable authorization dialog authentication
- **SSH agent** — Enable/disable SSH agent server
- **Auto-launch** — Start on login via `SMAppService`

## License

[Apache License 2.0](LICENSE) — including the PAM module in `pam/`. Device firmware is licensed separately under BSL 1.1.
