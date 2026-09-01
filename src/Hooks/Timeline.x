//
//  Timeline.x
//  NeoFreeBird
//

#import "HookHelpers.h"
#import <string.h>

// MARK: - Hide custom timelines

static __weak NSObject* PinnedTimelinesRepository;
static NSArray* LastPinnedTimelineModels;
static BOOL PinnedTimelinesWriteBypass = NO;

// Applies a toggle without relaunching. Hiding rewrites the UNCHANGED pinned
// list purely to republish — updatePinnedTimelines: persists server-side, so
// anything else would unpin for real; the delegate hook below swaps in the
// empty list on the way through.
void applyHideCustomTimelinesSetting(void) {
    NSObject* repository = PinnedTimelinesRepository;
    if (!repository) {
        return;
    }

    if ([BHTSettings boolForKey:@"hide_custom_timelines"]) {
        NSArray* models = LastPinnedTimelineModels;
        if (models.count > 0) {
            PinnedTimelinesWriteBypass = YES;
            ((void (*)(id, SEL, id))objc_msgSend)(repository, @selector(updatePinnedTimelines:), models);
            PinnedTimelinesWriteBypass = NO;
        }
    } else if ([repository respondsToSelector:@selector(fetchPinnedTimelinesWithThrottleEnabled:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(
            repository, @selector(fetchPinnedTimelinesWithThrottleEnabled:), NO);
    }
}

// The trailing accessory is only reconfigured while the strip is showing, so a
// button built before hiding mid-session survives; sync its visibility here. The
// property is a Swift lazy var whose storage ivar KVC can't see, hence the fallback.
static void SyncHomeAddTabButton(id container, BOOL hidden) {
    UIView* button = nil;

    @try {
        button = [container valueForKey:@"addTabButton"];
    } @catch (__unused NSException* exception) {
        unsigned int ivarCount = 0;
        Ivar* ivars = class_copyIvarList([container class], &ivarCount);
        for (unsigned int i = 0; i < ivarCount; i++) {
            const char* name = ivar_getName(ivars[i]);
            if (name && strstr(name, "addTabButton")) {
                button = object_getIvar(container, ivars[i]);
                break;
            }
        }
        free(ivars);
    }

    if ([button isKindOfClass:[UIView class]]) {
        button.hidden = hidden;
    }
}

// The repository publishes the pinned list through this single delegate call, so
// handing it an empty array hides the tabs without touching persisted state.
%hook _TtC32TwitterHomeFeatureImplementation35HomeTimelineContainerViewController

- (void)pinnedTimelinesRepository:(id)repository
    didChangeWithPinnedTimelineModels:(NSArray*)models {
    PinnedTimelinesRepository = repository;
    if (models.count > 0) {
        LastPinnedTimelineModels = [models copy];
    }
    BOOL hide = [BHTSettings boolForKey:@"hide_custom_timelines"];

    %orig(repository, hide ? @[] : models);
    SyncHomeAddTabButton(self, hide);
}

- (id)tfn_navigationBarAccessoryView {
    id accessoryView = %orig;
    SyncHomeAddTabButton(self, [BHTSettings boolForKey:@"hide_custom_timelines"]);
    return accessoryView;
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SyncHomeAddTabButton(self, [BHTSettings boolForKey:@"hide_custom_timelines"]);
}

%end

// While hiding, the overridden pinned-tabs feature switches make the app compute
// an empty pinned list; freeze writes so it can't overwrite the real tabs.
%hook _TtC32TwitterHomeFeatureImplementation31CachedPinnedTimelinesRepository

- (void)updatePinnedTimelines:(id)timelines {
    if (!PinnedTimelinesWriteBypass && [BHTSettings boolForKey:@"hide_custom_timelines"]) {
        return;
    }

    %orig;
}

%end

// MARK: - Force tweet images to full frame

%hook T1StandardStatusAttachmentViewAdapter

// attachmentType 2 = photos, displayType 1 = full frame
- (NSUInteger)displayType {
    if (self.attachmentType == 2) {
        return [BHTSettings boolForKey:@"force_tweet_full_frame"] ? 1 : %orig;
    }

    return %orig;
}

%end

// MARK: - Hide the Spaces bar

// The bar is still the repurposed Fleets line; both home timeline implementations
// share this visibility gate, re-evaluated on every content or settings update.
%hook T1FleetLineHeaderController

- (BOOL)_t1_shouldShowFleetLine {
    if ([BHTSettings boolForKey:@"hide_spaces"]) {
        return NO;
    }

    return %orig;
}

%end

// MARK: - Hide "Discover more", who-to-follow and prompts

// Resolves the class by name so mangled Swift names work; NSStringFromClass
// would only ever produce the demangled dotted form.
static BOOL IsInHierarchyOfClass(UIViewController* viewController, NSString* className) {
    Class targetClass = NSClassFromString(className);
    if (!targetClass) {
        return NO;
    }

    UIViewController* currentVC = viewController;

    while (currentVC) {
        if ([currentVC isKindOfClass:targetClass]) {
            return YES;
        }

        if (currentVC.parentViewController) {
            currentVC = currentVC.parentViewController;
        } else if (currentVC.navigationController) {
            currentVC = currentVC.navigationController;
        } else if (currentVC.presentingViewController) {
            currentVC = currentVC.presentingViewController;
        } else {
            break;
        }
    }

    return NO;
}

static NSString* ItemEntryID(id viewModel) {
    if (![viewModel respondsToSelector:@selector(entryID)]) {
        return nil;
    }

    NSString* entryID = [viewModel performSelector:@selector(entryID)];
    return [entryID isKindOfClass:[NSString class]] ? entryID : nil;
}

static NSString* ItemScribeComponent(id viewModel) {
    if (![viewModel respondsToSelector:@selector(scribeComponent)]) {
        return nil;
    }

    NSString* component = [viewModel performSelector:@selector(scribeComponent)];
    return [component isKindOfClass:[NSString class]] ? component : nil;
}


static BOOL ItemRespondsAndInvokesBOOL(id viewModel, SEL selector) {
    if (![viewModel respondsToSelector:selector]) {
        return NO;
    }

    return ((BOOL (*)(id, SEL))objc_msgSend)(viewModel, selector);
}

// Set when a reply is only on the feed because a followed account replied to
// someone else's tweet 
static BOOL ItemIsReplyWithSocialContext(id viewModel) {
    return ItemRespondsAndInvokesBOOL(viewModel, @selector(isReplyAndShouldShowSocialContext));
}


static BOOL ItemIsConversationThreadReply(id viewModel) {
    return [ItemEntryID(viewModel) containsString:@"conversationthread"];
}

// The tweet's author and who it's directly replying to, for recognizing an
// exchange between the thread's own author and a verified user. Real user
// IDs are never 0, so that doubles as "unknown/unsupported".
static long long ItemRepresentedFromUserID(id viewModel) {
    SEL selector = @selector(representedFromUserID);
    if (![viewModel respondsToSelector:selector]) {
        return 0;
    }

    return ((long long (*)(id, SEL))objc_msgSend)(viewModel, selector);
}

static long long ItemInReplyToUserID(id viewModel) {
    SEL selector = @selector(inReplyToUserID);
    if (![viewModel respondsToSelector:selector]) {
        return 0;
    }

    return ((long long (*)(id, SEL))objc_msgSend)(viewModel, selector);
}

// Twitter's *ByCurrentAccountState fields are a tri-state (0 unknown, 1 yes,
// 2 no); if follows still get hidden, flip this to the value logged for a
// known-followed account.
static const NSInteger kFollowedByCurrentAccountStateFollowing = 1;
static const NSInteger kBlockingCurrentAccountStateBlocking = 1;

static BOOL UserBlocksCurrentAccount(id user) {
    SEL relationshipSelector = @selector(relationship);
    if (![user respondsToSelector:relationshipSelector]) {
        return NO;
    }

    id relationship = ((id (*)(id, SEL))objc_msgSend)(user, relationshipSelector);
    SEL blockingSelector = @selector(blockingCurrentAccountState);
    if (![relationship respondsToSelector:blockingSelector]) {
        return NO;
    }

    NSInteger blockingState =
        ((NSInteger (*)(id, SEL))objc_msgSend)(relationship, blockingSelector);
    return blockingState == kBlockingCurrentAccountStateBlocking;
}

static BOOL ItemIsRetweetOfBlockingUser(id viewModel) {
    if (!ItemRespondsAndInvokesBOOL(viewModel, @selector(isRetweet))) {
        return NO;
    }

    SEL authorSelector = @selector(representedFromUser);
    if (![viewModel respondsToSelector:authorSelector]) {
        return NO;
    }

    return UserBlocksCurrentAccount(
        ((id (*)(id, SEL))objc_msgSend)(viewModel, authorSelector));
}

static BOOL BHShouldHideVerifiedItem(id viewModel, BOOL inConversation,
                                     long long conversationRootUserID,
                                     NSSet<NSNumber*>* authorRepliedToUserIDs) {
    SEL verifiedSelector = @selector(isFromUserVerified);
    if (![viewModel respondsToSelector:verifiedSelector]) {
        return NO;
    }

    BOOL verified = ((BOOL (*)(id, SEL))objc_msgSend)(viewModel, verifiedSelector);
    if (!verified) {
        return NO;
    }

    SEL bookmarkedSelector = @selector(displayAsBookmarked);
    if ([viewModel respondsToSelector:bookmarkedSelector]) {
        BOOL bookmarked = ((BOOL (*)(id, SEL))objc_msgSend)(viewModel, bookmarkedSelector);
        if (bookmarked) {
            return NO;
        }
    }

    if (inConversation) {
        if (!ItemIsConversationThreadReply(viewModel)) {
            return NO;
        }

        if (conversationRootUserID != 0) {
            long long repliedUserID = ItemRepresentedFromUserID(viewModel);

            BOOL isAuthorsOwnReply = repliedUserID == conversationRootUserID;
            BOOL authorRepliedToThisUser =
                [authorRepliedToUserIDs containsObject:@(repliedUserID)];
            if (isAuthorsOwnReply || authorRepliedToThisUser) {
                return NO;
            }
        }
    }

    if (!inConversation && ItemIsReplyWithSocialContext(viewModel)) {
        return NO;
    }

    SEL followStateSelector = @selector(representedFromUserFollowedByCurrentAccountState);
    if ([viewModel respondsToSelector:followStateSelector]) {
        NSInteger followState =
            ((NSInteger (*)(id, SEL))objc_msgSend)(viewModel, followStateSelector);
        if (followState == kFollowedByCurrentAccountStateFollowing) {
            return NO;
        }
    }

    return YES;
}

static BOOL ShouldHideTimelineItem(id item, BOOL hideWhoToFollow, BOOL hidePrompts,
                                   BOOL hideVerified, BOOL hideBlockedRetweets,
                                   BOOL inConversation, BOOL inProfile,
                                   long long conversationRootUserID,
                                   NSSet<NSNumber*>* authorRepliedToUserIDs) {
    id viewModel = unwrapDataViewItem(item);
    NSString* className = NSStringFromClass([viewModel classForCoder]);

    if (hideVerified && BHShouldHideVerifiedItem(viewModel, inConversation, conversationRootUserID,
                                                 authorRepliedToUserIDs)) {
        return YES;
    }

    if (hideBlockedRetweets && ItemIsRetweetOfBlockingUser(viewModel)) {
        return YES;
    }

    if (hidePrompts && [className isEqualToString:@"TwitterURT.URTTimelinePromptViewModel"]) {
        return YES;
    }

    if (hideWhoToFollow && [ItemScribeComponent(viewModel)
                               isEqualToString:@"suggest_who_to_follow"]) {
        return YES;
    }

    if (hideWhoToFollow && inProfile &&
        [className isEqualToString:@"T1TwitterSwift.URTTimelineCarouselViewModel"]) {
        return YES;
    }

    NSString* entryID = ItemEntryID(viewModel);

    if (!entryID) {
        return NO;
    }

    if (inConversation && [entryID hasPrefix:@"tweetdetailrelatedtweets"]) {
        return YES;
    }

    if (hideWhoToFollow && [entryID containsString:@"who-to-follow"]) {
        return YES;
    }

    return NO;
}

// More efficient way to filter timeline items than calling ShouldHideTimelineItem() repeatedly, which
// slows down the app a LOT
static BOOL MemoizedShouldHideTimelineItem(id item, BOOL hideWhoToFollow, BOOL hidePrompts,
                                           BOOL hideVerified, BOOL hideBlockedRetweets,
                                           BOOL inConversation, BOOL inProfile,
                                           long long conversationRootUserID,
                                           NSSet<NSNumber*>* authorRepliedToUserIDs) {
    static NSCache<NSString*, NSNumber*>* cache;
    static NSUInteger cachedFlags = NSUIntegerMax;
    static long long cachedRootUserID = 0;
    static NSSet<NSNumber*>* cachedAuthorRepliedToUserIDs;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
        cache.countLimit = 4000;
    });

    
    NSUInteger flags = (hideWhoToFollow << 0) | (hidePrompts << 1) | (hideVerified << 2) |
                       (inConversation << 3) | (inProfile << 4) | (hideBlockedRetweets << 5);
    BOOL repliedSetChanged = authorRepliedToUserIDs != cachedAuthorRepliedToUserIDs &&
                             ![authorRepliedToUserIDs isEqualToSet:cachedAuthorRepliedToUserIDs];
    if (flags != cachedFlags || conversationRootUserID != cachedRootUserID || repliedSetChanged) {
        [cache removeAllObjects];
        cachedFlags = flags;
        cachedRootUserID = conversationRootUserID;
        cachedAuthorRepliedToUserIDs = authorRepliedToUserIDs;
    }

    NSString* entryID = ItemEntryID(unwrapDataViewItem(item));
    if (!entryID) {
        return ShouldHideTimelineItem(item, hideWhoToFollow, hidePrompts, hideVerified,
                                      hideBlockedRetweets, inConversation, inProfile,
                                      conversationRootUserID, authorRepliedToUserIDs);
    }

    NSNumber* cached = [cache objectForKey:entryID];
    if (cached) {
        return cached.boolValue;
    }

    BOOL hide = ShouldHideTimelineItem(item, hideWhoToFollow, hidePrompts, hideVerified,
                                       hideBlockedRetweets, inConversation, inProfile,
                                       conversationRootUserID, authorRepliedToUserIDs);
    [cache setObject:@(hide) forKey:entryID];
    return hide;
}


