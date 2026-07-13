$ErrorActionPreference = 'Stop'

function ConvertTo-PowerShellSingleQuotedString {
    param([string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function New-EncodedPowerShellCommand {
    param([string]$Command)
    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
}

function Get-WindowsPowerShellPath {
    return (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
}


Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()


Add-Type -TypeDefinition @"
using System;
using System.Security.Cryptography;
using System.Text;

public static class JbbProofOfWork {
    public static string Solve(string nonce, string deviceId, int difficulty, int maxIterations) {
        if (difficulty < 1) difficulty = 1;
        if (difficulty > 6) difficulty = 6;
        string prefix = new string('0', difficulty);
        using (SHA256 sha = SHA256.Create()) {
            for (int i = 0; i < maxIterations; i++) {
                string answer = i.ToString();
                byte[] bytes = Encoding.UTF8.GetBytes(nonce + ":" + deviceId + ":" + answer);
                byte[] hash = sha.ComputeHash(bytes);
                char[] chars = new char[hash.Length * 2];
                for (int j = 0; j < hash.Length; j++) {
                    byte b = hash[j];
                    chars[j * 2] = GetHexValue(b / 16);
                    chars[j * 2 + 1] = GetHexValue(b % 16);
                }
                string hex = new string(chars);
                if (hex.StartsWith(prefix, StringComparison.Ordinal)) return answer;
            }
        }
        throw new Exception("本机验证计算超时，请重试。");
    }

    private static char GetHexValue(int i) {
        return (char)(i < 10 ? i + 48 : i - 10 + 97);
    }
}
"@

Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing,System.Net.Http -TypeDefinition @"
using System;
using System.Collections;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public sealed class JbbHttpResult {
    public bool Ok { get; set; }
    public int StatusCode { get; set; }
    public string Body { get; set; }
    public byte[] Bytes { get; set; }
    public string Error { get; set; }
}

public static class JbbAsyncHttp {
    private static readonly HttpClient Client = CreateClient();

    private static HttpClient CreateClient() {
        HttpClient client = new HttpClient();
        client.Timeout = System.Threading.Timeout.InfiniteTimeSpan;
        return client;
    }

    public static async Task<JbbHttpResult> SendAsync(string url, string method, IDictionary headers, string body, int timeoutSeconds) {
        JbbHttpResult result = new JbbHttpResult { Body = "", Bytes = new byte[0], Error = "" };
        try {
            using (HttpRequestMessage request = new HttpRequestMessage(new HttpMethod(method), url)) {
                if (!String.IsNullOrEmpty(body)) request.Content = new StringContent(body, Encoding.UTF8, "application/json");
                if (headers != null) {
                    foreach (DictionaryEntry header in headers) {
                        string name = Convert.ToString(header.Key);
                        string value = Convert.ToString(header.Value);
                        if (!String.IsNullOrEmpty(name) && !String.IsNullOrEmpty(value)) request.Headers.TryAddWithoutValidation(name, value);
                    }
                }
                using (System.Threading.CancellationTokenSource cts = new System.Threading.CancellationTokenSource(TimeSpan.FromSeconds(Math.Max(1, timeoutSeconds)))) {
                    using (HttpResponseMessage response = await Client.SendAsync(request, HttpCompletionOption.ResponseContentRead, cts.Token).ConfigureAwait(false)) {
                        byte[] bytes = response.Content == null ? new byte[0] : await response.Content.ReadAsByteArrayAsync().ConfigureAwait(false);
                        result.StatusCode = (int)response.StatusCode;
                        result.Bytes = bytes;
                        result.Body = bytes.Length == 0 ? "" : Encoding.UTF8.GetString(bytes);
                        result.Ok = response.IsSuccessStatusCode;
                        if (!result.Ok) result.Error = "HTTP " + result.StatusCode;
                    }
                }
            }
        }
        catch (Exception ex) {
            result.Ok = false;
            result.Error = ex.GetBaseException().Message;
        }
        return result;
    }

    public static async Task<JbbHttpResult> DelayFailureAsync(int milliseconds) {
        await Task.Delay(Math.Max(1, milliseconds)).ConfigureAwait(false);
        return new JbbHttpResult { Ok = false, StatusCode = 0, Body = "", Bytes = new byte[0], Error = "simulated slow network" };
    }
}

public static class JbbUiNative {
    [DllImport("user32.dll")]
    private static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")]
    private static extern int GetGuiResources(IntPtr process, int flags);
    public static void EnableDpiAwareness() { try { SetProcessDPIAware(); } catch { } }
    public static int GetGdiCount() { try { return GetGuiResources(System.Diagnostics.Process.GetCurrentProcess().Handle, 0); } catch { return -1; } }
    public static int GetUserCount() { try { return GetGuiResources(System.Diagnostics.Process.GetCurrentProcess().Handle, 1); } catch { return -1; } }
}

public static class JbbUiGeometry {
    public static GraphicsPath Rounded(Rectangle bounds, int radius) {
        int r = Math.Max(2, Math.Min(radius, Math.Min(bounds.Width, bounds.Height) / 2));
        int d = r * 2;
        GraphicsPath path = new GraphicsPath();
        path.AddArc(bounds.X, bounds.Y, d, d, 180, 90);
        path.AddArc(bounds.Right - d, bounds.Y, d, d, 270, 90);
        path.AddArc(bounds.Right - d, bounds.Bottom - d, d, d, 0, 90);
        path.AddArc(bounds.X, bounds.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }
}

public class JbbRoundedPanel : Panel {
    public int CornerRadius { get; set; }
    public Color BorderColor { get; set; }
    public float BorderThickness { get; set; }
    public JbbRoundedPanel() { DoubleBuffered = true; ResizeRedraw = true; BackColor = Color.White; CornerRadius = 16; BorderColor = Color.FromArgb(218, 228, 242); BorderThickness = 1f; }
    protected override void OnResize(EventArgs e) {
        base.OnResize(e);
        if (Width > 0 && Height > 0) using (GraphicsPath p = JbbUiGeometry.Rounded(new Rectangle(0, 0, Width, Height), CornerRadius)) Region = new Region(p);
    }
    protected override void OnPaint(PaintEventArgs e) {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        Rectangle rect = new Rectangle(0, 0, Width - 1, Height - 1);
        using (GraphicsPath p = JbbUiGeometry.Rounded(rect, CornerRadius)) {
            using (SolidBrush b = new SolidBrush(BackColor)) e.Graphics.FillPath(b, p);
            using (Pen pen = new Pen(BorderColor, BorderThickness)) e.Graphics.DrawPath(pen, p);
        }
        base.OnPaint(e);
    }
}

public class JbbRoundedButton : Control, IButtonControl {
    public int CornerRadius { get; set; }
    public Color BorderColor { get; set; }
    public float BorderThickness { get; set; }
    public DialogResult DialogResult { get; set; }
    private bool hover;
    public JbbRoundedButton() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.Selectable, true);
        DoubleBuffered = true; ResizeRedraw = true; CornerRadius = 10; BorderColor = Color.FromArgb(191, 219, 254); BorderThickness = 1f;
        Cursor = Cursors.Hand; TabStop = true; DialogResult = DialogResult.None;
    }
    protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hover = false; Invalidate(); base.OnMouseLeave(e); }
    public void NotifyDefault(bool value) { Invalidate(); }
    public void PerformClick() { if (Enabled && Visible) OnClick(EventArgs.Empty); }
    protected override void OnMouseUp(MouseEventArgs e) { base.OnMouseUp(e); }
    protected override void OnKeyDown(KeyEventArgs e) { if (e.KeyCode == Keys.Space || e.KeyCode == Keys.Enter) { PerformClick(); e.Handled = true; } base.OnKeyDown(e); }
    protected override void OnResize(EventArgs e) {
        base.OnResize(e);
        if (Width > 0 && Height > 0) using (GraphicsPath p = JbbUiGeometry.Rounded(new Rectangle(0, 0, Width, Height), CornerRadius)) Region = new Region(p);
    }
    protected override void OnPaint(PaintEventArgs e) {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        Color fill = Enabled ? BackColor : Color.FromArgb(235, 240, 248);
        if (hover && Enabled) fill = ControlPaint.Light(fill, 0.06f);
        Rectangle rect = new Rectangle(0, 0, Width - 1, Height - 1);
        using (GraphicsPath p = JbbUiGeometry.Rounded(rect, CornerRadius)) {
            using (SolidBrush b = new SolidBrush(fill)) e.Graphics.FillPath(b, p);
            if (BorderThickness > 0) using (Pen pen = new Pen(BorderColor, BorderThickness)) e.Graphics.DrawPath(pen, p);
        }
        TextRenderer.DrawText(e.Graphics, Text, Font, rect, Enabled ? ForeColor : Color.FromArgb(148, 163, 184),
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
        if (Focused) ControlPaint.DrawFocusRectangle(e.Graphics, new Rectangle(4, 4, Width - 8, Height - 8), ForeColor, Color.Transparent);
    }
}

public class JbbGooeyButton : JbbRoundedButton {
    private sealed class Particle {
        public float Angle;
        public float StartDistance;
        public float EndDistance;
        public float Radius;
        public Color Color;
    }

    private readonly Timer animationTimer;
    private readonly List<Particle> particles = new List<Particle>();
    private readonly Random random = new Random();
    private DateTime animationStarted;
    private bool hovering;
    private bool bursting;
    private float hoverProgress;

    public JbbGooeyButton() {
        animationTimer = new Timer();
        animationTimer.Interval = 16;
        animationTimer.Tick += delegate {
            if (bursting && (DateTime.UtcNow - animationStarted).TotalMilliseconds >= 280) bursting = false;
            float target = hovering ? 1f : 0f;
            hoverProgress += (target - hoverProgress) * 0.24f;
            if (!bursting && Math.Abs(target - hoverProgress) < 0.015f) {
                hoverProgress = target;
                animationTimer.Stop();
            }
            Invalidate();
        };
    }

    public void TriggerBurst() {
        if (!SystemInformation.IsMenuAnimationEnabled) { bursting = false; Invalidate(); return; }
        particles.Clear();
        Color[] palette = {
            Color.FromArgb(147, 197, 253), Color.FromArgb(96, 165, 250),
            Color.FromArgb(52, 211, 153), Color.FromArgb(191, 219, 254)
        };
        for (int i = 0; i < 12; i++) {
            double baseAngle = Math.PI * 2.0 * i / 12.0;
            particles.Add(new Particle {
                Angle = (float)(baseAngle + (random.NextDouble() - 0.5) * 0.18),
                StartDistance = 28f + (float)random.NextDouble() * 30f,
                EndDistance = 7f + (float)random.NextDouble() * 8f,
                Radius = 3f + (float)random.NextDouble() * 3f,
                Color = palette[random.Next(palette.Length)]
            });
        }
        animationStarted = DateTime.UtcNow;
        bursting = true;
        animationTimer.Start();
        Invalidate();
    }

    protected override void OnMouseEnter(EventArgs e) {
        hovering = true;
        animationTimer.Start();
        base.OnMouseEnter(e);
    }

    protected override void OnMouseLeave(EventArgs e) {
        hovering = false;
        animationTimer.Start();
        base.OnMouseLeave(e);
    }

    protected override void OnMouseUp(MouseEventArgs e) {
        if (e.Button == MouseButtons.Left && ClientRectangle.Contains(e.Location)) TriggerBurst();
        base.OnMouseUp(e);
    }

    protected override void OnPaint(PaintEventArgs e) {
        base.OnPaint(e);
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        RectangleF glow = new RectangleF(3, 3, Math.Max(1, Width - 7), Math.Max(1, Height - 7));
        if (hoverProgress > 0.01f) {
            int alpha = (int)(70 * hoverProgress);
            using (Pen pen = new Pen(Color.FromArgb(alpha, 219, 234, 254), 2f + hoverProgress * 2f)) {
                using (GraphicsPath path = JbbUiGeometry.Rounded(Rectangle.Round(glow), Math.Max(4, CornerRadius - 2))) e.Graphics.DrawPath(pen, path);
            }
        }
        if (!bursting) return;
        float t = (float)((DateTime.UtcNow - animationStarted).TotalMilliseconds / 280.0);
        if (t < 0f) t = 0f;
        if (t > 1f) t = 1f;
        float move = t < 0.7f ? (float)(1.0 - Math.Pow(1.0 - t / 0.7f, 2.2)) : 1f;
        float scale = t < 0.25f ? t / 0.25f : (t > 0.72f ? (1f - t) / 0.28f : 1f);
        float cx = Width / 2f, cy = Height / 2f;
        foreach (Particle p in particles) {
            float distance = p.StartDistance + (p.EndDistance - p.StartDistance) * move;
            float x = cx + (float)Math.Cos(p.Angle) * distance;
            float y = cy + (float)Math.Sin(p.Angle) * distance * 0.55f;
            float radius = Math.Max(0.5f, p.Radius * scale);
            using (SolidBrush brush = new SolidBrush(Color.FromArgb((int)(210 * scale), p.Color))) {
                e.Graphics.FillEllipse(brush, x - radius, y - radius, radius * 2f, radius * 2f);
            }
        }
    }
}

public class JbbAmountInput : Control {
    private readonly TextBox editor;
    private bool hovering;
    private bool syncing;
    private string lastValidText = "";

    public JbbAmountInput() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.Selectable, true);
        BackColor = Color.White;
        ForeColor = Color.FromArgb(15, 23, 42);
        Cursor = Cursors.IBeam;
        TabStop = true;
        editor = new TextBox();
        editor.BorderStyle = BorderStyle.None;
        editor.BackColor = Color.White;
        editor.ForeColor = ForeColor;
        editor.MaxLength = 14;
        editor.TabStop = false;
        editor.KeyPress += EditorKeyPress;
        editor.TextChanged += EditorTextChanged;
        editor.GotFocus += delegate { Invalidate(); };
        editor.LostFocus += delegate { Invalidate(); };
        editor.MouseEnter += delegate { hovering = true; Invalidate(); };
        editor.MouseLeave += delegate { if (!ClientRectangle.Contains(PointToClient(Cursor.Position))) hovering = false; Invalidate(); };
        Controls.Add(editor);
        Size = new Size(292, 44);
    }

    public override string Text {
        get { return editor == null ? base.Text : editor.Text; }
        set {
            string next = value ?? "";
            if (editor != null) { if (editor.Text != next) editor.Text = next; return; }
            if (base.Text != next) base.Text = next;
        }
    }

    public override Font Font {
        get { return base.Font; }
        set { base.Font = value; if (editor != null) editor.Font = value; LayoutEditor(); }
    }

    public override Color ForeColor {
        get { return base.ForeColor; }
        set { base.ForeColor = value; if (editor != null) editor.ForeColor = value; }
    }

    protected override void OnResize(EventArgs e) { base.OnResize(e); LayoutEditor(); }
    protected override void OnEnabledChanged(EventArgs e) {
        base.OnEnabledChanged(e);
        editor.Enabled = Enabled;
        editor.BackColor = Enabled ? Color.White : Color.FromArgb(248, 250, 252);
        Invalidate();
    }
    protected override void OnMouseEnter(EventArgs e) { hovering = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hovering = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnClick(EventArgs e) { if (Enabled) editor.Focus(); base.OnClick(e); }
    protected override void OnGotFocus(EventArgs e) { if (Enabled) editor.Focus(); base.OnGotFocus(e); }

    private void LayoutEditor() {
        if (editor == null) return;
        int left = ScalePx(12);
        int available = Math.Max(1, Width - left - ScalePx(12));
        int preferred = Math.Max(editor.PreferredHeight, ScalePx(22));
        editor.SetBounds(left, Math.Max(1, (Height - preferred) / 2), available, preferred);
    }

    private int ScalePx(int value) { return Math.Max(1, (int)Math.Round(value * (DeviceDpi > 0 ? DeviceDpi / 96.0 : 1.0))); }

    private void EditorKeyPress(object sender, KeyPressEventArgs e) {
        if (Char.IsControl(e.KeyChar)) return;
        if (!Char.IsDigit(e.KeyChar) && e.KeyChar != '.') { e.Handled = true; return; }
        string selectedAway = editor.Text.Remove(editor.SelectionStart, editor.SelectionLength);
        string candidate = selectedAway.Insert(editor.SelectionStart, e.KeyChar.ToString());
        if (!IsValidAmountText(candidate)) e.Handled = true;
    }

    private void EditorTextChanged(object sender, EventArgs e) {
        if (syncing) return;
        if (!IsValidAmountText(editor.Text)) {
            syncing = true;
            editor.Text = lastValidText;
            editor.SelectionStart = editor.Text.Length;
            syncing = false;
            return;
        }
        lastValidText = editor.Text;
        base.Text = editor.Text;
    }

    private static bool IsValidAmountText(string value) {
        if (String.IsNullOrEmpty(value)) return true;
        int dot = value.IndexOf('.');
        if (dot != value.LastIndexOf('.')) return false;
        for (int i = 0; i < value.Length; i++) if (!Char.IsDigit(value[i]) && value[i] != '.') return false;
        return dot < 0 || value.Length - dot - 1 <= 2;
    }

    protected override void OnPaint(PaintEventArgs e) {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        bool focused = editor.Focused || Focused;
        Color fill = Enabled ? Color.White : Color.FromArgb(248, 250, 252);
        Color border = focused ? Color.FromArgb(20, 99, 255) : (hovering ? Color.FromArgb(147, 197, 253) : Color.FromArgb(203, 213, 225));
        Rectangle rect = new Rectangle(2, 2, Math.Max(1, Width - 5), Math.Max(1, Height - 5));
        using (GraphicsPath path = JbbUiGeometry.Rounded(rect, ScalePx(9))) {
            using (SolidBrush brush = new SolidBrush(fill)) e.Graphics.FillPath(brush, path);
            if (focused) using (Pen glow = new Pen(Color.FromArgb(85, 147, 197, 253), 4f)) e.Graphics.DrawPath(glow, path);
            using (Pen pen = new Pen(border, focused ? 1.8f : 1f)) e.Graphics.DrawPath(pen, path);
        }
    }
}

public sealed class JbbItemCollection : IList {
    private readonly List<object> values = new List<object>();
    private readonly Action changed;
    public JbbItemCollection(Action changedCallback) { changed = changedCallback; }
    public int Add(object value) { values.Add(value); changed(); return values.Count - 1; }
    public void Clear() { values.Clear(); changed(); }
    public bool Contains(object value) { return values.Contains(value); }
    public int IndexOf(object value) { return values.IndexOf(value); }
    public void Insert(int index, object value) { values.Insert(index, value); changed(); }
    public void Remove(object value) { values.Remove(value); changed(); }
    public void RemoveAt(int index) { values.RemoveAt(index); changed(); }
    public object this[int index] { get { return values[index]; } set { values[index] = value; changed(); } }
    public bool IsFixedSize { get { return false; } }
    public bool IsReadOnly { get { return false; } }
    public int Count { get { return values.Count; } }
    public bool IsSynchronized { get { return false; } }
    public object SyncRoot { get { return this; } }
    public void CopyTo(Array array, int index) { ((ICollection)values).CopyTo(array, index); }
    public IEnumerator GetEnumerator() { return values.GetEnumerator(); }
}

internal sealed class JbbDropDownList : ListBox {
    private int hoverIndex = -1;
    public JbbDropDownList() {
        DrawMode = DrawMode.OwnerDrawFixed;
        BorderStyle = BorderStyle.None;
        IntegralHeight = false;
        BackColor = Color.White;
        ForeColor = Color.FromArgb(15, 23, 42);
    }
    protected override void OnMouseMove(MouseEventArgs e) {
        int next = IndexFromPoint(e.Location);
        if (next != hoverIndex) { hoverIndex = next; Invalidate(); }
        base.OnMouseMove(e);
    }
    protected override void OnMouseLeave(EventArgs e) { hoverIndex = -1; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnDrawItem(DrawItemEventArgs e) {
        if (e.Index < 0) return;
        bool selected = (e.State & DrawItemState.Selected) == DrawItemState.Selected;
        Color fill = selected ? Color.FromArgb(239, 246, 255) : (e.Index == hoverIndex ? Color.FromArgb(248, 250, 252) : Color.White);
        using (SolidBrush brush = new SolidBrush(fill)) e.Graphics.FillRectangle(brush, e.Bounds);
        Color textColor = selected ? Color.FromArgb(20, 99, 255) : ForeColor;
        Rectangle textRect = new Rectangle(e.Bounds.X + 12, e.Bounds.Y, Math.Max(1, e.Bounds.Width - 24), e.Bounds.Height);
        TextRenderer.DrawText(e.Graphics, GetItemText(Items[e.Index]), Font, textRect, textColor, TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
    }
}

public class JbbPaymentSelect : Control {
    private readonly JbbItemCollection items;
    private int selectedIndex = -1;
    private bool hovering;
    private JbbRoundedPanel popup;
    public event EventHandler SelectedIndexChanged;

    public JbbPaymentSelect() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.Selectable, true);
        BackColor = Color.White; ForeColor = Color.FromArgb(15, 23, 42); Cursor = Cursors.Hand; TabStop = true;
        items = new JbbItemCollection(delegate { if (selectedIndex >= items.Count) selectedIndex = -1; Invalidate(); });
        Size = new Size(292, 44);
    }
    public JbbItemCollection Items { get { return items; } }
    public int SelectedIndex {
        get { return selectedIndex; }
        set {
            int next = value < 0 || value >= items.Count ? -1 : value;
            if (selectedIndex == next) return;
            selectedIndex = next; Invalidate();
            if (SelectedIndexChanged != null) SelectedIndexChanged(this, EventArgs.Empty);
        }
    }
    public object SelectedItem { get { return selectedIndex >= 0 && selectedIndex < items.Count ? items[selectedIndex] : null; } }
    protected override void OnMouseEnter(EventArgs e) { hovering = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hovering = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnClick(EventArgs e) { base.OnClick(e); if (Enabled) ShowDropDown(); }
    protected override void OnKeyDown(KeyEventArgs e) {
        if (e.KeyCode == Keys.Enter || e.KeyCode == Keys.Space || (e.Alt && e.KeyCode == Keys.Down)) { ShowDropDown(); e.Handled = true; }
        else if (e.KeyCode == Keys.Down && items.Count > 0) { SelectedIndex = Math.Min(items.Count - 1, selectedIndex + 1); e.Handled = true; }
        else if (e.KeyCode == Keys.Up && items.Count > 0) { SelectedIndex = Math.Max(0, selectedIndex - 1); e.Handled = true; }
        base.OnKeyDown(e);
    }
    protected override void OnEnabledChanged(EventArgs e) { base.OnEnabledChanged(e); Invalidate(); }
    protected override void OnVisibleChanged(EventArgs e) { if (!Visible) CloseDropDown(); base.OnVisibleChanged(e); }
    protected override void Dispose(bool disposing) { if (disposing) CloseDropDown(); base.Dispose(disposing); }

    private int ScalePx(int value) { return Math.Max(1, (int)Math.Round(value * (DeviceDpi > 0 ? DeviceDpi / 96.0 : 1.0))); }
    private void CloseDropDown() {
        if (popup == null) return;
        JbbRoundedPanel old = popup;
        popup = null;
        if (old.Parent != null) old.Parent.Controls.Remove(old);
        old.Dispose();
        Invalidate();
    }
    private void ShowDropDown() {
        if (items.Count == 0) return;
        if (popup != null && !popup.IsDisposed) { CloseDropDown(); return; }
        Control overlayParent = Parent;
        while (overlayParent != null && overlayParent.Parent != null && !(overlayParent is JbbBackdropPanel)) overlayParent = overlayParent.Parent;
        if (overlayParent == null) return;
        popup = new JbbRoundedPanel();
        popup.CornerRadius = ScalePx(10);
        popup.BorderColor = Color.FromArgb(203, 213, 225);
        popup.BorderThickness = 1f;
        popup.BackColor = Color.White;
        JbbDropDownList list = new JbbDropDownList();
        list.Font = Font; list.ItemHeight = ScalePx(36); list.Dock = DockStyle.Fill;
        foreach (object item in items) list.Items.Add(item);
        list.SelectedIndex = selectedIndex;
        int visibleCount = Math.Min(6, Math.Max(1, items.Count));
        int popupHeight = visibleCount * list.ItemHeight + ScalePx(8);
        popup.Size = new Size(Width, popupHeight);
        popup.Padding = new Padding(ScalePx(4));
        popup.Controls.Add(list);
        Point location = overlayParent.PointToClient(PointToScreen(new Point(0, Height + ScalePx(4))));
        if (location.Y + popupHeight > overlayParent.ClientSize.Height) location = overlayParent.PointToClient(PointToScreen(new Point(0, -popupHeight - ScalePx(4))));
        location.X = Math.Max(0, Math.Min(location.X, Math.Max(0, overlayParent.ClientSize.Width - popup.Width)));
        location.Y = Math.Max(0, Math.Min(location.Y, Math.Max(0, overlayParent.ClientSize.Height - popup.Height)));
        popup.Location = location;
        list.Click += delegate { if (list.SelectedIndex >= 0) SelectedIndex = list.SelectedIndex; CloseDropDown(); Focus(); };
        list.KeyDown += delegate(object sender, KeyEventArgs e) { if (e.KeyCode == Keys.Enter) { if (list.SelectedIndex >= 0) SelectedIndex = list.SelectedIndex; CloseDropDown(); Focus(); } else if (e.KeyCode == Keys.Escape) { CloseDropDown(); Focus(); } };
        list.LostFocus += delegate { BeginInvoke(new Action(delegate { if (popup != null && !popup.ContainsFocus) CloseDropDown(); })); };
        overlayParent.Controls.Add(popup);
        popup.BringToFront();
        list.Focus();
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e) {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        bool focused = Focused || (popup != null && !popup.IsDisposed);
        Color fill = Enabled ? Color.White : Color.FromArgb(248, 250, 252);
        Color border = focused ? Color.FromArgb(20, 99, 255) : (hovering ? Color.FromArgb(147, 197, 253) : Color.FromArgb(203, 213, 225));
        Rectangle rect = new Rectangle(2, 2, Math.Max(1, Width - 5), Math.Max(1, Height - 5));
        using (GraphicsPath path = JbbUiGeometry.Rounded(rect, ScalePx(9))) {
            using (SolidBrush brush = new SolidBrush(fill)) e.Graphics.FillPath(brush, path);
            if (focused) using (Pen glow = new Pen(Color.FromArgb(85, 147, 197, 253), 4f)) e.Graphics.DrawPath(glow, path);
            using (Pen pen = new Pen(border, focused ? 1.8f : 1f)) e.Graphics.DrawPath(pen, path);
        }
        string label = SelectedItem == null ? "请选择支付方式" : Convert.ToString(SelectedItem);
        Color textColor = SelectedItem == null ? Color.FromArgb(148, 163, 184) : (Enabled ? ForeColor : Color.FromArgb(148, 163, 184));
        Rectangle textRect = new Rectangle(ScalePx(14), 0, Math.Max(1, Width - ScalePx(52)), Height);
        TextRenderer.DrawText(e.Graphics, label, Font, textRect, textColor, TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
        int cx = Width - ScalePx(20), cy = Height / 2;
        using (Pen arrow = new Pen(Enabled ? Color.FromArgb(71, 85, 105) : Color.FromArgb(148, 163, 184), 1.8f)) {
            arrow.StartCap = LineCap.Round; arrow.EndCap = LineCap.Round; arrow.LineJoin = LineJoin.Round;
            e.Graphics.DrawLines(arrow, new[] { new Point(cx - ScalePx(4), cy - ScalePx(2)), new Point(cx, cy + ScalePx(2)), new Point(cx + ScalePx(4), cy - ScalePx(2)) });
        }
        if (Focused) ControlPaint.DrawFocusRectangle(e.Graphics, new Rectangle(6, 6, Width - 12, Height - 12), ForeColor, Color.Transparent);
    }
}

public class JbbProgressBar : Control {
    private int progressValue;
    public int Value {
        get { return progressValue; }
        set { progressValue = Math.Max(0, Math.Min(100, value)); Invalidate(); }
    }
    public Color TrackColor { get; set; }
    public Color FillColor { get; set; }
    public JbbProgressBar() {
        DoubleBuffered = true; ResizeRedraw = true; progressValue = 0;
        TrackColor = Color.FromArgb(226, 232, 240); FillColor = Color.FromArgb(20, 99, 255);
    }
    protected override void OnPaint(PaintEventArgs e) {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        Rectangle track = new Rectangle(0, 0, Math.Max(1, Width - 1), Math.Max(1, Height - 1));
        int radius = Math.Max(2, Height / 2);
        using (GraphicsPath path = JbbUiGeometry.Rounded(track, radius))
        using (SolidBrush brush = new SolidBrush(TrackColor)) e.Graphics.FillPath(brush, path);
        int fillWidth = (int)Math.Round(track.Width * (progressValue / 100.0));
        if (fillWidth > 0) {
            Rectangle fill = new Rectangle(0, 0, Math.Max(Math.Min(fillWidth, track.Width), Math.Min(track.Height, track.Width)), track.Height);
            using (GraphicsPath path = JbbUiGeometry.Rounded(fill, radius))
            using (SolidBrush brush = new SolidBrush(FillColor)) e.Graphics.FillPath(brush, path);
        }
    }
}

public class JbbEllipsisLabel : Control {
    public bool AlignRight { get; set; }
    public JbbEllipsisLabel() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent; AlignRight = true;
    }
    protected override void OnPaint(PaintEventArgs e) {
        TextFormatFlags flags = TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding;
        flags |= AlignRight ? TextFormatFlags.Right : TextFormatFlags.Left;
        TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, ForeColor, flags);
    }
}

public class JbbBackdropPanel : Panel {
    public JbbBackdropPanel() { DoubleBuffered = true; ResizeRedraw = true; BackColor = Color.FromArgb(247, 250, 255); }
    protected override void OnPaintBackground(PaintEventArgs e) {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using (LinearGradientBrush bg = new LinearGradientBrush(ClientRectangle, Color.White, Color.FromArgb(239, 246, 255), 20f)) e.Graphics.FillRectangle(bg, ClientRectangle);
        using (SolidBrush wave1 = new SolidBrush(Color.FromArgb(42, 219, 234, 254))) e.Graphics.FillEllipse(wave1, -160, Height - 150, Width + 460, 250);
        using (SolidBrush wave2 = new SolidBrush(Color.FromArgb(28, 191, 219, 254))) e.Graphics.FillEllipse(wave2, Width / 2, -140, Width, 300);
    }
}

public class JbbRingPanel : Panel {
    public string ValueText { get; set; }
    public string Subtitle { get; set; }
    public Color RingColor { get; set; }
    public JbbRingPanel() { DoubleBuffered = true; ResizeRedraw = true; BackColor = Color.Transparent; ValueText = "100%"; Subtitle = "状态良好"; RingColor = Color.FromArgb(22, 163, 74); }
    protected override void OnPaint(PaintEventArgs e) {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        int d = Math.Min(Width, Height) - 18; Rectangle r = new Rectangle((Width-d)/2, 8, d, d);
        using (Pen track = new Pen(Color.FromArgb(226, 232, 240), 11f)) e.Graphics.DrawEllipse(track, r);
        using (Pen ring = new Pen(RingColor, 11f)) { ring.StartCap = LineCap.Round; ring.EndCap = LineCap.Round; e.Graphics.DrawArc(ring, r, -90, 360); }
        using (Font f = new Font("Microsoft YaHei UI", 19, FontStyle.Bold))
        using (Font s = new Font("Microsoft YaHei UI", 9, FontStyle.Regular)) {
            TextRenderer.DrawText(e.Graphics, ValueText, f, r, RingColor, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            Rectangle sr = new Rectangle(r.X, r.Bottom/2 + 26, r.Width, 24);
            TextRenderer.DrawText(e.Graphics, Subtitle, s, sr, Color.FromArgb(71,85,105), TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        }
    }
}

public class JbbRocketPanel : Panel {
    public JbbRocketPanel() { DoubleBuffered = true; ResizeRedraw = true; BackColor = Color.Transparent; }
    protected override void OnPaint(PaintEventArgs e) {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        int cx = Width / 2, cy = Height / 2 - 18;
        using (SolidBrush halo = new SolidBrush(Color.FromArgb(28, 59, 130, 246))) e.Graphics.FillEllipse(halo, cx-74, cy-74, 148, 148);
        Point[] body = { new Point(cx, cy-68), new Point(cx+34, cy+18), new Point(cx, cy+48), new Point(cx-34, cy+18) };
        using (LinearGradientBrush b = new LinearGradientBrush(new Rectangle(cx-38,cy-70,76,120), Color.White, Color.FromArgb(96,165,250), 90f)) e.Graphics.FillPolygon(b, body);
        using (SolidBrush blue = new SolidBrush(Color.FromArgb(37,99,235))) {
            e.Graphics.FillEllipse(blue, cx-14, cy-28, 28, 28);
            e.Graphics.FillPolygon(blue, new[]{new Point(cx-30,cy+8),new Point(cx-58,cy+44),new Point(cx-22,cy+31)});
            e.Graphics.FillPolygon(blue, new[]{new Point(cx+30,cy+8),new Point(cx+58,cy+44),new Point(cx+22,cy+31)});
        }
        using (SolidBrush flame = new SolidBrush(Color.FromArgb(52,211,153))) e.Graphics.FillPolygon(flame, new[]{new Point(cx-12,cy+42),new Point(cx,cy+88),new Point(cx+12,cy+42)});
        using (SolidBrush cloud = new SolidBrush(Color.FromArgb(245,249,255))) {
            e.Graphics.FillEllipse(cloud,cx-88,cy+68,82,42); e.Graphics.FillEllipse(cloud,cx-34,cy+62,80,48); e.Graphics.FillEllipse(cloud,cx+18,cy+72,76,38);
        }
    }
}
"@

[JbbUiNative]::EnableDpiAwareness()

function Enable-JbbFormEntranceAnimation {
    param([System.Windows.Forms.Form]$Form,[int]$Duration = 280)
    if (-not $Form -or -not [System.Windows.Forms.SystemInformation]::IsMenuAnimationEnabled) { return }
    $Form.Opacity = 0
    $Form.Add_Shown(({
        $targetTop = $Form.Top
        $startTop = $targetTop + 16
        $Form.Top = $startTop
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 16
        $timer.Add_Tick(({
            $t = [Math]::Min(1.0,$watch.Elapsed.TotalMilliseconds / $Duration)
            $ease = 1.0 - [Math]::Pow(1.0-$t,3)
            $Form.Top = [int]($startTop + ($targetTop-$startTop)*$ease)
            $Form.Opacity = [Math]::Min(1.0,$ease)
            if ($t -ge 1.0) { $timer.Stop(); $timer.Dispose(); $watch.Stop() }
        }).GetNewClosure())
        $timer.Start()
    }).GetNewClosure())
}

$script:AppVersion = 'v1.1.34-dropdown-panel-win64'
$script:JbbPortalBase = 'https://jbbt.cc'
$script:JbbRegisterUrl = 'https://jbbt.cc/register'
$script:JbbTokenPageUrl = 'https://jbbt.cc/console/token'
$script:JbbRechargeUrl = 'https://jbbt.cc/topup'
$script:JbbApiBaseUrl = 'https://downstream.jbbtoken.cn/v1'
$script:JbbCodexModel = if ($env:JBB_LAUNCHER_MODEL) { $env:JBB_LAUNCHER_MODEL } else { 'gpt-5.6-sol' }
$script:JbbLoginEndpoint = 'https://jbbt.cc/codex/launcher-login'
$script:JbbTokenEndpoint = 'https://downstream.jbbtoken.cn/api/desktop/codex/token'
$script:JbbDesktopApiBase = if ($env:JBB_LAUNCHER_DESKTOP_API_BASE) { $env:JBB_LAUNCHER_DESKTOP_API_BASE } else { 'https://downstream.jbbtoken.cn/api/desktop/codex' }

function TextFromCodes {
    param([int[]]$Codes)
    return (-join ($Codes | ForEach-Object { [char]$_ }))
}

function TextFromBase64 {
    param([string]$Value)
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value))
}

$script:Text = @{
    ConnJsonInvalid = '6L+e5o6l5L+h5oGvIEpTT04g5qC85byP5LiN5q2j56Gu44CC'
    ConnJsonInvalidTitle = '6L+e5o6l5L+h5oGv5peg5pWI'
    ConnTypeInvalid = '6L+e5o6l57G75Z6L5LiN5pivIG5ld2FwaV9jaGFubmVsX2Nvbm7jgII='
    ConnTypeInvalidTitle = '6L+e5o6l57G75Z6L5LiN5pSv5oyB'
    ConnFieldsMissing = '6L+e5o6l5L+h5oGv5b+F6aG75YyF5ZCrIGtleSDlkowgdXJsIOWtl+auteOAgg=='
    ConnFieldsMissingTitle = '6L+e5o6l5L+h5oGv57y65bCR5a2X5q61'
    StartDialogTitle = '5byA5aeL5L2/55SoIENvZGV4IENMSQ=='
    StartDialogTitle2 = '5aGr5YaZ6L+e5o6l5L+h5oGv5bm25byA5aeL'
    ConnJsonLabel = '6L+e5o6l5L+h5oGvIEpTT07vvIjlj6/pgInvvIk='
    PasteConn = '57KY6LS06L+e5o6l5L+h5oGv'
    ConnHelp = '5oqK5a6M5pW06L+e5o6l5L+h5oGv57KY6LS05Yiw6L+Z6YeM77yM56iL5bqP5Lya6Ieq5Yqo5o+Q5Y+WIEtleSDlkozlnLDlnYDjgII='
    ManualHelp = '6Ieq5Yqo5aSx6LSl5Lmf5rKh5LqL77ya5omT5byAIEFQSSBLZXkg6aG16Z2i77yM5paw5bu6L+WkjeWItiBrZXnvvIznspjliLDkuIvpnaLljbPlj6/jgII='
    LoginButton = '6Ieq5Yqo6I635Y+WIEFQSSBLZXnvvIjmjqjojZDvvIk='
    RegisterButton = 'MSDms6jlhowv55m75b2V'
    TokenPageButton = '5omT5byAIEFQSSBLZXkg6aG16Z2i'
    RechargeButton = '6aKd5bqm5LiN6LazL+WFheWAvA=='
    AutoLoginFallback = '6Ieq5Yqo6I635Y+W5pqC5pe25LiN5Y+v55So44CC54K54oCc5piv4oCd5omT5byAIEFQSSBLZXkg6aG16Z2i77yM5aSN5Yi2IGtleSDlkI7nspjotLTliLDmnKznqpflj6PjgII='
    QuotaPrompt = '55yL6LW35p2l5piv6aKd5bqm5LiN6Laz44CC54K54oCc5piv4oCd5omT5byA5YWF5YC86aG16Z2i44CC'
    OpenPageFailed = '5omT5byA572R6aG15aSx6LSl77ya'
    RegisterOpenedTip = '5bey5omT5byA5rWP6KeI5Zmo5rOo5YaML+eZu+W9lemhtemdouOAguWujOaIkOWQjuivt+WbnuWIsOacrOeql+WPo++8jOe7p+e7reeCueKAnDMg5omT5byAIEFQSSBLZXkg6aG16Z2i4oCd44CC'
    TokenOpenedTip = '5bey5omT5byAIEFQSSBLZXkg6aG16Z2i44CC6K+355m75b2V5ZCO5paw5bu65oiW5aSN5Yi2IEFQSSBLZXnvvIznhLblkI7lm57liLDmnKznqpflj6PngrnigJw0IOmFjee9ruW5tuWQr+WKqCBDb2RleOKAneeymOi0tOOAgg=='
    RechargeOpenedTip = '5bey5omT5byA5YWF5YC86aG16Z2i44CC5YWF5YC85a6M5oiQ5ZCO5Zue5Yiw5pys56qX5Y+j57un57ut5L2/55So44CC'
    LoginOrPasteTitle = 'SkJCVG9rZW4g5LiA6ZSu6YWN572u'
    LoginOrPasteHelp = '5paw5omL5oyJIDEg5rOo5YaML+eZu+W9le+8jOaMiSAyIOaJk+W8gCBBUEkgS2V5IOmhtemdou+8m+iDveiHquWKqOiOt+WPluWwseiHquWKqOWhq++8jOS4jeiDveiHquWKqOWwseWkjeWItueymOi0tOOAgg=='
    LoginHelp = '5o6o6I2Q77ya5YWI55m75b2VIGpiYnQuY2PvvIzlho3ngrnoh6rliqjojrflj5bvvJvlpoLmnpznq5nngrnmmoLmnKrlvIDmlL7oh6rliqjmjqXlj6PvvIzlsLHmiYvliqjlpI3liLYgQVBJIEtleeOAgg=='
    LoginWaiting = '5q2j5Zyo562J5b6F5rWP6KeI5Zmo55m75b2V77yM6K+35Zyo5omT5byA55qE572R6aG15a6M5oiQ55m75b2V44CC'
    LoginOpened = '5bey5omT5byA5rWP6KeI5Zmo55m75b2V6aG144CC'
    LoginTimeout = '55m75b2V6LaF5pe277yM6K+36YeN5paw54K55Ye755m75b2V77yM5oiW5omL5Yqo57KY6LS06L+e5o6l5L+h5oGv44CC'
    LoginSuccess = '55m75b2V5oiQ5Yqf77yM5bey6Ieq5Yqo5aGr5YaZ6L+e5o6l5L+h5oGv44CC'
    LoginFailed = '6Ieq5Yqo55m75b2V5aSx6LSl77ya'
    LoginFailedTitle = '6Ieq5Yqo55m75b2V5aSx6LSl'
    LoginNoConnection = '56uZ54K55bCa5pyq6L+U5Zue6L+e5o6l5L+h5oGv77yM6K+356Gu6K6k5bey5o6l5YWl5ZCv5Yqo5Zmo55m75b2V5o6l5Y+j44CC'
    LoginCompletePage = '55m75b2V5a6M5oiQ77yM5Y+v5Lul5YWz6Zet6L+Z5Liq6aG16Z2i44CC'
    LoginMissingCode = '56uZ54K55rKh5pyJ6L+U5Zue6L+e5o6l5L+h5oGv5oiW5o6I5p2D56CB44CC'
    ApiKeyLabel = 'QVBJIEtlee+8iOS7jiBqYmJ0LmNjIOiOt+WPlu+8jOeoi+W6j+S8mumakOiXj+aYvuekuu+8iQ=='
    BaseUrlLabel = 'QmFzZSBVUkzvvIjpu5jorqQgSkJCVG9rZW7vvIzkuI3mh4LliKvmlLnvvIk='
    Ok = '56Gu5a6a'
    OkStart = '5L+d5a2Y5bm25ZCv5Yqo'
    Cancel = '5Y+W5raI'
    ApiKeyMissing = '6K+35aGr5YaZIEFQSSBLZXnjgII='
    ApiKeyMissingTitle = '57y65bCRIEFQSSBLZXk='
    MainTitle = 'Q29kZXggQ0xJIOWuieijheWZqOWSjOWQr+WKqOWZqA=='
    Subtitle = '5Zu95YaF5bCP55m954mI77ya56a757q/5a6J6KOFIENvZGV477yb5rOo5YaM5ZCO5omL5Yqo5aSN5Yi2IEFQSSBLZXnvvJvmnIDlkI7lkK/liqjjgII='
    Step1Title = '5bCP55m95Zub5q2l5rWB56iL'
    Step1Desc = '5oyJ6aG65bqP54K55LiL6Z2i5oyJ6ZKu77ya5a6J6KOF44CB5rOo5YaM44CB5omT5byAIEtleSDpobXpnaLjgIHphY3nva7lkK/liqjjgII='
    Step2Title = 'SkJCVG9rZW4g6LSm5oi3'
    Step2Desc = '5rOo5YaM44CB5YWF5YC844CBQVBJIEtleSDpg73lnKggamJidC5jY++8m0NvZGV4IOS9v+eUqCBqYmJ0b2tlbi5jbi92MeOAgg=='
    CurrentStatus = '5b2T5YmN54q25oCB'
    ProgressTitle = '5a6J6KOF5ZKM5ZCv5Yqo6L+b5bqm'
    DetailsTitle = '6K+m57uG5pel5b+X'
    InstallHint = '5YaF572u5a6J6KOF5YyF77yM5peg6ZyAIFZQTuOAgg=='
    StartHint = '5o2i6LSm5Y+3L+mHjemFjeS5n+eCuei/memHjOOAgg=='
    Ready = '5YeG5aSH5bCx57uq77ya5YWI54K5IDEg5a6J6KOF77yb5bey5pyJIENvZGV4IOWPr+ebtOaOpeeCuSAyLzMvNOOAgg=='
    StartingInstall = '5byA5aeL5a6J6KOF44CC'
    CheckingInstalled = '5q2j5Zyo5qOA5p+l5piv5ZCm5bey5a6J6KOFIENvZGV4IENMSeOAgg=='
    AlreadyInstalled = '5bey5a6J6KOF77ya'
    AlreadyInstalledMsg = 'Q29kZXggQ0xJIOW3suWuieijheOAguS9oOWPr+S7pee7p+e7reeCuSAyIOazqOWGjC/nmbvlvZXjgIHngrkgMyDojrflj5YgQVBJIEtlee+8jOaIlueCuSA0IOmHjeaWsOmFjee9ri/lkK/liqjjgII='
    AlreadyInstalledTitle = '5bey5a6J6KOF'
    CheckingWinget = '5q2j5Zyo5qOA5p+lIHdpbmdldOOAgg=='
    WingetMissing = '5pyq5om+5YiwIHdpbmdldOOAguivt+WFiOS7jiBNaWNyb3NvZnQgU3RvcmUg5a6J6KOF5oiW5pu05pawIEFwcCBJbnN0YWxsZXLvvIznhLblkI7ph43mlrDov5DooYzmnKznqIvluo/jgII='
    DownloadingInstaller = '5q2j5Zyo5q2j5Zyo5a6J6KOF5YaF572uIENvZGV4IENMSe+8iOaXoOmcgCBWUE7vvInjgII='
    InstallingBg = '5q2j5Zyo5ZCO5Y+w5a6J6KOFIENvZGV4IENMSeOAgg=='
    InstallerExit = '5a6J6KOF5Zmo6L+U5Zue6ZSZ6K+v5Luj56CBIA=='
    CheckingCodex = '5q2j5Zyo5qOA5p+lIGNvZGV4IOWRveS7pOOAgg=='
    CodexNotFoundAfterInstall = '5a6J6KOF5bey5a6M5oiQ77yM5L2G5rKh5pyJ5ZyoIFBBVEgg5Lit5om+5YiwIGNvZGV4IOWRveS7pOOAguivt+mHjeWQryBXaW5kb3dzIOWQjuWGjeeCueWHu+KAnOW8gOWni+KAneOAgg=='
    VerifyingVersion = '5q2j5Zyo6aqM6K+BIENvZGV4IENMSSDniYjmnKzjgII='
    VersionCompleted = 'Y29kZXggLS12ZXJzaW9uIOW3suaJp+ihjOOAgg=='
    Installed = '5a6J6KOF5a6M5oiQ77ya'
    InstallComplete = '5a6J6KOF5a6M5oiQ44CC5LiL5LiA5q2l6K+354K55Ye74oCc5byA5aeL4oCd44CC'
    InstallFailedPrefix = '5a6J6KOF5aSx6LSl77ya'
    InstallFailedTitle = '5a6J6KOF5aSx6LSl'
    ConfigLaunch = '5q2j5Zyo6YWN572u5bm25ZCv5YqoIENvZGV444CC'
    CodexNotFoundStart = '5pyq5om+5YiwIENvZGV4IENMSeOAguivt+WFiOeCueWHu+KAnOWuieijheKAneOAgg=='
    WritingBaseUrl = '5q2j5Zyo5YaZ5YWlIEJhc2UgVVJMIOmFjee9ruOAgg=='
    SavingApiKey = '5q2j5Zyo5L+d5a2YIEFQSSBLZXkg55m75b2V54q25oCB44CC'
    ApiKeyConfigFailed = 'QVBJIEtleSDphY3nva7lpLHotKXjgII='
    CheckingLogin = '5q2j5Zyo5qOA5p+l55m75b2V54q25oCB44CC'
    OpeningCodex = '5q2j5Zyo5omT5byAIENvZGV4IENMSeOAgg=='
    ConfigComplete = '6YWN572u5a6M5oiQ77yMQ29kZXggQ0xJIOW3suaJk+W8gOOAgg=='
    StartFailedPrefix = '5ZCv5Yqo5aSx6LSl77ya'
    StartFailedTitle = '5ZCv5Yqo5aSx6LSl'
    AlreadyInstalledCanStart = '5qOA5rWL5Yiw5pys5py6IENvZGV4IOW3suWPr+eUqO+8m+WPr+e7p+e7reazqOWGjOOAgeiOt+WPliBBUEkgS2V5IOaIlumHjeaWsOmFjee9ruOAgg=='
    ExistingCodexReadyMsg = 'Q29kZXgg5bey5Y+v55So44CC6Iul6KaB5o2iIEpCQlRva2VuIOi0puWPt+aIliBBUEkgS2V577yM6K+357un57ut5Zyo6YWN572u56qX5Y+j5aGr5YaZ5pawIEtleeOAgg=='
    ExistingCodexReadyTitle = 'Q29kZXgg5bey5Y+v55So'
    ExistingCodexReadyStatus = '5qOA5rWL5Yiw5pys5py6IENvZGV4IOW3sue7j+WPr+eUqO+8jOW3suS/neeVmeeOsOaciei0puWPt+WSjCBBUEkg6YWN572u44CC'
}

function T {
    param([string]$Key)
    return (TextFromBase64 $script:Text[$Key])
}



function Set-JbbWebBrowserFeatureEmulation {
    try {
        $featureKey = 'HKCU:\Software\Microsoft\Internet Explorer\Main\FeatureControl\FEATURE_BROWSER_EMULATION'
        if (-not (Test-Path -LiteralPath $featureKey)) {
            New-Item -Path $featureKey -Force | Out-Null
        }

        $processName = [IO.Path]::GetFileName([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
        New-ItemProperty -Path $featureKey -Name $processName -Value 11001 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path $featureKey -Name 'powershell.exe' -Value 11001 -PropertyType DWord -Force | Out-Null
    }
    catch {}
}

function Show-JbbInAppBrowser {
    param(
        [string]$Url,
        [System.Windows.Forms.Form]$Owner,
        [string]$Title = 'JBBToken 账户中心',
        [switch]$Modeless
    )

    Set-JbbWebBrowserFeatureEmulation

    $browserForm = New-Object System.Windows.Forms.Form
    $browserForm.Text = $Title
    $browserForm.StartPosition = 'CenterParent'
    $browserForm.Size = New-Object System.Drawing.Size(1120, 760)
    $browserForm.MinimumSize = New-Object System.Drawing.Size(900, 620)
    $browserForm.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $browserForm.BackColor = [System.Drawing.Color]::White

    $topPanel = New-Object System.Windows.Forms.Panel
    $topPanel.Dock = 'Top'
    $topPanel.Height = 74
    $topPanel.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 252)

    $tipLabel = New-Object System.Windows.Forms.Label
    $tipLabel.Text = '内置账户窗口：在这里完成注册/登录/获取 API Key/充值；如果网页不兼容，可点“外部浏览器打开”。'
    $tipLabel.Location = New-Object System.Drawing.Point(14, 10)
    $tipLabel.Size = New-Object System.Drawing.Size(780, 24)
    $tipLabel.ForeColor = [System.Drawing.Color]::FromArgb(51, 65, 85)

    $urlLabel = New-Object System.Windows.Forms.Label
    $urlLabel.Text = $Url
    $urlLabel.Location = New-Object System.Drawing.Point(14, 42)
    $urlLabel.Size = New-Object System.Drawing.Size(620, 20)
    $urlLabel.ForeColor = [System.Drawing.Color]::FromArgb(100, 116, 139)

    $backButton = New-Object System.Windows.Forms.Button
    $backButton.Text = '后退'
    $backButton.Location = New-Object System.Drawing.Point(650, 38)
    $backButton.Size = New-Object System.Drawing.Size(58, 26)

    $forwardButton = New-Object System.Windows.Forms.Button
    $forwardButton.Text = '前进'
    $forwardButton.Location = New-Object System.Drawing.Point(714, 38)
    $forwardButton.Size = New-Object System.Drawing.Size(58, 26)

    $refreshButton = New-Object System.Windows.Forms.Button
    $refreshButton.Text = '刷新'
    $refreshButton.Location = New-Object System.Drawing.Point(778, 38)
    $refreshButton.Size = New-Object System.Drawing.Size(58, 26)

    $externalButton = New-Object System.Windows.Forms.Button
    $externalButton.Text = '外部浏览器打开'
    $externalButton.Location = New-Object System.Drawing.Point(842, 38)
    $externalButton.Size = New-Object System.Drawing.Size(118, 26)
    $externalButton.BackColor = [System.Drawing.Color]::White
    $externalButton.ForeColor = [System.Drawing.Color]::FromArgb(37, 99, 235)

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = '关闭'
    $closeButton.Location = New-Object System.Drawing.Point(966, 38)
    $closeButton.Size = New-Object System.Drawing.Size(70, 26)

    $browser = New-Object System.Windows.Forms.WebBrowser
    $browser.Dock = 'Fill'
    $browser.ScriptErrorsSuppressed = $true
    $browser.AllowWebBrowserDrop = $false
    $browser.IsWebBrowserContextMenuEnabled = $true

    $browser.Add_Navigating({
        try { $urlLabel.Text = $_.Url.AbsoluteUri } catch {}
    })
    $browser.Add_DocumentCompleted({
        try {
            if ($browser.Url) { $urlLabel.Text = $browser.Url.AbsoluteUri }
            $browserForm.Text = $Title + ' - ' + $browser.DocumentTitle
        } catch {}
    })

    $backButton.Add_Click({ try { if ($browser.CanGoBack) { $browser.GoBack() } } catch {} })
    $forwardButton.Add_Click({ try { if ($browser.CanGoForward) { $browser.GoForward() } } catch {} })
    $refreshButton.Add_Click({ try { $browser.Refresh() } catch {} })
    $externalButton.Add_Click({
        try {
            $openUrl = $Url
            if ($browser.Url) { $openUrl = $browser.Url.AbsoluteUri }
            Start-Process $openUrl | Out-Null
        } catch {}
    })
    $closeButton.Add_Click({ $browserForm.Close() })

    $topPanel.Controls.AddRange(@($tipLabel, $urlLabel, $backButton, $forwardButton, $refreshButton, $externalButton, $closeButton))
    $browserForm.Controls.Add($browser)
    $browserForm.Controls.Add($topPanel)

    $browserForm.Add_Shown({ try { $browser.Navigate($Url) } catch {} })

    if ($Modeless) {
        if ($Owner) { $browserForm.Show($Owner) } else { $browserForm.Show() }
        return $browserForm
    }

    Enable-JbbFormEntranceAnimation -Form $browserForm
    if ($Owner) { [void]$browserForm.ShowDialog($Owner) } else { [void]$browserForm.ShowDialog() }
    return $null
}

function Open-JbbUrl {
    param([string]$Url, [System.Windows.Forms.Form]$Owner)
    try {
        Show-JbbInAppBrowser -Url $Url -Owner $Owner -Title 'JBBToken 账户中心' | Out-Null
        return $true
    }
    catch {
        try {
            Start-Process $Url | Out-Null
            return $true
        }
        catch {
            if ($Owner) {
                [System.Windows.Forms.MessageBox]::Show($Owner, ((T 'OpenPageFailed') + $_.Exception.Message), 'JBBToken', 'OK', 'Warning') | Out-Null
            }
            return $false
        }
    }
}

function Show-ReturnTip {
    param([System.Windows.Forms.Form]$Owner, [string]$Message)
    if ($Owner) {
        try {
            $Owner.TopMost = $true
            $Owner.Activate()
            [System.Windows.Forms.MessageBox]::Show($Owner, $Message, 'JBBToken 下一步', 'OK', 'Information') | Out-Null
            $Owner.TopMost = $false
            $Owner.Activate()
        } catch {
            try { [System.Windows.Forms.MessageBox]::Show($Message, 'JBBToken 下一步') | Out-Null } catch {}
        }
    }
}
function Test-IsQuotaError {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }
    return ($Message -match '(?i)(quota|balance|insufficient|credit|billing|payment|recharge|top.?up|额度|余额|欠费|充值|扣费)')
}

function Get-JbbApiErrorDetail {
    param($ErrorRecord)

    $statusCode = 0
    $body = ''
    try {
        $response = $ErrorRecord.Exception.Response
        if ($response) {
            if ($response.StatusCode) { $statusCode = [int]$response.StatusCode }
            $stream = $response.GetResponseStream()
            if ($stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
            }
        }
    } catch {}

    if ([string]::IsNullOrWhiteSpace($body)) { $body = [string]$ErrorRecord.Exception.Message }
    $body = ($body -replace '\s+', ' ').Trim()
    if ($body.Length -gt 300) { $body = $body.Substring(0, 300) + '...' }
    return [pscustomobject]@{ StatusCode = $statusCode; Body = $body }
}

function Test-JbbApiConnection {
    param(
        [string]$ApiKey,
        [string]$BaseUrl,
        [int]$TimeoutSec = 25
    )

    if ([string]::IsNullOrWhiteSpace($ApiKey)) { throw 'API Key 为空，无法测试。' }
    if ([string]::IsNullOrWhiteSpace($BaseUrl)) { throw 'Base URL 为空，无法测试。' }

    $normalized = Normalize-BaseUrl $BaseUrl
    $uriValue = $null
    if (-not [Uri]::TryCreate($normalized, [UriKind]::Absolute, [ref]$uriValue) -or $uriValue.Scheme -notin @('http','https')) {
        throw ('Base URL 格式不正确：' + $normalized)
    }

    $modelsUri = $normalized.TrimEnd('/') + '/models'
    $responsesUri = $normalized.TrimEnd('/') + '/responses'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $response = Invoke-RestMethod -Uri $modelsUri -Method Get -Headers @{
            'Authorization' = 'Bearer ' + $ApiKey
            'Accept' = 'application/json'
        } -TimeoutSec $TimeoutSec
        $modelCount = 0
        if ($response -and $response.PSObject.Properties['data'] -and $response.data) {
            $modelCount = @($response.data).Count
        }

        $probeBody = @{
            model = $script:JbbCodexModel
            input = 'Reply only OK.'
            max_output_tokens = 8
        } | ConvertTo-Json -Compress
        $null = Invoke-RestMethod -Uri $responsesUri -Method Post -Headers @{
            'Authorization' = 'Bearer ' + $ApiKey
            'Accept' = 'application/json'
        } -ContentType 'application/json' -Body $probeBody -TimeoutSec $TimeoutSec
        $watch.Stop()
        return [pscustomobject]@{
            Success = $true
            Endpoint = $responsesUri
            ElapsedMs = $watch.ElapsedMilliseconds
            ModelCount = $modelCount
            Model = $script:JbbCodexModel
        }
    }
    catch {
        $watch.Stop()
        $detail = Get-JbbApiErrorDetail $_
        switch ([int]$detail.StatusCode) {
            401 { throw 'API 测试失败（401）：API Key 无效或与当前 Base URL 不匹配。' }
            403 { throw 'API 测试失败（403）：API Key 没有访问权限。' }
            404 { throw ('API 测试失败（404）：Base URL 或模型不正确。') }
            429 { throw ('API 测试失败（429）：请求被限流或账户额度不足。' + $(if ($detail.Body) { ' ' + $detail.Body } else { '' })) }
            default {
                if ($detail.StatusCode -gt 0) {
                    throw ('API 测试失败（HTTP ' + $detail.StatusCode + '）：' + $detail.Body)
                }
                throw ('API 无法连通：' + $detail.Body)
            }
        }
    }
}
function Get-UserCodexHome {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        return $env:CODEX_HOME
    }
    return (Join-Path $env:USERPROFILE '.codex')
}

