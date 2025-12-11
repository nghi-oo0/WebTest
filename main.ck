// =========================================================
// LIVE SAMPLER - Refactored & Commented
// =========================================================

// =========================================================
// [1] CONFIGURATION & GLOBALS
// =========================================================

// --- Audio Settings ---
10 => int NUM_SLOTS;            // Total number of sample slots
10::second => dur MAX_DUR;      // Max recording time per slot
0.02 => float THRESHOLD;        // Audio threshold to trigger recording
50::ms => dur RELEASE_TIME;     // Fade out time for effects
global float BPM;
100.0 => BPM;                   // Global Tempo

// --- Interface Globals ---
global int webKey;              // Key code from Web Interface
global Event webKeyEvent;       // Trigger when key is pressed
global float micLevel;          // Export mic level for visuals

// --- Data Transfer (Loading files from JS) ---
global float loadBuffer[0];     // Array to hold incoming sample data
global int loadBufferSize;      // Size of the incoming data
global Event loadBufferTrigger; // Trigger when JS finishes loading data

// --- State Variables ---
int playbackOrder[0];           // Queue for mixing/concatenation
0 => int concatRunning;         // Mode flag: Are we in macro mode?
0 => int pendingEffect;         // Mode flag: Is an effect armed?
0 => int targetSlot;            // Currently selected slot (0-9)
1 => int metronomeOn;           // Metronome Toggle

// --- Slot Data Arrays ---
NRev slotRevs[NUM_SLOTS];       // Reverb unit for each slot
LiSa slots[NUM_SLOTS];          // The actual sampler objects (LiSa)
float slotRates[NUM_SLOTS];     // Playback rate (pitch)
float slotGains[NUM_SLOTS];     // Volume per slot
int isRecording[NUM_SLOTS];     // State: Is currently recording?
int isPending[NUM_SLOTS];       // State: Is waiting for audio threshold?
int isPlaying[NUM_SLOTS];       // State: Is currently playing?
time recStart[NUM_SLOTS];       // Timestamp when recording started
time lastHeard[NUM_SLOTS];      // Timestamp of last valid audio (silence detection)
dur loopLength[NUM_SLOTS];      // Duration of the recorded loop
Shred playShreds[NUM_SLOTS];    // References to playing threads (to kill them if needed)

// =========================================================
// [2] AUDIO GRAPH & INITIALIZATION
// =========================================================

// Master Output Limiter
Dyno dyno => dac;
dyno.limit();

// Microphone Input
Gain adcGain;
adc => adcGain;
0.5 => adcGain.gain; // Initial Mic Boost

// Metronome Click
Impulse click => dyno; 
0.1 => click.gain;

// Initialize Slots
for(0 => int i; i < NUM_SLOTS; i++) {
    // Connect Mic -> LiSa -> Reverb -> Master
    adcGain => slots[i] => slotRevs[i] => dyno;
    
    // Default Settings
    0.0 => slotRevs[i].mix;         // Dry signal only
    MAX_DUR => slots[i].duration;   // Allocate memory
    slots[i].loop0(0);              // Disable loop by default
    slots[i].bi(0);                 // Unidirectional playback
    0::ms => slots[i].rampUp;       // Instant attack
    10::ms => slots[i].rampDown;    // Short release to prevent clicks
    0 => slots[i].feedback;         // No feedback (delay line behavior)
    
    // Default Values
    1.0 => slotRates[i];
    1.0 => slots[i].rate;
    1.0 => slotGains[i];
    1.0 => slots[i].gain;
}

// =========================================================
// [3] THREADS
// =========================================================

Event beatTrigger;

// Start background processes
spork ~ runClock();         // Metronome timing
spork ~ monitorMic();       // VU Meter logic
spork ~ bufferLoaderLoop(); // File loading system

<<< "--- LIVE SAMPLER READY ---", "" >>>;


// =========================================================
// [4] MAIN CONTROL LOOP
// =========================================================

