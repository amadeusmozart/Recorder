//
//  FLCaptureSession.h
//  RecorderLibrary
//
//  Created by Sumit Gera on 04/07/15.
//  Copyright (c) 2015 SumitGera. All rights reserved.
//

#import <AVFoundation/AVFoundation.h>

#define FLCaptureSessionPreset352x288 AVCaptureSessionPreset352x288
#define FLCaptureSessionPreset640x480 AVCaptureSessionPreset640x480
#define FLCaptureSessionPreset1280x720 AVCaptureSessionPreset1280x720
#define FLCaptureSessionPreset1920x1080 AVCaptureSessionPreset1920x1080

#define FLCaptureSessionRuntimeErrorNotification AVCaptureSessionRuntimeErrorNotification 


@interface FLCaptureSession : AVCaptureSession {
    NSMutableArray * videoSegments;
}

@end