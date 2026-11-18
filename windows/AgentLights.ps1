# Agent Lights pill: always-on-top status dots for your AI agents - one dot per agent session running in a
# terminal tab (Claude Code, Codex, Cursor, Grok, Hermes, ...), so two Claude tabs = two Claude dots. The agent
# machine picks each agent's tag: its first letter, or two letters when two agents share one (Cl, Cx).
# Left-click = bring up your terminal window (a normal local Windows Terminal with tabs) / click again
# to tuck it away. Drag = move. Hover = which dot is what.
# Right-click = one row per dot: Open (attach it in a new tab; a plain-tab session is moved here and
# resumed) or Close (end that agent), "Close all with no window", and "Reopen a closed session" (starts
# the agent again with its resume command). A hollow ring = it runs in tmux with no window showing it.
# Needs nothing beyond Windows PowerShell 5.1 and Windows Terminal (both built into Windows 11).
# Settings: %APPDATA%\AgentLights\config.json (written by install.ps1); a parameter passed here wins.
param(
    [string]$Server      = "",   # host[:port] or full status URL; several = comma-separated, tried in order
    [string]$Token       = "",   # from ~/.config/agent-lights/token on the agent machine
    [string]$SshHost     = "",   # what you type after `ssh` to reach the agent machine
    [string]$OpenCmd     = "",   # on the agent machine: attach / resume (default ~/.local/bin/agent-lights-open)
    [string]$TermProfile = ""    # empty = your Windows Terminal default profile
)
$cfgFile = Join-Path $env:APPDATA "AgentLights\config.json"
if (Test-Path $cfgFile) {
    try {
        $cfg = Get-Content -Raw $cfgFile | ConvertFrom-Json
        if (-not $Server      -and $cfg.server)      { $Server      = [string]$cfg.server }
        if (-not $Token       -and $cfg.token)       { $Token       = [string]$cfg.token }
        if (-not $SshHost     -and $cfg.sshHost)     { $SshHost     = [string]$cfg.sshHost }
        if (-not $OpenCmd     -and $cfg.openCmd)     { $OpenCmd     = [string]$cfg.openCmd }
        if (-not $TermProfile -and $cfg.termProfile) { $TermProfile = [string]$cfg.termProfile }
    } catch { }
}
if (-not $OpenCmd) { $OpenCmd = "~/.local/bin/agent-lights-open" }
$urls = @()
foreach ($s in ($Server -split ",")) {
    $s = $s.Trim()
    if (-not $s) { continue }
    if ($s -notmatch "^https?://") { if ($s -notmatch ":\d+$") { $s += ":8777" }; $s = "http://$s/status" }
    $urls += $s
}
$StatusUrls = $urls -join ","

Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing, System.Core -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

public class DotRow {
    public string Letter = "", Color = "off", Id = "", Label = "", Text = "", Target = "";
    public bool Window = true;     // false = runs in tmux with nobody attached (no window shows it)
}

public class AgentLightsPill : Form {
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern void SwitchToThisWindow(IntPtr h, bool altTab);
    delegate bool EnumProc(IntPtr h, IntPtr p);
    const string WtClass = "CASCADIA_HOSTING_WINDOW_CLASS";
    const string WinName = "AgentLights";   // our own named Windows Terminal window

    string[] urls; string token, profile, posFile, sshHost, openCmd, appDir;
    volatile bool reachable;
    volatile string dotstr = "?:off";   // "tag:color,..." for every dot; also the pill's shape while offline
    volatile DotRow[] rows = null;   // per-dot detail from the agent machine (null = older server: dotstr only)
    volatile string[][] closedRows = new string[0][];   // recently ended: {tag, id, text}
    volatile string tip = "connecting to your agent machine...";
    bool pulse;
    Point downAt; Point formAt; bool dragging; bool mouseDown;
    ToolTip tt = new ToolTip();
    System.Windows.Forms.Timer uiTimer = new System.Windows.Forms.Timer();
    System.Windows.Forms.Timer adoptTimer = new System.Windows.Forms.Timer();
    static Font labelFont = new Font("Segoe UI", 8f, FontStyle.Bold);
    IntPtr term = IntPtr.Zero;               // the terminal window this pill shows / hides
    HashSet<IntPtr> before = new HashSet<IntPtr>();
    int adoptTicks;

