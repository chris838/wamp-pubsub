//
//  MPMessagePackRPClient.m
//  MPMessagePack
//
//  Created by Gabriel on 12/12/14.
//  Copyright (c) 2014 Gabriel Handford. All rights reserved.
//

#import "MPMessagePackClient.h"

#import "MPMessagePack.h"
#include <sys/socket.h>
#include <sys/un.h>

@interface MPMessagePackClient ()
@property NSString *name;
@property MPMessagePackOptions options;

@property (nonatomic) MPMessagePackClientStatus status;
@property NSInputStream *inputStream;
@property NSOutputStream *outputStream;

@property NSMutableArray *queue;
@property NSUInteger writeIndex;

@property NSMutableDictionary *requests;

@property NSMutableData *readBuffer;
@property NSUInteger messageId;

@property (copy) MPCompletion openCompletion;

@property CFSocketRef socket;
@property CFSocketNativeHandle nativeSocket; // For native local socket
@end

@implementation MPMessagePackClient

- (instancetype)init {
  return [self initWithName:@"" options:0];
}

- (instancetype)initWithName:(NSString *)name options:(MPMessagePackOptions)options {
  if ((self = [super init])) {
    _name = name;
    _options = options;
    _queue = [NSMutableArray array];
    _readBuffer = [NSMutableData data];
    _requests = [NSMutableDictionary dictionary];
  }
  return self;
}