function Get-JbbCodexHome {
    if (-not [string]::IsNullOrWhiteSpace($env:JBB_LAUNCHER_CODEX_HOME)) {
        return $env:JBB_LAUNCHER_CODEX_HOME
    }
    return (Join-Path (Get-JbbLauncherDataDir) 'codex-home')
}

function Get-CodexHome {
    return (Get-JbbCodexHome)
}

function Add-CodexPathForCurrentProcess {
    $extraPaths = @(
        $env:CODEX_INSTALL_DIR,
        (Join-Path $env:USERPROFILE '.codex\bin'),
        (Join-Path $env:LOCALAPPDATA 'codex\bin'),
        (Join-Path $env:APPDATA 'npm'),
        (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'),
        (Join-Path $env:LOCALAPPDATA 'Programs\OpenAI\Codex\bin')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($path in $extraPaths) {
        if ((Test-Path (Join-Path $path 'codex.exe')) -or (Test-Path (Join-Path $path 'codex.cmd')) -or (Test-Path (Join-Path $path 'codex.ps1'))) {
            if (($env:Path -split ';') -notcontains $path) {
                $env:Path = "$path;$env:Path"
            }
        }
    }
}

function Get-CodexCommand {
    Add-CodexPathForCurrentProcess
    return (Get-Command codex -ErrorAction SilentlyContinue)
}

function Test-CodexAlreadyReady {
    $command = Get-CodexCommand
    if (-not $command) {
        return $false
    }

    $stdout = Join-Path $env:TEMP ('codex-login-status-out-' + [guid]::NewGuid().ToString('N') + '.log')
    $stderr = Join-Path $env:TEMP ('codex-login-status-err-' + [guid]::NewGuid().ToString('N') + '.log')

    try {
        $statusCommand = '$ErrorActionPreference = ''Continue''; $env:CODEX_HOME = ' + (ConvertTo-PowerShellSingleQuotedString (Get-CodexHome)) + '; & ' + (ConvertTo-PowerShellSingleQuotedString $command.Source) + ' login status; if ($null -ne $LASTEXITCODE) { exit $LASTEXITCODE }; exit 0'

        $process = Start-Process -FilePath (Get-WindowsPowerShellPath) -ArgumentList @(
            '-NoProfile',
            '-ExecutionPolicy',
            'Bypass',
            '-EncodedCommand',
            (New-EncodedPowerShellCommand $statusCommand)
        ) -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr

        return ($process.ExitCode -eq 0)
    }
    catch {
        return $false
    }
    finally {
        Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    }
}

function ConvertTo-TomlString {
    param([string]$Value)

    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    return '"' + $escaped + '"'
}

function Normalize-BaseUrl {
    param([string]$Url)

    $normalized = $Url.Trim()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return 'https://api.openai.com/v1'
    }

    $normalized = $normalized.TrimEnd('/')
    if ($normalized -notmatch '/v1$') {
        $normalized = "$normalized/v1"
    }

    return $normalized
}

function Test-JbbTomlShape {
    param([string]$Content)
    $lineNo = 0
    foreach ($line in ($Content -split "`r?`n")) {
        $lineNo++
        $trim = $line.Trim()
        if ($trim.StartsWith('[')) {
            if (-not $trim.EndsWith(']')) { throw "TOML table 第 $lineNo 行缺少 ]：$line" }
            $singleCount = ([regex]::Matches($trim, "'")).Count
            $doubleCount = ([regex]::Matches($trim, '"')).Count
            if (($singleCount % 2) -ne 0 -or ($doubleCount % 2) -ne 0) { throw "TOML table 第 $lineNo 行引号未闭合：$line" }
        }
    }
}

function Test-CodexConfigReadable {
    param([string]$CodexHome)
    $command = '$env:CODEX_HOME = ' + (ConvertTo-PowerShellSingleQuotedString $CodexHome) + '; codex login status'
    $stdout = Join-Path $env:TEMP ('codex-config-check-out-' + [guid]::NewGuid().ToString('N') + '.log')
    $stderr = Join-Path $env:TEMP ('codex-config-check-err-' + [guid]::NewGuid().ToString('N') + '.log')
    try {
        $process = Start-Process -FilePath (Get-WindowsPowerShellPath) -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',(New-EncodedPowerShellCommand $command)) -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $output = ''
        if (Test-Path $stdout) { $output += (Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue) }
        if (Test-Path $stderr) { $output += (Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue) }
        if ($output -match '(?i)(failed to read configuration layers|unclosed table|expected `]|expected \]|TOML|parse)') {
            throw ('Codex 配置解析失败：' + $output.Trim())
        }
        return $true
    }
    finally {
        Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    }
}

function Set-CodexBaseUrl {
    param([string]$BaseUrl)

    $baseUrl = $BaseUrl.Trim()
    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        $baseUrl = 'https://api.openai.com/v1'
    }

    $codexHome = Get-CodexHome
    New-Item -ItemType Directory -Path $codexHome -Force | Out-Null

    $configPath = Join-Path $codexHome 'config.toml'
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupPath = $null
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $backupPath = "$configPath.bak.launcher-$stamp"
        Copy-Item -LiteralPath $configPath -Destination $backupPath -Force
    }

    $newContent = @(
        '# Managed by JBBToken Codex Launcher. This file is isolated from the user default ~/.codex config.',
        ('model = ' + (ConvertTo-TomlString $script:JbbCodexModel)),
        'model_provider = "jbbtoken"',
        '',
        '[model_providers.jbbtoken]',
        'name = "JBBToken"',
        'wire_api = "responses"',
        'requires_openai_auth = true',
        ('base_url = ' + (ConvertTo-TomlString $baseUrl)),
        ''
    ) -join [Environment]::NewLine

    Test-JbbTomlShape -Content $newContent
    $tmpPath = "$configPath.tmp-$stamp"
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    try {
        [System.IO.File]::WriteAllText($tmpPath, $newContent, $utf8Bom)
        Move-Item -LiteralPath $tmpPath -Destination $configPath -Force
        Test-CodexConfigReadable -CodexHome $codexHome | Out-Null
    }
    catch {
        Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue
        if ($backupPath -and (Test-Path -LiteralPath $backupPath)) {
            Copy-Item -LiteralPath $backupPath -Destination $configPath -Force
        }
        elseif (Test-Path -LiteralPath $configPath) {
            Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Set-ProgressState {
    param(
        [int]$Value,
        [string]$Message
    )

    $safeValue = [Math]::Max(0, [Math]::Min(100, $Value))
    $progressBar.Value = $safeValue
    $percentLabel.Text = "$safeValue%"

    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        $statusLabel.Text = $Message
        $logBox.AppendText(("[$(Get-Date -Format 'HH:mm:ss')] $Message" + [Environment]::NewLine))
        $logBox.SelectionStart = $logBox.Text.Length
        $logBox.ScrollToCaret()
    }

    if ($activityCard) {
        $isFailure = ($safeValue -eq 0 -and -not [string]::IsNullOrWhiteSpace($Message) -and $Message -match '失败|错误|异常')
        $activityCard.Visible = (($safeValue -gt 0 -and $safeValue -lt 100) -or $isFailure)
        if ($isFailure) { $progressBar.FillColor = [System.Drawing.Color]::FromArgb(220,38,38) }
        else { $progressBar.FillColor = [System.Drawing.Color]::FromArgb(20,99,255) }
        $activityCard.BringToFront()
    }

    [System.Windows.Forms.Application]::DoEvents()
}

function Set-ButtonsEnabled {
    param([bool]$Enabled)

    foreach ($buttonName in @(
        'installButton',
        'startButton',
        'loginMainButton',
        'loginNetworkButton',
        'dashboardLaunchButton',
        'dashboardReconfigureButton',
        'dashboardFolderButton',
        'dashboardRechargeButton',
        'dashboardRefreshButton',
        'dashboardSwitchButton',
        'dashboardNetworkButton',
        'dashboardApiTestButton',
        'homeRegisterButton',
        'homeTokenButton',
        'homeRechargeButton'
    )) {
        $button = Get-Variable -Name $buttonName -ValueOnly -ErrorAction SilentlyContinue
        if ($button -and $button.PSObject.Properties['Enabled']) {
            $button.Enabled = $Enabled
        }
    }
}

function Try-ApplyConnectionJson {
    param(
        [string]$JsonText,
        [System.Windows.Forms.TextBox]$ApiBox,
        [System.Windows.Forms.TextBox]$UrlBox,
        [bool]$ShowError
    )

    if ([string]::IsNullOrWhiteSpace($JsonText)) {
        return $false
    }

    try {
        $connection = $JsonText | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        if ($ShowError) {
            [System.Windows.Forms.MessageBox]::Show($form, (T 'ConnJsonInvalid'), (T 'ConnJsonInvalidTitle'), 'OK', 'Warning') | Out-Null
        }
        return $false
    }

    $type = [string]$connection._type
    $key = [string]$connection.key
    $url = [string]$connection.url

    if (-not [string]::IsNullOrWhiteSpace($type) -and $type -ne 'newapi_channel_conn') {
        if ($ShowError) {
            [System.Windows.Forms.MessageBox]::Show($form, (T 'ConnTypeInvalid'), (T 'ConnTypeInvalidTitle'), 'OK', 'Warning') | Out-Null
        }
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($key) -or [string]::IsNullOrWhiteSpace($url)) {
        if ($ShowError) {
            [System.Windows.Forms.MessageBox]::Show($form, (T 'ConnFieldsMissing'), (T 'ConnFieldsMissingTitle'), 'OK', 'Warning') | Out-Null
        }
        return $false
    }

    $ApiBox.Text = $key
    $UrlBox.Text = Normalize-BaseUrl $url
    return $true
}

function Get-FreeLocalPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Parse('127.0.0.1'), 0)
    $listener.Start()
    try {
        return $listener.LocalEndpoint.Port
    }
    finally {
        $listener.Stop()
    }
}

