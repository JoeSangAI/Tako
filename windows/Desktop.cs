using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows;
using System.Windows.Automation;

namespace TakoWindows;

internal sealed record DesktopWindow(nint Handle, int Pid, string App, string Title, Rect Bounds) {
    public string Id => Handle.ToInt64().ToString();
    public string Bundle => App.Equals("Weixin", StringComparison.OrdinalIgnoreCase) || App.Equals("WeChat", StringComparison.OrdinalIgnoreCase) ? "com.tencent.xinWeChat" : "windows:" + App;
    public object Describe(nint attached) => new { ok=true, id=Id, app=App, title=Title, bundle=Bundle, stuck=attached==Handle,
        frame=new { x=Bounds.X, y=Bounds.Y, w=Bounds.Width, h=Bounds.Height } };
}

internal static class Desktop {
    internal delegate bool EnumProc(nint window, nint param);
    [StructLayout(LayoutKind.Sequential)] internal struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] internal static extern bool EnumWindows(EnumProc callback, nint param);
    [DllImport("user32.dll")] internal static extern bool IsWindowVisible(nint window);
    [DllImport("user32.dll")] internal static extern bool IsWindow(nint window);
    [DllImport("user32.dll")] internal static extern bool IsIconic(nint window);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] internal static extern int GetWindowText(nint window, StringBuilder text, int count);
    [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(nint window, out int pid);
    [DllImport("user32.dll")] internal static extern bool GetWindowRect(nint window, out RECT rect);
    [DllImport("user32.dll")] internal static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] internal static extern bool SetForegroundWindow(nint window);
    [DllImport("user32.dll")] internal static extern bool RegisterHotKey(nint window, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] internal static extern bool UnregisterHotKey(nint window, int id);
    [DllImport("user32.dll")] internal static extern uint GetWindowLong(nint window, int index);

    internal static List<DesktopWindow> Windows(bool includeSelf=false) {
        var found = new List<DesktopWindow>();
        EnumWindows((h, _) => {
            if (!IsWindowVisible(h) || IsIconic(h)) return true;
            GetWindowThreadProcessId(h, out int pid);
            if (!includeSelf && pid==Environment.ProcessId) return true;
            var title=new StringBuilder(1024); GetWindowText(h,title,title.Capacity);
            if (title.Length==0 || !GetWindowRect(h,out var r) || r.Right-r.Left<80 || r.Bottom-r.Top<60) return true;
            try { found.Add(new(h,pid,Process.GetProcessById(pid).ProcessName,title.ToString(),new Rect(r.Left,r.Top,r.Right-r.Left,r.Bottom-r.Top))); } catch { }
            return true;
        },0);
        return found;
    }
}

