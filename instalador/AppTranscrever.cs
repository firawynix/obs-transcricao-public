// Transcrever-Video.exe - interface grafica para a transcricao local.
//
// Mantem o trabalho pesado nos scripts PowerShell ja testados. Este executavel
// escolhe o arquivo, permite recortar varios intervalos independentes,
// estima o tempo, mostra o andamento real e oferece pausa/cancelamento.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Forms;

public static class AppTranscrever
{
    [STAThread]
    public static int Main(string[] args)
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        OpcoesInicio op = OpcoesInicio.Ler(args);
        string raiz = AcharInstalacao();
        if (raiz == null)
        {
            MessageBox.Show("Nao achei a instalacao da Transcricao OBS.\n\nRode o instalador primeiro.",
                            "Transcricao OBS", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 3;
        }
        Application.Run(new JanelaTranscricao(raiz, op));
        return 0;
    }

    static string AcharInstalacao()
    {
        string aoLado = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "transcrever.ps1");
        if (File.Exists(aoLado)) return Path.GetDirectoryName(aoLado);
        string noPerfil = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                                       @"obs-transcricao\transcrever.ps1");
        return File.Exists(noPerfil) ? Path.GetDirectoryName(noPerfil) : null;
    }
}

internal sealed class OpcoesInicio
{
    public string Video;
    public int Cpu = 70;
    public string Idioma = "pt";
    public bool Iniciar;
    public bool SemFalantes;
    public bool SemLegenda;
    public string Inicio = "00:00:00";
    public string Fim;
    public int Repeticoes = 1;
    public readonly List<string[]> Trechos = new List<string[]>();

    public static OpcoesInicio Ler(string[] args)
    {
        OpcoesInicio op = new OpcoesInicio();
        for (int i = 0; i < args.Length; i++)
        {
            string a = args[i].ToLowerInvariant();
            if ((a == "--cpu" || a == "-cpu") && i + 1 < args.Length) int.TryParse(args[++i], out op.Cpu);
            else if ((a == "--idioma" || a == "-idioma") && i + 1 < args.Length) op.Idioma = args[++i];
            else if (a == "--iniciar" || a == "--direto") op.Iniciar = true;
            else if (a == "--sem-falantes") op.SemFalantes = true;
            else if (a == "--sem-legenda") op.SemLegenda = true;
            else if (a == "--inicio" && i + 1 < args.Length) op.Inicio = args[++i];
            else if (a == "--fim" && i + 1 < args.Length) op.Fim = args[++i];
            else if ((a == "--repeticoes" || a == "--vezes") && i + 1 < args.Length) int.TryParse(args[++i], out op.Repeticoes);
            else if (a == "--trecho" && i + 1 < args.Length)
            {
                string[] tempos = args[++i].Split(',');
                if (tempos.Length == 2) op.Trechos.Add(tempos);
            }
            else if (!a.StartsWith("-") && File.Exists(args[i])) op.Video = Path.GetFullPath(args[i]);
        }
        if (op.Trechos.Count > 0) op.Repeticoes = op.Trechos.Count;
        op.Cpu = Math.Max(20, Math.Min(95, op.Cpu));
        op.Repeticoes = Math.Max(1, Math.Min(99, op.Repeticoes));
        return op;
    }
}

internal sealed class BarraCiano : Control
{
    int _valor;
    public int Valor { get { return _valor; } set { _valor = Math.Max(0, Math.Min(100, value)); Invalidate(); } }

    public BarraCiano()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.ResizeRedraw | ControlStyles.UserPaint, true);
        Height = 14;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.None;
        e.Graphics.Clear(Cores.Superficie2);
        int w = (int)Math.Round(Width * _valor / 100.0);
        if (w > 0) using (SolidBrush b = new SolidBrush(Cores.Ciano)) e.Graphics.FillRectangle(b, 0, 0, w, Height);
        using (Pen p = new Pen(Cores.Linha)) e.Graphics.DrawRectangle(p, 0, 0, Math.Max(0, Width - 1), Math.Max(0, Height - 1));
    }
}

internal static class Cores
{
    public static readonly Color Fundo = Color.FromArgb(7, 17, 22);
    public static readonly Color Superficie = Color.FromArgb(12, 23, 30);
    public static readonly Color Superficie2 = Color.FromArgb(17, 31, 40);
    public static readonly Color Linha = Color.FromArgb(36, 52, 61);
    public static readonly Color Ciano = Color.FromArgb(25, 211, 230);
    public static readonly Color Branco = Color.FromArgb(245, 251, 253);
    public static readonly Color Muted = Color.FromArgb(147, 167, 179);
    public static readonly Color Sucesso = Color.FromArgb(132, 230, 190);
}

internal sealed class JanelaTranscricao : Form
{
    readonly string _raiz;
    readonly string _dados;
    readonly Timer _timer = new Timer();
    readonly TrackBar _cpu = new TrackBar();
    readonly Label _cpuValor = new Label();
    readonly Label _estimativa = new Label();
    readonly DataGridView _intervalos = new DataGridView();
    readonly NumericUpDown _repeticoes = new NumericUpDown();
    readonly ComboBox _idioma = new ComboBox();
    readonly CheckBox _falantes = new CheckBox();
    readonly CheckBox _legenda = new CheckBox();
    readonly Label _arquivo = new Label();
    readonly Label _fase = new Label();
    readonly Label _detalhe = new Label();
    readonly Label _relogio = new Label();
    readonly BarraCiano _barra = new BarraCiano();
    readonly RichTextBox _log = new RichTextBox();
    readonly Button _escolher = new Button();
    readonly Button _iniciar = new Button();
    readonly Button _pausar = new Button();
    readonly Button _cancelar = new Button();
    readonly Button _abrirPasta = new Button();
    readonly Panel _corpo = new Panel();

