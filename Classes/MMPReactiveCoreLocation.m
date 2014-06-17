//
//  MMPReactiveCoreLocation.m
//
//  The MIT License (MIT)
//  Copyright (c) 2014 Mamad Purbo, purbo.org
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

#import "MMPReactiveCoreLocation.h"
#import <ReactiveCocoa/RACEXTScope.h>

#ifdef DEBUG
#   define MMPRxCL_LOG(fmt, ...) NSLog((@"%s [Line %d] " fmt), __PRETTY_FUNCTION__, __LINE__, ##__VA_ARGS__);
#else
#   define MMPRxCL_LOG(...)
#endif

NSString * const MMPRCLSignalErrorDomain = @"MMPRCLSignalErrorDomain";
const NSInteger MMPRCLSignalErrorServiceUnavailable = 1;

enum {
    MMPRCLBeaconRegionSignalTypeStartMonitoring,
    MMPRCLBeaconRegionSignalTypeDidEnter,
    MMPRCLBeaconRegionSignalTypeDidExit
};
typedef NSInteger MMPRCLBeaconRegionSignalType;

/**
 *  Delegate for custom location request.
 */
@interface MMPSignalDelegate : NSObject<CLLocationManagerDelegate>

@property(nonatomic, weak) id<RACSubscriber>subscriber, startMonitoringForRegionSubscriber, didEnterRegionSubscriber, didExitRegionSubscriber;
@property(assign, nonatomic) NSTimeInterval locationAgeLimit;
@property(assign, nonatomic) BOOL signalOnce;

- (instancetype)initWithSubscriber:(id<RACSubscriber>)subscriber
                  locationAgeLimit:(NSTimeInterval)locationAgeLimit
                        signalOnce:(BOOL)signalOnce;

- (instancetype)initWithStartMotitoringSubscriber:(id<RACSubscriber>)subscriber
                  locationAgeLimit:(NSTimeInterval)locationAgeLimit
                        signalOnce:(BOOL)signalOnce;

- (instancetype)initWithDidEnterRegionSubscriber:(id<RACSubscriber>)subscriber
                  locationAgeLimit:(NSTimeInterval)locationAgeLimit
                        signalOnce:(BOOL)signalOnce;

- (instancetype)initWithDidExitRegionSubscriber:(id<RACSubscriber>)subscriber
                  locationAgeLimit:(NSTimeInterval)locationAgeLimit
                        signalOnce:(BOOL)signalOnce;

@end

@interface MMPReactiveCoreLocation()<CLLocationManagerDelegate>

@property(nonatomic, strong) CLLocationManager *defaultLocationManager;
@property(nonatomic, strong) RACSubject *defaultLocationManagerDelegateSubject;
@property(assign, nonatomic) MMPRCLLocationUpdateType lastUsedlocationUpdateType;
@property(nonatomic, strong, readwrite) CLLocation *lastKnownLocation;

@property(nonatomic, strong) NSMutableArray *singleSignalDelegates;

@end

@implementation MMPReactiveCoreLocation

+ (instancetype)instance
{
    static dispatch_once_t once;
    static id shared = nil;
    dispatch_once(&once, ^{
        shared = [[super alloc] initSingletonInstance];
    });
    return shared;
}

- (instancetype)initSingletonInstance
{
    if (self = [super init]) {
        // default values (same as the default values for CLLocationManager)
        _pausesLocationUpdatesAutomatically = YES;
        _distanceFilter = kCLDistanceFilterNone;
        _desiredAccuracy = kCLLocationAccuracyBest;
        _activityType = CLActivityTypeOther;
        _locationUpdateType = MMPRCLLocationUpdateTypeStandard;
        _locationAgeLimit = MMPRCL_LOCATION_AGE_LIMIT_DEFAULT;
        _defaultTimeout = MMPRCL_LOCATION_TIMEOUT_DEFAULT;
        
        _lastKnownLocation = nil;
        _defaultLocationManager = [[CLLocationManager alloc] init];
        _defaultLocationManager.delegate = self;
        
        self.singleSignalDelegates = [NSMutableArray array];
    }
    return self;
}

