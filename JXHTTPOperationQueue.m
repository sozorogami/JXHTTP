#import "JXHTTPOperationQueue.h"
#import "JXHTTPOperation.h"

static void * JXHTTPOperationQueueKVOContext = &JXHTTPOperationQueueKVOContext;
static NSInteger JXHTTPOperationQueueDefaultMaxOps = 4;

@interface JXHTTPOperationQueue ()
@property (retain) NSMutableDictionary *bytesReceivedPerOperation;
@property (retain) NSMutableDictionary *bytesSentPerOperation;
@property (retain) NSMutableDictionary *expectedDownloadBytesPerOperation;
@property (retain) NSMutableDictionary *expectedUploadBytesPerOperation;
@property (retain) NSString *uniqueString;
@property (retain) NSNumber *downloadProgress;
@property (retain) NSNumber *uploadProgress;
@property (retain) NSNumber *bytesDownloaded;
@property (retain) NSNumber *bytesUploaded;
@property (retain) NSNumber *expectedUploadBytes;
@property (retain) NSNumber *expectedDownloadBytes;
@property (assign) dispatch_queue_t progressMathQueue;
@end

@implementation JXHTTPOperationQueue

#pragma mark -
#pragma mark Initialization

- (void)dealloc
{
    [self removeObserver:self forKeyPath:@"operations" context:JXHTTPOperationQueueKVOContext];

    self.delegate = nil;

    [_bytesReceivedPerOperation release];
    [_bytesSentPerOperation release];
    [_expectedUploadBytesPerOperation release];
    [_expectedDownloadBytesPerOperation release];
    [_expectedDownloadBytes release];
    [_expectedUploadBytes release];
    [_bytesDownloaded release];
    [_bytesUploaded release];
    [_downloadProgress release];
    [_uploadProgress release];
    [_uniqueString release];

    [_willStartBlock release];
    [_didUploadBlock release];
    [_didDownloadBlock release];
    [_didMakeProgressBlock release];
    [_didFinishBlock release];

    dispatch_release(_progressMathQueue);

    [super dealloc];
}

- (id)init
{
    if ((self = [super init])) {
        self.maxConcurrentOperationCount = JXHTTPOperationQueueDefaultMaxOps;
        self.uniqueString = [[NSProcessInfo processInfo] globallyUniqueString];
        self.progressMathQueue = dispatch_queue_create("JXHTTPOperationQueue.progressMathQueue", DISPATCH_QUEUE_CONCURRENT);

        [self addObserver:self forKeyPath:@"operations" options:(NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld) context:JXHTTPOperationQueueKVOContext];
    }
    return self;
}

+ (id)sharedQueue
{
    static id sharedQueue;
    static dispatch_once_t predicate;

    dispatch_once(&predicate, ^{
        sharedQueue = [[self alloc] init];
    });

    return sharedQueue;
}

+ (NSOperationQueue *)sharedBlockQueue
{
    static NSOperationQueue *sharedBlockQueue;
    static dispatch_once_t predicate;

    dispatch_once(&predicate, ^{
        sharedBlockQueue = [[NSOperationQueue alloc] init];
        sharedBlockQueue.maxConcurrentOperationCount = 1;
    });

    return sharedBlockQueue;
}

#pragma mark -
#pragma mark Private Methods

- (void)performDelegateMethod:(SEL)selector
{
    __block JXHTTPQueueBlock block = [self blockForSelector:selector];

    if (!self.delegate && !block)
        return;
    
    if (self.performsDelegateMethodsOnMainThread) {
        if ([self.delegate respondsToSelector:selector])
            [self.delegate performSelectorOnMainThread:selector withObject:self waitUntilDone:YES];
    } else {
        if ([self.delegate respondsToSelector:selector])
            [self.delegate performSelector:selector onThread:[NSThread currentThread] withObject:self waitUntilDone:YES];
    }

    if (!block)
        return;

    NSOperationQueue *queue = [[self class] sharedBlockQueue];

    if (self.performsBlocksOnMainThread)
        queue = [NSOperationQueue mainQueue];

    [queue addOperationWithBlock:^{
        block(self);
    }];
}

