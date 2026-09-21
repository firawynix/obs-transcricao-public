<#
    lib-quadro.ps1 - analise de quadro do Teams.

    No Teams, a miniatura de quem esta falando ganha uma borda azul-violeta
    (R~130 G~128 B~225) e o nome fica num chip no canto inferior esquerdo
    da propria miniatura. Aqui achamos essa borda e recortamos o chip.

    O trabalho pesado e em C# porque sao milhoes de pixels por quadro.
#>

if (-not ("Quadro" -as [type])) {

Add-Type -AssemblyName System.Drawing

Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class Quadro
{
    // azul-violeta do realce do Teams contra fundo escuro
    static bool EhAcento(byte r, byte g, byte b, int diffMin, int bMin)
    {
        if (b < bMin) return false;
        if (b - r < diffMin) return false;
        if (b - g < diffMin) return false;
        if (Math.Abs(r - g) > 40) return false;   // realce e azul puro: R e G parecidos
        return true;
    }

    // Versao por COR-ALVO: serve para qualquer plataforma. Teams e (130,128,225),
    // Google Meet e (175,198,240) - muda so o alvo, a logica e a mesma.
    static bool PertoDaCor(byte r, byte g, byte b, int ar, int ag, int ab, int tol)
    {
        return Math.Abs(r - ar) <= tol && Math.Abs(g - ag) <= tol && Math.Abs(b - ab) <= tol;
    }

    public static int[][] BordasPorCor(string caminho, int corridaMin, int ar, int ag, int ab, int tol, int tolX)
    {
        using (Bitmap bmp = new Bitmap(caminho))
        {
            int W = bmp.Width, H = bmp.Height;
            BitmapData d = bmp.LockBits(new Rectangle(0, 0, W, H),
                                        ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
            int stride = d.Stride;
            byte[] buf = new byte[stride * H];
            Marshal.Copy(d.Scan0, buf, 0, buf.Length);
            bmp.UnlockBits(d);

            var grupos = new System.Collections.Generic.List<int[]>();

            for (int y = 0; y < H; y++)
            {
                int b0 = y * stride;
                int ini = -1;
                for (int x = 0; x <= W; x++)
                {
                    bool acc = false;
                    if (x < W)
                    {
                        int i = b0 + x * 3;
                        acc = PertoDaCor(buf[i + 2], buf[i + 1], buf[i], ar, ag, ab, tol);
                    }
                    if (acc) { if (ini < 0) ini = x; continue; }
                    if (ini < 0) continue;

                    int fim = x - 1;
                    if (fim - ini + 1 >= corridaMin)
                    {
                        int achou = -1;
                        for (int k = 0; k < grupos.Count; k++)
                            if (Math.Abs(grupos[k][0] - ini) <= tolX && Math.Abs(grupos[k][2] - fim) <= tolX)
                            { achou = k; break; }

                        if (achou < 0) grupos.Add(new int[] { ini, y, fim, y, 1 });
                        else
                        {
                            var gr = grupos[achou];
                            if (ini < gr[0]) gr[0] = ini;
                            if (fim > gr[2]) gr[2] = fim;
                            if (y < gr[1]) gr[1] = y;
                            if (y > gr[3]) gr[3] = y;
                            gr[4]++;
                        }
                    }
                    ini = -1;
                }
            }

            var bons = new System.Collections.Generic.List<int[]>();
            foreach (var g in grupos)
                if (g[4] >= 2 && (g[3] - g[1]) >= 40) bons.Add(g);

            bons.Sort(delegate(int[] a, int[] b) {
                long areaA = (long)(a[2] - a[0]) * (a[3] - a[1]);
                long areaB = (long)(b[2] - b[0]) * (b[3] - b[1]);
                return areaB.CompareTo(areaA);
            });
            return bons.ToArray();
        }
    }

    // Procura linhas horizontais compridas na cor de realce. As bordas de cima e de
    // baixo de UMA MESMA miniatura tem o mesmo intervalo em x - e assim que agrupamos,
    // senao duas pessoas realcadas ao mesmo tempo viram uma caixa gigante.
    // Devolve uma lista de {x0,y0,x1,y1,linhas}, da maior para a menor.
    public static int[][] BordasAtivas(string caminho, int corridaMin, int diffMin, int bMin, int tolX)
    {
        using (Bitmap bmp = new Bitmap(caminho))
        {
            int W = bmp.Width, H = bmp.Height;
            BitmapData d = bmp.LockBits(new Rectangle(0, 0, W, H),
                                        ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
            int stride = d.Stride;
            byte[] buf = new byte[stride * H];
            Marshal.Copy(d.Scan0, buf, 0, buf.Length);
            bmp.UnlockBits(d);

            var grupos = new System.Collections.Generic.List<int[]>();  // x0,y0,x1,y1,linhas

            for (int y = 0; y < H; y++)
            {
                int b0 = y * stride;
                int ini = -1;

                for (int x = 0; x <= W; x++)
                {
                    bool acc = false;
                    if (x < W)
                    {
                        int i = b0 + x * 3;                   // ordem BGR
                        acc = EhAcento(buf[i + 2], buf[i + 1], buf[i], diffMin, bMin);
                    }

                    if (acc)
                    {
                        if (ini < 0) ini = x;
                        continue;
                    }
                    if (ini < 0) continue;

                    int fim = x - 1;
                    if (fim - ini + 1 >= corridaMin)
                    {
                        // acha um grupo com o mesmo intervalo horizontal
                        int achou = -1;
                        for (int k = 0; k < grupos.Count; k++)
                        {
                            if (Math.Abs(grupos[k][0] - ini) <= tolX && Math.Abs(grupos[k][2] - fim) <= tolX)
                            { achou = k; break; }
                        }
                        if (achou < 0)
                        {
                            grupos.Add(new int[] { ini, y, fim, y, 1 });
                        }
                        else
                        {
                            var gr = grupos[achou];
                            if (ini < gr[0]) gr[0] = ini;
                            if (fim > gr[2]) gr[2] = fim;
                            if (y < gr[1]) gr[1] = y;
                            if (y > gr[3]) gr[3] = y;
                            gr[4]++;
                        }
                    }
                    ini = -1;
                }
            }

            // so vale como miniatura o que tem borda em cima E embaixo, com altura de gente
            var bons = new System.Collections.Generic.List<int[]>();
            foreach (var g in grupos)
                if (g[4] >= 2 && (g[3] - g[1]) >= 40) bons.Add(g);

            bons.Sort(delegate(int[] a, int[] b) {
                long areaA = (long)(a[2] - a[0]) * (a[3] - a[1]);
                long areaB = (long)(b[2] - b[0]) * (b[3] - b[1]);
                return areaB.CompareTo(areaA);
            });
            return bons.ToArray();
        }
    }

    // Recorta um pedaco e amplia (o nome tem ~20px de altura: ampliar ajuda o OCR)
    public static void Recortar(string origem, string destino, int x, int y, int w, int h, int escala)
    {
        using (Bitmap src = new Bitmap(origem))
        {
            Rectangle r = Rectangle.Intersect(new Rectangle(x, y, w, h),
                                              new Rectangle(0, 0, src.Width, src.Height));
            if (r.Width <= 4 || r.Height <= 4) throw new Exception("recorte fora da imagem");

            using (Bitmap corte = src.Clone(r, PixelFormat.Format24bppRgb))
            using (Bitmap grande = new Bitmap(corte.Width * escala, corte.Height * escala))
            {
                using (Graphics g = Graphics.FromImage(grande))
                {
                    g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                    g.DrawImage(corte, 0, 0, grande.Width, grande.Height);
                }
                grande.Save(destino, ImageFormat.Png);
            }
        }
    }
}
"@
}
