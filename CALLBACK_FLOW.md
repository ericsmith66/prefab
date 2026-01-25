# Callback Logic & Polling Event Flow

## Overview

The system supports **two mechanisms** for detecting HomeKit accessory changes:

1. **Native Callbacks** - HomeKit automatically notifies us when values change
2. **Polling** - We manually read values at intervals and detect changes

Both paths ultimately trigger the **same webhook event**.

---

## The Flow

### 1. Native Callback Path (Preferred)

```
HomeKit Accessory Value Changes
        ↓
HomeKit Framework Detects Change
        ↓
Calls: accessory(_:didUpdateValueFor:)  [Line 377]
        ↓
Increments: nativeCallbackCount
        ↓
Calls: handleCharacteristicUpdate(source: "NATIVE")  [Line 380]
        ↓
Logs: 🔥 NATIVE [count] AccessoryName - Characteristic: Value
        ↓
Sends Webhook POST to configured URL  [Lines 398-425]
```

### 2. Polling Path (Fallback)

```
Timer Fires (every 5 seconds by default)  [Line 238]
        ↓
Loop through pollingAccessories  [Line 241]
        ↓
For each characteristic:
  - Store oldValue = characteristic.value  [Line 250]
  - Call characteristic.readValue()  [Line 252]
  - Get newValue = characteristic.value  [Line 254]
        ↓
Compare: if (oldValue != newValue)  [Lines 257-258]
        ↓
VALUE CHANGED! Call accessory(_:didUpdateValueFor:)  [Line 260]
        ↓
THIS TRIGGERS THE SAME NATIVE CALLBACK PATH!
        ↓
Increments: pollingCallbackCount  [Line 390]
        ↓
Calls: handleCharacteristicUpdate(source: "POLLING")
        ↓
Logs: 🔄 POLLING [count] AccessoryName - Characteristic: Value
        ↓
Sends Webhook POST to configured URL
```

---

## Key Insight: Polling Reuses Native Callback!

**Line 260 is critical:**
```swift
self.accessory(item.accessory, didUpdateValueFor: characteristic)
```

When polling detects a change, it **manually calls** the same delegate method that HomeKit would call natively. This means:

✅ **Same webhook sent** for both native and polling  
✅ **Same logging format**  
✅ **Same tracking** (just marked as "POLLING" source)  
✅ **No code duplication**

---

## When Do We Fire Events?

### Native Callbacks
**Event fires:** Immediately when HomeKit notifies us (pushed by accessories)

**Characteristics:**
- ⚡ **Instant** - No delay
- 📱 **Real-time** - As fast as HomeKit receives updates
- ✅ **Reliable** - HomeKit manages the connection
- 🎯 **Selective** - Only accessories that support notifications

### Polling
**Event fires:** Only when we detect a value change during polling

**Characteristics:**
- ⏱️ **Delayed** - Up to `polling.intervalSeconds` (default: 5s)
- 🔄 **Periodic checks** - Every N seconds
- 📊 **Comprehensive** - Can poll any readable characteristic
- 🔋 **Resource intensive** - More network/CPU usage

---

## Example Scenario

Let's say you have a temperature sensor that updates every 30 seconds:

### Scenario A: Native Callbacks Work ✅

```
T+0s:  Temperature = 20.0°C
T+30s: Temperature changes to 20.5°C
       → HomeKit immediately calls accessory(_:didUpdateValueFor:)
       → Webhook fires instantly
       → Log: 🔥 NATIVE [1] TempSensor - Current Temperature: 20.5
```

### Scenario B: Native Callbacks Broken, Polling Enabled 🔄

```
T+0s:  Temperature = 20.0°C
T+5s:  Poll #1: Read value → still 20.0°C → no change, no event
T+10s: Poll #2: Read value → still 20.0°C → no change, no event
T+15s: Poll #3: Read value → still 20.0°C → no change, no event
T+20s: Poll #4: Read value → still 20.0°C → no change, no event
T+25s: Poll #5: Read value → still 20.0°C → no change, no event
T+30s: Temperature changes to 20.5°C (but we don't know yet)
T+35s: Poll #6: Read value → now 20.5°C → CHANGE DETECTED!
       → Manually call accessory(_:didUpdateValueFor:)
       → Webhook fires
       → Log: 🔄 POLLING [1] TempSensor - Current Temperature: 20.5
```

**Notice:** With polling, there's a **5-second delay** (or whatever your interval is) before we detect the change.

---

## The Unified Event Handler

Both paths converge at `handleCharacteristicUpdate()` (Line 383):

