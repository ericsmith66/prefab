# 🚨 CRITICAL: Native Callbacks May Be Broken

## You Were Right!

After your restart at 16:04:58:
- ✅ Webhook events at 16:06:01 (60 seconds later)
- ❌ Log file stopped at 16:04:11 (hasn't updated since)
- ⚠️ **Logging was OFF after restart**
- ⚠️ **Polling was ON at 60-second interval**

**This means the webhook events at 16:06:01 were likely FROM POLLING, not native callbacks!**

---

## What Broke

### Timeline of Our Changes

1. **Disabled file logging** (`logging.enabled: false`)
2. **Set OS_ACTIVITY_MODE=disable** (suppress console logs)
3. **Result:** Native callbacks may have stopped being processed

### Hypothesis

When we disabled logging AND suppressed OS activity logging, we may have inadvertently:
- Broken the callback delegate setup
- Prevented HomeKit from initializing properly
- Caused native callbacks to silently fail

---

## The Evidence

### Before Your Restart (Old App Instance):
- Log file updating (last entry 16:04:11)
- Native callbacks marked `🔥 NATIVE`
- Updates every 5-11 seconds
- **Native callbacks were working**

### After Your Restart (New App Instance):
- Log file NOT updating (stopped at 16:04:11)
- Webhook events ONLY at 60-second intervals
- First webhook 60 seconds after restart
- **Matches polling interval exactly**

---

## Test: Disable Polling, Enable Logging

**New config created:**
```json
{
  "logging": {
    "enabled": true,
    "maxCallbacksPerSecond": 50
  },
  "polling": {
    "enabled": false  ← DISABLED
  }
}
```

### Restart the App and Watch:

**If native callbacks work:**
- Log file will show `🔥 NATIVE` entries
- Webhooks will arrive at irregular intervals (1-10 seconds)
- Many events per minute

**If native callbacks broken:**
- Log file will show nothing (or only POLLING)
- Webhooks will stop completely (polling disabled)
- No events

---

## Possible Causes

### 1. OS_ACTIVITY_MODE Breaking Callbacks

`OS_ACTIVITY_MODE=disable` might suppress more than just logs:
- Could disable activity tracing needed for delegate callbacks
- Could break HomeKit's internal event system
- Could prevent characteristic subscription setup

### 2. Logging Disabled Breaking Initialization

Some of our code might have issues when logging is disabled:
- Early returns in `logToFile()` might skip critical code
- Initialization steps might depend on logging side effects

### 3. Code Bug in Our Changes

Review recent changes to HomeBase.swift:
- Early return when `logging.enabled: false`
- Check if we accidentally disabled callback handling
- Verify delegate setup still happens

---

## How to Debug

### Step 1: Restart App with New Config

```bash
killall Prefab
# Run from Xcode
```

**New config has:**
- Logging: ON
- Polling: OFF

### Step 2: Watch Logs

```bash
tail -f ~/Documents/homebase_debug.log
```

**Look for:**
- Initialization messages
- "HOMEBASE INITIALIZED"
- "Finished setup"
- Any `🔥 NATIVE` or `🔄 POLLING` entries

### Step 3: Check Webhooks

**Watch your webhook server:**
- If receiving events → Check log to see if they're NATIVE or POLLING
- If NO events → Native callbacks broken, polling disabled

### Step 4: Trigger Activity

- Turn lights on/off
- Walk past motion sensors
- Check if events appear

---

## Likely Issues in Code

### Issue 1: Early Return in handleCharacteristicUpdate

**File: `prefab/model/HomeBase.swift`**

```swift
private func handleCharacteristicUpdate(...) {
    // Early exit if logging is disabled
    guard config.enabled else {
        sendWebhook(...)  // <-- Are webhooks sent before return?
        return
    }
    // ... rest of logging code
}
```

**Problem:** If webhook is sent AFTER the guard, it won't fire when logging disabled!

### Issue 2: Delegate Setup Skipped

```swift
override init() {
    // Only setup file logging if enabled in config
    if configManager.config.logging.enabled {
        setupFileLogging()
        logToFile("...")
    }
    
    homeManager.delegate = self  // Is this still executed?
}
```

**Problem:** If delegate setup is inside the if block, it won't happen when logging disabled!

### Issue 3: OS_ACTIVITY_MODE Side Effects

The environment variable might:
- Suppress HomeKit internal activity tracing
- Break event notification system
- Prevent delegate callbacks from firing

---

## Immediate Action Required

### 1. Test With Polling OFF

Restart app with new config (polling OFF, logging ON).

**Result will tell us:**
- Native callbacks working → Events continue
- Native callbacks broken → No events

### 2. Review Recent Code Changes

Check HomeBase.swift for:
- Any code that's skipped when `logging.enabled: false`
- Delegate setup in wrong place
- Webhook calls that happen after early returns

### 3. Consider Removing OS_ACTIVITY_MODE

If native callbacks don't work with OS_ACTIVITY_MODE:
- Remove from Xcode scheme
- Accept console spam
- OR run Release builds (less spam)

---

## What to Check In Code

### File: prefab/model/HomeBase.swift

1. **Line ~60 (init):** Does delegate setup happen regardless of logging config?
2. **Line ~390 (handleCharacteristicUpdate):** Does webhook fire before or after logging check?
3. **Line ~103 (subscription):** Does characteristic.enableNotification still happen?

### Quick Fix If Broken

If native callbacks are broken, likely fix:

```swift
private func handleCharacteristicUpdate(...) {
    let accessoryId = accessory.uniqueIdentifier.uuidString
    
    // Track stats regardless of logging
    if source == "NATIVE" {
        nativeAccessories.insert(accessoryId)
    } else {
        pollingCallbackCount += 1
        if !nativeAccessories.contains(accessoryId) {
            pollingOnlyAccessories.insert(accessoryId)
        }
    }
    
    // Send webhook FIRST (before any early returns)
    sendWebhook(accessory: accessory, characteristic: characteristic)
    
    // Then handle logging (can early return here)
    guard configManager.config.logging.enabled else { return }
    // ... logging code
}
```

**Key:** Send webhooks BEFORE checking if logging is enabled!

---

## Summary

**Your observation was correct:**
- 60-second delay after restart = polling interval
- No native callbacks in that period
- Logging stopped = can't see what's happening

**Likely cause:**
- Our changes broke native callbacks
- Only polling is working now
- Need to identify and fix the bug

**Test:**
- Restart with polling OFF, logging ON
- If no events → Native callbacks broken
- If events → Native callbacks working

**Next:** After restart, report what you see in logs and webhooks!