static long long ConversationRootUserID(NSArray* sections) {
    for (id section in sections) {
        if (![section isKindOfClass:[NSArray class]]) {
            continue;
        }

        for (id item in (NSArray*)section) {
            id viewModel = unwrapDataViewItem(item);
            if (ItemIsConversationThreadReply(viewModel)) {
                continue;
            }

            long long userID = ItemRepresentedFromUserID(viewModel);
            if (userID != 0) {
                return userID;
            }
        }
    }

    return 0;
}


static NSSet<NSNumber*>* ConversationAuthorRepliedToUserIDs(NSArray* sections,
                                                            long long rootUserID) {
    NSMutableSet<NSNumber*>* repliedToUserIDs = [NSMutableSet set];
    if (rootUserID == 0) {
        return repliedToUserIDs;
    }

    for (id section in sections) {
        if (![section isKindOfClass:[NSArray class]]) {
            continue;
        }

        for (id item in (NSArray*)section) {
            id viewModel = unwrapDataViewItem(item);
            if (!ItemIsConversationThreadReply(viewModel)) {
                continue;
            }

            if (ItemRepresentedFromUserID(viewModel) != rootUserID) {
                continue;
            }

            long long repliedToUserID = ItemInReplyToUserID(viewModel);
            if (repliedToUserID != 0) {
                [repliedToUserIDs addObject:@(repliedToUserID)];
            }
        }
    }

    return repliedToUserIDs;
}

