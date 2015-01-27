//
//  MDWampClientDelegateMock.m
//  MDWamp
//
//  Created by Niko Usai on 13/12/13.
//  Copyright (c) 2013 mogui.it. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import "MDWampClientDelegateMock.h"

@implementation MDWampClientDelegateMock

- (void) mdwamp:(MDWamp *)wamp sessionEstablished:(NSDictionary *)info
{
    self.onOpenCalled = YES;
    if(self.onOpenCallback){
        self.onOpenCallback();
    }
}

- (void) mdwamp:(MDWamp *)wamp closedSession:(NSInteger)code reason:(NSString*)reason details:(NSDictionary *)details
{
    self.onCloseCalled = YES;
}

- (void) onAuthReqWithAnswer:(NSString *)answer
{
    self.onAuthReqWithAnswerCalled = YES;
}

- (void) onAuthSignWithSignature:(NSString *)signature
{
    self.onAuthSignWithSignatureCalled = YES;
}

- (void) onAuthWithAnswer:(NSString *)answer
{
    self.onAuthWithAnswerCalled = YES;
}

- (void) onAuthFailForCall:(NSString *)procCall withError:(NSString *)errorDetails
{
    self.onAuthFailForCallCalled = YES;
}
@end
