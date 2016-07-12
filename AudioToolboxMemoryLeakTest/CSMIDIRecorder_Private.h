//
//  CSMIDIRecorder_Private.h
//  Composer's Sketchpad
//
//  Created by Alexei Baboulevitch on 4/22/16.
//
//

#import "CSMIDIRecorder.h"

#import <vector>
#import <map>

@interface CSMIDIRecorder () {
    std::vector<AudioUnit> samplers;
    std::map<AudioUnit, AUNode> samplerToNode;
}

@property (nonatomic, assign) Float64 sampleRate;
@property (nonatomic, assign) SInt32 framesPerSlice;

@property (nonatomic, retain) NSMutableIndexSet* availableMixerIndices;

@property (nonatomic, assign) AUGraph graph;
@property (nonatomic, assign) AudioUnit mixer;
@property (nonatomic, assign) AudioUnit output;
@property (nonatomic, assign) AUNode mixerNode;
@property (nonatomic, assign) AUNode outputNode;

-(AudioUnit) createSamplerWithOutputNode:(AUNode*)node synth:(BOOL)synth connected:(BOOL)connected;

@end