    string _video;
    string _progresso;
    string _arquivoLog;
    long _posLog;
    double _duracaoMin;
    double _duracaoTrechoMin;
    double _estimadoMin;
    Process _processo;
    DateTime _inicio;
    string _videoExecucao;
    string _pastaTemporaria;
    double _inicioSegundos;
    double _fimSegundos;
    int _repeticaoAtual;
    int _repeticoesTotal;
    readonly List<IntervaloVideo> _filaIntervalos = new List<IntervaloVideo>();
    bool _formatandoTempo;
    bool _preparandoTrecho;
    bool _pausado;
    bool _temJob;
    IntPtr _job = IntPtr.Zero;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr atributos, string nome);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr job, int classe, IntPtr info, uint tam);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr processo);

    [StructLayout(LayoutKind.Sequential)]
    struct FreezeInfo
    {
        public uint Flags; public byte Freeze; public byte Swap;
        public byte R0; public byte R1; public uint HighEdge; public uint LowEdge;
    }

    public JanelaTranscricao(string raiz, OpcoesInicio op)
    {
        _raiz = raiz;
        _dados = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                              "Firawynix", "OBSTranscricao");
        Directory.CreateDirectory(Path.Combine(_dados, "logs"));
        Text = "Transcricao OBS";
        Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        BackColor = Cores.Fundo;
        ForeColor = Cores.Branco;
        Font = new Font("Segoe UI", 9.5f, FontStyle.Regular);
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(900, 700);
        ClientSize = new Size(980, 850);
        AllowDrop = true;

        MontarInterface();
        _cpu.Value = op.Cpu;
        SelecionarIdioma(op.Idioma);
        _falantes.Checked = !op.SemFalantes;
        _legenda.Checked = !op.SemLegenda;
        DefinirVideo(op.Video);
        _repeticoes.Value = op.Repeticoes;
        if (op.Trechos.Count > 0)
        {
            for (int i = 0; i < op.Trechos.Count; i++)
            {
                _intervalos.Rows[i].Cells[1].Value = op.Trechos[i][0];
                _intervalos.Rows[i].Cells[2].Value = op.Trechos[i][1];
            }
        }
        else if (_intervalos.Rows.Count > 0)
        {
            if (!string.IsNullOrEmpty(op.Inicio)) _intervalos.Rows[0].Cells[1].Value = op.Inicio;
            if (!string.IsNullOrEmpty(op.Fim)) _intervalos.Rows[0].Cells[2].Value = op.Fim;
        }
        AtualizarEstimativa();

        Shown += delegate
        {
            BeginInvoke(new MethodInvoker(delegate
            {
                _intervalos.ClearSelection();
                _intervalos.CurrentCell = null;
                _escolher.Select();
                _corpo.AutoScrollPosition = new Point(0, 0);
                if (_corpo.VerticalScroll.Visible) _corpo.VerticalScroll.Value = _corpo.VerticalScroll.Minimum;
            }));
        };

        DragEnter += delegate(object s, DragEventArgs e) { if (e.Data.GetDataPresent(DataFormats.FileDrop)) e.Effect = DragDropEffects.Copy; };
        DragDrop += delegate(object s, DragEventArgs e)
        {
            string[] arquivos = (string[])e.Data.GetData(DataFormats.FileDrop);
            if (arquivos != null && arquivos.Length > 0) DefinirVideo(arquivos[0]);
        };
        FormClosing += AoFechar;
        _timer.Interval = 400;
        _timer.Tick += AtualizarAndamento;
        if (op.Iniciar && !string.IsNullOrEmpty(_video)) Shown += delegate { Iniciar(); };
    }

    void MontarInterface()
    {
        Panel topo = new Panel();
        topo.Dock = DockStyle.Top; topo.Height = 94; topo.BackColor = Cores.Fundo; topo.Padding = new Padding(28, 18, 28, 12);
        Controls.Add(topo);

        PictureBox logo = new PictureBox();
        logo.Size = new Size(58, 58); logo.Location = new Point(28, 18); logo.SizeMode = PictureBoxSizeMode.Zoom;
        try { logo.Image = Icon.ExtractAssociatedIcon(Application.ExecutablePath).ToBitmap(); } catch { }
        topo.Controls.Add(logo);
        Label nome = Texto("TRANSCRICAO OBS", 17, FontStyle.Bold, Cores.Branco); nome.Location = new Point(99, 22); nome.AutoSize = true; topo.Controls.Add(nome);
        Label subtitulo = Texto("AUDIO LOCAL  /  TEXTO PRONTO", 8.5f, FontStyle.Bold, Cores.Ciano); subtitulo.Location = new Point(101, 54); subtitulo.AutoSize = true; topo.Controls.Add(subtitulo);
        Label selo = Texto("100% LOCAL  •  SEM UPLOAD", 8.5f, FontStyle.Bold, Cores.Ciano); selo.AutoSize = true; selo.Anchor = AnchorStyles.Top | AnchorStyles.Right; selo.Location = new Point(730, 39); topo.Controls.Add(selo);
        Panel linha = new Panel(); linha.BackColor = Cores.Linha; linha.Dock = DockStyle.Bottom; linha.Height = 1; topo.Controls.Add(linha);

        _corpo.Location = new Point(0, topo.Height); _corpo.Size = new Size(ClientSize.Width, ClientSize.Height - topo.Height);
        _corpo.Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right;
        _corpo.Padding = new Padding(28, 18, 28, 24); _corpo.AutoScroll = true; Controls.Add(_corpo); topo.BringToFront();
        Label eyebrow = Texto("TRANSFORME A GRAVACAO EM CONTEUDO", 8.5f, FontStyle.Bold, Cores.Ciano); eyebrow.Location = new Point(28, 20); eyebrow.AutoSize = true; _corpo.Controls.Add(eyebrow);
        Label titulo = Texto("Escolha o video.\nAcompanhe cada etapa.", 27, FontStyle.Bold, Cores.Branco); titulo.Location = new Point(26, 46); titulo.Size = new Size(650, 88); _corpo.Controls.Add(titulo);
        Label intro = Texto("O processamento acontece nesta maquina. Cadastre ate 99 trechos, cada um com inicio e final proprios.", 10.5f, FontStyle.Regular, Cores.Muted); intro.Location = new Point(30, 140); intro.Size = new Size(800, 30); _corpo.Controls.Add(intro);

        Panel seletor = Cartao(new Rectangle(28, 180, 902, 78)); _corpo.Controls.Add(seletor);
        _arquivo.Text = "Nenhum video escolhido"; _arquivo.ForeColor = Cores.Muted; _arquivo.Location = new Point(18, 18); _arquivo.Size = new Size(650, 42); _arquivo.AutoEllipsis = true; _arquivo.Font = new Font("Segoe UI", 10, FontStyle.Bold); seletor.Controls.Add(_arquivo);
        _escolher.Text = "ESCOLHER VIDEO"; EstilizarBotao(_escolher, true); _escolher.Location = new Point(700, 16); _escolher.Size = new Size(180, 44); _escolher.TabIndex = 0; _escolher.Click += delegate { EscolherVideo(); }; seletor.Controls.Add(_escolher);

        Panel opcoes = Cartao(new Rectangle(28, 274, 438, 282)); _corpo.Controls.Add(opcoes);
        Label opTitulo = Texto("CONTROLE DE TEMPO", 8.5f, FontStyle.Bold, Cores.Ciano); opTitulo.Location = new Point(18, 16); opTitulo.AutoSize = true; opcoes.Controls.Add(opTitulo);
        Label cpuRot = Texto("Uso maximo do processador", 10, FontStyle.Bold, Cores.Branco); cpuRot.Location = new Point(18, 49); cpuRot.AutoSize = true; opcoes.Controls.Add(cpuRot);
        _cpuValor.Location = new Point(350, 47); _cpuValor.Size = new Size(65, 24); _cpuValor.TextAlign = ContentAlignment.MiddleRight; _cpuValor.ForeColor = Cores.Ciano; _cpuValor.Font = new Font("Segoe UI", 11, FontStyle.Bold); opcoes.Controls.Add(_cpuValor);
        _cpu.Minimum = 20; _cpu.Maximum = 95; _cpu.TickFrequency = 5; _cpu.SmallChange = 5; _cpu.LargeChange = 10; _cpu.Location = new Point(14, 74); _cpu.Size = new Size(406, 42); _cpu.BackColor = Cores.Superficie;
        _cpu.ValueChanged += delegate { AtualizarEstimativa(); }; opcoes.Controls.Add(_cpu);

        Label vezesRot = Texto("Quantos trechos processar", 9.5f, FontStyle.Bold, Cores.Branco); vezesRot.Location = new Point(18, 122); vezesRot.AutoSize = true; opcoes.Controls.Add(vezesRot);
        _repeticoes.Minimum = 1; _repeticoes.Maximum = 99; _repeticoes.Value = 1; _repeticoes.Location = new Point(345, 118); _repeticoes.Size = new Size(70, 26); _repeticoes.TextAlign = HorizontalAlignment.Center; _repeticoes.BackColor = Cores.Superficie2; _repeticoes.ForeColor = Cores.Branco;
        _repeticoes.ValueChanged += delegate { AtualizarQuantidadeTrechos(); }; opcoes.Controls.Add(_repeticoes);

        PrepararGradeIntervalos(); _intervalos.Location = new Point(18, 151); _intervalos.Size = new Size(397, 73); opcoes.Controls.Add(_intervalos);
        _estimativa.Location = new Point(20, 232); _estimativa.Size = new Size(395, 38); _estimativa.ForeColor = Cores.Muted; opcoes.Controls.Add(_estimativa);

        Panel config = Cartao(new Rectangle(492, 274, 438, 282)); _corpo.Controls.Add(config);
        Label confTitulo = Texto("SAIDA", 8.5f, FontStyle.Bold, Cores.Ciano); confTitulo.Location = new Point(18, 16); confTitulo.AutoSize = true; config.Controls.Add(confTitulo);
        Label idRot = Texto("Idioma", 10, FontStyle.Bold, Cores.Branco); idRot.Location = new Point(18, 49); idRot.AutoSize = true; config.Controls.Add(idRot);
        _idioma.DropDownStyle = ComboBoxStyle.DropDownList; _idioma.FlatStyle = FlatStyle.Flat; _idioma.BackColor = Cores.Superficie2; _idioma.ForeColor = Cores.Branco; _idioma.Location = new Point(18, 76); _idioma.Size = new Size(398, 28);
        _idioma.Items.Add(new ItemCombo("Portugues (PT-BR)", "pt")); _idioma.Items.Add(new ItemCombo("Ingles", "en")); _idioma.Items.Add(new ItemCombo("Espanhol", "es")); _idioma.Items.Add(new ItemCombo("Detectar automaticamente", "auto")); config.Controls.Add(_idioma);
        PrepararCheck(_falantes, "Identificar quem falou (Teams / Meet)", 124); config.Controls.Add(_falantes);
        PrepararCheck(_legenda, "Embutir legenda no proprio video", 160); config.Controls.Add(_legenda);
        Label priv = Texto("Nada e enviado para a internet.", 8.5f, FontStyle.Bold, Cores.Muted); priv.Location = new Point(20, 198); priv.AutoSize = true; config.Controls.Add(priv);

        Panel andamento = Cartao(new Rectangle(28, 572, 902, 176)); _corpo.Controls.Add(andamento);
        _fase.Text = "PRONTO PARA COMECAR"; _fase.Location = new Point(18, 15); _fase.Size = new Size(620, 25); _fase.Font = new Font("Segoe UI", 10, FontStyle.Bold); _fase.ForeColor = Cores.Ciano; andamento.Controls.Add(_fase);
        _relogio.Location = new Point(654, 15); _relogio.Size = new Size(226, 25); _relogio.TextAlign = ContentAlignment.MiddleRight; _relogio.ForeColor = Cores.Muted; andamento.Controls.Add(_relogio);
        _detalhe.Text = "Escolha um video ou arraste-o para esta janela."; _detalhe.Location = new Point(18, 45); _detalhe.Size = new Size(862, 25); _detalhe.ForeColor = Cores.Muted; andamento.Controls.Add(_detalhe);
        _barra.Location = new Point(18, 78); _barra.Size = new Size(862, 14); andamento.Controls.Add(_barra);
        _iniciar.Text = "INICIAR TRANSCRICAO"; EstilizarBotao(_iniciar, true); _iniciar.Location = new Point(18, 112); _iniciar.Size = new Size(238, 44); _iniciar.Click += delegate { Iniciar(); }; andamento.Controls.Add(_iniciar);
        _pausar.Text = "PAUSAR"; EstilizarBotao(_pausar, false); _pausar.Location = new Point(270, 112); _pausar.Size = new Size(132, 44); _pausar.Enabled = false; _pausar.Click += delegate { AlternarPausa(); }; andamento.Controls.Add(_pausar);
        _cancelar.Text = "CANCELAR"; EstilizarBotao(_cancelar, false); _cancelar.Location = new Point(416, 112); _cancelar.Size = new Size(132, 44); _cancelar.Enabled = false; _cancelar.Click += delegate { Cancelar(); }; andamento.Controls.Add(_cancelar);
        _abrirPasta.Text = "ABRIR PASTA"; EstilizarBotao(_abrirPasta, false); _abrirPasta.Location = new Point(742, 112); _abrirPasta.Size = new Size(138, 44); _abrirPasta.Enabled = false; _abrirPasta.Click += delegate { AbrirPasta(); }; andamento.Controls.Add(_abrirPasta);

        _log.Location = new Point(28, 764); _log.Size = new Size(902, 160); _log.BackColor = Color.FromArgb(5, 12, 16); _log.ForeColor = Cores.Muted; _log.BorderStyle = BorderStyle.FixedSingle; _log.Font = new Font("Consolas", 8.5f); _log.ReadOnly = true; _log.TabStop = false; _corpo.Controls.Add(_log);
        _corpo.AutoScrollMinSize = new Size(0, 950);
    }

    void SelecionarIdioma(string valor)
    {
        for (int i = 0; i < _idioma.Items.Count; i++) if (((ItemCombo)_idioma.Items[i]).Value == valor) { _idioma.SelectedIndex = i; return; }
        _idioma.SelectedIndex = 0;
    }

    static Label Texto(string texto, float tamanho, FontStyle estilo, Color cor)
    { Label l = new Label(); l.Text = texto; l.Font = new Font("Segoe UI", tamanho, estilo); l.ForeColor = cor; l.BackColor = Color.Transparent; return l; }

    static Panel Cartao(Rectangle r)
    { Panel p = new Panel(); p.Bounds = r; p.BackColor = Cores.Superficie; p.BorderStyle = BorderStyle.FixedSingle; return p; }

    static Button Botao(string texto, bool primario)
    { Button b = new Button(); b.Text = texto; EstilizarBotao(b, primario); return b; }

    static void EstilizarBotao(Button b, bool primario)
    {
        b.FlatStyle = FlatStyle.Flat; b.FlatAppearance.BorderSize = 1; b.Cursor = Cursors.Hand; b.Font = new Font("Segoe UI", 9, FontStyle.Bold);
        b.BackColor = primario ? Cores.Ciano : Cores.Superficie2; b.ForeColor = primario ? Cores.Fundo : Cores.Branco; b.FlatAppearance.BorderColor = primario ? Cores.Ciano : Cores.Linha;
    }

    static void PrepararCheck(CheckBox c, string texto, int y)
    { c.Text = texto; c.Location = new Point(18, y); c.AutoSize = true; c.ForeColor = Cores.Branco; }

    void PrepararGradeIntervalos()
    {
        _intervalos.AllowUserToAddRows = false; _intervalos.AllowUserToDeleteRows = false;
        _intervalos.AllowUserToResizeRows = false; _intervalos.RowHeadersVisible = false;
        _intervalos.MultiSelect = false; _intervalos.SelectionMode = DataGridViewSelectionMode.CellSelect;
        _intervalos.ScrollBars = ScrollBars.Vertical; _intervalos.BorderStyle = BorderStyle.FixedSingle;
        _intervalos.BackgroundColor = Cores.Superficie2; _intervalos.GridColor = Cores.Linha;
        _intervalos.EnableHeadersVisualStyles = false; _intervalos.ColumnHeadersHeight = 24; _intervalos.RowTemplate.Height = 24;
        _intervalos.ColumnHeadersDefaultCellStyle.BackColor = Cores.Superficie2;
        _intervalos.ColumnHeadersDefaultCellStyle.ForeColor = Cores.Ciano;
        _intervalos.ColumnHeadersDefaultCellStyle.Font = new Font("Segoe UI", 8.5f, FontStyle.Bold);
        _intervalos.DefaultCellStyle.BackColor = Cores.Superficie;
        _intervalos.DefaultCellStyle.ForeColor = Cores.Branco;
        _intervalos.DefaultCellStyle.SelectionBackColor = Color.FromArgb(20, 77, 86);
        _intervalos.DefaultCellStyle.SelectionForeColor = Cores.Branco;
        _intervalos.DefaultCellStyle.Font = new Font("Consolas", 9.5f, FontStyle.Bold);
        DataGridViewTextBoxColumn numero = new DataGridViewTextBoxColumn(); numero.HeaderText = "TRECHO"; numero.Width = 65; numero.ReadOnly = true;
        DataGridViewTextBoxColumn inicio = new DataGridViewTextBoxColumn(); inicio.HeaderText = "INICIO (HH:MM:SS)"; inicio.Width = 155;
        DataGridViewTextBoxColumn fim = new DataGridViewTextBoxColumn(); fim.HeaderText = "FINAL (HH:MM:SS)"; fim.Width = 155;
        _intervalos.Columns.Add(numero); _intervalos.Columns.Add(inicio); _intervalos.Columns.Add(fim);
        _intervalos.Rows.Add("01", "00:00:00", "00:00:00");
        _intervalos.CellValueChanged += delegate { AtualizarEstimativa(); };
        _intervalos.EditingControlShowing += AoMostrarEditorTempo;
        _intervalos.CellValidating += AoValidarCelulaTempo;
        _intervalos.CellEndEdit += delegate(object s, DataGridViewCellEventArgs e)
        {
            if (e.RowIndex < 0 || e.ColumnIndex == 0) return;
            string normalizado;
            if (NormalizarTempo(Convert.ToString(_intervalos.Rows[e.RowIndex].Cells[e.ColumnIndex].Value), out normalizado))
                _intervalos.Rows[e.RowIndex].Cells[e.ColumnIndex].Value = normalizado;
        };
    }

    void AtualizarQuantidadeTrechos()
    {
        int desejado = (int)_repeticoes.Value;
        string fimPadrao = _duracaoMin > 0 ? FormatarInstante(Math.Ceiling(_duracaoMin * 60.0)) : "00:00:00";
        while (_intervalos.Rows.Count < desejado)
            _intervalos.Rows.Add((_intervalos.Rows.Count + 1).ToString("00"), "00:00:00", fimPadrao);
        while (_intervalos.Rows.Count > desejado)
            _intervalos.Rows.RemoveAt(_intervalos.Rows.Count - 1);
        AtualizarEstimativa();
    }

    void AoMostrarEditorTempo(object sender, DataGridViewEditingControlShowingEventArgs e)
    {
        TextBox campo = e.Control as TextBox;
        if (campo == null) return;
        campo.KeyPress -= AoDigitarTempo;
        campo.TextChanged -= AoAlterarTempo;
        if (_intervalos.CurrentCell == null || _intervalos.CurrentCell.ColumnIndex == 0) return;
        campo.KeyPress += AoDigitarTempo;
        campo.TextChanged += AoAlterarTempo;
        BeginInvoke((MethodInvoker)delegate { if (!campo.IsDisposed) campo.SelectAll(); });
    }

    void AoDigitarTempo(object sender, KeyPressEventArgs e)
    {
        if (char.IsControl(e.KeyChar)) return;
        if (!char.IsDigit(e.KeyChar)) { e.Handled = true; return; }
        TextBox campo = sender as TextBox;
        if (campo == null) return;
        int posicao = ApenasDigitos(campo.Text.Substring(0, campo.SelectionStart)).Length;
        int selecionados = ApenasDigitos(campo.SelectedText).Length;
        int existentes = ApenasDigitos(campo.Text).Length - selecionados;
        if (existentes >= 6 || ((posicao == 2 || posicao == 4) && e.KeyChar > '5')) e.Handled = true;
    }

    void AoAlterarTempo(object sender, EventArgs e)
    {
        if (_formatandoTempo) return;
        TextBox campo = sender as TextBox;
        if (campo == null) return;
        string digitos = ApenasDigitos(campo.Text);
        if (digitos.Length > 6) digitos = digitos.Substring(0, 6);
        string formatado = digitos;
        if (digitos.Length > 4) formatado = digitos.Substring(0, 2) + ":" + digitos.Substring(2, 2) + ":" + digitos.Substring(4);
        else if (digitos.Length > 2) formatado = digitos.Substring(0, 2) + ":" + digitos.Substring(2);
        _formatandoTempo = true;
        campo.Text = formatado; campo.SelectionStart = campo.Text.Length;
        _formatandoTempo = false;
    }

    void AoValidarCelulaTempo(object sender, DataGridViewCellValidatingEventArgs e)
    {
        if (e.RowIndex < 0 || e.ColumnIndex == 0) return;
        string normalizado;
        if (!NormalizarTempo(Convert.ToString(e.FormattedValue), out normalizado))
        {
            e.Cancel = true;
            _intervalos.Rows[e.RowIndex].ErrorText = "Digite 6 numeros no formato HHMMSS. Minutos e segundos devem ficar entre 00 e 59.";
            MessageBox.Show("Digite 6 numeros. Exemplo: 001000 vira 00:10:00.\n\nMinutos e segundos devem ficar entre 00 e 59.", "Horario invalido", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }
        _intervalos.Rows[e.RowIndex].ErrorText = "";
        _intervalos.Rows[e.RowIndex].Cells[e.ColumnIndex].Value = normalizado;
    }

    static string ApenasDigitos(string texto)
    {
        StringBuilder sb = new StringBuilder();
        foreach (char c in texto ?? "") if (char.IsDigit(c)) sb.Append(c);
        return sb.ToString();
    }

    static bool NormalizarTempo(string texto, out string normalizado)
    {
        normalizado = null;
        string digitos = ApenasDigitos(texto);
        if (digitos.Length != 6) return false;
        int horas, minutos, segundos;
        if (!int.TryParse(digitos.Substring(0, 2), out horas) ||
            !int.TryParse(digitos.Substring(2, 2), out minutos) ||
            !int.TryParse(digitos.Substring(4, 2), out segundos)) return false;
        if (minutos > 59 || segundos > 59) return false;
        normalizado = horas.ToString("00") + ":" + minutos.ToString("00") + ":" + segundos.ToString("00");
        return true;
    }

    void EscolherVideo()
    {
        using (OpenFileDialog d = new OpenFileDialog())
        {
            d.Title = "Escolha o video ou audio para transcrever";
            d.Filter = "Videos e audios|*.mp4;*.mkv;*.mov;*.avi;*.webm;*.m4a;*.mp3;*.wav|Todos os arquivos|*.*";
            string videos = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Videos");
            if (Directory.Exists(videos)) d.InitialDirectory = videos;
            if (d.ShowDialog(this) == DialogResult.OK) DefinirVideo(d.FileName);
        }
    }

    void DefinirVideo(string caminho)
    {
        if (string.IsNullOrEmpty(caminho) || !File.Exists(caminho)) return;
        _video = Path.GetFullPath(caminho);
        _arquivo.Text = Path.GetFileName(_video) + "\n" + Path.GetDirectoryName(_video); _arquivo.ForeColor = Cores.Branco;
        _duracaoMin = LerDuracaoMin(_video);
        if (_duracaoMin > 0)
        {
            string fim = FormatarInstante(Math.Ceiling(_duracaoMin * 60.0));
            foreach (DataGridViewRow linha in _intervalos.Rows)
            {
                linha.Cells[1].Value = "00:00:00";
                linha.Cells[2].Value = fim;
            }
        }
        AtualizarEstimativa(); _detalhe.Text = "Configuracao pronta. Clique em iniciar quando quiser."; _iniciar.Enabled = true;
    }

    double LerDuracaoMin(string video)
    {
        string ffprobe = AcharFerramenta("ffprobe.exe"); if (ffprobe == null) return 0;
        try
        {
            ProcessStartInfo psi = new ProcessStartInfo(ffprobe, "-v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 \"" + video + "\"");
            psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.RedirectStandardOutput = true;
            using (Process p = Process.Start(psi))
            {
                string s = p.StandardOutput.ReadToEnd().Trim(); p.WaitForExit(10000); double segundos;
                if (double.TryParse(s, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out segundos)) return segundos / 60.0;
            }
        }
        catch { }
        return 0;
    }

    string AcharFerramenta(string nome)
    {
        string proprio = Path.Combine(_raiz, "bin", nome); if (File.Exists(proprio)) return proprio;
        string path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (string dir in path.Split(';')) { try { string p = Path.Combine(dir.Trim(), nome); if (File.Exists(p)) return p; } catch { } }
        string winget = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WinGet", "Packages");
        if (Directory.Exists(winget)) { try { string[] achados = Directory.GetFiles(winget, nome, SearchOption.AllDirectories); if (achados.Length > 0) return achados[0]; } catch { } }
        return null;
    }

    void AtualizarEstimativa()
    {
        if (_cpu.Value < _cpu.Minimum) return;
        _cpuValor.Text = _cpu.Value + "%";
        string erro;
        List<IntervaloVideo> intervalos = LerIntervalos(out erro);
        _duracaoTrechoMin = 0; _estimadoMin = 0;
        if (intervalos != null)
        {
            foreach (IntervaloVideo intervalo in intervalos)
            {
                double duracao = (intervalo.Fim - intervalo.Inicio) / 60.0;
                _duracaoTrechoMin += duracao;
                _estimadoMin += Math.Max(1.0, (duracao / 3.0) * 70.0 / _cpu.Value);
            }
        }
        if (_duracaoMin <= 0) _estimativa.Text = "A estimativa aparece depois que o video for escolhido.";
        else if (intervalos == null) _estimativa.Text = erro;
        else
        {
            _estimativa.Text = intervalos.Count + " trecho(s)  •  total: " + FormatarMinutos(_duracaoTrechoMin) + "  •  estimativa: " + FormatarMinutos(_estimadoMin);
        }
    }

    List<IntervaloVideo> LerIntervalos(out string erro)
    {
        erro = null;
        List<IntervaloVideo> lista = new List<IntervaloVideo>();
        for (int i = 0; i < _intervalos.Rows.Count; i++)
        {
            string inicioTexto = Convert.ToString(_intervalos.Rows[i].Cells[1].Value);
            string fimTexto = Convert.ToString(_intervalos.Rows[i].Cells[2].Value);
            double inicio, fim;
            if (!TryLerTempo(inicioTexto, out inicio) || !TryLerTempo(fimTexto, out fim))
            {
                erro = "Trecho " + (i + 1) + ": use HH:MM:SS.";
                return null;
            }
            if (fim <= inicio)
            {
                erro = "Trecho " + (i + 1) + ": o final deve ser maior que o inicio.";
                return null;
            }
            if (_duracaoMin > 0 && fim > (_duracaoMin * 60.0) + 1.0)
            {
                erro = "Trecho " + (i + 1) + ": o final ultrapassa o video.";
                return null;
            }
            lista.Add(new IntervaloVideo(inicio, fim));
        }
        return lista;
    }

    static bool TryLerTempo(string texto, out double segundos)
    {
        segundos = 0;
        if (string.IsNullOrWhiteSpace(texto)) return false;
        string[] partes = texto.Trim().Split(':');
        if (partes.Length < 2 || partes.Length > 3) return false;
        int h = 0, m = 0, s = 0;
        if (partes.Length == 3)
        {
            if (!int.TryParse(partes[0], out h) || !int.TryParse(partes[1], out m) || !int.TryParse(partes[2], out s)) return false;
        }
        else
        {
            if (!int.TryParse(partes[0], out m) || !int.TryParse(partes[1], out s)) return false;
        }
        if (h < 0 || m < 0 || m > 59 || s < 0 || s > 59) return false;
        segundos = h * 3600.0 + m * 60.0 + s;
        return true;
    }

    static string FormatarInstante(double segundos)
    {
        long total = (long)Math.Max(0, Math.Round(segundos));
        return ((long)(total / 3600)).ToString("00") + ":" + ((total % 3600) / 60).ToString("00") + ":" + (total % 60).ToString("00");
    }

    static string FormatarMinutos(double min)
    {
        if (min < 1) return "menos de 1 min"; int total = (int)Math.Ceiling(min);
        if (total < 60) return "~" + total + " min";
        return "~" + (total / 60) + "h " + (total % 60).ToString("00") + "min";
    }

    bool DependenciasOk()
    {
        string[] faltando = new string[3]; int n = 0;
        string whisper = Path.Combine(_raiz, @"bin\whisper-cli.exe");
        string modelo = Path.Combine(_raiz, @"modelos\ggml-large-v3-turbo.bin");
        if (!File.Exists(whisper) || new FileInfo(whisper).Length < 50 * 1024) faltando[n++] = "whisper.cpp";
        if (!File.Exists(modelo) || new FileInfo(modelo).Length < 1000L * 1024 * 1024) faltando[n++] = "modelo de transcricao";
        if (AcharFerramenta("ffmpeg.exe") == null) faltando[n++] = "ffmpeg";
        if (n == 0) return true;
        string lista = ""; for (int i = 0; i < n; i++) lista += "\n• " + faltando[i];
        MessageBox.Show("Faltam componentes para transcrever:" + lista + "\n\nRode novamente o instalador; ele verifica e baixa somente o que estiver faltando.",
                        "Transcricao OBS", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        return false;
    }

    void Iniciar()
    {
        if (_processo != null && !_processo.HasExited) return;
        if (string.IsNullOrEmpty(_video) || !File.Exists(_video)) { EscolherVideo(); if (string.IsNullOrEmpty(_video)) return; }
        if (!DependenciasOk()) return;

        _intervalos.EndEdit();
        string erro;
        List<IntervaloVideo> intervalos = LerIntervalos(out erro);
        if (intervalos == null)
        {
            MessageBox.Show(erro, "Transcricao OBS", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }

        _arquivoLog = Path.Combine(_dados, "logs", "transcricao-" + DateTime.Now.ToString("yyyy-MM") + ".log");
        _posLog = File.Exists(_arquivoLog) ? new FileInfo(_arquivoLog).Length : 0;
        _filaIntervalos.Clear(); _filaIntervalos.AddRange(intervalos);
        _repeticoesTotal = intervalos.Count; _repeticaoAtual = 0;
        _videoExecucao = _video; _pastaTemporaria = null; _progresso = null; _preparandoTrecho = false;
        _inicio = DateTime.Now; _pausado = false; _barra.Valor = 0; _log.Clear(); _fase.ForeColor = Cores.Ciano;
        _iniciar.Enabled = false; _pausar.Enabled = true; _cancelar.Enabled = true; _abrirPasta.Enabled = false; _timer.Start();
        _intervalos.Enabled = false; _repeticoes.Enabled = false; _cpu.Enabled = false;

        IniciarProximoTrecho();
    }

    void IniciarProximoTrecho()
    {
        LimparTemporario();
        _repeticaoAtual++;
        IntervaloVideo atual = _filaIntervalos[_repeticaoAtual - 1];
        _inicioSegundos = atual.Inicio; _fimSegundos = atual.Fim; _videoExecucao = _video;
        bool parcial = _inicioSegundos > 0.01 || (_duracaoMin > 0 && _fimSegundos < (_duracaoMin * 60.0) - 1.0);
        if (parcial) IniciarRecorte(); else IniciarTranscricaoTrecho();
    }

    void IniciarRecorte()
    {
        string ffmpeg = AcharFerramenta("ffmpeg.exe");
        if (ffmpeg == null) { Finalizar(false, "FFMPEG NAO ENCONTRADO"); return; }
        _pastaTemporaria = Path.Combine(Path.GetTempPath(), "obs-transcricao-lote-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_pastaTemporaria);
        _videoExecucao = Path.Combine(_pastaTemporaria, "trecho" + Path.GetExtension(_video));
        string invInicio = _inicioSegundos.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture);
        string invDuracao = (_fimSegundos - _inicioSegundos).ToString("0.###", System.Globalization.CultureInfo.InvariantCulture);
        string argumentos = "-hide_banner -loglevel error -y -ss " + invInicio + " -i \"" + _video + "\" -t " + invDuracao + " -map 0:v? -map 0:a? -c copy -avoid_negative_ts make_zero \"" + _videoExecucao + "\"";
        _fase.Text = "PREPARANDO TRECHO"; _detalhe.Text = "Trecho " + _repeticaoAtual + " de " + _repeticoesTotal + ": recortando sem alterar o original.";
        _barra.Valor = 3 + (int)Math.Floor(96.0 * (_repeticaoAtual - 1) / Math.Max(1, _repeticoesTotal));
        _preparandoTrecho = true;
        if (!IniciarProcesso(new ProcessStartInfo(ffmpeg, argumentos))) Finalizar(false, "NAO FOI POSSIVEL PREPARAR O TRECHO");
    }

    void IniciarTranscricaoTrecho()
    {
        string idioma = ((ItemCombo)_idioma.SelectedItem).Value;
        StringBuilder a = new StringBuilder();
        a.Append("-NoProfile -ExecutionPolicy Bypass -File \"").Append(Path.Combine(_raiz, "transcrever.ps1"));
        a.Append("\" -Video \"").Append(_videoExecucao).Append("\" -Forcar -CpuMax ").Append(_cpu.Value).Append(" -Idioma ").Append(idioma);
        if (!_falantes.Checked) a.Append(" -SemFalantes");
        if (!_legenda.Checked) a.Append(" -SemLegenda");
        _progresso = CaminhoProgresso(_dados, _videoExecucao);
        _fase.Text = "PREPARANDO";
        _detalhe.Text = "Trecho " + _repeticaoAtual + " de " + _repeticoesTotal + ".";
        _preparandoTrecho = false;
        if (!IniciarProcesso(new ProcessStartInfo("powershell.exe", a.ToString()))) Finalizar(false, "NAO FOI POSSIVEL INICIAR");
    }

    bool IniciarProcesso(ProcessStartInfo psi)
    {
        psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.WindowStyle = ProcessWindowStyle.Hidden;
        psi.EnvironmentVariables["FIRAW_OBS_DATA_DIR"] = _dados;
        try { _processo = Process.Start(psi); }
        catch (Exception ex)
        {
            MessageBox.Show("Nao consegui iniciar o processamento.\n\n" + ex.Message, "Transcricao OBS", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return false;
        }
        if (_job == IntPtr.Zero) _job = CreateJobObject(IntPtr.Zero, null);
        _temJob = false;
        if (_job != IntPtr.Zero) { try { _temJob = AssignProcessToJobObject(_job, _processo.Handle); } catch { } }
        return true;
    }

    static string CaminhoProgresso(string raiz, string video)
    {
        using (MD5 md5 = MD5.Create())
        {
            byte[] h = md5.ComputeHash(Encoding.UTF8.GetBytes(video.ToLowerInvariant()));
            return Path.Combine(raiz, "logs", "progresso-" + BitConverter.ToString(h).Replace("-", "").Substring(0, 8) + ".txt");
        }
    }

    void AtualizarAndamento(object sender, EventArgs e)
    {
        LerLog();
        if (!_pausado && !string.IsNullOrEmpty(_progresso) && File.Exists(_progresso))
        {
            try
            {
                string[] p = File.ReadAllText(_progresso, Encoding.UTF8).Split('|'); int pct;
                if (p.Length >= 2 && int.TryParse(p[0], out pct))
                {
                    double baseRodada = (_repeticaoAtual - 1) + pct / 100.0;
                    _barra.Valor = 3 + (int)Math.Floor(96.0 * baseRodada / Math.Max(1, _repeticoesTotal));
                    _fase.Text = p[1].ToUpperInvariant();
                    string detalheFilho = p.Length > 2 && p[2].Length > 0 ? " - " + p[2] : "";
                    _detalhe.Text = "Trecho " + _repeticaoAtual + " de " + _repeticoesTotal + detalheFilho;
                }
            }
            catch { }
        }
        TimeSpan dec = DateTime.Now - _inicio; string tempo = "decorrido " + FormatarRelogio(dec);
        if (!_pausado && _estimadoMin > 0) tempo += "  •  ~" + FormatarRelogio(TimeSpan.FromMinutes(Math.Max(0, _estimadoMin - dec.TotalMinutes))) + " restantes";
        _relogio.Text = _pausado ? "PAUSADO  •  " + tempo : tempo;
        if (_processo != null && _processo.HasExited)
        {
            int codigo = _processo.ExitCode;
            _processo.Dispose(); _processo = null;
            if (_preparandoTrecho)
            {
                _preparandoTrecho = false;
                if (codigo != 0 || !File.Exists(_videoExecucao)) Finalizar(false, "RECORTE NAO CONCLUIDO");
                else IniciarTranscricaoTrecho();
            }
            else if (codigo != 0) Finalizar(false);
            else
            {
                if (!ResultadoDaRepeticaoExiste())
                {
                    Finalizar(false, "ARQUIVOS DE SAIDA NAO FORAM GERADOS");
                    return;
                }
                GuardarResultadoDaRepeticao();
                GuardarVideoDoTrecho();
                if (_repeticaoAtual < _repeticoesTotal) IniciarProximoTrecho();
                else Finalizar(true);
            }
        }
    }

    static string FormatarRelogio(TimeSpan t)
    { return t.TotalHours >= 1 ? ((int)t.TotalHours) + ":" + t.Minutes.ToString("00") + ":" + t.Seconds.ToString("00") : ((int)t.TotalMinutes).ToString("00") + ":" + t.Seconds.ToString("00"); }

    void LerLog()
    {
        try
        {
            if (string.IsNullOrEmpty(_arquivoLog) || !File.Exists(_arquivoLog)) return;
            using (FileStream fs = new FileStream(_arquivoLog, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            {
                if (fs.Length <= _posLog) return; fs.Seek(_posLog, SeekOrigin.Begin);
                using (StreamReader sr = new StreamReader(fs, Encoding.UTF8)) { string novo = sr.ReadToEnd(); if (novo.Length > 0) { _log.AppendText(novo); _log.SelectionStart = _log.TextLength; _log.ScrollToCaret(); } }
                _posLog = fs.Length;
            }
        }
        catch { }
    }

    void AlternarPausa()
    {
        if (_processo == null || _processo.HasExited || !_temJob) return;
        FreezeInfo f = new FreezeInfo(); f.Flags = 1; f.Freeze = (byte)(_pausado ? 0 : 1);
        int tam = Marshal.SizeOf(typeof(FreezeInfo)); IntPtr ptr = Marshal.AllocHGlobal(tam);
        try
        {
            Marshal.StructureToPtr(f, ptr, false);
            if (!SetInformationJobObject(_job, 18, ptr, (uint)tam)) { MessageBox.Show("Esta versao do Windows nao permite pausar o processo inteiro.", "Transcricao OBS", MessageBoxButtons.OK, MessageBoxIcon.Information); return; }
            _pausado = !_pausado; _pausar.Text = _pausado ? "CONTINUAR" : "PAUSAR"; _fase.Text = _pausado ? "PAUSADO" : "RETOMANDO";
        }
        finally { Marshal.FreeHGlobal(ptr); }
    }

    void Cancelar()
    {
        if (_processo == null || _processo.HasExited) return;
        if (MessageBox.Show("Cancelar a transcricao em andamento?\n\nO video original sera mantido.", "Transcricao OBS", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
        try { ProcessStartInfo psi = new ProcessStartInfo("taskkill.exe", "/PID " + _processo.Id + " /T /F"); psi.UseShellExecute = false; psi.CreateNoWindow = true; Process.Start(psi).WaitForExit(5000); }
        catch { try { _processo.Kill(); } catch { } }
        Finalizar(false, "CANCELADO");
    }

    void GuardarResultadoDaRepeticao()
    {
        bool parcial = !string.Equals(_videoExecucao, _video, StringComparison.OrdinalIgnoreCase);
        if (!parcial && _repeticoesTotal == 1) return;
        string origem = Path.Combine(Path.GetDirectoryName(_videoExecucao), Path.GetFileNameWithoutExtension(_videoExecucao));
        string destino = BaseDestinoTrecho();
        string[] sufixos = { ".txt", ".srt", " - falas.txt", " - sem nomes.srt" };
        foreach (string sufixo in sufixos)
        {
            try { if (File.Exists(origem + sufixo)) File.Copy(origem + sufixo, destino + sufixo, true); }
            catch { }
        }
    }

    bool ResultadoDaRepeticaoExiste()
    {
        string origem = Path.Combine(Path.GetDirectoryName(_videoExecucao), Path.GetFileNameWithoutExtension(_videoExecucao));
        return File.Exists(origem + ".txt") && File.Exists(origem + ".srt") &&
               new FileInfo(origem + ".txt").Length > 0 && new FileInfo(origem + ".srt").Length > 0;
    }

    void GuardarVideoDoTrecho()
    {
        if (string.IsNullOrEmpty(_pastaTemporaria) || !File.Exists(_videoExecucao)) return;
        string destino = BaseDestinoTrecho() + Path.GetExtension(_video);
        try { File.Copy(_videoExecucao, destino, true); } catch { }
    }

    string BaseDestinoTrecho()
    {
        string destino = Path.Combine(Path.GetDirectoryName(_video), Path.GetFileNameWithoutExtension(_video));
        destino += _repeticoesTotal > 1 ? " - trecho " + _repeticaoAtual.ToString("00") + " - " : " - trecho ";
        return destino + FormatarMarcaArquivo(_inicioSegundos) + " a " + FormatarMarcaArquivo(_fimSegundos);
    }

    static string FormatarMarcaArquivo(double segundos)
    {
        long total = (long)Math.Max(0, Math.Round(segundos));
        return ((int)(total / 3600)).ToString("00") + "h" + ((int)((total % 3600) / 60)).ToString("00") + "m" + ((int)(total % 60)).ToString("00") + "s";
    }

    void LimparTemporario()
    {
        if (string.IsNullOrEmpty(_pastaTemporaria)) return;
        try { Directory.Delete(_pastaTemporaria, true); } catch { }
        _pastaTemporaria = null;
    }

    void Finalizar(bool ok) { Finalizar(ok, null); }
    void Finalizar(bool ok, string estado)
    {
        _timer.Stop(); LerLog(); _barra.Valor = ok ? 100 : _barra.Valor; _fase.Text = estado ?? (ok ? "TRANSCRICAO CONCLUIDA" : "NAO FOI POSSIVEL CONCLUIR"); _fase.ForeColor = ok ? Cores.Sucesso : Cores.Ciano;
        _detalhe.Text = ok ? "Os arquivos foram salvos ao lado do video." : "Consulte o registro abaixo para ver o que aconteceu.";
        _iniciar.Enabled = true; _pausar.Enabled = false; _cancelar.Enabled = false; _abrirPasta.Enabled = true; _pausar.Text = "PAUSAR"; _pausado = false; _processo = null;
        _intervalos.Enabled = true; _repeticoes.Enabled = true; _cpu.Enabled = true;
        LimparTemporario();
    }

    void AbrirPasta()
    {
        if (string.IsNullOrEmpty(_video)) return; string txt = Path.Combine(Path.GetDirectoryName(_video), Path.GetFileNameWithoutExtension(_video) + ".txt");
        try { Process.Start("explorer.exe", File.Exists(txt) ? "/select,\"" + txt + "\"" : "\"" + Path.GetDirectoryName(_video) + "\""); } catch { }
    }

    void AoFechar(object sender, FormClosingEventArgs e)
    {
        if (_processo == null || _processo.HasExited) return;
        if (MessageBox.Show("A transcricao ainda esta em andamento.\n\nDeseja cancelar e fechar?", "Transcricao OBS", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) { e.Cancel = true; return; }
        try { _processo.Kill(); } catch { }
        LimparTemporario();
    }
}

internal sealed class IntervaloVideo
{
    public double Inicio; public double Fim;
    public IntervaloVideo(double inicio, double fim) { Inicio = inicio; Fim = fim; }
}

internal sealed class ItemCombo
{
    public string Text; public string Value;
    public ItemCombo(string text, string value) { Text = text; Value = value; }
    public override string ToString() { return Text; }
}
