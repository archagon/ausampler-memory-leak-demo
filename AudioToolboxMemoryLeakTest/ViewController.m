//
//  ViewController.m
//  AudioToolboxMemoryLeakTest
//
//  Created by Alexei Baboulevitch on 2016-7-8.
//  Copyright © 2016 Alexei Baboulevitch. All rights reserved.
//

#import "ViewController.h"
#import "CSMIDIRecorder.h"

@interface ViewController ()

@end

@implementation ViewController

NSTimer* recorderTimer = nil;

-(void)viewDidAppear:(BOOL)animated {
    recorderTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
}

-(void) tick:(NSTimer*)timer {
    NSURL* sf2URL = [[NSBundle mainBundle] URLForResource:@"test" withExtension:@"sf2"];
    
    CSMIDIRecorder* recorder = [[CSMIDIRecorder alloc] init];
    
    AudioUnit sampler = [recorder createSampler];
    [recorder loadPatch:arc4random_uniform(80) withSoundbank:sf2URL forSampler:sampler];
    
    [recorder startGraph];
    
    // AB: this is what causes the leak. comment this out and no more leak!
    [recorder loadInfoForSampler:sampler];
}
@end
