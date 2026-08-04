//
//  MediaDownloads.x
//  NeoFreeBird
//

#import "HookHelpers.h"

// MARK: - DM voice message download
static NSURL* nfbLastCapturedVoiceURL = nil;

%hook AVURLAsset
- (id)initWithURL:(NSURL*)url options:(NSDictionary*)options {
    if ([url.path containsString:@"/decrypted-media-v2/"]) {
        nfbLastCapturedVoiceURL = url;
    }
    return %orig;
}
%end

// DM voice notes are pre-decrypted straight to disk (Documents/dm/.../
// decrypted-media-v2/.../*.m4a), so the captured URL is normally a local
// file URL already -- just copy it out and hand it to the share sheet. The
// network branch is kept as a fallback in case that ever changes.
static void DownloadVoiceMessage(NSURL* sourceURL) {
    NSString* extension = sourceURL.pathExtension.length ? sourceURL.pathExtension : @"m4a";
    NSURL* destination = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
        URLByAppendingPathComponent:[NSString
                                         stringWithFormat:@"%@.%@", NSUUID.UUID.UUIDString, extension]];

    if (sourceURL.isFileURL) {
        NSError* copyError = nil;
        [[NSFileManager defaultManager] copyItemAtURL:sourceURL toURL:destination error:&copyError];
        if (copyError) {
            NSLog(@"[NFB] DownloadVoiceMessage copy failed: %@", copyError);
            return;
        }
        [BHTManager showSaveVC:destination];
        return;
    }

    TFNHUD* hud = [[objc_getClass("TFNHUD") alloc]
        initWithText:[[BHTBundle sharedBundle]
                          localizedTwitterStringForKey:@"DOWNLOAD_LIVE_ACTIVITY_DOWNLOADING"]];
    [hud show];
    NSURLSessionDownloadTask* task = [[NSURLSession sharedSession]
        downloadTaskWithURL:sourceURL
          completionHandler:^(NSURL* location, NSURLResponse* response, NSError* error) {
              dispatch_async(dispatch_get_main_queue(), ^{
                  [hud hide];
                  if (!location || error) {
                      return;
                  }
                  NSError* moveError = nil;
                  [[NSFileManager defaultManager] moveItemAtURL:location toURL:destination error:&moveError];
                  if (moveError) {
                      return;
                  }
                  [BHTManager showSaveVC:destination];
              });
          }];
    [task resume];
}

// MARK: - DM video download

// The DM UI is Swift now: media messages live in DMConversation.MessageAttachmentView,
// which hosts a shared TweetMediaAttachments media view exposing its models through
// -inlineMediaInfos. Collect the entities from whichever descendant carries them.
static NSArray* DMVideoEntities(UIView* attachmentView) {
    NSMutableArray* entities = [NSMutableArray new];

    EnumerateSubviewsRecursively(attachmentView, ^(UIView* view) {
        if (![view respondsToSelector:@selector(inlineMediaInfos)]) {
            return;
        }

        for (TFSTwitterMediaInfo* info in
             [(_TtC21TweetMediaAttachments14MultiMediaView*)view inlineMediaInfos]) {
            TFSTwitterEntityMedia* media = info.mediaEntity;
            if (media.videoInfo.variants.count > 0) {
                [entities addObject:media];
            }
        }
    });

    return [entities copy];
}

%hook _TtC14DMConversation21MessageAttachmentView
%property (nonatomic, strong) UIContextMenuInteraction* downloadMenuInteraction;
%property (nonatomic, strong) DownloadInlineButton* downloadHandler;
- (void)layoutSubviews {
    %orig;

    if ([BHTSettings boolForKey:@"download_videos"] && self.downloadMenuInteraction == nil) {
        self.downloadMenuInteraction = [[UIContextMenuInteraction alloc] initWithDelegate:self];
        [self addInteraction:self.downloadMenuInteraction];
    }
}
%new
- (UIContextMenuConfiguration*)contextMenuInteraction:(UIContextMenuInteraction*)interaction
                       configurationForMenuAtLocation:(CGPoint)location {
    NSArray* videoEntities = DMVideoEntities(self);
    if (videoEntities.count == 0) {
        return nil;
    }

    return [UIContextMenuConfiguration
        configurationWithIdentifier:nil
                    previewProvider:nil
                     actionProvider:^UIMenu* _Nullable(
                         NSArray<UIMenuElement*>* _Nonnull suggestedActions) {
                         UIAction* saveAction = [UIAction
                             actionWithTitle:
                                 [[BHTBundle sharedBundle]
                                     localizedTwitterStringForKey:@"DOWNLOAD_ACTIVITY_VIEW_LABEL"]
                                       image:[UIImage systemImageNamed:@"square.and.arrow.down"]
                                  identifier:nil
                                     handler:^(__kindof UIAction* _Nonnull action) {
                                         if (self.downloadHandler == nil) {
                                             self.downloadHandler = [%c(DownloadInlineButton) new];
                                         }
                                         [self.downloadHandler
                                             presentDownloadOptionsForMediaEntities:videoEntities];
                                     }];
                         return [UIMenu menuWithTitle:@"" children:@[saveAction]];
                     }];
}
%end

