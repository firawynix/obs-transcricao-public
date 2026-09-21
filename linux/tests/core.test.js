const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { validMedia, outputBase, whisperArgs, percentFromFfmpeg } = require('../core');

test('aceita somente extensoes de midia conhecidas', () => {
  assert.equal(validMedia('/tmp/reuniao.MP4'), true);
  assert.equal(validMedia('/tmp/arquivo.exe'), false);
});

test('mantem a saida ao lado da gravacao', () => {
  assert.equal(outputBase('/tmp/reuniao.mp4'), path.join('/tmp', 'reuniao'));
});

test('monta argumentos com idioma e VAD', () => {
  const args = whisperArgs({ model: 'm', vad: 'v', wav: 'a', output: 'o', language: 'pt', threads: 8 });
  assert.deepEqual(args.slice(0, 8), ['-m', 'm', '-f', 'a', '-of', 'o', '-otxt', '-osrt']);
  assert.ok(args.includes('--vad'));
  assert.ok(args.includes('pt'));
});

test('passa auto explicitamente para o whisper', () => {
  const args = whisperArgs({ model: 'm', vad: null, wav: 'a', output: 'o', language: 'auto', threads: 4 });
  assert.ok(args.includes('auto'));
});

test('interpreta o andamento do ffmpeg', () => {
  assert.equal(percentFromFfmpeg('frame=20 time=00:00:30.00 speed=2x', 120), 25);
  assert.equal(percentFromFfmpeg('sem tempo', 120), null);
});
