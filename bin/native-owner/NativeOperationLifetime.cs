// Only fixed owner-operation jobs use kill-on-close. Never apply it to the
// encompassing session job or to independently owned worker jobs.
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Threading;
public static class NativeOperationLifetime {
    [StructLayout(LayoutKind.Sequential)] struct Limits {
        public long processTime,jobTime;
        public uint flags;
        public UIntPtr minimum,maximum;
        public uint active;
        public UIntPtr affinity;
        public uint priority,scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] struct Extended {
        public Limits basic;
        public ulong readOps,writeOps,otherOps,readBytes,writeBytes,otherBytes;
        public UIntPtr processMemory,jobMemory,peakProcess,peakJob;
    }
    [StructLayout(LayoutKind.Sequential)] struct Accounting {
        public long user,kernel,periodUser,periodKernel;
        public uint faults,total,active,terminated;
    }
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int kind,ref Extended value,uint size);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job,int kind,out Accounting value,uint size,IntPtr returned);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateJobObject(IntPtr job,uint code);
    public static void Configure(IntPtr ownedOperationJob) {
        var value=new Extended();value.basic.flags=0x2000;
        if(!SetInformationJobObject(ownedOperationJob,9,ref value,(uint)Marshal.SizeOf(typeof(Extended)))) throw new Win32Exception(Marshal.GetLastWin32Error(),"Operation kill-on-close configuration failed");
    }
    public static void Stop(IntPtr ownedOperationJob,int milliseconds) {
        if(milliseconds<0 || milliseconds>10000) throw new ArgumentOutOfRangeException("milliseconds");
        if(!TerminateJobObject(ownedOperationJob,125)) throw new Win32Exception(Marshal.GetLastWin32Error(),"Fixed operation stop failed");
        DateTime limit=DateTime.UtcNow.AddMilliseconds(milliseconds);
        do {
            Accounting value;
            if(!QueryInformationJobObject(ownedOperationJob,1,out value,(uint)Marshal.SizeOf(typeof(Accounting)),IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error(),"Operation liveness is unknown");
            if(value.active==0) return;
            Thread.Sleep(10);
        } while(DateTime.UtcNow<limit);
        throw new TimeoutException("Fixed operation processes did not stop within the bound");
    }
}
