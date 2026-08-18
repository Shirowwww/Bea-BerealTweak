// The tweak's version string, in one place.
//
// It used to live in three: Tweak.h, BeaInfoViewController.h and control, with
// a #ifndef guard between two of them that could not actually keep them in
// step because they are compiled as separate translation units - the Info
// screen had silently drifted to a stale "1.3.7" from long before this fork.
// Now every Objective-C file that needs it imports this header, and only
// `control` has to be updated alongside it.
#ifndef BEA_VERSION_H
#define BEA_VERSION_H

#define TWEAK_VERSION @"0.8.0-merged"

#endif
