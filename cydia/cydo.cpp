/* Cydia - iPhone UIKit Front-End for Debian APT
 * Copyright (C) 2008-2015  Jay Freeman (saurik)
 *
 * iOS 15+ rootless compatibility:
 * - keep the original cydo command-dispatch semantics
 * - avoid calling absent legacy libjailbreak symbols
 * - avoid the removed launch_data/launch_msg authorization path
 * - authenticate the direct caller by comparing its executable inode with
 *   /var/jb/Applications/Cydia.app/Cydia
 */

#include "CyteKit/UCPlatform.h"

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <cstdarg>
#include <ctime>

#include <errno.h>
#include <sysexits.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <fcntl.h>

#include <dlfcn.h>

struct timeval _ltv;
bool _itv;

#define FLAG_PLATFORMIZE (1ULL << 1)
#define CYDIA_BINARY "/var/jb/Applications/Cydia.app/Cydia"
#define ROOTLESS_DPKG "/var/jb/usr/bin/dpkg"
#define CYDIA_SOURCES_CACHE "/var/mobile/Library/Caches/com.saurik.Cydia/sources.list"
#define CYDIA_SOURCES_DIR "/var/jb/etc/apt/sources.list.d"
#define CYDIA_SOURCES_DEST "/var/jb/etc/apt/sources.list.d/cydia-added.list"
#define CYDIA_SOURCES_TEMP "/var/jb/etc/apt/sources.list.d/.cydia-added.list.tmp"
#define CYDIA_SOURCES_LEGACY "/var/jb/etc/apt/sources.list.d/cydia.list"


#define ROOTLESS_DIAGNOSTICS_LOG "/var/mobile/Documents/Cydia_Rootless_Diagnostics.log"
#define ROOTLESS_DIAGNOSTICS_OLD "/var/mobile/Documents/Cydia_Rootless_Diagnostics.log.1"
#define ROOTLESS_DIAGNOSTICS_MAX (2 * 1024 * 1024)