- (BOOL)locationServicesAvailable
{
    return
        [CLLocationManager locationServicesEnabled] &&
        [CLLocationManager authorizationStatus] != kCLAuthorizationStatusDenied &&
        [CLLocationManager authorizationStatus] != kCLAuthorizationStatusRestricted;
}

- (void)sendUnavailableError
{
    @synchronized(self) {
        if (_defaultLocationManagerDelegateSubject) {
            [_defaultLocationManagerDelegateSubject sendError:[NSError errorWithDomain:MMPRCLSignalErrorDomain
                                                                                  code:MMPRCLSignalErrorServiceUnavailable
                                                                              userInfo:nil]];
            _defaultLocationManagerDelegateSubject = nil;
        }
    }
}

- (void)start
{
    // start only if location service available
    if (![self locationServicesAvailable]) {
        [self sendUnavailableError];
    }
    
    _defaultLocationManager.pausesLocationUpdatesAutomatically = _pausesLocationUpdatesAutomatically;
    _defaultLocationManager.distanceFilter = _distanceFilter;
    _defaultLocationManager.desiredAccuracy = _desiredAccuracy;
    _defaultLocationManager.activityType = _activityType;
    
    // not thread-safe, should start/stop be thread safe?
    
    _lastUsedlocationUpdateType = _locationUpdateType;
    if (_locationUpdateType == MMPRCLLocationUpdateTypeStandard) {
        [_defaultLocationManager startUpdatingLocation];
    } else if (_locationUpdateType == MMPRCLLocationUpdateTypeSignificantChange) {
        [_defaultLocationManager startMonitoringSignificantLocationChanges];
    } else {
        NSLog(@"[WARN] Unknown location update type: %ld, not doing anything.", (long)_locationUpdateType);
    }
}

- (void)stop
{
    // if subject has been used before, complete the subject first.
    @synchronized(self) {
        if (_defaultLocationManagerDelegateSubject) {
            [_defaultLocationManagerDelegateSubject sendCompleted];
            _defaultLocationManagerDelegateSubject = nil;
        }
    }
    
    if (_lastUsedlocationUpdateType == MMPRCLLocationUpdateTypeStandard) {
        [_defaultLocationManager stopUpdatingLocation];
    } else if (_locationUpdateType == MMPRCLLocationUpdateTypeSignificantChange) {
        [_defaultLocationManager stopMonitoringSignificantLocationChanges];
    }
}

- (RACSubject *)defaultLocationManagerDelegateSubject
{
    @synchronized(self) {
        if (!_defaultLocationManagerDelegateSubject) {
            _defaultLocationManagerDelegateSubject = [RACSubject subject];
        }
    }
    return _defaultLocationManagerDelegateSubject;
}

#pragma mark Standard location signals

- (RACSignal *)locationSignal
{
    return [self defaultLocationManagerDelegateSubject];
}

- (RACSignal *)locationSignalWithAccuracy:(CLLocationAccuracy)desiredAccuracy
{
    return [[self defaultLocationManagerDelegateSubject] filter:^BOOL(CLLocation *location) {
        return (location.horizontalAccuracy <= desiredAccuracy);
    }];
}

- (RACSignal *)locationSignalWithAccuracy:(CLLocationAccuracy)desiredAccuracy timeout:(NSTimeInterval)timeout
{
    return [[[self defaultLocationManagerDelegateSubject]
                   takeUntilBlock:^BOOL(CLLocation *location) {
                       return (location.horizontalAccuracy <= desiredAccuracy);
                   }]
                   timeout:timeout onScheduler:[RACScheduler scheduler]];
}

#pragma mark Common custom location signal

