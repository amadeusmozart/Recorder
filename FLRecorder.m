//
//  FLRecorder.m
//  RecorderLibrary
//
//  Created by Ankur Kesharwani on 7/4/15.
//  Copyright (c) 2015 SumitGera. All rights reserved.
//

#import "FLRecorder.h"
#import <AssetsLibrary/AssetsLibrary.h>
#import "FLPreviewView.h"
#import <AVFoundation/AVFoundation.h>
#import "FLCaptureSession.h"


static void * RecordingContext = &RecordingContext;
static void * SessionRunningAndDeviceAuthorizedContext = &SessionRunningAndDeviceAuthorizedContext;

@interface FLRecorder () <AVCaptureFileOutputRecordingDelegate, AVCaptureVideoDataOutputSampleBufferDelegate> {
    
    AVCaptureInput * flCaptureInput;
    AVCaptureOutput * flCaptureOutput;
    AVCaptureDevice * flCaptureDevice;
    
    NSMutableArray * segments;
}

@property (nonatomic, weak) id<FLRecorderDelegate> delegate;

@property (nonatomic, weak) FLPreviewView * previewView;

// Session management.
@property (nonatomic) dispatch_queue_t sessionQueue; // Communicate with the session and other session objects on this queue.
@property (nonatomic) dispatch_queue_t callbackQueue; // All Calback will be sent on this queue;

@property (nonatomic) AVCaptureDeviceInput *videoDeviceInput;
@property (nonatomic) AVCaptureMovieFileOutput *movieFileOutput;
@property (nonatomic) FLCaptureSession * flCaptureSession;

// Utilities.
@property (nonatomic) UIBackgroundTaskIdentifier backgroundRecordingID;
@property (nonatomic, getter = isDeviceAuthorized) BOOL deviceAuthorized;
@property (nonatomic) id runtimeErrorHandlingObserver;
@property (nonatomic) BOOL lockInterfaceRotation;

@end

@implementation FLRecorder

-(void)initializeWithPreviewView:(FLPreviewView*)previewView andDelegate:(id)delegate {
    
    // Create the FLCaptureSession
    FLCaptureSession *session = [[FLCaptureSession alloc] init];
    [self setFlCaptureSession:session];
    
    // Setup the preview view
    [self setPreviewView:previewView];
    [[self previewView] setSession:session];
    
    // Check for device authorization
    [self checkDeviceAuthorizationStatus];
    
    // In general it is not safe to mutate an FLCaptureSession or any of its inputs, outputs, or connections from multiple threads at the same time.
    // Why not do all of this on the main queue?
    // -[FLCaptureSession startRunning] is a blocking call which can take a long time. We dispatch session setup to the sessionQueue so that the main queue isn't blocked (which keeps the UI responsive).
    dispatch_queue_t sessionQueue = dispatch_queue_create("session queue", DISPATCH_QUEUE_SERIAL);
    [self setSessionQueue:sessionQueue];
    
    dispatch_async(sessionQueue, ^{
        [self setBackgroundRecordingID:UIBackgroundTaskInvalid];
        
        NSError *error = nil;
        
        AVCaptureDevice *videoDevice = [self deviceWithMediaType:AVMediaTypeVideo preferringPosition:AVCaptureDevicePositionFront];
        AVCaptureDeviceInput *videoDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:&error];
        
        if (error){
            NSLog(@"%@", error);
        }
        
        if ([session canAddInput:videoDeviceInput]){
            [session addInput:videoDeviceInput];
            [self setVideoDeviceInput:videoDeviceInput];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                // Why are we dispatching this to the main queue?
                // Because AVCaptureVideoPreviewLayer is the backing layer for AVCamPreviewView and UIView can only be manipulated on main thread.
                // Note: As an exception to the above rule, it is not necessary to serialize video orientation changes on the AVCaptureVideoPreviewLayer’s connection with other session manipulation.
                
                [[(AVCaptureVideoPreviewLayer *)[[self previewView] layer] connection] setVideoOrientation:AVCaptureVideoOrientationPortrait];
            });
        }
        
        AVCaptureDevice *audioDevice = [[AVCaptureDevice devicesWithMediaType:AVMediaTypeAudio] firstObject];
        AVCaptureDeviceInput *audioDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:audioDevice error:&error];
        
        if (error){
            NSLog(@"%@", error);
        }
        
        if ([session canAddInput:audioDeviceInput]){
            [session addInput:audioDeviceInput];
        }
        
        AVCaptureMovieFileOutput *movieFileOutput = [[AVCaptureMovieFileOutput alloc] init];
        if ([session canAddOutput:movieFileOutput]){
            [session addOutput:movieFileOutput];
            AVCaptureConnection *connection = [movieFileOutput connectionWithMediaType:AVMediaTypeVideo];
            
            // Showing warning as the method is deprecated in 8.0
            if ([connection isVideoStabilizationSupported])
                [connection setEnablesVideoStabilizationWhenAvailable:YES];
            [self setMovieFileOutput:movieFileOutput];
        }
    });
}

