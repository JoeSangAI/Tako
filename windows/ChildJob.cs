using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
namespace TakoWindows;
internal sealed class ChildJob : IDisposable {
    nint handle;
    [StructLayout(LayoutKind.Sequential)] struct Basic {public long PerProcess,PerJob;public uint Flags;public nuint Min,Max;public uint Active;public nuint Affinity;public uint Priority,Scheduling;}
    [StructLayout(LayoutKind.Sequential)] struct IO {public ulong ReadOp,WriteOp,OtherOp,Read,Write,Other;}
    [StructLayout(LayoutKind.Sequential)] struct Extended {public Basic Basic;public IO IO;public nuint ProcessMemory,JobMemory,PeakProcess,PeakJob;}
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern nint CreateJobObject(nint attributes,string? name);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(nint job,int kind,ref Extended value,uint size);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool AssignProcessToJobObject(nint job,nint process);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(nint handle);
    internal ChildJob(Process process) {
        handle=CreateJobObject(0,null);var info=new Extended{Basic=new Basic{Flags=0x2000}};
        if(handle==0||!SetInformationJobObject(handle,9,ref info,(uint)Marshal.SizeOf<Extended>())||!AssignProcessToJobObject(handle,process.Handle)) {
            int code=Marshal.GetLastWin32Error();try {process.Kill(true);}catch{} Dispose();throw new Win32Exception(code);
        }
    }
    public void Dispose(){if(handle!=0){CloseHandle(handle);handle=0;}}
}
