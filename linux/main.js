const { app, BrowserWindow, dialog, ipcMain, shell } = require('electron');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const https = require('node:https');
const { spawn, spawnSync } = require('node:child_process');
const { validMedia, outputBase, whisperArgs } = require('./core');

app.setDesktopName('br.com.firawynix.obstranscricao.desktop');
const MODEL_URL = 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin';
const VAD_URL = 'https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin';
let win;
let activeProcess;
let cancelled = false;

const resources = () => app.isPackaged ? process.resourcesPath : __dirname;
const dataDir = () => path.join(app.getPath('userData'), 'modelos');
const modelPath = () => path.join(dataDir(), 'ggml-large-v3-turbo.bin');
const vadPath = () => path.join(dataDir(), 'ggml-silero-v5.1.2.bin');
const vendor = name => path.join(resources(), 'vendor', name);

function executable(name) {
  const bundled = vendor(name);
  if (fs.existsSync(bundled)) return bundled;
  const found = spawnSync('sh', ['-lc', `command -v ${name}`], { encoding: 'utf8' });
  return found.status === 0 ? found.stdout.trim() : null;
}

function emit(channel, payload) {
  if (win && !win.isDestroyed()) win.webContents.send(channel, payload);
}

function run(command, args, stage) {
  return new Promise((resolve, reject) => {
    emit('job:log', { stage, text: `${stage} iniciado.` });
    const child = spawn(command, args, { windowsHide: true });
    activeProcess = child;
    child.stdout.on('data', chunk => emit('job:log', { stage, text: chunk.toString() }));
    child.stderr.on('data', chunk => emit('job:log', { stage, text: chunk.toString() }));
    child.once('error', reject);
    child.once('exit', code => {
      if (activeProcess === child) activeProcess = null;
      if (cancelled) reject(new Error('Transcricao cancelada.'));
      else if (code === 0) resolve();
      else reject(new Error(`${stage} terminou com codigo ${code}.`));
    });
  });
}

function download(url, destination, label) {
  return new Promise(async (resolve, reject) => {
    await fsp.mkdir(path.dirname(destination), { recursive: true });
    const partial = `${destination}.part`;
    const request = current => https.get(current, response => {
      if ([301, 302, 303, 307, 308].includes(response.statusCode)) {
        response.resume();
        return request(new URL(response.headers.location, current).toString());
      }
      if (response.statusCode !== 200) return reject(new Error(`Download de ${label}: HTTP ${response.statusCode}`));
      const total = Number(response.headers['content-length'] || 0);
      let received = 0;
      const output = fs.createWriteStream(partial);
      response.on('data', chunk => {
        received += chunk.length;
        if (total) emit('setup:progress', { label, percent: Math.round(received / total * 100) });
      });
      response.pipe(output);
      output.on('finish', async () => {
        output.close();
        await fsp.rename(partial, destination);
        resolve();
      });
      output.on('error', reject);
    }).on('error', reject);
    request(url);
  });
}

async function prepare() {
  const missing = ['ffmpeg', 'ffprobe', 'whisper-cli'].filter(name => !executable(name));
  if (missing.length) throw new Error(`Componentes ausentes no pacote: ${missing.join(', ')}.`);
  const modelOk = fs.existsSync(modelPath()) && fs.statSync(modelPath()).size > 1_500_000_000;
  const vadOk = fs.existsSync(vadPath()) && fs.statSync(vadPath()).size > 800_000;
  if (!modelOk) await download(MODEL_URL, modelPath(), 'Modelo Whisper');
  if (!vadOk) await download(VAD_URL, vadPath(), 'Detector de voz');
  return { ready: true, model: modelPath() };
}

