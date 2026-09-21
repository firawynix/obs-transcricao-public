# Firaw — Transcrição OBS

[![Build Windows artifacts](https://github.com/firawynix/obs-transcricao-public/actions/workflows/build-windows.yml/badge.svg)](https://github.com/firawynix/obs-transcricao-public/actions/workflows/build-windows.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-cyan.svg)](LICENSE)

Código-fonte público do aplicativo de transcrição local da Firawynix. A compilação
oficial do Windows é feita diretamente deste repositório e publica os artefatos e
seus hashes para verificação de origem.

Ao parar a gravação, o OBS transcreve o vídeo sozinho e grava **`.txt`** e **`.srt`** na mesma pasta.
Se for reunião (Teams ou Google Meet), sai também **`<vídeo> - falas.txt`** com **quem falou o quê**,
e a legenda com o nome de quem fala **já abre ligada** no player.

Tudo roda **local e offline**: whisper.cpp na CPU e o OCR nativo do Windows. Nada sai da máquina.

## Linux

A edição nativa Linux fica em `linux/` e é publicada como AppImage e `.deb`.
Ela inclui FFmpeg/FFprobe e whisper.cpp, baixa os modelos oficiais no primeiro
uso, gera `.txt`/`.srt`, pode embutir a legenda em MP4/MOV e instala o script Lua
de integração ao OBS. O processamento continua local; a identificação visual de
participantes do fluxo Windows não faz parte da primeira edição Linux.

```
Nome sobrenome: bom dia pessoal, vamos começar
Outra pessoa: consegue compartilhar a tela?
Você: já vou compartilhar
(fala sem nome identificado sai só com o texto)
```

---

## Como funciona

```
gravação para
   │
   ├─ obs-transcrever.lua        evento RECORDING_STOPPED do OBS
   │     └─ abre Transcrever-Video.exe  →  configura e acompanha o trabalho
   │
   └─ Transcrever-Video.exe      multiplos trechos, barra, registro, pausa e cancelamento
         └─ transcrever.ps1
               ├─ ffmpeg      → wav mono 16 kHz (faixa 1 = mistura)
               ├─ whisper.cpp → .txt + .srt   (modelo large-v3-turbo + VAD silero)
               └─ falantes.ps1 → quem falou cada trecho
                     ├─ lib-quadro.ps1  acha a borda colorida da miniatura de quem fala
                     ├─ lib-ocr.ps1     lê o nome com o OCR do Windows (WinRT)
                     └─ faixa 2 (microfone) → "Você"
```

**Tudo sai do arquivo gravado, nunca do dispositivo ao vivo.** O que o OBS não gravou não existe
para a transcrição. O microfone vai na **faixa 2** (o instalador configura), o que permite saber
quando quem fala é você.

### Legenda: já abre ligada

A legenda com nome (`Nome: fala`) vai para **dois lugares**:

- **`<vídeo>.srt`**, ao lado do vídeo, com o mesmo nome. Player carrega sozinho a legenda que tem o
  nome do vídeo — e o MPC-HC (o que abre `.mp4` nesta máquina, via K-Lite) ainda **dá prioridade**
  a ela sobre a faixa embutida (`PrioritizeExternalSubtitles = 1`). Enquanto esse arquivo era o do
  whisper, abria-se o vídeo e aparecia a legenda **sem nome**, mesmo com a versão com nome embutida.
  A do whisper fica guardada como `<vídeo> - sem nomes.srt`.
- **Dentro do próprio `.mp4`**, como faixa de legenda marcada como padrão — sem recodificar, com
  `-c copy`: **1,5 s** num vídeo de 14,7 min / 652 MB, sem tocar num pixel. Serve para quando o
  vídeo vai para outro computador sem o `.srt` junto.

**Para ligar/desligar:** atalho **`Legenda liga-desliga`** na área de trabalho
(`alternar-legenda.ps1`). Ele muda a opção do próprio player (`EnableSubtitles` do MPC-HC), então
vale para todos os vídeos de uma vez e não reescreve arquivo nenhum. Com o MPC-HC aberto ele se
recusa, porque o player grava as opções ao fechar e desfaria a troca. Dentro do player, a legenda
também liga e desliga pelo botão direito › Legendas.

Não existe versão "ao vivo" disso, por dois motivos: o nome só aparece depois de ler a tela e cruzar
com a transcrição, e não dá para inserir faixa nova num arquivo que o OBS ainda está gravando.

O original é **substituído** (o remux é sem perda), e só depois de conferir que o arquivo novo tem
faixa de legenda e tamanho compatível; qualquer dúvida, o novo é descartado e o original fica. Se o
arquivo estiver travado (OneDrive sincronizando, player aberto), a versão legendada é salva ao lado
como `<vídeo> (com legenda).mp4` em vez de se perder. Rodar de novo **troca** a legenda em vez de
empilhar, porque o remux mapeia só vídeo e áudio da origem (`-map 0:v -map 0:a`).

Desligável em *Embutir a legenda dentro do próprio vídeo*, nas propriedades do script.

> Vídeo em pasta do OneDrive é re-enviado inteiro depois da troca — é o preço de mexer no arquivo.

### Identificação de quem falou

| Plataforma | Como é marcado | Situação |
|---|---|---|
| Microsoft Teams | borda azul-violeta na miniatura + nome no chip | ~1% sem nome num teste de 30 min |
| Google Meet | borda azul-clara + nome no chip | ~28% sem nome num teste de 10 min, 5 pessoas |

**Cuidado com o Meet em modo apresentação:** a borda passa a marcar **quem apresenta**, não quem
fala. Em modo grade funciona.

Quem não dá para identificar vira **`Não identificado`** — um rótulo só. Antes cada trecho ganhava
número próprio (`Voz 275`) e o tempo de fala de uma chamada de 1h37 virou uma lista de centenas de
"pessoas" que eram só trechos. Na legenda, fala sem nome sai só com o texto.

#### Chamada 1:1 com a tela compartilhada

Compartilhando a tela, o Teams esconde as miniaturas: não há borda nem chip para ler. Medido numa
chamada 1:1 de 1h37, quase toda com a tela do outro compartilhada: **91,7% das falas sem nome**.

Mas numa chamada 1:1 o **título da janela** é o nome da outra pessoa, e a faixa do microfone já
separou a sua voz — então o que sobra só pode ser dela. O `falantes.ps1` lê o título em 8 quadros
espalhados e só aceita se ao menos 3 leituras concordarem. Salvaguardas, todas vindas de gravação real:

- só com **faixa de microfone** (sem ela, a sua fala iria para a outra pessoa);
- só se a tela **não mostrou mais ninguém** além dessa pessoa;
- título de reunião (`Ingresso na reunião | Assunto` — o OCR lê a barra como `I`), de chamada em
  grupo (vários nomes, emendados com lixo pelo OCR) e de programa (`Microsoft Teams`) são recusados;
- o próprio nome de quem grava é ignorado.

Depende do Teams **maximizado** na tela gravada (o título é lido no canto superior esquerdo).

**O nome sai de uma votação, não de uma leitura.** O OCR erra feio quando o recorte pega ícone ou
borda: numa reunião real, "Bismarck Muniz Araujo" também saiu como `QBiSmarêk.MtI Araujo` e
`BEfii'àrc MbãlEArád'b`, e cada variante virava "mais uma pessoa" — uma reunião de ~8 pessoas foi
relatada como **23 pessoas identificadas**. Distância de edição não junta leitura tão corrompida.
Então cada miniatura é lida várias vezes e as leituras são pontuadas por *quanto parecem nome de
gente* (proporção de letras + palavras no formato `Maiúscula+minúsculas`); abaixo de 0,5 a leitura
é descartada, e entre as aceitas vence a melhor nota (empate vai para a mais frequente). Isso também
elimina o texto de interface que caía na lista, como `Abrir visualização detalhada`.

---

## Instalação

Os instaladores são idempotentes (pode rodar de novo): antes de baixar, conferem se OBS, ffmpeg,
ffprobe, whisper e os dois modelos já estão íntegros. Baixam e instalam somente o que faltar; se o
próprio OBS não estiver na máquina, tentam instalá-lo pelo `winget` (essa etapa pode pedir
administrador, conforme a configuração do Windows).
Eles fecham o OBS, copiam os arquivos, registram o script Lua em **todas** as coleções de cena,
põem o microfone na faixa 2 e criam na área de trabalho os atalhos `Transcrever vídeo.lnk` e
`Legenda liga-desliga.lnk`.

| Arquivo | Tamanho | O que traz |
|---|---|---|
| `Instalar-Transcricao-OBS.exe` | ~1,4 MB | aplicativo + scripts; baixa somente dependências ausentes |
| `Instalar-Transcricao-OBS-Completo.exe` | ~1,6 GB | whisper + modelos dentro; ffmpeg só se faltar |
| `Instalar-Transcricao-OBS-Offline.exe` | ~1,8 GB | tudo dentro, não toca a rede |

Os `.exe` **não ficam no repositório** (tamanho). Para gerá-los:

```powershell
cd instalador
.\compilar.ps1                 # gera o aplicativo visual e o instalador leve
.\empacotar.ps1                # gera o Completo
.\empacotar.ps1 -ComFfmpeg     # gera o Offline
```

> **Rode os dois depois de mexer em qualquer `.ps1`/`.lua`** — senão o instalador distribui a
> versão velha.

Compila com o `csc.exe` que já vem no Windows (`C:\Windows\Microsoft.NET\Framework64\v4.0.30319`),
sem SDK nenhum.

### O que não está no repositório

`bin/` e `modelos/` ficam de fora (48 MB de OpenBLAS, 1,5 GB de modelo). Para montar à mão:

- **whisper.cpp** — release Windows x64 BLAS de <https://github.com/ggml-org/whisper.cpp/releases>
  (usado aqui: v1.9.2) → `bin\`
- **modelo** `ggml-large-v3-turbo.bin` e **VAD** `ggml-silero-v5.1.2.bin` de
  <https://huggingface.co/ggerganov/whisper.cpp> → `modelos\`
- **ffmpeg/ffprobe** — `winget install Gyan.FFmpeg`, ou `bin\` (o `lib-ffmpeg.ps1` procura nos três)

---

## Uso

**Automático** — pare a gravação no OBS. O aplicativo abre com o vídeo selecionado; no modo direto,
o processamento já começa.

**Um vídeo qualquer** — atalho `Transcrever vídeo` na área de trabalho, ou:

```powershell
.\Transcrever-Video.exe
powershell -ExecutionPolicy Bypass -File transcrever.ps1 -Video "C:\...\reuniao.mp4"
```

**No aplicativo:** arraste um vídeo ou escolha o arquivo, defina quantos trechos deseja processar e
preencha o início e o final de cada linha no formato `HH:MM:SS`. Você pode cadastrar de 1 a 99
intervalos independentes. O aplicativo recorta cada trecho sem alterar o vídeo original, acompanha
o andamento total e salva os resultados numerados ao lado da gravação. Há botões para pausar,
continuar, cancelar e abrir a pasta final.

Os campos de tempo aceitam somente números e inserem os dois-pontos automaticamente. Digite seis
números na ordem `HHMMSS`: por exemplo, `001000` vira `00:10:00`. Minutos e segundos acima de 59
são recusados.

Para abrir a interface com vários trechos já configurados, repita `--trecho` usando
`inicio,final`:

```powershell
.\Transcrever-Video.exe "C:\Videos\reuniao.mp4" `
  --trecho 00:10:00,00:15:00 `
  --trecho 01:02:00,01:19:00
```

**Nas propriedades do script** (OBS › Ferramentas › Scripts): liga/desliga, *perguntar* × *direto*,
idioma (pt/en/es/auto), teto de processador (20–95%) e o botão *Transcrever a última gravação agora*.

---

## Desempenho: o que acelerou e o que não acelerou

Medido nesta máquina (32 núcleos lógicos, RX 9060 XT), num trecho real de reunião. Guardado aqui
porque **quase tudo que parecia óbvio não funcionou**:

| Tentativa | Resultado |
|---|---|
| Subir de 16 para 22 threads | +10% apenas — o whisper escala mal acima de ~16 |
| Decodificação gulosa (`-bs 1 -bo 1`) | **nada** — no `turbo` o peso está no encoder, não no decoder |
| Modelo quantizado `q5_0` (547 MB) | **nada** (~3%), e perde palavra: é compute-bound, não memory-bound |
| **Pedaços em paralelo** (antes `-p 4`) | **1,45×** — 4 pedaços de áudio ao mesmo tempo, com as mesmas threads |
| `-hwaccel d3d11va` na extração de quadros | **piorou** (75 s → 92 s): devolver quadro 3440×1440 da GPU custa mais que decodificar |
| 4 processos ffmpeg em paralelo | +10% só |
| **Decodificar só keyframes (`-skip_frame nokey`)** | **12×** (721 s → ~70 s) |

As duas que valeram:

- **Pedaços em paralelo na transcrição.** Começou como `-p 4` do whisper e virou corte próprio (ver
  a pegadinha 10): o áudio é partido em pedaços de até ~10 min, **no meio de um silêncio** perto de
  cada ponto ideal, e 4 whispers independentes (`-p 1`) rodam ao mesmo tempo; no fim os `.srt` são
  juntados somando o início de cada pedaço (`lib-srt.ps1`). O preço são as emendas, onde o whisper
  perde o contexto — cortando no silêncio, nenhuma palavra é partida. Abaixo de 8 min não compensa.
- **Só keyframes na leitura da tela.** Pedir `fps=0.5` obriga o ffmpeg a decodificar o vídeo inteiro
  para jogar 59 de cada 60 quadros fora. O OBS grava um keyframe a cada ~4 s, que já é a amostragem
  que queremos — e o `showinfo` entrega o instante de cada um na mesma passada (um `ffprobe`
  separado só para os tempos custaria 49 s sozinho).

Resultado num vídeo real de 1h42: **43 min → ~29 min** de transcrição, e a identificação de quem
falou caiu de 12 min para ~2 min.

**GPU está fora**: o whisper.cpp só publica binário Windows para CPU, BLAS e CUDA (NVIDIA). Placa
AMD só via Vulkan, que exigiria compilar o projeto (Vulkan SDK + CMake).

---

## Teto de processador: o que funciona e o que não funciona

Medido nesta máquina (32 núcleos lógicos). Vale registrar porque as duas primeiras abordagens
**parecem** funcionar — retornam sucesso e não limitam nada:

| Mecanismo | Resultado |
|---|---|
| Job Object com teto rígido (`CpuRateControlInformation`) | aceita a configuração, **não limita**: pedi 30%, medi 50-75% |
| `-t N` do whisper | **não segura** — abre 28 threads mesmo com `-t 9` |
| Variáveis do OpenBLAS (`OPENBLAS_NUM_THREADS` etc.) | sozinhas, não mudam nada |
| **Afinidade de processador** + prioridade `BelowNormal` | **funciona**: 70% → 75% de uso total, 30% → 41% |
| **`JobObjectFreezeInformation`** (classe 18) para pausar | **funciona**: whisper de 2063% → **0%** → 1986% |

O `ffmpeg` também precisa de `-threads N` explícito, senão toma a máquina inteira.

O teto vale para o trabalho da transcrição, não para a máquina toda: com ~10% de fundo (navegador,
Windows), 70% de teto dá ~75% de uso total.

---

## Pegadinhas que já custaram debug

1. **`Start-Process -ArgumentList @(...)` no PowerShell 5.1 não põe aspas** nos argumentos. Todo
   nome de gravação do OBS tem espaço (`2026-08-12 11-47-58.mp4`), então o caminho quebrava e o
   ffmpeg voltava `-2`. Por isso os argumentos vão como **uma string só, com aspas**.
2. **Sem VAD o whisper inventa texto no silêncio** (saiu "Legenda Adriana Zanotto" num trecho mudo).
   Daí o `--vad -vm ggml-silero -sns`, e o script apaga `.txt`/`.srt` em branco.
3. **O operador `-f` formata com a cultura do Windows.** Em pt-BR, `"fps={0}" -f 0.5`
   vira `fps=0,5`; o ffmpeg lê a vírgula como separador de filtro, responde
   *"No such filter: '5'"* e **não extrai quadro nenhum** — foi assim que a identificação de quem
   falou parou de funcionar em silêncio. Número que vai para linha de comando usa
   `.ToString([CultureInfo]::InvariantCulture)`. (Interpolação `"$x"` já é invariante; o `-f` não.)
4. **Script do OBS é salvo por coleção de cenas** (`basic\scenes\*.json` › `modules` › `scripts-tool`).
   Coleção nova nasce sem transcrição — o instalador cobre os 4 formatos de JSON que aparecem.
5. **`[int]` no PowerShell arredonda** (banker's rounding), não trunca. Foi assim que a legenda ficou
   1 hora adiantada depois dos 30 min. Os tempos usam milissegundo inteiro + `[math]::Floor`.
6. **PowerShell desenrola array de array** em `return` e em pipeline — quebrou a detecção de bordas
   três vezes (uma delas derrubou o Teams de 1% para 58% sem nome). Use `return , $array`.
   **Mas só quando os elementos são arrays.** Com elementos-objeto a vírgula faz o oposto: o chamador
   recebe *um* elemento contendo o array inteiro, e `$x.Fim - $x.Ini` estoura com
   *"[System.Object[]] não contém op_Subtraction"*. Pior, só acontece com mais de um elemento — a
   gravação com 1 trecho de microfone passou e a com 40 falhou, depois de já ter gasto a transcrição.
7. **`GetFolderPath(ApplicationData)` em C# ignora `%APPDATA%`** e vai na pasta real: impossível
   testar sem mexer na configuração de verdade. Trocado por ler a variável de ambiente.
8. **`| Select-Object -First N` mata o processo filho** — cuidado ao espiar saída de script.
9. **`[Console]::KeyAvailable` explode** quando a entrada está redirecionada; sempre guardar com
   `IsInputRedirected`.
10. **`-p 4` + VAD estraga os tempos em gravação longa** (whisper.cpp v1.9.2). A partir de certo
    ponto *todas* as legendas saem com o mesmo instante (`0,7 s`, `0,7 s`, `0,7 s`...) — o texto
    continua certo, só o relógio para. Medido em 2026-09-10 em três reuniões reais: o relógio parou
    em 2.130 s, 2.795 s e 3.900 s (a de 1h37 "terminava" aos 65 min). Em trechos de 10 e de 30 min
    **nenhuma** combinação (`-p 4`/`-p 1`, com/sem VAD) quebrou — por isso passou nos testes. Ia
    junto a identificação de quem falou, que cruza esses tempos com a tela. (Sem VAD o whisper
    ainda entra em laço no fim — "Um agente que, digamos assim..." repetido — e perdeu os últimos
    7 min de um trecho de 30.)
    Saída: pedaços próprios de até ~10 min com `-p 1` e `Test-SrtSaudavel` conferindo cada um
    (voltou no tempo, passou do fim, 4 legendas seguidas no mesmo instante → refaz sem VAD).

### Aplicativo e assinatura

`Transcrever-Video.exe` é uma interface WinForms pequena: ela não contém o motor de transcrição,
apenas configura e acompanha os scripts locais. O ícone e a interface usam a mesma identidade visual
do site. Como o binário ainda não tem assinatura de código, o SmartScreen pode avisar na primeira
execução. O fallback `transcrever-console.ps1` continua no pacote para ambientes que bloqueiem o `.exe`.

### Site e distribuição

A landing page está em `site/index.html`, com a mesma linguagem visual do SnapCopyText e conteúdo
próprio deste projeto. Para ver local, `site/abrir-site.ps1` inicia um servidor em
`http://127.0.0.1:8765/` e abre a página, sem depender de Node ou Python.

No ar em **<https://transcricao.firawynix.com.br>**: `index.html`, `app.js`, `styles.css` e
`assets/` copiados para `/home/ksdev/transcricao-site/public` no srv1 (nginx em
`127.0.0.1:26006`, Cloudflare Tunnel; mesmo `nginx.conf` do site do SnapCopyText, com o
`error_page 405 =200` do desafio da Cloudflare). A pasta `public` é montada inteira: publicar é
copiar os arquivos, sem recriar o container.

**Os instaladores saem de um repositório PÚBLICO só de releases**,
[firawynix/obs-transcricao-releases](https://github.com/firawynix/obs-transcricao-releases) — este
aqui continua privado. Os botões do site usam `releases/latest/download/<instalador>`. O Firawynix
Center instala o leve (`win_instalador=manual`, detecta por
`%USERPROFILE%\obs-transcricao\Transcrever-Video.exe`) e o `sync-release-center.sh` do srv1 mantém
link fixo da tag + SHA-256 + tamanho iguais à última release.

Publicar uma versão nova:

```powershell
cd instalador
.\compilar.ps1; .\empacotar.ps1; .\empacotar.ps1 -ComFfmpeg
# um .sha256 por instalador ("<hash>  <arquivo>") e depois:
gh release create vX.Y -R firawynix/obs-transcricao-public --title "Firaw — Transcrição OBS X.Y" --notes "..." `
  Instalar-Transcricao-OBS*.exe Instalar-Transcricao-OBS*.exe.sha256
```

> **Nada de nome real nos comentários dos scripts.** Tudo que o `compilar.ps1` embute vai, em
> Base64, dentro de um instalador PÚBLICO. Os exemplos de OCR nos comentários do `falantes.ps1`
> usam nomes fictícios; os logs (que guardam participantes de reunião) nunca entram.

---

## Arquivos

| Arquivo | O que faz |
|---|---|
| `obs-transcrever.lua` | script do OBS: evento de fim de gravação, propriedades, botão manual |
| `instalador/AppTranscrever.cs` | fonte do aplicativo visual (multiplos trechos, progresso, pausa) |
| `Transcrever-Video.exe` | aplicativo gerado por `compilar.ps1` (ignorado pelo Git) |
| `transcrever-console.ps1` | interface de console mantida como fallback |
| `alternar-legenda.ps1` | botão `Legenda liga-desliga`: muda a opção de legenda do player (MPC-HC) |
| `transcrever.ps1` | o trabalho: ffmpeg → whisper → falantes; um por vez (mutex global) |
| `falantes.ps1` | quem falou cada trecho; cruza bordas+OCR com os tempos do `.srt` |
| `lib-quadro.ps1` | C# embutido: acha bordas coloridas no quadro e recorta o chip do nome |
| `lib-ocr.ps1` | OCR nativo do Windows (`Windows.Media.Ocr`, WinRT) |
| `lib-ffmpeg.ps1` | acha ffmpeg/ffprobe em `bin\`, no PATH ou no winget |
| `lib-srt.ps1` | lê/escreve `.srt`, junta os pedaços e confere se os tempos fazem sentido |
| `lib-cpu.ps1` | Job Object (teto e congelamento) + afinidade de núcleos |
| `lib-progresso.ps1` | publica o andamento num arquivinho que a janela lê |
| `instalador/Instalador.cs` | o instalador; `Payload.cs` é gerado pelo `compilar.ps1` |
| `instalador/compilar.ps1` | compila o instalador leve |
| `instalador/empacotar.ps1` | cola whisper/modelos/ffmpeg no fim do `.exe` (índice + rodapé `OBSTRAN1`) |
| `assets/transcricao-logo.*` | logo PNG e ícone ICO do aplicativo |
| `site/` | página local responsiva, interativa e seus scripts de abertura |

## Requisitos

Windows 10/11, OBS Studio (com suporte a script Lua), PowerShell 5.1 — tudo já presente no sistema.
Roda na **CPU**: o whisper.cpp só publica binário Windows com CUDA (NVIDIA), não há build
Vulkan/ROCm pronta para Radeon.

## Segurança, privacidade e assinatura

- [Política de privacidade](PRIVACY.md)
- [Política de segurança](SECURITY.md)
- [Política de assinatura de código](CODE_SIGNING_POLICY.md)
- [Avisos de terceiros](THIRD_PARTY_NOTICES.md)
