# Prefab Configuration Guide

Prefab now supports comprehensive configuration through a JSON configuration file. This allows you to customize webhook settings, polling behavior, and device filtering.

## Configuration File Location

The configuration file is automatically created at:

```
~/Library/Application Support/Prefab/config.json
```

On first launch, Prefab creates a default configuration file that you can edit.

## Configuration Structure

### Complete Example

```json
{
  "webhook": {
    "url": "http://localhost:4567/event",
    "authToken": "your-secret-token-here",
    "enabled": true
  },
  "polling": {
    "intervalSeconds": 5.0,
    "enabled": true,
    "reportIntervalSeconds": 60.0
  },
  "deviceRegistry": {
    "mode": "all",
    "devices": []
  }
}
```

## Configuration Options

### Webhook Settings

Configure where HomeKit events are sent:

- **`url`** (string, required): The full URL of your callback server
  - Example: `"http://192.168.1.100:4567/event"`
  
- **`authToken`** (string, optional): Bearer token for webhook authentication
  - If provided, adds `Authorization: Bearer <token>` header to all webhook requests
  - Example: `"my-secret-token-12345"`
  - Set to `null` or omit for no authentication
  
- **`enabled`** (boolean, required): Enable/disable webhook notifications
  - `true`: Send webhook notifications for all events
  - `false`: Disable all webhook notifications

### Polling Settings

Control how often accessories are polled for value changes:

- **`intervalSeconds`** (number, required): How often to poll accessories (in seconds)
  - Default: `5.0` (5 seconds)
  - Minimum recommended: `1.0` (faster may cause performance issues)
  - Example: `10.0` for 10-second intervals
  
- **`enabled`** (boolean, required): Enable/disable polling
  - `true`: Poll accessories at the specified interval
  - `false`: Disable polling (rely only on native callbacks)
  
- **`reportIntervalSeconds`** (number, required): How often to generate accessory reports
  - Default: `60.0` (1 minute)
  - Reports show which accessories use native callbacks vs polling
  - Example: `300.0` for 5-minute reports

### Device Registry

Filter which accessories are polled:

- **`mode`** (string, required): Registry filtering mode
  - `"all"`: Poll all accessories (default)
  - `"whitelist"`: Only poll accessories in the `devices` list
  - `"blacklist"`: Poll all accessories except those in the `devices` list
  
- **`devices`** (array of strings, required): List of device identifiers
  - Can use either **accessory UUIDs** or **accessory names**
  - Empty array `[]` with `"all"` mode polls everything

## Usage Examples

### Example 1: Basic Setup with Authentication

```json
{
  "webhook": {
    "url": "https://my-server.com/homekit/events",
    "authToken": "sk_live_abc123xyz789",
    "enabled": true
  },
  "polling": {
    "intervalSeconds": 5.0,
    "enabled": true,
    "reportIntervalSeconds": 60.0
  },
  "deviceRegistry": {
    "mode": "all",
    "devices": []
  }
}
```

### Example 2: Poll Only Specific Devices

```json
{
  "webhook": {
    "url": "http://localhost:4567/event",
    "authToken": null,
    "enabled": true
  },
  "polling": {
    "intervalSeconds": 10.0,
    "enabled": true,
    "reportIntervalSeconds": 300.0
  },
  "deviceRegistry": {
    "mode": "whitelist",
    "devices": [
      "Living Room Light",
      "Kitchen Sensor",
      "12345678-1234-1234-1234-123456789ABC"
    ]
  }
}
```

### Example 3: Exclude Problematic Devices

```json
{
  "webhook": {
    "url": "http://192.168.1.50:8080/webhook",
    "authToken": "bearer-token-xyz",
    "enabled": true
  },
  "polling": {
    "intervalSeconds": 5.0,
    "enabled": true,
    "reportIntervalSeconds": 60.0
  },
  "deviceRegistry": {
    "mode": "blacklist",
    "devices": [
      "Broken Sensor",
      "Offline Device"
    ]
  }
}
```

### Example 4: Disable Polling (Native Callbacks Only)

