#import <UIKit/UIKit.h>

// ============================================================================
// "IS THIS VIEW ONE OF OURS?"
// ============================================================================
// ROOT CAUSE OF THE EMPTY SETTINGS SCREEN, and of the two rounds of blank rows,
// half-sections and same-height gaps before it that were both blamed on
// self-sizing table cells.
//
// This tweak's screens are ordinary UIKit views inside BeReal's own window, and
// two of its scanners hunt for BeReal's *localized copy* anywhere under a view
// controller's root view. The settings screen describes what each switch does,
// so it renders BeReal's copy verbatim:
//
//   settings.gating_hide  fr = "Masquer le voile « Poste pour voir »"
//                              ^^^^^^^^^^^^^^^^ timelineCell_blurredView_title
//   settings.ads_sponsored_detail fr = "... la mention « Sponsorisé »."
//                                                        ^^^^^^^^^^ general_sponsored
//
// The gating hider found the first, walked up to the row's card and stripped
// every non-button view inside it; the sponsored remover found the second and
// collapsed the card around it. Both did exactly what they are meant to do, to
// the wrong screen - a settings screen that erases itself while it explains
// what it erases.
//
// So every scan has to know what belongs to the tweak. Two signals, both
// cheap: the class-name prefix every class in this project carries, and an
// explicit mark on the root view of anything the tweak presents (its subviews
// are plain UIKit classes and carry no prefix of their own).
FOUNDATION_EXPORT void BeaMarkViewAsOurs(UIView *view);

// Whether `view` is itself one of the tweak's. Deliberately NOT a walk up the
// superview chain: the scanners call this on the way *down*, so pruning at the
// marked root already excludes everything under it, and an ancestor walk on
// every view of every pass is the kind of cost this release exists to remove.
FOUNDATION_EXPORT BOOL BeaViewIsOurs(UIView *view);