internal sealed class Hands {
    internal nint Attached;
    internal bool IncludeSelf;
    // References belong to the exact window and the last explicit look.
    readonly System.Collections.Concurrent.ConcurrentDictionary<nint,List<AutomationElement>> references=new();
    static readonly Regex Sending=new(@"发送|发出|群发|send|reply|转发|forward|寄出", RegexOptions.IgnoreCase);
    static readonly Regex Lasting=new(@"支付|付款|购买|删除|提交|发布|退出登录|卸载|重置|pay|purchase|buy|delete|submit|publish|sign.out|uninstall|reset", RegexOptions.IgnoreCase);
    static readonly Regex SystemTool=new(@"powershell|cmd|terminal|regedit|settings|control|vpn|clash|v2ray|proxy",RegexOptions.IgnoreCase);
    static object Fail(string error) => new {ok=false,error};
    internal static string Text(JsonObject value,string key) => value[key]?.ToString() ?? "";
    internal DesktopWindow? Resolve(string name) {
        var all=Desktop.Windows(IncludeSelf);
        if (string.IsNullOrWhiteSpace(name)) return all.FirstOrDefault(w=>w.Handle==Attached);
        var exact=all.Where(w=>w.Id==name || w.Bundle==name || w.Title==name || w.App.Equals(name,StringComparison.OrdinalIgnoreCase)).ToList();
        if (exact.Count==1) return exact[0];
        var matches=all.Where(w=>w.Title.Contains(name,StringComparison.OrdinalIgnoreCase)||w.App.Contains(name,StringComparison.OrdinalIgnoreCase)).ToList();
        return matches.Count==1 ? matches[0] : null;
    }
    internal object Run(JsonObject request,CancellationToken cancel=default) {
        cancel.ThrowIfCancellationRequested();
        var command=Text(request,"command");
        if(command=="windows") return new {ok=true,windows=Desktop.Windows(IncludeSelf).Select(w=>w.Describe(Attached)).ToArray()};
        if(command is "endSteps" or "followDone" or "listenStop") return new {ok=true};
        var win=Resolve(Text(request,"window"));
        if(win==null) return Fail("没有唯一匹配的窗口，请从窗口列表指定它。");
        try {
            switch(command) {
                case "resolve": case "about": return win.Describe(Attached);
                case "look": return Look(win,cancel);
                case "titles": return new {ok=true,lines=new[]{win.Title},others=Array.Empty<string>()};
                case "isBack": return new {ok=false,front=Desktop.GetForegroundWindow()==win.Handle,app=win.App,input=999};
                case "fill":
                    if(request["files"] is JsonArray files && files.Count>0) return Fail("Windows 版暂未接入文件填入。");
                    return Fill(win,Text(request,"text"),null,cancel);
                case "step": return Step(win,request["step"] as JsonObject ?? new(),request["confirmed"]?.GetValue<bool>()==true,cancel);
                case "bringForward": return Fail("只有你点击面板里的返回窗口按钮，才会切换前台。");
                default: return Fail("Windows 版尚未接入这项操作（"+command+"）。");
            }
        } catch(ElementNotAvailableException) { return Fail("窗口内容刚刚变了，请重新看一次。"); }
          catch(Exception ex) { return Fail("Windows 没有完成这项操作："+ex.GetType().Name); }
    }
    internal object Look(DesktopWindow win,CancellationToken cancel=default) {
        var root=AutomationElement.FromHandle(win.Handle);
        var nodes=new List<AutomationElement>();
        var text=new StringBuilder();
        Walk(root,0);
        cancel.ThrowIfCancellationRequested();
        references[win.Handle]=nodes;
        return new {ok=true,id=win.Id,app=win.App,title=win.Title,bundle=win.Bundle,elements=text.ToString(),
            note="来自 Windows 辅助功能树；未提供截图。编号仅用于本窗口本次读取。"};
        void Walk(AutomationElement node,int depth) {
            cancel.ThrowIfCancellationRequested();
            if(depth>12||nodes.Count>=350||text.Length>14000) return;
            var current=node.Current;
            if(current.IsPassword) return;
            if(current.IsOffscreen) return;
            var name=current.Name;
            if(node.TryGetCurrentPattern(ValuePattern.Pattern,out var value)) name += " "+((ValuePattern)value).Current.Value;
            if(!string.IsNullOrWhiteSpace(name)||current.ControlType==ControlType.Edit) {
                nodes.Add(node); var b=current.BoundingRectangle;
                text.AppendLine($"{nodes.Count} {current.ControlType.ProgrammaticName} {name.Replace('\n',' ')} ({b.X-win.Bounds.X:0},{b.Y-win.Bounds.Y:0},{b.Width:0},{b.Height:0})");
            }
            var walker=TreeWalker.ControlViewWalker;
            for(var child=walker.GetFirstChild(node);child!=null;child=walker.GetNextSibling(child)) Walk(child,depth+1);
        }
    }
    bool Belongs(AutomationElement node,DesktopWindow win) {
        if(node.Current.ProcessId!=win.Pid) return false;
        var root=AutomationElement.FromHandle(win.Handle);
        for(var parent=node;parent!=null;parent=TreeWalker.RawViewWalker.GetParent(parent)) if(Automation.Compare(parent,root)) return true;
        return false;
    }
    internal object Fill(DesktopWindow win,string text,AutomationElement? element,CancellationToken cancel=default) {
        if(element==null) {
            var focused=AutomationElement.FocusedElement;
            if(focused!=null && Belongs(focused,win) && focused.Current.ControlType==ControlType.Edit) element=focused;
            else {
                var edits=AutomationElement.FromHandle(win.Handle).FindAll(TreeScope.Descendants,new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.Edit));
                var candidates=edits.Cast<AutomationElement>().Where(e=>!e.Current.IsPassword&&!e.Current.IsOffscreen&&e.Current.IsEnabled&&e.TryGetCurrentPattern(ValuePattern.Pattern,out var pattern)&&!((ValuePattern)pattern).Current.IsReadOnly).Take(2).ToList();
                if(candidates.Count!=1) return Fail("没有唯一可填的输入框，请先看窗口并指定输入框编号。");
                element=candidates[0];
            }
        }
        if(!Belongs(element,win)||element.Current.IsPassword||!element.Current.IsEnabled) return Fail("不能写入这个字段。");
        if(!element.TryGetCurrentPattern(ValuePattern.Pattern,out var pattern)) return Fail("这个应用不支持后台填字，未使用鼠标或剪贴板。");
        var value=(ValuePattern)pattern;
        if(value.Current.IsReadOnly) return Fail("这个字段只读。");
        cancel.ThrowIfCancellationRequested();
        value.SetValue(text);
        return value.Current.Value==text ? new {ok=true,message="已填入并读回核对，没有发送。"} : Fail("填入后读回不一致，请核对输入框。");
    }
    internal object Step(DesktopWindow win,JsonObject step,bool confirmed,CancellationToken cancel=default) {
        string action=Text(step,"action");
        // No key injection, coordinate clicks or global pointer fallback exists in this host.
        if(action=="key") return Fail("Windows 版不注入按键；发送和回车始终由你操作。");
        if(action=="type" && step["ref"]==null) return Fill(win,Text(step,"text"),null,cancel);
        if(!references.TryGetValue(win.Handle,out var nodes)) return Fail("先看一次这个窗口，再使用元素编号。");
        AutomationElement? element=null;
        if(int.TryParse(Text(step,"ref"),out var index)&&index>0&&index<=nodes.Count) element=nodes[index-1];
        else if(Text(step,"text") is string query && query.Length>0) {
            var match=nodes.Where(e=>e.Current.Name.Equals(query,StringComparison.OrdinalIgnoreCase)).Take(2).ToList();
            if(match.Count==1) element=match[0];
        }
        if(element==null||!Belongs(element,win)) return Fail("元素不明确或已经变化，请重新看窗口。");
        var label=element.Current.Name+" "+element.Current.AutomationId;
        if(element.Current.IsPassword) return Fail("不能操作密码字段。");
        if(Sending.IsMatch(label)) return Fail("发送由你操作，Tako 不能代按。");
        if((Lasting.IsMatch(label)||SystemTool.IsMatch(win.App))&&!confirmed) return new {ok=false,needs="即将操作："+label};
        if(action=="type") return Fill(win,Text(step,"text"),element,cancel);
        cancel.ThrowIfCancellationRequested();
        if(action=="click" && element.TryGetCurrentPattern(InvokePattern.Pattern,out var invoke)) { ((InvokePattern)invoke).Invoke(); return new {ok=true,message="已调用此窗口的按钮。"}; }
        if(action=="choose" && element.TryGetCurrentPattern(SelectionItemPattern.Pattern,out var select)) { ((SelectionItemPattern)select).Select(); return new {ok=true}; }
        return Fail("这个元素不支持所请求的后台操作，未移动鼠标。");
    }
}
