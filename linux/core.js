const path = require('node:path');

const VIDEO_EXTENSIONS = new Set(['.mp4', '.mkv', '.mov', '.avi', '.webm', '.m4a', '.mp3', '.wav']);

function validMedia(file) {
  return typeof file === 'string' && VIDEO_EXTENSIONS.has(path.extname(file).toLowerCase());
}

function outputBase(file) {
  const parsed = path.parse(file);
  return path.join(parsed.dir, parsed.name);
}

function whisperArgs({ model, vad, wav, output, language, threads }) {
  const args = ['-m', model, '-f', wav, '-of', output, '-otxt', '-osrt', '-t', String(threads)];
  if (language) args.push('-l', language);
  if (vad) args.push('-vm', vad, '--vad');
  return args;
}

function percentFromFfmpeg(line, durationSeconds) {
  const match = /time=(\d+):(\d+):(\d+(?:\.\d+)?)/.exec(line || '');
  if (!match || !durationSeconds) return null;
  const elapsed = Number(match[1]) * 3600 + Number(match[2]) * 60 + Number(match[3]);
  return Math.max(0, Math.min(100, Math.round(elapsed / durationSeconds * 100)));
}

module.exports = { validMedia, outputBase, whisperArgs, percentFromFfmpeg };