- (RACSignal *)customLocationSignalWithPausesLocationUpdatesAutomatically:(BOOL)pausesLocationUpdatesAutomatically
                                                           distanceFilter:(CLLocationDistance)distanceFilter
                                                          desiredAccuracy:(CLLocationAccuracy)desiredAccuracy
                                                             activityType:(CLActivityType)activityType
                                                       locationUpdateType:(MMPRCLLocationUpdateType)locationUpdateType
                                                         locationAgeLimit:(NSTimeInterval)locationAgeLimit
                                                                  timeout:(NSTimeInterval)timeout
                                                               signalOnce:(BOOL)signalOnce
{
    @weakify(self)
    
    RACSignal *signal = [RACSignal createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
        
        @strongify(self)
        
        CLLocationManager *locationManager = [[CLLocationManager alloc] init];
        MMPSignalDelegate *delegate = [[MMPSignalDelegate alloc] initWithSubscriber:subscriber
                                                                   locationAgeLimit:locationAgeLimit
                                                                         signalOnce:signalOnce];
        // so that the delegate can be retained
        [self.singleSignalDelegates addObject:delegate];
        
        locationManager.pausesLocationUpdatesAutomatically = pausesLocationUpdatesAutomatically;
        locationManager.distanceFilter = distanceFilter;
        locationManager.desiredAccuracy = desiredAccuracy;
        locationManager.activityType = activityType;
        locationManager.delegate = delegate;
        
        if (locationUpdateType == MMPRCLLocationUpdateTypeStandard) {
            [locationManager startUpdatingLocation];
        } else if (locationUpdateType == MMPRCLLocationUpdateTypeSignificantChange) {
            [locationManager startMonitoringSignificantLocationChanges];
        } else {
            NSLog(@"[WARN] Unknown location update type: %ld, not doing anything.", (long)locationUpdateType);
        }
        
        MMPRxCL_LOG(@"custom CL manager started")
        
        return [RACDisposable disposableWithBlock:^{
            if (locationUpdateType == MMPRCLLocationUpdateTypeStandard) {
                [locationManager stopUpdatingLocation];
            } else if (locationUpdateType == MMPRCLLocationUpdateTypeSignificantChange) {
                [locationManager stopMonitoringSignificantLocationChanges];
            } else {
                NSLog(@"[WARN] Unknown location update type: %ld, not doing anything.", (long)locationUpdateType);
            }
            
            locationManager.delegate = nil; // fix delegate leak bug
            
            [self.singleSignalDelegates removeObject:delegate];
            
            MMPRxCL_LOG(@"custom CL manager stopped, number of delegates = %d", [self.singleSignalDelegates count])
        }];
    }];
    
    if (timeout > 0) {
        return [signal timeout:timeout onScheduler:[RACScheduler scheduler]];
    } else {
        return signal;
    }
}

