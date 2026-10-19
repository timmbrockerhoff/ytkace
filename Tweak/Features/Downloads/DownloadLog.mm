#import "DownloadLog.h"



static const NSUInteger YTKACEDownloadLogLimit = 512 * 1024;

static NSURL *YTKACEDownloadLogURL(void) {
    static NSURL *cached = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSNumber *> *candidates = @[@(NSDocumentDirectory),
                                            @(NSApplicationSupportDirectory),
                                            @(NSCachesDirectory)];
        for (NSNumber *candidate in candidates) {
            NSURL *base = [NSFileManager.defaultManager
                URLsForDirectory:(NSSearchPathDirectory)candidate.unsignedIntegerValue
                       inDomains:NSUserDomainMask].firstObject;
            if (base == nil) continue;
            NSURL *directory = [[base URLByAppendingPathComponent:@"YTKACE" isDirectory:YES]
                URLByAppendingPathComponent:@"Logs" isDirectory:YES];
            NSError *error = nil;
            if (![NSFileManager.defaultManager createDirectoryAtURL:directory
                                       withIntermediateDirectories:YES
                                                        attributes:nil
                                                             error:&error]) {
                continue;
            }
            NSURL *probe = [directory URLByAppendingPathComponent:@"downloads.log"];
            if (![NSFileManager.defaultManager fileExistsAtPath:probe.path] &&
                ![[NSData data] writeToURL:probe atomically:YES]) {
                continue;
            }
            cached = probe;
            break;
        }
        if (cached == nil) {
            cached = [NSURL fileURLWithPath:
                [NSTemporaryDirectory() stringByAppendingPathComponent:@"ytkace-downloads.log"]];
        }
        [NSUserDefaults.standardUserDefaults setObject:cached.path
                                                forKey:@"YTKACELogPath"];
    });
    return cached;
}

static dispatch_queue_t YTKACEDownloadLogQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.ytkace.download-log", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSString * const YTKACEDebugLogsKey = @"YTKACE.Preference.Developer.DebugLogs";

BOOL YTKACEDebugLogsEnabled(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:YTKACEDebugLogsKey];
}

void YTKACESetDebugLogsEnabled(BOOL enabled) {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:YTKACEDebugLogsKey];
}

static void YTKACEWriteLogLine(NSString *identifier, NSString *message);

void YTKACEDownloadLog(NSString *identifier, NSString *format, ...) {
    if (format.length == 0) return;
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    YTKACEWriteLogLine(identifier, message);
}

void YTKACEDebugLog(NSString *identifier, NSString *format, ...) {
    if (format.length == 0 || !YTKACEDebugLogsEnabled()) return;
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    YTKACEWriteLogLine(identifier, message);
}

// Log state below is touched only on YTKACEDownloadLogQueue(). Lines are appended through a
// long-lived file handle instead of re-reading and atomically rewriting the whole file per line.
static NSFileHandle *YTKACEDownloadLogHandle = nil;
static unsigned long long YTKACEDownloadLogSize = 0;

static void YTKACECloseDownloadLogHandle(void) {
    if (YTKACEDownloadLogHandle != nil) {
        [YTKACEDownloadLogHandle closeAndReturnError:nil];
        YTKACEDownloadLogHandle = nil;
    }
    YTKACEDownloadLogSize = 0;
}

static BOOL YTKACEOpenDownloadLogHandle(void) {
    if (YTKACEDownloadLogHandle != nil) return YES;
    NSURL *URL = YTKACEDownloadLogURL();
    if (![NSFileManager.defaultManager fileExistsAtPath:URL.path] &&
        ![NSFileManager.defaultManager createFileAtPath:URL.path contents:nil attributes:nil]) {
        return NO;
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:URL error:nil];
    if (handle == nil) return NO;
    unsigned long long offset = 0;
    if (![handle seekToEndReturningOffset:&offset error:nil]) {
        [handle closeAndReturnError:nil];
        return NO;
    }
    YTKACEDownloadLogHandle = handle;
    YTKACEDownloadLogSize = offset;
    return YES;
}

// Keeps roughly the newest half of the log, starting at a line boundary.
static void YTKACERotateDownloadLog(void) {
    YTKACECloseDownloadLogHandle();
    NSURL *URL = YTKACEDownloadLogURL();
    NSData *data = [NSData dataWithContentsOfURL:URL options:NSDataReadingMappedIfSafe error:nil];
    NSData *tail = NSData.data;
    NSUInteger keep = YTKACEDownloadLogLimit / 2;
    if (data.length > keep) {
        NSUInteger start = data.length - keep;
        NSRange newline = [data rangeOfData:[NSData dataWithBytes:"\n" length:1]
                                    options:0
                                      range:NSMakeRange(start, data.length - start)];
        if (newline.location != NSNotFound) start = NSMaxRange(newline);
        tail = [data subdataWithRange:NSMakeRange(start, data.length - start)];
    } else if (data != nil) {
        tail = data;
    }
    [tail writeToURL:URL atomically:YES];
}

static NSString *YTKACEDownloadLogTimestamp(NSDate *date) {
    // Same text as -[NSDate description] ("yyyy-MM-dd HH:mm:ss +0000"), without a formatter per line.
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
        formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss Z";
    });
    return [formatter stringFromDate:date];
}

static void YTKACEWriteLogLine(NSString *identifier, NSString *message) {
    if (message.length > 4096) {
        // Cut on a composed-character boundary so a split surrogate pair cannot make the UTF-8
        // conversion below fail.
        message = [message substringToIndex:
            [message rangeOfComposedCharacterSequenceAtIndex:4096].location];
    }
    NSDate *date = NSDate.date;
    NSString *tag = identifier.length == 0 ? @"download" : [identifier copy];
    dispatch_async(YTKACEDownloadLogQueue(), ^{
        NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n",
            YTKACEDownloadLogTimestamp(date), tag, message];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
        if (data.length == 0 || !YTKACEOpenDownloadLogHandle()) return;
        if (![YTKACEDownloadLogHandle writeData:data error:nil]) {
            YTKACECloseDownloadLogHandle();
            return;
        }
        YTKACEDownloadLogSize += data.length;
        if (YTKACEDownloadLogSize > YTKACEDownloadLogLimit) YTKACERotateDownloadLog();
    });
}

NSString *YTKACEDownloadLogContents(void) {
    __block NSString *contents = @"No download activity yet.";
    dispatch_sync(YTKACEDownloadLogQueue(), ^{
        NSString *value = [NSString stringWithContentsOfURL:YTKACEDownloadLogURL()
            encoding:NSUTF8StringEncoding error:nil];
        if (value.length != 0) contents = value;
    });
    return contents;
}

void YTKACEClearDownloadLog(void) {
    // Async: called from the launch constructor on the main thread. The queue is serial, so a
    // later YTKACEDownloadLogContents() still observes the cleared log.
    dispatch_async(YTKACEDownloadLogQueue(), ^{
        YTKACECloseDownloadLogHandle();
        [NSFileManager.defaultManager removeItemAtURL:YTKACEDownloadLogURL() error:nil];
    });
}