    const int Dot = 12, DotGap = 4, LabelW = 12, GroupGap = 10, Pad = 10;

    // room for an agent's tag ("C", "Cx", ...) before its dots
    static int TagW(string tag) {
        if (tag.Length <= 1) return LabelW;
        return Math.Max(LabelW, TextRenderer.MeasureText(tag, labelFont, Size.Empty, TextFormatFlags.NoPadding).Width + 4);
    }

    public AgentLightsPill(string urlList, string token, string profile, string sshHost, string openCmd) {
        this.urls = urlList.Split(new char[] { ',' }, StringSplitOptions.RemoveEmptyEntries);
        this.token = token;
        this.profile = profile;
        this.sshHost = sshHost;
        this.openCmd = openCmd;
        appDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "AgentLights");
        Directory.CreateDirectory(appDir);
        posFile = Path.Combine(appDir, "pos.txt");

        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        Size = new Size(WidthFor(FromDotstr(dotstr)), 26);
        BackColor = Color.Magenta;
        TransparencyKey = Color.Magenta;
        DoubleBuffered = true;
        Location = LoadPos();
        tt.InitialDelay = 200;

        ContextMenu cm = new ContextMenu();
        cm.Popup += delegate { BuildMenu(cm); };
        ContextMenu = cm;

        uiTimer.Interval = 500;
        uiTimer.Tick += delegate {
            pulse = !pulse;
            tt.SetToolTip(this, tip + (reachable && rows != null ? "\n\nRight-click: open or close a dot" : ""));
            int w = WidthFor(Current());
            if (w != Width) {
                // grow toward the screen's middle so a pill parked at the right edge stays on screen
                Rectangle sb = Screen.FromControl(this).Bounds;
                int x = Left + Width / 2 > sb.Left + sb.Width / 2 ? Right - w : Left;
                SetBounds(x, Top, w, Height);
            }
            Invalidate();
        };
        uiTimer.Start();

        adoptTimer.Interval = 200;
        adoptTimer.Tick += delegate { AdoptNewWindow(); };

