//
//  CSMIDIRecorder.m
//  Composer's Sketchpad
//
//  Created by Alexei Baboulevitch on 4/22/16.
//
//

#import "CSMIDIRecorder.h"
#import "CSMIDIRecorder_Private.h"

NSInteger OSSTATUS = 0;
#define OSSTATUS_CHECK if (OSSTATUS != 0) [NSException raise:NSInternalInconsistencyException \
format:@"OSStatus error: %d", (int)OSSTATUS];

@implementation CSMIDIRecorder

const NSInteger CSMIDIRecorderMaxMixerIndices = 50;

// TODO: line
void CSMIDIRecorderFatalError(BOOL condition, NSString* type) {
    if (!condition) {
        [NSException raise:NSInternalInconsistencyException format:@"Fatal error in audio recorder: %@", (type != nil ? type : @"unknown")];
    }
}

-(void) dealloc {
    NSLog(@"Graph dealloced");
    
    // https://groups.google.com/forum/#!topic/coreaudio-api/AkMIFy11yvA
    Boolean isRunning = YES;
    AUGraphIsRunning(self.graph, &isRunning);
    if (isRunning) {
        AUGraphStop(self.graph);
    }
    
    // KLUDGE: frees up pent-up samples, um, sometimes; dunno why everything else doesn't seem to do this
    [self cleanUpGraphAll:YES];
    
    AUGraphUninitialize(self.graph);
    DisposeAUGraph(self.graph);
}

-(instancetype) init {
    self = [super init];
    
    if (self) {
        self.availableMixerIndices = [NSMutableIndexSet indexSetWithIndexesInRange:NSMakeRange(0, CSMIDIRecorderMaxMixerIndices)];
        
        [self setupAudioSession];
        [self setupGraph];
    }
    
    return self;
}
                                                                                                        
#pragma mark - AudioSession Stuff -

-(void) setupAudioSession {
    [self resumeAudioSession];
}

-(void) resumeAudioSession {
    AVAudioSession* mySession = [AVAudioSession sharedInstance];
    
    NSError* error = nil;
    BOOL success = [mySession setCategory:AVAudioSessionCategoryPlayback error:&error];
    CSMIDIRecorderFatalError(success, @"AVAudioSession setCategory");
    
    self.sampleRate = 44100.0;
    
    success = [mySession setPreferredSampleRate:self.sampleRate error:&error];
    CSMIDIRecorderFatalError(success, @"AVAudioSession setPreferredSampleRate");
    
    success = [mySession setActive:YES error:&error];
    CSMIDIRecorderFatalError(success, @"AVAudioSession setActive");
    
    // BUGFIX: with headphones, retrieving the sample rate sets it to 16kHz, whereas doing nothing keeps it at 44.1kHz!!
    // however, the sample rate does neet to be set to something initially. presumably with offline rendering, the
    // actual device sample rate doesn't matter much.
    self.sampleRate = [mySession sampleRate];
}

#pragma mark - Graph Stuff -