#pragma mark iBeacon location signal
- (RACSignal *)iBeaconLocationSignalWithBeaconRegions:(NSArray *)beaconRegions
             pausesLocationUpdatesAutomatically:(BOOL)pausesLocationUpdatesAutomatically
                                 distanceFilter:(CLLocationDistance)distanceFilter
                                desiredAccuracy:(CLLocationAccuracy)desiredAccuracy
                                   activityType:(CLActivityType)activityType
                             locationUpdateType:(MMPRCLLocationUpdateType)locationUpdateType
                               locationAgeLimit:(NSTimeInterval)locationAgeLimit
                                        timeout:(NSTimeInterval)timeout
                                     signalOnce:(BOOL)signalOnce
                         beaconRegionSignalType:(MMPRCLBeaconRegionSignalType)signalType
{
    @weakify(self)
    
    RACSignal *signal = [RACSignal createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
        
        @strongify(self)
        
        CLLocationManager *locationManager = [[CLLocationManager alloc] init];
        MMPSignalDelegate *delegate = nil;
        if (signalType == MMPRCLBeaconRegionSignalTypeStartMonitoring) {
            delegate = [[MMPSignalDelegate alloc] initWithStartMotitoringSubscriber:subscriber
                                                                   locationAgeLimit:locationAgeLimit
                                                                         signalOnce:signalOnce];
        } else if (signalType == MMPRCLBeaconRegionSignalTypeDidEnter) {
            delegate = [[MMPSignalDelegate alloc] initWithDidEnterRegionSubscriber:subscriber
                                                                   locationAgeLimit:locationAgeLimit
                                                                         signalOnce:signalOnce];
        } else if (signalType == MMPRCLBeaconRegionSignalTypeDidExit) {
            delegate = [[MMPSignalDelegate alloc] initWithDidExitRegionSubscriber:subscriber
                                                                   locationAgeLimit:locationAgeLimit
                                                                         signalOnce:signalOnce];
        } else {
            NSLog(@"[WARN] invalid signal type");
        }
        
        // so that the delegate can be retained
        [self.singleSignalDelegates addObject:delegate];
        
//        locationManager.pausesLocationUpdatesAutomatically = pausesLocationUpdatesAutomatically;
//        locationManager.distanceFilter = distanceFilter;
//        locationManager.desiredAccuracy = desiredAccuracy;
//        locationManager.activityType = activityType;
        locationManager.delegate = delegate;
        
        if (beaconRegions.count > 0) {
            [self stopMonitoringRegions];
        }
        
        [beaconRegions enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
            CLBeaconRegion *beaconRegion = (CLBeaconRegion *)obj;
            if ([beaconRegion isKindOfClass:[CLBeaconRegion class]]) {
                [locationManager startMonitoringForRegion:beaconRegion];
            } else {
                NSLog(@"[WARN] non CLBeaconRegion type : %@, cannot start monitor", beaconRegion);
            }
        }];
        
        MMPRxCL_LOG(@"iBeacon CL manager started")
        
        return [RACDisposable disposableWithBlock:^{
            [beaconRegions enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
                CLBeaconRegion *beaconRegion = (CLBeaconRegion *)obj;
                if ([beaconRegion isKindOfClass:[CLBeaconRegion class]]) {
                    [locationManager stopMonitoringForRegion:beaconRegion];
                } else {
                    NSLog(@"[WARN] non CLBeaconRegion type : %@, cannot stop monitor", beaconRegion);
                }
            }];
            
            locationManager.delegate = nil; // fix delegate leak bug
            
            [self.singleSignalDelegates removeObject:delegate];
            
            MMPRxCL_LOG(@"iBeacon CL manager stopped, number of delegates = %d", [self.singleSignalDelegates count])
        }];
    }];
    
    if (timeout > 0) {
        return [signal timeout:timeout onScheduler:[RACScheduler scheduler]];
    } else {
        return signal;
    }
}

- (void)stopMonitoringRegions
{
    CLLocationManager *locationManager = [[CLLocationManager alloc] init];
    NSSet *regionsToStopMonitoring = [locationManager.monitoredRegions copy];
    
    [regionsToStopMonitoring enumerateObjectsUsingBlock:^(id obj, BOOL *stop) {
        [locationManager stopMonitoringForRegion:obj];
    }];
}

#pragma mark One-time location signals

- (RACSignal *)singleLocationSignal
{
    return [self singleLocationSignalWithPausesLocationUpdatesAutomatically:_pausesLocationUpdatesAutomatically
                                                             distanceFilter:_distanceFilter
                                                            desiredAccuracy:_desiredAccuracy
                                                               activityType:_activityType
                                                         locationUpdateType:MMPRCLLocationUpdateTypeStandard
                                                           locationAgeLimit:_locationAgeLimit
                                                                    timeout:self.defaultTimeout];
}

- (RACSignal *)singleLocationSignalWithAccuracy:(CLLocationAccuracy)desiredAccuracy
{
    return [self singleLocationSignalWithPausesLocationUpdatesAutomatically:_pausesLocationUpdatesAutomatically
                                                             distanceFilter:_distanceFilter
                                                            desiredAccuracy:desiredAccuracy
                                                               activityType:_activityType
                                                         locationUpdateType:MMPRCLLocationUpdateTypeStandard
                                                           locationAgeLimit:_locationAgeLimit
                                                                    timeout:self.defaultTimeout];
}

- (RACSignal *)singleLocationSignalWithAccuracy:(CLLocationAccuracy)desiredAccuracy timeout:(NSTimeInterval)timeout
{
    return [self singleLocationSignalWithPausesLocationUpdatesAutomatically:_pausesLocationUpdatesAutomatically
                                                             distanceFilter:_distanceFilter
                                                            desiredAccuracy:desiredAccuracy
                                                               activityType:_activityType
                                                         locationUpdateType:MMPRCLLocationUpdateTypeStandard
                                                           locationAgeLimit:_locationAgeLimit
                                                                    timeout:timeout];
}