        Thread t = new Thread(PollLoop); t.IsBackground = true; t.Start();
    }

    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x00000080 | 0x08000000 | 0x00000008; // TOOLWINDOW | NOACTIVATE | TOPMOST
            return cp;
        }
    }

    // ---------- layout ----------
    static DotRow[] FromDotstr(string ds) {
        // "C:green,C:yellow,G:off,H:red" (older servers send only this)
        List<DotRow> l = new List<DotRow>();
        foreach (string part in ds.Split(',')) {
            string[] kv = part.Split(':');
            if (kv.Length != 2) continue;
            DotRow r = new DotRow(); r.Letter = kv[0]; r.Color = kv[1]; r.Label = kv[0];
            l.Add(r);
        }
        return l.ToArray();
    }
    static DotRow[] ParseRows(string s) {
        // one line per dot: letter TAB color TAB window(1/0) TAB id TAB label TAB text TAB tmux-target
        List<DotRow> l = new List<DotRow>();
        foreach (string line in s.Split('\n')) {
            string[] f = line.Split('\t');
            if (f.Length < 7) continue;
            DotRow r = new DotRow();
            r.Letter = f[0]; r.Color = f[1]; r.Window = f[2] != "0"; r.Id = f[3]; r.Label = f[4]; r.Text = f[5]; r.Target = f[6];
            l.Add(r);
        }
        return l.ToArray();
    }
    static string[][] ParseClosed(string s) {
        List<string[]> l = new List<string[]>();
        foreach (string line in s.Split('\n')) {
            string[] f = line.Split('\t');
            if (f.Length >= 3 && f[1].Length > 0) l.Add(f);
        }
        return l.ToArray();
    }
    static string Offline(string ds) {
        // can't reach the agent machine: one grey ring per agent we last saw
        List<string> tags = new List<string>();
        foreach (string part in ds.Split(',')) {
            string[] kv = part.Split(':');
            if (kv.Length == 2 && (tags.Count == 0 || tags[tags.Count - 1] != kv[0] + ":off")) tags.Add(kv[0] + ":off");
        }
        return tags.Count > 0 ? string.Join(",", tags.ToArray()) : "?:off";
    }
    DotRow[] Current() {
        if (!reachable) return FromDotstr(Offline(dotstr));
        DotRow[] r = rows;
        return r != null ? r : FromDotstr(dotstr);
    }
    static List<List<DotRow>> Groups(DotRow[] all) {
        // consecutive dots with the same tag = one group (Claude's dots, then Codex's, ...)
        List<List<DotRow>> groups = new List<List<DotRow>>();
        List<DotRow> cur = null;
        foreach (DotRow r in all) {
            if (cur == null || cur[0].Letter != r.Letter) { cur = new List<DotRow>(); groups.Add(cur); }
            cur.Add(r);
        }
        return groups;
    }
    static int WidthFor(DotRow[] all) {
        List<List<DotRow>> g = Groups(all);
        int w = 2 * Pad;
        for (int i = 0; i < g.Count; i++) {
            int n = g[i].Count;
            w += TagW(g[i][0].Letter) + n * Dot + (n - 1) * DotGap;
            if (i > 0) w += GroupGap;
        }
        return Math.Max(w, 60);
    }

    Point DefaultPos() {
        Rectangle wa = Screen.PrimaryScreen.WorkingArea;
        return new Point(wa.Right - Width - 24, wa.Top + 8);
    }
    Point LoadPos() {
        try {
            string[] p = File.ReadAllText(posFile).Split(',');
            Point pt = new Point(int.Parse(p[0]), int.Parse(p[1]));
            foreach (Screen s in Screen.AllScreens) if (s.Bounds.Contains(pt)) return pt;
        } catch { }
        return DefaultPos();
    }
    void SavePos() { try { File.WriteAllText(posFile, Location.X + "," + Location.Y); } catch { } }

    // ---------- polling ----------
    string Fetch(out string err) {
        err = urls.Length == 0 ? "not set up yet. Run windows\\install.ps1 -Server ... -Token ... (the Linux installer prints the line)" : "";
        foreach (string u in urls) {
            try {
                HttpWebRequest req = (HttpWebRequest)WebRequest.Create(u.Trim());
                req.Timeout = 2000; req.ReadWriteTimeout = 2000; req.Proxy = null;
                req.Headers["X-Agent-Lights-Token"] = token;
                using (WebResponse r = req.GetResponse())
                using (StreamReader sr = new StreamReader(r.GetResponseStream())) return sr.ReadToEnd();
            } catch (WebException e) {
                HttpWebResponse hr = e.Response as HttpWebResponse;
                err = hr != null && (int)hr.StatusCode == 403 ? "wrong token (403). Copy it again from ~/.config/agent-lights/token" : e.Message;
            } catch (Exception e) { err = e.Message; }
        }
        return null;
    }

    void PollLoop() {
        while (true) {
            string err;
            string body = Fetch(out err);
            if (body == null) {
                reachable = false;
                tip = "Can't reach your agent machine: " + err;
            } else {
                Match d = Regex.Match(body, "\"dotstr\"\\s*:\\s*\"([^\"]*)\"");
                if (d.Success && d.Groups[1].Value.Length > 0) dotstr = d.Groups[1].Value;
                Match t = Regex.Match(body, "\"tip\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");
                try { tip = t.Success ? Regex.Unescape(t.Groups[1].Value) : ""; } catch { tip = ""; }
                Match rw = Regex.Match(body, "\"rows\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");
                try { rows = rw.Success ? ParseRows(Regex.Unescape(rw.Groups[1].Value)) : null; } catch { rows = null; }
                Match cl = Regex.Match(body, "\"closed\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");
                try { closedRows = cl.Success ? ParseClosed(Regex.Unescape(cl.Groups[1].Value)) : new string[0][]; }
                catch { closedRows = new string[0][]; }
                reachable = true;
            }
            Thread.Sleep(2000);
        }
    }

    // ---------- drawing ----------
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
        using (GraphicsPath gp = Pill(new Rectangle(0, 0, Width - 1, Height - 1), Height / 2))
        using (SolidBrush bg = new SolidBrush(Color.FromArgb(28, 28, 32)))
        using (Pen edge = new Pen(reachable ? Color.FromArgb(90, 90, 100) : Color.FromArgb(160, 60, 60)))
        { g.FillPath(bg, gp); g.DrawPath(edge, gp); }

        List<List<DotRow>> groups = Groups(Current());
        int x = Pad, y = (Height - Dot) / 2;
        for (int gi = 0; gi < groups.Count; gi++) {
            if (gi > 0) x += GroupGap;
            using (SolidBrush lb = new SolidBrush(Color.FromArgb(reachable ? 210 : 90, 200, 200, 205)))
                g.DrawString(groups[gi][0].Letter, labelFont, lb, x - 1, (Height - labelFont.Height) / 2 + 1);
            x += TagW(groups[gi][0].Letter);
            for (int i = 0; i < groups[gi].Count; i++) {
                string l = groups[gi][i].Color;
                Color c;
                if (l == "green") c = Color.FromArgb(60, 220, 90);
                else if (l == "yellow") c = Color.FromArgb(250, 200, 40);
                else if (l == "red") c = pulse ? Color.FromArgb(120, 30, 25) : Color.FromArgb(240, 60, 50);
                else c = Color.Empty;
                if (c.IsEmpty) {
                    using (Pen ring = new Pen(Color.FromArgb(85, 85, 92), 1.5f)) g.DrawEllipse(ring, x, y, Dot, Dot);
                } else if (!groups[gi][i].Window) {
                    // running, but no window shows it (tmux with nobody attached): hollow ring in its color
                    using (Pen ring = new Pen(c, 2.5f)) g.DrawEllipse(ring, x + 1, y + 1, Dot - 2, Dot - 2);
                } else {
                    using (SolidBrush b = new SolidBrush(c)) g.FillEllipse(b, x, y, Dot, Dot);
                }
                x += Dot + (i < groups[gi].Count - 1 ? DotGap : 0);
            }
        }
    }

    static GraphicsPath Pill(Rectangle r, int rad) {
        GraphicsPath p = new GraphicsPath(); int dd = rad * 2;
        p.AddArc(r.X, r.Y, dd, dd, 90, 180);
        p.AddArc(r.Right - dd, r.Y, dd, dd, 270, 180);
        p.CloseFigure(); return p;
    }

    // ---------- mouse ----------
    protected override void OnMouseDown(MouseEventArgs e) {
        if (e.Button != MouseButtons.Left) return;
        mouseDown = true; dragging = false; downAt = Cursor.Position; formAt = Location;
    }
    protected override void OnMouseMove(MouseEventArgs e) {
        if (!mouseDown) return;
        Point c = Cursor.Position;
        if (!dragging && (Math.Abs(c.X - downAt.X) > 4 || Math.Abs(c.Y - downAt.Y) > 4)) dragging = true;
        if (dragging) Location = new Point(formAt.X + c.X - downAt.X, formAt.Y + c.Y - downAt.Y);
    }
    protected override void OnMouseUp(MouseEventArgs e) {
        if (e.Button != MouseButtons.Left || !mouseDown) return;
        mouseDown = false;
        if (dragging) SavePos(); else Toggle();
    }

    // ---------- right-click menu ----------
    static string Amp(string s) { return s.Replace("&", "&&"); }

    void BuildMenu(ContextMenu cm) {
        cm.MenuItems.Clear();
        DotRow[] all = reachable ? rows : null;
        List<DotRow> ghosts = new List<DotRow>();
        if (!reachable) {
            MenuItem m = new MenuItem("Can't reach your agent machine"); m.Enabled = false; cm.MenuItems.Add(m);
        } else if (all == null) {
            MenuItem m = new MenuItem("Update the agent machine for open / close"); m.Enabled = false; cm.MenuItems.Add(m);
        } else {
            int n = 0;
            foreach (DotRow row in all) {
                if (row.Id.Length == 0) continue;
                DotRow r = row;
                n++;
                if (!r.Window) ghosts.Add(r);
                MenuItem m = new MenuItem(Amp(r.Label + "   " + r.Text));
                string openText = r.Target.Length == 0 ? "Move it here (stops it in its plain tab, resumes it in a new one)"
                                : r.Window ? "Open here too (new tab)" : "Open in a new tab";
                m.MenuItems.Add(new MenuItem(openText, delegate { OpenSession(r.Id, r.Label + " " + Short(r.Text)); }));
                m.MenuItems.Add(new MenuItem("Close (ends this agent)", delegate { CloseSessions(new DotRow[] { r }); }));
                cm.MenuItems.Add(m);
            }
            if (n == 0) { MenuItem m = new MenuItem("No agent sessions"); m.Enabled = false; cm.MenuItems.Add(m); }
            if (ghosts.Count > 0) {
                DotRow[] g = ghosts.ToArray();
                cm.MenuItems.Add(new MenuItem("-"));
                cm.MenuItems.Add(new MenuItem("Close all with no window (" + g.Length + ")", delegate { CloseSessions(g); }));
            }
            string[][] closed = closedRows;
            if (closed.Length > 0) {
                MenuItem re = new MenuItem("Reopen a closed session");
                foreach (string[] c in closed) {
                    string[] cc = c;
                    re.MenuItems.Add(new MenuItem(Amp(cc[2]), delegate { OpenSession(cc[1], cc[0] + " " + Short(cc[2])); }));
                }
                cm.MenuItems.Add(new MenuItem("-"));
                cm.MenuItems.Add(re);
            }
        }
        cm.MenuItems.Add(new MenuItem("-"));
        cm.MenuItems.Add(new MenuItem("Show / hide terminal", delegate { Toggle(); }));
        cm.MenuItems.Add(new MenuItem("New terminal tab", delegate { NewTab(); }));
        cm.MenuItems.Add(new MenuItem("Reset position", delegate { Location = DefaultPos(); SavePos(); }));
        cm.MenuItems.Add(new MenuItem("-"));
        cm.MenuItems.Add(new MenuItem("Exit overlay", delegate { Application.Exit(); }));
    }

    static string Short(string text) { return text.Split(new string[] { " - " }, StringSplitOptions.None)[0]; }

    void OpenSession(string id, string title) {
        if (sshHost.Length == 0) {
            MessageBox.Show(this, "Set -SshHost first (what you type after ssh to reach the agent machine):\n" +
                "run windows\\install.ps1 again with -SshHost you@host.", "Agent Lights");
            return;
        }
        // a new tab in our terminal window: ssh to the agent machine and run agent-lights-open there, which attaches the
        // session if it lives in tmux, or starts the agent again with its resume command
        if (!Regex.IsMatch(id, "^[A-Za-z0-9_.-]+$") || !Regex.IsMatch(sshHost, "^[A-Za-z0-9_.@-]+$")
            || !Regex.IsMatch(openCmd, "^[A-Za-z0-9_./~-]+$")) {
            MessageBox.Show(this, "Can't open " + title + ": unexpected session id, ssh host or OpenCmd.", "Agent Lights");
            return;
        }
        try {
            string file = Path.Combine(appDir, "open-" + id + ".cmd");
            File.WriteAllText(file,
                "@echo off\r\nssh -t " + sshHost + " " + openCmd + " " + id + "\r\nif errorlevel 1 pause\r\n",
                Encoding.ASCII);
            title = Regex.Replace(title, "[^A-Za-z0-9 _.()-]", "");
            // full path: the new tab does not start in our folder
            string args = " --title \"" + title + "\" --suppressApplicationTitle cmd.exe /c \"" + file + "\"";
            if (term != IntPtr.Zero && IsWindow(term)) {
                Process.Start("wt.exe", "-w " + WinName + " new-tab" + ProfileArg() + args);
                System.Windows.Forms.Timer later = new System.Windows.Forms.Timer();
                later.Interval = 400;
                later.Tick += delegate { later.Stop(); later.Dispose(); if (IsWindow(term)) Bring(term); };
                later.Start();
            } else {
                Launch(args);
            }
        } catch (Exception e) {
            MessageBox.Show(this, "Could not open " + title + ": " + e.Message, "Agent Lights");
        }
    }

    void CloseSessions(DotRow[] list) {
        StringBuilder q = new StringBuilder();
        foreach (DotRow r in list) q.Append("\n   " + r.Label + "   " + r.Text);
        string msg = (list.Length == 1 ? "Close this session?" : "Close these " + list.Length + " sessions?") + "\n" + q +
                     "\n\nThis ends the agent" + (list.Length == 1 ? "" : "s") + "." +
                     "\nThe chat is saved: right-click, Reopen a closed session brings it back.";
        if (MessageBox.Show(this, msg, "Agent Lights", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
        ThreadPool.QueueUserWorkItem(delegate {
            StringBuilder errs = new StringBuilder();
            foreach (DotRow r in list) {
                string err = PostClose(r.Id);
                if (err != null) errs.Append(r.Label + ": " + err + "\n");
            }
            if (errs.Length > 0) {
                string text = errs.ToString();
                BeginInvoke((MethodInvoker)delegate { MessageBox.Show(this, "Could not close:\n" + text, "Agent Lights"); });
            }
        });
    }

    string PostClose(string id) {
        // null = closed; otherwise why not. Tries each address until one answers.
        string last = "no address set up";
        foreach (string u in urls) {
            string cu = u.Trim();
            cu = cu.EndsWith("/status") ? cu.Substring(0, cu.Length - 7) + "/close" : cu.TrimEnd('/') + "/close";
            try {
                HttpWebRequest req = (HttpWebRequest)WebRequest.Create(cu);
                req.Method = "POST"; req.Timeout = 10000; req.ReadWriteTimeout = 10000; req.Proxy = null;
                req.ContentType = "application/x-www-form-urlencoded";
                req.Headers["X-Agent-Lights-Token"] = token;
                byte[] data = Encoding.ASCII.GetBytes("id=" + Uri.EscapeDataString(id));
                req.ContentLength = data.Length;
                using (Stream s = req.GetRequestStream()) s.Write(data, 0, data.Length);
                using (WebResponse r = req.GetResponse()) { }
                return null;
            } catch (WebException e) {
                HttpWebResponse hr = e.Response as HttpWebResponse;
                if (hr != null) {   // the agent machine answered with an error: say it, don't retry elsewhere
                    string body = "";
                    try { using (StreamReader sr = new StreamReader(hr.GetResponseStream())) body = sr.ReadToEnd(); } catch { }
                    Match m = Regex.Match(body, "\"error\"\\s*:\\s*\"([^\"]*)\"");
                    return m.Success ? m.Groups[1].Value : "HTTP " + (int)hr.StatusCode;
                }
                last = e.Message;
            } catch (Exception e) { last = e.Message; }
        }
        return last;
    }

    // ---------- terminal window ----------
    static HashSet<IntPtr> TerminalWindows() {
        HashSet<IntPtr> set = new HashSet<IntPtr>();
        EnumWindows(delegate (IntPtr h, IntPtr p) {
            StringBuilder cls = new StringBuilder(64);
            GetClassName(h, cls, 64);
            if (cls.ToString() == WtClass && IsWindowVisible(h)) set.Add(h);
            return true;
        }, IntPtr.Zero);
        return set;
    }

    void Toggle() {
        try {
            if (term != IntPtr.Zero && IsWindow(term)) {
                if (GetForegroundWindow() == term && !IsIconic(term)) ShowWindow(term, 6);  // SW_MINIMIZE
                else Bring(term);
            } else {
                Launch("");
            }
        } catch (Exception e) {
            MessageBox.Show("Could not open Windows Terminal: " + e.Message, "Agent Lights");
        }
    }

    void NewTab() {
        try {
            if (term != IntPtr.Zero && IsWindow(term)) {
                Process.Start("wt.exe", "-w " + WinName + " new-tab" + ProfileArg());
            } else {
                Launch("");
            }
        } catch (Exception e) {
            MessageBox.Show("Could not open Windows Terminal: " + e.Message, "Agent Lights");
        }
    }

    string ProfileArg() { return profile.Length > 0 ? " -p \"" + profile + "\"" : ""; }

    void Bring(IntPtr h) {
        if (IsIconic(h)) ShowWindow(h, 9);   // SW_RESTORE
        SetForegroundWindow(h);
        if (GetForegroundWindow() != h) SwitchToThisWindow(h, true);
    }

    void Launch(string extra) {
        before = TerminalWindows();
        Process.Start("wt.exe", "-w " + WinName + " new-tab" + ProfileArg() + extra);
        adoptTicks = 0;
        adoptTimer.Start();
    }

    void AdoptNewWindow() {
        // our window = the terminal window that appeared after launch; if none appeared (the named
        // window already existed and just got a new tab), take the terminal window now in front
        adoptTicks++;
        foreach (IntPtr h in TerminalWindows()) {
            if (!before.Contains(h)) { term = h; adoptTimer.Stop(); return; }
        }
        if (adoptTicks >= 15) {
            adoptTimer.Stop();
            IntPtr fg = GetForegroundWindow();
            StringBuilder cls = new StringBuilder(64);
            GetClassName(fg, cls, 64);
            if (cls.ToString() == WtClass) term = fg;
        }
    }
}
'@

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run((New-Object AgentLightsPill($StatusUrls, $Token, $TermProfile, $SshHost, $OpenCmd)))
