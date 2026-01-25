# File Logging Disabled by Default

## Config File Location

```
~/Library/Application Support/Prefab/config.json
```

**Full path:**
```
/Users/ericsmith66/Library/Application Support/Prefab/config.json
```

---

## Change Summary

File logging is now **DISABLED BY DEFAULT** to prevent quarantine issues with high-frequency sensors.

### New Default Configuration

```json
{
  "logging": {
    "enabled": false,
    "logAllCallbacks": false,
    "logOnlyChanges": true,
    "maxCallbacksPerSecond": 10
  }
}
```

---

## What This Means

### ✅ Webhooks Still Work
**File logging OFF does NOT affect webhooks!**

- All callbacks still trigger webhook POST requests
- Your webhook server receives every event
- Only the debug log file is affected

### 📝 Log File Behavior

When `enabled: false`:
- **No callback logs written** to `~/Documents/homebase_debug.log`
- Initialization logs still written (startup info)
- Accessory reports still written (every 60 seconds)
- Error logs still written (if any)

**Only callback logging is disabled** - structural/diagnostic logs remain.

### 🚀 Performance Benefits

With logging disabled:
- **Zero I/O overhead** from callbacks
- **No risk of quarantine** from high-frequency sensors
- **Faster response times**
- **Less disk usage**

---

## Enabling Logging

### Option 1: Edit Config File

```bash
# Edit the config
nano ~/Library/Application\ Support/Prefab/config.json
```

Change `enabled` to `true`:
```json
{
  "logging": {
    "enabled": true,
    "logAllCallbacks": false,
    "logOnlyChanges": true,
    "maxCallbacksPerSecond": 10
  }
}
```

Save and restart the app.

### Option 2: Delete Config (Resets to New Defaults)

```bash
rm ~/Library/Application\ Support/Prefab/config.json
```

App will create new config with `enabled: false` on next launch.

---

## Logging Modes

### Mode 1: Disabled (Default) - Recommended

```json
{
  "logging": {
    "enabled": false
  }
}
```

**Use when:**
- Normal operation
- High-frequency sensors
- Don't need detailed callback logs
- Rely on webhooks

**Result:** No callback logs, webhooks work, no quarantine risk.

---

### Mode 2: Minimal Logging - For Debugging

```json
{
  "logging": {
    "enabled": true,
    "logAllCallbacks": false,
    "logOnlyChanges": true,
    "maxCallbacksPerSecond": 5
  }
}
```

**Use when:**
- Debugging specific issues
- Want to see value changes
- Limited detail needed

**Result:** Only value changes logged, max 5/second.

---

### Mode 3: Full Logging - Troubleshooting

```json
{
  "logging": {
    "enabled": true,
    "logAllCallbacks": true,
    "logOnlyChanges": false,
    "maxCallbacksPerSecond": 50
  }
}
```

**Use when:**
- Deep troubleshooting
- Need to see every callback
- Short-term debugging

**Result:** All callbacks logged, may trigger quarantine if high frequency.

---

## Configuration Options Explained

### `enabled` (boolean) - Master Switch
- `false`: No callback logging to file (webhooks still work)
- `true`: Enable callback logging (subject to rate limits)

### `logAllCallbacks` (boolean)
- `false`: Apply rate limiting and change detection
- `true`: Log every callback (overrides rate limits)

### `logOnlyChanges` (boolean)
- `true`: Only log when value changes (recommended)
- `false`: Log even repeated values

### `maxCallbacksPerSecond` (integer)
- `0`: Unlimited (not recommended)
- `5`: Conservative (very busy sensors)
- `10`: Balanced (default when enabled)
- `20+`: Detailed (may cause issues)

---

## Viewing the Config

```bash
# Pretty print current config
cat ~/Library/Application\ Support/Prefab/config.json | python -m json.tool
```

Or:
```bash
# Quick view
cat ~/Library/Application\ Support/Prefab/config.json
```

---

## Log File Locations

### Callback Logs (affected by `logging.enabled`)
```
~/Documents/homebase_debug.log
```

**Contents when logging disabled:**
- Initialization messages
- Configuration loaded messages
- Accessory setup logs
- Periodic accessory reports
- ❌ NO individual callback logs

**Contents when logging enabled:**
- All of the above
- ✅ Individual callback logs (with rate limiting)

### Xcode Console
Always minimal - only critical messages.

---

## Checking Current Behavior

### Test if logging is working:
```bash
# Watch the log file
tail -f ~/Documents/homebase_debug.log
```

**If logging disabled:** You'll see reports every 60 seconds but NO callback logs between them.

**If logging enabled:** You'll see callback logs: `🔥 NATIVE [123] AccessoryName - Characteristic: Value`

### Trigger a callback:
1. Toggle a light or adjust a thermostat
2. Check the log file
3. If `enabled: false`, you won't see the callback logged
4. But your webhook server should still receive the POST request

---

## Recommended Setup

### For Production/Normal Use:
```json
{
  "logging": {
    "enabled": false
  }
}
```
✅ Best performance, no quarantine risk, webhooks work.

### For Debugging:
```json
{
  "logging": {
    "enabled": true,
    "logAllCallbacks": false,
    "logOnlyChanges": true,
    "maxCallbacksPerSecond": 10
  }
}
```
✅ See what's happening, limited I/O impact.

### After Debugging:
Set `enabled: false` and restart.

---

## Migration from Previous Version

If you have an existing config without the `enabled` field, it will default to `false` on next app launch when the config is regenerated.

To keep your existing config structure:
```bash
# Edit your config
nano ~/Library/Application\ Support/Prefab/config.json
```

Add the `enabled` field to the logging section:
```json
{
  "logging": {
    "enabled": true,  ← Add this line
    "logAllCallbacks": false,
    "logOnlyChanges": true,
    "maxCallbacksPerSecond": 10
  }
}
```

---

## Summary

📍 **Config Location:** `~/Library/Application Support/Prefab/config.json`

🔧 **Default:** `logging.enabled: false`

✅ **Webhooks:** Unaffected, always work

📝 **File Logs:** Disabled by default, enable for debugging

⚡ **Performance:** Best with logging disabled

🛡️ **Quarantine:** Eliminated with default config

**Bottom line:** Logging off by default = fast, stable, no quarantine issues, webhooks still work perfectly!
