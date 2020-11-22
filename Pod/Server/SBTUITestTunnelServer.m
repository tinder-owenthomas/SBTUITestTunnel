// SBTUITestTunnelServer.m
//
// Copyright (C) 2016 Subito.it S.r.l (www.subito.it)
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#if DEBUG
    #ifndef ENABLE_UITUNNEL
        #define ENABLE_UITUNNEL 1
    #endif
#endif

#if ENABLE_UITUNNEL

@import SBTUITestTunnelCommon;
@import GCDWebServer;
@import CoreLocation;
@import UserNotifications;

#import "SBTUITestTunnelServer.h"
#import "UITextField+DisableAutocomplete.h"
#import "SBTProxyURLProtocol.h"
#import "SBTAnyViewControllerPreviewing.h"
#import "UIViewController+SBTUITestTunnel.h"
#import "UIView+Extensions.h"
#import "CLLocationManager+Swizzles.h"
#import "UNUserNotificationCenter+Swizzles.h"

#if !defined(NS_BLOCK_ASSERTIONS)

#define BlockAssert(condition, desc, ...) \
do {\
if (!(condition)) { \
[[NSAssertionHandler currentHandler] handleFailureInFunction:NSStringFromSelector(_cmd) \
file:[NSString stringWithUTF8String:__FILE__] \
lineNumber:__LINE__ \
description:(desc), ##__VA_ARGS__]; \
}\
} while(0);

#else // NS_BLOCK_ASSERTIONS defined

#define BlockAssert(condition, desc, ...)

#endif

void repeating_dispatch_after(int64_t delay, dispatch_queue_t queue, BOOL (^block)(void))
{
    if (block() == NO) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay), dispatch_get_main_queue(), ^{
            repeating_dispatch_after(delay, queue, block);
        });
    }
}

@implementation GCDWebServerRequest (Extension)

- (NSDictionary *)parameters
{
    if ([self isKindOfClass:[GCDWebServerURLEncodedFormRequest class]]) {
        return ((GCDWebServerURLEncodedFormRequest *)self).arguments;
    } else {
        return self.query;
    }
}

@end

@interface SBTUITestTunnelServer()

@property (nonatomic, strong) GCDWebServer *server;
@property (nonatomic, strong) NSString *connectionFingerprint;
@property (nonatomic, strong) dispatch_queue_t commandDispatchQueue;
@property (nonatomic, strong) NSMutableDictionary<NSString *, void (^)(NSObject *)> *customCommands;

@property (nonatomic, strong) dispatch_semaphore_t startupCompletedSemaphore;

@property (nonatomic, strong) NSMapTable<CLLocationManager *, id<CLLocationManagerDelegate>> *coreLocationActiveManagers;
@property (nonatomic, strong) NSMutableString *coreLocationStubbedServiceStatus;
@property (nonatomic, strong) NSMutableString *notificationCenterStubbedAuthorizationStatus;

@end

@implementation SBTUITestTunnelServer

static NSTimeInterval SBTUITunneledServerDefaultTimeout = 60.0;

+ (SBTUITestTunnelServer *)sharedInstance
{
    static dispatch_once_t once;
    static SBTUITestTunnelServer *sharedInstance;
    dispatch_once(&once, ^{
        sharedInstance = [[SBTUITestTunnelServer alloc] init];
        sharedInstance.server = [[GCDWebServer alloc] init];
        sharedInstance.commandDispatchQueue = dispatch_queue_create("com.sbtuitesttunnel.queue.command", DISPATCH_QUEUE_SERIAL);
        sharedInstance.startupCompletedSemaphore = dispatch_semaphore_create(0);
        sharedInstance.coreLocationActiveManagers = NSMapTable.weakToWeakObjectsMapTable;
        sharedInstance.coreLocationStubbedServiceStatus = [NSMutableString string];
        sharedInstance.notificationCenterStubbedAuthorizationStatus = [NSMutableString string];

        [sharedInstance reset];
        
        [NSURLProtocol registerClass:[SBTProxyURLProtocol class]];
    });
    
    return sharedInstance;
}

+ (void)takeOff
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [self.sharedInstance takeOffOnce];
    });
}

- (void)takeOffOnce
{
    NSDictionary<NSString *, NSString *> *environment = [NSProcessInfo processInfo].environment;
    NSString *tunnelPort = environment[SBTUITunneledApplicationLaunchEnvironmentPortKey];
    self.connectionFingerprint = environment[SBTUITunneledApplicationLaunchEnvironmentFingerprintKey];
    
    if (!tunnelPort) {
        // Required methods missing, presumely app wasn't launched from ui test
        NSLog(@"[UITestTunnelServer] required environment parameters missing, safely landing");
        return;
    }
    
    Class requestClass = ([SBTUITunnelHTTPMethod isEqualToString:@"POST"]) ? [GCDWebServerURLEncodedFormRequest class] : [GCDWebServerRequest class];
    
    __weak typeof(self) weakSelf = self;
    [self.server addDefaultHandlerForMethod:SBTUITunnelHTTPMethod requestClass:requestClass processBlock:^GCDWebServerResponse *(GCDWebServerRequest* request) {
        __strong typeof(weakSelf)strongSelf = weakSelf;
        __block GCDWebServerDataResponse *ret;
        
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        dispatch_async(strongSelf.commandDispatchQueue, ^{
            NSString *command = [request.path stringByReplacingOccurrencesOfString:@"/" withString:@""];
            
            NSString *commandString = [command stringByAppendingString:@":"];
            SEL commandSelector = NSSelectorFromString(commandString);
            NSDictionary *response = nil;
            
            if (![strongSelf processCustomCommandIfNecessary:request returnObject:&response]) {
                if (![strongSelf respondsToSelector:commandSelector]) {
                    BlockAssert(NO, @"[UITestTunnelServer] Unhandled/unknown command! %@", command);
                }
                
                IMP imp = [strongSelf methodForSelector:commandSelector];
                
                NSLog(@"[UITestTunnelServer] Executing command '%@'", command);
                
                NSDictionary * (*func)(id, SEL, GCDWebServerRequest *) = (void *)imp;
                response = func(strongSelf, commandSelector, request);
            }
            
            ret = [GCDWebServerDataResponse responseWithJSONObject:response];
            
            dispatch_semaphore_signal(sem);
        });
        
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        return ret;
    }];
    
    [self processLaunchOptionsIfNeeded];
    
    if (![[NSProcessInfo processInfo].arguments containsObject:SBTUITunneledApplicationLaunchSignal]) {
        NSLog(@"[UITestTunnelServer] Signal launch option missing, safely landing!");
        return;
    }
    
    NSDictionary *serverOptions = [NSMutableDictionary dictionary];
    
    [serverOptions setValue:@NO forKey:GCDWebServerOption_AutomaticallySuspendInBackground];
    [serverOptions setValue:@([tunnelPort intValue]) forKey:GCDWebServerOption_Port];
    [serverOptions setValue:@(YES) forKey:GCDWebServerOption_BindToLocalhost];
    
    [GCDWebServer setLogLevel:3];
    
    NSLog(@"[SBTUITestTunnel] Starting server on port: %@", tunnelPort);
    
    NSError *serverError = nil;
    if (![self.server startWithOptions:serverOptions error:&serverError]) {
        BlockAssert(NO, @"[UITestTunnelServer] Failed to start server. %@", serverError.description);
        return;
    }
    
    if (dispatch_semaphore_wait(self.startupCompletedSemaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SBTUITunneledServerDefaultTimeout * NSEC_PER_SEC))) != 0) {
        BlockAssert(NO, @"[UITestTunnelServer] Fail waiting for launch semaphore");
        return;
    }
    
    NSLog(@"[UITestTunnelServer] Up and running!");
}

