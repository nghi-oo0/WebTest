# Keyboard Live Sampler

## 1. Introduction
**Keyboard Live Sampler** is a browser-based platform for real-time music performance and manipulation, built using **WebChucK**. Our inspiration is physical hardware samplers that give users the ability to record, edit, and perform audio directly on the keyboard.

The system includes a **smart recording engine** that automatically detects audio onsets, quantizes loops to a global tempo, and supports real-time transformations such as mixing, concatenation, reversing, pitch shifting, and applying reverb.

## 2. Core Functionality

### Performance
* **10-Slot Sample Bank:** Access 10 independent audio buffers (keys **1–0**), each capable of holding up to 10 seconds of audio.
* **Smart Recording:** When armed (key **R**), the system waits for an audio threshold before capturing, ensuring clean start points without silence at the beginning.
* **Auto-Quantization:** Recordings are automatically trimmed and snapped to the nearest musical beat based on the BPM. If a user records 3.8 beats, the system rounds it to 4.0 beats and inserts the necessary silence to maintain perfect rhythm.
* **Looping & Retriggering:** Users can toggle looping per slot or rapidly retrigger samples for stutter effects.

### Sound Manipulating & Editing
* **Effects:** Users can render effects permanently into new slots or create complex chains.
    * **Reverb**
    * **Reverse Playback**
    * **Pitch Shift:** Resamples audio up (+50%) or down (-25%).
* **Macro Modes:**
    * **Concatenate (Key F):** Sequencing multiple samples into a single slot.
    * **Mix (Key G):** Layers multiple samples on top of each other into a single slot.

### File Integration
* **Uploading & Playback:** Users can upload local audio files (MP3/WAV) and assign them into the live slots using the keys **Q-W-E-A-S-D**.

## 3. Technical Overview
The project follows a hybrid architecture, using **HTML/JavaScript** for the interface and **ChucK** for audio processing.

### Frontend (HTML/JS)
The visual interface manages user interactions, file decoding, and status indicators.

* **Bridge Architecture:** The `script.js` file initializes the WebChucK instance. It handles the `AudioContext` to decode uploaded files into raw PCM data (`Float32Array`) before sending them to the ChucK engine via the `loadBuffer` global array.

### Audio Engine (ChucK)
The core logic resides in `main.ck`:

* **Concurrency (Shreds):** The audio engine uses multiple concurrent shreds, such as:
    * `runClock()`: Maintains the global tempo.
    * `monitorMic()`: Analyzes input volume for visualization.
    * `bufferLoaderLoop()`: Receives sample data from JavaScript.
* **Memory Management (LiSa):** The project uses **LiSa** (Live Sampling) objects for audio manipulation. It is configured with feedback set to `0`, ensuring that new recordings completely replace old data (Tape Recorder behavior) rather than overdubbing.
* **Signal Flow:** Mic Input -> Gain -> LiSa (Sampler) -> Reverb -> Limiter -> Speakers