- (void)startSession
{
    dispatch_async([self sessionQueue], ^{
        [self addObserver:self forKeyPath:@"sessionRunningAndDeviceAuthorized" options:(NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew) context:SessionRunningAndDeviceAuthorizedContext];
        [self addObserver:self forKeyPath:@"movieFileOutput.recording" options:(NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew) context:RecordingContext];

        __weak FLRecorder *weakSelf = self;
        [self setRuntimeErrorHandlingObserver:[[NSNotificationCenter defaultCenter] addObserverForName:FLCaptureSessionRuntimeErrorNotification object:[self flCaptureSession] queue:nil usingBlock:^(NSNotification *note) {
            FLRecorder *strongSelf = weakSelf;
            dispatch_async([strongSelf sessionQueue], ^{
                // Manually restarting the session since it must have been stopped due to an error.
                [[strongSelf flCaptureSession] startRunning];
            });
        }]];
        [[self flCaptureSession] startRunning];
    });
}

- (void)stopSession
{
    dispatch_async([self sessionQueue], ^{
        [[self flCaptureSession] stopRunning];
        
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVCaptureDeviceSubjectAreaDidChangeNotification object:[[self videoDeviceInput] device]];
        [[NSNotificationCenter defaultCenter] removeObserver:[self runtimeErrorHandlingObserver]];
        
        [self removeObserver:self forKeyPath:@"sessionRunningAndDeviceAuthorized" context:SessionRunningAndDeviceAuthorizedContext];
        [self removeObserver:self forKeyPath:@"movieFileOutput.recording" context:RecordingContext];
    });
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context == RecordingContext)
    {
        BOOL isRecording = [change[NSKeyValueChangeNewKey] boolValue];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if([self.delegate respondsToSelector:@selector(recordingContextChanged:)]){
                [self.delegate recordingContextChanged:isRecording];
            }
        });
    }
    else if (context == SessionRunningAndDeviceAuthorizedContext)
    {
        BOOL isRunning = [change[NSKeyValueChangeNewKey] boolValue];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if([self.delegate respondsToSelector:@selector(sessionRunningAndDeviceAuthorizedContextChanged:)]){
                [self.delegate sessionRunningAndDeviceAuthorizedContextChanged:isRunning];
            }
        });
    }
    else
    {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (void)toggleMovieRecording
{
    dispatch_async([self sessionQueue], ^{
        if (![[self movieFileOutput] isRecording])
        {
            [self setLockInterfaceRotation:YES];
            
            if ([[UIDevice currentDevice] isMultitaskingSupported])
            {
                // Setup background task. This is needed because the captureOutput:didFinishRecordingToOutputFileAtURL: callback is not received until AVCam returns to the foreground unless you request background execution time. This also ensures that there will be time to write the file to the assets library when AVCam is backgrounded. To conclude this background execution, -endBackgroundTask is called in -recorder:recordingDidFinishToOutputFileURL:error: after the recorded file has been saved.
                [self setBackgroundRecordingID:[[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:nil]];
            }
            
            // Update the orientation on the movie file output video connection before starting recording.
            [[[self movieFileOutput] connectionWithMediaType:AVMediaTypeVideo] setVideoOrientation:[[(AVCaptureVideoPreviewLayer *)[[self previewView] layer] connection] videoOrientation]];
            
            // Turning OFF flash for video recording
            [self setFlashMode:AVCaptureFlashModeOff forDevice:[[self videoDeviceInput] device]];
            
            
            // Add segments here
            // Start recording to a temporary file.
            NSString *outputFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"movie" stringByAppendingPathExtension:@"mov"]];
            [[self movieFileOutput] startRecordingToOutputFileURL:[NSURL fileURLWithPath:outputFilePath] recordingDelegate:self];
        }
        else
        {
            [[self movieFileOutput] stopRecording];
        }
    });
}

-(void)switchCamera
{
    
    dispatch_async([self sessionQueue], ^{
        AVCaptureDevice *currentVideoDevice = [[self videoDeviceInput] device];
        AVCaptureDevicePosition preferredPosition = AVCaptureDevicePositionUnspecified;
        AVCaptureDevicePosition currentPosition = [currentVideoDevice position];
        
        switch (currentPosition)
        {
            case AVCaptureDevicePositionUnspecified:
                preferredPosition = AVCaptureDevicePositionFront;
                break;
            case AVCaptureDevicePositionBack:
                preferredPosition = AVCaptureDevicePositionFront;
                break;
            case AVCaptureDevicePositionFront:
                preferredPosition = AVCaptureDevicePositionBack;
                break;
        }
        
        AVCaptureDevice *videoDevice = [self deviceWithMediaType:AVMediaTypeVideo preferringPosition:preferredPosition];
        AVCaptureDeviceInput *videoDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:nil];
        
        [[self flCaptureSession] beginConfiguration];
        
        [[self flCaptureSession] removeInput:[self videoDeviceInput]];
        if ([[self flCaptureSession] canAddInput:videoDeviceInput])
        {
            [[NSNotificationCenter defaultCenter] removeObserver:self name:AVCaptureDeviceSubjectAreaDidChangeNotification object:currentVideoDevice];
            
            [self setFlashMode:AVCaptureFlashModeAuto forDevice:videoDevice];

            
            [[self flCaptureSession] addInput:videoDeviceInput];
            [self setVideoDeviceInput:videoDeviceInput];
        }
        else
        {
            [[self flCaptureSession] addInput:[self videoDeviceInput]];
        }
        
        [[self flCaptureSession] commitConfiguration];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if([self.delegate respondsToSelector:@selector(cameraSwitched)]){
                [self.delegate cameraSwitched];
            }
        });
    });
}

