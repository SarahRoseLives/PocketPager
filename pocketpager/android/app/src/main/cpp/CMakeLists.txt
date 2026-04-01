cmake_minimum_required(VERSION 3.18.1)
project("pocketpager" C)

# ── Paths ──────────────────────────────────────────────────────────────────
set(RTL_ROOT
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../../rtl_tcp_andro/rtlsdr/src/main/cpp/librtlsdr")

set(MULTIMON_ROOT
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../..")

# Resolve to the multimon-ng directory (two levels up from pocketpager/)
set(MULTIMON_NG "${MULTIMON_ROOT}/multimon-ng")

find_library(LOG_LIB log)

# ── libusb (static) ────────────────────────────────────────────────────────
add_library(libusb STATIC
    ${RTL_ROOT}/libusb/libusb/core.c
    ${RTL_ROOT}/libusb/libusb/descriptor.c
    ${RTL_ROOT}/libusb/libusb/hotplug.c
    ${RTL_ROOT}/libusb/libusb/io.c
    ${RTL_ROOT}/libusb/libusb/strerror.c
    ${RTL_ROOT}/libusb/libusb/sync.c
    ${RTL_ROOT}/libusb/libusb/os/linux_netlink.c
    ${RTL_ROOT}/libusb/libusb/os/linux_usbfs.c
    ${RTL_ROOT}/libusb/libusb/os/poll_posix.c
    ${RTL_ROOT}/libusb/libusb/os/threads_posix.c)
target_include_directories(libusb PUBLIC
    ${RTL_ROOT}/libusb/libusb
    ${RTL_ROOT}/libusb/android)
target_compile_options(libusb PRIVATE -Wall -O2 -Wno-unused-parameter)
target_link_libraries(libusb ${LOG_LIB})

# ── librtlsdr (static) ────────────────────────────────────────────────────
add_library(rtlsdr STATIC
    ${RTL_ROOT}/src/librtlsdr.c
    ${RTL_ROOT}/src/tuner_e4k.c
    ${RTL_ROOT}/src/tuner_fc0012.c
    ${RTL_ROOT}/src/tuner_fc0013.c
    ${RTL_ROOT}/src/tuner_fc2580.c
    ${RTL_ROOT}/src/tuner_r82xx.c
    ${RTL_ROOT}/src/convenience/convenience.c)
target_include_directories(rtlsdr PUBLIC  ${RTL_ROOT}/include)
target_include_directories(rtlsdr PRIVATE ${RTL_ROOT}/libusb/libusb)
target_compile_options(rtlsdr PRIVATE -Wall -O2 -Wno-unused-parameter)
target_link_libraries(rtlsdr libusb ${LOG_LIB})

# ── multimon-ng decoder sources ───────────────────────────────────────────
set(MULTIMON_SRCS
    ${MULTIMON_NG}/pocsag.c
    ${MULTIMON_NG}/demod_poc5.c
    ${MULTIMON_NG}/demod_poc12.c
    ${MULTIMON_NG}/demod_poc24.c
    ${MULTIMON_NG}/demod_flex.c
    ${MULTIMON_NG}/demod_flex_next.c
    ${MULTIMON_NG}/bch.c
    ${MULTIMON_NG}/costabf.c
    ${MULTIMON_NG}/cJSON.c)

# ── libpocketpager.so (shared – loaded by Dart FFI) ───────────────────────
add_library(pocketpager SHARED
    pager_lib.c
    ${MULTIMON_SRCS})

target_include_directories(pocketpager PRIVATE
    ${RTL_ROOT}/include
    ${MULTIMON_NG})

target_compile_options(pocketpager PRIVATE
    -Wall -O2
    -DMAX_VERBOSE_LEVEL=0
    -DCHARSET_UTF8
    -DNO_X11
    -DNO_SDL3
    -DDUMMY_AUDIO)

target_link_libraries(pocketpager
    rtlsdr
    libusb
    ${LOG_LIB}
    m)
