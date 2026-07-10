#include <AudioUnit/AudioUnit.h>
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreMIDI/CoreMIDI.h>
#include <OpenAL/al.h>
#include <OpenAL/alc.h>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#if TARGET_OS_OSX
#include <CoreAudio/AudioServerPlugIn.h>
#include <IOKit/audio/IOAudioTypes.h>
#endif
#endif