+ (void)takeOffCompleted:(BOOL)completed
{

}

- (BOOL)processCustomCommandIfNecessary:(GCDWebServerRequest *)request returnObject:(NSObject **)returnObject
{
    NSString *command = [request.path stringByReplacingOccurrencesOfString:@"/" withString:@""];
    
    if ([command isEqualToString:SBTUITunneledApplicationCommandCustom]) {
        NSString *customCommandName = request.parameters[SBTUITunnelCustomCommandKey];
        NSData *objData = [[NSData alloc] initWithBase64EncodedString:request.parameters[SBTUITunnelObjectKey] options:0];
        NSObject *inObj = [NSKeyedUnarchiver unarchiveObjectWithData:objData];
        
        NSObject *(^block)(NSObject *) = [[SBTUITestTunnelServer customCommands] objectForKey:customCommandName];
        if (block) {
            NSObject *outObject = block(inObj);
            
            NSData *data = [NSKeyedArchiver archivedDataWithRootObject:outObject];
            
            NSString *ret = data ? [data base64EncodedStringWithOptions:0] : @"";
            *returnObject = @{ SBTUITunnelResponseResultKey: ret };
            
            return YES;
        }
    }
    
    return NO;
}

/* Rememeber to always return something at the end of the command otherwise [self performSelector] will crash with an EXC_I386_GPFLT */

#pragma mark - Fingerprint Command

- (NSDictionary *)commandFingerprint:(GCDWebServerRequest *)tunnelRequest
{
    return @{ SBTUITunnelResponseResultKey: self.connectionFingerprint };
}

#pragma mark - Quit Command

- (NSDictionary *)commandQuit:(GCDWebServerRequest *)tunnelRequest
{
    exit(0);
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

#pragma mark - Stubs Commands

- (NSDictionary *)commandStubMatching:(GCDWebServerRequest *)tunnelRequest
{
    __block NSString *stubId = @"";
    SBTRequestMatch *requestMatch = nil;
    
    if ([self validStubRequest:tunnelRequest]) {
        NSData *requestMatchData = [[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelStubMatchRuleKey] options:0];
        requestMatch = [NSKeyedUnarchiver unarchiveObjectWithData:requestMatchData];
        
        NSData *responseData = [[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelStubResponseKey] options:0];
        SBTStubResponse *response = [NSKeyedUnarchiver unarchiveObjectWithData:responseData];

        stubId = [SBTProxyURLProtocol stubRequestsMatching:requestMatch stubResponse:response];
    }
    
    return @{ SBTUITunnelResponseResultKey: stubId ?: @"", SBTUITunnelResponseDebugKey: [requestMatch description] ?: @"" };
}

#pragma mark - Stub Remove Commands

- (NSDictionary *)commandStubRequestsRemove:(GCDWebServerRequest *)tunnelRequest
{
    NSData *responseData = [[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelStubMatchRuleKey] options:0];
    NSString *stubId = [NSKeyedUnarchiver unarchiveObjectWithData:responseData];
    
    NSString *ret = [SBTProxyURLProtocol stubRequestsRemoveWithId:stubId] ? @"YES" : @"NO";
    
    return @{ SBTUITunnelResponseResultKey: ret };
}

- (NSDictionary *)commandStubRequestsRemoveAll:(GCDWebServerRequest *)tunnelRequest
{
    [SBTProxyURLProtocol stubRequestsRemoveAll];
    
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

#pragma mark - Stub Retrieve Commands

- (NSDictionary *)commandStubRequestsAll:(GCDWebServerRequest *)tunnelRequest
{
    NSString *ret = nil;
    
    NSDictionary *activeStubs = [SBTProxyURLProtocol stubRequestsAll];
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:activeStubs];
    
    if (data) {
        ret = [data base64EncodedStringWithOptions:0];
    }
    
    return @{ SBTUITunnelResponseResultKey: ret ?: @"" };
}

#pragma mark - Rewrites Commands

- (NSDictionary *)commandRewriteMatching:(GCDWebServerRequest *)tunnelRequest
{
    __block NSString *rewriteId = @"";
    SBTRequestMatch *requestMatch = nil;
    
    if ([self validRewriteRequest:tunnelRequest]) {
        NSData *requestMatchData = [[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelRewriteMatchRuleKey] options:0];
        requestMatch = [NSKeyedUnarchiver unarchiveObjectWithData:requestMatchData];
        
        NSData *rewriteData = [[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelRewriteKey] options:0];
        SBTRewrite *rewrite = [NSKeyedUnarchiver unarchiveObjectWithData:rewriteData];
        
        rewriteId = [SBTProxyURLProtocol rewriteRequestsMatching:requestMatch rewrite:rewrite];
    }
    
    return @{ SBTUITunnelResponseResultKey: rewriteId ?: @"", SBTUITunnelResponseDebugKey: [requestMatch description] ?: @"" };
}

#pragma mark - Rewrite Remove Commands

- (NSDictionary *)commandRewriteRemove:(GCDWebServerRequest *)tunnelRequest
{
    NSData *responseData = [[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelRewriteMatchRuleKey] options:0];
    NSString *rewriteId = [NSKeyedUnarchiver unarchiveObjectWithData:responseData];
    
    NSString *ret = [SBTProxyURLProtocol rewriteRequestsRemoveWithId:rewriteId] ? @"YES" : @"NO";
    
    return @{ SBTUITunnelResponseResultKey: ret };
}

- (NSDictionary *)commandRewriteRemoveAll:(GCDWebServerRequest *)tunnelRequest
{
    [SBTProxyURLProtocol rewriteRequestsRemoveAll];
    
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

#pragma mark - Request Monitor Commands

- (NSDictionary *)commandMonitorMatching:(GCDWebServerRequest *)tunnelRequest
{
    NSString *reqId = @"";
    SBTRequestMatch *requestMatch = nil;
    
    if ([self validMonitorRequest:tunnelRequest]) {
        NSData *requestMatchData = [[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelProxyQueryRuleKey] options:0];
        requestMatch = [NSKeyedUnarchiver unarchiveObjectWithData:requestMatchData];
        
        reqId = [SBTProxyURLProtocol monitorRequestsMatching:requestMatch];
    }
    
    return @{ SBTUITunnelResponseResultKey: reqId ?: @"", SBTUITunnelResponseDebugKey: [requestMatch description] ?: @"" };
}

- (NSDictionary *)commandMonitorRemove:(GCDWebServerRequest *)tunnelRequest
{
    NSData *responseData = [[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelProxyQueryRuleKey] options:0];
    NSString *reqId = [NSKeyedUnarchiver unarchiveObjectWithData:responseData];
    
    NSString *ret = [SBTProxyURLProtocol monitorRequestsRemoveWithId:reqId] ? @"YES" : @"NO";
    
    return @{ SBTUITunnelResponseResultKey: ret };
}

- (NSDictionary *)commandMonitorsRemoveAll:(GCDWebServerRequest *)tunnelRequest
{
    [SBTProxyURLProtocol monitorRequestsRemoveAll];
    
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

- (NSDictionary *)commandMonitorPeek:(GCDWebServerRequest *)tunnelRequest
{
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    
    __block NSString *ret = @"";
    __block NSArray<SBTMonitoredNetworkRequest *> *requestsToPeek = @[];
    __block NSString *debugInfo = @"";
    
    void (^monitorBlock)(void) = ^{
        requestsToPeek = [SBTProxyURLProtocol monitoredRequestsAll];
        
        NSData *data = [NSKeyedArchiver archivedDataWithRootObject:requestsToPeek];
        if (data) {
            ret = [data base64EncodedStringWithOptions:0];
        }
        
        debugInfo = [NSString stringWithFormat:@"Found %ld monitored requests", (unsigned long)requestsToPeek.count];
    };
    
    if ([tunnelRequest.parameters[SBTUITunnelLocalExecutionKey] boolValue]) {
        if ([NSThread isMainThread]) {
            monitorBlock();
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{ monitorBlock(); });
        }
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            // we use main thread to synchronize access to self.monitoredRequests
            monitorBlock();
            
            dispatch_semaphore_signal(sem);
        });
        
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    }
    
    return @{ SBTUITunnelResponseResultKey: ret ?: @"", SBTUITunnelResponseDebugKey: debugInfo ?: @"" };
}

