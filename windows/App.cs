using System;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace TakoWindows;

internal static class Program {
    [STAThread] static int Main(string[] args) {
        var app=new Application {ShutdownMode=ShutdownMode.OnMainWindowClose};
        try {
            if(args.Length>0&&args[0]=="--self-test") return SelfTest.Run(app,args[1]);
            if(args.Length>0&&args[0]=="--smoke-test") {
                Directory.CreateDirectory(args[1]);int result=1;var window=new CompanionWindow();
                window.Loaded+=async(_,_)=>{try{await window.Inspect(args[1]);result=0;}catch(Exception ex){File.WriteAllText(Path.Combine(args[1],"failure.txt"),ex.ToString());}finally{window.Close();}};
                app.Run(window);return result;
            }
            app.Run(new CompanionWindow()); return 0;
        } catch(Exception ex) {
            if(args.Length>1) File.WriteAllText(args[1]+".error",ex.ToString());
            else MessageBox.Show("Tako 没能启动："+ex.Message,"Tako");
            return 1;
        }
    }
}

internal sealed class CompanionWindow : Window {
    internal readonly TaskCompletionSource Ready=new(TaskCreationOptions.RunContinuationsAsynchronously);
    readonly WebView2 web=new();
    readonly TextBlock status=new() {Text="Tako 正在醒来…",Margin=new Thickness(24),FontSize=16};
    readonly HttpClient http=new() {Timeout=TimeSpan.FromSeconds(30)};
    readonly CancellationTokenSource closing=new();
    readonly Hands hands=new();
    readonly Grid layout=new();
    readonly string root=Environment.GetEnvironmentVariable("TAKO_HOME") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"Tako");
    Process? backend;
    ChildJob? job;
    Uri? address;
    GooWindow? goo;
    nint handle;
    public CompanionWindow() {
        Title="Tako"; Width=450; Height=700; MinWidth=330; MinHeight=400;
        Background=Brushes.White; FontFamily=new FontFamily("Microsoft YaHei UI");
        layout.Children.Add(web); layout.Children.Add(status); Content=layout;
        Loaded+=async (_,_)=>await Start();
        Closing+=(_,_)=>{ closing.Cancel(); goo?.Close(); Desktop.UnregisterHotKey(handle,1); backend?.StandardInput.Close(); job?.Dispose(); web.Dispose(); http.Dispose(); };
        SourceInitialized+=(_,_)=>{
            handle=new WindowInteropHelper(this).Handle;
            var source=HwndSource.FromHwnd(handle); source?.AddHook((nint h,int m,nint w,nint l,ref bool handled)=>{
                if(m==0x312&&w==1) { AttachForeground(); Show(); Activate(); handled=true; } return 0;
            });
            Desktop.RegisterHotKey(handle,1,0x0002|0x0001|0x4000,0x54);
        };
    }
    async Task Start() {
        try {
            Directory.CreateDirectory(root);
            string python=Path.Combine(AppContext.BaseDirectory,"python","python.exe");
            if(!File.Exists(python)) python=Environment.GetEnvironmentVariable("TAKO_PYTHON") ?? "python.exe";
            string script=Path.Combine(AppContext.BaseDirectory,"brain","tako_server.py");
            var start=new ProcessStartInfo(python) {UseShellExecute=false,CreateNoWindow=true,RedirectStandardInput=true,RedirectStandardOutput=true,RedirectStandardError=true,WorkingDirectory=root};
            start.ArgumentList.Add("-X"); start.ArgumentList.Add("utf8"); start.ArgumentList.Add(script); start.ArgumentList.Add("--with-app");
            start.Environment["PYTHONUTF8"]="1"; start.Environment["PYTHONDONTWRITEBYTECODE"]="1";
            backend=Process.Start(start) ?? throw new IOException("无法启动内置处理程序");
            job=new ChildJob(backend);
            _=Task.Run(async ()=>{ using var log=new StreamWriter(Path.Combine(root,"server.err"),false); while(await backend.StandardError.ReadLineAsync() is string line) await log.WriteLineAsync(line); });
            string? ready=await backend.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(30));
            if(!Uri.TryCreate(ready,UriKind.Absolute,out address)||address.Host!="127.0.0.1") throw new IOException("处理程序未就绪，请查看应用数据目录的 server.err");
            var environment=await CoreWebView2Environment.CreateAsync(null,Path.Combine(root,"WebView2"));
            await web.EnsureCoreWebView2Async(environment);
            web.CoreWebView2.Settings.AreDevToolsEnabled=false;
            web.CoreWebView2.Settings.AreDefaultContextMenusEnabled=false;
            web.CoreWebView2.WebMessageReceived+=async (_,e)=>{
                if(!Uri.TryCreate(e.Source,UriKind.Absolute,out var origin)||origin.GetLeftPart(UriPartial.Authority)!=address.GetLeftPart(UriPartial.Authority)) return;
                try { await Message(JsonNode.Parse(e.WebMessageAsJson) as JsonObject ?? new()); } catch(Exception ex) { status.Text="没有完成："+ex.Message; status.Visibility=Visibility.Visible; }
            };
            web.CoreWebView2.NavigationStarting+=(_,e)=>{ if(!Uri.TryCreate(e.Uri,UriKind.Absolute,out var target)||target.GetLeftPart(UriPartial.Authority)!=address.GetLeftPart(UriPartial.Authority)) e.Cancel=true; };
            web.CoreWebView2.NewWindowRequested+=(_,e)=>e.Handled=true;
            web.CoreWebView2.NavigationCompleted+=async (_,e)=>{
                if(!e.IsSuccess) {status.Text="面板没有打开，请重新启动 Tako。";return;}
                status.Visibility=Visibility.Collapsed;
                await web.ExecuteScriptAsync("window.setOpen?.(true); window.setWidth?.(420);");
                Ready.TrySetResult();
            };
            web.Source=address;
            goo=new GooWindow(this,hands); goo.Show();
            AttachForeground();
            _=Poll();
        } catch(Exception ex) { status.Text="Tako 没能启动："+ex.Message; Ready.TrySetException(ex); }
    }
    Uri Endpoint(string path) => new UriBuilder(address!) {Path=path}.Uri;
    internal async Task Attach(DesktopWindow window) {
        hands.Attached=window.Handle;
        if(address!=null) await http.PostAsJsonAsync(Endpoint("/stuck"),new{app=window.App,bundle=window.Bundle,title=window.Title,id=window.Id},closing.Token);
        goo?.Follow();
    }
    void AttachForeground() {
        var foreground=Desktop.GetForegroundWindow();
        var windows=Desktop.Windows();
        var target=windows.Find(w=>w.Handle==foreground) ?? windows.Find(w=>w.Handle==hands.Attached) ?? windows.Find(w=>w.App!="explorer");
        if(target!=null) _=Attach(target);
    }
    async Task Poll() {
        while(!closing.IsCancellationRequested) {
            try {
                var command=await http.GetFromJsonAsync<JsonObject>(Endpoint("/native/next"),closing.Token);
                if(command?["id"]==null) continue;
                // UI Automation runs away from WPF's UI thread. It never injects global input.
                using var action=CancellationTokenSource.CreateLinkedTokenSource(closing.Token);
                action.CancelAfter(TimeSpan.FromSeconds(15));
                object result;
                try { result=await Task.Run(()=>hands.Run(command,action.Token),action.Token).WaitAsync(action.Token); }
                catch(OperationCanceledException) when(!closing.IsCancellationRequested) { result=new {ok=false,error="窗口响应超时，未开始的操作已取消。"}; }
                await http.PostAsJsonAsync(Endpoint("/native/result"),new{id=command["id"]!.ToString(),result},closing.Token);
            } catch(OperationCanceledException) {break;}
              catch(Exception ex) { if(!closing.IsCancellationRequested) {status.Text="窗口服务暂时没有响应："+ex.GetType().Name;status.Visibility=Visibility.Visible;await Task.Delay(1000);} }
        }
    }
    internal void TogglePanel() { if(IsVisible) Hide(); else {Show();Activate();} }
    internal void FollowSide(Desktop.RECT rect) {
        var transform=PresentationSource.FromVisual(this)?.CompositionTarget?.TransformFromDevice??Matrix.Identity;
        var right=transform.Transform(new Point(rect.Right,rect.Top));
        var left=transform.Transform(new Point(rect.Left,rect.Top));
        var area=System.Windows.Forms.Screen.FromHandle(hands.Attached).WorkingArea;
        var low=transform.Transform(new Point(area.Left,area.Top));var high=transform.Transform(new Point(area.Right,area.Bottom));
        double x=right.X+6;if(x+Width>high.X)x=left.X-Width-6;
        Left=Math.Max(low.X,Math.Min(x,high.X-Width));Top=Math.Max(low.Y,Math.Min(right.Y,high.Y-Height));
    }
    async Task Message(JsonObject message) {
        string Read(string key)=>message[key]?.ToString()??"";
        if(message["open"] is JsonValue open && open.TryGetValue<bool>(out var show) && !show) Hide();
        if(message["needsSetup"]!=null) {Show();Activate();}
        if(message["copy"]!=null) Clipboard.SetText(Read("copy")); // Explicit owner button only.
        if(message["openURL"]!=null && Uri.TryCreate(Read("openURL"),UriKind.Absolute,out var url)&&url.Scheme is "https" or "http") Process.Start(new ProcessStartInfo(url.AbsoluteUri){UseShellExecute=true});
        if(message["openFile"]!=null && (File.Exists(Read("openFile"))||Directory.Exists(Read("openFile")))) Process.Start(new ProcessStartInfo(Read("openFile")){UseShellExecute=true});
        if(message["revealFile"]!=null && File.Exists(Read("revealFile"))) Process.Start(new ProcessStartInfo("explorer.exe", "/select,\""+Read("revealFile")+"\""){UseShellExecute=true});
        if(message["goTo"]!=null && hands.Resolve(Read("goTo")) is DesktopWindow target) {Desktop.SetForegroundWindow(target.Handle);await Attach(target);}
        if(message["pickFiles"]!=null) {
            var dialog=new Microsoft.Win32.OpenFileDialog{Multiselect=true};
            if(dialog.ShowDialog(this)==true) await web.ExecuteScriptAsync("window.addFiles?.("+JsonSerializer.Serialize(dialog.FileNames)+");");
        }
        if(message["chooseFolder"]!=null) {
            var dialog=new Microsoft.Win32.OpenFolderDialog();
            if(dialog.ShowDialog(this)==true) await http.PostAsJsonAsync(Endpoint("/folder"),new {path=dialog.FolderName,move=true});
        }
    }
    internal async Task Inspect(string output) {
        await Ready.Task.WaitAsync(TimeSpan.FromSeconds(40));
        var setup=await http.GetFromJsonAsync<JsonObject>(Endpoint("/setup"));
        await Task.Delay(500); // Let the initial HTML layout finish before capturing it.
        using var denied=await http.GetAsync(new UriBuilder(address!){Path="/state",Query=""}.Uri);
        using(var file=File.Create(Path.Combine(output,"panel.png")))await web.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png,file);
        File.WriteAllText(Path.Combine(output,"startup.json"),JsonSerializer.Serialize(new{passed=denied.StatusCode==System.Net.HttpStatusCode.Forbidden,setup,unauthenticated=(int)denied.StatusCode,cloud=false,backend=backend!.Id}));
    }
}

