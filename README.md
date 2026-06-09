# PocketPager

A Flutter Android app that decodes pager signals (POCSAG 512/1200/2400 and FLEX) in real-time using an RTL-SDR dongle connected via USB OTG.

## Signal Pipeline

```
RTL-SDR (USB OTG) → FM Demodulation → multimon-ng Decoders → Flutter UI
```

The entire DSP pipeline runs as native C code via Flutter FFI:
- **RTL-SDR → IQ samples** — via `librtlsdr` (Android USB OTG variant from `rtl_tcp_andro`)
- **FM demodulation** — quadrature discriminator, inline linear-interpolation SRC to 22 050 Hz
- **Decoding** — all multimon-ng pager decoders compiled directly into `libpocketpager.so`
- **UI** — Flutter Dart receives decoded messages via `NativeCallable.listener()` callback

## Supported Protocols

| Protocol | Description |
|---|---|
| POCSAG 512 | Pager – 512 bps |
| POCSAG 1200 | Pager – 1200 bps |
| POCSAG 2400 | Pager – 2400 bps |
| FLEX | Pager – 1600/3200/6400 bps |
| FLEX Next | Next-generation FLEX |

## Requirements

- Android phone with USB OTG support (API 24+)
- RTL-SDR dongle (Realtek RTL2832U, VID `0x0BDA`)
- USB OTG cable

## Building

### Prerequisites

- Flutter SDK (3.10+)
- Android NDK 27.0.12077973
- Android SDK with CMake 3.22.1

### Clone with submodules

```bash
git clone --recurse-submodules https://github.com/SarahRoseLives/PocketPager.git
cd PocketPager
```

### Run

```bash
cd pocketpager
flutter pub get
flutter run -d <device-id>
```

The NDK build compiles `librtlsdr` (Android USB OTG), `libusb` (Android), and all multimon-ng decoder sources into a single `libpocketpager.so`.

## Downloads

Pre-built signed APKs are available at [sarahsforge.dev/products/pocketpager](https://sarahsforge.dev/products/pocketpager).

## Usage

1. Plug the RTL-SDR into your phone via OTG cable — PocketPager auto-launches
2. Grant the USB permission when prompted
3. Enter the frequency in MHz (default: 439.9875 MHz)
4. Tap **Connect**
5. Decoded messages appear in the list as they are received

## Project Structure

```
PocketPager/
├── multimon-ng/          # multimon-ng source (decoder engines)
├── native/               # Host-side test pipeline (Linux, for development)
│   ├── pocketpager_test.c
│   └── Makefile
└── pocketpager/          # Flutter Android app
    ├── lib/
    │   ├── main.dart         # UI
    │   └── pager_ffi.dart    # FFI bindings + PagerDecoder class
    └── android/
        ├── rtl_tcp_andro/    # submodule: librtlsdr Android OTG variant
        └── app/src/main/
            ├── cpp/
            │   ├── pager_lib.c       # Native pipeline: FM demod + SRC + decoders
            │   └── CMakeLists.txt    # Builds libpocketpager.so
            └── kotlin/.../
                └── MainActivity.kt  # USB OTG bridge (MethodChannel)
```

## Native Library (`pager_lib.c`)

The core DSP runs in a single `pthread` loop:

```
rtlsdr_read_sync() → FM discriminator → linear SRC → demod_poc512/1200/2400/flex/flex_next
                                                          ↓
                                              _verbprintf intercept
                                                          ↓
                                         NativeCallable callback → Dart
```

## Host Testing

A standalone Linux test binary is included for development without a phone:

```bash
cd native
make
./pocketpager_test      # requires RTL-SDR plugged in to Linux host
```

## Third-Party Components

- [multimon-ng](https://github.com/EliasOenal/multimon-ng) — pager decoders (GPL-2.0)
- [rtl_tcp_andro](https://github.com/signalwareltd/rtl_tcp_andro-) — Android librtlsdr + libusb OTG (GPL-2.0)

> **Note:** The GPL-licensed components (multimon-ng, rtl_tcp_andro) are compiled into the native library. Distribution of binaries containing these components must comply with the GPL-2.0 license.

## License

GPL-2.0 — see [LICENSE](LICENSE)
