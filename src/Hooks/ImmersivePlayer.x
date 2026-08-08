//
//  ImmersivePlayer.x
//  NeoFreeBird
//

#import "HookHelpers.h"

// MARK: - Immersive Player Timestamp

// Field indexes in ImmersiveCardState's declaration order.
enum {
    CardStateFieldIsPanningBetweenCards = 19,
    CardStateFieldIsChromeFadedOutWhilePanning = 20,
};

static const uint8_t* immersiveCardStateMetadata(void) {
    static const uint8_t* metadata;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const void* (*getType)(const char*, size_t, const void*,
                               const void* const*) =
            dlsym(RTLD_DEFAULT, "swift_getTypeByMangledNameInEnvironment");
        if (getType) {
            const char* mangledName = "14T1TwitterSwift18ImmersiveCardStateV";
            metadata = getType(mangledName, strlen(mangledName), NULL, NULL);
        }
    });
    return metadata;
}

// Reads a Bool field through the struct's field offset vector, the same way the
// app's own compiled accesses do, so byte offsets never have to be hardcoded.
static BOOL cardStateBoolField(const uint8_t* state,
                               uint32_t fieldIndex,
                               BOOL* outValue) {
    const uint8_t* metadata = immersiveCardStateMetadata();
    if (!metadata) {
        return NO;
    }

    const uint8_t* descriptor = *(const uint8_t* const*)(metadata + 8);
    uint32_t numFields = *(const uint32_t*)(descriptor + 20);
    uint32_t offsetVectorOffset = *(const uint32_t*)(descriptor + 24);
    if (fieldIndex >= numFields || offsetVectorOffset == 0) {
        return NO;
    }

    const int32_t* fieldOffsets =
        (const int32_t*)(metadata + offsetVectorOffset * sizeof(void*));
    *outValue = state[fieldOffsets[fieldIndex]] & 1;
    return YES;
}

// displayMode is a Swift enum stored as an 8-byte case index followed by a
// discriminator tag (0 = the repliesPanning payload case, 1 = an empty case).
// Empty cases: regular = 0, repliesOpen = 1, repliesCompletelyOpen = 2,
// controlsHidden = 3, scrubbing = 4, statusExpanded = 5.
static BOOL progressLabelAlphaFromState(id pluginView, CGFloat* outAlpha) {
    Ivar stateIvar = class_getInstanceVariable([pluginView class], "state");
    if (!stateIvar) {
        return NO;
    }

    uint8_t* state =
        (uint8_t*)(__bridge void*)pluginView + ivar_getOffset(stateIvar);
    uint64_t displayModeCase = *(uint64_t*)state;
    uint8_t displayModeTag = state[8];

    BOOL visible =
        displayModeTag == 1 && (displayModeCase < 1 || displayModeCase > 3);

    if (visible) {
        BOOL panning = NO, chromeFaded = NO;
        if (cardStateBoolField(state, CardStateFieldIsPanningBetweenCards,
                               &panning) &&
            panning) {
            visible = NO;
        } else if (cardStateBoolField(state,
                                      CardStateFieldIsChromeFadedOutWhilePanning,
                                      &chromeFaded) &&
                   chromeFaded) {
            visible = NO;
        }
    }

    *outAlpha = visible ? 1.0 : 0.0;
    return YES;
}


static const void* kBHTRestoredTimestampKey = &kBHTRestoredTimestampKey;

%hook _TtC14T1TwitterSwift17VideoControlsView

- (void)layoutSubviews {
    %orig;

    if ([BHTSettings boolForKey:@"restore_video_timestamp"] &&
        !objc_getAssociatedObject(self, kBHTRestoredTimestampKey)) {
        objc_setAssociatedObject(self, kBHTRestoredTimestampKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self timestampLabelTapped];
    }
}

%end

%hook _TtC14T1TwitterSwift24ImmersivePiPDropZoneView
- (void)didMoveToWindow {
    %orig;
    if ([BHTSettings boolForKey:@"disable_video_docking"]) {
        self.hidden = true;
        self.alpha = 0.0;
        self.userInteractionEnabled = false;
        for (UIView* subview in self.subviews) {
            subview.hidden = true;
            subview.alpha = 0.0;
            subview.userInteractionEnabled = false;
        }
    }
}

%end

%hook T1ImmersiveViewController

- (BOOL)isCurrentCardDockEligible {
    if ([BHTSettings boolForKey:@"disable_video_docking"]) {
        return NO;
    }

    return %orig;
}

%end

%hook T1ImmersiveViewControllerV2

- (BOOL)isCurrentCardDockEligible {
    if ([BHTSettings boolForKey:@"disable_video_docking"]) {
        return NO;
    }

    return %orig;
}

%end

// MARK: - Disable Immersive Feed Scrolling

// The card pan drives vertical paging between videos; blocking it lets the
// swipe-down dismiss gesture take over.
static BOOL isImmersiveCardPan(id viewController,
                               UIGestureRecognizer* gesture) {
    Ivar panIvar =
        class_getInstanceVariable([viewController class], "panRecognizer");
    return panIvar && object_getIvar(viewController, panIvar) == gesture;
}

%hook T1ImmersiveViewController

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer*)gesture {
    if ([BHTSettings boolForKey:@"disable_immersive_scroll"] &&
        isImmersiveCardPan(self, gesture)) {
        return NO;
    }

    return %orig;
}

%end

%hook T1ImmersiveViewControllerV2

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer*)gesture {
    if ([BHTSettings boolForKey:@"disable_immersive_scroll"] &&
        isImmersiveCardPan(self, gesture)) {
        return NO;
    }

    return %orig;
}

%end

// MARK: - Tap to Play/Pause

static TAVPlayer* immersivePagePlayer(UIView* pageView) {
    Ivar playerIvar = class_getInstanceVariable([pageView class], "player");
    return playerIvar ? object_getIvar(pageView, playerIvar) : nil;
}

// timeControlStatus follows AVPlayer: 0 paused, 1 waiting to play, 2 playing.
static void togglePlayback(TAVPlayer* player) {
    if (player.playbackState.timeControlStatus != 0) {
        [player pause];
    } else {
        [player playOrReplay];  // replays instead of no-oping at end of video
    }
}

%hook _TtC14T1TwitterSwift17ImmersiveCardView

- (void)handleSingleTap:(UITapGestureRecognizer*)tap {
    if (![BHTSettings boolForKey:@"tap_to_pause"]) {
        %orig; 
        return;
    }

    __block UIView* pageView = nil;
    EnumerateSubviewsRecursively(self, ^(UIView* view) {
        if (!pageView &&
            [view isKindOfClass:%c(_TtC14T1TwitterSwift22ImmersiveVideoPageView)]) {
            pageView = view;
        }
    });

    TAVPlayer* player = pageView ? immersivePagePlayer(pageView) : nil;
    if (!player) {
        %orig;
        return;
    }

    BOOL wasPlaying = player.playbackState.timeControlStatus != 0;
    togglePlayback(player);
    [self setPausedByUser:wasPlaying];  
}

%end