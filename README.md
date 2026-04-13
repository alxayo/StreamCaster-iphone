# StreamCaster iOS

StreamCaster is an iOS live streaming app built with SwiftUI.
It supports RTMP and RTMPS ingest endpoints, local preview, and basic stream health/state reporting.

## What Is In This Repository

- `StreamCaster/`: app source code
- `StreamCasterTests/`: unit/smoke tests
- `project.yml`: XcodeGen specification (source of truth for project generation)
- `StreamCaster.xcodeproj/`: generated Xcode project

## Requirements

- macOS with Xcode installed (tested with modern Xcode versions)
- Xcode command line tools selected:

```bash
xcode-select -p
```

- XcodeGen installed (recommended via Homebrew):

```bash
brew install xcodegen
```

- iOS Simulator runtime installed in Xcode (for simulator runs)
- Apple Developer account + provisioning setup (for real device runs)

## Quick Start (Simulator)

1. Generate the Xcode project from `project.yml`:

```bash
xcodegen generate
```

2. Open the generated project:

```bash
open StreamCaster.xcodeproj
```

3. In Xcode:
- Select the `StreamCaster` scheme
- Select an iPhone simulator device
- Build and run (`Cmd+R`)

### CLI Build/Test (Simulator)

You can also build and test without opening Xcode:

```bash
xcodebuild \
  -project StreamCaster.xcodeproj \
  -scheme StreamCaster \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  build test
```

If your simulator name differs, list devices first:

```bash
xcrun simctl list devices
```

## Configure Streaming Endpoint

Before starting a stream:

1. Open the app
2. Go to **Settings > Endpoint**
3. Create and save an endpoint profile with:
- RTMP URL (e.g. `rtmp://...` or `rtmps://...`)
- Stream key
- Optional username/password if your server requires auth
4. Mark the profile as default (recommended)

Notes:
- `rtmps://` is preferred for encrypted transport.
- `rtmp://` is allowed but shown as a security warning.

## Minimal Mode

Toggle Minimal Mode during streaming to hide the camera preview and save battery.
The stream continues normally — only the on-device display is turned off.
Ideal for long, stationary streams (e.g., on a tripod).

## Running On a Real Device

### 1. Prepare Signing

In Xcode:

1. Open `StreamCaster.xcodeproj`
2. Select target **StreamCaster**
3. Go to **Signing & Capabilities**
4. Enable **Automatically manage signing**
5. Select your Team
6. Ensure a unique bundle identifier if needed

### 2. Connect Device

- Connect iPhone via USB (or enable wireless debugging)
- Unlock device and trust this Mac
- In Xcode, select your physical device as run destination

### 3. Enable Developer Mode (if prompted)

On the device:
- Settings > Privacy & Security > Developer Mode
- Reboot and confirm

### 4. Run App

- Press `Cmd+R` in Xcode
- Accept certificate trust prompts if shown

### 5. Grant Permissions

At first launch, allow:
- Camera
- Microphone

Without these permissions, preview/streaming will not work.

## Real Device Streaming Test Checklist

Use this checklist for a meaningful end-to-end validation:

1. Endpoint profile saved and selected/default
2. Camera preview appears in main stream screen
3. Tap Start and observe status transition:
- Ready -> Connecting -> Live
4. Verify ingest on your streaming server/dashboard
5. Verify stop action returns app to non-live state cleanly
6. Test network interruption (toggle Wi-Fi/cellular) and confirm behavior

## Running Tests

### In Xcode

- Select `StreamCaster` scheme
- Product > Test (`Cmd+U`)

### In CLI

```bash
xcodebuild \
  -project StreamCaster.xcodeproj \
  -scheme StreamCaster \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  test
```

Current test target includes startup smoke tests (basic view load checks).

## Troubleshooting

### No Preview In Simulator

The iOS simulator camera backend can fail or be unavailable depending on host setup/runtime. This may result in a black preview even when code is correct.

Recommendation: validate preview and actual streaming on a real device.

### Tapping Start Appears To Do Nothing

Check:

- Endpoint profile exists and is saved
- Default profile is set (or at least one profile exists)
- URL/stream key are valid
- App has camera/microphone permissions
- Network can reach your ingest endpoint

The app now surfaces startup/connection failures in an in-app error banner.

### Build Fails After Dependency/Project Changes

Regenerate project and rebuild:

```bash
xcodegen generate
xcodebuild -project StreamCaster.xcodeproj -scheme StreamCaster -destination 'platform=iOS Simulator,name=iPhone 16' build
```

### Signing Issues On Device

- Confirm Team is selected for target signing
- Ensure bundle ID is unique for your account if needed
- Reconnect device and trust developer certificate
- Clean build folder (`Shift+Cmd+K`) and rebuild

## Video Codec Support

StreamCaster supports three video codecs:

| Codec | Quality | Compatibility | Device Requirement |
|-------|---------|--------------|-------------------|
| H.264 | Good | Universal | All iPhones |
| H.265 (HEVC) | Better (~40% savings) | Enhanced RTMP servers | All iPhones |
| AV1 | Best (~50% savings) | Enhanced RTMP servers | iPhone 15 Pro+ |

Select the codec per-endpoint in the Endpoint Settings screen.

## Development Notes

- This repo uses XcodeGen; avoid manual long-term edits to generated project settings.
- Keep `project.yml` as the source of truth, then regenerate `StreamCaster.xcodeproj`.

## Useful Commands

```bash
# Generate Xcode project
xcodegen generate

# Build + test on simulator
xcodebuild -project StreamCaster.xcodeproj -scheme StreamCaster -destination 'platform=iOS Simulator,name=iPhone 16' build test

# Install app to a booted simulator (replace app path as needed)
xcrun simctl install booted ~/Library/Developer/Xcode/DerivedData/.../Build/Products/Debug-iphonesimulator/StreamCaster.app

# Launch app by bundle id
xcrun simctl launch booted com.port80.app
```
