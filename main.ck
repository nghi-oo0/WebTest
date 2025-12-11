// =========================================================
        // LIVE SAMPLER - Robust Web Version
        // =========================================================

        // --- INTERFACE GLOBALS ---
        global int webKey;
        global Event webKeyEvent;
        global float micLevel;
        
        // --- DATA TRANSFER GLOBALS ---
        global float loadBuffer[0]; // Buffer for incoming JS file data
        global int loadBufferSize;  // Size of incoming data
        global Event loadBufferTrigger; 

        // --- MASTER OUTPUT ---
        Dyno dyno => dac;
        dyno.limit();

        // 1. CONFIGURATION
        10 => int NUM_SLOTS;            
        10::second => dur MAX_DUR;
        0.02 => float THRESHOLD;        
        50::ms => dur RELEASE_TIME;
        100.0 => float BPM;
        60::second / BPM => dur quarter;

        // 2. STATE
        int playbackOrder[0];           
        0 => int concatRunning;
        0 => int pendingEffect;         
        NRev slotRevs[NUM_SLOTS];
        LiSa slots[NUM_SLOTS];          
        Gain adcGain;
        0 => int targetSlot;            
        float slotRates[NUM_SLOTS];
        float slotGains[NUM_SLOTS];     
        int isRecording[NUM_SLOTS];     
        int isPending[NUM_SLOTS];
        int isPlaying[NUM_SLOTS];       
        time recStart[NUM_SLOTS];
        time lastHeard[NUM_SLOTS];      
        dur loopLength[NUM_SLOTS];
        Shred playShreds[NUM_SLOTS];    

        // 3. INITIALIZATION
        for(0 => int i; i < NUM_SLOTS; i++)
        {
            adc => adcGain;
            0.5 => adcGain.gain; // Mic Boost
            adcGain => slots[i] => slotRevs[i] => dyno;
            0.0 => slotRevs[i].mix; 
            MAX_DUR => slots[i].duration;
            slots[i].loop0(0);            
            slots[i].bi(0);
            0::ms => slots[i].rampUp;     
            10::ms => slots[i].rampDown;
            0 => slots[i].feedback;
            1.0 => slotRates[i];
            1.0 => slots[i].rate;
            1.0 => slotGains[i];
            1.0 => slots[i].gain;
        }

        // 4. THREADS
        Event beatTrigger;
        Impulse click => dyno; 0.1 => click.gain;
        1 => int metronomeOn;
        spork ~ runClock();
        spork ~ monitorMic();
        spork ~ bufferLoaderLoop(); // New thread for file loading

        <<< "--- LIVE SAMPLER READY ---", "" >>>;

        // =========================================================
        // DATA LOADER (Reads raw array from JS)
        // =========================================================
        fun void bufferLoaderLoop() {
            while(true) {
                loadBufferTrigger => now;
                loadFromBuffer(targetSlot);
            }
        }

        fun void loadFromBuffer(int index) {
            // Reset Slot
            0 => slots[index].play; 0 => slots[index].record; 
            0 => isPlaying[index]; 0 => isRecording[index];

            // Safety check
            if(loadBufferSize <= 0) { <<< "Buffer empty!", "" >>>; return; }

            // Write to LiSa
            for(0 => int i; i < loadBufferSize; i++) {
                // Read from global array, write to LiSa
                slots[index].valueAt(loadBuffer[i], i::samp);
            }

            // Clear tail (silence rest of buffer)
            for(loadBufferSize => int i; i < (MAX_DUR/samp); i++) {
                slots[index].valueAt(0.0, i::samp);
            }

            // Reset Params
            0::ms => slots[index].playPos; 0 => slots[index].loop0; 
            1.0 => slots[index].rate; 1.0 => slotRates[index]; 1.0 => slotGains[index]; 
            
            loadBufferSize::samp => dur rawDur;
            rawDur => loopLength[index];
            rawDur => slots[index].loopEnd;
            
            <<< "Loaded Buffer into Slot", index+1, "(", rawDur/second, "sec )" >>>;
        }

        // =========================================================
        // MAIN CONTROL LOOP
        // =========================================================
        while(true)
        {
            webKeyEvent => now; 
            webKey => int c;

            // [1-0] Slot Trigger
            if(c >= 48 && c <= 57) {
                c - 48 => int keyIndex;
                if(keyIndex == 0) 10 => keyIndex; keyIndex - 1 => keyIndex;
                if(pendingEffect > 0) { spork ~ renderEffect(keyIndex, targetSlot, pendingEffect); 0 => pendingEffect; }
                else if(concatRunning == 1) { playbackOrder << keyIndex; spork ~ syncPlay(keyIndex); <<< "Added Slot", keyIndex+1, "to sequence" >>>; }
                else { handlePlayback(keyIndex); }
            }
            
            // [M] Metronome
            if(c == 77) {
                if(metronomeOn == 1) { 0 => metronomeOn; <<< "Metronome: MUTED" >>>; }
                else { 1 => metronomeOn; <<< "Metronome: ON" >>>; }
            }
            
            // [-/=] Select Slot
            if(c == 45 || c == 189) {
                targetSlot--; if(targetSlot < 0) 9 => targetSlot; 
                <<< "Selected Slot:", targetSlot+1, "| Vol:", slotGains[targetSlot] >>>; 0 => pendingEffect;
            }
            if(c == 61 || c == 187) {
                targetSlot++; if(targetSlot > 9) 0 => targetSlot; 
                <<< "Selected Slot:", targetSlot+1, "| Vol:", slotGains[targetSlot] >>>; 0 => pendingEffect;
            }

            // [[/]] Volume
            if(c == 91 || c == 219) {
                slotGains[targetSlot] - 0.1 => slotGains[targetSlot]; if(slotGains[targetSlot] < 0) 0 => slotGains[targetSlot];
                slotGains[targetSlot] => slots[targetSlot].gain; <<< "Slot", targetSlot+1, "Volume:", slotGains[targetSlot] >>>;
            }
            if(c == 93 || c == 221) {
                slotGains[targetSlot] + 0.1 => slotGains[targetSlot]; if(slotGains[targetSlot] > 2.0) 2.0 => slotGains[targetSlot];
                slotGains[targetSlot] => slots[targetSlot].gain; <<< "Slot", targetSlot+1, "Volume:", slotGains[targetSlot] >>>;
            }

            // [R] Record
            if(c == 82) {
                if(concatRunning == 0) {
                    if(isRecording[targetSlot] == 0 && isPending[targetSlot] == 0) {
                        1 => isPending[targetSlot]; 0 => slots[targetSlot].play; 0 => isPlaying[targetSlot];
                        spork ~ waitAndRecord(targetSlot);
                        <<< "Slot [" + (targetSlot+1) + "] ARMED...", "" >>>;
                    } else if(isRecording[targetSlot] == 1) { stopRecording(targetSlot); }
                } else { <<< "Cannot mic record during Concat/Mix mode!" >>>; }
            }

            // [Z,X,C,V] FX
            if(c == 90) { 1 => pendingEffect; <<< "[Z] REVERB ARMED" >>>; }
            if(c == 88) { 2 => pendingEffect; <<< "[X] REVERSE ARMED" >>>; }
            if(c == 67) { 3 => pendingEffect; <<< "[C] PITCH UP ARMED" >>>; }
            if(c == 86) { 4 => pendingEffect; <<< "[V] PITCH DOWN ARMED" >>>; }

            // [F/G] Macros
            if(c == 70) {
                if(concatRunning == 0) { 1 => concatRunning; playbackOrder.clear(); <<< "Concatenate ON. Play sequence. Press F to Render." >>>; spork ~ concatManager(); }
                else { 0 => concatRunning; } 
            }
            if(c == 71) {
                if(concatRunning == 0) { 1 => concatRunning; playbackOrder.clear(); <<< "Mix Mode ON. Play layers. Press G to Render." >>>; spork ~ mixManager(); }
                else { 0 => concatRunning; }
            }

            // [L] Loop
            if(c == 76) {
                if(slots[targetSlot].loop0() == 0) { 1 => slots[targetSlot].loop0; <<< "Loop: ON" >>>; }
                else { 0 => slots[targetSlot].loop0; <<< "Loop: OFF" >>>; }
            }

            // [Space] Panic
            if(c == 32) {
                for(0 => int i; i < NUM_SLOTS; i++) { 0 => slots[i].play; 0 => slots[i].record; 0 => isPlaying[i]; 0 => isRecording[i]; 0 => isPending[i]; }
                0 => pendingEffect; 0 => concatRunning; <<< "!!! ALL STOP !!!", "" >>>;
            }
        }

        // =========================================================
        // LOGIC UTILS
        // =========================================================
        fun void handlePlayback(int index) {
            if(isRecording[index] == 0 && isPending[index] == 0) {
                if(isPlaying[index] == 1) {
                    playShreds[index].exit(); slotRates[index] => slots[index].rate;
                    if(slotRates[index] < 0) slots[index].loopEnd() => slots[index].playPos; else 0::ms => slots[index].playPos;
                    1 => slots[index].play; spork ~ waitAndStop(index) @=> playShreds[index]; <<< "Slot", index+1, " -> RETRIGGER" >>>;
                } else { 1 => isPlaying[index]; spork ~ syncPlay(index) @=> playShreds[index]; <<< "Slot", index+1, " -> QUEUED" >>>; }
            }
        }
        fun void stopRecording(int index) {
            adcGain =< slots[index]; 0 => isRecording[index]; 
            now - recStart[index] => dur validAudio;
            validAudio / quarter => float rawBeats; Math.ceil(rawBeats) => float snappedBeats; if(snappedBeats < 1) 1 => snappedBeats;
            snappedBeats * quarter => dur quantLength; quantLength - validAudio => dur gapToFill;
            if(gapToFill > 0::ms) { spork ~ finalizeLoop(index, gapToFill, quantLength); } else { finalizeLoop(index, 0::ms, quantLength); }
        }
        fun void finalizeLoop(int index, dur waitTime, dur finalLength) {
            waitTime => now; 0 => slots[index].record; finalLength => loopLength[index]; loopLength[index] => slots[index].loopEnd;
            1.0 => slotRates[index]; 1.0 => slotGains[index]; 1.0 => slots[index].gain; adcGain => slots[index]; 
            <<< "Recorded Slot", index+1, "(", finalLength/quarter, "beats )" >>>;
        }
        fun void runClock() { while(true) { beatTrigger.broadcast(); if(metronomeOn == 1) { 1.0 => click.next; } quarter => now; } }
        fun void monitorMic() { while(true) { Math.fabs(adc.last()) => micLevel; 100::ms => now; } }
        fun void syncPlay(int index) { beatTrigger => now; slotRates[index] => slots[index].rate; if(slotRates[index] < 0) slots[index].loopEnd() => slots[index].playPos; else 0::ms => slots[index].playPos; 1 => slots[index].play; waitAndStop(index); }
        fun void waitAndStop(int index) {
            slotRates[index] => float currentRate; Math.fabs(currentRate) => float absRate; if(absRate < 0.01) 1.0 => absRate;
            slots[index].loopEnd() / absRate => dur playTime;
            while(isPlaying[index] == 1) { playTime => now; if(isPlaying[index] == 0) break; if(slots[index].loop0() == 0) { 0 => isPlaying[index]; 0 => slots[index].play; break; } if(slotRates[index] < 0) slots[index].loopEnd() => slots[index].playPos; else 0::ms => slots[index].playPos; }
        }
        fun void waitAndRecord(int index) {
            while(isPending[index] == 1) {
                if(Math.fabs(adc.last()) > THRESHOLD) {
                    0 => isPending[index]; 1 => isRecording[index]; 0::ms => slots[index].recPos; now => recStart[index]; now => lastHeard[index]; 0::ms => slots[index].playPos; 1 => slots[index].record;
                    <<< "Ref [" + (index+1) + "] *** REC START ***", "" >>>;
                } 1::samp => now;
            }
            while(isRecording[index] == 1) { if(Math.fabs(adc.last()) > THRESHOLD / 2) { now => lastHeard[index]; } 1::ms => now; }
        }
        fun void renderEffect(int srcIndex, int destIndex, int type) {
            if(slots[srcIndex].loopEnd() <= 0::ms) { <<< "Error: Source Empty!", "" >>>; return; } 0.0 => adcGain.gain; MAX_DUR => slots[destIndex].duration; slots[destIndex].play(0); slots[destIndex].record(1); 0::ms => slots[destIndex].recPos; slots[srcIndex].rate(1.0); 0::ms => slots[srcIndex].playPos; slots[srcIndex].loopEnd() => dur srcDur; dur renderDur;
            if(type == 1) { 0.2 => slotRevs[srcIndex].mix; slotRevs[srcIndex] => slots[destIndex]; slots[srcIndex].play(1); srcDur + RELEASE_TIME => now; srcDur + RELEASE_TIME => renderDur; slots[srcIndex].play(0); slotRevs[srcIndex] =< slots[destIndex]; 0.0 => slotRevs[srcIndex].mix; }
            else if(type == 2) { slots[srcIndex] => slots[destIndex]; -1.0 => slots[srcIndex].rate; slots[srcIndex].loopEnd() => slots[srcIndex].playPos; slots[srcIndex].play(1); srcDur => now; srcDur => renderDur; slots[srcIndex].play(0); slots[srcIndex] =< slots[destIndex]; 1.0 => slots[srcIndex].rate; }
            else if(type == 3) { slots[srcIndex] => slots[destIndex]; 1.5 => slots[srcIndex].rate; slots[srcIndex].play(1); srcDur / 1.5 => now; srcDur / 1.5 => renderDur; slots[srcIndex].play(0); slots[srcIndex] =< slots[destIndex]; 1.0 => slots[srcIndex].rate; }
            else if(type == 4) { slots[srcIndex] => slots[destIndex]; 0.75 => slots[srcIndex].rate; slots[srcIndex].play(1); srcDur / 0.75 => now; srcDur / 0.75 => renderDur; slots[srcIndex].play(0); slots[srcIndex] =< slots[destIndex]; 1.0 => slots[srcIndex].rate; }
            slots[destIndex].record(0); renderDur => slots[destIndex].loopEnd; renderDur => loopLength[destIndex]; 1.0 => slots[destIndex].rate; 1.0 => slotRates[destIndex]; 1.0 => slotGains[destIndex]; 1.0 => slots[destIndex].gain; 1.0 => adcGain.gain; <<< "RENDER COMPLETE into Slot", destIndex+1 >>>;
        }
        fun void concatManager() { while(concatRunning == 1) { 100::ms => now; } concatenateSamples(targetSlot); }
        fun void concatenateSamples(int target) {
            if(playbackOrder.size() == 0) { <<< "Nothing to concatenate" >>>; return; } 0::ms => dur totalDur; for(0 => int i; i < playbackOrder.size(); i++) { slots[playbackOrder[i]].loopEnd() + totalDur => totalDur; } 0 => slots[target].play; 0 => slots[target].loop0; totalDur => slots[target].duration; 0.0 => adcGain.gain; slots[target].record(1); 0::ms => slots[target].recPos;
            for(0 => int i; i < playbackOrder.size(); i++) { playbackOrder[i] => int s; slots[s].loopEnd() => dur d; 0 => slots[s].loop0; slots[s].rate(1.0); 0::ms => slots[s].playPos; slotGains[s] => slots[s].gain; slots[s] => slots[target]; slots[s].play(1); d => now; slots[s].play(0); slots[s] =< slots[target]; slots[s].rate(slotRates[s]); }
            slots[target].record(0); 1.0 => adcGain.gain; totalDur => slots[target].loopEnd; totalDur => loopLength[target]; 10::ms => slots[target].rampDown; 1.0 => slotGains[target]; 1.0 => slots[target].gain; playbackOrder.clear(); <<< "Concatenation complete to Slot", target+1 >>>;
        }
        fun void mixManager() { while(concatRunning == 1) { 100::ms => now; } mixSamples(targetSlot); }
        fun void tempMixPlay(int index, LiSa recorder, float safetyGain) { slots[index] => recorder; safetyGain * slotGains[index] => slots[index].gain; slots[index].rate(1.0); 0::ms => slots[index].playPos; slots[index].play(1); slots[index].loopEnd() => now; slots[index].play(0); slots[index].rate(slotRates[index]); slotGains[index] => slots[index].gain; slots[index] =< recorder; }
        fun void mixSamples(int target) {
            if(playbackOrder.size() == 0) { <<< "Nothing to mix" >>>; return; } 0::ms => dur totalDur; for(0 => int i; i < playbackOrder.size(); i++) { slots[playbackOrder[i]].loopEnd() => dur d; if(d > totalDur) d => totalDur; } 0 => slots[target].play; 0 => slots[target].loop0; totalDur => slots[target].duration; 0.0 => adcGain.gain; slots[target].record(1); 0::ms => slots[target].recPos; 1.0 / playbackOrder.size() => float mixGain; if(mixGain > 0.8) 0.8 => mixGain; for(0 => int i; i < playbackOrder.size(); i++) { playbackOrder[i] => int s; 0 => slots[s].loop0; spork ~ tempMixPlay(s, slots[target], mixGain); }
            totalDur => now; slots[target].record(0); 1.0 => adcGain.gain; totalDur => slots[target].loopEnd; totalDur => loopLength[target]; 10::ms => slots[target].rampDown; 1.0 => slotGains[target]; 1.0 => slots[target].gain; playbackOrder.clear(); <<< "Mix complete to Slot", target+1 >>>;
        }