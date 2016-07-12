//
//  CSMIDIRecorder.h
//  Composer's Sketchpad
//
//  Created by Alexei Baboulevitch on 4/22/16.
//
//

#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

@interface CSMIDIRecorder : NSObject

-(instancetype) init;

-(void) debugPrintGraph;

-(void) startGraph;
-(void) stopGraph;
-(AudioUnit) createSampler;
-(void) loadPatch:(NSInteger)patch withSoundbank:(NSURL*)soundbank forSampler:(AudioUnit)unit;
-(void) loadInfoForSampler:(AudioUnit)sampler;

@end