internal sealed class GooWindow : Window {
    readonly CompanionWindow panel; readonly Hands hands; readonly Goo drawing=new(); readonly DispatcherTimer timer;
    bool dragging; Point start;
    internal GooWindow(CompanionWindow panel,Hands hands) {
        this.panel=panel;this.hands=hands;
        Width=90;Height=95;WindowStyle=WindowStyle.None;AllowsTransparency=true;Background=Brushes.Transparent;
        ShowInTaskbar=false;Topmost=true;ShowActivated=false;Content=drawing;
        Left=SystemParameters.WorkArea.Right-110;Top=SystemParameters.WorkArea.Bottom-130;
        MouseLeftButtonDown+=(_,e)=>{start=e.GetPosition(this);dragging=false;CaptureMouse();};
        MouseMove+=(_,e)=>{if(e.LeftButton!=MouseButtonState.Pressed||!IsMouseCaptured)return;var point=e.GetPosition(this);if((point-start).Length>4)dragging=true;if(dragging){Left+=point.X-start.X;Top+=point.Y-start.Y;}};
        MouseLeftButtonUp+=async (_,e)=>{
            ReleaseMouseCapture(); if(!dragging){panel.TogglePanel();return;}
            var center=PointToScreen(new Point(Width/2,Height/2));
            var target=Desktop.Windows().Find(w=>w.Bounds.Contains(center));
            if(target!=null) await panel.Attach(target);
            dragging=false;
        };
        ContextMenu=new ContextMenu();var quit=new MenuItem{Header="退出 Tako"};quit.Click+=(_,_)=>panel.Close();ContextMenu.Items.Add(quit);
        timer=new DispatcherTimer{Interval=TimeSpan.FromMilliseconds(50)};timer.Tick+=(_,_)=>{Follow();drawing.InvalidateVisual();};timer.Start();Closed+=(_,_)=>timer.Stop();
    }
    internal void Follow() {
        if(dragging||IsMouseCaptured||hands.Attached==0)return;
        if(Desktop.IsIconic(hands.Attached)||!Desktop.IsWindow(hands.Attached)){Opacity=.5;return;}
        Opacity=1;
        if(Desktop.GetWindowRect(hands.Attached,out var r)) {
            panel.FollowSide(r);
            var source=PresentationSource.FromVisual(this);var transform=source?.CompositionTarget?.TransformFromDevice??Matrix.Identity;
            var point=transform.Transform(new Point(r.Right-35,r.Top+35));Left=point.X;Top=point.Y;
        }
    }
}
internal sealed class Goo : FrameworkElement {
    protected override void OnRender(DrawingContext dc) {
        double phase=Environment.TickCount64/650.0, bob=Math.Sin(phase)*2;
        var shape=new StreamGeometry();using(var g=shape.Open()) {
            g.BeginFigure(new Point(14,53+bob),true,true);
            g.BezierTo(new Point(8,8),new Point(76,4),new Point(77,49+bob),true,false);
            for(int i=0;i<4;i++){double x=76-i*16;g.BezierTo(new Point(x+4,82+Math.Sin(phase+i)*5),new Point(x-12,87),new Point(x-13,60+bob),true,false);}
        }
        dc.DrawGeometry(new SolidColorBrush(Color.FromRgb(24,24,28)),null,shape);
        dc.DrawEllipse(Brushes.White,null,new Point(35,36+bob),8,10);dc.DrawEllipse(Brushes.White,null,new Point(58,36+bob),8,10);
        dc.DrawEllipse(Brushes.Black,null,new Point(38,38+bob),3,5);dc.DrawEllipse(Brushes.Black,null,new Point(61,38+bob),3,5);
    }
}
