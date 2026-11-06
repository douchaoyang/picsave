#import "PSDownloader.h"

#import "PSImageProbe.h"
#import "PSProgressHUD.h"

#import <ImageIO/ImageIO.h>
#import <string.h>

static NSString *const kPSRandomAlphabet = @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

@interface PSDownloader () <NSURLSessionDownloadDelegate>

@property(nonatomic, assign, readwrite, getter=isBusy) BOOL busy;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionDownloadTask *task;
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
    NSString *directory = [self picsaveDirectory];
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
}

- (void)finishWithSuccess {
    if (self.settled) {
        return;
    }
    self.settled = YES;
    self.task = nil;
    [self.hud completeAndDismiss];
}

- (void)finishWithFailure {
    if (self.settled) {
        return;
    }
    self.settled = YES;
    [self.task cancel];
    self.task = nil;
    [self.hud failAndDismiss];
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

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
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
