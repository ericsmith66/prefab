# 🔧 Xcode Scheme Fix for Quarantine

## Problem

The `setenv()` call in code happens **too late** - Apple's frameworks are already loaded and logging.

We need to set `OS_ACTIVITY_MODE=disable` **before** the app launches.

---

## Solution: Set in Xcode Scheme

### Step-by-Step Instructions

1. **Open Xcode**
   ```bash
   cd /Users/ericsmith66/development/prefab
   open prefab.xcodeproj
   ```

2. **Edit the Scheme**
   - Click the scheme dropdown next to the Stop button (shows "Prefab")
   - Select **"Edit Scheme..."**
   
   OR
   
   - Press: **Cmd + <** (Command + Less Than)

3. **Go to Run Settings**
   - In the left sidebar, click **"Run"**
   - Make sure "Debug" is selected at top

4. **Add Environment Variable**
   - Click the **"Arguments"** tab
   - Find **"Environment Variables"** section
   - Click the **"+"** button at bottom of that section

5. **Enter the Variable**
   ```
   Name:  OS_ACTIVITY_MODE
   Value: disable
   ```
   - Make sure the checkbox next to it is **checked** (enabled)

6. **Close and Save**
   - Click **"Close"** button
   - The scheme is automatically saved

7. **Clean Build**
   - Product → Clean Build Folder (or press **Cmd+Shift+K**)

8. **Run**
   - Product → Run (or press **Cmd+R**)

---

## Verification

After running with the new scheme:

### Check Environment
```bash
ps e $(pgrep -x Prefab) | tr ' ' '\n' | grep OS_ACTIVITY_MODE
```

Should show:
```
OS_ACTIVITY_MODE=disable
```

### Check Logging
```bash
log show --predicate 'process == "Prefab"' --last 30s | grep -c "HMFActivity"
```

Should show **zero or very few** (was 17,000+)

### Check Console
Xcode console should be **completely quiet** - no HMFActivity spam, no quarantine.

---

## Why This Works

Setting the environment variable in the Xcode scheme:
- ✅ Applied **before** app launches
- ✅ Frameworks see it when they load
- ✅ Prevents os_log initialization
- ✅ Completely suppresses framework logging

Setting it in code (`setenv()` in init):
- ❌ Called **after** frameworks load
- ❌ Too late to affect framework initialization
- ❌ Logging already enabled by the time it runs

---

## Alternative: Launch Arguments

You can also set it via launch arguments (same effect):

In Xcode Scheme → Arguments → Arguments Passed On Launch:
```
-OS_ACTIVITY_MODE disable
```

But environment variable is cleaner.

---

## Important Notes

### This Only Affects Development
The environment variable is only set when running from Xcode. If you:
- Build and distribute the app
- Run it outside Xcode
- Give it to others

They won't have this variable set. But they also won't see the console/quarantine anyway since they're not debugging.

### For Production Distribution

If you want to disable logging in released builds, you can:

1. **Add to Info.plist:**
   ```xml
   <key>OS_ACTIVITY_DT_MODE</key>
   <string>NO</string>
   ```

2. **Or in entitlements:**
   Set logging entitlements to minimum level

But for now, the Xcode scheme fix is sufficient.

---

## Expected Result

After setting this in Xcode scheme and running:

✅ **Console:** Completely silent (no spam)  
✅ **Quarantine:** Never appears  
✅ **HomeKit:** Works normally  
✅ **Webhooks:** Fire normally  
✅ **Callbacks:** Process normally  
✅ **Debugging:** Can still debug your own code  

Only Apple's excessive framework logging is suppressed.

---

## Troubleshooting

### If Still Seeing HMFActivity Logs:

1. **Check the environment variable is actually set:**
   ```bash
   ps e $(pgrep -x Prefab) | grep OS_ACTIVITY_MODE
   ```
   Should show: `OS_ACTIVITY_MODE=disable`

2. **Make sure you closed the scheme editor** (changes auto-save)

3. **Clean build folder** before running

4. **Quit any running Prefab instances** before launching from Xcode

### If Still Seeing Quarantine:

The scheme fix should eliminate it. If not, the only other option is:
- Run Release builds (not Debug)
- Run without Xcode debugger attached

But with the scheme fix, you should be fine.

---

## Summary

1. ✅ Open Xcode
2. ✅ Edit Scheme (Cmd+<)
3. ✅ Run → Arguments → Environment Variables
4. ✅ Add: `OS_ACTIVITY_MODE` = `disable`
5. ✅ Clean Build (Cmd+Shift+K)
6. ✅ Run (Cmd+R)
7. ✅ Enjoy silent console!

Takes 2 minutes to set up, eliminates the quarantine forever.
