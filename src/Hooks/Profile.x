//
//  Profile.x
//  NeoFreeBird
//

#import "HookHelpers.h"

// MARK: - Copy profile info

static void PresentCopyProfileInfoSheet(T1ProfileUserViewModel* viewModel) {
    NSMutableArray<TFNActionItem*>* items = [NSMutableArray array];

    void (^addCopyItem)(NSString*, NSString*, NSString*) =
        ^(NSString* titleKey, NSString* iconName, NSString* value) {
            if (!value.length) {
                return;
            }
            TFNActionItem* item = [%c(TFNActionItem)
                actionItemWithTitle:[[BHTBundle sharedBundle] localizedStringForKey:titleKey]
                          imageName:iconName
                             action:^{
                                 UIPasteboard.generalPasteboard.string = value;
                             }];
            if (item) {
                [items addObject:item];
            }
        };

    addCopyItem(@"COPY_PROFILE_INFO_MENU_OPTION_3", @"account", viewModel.fullName);
    addCopyItem(@"COPY_PROFILE_INFO_MENU_OPTION_2", @"at", viewModel.username);
    addCopyItem(@"COPY_PROFILE_INFO_MENU_OPTION_1", @"news_stroke", viewModel.bio);
    addCopyItem(@"COPY_PROFILE_INFO_MENU_OPTION_5", @"location_stroke", viewModel.location);
    addCopyItem(@"COPY_PROFILE_INFO_MENU_OPTION_4", @"link", viewModel.url);
    if (viewModel.username.length) {
        addCopyItem(@"COPY_PROFILE_INFO_MENU_OPTION_6", @"link",
                    [NSString stringWithFormat:@"https://x.com/%@", viewModel.username]);
    }
    addCopyItem(@"COPY_PROFILE_INFO_MENU_OPTION_7", @"bar_chart", [NSString stringWithFormat:@"%ld", (long)viewModel.userDataSource.user.userID]);
    NSDateFormatter* dateFormatter = [[NSDateFormatter alloc] init];
    dateFormatter.dateStyle = NSDateFormatterLongStyle;
    addCopyItem(@"COPY_PROFILE_INFO_MENU_OPTION_8", @"calendar",
                [dateFormatter stringFromDate:viewModel.userDataSource.user.createdDate]);

    if (!items.count) {
        return;
    }

    TFNMenuSheetViewController* sheet = [[%c(TFNMenuSheetViewController) alloc]
        initWithTitle:[[BHTBundle sharedBundle] localizedStringForKey:@"COPY_PROFILE_INFO_TITLE"]
          actionItems:items];
    [sheet tfnPresentedCustomPresentFromViewController:topMostController()
                                              animated:YES
                                            completion:nil];
}

%hook T1ProfileHeaderViewController

- (id)profileMoreActionsBaseActionItemsWithSender:(id)sender {
    NSArray* items = %orig;

    if (![BHTSettings boolForKey:@"copy_profile_info"] ||
        ![items isKindOfClass:[NSArray class]]) {
        return items;
    }

    // Only extend a menu built the way this expects: if the action items ever
    // stop being TFNActionItems, the copy entry drops out rather than handing
    // the menu something it cannot show.
    if (![items.firstObject isKindOfClass:%c(TFNActionItem)]) {
        return items;
    }

    T1ProfileUserViewModel* viewModel = self.viewModel;
    if (![viewModel respondsToSelector:@selector(username)]) {
        return items;
    }

    TFNActionItem* copyItem = [%c(TFNActionItem)
        actionItemWithTitle:[[BHTBundle sharedBundle]
                                localizedStringForKey:@"COPY_PROFILE_INFO_TITLE"]
                  imageName:@"copy_stroke"
                     action:^{
                         // The more-actions menu is still on its way out when
                         // the action fires, so let it finish before stacking
                         // the copy sheet on top.
                         dispatch_async(dispatch_get_main_queue(), ^{
                             PresentCopyProfileInfoSheet(viewModel);
                         });
                     }];

    return copyItem ? [items arrayByAddingObject:copyItem] : items;
}

%end

// MARK: - Hide premium offer

%hook T1ProfileSummaryView

- (BOOL)shouldShowGetVerifiedButton {
    return [BHTSettings boolForKey:@"hide_premium_offer"] ? NO : %orig;
}

%end

// MARK: - Show unrounded follower/following counts

%hook T1ProfileFriendsFollowingViewModel

- (id)_t1_followCountTextWithLabel:(__unsafe_unretained id)label
                     singularLabel:(__unsafe_unretained id)singularLabel
                             count:(NSNumber*)count
                       highlighted:(BOOL)highlighted {
    id original = %orig;
    if (![BHTSettings boolForKey:@"show_unrounded_counts"]) {
        return original;
    }

    if (![count isKindOfClass:[NSNumber class]] ||
        ![original isKindOfClass:[NSAttributedString class]]) {
        return original;
    }

    NSString* abbreviated = [count tfs_twitterAbbreviated];
    NSNumberFormatter* formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    NSString* fullCount = [formatter stringFromNumber:count];

    if (!abbreviated.length || !fullCount.length || [abbreviated isEqualToString:fullCount]) {
        return original;
    }

    NSRange range = [[original string] rangeOfString:abbreviated];
    if (range.location == NSNotFound) {
        return original;
    }

    NSMutableAttributedString* expanded = [original mutableCopy];
    [expanded replaceCharactersInRange:range withString:fullCount];
    return [expanded copy];
}

%end

// MARK: - Show unrounded tweet/post count

%hook T1ProfileDisplayNormalMainContentProvider

- (id)_tweetsSubtitle {
    id original = %orig;
    
    if (![BHTSettings boolForKey:@"show_unrounded_counts"]) {
        return original;
    }

    NSNumber* count = self.viewModel.tweetCount;
    if (![count isKindOfClass:[NSNumber class]] || ![original isKindOfClass:[NSString class]]) {
        return original;
    }

    NSString* abbreviated = [count tfs_twitterAbbreviated];
    NSNumberFormatter* formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    NSString* fullCount = [formatter stringFromNumber:count];

    if (!abbreviated.length || !fullCount.length || [abbreviated isEqualToString:fullCount]) {
        return original;
    }

    NSRange range = [(NSString*)original rangeOfString:abbreviated];
    if (range.location == NSNotFound) {
        return original;
    }

    return [(NSString*)original stringByReplacingCharactersInRange:range withString:fullCount];
}

%end