function ConvertFrom-Base64Url {
    param([string]$Value)

    $normalized = $Value.Replace('-', '+').Replace('_', '/')
    switch ($normalized.Length % 4) {
        2 { $normalized += '==' }
        3 { $normalized += '=' }
    }

    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($normalized))
}

function Get-ConnectionJsonFromObject {
    param($Object)

    if ($null -eq $Object) {
        return $null
    }

    if ($Object -is [string]) {
        return $Object
    }

    $props = $Object.PSObject.Properties
    $keyProp = $props['key']
    $urlProp = $props['url']
    if ($keyProp -and $urlProp) {
        return (@{
            _type = 'newapi_channel_conn'
            key = [string]$keyProp.Value
            url = [string]$urlProp.Value
        } | ConvertTo-Json -Compress)
    }

    foreach ($name in @('connection', 'data', 'result', 'config')) {
        $prop = $props[$name]
        if ($prop) {
            $json = Get-ConnectionJsonFromObject $prop.Value
            if (-not [string]::IsNullOrWhiteSpace($json)) {
                return $json
            }
        }
    }

    return $null
}

function Get-JbbLauncherDataDir {
    $root = Join-Path $env:APPDATA 'JBBTokenCodexLauncher'
    if (-not (Test-Path -LiteralPath $root)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }
    return $root
}

function Get-JbbDeviceId {
    $path = Join-Path (Get-JbbLauncherDataDir) 'device.id'
    if (Test-Path -LiteralPath $path) {
        $existing = (Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue).Trim()
        if (-not [string]::IsNullOrWhiteSpace($existing) -and $existing.Length -ge 16) {
            return $existing
        }
    }

    $deviceId = 'jbb_' + ([guid]::NewGuid().ToString('N'))
    Set-Content -LiteralPath $path -Value $deviceId -Encoding ASCII
    return $deviceId
}

function Protect-JbbText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $secure = ConvertTo-SecureString -String $Text -AsPlainText -Force
    return (ConvertFrom-SecureString -SecureString $secure)
}

function Unprotect-JbbText {
    param([string]$CipherText)
    if ([string]::IsNullOrWhiteSpace($CipherText)) { return '' }
    $secure = ConvertTo-SecureString -String $CipherText
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Save-JbbDesktopSession {
    param($Auth)
    if ($null -eq $Auth -or [string]::IsNullOrWhiteSpace([string]$Auth.access_token)) { return }
    $path = Join-Path (Get-JbbLauncherDataDir) 'session.json'
    $payload = [pscustomobject]@{
        user_id = [int]$Auth.user_id
        username = [string]$Auth.username
        access_token = Protect-JbbText ([string]$Auth.access_token)
        saved_at = (Get-Date).ToString('o')
    }
    $payload | ConvertTo-Json -Compress | Set-Content -LiteralPath $path -Encoding UTF8
}

function Get-JbbDesktopSession {
    $path = Join-Path (Get-JbbLauncherDataDir) 'session.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $payload = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $token = Unprotect-JbbText ([string]$payload.access_token)
        if ([string]::IsNullOrWhiteSpace($token) -or -not $payload.user_id) { return $null }
        return [pscustomobject]@{
            user_id = [int]$payload.user_id
            username = [string]$payload.username
            access_token = $token
        }
    }
    catch {
        return $null
    }
}

