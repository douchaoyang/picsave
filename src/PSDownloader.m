#import "PSDownloader.h"

#import "PSImageProbe.h"
#import "PSProgressHUD.h"

#import <ImageIO/ImageIO.h>
#import <string.h>

static NSString *const kPSRandomAlphabet = @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

@interface PSDownloader () <NSURLSessionDownloadDelegate, NSURLSessionDataDelegate>

@property(nonatomic, assign, readwrite, getter=isBusy) BOOL busy;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionDownloadTask *task;
@property(nonatomic, strong) NSURLSession *videoSession;
@property(nonatomic, strong) NSURLSessionDataTask *videoTask;
@property(nonatomic, strong) dispatch_queue_t videoIOQueue;
@property(nonatomic, strong) NSFileHandle *videoHandle;
@property(nonatomic, strong) NSMutableData *videoHeaderBuffer;
@property(nonatomic, copy) NSURL *videoURL;
@property(nonatomic, copy) NSString *partialPath;
@property(nonatomic, copy) NSString *partialMarkerPath;
@property(nonatomic, copy) NSString *videoBaseName;
@property(nonatomic, copy) NSString *videoExtension;
@property(nonatomic, assign) int64_t videoResumeOffset;
@property(nonatomic, assign) int64_t videoReceived;
@property(nonatomic, assign) int64_t videoExpectedTotal;
@property(nonatomic, assign) BOOL videoHeaderChecked;
@property(nonatomic, assign) BOOL videoDeletePartial;
@property(nonatomic, assign) BOOL videoRetryWithoutRange;
@property(nonatomic, assign) BOOL videoRetriedWithoutRange;
@property(nonatomic, assign) BOOL videoReplaceFromStart;
@property(atomic, assign) BOOL videoWriteFailed;
@property(nonatomic, strong) PSProgressHUD *hud;
@property(nonatomic, assign) BOOL settled;
@property(nonatomic, assign) BOOL pendingSuccess;

@end

@implementation PSDownloader

+ (instancetype)sharedDownloader {
    static PSDownloader *downloader;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      downloader = [[PSDownloader alloc] init];
    });
    return downloader;
}

- (NSURLSession *)session {
    if (!_session) {
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.HTTPCookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        configuration.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;
        configuration.HTTPShouldSetCookies = YES;
        configuration.URLCredentialStorage = [NSURLCredentialStorage sharedCredentialStorage];
        configuration.timeoutIntervalForRequest = 60;
        configuration.timeoutIntervalForResource = 300;
        _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:[NSOperationQueue mainQueue]];
    }
    return _session;
}

- (NSURLSession *)videoSession {
    if (!_videoSession) {
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.HTTPCookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        configuration.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;
        configuration.HTTPShouldSetCookies = YES;
        configuration.URLCredentialStorage = [NSURLCredentialStorage sharedCredentialStorage];
        configuration.timeoutIntervalForRequest = 60;
        // 视频可能很大。拉长整次传输的上限，空闲超过 60 秒仍会失败。不用后台会话。
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60;
        _videoSession = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:[NSOperationQueue mainQueue]];
    }
    return _videoSession;
}

- (dispatch_queue_t)videoIOQueue {
    if (!_videoIOQueue) {
        _videoIOQueue = dispatch_queue_create("picsave.video.io", DISPATCH_QUEUE_SERIAL);
    }
    return _videoIOQueue;
}

#pragma mark - 路径与命名

- (NSString *)picsaveDirectory {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (documents.length == 0) {
        return nil;
    }
    return [documents stringByAppendingPathComponent:@"picsave"];
}

