#ifndef CZLIB_SHIM_H
#define CZLIB_SHIM_H

#include <zlib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <MediaToolbox/MTAudioProcessingTap.h>

static inline OSStatus echoCreateAudioProcessingTap(
    const MTAudioProcessingTapCallbacks *callbacks,
    MTAudioProcessingTapCreationFlags flags,
    void *outTap
) {
    return MTAudioProcessingTapCreate(kCFAllocatorDefault, callbacks, flags, (MTAudioProcessingTapRef *)outTap);
}

#endif