static NSArray* FilteredTimelineSections(TFNItemsDataViewController* dataViewController,
                                         NSArray* sections) {
    BOOL hideWhoToFollow = [BHTSettings boolForKey:@"hide_who_to_follow"];
    BOOL hidePrompts = [BHTSettings boolForKey:@"hide_timeline_prompts"];
    BOOL inConversation =
        IsInHierarchyOfClass(dataViewController, @"T1ConversationContainerViewController");
    BOOL inProfile = IsInHierarchyOfClass(dataViewController, @"T1ProfileViewController");

    BOOL hideVerified = [BHTSettings boolForKey:@"hide_verified_tweets"] && !inProfile;
    BOOL hideBlockedRetweets = [BHTSettings boolForKey:@"hide_blocked_retweets"];

    if (!hideWhoToFollow && !hidePrompts && !hideVerified && !hideBlockedRetweets &&
        !inConversation) {
        return sections;
    }

    long long conversationRootUserID =
        (hideVerified && inConversation) ? ConversationRootUserID(sections) : 0;
    NSSet<NSNumber*>* authorRepliedToUserIDs =
        (hideVerified && inConversation)
            ? ConversationAuthorRepliedToUserIDs(sections, conversationRootUserID)
            : nil;

    // Modules can share a section with unrelated items, so filtering is per item;
    // a purely filtered section (like the Discover More one) empties and is dropped.
    BOOL modified = NO;
    NSMutableArray* filteredSections = [NSMutableArray arrayWithCapacity:sections.count];

    for (id section in sections) {
        if (![section isKindOfClass:[NSArray class]]) {
            [filteredSections addObject:section];
            continue;
        }

        NSArray* items = section;
        NSMutableIndexSet* removed = [NSMutableIndexSet indexSet];

        for (NSUInteger i = 0; i < items.count; i++) {
            if (MemoizedShouldHideTimelineItem(items[i], hideWhoToFollow, hidePrompts, hideVerified,
                                               hideBlockedRetweets, inConversation, inProfile,
                                               conversationRootUserID, authorRepliedToUserIDs)) {
                [removed addIndex:i];
            }
        }

        if (removed.count == 0) {
            [filteredSections addObject:section];
            continue;
        }

        MarkEmptiedModuleChrome(items, removed);

        modified = YES;
        NSMutableArray* keptItems = [items mutableCopy];
        [keptItems removeObjectsAtIndexes:removed];
        if (keptItems.count > 0) {
            [filteredSections addObject:keptItems];
        }
    }

    return modified ? [filteredSections copy] : sections;
}