async function transcribe(options) {
  if (!validMedia(options.file) || !fs.existsSync(options.file)) throw new Error('Escolha um video ou audio valido.');
  await prepare();
  cancelled = false;
  const ffmpeg = executable('ffmpeg');
  const whisper = executable('whisper-cli');
  const tempDir = await fsp.mkdtemp(path.join(os.tmpdir(), 'firaw-obs-'));
  const wav = path.join(tempDir, 'audio.wav');
  const output = outputBase(options.file);
  try {
    emit('job:state', { running: true, stage: 'Extraindo audio' });
    await run(ffmpeg, ['-y', '-i', options.file, '-vn', '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le', wav], 'Extracao de audio');
    emit('job:state', { running: true, stage: 'Transcrevendo localmente' });
    const threads = Math.max(1, Math.round(os.cpus().length * Math.max(20, Math.min(95, Number(options.cpu || 70))) / 100));
    await run(whisper, whisperArgs({ model: modelPath(), vad: vadPath(), wav, output, language: options.language, threads }), 'Whisper');
    let embedded = null;
    if (options.embed && /\.(mp4|mov)$/i.test(options.file)) {
      embedded = `${output} (com legenda)${path.extname(options.file)}`;
      emit('job:state', { running: true, stage: 'Embutindo legenda' });
      await run(ffmpeg, ['-y', '-i', options.file, '-i', `${output}.srt`, '-map', '0:v?', '-map', '0:a?', '-map', '1:0', '-c:v', 'copy', '-c:a', 'copy', '-c:s', 'mov_text', '-metadata:s:s:0', `language=${options.language === 'en' ? 'eng' : options.language === 'es' ? 'spa' : 'por'}`, '-disposition:s:0', 'default', embedded], 'Legenda');
    }
    const result = { text: `${output}.txt`, subtitle: `${output}.srt`, embedded };
    emit('job:state', { running: false, done: true, result });
    return result;
  } finally {
    await fsp.rm(tempDir, { recursive: true, force: true });
  }
}

async function installObsIntegration() {
  const appImage = process.env.APPIMAGE || process.execPath;
  const configDir = path.join(os.homedir(), '.config', 'firawynix', 'obs-transcricao');
  const scriptsDir = path.join(os.homedir(), '.config', 'obs-studio', 'scripts');
  await fsp.mkdir(configDir, { recursive: true });
  await fsp.mkdir(scriptsDir, { recursive: true });
  await fsp.writeFile(path.join(configDir, 'appimage-path'), appImage, 'utf8');
  await fsp.copyFile(path.join(resources(), 'obs-transcrever-linux.lua'), path.join(scriptsDir, 'firaw-obs-transcricao.lua'));
  return path.join(scriptsDir, 'firaw-obs-transcricao.lua');
}

function createWindow() {
  win = new BrowserWindow({ width: 980, height: 720, minWidth: 760, minHeight: 560, title: 'Firaw OBS Transcricao', backgroundColor: '#071116', autoHideMenuBar: true, webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, sandbox: true } });
  win.loadFile('index.html');
  win.webContents.once('did-finish-load', () => {
    const media = process.argv.find(validMedia);
    if (media) emit('launch:file', { file: path.resolve(media), start: process.argv.includes('--start') });
  });
}

ipcMain.handle('media:choose', async () => {
  const result = await dialog.showOpenDialog(win, { title: 'Escolha a gravacao', properties: ['openFile'], filters: [{ name: 'Videos e audios', extensions: ['mp4', 'mkv', 'mov', 'avi', 'webm', 'm4a', 'mp3', 'wav'] }] });
  return result.canceled ? null : result.filePaths[0];
});
ipcMain.handle('setup:prepare', () => prepare());
ipcMain.handle('job:start', (_event, options) => transcribe(options));
ipcMain.handle('job:cancel', () => { cancelled = true; if (activeProcess) activeProcess.kill('SIGTERM'); return true; });
ipcMain.handle('obs:install', () => installObsIntegration());
ipcMain.handle('path:open', (_event, target) => shell.openPath(path.dirname(target)));
ipcMain.handle('setup:state', () => ({ ffmpeg: Boolean(executable('ffmpeg')), whisper: Boolean(executable('whisper-cli')), model: fs.existsSync(modelPath()) && fs.statSync(modelPath()).size > 1_500_000_000 }));

app.whenReady().then(createWindow);
app.on('window-all-closed', () => app.quit());
