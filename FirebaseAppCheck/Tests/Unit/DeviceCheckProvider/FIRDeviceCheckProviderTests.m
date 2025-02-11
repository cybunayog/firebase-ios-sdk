/*
 * Copyright 2020 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import <XCTest/XCTest.h>

#import <OCMock/OCMock.h>
#import "FBLPromise+Testing.h"

#import "FirebaseAppCheck/Sources/Core/Errors/FIRAppCheckErrorUtil.h"
#import "FirebaseAppCheck/Sources/Core/FIRAppCheckToken+Internal.h"
#import "FirebaseAppCheck/Sources/DeviceCheckProvider/API/FIRDeviceCheckAPIService.h"
#import "FirebaseAppCheck/Sources/DeviceCheckProvider/FIRDeviceCheckTokenGenerator.h"
#import "FirebaseAppCheck/Sources/Public/FirebaseAppCheck/FIRDeviceCheckProvider.h"

#import "FirebaseCore/Extension/FirebaseCoreInternal.h"

#import "SharedTestUtilities/AppCheckBackoffWrapperFake/FIRAppCheckBackoffWrapperFake.h"

#if FIR_DEVICE_CHECK_SUPPORTED_TARGETS

FIR_DEVICE_CHECK_PROVIDER_AVAILABILITY
@interface FIRDeviceCheckProvider (Tests)

- (instancetype)initWithAPIService:(id<FIRDeviceCheckAPIServiceProtocol>)APIService
              deviceTokenGenerator:(id<FIRDeviceCheckTokenGenerator>)deviceTokenGenerator
                    backoffWrapper:(id<FIRAppCheckBackoffWrapperProtocol>)backoffWrapper;

@end

FIR_DEVICE_CHECK_PROVIDER_AVAILABILITY
@interface FIRDeviceCheckProviderTests : XCTestCase

@property(nonatomic) FIRDeviceCheckProvider *provider;
@property(nonatomic) id fakeAPIService;
@property(nonatomic) id fakeTokenGenerator;
@property(nonatomic) FIRAppCheckBackoffWrapperFake *fakeBackoffWrapper;

@end

@implementation FIRDeviceCheckProviderTests

- (void)setUp {
  [super setUp];

  self.fakeAPIService = OCMProtocolMock(@protocol(FIRDeviceCheckAPIServiceProtocol));
  self.fakeTokenGenerator = OCMProtocolMock(@protocol(FIRDeviceCheckTokenGenerator));

  self.fakeBackoffWrapper = [[FIRAppCheckBackoffWrapperFake alloc] init];
  // Don't backoff by default.
  self.fakeBackoffWrapper.isNextOperationAllowed = YES;

  self.provider = [[FIRDeviceCheckProvider alloc] initWithAPIService:self.fakeAPIService
                                                deviceTokenGenerator:self.fakeTokenGenerator
                                                      backoffWrapper:self.fakeBackoffWrapper];
}

- (void)tearDown {
  self.provider = nil;
  self.fakeAPIService = nil;
  self.fakeTokenGenerator = nil;
  self.fakeBackoffWrapper = nil;
}

- (void)testInitWithValidApp {
  FIROptions *options = [[FIROptions alloc] initWithGoogleAppID:@"app_id" GCMSenderID:@"sender_id"];
  options.APIKey = @"api_key";
  options.projectID = @"project_id";
  FIRApp *app = [[FIRApp alloc] initInstanceWithName:@"testInitWithValidApp" options:options];

  XCTAssertNotNil([[FIRDeviceCheckProvider alloc] initWithApp:app]);
}

- (void)testInitWithIncompleteApp {
  FIROptions *options = [[FIROptions alloc] initWithGoogleAppID:@"app_id" GCMSenderID:@"sender_id"];

  options.projectID = @"project_id";
  FIRApp *missingAPIKeyApp = [[FIRApp alloc] initInstanceWithName:@"testInitWithValidApp"
                                                          options:options];
  XCTAssertNil([[FIRDeviceCheckProvider alloc] initWithApp:missingAPIKeyApp]);

  options.projectID = nil;
  options.APIKey = @"api_key";
  FIRApp *missingProjectIDApp = [[FIRApp alloc] initInstanceWithName:@"testInitWithValidApp"
                                                             options:options];
  XCTAssertNil([[FIRDeviceCheckProvider alloc] initWithApp:missingProjectIDApp]);
}

- (void)testGetTokenSuccess {
  // 1. Expect FIRDeviceCheckTokenGenerator.isSupported.
  OCMExpect([self.fakeTokenGenerator isSupported]).andReturn(YES);

  // 2. Expect device token to be generated.
  NSData *deviceToken = [NSData data];
  id generateTokenArg = [OCMArg invokeBlockWithArgs:deviceToken, [NSNull null], nil];
  OCMExpect([self.fakeTokenGenerator generateTokenWithCompletionHandler:generateTokenArg]);

  // 3. Expect FAA token to be requested.
  FIRAppCheckToken *validToken = [[FIRAppCheckToken alloc] initWithToken:@"valid_token"
                                                          expirationDate:[NSDate distantFuture]
                                                          receivedAtDate:[NSDate date]];
  OCMExpect([self.fakeAPIService appCheckTokenWithDeviceToken:deviceToken])
      .andReturn([FBLPromise resolvedWith:validToken]);

  // 4. Expect backoff wrapper to be used.
  self.fakeBackoffWrapper.backoffExpectation = [self expectationWithDescription:@"Backoff"];

  // 5. Call getToken and validate the result.
  XCTestExpectation *completionExpectation =
      [self expectationWithDescription:@"completionExpectation"];
  [self.provider
      getTokenWithCompletion:^(FIRAppCheckToken *_Nullable token, NSError *_Nullable error) {
        [completionExpectation fulfill];
        XCTAssertEqualObjects(token.token, validToken.token);
        XCTAssertEqualObjects(token.expirationDate, validToken.expirationDate);
        XCTAssertEqualObjects(token.receivedAtDate, validToken.receivedAtDate);
        XCTAssertNil(error);
      }];

  [self waitForExpectations:@[ self.fakeBackoffWrapper.backoffExpectation, completionExpectation ]
                    timeout:0.5
               enforceOrder:YES];

  // 6. Verify.
  XCTAssertNil(self.fakeBackoffWrapper.operationError);
  FIRAppCheckToken *wrapperResult =
      [self.fakeBackoffWrapper.operationResult isKindOfClass:[FIRAppCheckToken class]]
          ? self.fakeBackoffWrapper.operationResult
          : nil;
  XCTAssertEqualObjects(wrapperResult.token, validToken.token);

  OCMVerifyAll(self.fakeAPIService);
  OCMVerifyAll(self.fakeTokenGenerator);
}

- (void)testGetTokenWhenDeviceCheckIsNotSupported {
  NSError *expectedError =
      [FIRAppCheckErrorUtil unsupportedAttestationProvider:@"DeviceCheckProvider"];

  // 0.1. Expect backoff wrapper to be used.
  self.fakeBackoffWrapper.backoffExpectation = [self expectationWithDescription:@"Backoff"];

  // 0.2. Expect default error handler to be used.
  XCTestExpectation *errorHandlerExpectation = [self expectationWithDescription:@"Error handler"];
  self.fakeBackoffWrapper.defaultErrorHandler = ^FIRAppCheckBackoffType(NSError *_Nonnull error) {
    XCTAssertEqualObjects(error, expectedError);
    [errorHandlerExpectation fulfill];
    return FIRAppCheckBackoffType1Day;
  };

  // 1. Expect FIRDeviceCheckTokenGenerator.isSupported.
  OCMExpect([self.fakeTokenGenerator isSupported]).andReturn(NO);

  // 2. Don't expect DeviceCheck token to be generated or FAA token to be requested.
  OCMReject([self.fakeTokenGenerator generateTokenWithCompletionHandler:OCMOCK_ANY]);
  OCMReject([self.fakeAPIService appCheckTokenWithDeviceToken:OCMOCK_ANY]);

  // 3. Call getToken and validate the result.
  XCTestExpectation *completionExpectation =
      [self expectationWithDescription:@"completionExpectation"];
  [self.provider
      getTokenWithCompletion:^(FIRAppCheckToken *_Nullable token, NSError *_Nullable error) {
        [completionExpectation fulfill];
        XCTAssertNil(token);
        XCTAssertEqualObjects(error, expectedError);
      }];

  [self waitForExpectations:@[
    self.fakeBackoffWrapper.backoffExpectation, errorHandlerExpectation, completionExpectation
  ]
                    timeout:0.5
               enforceOrder:YES];

  // 4. Verify.
  OCMVerifyAll(self.fakeAPIService);
  OCMVerifyAll(self.fakeTokenGenerator);

  XCTAssertEqualObjects(self.fakeBackoffWrapper.operationError, expectedError);
  XCTAssertNil(self.fakeBackoffWrapper.operationResult);
}

- (void)testGetTokenWhenDeviceTokenFails {
  NSError *deviceTokenError = [NSError errorWithDomain:@"FIRDeviceCheckProviderTests"
                                                  code:-1
                                              userInfo:nil];

  // 0.1. Expect backoff wrapper to be used.
  self.fakeBackoffWrapper.backoffExpectation = [self expectationWithDescription:@"Backoff"];

  // 0.2. Expect default error handler to be used.
  XCTestExpectation *errorHandlerExpectation = [self expectationWithDescription:@"Error handler"];
  self.fakeBackoffWrapper.defaultErrorHandler = ^FIRAppCheckBackoffType(NSError *_Nonnull error) {
    XCTAssertEqualObjects(error, deviceTokenError);
    [errorHandlerExpectation fulfill];
    return FIRAppCheckBackoffType1Day;
  };

  // 1. Expect FIRDeviceCheckTokenGenerator.isSupported.
  OCMExpect([self.fakeTokenGenerator isSupported]).andReturn(YES);

  // 2. Expect device token to be generated.
  id generateTokenArg = [OCMArg invokeBlockWithArgs:[NSNull null], deviceTokenError, nil];
  OCMExpect([self.fakeTokenGenerator generateTokenWithCompletionHandler:generateTokenArg]);

  // 3. Don't expect FAA token to be requested.
  OCMReject([self.fakeAPIService appCheckTokenWithDeviceToken:[OCMArg any]]);

  // 4. Call getToken and validate the result.
  XCTestExpectation *completionExpectation =
      [self expectationWithDescription:@"completionExpectation"];
  [self.provider
      getTokenWithCompletion:^(FIRAppCheckToken *_Nullable token, NSError *_Nullable error) {
        [completionExpectation fulfill];
        XCTAssertNil(token);
        XCTAssertEqualObjects(error, deviceTokenError);
      }];

  [self waitForExpectations:@[
    self.fakeBackoffWrapper.backoffExpectation, errorHandlerExpectation, completionExpectation
  ]
                    timeout:0.5
               enforceOrder:YES];

  // 5. Verify.
  OCMVerifyAll(self.fakeAPIService);
  OCMVerifyAll(self.fakeTokenGenerator);

  XCTAssertEqualObjects(self.fakeBackoffWrapper.operationError, deviceTokenError);
  XCTAssertNil(self.fakeBackoffWrapper.operationResult);
}

- (void)testGetTokenWhenAPIServiceFails {
  NSError *APIServiceError = [NSError errorWithDomain:@"FIRDeviceCheckProviderTests"
                                                 code:-1
                                             userInfo:nil];

  // 0.1. Expect backoff wrapper to be used.
  self.fakeBackoffWrapper.backoffExpectation = [self expectationWithDescription:@"Backoff"];

  // 0.2. Expect default error handler to be used.
  XCTestExpectation *errorHandlerExpectation = [self expectationWithDescription:@"Error handler"];
  self.fakeBackoffWrapper.defaultErrorHandler = ^FIRAppCheckBackoffType(NSError *_Nonnull error) {
    XCTAssertEqualObjects(error, APIServiceError);
    [errorHandlerExpectation fulfill];
    return FIRAppCheckBackoffType1Day;
  };

  // 1. Expect FIRDeviceCheckTokenGenerator.isSupported.
  OCMExpect([self.fakeTokenGenerator isSupported]).andReturn(YES);

  // 2. Expect device token to be generated.
  NSData *deviceToken = [NSData data];
  id generateTokenArg = [OCMArg invokeBlockWithArgs:deviceToken, [NSNull null], nil];
  OCMExpect([self.fakeTokenGenerator generateTokenWithCompletionHandler:generateTokenArg]);

  // 3. Expect FAA token to be requested.
  FBLPromise *rejectedPromise = [FBLPromise pendingPromise];
  [rejectedPromise reject:APIServiceError];
  OCMExpect([self.fakeAPIService appCheckTokenWithDeviceToken:deviceToken])
      .andReturn(rejectedPromise);

  // 4. Call getToken and validate the result.
  XCTestExpectation *completionExpectation =
      [self expectationWithDescription:@"completionExpectation"];
  [self.provider
      getTokenWithCompletion:^(FIRAppCheckToken *_Nullable token, NSError *_Nullable error) {
        [completionExpectation fulfill];
        XCTAssertNil(token);
        XCTAssertEqualObjects(error, APIServiceError);
      }];

  [self waitForExpectations:@[
    self.fakeBackoffWrapper.backoffExpectation, errorHandlerExpectation, completionExpectation
  ]
                    timeout:0.5
               enforceOrder:YES];

  // 5. Verify.
  OCMVerifyAll(self.fakeAPIService);
  OCMVerifyAll(self.fakeTokenGenerator);

  XCTAssertEqualObjects(self.fakeBackoffWrapper.operationError, APIServiceError);
  XCTAssertNil(self.fakeBackoffWrapper.operationResult);
}

#pragma mark - Backoff tests

- (void)testGetTokenBackoff {
  // 1. Configure backoff.
  self.fakeBackoffWrapper.isNextOperationAllowed = NO;
  self.fakeBackoffWrapper.backoffExpectation = [self expectationWithDescription:@"Backoff"];

  // 2. Don't expect any operations.
  OCMReject([self.fakeAPIService appCheckTokenWithDeviceToken:[OCMArg any]]);
  OCMReject([self.fakeTokenGenerator generateTokenWithCompletionHandler:OCMOCK_ANY]);

  // 3. Call getToken and validate the result.
  XCTestExpectation *completionExpectation =
      [self expectationWithDescription:@"completionExpectation"];
  [self.provider
      getTokenWithCompletion:^(FIRAppCheckToken *_Nullable token, NSError *_Nullable error) {
        [completionExpectation fulfill];
        XCTAssertNil(token);
        XCTAssertEqualObjects(error, self.fakeBackoffWrapper.backoffError);
      }];

  [self waitForExpectations:@[ self.fakeBackoffWrapper.backoffExpectation, completionExpectation ]
                    timeout:0.5
               enforceOrder:YES];

  // 4. Verify.
  OCMVerifyAll(self.fakeAPIService);
  OCMVerifyAll(self.fakeTokenGenerator);
}

@end

#endif  // FIR_DEVICE_CHECK_SUPPORTED_TARGETS
