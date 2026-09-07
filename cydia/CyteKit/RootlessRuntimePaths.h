#ifndef CyteKit_RootlessRuntimePaths_H
#define CyteKit_RootlessRuntimePaths_H

/*
 * Standard Cydia remains installed under /var/jb/Applications.  The
 * TrollStore R2 target is built from the same source with one explicit build
 * define and reaches its randomized application container only through a
 * root-owned bridge.  Keeping the selection compile-time prevents a
 * TrollStore package from silently weakening the standard package layout.
 */
#if defined(CYDIA_TROLLSTORE_R2)
#define CYDIA_APPLICATION_PATH "/var/jb/.CydiaBridge/Cydia.app"
#define CYDIA_APPLICATION_BINARY "/var/jb/.CydiaBridge/Cydia.app/Cydia"
#define CYDIA_RUNTIME_VARIANT "trollstore-r2"
#else
#define CYDIA_APPLICATION_PATH "/var/jb/Applications/Cydia.app"
#define CYDIA_APPLICATION_BINARY "/var/jb/Applications/Cydia.app/Cydia"
#define CYDIA_RUNTIME_VARIANT "standard-rootless"
#endif

#endif