while(true) {
    // Wait for a key press from the web interface
    webKeyEvent => now;
    webKey => int c;

    // -------------------------------------
    // [0-9] SLOT TRIGGERING
    // -------------------------------------
    if(c >= 48 && c <= 57) {
        c - 48 => int keyIndex;
        // Fix '0' key (ASCII 48) to be index 9
        if(keyIndex == 0) 10 => keyIndex; 
        keyIndex - 1 => keyIndex;

        if(pendingEffect > 0) { 
            // If an FX key (Z,X,C,V) was pressed previously, render FX
            spork ~ renderEffect(keyIndex, targetSlot, pendingEffect);
            0 => pendingEffect; 
        }
        else if(concatRunning == 1) { 
            // If in Macro mode, add to queue
            playbackOrder << keyIndex;
            spork ~ syncPlay(keyIndex); 
            <<< "Added Slot", keyIndex+1, "to sequence" >>>;
        }
        else { 
            // Standard Playback
            handlePlayback(keyIndex);
        }
    }
    
    // -------------------------------------
    // [M] METRONOME
    // -------------------------------------
    if(c == 77) {
        if(metronomeOn == 1) { 
            0 => metronomeOn;
            <<< "Metronome: MUTED" >>>; 
        } else { 
            1 => metronomeOn;
            <<< "Metronome: ON" >>>; 
        }
    }
    
    // -------------------------------------
    // [- / =] SELECT SLOT
    // -------------------------------------
    if(c == 45 || c == 189) { // '-' key
        targetSlot--;
        if(targetSlot < 0) 9 => targetSlot; 
        <<< "Selected Slot:", targetSlot+1, "| Vol:", slotGains[targetSlot] >>>; 
        0 => pendingEffect;
    }
    if(c == 61 || c == 187) { // '=' key
        targetSlot++;
        if(targetSlot > 9) 0 => targetSlot; 
        <<< "Selected Slot:", targetSlot+1, "| Vol:", slotGains[targetSlot] >>>; 
        0 => pendingEffect;
    }

    // -------------------------------------
    // [[ / ]] VOLUME CONTROL
    // -------------------------------------
    if(c == 91 || c == 219) { // '[' key
        slotGains[targetSlot] - 0.1 => slotGains[targetSlot];
        if(slotGains[targetSlot] < 0) 0 => slotGains[targetSlot];
        slotGains[targetSlot] => slots[targetSlot].gain; 
        <<< "Slot", targetSlot+1, "Volume:", slotGains[targetSlot] >>>;
    }
    if(c == 93 || c == 221) { // ']' key
        slotGains[targetSlot] + 0.1 => slotGains[targetSlot];
        if(slotGains[targetSlot] > 2.0) 2.0 => slotGains[targetSlot];
        slotGains[targetSlot] => slots[targetSlot].gain; 
        <<< "Slot", targetSlot+1, "Volume:", slotGains[targetSlot] >>>;
    }

    // -------------------------------------
    // [R] RECORD
    // -------------------------------------
    if(c == 82) {
        if(concatRunning == 0) {
            if(isRecording[targetSlot] == 0 && isPending[targetSlot] == 0) {
                // ARM RECORDING
                1 => isPending[targetSlot]; 
                0 => slots[targetSlot].play; 
                0 => isPlaying[targetSlot];
                spork ~ waitAndRecord(targetSlot);
                <<< "Slot [" + (targetSlot+1) + "] ARMED... (Speak to trigger)", "" >>>;
            } else if(isRecording[targetSlot] == 1) { 
                // STOP RECORDING
                stopRecording(targetSlot);
            }
        } else { 
            <<< "Cannot mic record during Concat/Mix mode!" >>>; 
        }
    }

    // -------------------------------------
    // [Z, X, C, V] FX SELECTION
    // -------------------------------------
    if(c == 90) { 1 => pendingEffect; <<< "[Z] REVERB ARMED (Select source slot 1-0)" >>>; }
    if(c == 88) { 2 => pendingEffect; <<< "[X] REVERSE ARMED (Select source slot 1-0)" >>>; }
    if(c == 67) { 3 => pendingEffect; <<< "[C] PITCH UP ARMED (Select source slot 1-0)" >>>; }
    if(c == 86) { 4 => pendingEffect; <<< "[V] PITCH DOWN ARMED (Select source slot 1-0)" >>>; }

    // -------------------------------------
    // [F / G] MACRO MODES
    // -------------------------------------
    // [F] Concatenate Mode
    if(c == 70) {
        if(concatRunning == 0) { 
            1 => concatRunning;
            playbackOrder.clear(); 
            <<< "Concatenate ON. Play sequence. Press F again to Render." >>>; 
            spork ~ concatManager();
        } else { 
            0 => concatRunning; // Triggers the render in the thread
        } 
    }
    // [G] Mix Mode
    if(c == 71) {
        if(concatRunning == 0) { 
            1 => concatRunning;
            playbackOrder.clear(); 
            <<< "Mix Mode ON. Play layers. Press G again to Render." >>>; 
            spork ~ mixManager();
        } else { 
            0 => concatRunning; 
        }
    }

    // -------------------------------------
    // [L] LOOP TOGGLE
    // -------------------------------------
    if(c == 76) {
        if(slots[targetSlot].loop0() == 0) { 
            1 => slots[targetSlot].loop0;
            <<< "Loop: ON" >>>; 
        } else { 
            0 => slots[targetSlot].loop0;
            <<< "Loop: OFF" >>>; 
        }
    }

    // -------------------------------------
    // [SPACE] PANIC / STOP ALL
    // -------------------------------------
    if(c == 32) {
        for(0 => int i; i < NUM_SLOTS; i++) { 
            0 => slots[i].play;
            0 => slots[i].record; 
            0 => isPlaying[i]; 
            0 => isRecording[i]; 
            0 => isPending[i];
        }
        0 => pendingEffect;
        0 => concatRunning; 
        <<< "!!! ALL STOP !!!", "" >>>;
    }
}

