//
//  FLRecorder.h
//  RecorderLibrary
//
//  Created by Ankur Kesharwani on 7/4/15.
//  Copyright (c) 2015 SumitGera. All rights reserved.
//

#import <Foundation/Foundation.h>

@protocol FLRecorderDelegate <NSObject>

// Called when the decice is not autorized to use the camera.
-(void) deviceNotAuthorized;

// Sync UI here.
-(void) recordingContextChanged:(BOOL)isRecording;
-(void) sessionRunningAndDeviceAuthorizedContextChanged:(BOOL)isRunning;

-(void) cameraSwitched;

@end

@interface FLRecorder : NSObject


- (void)checkDeviceAuthorizationStatus;

@end
