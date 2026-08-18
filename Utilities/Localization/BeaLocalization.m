#import "BeaLocalization.h"
#import "../Debug/BeaDebug.h"
#import <QuartzCore/QuartzCore.h>

// The language the app is actually running in - not the device's raw locale.
// -preferredLocalizations is the intersection of the user's language order
// with what BeReal itself ships, which is the same answer BeReal's own UI
// resolves to, so the tweak's copy can never end up in a different language
// from the screen it is sitting on.
static NSString *BeaLanguageCode(void) {
	static NSString *code;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		NSString *preferred = [[NSBundle mainBundle] preferredLocalizations].firstObject
			?: [NSLocale preferredLanguages].firstObject;
		// "fr-CA" / "pt-BR" -> "fr" / "pt". Regional variants share this
		// tweak's translations; BeReal's own bundle still resolves them
		// per-region on its side.
		code = [preferred componentsSeparatedByString:@"-"].firstObject.lowercaseString ?: @"en";
	});
	return code;
}

// Only the copy this tweak invents. Anything BeReal already says somewhere in
// its own UI goes through BeaSharedCopy instead, so it comes out in all
// fifteen languages rather than the two here.
static NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *BeaOwnStrings(void) {
	static NSDictionary *strings;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		strings = @{
			// --- BeFake composer -------------------------------------------
			@"upload.front_image":        @{ @"en": @"Front image", @"fr": @"Photo avant" },
			@"upload.back_image":         @{ @"en": @"Back image",  @"fr": @"Photo arrière" },
			@"upload.caption":            @{ @"en": @"Caption",     @"fr": @"Légende" },
			@"upload.retakes":            @{ @"en": @"Retakes",     @"fr": @"Reprises" },
			@"upload.audience":           @{ @"en": @"Audience",    @"fr": @"Audience" },
			@"upload.friends":            @{ @"en": @"Friends",     @"fr": @"Amis" },
			@"upload.friends_of_friends": @{ @"en": @"Friends of friends", @"fr": @"Amis d’amis" },
			@"upload.everyone":           @{ @"en": @"Everyone",    @"fr": @"Tout le monde" },
			@"upload.post_late":          @{ @"en": @"Post late",   @"fr": @"Poster en retard" },
			@"upload.location":           @{ @"en": @"Location",    @"fr": @"Localisation" },
			@"upload.send":               @{ @"en": @"Send",        @"fr": @"Envoyer" },
			@"upload.loading":            @{ @"en": @"Loading…",    @"fr": @"Chargement…" },
			@"upload.location_error":     @{ @"en": @"Location unavailable", @"fr": @"Localisation indisponible" },
			@"upload.city_not_found":     @{ @"en": @"City not found", @"fr": @"Ville introuvable" },
			@"upload.missing_images_title":   @{ @"en": @"Missing images", @"fr": @"Photos manquantes" },
			@"upload.missing_images_message": @{ @"en": @"Select all required images.", @"fr": @"Choisis les deux photos." },
			@"upload.error_title":        @{ @"en": @"Something went wrong", @"fr": @"Une erreur est survenue" },
			@"upload.error_restart":      @{ @"en": @"2 - Please restart the app and try again.",
			                                 @"fr": @"2 - Redémarre l’application et réessaie." },
			@"upload.success_title":      @{ @"en": @"Success 🎉",  @"fr": @"Envoyé 🎉" },
			@"upload.success_message":    @{ @"en": @"Your BeReal was uploaded successfully!",
			                                 @"fr": @"Ton BeReal a bien été publié !" },
			@"upload.source_title":       @{ @"en": @"Choose an Image Source", @"fr": @"Choisir une source" },
			@"upload.source_message":     @{ @"en": @"Select the desired image source for your content.",
			                                 @"fr": @"Sélectionne la provenance de la photo." },
			@"upload.open_camera":        @{ @"en": @"Take a Photo", @"fr": @"Prendre une photo" },
			@"upload.choose_library":     @{ @"en": @"Choose from Library", @"fr": @"Choisir dans la galerie" },
			@"upload.show_information":   @{ @"en": @"Show Information", @"fr": @"À propos" },
			@"upload.buy_coffee":         @{ @"en": @"Buy me a ☕",  @"fr": @"Offre-moi un ☕" },

			// --- Download button / picker ----------------------------------
			@"download.picker_title":     @{ @"en": @"Save which photo?", @"fr": @"Quelle photo enregistrer ?" },
			@"download.both":             @{ @"en": @"Both photos", @"fr": @"Les deux photos" },
			@"download.back_only":        @{ @"en": @"Back camera only", @"fr": @"Caméra arrière uniquement" },
			@"download.front_only":       @{ @"en": @"Front camera only", @"fr": @"Caméra avant uniquement" },
			@"download.a11y_label":       @{ @"en": @"Save BeReal photos", @"fr": @"Enregistrer les photos du BeReal" },
			@"download.a11y_hint":        @{ @"en": @"%@. Touch and hold to choose front, back, or both.",
			                                 @"fr": @"%@. Appuie longuement pour choisir avant, arrière ou les deux." },

			// --- Shared / misc ---------------------------------------------
			@"general.cancel":            @{ @"en": @"Cancel",      @"fr": @"Annuler" },
			@"general.done":              @{ @"en": @"Done",        @"fr": @"Terminer" },
			@"general.search":            @{ @"en": @"Search",      @"fr": @"Rechercher" },
			@"music.currently_playing":   @{ @"en": @"Currently playing", @"fr": @"Actuellement à l’écoute" },
			@"music.search_subtitle":     @{ @"en": @"Search for another song", @"fr": @"Chercher un autre morceau" },
			@"music.search_placeholder":  @{ @"en": @"Search song, artist, album...", @"fr": @"Titre, artiste, album…" },
			@"music.shared":              @{ @"en": @"Shared",      @"fr": @"Partagé" },
			@"music.shared_subtitle":     @{ @"en": @"Visible to your friends", @"fr": @"Visible par tes amis" },
			@"music.private":             @{ @"en": @"Private",     @"fr": @"Privé" },
			@"music.private_subtitle":    @{ @"en": @"Only visible to you", @"fr": @"Visible uniquement par toi" },
			@"music.disabled":            @{ @"en": @"Disabled",    @"fr": @"Désactivé" },
			@"music.disabled_subtitle":   @{ @"en": @"Don’t add what you’re listening to",
			                                 @"fr": @"Ce que tu écoutes ne sera pas ajouté" },
			@"info.developed_by":         @{ @"en": @"developed by", @"fr": @"développé par" },

			// --- Settings screen -------------------------------------------
			@"settings.title":            @{ @"en": @"MiniBea", @"fr": @"MiniBea" },
			@"settings.section_ads":      @{ @"en": @"Advertising", @"fr": @"Publicité" },
			@"settings.ads_network":      @{ @"en": @"Block ad networks", @"fr": @"Bloquer les régies publicitaires" },
			@"settings.ads_network_detail": @{ @"en": @"Fails requests to ad and mediation hosts, so most slots are never filled.",
			                                   @"fr": @"Fait échouer les requêtes vers les régies : la plupart des emplacements ne se remplissent jamais." },
			@"settings.ads_views":        @{ @"en": @"Remove ad views", @"fr": @"Supprimer les vues publicitaires" },
			@"settings.ads_views_detail": @{ @"en": @"Removes any view belonging to BeReal's ad modules or an embedded ad SDK.",
			                                 @"fr": @"Supprime toute vue appartenant aux modules pub de BeReal ou à un SDK publicitaire intégré." },
			@"settings.ads_sponsored":    @{ @"en": @"Remove sponsored posts", @"fr": @"Supprimer les posts sponsorisés" },
			@"settings.ads_sponsored_detail": @{ @"en": @"Collapses in-feed cards carrying the \"Sponsored\" byline.",
			                                     @"fr": @"Replie les cartes du fil portant la mention « Sponsorisé »." },
			@"settings.ads_widen":        @{ @"en": @"Collapse the card around a removed ad",
			                                 @"fr": @"Replier la carte autour d’une pub supprimée" },
			@"settings.ads_widen_detail": @{ @"en": @"Stops a removed ad leaving a black rectangle with the advertiser's name still on it. Turn off if a real post ever disappears.",
			                                 @"fr": @"Évite qu’une pub supprimée laisse un rectangle noir avec le nom de l’annonceur. Désactive si un vrai post disparaît." },

			@"settings.section_feed":     @{ @"en": @"Feed", @"fr": @"Fil" },
			@"settings.gating_hide":      @{ @"en": @"Hide the \"Post to view\" overlay",
			                                 @"fr": @"Masquer le voile « Poste pour voir »" },
			@"settings.gating_hide_detail": @{ @"en": @"Removes the lock overlay drawn over a gated post.",
			                                   @"fr": @"Retire le voile affiché par-dessus un post verrouillé." },
			@"settings.gating_keep_cta":  @{ @"en": @"Keep the \"Post a BeReal.\" button",
			                                 @"fr": @"Garder le bouton « Poste un BeReal. »" },
			@"settings.gating_keep_cta_detail": @{ @"en": @"Off hides the overlay whole, which always works but loses the button.",
			                                       @"fr": @"Désactivé, tout le voile est masqué : ça marche toujours, mais le bouton disparaît." },

			@"settings.section_buttons":  @{ @"en": @"Buttons", @"fr": @"Boutons" },
			@"settings.button_download":  @{ @"en": @"Download button", @"fr": @"Bouton de téléchargement" },
			@"settings.button_upload":    @{ @"en": @"BeFake \"+\" button", @"fr": @"Bouton « + » BeFake" },
			@"settings.button_hide_scrolling": @{ @"en": @"Fade out while scrolling", @"fr": @"Estomper pendant le défilement" },
			@"settings.button_hide_scrolling_detail": @{ @"en": @"Off keeps the buttons pinned in place at all times.",
			                                             @"fr": @"Désactivé, les boutons restent fixes en permanence." },

			@"settings.section_diagnostics": @{ @"en": @"Diagnostics", @"fr": @"Diagnostic" },
			@"settings.a11y_bundles":     @{ @"en": @"Read SwiftUI text", @"fr": @"Lire le texte SwiftUI" },
			@"settings.a11y_bundles_detail": @{ @"en": @"Loads the system accessibility bundles. Without them BeReal's SwiftUI text is invisible to the tweak, and the two features above cannot find anything. Restart required.",
			                                    @"fr": @"Charge les bundles d’accessibilité du système. Sans eux, le texte SwiftUI de BeReal est invisible pour le tweak et les deux réglages ci-dessus ne trouvent rien. Redémarrage requis." },
			@"settings.debug_logging":    @{ @"en": @"Verbose logging", @"fr": @"Journalisation détaillée" },
			@"settings.debug_logging_detail": @{ @"en": @"Off by default: some of it includes tokens.",
			                                     @"fr": @"Désactivée par défaut : elle peut contenir des jetons d’authentification." },
			@"settings.report_share":     @{ @"en": @"Share a diagnostics report", @"fr": @"Partager un rapport de diagnostic" },
			@"settings.report_share_detail": @{ @"en": @"Closes this screen, waits for the feed, then captures what the tweak sees.",
			                                    @"fr": @"Ferme cet écran, attend le fil, puis capture ce que le tweak voit." },
			@"settings.report_summary":   @{ @"en": @"Show a summary", @"fr": @"Afficher un résumé" },
			@"settings.restart_required": @{ @"en": @"Restart BeReal for this to take effect.",
			                                 @"fr": @"Redémarre BeReal pour appliquer ce réglage." },
			@"settings.open_hint":        @{ @"en": @"MiniBea settings", @"fr": @"Réglages MiniBea" },
		};
	});
	return strings;
}

