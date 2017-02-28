/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import <FBDeviceControl/FBDeviceControl.h>

#import "FBDevice.h"
#import "FBDeviceControlError.h"

@interface FBDeviceXCTestCommands ()

@property (nonatomic, weak, readonly) FBDevice *device;
@property (nonatomic, strong, nullable, readonly) FBTask *task;

@end

@implementation FBDeviceXCTestCommands

+ (instancetype)commandsWithDevice:(FBDevice *)device
{
  return [[self alloc] initWithDevice:device];
}

- (instancetype)initWithDevice:(FBDevice *)device
{
  self = [super init];
  if (!self) {
    return nil;
  }
  _device = device;
  return self;
}

+ (NSDictionary<NSString *, NSDictionary<NSString *, NSObject *> *> *)xctestRunProperties:(FBTestLaunchConfiguration *)testLaunch
{
  return @{
    @"StubBundleId" : @{
      @"TestHostPath" : testLaunch.testHostPath,
      @"TestBundlePath" : testLaunch.testBundlePath,
      @"UseUITargetAppProvidedByTests" : @YES,
      @"IsUITestBundle" : @YES,
      @"CommandLineArguments": testLaunch.applicationLaunchConfiguration.arguments,
    }
  };
}

- (BOOL)startTestWithLaunchConfiguration:(FBTestLaunchConfiguration *)testLaunchConfiguration error:(NSError **)error
{
  // Return early and fail if there is already a test run for the device.
  // There should only ever be one test run per-device.
  if (self.task) {
    return [[FBDeviceControlError
      describeFormat:@"Cannot Start Test Manager with Configuration %@ as it is already running", testLaunchConfiguration]
      failBool:error];
  }

  // Create the .xctestrun file
  NSError *innerError = nil;
  NSString *filePath = [FBDeviceXCTestCommands createXCTestRunFileFromConfiguration:testLaunchConfiguration forDevice:self.device error:&innerError];
  if (!filePath) {
    return [FBDeviceControlError failBoolWithError:innerError errorOut:error];
  }

  // Find the path to xcodebuild
  NSString *xcodeBuildPath = [FBDeviceXCTestCommands xcodeBuildPathWithError:&innerError];
  if (!xcodeBuildPath) {
    return [FBDeviceControlError failBoolWithError:innerError errorOut:error];
  }

  // Create the Task and store it.
  _task = [FBDeviceXCTestCommands createTask:testLaunchConfiguration xcodeBuildPath:xcodeBuildPath testRunFilePath:filePath device:self.device];
  [self.task startAsynchronously];

  return YES;
}

- (BOOL)waitUntilAllTestRunnersHaveFinishedTestingWithTimeout:(NSTimeInterval)timeout error:(NSError **)error
{
  if (!self.task) {
    return YES;
  }
  NSError *innerError = nil;
  if (![self.task waitForCompletionWithTimeout:timeout error:&innerError]) {
    [self.task terminate];
    _task = nil;
    return [[[FBDeviceControlError
      describe:@"Failed waiting for timeout"]
      causedBy:innerError]
      failBool:error];
  }
  _task = nil;
  return YES;
}

+ (nullable NSString *)createXCTestRunFileFromConfiguration:(FBTestLaunchConfiguration *)configuration forDevice:(FBDevice *)device error:(NSError **)error
{
  NSString *tmp = NSTemporaryDirectory();
  NSString *fileName = [NSProcessInfo.processInfo.globallyUniqueString stringByAppendingPathExtension:@"xctestrun"];
  NSString *path = [tmp stringByAppendingPathComponent:fileName];

  NSDictionary *testRunProperties = [self xctestRunProperties:configuration];
  if (![testRunProperties writeToFile:path atomically:false]) {
    return [[FBDeviceControlError
      describeFormat:@"Failed to write to file %@", path]
      fail:error];
  }
  return path;
}

+ (NSString *)xcodeBuildPathWithError:(NSError **)error
{
  NSString *path = [FBControlCoreGlobalConfiguration.developerDirectory stringByAppendingPathComponent:@"/usr/bin/xcodebuild"];
  if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
    return [[FBDeviceControlError
      describeFormat:@"xcodebuild does not exist at expected path %@", path]
      fail:error];
  }
  return path;
}

+ (FBTask *)createTask:(FBTestLaunchConfiguration *)configuraton xcodeBuildPath:(NSString *)xcodeBuildPath testRunFilePath:(NSString *)testRunFilePath device:(FBDevice *)device
{

  NSArray<NSString *> *arguments = @[
    @"test-without-building",
    @"-xctestrun", testRunFilePath,
    @"-destination", [NSString stringWithFormat:@"id=%@", device.udid],
  ];

  NSDictionary<NSString *, NSString *> *env = [[NSProcessInfo processInfo] environment];

  FBTask *task = [[[[[FBTaskBuilder
    withLaunchPath:xcodeBuildPath arguments:arguments]
    withEnvironment:env]
    withStdOutToLogger:device.logger]
    withStdErrToLogger:device.logger]
    build];

  return task;
}

@end