-(void) setupGraph {
    // create initial graph
    {
        AUGraph graph;
        AUNode ioNode, mixerNode;
        
        AudioComponentDescription cd = {};
        cd.componentManufacturer     = kAudioUnitManufacturer_Apple;
        cd.componentFlags            = 0;
        cd.componentFlagsMask        = 0;
        
        OSSTATUS = NewAUGraph(&graph); OSSTATUS_CHECK
        
        cd.componentType = kAudioUnitType_Mixer;
        cd.componentSubType = kAudioUnitSubType_MultiChannelMixer;
        
        OSSTATUS = AUGraphAddNode(graph, &cd, &mixerNode); OSSTATUS_CHECK
        
        cd.componentType = kAudioUnitType_Output;
        cd.componentSubType = kAudioUnitSubType_RemoteIO;
        
        OSSTATUS = AUGraphAddNode(graph, &cd, &ioNode); OSSTATUS_CHECK
        
        // in most examples, this function is called after nodes are added; not sure if we can call it before
        // however, it does have to be called before we make connections or set properties
        OSSTATUS = AUGraphOpen (graph); OSSTATUS_CHECK
        
        OSSTATUS = AUGraphConnectNodeInput(graph, mixerNode, 0, ioNode, 0); OSSTATUS_CHECK
        
        self.graph = graph;
        self.mixerNode = mixerNode;
        self.outputNode = ioNode;
    }
  
    // setup initial units
    {
        AudioUnit ioUnit, mixerUnit;
        
        OSSTATUS = AUGraphNodeInfo (self.graph, self.mixerNode, 0, &mixerUnit); OSSTATUS_CHECK
        OSSTATUS = AUGraphNodeInfo (self.graph, self.outputNode, 0, &ioUnit); OSSTATUS_CHECK
        
        UInt32 framesPerSlice = 0;
        UInt32 framesPerSlicePropertySize = sizeof (framesPerSlice);
        
        // global frames per slice
        OSSTATUS = AudioUnitGetProperty (ioUnit,
                                         kAudioUnitProperty_MaximumFramesPerSlice,
                                         kAudioUnitScope_Global,
                                         0,
                                         &framesPerSlice,
                                         &framesPerSlicePropertySize); OSSTATUS_CHECK
        self.framesPerSlice = framesPerSlice;
        
        // this is necessary so that we can set the output unit's sample rate
        OSSTATUS = AudioUnitInitialize(ioUnit); OSSTATUS_CHECK
        
        [self configureAudioUnit:ioUnit];
        [self configureAudioUnit:mixerUnit];
        
        UInt32 busCount = 50;
        OSSTATUS = AudioUnitSetProperty(mixerUnit,
                                        kAudioUnitProperty_ElementCount,
                                        kAudioUnitScope_Input,
                                        0,
                                        &busCount,
                                        sizeof(busCount)); OSSTATUS_CHECK
        
        self.mixer = mixerUnit;
        self.output = ioUnit;
    }
    
    AUGraphInitialize(self.graph);
}

-(AudioUnit) createSampler {
    return [self createSamplerWithOutputNode:NULL synth:NO connected:YES];
}

-(AudioUnit) createSamplerWithOutputNode:(AUNode*)node synth:(BOOL)synth connected:(BOOL)connected
{
    Boolean value;
    OSSTATUS = AUGraphIsOpen(self.graph, &value); OSSTATUS_CHECK
    if (!value) {
        return NULL;
    }
    OSSTATUS = AUGraphIsInitialized(self.graph, &value); OSSTATUS_CHECK
    if (!value) {
        return NULL;
    }
    
    AUNode samplerNode;
    AudioUnit samplerUnit;
    
    AudioComponentDescription cd = {};
    cd.componentManufacturer     = kAudioUnitManufacturer_Apple;
    cd.componentFlags            = 0;
    cd.componentFlagsMask        = 0;
    cd.componentType = kAudioUnitType_MusicDevice;
    cd.componentSubType = (synth ? kAudioUnitSubType_MIDISynth : kAudioUnitSubType_Sampler);
    
    OSSTATUS = AUGraphAddNode(self.graph, &cd, &samplerNode); OSSTATUS_CHECK
    
    OSSTATUS = AUGraphNodeInfo (self.graph, samplerNode, 0, &samplerUnit); OSSTATUS_CHECK
    
    [self configureAudioUnit:samplerUnit];
    
    // connect it after configuration, because it initializes when this happens and we can't configure it once initialized
    NSInteger index = [self.availableMixerIndices firstIndex];
    OSSTATUS = AUGraphConnectNodeInput(self.graph, samplerNode, 0, self.mixerNode, (UInt32)index); OSSTATUS_CHECK
    [self.availableMixerIndices removeIndex:index];
    
    samplers.push_back(samplerUnit);
    samplerToNode[samplerUnit] = samplerNode;
    
    OSSTATUS = AUGraphUpdate(self.graph, NULL); OSSTATUS_CHECK
    
    if (node != NULL) {
        *node = samplerNode;
    }
    
    return samplerUnit;
}
                                                                                                        
