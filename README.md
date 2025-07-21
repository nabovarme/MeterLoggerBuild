# MeterLoggerBuild

**Build and flashing environment for [MeterLogger](https://github.com/nabovarme/MeterLogger)**  
ESP8266 firmware for logging Kamstrup heat meters and pulse-based meters, with secure MQTT publishing.

This repository automates:
- **Building the MeterLogger firmware**
- **Packaging a standalone `esptool.pyz` flasher**
- **Flashing your ESP8266 device without extra dependencies**

---

## 📦 What’s Inside?

- **MeterLogger firmware** – The actual ESP8266 code that logs heat and pulse meters.
- **Makefile** – Orchestrates building, packaging, and flashing.
- **Dockerfile.esptool** – Builds a clean Python environment and creates `esptool.pyz`.
- **esptool.pyz** – A self-contained, portable ESP8266 flashing utility (no installs required).

---

## 🔄 How It Works

1. The `Makefile` builds the firmware files and helper binaries, placing them in the `release/` directory. The main firmware files are:
   - `release/0x00000.bin`
   - `release/0x10000.bin`
   
   Additional helper files include:
   - `release/blank.bin`
   - `release/esp_init_data_default_112th_byte_0x03.bin`
   - `release/webpages.espfs`

2. The build process also runs the `Dockerfile.esptool` to produce a fresh, version-pinned `esptool.pyz` — a portable, self-contained flasher utility.

3. You can then use `esptool.pyz` to flash the firmware to your ESP8266 device, specifying the appropriate addresses for each binary. For example:
   ```bash
   python3 esptool.pyz --port /dev/ttyUSB0 write_flash 0x00000 release/0x00000.bin 0x10000 release/0x10000.bin <-- DEBUG

---

## 🚀 Quick Start

### 1. Clone the Repo
```bash
git clone https://github.com/nabovarme/MeterLoggerBuild.git
cd MeterLoggerBuild
```

### 2. Build Everything
This compiles the firmware **and** packages `esptool.pyz`:
```bash
make all
```

### 3. Flash Your ESP8266
```bash
make flash PORT=/dev/ttyUSB0 <-- DEBUG
```
This uses the `esptool.pyz` created during the build, so no extra installs are needed.

### 4. (Optional) Build Just the Flasher
```bash
make esptool
```
After this, you can manually flash with:
```bash
python esptool.pyz --port /dev/ttyUSB0 write_flash 0x00000 build/firmware.bin <-- DEBUG
```

---

## 🔧 Makefile Targets

- `make all` – Build firmware and `esptool.pyz`
- `make firmware` – Build only the firmware
- `make esptool` – Build only `esptool.pyz`
- `make flash PORT=/dev/ttyUSBX` – Flash the device using the built `esptool.pyz`
- `make clean` – Remove build artifacts

---

## 📡 About MeterLogger Firmware

The MeterLogger firmware:
- Supports **Kamstrup Multical (601, 66 C/B)** and **pulse-based meters**
- Publishes data securely via **AES-128 CBC encryption + HMAC-SHA256 authentication** over MQTT
- Runs on **ESP8266 (NodeMCU, etc.)**

See [MeterLogger](https://github.com/nabovarme/MeterLogger) for full firmware documentation and supported build flags (e.g., `EN61107=1`, `IMPULSE=1`, `DEBUG=1`).

---

## 🧰 Why `esptool.pyz`?

Instead of requiring users to install `esptool` via `pip` or rely on Docker:
- `esptool.pyz` is a **self-contained Python zipapp** created during the build.
- It guarantees a **consistent version** of `esptool`.
- It’s **cross-platform**: works on Linux, macOS, and Windows with just Python 3.

Once built, you can flash your device anywhere with:
```bash
python esptool.pyz --port /dev/ttyUSB0 write_flash 0x00000 firmware.bin
```

---

## 🧩 How These Pieces Fit

```
+------------------+        +---------------------+
|  MeterLogger     |        |  MeterLoggerBuild   |
|  (firmware)      |<-------|  (this repo)        |
+------------------+        +---------------------+
                                  |
                                  | builds
                                  v
                         +-------------------+
                         |  esptool.pyz      |
                         |  (portable flasher)|
                         +-------------------+
                                  |
                                  | flashes
                                  v
                         +-------------------+
                         |  ESP8266 Device   |
                         +-------------------+
```

---

## 📄 License

This project is licensed under the **MIT License**. See `LICENSE` for details.

---

## 🌐 Related Repositories

- [MeterLogger](https://github.com/nabovarme/MeterLogger) – Firmware source
- [MeterLoggerWeb](https://github.com/nabovarme/MeterLoggerWeb) – MQTT ingestion & web UI
- [MeterLoggerPCB](https://github.com/nabovarme/MeterLoggerPCB) – PCB designs for heat meter daughterboards

---

**MeterLoggerBuild** makes it simple to build, package, and flash open-source heat meter loggers, ensuring a reproducible toolchain and zero setup friction.