- (JXHTTPQueueBlock)blockForSelector:(SEL)selector
{
    if (selector == @selector(httpOperationQueueWillStart:))
        return self.willStartBlock;
    if (selector == @selector(httpOperationQueueDidUpload:))
        return self.didUploadBlock;
    if (selector == @selector(httpOperationQueueDidDownload:))
        return self.didDownloadBlock;
    if (selector == @selector(httpOperationQueueDidMakeProgress:))
        return self.didMakeProgressBlock;
    if (selector == @selector(httpOperationQueueDidFinish:))
        return self.didFinishBlock;
    return nil;
}

- (void)resetProgress
{
    __block JXHTTPOperationQueue *blockSelf = self;

    dispatch_barrier_async(self.progressMathQueue, ^{
        blockSelf.bytesReceivedPerOperation = [NSMutableDictionary dictionary];
        blockSelf.bytesSentPerOperation = [NSMutableDictionary dictionary];
        blockSelf.expectedDownloadBytesPerOperation = [NSMutableDictionary dictionary];
        blockSelf.expectedUploadBytesPerOperation = [NSMutableDictionary dictionary];
        blockSelf.downloadProgress = [NSNumber numberWithFloat:0.0f];
        blockSelf.uploadProgress = [NSNumber numberWithFloat:0.0f];
        blockSelf.bytesDownloaded = [NSNumber numberWithLongLong:0LL];
        blockSelf.bytesUploaded = [NSNumber numberWithLongLong:0LL];
        blockSelf.expectedDownloadBytes = [NSNumber numberWithLongLong:0LL];
        blockSelf.expectedUploadBytes = [NSNumber numberWithLongLong:0LL];
    });
}

