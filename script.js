import { Chuck } from 'https://cdn.jsdelivr.net/npm/webchuck/+esm';

// =========================================================
// DOM ELEMENTS
// =========================================================
const startBtn = document.getElementById('startBtn');
const uploadBtn = document.getElementById('uploadBtn');
const fileInput = document.getElementById('fileInput');
const statusDiv = document.getElementById('status');
const consoleDiv = document.getElementById('console');
const micLed = document.getElementById('micLed');
const fileMappingDiv = document.getElementById('fileMapping');
const bpmInput = document.getElementById('bpmInput');

// =========================================================
// STATE VARIABLES
// =========================================================
let theChuck; 
let audioContext;       // For decoding files
let fileBuffers = {};   // Stores decoded PCM data: { 81: Float32Array, ... }
let fileNames = {};     // Stores filenames: { 81: "kick.wav", ... }

// Helper: Print to custom console div
var print = function(msg) {
    consoleDiv.innerText += msg + "\n";
    consoleDiv.scrollTop = consoleDiv.scrollHeight;
};

// Helper: Visualizer
function updateMicLed() {
    if(!theChuck) return;
    theChuck.getFloat("micLevel").then((level) => {
        if (level > 0.005) micLed.classList.add("mic-active");
        else micLed.classList.remove("mic-active");
        requestAnimationFrame(updateMicLed);
    }).catch(() => {});
}

// =========================================================
// 1. START ENGINE
// =========================================================
startBtn.addEventListener('click', async () => {
    try {
        statusDiv.innerText = "Status: Requesting Microphone...";
        const stream = await navigator.mediaDevices.getUserMedia({ audio: true });

        statusDiv.innerText = "Status: Initializing WebChucK...";
        theChuck = await Chuck.init([]); 
        
        // Get Audio Context
        audioContext = new AudioContext();
        const chuckCtx = theChuck.context;
        const micSource = chuckCtx.createMediaStreamSource(stream);
        micSource.connect(theChuck);

        theChuck.chuckPrint = print;

        // Fetch code from file
        statusDiv.innerText = "Status: Fetching main.ck...";
        const response = await fetch('./main.ck');
        if (!response.ok) throw new Error("Could not fetch main.ck");
        const chuckCode = await response.text();

        await theChuck.runCode(chuckCode);
        
        statusDiv.innerText = "Status: RUNNING";
        statusDiv.style.color = "#0f0";
        startBtn.disabled = true;
        uploadBtn.disabled = false;

        updateMicLed();
        setupKeyboard();

    } catch (e) {
        console.error(e);
        statusDiv.innerText = "Error: " + e.message;
        statusDiv.style.color = "#f00";
    }
});

// =========================================================
// 2. FILE UPLOAD & DECODE
// =========================================================
uploadBtn.addEventListener('click', () => fileInput.click());

fileInput.addEventListener('change', async (e) => {
    const files = Array.from(e.target.files);
    const keys = [81, 87, 69, 65, 83, 68]; // Q, W, E, A, S, D
    const keyNames = ['Q', 'W', 'E', 'A', 'S', 'D'];
    
    fileMappingDiv.innerHTML = "";

    for(let i=0; i<files.length; i++) {
        if(i >= keys.length) break;
        
        const file = files[i];
        const key = keys[i];
        
        print(`[JS] Decoding ${file.name}...`);

        try {
            const arrayBuffer = await file.arrayBuffer();
            const audioBuffer = await audioContext.decodeAudioData(arrayBuffer);
            
            // Mix to Mono
            const channels = audioBuffer.numberOfChannels;
            const len = audioBuffer.length;
            const pcm = new Float32Array(len);
            
            const chan0 = audioBuffer.getChannelData(0);
            if (channels > 1) {
                const chan1 = audioBuffer.getChannelData(1);
                for(let s=0; s<len; s++) {
                    pcm[s] = (chan0[s] + chan1[s]) * 0.5;
                }
            } else {
                pcm.set(chan0);
            }

            fileBuffers[key] = pcm;
            fileNames[key] = file.name;

            const tag = document.createElement("span");
            tag.className = "map-item";
            tag.innerHTML = `<span class="key-badge">[${keyNames[i]}]</span> ${file.name}`;
            fileMappingDiv.appendChild(tag);
            
            print(`[JS] Ready: ${file.name} mapped to [${keyNames[i]}]`);
        } catch(err) {
            print(`[JS] Error decoding ${file.name}: ${err.message}`);
        }
    }
});

// =========================================================
// 3. KEYBOARD HANDLING
// =========================================================
function setupKeyboard() {
    window.addEventListener('keydown', (e) => {
        if (e.repeat) return; 
        let code = e.keyCode; 

        if (fileBuffers[code]) {
            const pcmData = fileBuffers[code];
            print(`[JS] Transferring ${fileNames[code]} to ChucK...`);
            
            theChuck.setFloatArray("loadBuffer", pcmData);
            theChuck.setInt("loadBufferSize", pcmData.length);
            theChuck.broadcastEvent("loadBufferTrigger");
        } else {
            theChuck.setInt("webKey", code);
            theChuck.broadcastEvent("webKeyEvent");
        }
    });
    bpmInput.addEventListener('input', (e) => {
        const newBpm = parseFloat(e.target.value);
        if(theChuck && newBpm > 0) {
            theChuck.setFloat("BPM", newBpm);
        }
    });
}