// =========================================================
// [5] LOGIC UTILS & FUNCTIONS
// =========================================================

// =========================================================
// PLAYBACK ENGINE
// =========================================================

// Function: handlePlayback
// ------------------------
// The main entry point when a slot key (1-0) is pressed.
// Logic:
// 1. If recording, do nothing (safety).
// 2. If already playing, retrigger (restart) the sound immediately.
// 3. If silent, start a new playback thread.
fun void handlePlayback(int index) {
    // Only play if we aren't currently recording or waiting for threshold
    if(isRecording[index] == 0 && isPending[index] == 0) {
        
        if(isPlaying[index] == 1) {
            // [RETRIGGER MODE]
            playShreds[index].exit(); // Kill the previous waiting thread
            slotRates[index] => slots[index].rate;

            // Reset position (Handle reverse playback logic)
            if(slotRates[index] < 0) slots[index].loopEnd() => slots[index].playPos; 
            else 0::ms => slots[index].playPos;
            
            1 => slots[index].play; 
            spork ~ waitAndStop(index) @=> playShreds[index]; // Start new watcher
            <<< "Slot", index+1, " -> RETRIGGER" >>>;
            
        } else { 
            // [NEW PLAYBACK MODE]
            1 => isPlaying[index]; 
            spork ~ syncPlay(index) @=> playShreds[index]; 
            <<< "Slot", index+1, " -> PLAYING" >>>;
        }
    }
}

// Function: syncPlay
// ------------------
// Starts playback. Originally designed to wait for the beat (Quantized Start),
// but modified here for Instant Start.
fun void syncPlay(int index) { 
    // beatTrigger => now; // <--- REMOVED: Instant Playback (No wait)
    
    slotRates[index] => slots[index].rate;
    
    // Set start position based on direction (Forward vs Reverse)
    if(slotRates[index] < 0) slots[index].loopEnd() => slots[index].playPos; 
    else 0::ms => slots[index].playPos; 
    
    1 => slots[index].play; 
    waitAndStop(index); // Enter the "Watcher" loop
}

// Function: waitAndStop
// ---------------------
// "The Watcher". This function keeps the 'isPlaying' flag TRUE while the sample plays.
// It calculates exactly how long the sample will take (accounting for pitch speed)
// and waits for that duration.
fun void waitAndStop(int index) {
    slotRates[index] => float currentRate;
    Math.fabs(currentRate) => float absRate; 
    if(absRate < 0.01) 1.0 => absRate; // Safety: Prevent divide by zero

    // Calculate duration: (Length / Rate) = Time to wait
    slots[index].loopEnd() / absRate => dur playTime;
    
    while(isPlaying[index] == 1) { 
        playTime => now; 
        
        // Check if user stopped it manually while we were waiting
        if(isPlaying[index] == 0) break; 
        
        // [LOOP LOGIC]
        if(slots[index].loop0() == 0) { 
            // Loop is OFF: Stop everything
            0 => isPlaying[index];
            0 => slots[index].play; 
            break; 
        } 
        
        // Loop is ON: Reset position and wait again
        if(slotRates[index] < 0) slots[index].loopEnd() => slots[index].playPos; 
        else 0::ms => slots[index].playPos;
    }
}


