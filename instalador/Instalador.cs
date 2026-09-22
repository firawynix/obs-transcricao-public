// Instalador.cs - instala e configura a transcricao automatica no OBS.
//
// Nao pede nada, nao abre janela de dialogo, nao precisa de administrador.
// Escreve os scripts, baixa o que falta (ffmpeg, whisper, modelos) e registra
// o script Lua em TODAS as colecoes de cenas do OBS.
//
// Codigos de saida: 0 = ok, 3 = OBS nao instalado, 4 = falha de download.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

public static partial class Instalador
{
    const string VERSAO = "2.5.1";

    const string URL_WHISPER = "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-blas-bin-x64.zip";
    const string URL_MODELO  = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin";
    const string URL_VAD     = "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin";
    const string URL_FFMPEG  = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip";

    static StreamWriter _log;
    static string _raiz;

    [DllImport("kernel32.dll")]
    static extern IntPtr GetConsoleWindow();

    [DllImport("user32.dll")]
    static extern bool ShowWindow(IntPtr janela, int comando);

    static void Diz(string msg)
    {
        Console.WriteLine(msg);
        if (_log != null) { _log.WriteLine("{0:HH:mm:ss}  {1}", DateTime.Now, msg); _log.Flush(); }
    }

    public static int Main(string[] args)
    {
        try { Console.OutputEncoding = Encoding.UTF8; } catch { }

        _raiz = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "obs-transcricao");
        bool fecharObs = true;
        bool faixaMic = true;
        bool silencioso = false;

        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--pasta" && i + 1 < args.Length) { _raiz = args[++i]; }
            else if (args[i] == "--nao-fechar-obs") { fecharObs = false; }
            else if (string.Equals(args[i], "/S", StringComparison.OrdinalIgnoreCase)
                     || args[i] == "--silencioso") { silencioso = true; fecharObs = false; }
            else if (args[i] == "--sem-faixa-mic") { faixaMic = false; }
            else if (args[i] == "--ajuda" || args[i] == "-h")
            {
                Console.WriteLine("Uso: Instalar-Transcricao-OBS.exe [--pasta <dir>] [--nao-fechar-obs] [--sem-faixa-mic]");
                Console.WriteLine("  --sem-faixa-mic: nao mexe nas faixas de audio do OBS (a fala de quem");
                Console.WriteLine("                   grava so sera identificada pela tela do Teams)");
                return 0;
            }
        }

        if (silencioso)
        {
            try { ShowWindow(GetConsoleWindow(), 0); } catch { }
        }

        Directory.CreateDirectory(_raiz);
        Directory.CreateDirectory(Path.Combine(_raiz, "bin"));
        Directory.CreateDirectory(Path.Combine(_raiz, "modelos"));
        Directory.CreateDirectory(Path.Combine(_raiz, "logs"));

        _log = new StreamWriter(Path.Combine(_raiz, "logs", "instalacao.log"), true, new UTF8Encoding(false));

        Diz("== Transcricao automatica para OBS - instalador " + VERSAO + " ==");
        Diz("pasta: " + _raiz);

        // --- pre-requisitos ---
        // Verifica antes de baixar: reinstalar e seguro e nao gasta rede a toa.
        // Se o OBS ainda nao existir, tenta instala-lo pelo winget.
        string obsExe;
        try { obsExe = GarantirObs(); }
        catch (Exception e)
        {
            Diz("ERRO preparando o OBS Studio: " + e.Message);
            return 3;
        }

        if (fecharObs) FecharObs();

        // --- scripts ---
        foreach (KeyValuePair<string, string> par in Arquivos())
        {
            string destino = Path.Combine(_raiz, par.Key);
            File.WriteAllBytes(destino, Convert.FromBase64String(par.Value));
            Diz("  gravado: " + par.Key);
        }

        // --- o que veio grudado no proprio .exe (versao completa) ---
        try
        {
            int extraidos = ExtrairEmbutidos();
            if (extraidos > 0) Diz("desempacotados " + extraidos + " arquivo(s) de dentro do instalador");
        }
        catch (Exception e)
        {
            Diz("AVISO: falha ao desempacotar (" + e.Message + ") - vou tentar baixar");
        }

        // --- programas e modelos ---
        try
        {
            Diz("verificando componentes locais...");
            GarantirFfmpeg();
            GarantirWhisper();
            GarantirModelo("ggml-large-v3-turbo.bin", URL_MODELO, "modelo de transcricao (1,5 GB)");
            GarantirModelo("ggml-silero-v5.1.2.bin", URL_VAD, "detector de fala");
        }
        catch (Exception e)
        {
            Diz("ERRO baixando componentes: " + e.Message);
            Diz("Verifique a conexao e rode de novo (o que ja baixou fica salvo).");
            return 4;
        }

        // --- atalho na area de trabalho para transcrever um video avulso ---
        // Atalho (.lnk) e nao executavel proprio: .exe novo sem assinatura que
        // dispara powershell e bloqueado por antivirus (aconteceu no teste).
        try { CriarAtalho(); }
        catch (Exception e) { Diz("AVISO: nao consegui por o atalho na area de trabalho: " + e.Message); }

        // --- botao para ligar/desligar a legenda no player ---
        try { CriarAtalhoLegenda(); }
        catch (Exception e) { Diz("AVISO: nao consegui por o atalho da legenda: " + e.Message); }

        // --- faixa separada do microfone ---
        if (faixaMic)
        {
            try { ConfigurarFaixaDoMicrofone(); }
            catch (Exception e) { Diz("AVISO: nao consegui configurar a faixa do microfone: " + e.Message); }
        }

        // --- registrar no OBS ---
        int registradas = RegistrarNoObs();
        if (registradas < 0)
        {
            Diz("AVISO: nenhuma colecao de cenas encontrada. Abra o OBS uma vez e rode o instalador de novo.");
        }
        else
        {
            Diz("registrado em " + registradas + " colecao(oes) de cenas do OBS");
        }

        Diz("");
        Diz("PRONTO. Abra o OBS e grave: ao parar, aparece .txt e .srt junto do video.");
        Diz("Em reuniao do Teams sai tambem '<video> - falas.txt' com quem falou o que,");
        Diz("e a legenda ja abre ligada com o nome de quem fala.");
        Diz("Atalho 'Legenda liga-desliga' na area de trabalho: liga/desliga no player.");
        _log.Flush();
        return 0;
    }

    // ------------------------------------------------------------------ OBS

    static string AcharObs()
    {
        string[] chaves = {
            @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OBS Studio",
            @"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\OBS Studio"
        };
        foreach (string chave in chaves)
        {
            try
            {
                using (Microsoft.Win32.RegistryKey k = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(chave))
                {
                    if (k == null) continue;
                    object v = k.GetValue("InstallLocation");
                    if (v == null) continue;
                    string exe = Path.Combine(v.ToString(), @"bin\64bit\obs64.exe");
                    if (File.Exists(exe)) return exe;
                }
            }
            catch { }
        }

        string[] palpites = {
            @"C:\Program Files\obs-studio\bin\64bit\obs64.exe",
            @"C:\Program Files (x86)\obs-studio\bin\64bit\obs64.exe",
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                         @"Programs\obs-studio\bin\64bit\obs64.exe")
        };
        foreach (string p in palpites) if (File.Exists(p)) return p;
        return null;
    }

    static string AcharNoPath(string exe)
    {
        string path = Environment.GetEnvironmentVariable("PATH");
        if (path != null)
        {
            foreach (string dir in path.Split(';'))
            {
                if (dir.Trim() == "") continue;
                try
                {
                    string candidato = Path.Combine(dir.Trim(), exe);
                    if (File.Exists(candidato)) return candidato;
                }
                catch { }
            }
        }

        string alias = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                    "Microsoft", "WindowsApps", exe);
        return File.Exists(alias) ? alias : null;
    }

    static string GarantirObs()
    {
        string obs = AcharObs();
        if (obs != null) { Diz("OBS encontrado: " + obs); return obs; }

        string winget = AcharNoPath("winget.exe");
        if (winget == null)
            throw new Exception("OBS nao encontrado e o instalador de aplicativos do Windows (winget) nao esta disponivel.");

        Diz("OBS Studio nao encontrado - baixando e instalando a versao oficial...");
        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = winget;
        psi.Arguments = "install --id OBSProject.OBSStudio -e --source winget --accept-package-agreements --accept-source-agreements --silent --disable-interactivity";
        psi.UseShellExecute = false;
        psi.CreateNoWindow = false;
        using (Process p = Process.Start(psi)) { p.WaitForExit(); if (p.ExitCode != 0) throw new Exception("a instalacao automatica do OBS falhou (codigo " + p.ExitCode + ")."); }

        obs = AcharObs();
        if (obs == null) throw new Exception("o OBS foi instalado, mas ainda nao consegui localizar obs64.exe.");
        Diz("OBS instalado: " + obs);
        return obs;
    }

    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    delegate bool EnumProc(IntPtr h, IntPtr p);
    const uint WM_CLOSE = 0x0010;

    static void FecharObs()
    {
        Process[] ps = Process.GetProcessesByName("obs64");
        if (ps.Length == 0) return;

        Diz("OBS esta aberto - pedindo para fechar (a configuracao so gruda com ele fechado)");
        foreach (Process p in ps)
        {
            try { if (!p.CloseMainWindow()) { } } catch { }
        }
        // OBS minimizado na bandeja nao tem janela principal: manda WM_CLOSE em todas
        EnumWindows(delegate(IntPtr h, IntPtr lp)
        {
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            foreach (Process p in ps) { try { if (p.Id == (int)pid) PostMessage(h, WM_CLOSE, IntPtr.Zero, IntPtr.Zero); } catch { } }
            return true;
        }, IntPtr.Zero);

        for (int i = 0; i < 60; i++)
        {
            if (Process.GetProcessesByName("obs64").Length == 0) { Diz("OBS fechou"); return; }
            System.Threading.Thread.Sleep(500);
        }
        Diz("AVISO: o OBS continua aberto. Se o script nao aparecer, feche o OBS e rode o instalador de novo.");
    }

    // ------------------------------------------------------ payload embutido
    //
    // A versao completa do instalador tem os arquivos grandes (whisper e modelos)
    // grudados no fim do proprio .exe, com um indice e um rodape de 24 bytes:
    //     [exe][arquivo1][arquivo2]...[indice][offset:8][tamanho:8][ASSINATURA:8]
    // A versao leve nao tem nada disso e cai no download. O mesmo codigo serve p/ as duas.

    const string ASSINATURA = "OBSTRAN1";

    static void CopiarPedaco(Stream origem, string destino, long tamanho, string oque)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(destino));
        byte[] buf = new byte[1024 * 1024];
        long feito = 0;
        int ultimo = -1;

        using (FileStream saida = new FileStream(destino, FileMode.Create, FileAccess.Write))
        {
            while (feito < tamanho)
            {
                int pedir = (int)Math.Min(buf.Length, tamanho - feito);
                int lido = origem.Read(buf, 0, pedir);
                if (lido <= 0) throw new IOException("payload truncado em " + oque);
                saida.Write(buf, 0, lido);
                feito += lido;

                int pct = (int)(feito * 100 / tamanho);
                if (tamanho > 50L * 1024 * 1024 && pct / 10 != ultimo)
                {
                    ultimo = pct / 10;
                    Console.Write("  " + pct + "%\r");
                }
            }
        }
    }

    static int ExtrairEmbutidos()
    {
        string eu = Assembly.GetExecutingAssembly().Location;
        if (string.IsNullOrEmpty(eu) || !File.Exists(eu)) return 0;

        using (FileStream fs = new FileStream(eu, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        {
            if (fs.Length < 64) return 0;

            byte[] rodape = new byte[24];
            fs.Seek(-24, SeekOrigin.End);
            if (fs.Read(rodape, 0, 24) != 24) return 0;
            if (Encoding.ASCII.GetString(rodape, 16, 8) != ASSINATURA) return 0;   // instalador leve

            long offIndice = BitConverter.ToInt64(rodape, 0);
            long tamIndice = BitConverter.ToInt64(rodape, 8);
            if (offIndice <= 0 || tamIndice <= 0 || offIndice + tamIndice > fs.Length) return 0;

            fs.Seek(offIndice, SeekOrigin.Begin);
            byte[] cru = new byte[tamIndice];
            int pos = 0;
            while (pos < cru.Length)
            {
                int n = fs.Read(cru, pos, cru.Length - pos);
                if (n <= 0) break;
                pos += n;
            }

            int extraidos = 0;
            foreach (string linha in Encoding.UTF8.GetString(cru).Split('\n'))
            {
                string l = linha.Trim();
                if (l == "") continue;
                string[] p = l.Split('|');
                if (p.Length != 3) continue;

                string rel = p[0].Replace('/', '\\');
                long off = long.Parse(p[1]);
                long tam = long.Parse(p[2]);
                string destino = Path.Combine(_raiz, rel);

                if (File.Exists(destino) && new FileInfo(destino).Length == tam) continue;  // ja esta la

                Diz("  extraindo " + rel + (tam > 50L * 1024 * 1024 ? " (" + (tam / 1024 / 1024) + " MB)" : ""));
                fs.Seek(off, SeekOrigin.Begin);
                CopiarPedaco(fs, destino, tam, rel);
                extraidos++;
            }
            return extraidos;
        }
    }

    // -------------------------------------------------------------- baixados

    static void Baixar(string url, string destino, string oque)
    {
        string parcial = destino + ".parcial";
        Diz("baixando " + oque + " ...");

        ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
        using (WebClient wc = new WebClient())
        {
            wc.Headers.Add("User-Agent", "obs-transcricao-instalador");
            int ultimo = -1;
            wc.DownloadProgressChanged += delegate(object s, DownloadProgressChangedEventArgs e)
            {
                int passo = e.ProgressPercentage / 10;
                if (passo != ultimo) { ultimo = passo; Console.Write("  " + e.ProgressPercentage + "%\r"); }
            };
            bool pronto = false;
            Exception falha = null;
            wc.DownloadFileCompleted += delegate(object s, System.ComponentModel.AsyncCompletedEventArgs e)
            {
                falha = e.Error; pronto = true;
            };
            wc.DownloadFileAsync(new Uri(url), parcial);
            while (!pronto) System.Threading.Thread.Sleep(200);
            if (falha != null) { try { File.Delete(parcial); } catch { } throw falha; }
        }
        if (File.Exists(destino)) File.Delete(destino);
        File.Move(parcial, destino);
        Diz("  ok: " + oque);
    }

    // procura um executavel nas pastas do PATH
    static bool TemNoPath(string exe)
    {
        return AcharNoPath(exe) != null;
    }

    static bool ExecutavelValido(string caminho, string argumentos)
    {
        if (!File.Exists(caminho) || new FileInfo(caminho).Length < 50 * 1024) return false;
        try
        {
            ProcessStartInfo psi = new ProcessStartInfo(caminho, argumentos);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            using (Process p = Process.Start(psi))
            {
                if (!p.WaitForExit(8000)) { try { p.Kill(); } catch { } return false; }
                return p.ExitCode == 0;
            }
        }
        catch { return false; }
    }

    static void GarantirFfmpeg()
    {
        string ffmpeg = Path.Combine(_raiz, @"bin\ffmpeg.exe");
        string ffprobe = Path.Combine(_raiz, @"bin\ffprobe.exe");
        if (ExecutavelValido(ffmpeg, "-version") && ExecutavelValido(ffprobe, "-version")) { Diz("ffmpeg: ja instalado e conferido"); return; }

        // Nao deixa um executavel local quebrado ganhar prioridade sobre uma
        // copia boa do PATH em lib-ffmpeg.ps1.
        if (File.Exists(ffmpeg) || File.Exists(ffprobe))
        {
            Diz("ffmpeg local incompleto ou invalido - removendo a copia quebrada");
            try { File.Delete(ffmpeg); } catch { }
            try { File.Delete(ffprobe); } catch { }
        }

        // se a maquina ja tem ffmpeg, nao gasta 290 MB de disco baixando outro
        string ffPath = AcharNoPath("ffmpeg.exe");
        string fpPath = AcharNoPath("ffprobe.exe");
        if (ffPath != null && fpPath != null && ExecutavelValido(ffPath, "-version") && ExecutavelValido(fpPath, "-version"))
        {
            Diz("ffmpeg: ja existe na maquina e foi conferido, nao vou baixar");
            return;
        }

        string zip = Path.Combine(Path.GetTempPath(), "ffmpeg-obs-transcricao.zip");
        Baixar(URL_FFMPEG, zip, "ffmpeg (~90 MB)");

        using (ZipArchive z = ZipFile.OpenRead(zip))
        {
            foreach (ZipArchiveEntry e in z.Entries)
            {
                string nome = Path.GetFileName(e.FullName).ToLower();
                if (nome == "ffmpeg.exe" || nome == "ffprobe.exe")
                    e.ExtractToFile(Path.Combine(_raiz, "bin", nome), true);
            }
        }
        try { File.Delete(zip); } catch { }
        if (!ExecutavelValido(ffmpeg, "-version") || !ExecutavelValido(ffprobe, "-version"))
            throw new Exception("ffmpeg foi baixado, mas nao passou na verificacao");
        Diz("ffmpeg instalado em bin\\");
    }

    static void GarantirWhisper()
    {
        string cli = Path.Combine(_raiz, @"bin\whisper-cli.exe");
        if (ExecutavelValido(cli, "--help")) { Diz("whisper: ja instalado e conferido"); return; }

        string zip = Path.Combine(Path.GetTempPath(), "whisper-obs-transcricao.zip");
        Baixar(URL_WHISPER, zip, "whisper.cpp (~21 MB)");

        using (ZipArchive z = ZipFile.OpenRead(zip))
        {
            foreach (ZipArchiveEntry e in z.Entries)
            {
                if (e.Length == 0) continue;                    // pasta
                string nome = Path.GetFileName(e.FullName);     // achata o Release\
                if (nome == "") continue;
                // so o que a transcricao usa: o resto do zip e teste e demo (~10 MB)
                string min = nome.ToLower();
                if (min != "whisper-cli.exe" && !min.EndsWith(".dll")) continue;
                e.ExtractToFile(Path.Combine(_raiz, "bin", nome), true);
            }
        }
        try { File.Delete(zip); } catch { }
        if (!ExecutavelValido(cli, "--help")) throw new Exception("whisper foi baixado, mas nao passou na verificacao");
        Diz("whisper instalado em bin\\");
    }

    static void GarantirModelo(string arquivo, string url, string oque)
    {
        string destino = Path.Combine(_raiz, "modelos", arquivo);
        long minimo = arquivo.IndexOf("large-v3", StringComparison.OrdinalIgnoreCase) >= 0
                    ? 1000L * 1024 * 1024 : 500L * 1024;
        if (File.Exists(destino) && new FileInfo(destino).Length > minimo)
        {
            Diz(oque + ": ja instalado e conferido");
            return;
        }

        // se alguem colocou o modelo do lado do instalador, usa ele (instalacao sem internet)
        string aoLado = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, arquivo);
        if (File.Exists(aoLado))
        {
            Diz("copiando " + oque + " de junto do instalador...");
            File.Copy(aoLado, destino, true);
            return;
        }
        Baixar(url, destino, oque);
        if (!File.Exists(destino) || new FileInfo(destino).Length <= minimo)
            throw new Exception(oque + " ficou incompleto depois do download");
    }

    // ------------------------------------------------------------------ atalho

    static void CriarAtalho()
    {
        string app = Path.Combine(_raiz, "Transcrever-Video.exe");
        if (File.Exists(app))
        {
            CriarLnkDireto("Transcrever video.lnk", app, "", "Escolhe um video e transcreve", app);
            return;
        }
        CriarLnk("Transcrever video.lnk", "transcrever-console.ps1", "",
                 "Escolhe um video e transcreve", @"%SystemRoot%\System32\shell32.dll,165");
    }

    // A legenda ja vem ligada; este botao liga/desliga no player (MPC-HC) para
    // todos os videos, sem reescrever arquivo nenhum. -WindowStyle Hidden: so a
    // caixa de aviso aparece, sem janela preta do PowerShell piscando.
    static void CriarAtalhoLegenda()
    {
        CriarLnk("Legenda liga-desliga.lnk", "alternar-legenda.ps1", "-WindowStyle Hidden ",
                 "Liga ou desliga a legenda com o nome de quem fala no player",
                 @"%SystemRoot%\System32\imageres.dll,18");
    }

    static void CriarLnk(string nome, string script, string extra, string descricao, string icone)
    {
        string alvo = Path.Combine(_raiz, script);
        if (!File.Exists(alvo)) { Diz("AVISO: " + script + " ausente, sem atalho"); return; }

        string mesa = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
        string lnk = Path.Combine(mesa, nome);

        Type tipo = Type.GetTypeFromProgID("WScript.Shell");
        object shell = Activator.CreateInstance(tipo);
        object atalho = tipo.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod,
                                          null, shell, new object[] { lnk });
        Type ta = atalho.GetType();
        ta.InvokeMember("TargetPath", BindingFlags.SetProperty, null, atalho,
                        new object[] { "powershell.exe" });
        ta.InvokeMember("Arguments", BindingFlags.SetProperty, null, atalho,
                        new object[] { "-NoProfile " + extra + "-ExecutionPolicy Bypass -File \"" + alvo + "\"" });
        ta.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, atalho,
                        new object[] { _raiz });
        ta.InvokeMember("Description", BindingFlags.SetProperty, null, atalho,
                        new object[] { descricao });
        ta.InvokeMember("IconLocation", BindingFlags.SetProperty, null, atalho,
                        new object[] { icone });
        ta.InvokeMember("Save", BindingFlags.InvokeMethod, null, atalho, null);

        Diz("atalho criado: " + lnk);
    }

    static void CriarLnkDireto(string nome, string alvo, string argumentos, string descricao, string icone)
    {
        string mesa = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
        string lnk = Path.Combine(mesa, nome);
        Type tipo = Type.GetTypeFromProgID("WScript.Shell");
        object shell = Activator.CreateInstance(tipo);
        object atalho = tipo.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { lnk });
        Type ta = atalho.GetType();
        ta.InvokeMember("TargetPath", BindingFlags.SetProperty, null, atalho, new object[] { alvo });
        ta.InvokeMember("Arguments", BindingFlags.SetProperty, null, atalho, new object[] { argumentos });
        ta.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, atalho, new object[] { _raiz });
        ta.InvokeMember("Description", BindingFlags.SetProperty, null, atalho, new object[] { descricao });
        ta.InvokeMember("IconLocation", BindingFlags.SetProperty, null, atalho, new object[] { icone });
        ta.InvokeMember("Save", BindingFlags.InvokeMethod, null, atalho, null);
        Diz("atalho criado: " + lnk);
    }

    // ------------------------------------------- faixa separada para o microfone
    //
    // Faixa 1 = tudo misturado (Ã© o que vai para o player e para a transcricao).
    // Faixa 2 = so o microfone, o que permite marcar a fala de quem gravou mesmo
    // quando a tela do Teams nao mostra a miniatura dele.

    static string PastaObs()
    {
        string appdata = Environment.GetEnvironmentVariable("APPDATA");
        if (string.IsNullOrEmpty(appdata))
            appdata = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        return Path.Combine(appdata, "obs-studio");
    }

    static void ConfigurarFaixaDoMicrofone()
    {
        // 1) gravar as faixas 1 e 2 (so no modo Avancado; o Simples nao tem multi-faixa)
        string perfis = Path.Combine(PastaObs(), @"basic\profiles");
        int perfisMexidos = 0;
        if (Directory.Exists(perfis))
        {
            foreach (string dir in Directory.GetDirectories(perfis))
            {
                string ini = Path.Combine(dir, "basic.ini");
                if (!File.Exists(ini)) continue;

                string[] linhas = File.ReadAllLines(ini);
                bool advOut = false, mudou = false;
                for (int i = 0; i < linhas.Length; i++)
                {
                    string l = linhas[i].Trim();
                    if (l.StartsWith("[")) advOut = (l == "[AdvOut]");
                    if (advOut && l.StartsWith("RecTracks="))
                    {
                        int atual;
                        if (int.TryParse(l.Substring("RecTracks=".Length), out atual))
                        {
                            int novo = atual | 2;              // acrescenta a faixa 2
                            if (novo != atual) { linhas[i] = "RecTracks=" + novo; mudou = true; }
                        }
                    }
                }
                if (mudou) { File.WriteAllLines(ini, linhas); perfisMexidos++; }
            }
        }

        // 2) microfone nas faixas 1 e 2; o resto do audio so na faixa 1
        string cenas = Path.Combine(PastaObs(), @"basic\scenes");
        int fontes = 0;
        int micsAtivos = 0;
        if (Directory.Exists(cenas))
        {
            foreach (string arq in Directory.GetFiles(cenas, "*.json"))
            {
                string txt = File.ReadAllText(arq, Encoding.UTF8);
                string novo = txt;

                foreach (Match m in Regex.Matches(txt, "\"id\":\\s*\"wasapi_(input|output)_capture\""))
                {
                    bool ehMic = m.Value.Contains("input");
                    // o "mixers" da propria fonte vem logo depois do "id"
                    Match mix = Regex.Match(novo.Substring(m.Index),
                                            "\"mixers\":\\s*(\\d+)", RegexOptions.None);
                    if (!mix.Success || mix.Index > 2000) continue;

                    if (ehMic)
                    {
                        // microfone desligado nas Configuracoes > Audio nao grava nada
                        Match dev = Regex.Match(novo.Substring(m.Index), "\"device_id\":\\s*\"([^\"]*)\"");
                        if (!dev.Success || dev.Index > 2000 || dev.Groups[1].Value != "disabled") micsAtivos++;
                    }

                    int alvo = ehMic ? 3 : 1;
                    int pos = m.Index + mix.Index;
                    string trecho = novo.Substring(pos, mix.Length);
                    string trocado = "\"mixers\": " + alvo;
                    if (trecho != trocado)
                    {
                        novo = novo.Substring(0, pos) + trocado + novo.Substring(pos + mix.Length);
                        fontes++;
                    }
                }

                if (novo != txt)
                {
                    File.Copy(arq, arq + ".antes-faixas", true);
                    File.WriteAllText(arq, novo, new UTF8Encoding(false));
                }
            }
        }

        if (perfisMexidos > 0 || fontes > 0)
            Diz("faixa 2 = microfone configurada (" + perfisMexidos + " perfil(is), " + fontes + " fonte(s) de audio)");
        else
            Diz("faixa 2 = microfone: ja estava configurada");

        // sem microfone no OBS nao ha o que transcrever da sua voz - e melhor avisar
        if (micsAtivos == 0)
            Diz("AVISO: nenhum microfone ativo no OBS deste computador. O que voce falar");
        if (micsAtivos == 0)
            Diz("       NAO entra na gravacao (e portanto nao aparece na transcricao).");
    }

    // ------------------------------------------------------- registro no OBS

    static int RegistrarNoObs()
    {
        // pelo env var (dÃ¡ para testar apontando para outro lugar); so cai no
        // GetFolderPath se a variavel nao existir
        string appdata = Environment.GetEnvironmentVariable("APPDATA");
        if (string.IsNullOrEmpty(appdata))
            appdata = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);

        string cenas = Path.Combine(appdata, @"obs-studio\basic\scenes");
        if (!Directory.Exists(cenas)) return -1;

        string[] arquivos = Directory.GetFiles(cenas, "*.json");
        if (arquivos.Length == 0) return -1;

        string caminhoLua = Path.Combine(_raiz, "obs-transcrever.lua").Replace("\\", "/");
        string entrada =
            "\n            {\n" +
            "                \"path\": \"" + caminhoLua + "\",\n" +
            "                \"settings\": {\n" +
            "                    \"ativo\": true,\n" +
            "                    \"idioma\": \"pt\"\n" +
            "                }\n" +
            "            }";

        int feitas = 0;
        foreach (string arq in arquivos)
        {
            try
            {
                string txt = File.ReadAllText(arq, Encoding.UTF8);
                if (txt.Contains("obs-transcrever.lua")) { feitas++; continue; }   // ja registrado

                string novo;
                Match m = Regex.Match(txt, "\"scripts-tool\"\\s*:\\s*\\[");
                if (m.Success)
                {
                    int fim = m.Index + m.Length;
                    string resto = txt.Substring(fim).TrimStart();
                    bool vazio = resto.StartsWith("]");
                    novo = txt.Substring(0, fim) + entrada + (vazio ? "\n        " : ",") + txt.Substring(fim);
                }
                else
                {
                    Match mm = Regex.Match(txt, "\"modules\"\\s*:\\s*\\{");
                    if (mm.Success)
                    {
                        int fim = mm.Index + mm.Length;
                        novo = txt.Substring(0, fim) + "\n        \"scripts-tool\": [" + entrada + "\n        ]," + txt.Substring(fim);
                    }
                    else
                    {
                        int fim = txt.IndexOf('{') + 1;
                        novo = txt.Substring(0, fim) +
                               "\n    \"modules\": {\n        \"scripts-tool\": [" + entrada + "\n        ]\n    }," +
                               txt.Substring(fim);
                    }
                }

                File.Copy(arq, arq + ".antes-transcricao", true);
                File.WriteAllText(arq, novo, new UTF8Encoding(false));
                feitas++;
            }
            catch (Exception e)
            {
                Diz("AVISO: nao consegui registrar em " + Path.GetFileName(arq) + ": " + e.Message);
            }
        }
        return feitas;
    }
}