- (NSDictionary *)commandMonitorFlush:(GCDWebServerRequest *)tunnelRequest
{
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    
    __block NSString *ret = @"";
    __block NSArray<SBTMonitoredNetworkRequest *> *requestsToFlush = @[];

    void (^flushBlock)(void) = ^{
        requestsToFlush = [SBTProxyURLProtocol monitoredRequestsAll];
        [SBTProxyURLProtocol monitoredRequestsFlushAll];
        
        NSData *data = [NSKeyedArchiver archivedDataWithRootObject:requestsToFlush];
        if (data) {
            ret = [data base64EncodedStringWithOptions:0];
        }
    };
    
    if ([tunnelRequest.parameters[SBTUITunnelLocalExecutionKey] boolValue]) {
        if ([NSThread isMainThread]) {
            flushBlock();
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{ flushBlock(); });
        }
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            // we use main thread to synchronize access to self.monitoredRequests
            flushBlock();
            
            dispatch_semaphore_signal(sem);
        });
        
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    }
    
    NSString *debugInfo = [NSString stringWithFormat:@"Found %ld monitored requests", (unsigned long)requestsToFlush.count];
    return @{ SBTUITunnelResponseResultKey: ret ?: @"", SBTUITunnelResponseDebugKey: debugInfo ?: @"" };
}

#pragma mark - Request Throttle Commands

- (NSDictionary *)commandThrottleMatching:(GCDWebServerRequest *)tunnelRequest
{
    NSString *reqId = @"";
    SBTRequestMatch *requestMatch = nil;
    
    if ([self validThrottleRequest:tunnelRequest]) {
        NSData *requestMatchData = [[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelProxyQueryRuleKey] options:0];
        requestMatch = [NSKeyedUnarchiver unarchiveObjectWithData:requestMatchData];
        NSTimeInterval responseDelayTime = [tunnelRequest.parameters[SBTUITunnelProxyQueryResponseTimeKey] doubleValue];
        
        reqId = [SBTProxyURLProtocol throttleRequestsMatching:requestMatch delayResponse:responseDelayTime];
    }
    
    return @{ SBTUITunnelResponseResultKey: reqId ?: @"", SBTUITunnelResponseDebugKey: [requestMatch description] ?: @""};
}

- (NSDictionary *)commandThrottleRemove:(GCDWebServerRequest *)tunnelRequest
{
    NSData *responseData = [[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelProxyQueryRuleKey] options:0];
    NSString *reqId = [NSKeyedUnarchiver unarchiveObjectWithData:responseData];
    
    NSString *ret = [SBTProxyURLProtocol throttleRequestsRemoveWithId:reqId] ? @"YES" : @"NO";
    return @{ SBTUITunnelResponseResultKey: ret };
}

