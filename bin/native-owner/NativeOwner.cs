// Experimental ownership core for the explicit opt-in launcher; no runtime
// backend is installed. The controller registers scopes; association alone
// never grants ownership.
using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

public static partial class NativeOwner {
    static JavaScriptSerializer Json = new JavaScriptSerializer();
    static string RegisteredHarness="unknown";
    const uint WAIT_TIMEOUT = 258;
    [StructLayout(LayoutKind.Sequential)] struct SA { public int length; public IntPtr descriptor; public int inherit; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct SI {
        public int cb; public string reserved, desktop, title;
        public uint x,y,xSize,ySize,xCount,yCount,fill,flags;
        public short show, reserved2; public IntPtr reservedBytes, input, output, error;
    }
    [StructLayout(LayoutKind.Sequential)] struct PI { public IntPtr process, thread; public uint pid, tid; }
    [StructLayout(LayoutKind.Sequential)] struct FT { public uint low, high; }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr security, string name);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateProcess(string exe, StringBuilder args, IntPtr psa, IntPtr tsa, bool inherit, uint flags, IntPtr env, string cwd, ref SI startup, out PI process);
    [DllImport("kernel32.dll", SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr process, out uint code);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessTimes(IntPtr process, out FT created, out FT exited, out FT kernel, out FT user);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetNamedPipeClientProcessId(IntPtr pipe, out uint pid);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateJobObject(IntPtr job, uint code);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateFile(string name, uint access, uint share, ref SA sa, uint creation, uint flags, IntPtr template);

    [StructLayout(LayoutKind.Sequential)] struct SidAttributes { public IntPtr sid; public uint attributes; }
    [StructLayout(LayoutKind.Sequential)] struct TokenGroupsFirst { public uint count; public SidAttributes first; }
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool GetTokenInformation(IntPtr token, int kind, IntPtr data, int size, out int needed);
    static List<Dictionary<string,object>> TokenGroups(IntPtr token, int kind) {
        int needed; GetTokenInformation(token,kind,IntPtr.Zero,0,out needed);
        if (needed==0) throw Error("GetTokenInformation size");
        IntPtr data=Marshal.AllocHGlobal(needed);
        try {
            if (!GetTokenInformation(token,kind,data,needed,out needed)) throw Error("GetTokenInformation");
            int count=Marshal.ReadInt32(data), offset=(int)Marshal.OffsetOf(typeof(TokenGroupsFirst),"first");
            int stride=Marshal.SizeOf(typeof(SidAttributes));
            var rows=new List<Dictionary<string,object>>();
            for(int i=0;i<count;i++) {
                var entry=(SidAttributes)Marshal.PtrToStructure(IntPtr.Add(data,offset+i*stride),typeof(SidAttributes));
                rows.Add(new Dictionary<string,object>{{"sid",new SecurityIdentifier(entry.sid).Value},{"attributes",entry.attributes}});
            }
            return rows;
        } finally { Marshal.FreeHGlobal(data); }
    }
    static Exception Error(string call) { return new Win32Exception(Marshal.GetLastWin32Error(), call); }
    static string OwnExe { get { return Process.GetCurrentProcess().MainModule.FileName; } }
    static string Quote(string s) { return "\"" + s.Replace("\"", "\\\"") + "\""; }
    sealed class ChildScope { public IntPtr job; public PI process; public string role; public string purpose; }
    static ChildScope pendingOperation;
    static Dictionary<string,object> delivered;
    static string receipt;
    static bool consumed;
    static Dictionary<string,object> Verdict(Dictionary<string,object> request, uint pid, IntPtr root, IntPtr job, uint rootPid, List<ChildScope> scopes, string session, string home, string nonce) {
        string reason = "unverified", classification="none";
        if (WaitForSingleObject(root, 0) != WAIT_TIMEOUT) reason = "session-exited";
        else if (!request.ContainsKey("session") || (string)request["session"] != session) reason = "wrong-session";
        else if (!request.ContainsKey("home") || (string)request["home"] != home) reason = "wrong-home";
        else if (!request.ContainsKey("nonce") || (string)request["nonce"] != nonce) reason = "wrong-capability";
        else {
            IntPtr client = OpenProcess(0x1000 | 0x100000, false, pid);
            if (client == IntPtr.Zero) reason = "client-unreadable";
            else try {
                bool member;
                if (!IsProcessInJob(client, job, out member)) reason = "membership-unreadable";
                else if (WaitForSingleObject(client, 0) != WAIT_TIMEOUT) reason = "client-exited";
                else {
                    reason = member ? "associated" : "outside-session-job";
                    if(member) {
                        classification=pid==rootPid ? "registered-primary" : "unclassified-descendant";
                        foreach(var scope in scopes) {
                            bool scoped;
                            if(!IsProcessInJob(client,scope.job,out scoped)) { classification="scope-unreadable"; break; }
                            if(!scoped) continue;
                            // A restrictive child scope always defeats an enclosing grant.
                            if(scope.role!="owner-operation") { classification="registered-"+scope.role; break; }
                            classification=WaitForSingleObject(scope.process.process,0)==WAIT_TIMEOUT ? "registered-owner-operation" : "expired-owner-operation";
                        }
                    }
                }
            } finally { CloseHandle(client); }
        }
        return new Dictionary<string,object> {
            {"clientPid",pid}, {"case", request.ContainsKey("case") ? request["case"] : "unnamed"},
            {"association",reason}, {"hostClassification",classification}, {"authorityGranted",false}
        };
    }
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetNamedPipeServerProcessId(IntPtr pipe,out uint pid);
    static string Canonical(string value) { return Path.GetFullPath(value).TrimEnd('\\','/'); }
    static void AuthorizeOwner(Dictionary<string,object> request,Dictionary<string,object> verdict,NamedPipeServerStream server,NativeHomeLease lease,string session) {
        bool unrestricted=false;
        server.RunAsClient(delegate {
            using(var identity=WindowsIdentity.GetCurrent(true)) unrestricted=identity!=null && TokenGroups(identity.Token,11).Count==0;
        });
        bool allowed=lease!=null && (string)verdict["association"]=="associated" && unrestricted &&
            ((string)verdict["hostClassification"]=="registered-primary" || (string)verdict["hostClassification"]=="registered-owner-operation") &&
            request.ContainsKey("state") && string.Equals(Canonical((string)request["state"]),Canonical(Path.Combine(lease.Home,"state")),StringComparison.OrdinalIgnoreCase);
        string verb=request.ContainsKey("verb") ? (string)request["verb"] : "";
        allowed=allowed && (verb=="identity" || verb=="alive" || verb=="owns" || verb=="harness");
        string id="native:"+session, value="";
        if(allowed) {
            if(verb=="identity") value=id;
            else if(verb=="harness") value=RegisteredHarness;
            else if(verb=="alive") {
                string requested=request.ContainsKey("id") ? (string)request["id"] : "";
                value=requested==id ? "true" : requested.StartsWith("native:",StringComparison.Ordinal) && lease.ProvenDeadGeneration(requested.Substring(7)) ? "false" : "unknown";
            }
            else {
                string filename=Path.Combine(lease.Home,"state",".lock");
                value=File.Exists(filename) && (File.GetAttributes(filename)&FileAttributes.ReparsePoint)==0 && File.ReadAllText(filename).Trim()==id ? "true" : "false";
            }
        }
        verdict["ownerAuthorized"]=allowed;
        verdict["ownerValue"]=value;
        // Limited to the isolated state path and the three operations above.
        verdict["authorityGranted"]=allowed;
    }
    static int OwnerClient(string verb,string state,string id) {
        var binding=NativeHomeLease.Binding(state);
        using(var pipe=new NamedPipeClientStream(".",(string)binding["pipe"],PipeAccessRights.ReadData|PipeAccessRights.WriteData|PipeAccessRights.Synchronize,PipeOptions.None,TokenImpersonationLevel.Identification,HandleInheritability.None)) {
            pipe.Connect(8000);
            uint serverPid;
            if(!GetNamedPipeServerProcessId(pipe.SafePipeHandle.DangerousGetHandle(),out serverPid) || serverPid!=Convert.ToUInt32(binding["controllerPid"])) throw new InvalidOperationException("Owner server identity mismatch");
            IntPtr server=OpenProcess(0x1000|0x100000,false,serverPid);
            if(server==IntPtr.Zero) throw Error("Owner server unreadable");
            try {
                FT born,exit,kernel,user;
                if(!GetProcessTimes(server,out born,out exit,out kernel,out user) || (((ulong)born.high<<32)|born.low)!=Convert.ToUInt64(binding["controllerCreated"]) || WaitForSingleObject(server,0)!=WAIT_TIMEOUT) throw new InvalidOperationException("Owner server instance mismatch");
                var request=new Dictionary<string,object>{{"session",(string)binding["generation"]},{"home",Environment.GetEnvironmentVariable("FM_PROBE_HOME")},{"nonce",Environment.GetEnvironmentVariable("FM_PROBE_NONCE")},{"case","owner-"+verb},{"kind","owner"},{"verb",verb},{"state",Canonical(state)},{"id",id}};
                using(var writer=new StreamWriter(pipe,new UTF8Encoding(false),1024,true))
                using(var reader=new StreamReader(pipe,Encoding.UTF8,false,1024,true)) {
                    writer.AutoFlush=true; writer.WriteLine(Json.Serialize(request));
                    var answer=Json.Deserialize<Dictionary<string,object>>(reader.ReadLine());
                    if(!answer.ContainsKey("ownerAuthorized") || !(bool)answer["ownerAuthorized"]) { Console.Error.WriteLine("Owner operation refused"); return 2; }
                    string value=(string)answer["ownerValue"];
                    if(verb=="identity" || verb=="harness") { Console.WriteLine(value); return 0; }
                    if(value=="unknown") { Console.Error.WriteLine("Owner liveness unknown"); return 2; }
                    return value=="true" ? 0 : 1;
                }
            } finally { CloseHandle(server); }
        }
    }
    static bool TryOwnerCommand(string[] args,out int result) {
        result=0;
        if(args.Length==3 && args[0]=="owner" && (args[1]=="identity" || args[1]=="owns" || args[1]=="harness")) {
            result=OwnerClient(args[1],args[2],"");return true;
        }
        if(args.Length==4 && args[0]=="owner" && args[1]=="alive") {
            result=OwnerClient(args[1],args[2],args[3]);return true;
        }
        return false;
    }
}