- (void)setInputStream:(NSInputStream *)inputStream outputStream:(NSOutputStream *)outputStream {
  _inputStream = inputStream;
  _outputStream = outputStream;
  _inputStream.delegate = self;
  _outputStream.delegate = self;
  [_inputStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
  [_outputStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
  //MPDebug(@"[%@] Opening streams", _name);
  self.status = MPMessagePackClientStatusOpening;
  [_inputStream open];
  [_outputStream open];
}

- (void)openWithHost:(NSString *)host port:(UInt32)port completion:(MPCompletion)completion {
  if (_status == MPMessagePackClientStatusOpen || _status == MPMessagePackClientStatusOpening) {
    MPErr(@"[%@] Already open", _name);
    completion(nil); // TODO: Maybe something better to do here
    return;
  }
  CFReadStreamRef readStream;
  CFWriteStreamRef writeStream;
  CFStreamCreatePairWithSocketToHost(NULL, (__bridge CFStringRef)host, port, &readStream, &writeStream);
  _openCompletion = completion;
  [self setInputStream:(__bridge NSInputStream *)(readStream) outputStream:(__bridge NSOutputStream *)(writeStream)];
}

- (void)close {
  if (_openCompletion) {
    MPErr(@"We had an open completion block set");
    _openCompletion = nil;
  }
  
  [_inputStream close];
  [_inputStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
  _inputStream = nil;
  [_outputStream close];
  [_outputStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
  _outputStream = nil;
  
  if (_socket) {
    CFSocketInvalidate(_socket);
    _socket = NULL;
  }
  
  if (_nativeSocket) {
    close(_nativeSocket);
    _nativeSocket = 0;
  }
  
  self.status = MPMessagePackClientStatusClosed;
}

- (void)sendRequestWithMethod:(NSString *)method params:(NSArray *)params completion:(MPRequestCompletion)completion {
  NSNumber *messageId = @(++_messageId);
  params = [self encodeObject:params];
  NSArray *request = @[@(0), messageId, method, params ? params : NSNull.null];
  _requests[messageId] = completion;
  //MPDebug(@"Send: %@", [request componentsJoinedByString:@", "]);
  [self writeObject:request];
}

- (id)encodeObject:(id)object {
  if (!object) return nil;
  if (_coder) {
    if ([object isKindOfClass:NSArray.class]) {
      NSMutableArray *encoded = [NSMutableArray array];
      for (id obj in (NSArray *)object) {
        [encoded addObject:[self encodeObject:obj]];
      }
      object = encoded;
    } else if ([object isKindOfClass:NSDictionary.class]) {
      NSMutableDictionary *encoded = [NSMutableDictionary dictionary];
      for (id key in (NSDictionary *)object) {
        id value = ((NSDictionary *)object)[key];
        encoded[key] = [self encodeObject:value];
      }
      object = encoded;
    } else {
      object = [_coder encodeObject:object];
    }
  }
  return object;
}

- (void)sendResponseWithResult:(id)result error:(id)error messageId:(NSInteger)messageId {
  if ([error isKindOfClass:NSError.class]) {
    NSError *responseError = error;
    error = @{@"code": @(responseError.code), @"desc": responseError.localizedDescription};
  }

  result = [self encodeObject:result];

  NSArray *response = @[@(1), @(messageId), error ? error : NSNull.null, result ? result : NSNull.null];
  [self writeObject:response];
}

- (void)writeObject:(id)object {
  NSError *error = nil;

  //MPDebug(@"Sending message: %@", object);
  NSData *data = [MPMessagePackWriter writeObject:object options:0 error:&error];
  NSAssert(!error, @"Unable to serialize object: %@", error);

  if (_options & MPMessagePackOptionsFramed) {
    //MPDebug(@"[%@] Writing frame size: %@", _name, @(data.length));
    NSData *frameSize = [MPMessagePackWriter writeObject:@(data.length) options:0 error:&error];
    NSAssert(frameSize, @"Error packing frame size: %@", error);
    [_queue addObject:frameSize];
  }
  NSAssert(data.length > 0, @"Data was empty");
  [_queue addObject:data];
  [self checkQueue];
}

- (void)checkQueue {
  //MPDebug(@"[%@] Checking write; hasSpaceAvailable:%d, queue.count:%d, writeIndex:%d", _name, (int)[_outputStream hasSpaceAvailable], (int)_queue.count, (int)_writeIndex);
  
  while (YES) {
    if (![_outputStream hasSpaceAvailable]) break;
    
    NSMutableData *data = [_queue firstObject];
    if (!data) break;
    
    // TODO: Buffer size
    NSUInteger length = (((data.length - _writeIndex) >= 1024) ? 1024 : (data.length - _writeIndex));
    if (length == 0) break;
    
    uint8_t buffer[length];
    //MPDebug(@"Write(%@): %@", @(length), [data base64EncodedStringWithOptions:0]); // [data mp_hexString]);
    [data getBytes:buffer length:length];
    NSInteger bytesLength = [_outputStream write:(const uint8_t *)buffer maxLength:length];
    //MPDebug(@"[%@] Wrote %d", _name, (int)bytesLength);
    _writeIndex += bytesLength;
    
    if (_writeIndex == data.length) {
      [_queue removeObjectAtIndex:0];
      _writeIndex = 0;
    }
  }
}

- (void)readInputStream {
  if (![_inputStream hasBytesAvailable]) return;
  
  // TODO: Buffer size
  uint8_t buffer[4096];
  NSInteger length = [_inputStream read:buffer maxLength:4096];
  if (length > 0) {
    //MPDebug(@"[%@] Bytes: (%@)", _name, @(length));
    [_readBuffer appendBytes:buffer length:length];
    [self checkReadBuffer];
  }
}

- (void)checkReadBuffer {
  //MPDebug(@"[%@] Checking read buffer: %d", _name, (int)_readBuffer.length);
  if (_readBuffer.length == 0) return;
  
  MPMessagePackReader *reader = [[MPMessagePackReader alloc] initWithData:_readBuffer]; // TODO: Fix init every check
  
  if (_options & MPMessagePackOptionsFramed) {
    NSError *error = nil;
    NSNumber *frameSize = [reader readObject:&error];
    //MPDebug(@"[%@] Read frame size: %@", _name, frameSize);
    if (error) {
      [self handleError:error fatal:YES];
      return;
    }
    if (!frameSize) return;
    if (![frameSize isKindOfClass:NSNumber.class]) {
      [self handleError:MPMakeError(502, @"[%@] Expected number for frame size. You need to have framing on for both sides?", _name) fatal:YES];
      return;
    }
    if (_readBuffer.length < (frameSize.unsignedIntegerValue + reader.index)) {
      //MPDebug(@"Not enough data for response in frame: %d < %d", (int)_readBuffer.length, (int)(frameSize.unsignedIntegerValue + reader.index));
      return;
    }

    // To debug the message
    //NSData *data = [_readBuffer subdataWithRange:NSMakeRange(reader.index, frameSize.unsignedIntegerValue)];
    //MPDebug(@"Data: %@", [data base64EncodedStringWithOptions:0]);
  }

  NSError *error = nil;
  id<NSObject> obj = [reader readObject:&error];
  if (error) {
    [self handleError:error fatal:YES];
    return;
  }
  if (!obj) return;
  if (![obj isKindOfClass:NSArray.class] || [(NSArray *)obj count] != 4) {
    [self handleError:MPMakeError(500, @"[%@] Received an invalid response: %@ (%@)", _name, obj, NSStringFromClass([obj class])) fatal:YES];
    return;
  }
  
  NSArray *message = (NSArray *)obj;
  //MPDebug(@"Read message: %@", [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:message options:NSJSONWritingPrettyPrinted error:nil] encoding:NSUTF8StringEncoding]);

  NSInteger type = [message[0] integerValue];
  NSNumber *messageId = message[1];
  
  if (type == 0) {
    //MPDebug(@"Request, messageId=%@", messageId);
    NSString *method = MPIfNull(message[2], nil);
    NSArray *params = MPIfNull(message[3], nil);
    NSAssert(self.requestHandler, @"No request handler");
    self.requestHandler(method, params, ^(NSError *error, id result) {
      //MPDebug(@"Sending response, messageId=%@", messageId);
      [self sendResponseWithResult:result error:error messageId:messageId.integerValue];
    });
  } else if (type == 1) {
    NSDictionary *responseError = MPIfNull(message[2], nil);
    NSError *error = nil;
    if (responseError) {
      NSInteger code = [responseError[@"code"] integerValue];
      if (code != 0) error = MPMakeError(code, @"%@", responseError[@"desc"]);
    }
    
    id result = MPIfNull(message[3], nil);
    MPRequestCompletion completion = _requests[messageId];
    if (!completion) {
      MPErr(@"No completion block for request: %@", messageId);
      [self handleError:MPMakeError(501, @"[%@] Got response for unknown request", _name) fatal:NO];
    } else {
      [_requests removeObjectForKey:messageId];
      completion(error, result);
    }
  } else if (type == 2) {
    NSString *method = MPIfNull(message[1], nil);
    NSArray *params = MPIfNull(message[2], nil);
    [self.delegate client:self didReceiveNotificationWithMethod:method params:params];
  }
  
  _readBuffer = [[_readBuffer subdataWithRange:NSMakeRange(reader.index, _readBuffer.length - reader.index)] mutableCopy]; // TODO: Fix mutable copy (this might actually no-op tho)
  [self checkReadBuffer];
}

- (void)setStatus:(MPMessagePackClientStatus)status {
  if (_status != status) {
    _status = status;
    [self.delegate client:self didChangeStatus:_status];
  }
}

- (void)handleError:(NSError *)error fatal:(BOOL)fatal {
  MPErr(@"[%@] Error: %@", _name, error);
  [self.delegate client:self didError:error fatal:fatal];
  if (fatal) {
    [self close];
  }
}

NSString *MPNSStringFromNSStreamEvent(NSStreamEvent e) {
  NSMutableString *str = [[NSMutableString alloc] init];
  if (e & NSStreamEventOpenCompleted) [str appendString:@"NSStreamEventOpenCompleted"];
  if (e & NSStreamEventHasBytesAvailable) [str appendString:@"NSStreamEventHasBytesAvailable"];
  if (e & NSStreamEventHasSpaceAvailable) [str appendString:@"NSStreamEventHasSpaceAvailable"];
  if (e & NSStreamEventErrorOccurred) [str appendString:@"NSStreamEventErrorOccurred"];
  if (e & NSStreamEventEndEncountered) [str appendString:@"NSStreamEventEndEncountered"];
  return str;
}

- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)event {
  //MPDebug(@"[%@] Stream event: %@ (%@)", _name, MPNSStringFromNSStreamEvent(event), NSStringFromClass(stream.class));
  switch (event) {
    case NSStreamEventNone:
      break;
      
    case NSStreamEventOpenCompleted: {
      if ([stream isKindOfClass:NSOutputStream.class]) {
        if (_status != MPMessagePackClientStatusOpening) {
          MPErr(@"[%@] Status wasn't opening and we got an open completed event", _name);
        }
        self.status = MPMessagePackClientStatusOpen;
        if (self.openCompletion) {
          self.openCompletion(nil);
          self.openCompletion = nil;
        }
      }
      break;
    }
    case NSStreamEventHasSpaceAvailable: {
      [self checkQueue];
      break;
    }
    case NSStreamEventHasBytesAvailable: {
      if (stream == _inputStream) {
        [self readInputStream];
      }
      break;
    }
    case NSStreamEventErrorOccurred: {
      MPErr(@"[%@] Stream error", _name);
      if (self.openCompletion) {
        self.openCompletion(stream.streamError);
        self.openCompletion = nil;
      } else {
        [self handleError:stream.streamError fatal:YES];
      }
      break;
    }
    case NSStreamEventEndEncountered: {
//      NSData *data = [_inputStream propertyForKey:NSStreamDataWrittenToMemoryStreamKey];
//      if (!data) {
//        MPErr(@"[%@] No data from end event", _name);
//      } else {
//        [_readBuffer appendData:data];
//        [self checkReadBuffer];
//      }
      //MPDebug(@"[%@] Stream end", _name);
      [self close];
      break;
    }
  }
}

#pragma mark Unix Socket

- (BOOL)openWithSocket:(NSString *)socketName completion:(MPCompletion)completion {
  CFSocketContext context = {0, (__bridge void *)self, nil, nil, nil};
  CFSocketCallBackType types = kCFSocketConnectCallBack;
  CFSocketNativeHandle sock = socket(AF_UNIX, SOCK_STREAM, 0);
  _socket = CFSocketCreateWithNative(nil, sock, types, MPSocketClientCallback, &context);
  if (!_socket) {
    completion(MPMakeError(-5, @"Couldn't create native socket to: %@", socketName));
    return NO;
  }

  struct sockaddr_un sun;
  sun.sun_len = sizeof(struct sockaddr_un);
  sun.sun_family = AF_UNIX;
  strcpy(&sun.sun_path[0], [socketName UTF8String]);
  NSData *address = [NSData dataWithBytes:&sun length:sizeof(sun)];
  
  if (CFSocketConnectToAddress(_socket, (__bridge CFDataRef)address, (CFTimeInterval)-1) != kCFSocketSuccess) {
    completion(MPMakeError(-5, @"Couldn't open socket: %@", socketName));
    return NO; 
  }
  
  _openCompletion = completion;
  CFRunLoopSourceRef sourceRef = CFSocketCreateRunLoopSource(kCFAllocatorDefault, _socket, 0);
  CFRunLoopAddSource(CFRunLoopGetCurrent(), sourceRef, kCFRunLoopCommonModes);
  CFRelease(sourceRef);
  
  return YES;
}

static void MPSocketClientCallback(CFSocketRef socket, CFSocketCallBackType type, CFDataRef address, const void *data, void *info) {
  MPMessagePackClient *client = (__bridge MPMessagePackClient *)info;
  //MPDebug(@"Callback: %d", (int)type);
  switch (type) {
    case kCFSocketConnectCallBack:
      //if (data) {
      [client connectSocketStreams];
      break;
    default:
      break;
  }
}

- (void)connectSocketStreams {
  //MPDebug(@"Connecting streams");
  _nativeSocket = CFSocketGetNative(_socket);
  
  //
  // From CocoaAsyncSocket
  //
  
  // Setup the CFSocket so that invalidating it will not close the underlying native socket
  CFSocketSetSocketFlags(_socket, 0);
  
  // Invalidate and release the CFSocket - All we need from here on out is the nativeSocket.
  // Note: If we don't invalidate the CFSocket (leaving the native socket open)
  // then readStream and writeStream won't function properly.
  // Specifically, their callbacks won't work, with the exception of kCFStreamEventOpenCompleted.
  //
  // This is likely due to the mixture of the CFSocketCreateWithNative method,
  // along with the CFStreamCreatePairWithSocket method.
  // The documentation for CFSocketCreateWithNative states:
  //
  //   If a CFSocket object already exists for sock,
  //   the function returns the pre-existing object instead of creating a new object;
  //   the context, callout, and callBackTypes parameters are ignored in this case.
  //
  // So the CFStreamCreateWithNative method invokes the CFSocketCreateWithNative method,
  // thinking that is creating a new underlying CFSocket for it's own purposes.
  // When it does this, it uses the context/callout/callbackTypes parameters to setup everything appropriately.
  // However, if a CFSocket already exists for the native socket,
  // then it is returned (as per the documentation), which in turn screws up the CFStreams.
  
  CFSocketInvalidate(_socket);
  CFRelease(_socket);
  _socket = NULL;
  
  CFReadStreamRef readStream = NULL;
  CFWriteStreamRef writeStream = NULL;
  CFStreamCreatePairWithSocket(kCFAllocatorDefault, _nativeSocket, &readStream, &writeStream);
  if (readStream && writeStream) {
    CFReadStreamSetProperty(readStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
    CFWriteStreamSetProperty(writeStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
    [self setInputStream:(__bridge NSInputStream *)readStream outputStream:(__bridge NSOutputStream *)writeStream];
  } else {
    close(_nativeSocket);
  }
  if (readStream) {
    CFRelease(readStream);
    readStream = nil;
  }
  if (writeStream) {
    CFRelease(writeStream);
    writeStream = nil;
  }
}

@end