// =========================================================
// RECORDING & QUANTIZATION
// =========================================================

// Function: waitAndRecord
// -----------------------
// Handles the "Arm -> Wait for Sound -> Record" workflow.
fun void waitAndRecord(int index) {
    // Stage 1: Wait for Audio Threshold (Auto-Start)
    while(isPending[index] == 1) {
        if(Math.fabs(adc.last()) > THRESHOLD) {
            0 => isPending[index];
            1 => isRecording[index]; 
            
            // Initialize LiSa for recording
            0::ms => slots[index].recPos; 
            now => recStart[index]; 
            now => lastHeard[index]; 
            0::ms => slots[index].playPos; 
            1 => slots[index].record;
            
            <<< "Ref [" + (index+1) + "] *** REC START ***", "" >>>;
        } 
        1::samp => now;
    }
    
    // Stage 2: Monitor input while recording (used for Silence Detection)
    while(isRecording[index] == 1) { 
        if(Math.fabs(adc.last()) > THRESHOLD / 2) { 
            now => lastHeard[index];
        } 
        1::ms => now; 
    }
}

// Function: stopRecording
// -----------------------
// Triggered when user presses 'R' to stop.
// CRITICAL: Calculates the "musical" length of the loop (Quantization).
// If you recorded 3.9 beats, it snaps to 4.0 and waits for the gap to fill.
fun void stopRecording(int index) {
    adcGain =< slots[index]; // Unpatch mic immediately
    0 => isRecording[index]; 
    
    // Calculate raw duration
    now - recStart[index] => dur validAudio;
    
    // Snap to nearest beat
    validAudio / 60::second / BPM => float rawBeats; 
    Math.ceil(rawBeats) => float snappedBeats;
    if(snappedBeats < 1) 1 => snappedBeats; // Min length: 1 beat
    
    snappedBeats * 60::second / BPM => dur quantLength; 
    quantLength - validAudio => dur gapToFill;
    
    if(gapToFill > 0::ms) { 
        // We stopped early. Record silence to fill the measure.
        spork ~ finalizeLoop(index, gapToFill, quantLength); 
    } else { 
        finalizeLoop(index, 0::ms, quantLength);
    }
}

// Function: finalizeLoop
// ----------------------
// Commits the recording to memory and resets playback defaults.
fun void finalizeLoop(int index, dur waitTime, dur finalLength) {
    waitTime => now; // Wait for gap (silence)
    0 => slots[index].record; 
    
    // Set Loop Points
    finalLength => loopLength[index]; 
    loopLength[index] => slots[index].loopEnd;
    
    // Reset Defaults (Pitch, Gain)
    1.0 => slotRates[index]; 
    1.0 => slotGains[index]; 
    1.0 => slots[index].gain;
    
    adcGain => slots[index]; // Repatch mic for next time
    <<< "Recorded Slot", index+1, "(", finalLength/60::second / BPM, "beats )" >>>;
}


// =========================================================
// EFFECTS RENDERER
// =========================================================

