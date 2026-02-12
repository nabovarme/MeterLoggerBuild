#!/bin/bash

# --- Configuration ---
ESPTOOL="python3 -u ./esptool/esptool.pyz"  # Path to esptool, unbuffered
CHIP="esp8266"                              # Explicit chip type
PORT="/dev/tty.usbserial-A9M9DV3R"
MIN_BLOCK=0x1000                             # 4 KB minimum block
BASE_TIMEOUT=5                               # Base timeout for MIN_BLOCK in seconds

BAD_SECTORS=()
DEBUG=0

# --- Parse flags ---
while getopts "d" opt; do
    case $opt in
        d) DEBUG=1 ;;
    esac
done
shift $((OPTIND-1))

# Optional start address
START_ADDR=0x0
if [ $# -ge 1 ]; then
    START_ADDR=$1
fi

# --- Function to detect flash size ---
get_flash_size() {
    local size_str
    size_str=$($ESPTOOL -p $PORT flash_id 2>/dev/null | grep -i "Detected flash size" | awk '{print $4}')
    case $size_str in
        512KB) echo 0x80000 ;;
        1MB)   echo 0x100000 ;;
        2MB)   echo 0x200000 ;;
        4MB)   echo 0x400000 ;;
        8MB)   echo 0x800000 ;;
        *)     echo "Unknown flash size, defaulting to 1MB" >&2; echo 0x100000 ;;
    esac
}

FLASH_SIZE=$(get_flash_size)
echo "Flash size detected: 0x$(printf "%X" $FLASH_SIZE) bytes"

echo "Starting binary-tree flash scan on $PORT from 0x$(printf "%X" $START_ADDR) (chip: $CHIP)"
[ $DEBUG -eq 1 ] && echo "Debug mode: ON (real-time esptool output)"
echo

# --- Read a block with proportional timeout and real-time debug ---
read_block() {
    local addr=$1
    local size=$2

    TMP_FILE=$(mktemp)
    OUT_FILE=$(mktemp)

    # --- DEBUG: print block being read ---
    [ $DEBUG -eq 1 ] && echo "Reading sector 0x$(printf "%05X" $addr) - 0x$(printf "%05X" $((addr+size-1))) ..."

    # Calculate proportional timeout
    local dec_size=$((size))
    local dec_min=$((MIN_BLOCK))
    local proportional_timeout=$(( BASE_TIMEOUT * dec_size / dec_min ))

    # Determine timeout command
    if command -v gtimeout >/dev/null 2>&1; then
        TIMEOUT_CMD="gtimeout $proportional_timeout"
    else
        TIMEOUT_CMD="timeout $proportional_timeout"
    fi

    if [ $DEBUG -eq 1 ]; then
        # Real-time output via tee
        $TIMEOUT_CMD $ESPTOOL --chip $CHIP -p $PORT read_flash $addr $size "$TMP_FILE" 2>&1 | tee "$OUT_FILE"
        EXIT_CODE=${PIPESTATUS[0]}
    else
        # Silent mode, capture output only
        $TIMEOUT_CMD $ESPTOOL --chip $CHIP -p $PORT read_flash $addr $size "$TMP_FILE" >"$OUT_FILE" 2>&1
        EXIT_CODE=$?
    fi

    OUTPUT=$(cat "$OUT_FILE")
    rm -f "$TMP_FILE" "$OUT_FILE"

    # Determine if block read succeeded
    if [ $EXIT_CODE -ne 0 ] || ! echo "$OUTPUT" | grep -q "completed"; then
        return 1
    else
        return 0
    fi
}

# --- Recursive binary-tree scan ---
scan_block() {
    local addr=$1
    local size=$2

    if read_block $addr $size; then
        printf "Block 0x%05X-%05X OK\n" $addr $((addr+size-1))
    else
        local dec_size=$((size))
        local dec_min=$((MIN_BLOCK))

        if [ $dec_size -le $dec_min ]; then
            printf "❌ Bad sector at 0x%05X\n" $addr
            BAD_SECTORS+=($(printf "0x%05X" $addr))
        else
            local half=$((dec_size / 2))
            scan_block $addr $half
            scan_block $((addr+half)) $half
        fi
    fi
}

# --- Start scanning ---
scan_block $START_ADDR $FLASH_SIZE

# --- Summary ---
echo
echo "=== SCAN COMPLETE ==="
if [ ${#BAD_SECTORS[@]} -eq 0 ]; then
    echo "All sectors OK ✅"
else
    echo "Bad sectors found:"
    for s in "${BAD_SECTORS[@]}"; do
        echo "  $s"
    done
fi