- (NSDictionary *)commandThrottlesRemoveAll:(GCDWebServerRequest *)tunnelRequest
{
    [SBTProxyURLProtocol throttleRequestsRemoveAll];
    
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

#pragma mark - Cookie Block Commands

- (NSDictionary *)commandCookiesBlockMatching:(GCDWebServerRequest *)tunnelRequest
{
    NSString *cookieBlockId = @"";
    SBTRequestMatch *requestMatch = nil;
    
    if ([self validCookieBlockRequest:tunnelRequest]) {
        NSData *requestMatchData = [[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelCookieBlockMatchRuleKey] options:0];
        requestMatch = [NSKeyedUnarchiver unarchiveObjectWithData:requestMatchData];
        
        NSInteger cookieBlockRemoveAfterCount = [tunnelRequest.parameters[SBTUITunnelCookieBlockQueryIterationsKey] integerValue];
        
        cookieBlockId = [SBTProxyURLProtocol cookieBlockRequestsMatching:requestMatch activeIterations:cookieBlockRemoveAfterCount];
    }
    
    return @{ SBTUITunnelResponseResultKey: cookieBlockId ?: @"", SBTUITunnelResponseDebugKey: [requestMatch description] ?: @"" };
}

#pragma mark - Cookie Block Remove Commands

- (NSDictionary *)commandCookiesBlockRemove:(GCDWebServerRequest *)tunnelRequest
{
    NSData *responseData = [[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelCookieBlockMatchRuleKey] options:0];
    NSString *reqId = [NSKeyedUnarchiver unarchiveObjectWithData:responseData];
    
    NSString *ret = [SBTProxyURLProtocol cookieBlockRequestsRemoveWithId:reqId] ? @"YES" : @"NO";
    return @{ SBTUITunnelResponseResultKey: ret };
}

- (NSDictionary *)commandCookiesBlockRemoveAll:(GCDWebServerRequest *)tunnelRequest
{
    [SBTProxyURLProtocol cookieBlockRequestsRemoveAll];
    
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

#pragma mark - NSUSerDefaults Commands

- (NSDictionary *)commandNSUserDefaultsSetObject:(GCDWebServerRequest *)tunnelRequest
{
    NSString *objKey = tunnelRequest.parameters[SBTUITunnelObjectKeyKey];
    NSString *suiteName = tunnelRequest.parameters[SBTUITunnelUserDefaultSuiteNameKey];
    NSData *objData = [[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelObjectKey] options:0];
    id obj = [NSKeyedUnarchiver unarchiveObjectWithData:objData];
    
    NSString *ret = @"NO";
    if (objKey) {
        NSUserDefaults *userDefault;
        if ([suiteName length] > 0) {
            userDefault = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
        } else {
            userDefault = [NSUserDefaults standardUserDefaults];
        }

        [userDefault setObject:obj forKey:objKey];
        ret = [userDefault synchronize] ? @"YES" : @"NO";
    }
    
    return @{ SBTUITunnelResponseResultKey: ret };
}

- (NSDictionary *)commandNSUserDefaultsRemoveObject:(GCDWebServerRequest *)tunnelRequest
{
    NSString *objKey = tunnelRequest.parameters[SBTUITunnelObjectKeyKey];
    NSString *suiteName = tunnelRequest.parameters[SBTUITunnelUserDefaultSuiteNameKey];
    
    NSString *ret = @"NO";
    if (objKey) {
        NSUserDefaults *userDefault;
        if ([suiteName length] > 0) {
            userDefault = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
        } else {
            userDefault = [NSUserDefaults standardUserDefaults];
        }
        
        [userDefault removeObjectForKey:objKey];
        ret = [userDefault synchronize] ? @"YES" : @"NO";
    }
    
    return @{ SBTUITunnelResponseResultKey: ret };
}

- (NSDictionary *)commandNSUserDefaultsObject:(GCDWebServerRequest *)tunnelRequest
{
    NSString *objKey = tunnelRequest.parameters[SBTUITunnelObjectKeyKey];
    NSString *suiteName = tunnelRequest.parameters[SBTUITunnelUserDefaultSuiteNameKey];
    
    NSUserDefaults *userDefault;
    if ([suiteName length] > 0) {
        userDefault = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
    } else {
        userDefault = [NSUserDefaults standardUserDefaults];
    }
    
    NSObject *obj = [userDefault objectForKey:objKey];
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:obj];
    NSString *ret = @"";
    if (data) {
        ret = [data base64EncodedStringWithOptions:0];
    }
    
    return @{ SBTUITunnelResponseResultKey: ret ?: @"" };
}

- (NSDictionary *)commandNSUserDefaultsReset:(GCDWebServerRequest *)tunnelRequest
{
    NSString *suiteName = tunnelRequest.parameters[SBTUITunnelUserDefaultSuiteNameKey];
    
    NSUserDefaults *userDefault;
    if ([suiteName length] > 0) {
        userDefault = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
    } else {
        userDefault = [NSUserDefaults standardUserDefaults];
    }
    
    [userDefault removePersistentDomainForName:[[NSBundle mainBundle] bundleIdentifier]];
    [userDefault synchronize];
    
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

#pragma mark - NSBundle

- (NSDictionary *)commandMainBundleInfoDictionary:(GCDWebServerRequest *)tunnelRequest
{
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:[[NSBundle mainBundle] infoDictionary]];
    NSString *ret = @"";
    if (data) {
        ret = [data base64EncodedStringWithOptions:0];
    }
    
    return @{ SBTUITunnelResponseResultKey: ret ?: @"" };
}

#pragma mark - Copy Commands

- (NSDictionary *)commandUpload:(GCDWebServerRequest *)tunnelRequest
{
    NSData *fileData = [[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelUploadDataKey] options:0];
    NSString *destPath = [NSKeyedUnarchiver unarchiveObjectWithData:[[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelUploadDestPathKey] options:0]];
    NSSearchPathDirectory basePath = [tunnelRequest.parameters[SBTUITunnelUploadBasePathKey] intValue];
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(basePath, NSUserDomainMask, YES);
    NSString *path = [[paths firstObject] stringByAppendingPathComponent:destPath];
    
    NSError *error = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:&error];
        
        if (error) {
            return @{ SBTUITunnelResponseResultKey: @"NO" };
        }
    }
    
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES
                                               attributes:nil error:&error];
    if (error) {
        return @{ SBTUITunnelResponseResultKey: @"NO" };
    }
    
    
    NSString *ret = [fileData writeToFile:path atomically:YES] ? @"YES" : @"NO";
    
    NSString *debugInfo = [NSString stringWithFormat:@"Writing %ld bytes to file %@", (unsigned long)fileData.length, path ?: @""];
    return @{ SBTUITunnelResponseResultKey: ret, SBTUITunnelResponseDebugKey: debugInfo };
}

