using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
namespace TakoWindows;
internal static class SelfTest {
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool ShowWindow(nint window,int command);
    internal static int Run(Application app,string output) {
        Directory.CreateDirectory(output);
        var field=new TextBox{Text="Tako Windows",Margin=new Thickness(20),MinHeight=40};
        var send=new Button{Content="发送",Margin=new Thickness(20)};
        var password=new PasswordBox{Margin=new Thickness(20)};
        int sends=0;send.Click+=(_,_)=>sends++;
        var content=new StackPanel();content.Children.Add(new TextBlock{Text="Tako · Windows 隔离验收",FontSize=24,Margin=new Thickness(20)});content.Children.Add(field);content.Children.Add(password);content.Children.Add(send);content.Children.Add(new Goo{Width=90,Height=95});
        var window=new Window{Title="Tako Windows Self Test",Width=500,Height=420,Content=content,Background=Brushes.White};
        int result=1;
        window.ContentRendered+=async (_,_)=>{
            try {
                var hands=new Hands{IncludeSelf=true,Attached=new WindowInteropHelper(window).Handle};
                // WSL launches inherit SW_HIDE. Show this isolated test window explicitly.
                ShowWindow(hands.Attached,5);
                string id=hands.Attached.ToInt64().ToString();
                Desktop.GetWindowRect(hands.Attached,out var bounds);
                var title=new System.Text.StringBuilder(1024);int titleLength=Desktop.GetWindowText(hands.Attached,title,1024);
                var raw=new System.Collections.Generic.List<string>();Desktop.EnumWindows((handle,_)=>{raw.Add(handle.ToInt64().ToString());return true;},0);
                File.WriteAllText(Path.Combine(output,"diagnostic.json"),JsonSerializer.Serialize(new{id,visible=Desktop.IsWindowVisible(hands.Attached),iconic=Desktop.IsIconic(hands.Attached),title=title.ToString(),titleLength,bounds=new{bounds.Left,bounds.Top,bounds.Right,bounds.Bottom},raw}));
                var report=await Task.Run(()=>{
                    JsonObject Command(string name,JsonObject? step=null)=>new(){["command"]=name,["window"]=id,["step"]=step};
                    JsonNode Convert(object value)=>JsonSerializer.SerializeToNode(value)!;
                    var look=Convert(hands.Run(Command("look")));
                    var fill=Command("fill");fill["text"]="Tako Windows 后台填入核对";
                    var filled=Convert(hands.Run(fill));
                    var blocked=Convert(hands.Run(Command("step",new(){["action"]="click",["text"]="发送"})));
                    var enter=Convert(hands.Run(Command("step",new(){["action"]="key",["keys"]="return"})));
                    return new {look,filled,blocked,enter,windows=Desktop.Windows(true).Select(w=>w.Describe(hands.Attached)).ToArray()};
                });
                bool passed=report.look["ok"]!.GetValue<bool>()&&report.filled["ok"]!.GetValue<bool>()&&!report.blocked["ok"]!.GetValue<bool>()&&!report.enter["ok"]!.GetValue<bool>()&&sends==0&&field.Text=="Tako Windows 后台填入核对";
                File.WriteAllText(Path.Combine(output,"native.json"),JsonSerializer.Serialize(new{passed,report,sends,field=field.Text},new JsonSerializerOptions{WriteIndented=true}));
                var bitmap=new RenderTargetBitmap((int)window.ActualWidth,(int)window.ActualHeight,96,96,PixelFormats.Pbgra32);bitmap.Render(window);var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));using(var file=File.Create(Path.Combine(output,"native.png")))encoder.Save(file);
                result=passed?0:1;
            }catch(Exception ex){File.WriteAllText(Path.Combine(output,"failure.txt"),ex.ToString());}
            window.Close();
        };
        app.Run(window);return result;
    }
}