- (void) captureOutput:(AVCaptureFileOutput *)captureOutput didStartRecordingToOutputFileAtURL:(NSURL *)fileURL fromConnections:(NSArray *)connections {
    
}

- (void)captureOutput:(AVCaptureFileOutput *)captureOutput didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL fromConnections:(NSArray *)connections error:(NSError *)error
{
    if (error)
        NSLog(@"%@", error);
    
    [self setLockInterfaceRotation:NO];
    
    // Note the backgroundRecordingID for use in the ALAssetsLibrary completion handler to end the background task associated with this recording. This allows a new recording to be started, associated with a new UIBackgroundTaskIdentifier, once the movie file output's -isRecording is back to NO — which happens sometime after this method returns.
    UIBackgroundTaskIdentifier backgroundRecordingID = [self backgroundRecordingID];
    [self setBackgroundRecordingID:UIBackgroundTaskInvalid];
    
    [[[ALAssetsLibrary alloc] init] writeVideoAtPathToSavedPhotosAlbum:outputFileURL completionBlock:^(NSURL *assetURL, NSError *error) {
        if (error)
            NSLog(@"%@", error);
        
        [[NSFileManager defaultManager] removeItemAtURL:outputFileURL error:nil];
        
        if (backgroundRecordingID != UIBackgroundTaskInvalid)
            [[UIApplication sharedApplication] endBackgroundTask:backgroundRecordingID];
    }];
}

- (void) setOptimumSessionPreset: (FLCaptureSession *) aCaptureSession {
    NSArray * devices = [AVCaptureDevice devices];
    
    for (AVCaptureDevice * device in devices) {
        if ([device hasMediaType:AVMediaTypeVideo]) {
            if ([aCaptureSession canSetSessionPreset:FLCaptureSessionPreset1920x1080])
                [aCaptureSession setSessionPreset:FLCaptureSessionPreset1920x1080];
            else if ([aCaptureSession canSetSessionPreset:FLCaptureSessionPreset1280x720])
                [aCaptureSession setSessionPreset:FLCaptureSessionPreset1280x720];
            else if ([aCaptureSession canSetSessionPreset:FLCaptureSessionPreset640x480])
                [aCaptureSession setSessionPreset:FLCaptureSessionPreset640x480];
            else if ([aCaptureSession canSetSessionPreset:FLCaptureSessionPreset352x288])
                [aCaptureSession setSessionPreset:FLCaptureSessionPreset352x288];
            else
                NSLog(@"Error: Failed to set SessionPreset!");
        }
        else
            NSLog(@"Error: No Camera Found!");
    }
}

- (void)setFlashMode:(AVCaptureFlashMode)flashMode forDevice:(AVCaptureDevice *)device
{
    if ([device hasFlash] && [device isFlashModeSupported:flashMode])
    {
        NSError *error = nil;
        if ([device lockForConfiguration:&error])
        {
            [device setFlashMode:flashMode];
            [device unlockForConfiguration];
        }
        else
        {
            NSLog(@"%@", error);
        }
    }
}

- (void) toggleRecorderMirroringWithCaptureConnection: (AVCaptureConnection *) aCaptureConnection {
    // Check whether capture connection supports mirroring
    
    if (aCaptureConnection.isVideoMirroringSupported) {
        if (aCaptureConnection.isVideoMirrored) {
            [aCaptureConnection setVideoMirrored:NO];
        }
        else {
            [aCaptureConnection setVideoMirrored:YES];
        }
    }
}




- (void)checkDeviceAuthorizationStatus {
    NSString *mediaType = AVMediaTypeVideo;
    
    [AVCaptureDevice requestAccessForMediaType:mediaType completionHandler:^(BOOL granted) {
        if (granted) {
            //Granted access to mediaType
            [self setDeviceAuthorized:YES];
        }
        else{
            [self setDeviceAuthorized:NO];
            
            //Not granted access to mediaType
            dispatch_async(dispatch_get_main_queue(), ^{

                // Notify the delegate that the device is not autorized to use the camera.
                if([self.delegate respondsToSelector:@selector(deviceNotAuthorized)]){
                    [self.delegate deviceNotAuthorized];
                }
            });
        }
    }];
}

- (AVCaptureDevice *)deviceWithMediaType:(NSString *)mediaType preferringPosition:(AVCaptureDevicePosition)position {
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:mediaType];
    AVCaptureDevice *captureDevice = [devices firstObject];
    
    for (AVCaptureDevice *device in devices){
        if ([device position] == position){
            captureDevice = device;
            break;
        }
    }
    
    return captureDevice;
}


@end