- (RACSignal *)singleLocationSignalWithPausesLocationUpdatesAutomatically:(BOOL)pausesLocationUpdatesAutomatically
                                                           distanceFilter:(CLLocationDistance)distanceFilter
                                                          desiredAccuracy:(CLLocationAccuracy)desiredAccuracy
                                                             activityType:(CLActivityType)activityType
                                                       locationUpdateType:(MMPRCLLocationUpdateType)locationUpdateType
                                                         locationAgeLimit:(NSTimeInterval)locationAgeLimit
                                                                  timeout:(NSTimeInterval)timeout
{
    return [self customLocationSignalWithPausesLocationUpdatesAutomatically:pausesLocationUpdatesAutomatically
                                                             distanceFilter:distanceFilter
                                                            desiredAccuracy:desiredAccuracy
                                                               activityType:activityType
                                                         locationUpdateType:locationUpdateType
                                                           locationAgeLimit:locationAgeLimit
                                                                    timeout:timeout
                                                                 signalOnce:YES];
}

#pragma mark Automatic location signals

- (RACSignal *)autoLocationSignalWithLocationUpdateType:(MMPRCLLocationUpdateType)locationUpdateType
{
    return [self autoLocationSignalWithPausesLocationUpdatesAutomatically:_pausesLocationUpdatesAutomatically
                                                           distanceFilter:_distanceFilter
                                                          desiredAccuracy:_desiredAccuracy
                                                             activityType:_activityType
                                                       locationUpdateType:locationUpdateType
                                                         locationAgeLimit:_locationAgeLimit];
}

- (RACSignal *)autoLocationSignalWithAccuracy:(CLLocationAccuracy)desiredAccuracy
                           locationUpdateType:(MMPRCLLocationUpdateType)locationUpdateType;
{
    return [self autoLocationSignalWithPausesLocationUpdatesAutomatically:_pausesLocationUpdatesAutomatically
                                                           distanceFilter:_distanceFilter
                                                          desiredAccuracy:desiredAccuracy
                                                             activityType:_activityType
                                                       locationUpdateType:locationUpdateType
                                                         locationAgeLimit:_locationAgeLimit];
}

- (RACSignal *)autoLocationSignalWithPausesLocationUpdatesAutomatically:(BOOL)pausesLocationUpdatesAutomatically
                                                         distanceFilter:(CLLocationDistance)distanceFilter
                                                        desiredAccuracy:(CLLocationAccuracy)desiredAccuracy
                                                           activityType:(CLActivityType)activityType
                                                     locationUpdateType:(MMPRCLLocationUpdateType)locationUpdateType
                                                       locationAgeLimit:(NSTimeInterval)locationAgeLimit
{
    return [self customLocationSignalWithPausesLocationUpdatesAutomatically:pausesLocationUpdatesAutomatically
                                                             distanceFilter:distanceFilter
                                                            desiredAccuracy:desiredAccuracy
                                                               activityType:activityType
                                                         locationUpdateType:locationUpdateType
                                                           locationAgeLimit:locationAgeLimit
                                                                    timeout:MMPRCL_LOCATION_TIMEOUT_DEFAULT
                                                                 signalOnce:NO];
}

#pragma mark Beacon region signals

- (RACSignal *)beaconRegionSignalWithStartMonitoringBeaconRegions:(NSArray *)beaconRegionsArray
{
    return [self iBeaconLocationSignalWithBeaconRegions:beaconRegionsArray
                     pausesLocationUpdatesAutomatically:_pausesLocationUpdatesAutomatically
                                         distanceFilter:_distanceFilter
                                        desiredAccuracy:_desiredAccuracy
                                           activityType:_activityType
                                     locationUpdateType:_locationUpdateType
                                       locationAgeLimit:_locationAgeLimit
                                                timeout:MMPRCL_LOCATION_TIMEOUT_DEFAULT
                                             signalOnce:NO
                                beaconRegionSignalType:MMPRCLBeaconRegionSignalTypeStartMonitoring];
}