```json
{
  "webhook": {
    "url": "http://localhost:4567/event",
    "authToken": null,
    "enabled": true
  },
  "polling": {
    "intervalSeconds": 5.0,
    "enabled": false,
    "reportIntervalSeconds": 60.0
  },
  "deviceRegistry": {
    "mode": "all",
    "devices": []
  }
}
```

## How It Works

### Device Registry Filtering

The device registry allows you to control which accessories are polled:

1. **All Mode** (`"all"`): Polls every accessory in your HomeKit setup
   - Use when you want complete coverage
   - Default mode

2. **Whitelist Mode** (`"whitelist"`): Only polls devices in the list
   - Use when you only care about specific accessories
   - Reduces polling overhead
   - Example: Only poll battery-powered devices

3. **Blacklist Mode** (`"blacklist"`): Polls everything except listed devices
   - Use to exclude problematic or offline devices
   - Example: Skip accessories that don't respond well to polling

### Device Identification

You can identify devices by either:

- **Accessory Name**: `"Living Room Light"`
  - Case-sensitive
  - Must match exactly as shown in HomeKit
  
- **Accessory UUID**: `"12345678-1234-1234-1234-123456789ABC"`
  - More reliable than names (doesn't change if device is renamed)
  - Found in logs or HomeKit APIs

## Configuration Tips

### Finding Device UUIDs

Check the debug log to find accessory UUIDs:

```bash
tail -f ~/Documents/homebase_debug.log
```

The log shows entries like:
```
🔥🔥🔥 NATIVE CALLBACK 🔥🔥🔥 (count: 123)
  Source: NATIVE
  Accessory: 'Living Room Light'
  ...
```

And in the periodic report:
```
║ 🔥 NATIVE CALLBACK ACCESSORIES:
║   • Living Room Light
║   • Kitchen Sensor
```

### Reloading Configuration

Currently, you need to restart the Prefab app to reload configuration changes:

1. Edit `~/Library/Application Support/Prefab/config.json`
2. Stop the Prefab app
3. Restart the Prefab app
4. Check logs to verify new settings are applied

### Webhook Authentication

If your webhook server requires authentication:

1. Set the `authToken` in the config
2. Prefab will add the header: `Authorization: Bearer <your-token>`
3. Your server should validate this token

Example server-side validation (Node.js/Express):

```javascript
app.post('/event', (req, res) => {
  const authHeader = req.headers.authorization;
  if (authHeader !== 'Bearer your-secret-token-here') {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  // Process the webhook...
});
```

## Troubleshooting

### Configuration Not Loading

If your configuration isn't being applied:

1. Check the file exists: `ls -la ~/Library/Application\ Support/Prefab/config.json`
2. Verify JSON syntax: `cat ~/Library/Application\ Support/Prefab/config.json | python -m json.tool`
3. Check console output on app launch for "PREFAB CONFIG" messages
4. Ensure the app has been restarted after config changes

### Invalid Configuration

If the configuration file is invalid or missing, Prefab will:

1. Log an error message
2. Use default configuration values
3. Create a new default config file

### Polling Not Working

If accessories aren't being polled:

1. Verify `polling.enabled` is `true`
2. Check device registry mode and devices list
3. Look for "POLLING TICK" messages in the log
4. Confirm accessories are reachable in HomeKit

## Default Configuration

If no configuration file exists, Prefab uses these defaults:

```json
{
  "webhook": {
    "url": "http://localhost:4567/event",
    "authToken": null,
    "enabled": true
  },
  "polling": {
    "intervalSeconds": 5.0,
    "enabled": true,
    "reportIntervalSeconds": 60.0
  },
  "deviceRegistry": {
    "mode": "all",
    "devices": []
  }
}
```

## Security Considerations

### Protect Your Auth Token

- Never commit your `config.json` with real tokens to version control
- Use environment-specific tokens
- Rotate tokens regularly
- Use HTTPS for webhook URLs in production

### File Permissions

The config file is stored in your user's Application Support directory with standard macOS file permissions. Only your user account can read/write it.

## Example Configuration File

See `config.example.json` in the project root for a template you can copy and customize.
