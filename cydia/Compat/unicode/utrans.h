/*
 * Cydia iOS 15+ rootless compatibility shim.
 *
 * Modern Apple iPhoneOS SDKs still provide libicucore and the common ICU
 * headers used by Cydia, but do not expose unicode/utrans.h.  Cydia only
 * needs the stable C transliteration ABI below.  Keep the declarations tied
 * to the SDK's own unicode/utypes.h so Apple's ICU symbol/visibility macros
 * remain authoritative for the SDK being used.
 */
#ifndef CYDIA_COMPAT_UNICODE_UTRANS_H
#define CYDIA_COMPAT_UNICODE_UTRANS_H

#include <unicode/utypes.h>

U_CDECL_BEGIN

typedef void *UTransliterator;
typedef void *UReplaceable;

typedef struct UReplaceableCallbacks {
    int32_t (*length)(const UReplaceable *rep);
    UChar (*charAt)(const UReplaceable *rep, int32_t offset);
    UChar32 (*char32At)(const UReplaceable *rep, int32_t offset);
    void (*replace)(UReplaceable *rep, int32_t start, int32_t limit,
                    const UChar *text, int32_t textLength);
    void (*extract)(UReplaceable *rep, int32_t start, int32_t limit,
                    UChar *dst);
    void (*copy)(UReplaceable *rep, int32_t start, int32_t limit,
                 int32_t dest);
} UReplaceableCallbacks;

typedef enum UTransDirection {
    UTRANS_FORWARD = 0,
    UTRANS_REVERSE = 1
} UTransDirection;

/* UParseError is opaque to Cydia here; it always passes NULL. */
typedef struct UParseError UParseError;

U_CAPI UTransliterator *U_EXPORT2
utrans_openU(const UChar *id, int32_t idLength, UTransDirection dir,
             const UChar *rules, int32_t rulesLength,
             UParseError *parseError, UErrorCode *pErrorCode);

U_CAPI void U_EXPORT2
utrans_trans(const UTransliterator *trans, UReplaceable *rep,
             const UReplaceableCallbacks *repFunc, int32_t start,
             int32_t *limit, UErrorCode *status);

U_CDECL_END

#endif /* CYDIA_COMPAT_UNICODE_UTRANS_H */
