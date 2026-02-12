#!/bin/bash

# --- Configuration ---
ESPTOOL="python3 -u ./esptool/esptool.pyz"
PORT="/dev/tty.usbserial-A9M9DV3R"
CHIP="esp8266"
FLASH_SIZE=0x100000   # Default 1MB, will detect later
MIN_BLOCK=0x1000
BASE_TIMEOUT=5
CYCLES=10             # Default stress-test iterations
LOG_FILE="flash_stress_log.txt"
DEBUG=0

# --- Parse flags ---
while getopts "d" opt; do
    case $opt in
        d) DEBUG=1 ;;
    esac
done
shift $((OPTIND-1))

# Optional first argument: cycles
if [ $# -ge 1 ]; then
    CYCLES=$1
fi

echo "Stress-test cycles: $CYCLES"
[ $DEBUG -eq 1 ] && echo "Debug mode: ON (full esptool output)"

# --- Detect flash size automatically ---
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
echo "Stress-test log: $LOG_FILE"

# --- Patterns to test ---
PATTERNS=(AA 55 00 FF)

# --- Helper functions ---
write_pattern() {
    local addr=$1
    local size=$2
    local pattern=$3
    local tmpfile=$(mktemp)
    printf "%${size}s" | tr ' ' "\x$pattern" > "$tmpfile"

    if [ $DEBUG -eq 1 ]; then
        # Full output
        $ESPTOOL -p $PORT --chip $CHIP write_flash $addr "$tmpfile" 2>&1 | tee -a "$LOG_FILE"
    else
        # Quiet mode, only print sector progress
        echo "Writing sector 0x$(printf "%05X" $addr) - 0x$(printf "%05X" $((addr+size-1))) pattern 0x$pattern"
        $ESPTOOL -p $PORT --chip $CHIP write_flash $addr "$tmpfile" > /dev/null 2>&1
    fi

    rm -f "$tmpfile"
}

read_and_compare() {
    local addr=$1
    local size=$2
    local pattern=$3
    local tmpfile=$(mktemp)

    if [ $DEBUG -eq 1 ]; then
        $ESPTOOL -p $PORT --chip $CHIP read_flash $addr $size "$tmpfile" 2>&1 | tee -a "$LOG_FILE"
    else
        echo "Verifying sector 0x$(printf "%05X" $addr) - 0x$(printf "%05X" $((addr+size-1))) pattern 0x$pattern"
        $ESPTOOL -p $PORT --chip $CHIP read_flash $addr $size "$tmpfile" > /dev/null 2>&1
    fi

    local mismatch=$(cmp -n $size -b "$tmpfile" <(printf "%${size}s" | tr ' ' "\x$pattern") 2>&1)
    rm -f "$tmpfile"
    if [ -n "$mismatch" ]; then
        echo "ERROR at 0x$(printf "%05X" $addr) pattern $pattern" | tee -a "$LOG_FILE"
    fi
}

# --- Main stress-test loop ---
echo "Erasing full flash..."
$ESPTOOL -p $PORT --chip $CHIP erase_flash > /dev/null 2>&1

for ((cycle=1; cycle<=CYCLES; cycle++)); do
    echo "=== Cycle $cycle / $CYCLES ==="
    for pattern in "${PATTERNS[@]}"; do
        echo "Writing pattern 0x$pattern..."
        for ((addr=0; addr<FLASH_SIZE; addr+=MIN_BLOCK)); do
            write_pattern $addr $MIN_BLOCK $pattern
        done

        echo "Verifying pattern 0x$pattern..."
        for ((addr=0; addr<FLASH_SIZE; addr+=MIN_BLOCK)); do
            read_and_compare $addr $MIN_BLOCK $pattern
        done
    done
done

echo "Stress-test complete. Check $LOG_FILE for any errors."