function Clear-JbbDesktopSession {
    $path = Join-Path (Get-JbbLauncherDataDir) 'session.json'
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function ConvertTo-JbbSha256Hex {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return (-join ($hash | ForEach-Object { $_.ToString('x2') }))
    }
    finally {
        $sha.Dispose()
    }
}

function Find-JbbChallengeAnswer {
    param(
        [string]$Nonce,
        [string]$DeviceId,
        [int]$Difficulty
    )
    return [JbbProofOfWork]::Solve($Nonce, $DeviceId, $Difficulty, 5000000)
}

function Invoke-JbbDesktopApi {
    param(
        [string]$Path,
        [string]$Method = 'Get',
        $Body = $null,
        $Auth = $null,
        [bool]$WithChallenge = $false
    )

    $deviceId = Get-JbbDeviceId
    $headers = @{
        'X-JBB-Device-Id' = $deviceId
    }

    if ($Auth) {
        $accessToken = [string]$Auth.access_token
        if (-not [string]::IsNullOrWhiteSpace($accessToken) -and $accessToken -notmatch '^(?i)Bearer\s+') {
            $accessToken = 'Bearer ' + $accessToken
        }
        $headers['Authorization'] = $accessToken
        $headers['New-Api-User'] = [string]$Auth.user_id
    }

    if ($WithChallenge) {
        $challengeUri = $script:JbbDesktopApiBase.TrimEnd('/') + '/challenge'
        $challengeResp = Invoke-RestMethod -Uri $challengeUri -Method Get -Headers @{ 'X-JBB-Device-Id' = $deviceId } -TimeoutSec 30
        if ($challengeResp.success -eq $false) {
            throw ([string]$challengeResp.message)
        }
        $challenge = $challengeResp.data
        $answer = Find-JbbChallengeAnswer -Nonce ([string]$challenge.nonce) -DeviceId $deviceId -Difficulty ([int]$challenge.difficulty)
        $headers['X-JBB-Challenge-Nonce'] = [string]$challenge.nonce
        $headers['X-JBB-Challenge-Answer'] = $answer
    }

    $uri = $script:JbbDesktopApiBase.TrimEnd('/') + $Path
    $jsonBody = $null
    if ($null -ne $Body) {
        $jsonBody = $Body | ConvertTo-Json -Compress
    }

    if ($null -ne $jsonBody) {
        $resp = Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers -ContentType 'application/json' -Body $jsonBody -TimeoutSec 45
    }
    else {
        $resp = Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers -TimeoutSec 45
    }

    if ($resp.PSObject.Properties['success'] -and $resp.success -eq $false) {
        throw ([string]$resp.message)
    }
    return $resp
}

function Invoke-JbbDesktopLogin {
    param(
        [string]$Username,
        [string]$Password,
        [string]$TwoFACode = ''
    )
    $body = @{
        username = $Username
        password = $Password
    }
    if (-not [string]::IsNullOrWhiteSpace($TwoFACode)) {
        $body['two_fa_code'] = $TwoFACode
    }
    $resp = Invoke-JbbDesktopApi -Path '/login' -Method Post -Body $body -WithChallenge $true
    if ($resp.data -and $resp.data.require_2fa) {
        return $resp.data
    }
    Save-JbbDesktopSession $resp.data
    return $resp.data
}

function Get-JbbConnectionByAuth {
    param($Auth)
    $resp = Invoke-JbbDesktopApi -Path '/token' -Method Get -Auth $Auth
    $json = Get-ConnectionJsonFromObject $resp
    if ([string]::IsNullOrWhiteSpace($json)) {
        throw '未能从服务器获取 API Key。'
    }
    return $json
}

function Show-JbbInputDialog {
    param(
        [string]$Title,
        [string]$Prompt,
        [bool]$Password = $false
    )
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Title
    $f.StartPosition = 'CenterParent'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.ClientSize = New-Object System.Drawing.Size(360, 142)
    $f.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Prompt
    $label.Location = New-Object System.Drawing.Point(18, 16)
    $label.Size = New-Object System.Drawing.Size(324, 26)

    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = New-Object System.Drawing.Point(18, 48)
    $box.Size = New-Object System.Drawing.Size(324, 26)
    $box.UseSystemPasswordChar = $Password

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = '确定'
    $ok.Location = New-Object System.Drawing.Point(176, 94)
    $ok.Size = New-Object System.Drawing.Size(78, 30)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = '取消'
    $cancel.Location = New-Object System.Drawing.Point(264, 94)
    $cancel.Size = New-Object System.Drawing.Size(78, 30)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $f.Controls.AddRange(@($label, $box, $ok, $cancel))
    $f.AcceptButton = $ok
    $f.CancelButton = $cancel
    Enable-JbbFormEntranceAnimation -Form $f
    if ($f.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        return $box.Text
    }
    return ''
}

function Show-JbbNativeAccountDialog {
    param([System.Windows.Forms.Form]$Owner)

    $accountForm = New-Object System.Windows.Forms.Form
    $accountForm.Text = 'JBBToken 登录 / 注册'
    $accountForm.StartPosition = 'CenterParent'
    $accountForm.FormBorderStyle = 'FixedDialog'
    $accountForm.MaximizeBox = $false
    $accountForm.MinimizeBox = $false
    $accountForm.ClientSize = New-Object System.Drawing.Size(680, 520)
    $accountForm.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $accountForm.BackColor = [System.Drawing.Color]::FromArgb(242, 247, 255)
    $accountForm.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $accountForm.AutoScaleDimensions = New-Object System.Drawing.SizeF(96,96)

    $mode = @{ Register = $false }
    $script:JbbNativeAuthResult = $null

    $brand = New-JbbCard -X 28 -Y 30 -W 220 -H 430
    $brandLogo = New-JbbLabel -Text 'JBB' -X 50 -Y 56 -W 120 -H 72 -Size 34 -Bold $true -Color ([System.Drawing.Color]::FromArgb(20,99,255)) -Align 'MiddleCenter'
    $brandTitle = New-JbbLabel -Text 'Codex 启动配置' -X 28 -Y 154 -W 164 -H 32 -Size 15 -Bold $true -Color ([System.Drawing.Color]::FromArgb(15,23,42)) -Align 'MiddleCenter'
    $brandSub = New-JbbLabel -Text "注册、登录、取 API Key 都在这里完成`r`n不再跳转网页" -X 24 -Y 198 -W 174 -H 56 -Size 9 -Color ([System.Drawing.Color]::FromArgb(100,116,139)) -Align 'MiddleCenter'
    $brandCheck1 = New-JbbLabel -Text '✓ 邮箱验证码注册' -X 40 -Y 286 -W 150 -H 24 -Size 9 -Color ([System.Drawing.Color]::FromArgb(22,163,74))
    $brandCheck2 = New-JbbLabel -Text '✓ 自动获取 API Key' -X 40 -Y 318 -W 150 -H 24 -Size 9 -Color ([System.Drawing.Color]::FromArgb(22,163,74))
    $brandCheck3 = New-JbbLabel -Text '✓ 连接 JBBToken 网关' -X 40 -Y 350 -W 160 -H 24 -Size 9 -Color ([System.Drawing.Color]::FromArgb(22,163,74))
    $brand.Controls.AddRange(@($brandLogo,$brandTitle,$brandSub,$brandCheck1,$brandCheck2,$brandCheck3))

    $card = New-JbbCard -X 276 -Y 30 -W 374 -H 430
    $title = New-JbbLabel -Text '登录 JBBToken' -X 30 -Y 28 -W 300 -H 38 -Size 20 -Bold $true -Color ([System.Drawing.Color]::FromArgb(15,23,42))
    $subtitle = New-JbbLabel -Text '登录后自动完成 Codex 配置。' -X 32 -Y 68 -W 300 -H 24 -Size 9 -Color ([System.Drawing.Color]::FromArgb(100,116,139))
    $loginTab = New-JbbButton -Text '登录' -X 32 -Y 108 -W 140 -H 36 -Kind 'Primary' -Size 10
    $registerTab = New-JbbButton -Text '注册' -X 184 -Y 108 -W 140 -H 36 -Kind 'Secondary' -Size 10

    $userLabel = New-JbbLabel -Text '用户名' -X 32 -Y 168 -W 80 -H 22 -Size 9 -Color ([System.Drawing.Color]::FromArgb(15,23,42))
    $userBox = New-Object System.Windows.Forms.TextBox
    $userBox.Location = New-Object System.Drawing.Point(32, 192)
    $userBox.Size = New-Object System.Drawing.Size(292, 28)
    Set-JbbInputStyle -Control $userBox -Size 10

    $passwordLabel = New-JbbLabel -Text '密码' -X 32 -Y 230 -W 80 -H 22 -Size 9 -Color ([System.Drawing.Color]::FromArgb(15,23,42))
    $passwordBox = New-Object System.Windows.Forms.TextBox
    $passwordBox.Location = New-Object System.Drawing.Point(32, 254)
    $passwordBox.Size = New-Object System.Drawing.Size(292, 28)
    $passwordBox.UseSystemPasswordChar = $true
    Set-JbbInputStyle -Control $passwordBox -Size 10

    $emailLabel = New-JbbLabel -Text '邮箱' -X 32 -Y 292 -W 80 -H 22 -Size 9 -Color ([System.Drawing.Color]::FromArgb(15,23,42))
    $emailBox = New-Object System.Windows.Forms.TextBox
    $emailBox.Location = New-Object System.Drawing.Point(32, 316)
    $emailBox.Size = New-Object System.Drawing.Size(182, 28)
    Set-JbbInputStyle -Control $emailBox -Size 10
    $sendCodeButton = New-JbbButton -Text '发送验证码' -X 224 -Y 314 -W 100 -H 30 -Kind 'Secondary' -Size 9

    $codeLabel = New-JbbLabel -Text '验证码' -X 32 -Y 352 -W 80 -H 22 -Size 9 -Color ([System.Drawing.Color]::FromArgb(15,23,42))
    $codeBox = New-Object System.Windows.Forms.TextBox
    $codeBox.Location = New-Object System.Drawing.Point(32, 376)
    $codeBox.Size = New-Object System.Drawing.Size(292, 28)
    Set-JbbInputStyle -Control $codeBox -Size 10

    $status = New-JbbLabel -Text '' -X 30 -Y 410 -W 306 -H 24 -Size 9 -Color ([System.Drawing.Color]::FromArgb(100,116,139))
    $primary = New-JbbButton -Text '登录并自动获取 Key' -X 276 -Y 472 -W 240 -H 38 -Kind 'Primary' -Size 11
    $cancel = New-JbbButton -Text '取消' -X 528 -Y 472 -W 90 -H 38 -Kind 'Secondary' -Size 10
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $updateMode = {
        if ($mode.Register) {
            $title.Text = '注册 JBBToken'
            $subtitle.Text = '填写邮箱验证码，注册后自动登录。'
            $emailLabel.Visible = $true; $emailBox.Visible = $true; $sendCodeButton.Visible = $true
            $codeLabel.Visible = $true; $codeBox.Visible = $true
            $primary.Text = '注册并自动获取 Key'
            $loginTab.BackColor = [System.Drawing.Color]::White; $loginTab.ForeColor = [System.Drawing.Color]::FromArgb(37,99,235); $loginTab.BorderThickness = 1; $loginTab.BorderColor = [System.Drawing.Color]::FromArgb(191,219,254)
            $registerTab.BackColor = [System.Drawing.Color]::FromArgb(20,99,255); $registerTab.ForeColor = [System.Drawing.Color]::White; $registerTab.BorderThickness = 0
        } else {
            $title.Text = '登录 JBBToken'
            $subtitle.Text = '登录后自动完成 Codex 配置。'
            $emailLabel.Visible = $false; $emailBox.Visible = $false; $sendCodeButton.Visible = $false
            $codeLabel.Visible = $false; $codeBox.Visible = $false
            $primary.Text = '登录并自动获取 Key'
            $loginTab.BackColor = [System.Drawing.Color]::FromArgb(20,99,255); $loginTab.ForeColor = [System.Drawing.Color]::White; $loginTab.BorderThickness = 0
            $registerTab.BackColor = [System.Drawing.Color]::White; $registerTab.ForeColor = [System.Drawing.Color]::FromArgb(37,99,235); $registerTab.BorderThickness = 1; $registerTab.BorderColor = [System.Drawing.Color]::FromArgb(191,219,254)
        }
        $status.Text = ''
    }

    $loginTab.Add_Click({ $mode.Register = $false; & $updateMode })
    $registerTab.Add_Click({ $mode.Register = $true; & $updateMode })
    $sendCodeButton.Add_Click({
        try {
            if ([string]::IsNullOrWhiteSpace($emailBox.Text)) { throw '请先输入邮箱。' }
            $sendCodeButton.Enabled = $false
            $status.Text = '正在发送验证码...'
            [System.Windows.Forms.Application]::DoEvents()
            Invoke-JbbDesktopApi -Path '/email-verification' -Method Post -Body @{ email = $emailBox.Text.Trim() } -WithChallenge $true | Out-Null
            $status.Text = '验证码已发送，请查看邮箱。'
        } catch {
            $message = [string]$_.Exception.Message
            if ($message -match '(?i)email is already taken|邮箱.{0,8}(已注册|已被使用|已存在)') {
                $mode.Register = $false
                & $updateMode
                $status.Text = '该邮箱已经注册，无需验证码，请直接输入用户名和密码登录。'
                $userBox.Focus()
            }
            elseif ($message -match '(?i)invalid email') {
                $status.Text = '邮箱格式不正确，请检查后重试。'
                $emailBox.Focus()
            }
            elseif ($message -match '(?i)email domain is not allowed') {
                $status.Text = '当前邮箱域名不支持注册，请更换邮箱。'
                $emailBox.Focus()
            }
            elseif ($message -match '(?i)email alias is not allowed') {
                $status.Text = '邮箱别名不支持注册，请使用原始邮箱地址。'
                $emailBox.Focus()
            }
            else {
                $status.Text = '验证码发送失败：' + $message
            }
        }
        finally { $sendCodeButton.Enabled = $true }
    })
    $primary.Add_Click({
        try {
            if ([string]::IsNullOrWhiteSpace($userBox.Text)) { throw '请输入用户名。' }
            if ([string]::IsNullOrWhiteSpace($passwordBox.Text)) { throw '请输入密码。' }
            $primary.Enabled = $false
            $status.Text = '正在验证设备并连接 JBBToken...'
            [System.Windows.Forms.Application]::DoEvents()
            if ($mode.Register) {
                if ([string]::IsNullOrWhiteSpace($emailBox.Text)) { throw '请输入邮箱。' }
                if ([string]::IsNullOrWhiteSpace($codeBox.Text)) { throw '请输入邮箱验证码。' }
                Invoke-JbbDesktopApi -Path '/register' -Method Post -Body @{ username = $userBox.Text.Trim(); password = $passwordBox.Text; email = $emailBox.Text.Trim(); verification_code = $codeBox.Text.Trim() } -WithChallenge $true | Out-Null
            }
            $auth = Invoke-JbbDesktopLogin -Username $userBox.Text.Trim() -Password $passwordBox.Text
            if ($auth -and $auth.require_2fa) {
                $twoFA = Show-JbbInputDialog -Title '二次验证' -Prompt '请输入 2FA 验证码或备用码：'
                if ([string]::IsNullOrWhiteSpace($twoFA)) { throw '需要 2FA 验证码。' }
                $auth = Invoke-JbbDesktopLogin -Username $userBox.Text.Trim() -Password $passwordBox.Text -TwoFACode $twoFA
            }
            $script:JbbNativeAuthResult = $auth
            $accountForm.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $accountForm.Close()
        } catch { $status.Text = '失败：' + $_.Exception.Message }
        finally { $primary.Enabled = $true }
    })

    $card.Controls.AddRange(@($title,$subtitle,$loginTab,$registerTab,$userLabel,$userBox,$passwordLabel,$passwordBox,$emailLabel,$emailBox,$sendCodeButton,$codeLabel,$codeBox,$status))
    $accountForm.Controls.AddRange(@($brand,$card,$primary,$cancel))
    & $updateMode
    $accountForm.AcceptButton = $primary
    $accountForm.CancelButton = $cancel
    Enable-JbbFormEntranceAnimation -Form $accountForm
    if ($accountForm.ShowDialog($Owner) -eq [System.Windows.Forms.DialogResult]::OK) { return $script:JbbNativeAuthResult }
    return $null
}
function ConvertTo-JbbQueryString {
    param($Object)
    if ($null -eq $Object) { return '' }
    $pairs = @()
    foreach ($prop in $Object.PSObject.Properties) {
        if ($null -eq $prop.Value) { continue }
        $pairs += ([Uri]::EscapeDataString([string]$prop.Name) + '=' + [Uri]::EscapeDataString([string]$prop.Value))
    }
    return ($pairs -join '&')
}

function Get-JbbPaymentUrl {
    param($RechargeResponse)
    $url = [string]$RechargeResponse.url
    if ([string]::IsNullOrWhiteSpace($url) -and $RechargeResponse.data -and $RechargeResponse.data.checkout_url) {
        $url = [string]$RechargeResponse.data.checkout_url
    }
    if ([string]::IsNullOrWhiteSpace($url)) { return '' }
    if ($RechargeResponse.data) {
        $qs = ConvertTo-JbbQueryString $RechargeResponse.data
        if (-not [string]::IsNullOrWhiteSpace($qs)) {
            if ($url.Contains('?')) { return $url + '&' + $qs }
            return $url + '?' + $qs
        }
    }
    return $url
}

function Resolve-JbbAbsoluteUrl {
    param([string]$BaseUrl,[string]$Candidate)
    if ([string]::IsNullOrWhiteSpace($Candidate)) { return '' }
    try { return ([Uri]::new([Uri]$BaseUrl, $Candidate)).AbsoluteUri } catch { return $Candidate }
}