- (BOOL)ensurePicsaveDirectory {
    NSString *directory = [self picsaveDirectory];
    if (directory.length == 0) {
        return NO;
    }
    return [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
}

- (NSString *)videoDirectory {
    NSString *root = [self picsaveDirectory];
    if (root.length == 0) {
        return nil;
    }
    return [root stringByAppendingPathComponent:@"v"];
}

- (BOOL)ensureVideoDirectory {
    NSString *directory = [self videoDirectory];
    if (directory.length == 0) {
        return NO;
    }
    return [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
}

+ (NSString *)normalizedImageExtension:(NSString *)extension {
    if (extension.length == 0) {
        return nil;
    }
    NSString *lower = extension.lowercaseString;
    NSMutableString *letters = [NSMutableString string];
    for (NSUInteger index = 0; index < lower.length && letters.length < 5; index++) {
        unichar character = [lower characterAtIndex:index];
        if (character < 'a' || character > 'z') {
            break;
        }
        [letters appendFormat:@"%C", character];
    }
    NSDictionary<NSString *, NSString *> *map = @{
        @"jpg" : @"jpg",
        @"jpeg" : @"jpg",
        @"png" : @"png",
        @"gif" : @"gif",
        @"webp" : @"webp",
        @"heic" : @"heic",
        @"heif" : @"heic",
        @"bmp" : @"bmp",
        @"tif" : @"tiff",
        @"tiff" : @"tiff"
    };
    return map[letters];
}

+ (NSString *)extensionForMIMEType:(NSString *)mimeType {
    if (mimeType.length == 0) {
        return nil;
    }
    NSString *lower = mimeType.lowercaseString;
    NSDictionary<NSString *, NSString *> *map = @{
        @"image/jpeg" : @"jpg",
        @"image/jpg" : @"jpg",
        @"image/png" : @"png",
        @"image/gif" : @"gif",
        @"image/webp" : @"webp",
        @"image/heic" : @"heic",
        @"image/heif" : @"heic",
        @"image/bmp" : @"bmp",
        @"image/x-ms-bmp" : @"bmp",
        @"image/tiff" : @"tiff"
    };
    return map[lower];
}

+ (NSString *)extensionForFileHeader:(NSData *)data {
    if (data.length < 12) {
        return nil;
    }
    const unsigned char *bytes = data.bytes;
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
        return @"jpg";
    }
    if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
        return @"png";
    }
    if (bytes[0] == 'G' && bytes[1] == 'I' && bytes[2] == 'F' && bytes[3] == '8') {
        return @"gif";
    }
    if (bytes[0] == 'B' && bytes[1] == 'M') {
        return @"bmp";
    }
    if (memcmp(bytes, "RIFF", 4) == 0 && memcmp(bytes + 8, "WEBP", 4) == 0) {
        return @"webp";
    }
    if (memcmp(bytes + 4, "ftyp", 4) == 0) {
        if (memcmp(bytes + 8, "heic", 4) == 0 || memcmp(bytes + 8, "heix", 4) == 0 || memcmp(bytes + 8, "heif", 4) == 0 || memcmp(bytes + 8, "mif1", 4) == 0 ||
            memcmp(bytes + 8, "msf1", 4) == 0) {
            return @"heic";
        }
    }
    return nil;
}

+ (NSString *)extensionBySniffingFileAtURL:(NSURL *)fileURL {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:fileURL error:nil];
    if (!handle) {
        return nil;
    }
    NSData *header = [handle readDataUpToLength:32 error:nil];
    [handle closeAndReturnError:nil];
    return [self extensionForFileHeader:header];
}