#pragma mark -
#pragma mark <NSKeyValueObserving>

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context != JXHTTPOperationQueueKVOContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }

    __block JXHTTPOperationQueue *blockSelf = self;

    if (object == self && [keyPath isEqualToString:@"operations"]) {
        if (![[change objectForKey:NSKeyValueChangeKindKey] intValue] == NSKeyValueChangeSetting)
            return;

        NSArray *newOperationsArray = [change objectForKey:NSKeyValueChangeNewKey];
        NSArray *oldOperationsArray = [change objectForKey:NSKeyValueChangeOldKey];
        NSUInteger newCount = [newOperationsArray count];
        NSUInteger oldCount = [oldOperationsArray count];

        NSMutableArray *insertedArray = [NSMutableArray arrayWithArray:newOperationsArray];
        NSMutableArray *removedArray = [NSMutableArray arrayWithArray:oldOperationsArray];
        [insertedArray removeObjectsInArray:oldOperationsArray];
        [removedArray removeObjectsInArray:newOperationsArray];

        if (oldCount < 1 && newCount > 0) {
            [self resetProgress];
            [self performDelegateMethod:@selector(httpOperationQueueWillStart:)];
        }

        for (JXHTTPOperation *operation in insertedArray) {
            if (![operation isKindOfClass:[JXHTTPOperation class]])
                continue;

            NSNumber *expectedUp = [NSNumber numberWithLongLong:operation.requestBody.httpContentLength];
            NSString *uniqueString = [NSString stringWithString:operation.uniqueString];

            dispatch_barrier_async(self.progressMathQueue, ^{
                [blockSelf.expectedUploadBytesPerOperation setObject:expectedUp forKey:uniqueString];
            });

            [operation addObserver:blockSelf forKeyPath:@"bytesReceived" options:0 context:JXHTTPOperationQueueKVOContext];
            [operation addObserver:blockSelf forKeyPath:@"bytesSent" options:0 context:JXHTTPOperationQueueKVOContext];
            [operation addObserver:blockSelf forKeyPath:@"response" options:0 context:JXHTTPOperationQueueKVOContext];
        }

        for (JXHTTPOperation *operation in removedArray) {
            if (![operation isKindOfClass:[JXHTTPOperation class]])
                continue;

            [operation removeObserver:blockSelf forKeyPath:@"bytesReceived" context:JXHTTPOperationQueueKVOContext];
            [operation removeObserver:blockSelf forKeyPath:@"bytesSent" context:JXHTTPOperationQueueKVOContext];
            [operation removeObserver:blockSelf forKeyPath:@"response" context:JXHTTPOperationQueueKVOContext];

            if (operation.isCancelled) {
                NSString *uniqueString = [NSString stringWithString:operation.uniqueString];

                dispatch_barrier_async(self.progressMathQueue, ^{
                    [blockSelf.bytesReceivedPerOperation removeObjectForKey:uniqueString];
                    [blockSelf.bytesSentPerOperation removeObjectForKey:uniqueString];
                });
            }
        }

        if (oldCount > 0 && newCount < 1)
            [self performDelegateMethod:@selector(httpOperationQueueDidFinish:)];

        return;
    }

    if ([keyPath isEqualToString:@"response"]) {
        JXHTTPOperation *operation = object;
        long long length = [operation.response expectedContentLength];

        if (length && length != NSURLResponseUnknownLength) {
            NSNumber *expectedDown = [NSNumber numberWithLongLong:length];
            NSString *uniqueString = [NSString stringWithString:operation.uniqueString];

            dispatch_barrier_async(self.progressMathQueue, ^{
                [blockSelf.expectedDownloadBytesPerOperation setObject:expectedDown forKey:uniqueString];
            });
        }

        return;
    }

    if ([keyPath isEqualToString:@"bytesReceived"]) {
        JXHTTPOperation *operation = (JXHTTPOperation *)object;

        long long bytesReceived = operation.bytesReceived;
        NSString *uniqueString = [NSString stringWithString:operation.uniqueString];

        dispatch_barrier_async(self.progressMathQueue, ^{
            [blockSelf.bytesReceivedPerOperation setObject:[NSNumber numberWithLongLong:bytesReceived] forKey:uniqueString];
        });

        dispatch_sync(self.progressMathQueue, ^{
            long long bytesDownloaded = 0LL;
            long long expectedDownloadBytes = 0LL;

            for (NSString *opID in [blockSelf.bytesReceivedPerOperation allKeys]) {
                bytesDownloaded += [[blockSelf.bytesReceivedPerOperation objectForKey:opID] longLongValue];
            }

            for (NSString *opID in [blockSelf.expectedDownloadBytesPerOperation allKeys]) {
                expectedDownloadBytes += [[blockSelf.expectedDownloadBytesPerOperation objectForKey:opID] longLongValue];
            }

            dispatch_barrier_async(blockSelf.progressMathQueue, ^{
                blockSelf.bytesDownloaded = [NSNumber numberWithLongLong:bytesDownloaded];
                blockSelf.expectedDownloadBytes = [NSNumber numberWithLongLong:expectedDownloadBytes];
                blockSelf.downloadProgress = [NSNumber numberWithFloat:expectedDownloadBytes ? (bytesDownloaded / (float)expectedDownloadBytes) : 0.0f];
                [blockSelf performDelegateMethod:@selector(httpOperationQueueDidUpload:)];
                [blockSelf performDelegateMethod:@selector(httpOperationQueueDidMakeProgress:)];
            });
        });

        return;
    }

    if ([keyPath isEqualToString:@"bytesSent"]) {
        JXHTTPOperation *operation = (JXHTTPOperation *)object;

        long long bytesSent = operation.bytesSent;
        NSString *uniqueString = [NSString stringWithString:operation.uniqueString];

        dispatch_barrier_async(self.progressMathQueue, ^{
            [blockSelf.bytesSentPerOperation setObject:[NSNumber numberWithLongLong:bytesSent] forKey:uniqueString];
        });

        dispatch_sync(self.progressMathQueue, ^{
            long long bytesUploaded = 0LL;
            long long expectedUploadBytes = 0LL;

            for (NSString *opID in [blockSelf.bytesSentPerOperation allKeys]) {
                bytesUploaded += [[blockSelf.bytesSentPerOperation objectForKey:opID] longLongValue];
            }

            for (NSString *opID in [blockSelf.expectedUploadBytesPerOperation allKeys]) {
                expectedUploadBytes += [[blockSelf.expectedUploadBytesPerOperation objectForKey:opID] longLongValue];
            }

            dispatch_barrier_async(blockSelf.progressMathQueue, ^{
                blockSelf.bytesUploaded = [NSNumber numberWithLongLong:bytesUploaded];
                blockSelf.expectedUploadBytes = [NSNumber numberWithLongLong:expectedUploadBytes];
                blockSelf.uploadProgress = [NSNumber numberWithFloat:expectedUploadBytes ? (bytesUploaded / (float)expectedUploadBytes) : 0.0f];
                [blockSelf performDelegateMethod:@selector(httpOperationQueueDidDownload:)];
                [blockSelf performDelegateMethod:@selector(httpOperationQueueDidMakeProgress:)];
            });
        });

        return;
    }
}

@end