// for some units, these can only be done when they're uninitialized
-(void) configureAudioUnit:(AudioUnit)unit {
    OSSTATUS = AudioUnitSetProperty (unit,
                                     kAudioUnitProperty_SampleRate,
                                     kAudioUnitScope_Output,
                                     0,
                                     &_sampleRate,
                                     sizeof(_sampleRate)); OSSTATUS_CHECK
    OSSTATUS = AudioUnitSetProperty (unit,
                                     kAudioUnitProperty_MaximumFramesPerSlice,
                                     kAudioUnitScope_Global,
                                     0,
                                     &_framesPerSlice,
                                     sizeof(_framesPerSlice)); OSSTATUS_CHECK
}

// HACK: can crash on draw if graph is still in use, so do it only in dealloc, etc.
-(void) cleanUpGraphAll:(BOOL)all {
    UInt32 interactions = 0;
    OSSTATUS = AUGraphGetNumberOfInteractions(self.graph, &interactions); OSSTATUS_CHECK
    
    UInt32 nodes = 0;
    OSSTATUS = AUGraphGetNodeCount(self.graph, &nodes); OSSTATUS_CHECK
    
    AUNode maxNodesToRemove[nodes];
    AudioUnit graphSamplers[nodes];
    int nodesToRemove = 0;
    
    for (int i = 0; i < nodes; i++) {
        AUNode node = 0;
        AudioUnit sampler = NULL;
        AudioComponentDescription description = { 0 };
        
        OSSTATUS = AUGraphGetIndNode(self.graph, i, &node); OSSTATUS_CHECK
        OSSTATUS = AUGraphNodeInfo(self.graph, node, &description, &sampler); OSSTATUS_CHECK
        
        if (description.componentType == kAudioUnitType_MusicDevice) {
            NSInteger mixerConnection = -1;
            
            for (UInt32 i = 0; i < interactions; i++) {
                AUNodeInteraction interaction;
                OSSTATUS = AUGraphGetInteractionInfo(self.graph, i, &interaction);
                
                if (interaction.nodeInteractionType == 1 &&
                    interaction.nodeInteraction.connection.sourceNode == node) {
                    mixerConnection = interaction.nodeInteraction.connection.destInputNumber;
                    break;
                }
            }
            
            // only clean up disconnected nodes
            if (all || mixerConnection == -1) {
                maxNodesToRemove[nodesToRemove] = node;
                graphSamplers[nodesToRemove] = sampler;
                nodesToRemove++;
            }
        }
    }
     
    for (int i = 0; i < nodesToRemove; i++) {
        // AB: just in case — testing all possibilities!!
        for (int j = 0; j < 16; j++) {
            AudioUnitReset(graphSamplers[i], kAudioUnitScope_Global, j);
            AudioUnitReset(graphSamplers[i], kAudioUnitScope_Input, j);
            AudioUnitReset(graphSamplers[i], kAudioUnitScope_Output, j);
            AudioUnitReset(graphSamplers[i], kAudioUnitScope_Group, j);
            AudioUnitReset(graphSamplers[i], kAudioUnitScope_Part, j);
            AudioUnitReset(graphSamplers[i], kAudioUnitScope_Note, j);
            AudioUnitReset(graphSamplers[i], kAudioUnitScope_Layer, j);
            AudioUnitReset(graphSamplers[i], kAudioUnitScope_LayerItem, j);
        }
        OSSTATUS = AUGraphRemoveNode(self.graph, maxNodesToRemove[i]); OSSTATUS_CHECK
    }
    
    OSSTATUS = AUGraphUpdate(self.graph, NULL); OSSTATUS_CHECK
}

-(void) debugPrintGraph {
    CAShow(self.graph);
}

#pragma mark - Audio Unit Specific Setup -

