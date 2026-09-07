#!/var/jb/bin/bash

# /usr/bin \

for dir in \
    /Applications \
    /Library/Wallpaper \
    /Library/Ringtones \
    /usr/include \
    /usr/share \
; do
    . /var/jb/usr/libexec/cydia/move.sh "$@" "${dir}"
done

sync
