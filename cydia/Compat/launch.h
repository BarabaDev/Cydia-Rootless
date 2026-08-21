/*
 * Cydia iOS 15+ rootless compatibility header.
 *
 * Modern iPhoneOS SDKs no longer ship the historical public launch.h,
 * while the legacy launch_data / launch_msg ABI used by original Cydia is
 * still referenced by MobileCydia.mm and cydo.cpp.
 *
 * This header intentionally declares only the subset used by Cydia. It does
 * not replace or reimplement launchd and does not alter Cydia behavior.
 */
#ifndef CYDIA_COMPAT_LAUNCH_H
#define CYDIA_COMPAT_LAUNCH_H

#include <stddef.h>
#include <stdbool.h>
#include <mach/mach.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LAUNCH_KEY_GETJOB                         "GetJob"
#define LAUNCH_KEY_GETJOBS                        "GetJobs"

#define LAUNCH_JOBKEY_PROGRAMARGUMENTS            "ProgramArguments"
#define LAUNCH_JOBKEY_PROGRAM                     "Program"
#define LAUNCH_JOBKEY_ENVIRONMENTVARIABLES        "EnvironmentVariables"
#define LAUNCH_JOBKEY_PID                         "PID"

typedef struct _launch_data *launch_data_t;

typedef enum {
    LAUNCH_DATA_DICTIONARY = 1,
    LAUNCH_DATA_ARRAY,
    LAUNCH_DATA_FD,
    LAUNCH_DATA_INTEGER,
    LAUNCH_DATA_REAL,
    LAUNCH_DATA_BOOL,
    LAUNCH_DATA_STRING,
    LAUNCH_DATA_OPAQUE,
    LAUNCH_DATA_ERRNO,
    LAUNCH_DATA_MACHPORT
} launch_data_type_t;

launch_data_t launch_data_alloc(launch_data_type_t type);
launch_data_type_t launch_data_get_type(const launch_data_t data);
void launch_data_free(launch_data_t data);

bool launch_data_dict_insert(launch_data_t dict,
                             const launch_data_t value,
                             const char *key);
launch_data_t launch_data_dict_lookup(const launch_data_t dict,
                                      const char *key);
void launch_data_dict_iterate(const launch_data_t dict,
                              void (*iterator)(const launch_data_t value,
                                               const char *key,
                                               void *context),
                              void *context);

launch_data_t launch_data_array_get_index(const launch_data_t array,
                                          size_t index);
size_t launch_data_array_get_count(const launch_data_t array);

launch_data_t launch_data_new_string(const char *value);
long long launch_data_get_integer(const launch_data_t data);
const char *launch_data_get_string(const launch_data_t data);

launch_data_t launch_msg(const launch_data_t request);

#ifdef __cplusplus
}
#endif

#endif /* CYDIA_COMPAT_LAUNCH_H */
