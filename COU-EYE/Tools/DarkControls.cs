using System;using System.Drawing;using System.Drawing.Drawing2D;using System.Windows.Forms;
namespace CouEyeUI {
 public static class PortableFont {
  static System.Drawing.Text.PrivateFontCollection fonts;
  public static FontFamily Family {get;private set;}
  [System.Runtime.InteropServices.DllImport("gdi32.dll",CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
  static extern int AddFontResourceEx(string path,uint flags,IntPtr reserved);
  [System.Runtime.InteropServices.DllImport("gdi32.dll")] static extern IntPtr AddFontMemResourceEx(IntPtr data,uint length,IntPtr reserved,ref uint count);
  static System.Collections.Generic.List<IntPtr> buffers=new System.Collections.Generic.List<IntPtr>();
  [System.Runtime.InteropServices.DllImport("gdi32.dll",CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
  static extern uint GetGlyphIndices(IntPtr dc,string text,int count,[System.Runtime.InteropServices.Out] ushort[] glyphs,uint flags);
  [System.Runtime.InteropServices.DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc,IntPtr obj);
  [System.Runtime.InteropServices.DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
  public static void Load(string directory){
   fonts=new System.Drawing.Text.PrivateFontCollection();
   foreach(string name in new[]{"NanumGothic-Regular.ttf","NanumGothic-Bold.ttf"}){
    string path=System.IO.Path.Combine(directory,name);
    byte[] data=System.IO.File.ReadAllBytes(path);IntPtr memory=System.Runtime.InteropServices.Marshal.AllocHGlobal(data.Length);buffers.Add(memory);System.Runtime.InteropServices.Marshal.Copy(data,0,memory,data.Length);uint count=0;
    if(AddFontMemResourceEx(memory,(uint)data.Length,IntPtr.Zero,ref count)==IntPtr.Zero)throw new InvalidOperationException("Cannot load bundled Korean font: "+path);
    fonts.AddMemoryFont(memory,data.Length);
   }
   Family=fonts.Families[0];
   if(!HasGlyphs("운송장 번호 입력 검사 완료"))throw new InvalidOperationException("Bundled font lacks Korean glyphs.");
  }
  public static bool HasGlyphs(string text){
   using(var bitmap=new Bitmap(1,1))using(var graphics=Graphics.FromImage(bitmap))using(var font=new Font(Family,12)){
    IntPtr dc=graphics.GetHdc(),handle=font.ToHfont(),previous=SelectObject(dc,handle);
    try{var glyphs=new ushort[text.Length];if(GetGlyphIndices(dc,text,text.Length,glyphs,1)==0xffffffff)return false;foreach(var glyph in glyphs)if(glyph==0xffff)return false;return true;}
    finally{SelectObject(dc,previous);DeleteObject(handle);graphics.ReleaseHdc(dc);}
   }
  }
 }
 public class Entry:TextBox {
  public string Hint="";
  protected override void OnTextChanged(EventArgs e){base.OnTextChanged(e);Invalidate();}
  protected override void WndProc(ref Message m){base.WndProc(ref m);if((m.Msg==15||m.Msg==0x317||m.Msg==0x318)&&Text.Length==0){using(var g=m.Msg==15?Graphics.FromHwnd(Handle):Graphics.FromHdc(m.WParam)){TextRenderer.DrawText(g,Hint,Font,ClientRectangle,Color.FromArgb(150,150,150),BackColor,TextFormatFlags.Left|TextFormatFlags.VerticalCenter);}}}
 }
 public class Card:Panel {
  public int Radius=10;public Color BorderColor=Color.FromArgb(48,48,48);
  public Card(){DoubleBuffered=true;BackColor=Color.FromArgb(8,8,8);}
  protected override void OnPaint(PaintEventArgs e){base.OnPaint(e);e.Graphics.SmoothingMode=SmoothingMode.AntiAlias;using(var p=Shape(Width-1,Height-1,Radius))using(var pen=new Pen(BorderColor)){e.Graphics.DrawPath(pen,p);}}
  public static GraphicsPath Shape(int w,int h,int r){var p=new GraphicsPath();int d=r*2;p.AddArc(0,0,d,d,180,90);p.AddArc(w-d,0,d,d,270,90);p.AddArc(w-d,h-d,d,d,0,90);p.AddArc(0,h-d,d,d,90,90);p.CloseFigure();return p;}
 }
 public class ActionButton:Button {
  bool hover;public ActionButton(){FlatStyle=FlatStyle.Flat;FlatAppearance.BorderSize=0;Cursor=Cursors.Hand;SetStyle(ControlStyles.UserPaint|ControlStyles.AllPaintingInWmPaint|ControlStyles.OptimizedDoubleBuffer,true);}
  protected override void OnMouseEnter(EventArgs e){hover=true;Invalidate();base.OnMouseEnter(e);}
  protected override void OnMouseLeave(EventArgs e){hover=false;Invalidate();base.OnMouseLeave(e);}
  protected override void OnPaint(PaintEventArgs e){e.Graphics.Clear(Parent.BackColor);e.Graphics.SmoothingMode=SmoothingMode.AntiAlias;using(var p=Card.Shape(Width-1,Height-1,Math.Min(22,Height/2-1)))using(var b=new SolidBrush(!Enabled?Color.FromArgb(16,16,16):hover?Color.FromArgb(58,58,58):Color.FromArgb(35,35,35))){e.Graphics.FillPath(b,p);if(Focused)using(var pen=new Pen(Color.Gray)){e.Graphics.DrawPath(pen,p);}}TextRenderer.DrawText(e.Graphics,Text,Font,ClientRectangle,Enabled?Color.White:Color.FromArgb(115,115,115),TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter);}
 }
}
