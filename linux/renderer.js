const api = window.obsTranscricao;
const $ = id => document.getElementById(id);
let ready = false;
function message(text, bad = false) { $('status').textContent = text; $('status').classList.toggle('bad', bad); }
function updateStart() { $('start').disabled = !ready || !$('file').value; }
async function refresh() { const state = await api.state(); ready = state.ffmpeg && state.whisper && state.model; $('components').textContent = `FFmpeg: ${state.ffmpeg ? 'pronto' : 'ausente'} · Whisper: ${state.whisper ? 'pronto' : 'ausente'} · Modelo: ${state.model ? 'pronto' : 'baixar'}`; updateStart(); }
$('choose').onclick = async () => { const file = await api.choose(); if (file) { $('file').value = file; updateStart(); } };
$('cpu').oninput = () => $('cpuValue').textContent = `${$('cpu').value}%`;
$('prepare').onclick = async () => { try { $('prepare').disabled = true; message('Preparando os componentes…'); await api.prepare(); message('Componentes prontos.'); await refresh(); } catch (error) { message(error.message, true); } finally { $('prepare').disabled = false; } };
$('installObs').onclick = async () => { try { const target = await api.installObs(); message(`Script instalado em ${target}. Adicione-o em Ferramentas > Scripts no OBS.`); } catch (error) { message(error.message, true); } };
$('start').onclick = async () => { try { $('start').disabled = true; $('cancel').disabled = false; $('results').replaceChildren(); $('log').textContent = ''; await api.start({ file: $('file').value, language: $('language').value, cpu: Number($('cpu').value), embed: $('embed').checked }); } catch (error) { message(error.message, true); } finally { $('cancel').disabled = true; updateStart(); } };
$('cancel').onclick = () => api.cancel();
api.onProgress(value => { message(`${value.label}: ${value.percent}%`); $('bar').style.width = `${value.percent}%`; });
api.onLog(value => { message(value.stage); $('log').textContent = ($('log').textContent + value.text).slice(-16000); $('log').scrollTop = $('log').scrollHeight; });
api.onState(value => { if (value.stage) message(value.stage); if (value.done) { message('Transcricao concluida.'); $('bar').style.width = '100%'; for (const target of [value.result.text, value.result.subtitle, value.result.embedded].filter(Boolean)) { const button = document.createElement('button'); button.className = 'secondary result'; button.textContent = target; button.onclick = () => api.open(target); $('results').append(button); } } });
api.onLaunch(value => { $('file').value = value.file; updateStart(); if (value.start) setTimeout(() => $('start').click(), 300); });
refresh().catch(error => message(error.message, true));