// MARK: - DM voice message download (context menu)
//
// Lives directly on the audio view -- see the note at the top of this file
// for why this can't share MessageAttachmentView's interaction. Same
// UIContextMenuInteraction pattern as the video/gif download above: its
// fixed ~0.5s trigger duration wins the race against the stock DM context
// menu (React/Reply/Copy/etc) essentially every time a long-press lands on
// the audio view specifically, replacing it with just Download rather than
// merging the two. That's an accepted tradeoff, matching how the video/gif
// download above already behaves for images/videos -- confirmed on-device
// that a longer-duration separate UILongPressGestureRecognizer (see the
// commented-out block below) doesn't help: the native menu's own preview
// animation takes over the touch before the longer threshold is ever
// reached, so it never fires at all.
%hook _TtC13DMAttachments24AttachmentAssetAudioView
%property (nonatomic, strong) UIContextMenuInteraction* voiceDownloadInteraction;
- (void)layoutSubviews {
    %orig;

    if ([BHTSettings boolForKey:@"download_voice_messages"] && self.voiceDownloadInteraction == nil) {
        self.voiceDownloadInteraction = [[UIContextMenuInteraction alloc] initWithDelegate:self];
        [self addInteraction:self.voiceDownloadInteraction];
    }
}
%new
- (UIContextMenuConfiguration*)contextMenuInteraction:(UIContextMenuInteraction*)interaction
                       configurationForMenuAtLocation:(CGPoint)location {
    NSURL* voiceURL = nfbLastCapturedVoiceURL;
    if (!voiceURL) {
        return nil;
    }

    return [UIContextMenuConfiguration
        configurationWithIdentifier:nil
                    previewProvider:nil
                     actionProvider:^UIMenu* _Nullable(
                         NSArray<UIMenuElement*>* _Nonnull suggestedActions) {
                         UIAction* saveAction = [UIAction
                             actionWithTitle:
                                 [[BHTBundle sharedBundle]
                                     localizedTwitterStringForKey:@"DOWNLOAD_ACTIVITY_VIEW_LABEL"]
                                       image:[UIImage systemImageNamed:@"square.and.arrow.down"]
                                  identifier:nil
                                     handler:^(__kindof UIAction* _Nonnull action) {
                                         DownloadVoiceMessage(voiceURL);
                                     }];
                         return [UIMenu menuWithTitle:@"" children:@[saveAction]];
                     }];
}
%end

// MARK: - Upload custom voice

// Overwrites the recording at the attachment's existing file path, so the
// composer picks up the replacement without any model changes.
%hook T1MediaAttachmentsViewCell
%property (nonatomic, strong) UIButton* uploadButton;
- (void)updateCellElements {
    %orig;

    BOOL isVoiceRecording = [self.attachment isKindOfClass:%c(TTMAssetVoiceRecording)];

    if (isVoiceRecording && self.uploadButton == nil) {
        TFNButton* removeButton = [self valueForKey:@"_removeButton"];
        if (removeButton == nil) {
            return;
        }

        self.uploadButton = [UIButton buttonWithType:UIButtonTypeCustom];
        UIImageSymbolConfiguration* smallConfig =
            [UIImageSymbolConfiguration configurationWithScale:UIImageSymbolScaleSmall];
        UIImage* arrowUpImage = [UIImage systemImageNamed:@"arrow.up" withConfiguration:smallConfig];
        [self.uploadButton setImage:arrowUpImage forState:UIControlStateNormal];
        [self.uploadButton addTarget:self
                              action:@selector(handleUploadButton:)
                    forControlEvents:UIControlEventTouchUpInside];
        [self.uploadButton setTintColor:UIColor.labelColor];
        [self.uploadButton setBackgroundColor:[UIColor blackColor]];
        [self.uploadButton.layer setCornerRadius:29 / 2];
        [self.uploadButton setTranslatesAutoresizingMaskIntoConstraints:false];

        [self addSubview:self.uploadButton];
        [NSLayoutConstraint activateConstraints:@[
            [self.uploadButton.trailingAnchor constraintEqualToAnchor:removeButton.leadingAnchor
                                                             constant:-10],
            [self.uploadButton.topAnchor constraintEqualToAnchor:removeButton.topAnchor],
            [self.uploadButton.widthAnchor constraintEqualToConstant:29],
            [self.uploadButton.heightAnchor constraintEqualToConstant:29],
        ]];
    }

    self.uploadButton.hidden = !isVoiceRecording;
}
%new
- (void)handleUploadButton:(UIButton*)sender {
    UIImagePickerController* videoPicker = [[UIImagePickerController alloc] init];
    videoPicker.mediaTypes = @[(NSString*)kUTTypeMovie];
    videoPicker.delegate = self;

    [topMostController() presentViewController:videoPicker animated:YES completion:nil];
}
%new
- (void)imagePickerController:(UIImagePickerController*)picker
    didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id>*)info {
    NSURL* videoURL = info[UIImagePickerControllerMediaURL];
    TTMAssetVoiceRecording* attachment = self.attachment;
    NSURL* recorder_url = [NSURL fileURLWithPath:attachment.filePath];

    if (recorder_url != nil) {
        NSFileManager* fileManager = [NSFileManager defaultManager];

        NSError* error = nil;
        if ([fileManager fileExistsAtPath:[recorder_url path]]) {
            [fileManager removeItemAtURL:recorder_url error:&error];
            if (error) {
                NSLog(@"[BHTwitter] Error removing existing file: %@", error);
            }
        }

        [fileManager copyItemAtURL:videoURL toURL:recorder_url error:&error];
        if (error) {
            NSLog(@"[BHTwitter] Error copying file: %@", error);
        }
    }

    [picker dismissViewControllerAnimated:true completion:nil];
}
%new
- (void)imagePickerControllerDidCancel:(UIImagePickerController*)picker {
    [picker dismissViewControllerAnimated:true completion:nil];
}
%end

