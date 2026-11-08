'use strict';

const video = document.getElementById('phone');
const canvas = document.createElement('canvas');
const painter = canvas.getContext('2d', { alpha: false });
let sdk;
let videoTimer;
let videoTrack;
let encodingFrame = false;
let lastVideoFrame = 0;
let audioContext;
let audioNode;
let audioTrack;

function send(kind, data = '', rate = 0) {
    window.webkit.messageHandlers.takeRecPhone.postMessage({ kind, data, rate });
}

function readFrame() {
    if (encodingFrame || !videoTrack || videoTrack.muted || videoTrack.readyState !== 'live' ||
        video.readyState < 2 || !video.videoWidth) return;
    const now = performance.now();
    if (now - lastVideoFrame < 50) return;
    lastVideoFrame = now;
    const scale = Math.min(1, 1920 / Math.max(video.videoWidth, video.videoHeight));
    const width = Math.max(2, Math.round(video.videoWidth * scale));
    const height = Math.max(2, Math.round(video.videoHeight * scale));
    if (canvas.width !== width || canvas.height !== height) {
        canvas.width = width;
        canvas.height = height;
    }
    painter.drawImage(video, 0, 0, width, height);
    const track = videoTrack;
    encodingFrame = true;
    canvas.toBlob(blob => {
        if (!blob || blob.size > 1800000) {
            encodingFrame = false;
            return;
        }
        const reader = new FileReader();
        reader.onloadend = () => {
            encodingFrame = false;
            if (track === videoTrack && typeof reader.result === 'string') {
                send('video', reader.result.split(',', 2)[1]);
            }
        };
        reader.readAsDataURL(blob);
    }, 'image/jpeg', 0.87);
}

async function receiveTrack(track) {
    if (track.kind === 'video') {
        if (videoTrack === track) return;
        videoTrack = track;
        video.srcObject = new MediaStream([track]);
        video.muted = true;
        try { await video.play(); } catch (_) { send('videoError'); }
        if (videoTrack === track && !videoTimer) videoTimer = setInterval(readFrame, 55);
        return;
    }

    if (track.kind !== 'audio' || audioTrack === track) return;
    audioTrack = track;
    const previous = audioContext;
    const context = new AudioContext({ sampleRate: 48000 });
    audioContext = context;
    if (previous) previous.close().catch(() => {});
    try {
        // WebKit restricts worklet script loading from a local app bundle. The audio callback
        // processes the received track into short PCM packets and leaves its playback output silent.
        audioNode = context.createScriptProcessor(1024, 1, 1);
        audioNode.onaudioprocess = event => {
            if (audioTrack !== track || track.muted || track.readyState !== 'live') return;
            const samples = event.inputBuffer.getChannelData(0);
            const pcm = new Int16Array(samples.length);
            for (let i = 0; i < samples.length; i++) {
                const value = Math.max(-1, Math.min(1, samples[i]));
                pcm[i] = Math.round(value * (value < 0 ? 32768 : 32767));
            }
            const bytes = new Uint8Array(pcm.buffer);
            send('audio', btoa(String.fromCharCode(...bytes)), context.sampleRate);
            readFrame();
        };
        context.createMediaStreamSource(new MediaStream([track])).connect(audioNode);
        // The worklet leaves its output silent. The received voice goes to the app's microphone track.
        audioNode.connect(context.destination);
        await context.resume();
    } catch (_) {
        if (audioContext === context) send('audioError');
    }
}

async function startTakeRec(streamID, password) {
    stopTakeRec();
    if (typeof VDONinjaSDK === 'undefined') {
        send('error');
        return;
    }
    const connection = new VDONinjaSDK({ password, salt: 'vdo.ninja', autoRecover: true });
    sdk = connection;
    connection.addEventListener('track', event => {
        if (sdk === connection) receiveTrack(event.detail.track).catch(() => send('error'));
    });
    try {
        await connection.connect();
        if (sdk !== connection) return;
        send('waiting');
        while (sdk === connection) {
            if (await connection.view(streamID, { video: true, audio: true, videoBitrate: 6000 })) break;
        }
    } catch (_) {
        if (sdk === connection) send('error');
    }
}

function stopTakeRec() {
    const previous = sdk;
    sdk = undefined;
    if (previous) previous.disconnect();
    clearInterval(videoTimer);
    videoTimer = undefined;
    videoTrack = undefined;
    video.srcObject = null;
    audioTrack = undefined;
    if (audioNode) audioNode.onaudioprocess = null;
    audioNode = undefined;
    if (audioContext) audioContext.close().catch(() => {});
    audioContext = undefined;
}

window.addEventListener('pagehide', stopTakeRec);
