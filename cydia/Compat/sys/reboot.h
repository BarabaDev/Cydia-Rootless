/*
 * Cydia iOS 15+ rootless compatibility header.
 *
 * Current public iPhoneOS SDKs do not expose <sys/reboot.h>. Original Cydia
 * includes it for RB_AUTOBOOT before invoking the private reboot2() symbol,
 * whose declaration is already provided by iPhonePrivate.h.
 *
 * Apple's XNU reboot.h defines RB_AUTOBOOT as 0. Keep only the constant Cydia
 * actually consumes; do not reimplement reboot or alter finish-action logic.
 */
#ifndef CYDIA_COMPAT_SYS_REBOOT_H
#define CYDIA_COMPAT_SYS_REBOOT_H

#ifndef RB_AUTOBOOT
#define RB_AUTOBOOT 0
#endif

#endif /* CYDIA_COMPAT_SYS_REBOOT_H */
