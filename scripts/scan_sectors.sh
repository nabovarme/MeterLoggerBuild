#!/bin/bash

# --- Configuration ---
ESPTOOL="./esptool/esptool.pyz"  # Path to esptool.pyz
CHIP="esp8266"                    # Explicit chip type to skip autodetect
PORT="/dev/tty.usbserial-A9M9DV3R"
SECTOR_SIZE=0x1000
FLASH_SIZE=0x100000  # 1 MB flash
TIMEOUT_SEC=10        # Timeout per sector in seconds

# Optional start address
START_ADDR=0x0
DEBUG=0

# Parse optional flags
while getopts "d" opt; do
    case $opt in
        d) DEBUG=1 ;;
        *) ;;
    esac
done
shift $((OPTIND-1))

# Optional start address as positional parameter
if [ $# -ge 1 ]; then
    START_ADDR=$1
fi

START_ADDR_HEX=$(printf "%X" $START_ADDR)

echo "Starting robust flash scan on $PORT from 0x$START_ADDR_HEX using $ESPTOOL (chip: $CHIP)"
if [ $DEBUG -eq 1 ]; then
    echo "Debug mode: ON (full esptool output will be shown)"
fi
echo

# List to store bad sectors
BAD_SECTORS=()

# Loop through all sectors
for ((addr=START_ADDR; addr<FLASH_SIZE; addr+=SECTOR_SIZE))
do
    printf "Reading sector 0x%05X ... " $addr

    # Run esptool in background with timeout
    OUTPUT=$(
        (
            $ESPTOOL --chip $CHIP -p $PORT read_flash $addr $SECTOR_SIZE /dev/null 2>&1 &
            pid=$!
            sleep $TIMEOUT_SEC
            kill -0 $pid 2>/dev/null && kill -9 $pid 2>/dev/null
        )
    )

    # Show debug output if requested
    if [ $DEBUG -eq 1 ]; then
        echo "$OUTPUT"
    fi

    # Check if esptool output contains "completed"
    if echo "$OUTPUT" | grep -q "completed"; then
        echo "OK"
    else
        echo "❌ Corrupt or hang detected!"
        BAD_SECTORS+=($(printf "0x%05X" $addr))
    fi
done

# --- Summary report ---
echo
echo "=== SCAN COMPLETE ==="
if [ ${#BAD_SECTORS[@]} -eq 0 ]; then
    echo "All sectors read OK ✅"
else
    echo "Corrupt or hang sectors found:"
    for s in "${BAD_SECTORS[@]}"; do
        echo "  $s"
    done
fi