- (RACSignal *)didEnterBeaconRegionSignal
{
    return [self iBeaconLocationSignalWithBeaconRegions:@[]
                     pausesLocationUpdatesAutomatically:_pausesLocationUpdatesAutomatically
                                         distanceFilter:_distanceFilter
                                        desiredAccuracy:_desiredAccuracy
                                           activityType:_activityType
                                     locationUpdateType:_locationUpdateType
                                       locationAgeLimit:_locationAgeLimit
                                                timeout:MMPRCL_LOCATION_TIMEOUT_DEFAULT
                                             signalOnce:NO
                                 beaconRegionSignalType:MMPRCLBeaconRegionSignalTypeDidEnter];
}

- (RACSignal *)didExitBeaconRegionSignal
{
    return [self iBeaconLocationSignalWithBeaconRegions:@[]
                     pausesLocationUpdatesAutomatically:_pausesLocationUpdatesAutomatically
                                         distanceFilter:_distanceFilter
                                        desiredAccuracy:_desiredAccuracy
                                           activityType:_activityType
                                     locationUpdateType:_locationUpdateType
                                       locationAgeLimit:_locationAgeLimit
                                                timeout:MMPRCL_LOCATION_TIMEOUT_DEFAULT
                                             signalOnce:NO
                                 beaconRegionSignalType:MMPRCLBeaconRegionSignalTypeDidExit];
}

