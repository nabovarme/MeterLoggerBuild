#!/bin/bash

# --- Configuration ---
ESPTOOL="python3 -u ./esptool/esptool.pyz"
CHIP="esp8266"
PORT="/dev/tty.usbserial-A9M9DV3R"
MIN_BLOCK=0x1000
BASE_TIMEOUT=5
DEBUG=0
WRITE_CYCLES=0        # 0 = read-only mode
BAD_SECTORS=()
LOG_FILE="flash_bin_tree_stress_log.txt"
TMP_FILES=()
PATTERNS=(AA 55 00 FF)

# --- Cleanup on exit ---
cleanup() {
    rm -f "${TMP_FILES[@]}" 2>/dev/null
    echo
    echo "=== ABORTED ==="
    if [ ${#BAD_SECTORS[@]} -eq 0 ]; then
        echo "All sectors OK ✅ (so far)"
    else
        echo "Bad sectors found so far:"
        for s in "${BAD_SECTORS[@]}"; do
            echo "  $s"
        done
    fi
    exit
}
trap cleanup SIGINT SIGTERM

# --- Parse flags manually ---
START_ADDR=0x0
while [[ $# -gt 0 ]]; do
    case $1 in
        -d)
            DEBUG=1
            shift
            ;;
        -w)
            if [[ $2 =~ ^[0-9]+$ ]]; then
                WRITE_CYCLES=$2
                shift 2
            else
                WRITE_CYCLES=1
                shift
            fi
            ;;
        *)
            START_ADDR=$1
            shift
            ;;
    esac
done

# --- Detect flash size ---
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
TOTAL_SECTORS=$((FLASH_SIZE / MIN_BLOCK))
PROCESSED_SECTORS=0

echo "Flash size detected: 0x$(printf "%X" $FLASH_SIZE) bytes"
echo "Binary-tree flash scan on $PORT from 0x$(printf "%X" $START_ADDR) (chip: $CHIP)"
if [ $WRITE_CYCLES -gt 0 ]; then
    echo "Write/read cycles per pattern: $WRITE_CYCLES"
else
    echo "Read-only mode (no writing)"
fi
[ $DEBUG -eq 1 ] && echo "Debug mode: ON (full esptool output)"
echo "Log file: $LOG_FILE"
echo

# --- Track progress ---
progress() {
    local addr=$1
    local size=$2
    PROCESSED_SECTORS=$((PROCESSED_SECTORS + size / MIN_BLOCK))
    local pct=$((PROCESSED_SECTORS * 100 / TOTAL_SECTORS))
    echo "[Progress: $pct%] Operating on 0x$(printf "%05X" $addr)-0x$(printf "%05X" $((addr+size-1)))"
}

# --- Write a block (stress mode) ---
write_block() {
    local addr=$1 size=$2 pattern=$3
    local tmpfile=$(mktemp)
    TMP_FILES+=("$tmpfile")
    printf "%${size}s" | tr ' ' "\x$pattern" > "$tmpfile"

    if [ $DEBUG -eq 1 ]; then
        $ESPTOOL -p $PORT --chip $CHIP write_flash $addr "$tmpfile" 2>&1 | tee -a "$LOG_FILE"
    else
        echo "Writing block 0x$(printf "%05X" $addr)-0x$(printf "%05X" $((addr+size-1))) pattern 0x$pattern"
        $ESPTOOL -p $PORT --chip $CHIP write_flash $addr "$tmpfile" > /dev/null 2>&1
    fi
}

# --- Read and verify a block ---
verify_block() {
    local addr=$1 size=$2 pattern=$3
    local tmpfile=$(mktemp)
    TMP_FILES+=("$tmpfile")

    if [ $DEBUG -eq 1 ]; then
        $ESPTOOL -p $PORT --chip $CHIP read_flash $addr $size "$tmpfile" 2>&1 | tee -a "$LOG_FILE"
    else
        echo "Reading block 0x$(printf "%05X" $addr)-0x$(printf "%05X" $((addr+size-1)))"
        $ESPTOOL -p $PORT --chip $CHIP read_flash $addr $size "$tmpfile" > /dev/null 2>&1
    fi

    if [ -n "$pattern" ]; then
        local mismatch=$(cmp -n $size -b "$tmpfile" <(printf "%${size}s" | tr ' ' "\x$pattern") 2>&1)
        [ -n "$mismatch" ] && return 1 || return 0
    else
        return 0
    fi
}

# --- Recursive binary-tree scan/stress ---
stress_block() {
    local addr=$1 size=$2
    progress $addr $size

    if [ $WRITE_CYCLES -gt 0 ]; then
        for pattern in "${PATTERNS[@]}"; do
            for ((cycle=1; cycle<=WRITE_CYCLES; cycle++)); do
                write_block $addr $size $pattern
                if ! verify_block $addr $size $pattern; then
                    if [ $size -le $MIN_BLOCK ]; then
                        printf "❌ Bad sector at 0x%05X pattern 0x%s\n" $addr $pattern
                        BAD_SECTORS+=($(printf "0x%05X" $addr))
                    else
                        local half=$((size / 2))
                        stress_block $addr $half
                        stress_block $((addr+half)) $half
                    fi
                else
                    printf "Block 0x%05X-0x%05X pattern 0x%s OK (cycle %d/%d)\n" $addr $((addr+size-1)) $pattern $cycle $WRITE_CYCLES
                fi
            done
        done
    else
        if ! verify_block $addr $size ""; then
            if [ $size -le $MIN_BLOCK ]; then
                printf "❌ Bad sector at 0x%05X\n" $addr
                BAD_SECTORS+=($(printf "0x%05X" $addr))
            else
                local half=$((size / 2))
                stress_block $addr $half
                stress_block $((addr+half)) $half
            fi
        else
            printf "Block 0x%05X-0x%05X OK\n" $addr $((addr+size-1))
        fi
    fi
}

# --- Start scan ---
stress_block $START_ADDR $FLASH_SIZE

# --- Cleanup temp files ---
rm -f "${TMP_FILES[@]}" 2>/dev/null

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