// Function: renderEffect
// ----------------------
// Renders offline effects (Reverb, Reverse, Pitch) from one slot to another.
fun void renderEffect(int srcIndex, int destIndex, int type) {
    // Safety Check
    if(slots[srcIndex].loopEnd() <= 0::ms) { 
        <<< "Error: Source Empty!", "" >>>;
        return; 
    } 
    
    // Setup Destination (Clean slate)
    0.0 => adcGain.gain; // Mute mic
    MAX_DUR => slots[destIndex].duration; 
    slots[destIndex].play(0); 
    slots[destIndex].record(1); 
    0::ms => slots[destIndex].recPos; 
    
    // Setup Source (Reset to normal speed for processing)
    slots[srcIndex].rate(1.0); 
    0::ms => slots[srcIndex].playPos;
    slots[srcIndex].loopEnd() => dur srcDur; 
    dur renderDur;

    // --- FX PROCESSING ---
    if(type == 1) { // REVERB
        0.2 => slotRevs[srcIndex].mix; 
        slotRevs[srcIndex] => slots[destIndex]; // Route via Reverb
        slots[srcIndex].play(1);
        
        // Wait for sample + tail
        srcDur + RELEASE_TIME => now; 
        srcDur + RELEASE_TIME => renderDur; 
        
        slots[srcIndex].play(0); 
        slotRevs[srcIndex] =< slots[destIndex]; // Unpatch
        0.0 => slotRevs[srcIndex].mix;
    }
    else if(type == 2) { // REVERSE
        slots[srcIndex] => slots[destIndex];
        -1.0 => slots[srcIndex].rate; // Negative Rate
        slots[srcIndex].loopEnd() => slots[srcIndex].playPos; 
        slots[srcIndex].play(1); 
        
        srcDur => now; 
        srcDur => renderDur; 
        
        slots[srcIndex].play(0); 
        slots[srcIndex] =< slots[destIndex]; 
        1.0 => slots[srcIndex].rate;
    }
    else if(type == 3) { // PITCH UP (+50%)
        slots[srcIndex] => slots[destIndex];
        1.5 => slots[srcIndex].rate; 
        slots[srcIndex].play(1); 
        
        srcDur / 1.5 => now; // Wait less time (faster)
        srcDur / 1.5 => renderDur; 
        
        slots[srcIndex].play(0); 
        slots[srcIndex] =< slots[destIndex];
        1.0 => slots[srcIndex].rate; 
    }
    else if(type == 4) { // PITCH DOWN (-25%)
        slots[srcIndex] => slots[destIndex];
        0.75 => slots[srcIndex].rate; 
        slots[srcIndex].play(1); 
        
        srcDur / 0.75 => now; // Wait more time (slower)
        srcDur / 0.75 => renderDur; 
        
        slots[srcIndex].play(0); 
        slots[srcIndex] =< slots[destIndex];
        1.0 => slots[srcIndex].rate; 
    }
    
    // Finalize Destination
    slots[destIndex].record(0); 
    renderDur => slots[destIndex].loopEnd;
    renderDur => loopLength[destIndex]; 
    
    // Reset Destination Defaults
    1.0 => slots[destIndex].rate; 
    1.0 => slotRates[destIndex]; 
    1.0 => slotGains[destIndex]; 
    1.0 => slots[destIndex].gain; 
    1.0 => adcGain.gain; // Restore Mic
    
    <<< "RENDER COMPLETE into Slot", destIndex+1 >>>;
}


// =========================================================
// MACRO MANAGERS (Concatenate & Mix)
// =========================================================

// Function: concatManager / concatenateSamples
// --------------------------------------------
// Records a sequence of slots end-to-end into a target slot.
fun void concatManager() { 
    while(concatRunning == 1) { 100::ms => now; } 
    concatenateSamples(targetSlot); 
}

fun void concatenateSamples(int target) {
    if(playbackOrder.size() == 0) { <<< "Nothing to concatenate" >>>; return; } 
    
    // Calculate total size needed
    0::ms => dur totalDur; 
    for(0 => int i; i < playbackOrder.size(); i++) { 
        slots[playbackOrder[i]].loopEnd() + totalDur => totalDur;
    } 
    
    // Prepare Target
    0 => slots[target].play; 
    0 => slots[target].loop0; 
    totalDur => slots[target].duration; 
    0.0 => adcGain.gain; 
    slots[target].record(1); 
    0::ms => slots[target].recPos;

    // Render Logic
    for(0 => int i; i < playbackOrder.size(); i++) { 
        playbackOrder[i] => int s; 
        slots[s].loopEnd() => dur d; 
        0 => slots[s].loop0;
        
        // Reset source params for clean recording
        slots[s].rate(1.0); 
        0::ms => slots[s].playPos; 
        slotGains[s] => slots[s].gain; 
        
        // Patch and Play
        slots[s] => slots[target]; 
        slots[s].play(1); 
        d => now; 
        slots[s].play(0); 
        slots[s] =< slots[target]; 
        
        slots[s].rate(slotRates[s]); // Restore original rate
    }

    // Cleanup
    slots[target].record(0); 
    1.0 => adcGain.gain; 
    totalDur => slots[target].loopEnd;
    totalDur => loopLength[target]; 
    10::ms => slots[target].rampDown; 
    1.0 => slotGains[target]; 
    1.0 => slots[target].gain; 
    playbackOrder.clear(); 
    <<< "Concatenation complete to Slot", target+1 >>>;
}

// Function: mixManager / mixSamples
// ---------------------------------
// Records multiple slots simultaneously (layered) into a target slot.
fun void mixManager() { 
    while(concatRunning == 1) { 100::ms => now; } 
    mixSamples(targetSlot); 
}

