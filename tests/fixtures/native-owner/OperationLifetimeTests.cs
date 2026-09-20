using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
public static partial class NativeOwner {
    static PI LifetimeChild(IntPtr job,string marker) {
        PI child=new PI();var startup=new SI { cb=Marshal.SizeOf(typeof(SI)) };
        if(!CreateProcess(OwnExe,new StringBuilder(Quote(OwnExe)+" operation-parent "+Quote(marker)),IntPtr.Zero,IntPtr.Zero,false,0x4|0x400,IntPtr.Zero,Path.GetTempPath(),ref startup,out child)) throw Error("Create lifetime child");
        try {
            if(!AssignProcessToJobObject(job,child.process)) throw Error("Assign lifetime child");
            if(ResumeThread(child.thread)==0xffffffff) throw Error("Resume lifetime child");
            return child;
        } catch { TerminateProcess(child.process,125);CloseHandle(child.thread);CloseHandle(child.process);throw; }
    }
    static int TestOperationLifetime() {
        using(var independent=Process.Start(new ProcessStartInfo(OwnExe,"sleep 15000") { UseShellExecute=false })) {
            try {
                foreach(bool close in new [] {false,true}) {
                    IntPtr job=CreateJobObject(IntPtr.Zero,null);PI child=new PI();Process descendant=null;
                    string marker=Path.Combine(Path.GetTempPath(),"fm-native-operation-worker-"+Guid.NewGuid().ToString("N"));
                    if(job==IntPtr.Zero) throw Error("Create lifetime job");
                    try {
                        NativeOperationLifetime.Configure(job);child=LifetimeChild(job,marker);
                        DateTime limit=DateTime.UtcNow.AddSeconds(3);
                        while(!File.Exists(marker) && DateTime.UtcNow<limit) System.Threading.Thread.Sleep(10);
                        if(!File.Exists(marker)) throw new Exception("Operation descendant did not start");
                        descendant=Process.GetProcessById(int.Parse(File.ReadAllText(marker)));
                        if(WaitForSingleObject(child.process,0)!=WAIT_TIMEOUT) throw new Exception("Operation was not initially live");
                        if(descendant.HasExited) throw new Exception("Operation descendant was not initially live");
                        if(close) { CloseHandle(job);job=IntPtr.Zero; }
                        else NativeOperationLifetime.Stop(job,3000);
                        if(WaitForSingleObject(child.process,3000)!=0) throw new Exception("Fixed operation survived shutdown");
                        if(!descendant.WaitForExit(3000)) throw new Exception("Session-owned deferred worker survived shutdown");
                        if(independent.HasExited) throw new Exception("Independent process was stopped");
                        Console.WriteLine("PASS: operation "+(close ? "last-handle close" : "bounded stop")+" stops its deferred worker and preserves an independent process");
                    } finally {
                        if(descendant!=null) descendant.Dispose();
                        if(child.process!=IntPtr.Zero) {
                            if(WaitForSingleObject(child.process,0)==WAIT_TIMEOUT) {TerminateProcess(child.process,125);WaitForSingleObject(child.process,3000);}
                            CloseHandle(child.thread);CloseHandle(child.process);
                        }
                        if(job!=IntPtr.Zero) CloseHandle(job);
                        if(File.Exists(marker)) File.Delete(marker);
                    }
                }
            } finally { if(!independent.HasExited) independent.Kill();independent.WaitForExit(3000); }
        }
        return 0;
    }
}