// MARK: - Save tweet as an image

%hook TTAStatusInlineShareButton
- (void)didLongPressActionButton:(UILongPressGestureRecognizer*)gestureRecognizer {
    if ([BHTSettings boolForKey:@"tweet_to_image"]) {
        if (gestureRecognizer.state == UIGestureRecognizerStateBegan) {
            UIView* statusView = self.superview;
            while (statusView && ![statusView respondsToSelector:@selector(eventHandler)]) {
                statusView = statusView.superview;
            }

            UIView* tweetView = nil;
            id eventHandler = [(T1StandardStatusView*)statusView eventHandler];
            if ([eventHandler isKindOfClass:UIView.class]) {
                tweetView = eventHandler;
            }

            if (tweetView == nil) {
                UIView* ancestor = self.superview;
                while (ancestor && ![ancestor isKindOfClass:UITableViewCell.class] &&
                       ![ancestor isKindOfClass:UICollectionViewCell.class]) {
                    ancestor = ancestor.superview;
                }
                tweetView = ancestor;
            }

            if (tweetView == nil) {
                return %orig;
            }

            UIImage* tweetImage = imageFromView(tweetView);
            NSData* pngData = UIImagePNGRepresentation(tweetImage);
            NSURL* pngURL = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
                URLByAppendingPathComponent:[NSString
                                                stringWithFormat:@"%@.png", [[NSUUID UUID] UUIDString]]];
            [pngData writeToURL:pngURL atomically:YES];
            UIActivityViewController* acVC =
                [[UIActivityViewController alloc] initWithActivityItems:@[pngURL]
                                                  applicationActivities:nil];
            if (is_iPad()) {
                acVC.popoverPresentationController.sourceView = self;
                acVC.popoverPresentationController.sourceRect = self.frame;
            }
            [topMostController() presentViewController:acVC animated:true completion:nil];
            return;
        }
    }
    return %orig;
}
%end

// MARK: - Tweet video download

// _t1_actionItemsForStatus:... is a category method on UIViewController, so the
// hook has to land on the base class to cover every share/action sheet.
%hook UIViewController
- (NSArray*)_t1_actionItemsForStatus:(__unsafe_unretained id)status
                             account:(__unsafe_unretained id)account
                     shareableEntity:(__unsafe_unretained id)shareableEntity
                           entityURL:(__unsafe_unretained id)entityURL
                              source:(__unsafe_unretained id)source
                             options:(NSUInteger)options
                     scribeComponent:(__unsafe_unretained id)scribeComponent
                           doneBlock:(__unsafe_unretained id)doneBlock {
    NSArray* origItems = %orig;

    if (![BHTSettings boolForKey:@"download_videos"] ||
        ![status respondsToSelector:@selector(entities)]) {
        return origItems;
    }

    NSArray* mediaEntities = [[status entities] media];
    BOOL hasVideo = NO;
    // mediaType 2 = GIF, 3 = video
    for (TFSTwitterEntityMedia* media in mediaEntities) {
        if ([media isKindOfClass:%c(TFSTwitterEntityMedia)] &&
            (media.mediaType == 2 || media.mediaType == 3)) {
            hasVideo = YES;
            break;
        }
    }
    if (!hasVideo) {
        return origItems;
    }

    static char downloaderKey;
    DownloadInlineButton* downloader = objc_getAssociatedObject(self, &downloaderKey);
    if (!downloader) {
        downloader = [%c(DownloadInlineButton) new];
        objc_setAssociatedObject(self, &downloaderKey, downloader, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    TFNActionItem* downloadItem = [%c(TFNActionItem)
        actionItemWithTitle:[[BHTBundle sharedBundle] localizedStringForKey:@"DOWNLOAD_VIDEOS_TITLE"]
                  imageName:@"arrow_down_circle_stroke"
                     action:^{
                         [downloader presentDownloadOptionsForMediaEntities:mediaEntities];
                     }];

    NSMutableArray* newItems = origItems ? [origItems mutableCopy] : [NSMutableArray array];
    NSUInteger insertIndex = newItems.count > 0 ? newItems.count - 1 : 0;
    [newItems insertObject:downloadItem atIndex:insertIndex];
    return newItems;
}
%end
