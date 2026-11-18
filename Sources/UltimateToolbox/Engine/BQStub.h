#pragma once
#import <Foundation/Foundation.h>

// Minimal stub replacing KAMUI's BQUI.h for BQCore.m.
// BQCore.m only uses NSLocalizedString (redefined here to BQLocalizedString);
// no KAMUI UI code is used. Written by Ultimate Toolbox, not copied.
NSString *BQLocalizedString(NSString *key);

#undef NSLocalizedString
#define NSLocalizedString(key, comment) BQLocalizedString((key))
