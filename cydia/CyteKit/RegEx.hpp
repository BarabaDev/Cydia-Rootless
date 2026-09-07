/* Cydia - iPhone UIKit Front-End for Debian APT
 * Copyright (C) 2008-2015  Jay Freeman (saurik)
*/

/* GNU General Public License, Version 3 {{{ */
/*
 * Cydia is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published
 * by the Free Software Foundation, either version 3 of the License,
 * or (at your option) any later version.
 *
 * Cydia is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Cydia.  If not, see <http://www.gnu.org/licenses/>.
**/
/* }}} */

#ifndef Cydia_RegEx_HPP
#define Cydia_RegEx_HPP

#include <unicode/uregex.h>
#include <vector>

#include "CyteKit/UCPlatform.h"
#include "CyteKit/stringWith.h"

#define _rgxcall(code, args...) ({ \
    UErrorCode status(U_ZERO_ERROR); \
    auto _value(code(args, &status)); \
    if (U_FAILURE(status)) { \
        fprintf(stderr, "%d:%s\n", error.offset, u_errorName(status)); \
        _assert(false); \
    } \
_value; })

#define _rgxcallv(code, args...) ({ \
    UErrorCode status(U_ZERO_ERROR); \
    code(args, &status); \
    if (U_FAILURE(status)) { \
        fprintf(stderr, "%d:%s\n", error.offset, u_errorName(status)); \
        _assert(false); \
    } \
})

class RegEx {
  private:
    URegularExpression *regex_;
    int capture_;
    size_t size_;
    // ICU's uregex_setText does NOT copy the text; it keeps the pointer and
    // reads it later during capture extraction. The callers pass a temporary
    // UTF-16 buffer (from -cStringUsingEncoding:) that can be freed before the
    // captures are read, leaving ICU reading freed memory and producing a
    // corrupt capture string (an intermittent crash when that string is later
    // messaged). Own a private copy of the text so ICU's pointer stays valid
    // for the whole match/extract cycle.
    std::vector<UChar> text_;

  public:
    RegEx() :
        regex_(NULL),
        capture_(0),
        size_(_not(size_t))
    {
    }

    RegEx(const char *regex) :
        regex_(NULL),
        capture_(0),
        size_(_not(size_t))
    {
        this->operator =(regex);
    }

    template <typename Type_>
    RegEx(const char *regex, const Type_ &data) :
        RegEx(regex)
    {
        this->operator ()(data);
    }

    void operator =(const char *regex) {
        _assert(regex_ == NULL);
        UParseError error = {};
        regex_ = _rgxcall(uregex_openC, regex, 0, &error);
        capture_ = _rgxcall(uregex_groupCount, regex_);
    }

    ~RegEx() {
        uregex_close(regex_);
    }

    NSString *operator [](size_t match) const {
        if (size_ == _not(size_t))
            return nil;
        UParseError error = {};
        std::vector<UChar> data(size_ + 1);
        int32_t size(_rgxcall(uregex_group, regex_, match, data.data(), data.size()));
        return [[[NSString alloc] initWithBytes:data.data() length:(size * sizeof(UChar)) encoding:NSUTF16LittleEndianStringEncoding] autorelease];
    }

    _finline bool operator ()(NSString *string) {
        return operator ()(reinterpret_cast<const uint16_t *>([string cStringUsingEncoding:NSUTF16LittleEndianStringEncoding]), [string length]);
    }

    _finline bool operator ()(const char *data) {
        return operator ()([NSString stringWithUTF8String:data]);
    }

    bool operator ()(const UChar *data, size_t size) {
        UParseError error = {};
        if (data == NULL) {
            text_.clear();
            size_ = _not(size_t);
            return false;
        }
        // Keep our own copy alive; ICU reads this buffer during uregex_group.
        text_.assign(data, data + size);
        _rgxcallv(uregex_setText, regex_, text_.data(), (int32_t) text_.size());

        if (_rgxcall(uregex_matches, regex_, -1)) {
            size_ = size;
            return true;
        } else {
            size_ = _not(size_t);
            return false;
        }
    }

    bool operator ()(const char *data, size_t size) {
        return operator ()([[[NSString alloc] initWithBytes:data length:size encoding:NSUTF8StringEncoding] autorelease]);
    }

    operator bool() const {
        return size_ != _not(size_t);
    }

    NSString *operator ->*(NSString *format) const {
        std::vector<id> values(capture_);
        for (int i(0); i != capture_; ++i)
            values[i] = this->operator [](i + 1);
        return [NSString stringWithFormat:format :capture_ :values.data()];
    }
};

#endif//Cydia_RegEx_HPP