- (NSDictionary *)commandDownload:(GCDWebServerRequest *)tunnelRequest
{
    NSSearchPathDirectory basePathDirectory = [tunnelRequest.parameters[SBTUITunnelDownloadBasePathKey] intValue];
    
    NSString *basePath = [NSSearchPathForDirectoriesInDomains(basePathDirectory, NSUserDomainMask, YES) firstObject];
    
    NSArray *basePathContent = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:basePath error:nil];
    
    NSString *filesToMatch = [NSKeyedUnarchiver unarchiveObjectWithData:[[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelDownloadPathKey] options:0]];
    NSPredicate *filterPredicate = [NSPredicate predicateWithFormat:@"SELF like %@", filesToMatch];
    NSArray *matchingFiles = [basePathContent filteredArrayUsingPredicate:filterPredicate];
    
    NSMutableArray *filesDataArr = [NSMutableArray array];
    for (NSString *matchingFile in matchingFiles) {
        NSData *fileData = [NSData dataWithContentsOfFile:[basePath stringByAppendingPathComponent:matchingFile]];
        
        [filesDataArr addObject:fileData];
    }
    
    NSData *filesDataArrData = [NSKeyedArchiver archivedDataWithRootObject:filesDataArr];
    
    NSString *ret = [filesDataArrData base64EncodedStringWithOptions:0];
    
    NSString *debugInfo = [NSString stringWithFormat:@"Found %ld files matching download request@", (unsigned long)matchingFiles.count];
    return @{ SBTUITunnelResponseResultKey: ret ?: @"", SBTUITunnelResponseDebugKey: debugInfo };
}

#pragma mark - Other Commands

- (NSDictionary *)commandSetUIAnimations:(GCDWebServerRequest *)tunnelRequest
{
    BOOL enableAnimations = [tunnelRequest.parameters[SBTUITunnelObjectKey] boolValue];
    
    [UIView setAnimationsEnabled:enableAnimations];
    
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

- (NSDictionary *)commandSetUIAnimationSpeed:(GCDWebServerRequest *)tunnelRequest
{
    NSAssert(![NSThread isMainThread], @"Shouldn't be on main thread");
    
    NSInteger animationSpeed = [tunnelRequest.parameters[SBTUITunnelObjectKey] integerValue];
    dispatch_sync(dispatch_get_main_queue(), ^() {
        // Replacing [UIView setAnimationsEnabled:] as per
        // https://pspdfkit.com/blog/2016/running-ui-tests-with-ludicrous-speed/
        UIApplication.sharedApplication.keyWindow.layer.speed = animationSpeed;
    });
    
    NSString *debugInfo = [NSString stringWithFormat:@"Setting animationSpeed to %ld", (long)animationSpeed];
    return @{ SBTUITunnelResponseResultKey: @"YES", SBTUITunnelResponseDebugKey: debugInfo };
}

- (NSDictionary *)commandShutDown:(GCDWebServerRequest *)tunnelRequest
{
    [self reset];
    if (self.server.isRunning) {
        [self.server stop];
    }
    
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

- (NSDictionary *)commandStartupCompleted:(GCDWebServerRequest *)tunnelRequest
{
    dispatch_semaphore_signal(self.startupCompletedSemaphore);
    
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

#pragma mark - XCUITest scroll extensions

- (BOOL)scrollElementWithIdentifier:(NSString *)elementIdentifier elementClass:(Class)elementClass toRow:(NSInteger)elementRow numberOfSections:(NSInteger (^)(UIView *))sectionsDataSource numberOfRows:(NSInteger (^)(UIView *, NSInteger))rowsDataSource scrollDelegate:(void (^)(UIView *, NSIndexPath *))scrollDelegate;
{
    NSAssert([NSThread isMainThread], @"Call this from main thread!");
    
    // Hacky way to get top-most UIViewController
    UIViewController *rootViewController = [UIApplication sharedApplication].keyWindow.rootViewController;
    while (rootViewController.presentedViewController != nil) {
        rootViewController = rootViewController.presentedViewController;
    }
    
    NSArray *allViews = [rootViewController.view allSubviews];
    for (UIView *view in [allViews reverseObjectEnumerator]) {
        if ([view isKindOfClass:elementClass]) {
            BOOL withinVisibleBounds = CGRectContainsRect( UIScreen.mainScreen.bounds, [view convertRect:view.bounds toView:nil]);
            
            if (!withinVisibleBounds) {
                continue;
            }
            
            BOOL expectedIdentifier = [view.accessibilityIdentifier isEqualToString:elementIdentifier] || [view.accessibilityLabel isEqualToString:elementIdentifier];
            if (expectedIdentifier) {
                NSInteger numberOfSections = sectionsDataSource(view);
                
                NSInteger processedRows = 0;
                NSInteger targetSection = numberOfSections - 1;
                NSInteger targetRow = rowsDataSource(view, targetSection) - 1;
                for (NSInteger section = 0; section < numberOfSections; section++) {
                    NSInteger rowsInSection = rowsDataSource(view, section);
                    if (processedRows + rowsInSection > elementRow) {
                        targetSection = section;
                        targetRow = elementRow - processedRows;
                        break;
                    }
                    
                    processedRows += rowsInSection;
                }

                NSIndexPath *targetIndexPath = [NSIndexPath indexPathForRow:targetRow inSection:targetSection];
                if (targetIndexPath.row >= 0 && targetIndexPath.section >= 0) {
                    scrollDelegate(view, targetIndexPath);
                }
                
                return YES;
            }
        }
    }
    
    return NO;
}

- (NSDictionary *)commandScrollScrollView:(GCDWebServerRequest *)tunnelRequest
{
    NSString *elementIdentifier = tunnelRequest.parameters[SBTUITunnelObjectKey];
    NSString *targetElementIdentifier = tunnelRequest.parameters[SBTUITunnelObjectValueKey];
    BOOL animated = [tunnelRequest.parameters[SBTUITunnelObjectAnimatedKey] boolValue];
    
    __block BOOL result = NO;
    
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Hacky way to get top-most UIViewController
        UIViewController *rootViewController = [UIApplication sharedApplication].keyWindow.rootViewController;
        while (rootViewController.presentedViewController != nil) {
            rootViewController = rootViewController.presentedViewController;
        }
        
        NSArray *allViews = [rootViewController.view allSubviews];
        for (UIView *view in [allViews reverseObjectEnumerator]) {
            if ([view isKindOfClass:[UIScrollView class]]) {
                BOOL withinVisibleBounds = CGRectContainsRect( UIScreen.mainScreen.bounds, [view convertRect:view.bounds toView:nil]);
                
                if (!withinVisibleBounds) {
                    continue;
                }
                
                BOOL expectedIdentifier = [view.accessibilityIdentifier isEqualToString:elementIdentifier] || [view.accessibilityLabel isEqualToString:elementIdentifier];
                if (expectedIdentifier) {
                    UIScrollView *scrollView = (UIScrollView *)view;
                    NSArray *allScrollViewViews = [view allSubviews];
                    for (UIView *scrollViewView in [allScrollViewViews reverseObjectEnumerator]) {
                        BOOL expectedTargetIdentifier = [scrollViewView.accessibilityIdentifier isEqualToString:targetElementIdentifier] || [scrollViewView.accessibilityLabel isEqualToString:targetElementIdentifier];
                        if (expectedTargetIdentifier) {
                            CGRect frameInScrollView = [scrollViewView convertRect:scrollView.bounds toView:nil];
                            CGFloat targetContentOffsetY = MAX(0.0, frameInScrollView.origin.y - view.frame.size.height / 2);
                            
                            [scrollView setContentOffset:CGPointMake(0, targetContentOffsetY) animated:animated];
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                dispatch_semaphore_signal(sem);
                            });

                            result = YES;
                            break;
                        }
                    }
                }
            }
            
            if (result) { break; }
        }
    });
    
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC))) != 0) {}
    
    NSString *debugInfo = result ? @"" : @"element not found!";
    
    return @{ SBTUITunnelResponseResultKey: result ? @"YES": @"NO", SBTUITunnelResponseDebugKey: debugInfo };
}

