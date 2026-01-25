#!/bin/bash
# Script to retrieve HomeBase debug log

# Find the app's container
CONTAINER=$(find ~/Library/Containers -name "com.ericsmith66.prefab*" -type d 2>/dev/null | head -1)

if [ -z "$CONTAINER" ]; then
    echo "Error: Could not find Prefab app container"
    echo "Searching in common locations..."
    find ~/Library/Containers -name "*prefab*" -type d 2>/dev/null
    exit 1
fi

LOG_FILE="$CONTAINER/Data/Documents/homebase_debug.log"

if [ -f "$LOG_FILE" ]; then
    echo "Found log file: $LOG_FILE"
    echo "========================================"
    cat "$LOG_FILE"
    echo "========================================"
    echo ""
    echo "Log file location: $LOG_FILE"
else
    echo "Log file not found at: $LOG_FILE"
    echo "Searching for log file..."
    find "$CONTAINER" -name "homebase_debug.log" 2>/dev/null
fi