// Helper: Plays one layer for the mixdown
fun void tempMixPlay(int index, LiSa recorder, float safetyGain) { 
    slots[index] => recorder;
    safetyGain * slotGains[index] => slots[index].gain; 
    slots[index].rate(1.0); 
    0::ms => slots[index].playPos; 
    slots[index].play(1); 
    
    slots[index].loopEnd() => now; 
    
    slots[index].play(0); 
    slots[index].rate(slotRates[index]); 
    slotGains[index] => slots[index].gain;
    slots[index] =< recorder; 
}

fun void mixSamples(int target) {
    if(playbackOrder.size() == 0) { <<< "Nothing to mix" >>>; return; } 
    
    // Determine the longest file duration
    0::ms => dur totalDur; 
    for(0 => int i; i < playbackOrder.size(); i++) { 
        slots[playbackOrder[i]].loopEnd() => dur d;
        if(d > totalDur) d => totalDur; 
    } 
    
    // Prepare Target
    0 => slots[target].play; 
    0 => slots[target].loop0; 
    totalDur => slots[target].duration; 
    0.0 => adcGain.gain; 
    slots[target].record(1);
    0::ms => slots[target].recPos; 
    
    // Auto-Mix Volume (Decrease volume as layer count increases)
    1.0 / playbackOrder.size() => float mixGain; 
    if(mixGain > 0.8) 0.8 => mixGain;

    // Spawn threads for simultaneous playback
    for(0 => int i; i < playbackOrder.size(); i++) { 
        playbackOrder[i] => int s; 
        0 => slots[s].loop0;
        spork ~ tempMixPlay(s, slots[target], mixGain); 
    }
    
    totalDur => now; // Wait for longest file

    // Cleanup
    slots[target].record(0); 
    1.0 => adcGain.gain; 
    totalDur => slots[target].loopEnd; 
    totalDur => loopLength[target]; 
    10::ms => slots[target].rampDown; 
    1.0 => slotGains[target]; 
    1.0 => slots[target].gain; 
    playbackOrder.clear();
    <<< "Mix complete to Slot", target+1 >>>;
}


// =========================================================
// SYSTEM UTILITIES
// =========================================================

// Function: runClock
// ------------------
// Background thread for Metronome and Timing Events.
fun void runClock() { 
    while(true) { 
        beatTrigger.broadcast(); // Notify all listeners
        if(metronomeOn == 1) { 1.0 => click.next; } 
        60::second / BPM => now;
    } 
}

// Function: monitorMic
// --------------------
// Background thread to read mic level for the UI Visualizer.
fun void monitorMic() { 
    while(true) { 
        Math.fabs(adc.last()) => micLevel;
        100::ms => now; 
    } 
}

// Function: bufferLoaderLoop
// --------------------------
// Background thread waiting for file uploads from the Web Interface.
fun void bufferLoaderLoop() {
    while(true) {
        loadBufferTrigger => now; // Wait for JS event
        loadFromBuffer(targetSlot);
    }
}

// Function: loadFromBuffer
// ------------------------
// Transfers raw data from JS Array -> LiSa Memory
fun void loadFromBuffer(int index) {
    // Reset Slot
    0 => slots[index].play;
    0 => slots[index].record; 
    0 => isPlaying[index]; 
    0 => isRecording[index];

    if(loadBufferSize <= 0) { 
        <<< "Buffer empty!", "" >>>;
        return; 
    }

    // Write Buffer to Memory
    for(0 => int i; i < loadBufferSize; i++) {
        slots[index].valueAt(loadBuffer[i], i::samp);
    }

    // Silence the remaining tail of the buffer memory
    for(loadBufferSize => int i; i < (MAX_DUR/samp); i++) {
        slots[index].valueAt(0.0, i::samp);
    }

    // Reset Defaults
    0::ms => slots[index].playPos;
    0 => slots[index].loop0; 
    1.0 => slots[index].rate; 
    1.0 => slotRates[index]; 
    1.0 => slotGains[index]; 
    
    loadBufferSize::samp => dur rawDur;
    rawDur => loopLength[index];
    rawDur => slots[index].loopEnd;
    
    <<< "Loaded Buffer into Slot", index+1, "(", rawDur/second, "sec )" >>>;
}