- (NSDictionary *)commandScrollTableView:(GCDWebServerRequest *)tunnelRequest
{
    NSString *elementIdentifier = tunnelRequest.parameters[SBTUITunnelObjectKey];
    NSInteger elementRow = [tunnelRequest.parameters[SBTUITunnelObjectValueKey] intValue];
    BOOL animated = [tunnelRequest.parameters[SBTUITunnelObjectAnimatedKey] boolValue];
    
    __block BOOL result = NO;
    
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    
    __weak typeof(self)weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        result = [weakSelf scrollElementWithIdentifier:elementIdentifier
                                      elementClass:[UITableView class]
                                             toRow:elementRow
                                  numberOfSections:^NSInteger (UIView *view) {
                                      UITableView *tableView = (UITableView *)view;
                                      if ([tableView.dataSource respondsToSelector:@selector(numberOfSectionsInTableView:)]) {
                                          return [tableView.dataSource numberOfSectionsInTableView:tableView];
                                      } else {
                                          return 1;
                                      }
                                  }
                                      numberOfRows:^NSInteger (UIView *view, NSInteger section) {
                                          UITableView *tableView = (UITableView *)view;
                                          if ([tableView.dataSource respondsToSelector:@selector(tableView:numberOfRowsInSection:)]) {
                                              return [tableView.dataSource tableView:tableView numberOfRowsInSection:section];
                                          } else {
                                              return 0;
                                          }
                                      }
                                    scrollDelegate:^void (UIView *view, NSIndexPath *indexPath) {
                                        UITableView *tableView = (UITableView *)view;
                                        
                                        [tableView scrollToRowAtIndexPath:indexPath atScrollPosition:UITableViewScrollPositionTop animated:animated];
                                        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
                                        
                                        __block int iteration = 0;
                                        repeating_dispatch_after((int64_t)(0.1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                                            if ([tableView.indexPathsForVisibleRows containsObject:indexPath] || iteration == 10) {
                                                return YES;
                                            } else {
                                                iteration++;
                                                [tableView scrollToRowAtIndexPath:indexPath atScrollPosition:UITableViewScrollPositionTop animated:animated];
                                                [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
                                                return NO;
                                            }
                                        });
                                    }];
        
        dispatch_semaphore_signal(sem);
    });
    
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC))) != 0) {}
    
    NSString *debugInfo = result ? @"" : @"element not found!";
    
    return @{ SBTUITunnelResponseResultKey: result ? @"YES": @"NO", SBTUITunnelResponseDebugKey: debugInfo };
}

- (NSDictionary *)commandScrollCollectionView:(GCDWebServerRequest *)tunnelRequest
{
    NSString *elementIdentifier = tunnelRequest.parameters[SBTUITunnelObjectKey];
    NSInteger elementRow = [tunnelRequest.parameters[SBTUITunnelObjectValueKey] intValue];
    BOOL animated = [tunnelRequest.parameters[SBTUITunnelObjectAnimatedKey] boolValue];
    
    __block BOOL result = NO;
    
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    
    __weak typeof(self)weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        result = [weakSelf scrollElementWithIdentifier:elementIdentifier
                                      elementClass:[UICollectionView class]
                                             toRow:elementRow
                                  numberOfSections:^NSInteger (UIView *view) {
                                      UICollectionView *collectionView = (UICollectionView *)view;
                                      if ([collectionView.dataSource respondsToSelector:@selector(numberOfSectionsInCollectionView:)]) {
                                          return [collectionView.dataSource numberOfSectionsInCollectionView:collectionView];
                                      } else {
                                          return 1;
                                      }
                                  }
                                      numberOfRows:^NSInteger (UIView *view, NSInteger section) {
                                          UICollectionView *collectionView = (UICollectionView *)view;
                                          if ([collectionView.dataSource respondsToSelector:@selector(collectionView:numberOfItemsInSection:)]) {
                                              return [collectionView.dataSource collectionView:collectionView numberOfItemsInSection:section];
                                          } else {
                                              return 0;
                                          }
                                      }
                                    scrollDelegate:^void (UIView *view, NSIndexPath *indexPath) {
                                        UICollectionView *collectionView = (UICollectionView *)view;
                                        
                                        [collectionView scrollToItemAtIndexPath:indexPath atScrollPosition:UICollectionViewScrollPositionTop animated:animated];
                                        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
                                        
                                        __block int iteration = 0;
                                        repeating_dispatch_after((int64_t)(0.1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                                            if ([collectionView.indexPathsForVisibleItems containsObject:indexPath] || iteration == 10) {
                                                return YES;
                                            } else {
                                                iteration++;
                                                [collectionView scrollToItemAtIndexPath:indexPath atScrollPosition:UICollectionViewScrollPositionTop animated:animated];
                                                [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
                                                return NO;
                                            }
                                        });
                                    }];
        
        dispatch_semaphore_signal(sem);
    });
    
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC))) != 0) {}
    
    NSString *debugInfo = result ? @"" : @"element not found!";
    
    return @{ SBTUITunnelResponseResultKey: result ? @"YES": @"NO", SBTUITunnelResponseDebugKey: debugInfo };
}

