// Private AppKit and DFRFoundation declarations used to put SoundBar's own view on the Touch Bar.
//
// None of this is public API. It is what every Touch Bar utility on macOS uses (AVTouchBar and
// BetterTouchTool both link DFRFoundation and call these), and all of the symbols below were verified
// present on macOS 26.6. Everything is called defensively: SoundBar checks `respondsToSelector` and
// dlsym results before use, so a future macOS that drops one of these degrades to "no visualiser"
// rather than crashing.

#import <AppKit/AppKit.h>

@interface NSTouchBar (SoundBarPrivate)

/// Present a touch bar that takes over the strip.
/// `placement` 1 puts it in front of the control strip; `systemTrayItemIdentifier` nil means no
/// control-strip button is left behind, which is what "fullscreen" means here.
+ (void)presentSystemModalTouchBar:(NSTouchBar *)touchBar
                         placement:(long long)placement
          systemTrayItemIdentifier:(NSTouchBarItemIdentifier)identifier;

+ (void)presentSystemModalTouchBar:(NSTouchBar *)touchBar
          systemTrayItemIdentifier:(NSTouchBarItemIdentifier)identifier;

+ (void)dismissSystemModalTouchBar:(NSTouchBar *)touchBar;
+ (void)minimizeSystemModalTouchBar:(NSTouchBar *)touchBar;

@end

/// Adds or removes a button for `identifier` in the control strip.
extern void DFRElementSetControlStripPresenceForIdentifier(NSTouchBarItemIdentifier identifier,
                                                           BOOL present);

/// When NO, no close/Esc box is drawn over our touch bar.
extern void DFRSystemModalShowsCloseBoxWhenFrontMost(BOOL shows);

extern int DFRGetStatus(void);
extern int DFRSetStatus(int status);

/// Posts a synthetic mouse event into the Touch Bar's own event stream. Touch-Bar-scoped: unlike a
/// system HID event it does NOT reset the machine's HIDIdleTime, so display sleep and the
/// screensaver are unaffected. See the keep-awake note in TouchBarVisualizer for why this — and
/// every other synthetic-activity path — fails to defeat the strip's dimming on this macOS.
extern void DFRFoundationPostEventWithMouseActivity(NSEventType type, NSPoint p);