+ (NSString *)sanitizedBaseName:(NSString *)rawName {
    if (rawName.length == 0) {
        return nil;
    }
    NSString *decoded = rawName.stringByRemovingPercentEncoding ?: rawName;
    NSCharacterSet *illegal = [NSCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|"];
    NSMutableString *clean = [NSMutableString string];
    for (NSUInteger index = 0; index < decoded.length; index++) {
        unichar character = [decoded characterAtIndex:index];
        if (character < 32 || [illegal characterIsMember:character]) {
            continue;
        }
        [clean appendFormat:@"%C", character];
    }
    NSString *trimmed = [clean stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([trimmed hasSuffix:@"."]) {
        if (trimmed.length == 1) {
            return nil;
        }
        trimmed = [trimmed substringToIndex:trimmed.length - 1];
    }
    if (trimmed.length == 0 || [trimmed isEqualToString:@"."] || [trimmed isEqualToString:@".."]) {
        return nil;
    }
    if (trimmed.length > 80) {
        trimmed = [trimmed substringToIndex:80];
    }
    return trimmed;
}

+ (NSString *)originalNameFromURL:(NSURL *)url {
    NSString *last = url.lastPathComponent.stringByRemovingPercentEncoding ?: url.lastPathComponent;
    if (last.length == 0 || [last isEqualToString:@"/"]) {
        return nil;
    }
    if (last.pathExtension.length > 0) {
        last = last.stringByDeletingPathExtension;
    }
    return [self sanitizedBaseName:last];
}

+ (NSString *)randomToken {
    NSMutableString *token = [NSMutableString stringWithCapacity:6];
    uint32_t length = (uint32_t)kPSRandomAlphabet.length;
    for (NSInteger index = 0; index < 6; index++) {
        unichar character = [kPSRandomAlphabet characterAtIndex:arc4random_uniform(length)];
        [token appendFormat:@"%C", character];
    }
    return token;
}

- (NSString *)uniquePathWithBaseName:(NSString *)baseName extension:(NSString *)extension {
    return [self uniquePathWithBaseName:baseName extension:extension directory:[self picsaveDirectory]];
}

- (NSString *)uniquePathWithBaseName:(NSString *)baseName extension:(NSString *)extension directory:(NSString *)directory {
    if (directory.length == 0 || extension.length == 0) {
        return nil;
    }
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSInteger attempt = 0; attempt < 8; attempt++) {
        NSString *token = [PSDownloader randomToken];
        NSString *fileName = baseName.length > 0 ? [NSString stringWithFormat:@"%@-%@.%@", baseName, token, extension]
                                                  : [NSString stringWithFormat:@"%@.%@", token, extension];
        NSString *path = [directory stringByAppendingPathComponent:fileName];
        if (![fileManager fileExistsAtPath:path]) {
            return path;
        }
    }
    return nil;
}

#pragma mark - 开始

- (void)startWithSource:(PSImageSource *)source inWindow:(UIWindow *)window {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [self startWithSource:source inWindow:window];
        });
        return;
    }
    if (self.busy || !source || !window) {
        return;
    }

    self.busy = YES;
    self.settled = NO;
    self.pendingSuccess = NO;
    self.task = nil;

    __weak typeof(self) weakSelf = self;
    self.hud = [PSProgressHUD showInWindow:window
                             cancelHandler:^{
                               [weakSelf cancelTask];
                             }
                            dismissHandler:^{
                              weakSelf.busy = NO;
                              weakSelf.hud = nil;
                            }];

    if (source.kind == PSMediaKindVideo) {
        self.videoRetriedWithoutRange = NO;
        if (![self ensureVideoDirectory] || ![self preparePartialFileForURL:source.remoteURL]) {
            [self finishWithFailure];
            return;
        }
        [self beginVideoTaskAllowingRange:YES];
        return;
    }

    if (![self ensurePicsaveDirectory]) {
        [self finishWithFailure];
        return;
    }

    if (PSIsHTTPURL(source.remoteURL)) {
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:source.remoteURL];
        request.HTTPShouldHandleCookies = YES;
        self.task = [self.session downloadTaskWithRequest:request];
        [self.task resume];
        return;
    }

    if (source.image) {
        [self saveImage:source.image];
        return;
    }

    [self finishWithFailure];
}

- (void)cancelTask {
    if (self.settled) {
        return;
    }
    self.settled = YES;
    self.pendingSuccess = NO;
    [self.task cancel];
    self.task = nil;
    [self.videoTask cancel];
    self.videoTask = nil;
    [self closeVideoHandleWaiting:YES];
}

- (void)finishWithSuccess {
    if (self.settled) {
        return;
    }
    self.settled = YES;
    self.task = nil;
    self.videoTask = nil;
    [self.hud completeAndDismiss];
}