- (NSDictionary *)commandForceTouchPopView:(GCDWebServerRequest *)tunnelRequest
{
    NSString *elementIdentifier = tunnelRequest.parameters[SBTUITunnelObjectKey];

    __block BOOL result = NO;
    
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Hacky way to get top-most UIViewController
        UIViewController *rootViewController = [UIApplication sharedApplication].keyWindow.rootViewController;
        while (rootViewController.presentedViewController != nil) {
            rootViewController = rootViewController.presentedViewController;
        }
        
        NSArray *allViews = [rootViewController.view allSubviews];
        for (UIView *view in [allViews reverseObjectEnumerator]) {
            BOOL expectedIdentifier = [view.accessibilityIdentifier isEqualToString:elementIdentifier] || [view.accessibilityLabel isEqualToString:elementIdentifier];
            if (expectedIdentifier) {
                UIView *registeredView = [UIViewController previewingRegisteredViewForView:view];
                if (registeredView == nil) { break; }
                
                id<UIViewControllerPreviewingDelegate> sourceDelegate = [UIViewController previewingDelegateForRegisteredView:registeredView];
                if (sourceDelegate == nil) { break; }

                SBTAnyViewControllerPreviewing *context = [[SBTAnyViewControllerPreviewing alloc] initWithSourceView:registeredView delegate:sourceDelegate];
                UIViewController *viewController = [sourceDelegate previewingContext:context viewControllerForLocation:view.center];
                if (viewController == nil) { break; }
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    [sourceDelegate previewingContext:context commitViewController:viewController];
                    dispatch_semaphore_signal(sem);
                });
            }
        }
    });
    
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC))) != 0) {
        result = NO;
    }
    
    NSString *debugInfo = result ? @"" : @"element not found!";
    
    return @{ SBTUITunnelResponseResultKey: result ? @"YES": @"NO", SBTUITunnelResponseDebugKey: debugInfo };
}

#pragma mark - XCUITest CLLocation extensions