%hook TFNItemsDataViewController

- (void)setSections:(NSArray*)sections restoreScrollPosition:(BOOL)restoreScrollPosition {
    %orig(FilteredTimelineSections(self, sections), restoreScrollPosition);
}

- (void)updateSections:(NSArray*)sections
    reconfigureItemIdentifiers:(NSArray*)identifiers
              withRowAnimation:(long long)animation
                    completion:(id)completion {
    %orig(FilteredTimelineSections(self, sections), identifiers, animation, completion);
}

%end

// MARK: Hide the refresh pill at the top of the page that appears when new tweets are available
%hook TFNPillControl
- (void)didMoveToWindow {
    %orig;

    if ([BHTSettings boolForKey:@"hide_timeline_prompts"]) {
        self.userInteractionEnabled = NO;
        self.hidden = YES;
        self.alpha = 0.0;
    }
}

%end

%hook TFNFloatingActionButton
- (void)didMoveToWindow {
    %orig;

    if ([BHTSettings boolForKey:@"hide_tweet_button"]) {
        self.userInteractionEnabled = NO;
        self.hidden = YES;
        self.alpha = 0.0;
    }
}

%end

// Polls carry at most four choices. Don't derive the count from the card name:
// text polls are "poll2choice_text_only", but image polls arrive as
// "1906814671912599552:poll_choice_images", which encodes no count at all —
// PollCardDisplayConfiguration reads a choice_count binding for that reason.
static const NSUInteger BHTPollMaxChoices = 4;