- (void)finishWithFailure {
    if (self.settled) {
        return;
    }
    self.settled = YES;
    [self.task cancel];
    self.task = nil;
    [self.videoTask cancel];
    self.videoTask = nil;
    [self closeVideoHandleWaiting:YES];
    [self.hud failAndDismiss];
}

#pragma mark - 视频

+ (NSString *)shortHashForString:(NSString *)string {
    uint64_t hash = 14695981039346656037ULL;
    const char *bytes = string.UTF8String;
    if (!bytes) {
        return @"00000000";
    }
    for (const unsigned char *cursor = (const unsigned char *)bytes; *cursor; cursor++) {
        hash ^= *cursor;
        hash *= 1099511628211ULL;
    }
    return [NSString stringWithFormat:@"%08llx", (unsigned long long)(hash & 0xffffffffULL)];
}

+ (BOOL)dataLooksLikeMP4OrMOV:(NSData *)data {
    if (data.length < 8) {
        return NO;
    }
    const unsigned char *bytes = data.bytes;
    return memcmp(bytes + 4, "ftyp", 4) == 0;
}

+ (BOOL)MIMETypeAllowsVideoFile:(NSString *)mimeType {
    if (mimeType.length == 0) {
        return YES;
    }
    NSString *lower = mimeType.lowercaseString;
    NSRange separator = [lower rangeOfString:@";"];
    if (separator.location != NSNotFound) {
        lower = [lower substringToIndex:separator.location];
    }
    lower = [lower stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [lower isEqualToString:@"video/mp4"] || [lower isEqualToString:@"video/quicktime"] || [lower isEqualToString:@"application/mp4"] ||
           [lower isEqualToString:@"application/octet-stream"] || [lower isEqualToString:@"binary/octet-stream"];
}

+ (int64_t)totalBytesFromContentRange:(NSString *)header {
    if (header.length == 0) {
        return -1;
    }
    NSRange slash = [header rangeOfString:@"/" options:NSBackwardsSearch];
    if (slash.location == NSNotFound || slash.location + 1 >= header.length) {
        return -1;
    }
    NSString *total = [[header substringFromIndex:slash.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (total.length == 0 || [total isEqualToString:@"*"]) {
        return -1;
    }
    long long value = [total longLongValue];
    return value > 0 ? value : -1;
}

- (void)closeVideoHandleWaiting:(BOOL)wait {
    NSFileHandle *handle = self.videoHandle;
    self.videoHandle = nil;
    if (!handle) {
        return;
    }
    void (^closeHandle)(void) = ^{
      [handle closeAndReturnError:nil];
    };
    if (wait) {
        dispatch_sync(self.videoIOQueue, closeHandle);
    } else {
        dispatch_async(self.videoIOQueue, closeHandle);
    }
}

- (void)removePartialFiles {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (self.partialPath.length > 0) {
        [fileManager removeItemAtPath:self.partialPath error:nil];
    }
    if (self.partialMarkerPath.length > 0) {
        [fileManager removeItemAtPath:self.partialMarkerPath error:nil];
    }
}

- (void)removePartialIfEmpty {
    if (self.partialPath.length == 0) {
        return;
    }
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:self.partialPath error:nil];
    if (attributes.fileSize == 0) {
        [self removePartialFiles];
    }
}

- (BOOL)preparePartialFileForURL:(NSURL *)url {
    NSString *extension = PSVideoFileExtension(url);
    NSString *directory = [self videoDirectory];
    if (extension.length == 0 || directory.length == 0) {
        return NO;
    }

    NSString *baseName = [PSDownloader originalNameFromURL:url];
    NSString *hash = [PSDownloader shortHashForString:url.absoluteString];
    NSString *partialName = baseName.length > 0 ? [NSString stringWithFormat:@"%@-%@.%@.pspart", baseName, hash, extension]
                                                 : [NSString stringWithFormat:@"%@.%@.pspart", hash, extension];
    NSString *partialPath = [directory stringByAppendingPathComponent:partialName];
    NSString *markerPath = [partialPath stringByAppendingString:@".url"];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *markedURL = [NSString stringWithContentsOfFile:markerPath encoding:NSUTF8StringEncoding error:nil];
    unsigned long long offset = 0;
    BOOL sameURL = [markedURL isEqualToString:url.absoluteString] && [fileManager fileExistsAtPath:partialPath];
    if (sameURL) {
        offset = [[fileManager attributesOfItemAtPath:partialPath error:nil] fileSize];
    } else {
        [fileManager removeItemAtPath:partialPath error:nil];
        [fileManager removeItemAtPath:markerPath error:nil];
    }
    if (offset > 0 && offset < 12) {
        [fileManager removeItemAtPath:partialPath error:nil];
        offset = 0;
    }
    if (offset >= 12) {
        NSFileHandle *reader = [NSFileHandle fileHandleForReadingAtPath:partialPath];
        NSData *header = [reader readDataUpToLength:12 error:nil];
        [reader closeAndReturnError:nil];
        if (![PSDownloader dataLooksLikeMP4OrMOV:header]) {
            [fileManager removeItemAtPath:partialPath error:nil];
            offset = 0;
        }
    }
    if (offset == 0) {
        [fileManager removeItemAtPath:partialPath error:nil];
        if (![fileManager createFileAtPath:partialPath contents:nil attributes:nil]) {
            return NO;
        }
    }
    if (![url.absoluteString writeToFile:markerPath atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
        if (offset == 0) {
            [fileManager removeItemAtPath:partialPath error:nil];
        }
        return NO;
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:partialPath];
    if (!handle) {
        return NO;
    }
    if (offset > 0) {
        NSError *seekError = nil;
        if (![handle seekToEndReturningOffset:NULL error:&seekError]) {
            [handle closeAndReturnError:nil];
            return NO;
        }
    }

    self.videoURL = url;
    self.videoBaseName = baseName;
    self.videoExtension = extension;
    self.partialPath = partialPath;
    self.partialMarkerPath = markerPath;
    self.videoHandle = handle;
    self.videoResumeOffset = (int64_t)offset;
    self.videoReceived = 0;
    self.videoExpectedTotal = 0;
    self.videoHeaderChecked = offset > 0;
    self.videoHeaderBuffer = [NSMutableData data];
    self.videoDeletePartial = NO;
    self.videoRetryWithoutRange = NO;
    self.videoReplaceFromStart = NO;
    self.videoWriteFailed = NO;
    return YES;
}

- (BOOL)truncateVideoFile {
    NSFileHandle *handle = self.videoHandle;
    if (!handle) {
        return NO;
    }
    __block BOOL truncated = NO;
    dispatch_sync(self.videoIOQueue, ^{
      NSError *error = nil;
      truncated = [handle truncateAtOffset:0 error:&error] && [handle seekToOffset:0 error:&error];
    });
    return truncated;
}

- (BOOL)rewindPartialFile {
    self.videoResumeOffset = 0;
    self.videoReceived = 0;
    self.videoExpectedTotal = 0;
    self.videoHeaderChecked = NO;
    self.videoHeaderBuffer = [NSMutableData data];
    self.videoReplaceFromStart = NO;
    return [self truncateVideoFile];
}

- (void)beginVideoTaskAllowingRange:(BOOL)allowRange {
    if (!self.videoURL || !self.videoHandle) {
        [self finishWithFailure];
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:self.videoURL];
    request.HTTPShouldHandleCookies = YES;
    if (allowRange && self.videoResumeOffset > 0) {
        [request setValue:[NSString stringWithFormat:@"bytes=%lld-", self.videoResumeOffset] forHTTPHeaderField:@"Range"];
    }
    self.videoTask = [self.videoSession dataTaskWithRequest:request];
    [self.videoTask resume];
}

- (void)updateVideoProgress {
    if (self.videoExpectedTotal <= 0) {
        [self.hud setIndeterminate];
        return;
    }
    int64_t done = self.videoResumeOffset + self.videoReceived;
    [self.hud setProgress:(float)done / (float)self.videoExpectedTotal];
}

- (void)appendVideoData:(NSData *)data {
    if (data.length == 0 || self.settled) {
        return;
    }
    if (self.videoWriteFailed) {
        self.videoDeletePartial = YES;
        [self.videoTask cancel];
        return;
    }
    if (!self.videoHeaderChecked) {
        if (!self.videoHeaderBuffer) {
            self.videoHeaderBuffer = [NSMutableData data];
        }
        [self.videoHeaderBuffer appendData:data];
        if (self.videoHeaderBuffer.length < 12) {
            return;
        }
        if (![PSDownloader dataLooksLikeMP4OrMOV:self.videoHeaderBuffer]) {
            BOOL replacing = self.videoReplaceFromStart;
            self.videoReplaceFromStart = NO;
            self.videoDeletePartial = !replacing;
            [self.videoTask cancel];
            return;
        }
        if (self.videoReplaceFromStart) {
            if (![self truncateVideoFile]) {
                self.videoDeletePartial = YES;
                [self.videoTask cancel];
                return;
            }
            self.videoResumeOffset = 0;
            self.videoReplaceFromStart = NO;
        }
        data = [self.videoHeaderBuffer copy];
        self.videoHeaderBuffer = nil;
        self.videoHeaderChecked = YES;
    }

    self.videoReceived += data.length;
    [self updateVideoProgress];
    NSFileHandle *handle = self.videoHandle;
    NSData *chunk = [data copy];
    dispatch_async(self.videoIOQueue, ^{
      NSError *error = nil;
      if (handle && ![handle writeData:chunk error:&error]) {
          self.videoWriteFailed = YES;
      }
    });
}

- (void)finishVideoDownloadWithError:(NSError *)error {
    [self closeVideoHandleWaiting:YES];
    self.videoTask = nil;
    if (self.videoWriteFailed) {
        self.videoDeletePartial = YES;
    }

    BOOL failed = error != nil || self.videoDeletePartial;
    if (!failed) {
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:self.partialPath error:nil];
        unsigned long long size = attributes.fileSize;
        if (size == 0) {
            failed = YES;
            self.videoDeletePartial = YES;
        } else if (self.videoExpectedTotal > 0 && (int64_t)size < self.videoExpectedTotal) {
            failed = YES;
        }
    }

    if (failed) {
        if (self.videoDeletePartial) {
            [self removePartialFiles];
        } else {
            [self removePartialIfEmpty];
        }
        [self finishWithFailure];
        return;
    }

    NSString *path = [self uniquePathWithBaseName:self.videoBaseName extension:self.videoExtension directory:[self videoDirectory]];
    if (path.length == 0) {
        [self finishWithFailure];
        return;
    }
    NSError *moveError = nil;
    BOOL moved = [[NSFileManager defaultManager] moveItemAtURL:[NSURL fileURLWithPath:self.partialPath] toURL:[NSURL fileURLWithPath:path] error:&moveError];
    if (!moved) {
        [self finishWithFailure];
        return;
    }
    [[NSFileManager defaultManager] removeItemAtPath:self.partialMarkerPath error:nil];
    [self finishWithSuccess];
}

- (void)handleVideoTask:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (self.settled || task != self.videoTask) {
        return;
    }
    if (self.videoRetryWithoutRange && !self.videoRetriedWithoutRange) {
        self.videoRetriedWithoutRange = YES;
        self.videoRetryWithoutRange = NO;
        if ([self rewindPartialFile]) {
            [self beginVideoTaskAllowingRange:NO];
            return;
        }
        self.videoDeletePartial = YES;
    }
    [self finishVideoDownloadWithError:error];
}

#pragma mark - 内存图片

+ (BOOL)imageHasAlpha:(UIImage *)image {
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) {
        return NO;
    }
    CGImageAlphaInfo alpha = CGImageGetAlphaInfo(cgImage) & kCGBitmapAlphaInfoMask;
    switch (alpha) {
        case kCGImageAlphaFirst:
        case kCGImageAlphaLast:
        case kCGImageAlphaPremultipliedFirst:
        case kCGImageAlphaPremultipliedLast:
            return YES;
        default:
            return NO;
    }
}

