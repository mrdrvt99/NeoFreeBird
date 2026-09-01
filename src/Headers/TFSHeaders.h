//
//  TFSHeaders.h
//  BHTwitter
//
//  Created by BandarHelal
//

#import <Foundation/Foundation.h>

@interface TFSTwitterEntityMediaVideoVariant : NSObject
@property (readonly, copy, nonatomic) NSString* contentType;
@property (readonly, copy, nonatomic) NSString* url;
@end

@interface TFSTwitterEntityMediaVideoInfo : NSObject
@property (readonly, copy, nonatomic) NSArray* variants;
@property (readonly, copy, nonatomic) NSString* primaryUrl;
@end

@interface TFSTwitterEntityMedia : NSObject
@property (readonly, nonatomic) TFSTwitterEntityMediaVideoInfo* videoInfo;
@property (readonly, copy, nonatomic) NSString* mediaURL;
@property (nonatomic, assign, readonly)
    NSInteger mediaType; // 1 = photo, 2 = GIF, 3 = video
@end

@interface TFSTwitterMediaInfo : NSObject
@property (readonly, nonatomic) TFSTwitterEntityMedia* mediaEntity;
@property (readonly, nonatomic) TFSTwitterEntityMediaVideoInfo* videoInfo;
@end

@interface TFSTwitterEntitySet : NSObject
@property (readonly, copy, nonatomic) NSArray* media;
@end

@interface TFSTwitterEntityURL : NSObject
@property (readonly, copy, nonatomic) NSString* expandedURL;
@end

@interface TFSTwitterRelationship : NSObject
@property (readonly, nonatomic) NSInteger superFollowingState;
@property (readonly, nonatomic) long long followedByCurrentAccountState;
@property (readonly, nonatomic) long long followingCurrentAccountState;
@property (readonly, nonatomic) long long followRequestSentByCurrentAccountState;
@property (readonly, nonatomic) long long blockedByCurrentAccountState;
@property (readonly, nonatomic) long long blockingCurrentAccountState;
@property (readonly, nonatomic) long long mutedByCurrentAccountState;
@end

@interface NSNumber (TFSTwitter)
- (NSString*)tfs_twitterAbbreviated;
@end
