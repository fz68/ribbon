// Private NSTouchBar declarations, adapted from Pock (MIT).
#import <AppKit/AppKit.h>

@interface NSTouchBar ()
+ (void)presentSystemModalTouchBar:(NSTouchBar *)touchBar placement:(long long)placement systemTrayItemIdentifier:(NSTouchBarItemIdentifier)identifier;
+ (void)dismissSystemModalTouchBar:(NSTouchBar *)touchBar;
@end