- (NSDictionary *)commandCoreLocationStubbing:(GCDWebServerRequest *)tunnelRequest
{
    BOOL stubSystemLocation = [tunnelRequest.parameters[SBTUITunnelObjectValueKey] isEqualToString:@"YES"];
    if (stubSystemLocation) {
        [CLLocationManager loadSwizzlesWithInstanceHashTable:self.coreLocationActiveManagers];
    } else {
        [CLLocationManager removeSwizzles];
    }
    
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

- (NSDictionary *)commandCoreLocationStubAuthorizationStatus:(GCDWebServerRequest *)tunnelRequest
{
    NSString *authorizationStatus = tunnelRequest.parameters[SBTUITunnelObjectValueKey];
    
    [CLLocationManager setStubbedAuthorizationStatus:authorizationStatus];
    for (CLLocationManager *locationManager in self.coreLocationActiveManagers.keyEnumerator.allObjects) {
        [locationManager.stubbedDelegate locationManager:locationManager didChangeAuthorizationStatus:authorizationStatus.intValue];
        #if __IPHONE_OS_VERSION_MAX_ALLOWED >= 140000
        if (@available(iOS 14.0, *)) {
            [locationManager.stubbedDelegate locationManagerDidChangeAuthorization:locationManager];
        }
        #endif
    }

    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

- (NSDictionary *)commandCoreLocationStubAccuracyAuthorization:(GCDWebServerRequest *)tunnelRequest API_AVAILABLE(ios(14))
{
    #if __IPHONE_OS_VERSION_MAX_ALLOWED >= 140000
        NSString *accuracyAuthorization = tunnelRequest.parameters[SBTUITunnelObjectValueKey];
        
        [CLLocationManager setStubbedAccuracyAuthorization:accuracyAuthorization];
        for (CLLocationManager *locationManager in self.coreLocationActiveManagers.keyEnumerator.allObjects) {
            [locationManager.stubbedDelegate locationManagerDidChangeAuthorization:locationManager];
        }
    #endif

    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

- (NSDictionary *)commandCoreLocationStubServiceStatus:(GCDWebServerRequest *)tunnelRequest
{
    NSString *serviceStatus = tunnelRequest.parameters[SBTUITunnelObjectValueKey];
    
    [self.coreLocationStubbedServiceStatus setString:serviceStatus];

    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

- (NSDictionary *)commandCoreLocationNotifyUpdate:(GCDWebServerRequest *)tunnelRequest
{
    NSData *locationsData = [[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelObjectKey] options:0];
    NSArray<CLLocation *> *locations = [NSKeyedUnarchiver unarchiveObjectWithData:locationsData];
    
    for (CLLocationManager *locationManager in self.coreLocationActiveManagers.keyEnumerator.allObjects) {
        [locationManager.stubbedDelegate locationManager:locationManager didUpdateLocations:locations];
    }

    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

- (NSDictionary *)commandCoreLocationNotifyFailure:(GCDWebServerRequest *)tunnelRequest
{
    NSData *paramData = [[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelObjectKey] options:0];
    NSError *error = [NSKeyedUnarchiver unarchiveObjectWithData:paramData];
    
    for (CLLocationManager *locationManager in self.coreLocationActiveManagers.keyEnumerator.allObjects) {
        [locationManager.stubbedDelegate locationManager:locationManager didFailWithError:error];
    }

    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

#pragma mark - XCUITest UNUserNotificationCenter extensions

- (NSDictionary *)commandNotificationCenterStubbing:(GCDWebServerRequest *)tunnelRequest
{
    if (@available(iOS 10.0, *)) {
        BOOL stubNotificationCenter = [tunnelRequest.parameters[SBTUITunnelObjectValueKey] isEqualToString:@"YES"];
        if (stubNotificationCenter) {
            [UNUserNotificationCenter loadSwizzlesWithAuthorizationStatus:self.notificationCenterStubbedAuthorizationStatus];
        } else {
            [UNUserNotificationCenter removeSwizzles];
        }
    }
    
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

- (NSDictionary *)commandNotificationCenterStubAuthorizationStatus:(GCDWebServerRequest *)tunnelRequest
{
    NSString *authorizationStatus = tunnelRequest.parameters[SBTUITunnelObjectValueKey];
    
    [self.notificationCenterStubbedAuthorizationStatus setString:authorizationStatus];

    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

#pragma mark - XCUITest WKWebView stubbing

- (NSDictionary *)commandWkWebViewStubbing:(GCDWebServerRequest *)tunnelRequest
{
    BOOL stubWkWebView = [tunnelRequest.parameters[SBTUITunnelObjectValueKey] isEqualToString:@"YES"];
    if (stubWkWebView) {
        [self enableUrlProtocolInWkWebview];
    } else {
        [self disableUrlProtocolInWkWebview];
    }
    
    return @{ SBTUITunnelResponseResultKey: @"YES" };
}

#pragma mark - Custom Commands

+ (NSMutableDictionary *)customCommands
{
    static NSMutableDictionary *customCommandsDict = nil;
    
    if (customCommandsDict == nil) {
        customCommandsDict = [NSMutableDictionary dictionary];
    }
    
    return customCommandsDict;
}

+ (void)registerCustomCommandNamed:(NSString *)commandName block:(NSObject *(^)(NSObject *object))block
{
    if ([self respondsToSelector:NSSelectorFromString([commandName stringByAppendingString:@":"])]) {
        NSAssert(NO, @"Command name already taken");
    }
    if ([[self customCommands] objectForKey:commandName]) {
        NSAssert(NO, @"Custom command already registered, did you forgot to unregister it?");
    }
    
    [[self customCommands] setObject:block forKey:commandName];
}

+ (void)unregisterCommandNamed:(NSString *)commandName
{
    [[self customCommands] removeObjectForKey:commandName];
}

#pragma mark - Helper Methods

- (void)processLaunchOptionsIfNeeded
{
    if ([[NSProcessInfo processInfo].arguments containsObject:SBTUITunneledApplicationLaunchOptionResetFilesystem]) {
        [self deleteAppData];
        [self commandNSUserDefaultsReset:nil];
    }
    if ([[NSProcessInfo processInfo].arguments containsObject:SBTUITunneledApplicationLaunchOptionDisableUITextFieldAutocomplete]) {
        [UITextField disableAutocompleteOnce];
    }
}

- (BOOL)validStubRequest:(GCDWebServerRequest *)tunnelRequest
{
    if (![[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelStubMatchRuleKey] options:0]) {
        NSLog(@"[UITestTunnelServer] Invalid stubRequest received!");
        
        return NO;
    }
    
    return YES;
}

- (BOOL)validRewriteRequest:(GCDWebServerRequest *)tunnelRequest
{
    if (![[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelRewriteMatchRuleKey] options:0]) {
        NSLog(@"[UITestTunnelServer] Invalid rewriteRequest received!");
        
        return NO;
    }
    
    return YES;
}

- (BOOL)validMonitorRequest:(GCDWebServerRequest *)tunnelRequest
{
    if (![[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelProxyQueryRuleKey] options:0]) {
        NSLog(@"[UITestTunnelServer] Invalid monitorRequest received!");
        
        return NO;
    }
    
    return YES;
}

- (BOOL)validThrottleRequest:(GCDWebServerRequest *)tunnelRequest
{
    if (tunnelRequest.parameters[SBTUITunnelProxyQueryResponseTimeKey] != nil && ![[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelProxyQueryRuleKey] options:0]) {
        NSLog(@"[UITestTunnelServer] Invalid throttleRequest received!");
        
        return NO;
    }
    
    return YES;
}

- (BOOL)validCookieBlockRequest:(GCDWebServerRequest *)tunnelRequest
{
    if (![[NSData alloc] initWithBase64EncodedString:tunnelRequest.parameters[SBTUITunnelCookieBlockMatchRuleKey] options:0]) {
        NSLog(@"[UITestTunnelServer] Invalid cookieBlockRequest received!");
        
        return NO;
    }
    
    return YES;
}

#pragma mark - Helper Functions

// https://gist.github.com/michalzelinka/67adfa0142767575194f
- (void)deleteAppData
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *folders = @[[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject],
                                     [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject],
                                     [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject],
                                     NSTemporaryDirectory()];
    
    NSError *error = nil;
    for (NSString *folder in folders) {
        for (NSString *file in [fm contentsOfDirectoryAtPath:folder error:&error]) {
            [fm removeItemAtPath:[folder stringByAppendingPathComponent:file] error:&error];
        }
    }
}

#pragma mark - Connectionless

+ (NSString *)performCommand:(NSString *)commandName params:(NSDictionary<NSString *, NSString *> *)params
{
    NSString *commandString = [commandName stringByAppendingString:@":"];
    SEL commandSelector = NSSelectorFromString(commandString);
    
    NSMutableDictionary *unescapedParams = [params mutableCopy];
    for (NSString *key in params) {
        unescapedParams[key] = [unescapedParams[key] stringByRemovingPercentEncoding];
    }
    unescapedParams[SBTUITunnelLocalExecutionKey] = @(YES);
    
    GCDWebServerRequest *request = [[GCDWebServerRequest alloc] initWithMethod:@"POST" url:[NSURL URLWithString:@""] headers:@{} path:commandName query:unescapedParams];
    
    NSDictionary *response = nil;
    
    if (![self.sharedInstance processCustomCommandIfNecessary:request returnObject:&response]) {
        if (![self.sharedInstance respondsToSelector:commandSelector]) {
            NSAssert(NO, @"[UITestTunnelServer] Unhandled/unknown command! %@", commandName);
        }
        
        IMP imp = [self.sharedInstance methodForSelector:commandSelector];
        
        NSLog(@"[UITestTunnelServer] Executing command '%@'", commandName);
        
        NSDictionary * (*func)(id, SEL, GCDWebServerRequest *) = (void *)imp;
        response = func(self.sharedInstance, commandSelector, request);
    }
    
    return response[SBTUITunnelResponseResultKey];
}

- (void)reset
{
    [SBTProxyURLProtocol reset];
    [[self customCommands] removeAllObjects];
}

- (void)enableUrlProtocolInWkWebview
{
    Class cls = NSClassFromString(@"WKBrowsingContextController");
    SEL sel = NSSelectorFromString(@"registerSchemeForCustomProtocol:");
    if ([cls respondsToSelector:sel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [cls performSelector:sel withObject:@"http"];
        [cls performSelector:sel withObject:@"https"];
#pragma clang diagnostic pop
    }
}

- (void)disableUrlProtocolInWkWebview
{
    Class cls = NSClassFromString(@"WKBrowsingContextController");
    SEL sel = NSSelectorFromString(@"unregisterSchemeForCustomProtocol:");
    if ([cls respondsToSelector:sel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [cls performSelector:sel withObject:@"http"];
        [cls performSelector:sel withObject:@"https"];
#pragma clang diagnostic pop
    }
}

@end

#endif