// "choice2_label" -> 2, anything else -> 0.
static NSUInteger BHTPollChoiceIndexForKey(NSString *key) {
    if (![key hasPrefix:@"choice"] || ![key hasSuffix:@"_label"]) {
        return 0;
    }

    NSRange digits = NSMakeRange(6, key.length - 6 - 6);
    NSInteger index = [key substringWithRange:digits].integerValue;
    return index > 0 ? (NSUInteger)index : 0;
}

static BOOL BHTPollAlreadyShowsResults(TFCCardData *cardData) {
    if ([cardData boolForKey:@"counts_are_final"]) {
        return YES;
    }

    return [cardData stringForKey:@"selected_choice"].length > 0;
}

static NSString *BHTPollPercentageString(double fraction) {
    static NSNumberFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[NSNumberFormatter alloc] init];
        formatter.numberStyle = NSNumberFormatterPercentStyle;
        formatter.maximumFractionDigits = 0;
    });

    return [formatter stringFromNumber:@(fraction)];
}

static NSString *BHTPollTitleWithPercentage(TFCCardData *cardData,
                                            NSString *key,
                                            NSString *title) {
    NSUInteger choice = BHTPollChoiceIndexForKey(key);
    if (choice == 0 || choice > BHTPollMaxChoices || title.length == 0 ||
        ![BHTSettings boolForKey:@"show_poll_results"]) {
        return title;
    }
    if (BHTPollAlreadyShowsResults(cardData)) {
        return title;
    }

    // numberForKey: tells a missing binding apart from a zero tally, and neither
    // it nor numberFromStringForKey: is hooked below, so probing the siblings
    // can't recurse back in here.
    long long total = 0;
    long long votes = 0;
    for (NSUInteger i = 1; i <= BHTPollMaxChoices; i++) {
        NSString *countKey =
            [NSString stringWithFormat:@"choice%lu_count", (unsigned long)i];
        NSNumber *count = [cardData numberForKey:countKey]
                              ?: [cardData numberFromStringForKey:countKey];
        if (!count) {
            continue;
        }

        total += count.longLongValue;
        if (i == choice) {
            votes = count.longLongValue;
        }
    }

    if (total <= 0) {
        return title;
    }

    return [NSString stringWithFormat:@"%@ (%@)", title,
                                      BHTPollPercentageString((double)votes /
                                                              (double)total)];
}

%hook TFCCardData

- (NSString *)stringForKey:(NSString *)key {
    NSString *title = %orig;
    return BHTPollTitleWithPercentage(self, key, title);
}

- (NSString *)stringForKey:(NSString *)key defaultValue:(NSString *)value {
    NSString *title = %orig;
    return BHTPollTitleWithPercentage(self, key, title);
}

%end