NSString *BeaLocalized(NSString *key) {
	if (key.length == 0) return @"";
	NSDictionary<NSString *, NSString *> *entry = BeaOwnStrings()[key];
	if (!entry) {
		// A mistyped key has to be loud in development and harmless in
		// production - returning the key itself is both.
		BeaLog("[Bea] no own-table string for key %{public}@", key);
		return key;
	}
	return entry[BeaLanguageCode()] ?: entry[@"en"] ?: key;
}

NSString *BeaAppLocalized(NSString *berealKey, NSString *fallback) {
	if (berealKey.length == 0) return fallback;

	static NSBundle *localisation;
	static NSMutableDictionary<NSString *, NSString *> *cache;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		NSString *path = [[NSBundle mainBundle] pathForResource:@"Localisation_Localisation" ofType:@"bundle"];
		localisation = path ? [NSBundle bundleWithPath:path] : nil;
		cache = [NSMutableDictionary dictionary];
		BeaLog("[Bea] BeReal localisation bundle %{public}s", localisation ? "found" : "NOT found");
	});
	if (!localisation) return fallback;

	// Reached from the per-layout-pass marker scans, so the lookup is memoized
	// rather than hitting NSBundle every time. @synchronized rather than a
	// plain read because a %hook can get here off the main thread (ad verdicts
	// run wherever the view was inserted).
	@synchronized (cache) {
		NSString *cached = cache[berealKey];
		if (cached) return cached.length > 0 ? cached : fallback;

		// value:@"" makes -localizedStringForKey: echo the key back when it
		// isn't found, which is exactly what must never reach the UI - or, for
		// the marker scans, the needle list.
		NSString *value = [localisation localizedStringForKey:berealKey value:@"" table:@"Localizable"];
		if (value.length == 0 || [value isEqualToString:berealKey]) {
			cache[berealKey] = @"";
			return fallback;
		}
		cache[berealKey] = value;
		return value;
	}
}