+ (int)exifOrientationForImage:(UIImage *)image {
    switch (image.imageOrientation) {
        case UIImageOrientationUp:
            return 1;
        case UIImageOrientationDown:
            return 3;
        case UIImageOrientationLeft:
            return 8;
        case UIImageOrientationRight:
            return 6;
        case UIImageOrientationUpMirrored:
            return 2;
        case UIImageOrientationDownMirrored:
            return 4;
        case UIImageOrientationLeftMirrored:
            return 5;
        case UIImageOrientationRightMirrored:
            return 7;
    }
    return 1;
}

+ (NSData *)dataByWritingCGImage:(CGImageRef)image hasAlpha:(BOOL)hasAlpha orientation:(int)orientation {
    NSMutableData *data = [NSMutableData data];
    CFStringRef type = hasAlpha ? CFSTR("public.png") : CFSTR("public.jpeg");
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, type, 1, NULL);
    if (!destination) {
        return nil;
    }
    NSMutableDictionary *properties = [NSMutableDictionary dictionary];
    properties[(__bridge id)kCGImagePropertyOrientation] = @(orientation);
    if (!hasAlpha) {
        properties[(__bridge id)kCGImageDestinationLossyCompressionQuality] = @0.95;
    }
    CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)properties);
    BOOL wrote = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    return wrote && data.length > 0 ? data : nil;
}

