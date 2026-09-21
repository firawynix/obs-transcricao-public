<#
    lib-cpu.ps1 - teto de processador e pausa, via Job Object do Windows.

    Job Object com teto rigido: quem segura o uso e o proprio sistema, nao e
    "prioridade baixa". Processo filho herda o job, entao prender o PowerShell
    principal cobre ffmpeg e whisper junto.

    Congelar tambem sai daqui (JobObjectFreezeInformation) - de proposito NAO
    usamos suspensao de thread/ntdll, que antivirus trata como comportamento
    suspeito e bloqueia.
#>

if (-not ("JobCpu" -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class JobCpu
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr CreateJobObject(IntPtr atributos, string nome);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetInformationJobObject(IntPtr job, int classe, IntPtr info, uint tam);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr processo);
    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();

    [StructLayout(LayoutKind.Sequential)]
    struct TAXA { public uint ControlFlags; public uint CpuRate; }

    [StructLayout(LayoutKind.Sequential)]
    struct CONGELA
    {
        public uint Flags; public byte Freeze; public byte Swap;
        public byte R0; public byte R1; public uint HighEdge; public uint LowEdge;
    }

    const int TAXA_INFO = 15;
    const int CONGELA_INFO = 18;
    const uint HABILITA = 0x1, TETO_RIGIDO = 0x4, OPERACAO_CONGELAR = 0x1;

    static bool Enviar(IntPtr job, int classe, object info, int tam)
    {
        if (job == IntPtr.Zero) return false;
        IntPtr ptr = Marshal.AllocHGlobal(tam);
        try
        {
            Marshal.StructureToPtr(info, ptr, false);
            return SetInformationJobObject(job, classe, ptr, (uint)tam);
        }
        finally { Marshal.FreeHGlobal(ptr); }
    }

    public static IntPtr Criar() { return CreateJobObject(IntPtr.Zero, null); }

    public static bool DefinirTeto(IntPtr job, int percentual)
    {
        if (percentual <= 0 || percentual >= 100) return false;
        TAXA t = new TAXA();
        t.ControlFlags = HABILITA | TETO_RIGIDO;
        t.CpuRate = (uint)(percentual * 100);      // centesimos de por cento
        return Enviar(job, TAXA_INFO, t, Marshal.SizeOf(typeof(TAXA)));
    }

    public static bool Prender(IntPtr job, IntPtr processo)
    {
        return AssignProcessToJobObject(job, processo);
    }

    public static bool PrenderEsteProcesso(IntPtr job)
    {
        return AssignProcessToJobObject(job, GetCurrentProcess());
    }

    // true = congelou de verdade; false = so deu para estrangular a CPU
    public static bool Congelar(IntPtr job, bool pausar, int tetoNormal)
    {
        CONGELA c = new CONGELA();
        c.Flags = OPERACAO_CONGELAR;
        c.Freeze = (byte)(pausar ? 1 : 0);
        if (Enviar(job, CONGELA_INFO, c, Marshal.SizeOf(typeof(CONGELA)))) return true;

        DefinirTeto(job, pausar ? 1 : tetoNormal);   // Windows antigo
        return false;
    }
}
"@
}

# O QUE REALMENTE SEGURA: afinidade de processador.
# Medido nesta maquina: o whisper abre 28 threads mesmo com "-t 9", e o job
# object de teto rigido aceita a configuracao sem limitar nada. Prendendo o
# processo a N nucleos, o Windows garante o teto, nao importa quantas threads
# o programa crie.
function Set-AfinidadeNucleos {
    param([System.Diagnostics.Process]$Processo, [int]$Nucleos)

    $total = [Environment]::ProcessorCount
    if ($Nucleos -le 0 -or $Nucleos -ge $total) { return $false }
    try {
        [long]$mascara = 0
        for ($i = 0; $i -lt $Nucleos; $i++) { $mascara = $mascara -bor ([long]1 -shl $i) }
        $Processo.ProcessorAffinity = [IntPtr]$mascara
        $Processo.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
        return $true
    } catch { return $false }
}

# usado pelo transcrever.ps1 quando roda sozinho (sem a janela)
function Set-LimiteCpu {
    param([int]$Percentual = 70)
    if ($Percentual -le 0 -or $Percentual -ge 100) { return "sem limite de processador" }
    $job = [JobCpu]::Criar()
    if ($job -eq [IntPtr]::Zero) { return "limite de CPU nao aplicado (job object)" }
    if (-not [JobCpu]::DefinirTeto($job, $Percentual)) { return "limite de CPU nao aplicado (teto)" }
    if (-not [JobCpu]::PrenderEsteProcesso($job)) { return "limite de CPU nao aplicado (prender)" }
    return "processador limitado a $Percentual%"
}