NSString *BeaSharedCopy(NSString *berealKey, NSString *ownKey) {
	return BeaAppLocalized(berealKey, BeaLocalized(ownKey));
}

NSString *BeaNormalizedCopy(NSString *text) {
	if (text.length == 0) return nil;

	NSString *normalized = text.lowercaseString;
	normalized = [normalized stringByReplacingOccurrencesOfString:@"’" withString:@"'"];
	normalized = [normalized stringByReplacingOccurrencesOfString:@"‘" withString:@"'"];
	// U+00A0. French typography puts a non-breaking space before ! ? : and
	// BeReal's own strings are full of them, so fold it to a plain space
	// before the whitespace split below.
	normalized = [normalized stringByReplacingOccurrencesOfString:@" " withString:@" "];

	NSRange formatSpecifier = [normalized rangeOfString:@"%"];
	if (formatSpecifier.location != NSNotFound) {
		normalized = [normalized substringToIndex:formatSpecifier.location];
	}

	NSArray<NSString *> *words = [normalized componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	NSMutableArray<NSString *> *nonEmpty = [NSMutableArray array];
	for (NSString *word in words) {
		if (word.length > 0) [nonEmpty addObject:word];
	}
	return [nonEmpty componentsJoinedByString:@" "];
}

BOOL BeaCopyContainsPhrase(NSString *haystack, NSString *needle) {
	if (haystack.length == 0 || needle.length == 0) return NO;
	if ([haystack isEqualToString:needle]) return YES;
	if (haystack.length < needle.length) return NO;

	NSCharacterSet *wordCharacters = [NSCharacterSet alphanumericCharacterSet];
	NSRange searchRange = NSMakeRange(0, haystack.length);
	while (searchRange.length >= needle.length) {
		NSRange found = [haystack rangeOfString:needle options:0 range:searchRange];
		if (found.location == NSNotFound) return NO;

		NSUInteger end = found.location + found.length;
		BOOL startsCleanly = found.location == 0 ||
			![wordCharacters characterIsMember:[haystack characterAtIndex:found.location - 1]];
		BOOL endsCleanly = end >= haystack.length ||
			![wordCharacters characterIsMember:[haystack characterAtIndex:end]];
		if (startsCleanly && endsCleanly) return YES;

		searchRange = NSMakeRange(found.location + 1, haystack.length - found.location - 1);
	}
	return NO;
}

// Text a view renders through a real UIKit control. Cheap - property reads
// only - so this runs on every view, every pass.
static BOOL BeaViewOwnTextMatches(UIView *view, BOOL (^matches)(NSString *)) {
	NSMutableArray<NSString *> *candidates = [NSMutableArray arrayWithCapacity:2];

	if ([view isKindOfClass:[UILabel class]]) {
		[candidates addObject:((UILabel *)view).text ?: @""];
	} else if ([view isKindOfClass:[UITextView class]]) {
		[candidates addObject:((UITextView *)view).text ?: @""];
	} else if ([view isKindOfClass:[UIButton class]]) {
		[candidates addObject:((UIButton *)view).currentTitle ?: @""];
	}
	[candidates addObject:view.accessibilityLabel ?: @""];

	for (NSString *candidate in candidates) {
		NSString *normalized = BeaNormalizedCopy(candidate);
		if (normalized.length > 0 && matches(normalized)) return YES;
	}
	return NO;
}

// Text a view publishes only as accessibility elements - i.e. everything
// SwiftUI draws. Not free (asking a SwiftUI hosting view for its elements can
// force its accessibility tree to be built), which is why the caller only
// reaches this when the cheap scan came up empty, and why it is throttled in
// BeaCollectViewsWithMatchingText.
static BOOL BeaAccessibilityElementsMatch(id container, BOOL (^matches)(NSString *), NSInteger depth) {
	if (!container || depth > 4) return NO;

	// depth 0 is the UIView itself, whose own accessibilityLabel the cheap
	// scan already read - only its published elements are new information.
	if (depth > 0 && [container respondsToSelector:@selector(accessibilityLabel)]) {
		NSString *normalized = BeaNormalizedCopy([container accessibilityLabel]);
		if (normalized.length > 0 && matches(normalized)) return YES;
	}

	// Two spellings of the same protocol: an explicit array, or the
	// count/index pair a container may implement instead. A plain UIView
	// answers nil and NSNotFound respectively, so this costs nothing on
	// ordinary views.
	NSArray *elements = [container respondsToSelector:@selector(accessibilityElements)]
		? [container accessibilityElements] : nil;
	if (elements) {
		for (id element in elements) {
			if (BeaAccessibilityElementsMatch(element, matches, depth + 1)) return YES;
		}
		return NO;
	}

	if (![container respondsToSelector:@selector(accessibilityElementCount)]) return NO;
	NSInteger count = [container accessibilityElementCount];
	if (count == NSNotFound || count <= 0) return NO;
	// A SwiftUI screen can publish a great many elements; cap the fan-out so a
	// pathological one can't stall a layout pass.
	for (NSInteger i = 0; i < MIN(count, (NSInteger)64); i++) {
		if (BeaAccessibilityElementsMatch([container accessibilityElementAtIndex:i], matches, depth + 1)) return YES;
	}
	return NO;
}

static void BeaCollectRecursively(UIView *view,
                                  BOOL (^matches)(NSString *),
                                  BOOL includeAccessibility,
                                  NSMutableArray<UIView *> *result,
                                  NSInteger depth) {
	if (!view || depth > 24) return;

	if (BeaViewOwnTextMatches(view, matches) ||
	    (includeAccessibility && BeaAccessibilityElementsMatch(view, matches, 0))) {
		[result addObject:view];
		// Deliberately keeps descending: SwiftUI publishes the same string on
		// a wrapper and on the element inside it, and the callers want the
		// tightest view they can act on, not only the outermost one.
	}

	for (UIView *subview in view.subviews) {
		BeaCollectRecursively(subview, matches, includeAccessibility, result, depth + 1);
	}
}

void BeaCollectViewsWithMatchingText(NSString *purpose, UIView *root, BOOL (^matches)(NSString *), NSMutableArray<UIView *> *result) {
	if (!root || !matches || !result) return;

	BeaCollectRecursively(root, matches, NO, result, 0);
	if (result.count > 0) return;

	// Nothing in the UIKit layer said so. Before concluding the text isn't on
	// screen, ask the accessibility layer - but not on every layout pass. The
	// feed invalidates layout continuously while scrolling, and a gated post
	// or an ad stays on screen for seconds, so once every 400ms is fast enough
	// to feel immediate while keeping the expensive walk off the hot path.
	//
	// Throttled per `purpose`, not globally. A single shared timestamp was a
	// real bug rather than a tidiness point: the gating hunt and the sponsored
	// hunt both run from the same layout pass, so whichever asked first took
	// the 400ms slot and the other one was answered "nothing found" every
	// single time - permanently, not occasionally.
	static NSMutableDictionary<NSString *, NSNumber *> *lastScanByPurpose;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{ lastScanByPurpose = [NSMutableDictionary dictionary]; });

	NSString *key = purpose ?: @"default";
	CFTimeInterval now = CACurrentMediaTime();
	@synchronized (lastScanByPurpose) {
		CFTimeInterval last = lastScanByPurpose[key].doubleValue;
		if (last > 0 && now - last < 0.4) return;
		lastScanByPurpose[key] = @(now);
	}

	BeaCollectRecursively(root, matches, YES, result, 0);
}