+ (NSData *)encodedDataForImage:(UIImage *)image png:(BOOL *)png {
    if (image.size.width < 1 || image.size.height < 1) {
        return nil;
    }
    BOOL hasAlpha = [self imageHasAlpha:image];
    if (image.CGImage) {
        NSData *written = [self dataByWritingCGImage:image.CGImage hasAlpha:hasAlpha orientation:[self exifOrientationForImage:image]];
        if (written.length > 0) {
            if (png) {
                *png = hasAlpha;
            }
            return written;
        }
    }
    UIGraphicsImageRendererFormat *format = [[UIGraphicsImageRendererFormat alloc] init];
    format.opaque = !hasAlpha;
    format.scale = image.scale > 0 ? image.scale : 1;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:image.size format:format];
    UIImage *original = [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    if (hasAlpha) {
        if (png) {
            *png = YES;
        }
        return [renderer PNGDataWithActions:^(UIGraphicsImageRendererContext *context) {
          [original drawInRect:CGRectMake(0, 0, image.size.width, image.size.height)];
        }];
    }
    if (png) {
        *png = NO;
    }
    return [renderer JPEGDataWithCompressionQuality:0.95
                                            actions:^(UIGraphicsImageRendererContext *context) {
                                              [original drawInRect:CGRectMake(0, 0, image.size.width, image.size.height)];
                                            }];
}

