// Fail-soft wrapper around the private MonitorPanel framework, the only way found to rotate a display.
// The framework is loaded at runtime and never linked: when anything is missing, both functions return NO.

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

/// YES when MonitorPanel lists this display and its `setOrientation:` takes one 32-bit integer.
/// Reads only: nothing is changed on any display.
BOOL ODRotationAvailable(CGDirectDisplayID display);

/// Rotates the display to `degrees` (0, 90, 180 or 270). NO, and no call, when `ODRotationAvailable`
/// is NO for it; NO when the call raised an Objective-C exception (Swift cannot catch one).
BOOL ODRotationSet(CGDirectDisplayID display, int32_t degrees);
