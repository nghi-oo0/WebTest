import { Chuck } from 'https://cdn.jsdelivr.net/npm/webchuck/+esm';

// =========================================================
// CONFIGURATION
// =========================================================
const KEY_MAP = {
    UPLOAD_KEYS: [81, 87, 69, 65, 83, 68], // Q, W, E, A, S, D
    LABELS: ['Q', 'W', 'E', 'A', 'S', 'D']
};

// =========================================================
// DOM ELEMENTS
// =========================================================
const ui = {
    startBtn: document.getElementById('startBtn'),
    uploadBtn: document.getElementById('uploadBtn'),
    fileInput: document.getElementById('fileInput'),
    status: document.getElementById('status'),
    console: document.getElementById('console'),
    micLed: document.getElementById('micLed'),
    fileMapping: document.getElementById('fileMapping'),
    bpmInput: document.getElementById('bpmInput')
};

// =========================================================
// STATE
// =========================================================
let theChuck;
let audioContext;
let fileBuffers = {}; // Map<KeyCode, Float32Array>
let fileNames = {};   // Map<KeyCode, FileName>

// Logger
const log = (msg) => {
    ui.console.innerText += msg + "\n";
    ui.console.scrollTop = ui.console.scrollHeight;
};

// =========================================================
// MAIN INIT
// =========================================================
ui.startBtn.addEventListener('click', async () => {
    try {
        ui.status.innerText = "Status: Initializing Audio...";
        
        // 1. Get Mic Access
        const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
        
        // 2. Initialize WebChucK
        ui.status.innerText = "Status: Starting Engine...";
        theChuck = await Chuck.init([]);
        
        // 3. Connect Mic
        audioContext = new AudioContext(); // Helper context for decoding
        const chuckCtx = theChuck.context;
        const micSource = chuckCtx.createMediaStreamSource(stream);
        micSource.connect(theChuck);

        // 4. Hook up Logger
        theChuck.chuckPrint = log;

        // 5. Load Main Script
        ui.status.innerText = "Status: Loading main.ck...";
        const response = await fetch('./main.ck');
        if (!response.ok) throw new Error("main.ck not found");
        const chuckCode = await response.text();
        
        await theChuck.runCode(chuckCode);

        // 6. Finalize UI
        ui.status.innerText = "Status: RUNNING";
        ui.status.className = "status-bar status-success";
        ui.startBtn.disabled = true;
        ui.uploadBtn.disabled = false;

        // 7. Start Loops
        requestAnimationFrame(updateMicLed);
        setupKeyboard();

    } catch (e) {
        console.error(e);
        ui.status.innerText = "Error: " + e.message;
        ui.status.className = "status-bar status-error";
    }
});

// =========================================================
// FILE HANDLING
// =========================================================
ui.uploadBtn.addEventListener('click', () => ui.fileInput.click());

ui.fileInput.addEventListener('change', async (e) => {
    const files = Array.from(e.target.files);
    ui.fileMapping.innerText = ""; // Clear visual list

    for(let i = 0; i < files.length; i++) {
        if(i >= KEY_MAP.UPLOAD_KEYS.length) break;

        const file = files[i];
        const key = KEY_MAP.UPLOAD_KEYS[i];
        const label = KEY_MAP.LABELS[i];

        log(`[JS] Processing ${file.name}...`);

        try {
            // Decode Audio
            const arrayBuffer = await file.arrayBuffer();
            const audioBuffer = await audioContext.decodeAudioData(arrayBuffer);
            
            // Mix down to Mono
            const pcm = mixToMono(audioBuffer);

            // Store Data
            fileBuffers[key] = pcm;
            fileNames[key] = file.name;

            // Update UI
            addMappingBadge(label, file.name);
            log(`[JS] Mapped ${file.name} -> [${label}]`);

        } catch(err) {
            log(`[JS] Error: ${err.message}`);
        }
    }
});

function mixToMono(audioBuffer) {
    const channels = audioBuffer.numberOfChannels;
    const len = audioBuffer.length;
    const pcm = new Float32Array(len);
    const chan0 = audioBuffer.getChannelData(0);

    if (channels > 1) {
        const chan1 = audioBuffer.getChannelData(1);
        for(let s = 0; s < len; s++) {
            pcm[s] = (chan0[s] + chan1[s]) * 0.5;
        }
    } else {
        pcm.set(chan0);
    }
    return pcm;
}

function addMappingBadge(keyLabel, fileName) {
    const tag = document.createElement("span");
    tag.className = "map-item";
    tag.innerHTML = `<span class="key-badge">[${keyLabel}]</span> ${fileName}`;
    ui.fileMapping.appendChild(tag);
}

// =========================================================
// INPUT & BRIDGE
// =========================================================
function setupKeyboard() {
    window.addEventListener('keydown', (e) => {
        if (e.repeat) return;
        const code = e.keyCode;

        // Is this a file trigger key?
        if (fileBuffers[code]) {
            const pcmData = fileBuffers[code];
            log(`[JS] Uploading ${fileNames[code]} to Active Slot...`);
            
            // Send Data to ChucK
            theChuck.setFloatArray("loadBuffer", pcmData);
            theChuck.setInt("loadBufferSize", pcmData.length);
            theChuck.broadcastEvent("loadBufferTrigger");
        } 
        // Otherwise, pass key to ChucK logic
        else {
            theChuck.setInt("webKey", code);
            theChuck.broadcastEvent("webKeyEvent");
        }
    });

    ui.bpmInput.addEventListener('input', (e) => {
        const val = parseFloat(e.target.value);
        if(theChuck && val > 0) theChuck.setFloat("BPM", val);
    });
}

// Visualizer Loop
function updateMicLed() {
    if(!theChuck) return;
    theChuck.getFloat("micLevel").then((level) => {
        if (level > 0.06) ui.micLed.classList.add("mic-active");
        else ui.micLed.classList.remove("mic-active");
        requestAnimationFrame(updateMicLed);
    }).catch(() => {});
}