- (void)saveImage:(UIImage *)image {
    [self.hud setProgress:0];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      BOOL png = NO;
      NSData *data = [PSDownloader encodedDataForImage:image png:&png];
      NSString *extension = png ? @"png" : @"jpg";
      dispatch_async(dispatch_get_main_queue(), ^{
        PSDownloader *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.settled) {
            return;
        }
        if (data.length == 0) {
            [strongSelf finishWithFailure];
            return;
        }
        NSString *path = [strongSelf uniquePathWithBaseName:nil extension:extension];
        if (path.length == 0 || ![data writeToFile:path atomically:YES]) {
            [strongSelf finishWithFailure];
            return;
        }
        [strongSelf.hud setProgress:1];
        [strongSelf finishWithSuccess];
      });
    });
}

#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session
                 downloadTask:(NSURLSessionDownloadTask *)downloadTask
                 didWriteData:(int64_t)bytesWritten
            totalBytesWritten:(int64_t)totalBytesWritten
    totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    if (downloadTask != self.task || self.settled) {
        return;
    }
    if (totalBytesExpectedToWrite <= 0) {
        [self.hud setIndeterminate];
        return;
    }
    [self.hud setProgress:(float)totalBytesWritten / (float)totalBytesExpectedToWrite];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location {
    if (downloadTask != self.task || self.settled) {
        return;
    }

    NSHTTPURLResponse *http = nil;
    if ([downloadTask.response isKindOfClass:[NSHTTPURLResponse class]]) {
        http = (NSHTTPURLResponse *)downloadTask.response;
        NSInteger status = http.statusCode;
        if (status >= 400) {
            return;
        }
    }

    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:location.path error:nil];
    if (attributes.fileSize == 0) {
        return;
    }

    NSURL *originalURL = downloadTask.originalRequest.URL;
    NSURL *finalURL = downloadTask.response.URL ?: originalURL;
    NSString *extension = [PSDownloader normalizedImageExtension:originalURL.pathExtension];
    if (extension.length == 0) {
        extension = [PSDownloader normalizedImageExtension:finalURL.pathExtension];
    }
    if (extension.length == 0) {
        extension = [PSDownloader extensionForMIMEType:http.MIMEType];
    }
    if (extension.length == 0) {
        extension = [PSDownloader extensionBySniffingFileAtURL:location];
    }
    if (extension.length == 0) {
        extension = @"jpg";
    }

    NSString *baseName = [PSDownloader originalNameFromURL:originalURL];
    if (baseName.length == 0) {
        baseName = [PSDownloader originalNameFromURL:finalURL];
    }
    NSString *path = [self uniquePathWithBaseName:baseName extension:extension];
    if (path.length == 0) {
        return;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSURL *destination = [NSURL fileURLWithPath:path];
    NSError *error = nil;
    BOOL moved = [fileManager moveItemAtURL:location toURL:destination error:&error];
    if (!moved) {
        moved = [fileManager copyItemAtURL:location toURL:destination error:&error];
    }
    self.pendingSuccess = moved;
}

