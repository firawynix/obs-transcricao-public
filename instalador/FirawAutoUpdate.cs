using System;
using System.Diagnostics;
using System.IO;
using System.Threading;

static class FirawAutoUpdate
{
    static int Main(string[] args)
    {
        if (args.Length != 2) return 2;
        int pid;
        if (!int.TryParse(args[0], out pid) || !File.Exists(args[1])) return 2;
        try
        {
            Process processo = Process.GetProcessById(pid);
            processo.WaitForExit(10 * 60 * 1000);
        }
        catch { }
        Thread.Sleep(700);
        try
        {
            ProcessStartInfo psi = new ProcessStartInfo(args[1], "--nao-fechar-obs");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WindowStyle = ProcessWindowStyle.Hidden;
            Process instalador = Process.Start(psi);
            if (instalador != null) instalador.WaitForExit(60 * 60 * 1000);
            try { File.Delete(args[1]); } catch { }
            return instalador == null ? 1 : instalador.ExitCode;
        }
        catch { return 1; }
    }
}
