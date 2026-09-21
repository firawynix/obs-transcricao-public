const steps = [
  {n:'01',title:'Grave normalmente no OBS',text:'Quando a gravação termina, o fluxo começa sozinho. Você também pode escolher qualquer vídeo ou áudio pelo atalho.',points:['+ Disparo automático ou manual','+ Vídeo original sempre preservado','+ MP4, MKV, MOV, AVI, áudio e mais'],active:0},
  {n:'02',title:'Cadastre todos os trechos',text:'Escolha de 1 a 99 trechos e informe um início e um final diferentes para cada linha. Digite apenas os números: os dois-pontos entram sozinhos.',points:['+ 001000 vira 00:10:00','+ Até 99 intervalos independentes','+ Pausa e continuação a qualquer momento'],active:1},
  {n:'03',title:'Veja quem falou cada trecho',text:'O OCR local lê o nome destacado na reunião e cruza a imagem com os tempos da transcrição e da faixa do microfone.',points:['+ Teams e Google Meet','+ Chamada 1:1 com tela compartilhada','+ Tudo analisado localmente'],active:1},
  {n:'04',title:'Receba arquivos que já funcionam',text:'O texto, a legenda e o relatório por pessoa aparecem ao lado do vídeo. A legenda também pode ser embutida sem recodificar.',points:['+ Texto em UTF-8','+ Legenda SRT carregada automaticamente','+ Vídeo preservado, sem perda de qualidade'],active:2}
];

const tabs = [...document.querySelectorAll('[data-step]')];
const number = document.querySelector('#step-number');
const title = document.querySelector('#step-title');
const text = document.querySelector('#step-text');
const points = document.querySelector('#step-points');
const nodes = [...document.querySelectorAll('.flow-node')];

tabs.forEach(tab => tab.addEventListener('click', () => {
  const step = steps[Number(tab.dataset.step)];
  tabs.forEach(item => item.setAttribute('aria-selected', String(item === tab)));
  number.textContent = step.n;
  title.textContent = step.title;
  text.textContent = step.text;
  points.innerHTML = step.points.map(point => `<li>${point}</li>`).join('');
  nodes.forEach((node,index) => node.classList.toggle('active', index === step.active));
}));

const observer = new IntersectionObserver(entries => {
  entries.forEach(entry => { if (entry.isIntersecting) { entry.target.classList.add('visible'); observer.unobserve(entry.target); } });
}, {threshold:.12});
document.querySelectorAll('.reveal').forEach(item => observer.observe(item));

const ticker = document.querySelector('.ticker div');
ticker.innerHTML += ticker.innerHTML;
