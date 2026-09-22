using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Threading;
using System.Web.Script.Serialization;

sealed class PacoteAtualizacao
{
    public string url { get; set; }
    public string sha256 { get; set; }
    public long size { get; set; }
}

sealed class ManifestoAtualizacao
{
    public string version { get; set; }
    public Dictionary<string, PacoteAtualizacao> architectures { get; set; }
}

static class AutoUpdate
{
    const string Slug = "transcricao-obs";
    const string VersaoAtual = "2.5.1";
    const string Base = "https://jogos.firawynix.com.br/api/games/transcricao-obs/windows/";

    public static void Verificar()
    {
        ThreadPool.QueueUserWorkItem(delegate
        {
            try
            {
                using (Mutex trava = new Mutex(false, @"Local\Firawynix.Update." + Slug))
                {
                    if (!trava.WaitOne(0)) return;
                    VerificarAgora();
                }
            }
            catch { }
        });
    }

    static void VerificarAgora()
    {
        ManifestoAtualizacao manifesto;
        using (WebClient web = new WebClient())
        {
            web.Headers[HttpRequestHeader.UserAgent] = "Firawynix-AutoUpdate/1.0";
            manifesto = new JavaScriptSerializer().Deserialize<ManifestoAtualizacao>(
                web.DownloadString(Base + "atualizacao.json"));
        }

        Version nova, atual;
        if (manifesto == null || !Version.TryParse(manifesto.version, out nova)
            || !Version.TryParse(VersaoAtual, out atual) || nova <= atual
            || manifesto.architectures == null) return;

        PacoteAtualizacao pacote;
        if (!manifesto.architectures.TryGetValue("x64", out pacote)
            || pacote == null || !pacote.url.StartsWith(Base, StringComparison.OrdinalIgnoreCase)) return;

        string pasta = Path.Combine(Path.GetTempPath(), "FirawynixUpdates", Slug, manifesto.version);
        Directory.CreateDirectory(pasta);
        string instalador = Path.Combine(pasta, Slug + "-x64.exe");
        using (WebClient web = new WebClient())
        {
            web.Headers[HttpRequestHeader.UserAgent] = "Firawynix-AutoUpdate/1.0";
            web.DownloadFile(pacote.url, instalador);
        }

        FileInfo info = new FileInfo(instalador);
        if (!info.Exists || info.Length != pacote.size
            || !Hash(instalador).Equals(pacote.sha256, StringComparison.OrdinalIgnoreCase))
        {
            try { File.Delete(instalador); } catch { }
            return;
        }

        string helperInstalado = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "FirawAutoUpdate.exe");
        if (!File.Exists(helperInstalado)) return;
        string helperTemporario = Path.Combine(pasta, "FirawAutoUpdate-" + Process.GetCurrentProcess().Id + ".exe");
        File.Copy(helperInstalado, helperTemporario, true);
        ProcessStartInfo psi = new ProcessStartInfo(helperTemporario,
            Process.GetCurrentProcess().Id + " \"" + instalador + "\"");
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WindowStyle = ProcessWindowStyle.Hidden;
        Process.Start(psi);
    }

    static string Hash(string caminho)
    {
        using (FileStream arquivo = File.OpenRead(caminho))
        using (SHA256 sha = SHA256.Create())
            return BitConverter.ToString(sha.ComputeHash(arquivo)).Replace("-", "").ToLowerInvariant();
    }
}