static void RootlessDiag(const char *component, const char *format, ...) {
    struct stat info;
    if (stat(ROOTLESS_DIAGNOSTICS_LOG, &info) == 0 && info.st_size >= ROOTLESS_DIAGNOSTICS_MAX) {
        unlink(ROOTLESS_DIAGNOSTICS_OLD);
        rename(ROOTLESS_DIAGNOSTICS_LOG, ROOTLESS_DIAGNOSTICS_OLD);
    }

    int fd = open(ROOTLESS_DIAGNOSTICS_LOG, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0)
        return;

    // cydo normally writes as root. If it creates the shared log
    // first, root:wheel 0644 blocks the mobile Cydia process from appending
    // its SESSION/SOURCE/APT records. Hand ownership back to mobile while
    // retaining root write access through privilege.
    if (geteuid() == 0) {
        (void) fchown(fd, 501, 501);
        (void) fchmod(fd, 0644);
    }

    char message[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(message, sizeof(message), format, args);
    va_end(args);

    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tm;
    gmtime_r(&tv.tv_sec, &tm);
    char date[48];
    strftime(date, sizeof(date), "%Y-%m-%d %H:%M:%S", &tm);
    char stamp[64];
    snprintf(stamp, sizeof(stamp), "%s.%03d +0000", date, (int) (tv.tv_usec / 1000));

    char line[1500];
    int size = snprintf(line, sizeof(line), "%s [%s] pid=%d ppid=%d %s\n",
        stamp, component != NULL ? component : "CYDO", getpid(), getppid(), message);
    if (size > 0)
        (void) write(fd, line, static_cast<size_t>(size < (int) sizeof(line) ? size : (int) sizeof(line)));
    close(fd);
}

static bool SameFile(const char *left, const char *right) {
    struct stat a;
    struct stat b;

    if (left == NULL || right == NULL)
        return false;
    if (stat(left, &a) != 0 || stat(right, &b) != 0)
        return false;

    return a.st_dev == b.st_dev && a.st_ino == b.st_ino;
}

/*
 * proc_pidpath is intentionally resolved at runtime. Modern iPhoneOS SDKs do
 * not always expose libproc headers to on-device builds, while the runtime
 * API is present on supported iOS versions.
 */
static bool CallerIsCydia() {
    typedef int (*proc_pidpath_t)(int pid, void *buffer, uint32_t buffersize);
    typedef int (*proc_pidinfo_t)(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);

    proc_pidpath_t proc_pidpath_ptr =
        reinterpret_cast<proc_pidpath_t>(dlsym(RTLD_DEFAULT, "proc_pidpath"));
    proc_pidinfo_t proc_pidinfo_ptr =
        reinterpret_cast<proc_pidinfo_t>(dlsym(RTLD_DEFAULT, "proc_pidinfo"));

    void *libproc = NULL;
    if (proc_pidpath_ptr == NULL || proc_pidinfo_ptr == NULL) {
        libproc = dlopen("/usr/lib/libproc.dylib", RTLD_LAZY | RTLD_LOCAL);
        if (libproc != NULL) {
            if (proc_pidpath_ptr == NULL)
                proc_pidpath_ptr = reinterpret_cast<proc_pidpath_t>(dlsym(libproc, "proc_pidpath"));
            if (proc_pidinfo_ptr == NULL)
                proc_pidinfo_ptr = reinterpret_cast<proc_pidinfo_t>(dlsym(libproc, "proc_pidinfo"));
        }
    }

    if (proc_pidpath_ptr == NULL) {
        if (libproc != NULL)
            dlclose(libproc);
        fprintf(stderr, "cydo: proc_pidpath is unavailable; refusing privileged request\n");
        return false;
    }

    /* popen()/system() may put one shell process between Cydia and cydo.
       Walk a short ancestry chain and require the installed Cydia binary to
       be present by device/inode identity. PROC_PIDTBSDINFO is flavor 3; the
       first five 32-bit fields end with pbi_ppid. */
    pid_t pid = getppid();
    for (unsigned depth = 0; pid > 1 && depth < 6; ++depth) {
        char path[4096];
        memset(path, 0, sizeof(path));
        int length = proc_pidpath_ptr(pid, path, static_cast<uint32_t>(sizeof(path)));
        if (length > 0 && SameFile(path, CYDIA_BINARY)) {
            if (libproc != NULL)
                dlclose(libproc);
            return true;
        }

        if (proc_pidinfo_ptr == NULL)
            break;

        struct BSDInfoPrefix {
            uint32_t flags;
            uint32_t status;
            uint32_t xstatus;
            uint32_t current_pid;
            uint32_t parent_pid;
        } info;
        memset(&info, 0, sizeof(info));

        int got = proc_pidinfo_ptr(pid, 3 /* PROC_PIDTBSDINFO */, 0, &info, sizeof(info));
        if (got < static_cast<int>(sizeof(info)) || info.parent_pid == 0 || info.parent_pid == static_cast<uint32_t>(pid))
            break;
        pid = static_cast<pid_t>(info.parent_pid);
    }

    if (libproc != NULL)
        dlclose(libproc);

    fprintf(stderr, "cydo: caller ancestry does not contain installed Cydia; refusing privileged request\n");
    return false;
}
/*
 * Old jailbreaks exported jb_oneshot_* from libjailbreak. New jailbreaks may
 * not export one or both symbols. The old cydo called both pointers without
 * checking them, which turns a missing symbol into SIGSEGV. Keep the legacy
 * compatibility path, but only call symbols that actually exist.
 */
static bool BecomeRoot() {
    if (geteuid() == 0)
        return true;

    /* A correctly installed cydo is root:wheel mode 6755. Try normal setuid
       semantics first; many rootless bootstraps handle this directly. */
    setgid(0);
    setuid(0);
    if (geteuid() == 0)
        return true;

    const char *libraries[] = {
        "/var/jb/usr/lib/libjailbreak.dylib",
        "/var/jb/basebin/libjailbreak.dylib",
        "/usr/lib/libjailbreak.dylib",
        NULL
    };

    for (size_t i = 0; libraries[i] != NULL; ++i) {
        void *handle = dlopen(libraries[i], RTLD_LAZY | RTLD_LOCAL);
        if (handle == NULL)
            continue;

        typedef void (*entitle_t)(pid_t, uint64_t);
        typedef void (*fix_setuid_t)(pid_t);

        entitle_t entitle = reinterpret_cast<entitle_t>(dlsym(handle, "jb_oneshot_entitle_now"));
        fix_setuid_t fix_setuid = reinterpret_cast<fix_setuid_t>(dlsym(handle, "jb_oneshot_fix_setuid_now"));

        if (entitle != NULL)
            entitle(getpid(), FLAG_PLATFORMIZE);
        if (fix_setuid != NULL)
            fix_setuid(getpid());

        setgid(0);
        setuid(0);

        bool root = geteuid() == 0;
        dlclose(handle);
        if (root)
            return true;
    }

    fprintf(stderr, "cydo: unable to obtain root privileges (uid=%d euid=%d)\n", getuid(), geteuid());
    return false;
}

static int SyncCydiaSources(const char *source) {
    RootlessDiag("SOURCES", "sync begin source=%s destination=%s", source != NULL ? source : "<null>", CYDIA_SOURCES_DEST);
    if (source == NULL || strcmp(source, CYDIA_SOURCES_CACHE) != 0) {
        RootlessDiag("SOURCES", "level=ERROR sync refused reason=unexpected-source-path");
        fprintf(stderr, "cydo: refusing source sync from unexpected path\n");
        return EX_NOPERM;
    }

    if (mkdir("/var/jb/etc", 0755) != 0 && errno != EEXIST) {
        RootlessDiag("SOURCES", "level=ERROR sync failed phase=mkdir-etc errno=%d error=%s", errno, strerror(errno));
        return EX_CANTCREAT;
    }
    if (mkdir("/var/jb/etc/apt", 0755) != 0 && errno != EEXIST) {
        RootlessDiag("SOURCES", "level=ERROR sync failed phase=mkdir-apt errno=%d error=%s", errno, strerror(errno));
        return EX_CANTCREAT;
    }
    if (mkdir(CYDIA_SOURCES_DIR, 0755) != 0 && errno != EEXIST) {
        RootlessDiag("SOURCES", "level=ERROR sync failed phase=mkdir-sources-dir errno=%d error=%s", errno, strerror(errno));
        return EX_CANTCREAT;
    }

    int input = open(source, O_RDONLY | O_NOFOLLOW);
    if (input < 0) {
        RootlessDiag("SOURCES", "level=ERROR sync failed phase=open-input errno=%d error=%s", errno, strerror(errno));
        fprintf(stderr, "cydo: open(%s) failed: %s\n", source, strerror(errno));
        return EX_NOINPUT;
    }

    unlink(CYDIA_SOURCES_TEMP);
    int output = open(CYDIA_SOURCES_TEMP, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0644);
    if (output < 0) {
        RootlessDiag("SOURCES", "level=ERROR sync failed phase=open-temp errno=%d error=%s", errno, strerror(errno));
        fprintf(stderr, "cydo: open(%s) failed: %s\n", CYDIA_SOURCES_TEMP, strerror(errno));
        close(input);
        return EX_CANTCREAT;
    }

    bool okay = true;
    int failure_errno = 0;
    const char *failure_phase = NULL;
    unsigned long long copied = 0;
    char buffer[16384];
    for (;;) {
        ssize_t size = read(input, buffer, sizeof(buffer));
        if (size == 0)
            break;
        if (size < 0) {
            if (errno == EINTR)
                continue;
            okay = false;
            failure_errno = errno;
            failure_phase = "read-input";
            break;
        }

        ssize_t offset = 0;
        while (offset < size) {
            ssize_t wrote = write(output, buffer + offset, static_cast<size_t>(size - offset));
            if (wrote < 0) {
                if (errno == EINTR)
                    continue;
                okay = false;
                failure_errno = errno;
                failure_phase = "write-temp";
                break;
            }
            offset += wrote;
            copied += static_cast<unsigned long long>(wrote);
        }
        if (!okay)
            break;
    }

    if (okay && fsync(output) != 0) {
        okay = false;
        failure_errno = errno;
        failure_phase = "fsync-temp";
    }
    if (okay && fchmod(output, 0644) != 0) {
        okay = false;
        failure_errno = errno;
        failure_phase = "chmod-temp";
    }
    if (okay && fchown(output, 0, 0) != 0) {
        okay = false;
        failure_errno = errno;
        failure_phase = "chown-temp";
    }

    close(output);
    close(input);

    if (!okay) {
        RootlessDiag("SOURCES", "level=ERROR sync failed phase=%s errno=%d error=%s bytes=%llu",
            failure_phase != NULL ? failure_phase : "copy", failure_errno,
            failure_errno != 0 ? strerror(failure_errno) : "unknown", copied);
        fprintf(stderr, "cydo: failed while writing managed source list: %s\n", failure_errno != 0 ? strerror(failure_errno) : "unknown");
        unlink(CYDIA_SOURCES_TEMP);
        return EX_IOERR;
    }

    if (rename(CYDIA_SOURCES_TEMP, CYDIA_SOURCES_DEST) != 0) {
        int saved = errno;
        RootlessDiag("SOURCES", "level=ERROR sync failed phase=rename errno=%d error=%s bytes=%llu", saved, strerror(saved), copied);
        fprintf(stderr, "cydo: rename(%s, %s) failed: %s\n", CYDIA_SOURCES_TEMP, CYDIA_SOURCES_DEST, strerror(saved));
        unlink(CYDIA_SOURCES_TEMP);
        return EX_CANTCREAT;
    }

    RootlessDiag("SOURCES", "sync end status=ok bytes=%llu", copied);
    return EX_OK;
}

static int CleanupLegacyCydiaSourceLink() {
    struct stat info;
    if (lstat(CYDIA_SOURCES_LEGACY, &info) != 0) {
        if (errno == ENOENT) {
            RootlessDiag("SOURCES", "legacy cleanup status=absent path=%s", CYDIA_SOURCES_LEGACY);
            return EX_OK;
        }
        RootlessDiag("SOURCES", "level=ERROR legacy cleanup phase=lstat errno=%d error=%s", errno, strerror(errno));
        return EX_IOERR;
    }

    // Never remove a regular source file owned by the user or bootstrap.
    // Only delete the exact symlink created by older Cydia rootless builds.
    if (!S_ISLNK(info.st_mode)) {
        RootlessDiag("SOURCES", "legacy cleanup status=preserved reason=not-symlink path=%s", CYDIA_SOURCES_LEGACY);
        return EX_OK;
    }

    char target[4096];
    ssize_t size = readlink(CYDIA_SOURCES_LEGACY, target, sizeof(target) - 1);
    if (size < 0) {
        RootlessDiag("SOURCES", "level=ERROR legacy cleanup phase=readlink errno=%d error=%s", errno, strerror(errno));
        return EX_IOERR;
    }
    target[size] = '\0';

    if (strcmp(target, CYDIA_SOURCES_CACHE) != 0) {
        RootlessDiag("SOURCES", "legacy cleanup status=preserved reason=foreign-target path=%s", CYDIA_SOURCES_LEGACY);
        return EX_OK;
    }

    if (unlink(CYDIA_SOURCES_LEGACY) != 0) {
        RootlessDiag("SOURCES", "level=ERROR legacy cleanup phase=unlink errno=%d error=%s", errno, strerror(errno));
        return EX_IOERR;
    }

    RootlessDiag("SOURCES", "legacy cleanup status=removed path=%s", CYDIA_SOURCES_LEGACY);
    return EX_OK;
}

static void SanitizeEnvironment() {
    /* Never pass dynamic-loader injection variables through a privileged
       package-management helper. */
    unsetenv("DYLD_INSERT_LIBRARIES");
    unsetenv("DYLD_LIBRARY_PATH");
    unsetenv("DYLD_FRAMEWORK_PATH");
    unsetenv("DYLD_FALLBACK_LIBRARY_PATH");
    unsetenv("DYLD_FALLBACK_FRAMEWORK_PATH");

    setenv("PATH", "/var/jb/usr/sbin:/var/jb/usr/bin:/var/jb/sbin:/var/jb/bin:/usr/sbin:/usr/bin:/sbin:/bin", 1);
}

int main(int argc, char *argv[]) {
    RootlessDiag("CYDO", "start argc=%d uid=%d euid=%d", argc, getuid(), geteuid());
    if (argc <= 0 || argv == NULL || argv[0] == NULL)
        return EX_USAGE;

    /* Root-run maintenance/self-tests are allowed. Requests coming from the
       Cydia app must originate from the installed Cydia executable. */
    if (getuid() != 0 && !CallerIsCydia()) {
        RootlessDiag("SECURITY", "level=ERROR caller validation failed uid=%d euid=%d", getuid(), geteuid());
        return EX_NOPERM;
    }

    if (!BecomeRoot()) {
        RootlessDiag("CYDO", "level=ERROR failed to obtain root uid=%d euid=%d", getuid(), geteuid());
        return EX_NOPERM;
    }

    if (setgid(0) != 0 || setuid(0) != 0 || geteuid() != 0) {
        int saved = errno;
        RootlessDiag("CYDO", "level=ERROR root transition failed errno=%d error=%s uid=%d euid=%d", saved, strerror(saved), getuid(), geteuid());
        fprintf(stderr, "cydo: root transition failed: %s\n", strerror(saved));
        return EX_NOPERM;
    }

    SanitizeEnvironment();

    // Narrowly-scoped privileged source persistence.  This is not
    // a general file-write primitive: only Cydia's fixed cache file may be
    // atomically published to Cydia's own rootless APT list file.
    if (argc == 3 && strcmp(argv[1], "--sync-sources") == 0)
        return SyncCydiaSources(argv[2]);
    if (argc == 2 && strcmp(argv[1], "--cleanup-legacy-source-link") == 0)
        return CleanupLegacyCydiaSourceLink();

    /* Preserve original cydo dispatch behavior:
       cydo --configure ...        -> /var/jb/usr/bin/dpkg --configure ...
       cydo /absolute/tool args... -> /absolute/tool args...
     */
    if (argc < 2 || argv[1] == NULL || argv[1][0] != '/') {
        argv[0] = const_cast<char *>(ROOTLESS_DPKG);
    } else {
        --argc;
        ++argv;
    }

    RootlessDiag("CYDO", "exec target=%s", argv[0]);
    execv(argv[0], argv);
    RootlessDiag("CYDO", "level=ERROR exec failed target=%s errno=%d error=%s", argv[0], errno, strerror(errno));
    fprintf(stderr, "cydo: execv(%s) failed: %s\n", argv[0], strerror(errno));
    return EX_UNAVAILABLE;
}