-(void) setupSoundbank:(NSURL*)aUrl forSynth:(AudioUnit)unit {
    CFURLRef url = (CFURLRef)CFRetain((CFURLRef)aUrl);
    OSSTATUS = AudioUnitSetProperty(unit,
                                    kMusicDeviceProperty_SoundBankURL,
                                    kAudioUnitScope_Global,
                                    0,
                                    &url,
                                    sizeof(url)); OSSTATUS_CHECK
    CFAutorelease(url);
}

-(void) loadPatch:(NSInteger)patch forSynth:(AudioUnit)unit {
    UInt32 actualPreset = (UInt32)patch;
    BOOL isPercussion = (patch == -1);
    
    UInt32 instrumentMSB = kAUSampler_DefaultMelodicBankMSB;
    UInt32 instrumentLSB = kAUSampler_DefaultBankLSB;
    UInt32 percussionMSB = kAUSampler_DefaultPercussionBankMSB;
    UInt32 percussionLSB = kAUSampler_DefaultBankLSB;
    
    for (int j = 0; j < 16; j++) {
        UInt32 enabled = 1;
        OSSTATUS = AudioUnitSetProperty(unit,
                                        kAUMIDISynthProperty_EnablePreload,
                                        kAudioUnitScope_Global,
                                        0,
                                        &enabled,
                                        sizeof(enabled)); OSSTATUS_CHECK
        
        OSSTATUS = MusicDeviceMIDIEvent(unit, 0xB0 | j, 0x00, (isPercussion ? percussionMSB : instrumentMSB), 0); OSSTATUS_CHECK
        OSSTATUS = MusicDeviceMIDIEvent(unit, 0xB0 | j, 0x20, (isPercussion ? percussionLSB : instrumentLSB), 0); OSSTATUS_CHECK
        
        OSSTATUS = MusicDeviceMIDIEvent(unit, 0xC0 | j, (UInt32)actualPreset, 0, 0); OSSTATUS_CHECK
        
        enabled = 0;
        OSSTATUS = AudioUnitSetProperty(unit,
                                        kAUMIDISynthProperty_EnablePreload,
                                        kAudioUnitScope_Global,
                                        0,
                                        &enabled,
                                        sizeof(enabled)); OSSTATUS_CHECK
        
        OSSTATUS = MusicDeviceMIDIEvent(unit, 0xC0 | j, (UInt32)actualPreset, 0, 0); OSSTATUS_CHECK
    }
}

-(void) loadPatch:(NSInteger)patch withSoundbank:(NSURL*)soundbank forSampler:(AudioUnit)unit {
    CFURLRef bridgedURL = (CFURLRef)CFBridgingRetain(soundbank);
    
    AUSamplerInstrumentData instdata;
    instdata.fileURL = bridgedURL;
    instdata.instrumentType = kInstrumentType_SF2Preset;
    instdata.bankMSB = kAUSampler_DefaultMelodicBankMSB;
    instdata.bankLSB = kAUSampler_DefaultBankLSB;
    instdata.presetID = patch;
    
    OSSTATUS = AudioUnitSetProperty(unit,
                                    kAUSamplerProperty_LoadInstrument,
                                    kAudioUnitScope_Global,
                                    0,
                                    &instdata,
                                    sizeof(instdata)); OSSTATUS_CHECK
    
    CFBridgingRelease(bridgedURL);
}

-(void) loadInfoForSampler:(AudioUnit)sampler {
    CFPropertyListRef myClassData;
    
    UInt32 size = sizeof(CFPropertyListRef);
    OSSTATUS = AudioUnitGetProperty(sampler,
                                    kAudioUnitProperty_ClassInfo,
                                    kAudioUnitScope_Global,
                                    0,
                                    &myClassData,
                                    &size); OSSTATUS_CHECK
    
    CFRelease(myClassData);
}

#pragma mark - Graph Control -

-(void) stopGraph {
    OSSTATUS = AUGraphStop(self.graph); OSSTATUS_CHECK
}

-(void) startGraph {
    OSSTATUS = AUGraphStart(self.graph); OSSTATUS_CHECK
}

@end