function New-JbbPaymentQrImagePath {
    param([string]$PayUrl, $Auth)
    if ([string]::IsNullOrWhiteSpace($PayUrl)) { return '' }
    if (-not $Auth) { throw '请先登录后再生成支付二维码。' }

    $headers = @{
        'X-JBB-Device-Id' = (Get-JbbDeviceId)
    }
    $accessToken = [string]$Auth.access_token
    if (-not [string]::IsNullOrWhiteSpace($accessToken) -and $accessToken -notmatch '^(?i)Bearer\s+') {
        $accessToken = 'Bearer ' + $accessToken
    }
    $headers['Authorization'] = $accessToken
    $headers['New-Api-User'] = [string]$Auth.user_id

    $qrDir = Join-Path (Get-JbbLauncherDataDir) 'payment-qr'
    New-Item -ItemType Directory -Force -Path $qrDir | Out-Null
    Get-ChildItem -LiteralPath $qrDir -Filter 'qr-*.png' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } | Remove-Item -Force -ErrorAction SilentlyContinue
    $qrPath = Join-Path $qrDir ('qr-' + ([Guid]::NewGuid().ToString('N')) + '.png')
    $uri = $script:JbbDesktopApiBase.TrimEnd('/') + '/qr'
    $body = @{ text = $PayUrl } | ConvertTo-Json -Compress
    Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -ContentType 'application/json' -Body $body -OutFile $qrPath -TimeoutSec 30 | Out-Null
    $file = Get-Item -LiteralPath $qrPath -ErrorAction Stop
    if ($file.Length -lt 100) { throw '二维码图片生成失败。' }
    return $qrPath
}
function Get-JbbPaymentQrImageUrl {
    param([string]$PayUrl)
    if ([string]::IsNullOrWhiteSpace($PayUrl)) { return '' }
    try {
        $resp = Invoke-WebRequest -Uri $PayUrl -UseBasicParsing -TimeoutSec 15 -MaximumRedirection 5 -Headers @{ 'User-Agent' = 'Mozilla/5.0 JBBTokenCodexLauncher' }
        $html = [string]$resp.Content
        if ([string]::IsNullOrWhiteSpace($html)) { return '' }
        $imgMatches = [regex]::Matches($html, '<img[^>]+(?:src|data-src)=["'']([^"'']+)["''][^>]*>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $first = ''
        foreach ($m in $imgMatches) {
            $src = [string]$m.Groups[1].Value
            if ([string]::IsNullOrWhiteSpace($src) -or $src.StartsWith('data:', [StringComparison]::OrdinalIgnoreCase)) { continue }
            $abs = Resolve-JbbAbsoluteUrl -BaseUrl $PayUrl -Candidate $src
            if ([string]::IsNullOrWhiteSpace($first)) { $first = $abs }
            if ($abs -match '(?i)(qr|qrcode|code|pay|alipay|weixin|wechat)') { return $abs }
        }
        return $first
    } catch {
        return ''
    }
}

function Get-JbbRechargeTradeNo {
    param($Response,[string]$PayUrl)
    foreach ($candidate in @(
        $Response.trade_no,
        $Response.order_id,
        $(if ($Response.data) { $Response.data.trade_no }),
        $(if ($Response.data) { $Response.data.out_trade_no }),
        $(if ($Response.data) { $Response.data.order_id }),
        $(if ($Response.data) { $Response.data.order_no })
    )) {
        $value = [string]$candidate
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    }
    if (-not [string]::IsNullOrWhiteSpace($PayUrl)) {
        try {
            $query = ([Uri]$PayUrl).Query.TrimStart('?')
            foreach ($pair in $query -split '&') {
                $parts = $pair -split '=',2
                if ($parts.Count -eq 2 -and $parts[0] -match '^(?i)(trade_no|out_trade_no|order_id|order_no)$') {
                    return [Uri]::UnescapeDataString($parts[1])
                }
            }
        } catch {}
    }
    return ''
}

function Get-JbbAsyncAuthHeaders {
    param($Auth)
    $headers = @{
        'X-JBB-Device-Id' = (Get-JbbDeviceId)
    }
    if ($Auth) {
        $accessToken = [string]$Auth.access_token
        if (-not [string]::IsNullOrWhiteSpace($accessToken) -and $accessToken -notmatch '^(?i)Bearer\s+') {
            $accessToken = 'Bearer ' + $accessToken
        }
        $headers['Authorization'] = $accessToken
        $headers['New-Api-User'] = [string]$Auth.user_id
    }
    return $headers
}

function Start-JbbAsyncDesktopRequest {
    param(
        [string]$Path,
        [string]$Method = 'GET',
        $Body = $null,
        $Auth = $null,
        [int]$TimeoutSeconds = 45
    )
    [int]$slowMs = 0
    if ([int]::TryParse([string]$env:JBB_LAUNCHER_TEST_SLOW_NETWORK_MS,[ref]$slowMs) -and $slowMs -gt 0) { return [JbbAsyncHttp]::DelayFailureAsync($slowMs) }
    $uri = $script:JbbDesktopApiBase.TrimEnd('/') + $Path
    $jsonBody = if ($null -eq $Body) { '' } else { $Body | ConvertTo-Json -Compress }
    return [JbbAsyncHttp]::SendAsync($uri,$Method,(Get-JbbAsyncAuthHeaders -Auth $Auth),$jsonBody,$TimeoutSeconds)
}

function ConvertFrom-JbbAsyncResult {
    param($Result)
    if (-not $Result) { throw '服务器未返回数据。' }
    if (-not $Result.Ok) {
        $message = [string]$Result.Error
        if (-not [string]::IsNullOrWhiteSpace([string]$Result.Body)) {
            try {
                $errorBody = [string]$Result.Body | ConvertFrom-Json -ErrorAction Stop
                if ($errorBody.message) { $message = [string]$errorBody.message }
                elseif ($errorBody.error) { $message = [string]$errorBody.error }
                elseif ($errorBody.data -is [string]) { $message = [string]$errorBody.data }
            } catch {}
        }
        if ([string]::IsNullOrWhiteSpace($message)) { $message = '网络请求失败。' }
        throw $message
    }
    if ([string]::IsNullOrWhiteSpace([string]$Result.Body)) { return $null }
    $response = [string]$Result.Body | ConvertFrom-Json -ErrorAction Stop
    if ($response.PSObject.Properties['success'] -and $response.success -eq $false) {
        $message = [string]$response.message
        if ([string]::IsNullOrWhiteSpace($message) -and $response.data -is [string]) { $message = [string]$response.data }
        if ([string]::IsNullOrWhiteSpace($message)) { $message = '服务器请求失败。' }
        throw $message
    }
    return $response
}

function New-JbbControlSnapshot {
    param([System.Windows.Forms.Control]$Control)
    if (-not $Control -or $Control.Width -le 0 -or $Control.Height -le 0) { return $null }
    $bitmap = New-Object System.Drawing.Bitmap($Control.Width,$Control.Height,[System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
    try {
        $Control.DrawToBitmap($bitmap,(New-Object System.Drawing.Rectangle(0,0,$Control.Width,$Control.Height)))
        return $bitmap
    } catch {
        $bitmap.Dispose()
        throw
    }
}

function Set-JbbSnapshotImage {
    param([System.Windows.Forms.PictureBox]$PictureBox,[System.Drawing.Image]$Image)
    if ($PictureBox.Image) {
        $old = $PictureBox.Image
        $PictureBox.Image = $null
        try { $old.Dispose() } catch {}
    }
    $PictureBox.Image = $Image
}

function Write-JbbRechargePerfLog {
    param([string]$Mode,[System.Collections.IEnumerable]$Intervals)
    $path = [string]$env:JBB_LAUNCHER_PERF_LOG
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    try {
        $values = @($Intervals | ForEach-Object { [double]$_ } | Sort-Object)
        if ($values.Count -eq 0) { return }
        $percentile = {
            param([double]$P)
            $index = [Math]::Min($values.Count-1,[Math]::Max(0,[int][Math]::Ceiling($values.Count*$P)-1))
            return [Math]::Round($values[$index],2)
        }
        $line = "{0}`t{1}`tticks={2}`tp50={3}ms`tp95={4}ms`tmax={5}ms" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'),$Mode,$values.Count,(& $percentile 0.50),(& $percentile 0.95),([Math]::Round($values[-1],2))
        $dir = Split-Path -Parent $path
        if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Add-Content -LiteralPath $path -Value $line -Encoding UTF8
    } catch {}
}

function Set-JbbRechargeQuickSelection {
    param($Selected)
    if (-not $script:JbbRechargeUi) { return }
    foreach ($button in $script:JbbRechargeUi.QuickButtons) {
        $button.BackColor = [System.Drawing.Color]::White
        $button.ForeColor = [System.Drawing.Color]::FromArgb(20,99,255)
        $button.BorderColor = [System.Drawing.Color]::FromArgb(191,219,254)
    }
    if ($Selected) {
        $Selected.BackColor = [System.Drawing.Color]::FromArgb(239,246,255)
        $Selected.BorderColor = [System.Drawing.Color]::FromArgb(20,99,255)
    }
}

function Start-JbbRechargeAnimation {
    param([ValidateSet('Open','Close','Stage')][string]$Mode)
    $ui = $script:JbbRechargeUi
    if (-not $ui -or $ui.Animating) { return }
    $ui.Animating = $true
    $ui.ReturnButton.Enabled = $false
    $ui.SupportButton.Enabled = $false
    $hostWidth = $ui.Host.ClientSize.Width
    $targetLeft = [Math]::Max(0, $hostWidth - $ui.Drawer.Width)
    $drawerScale = [double]$ui.Drawer.Width / 800.0
    $snapshot = $null
    if ($Mode -eq 'Open') {
        $ui.Drawer.Location = New-Object System.Drawing.Point($targetLeft,0)
        $ui.Drawer.Height = $ui.Host.ClientSize.Height
        $ui.Drawer.Visible = $true
        $ui.Drawer.BringToFront()
        $ui.OrderCard.Top = [int](144 * $drawerScale)
        $ui.Drawer.PerformLayout()
        [System.Windows.Forms.Application]::DoEvents()
        Set-JbbSnapshotImage -PictureBox $ui.DrawerSnapshot -Image (New-JbbControlSnapshot -Control $ui.Drawer)
        $ui.DrawerSnapshot.Bounds = New-Object System.Drawing.Rectangle($hostWidth,0,$ui.Drawer.Width,$ui.Drawer.Height)
        $ui.Drawer.Visible = $false
        $ui.DrawerSnapshot.Visible = $true
        $ui.DrawerSnapshot.BringToFront()
        $snapshot = $ui.DrawerSnapshot
    }
    elseif ($Mode -eq 'Stage') {
        $ui.PayCard.Left = $ui.Drawer.Width
        $ui.PayCard.Visible = $true
        $ui.Drawer.PerformLayout()
        Set-JbbSnapshotImage -PictureBox $ui.OrderSnapshot -Image (New-JbbControlSnapshot -Control $ui.OrderCard)
        Set-JbbSnapshotImage -PictureBox $ui.PaySnapshot -Image (New-JbbControlSnapshot -Control $ui.PayCard)
        $ui.OrderSnapshot.Bounds = $ui.OrderCard.Bounds
        $ui.PaySnapshot.Bounds = $ui.PayCard.Bounds
        $ui.OrderCard.Visible = $false
        $ui.PayCard.Visible = $false
        $ui.OrderSnapshot.Visible = $true
        $ui.PaySnapshot.Visible = $true
        $ui.OrderSnapshot.BringToFront(); $ui.PaySnapshot.BringToFront()
        $snapshot = $ui.OrderSnapshot
    }
    else {
        $ui.Drawer.PerformLayout()
        Set-JbbSnapshotImage -PictureBox $ui.DrawerSnapshot -Image (New-JbbControlSnapshot -Control $ui.Drawer)
        $ui.DrawerSnapshot.Bounds = $ui.Drawer.Bounds
        $ui.Drawer.Visible = $false
        $ui.DrawerSnapshot.Visible = $true
        $ui.DrawerSnapshot.BringToFront()
        $snapshot = $ui.DrawerSnapshot
    }
    $duration = if (-not [System.Windows.Forms.SystemInformation]::IsMenuAnimationEnabled) { 1.0 } elseif ($Mode -eq 'Stage') { 260.0 } else { 320.0 }
    $script:JbbRechargeAnimationState = @{
        Mode = $Mode; Started = [DateTime]::UtcNow; Duration = $duration
        DrawerStart = if ($Mode -eq 'Open') { $hostWidth } else { $targetLeft }; DrawerEnd = if ($Mode -eq 'Close') { $hostWidth } else { $targetLeft }
        OrderStart = $ui.OrderSnapshot.Left; OrderEnd = if ($Mode -eq 'Stage') { [int](28*$drawerScale) } else { $ui.OrderSnapshot.Left }
        PayStart = $ui.PaySnapshot.Left; PayEnd = [int]($ui.Drawer.Width-$ui.PayCard.Width-(28*$drawerScale))
        Snapshot = $snapshot; Intervals = New-Object System.Collections.ArrayList; LastTick = [System.Diagnostics.Stopwatch]::StartNew()
    }
    $ui.AnimationTimer.Start()
}

function Hide-JbbRechargeDrawer {
    if (-not $script:JbbRechargeUi -or (-not $script:JbbRechargeUi.Drawer.Visible -and -not $script:JbbRechargeUi.DrawerSnapshot.Visible)) { return }
    $script:JbbRechargeUi.PollTimer.Stop(); $script:JbbRechargeUi.AsyncTimer.Stop()
    $script:JbbRechargeUi.AsyncOperation = $null
    $script:JbbRechargeUi.Generation = [int]$script:JbbRechargeUi.Generation + 1
    $script:JbbRechargeUi.SupportCard.Visible = $false
    Start-JbbRechargeAnimation -Mode Close
}

function Set-JbbRechargeInitialStage {
    $ui = $script:JbbRechargeUi
    if (-not $ui) { return }
    $ui.PollTimer.Stop()
    $script:JbbRechargeTradeNo = ''
    $drawerScale = [double]$ui.Drawer.Width / 800.0
    $ui.OrderCard.Left = [int](($ui.Drawer.Width-$ui.OrderCard.Width)/2)
    $ui.OrderCard.Top = [int](126*$drawerScale)
    $ui.PayCard.Visible = $false
    $ui.PayCard.Left = $ui.Drawer.Width
    $ui.OrderCard.Visible = $true
    $ui.OrderSnapshot.Visible = $false; $ui.PaySnapshot.Visible = $false
    $ui.QrFrame.Visible = $true
    if ($ui.QrBox.Image) { $oldImage = $ui.QrBox.Image; $ui.QrBox.Image = $null; try { $oldImage.Dispose() } catch {} }
    $ui.QrHint.Text = ''
    $ui.OrderAmount.Text = ''
    $ui.PayStatusText.Text = '等待支付'
    $ui.PayStatus.BackColor = [System.Drawing.Color]::FromArgb(239,246,255)
    $ui.PayStatus.BorderColor = $ui.PayStatus.BackColor
    $ui.PayStatusText.ForeColor = [System.Drawing.Color]::FromArgb(20,99,255)
    $ui.CreateButton.Enabled = $true
    $ui.Status.Text = '充值金额将在支付成功后实时到账。'
}

function Load-JbbRechargeData {
    $ui = $script:JbbRechargeUi
    if (-not $ui) { return }
    $ui.MethodBox.Items.Clear(); $ui.MethodTypes.Clear(); $ui.CreateButton.Enabled = $false
    if ([string]$env:JBB_LAUNCHER_UI_PREVIEW -eq 'Recharge' -and [string]$env:JBB_LAUNCHER_UI_PREVIEW_ASYNC -ne '1') {
        $ui.WalletAmount.Text = '¥ 128.50'; $ui.WalletHint.Text = '额度充足'; $ui.AmountBox.Text = '100'
        $ui.MethodTypes['微信支付'] = 'wxpay'; [void]$ui.MethodBox.Items.Add('微信支付'); $ui.MethodBox.SelectedIndex = 0
        Set-JbbRechargeQuickSelection -Selected $ui.QuickButtons[1]
        $ui.Status.Text = '选择金额后创建充值订单。'; $ui.CreateButton.Enabled = $true
        if ($env:JBB_LAUNCHER_UI_CAPTURE) {
            $captureTimer = New-Object System.Windows.Forms.Timer
            $captureTimer.Interval = 380
            $captureTimer.Add_Tick({ $this.Stop(); Save-JbbFormCapture -Form $script:JbbRechargeUi.Host -Path $env:JBB_LAUNCHER_UI_CAPTURE; $this.Dispose() })
            $script:JbbRechargeCaptureTimer = $captureTimer
            $captureTimer.Start()
        }
        if ([string]$env:JBB_LAUNCHER_UI_PREVIEW_ORDER -eq '1') {
            Invoke-JbbRechargeOrderCreation
        }
        return
    }
    $ui.Status.Text = '正在读取充值信息...'
    $ui.AsyncOperation = @{
        Kind='Load'; Generation=$ui.Generation
        WalletTask=(Start-JbbAsyncDesktopRequest -Path '/wallet' -Method 'GET' -Auth $script:JbbRechargeAuth)
        InfoTask=(Start-JbbAsyncDesktopRequest -Path '/recharge/info' -Method 'GET' -Auth $script:JbbRechargeAuth)
    }
    $ui.AsyncTimer.Start()
}

function Update-JbbRechargeOrderStatus {
    $ui = $script:JbbRechargeUi
    if (-not $ui -or $ui.AsyncOperation -or [string]::IsNullOrWhiteSpace($script:JbbRechargeTradeNo)) { return }
    $escaped = [Uri]::EscapeDataString($script:JbbRechargeTradeNo)
    $ui.AsyncOperation = @{ Kind='Poll'; Generation=$ui.Generation; Task=(Start-JbbAsyncDesktopRequest -Path ('/recharge/' + $escaped) -Method 'GET' -Auth $script:JbbRechargeAuth) }
    $ui.AsyncTimer.Start()
}

function New-JbbPreviewQrImage {
    $bitmap = New-Object System.Drawing.Bitmap(256,256)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([System.Drawing.Color]::White)
        $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(15,23,42))
        try {
            for ($row=0; $row -lt 29; $row++) {
                for ($col=0; $col -lt 29; $col++) {
                    if ((($row*7 + $col*11 + $row*$col) % 5) -lt 2) { $graphics.FillRectangle($brush,12+$col*8,12+$row*8,7,7) }
                }
            }
            foreach ($point in @(@(12,12),@(188,12),@(12,188))) {
                $graphics.FillRectangle($brush,$point[0],$point[1],56,56)
                $graphics.FillRectangle([System.Drawing.Brushes]::White,$point[0]+8,$point[1]+8,40,40)
                $graphics.FillRectangle($brush,$point[0]+16,$point[1]+16,24,24)
            }
        } finally { $brush.Dispose() }
    } finally { $graphics.Dispose() }
    return $bitmap
}

function Invoke-JbbRechargeOrderCreation {
    $ui = $script:JbbRechargeUi
    if (-not $ui -or -not $ui.CreateButton.Enabled -or $ui.AsyncOperation) { return }
    try {
        $selected = [string]$ui.MethodBox.SelectedItem
        if ([string]::IsNullOrWhiteSpace($selected)) { throw '请选择支付方式。' }
        $method = [string]$ui.MethodTypes[$selected]
        [decimal]$amount = 0
        try { $amount = [decimal]::Parse($ui.AmountBox.Text.Trim(),[Globalization.NumberStyles]::Number,[Globalization.CultureInfo]::InvariantCulture) } catch { throw '请输入正确的充值金额，最多保留两位小数。' }
        if ($amount -le 0 -or [decimal]::Round($amount,2) -ne $amount) { throw '请输入正确的充值金额，最多保留两位小数。' }
        $ui.CreateButton.Enabled = $false
        $ui.Status.Text = '正在创建充值订单，请稍候...'
        if ([string]$env:JBB_LAUNCHER_UI_PREVIEW -eq 'Recharge') {
            $ui.QrBox.Image = New-JbbPreviewQrImage
            $ui.QrFrame.Visible = $true
            $ui.QrHint.Text = '请使用微信扫码支付'
            $ui.OrderAmount.Text = '订单金额：¥' + $amount.ToString('0.00')
            $ui.PayStatusText.Text = '等待支付'
            $ui.Status.Text = '订单已创建，请扫码支付。'
            Start-JbbRechargeAnimation -Mode Stage
            return
        }
        $ui.AsyncOperation = @{
            Kind='Create'; Generation=$ui.Generation; Amount=$amount
            Task=(Start-JbbAsyncDesktopRequest -Path '/recharge' -Method 'POST' -Auth $script:JbbRechargeAuth -Body @{ amount = $amount; payment_method = $method })
        }
        $ui.AsyncTimer.Start()
    } catch {
        $ui.PayCard.Visible = $false
        $ui.OrderCard.Left = [int](($ui.Drawer.Width-$ui.OrderCard.Width)/2)
        $message = [string]$_.Exception.Message
        if ($message -match '(?i)(network|timeout|timed out|无法连接|连接.*失败)') { $message = '网络连接失败，请检查网络后重试。' }
        $ui.CreateButton.Enabled = $true
        $ui.Status.Text = $message
    }
}

function Format-JbbCurrencyDisplay {
    param($Balance,[string]$DisplayType)
    [decimal]$value = 0
    $raw = ([string]$Balance).Trim().Replace(',','')
    if (-not [decimal]::TryParse($raw,[Globalization.NumberStyles]::Number,[Globalization.CultureInfo]::InvariantCulture,[ref]$value)) {
        return ([string]$Balance + $(if ($DisplayType) { ' ' + $DisplayType } else { '' }))
    }
    $number = $value.ToString('#,##0.00',[Globalization.CultureInfo]::InvariantCulture)
    $type = ([string]$DisplayType).Trim()
    if ([string]::IsNullOrWhiteSpace($type) -or $type -match '^(?i)(CNY|RMB|人民币|元|¥)$') { return '¥' + $number }
    if ($type -match '^(?i)(USD|\$)$') { return '$' + $number }
    return ($number + ' ' + $type)
}

function Set-JbbRechargeWalletData {
    param($Wallet,[bool]$Updated = $false)
    $ui = $script:JbbRechargeUi
    if (-not $ui -or -not $Wallet -or -not $Wallet.data) { return }
    $display = Format-JbbCurrencyDisplay -Balance $Wallet.data.display_balance -DisplayType ([string]$Wallet.data.display_type)
    $ui.WalletAmount.Text = $display
    $ui.WalletHint.Text = if ($Updated) { '额度已更新。' } elseif ($Wallet.data.low_balance) { '余额偏低，建议充值。' } else { '额度充足。' }
    if ($balanceAmountLabel) { $balanceAmountLabel.Text = $display }
    if ($balanceHintLabel) { $balanceHintLabel.Text = if ($Wallet.data.low_balance) { '余额偏低' } else { '额度充足' } }
}

function Complete-JbbRechargeAsyncOperation {
    $ui = $script:JbbRechargeUi
    if (-not $ui -or -not $ui.AsyncOperation) { if ($ui) { $ui.AsyncTimer.Stop() }; return }
    $op = $ui.AsyncOperation
    if ([int]$op.Generation -ne [int]$ui.Generation) { $ui.AsyncOperation = $null; $ui.AsyncTimer.Stop(); return }
    try {
        if ($op.Kind -eq 'Load') {
            if (-not $op.WalletTask.IsCompleted -or -not $op.InfoTask.IsCompleted) { return }
            $walletError = $null; $infoError = $null; $wallet = $null; $info = $null
            try { $wallet = ConvertFrom-JbbAsyncResult -Result $op.WalletTask.Result } catch { $walletError = $_.Exception.Message }
            try { $info = ConvertFrom-JbbAsyncResult -Result $op.InfoTask.Result } catch { $infoError = $_.Exception.Message }
            if ($wallet) { Set-JbbRechargeWalletData -Wallet $wallet }
            if ($info -and $info.data) {
                foreach ($method in @($info.data.pay_methods)) {
                    $name = if ($method.name) { [string]$method.name } else { [string]$method.type }
                    $type = [string]$method.type
                    if (-not [string]::IsNullOrWhiteSpace($type)) { $ui.MethodTypes[$name] = $type; [void]$ui.MethodBox.Items.Add($name) }
                }
                if ($ui.MethodBox.Items.Count -gt 0) { $ui.MethodBox.SelectedIndex = 0 }
                if ($info.data.amount_options -and @($info.data.amount_options).Count -gt 0) {
                    $options = @($info.data.amount_options); $ui.AmountBox.Text = [string]$options[0]
                    for ($i=0; $i -lt [Math]::Min($options.Count,$ui.QuickButtons.Count); $i++) {
                        $ui.QuickButtons[$i].Tag = $options[$i]; $ui.QuickButtons[$i].Text = '¥' + [string]$options[$i]
                    }
                    Set-JbbRechargeQuickSelection -Selected $ui.QuickButtons[0]
                } elseif ($info.data.min_topup) { $ui.AmountBox.Text = [string]$info.data.min_topup }
            }
            $ui.CreateButton.Enabled = ($ui.MethodBox.Items.Count -gt 0)
            $ui.Status.Text = if ($infoError) { '充值信息读取失败，请检查网络后返回重试。' } elseif ($walletError) { '支付方式已加载，余额暂时读取失败。' } else { '选择金额后创建充值订单。' }
            $ui.AsyncOperation = $null; $ui.AsyncTimer.Stop(); return
        }

        if (-not $op.Task.IsCompleted) { return }
        if ($op.Kind -eq 'Create') {
            $response = ConvertFrom-JbbAsyncResult -Result $op.Task.Result
            if ([string]$response.message -eq 'error') { throw ([string]$response.data) }
            $payUrl = Get-JbbPaymentUrl $response
            if ([string]::IsNullOrWhiteSpace($payUrl)) { throw '订单创建失败：服务器未返回支付地址。' }
            $tradeNo = Get-JbbRechargeTradeNo -Response $response -PayUrl $payUrl
            $ui.Status.Text = '订单已创建，正在生成支付二维码...'
            $ui.AsyncOperation = @{
                Kind='Qr'; Generation=$ui.Generation; Amount=$op.Amount; TradeNo=$tradeNo
                Task=(Start-JbbAsyncDesktopRequest -Path '/qr' -Method 'POST' -Auth $script:JbbRechargeAuth -Body @{ text = $payUrl } -TimeoutSeconds 30)
            }
            return
        }
        if ($op.Kind -eq 'Qr') {
            $result = $op.Task.Result
            if (-not $result.Ok -or -not $result.Bytes -or $result.Bytes.Length -lt 100) { throw '订单已经创建，但二维码显示失败。请联系客服处理，勿重复创建订单。' }
            $stream = New-Object System.IO.MemoryStream(,$result.Bytes)
            try { $source = [System.Drawing.Image]::FromStream($stream); try { $image = New-Object System.Drawing.Bitmap($source) } finally { $source.Dispose() } } finally { $stream.Dispose() }
            if ($ui.QrBox.Image) { $oldImage = $ui.QrBox.Image; $ui.QrBox.Image = $null; try { $oldImage.Dispose() } catch {} }
            $ui.QrBox.Image = $image; $ui.QrFrame.Visible = $true; $ui.QrHint.Text = '请使用微信扫码支付'
            $ui.OrderAmount.Text = '订单金额：¥' + ([decimal]$op.Amount).ToString('0.00'); $ui.PayStatusText.Text = '等待支付'
            $ui.PayStatus.BackColor = [System.Drawing.Color]::FromArgb(239,246,255); $ui.PayStatus.BorderColor = $ui.PayStatus.BackColor
            $ui.PayStatusText.ForeColor = [System.Drawing.Color]::FromArgb(20,99,255)
            $script:JbbRechargeTradeNo = [string]$op.TradeNo; $ui.Status.Text = '订单已创建，请扫码支付。'
            $ui.AsyncOperation = $null; $ui.AsyncTimer.Stop(); Start-JbbRechargeAnimation -Mode Stage
            if (-not [string]::IsNullOrWhiteSpace($script:JbbRechargeTradeNo)) { $ui.PollTimer.Start() }
            return
        }
        if ($op.Kind -eq 'Poll') {
            $response = ConvertFrom-JbbAsyncResult -Result $op.Task.Result
            $state = [string]$response.data.status
            $ui.AsyncOperation = $null; $ui.AsyncTimer.Stop()
            if ($state -eq 'success') {
                $ui.PayStatusText.Text = '支付成功'; $ui.PayStatus.BackColor = [System.Drawing.Color]::FromArgb(236,253,245)
                $ui.PayStatus.BorderColor = [System.Drawing.Color]::FromArgb(167,243,208); $ui.PayStatusText.ForeColor = [System.Drawing.Color]::FromArgb(5,150,105)
                $ui.QrHint.Text = '充值成功，余额已自动刷新'; $ui.Status.Text = '支付成功，充值额度已经到账。'; $ui.PollTimer.Stop()
                $ui.AsyncOperation = @{ Kind='WalletAfterPayment'; Generation=$ui.Generation; Task=(Start-JbbAsyncDesktopRequest -Path '/wallet' -Method 'GET' -Auth $script:JbbRechargeAuth) }
                $ui.AsyncTimer.Start()
            } elseif ($state -eq 'failed') {
                $ui.PayStatusText.Text = '支付失败'; $ui.QrHint.Text = '订单支付失败，请重新创建订单'; $ui.Status.Text = '支付未完成，请返回后重新创建订单。'; $ui.PollTimer.Stop()
            } else { $ui.PayStatusText.Text = '等待支付'; $ui.PollTimer.Start() }
            return
        }
        if ($op.Kind -eq 'WalletAfterPayment') {
            Set-JbbRechargeWalletData -Wallet (ConvertFrom-JbbAsyncResult -Result $op.Task.Result) -Updated $true
            $ui.AsyncOperation = $null; $ui.AsyncTimer.Stop(); return
        }
    } catch {
        $kind = [string]$op.Kind
        $message = [string]$_.Exception.Message
        if ($message -match '(?i)(network|timeout|timed out|无法连接|连接.*失败|请求已取消)') { $message = '网络连接失败，请检查网络后重试。' }
        $ui.AsyncOperation = $null; $ui.AsyncTimer.Stop()
        if ($kind -eq 'Poll') { $ui.Status.Text = '正在等待支付结果，网络恢复后会继续查询。'; $ui.PollTimer.Start() }
        elseif ($kind -eq 'Qr') { $ui.CreateButton.Enabled = $false; $ui.Status.Text = '订单已经创建，但二维码显示失败。请联系客服处理，勿重复创建订单。'; Show-JbbRechargeSupportCard }
        elseif ($kind -eq 'WalletAfterPayment') { $ui.WalletHint.Text = '充值成功，余额稍后刷新。' }
        else { $ui.CreateButton.Enabled = $true; $ui.Status.Text = $message }
    }
}

function Show-JbbRechargeSupportCard {
    $ui = $script:JbbRechargeUi
    if (-not $ui) { return }
    $ui.SupportState.Text = ''
    $card = $ui.SupportCard
    $targetTop = [int](246 * ([double]$ui.Drawer.Width / 800.0))
    $card.Visible = $true
    $card.BringToFront()
    if (-not [System.Windows.Forms.SystemInformation]::IsMenuAnimationEnabled) { $card.Top = $targetTop; return }
    $startTop = $targetTop + [int](14 * ([double]$ui.Drawer.Width / 800.0))
    $card.Top = $startTop
    if ($script:JbbSupportAnimationTimer) { try { $script:JbbSupportAnimationTimer.Stop(); $script:JbbSupportAnimationTimer.Dispose() } catch {} }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 16
    $script:JbbSupportAnimationTimer = $timer
    $timer.Add_Tick(({
        $t = [Math]::Min(1.0,$watch.Elapsed.TotalMilliseconds / 220.0)
        $ease = 1.0 - [Math]::Pow(1.0-$t,3)
        $card.Top = [int]($startTop + ($targetTop-$startTop)*$ease)
        if ($t -ge 1.0) { $timer.Stop(); $timer.Dispose(); $watch.Stop(); $script:JbbSupportAnimationTimer = $null }
    }).GetNewClosure())
    $timer.Start()
}

function Initialize-JbbRechargeDrawer {
    param([System.Windows.Forms.Form]$Owner)
    if ($script:JbbRechargeUi -and $script:JbbRechargeUi.Host -eq $Owner) { return }
    $drawer = New-Object JbbBackdropPanel
    $drawer.Size = New-Object System.Drawing.Size(800,$Owner.ClientSize.Height)
    $drawer.Location = New-Object System.Drawing.Point($Owner.ClientSize.Width,0)
    $drawer.Visible = $false

    $logo = New-JbbLogo -X 28 -Y 22 -W 50 -H 46 -Size 13
    $title = New-JbbLabel -Text 'JBBToken 充值中心' -X 94 -Y 27 -W 310 -H 34 -Size 15 -Bold $true -Color ([System.Drawing.Color]::FromArgb(15,23,42))
    $header = New-JbbLabel -Text '账户充值' -X 30 -Y 76 -W 260 -H 42 -Size 24 -Bold $true -Color ([System.Drawing.Color]::FromArgb(15,23,42))
    $sub = New-JbbLabel -Text '选择金额并创建订单，支付区域将在订单创建后出现。' -X 32 -Y 112 -W 620 -H 26 -Size 10 -Color ([System.Drawing.Color]::FromArgb(71,85,105))

    $orderCard = New-JbbCard -X 214 -Y 126 -W 340 -H 510 -Radius 18
    $walletTitle = New-JbbLabel -Text '当前余额' -X 24 -Y 22 -W 130 -H 28 -Size 12 -Bold $true -Color ([System.Drawing.Color]::FromArgb(15,23,42))
    $walletAmount = New-JbbLabel -Text '读取中...' -X 24 -Y 52 -W 292 -H 52 -Size 22 -Bold $true -Color ([System.Drawing.Color]::FromArgb(22,163,74)) -Align 'MiddleLeft'
    $walletHint = New-JbbLabel -Text '' -X 24 -Y 104 -W 292 -H 22 -Size 9 -Color ([System.Drawing.Color]::FromArgb(71,85,105))
    $divider = New-JbbDivider -X 24 -Y 134 -W 292
    $amountLabel = New-JbbLabel -Text '充值金额' -X 24 -Y 150 -W 120 -H 22 -Size 10 -Bold $true -Color ([System.Drawing.Color]::FromArgb(15,23,42))
    $amountBox = New-Object JbbAmountInput
    $amountBox.Location = New-Object System.Drawing.Point(24,178); $amountBox.Size = New-Object System.Drawing.Size(292,44)
    Set-JbbInputStyle -Control $amountBox -Size 11
    $quick50 = New-JbbButton -Text '¥50' -X 24 -Y 234 -W 64 -H 36 -Kind 'Secondary' -Size 9; $quick50.Tag = 50
    $quick100 = New-JbbButton -Text '¥100' -X 100 -Y 234 -W 64 -H 36 -Kind 'Secondary' -Size 9; $quick100.Tag = 100
    $quick200 = New-JbbButton -Text '¥200' -X 176 -Y 234 -W 64 -H 36 -Kind 'Secondary' -Size 9; $quick200.Tag = 200
    $quick500 = New-JbbButton -Text '¥500' -X 252 -Y 234 -W 64 -H 36 -Kind 'Secondary' -Size 9; $quick500.Tag = 500
    $methodLabel = New-JbbLabel -Text '支付方式' -X 24 -Y 286 -W 120 -H 22 -Size 10 -Bold $true -Color ([System.Drawing.Color]::FromArgb(15,23,42))
    $methodBox = New-Object JbbPaymentSelect
    $methodBox.Location = New-Object System.Drawing.Point(24,312); $methodBox.Size = New-Object System.Drawing.Size(292,44)
    Set-JbbInputStyle -Control $methodBox -Size 10
    $createButton = New-JbbButton -Text '创建充值订单' -X 24 -Y 376 -W 292 -H 48 -Kind 'Primary' -Size 13
    $status = New-JbbLabel -Text '充值金额将在支付成功后实时到账。' -X 24 -Y 438 -W 292 -H 48 -Size 9 -Color ([System.Drawing.Color]::FromArgb(100,116,139)) -Align 'TopCenter'
    $orderCard.Controls.AddRange(@($walletTitle,$walletAmount,$walletHint,$divider,$amountLabel,$amountBox,$quick50,$quick100,$quick200,$quick500,$methodLabel,$methodBox,$createButton,$status))

    $payCard = New-JbbCard -X 800 -Y 126 -W 364 -H 510 -Radius 18
    $payCard.Visible = $false
    $payTitle = New-JbbLabel -Text '扫码支付' -X 24 -Y 22 -W 150 -H 30 -Size 13 -Bold $true -Color ([System.Drawing.Color]::FromArgb(15,23,42))
    $qrFrame = New-JbbCard -X 42 -Y 68 -W 280 -H 280 -Radius 14
    $qrFrame.BorderColor = [System.Drawing.Color]::FromArgb(203,213,225)
    $qrBox = New-Object System.Windows.Forms.PictureBox
    $qrBox.Location = New-Object System.Drawing.Point(12,12); $qrBox.Size = New-Object System.Drawing.Size(256,256); $qrBox.SizeMode = 'Zoom'; $qrBox.BackColor = [System.Drawing.Color]::White
    $qrFrame.Controls.Add($qrBox)
    $qrHint = New-JbbLabel -Text '' -X 24 -Y 358 -W 316 -H 28 -Size 10 -Color ([System.Drawing.Color]::FromArgb(71,85,105)) -Align 'MiddleCenter'
    $orderAmount = New-JbbLabel -Text '' -X 24 -Y 394 -W 316 -H 30 -Size 13 -Bold $true -Color ([System.Drawing.Color]::FromArgb(15,23,42)) -Align 'MiddleCenter'
    $payStatus = New-JbbCard -X 122 -Y 440 -W 120 -H 36 -Radius 18
    $payStatus.BackColor = [System.Drawing.Color]::FromArgb(239,246,255); $payStatus.BorderColor = $payStatus.BackColor
    $payStatusText = New-JbbLabel -Text '等待支付' -X 0 -Y 0 -W 120 -H 36 -Size 9 -Bold $true -Color ([System.Drawing.Color]::FromArgb(20,99,255)) -Align 'MiddleCenter'
    $payStatus.Controls.Add($payStatusText)
    $payCard.Controls.AddRange(@($payTitle,$qrFrame,$qrHint,$orderAmount,$payStatus))

    $help = New-JbbLabel -Text '支付遇到问题？' -X 32 -Y 662 -W 120 -H 34 -Size 10 -Bold $true -Color ([System.Drawing.Color]::FromArgb(15,23,42)) -Align 'MiddleLeft'
    $supportButton = New-JbbButton -Text '联系客服' -X 152 -Y 662 -W 104 -H 36 -Kind 'Secondary' -Size 9
    $returnButton = New-JbbButton -Text '返回' -X 664 -Y 658 -W 104 -H 42 -Kind 'Secondary' -Size 10

    $supportCard = New-JbbCard -X 388 -Y 246 -W 360 -H 190 -Radius 18
    $supportCard.Visible = $false
    $supportTitle = New-JbbLabel -Text '联系 JBBToken 客服' -X 24 -Y 22 -W 300 -H 30 -Size 14 -Bold $true -Color ([System.Drawing.Color]::FromArgb(15,23,42))
    $supportHint = New-JbbLabel -Text '遇到支付问题，请通过 QQ 联系客服。' -X 24 -Y 60 -W 310 -H 26 -Size 9 -Color ([System.Drawing.Color]::FromArgb(71,85,105))
    $qqLabel = New-JbbLabel -Text 'QQ：1165643117' -X 24 -Y 92 -W 200 -H 34 -Size 13 -Bold $true -Color ([System.Drawing.Color]::FromArgb(20,99,255)) -Align 'MiddleLeft'
    $copyQq = New-JbbButton -Text '复制 QQ 号' -X 226 -Y 92 -W 110 -H 34 -Kind 'Primary' -Size 9
    $supportState = New-JbbLabel -Text '' -X 24 -Y 138 -W 214 -H 28 -Size 9 -Color ([System.Drawing.Color]::FromArgb(5,150,105)) -Align 'MiddleLeft'
    $supportBack = New-JbbButton -Text '收起' -X 252 -Y 138 -W 84 -H 32 -Kind 'Secondary' -Size 9
    $supportCard.Controls.AddRange(@($supportTitle,$supportHint,$qqLabel,$copyQq,$supportState,$supportBack))

    $animationTimer = New-Object System.Windows.Forms.Timer
    $animationTimer.Interval = 10
    $asyncTimer = New-Object System.Windows.Forms.Timer
    $asyncTimer.Interval = 50
    $pollTimer = New-Object System.Windows.Forms.Timer
    $pollTimer.Interval = 4000
    $drawerSnapshot = New-Object System.Windows.Forms.PictureBox
    $drawerSnapshot.SizeMode = 'Normal'; $drawerSnapshot.Visible = $false; $drawerSnapshot.BackColor = [System.Drawing.Color]::Transparent
    $orderSnapshot = New-Object System.Windows.Forms.PictureBox
    $orderSnapshot.SizeMode = 'Normal'; $orderSnapshot.Visible = $false; $orderSnapshot.BackColor = [System.Drawing.Color]::Transparent
    $paySnapshot = New-Object System.Windows.Forms.PictureBox
    $paySnapshot.SizeMode = 'Normal'; $paySnapshot.Visible = $false; $paySnapshot.BackColor = [System.Drawing.Color]::Transparent
    $methodTypes = @{}
    $script:JbbRechargeUi = @{
        Host=$Owner; Drawer=$drawer; OrderCard=$orderCard; PayCard=$payCard; WalletAmount=$walletAmount; WalletHint=$walletHint
        AmountBox=$amountBox; MethodBox=$methodBox; MethodTypes=$methodTypes; QuickButtons=@($quick50,$quick100,$quick200,$quick500)
        CreateButton=$createButton; Status=$status; QrFrame=$qrFrame; QrBox=$qrBox; QrHint=$qrHint; OrderAmount=$orderAmount
        PayStatus=$payStatus; PayStatusText=$payStatusText; SupportButton=$supportButton; ReturnButton=$returnButton
        SupportCard=$supportCard; SupportState=$supportState; AnimationTimer=$animationTimer; AsyncTimer=$asyncTimer; PollTimer=$pollTimer; Animating=$false
        DrawerSnapshot=$drawerSnapshot; OrderSnapshot=$orderSnapshot; PaySnapshot=$paySnapshot; AsyncOperation=$null; Generation=0
    }

    foreach ($quick in $script:JbbRechargeUi.QuickButtons) { $quick.Add_Click({ $script:JbbRechargeUi.AmountBox.Text = [string]$this.Tag; Set-JbbRechargeQuickSelection -Selected $this }) }
    $createButton.Add_Click({ Invoke-JbbRechargeOrderCreation })
    $returnButton.Add_Click({ Hide-JbbRechargeDrawer })
    $supportButton.Add_Click({ Show-JbbRechargeSupportCard })
    $supportBack.Add_Click({ $script:JbbRechargeUi.SupportCard.Visible = $false })
    $copyQq.Add_Click({ [System.Windows.Forms.Clipboard]::SetText('1165643117'); $script:JbbRechargeUi.SupportState.Text = 'QQ 号已复制。' })
    $pollTimer.Add_Tick({ $this.Stop(); Update-JbbRechargeOrderStatus })
    $asyncTimer.Add_Tick({ Complete-JbbRechargeAsyncOperation })
    $animationTimer.Add_Tick({
        try {
            $state = $script:JbbRechargeAnimationState
            $ui = $script:JbbRechargeUi
            if (-not $state -or -not $ui) { if ($ui) { $ui.AnimationTimer.Stop() }; return }
            [void]$state.Intervals.Add($state.LastTick.Elapsed.TotalMilliseconds); $state.LastTick.Restart()
            $t = [Math]::Min(1.0,([DateTime]::UtcNow - $state.Started).TotalMilliseconds / $state.Duration)
            $ease = if ($state.Mode -eq 'Close') { [Math]::Pow($t,3) } else { 1.0 - [Math]::Pow(1.0-$t,3) }
            if ($state.Mode -eq 'Stage') {
                $ui.OrderSnapshot.Left = [int]($state.OrderStart + ($state.OrderEnd-$state.OrderStart)*$ease)
                $ui.PaySnapshot.Left = [int]($state.PayStart + ($state.PayEnd-$state.PayStart)*$ease)
            } else {
                $ui.DrawerSnapshot.Left = [int]($state.DrawerStart + ($state.DrawerEnd-$state.DrawerStart)*$ease)
            }
            if ($t -ge 1.0) {
                $ui.AnimationTimer.Stop(); $ui.Animating = $false; $ui.ReturnButton.Enabled = $true; $ui.SupportButton.Enabled = $true
                $state.LastTick.Stop(); Write-JbbRechargePerfLog -Mode $state.Mode -Intervals $state.Intervals
                if ($state.Mode -eq 'Stage') {
                    $ui.OrderCard.Left = $state.OrderEnd; $ui.PayCard.Left = $state.PayEnd
                    $ui.OrderSnapshot.Visible = $false; $ui.PaySnapshot.Visible = $false
                    Set-JbbSnapshotImage -PictureBox $ui.OrderSnapshot -Image $null; Set-JbbSnapshotImage -PictureBox $ui.PaySnapshot -Image $null
                    $ui.OrderCard.Visible = $true; $ui.PayCard.Visible = $true
                } else {
                    $ui.DrawerSnapshot.Visible = $false; Set-JbbSnapshotImage -PictureBox $ui.DrawerSnapshot -Image $null
                    if ($state.Mode -eq 'Close') { $ui.Drawer.Visible = $false }
                    else { $ui.Drawer.Location = New-Object System.Drawing.Point($state.DrawerEnd,0); $ui.OrderCard.Top = [int](126*([double]$ui.Drawer.Width/800.0)); $ui.Drawer.Visible = $true; $ui.Drawer.BringToFront(); Load-JbbRechargeData }
                }
            }
        } catch {
            $errorMessage = [string]$_.Exception.Message
            if ($env:JBB_LAUNCHER_PERF_LOG) { try { Add-Content -LiteralPath $env:JBB_LAUNCHER_PERF_LOG -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') + "`tERROR`t" + $errorMessage) -Encoding UTF8 } catch {} }
            $script:JbbRechargeUi.AnimationTimer.Stop(); $script:JbbRechargeUi.Animating = $false
            $script:JbbRechargeUi.DrawerSnapshot.Visible = $false; $script:JbbRechargeUi.OrderSnapshot.Visible = $false; $script:JbbRechargeUi.PaySnapshot.Visible = $false
            if ($script:JbbRechargeAnimationState.Mode -eq 'Open') { $script:JbbRechargeUi.Drawer.Visible = $true; $script:JbbRechargeUi.Drawer.BringToFront(); Load-JbbRechargeData }
        }
    })

    $drawer.Controls.AddRange(@($logo,$title,$header,$sub,$orderCard,$payCard,$help,$supportButton,$returnButton,$supportCard,$orderSnapshot,$paySnapshot))
    $Owner.Controls.AddRange(@($drawer,$drawerSnapshot))
    $drawer.BringToFront()
}

function Show-JbbNativeRechargeDialog {
    param([System.Windows.Forms.Form]$Owner)
    $targetForm = if ($script:JbbMainForm) { $script:JbbMainForm } else { $Owner }
    $previewMode = [string]$env:JBB_LAUNCHER_UI_PREVIEW
    if ($previewMode -eq 'Recharge') { $auth = [pscustomobject]@{ user_id = 0; access_token = 'preview' } }
    else {
        $auth = Get-JbbDesktopSession
        if (-not $auth) { $auth = Show-JbbNativeAccountDialog -Owner $targetForm }
        if (-not $auth) { return }
    }
    Initialize-JbbRechargeDrawer -Owner $targetForm
    if ($script:JbbRechargeUi.Drawer.Visible -or $script:JbbRechargeUi.Animating) { return }
    $script:JbbRechargeAuth = $auth
    $script:JbbRechargeUi.Generation = [int]$script:JbbRechargeUi.Generation + 1
    $script:JbbRechargeUi.AsyncOperation = $null; $script:JbbRechargeUi.AsyncTimer.Stop(); $script:JbbRechargeUi.PollTimer.Stop()
    Set-JbbRechargeInitialStage
    $script:JbbRechargeUi.WalletAmount.Text = '读取中...'
    $script:JbbRechargeUi.WalletHint.Text = ''
    $script:JbbRechargeUi.Status.Text = '正在读取充值信息...'
    Start-JbbRechargeAnimation -Mode Open
}

function Start-JbbRechargePreviewStress {
    param([int]$Cycles)
    if ($Cycles -le 0 -or -not $script:JbbRechargeUi) { return }
    $ui = $script:JbbRechargeUi
    $process = [System.Diagnostics.Process]::GetCurrentProcess()
    $state = @{ Phase='Open'; Count=0; Warmed=$false; StartHandles=$process.HandleCount; StartMemory=$process.PrivateMemorySize64; StartGdi=[JbbUiNative]::GetGdiCount(); StartUser=[JbbUiNative]::GetUserCount() }
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 40
    $script:JbbRechargeStressTimer = $timer
    $timer.Add_Tick(({
        if ($ui.Animating) { return }
        if ($state.Phase -eq 'Open' -and $ui.Drawer.Visible) {
            Hide-JbbRechargeDrawer; $state.Phase = 'Close'; return
        }
        if ($state.Phase -eq 'Close' -and -not $ui.Drawer.Visible -and -not $ui.DrawerSnapshot.Visible) {
            if (-not $state.Warmed) {
                [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect(); $process.Refresh()
                $state.StartHandles=$process.HandleCount; $state.StartMemory=$process.PrivateMemorySize64; $state.StartGdi=[JbbUiNative]::GetGdiCount(); $state.StartUser=[JbbUiNative]::GetUserCount(); $state.Warmed=$true
                Show-JbbNativeRechargeDialog -Owner $ui.Host; $state.Phase = 'Open'; return
            }
            $state.Count++
            if ($state.Count -ge $Cycles) {
                $timer.Stop(); $timer.Dispose(); [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect(); $process.Refresh()
                if ($env:JBB_LAUNCHER_PERF_LOG) {
                    $line = "{0}`tSTRESS`tcycles={1}`thandles={2}->{3}`tgdi={4}->{5}`tuser={6}->{7}`tprivateMB={8}->{9}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'),$state.Count,$state.StartHandles,$process.HandleCount,$state.StartGdi,[JbbUiNative]::GetGdiCount(),$state.StartUser,[JbbUiNative]::GetUserCount(),[Math]::Round($state.StartMemory/1MB,2),[Math]::Round($process.PrivateMemorySize64/1MB,2)
                    Add-Content -LiteralPath $env:JBB_LAUNCHER_PERF_LOG -Value $line -Encoding UTF8
                }
                return
            }
            Show-JbbNativeRechargeDialog -Owner $ui.Host; $state.Phase = 'Open'
        }
    }).GetNewClosure())
    $timer.Start()
}
function Invoke-JbbTokenLogin {
    param(
        [System.Windows.Forms.TextBox]$ApiBox,
        [System.Windows.Forms.TextBox]$UrlBox,
        [System.Windows.Forms.Label]$StatusLabel,
        [System.Windows.Forms.Form]$Owner
    )

    try {
        $StatusLabel.Text = '正在检查本机登录状态...'
        [System.Windows.Forms.Application]::DoEvents()

        $auth = Get-JbbDesktopSession
        if ($auth) {
            try {
                $connectionJson = Get-JbbConnectionByAuth $auth
                $applied = Try-ApplyConnectionJson -JsonText $connectionJson -ApiBox $ApiBox -UrlBox $UrlBox -ShowError $true
                if ($applied) {
                    $StatusLabel.Text = '已使用本机保存的 JBBToken 登录状态自动获取 API Key。'
                    [System.Windows.Forms.Application]::DoEvents()
                    return
                }
            }
            catch {
                Clear-JbbDesktopSession
            }
        }

        $StatusLabel.Text = '请在启动器内登录或注册 JBBToken。'
        [System.Windows.Forms.Application]::DoEvents()
        $auth = Show-JbbNativeAccountDialog -Owner $Owner
        if (-not $auth) {
            throw '未完成登录。'
        }

        $connectionJson = Get-JbbConnectionByAuth $auth
        $applied = Try-ApplyConnectionJson -JsonText $connectionJson -ApiBox $ApiBox -UrlBox $UrlBox -ShowError $true
        if (-not $applied) {
            throw (T 'LoginNoConnection')
        }

        $StatusLabel.Text = '登录成功，API Key 已自动获取。'
        [System.Windows.Forms.Application]::DoEvents()
    }
    catch {
        $message = $_.Exception.Message
        $StatusLabel.Text = '登录失败：' + $message
        [System.Windows.Forms.MessageBox]::Show($Owner, $message, (T 'LoginFailedTitle'), 'OK', 'Warning') | Out-Null
    }
}

function Show-CodexStartDialog {
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = T 'StartDialogTitle2'
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ClientSize = New-Object System.Drawing.Size(660, 650)
    $dialog.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $dialog.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)

    $dialogHeader = New-Object System.Windows.Forms.Panel
    $dialogHeader.Location = New-Object System.Drawing.Point(0, 0)
    $dialogHeader.Size = New-Object System.Drawing.Size(660, 82)
    $dialogHeader.BackColor = [System.Drawing.Color]::White

    $jsonLabel = New-Object System.Windows.Forms.Label
    $jsonLabel.Text = T 'LoginOrPasteTitle'
    $jsonLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
    $jsonLabel.ForeColor = [System.Drawing.Color]::FromArgb(24, 35, 52)
    $jsonLabel.Location = New-Object System.Drawing.Point(28, 18)
    $jsonLabel.Size = New-Object System.Drawing.Size(600, 30)

    $jsonHelp = New-Object System.Windows.Forms.Label
    $jsonHelp.Text = '推荐点“登录/注册并自动获取”：全程在启动器内完成；复制 Key 后也会自动识别。'
    $jsonHelp.ForeColor = [System.Drawing.Color]::FromArgb(90, 99, 115)
    $jsonHelp.Location = New-Object System.Drawing.Point(30, 50)
    $jsonHelp.Size = New-Object System.Drawing.Size(600, 24)

    $dialogHeader.Controls.AddRange(@($jsonLabel, $jsonHelp))

    $loginButton = New-Object System.Windows.Forms.Button
    $loginButton.Text = '登录/注册并自动获取'
    $loginButton.Location = New-Object System.Drawing.Point(28, 154)
    $loginButton.Size = New-Object System.Drawing.Size(190, 40)
    $loginButton.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
    $loginButton.ForeColor = [System.Drawing.Color]::White
    $loginButton.FlatStyle = 'Flat'
    $loginButton.FlatAppearance.BorderSize = 0

    $registerButton = New-Object System.Windows.Forms.Button
    $registerButton.Text = '登录/注册'
    $registerButton.Location = New-Object System.Drawing.Point(28, 104)
    $registerButton.Size = New-Object System.Drawing.Size(150, 34)
    $registerButton.BackColor = [System.Drawing.Color]::White
    $registerButton.FlatStyle = 'Flat'

    $tokenPageButton = New-Object System.Windows.Forms.Button
    $tokenPageButton.Text = '切换账号'
    $tokenPageButton.Location = New-Object System.Drawing.Point(190, 104)
    $tokenPageButton.Size = New-Object System.Drawing.Size(180, 34)
    $tokenPageButton.BackColor = [System.Drawing.Color]::White
    $tokenPageButton.FlatStyle = 'Flat'

    $rechargeButton = New-Object System.Windows.Forms.Button
    $rechargeButton.Text = '充值中心'
    $rechargeButton.Location = New-Object System.Drawing.Point(382, 104)
    $rechargeButton.Size = New-Object System.Drawing.Size(150, 34)
    $rechargeButton.BackColor = [System.Drawing.Color]::White
    $rechargeButton.FlatStyle = 'Flat'

    $loginStatus = New-Object System.Windows.Forms.Label
    $loginStatus.Text = '不用离开启动器：登录或注册后会自动获取 API Key，下面也保留手动粘贴兜底。'
    $loginStatus.ForeColor = [System.Drawing.Color]::FromArgb(90, 99, 115)
    $loginStatus.Location = New-Object System.Drawing.Point(30, 202)
    $loginStatus.Size = New-Object System.Drawing.Size(602, 42)

    $jsonBox = New-Object System.Windows.Forms.TextBox
    $jsonBox.Location = New-Object System.Drawing.Point(28, 270)
    $jsonBox.Size = New-Object System.Drawing.Size(604, 96)
    $jsonBox.Multiline = $true
    $jsonBox.ScrollBars = 'Vertical'
    $jsonBox.BorderStyle = 'FixedSingle'

    $manualHelp = New-Object System.Windows.Forms.Label
    $manualHelp.Text = '兜底：如果自动接口暂不可用，可把 API Key 或连接 JSON 粘到这里。'
    $manualHelp.ForeColor = [System.Drawing.Color]::FromArgb(90, 99, 115)
    $manualHelp.Location = New-Object System.Drawing.Point(30, 380)
    $manualHelp.Size = New-Object System.Drawing.Size(600, 24)

    $apiLabel = New-Object System.Windows.Forms.Label
    $apiLabel.Text = T 'ApiKeyLabel'
    $apiLabel.Location = New-Object System.Drawing.Point(28, 416)
    $apiLabel.Size = New-Object System.Drawing.Size(604, 22)
    $apiLabel.ForeColor = [System.Drawing.Color]::FromArgb(24, 35, 52)

    $apiBox = New-Object System.Windows.Forms.TextBox
    $apiBox.Location = New-Object System.Drawing.Point(28, 442)
    $apiBox.Size = New-Object System.Drawing.Size(604, 28)
    $apiBox.UseSystemPasswordChar = $true

    $urlLabel = New-Object System.Windows.Forms.Label
    $urlLabel.Text = T 'BaseUrlLabel'
    $urlLabel.Location = New-Object System.Drawing.Point(28, 484)
    $urlLabel.Size = New-Object System.Drawing.Size(604, 22)
    $urlLabel.ForeColor = [System.Drawing.Color]::FromArgb(24, 35, 52)

    $urlBox = New-Object System.Windows.Forms.TextBox
    $urlBox.Location = New-Object System.Drawing.Point(28, 510)
    $urlBox.Size = New-Object System.Drawing.Size(604, 28)
    $urlBox.Text = $script:JbbApiBaseUrl

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = T 'OkStart'
    $okButton.Location = New-Object System.Drawing.Point(424, 590)
    $okButton.Size = New-Object System.Drawing.Size(112, 32)
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $okButton.BackColor = [System.Drawing.Color]::FromArgb(16, 185, 129)
    $okButton.ForeColor = [System.Drawing.Color]::White
    $okButton.FlatStyle = 'Flat'
    $okButton.FlatAppearance.BorderSize = 0

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = T 'Cancel'
    $cancelButton.Location = New-Object System.Drawing.Point(546, 590)
    $cancelButton.Size = New-Object System.Drawing.Size(86, 32)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $jsonBox.Add_TextChanged({
        Try-ApplyConnectionJson -JsonText $jsonBox.Text -ApiBox $apiBox -UrlBox $urlBox -ShowError $false | Out-Null
    })

    $script:lastJbbClipboardText = ''
    $clipboardTimer = New-Object System.Windows.Forms.Timer
    $clipboardTimer.Interval = 900
    $clipboardTimer.Add_Tick({
        try {
            if (-not [System.Windows.Forms.Clipboard]::ContainsText()) { return }
            $clip = [System.Windows.Forms.Clipboard]::GetText()
            if ([string]::IsNullOrWhiteSpace($clip) -or $clip -eq $script:lastJbbClipboardText) { return }
            $script:lastJbbClipboardText = $clip

            if (Try-ApplyConnectionJson -JsonText $clip -ApiBox $apiBox -UrlBox $urlBox -ShowError $false) {
                if ($jsonBox.Text -ne $clip) { $jsonBox.Text = $clip }
                $loginStatus.Text = '已从剪贴板自动识别连接信息。直接点“保存并启动”。'
                return
            }

            $keyMatch = [regex]::Match($clip, '(sk-[A-Za-z0-9_\-]{20,})')
            if ($keyMatch.Success) {
                $apiBox.Text = $keyMatch.Groups[1].Value
                if ([string]::IsNullOrWhiteSpace($urlBox.Text)) { $urlBox.Text = $script:JbbApiBaseUrl }
                $loginStatus.Text = '已从剪贴板自动识别 API Key。直接点“保存并启动”。'
            }
        } catch {}
    })
    $dialog.Add_Shown({ try { $clipboardTimer.Start() } catch {} })
    $dialog.Add_FormClosed({ try { $clipboardTimer.Stop(); $clipboardTimer.Dispose() } catch {} })

    $registerButton.Add_Click({
        Invoke-JbbTokenLogin -ApiBox $apiBox -UrlBox $urlBox -StatusLabel $loginStatus -Owner $dialog
    })

    $tokenPageButton.Add_Click({
        Clear-JbbDesktopSession
        $apiBox.Text = ''
        $loginStatus.Text = '已清除本机登录状态，请重新登录。'
        Invoke-JbbTokenLogin -ApiBox $apiBox -UrlBox $urlBox -StatusLabel $loginStatus -Owner $dialog
    })

    $rechargeButton.Add_Click({
        Show-JbbNativeRechargeDialog -Owner $dialog
    })

    $loginButton.Add_Click({
        Invoke-JbbTokenLogin -ApiBox $apiBox -UrlBox $urlBox -StatusLabel $loginStatus -Owner $dialog
    })

    $dialog.Controls.AddRange(@($dialogHeader, $registerButton, $tokenPageButton, $rechargeButton, $loginButton, $loginStatus, $jsonBox, $manualHelp, $apiLabel, $apiBox, $urlLabel, $urlBox, $okButton, $cancelButton))
    $dialog.AcceptButton = $okButton
    $dialog.CancelButton = $cancelButton
    Enable-JbbFormEntranceAnimation -Form $dialog

    $result = $dialog.ShowDialog($form)
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }

    if (-not [string]::IsNullOrWhiteSpace($jsonBox.Text)) {
        $jsonApplied = Try-ApplyConnectionJson -JsonText $jsonBox.Text -ApiBox $apiBox -UrlBox $urlBox -ShowError $true
        if (-not $jsonApplied) {
            return $null
        }
    }

    if ([string]::IsNullOrWhiteSpace($apiBox.Text)) {
        [System.Windows.Forms.MessageBox]::Show($dialog, (T 'ApiKeyMissing'), (T 'ApiKeyMissingTitle'), 'OK', 'Warning') | Out-Null
        return $null
    }

    return [pscustomobject]@{
        ApiKey = $apiBox.Text
        BaseUrl = Normalize-BaseUrl $urlBox.Text
    }
}


function New-JbbLabel {
    param([string]$Text,[int]$X,[int]$Y,[int]$W,[int]$H,[int]$Size = 9,[bool]$Bold = $false,[System.Drawing.Color]$Color = $null,[string]$Align = 'TopLeft')
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($W, $H)
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $label.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', $Size, $style)
    if ($Color) { $label.ForeColor = $Color }
    $label.TextAlign = $Align
    $label.BackColor = [System.Drawing.Color]::Transparent
    $label.UseCompatibleTextRendering = $false
    return $label
}
function New-JbbCard {
    param([int]$X,[int]$Y,[int]$W,[int]$H,[int]$Radius = 16)
    $panel = New-Object JbbRoundedPanel
    $panel.Location = New-Object System.Drawing.Point($X, $Y)
    $panel.Size = New-Object System.Drawing.Size($W, $H)
    $panel.BackColor = [System.Drawing.Color]::White
    $panel.CornerRadius = $Radius
    $panel.BorderColor = [System.Drawing.Color]::FromArgb(218,228,242)
    $panel.BorderThickness = 1
    return $panel
}
function New-JbbButton {
    param([string]$Text,[int]$X,[int]$Y,[int]$W,[int]$H,[string]$Kind = 'Secondary',[int]$Size = 10)
    $button = New-Object JbbRoundedButton
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point($X, $Y)
    $button.Size = New-Object System.Drawing.Size($W, $H)
    $button.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', $Size, [System.Drawing.FontStyle]::Bold)
    $button.CornerRadius = if ($H -ge 52) { 14 } else { 10 }
    if ($Kind -eq 'Primary') { $button.BackColor = [System.Drawing.Color]::FromArgb(20,99,255); $button.ForeColor = [System.Drawing.Color]::White; $button.BorderColor = $button.BackColor; $button.BorderThickness = 0 }
    elseif ($Kind -eq 'Success') { $button.BackColor = [System.Drawing.Color]::FromArgb(22,163,74); $button.ForeColor = [System.Drawing.Color]::White; $button.BorderColor = $button.BackColor; $button.BorderThickness = 0 }
    elseif ($Kind -eq 'Danger') { $button.BackColor = [System.Drawing.Color]::FromArgb(254,242,242); $button.ForeColor = [System.Drawing.Color]::FromArgb(185,28,28); $button.BorderColor = [System.Drawing.Color]::FromArgb(254,202,202); $button.BorderThickness = 1 }
    else { $button.BackColor = [System.Drawing.Color]::White; $button.ForeColor = [System.Drawing.Color]::FromArgb(20,99,255); $button.BorderColor = [System.Drawing.Color]::FromArgb(191,219,254); $button.BorderThickness = 1 }
    return $button
}
function New-JbbGooeyButton {
    param([string]$Text,[int]$X,[int]$Y,[int]$W,[int]$H,[int]$Size = 10)
    $button = New-Object JbbGooeyButton
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point($X,$Y)
    $button.Size = New-Object System.Drawing.Size($W,$H)
    $button.Font = New-Object System.Drawing.Font('Microsoft YaHei UI',$Size,[System.Drawing.FontStyle]::Bold)
    $button.CornerRadius = if ($H -ge 52) { 14 } else { 10 }
    $button.BackColor = [System.Drawing.Color]::FromArgb(22,163,74)
    $button.ForeColor = [System.Drawing.Color]::White
    $button.BorderColor = $button.BackColor
    $button.BorderThickness = 0
    return $button
}
function New-JbbLogo {
    param([int]$X,[int]$Y,[int]$W = 54,[int]$H = 54,[int]$Size = 17)
    $logo = New-JbbCard -X $X -Y $Y -W $W -H $H -Radius 12
    $logo.BackColor = [System.Drawing.Color]::FromArgb(20,99,255)
    $logo.BorderColor = $logo.BackColor
    $text = New-JbbLabel -Text 'JBB' -X 0 -Y 0 -W $W -H $H -Size $Size -Bold $true -Color ([System.Drawing.Color]::White) -Align 'MiddleCenter'
    [void]$logo.Controls.Add($text)
    return $logo
}
function New-JbbDivider {
    param([int]$X,[int]$Y,[int]$W)
    $line = New-Object System.Windows.Forms.Panel
    $line.Location = New-Object System.Drawing.Point($X,$Y)
    $line.Size = New-Object System.Drawing.Size($W,1)
    $line.BackColor = [System.Drawing.Color]::FromArgb(226,232,240)
    return $line
}
function Set-JbbInputStyle {
    param([System.Windows.Forms.Control]$Control,[int]$Size = 10)
    $Control.Font = New-Object System.Drawing.Font('Microsoft YaHei UI',$Size)
    $Control.BackColor = [System.Drawing.Color]::White
    $Control.ForeColor = [System.Drawing.Color]::FromArgb(15,23,42)
    if ($Control -is [System.Windows.Forms.TextBox]) { $Control.BorderStyle = 'FixedSingle' }
}
function Get-JbbPreviewScale {
    $value = 1.0
    if (-not [string]::IsNullOrWhiteSpace($env:JBB_LAUNCHER_UI_SCALE)) { [double]::TryParse($env:JBB_LAUNCHER_UI_SCALE, [ref]$value) | Out-Null }
    if ($value -lt 1.0 -or $value -gt 1.5) { $value = 1.0 }
    return $value
}
function Apply-JbbPreviewScale {
    param([System.Windows.Forms.Form]$Form,[int]$BaseWidth,[int]$BaseHeight)
    $scale = Get-JbbPreviewScale
    if ([string]::IsNullOrWhiteSpace($env:JBB_LAUNCHER_UI_SCALE)) { return }
    [void]$Form.Handle
    $deviceScale = 1.0
    try { if ($Form.DeviceDpi -gt 0) { $deviceScale = [double]$Form.DeviceDpi / 96.0 } } catch {}
    $Form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $ratio = $scale / $deviceScale
    if ([Math]::Abs($ratio - 1.0) -gt 0.001) { $Form.Scale((New-Object System.Drawing.SizeF($ratio,$ratio))) }
    $Form.ClientSize = New-Object System.Drawing.Size([int]($BaseWidth*$scale),[int]($BaseHeight*$scale))
}
function Save-JbbFormCapture {
    param([System.Windows.Forms.Form]$Form,[string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $dir = Split-Path -Parent $Path
    if ($dir) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $bitmap = New-Object System.Drawing.Bitmap($Form.Width,$Form.Height)
    try {
        $Form.DrawToBitmap($bitmap,(New-Object System.Drawing.Rectangle(0,0,$bitmap.Width,$bitmap.Height)))
        $bitmap.Save($Path,[System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally { $bitmap.Dispose() }
}
function Mask-JbbSecret {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '未获取' }
    if ($Value.Length -le 12) { return '***' }
    return ($Value.Substring(0, 6) + '...' + $Value.Substring($Value.Length - 4))
}
function Set-JbbPage {
    param([string]$Page)
    $loginPagePanel.Visible = ($Page -eq 'Login')
    $dashboardPagePanel.Visible = ($Page -eq 'Dashboard')
    if ($Page -eq 'Login') { $form.Text = 'JBBToken Codex 一键启动器' } else { $form.Text = 'JBBToken Codex 一键启动器（2/2）' }
}
function Invoke-JbbOfflineInstallIfNeeded {
    param([bool]$Force = $false)
    $env:CODEX_HOME = Get-CodexHome
    Add-CodexPathForCurrentProcess
    if (-not $Force -and (Get-CodexCommand)) { Set-ProgressState -Value 100 -Message 'Codex 已安装，跳过离线安装。'; return }
    Set-ProgressState -Value 8 -Message '正在准备内置离线安装包...'
    $installerPath = Join-Path $PSScriptRoot 'Install-CodexOffline-Win64.ps1'
    if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) { throw '内置 Codex 离线安装脚本缺失。' }
    Set-ProgressState -Value 28 -Message '正在离线安装 Codex...'
    $env:CODEX_NON_INTERACTIVE = '1'
    $stdout = Join-Path $env:TEMP ('codex-install-out-' + [guid]::NewGuid().ToString('N') + '.log')
    $stderr = Join-Path $env:TEMP ('codex-install-err-' + [guid]::NewGuid().ToString('N') + '.log')
    $installerCommand = '& ' + (ConvertTo-PowerShellSingleQuotedString $installerPath)
    $process = Start-Process -FilePath (Get-WindowsPowerShellPath) -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',(New-EncodedPowerShellCommand $installerCommand)) -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    if ($process.ExitCode -ne 0) {
        $errorText = ''
        if (Test-Path $stderr) { $errorText = Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue }
        if ([string]::IsNullOrWhiteSpace($errorText) -and (Test-Path $stdout)) { $errorText = Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue }
        throw ('Codex 离线安装失败，退出码 ' + $process.ExitCode + '。' + $errorText)
    }
    Set-ProgressState -Value 78 -Message '正在验证 Codex 安装...'
    if (-not (Get-CodexCommand)) { throw 'Codex 安装后仍未找到命令。' }
    $versionText = (& codex --version 2>&1 | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($versionText)) { $versionText = 'Codex CLI' }
    Set-ProgressState -Value 100 -Message ('Codex 已安装：' + $versionText)
}
function Get-JbbAuthOrPrompt {
    param([System.Windows.Forms.Form]$Owner)
    $auth = Get-JbbDesktopSession
    if ($auth) { return $auth }
    $auth = Show-JbbNativeAccountDialog -Owner $Owner
    if (-not $auth) { throw '未完成登录。' }
    return $auth
}
function Refresh-JbbDashboard {
    param([bool]$Silent = $false)
    $auth = Get-JbbDesktopSession
    if (-not $auth) { Set-JbbPage -Page 'Login'; return }
    try {
        if (-not $Silent) { Set-ProgressState -Value 15 -Message '正在同步 JBBToken 账户状态...' }
        $session = Invoke-JbbDesktopApi -Path '/session' -Method Get -Auth $auth
        $walletResp = Invoke-JbbDesktopApi -Path '/wallet' -Method Get -Auth $auth
        $tokenResp = Invoke-JbbDesktopApi -Path '/token' -Method Get -Auth $auth
        $user = $session.data.user; $wallet = $walletResp.data; $tokenData = $tokenResp.data; $connection = $tokenData.connection; $apiKey = [string]$tokenData.api_key
        $displayName = [string]$user.username
        if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = [string]$auth.username }
        $dashboardUserLabel.Text = '已登录：' + $displayName
        $balanceAmountLabel.Text = Format-JbbCurrencyDisplay -Balance $wallet.display_balance -DisplayType ([string]$wallet.display_type)
        $balanceHintLabel.Text = if ($wallet.low_balance) { '余额偏低，建议充值' } else { '额度充足' }
        $apiStateLabel.Text = 'API Key 已自动获取：' + (Mask-JbbSecret $apiKey)
        $baseUrlValueLabel.Text = [string]$connection.url
        if ($dashboardToolTip) { $dashboardToolTip.SetToolTip($baseUrlValueLabel, [string]$connection.url); $dashboardToolTip.SetToolTip($apiStateLabel, $apiStateLabel.Text) }
        $versionValueLabel.Text = $script:AppVersion
        $lastCheckValueLabel.Text = Get-Date -Format 'HH:mm:ss'
        $gatewayDotLabel.ForeColor = [System.Drawing.Color]::FromArgb(217,119,6)
        $gatewayStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(217,119,6)
        $gatewayStatusLabel.Text = '●  API 待测试'
        $authStateLabel.Text = '●  API Key 已准备'
        if (Get-CodexCommand) { $codexStateLabel.Text = '●  Codex 已安装'; try { $v = (& codex --version 2>&1 | Out-String).Trim(); if ($v) { $versionValueLabel.Text = $v } } catch {} } else { $codexStateLabel.Text = '●  Codex 待安装' }
        Set-JbbPage -Page 'Dashboard'
        if (-not $Silent) { Set-ProgressState -Value 100 -Message '账户状态已同步。' }
    } catch {
        Clear-JbbDesktopSession; Set-JbbPage -Page 'Login'
        if (-not $Silent) { Set-ProgressState -Value 0 -Message ('账户状态同步失败：' + $_.Exception.Message) }
    }
}
function Invoke-JbbNetworkSelfTest {
    param([System.Windows.Forms.Form]$Owner)
    try {
        Set-ButtonsEnabled $false
        Set-ProgressState -Value 10 -Message '正在检测 downstream.jbbtoken.cn...'
        $statusUri = $script:JbbDesktopApiBase -replace '/api/desktop/codex/?$', '/api/status'
        $resp = Invoke-RestMethod -Uri $statusUri -Method Get -TimeoutSec 20
        if ($resp.success -eq $false) { throw ([string]$resp.message) }
        Set-ProgressState -Value 55 -Message '下游服务与桌面网关入口可达。'
        if (Get-CodexCommand) { Set-ProgressState -Value 88 -Message '本机已检测到 Codex 命令。' } else { Set-ProgressState -Value 88 -Message '本机暂未检测到 Codex；启动时可用内置包离线安装。' }
        Set-ProgressState -Value 100 -Message '网络自检完成。'
        [System.Windows.Forms.MessageBox]::Show($Owner, '网络正常：JBBToken 网关可达。', '网络自检', 'OK', 'Information') | Out-Null
    } catch { Set-ProgressState -Value 0 -Message ('网络自检失败：' + $_.Exception.Message); [System.Windows.Forms.MessageBox]::Show($Owner, $_.Exception.Message, '网络自检失败', 'OK', 'Warning') | Out-Null } finally { Set-ButtonsEnabled $true }
}
function Invoke-JbbApiConnectionTest {
    param([System.Windows.Forms.Form]$Owner)
    Set-ButtonsEnabled $false
    try {
        $auth = Get-JbbAuthOrPrompt -Owner $Owner
        Set-ProgressState -Value 15 -Message '正在获取 API Key 和 Base URL...'
        $connectionJson = Get-JbbConnectionByAuth $auth
        $connection = $connectionJson | ConvertFrom-Json
        $apiKey = [string]$connection.key
        $baseUrl = Normalize-BaseUrl ([string]$connection.url)
        Set-ProgressState -Value 45 -Message ('正在测试 API：' + $baseUrl)
        $result = Test-JbbApiConnection -ApiKey $apiKey -BaseUrl $baseUrl
        $gatewayDotLabel.ForeColor = [System.Drawing.Color]::FromArgb(22,163,74)
        $gatewayStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(22,163,74)
        $gatewayStatusLabel.Text = '●  API 连接正常'
        $authStateLabel.Text = '●  API Key 有效'
        $lastCheckValueLabel.Text = Get-Date -Format 'HH:mm:ss'
        Set-ProgressState -Value 100 -Message ('API 测试通过，耗时 ' + $result.ElapsedMs + ' ms，可用模型 ' + $result.ModelCount + ' 个。')
        [System.Windows.Forms.MessageBox]::Show($Owner, ('API 连接正常。' + [Environment]::NewLine + '地址：' + $baseUrl + [Environment]::NewLine + '耗时：' + $result.ElapsedMs + ' ms'), 'API 测试通过', 'OK', 'Information') | Out-Null
    }
    catch {
        $message = $_.Exception.Message
        $gatewayDotLabel.ForeColor = [System.Drawing.Color]::FromArgb(220,38,38)
        $gatewayStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(220,38,38)
        $gatewayStatusLabel.Text = '●  API 测试失败'
        $authStateLabel.Text = '●  API Key 待检查'
        $lastCheckValueLabel.Text = Get-Date -Format 'HH:mm:ss'
        Set-ProgressState -Value 0 -Message ('API 测试失败：' + $message)
        [System.Windows.Forms.MessageBox]::Show($Owner, $message, 'API 测试失败', 'OK', 'Error') | Out-Null
    }
    finally {
        Set-ButtonsEnabled $true
    }
}
function Invoke-CodexLoginWithApiKey {
    param([string]$ApiKey)
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = ($ApiKey | codex login --with-api-key 2>&1 | Out-String).Trim()
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldEap
    }
    if ($exitCode -ne 0) {
        throw ('API Key 配置失败：' + $output)
    }
    return $output
}
function Invoke-JbbConfigureCodex {
    param([System.Windows.Forms.Form]$Owner,[bool]$Launch = $false)
    Set-ButtonsEnabled $false
    try {
        $auth = Get-JbbAuthOrPrompt -Owner $Owner
        Set-ProgressState -Value 10 -Message '正在读取 JBBToken API Key...'
        $connectionJson = Get-JbbConnectionByAuth $auth
        $connection = $connectionJson | ConvertFrom-Json
        $apiKey = [string]$connection.key; $baseUrl = Normalize-BaseUrl ([string]$connection.url)
        if ([string]::IsNullOrWhiteSpace($apiKey) -or [string]::IsNullOrWhiteSpace($baseUrl)) { throw '服务器返回的 API Key 或 Base URL 为空。' }
        Set-ProgressState -Value 18 -Message ('正在启动前测试 API 连通性：' + $baseUrl)
        $apiTest = Test-JbbApiConnection -ApiKey $apiKey -BaseUrl $baseUrl
        Set-ProgressState -Value 30 -Message ('API 测试通过，耗时 ' + $apiTest.ElapsedMs + ' ms。')
        $env:CODEX_HOME = Get-CodexHome
        Set-ProgressState -Value 38 -Message '正在确认 Codex 安装状态...'
        Invoke-JbbOfflineInstallIfNeeded
        Set-ProgressState -Value 62 -Message '正在写入 JBBToken 网关配置...'
        Set-CodexBaseUrl -BaseUrl $baseUrl
        Set-ProgressState -Value 76 -Message '正在写入 API Key 到 Codex...'
        $loginOutput = Invoke-CodexLoginWithApiKey -ApiKey $apiKey
        Set-ProgressState -Value 90 -Message '正在验证 Codex 登录状态...'
        Test-CodexAlreadyReady | Out-Null
        if ($Launch) { Set-ProgressState -Value 96 -Message '正在启动 Codex...'; $jbbCodexHome = Get-CodexHome; $launchCommand = '$env:CODEX_HOME = ' + (ConvertTo-PowerShellSingleQuotedString $jbbCodexHome) + '; Set-Location -LiteralPath ' + (ConvertTo-PowerShellSingleQuotedString $env:USERPROFILE) + '; codex'; Start-Process -FilePath (Get-WindowsPowerShellPath) -ArgumentList @('-NoExit','-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',(New-EncodedPowerShellCommand $launchCommand)) -WorkingDirectory $env:USERPROFILE | Out-Null; Set-ProgressState -Value 100 -Message 'Codex 已启动（JBBToken 独立配置）。' } else { Set-ProgressState -Value 100 -Message 'Codex 已重新配置完成。' }
        Refresh-JbbDashboard -Silent $true
    } catch { $message = $_.Exception.Message; Set-ProgressState -Value 0 -Message ('操作失败：' + $message); if (Test-IsQuotaError $message) { $choice = [System.Windows.Forms.MessageBox]::Show($Owner, ($message + [Environment]::NewLine + [Environment]::NewLine + '是否打开充值中心？'), '额度不足', 'YesNo', 'Warning'); if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) { Show-JbbNativeRechargeDialog -Owner $Owner } } else { [System.Windows.Forms.MessageBox]::Show($Owner, $message, '操作失败', 'OK', 'Error') | Out-Null } } finally { Set-ButtonsEnabled $true }
}
$form = New-Object System.Windows.Forms.Form
$script:JbbMainForm = $form
$form.Text = 'JBBToken Codex 一键启动器'
$form.StartPosition = 'CenterScreen'; $form.FormBorderStyle = 'FixedSingle'; $form.MaximizeBox = $false; $form.ClientSize = New-Object System.Drawing.Size(1180,740); $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI',9); $form.BackColor = [System.Drawing.Color]::FromArgb(247,250,255); $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi; $form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96,96)
$activityCard = New-JbbCard -X 36 -Y 682 -W 1108 -H 42 -Radius 12
$activityCard.BackColor = [System.Drawing.Color]::FromArgb(255,255,255)
$activityCard.Visible = $false
$progressBar = New-Object JbbProgressBar; $progressBar.Location = New-Object System.Drawing.Point(18,17); $progressBar.Size = New-Object System.Drawing.Size(220,8); $progressBar.Value = 0
$percentLabel = New-JbbLabel -Text '0%' -X 248 -Y 8 -W 56 -H 26 -Size 9 -Color ([System.Drawing.Color]::FromArgb(20,99,255)) -Align 'MiddleLeft'
$statusLabel = New-JbbLabel -Text '准备就绪。' -X 308 -Y 8 -W 770 -H 26 -Size 9 -Color ([System.Drawing.Color]::FromArgb(71,85,105)) -Align 'MiddleLeft'
$activityCard.Controls.AddRange(@($progressBar,$percentLabel,$statusLabel))
$logBox = New-Object System.Windows.Forms.TextBox; $logBox.Location = New-Object System.Drawing.Point(36,740); $logBox.Size = New-Object System.Drawing.Size(1108,42); $logBox.Multiline = $true; $logBox.ReadOnly = $true; $logBox.ScrollBars = 'Vertical'; $logBox.BackColor = [System.Drawing.Color]::FromArgb(248,250,252); $logBox.BorderStyle = 'FixedSingle'; $logBox.Visible = $false

$loginPagePanel = New-Object JbbBackdropPanel; $loginPagePanel.Location = New-Object System.Drawing.Point(0,0); $loginPagePanel.Size = New-Object System.Drawing.Size(1180,740)
$loginHeaderLogo = New-JbbLogo -X 32 -Y 22 -W 48 -H 48 -Size 14
$loginHeaderTitle = New-JbbLabel -Text 'JBBToken Codex 一键启动器' -X 94 -Y 27 -W 420 -H 34 -Size 14 -Bold $true -Color ([System.Drawing.Color]::FromArgb(15,23,42)) -Align 'MiddleLeft'
$loginHero = New-JbbCard -X 286 -Y 104 -W 608 -H 500 -Radius 20
$loginLogo = New-JbbLabel -Text 'JBB' -X 178 -Y 52 -W 252 -H 92 -Size 44 -Bold $true -Color ([System.Drawing.Color]::FromArgb(20,99,255)) -Align 'MiddleCenter'
$loginTitle = New-JbbLabel -Text '登录 JBBToken' -X 84 -Y 162 -W 440 -H 54 -Size 27 -Bold $true -Color ([System.Drawing.Color]::FromArgb(15,23,42)) -Align 'MiddleCenter'
$loginSubtitle = New-JbbLabel -Text '登录后自动完成 Codex 配置，无需手动复制 API Key' -X 76 -Y 224 -W 456 -H 30 -Size 11 -Color ([System.Drawing.Color]::FromArgb(100,116,139)) -Align 'MiddleCenter'
$loginMainButton = New-JbbButton -Text '登录 / 注册' -X 76 -Y 286 -W 456 -H 62 -Kind 'Primary' -Size 18
$loginHint = New-JbbLabel -Text '新用户会自动进入注册流程' -X 98 -Y 366 -W 412 -H 28 -Size 10 -Color ([System.Drawing.Color]::FromArgb(100,116,139)) -Align 'MiddleCenter'
$loginNetworkButton = New-JbbButton -Text '网络自检' -X 222 -Y 416 -W 164 -H 40 -Kind 'Secondary' -Size 10
$loginHero.Controls.AddRange(@($loginLogo,$loginTitle,$loginSubtitle,$loginMainButton,$loginHint,$loginNetworkButton))
$loginIllustration = New-Object JbbRocketPanel; $loginIllustration.Location = New-Object System.Drawing.Point(914,250); $loginIllustration.Size = New-Object System.Drawing.Size(220,300)
$loginPagePanel.Controls.AddRange(@($loginHeaderLogo,$loginHeaderTitle,$loginHero,$loginIllustration))

$dashboardPagePanel = New-Object JbbBackdropPanel; $dashboardPagePanel.Location = New-Object System.Drawing.Point(0,0); $dashboardPagePanel.Size = New-Object System.Drawing.Size(1180,740); $dashboardPagePanel.Visible = $false
$dashLogo = New-JbbLogo -X 36 -Y 24 -W 58 -H 58 -Size 17
$dashTitle = New-JbbLabel -Text 'JBBToken Codex 一键启动器' -X 116 -Y 30 -W 560 -H 46 -Size 23 -Bold $true -Color ([System.Drawing.Color]::FromArgb(15,23,42)) -Align 'MiddleLeft'
$accountPill = New-JbbCard -X 792 -Y 28 -W 352 -H 54 -Radius 14; $dashboardUserLabel = New-JbbLabel -Text '已登录：-' -X 20 -Y 13 -W 228 -H 28 -Size 10 -Color ([System.Drawing.Color]::FromArgb(15,23,42)) -Align 'MiddleLeft'; $dashboardSwitchButton = New-JbbButton -Text '切换账号' -X 252 -Y 10 -W 86 -H 34 -Kind 'Secondary' -Size 9; $accountPill.Controls.AddRange(@($dashboardUserLabel,$dashboardSwitchButton))

$mainCard = New-JbbCard -X 36 -Y 108 -W 610 -H 400 -Radius 18
$rocketLabel = New-Object JbbRocketPanel; $rocketLabel.Location = New-Object System.Drawing.Point(24,46); $rocketLabel.Size = New-Object System.Drawing.Size(224,246)
$mainReadyTitle = New-JbbLabel -Text '一切就绪，开始使用 Codex' -X 266 -Y 52 -W 322 -H 44 -Size 17 -Bold $true -Color ([System.Drawing.Color]::FromArgb(15,23,42)) -Align 'MiddleLeft'
$mainReadySub = New-JbbLabel -Text '已连接 JBBToken 网关，API Key 已自动配置。' -X 268 -Y 104 -W 310 -H 46 -Size 10 -Color ([System.Drawing.Color]::FromArgb(100,116,139))
$dashboardLaunchButton = New-JbbGooeyButton -Text '启动 Codex' -X 266 -Y 160 -W 312 -H 62 -Size 18
$dashboardReconfigureButton = New-JbbButton -Text '重新配置' -X 266 -Y 240 -W 148 -H 44 -Kind 'Secondary' -Size 10
$dashboardFolderButton = New-JbbButton -Text '打开项目文件夹' -X 430 -Y 240 -W 148 -H 44 -Kind 'Secondary' -Size 10
    $mainDivider = New-JbbDivider -X 32 -Y 310 -W 546
    $statusDividerA = New-Object System.Windows.Forms.Panel; $statusDividerA.Location = New-Object System.Drawing.Point(208,326); $statusDividerA.Size = New-Object System.Drawing.Size(1,44); $statusDividerA.BackColor = [System.Drawing.Color]::FromArgb(226,232,240)
    $statusDividerB = New-Object System.Windows.Forms.Panel; $statusDividerB.Location = New-Object System.Drawing.Point(392,326); $statusDividerB.Size = New-Object System.Drawing.Size(1,44); $statusDividerB.BackColor = [System.Drawing.Color]::FromArgb(226,232,240)
    $codexStateLabel = New-JbbLabel -Text '●  Codex 状态检测中' -X 34 -Y 332 -W 166 -H 34 -Size 10 -Color ([System.Drawing.Color]::FromArgb(22,163,74)) -Align 'MiddleCenter'; $authStateLabel = New-JbbLabel -Text '●  API Key 检测中' -X 218 -Y 332 -W 166 -H 34 -Size 10 -Color ([System.Drawing.Color]::FromArgb(22,163,74)) -Align 'MiddleCenter'; $gatewayStatusLabel = New-JbbLabel -Text '●  网关检测中' -X 402 -Y 332 -W 166 -H 34 -Size 10 -Color ([System.Drawing.Color]::FromArgb(22,163,74)) -Align 'MiddleCenter'
    $mainCard.Controls.AddRange(@($rocketLabel,$mainReadyTitle,$mainReadySub,$dashboardLaunchButton,$dashboardReconfigureButton,$dashboardFolderButton,$mainDivider,$statusDividerA,$statusDividerB,$codexStateLabel,$authStateLabel,$gatewayStatusLabel))

$balanceCard = New-JbbCard -X 670 -Y 108 -W 474 -H 190 -Radius 18
$balanceTitle = New-JbbLabel -Text '账户余额' -X 28 -Y 24 -W 160 -H 32 -Size 14 -Bold $true -Color ([System.Drawing.Color]::FromArgb(15,23,42)); $balanceAmountLabel = New-JbbLabel -Text '-' -X 28 -Y 66 -W 238 -H 60 -Size 29 -Bold $true -Color ([System.Drawing.Color]::FromArgb(22,163,74)) -Align 'MiddleLeft'; $balanceHintLabel = New-JbbLabel -Text '正在读取余额' -X 260 -Y 86 -W 90 -H 28 -Size 10 -Color ([System.Drawing.Color]::FromArgb(71,85,105)) -Align 'MiddleLeft'; $dashboardRechargeButton = New-JbbButton -Text '充值中心' -X 348 -Y 70 -W 100 -H 48 -Kind 'Secondary' -Size 10; $balanceDivider = New-JbbDivider -X 28 -Y 136 -W 420; $dashboardRefreshButton = New-JbbButton -Text '刷新余额' -X 28 -Y 146 -W 104 -H 34 -Kind 'Secondary' -Size 9; $balanceCard.Controls.AddRange(@($balanceTitle,$balanceAmountLabel,$balanceHintLabel,$dashboardRechargeButton,$balanceDivider,$dashboardRefreshButton))

$statusCard = New-JbbCard -X 670 -Y 318 -W 474 -H 190 -Radius 18
$statusTitle2 = New-JbbLabel -Text '运行状态' -X 28 -Y 20 -W 160 -H 32 -Size 14 -Bold $true -Color ([System.Drawing.Color]::FromArgb(15,23,42)); $statusRing = New-Object JbbRingPanel; $statusRing.Location = New-Object System.Drawing.Point(24,48); $statusRing.Size = New-Object System.Drawing.Size(146,132)
$statusRowDivider1 = New-JbbDivider -X 190 -Y 91 -W 252
$statusRowDivider2 = New-JbbDivider -X 190 -Y 129 -W 252
$versionKeyLabel = New-JbbLabel -Text '当前版本' -X 194 -Y 58 -W 88 -H 28 -Size 10 -Color ([System.Drawing.Color]::FromArgb(71,85,105))
$versionValueLabel = New-JbbLabel -Text $script:AppVersion -X 284 -Y 58 -W 158 -H 28 -Size 9 -Color ([System.Drawing.Color]::FromArgb(15,23,42)) -Align 'MiddleRight'
$baseUrlKeyLabel = New-JbbLabel -Text 'Base URL' -X 194 -Y 96 -W 88 -H 28 -Size 10 -Color ([System.Drawing.Color]::FromArgb(71,85,105))
$baseUrlValueLabel = New-Object JbbEllipsisLabel
$baseUrlValueLabel.Text = '-'
$baseUrlValueLabel.Location = New-Object System.Drawing.Point(284,100)
$baseUrlValueLabel.Size = New-Object System.Drawing.Size(158,20)
$baseUrlValueLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI',9)
$baseUrlValueLabel.ForeColor = [System.Drawing.Color]::FromArgb(15,23,42)
$lastCheckKeyLabel = New-JbbLabel -Text '最近检测' -X 194 -Y 134 -W 88 -H 28 -Size 10 -Color ([System.Drawing.Color]::FromArgb(71,85,105))
$lastCheckValueLabel = New-JbbLabel -Text '-' -X 316 -Y 134 -W 102 -H 28 -Size 10 -Color ([System.Drawing.Color]::FromArgb(15,23,42)) -Align 'MiddleRight'
$gatewayDotLabel = New-JbbLabel -Text '●' -X 424 -Y 134 -W 18 -H 28 -Size 11 -Color ([System.Drawing.Color]::FromArgb(22,163,74)) -Align 'MiddleCenter'
$statusCard.Controls.AddRange(@($statusTitle2,$statusRing,$statusRowDivider1,$statusRowDivider2,$versionKeyLabel,$versionValueLabel,$baseUrlKeyLabel,$baseUrlValueLabel,$lastCheckKeyLabel,$lastCheckValueLabel,$gatewayDotLabel))

$apiStateCard = New-JbbCard -X 36 -Y 530 -W 1108 -H 58 -Radius 14; $apiStateTitle = New-JbbLabel -Text '连接信息' -X 22 -Y 15 -W 92 -H 28 -Size 11 -Bold $true -Color ([System.Drawing.Color]::FromArgb(15,23,42)); $apiStateLabel = New-JbbLabel -Text 'API Key 待同步' -X 126 -Y 15 -W 760 -H 28 -Size 10 -Color ([System.Drawing.Color]::FromArgb(71,85,105)); $apiStateLabel.AutoEllipsis = $true; $dashboardApiTestButton = New-JbbButton -Text '测试 API' -X 930 -Y 11 -W 150 -H 36 -Kind 'Secondary' -Size 9; $apiStateCard.Controls.AddRange(@($apiStateTitle,$apiStateLabel,$dashboardApiTestButton))
$helpCard = New-JbbCard -X 36 -Y 604 -W 1108 -H 58 -Radius 14; $helpTitle = New-JbbLabel -Text '遇到问题？' -X 24 -Y 15 -W 100 -H 28 -Size 11 -Bold $true -Color ([System.Drawing.Color]::FromArgb(15,23,42)); $dashboardNetworkButton = New-JbbButton -Text '网络自检' -X 136 -Y 11 -W 112 -H 36 -Kind 'Secondary' -Size 9; $dashboardInstallButton = New-JbbButton -Text '安装/修复 Codex' -X 260 -Y 11 -W 142 -H 36 -Kind 'Secondary' -Size 9; $helpHint = New-JbbLabel -Text '所有配置保存在 JBBToken 独立目录，不影响系统默认 Codex。' -X 430 -Y 15 -W 626 -H 28 -Size 9 -Color ([System.Drawing.Color]::FromArgb(100,116,139)) -Align 'MiddleRight'; $helpCard.Controls.AddRange(@($helpTitle,$dashboardNetworkButton,$dashboardInstallButton,$helpHint))
$dashboardPagePanel.Controls.AddRange(@($dashLogo,$dashTitle,$accountPill,$mainCard,$balanceCard,$statusCard,$apiStateCard,$helpCard))
$form.Controls.AddRange(@($loginPagePanel,$dashboardPagePanel,$activityCard,$logBox))
Initialize-JbbRechargeDrawer -Owner $form
$dashboardToolTip = New-Object System.Windows.Forms.ToolTip
$script:JbbLaunchPending = $false
$loginMainButton.Add_Click({ try { Set-ButtonsEnabled $false; Set-ProgressState -Value 10 -Message '正在打开 JBBToken 登录/注册...'; $auth = Show-JbbNativeAccountDialog -Owner $form; if ($auth) { Set-ProgressState -Value 55 -Message '登录成功，正在同步账户状态...'; Refresh-JbbDashboard } } finally { Set-ButtonsEnabled $true } })
$loginNetworkButton.Add_Click({ Invoke-JbbNetworkSelfTest -Owner $form })
$dashboardNetworkButton.Add_Click({ Invoke-JbbNetworkSelfTest -Owner $form })
$dashboardApiTestButton.Add_Click({ Invoke-JbbApiConnectionTest -Owner $form })
$dashboardRefreshButton.Add_Click({ Refresh-JbbDashboard })
$dashboardSwitchButton.Add_Click({ Clear-JbbDesktopSession; Set-ProgressState -Value 0 -Message '已退出当前账号。'; Set-JbbPage -Page 'Login' })
$dashboardRechargeButton.Add_Click({ Show-JbbNativeRechargeDialog -Owner $form })
$dashboardFolderButton.Add_Click({ $dir = Get-CodexHome; New-Item -ItemType Directory -Path $dir -Force | Out-Null; Start-Process $dir | Out-Null; Set-ProgressState -Value 100 -Message ('已打开工作目录：' + $dir) })
$dashboardReconfigureButton.Add_Click({ Invoke-JbbConfigureCodex -Owner $form -Launch $false })
$dashboardLaunchButton.Add_Click({
    if ($script:JbbLaunchPending) { return }
    $script:JbbLaunchPending = $true
    $dashboardLaunchButton.TriggerBurst()
    $launchDelay = New-Object System.Windows.Forms.Timer
    $launchDelay.Interval = 180
    $launchDelay.Add_Tick({
        $this.Stop()
        $this.Dispose()
        try {
            if ([string]$env:JBB_LAUNCHER_UI_PREVIEW -eq 'Dashboard') {
                Set-ProgressState -Value 100 -Message '启动按钮动效预览完成。'
            }
            else { Invoke-JbbConfigureCodex -Owner $form -Launch $true }
        }
        finally { $script:JbbLaunchPending = $false; $dashboardLaunchButton.Enabled = $true }
    })
    $launchDelay.Start()
})
$dashboardInstallButton.Add_Click({ Set-ButtonsEnabled $false; try { Invoke-JbbOfflineInstallIfNeeded -Force $true } catch { Set-ProgressState -Value 0 -Message ('安装/修复失败：' + $_.Exception.Message); [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, '安装/修复失败', 'OK', 'Error') | Out-Null } finally { Set-ButtonsEnabled $true; Refresh-JbbDashboard -Silent $true } })
$form.Add_Shown({
    Add-CodexPathForCurrentProcess
    $preview = [string]$env:JBB_LAUNCHER_UI_PREVIEW
    if ($preview -eq 'Dashboard' -or $preview -eq 'Recharge') {
        $dashboardUserLabel.Text = '已登录：user@example.com'
        $balanceAmountLabel.Text = '¥ 128.50'; $balanceHintLabel.Text = '额度充足'
        $apiStateLabel.Text = 'API Key 已自动获取：sk-demo...ready'
        $baseUrlValueLabel.Text = 'https://downstream.jbbtoken.cn/v1'; $dashboardToolTip.SetToolTip($baseUrlValueLabel,$baseUrlValueLabel.Text)
        $versionValueLabel.Text = 'codex-cli 0.142.2'; $lastCheckValueLabel.Text = '刚刚'
        $codexStateLabel.Text = '●  Codex 已安装'; $authStateLabel.Text = '●  API Key 已配置'; $gatewayStatusLabel.Text = '●  网关连接正常'
        Set-JbbPage -Page 'Dashboard'; Set-ProgressState -Value 100 -Message 'UI 预览模式。'
        if ($preview -eq 'Recharge') {
            [System.Windows.Forms.Application]::DoEvents()
            Show-JbbNativeRechargeDialog -Owner $form
            [int]$stressCycles = 0
            if ([int]::TryParse([string]$env:JBB_LAUNCHER_UI_STRESS_CYCLES,[ref]$stressCycles) -and $stressCycles -gt 0) { Start-JbbRechargePreviewStress -Cycles $stressCycles }
            if ($env:JBB_LAUNCHER_UI_CAPTURE) {
                $previewCaptureTimer = New-Object System.Windows.Forms.Timer
                $previewCaptureTimer.Interval = 900
                $previewCaptureTimer.Add_Tick({ $this.Stop(); Save-JbbFormCapture -Form $form -Path $env:JBB_LAUNCHER_UI_CAPTURE; $this.Dispose() })
                $script:JbbRechargePreviewCaptureTimer = $previewCaptureTimer
                $previewCaptureTimer.Start()
            }
        }
    }
    elseif (Get-JbbDesktopSession) { Refresh-JbbDashboard -Silent $true }
    else { Set-JbbPage -Page 'Login' }
    if (-not $preview) { Set-ProgressState -Value 0 -Message '启动器已就绪。' }
    if ($env:JBB_LAUNCHER_UI_CAPTURE -and $preview -ne 'Recharge') { Save-JbbFormCapture -Form $form -Path $env:JBB_LAUNCHER_UI_CAPTURE }
})
Apply-JbbPreviewScale -Form $form -BaseWidth 1180 -BaseHeight 740
[System.Windows.Forms.Application]::Run($form)
