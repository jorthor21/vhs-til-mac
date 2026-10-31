/* config.h – hand written for building libusb 1.0.27 inside VHS til Mac
 * (based on libusb's own Xcode/config.h). macOS only. */
#ifndef VHS_LIBUSB_CONFIG_H
#define VHS_LIBUSB_CONFIG_H
#include <AvailabilityMacros.h>
#define DEFAULT_VISIBILITY __attribute__ ((visibility ("default")))
#define ENABLE_LOGGING 1
#define HAVE_PTHREAD_THREADID_NP 1
#define HAVE_NFDS_T 1
#define HAVE_SYS_TIME_H 1
#define HAVE_CLOCK_GETTIME 1
#define HAVE_IOKIT_USB_IOUSBHOSTFAMILYDEFINITIONS_H 1
#define PLATFORM_POSIX 1
#define PRINTF_FORMAT(a, b) __attribute__ ((__format__ (__printf__, a, b)))
#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif
#endif