```swift
private func handleCharacteristicUpdate(
    _ accessory: HMAccessory, 
    characteristic: HMCharacteristic, 
    source: String  // "NATIVE" or "POLLING"
) {
    // 1. Track statistics
    if source == "NATIVE" {
        nativeCallbackCount++
        nativeAccessories.insert(accessoryId)
    } else {
        pollingCallbackCount++
        pollingOnlyAccessories.insert(accessoryId)  // Only if no native callbacks yet
    }
    
    // 2. Log the event
    logToFile("🔥/🔄 [source] [count] Accessory - Characteristic: Value")
    
    // 3. Send webhook notification
    POST to webhook URL {
        "type": "characteristic_updated",
        "accessory": "AccessoryName",
        "characteristic": "CharacteristicName",
        "value": actualValue,
        "timestamp": "2026-01-25T19:10:36Z"
    }
}
```

---

## Why Both Methods?

### Problem: Some Accessories Don't Support Native Callbacks

HomeKit accessories vary in quality:

- **Good accessories:** Support `supportsEventNotification` property
  - Send updates immediately via HomeKit notifications
  - We subscribe to these at startup (Line 126)
  
- **Bad/cheap accessories:** Don't support notifications
  - HomeKit never tells us when they change
  - We must manually poll them to detect changes

### Solution: Hybrid Approach

1. **Attempt native subscription** for all accessories at startup
2. **Add all to polling list** as fallback (Line 147-151)
3. **Track which ones actually send native callbacks** (Line 387)
4. **Report shows which method each accessory uses** (logAccessoryReport)

---

## Configuration Control

You can control event firing via `config.json`:

### Disable All Events
```json
{
  "webhook": {
    "enabled": false  // No events will be sent
  }
}
```

### Native Only (No Polling)
```json
{
  "polling": {
    "enabled": false  // Only native callbacks trigger events
  }
}
```

### Filter Specific Accessories
```json
{
  "deviceRegistry": {
    "mode": "whitelist",
    "devices": ["Living Room Light"]  // Only this accessory sends events
  }
}
```

### Adjust Polling Frequency
```json
{
  "polling": {
    "intervalSeconds": 10.0  // Check every 10 seconds instead of 5
  }
}
```

---

## Webhook Payload

Both native and polling send the **exact same webhook format**:

```json
{
  "type": "characteristic_updated",
  "accessory": "Living Room Light",
  "characteristic": "Brightness",
  "value": 75,
  "timestamp": "2026-01-25T19:10:36Z"
}
```

**Note:** The webhook does NOT include whether it came from native or polling. That's only tracked internally for reporting purposes.

---

## Performance Considerations

### Native Callbacks
- ✅ **Zero CPU overhead** when idle
- ✅ **Zero network overhead** when idle
- ✅ **Instant notifications**
- ❌ **Not supported by all accessories**

### Polling
- ❌ **Constant CPU usage** (timer every N seconds)
- ❌ **Constant network traffic** (reading all characteristics)
- ❌ **Delayed detection** (up to interval duration)
- ✅ **Works with any readable characteristic**

**Recommendation:** Use native callbacks whenever possible, polling only as fallback.

---

## Debugging: Which Method Is Being Used?

Check the log or wait for the periodic report (every 60 seconds):

```
╔════════════════════════════════════════════════════════════════════
║ 📊 ACCESSORY CALLBACK REPORT
╠════════════════════════════════════════════════════════════════════
║ Native Callback Count: 863
║ Polling Callback Count: 45
╠════════════════════════════════════════════════════════════════════
║ Accessories with Native Callbacks: 3 (60.0%)
║ Accessories with Polling Only: 1 (20.0%)
╠════════════════════════════════════════════════════════════════════
║ 🔥 NATIVE CALLBACK ACCESSORIES:
║   • Living Room Light
║   • Kitchen Sensor
║   • Master Thermistat
╠════════════════════════════════════════════════════════════════════
║ 🔄 POLLING-ONLY ACCESSORIES:
║   • Cheap Sensor (doesn't support native callbacks)
╠════════════════════════════════════════════════════════════════════
```

---

## Summary

1. **Two paths, one destination:** Native and polling both call `handleCharacteristicUpdate()`
2. **Polling manually triggers the delegate:** Line 260 reuses the native callback mechanism
3. **Events fire on value change only:** Not on every poll, only when different
4. **Single webhook payload:** Server receives same format regardless of source
5. **Tracking is internal:** Reports show which accessories use which method
6. **Configuration controls all:** Enable/disable polling, webhooks, and filter accessories

The key design principle: **Polling is a fallback that simulates native callbacks** when accessories don't support them natively.
