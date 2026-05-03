#ifdef __APPLE__

#import <Cocoa/Cocoa.h>

static NSScreen *wioxGetScreen(CGDirectDisplayID displayId) {
    for (NSScreen *screen in [NSScreen screens]) {
        NSNumber *number = [[screen deviceDescription] objectForKey:@"NSScreenNumber"];
        if ([number unsignedIntValue] == displayId) return screen;
    }
    return nil;
}

uint32_t wioxGetDisplayCount(void) {
    return (uint32_t)[[NSScreen screens] count];
}

uint32_t wioxGetDisplayIds(CGDirectDisplayID *ids, uint32_t maxCount) {
    NSArray<NSScreen *> *screens = [NSScreen screens];
    uint32_t count = (uint32_t)MIN([screens count], maxCount);
    for (uint32_t i = 0; i < count; ++i) {
        NSNumber *number = [[screens[i] deviceDescription] objectForKey:@"NSScreenNumber"];
        ids[i] = [number unsignedIntValue];
    }
    return count;
}

uint8_t wioxGetDisplayBounds(CGDirectDisplayID displayId, int32_t *x, int32_t *y, uint32_t *width, uint32_t *height) {
    NSScreen *screen = wioxGetScreen(displayId);
    if (!screen) return 0;
    NSRect frame = [screen frame];
    *x = (int32_t)frame.origin.x;
    *y = (int32_t)frame.origin.y;
    *width = (uint32_t)frame.size.width;
    *height = (uint32_t)frame.size.height;
    return 1;
}

uint8_t wioxGetDisplayUsableBounds(CGDirectDisplayID displayId, int32_t *x, int32_t *y, uint32_t *width, uint32_t *height) {
    NSScreen *screen = wioxGetScreen(displayId);
    if (!screen) return 0;
    NSRect frame = [screen visibleFrame];
    *x = (int32_t)frame.origin.x;
    *y = (int32_t)frame.origin.y;
    *width = (uint32_t)frame.size.width;
    *height = (uint32_t)frame.size.height;
    return 1;
}

double wioxGetDisplayContentScale(CGDirectDisplayID displayId) {
    NSScreen *screen = wioxGetScreen(displayId);
    return screen ? [screen backingScaleFactor] : 0.0;
}

uint8_t wioxGetWindowDisplay(NSWindow *window, CGDirectDisplayID *displayId) {
    NSScreen *screen = [window screen];
    if (!screen) return 0;

    NSNumber *number = [[screen deviceDescription] objectForKey:@"NSScreenNumber"];
    if (!number) return 0;

    *displayId = [number unsignedIntValue];
    return 1;
}

#endif