#pragma mark CLLocationManagerDelegate implementation

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray *)locations
{
    // get latest location
    if (![locations count]) return;
    CLLocation *newLocation = [locations lastObject];
    
    // test the age of the location measurement to determine if the measurement is cached
    // in most cases you will not want to rely on cached measurements
    NSTimeInterval locationAge = -[newLocation.timestamp timeIntervalSinceNow];
    if (locationAge > _locationAgeLimit) return;
    
    // test that the horizontal accuracy does not indicate an invalid measurement
    if (newLocation.horizontalAccuracy < 0) return;
    
    self.lastKnownLocation = [newLocation copy];
    //MMPRxCL_LOG(@"default CL manager updated: (%f, %f, %f)", _lastKnownLocation.coordinate.latitude, _lastKnownLocation.coordinate.longitude, _lastKnownLocation.horizontalAccuracy)
    
    // send to default subject
    [[self defaultLocationManagerDelegateSubject] sendNext:[newLocation copy]];
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error
{
    // kCLErrorLocationUnknown: location is currently unknown, but CL will keep trying
    if (error.code != kCLErrorLocationUnknown) {
        MMPRxCL_LOG(@"default CL manager failed, error.code: %ld", (long)error.code)
        @synchronized(self) {
            if (_defaultLocationManagerDelegateSubject) {
                [_defaultLocationManagerDelegateSubject sendError:error];
                _defaultLocationManagerDelegateSubject = nil;
            }
        }
    }
}

- (void)locationManager:(CLLocationManager *)manager didChangeAuthorizationStatus:(CLAuthorizationStatus)status
{
    if (status == kCLAuthorizationStatusDenied || status == kCLAuthorizationStatusRestricted) {
        [self sendUnavailableError];
    }
}

@end

@implementation MMPSignalDelegate

- (instancetype)initWithSubscriber:(id<RACSubscriber>)subscriber
                  locationAgeLimit:(NSTimeInterval)locationAgeLimit
                        signalOnce:(BOOL)signalOnce
{
    if (self = [super init]) {
        self.subscriber = subscriber;
        self.locationAgeLimit = locationAgeLimit;
        self.signalOnce = signalOnce;
    }
    return self;
}

- (instancetype)initWithStartMotitoringSubscriber:(id<RACSubscriber>)subscriber
                                 locationAgeLimit:(NSTimeInterval)locationAgeLimit
                                       signalOnce:(BOOL)signalOnce
{
    if (self = [super init]) {
        self.startMonitoringForRegionSubscriber = subscriber;
        self.locationAgeLimit = locationAgeLimit;
        self.signalOnce = signalOnce;
    }
    return self;
}

- (instancetype)initWithDidEnterRegionSubscriber:(id<RACSubscriber>)subscriber
                                locationAgeLimit:(NSTimeInterval)locationAgeLimit
                                      signalOnce:(BOOL)signalOnce
{
    if (self = [super init]) {
        self.didEnterRegionSubscriber = subscriber;
        self.locationAgeLimit = locationAgeLimit;
        self.signalOnce = signalOnce;
    }
    return self;
}

- (instancetype)initWithDidExitRegionSubscriber:(id<RACSubscriber>)subscriber
                                locationAgeLimit:(NSTimeInterval)locationAgeLimit
                                      signalOnce:(BOOL)signalOnce
{
    if (self = [super init]) {
        self.didExitRegionSubscriber = subscriber;
        self.locationAgeLimit = locationAgeLimit;
        self.signalOnce = signalOnce;
    }
    return self;
}

#pragma mark CLLocationManagerDelegate implementation

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray *)locations
{
    // get latest location
    if (![locations count]) return;
    CLLocation *newLocation = [locations lastObject];
    
    // test the age of the location measurement to determine if the measurement is cached
    // in most cases you will not want to rely on cached measurements
    NSTimeInterval locationAge = -[newLocation.timestamp timeIntervalSinceNow];
    if (locationAge > _locationAgeLimit) return;
    
    // test that the horizontal accuracy does not indicate an invalid measurement
    if (newLocation.horizontalAccuracy < 0) return;
    
    MMPRxCL_LOG(@"custom CL manager updated: (%f, %f, %f)", newLocation.coordinate.latitude, newLocation.coordinate.longitude, newLocation.horizontalAccuracy)
    
    [_subscriber sendNext:[newLocation copy]];
    
    if (_signalOnce) {
        // subscriber only wants one signal
        [_subscriber sendCompleted];
    }
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error
{
    if (error.code != kCLErrorLocationUnknown) {
        [_subscriber sendError:[NSError errorWithDomain:MMPRCLSignalErrorDomain
                                                   code:MMPRCLSignalErrorServiceUnavailable
                                               userInfo:nil]];
    }
}

- (void)locationManager:(CLLocationManager *)manager didChangeAuthorizationStatus:(CLAuthorizationStatus)status
{
    if (status == kCLAuthorizationStatusDenied || status == kCLAuthorizationStatusRestricted) {
        [_subscriber sendError:[NSError errorWithDomain:MMPRCLSignalErrorDomain
                                                   code:MMPRCLSignalErrorServiceUnavailable
                                               userInfo:nil]];
    }
}

- (void)locationManager:(CLLocationManager *)manager didStartMonitoringForRegion:(CLRegion *)region
{
    [_startMonitoringForRegionSubscriber sendNext:[region copy]];
    
    if (_signalOnce) {
        [_startMonitoringForRegionSubscriber sendCompleted];
    }
}

- (void)locationManager:(CLLocationManager *)manager didEnterRegion:(CLRegion *)region
{
    [_didEnterRegionSubscriber sendNext:[region copy]];
    
    if (_signalOnce) {
        [_didEnterRegionSubscriber sendCompleted];
    }
}

- (void)locationManager:(CLLocationManager *)manager didExitRegion:(CLRegion *)region
{
    [_didExitRegionSubscriber sendNext:[region copy]];
    
    if (_signalOnce) {
        [_didExitRegionSubscriber sendCompleted];
    }
}

- (void)locationManager:(CLLocationManager *)manager didDetermineState:(CLRegionState)state forRegion:(CLRegion *)region
{
    if(state == CLRegionStateInside)
    {
        [_didEnterRegionSubscriber sendNext:[region copy]];
        
        if (_signalOnce) {
            [_didEnterRegionSubscriber sendCompleted];
        }
    }
    else if(state == CLRegionStateOutside)
    {
        [_didExitRegionSubscriber sendNext:[region copy]];
        
        if (_signalOnce) {
            [_didExitRegionSubscriber sendCompleted];
        }
    }
    else
    {
        return;
    }

}

@end