- (void)URLSession:(NSURLSession *)session
              dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveResponse:(NSURLResponse *)response
     completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    if (dataTask != self.videoTask || self.settled) {
        completionHandler(NSURLSessionResponseCancel);
        return;
    }

    NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
    NSInteger status = http ? http.statusCode : 200;
    if (status == 416) {
        self.videoRetryWithoutRange = YES;
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    if (status >= 400) {
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    if (http && ![PSDownloader MIMETypeAllowsVideoFile:http.MIMEType]) {
        self.videoDeletePartial = YES;
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    if (status == 200 && self.videoResumeOffset > 0) {
        // 先确认新内容是视频，再覆盖已经下好的部分。
        self.videoReplaceFromStart = YES;
        self.videoHeaderChecked = NO;
        self.videoHeaderBuffer = [NSMutableData data];
        self.videoResumeOffset = 0;
        self.videoReceived = 0;
    }

    self.videoExpectedTotal = 0;
    if (http && status == 206) {
        int64_t total = [PSDownloader totalBytesFromContentRange:[http valueForHTTPHeaderField:@"Content-Range"]];
        if (total > 0) {
            self.videoExpectedTotal = total;
        } else if (http.expectedContentLength > 0) {
            self.videoExpectedTotal = self.videoResumeOffset + http.expectedContentLength;
        }
    } else if (http && http.expectedContentLength > 0) {
        self.videoExpectedTotal = http.expectedContentLength;
    }
    [self updateVideoProgress];
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    if (dataTask != self.videoTask || self.settled) {
        return;
    }
    [self appendVideoData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (task == self.videoTask) {
        [self handleVideoTask:task didCompleteWithError:error];
        return;
    }
    if (task != self.task || self.settled) {
        return;
    }
    if (error.code == NSURLErrorCancelled) {
        [self cancelTask];
        return;
    }
    if (self.pendingSuccess && !error) {
        [self finishWithSuccess];
        return;
    }
    [self finishWithFailure];
}

@end
