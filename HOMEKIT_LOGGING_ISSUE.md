# 🎯 Root Cause Found: Apple's HomeKit Framework Logging

## The Real Problem

The quarantine is **NOT from our code** - it's from **Apple's HomeKit framework**!

### Evidence

```
log show --predicate 'process == "Prefab"' --last 10m
```

**Result:** 97,711 logs in 10 minutes from `HMFoundation`

```
2026-01-25 15:14:07.302 (HMFoundation) HMFActivity
2026-01-25 15:14:07.303 (HMFoundation) HMFActivity
2026-01-25 15:14:07.303 (HMFoundation) HMFActivity
... (40+ times in ONE MILLISECOND!)
2026-01-25 15:14:07.309 QUARANTINED DUE TO HIGH LOGGING VOLUME
```

### What is HMFActivity?

`HMFActivity` is Apple's internal HomeKit Foundation framework logging. Every HomeKit operation (callbacks, reads, subscriptions) triggers these logs.

**We cannot control this** - it's Apple's framework code, not ours.

---

## Why This Happens

With your **very active sensors** (updating every 1-2 seconds), HomeKit is:
1. Processing callbacks constantly
2. Logging every internal operation
3. Creating 100,000+ log entries per 10 minutes
4. Overwhelming the logging system

This is a **known issue** with HomeKit apps that have many accessories.

---

## Solutions

### Option 1: Disable OS Logging for Prefab (Recommended)

Create a launch configuration to disable os_log:

**In Xcode:**
1. Product → Scheme → Edit Scheme
2. Run → Arguments
3. Add Environment Variable:
   - Name: `OS_ACTIVITY_MODE`
   - Value: `disable`

This tells the OS to suppress framework logging for your app.

### Option 2: Build as Release (Not Debug)

Debug builds have more verbose logging. Release builds are quieter.

```bash
xcodebuild -project prefab.xcodeproj -scheme Prefab -configuration Release
```

### Option 3: Filter HomeKit Logging

Add to your app's `Info.plist` or scheme:

```xml
<key>OS_ACTIVITY_DT_MODE</key>
<string>NO</string>
```

### Option 4: Run Without Xcode Debugger

The quarantine only affects the console. If you run the app without Xcode attached:

```bash
# Build first
xcodebuild -project prefab.xcodeproj -scheme Prefab -configuration Release

# Run directly (not from Xcode)
open /path/to/Prefab.app
```

The logs still happen, but you won't see the quarantine message.

---

## Implementing Option 1 (Best Solution)

### Step 1: Edit Scheme in Xcode

1. Open `prefab.xcodeproj` in Xcode
2. Click on the scheme dropdown (near Play button) → **Edit Scheme**
3. Select **Run** in left sidebar
4. Click **Arguments** tab
5. Under **Environment Variables**, click **+**
6. Add:
   ```
   Name:  OS_ACTIVITY_MODE
   Value: disable
   ```
7. Click **Close**

### Step 2: Rebuild and Run

```bash
# Clean build
Product → Clean Build Folder (Cmd+Shift+K)

# Run
Product → Run (Cmd+R)
```

---

## What This Does

`OS_ACTIVITY_MODE=disable` tells macOS to:
- ✅ Suppress os_log() calls from frameworks
- ✅ Reduce HMFoundation logging
- ✅ Prevent quarantine messages
- ❌ Does NOT affect your app's functionality
- ❌ Does NOT affect webhooks

**The app works exactly the same**, just without the framework spam.

---

## Alternative: Programmatic Approach

We can also set this in code, but it must be done VERY early:

```swift
// In prefabApp.swift, at the very top of init
import os.activity

@main
struct PrefabApp: App {
    init() {
        // Disable excessive HomeKit framework logging
        setenv("OS_ACTIVITY_MODE", "disable", 1)
        
        // Rest of init...
    }
}
```

But this may not work if the frameworks are already loaded.

---

## Verification

After setting `OS_ACTIVITY_MODE=disable`:

```bash
log show --predicate 'process == "Prefab"' --last 2m | grep -c "HMFActivity"
```

Should show **dramatically fewer** or **zero** HMFActivity logs.

---

## Why Our Logging Fixes Still Matter

Even though the quarantine is from HomeKit framework:
- ✅ We eliminated our own logging overhead
- ✅ We reduced file I/O to zero
- ✅ We improved app performance
- ✅ We made our code cleaner

Now we just need to silence Apple's framework logging.

---

## Expected Result

After implementing Option 1:
- ✅ No quarantine messages
- ✅ Clean console
- ✅ HomeKit still works
- ✅ Webhooks still work
- ✅ All callbacks still processed

---

## Summary

**The Problem:**
- Apple's HomeKit framework logs 100,000+ times per 10 minutes
- This is THEIR code, not ours
- We cannot change their logging behavior

**The Solution:**
- Set `OS_ACTIVITY_MODE=disable` environment variable
- This suppresses framework logging system-wide for the app
- No impact on functionality

**Next Step:**
Edit Xcode scheme → Add environment variable → Rebuild → Run

---

## Testing

1. Edit scheme and add `OS_ACTIVITY_MODE=disable`
2. Clean build folder
3. Run app
4. Watch console - should be **completely silent**
5. Verify webhooks still work
6. No quarantine message!

Let me know if you need help setting this in Xcode!
