// Shared registered operation dispatch; external callers never choose commands.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
public static partial class NativeOwner {
    static NativeReceiptJournal operationJournal;
    static bool shutdownRequested;
    internal static string CodeRoot { get { return Path.GetDirectoryName(Path.GetDirectoryName(OwnExe)); } }
    static SortedDictionary<string,string> TrustedBaseEnvironment() {
        var values=new SortedDictionary<string,string>(StringComparer.OrdinalIgnoreCase);
        foreach(string key in new [] {"SystemRoot","WINDIR","TEMP","TMP","USERPROFILE","APPDATA","LOCALAPPDATA"}) {
            string value=Environment.GetEnvironmentVariable(key);if(value!=null)values[key]=value;
        }
        values["PATH"]=@"C:\Program Files\Git\usr\bin;C:\Windows\System32;C:\Windows;C:\Program Files\nodejs;C:\Program Files\GitHub CLI;"+Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),"npm");
        return values;
    }
    internal static ProcessStartInfo BashHelper(string script,string arguments,string home,bool includeProbe=false) {
        var start=new ProcessStartInfo(@"C:\Program Files\Git\bin\bash.exe","--noprofile --norc "+Quote(script.Replace('\\','/'))+(string.IsNullOrEmpty(arguments) ? "" : " "+arguments)) {UseShellExecute=false,CreateNoWindow=true};
        start.EnvironmentVariables.Clear();
        foreach(var entry in TrustedBaseEnvironment())start.EnvironmentVariables[entry.Key]=entry.Value;
        if(includeProbe) {
            foreach(string key in new [] {"FM_PROBE_PIPE","FM_PROBE_SESSION","FM_PROBE_HOME","FM_PROBE_NONCE","FM_PROBE_JQ_IMAGE","FM_PROBE_VERIFY_ONLY"}) {
                string value=Environment.GetEnvironmentVariable(key);if(value!=null)start.EnvironmentVariables[key]=value;
            }
        }
        start.EnvironmentVariables["FM_HOME"]=home;
        start.EnvironmentVariables["MSYS"]="winsymlinks:nativestrict";
        return start;
    }
    static void OwnerAdmission(string home,bool launch,string[] provenDeadGenerations) {
        string script=Path.Combine(CodeRoot,"bin","native-owner","admit.sh");
        object evidence=NativeReceiptJournal.AdmissionEvidence(home);
        string input="";
        var start=BashHelper(script,launch ? "launch" : "owned-operation",home);start.RedirectStandardInput=true;start.RedirectStandardError=true;
        if(launch && provenDeadGenerations!=null && provenDeadGenerations.Length>0)start.EnvironmentVariables["FM_NATIVE_PROVEN_DEAD_GENERATIONS"]=string.Join(",",provenDeadGenerations);
        if(evidence is string) {start.EnvironmentVariables["FM_NATIVE_ACK_EVIDENCE_KIND"]="token";input=(string)evidence;}
        else if(evidence!=null) {start.EnvironmentVariables["FM_NATIVE_ACK_EVIDENCE_KIND"]="legacy";input=Json.Serialize(evidence);}
        using(var process=Process.Start(start)) {
            var error=process.StandardError.ReadToEndAsync();
            process.StandardInput.Write(input);process.StandardInput.Close();
            if(!process.WaitForExit(30000)){process.Kill();throw new TimeoutException("The empty-fleet owner preflight exceeded its bound");}
            if(process.ExitCode!=0)throw new InvalidOperationException("This experimental launcher requires an empty fleet; existing records were preserved: "+error.Result.Trim());
        }
    }
    static bool PathPresent(string name) {
        try { File.GetAttributes(name);return true; }
        catch(FileNotFoundException) { return false; }
        catch(DirectoryNotFoundException) { return false; }
    }
    static bool ProjectsOccupied(string name) {
        FileAttributes attributes;
        try { attributes=File.GetAttributes(name); }
        catch(FileNotFoundException) { return false; }
        catch(DirectoryNotFoundException) { return false; }
        if((attributes&FileAttributes.ReparsePoint)!=0 || (attributes&FileAttributes.Directory)==0) return true;
        return Directory.GetFileSystemEntries(name).Length!=0;
    }
    internal static void EmptyFleet(string home,bool launch,string[] provenDeadGenerations=null) {
        string state=Path.Combine(home,"state"),projects=Path.Combine(home,"projects");
        if(ProjectsOccupied(projects) || PathPresent(Path.Combine(home,"data","secondmates.md")) || PathPresent(Path.Combine(home,"data","projects.md")) || PathPresent(Path.Combine(home,".env")) || PathPresent(Path.Combine(home,"config","x-mode.env")) || (Directory.Exists(Path.Combine(state,"procevent"))&&Directory.GetFileSystemEntries(Path.Combine(state,"procevent")).Length!=0)) throw new InvalidOperationException("This experimental launcher requires an empty fleet; existing fleet records were preserved");
        OwnerAdmission(home,launch,provenDeadGenerations);
    }
    static IntPtr FileHandle(string path, uint access, uint creation) {
        SA sa = new SA { length=Marshal.SizeOf(typeof(SA)), inherit=1 };
        IntPtr h = CreateFile(path, access, 3, ref sa, creation, 0x80, IntPtr.Zero);
        if (h == new IntPtr(-1)) throw Error("CreateFile");
        return h;
    }
    static SortedDictionary<string,string> EnvironmentFor(string pipe, string session, string home, string nonce) {
        var result = new SortedDictionary<string,string>(StringComparer.OrdinalIgnoreCase);
        foreach (DictionaryEntry e in Environment.GetEnvironmentVariables()) {
            string k = (string)e.Key;
            if (string.Equals(k,"NODE_OPTIONS",StringComparison.OrdinalIgnoreCase) || string.Equals(k,"NODE_PATH",StringComparison.OrdinalIgnoreCase) || string.Equals(k,"BASH_ENV",StringComparison.OrdinalIgnoreCase) || string.Equals(k,"ENV",StringComparison.OrdinalIgnoreCase)) continue;
            if (k.StartsWith("FM_", StringComparison.OrdinalIgnoreCase) || k.StartsWith("PI_", StringComparison.OrdinalIgnoreCase) || k.StartsWith("NO_MISTAKES", StringComparison.OrdinalIgnoreCase) || string.Equals(k,"CLAUDE_PID",StringComparison.OrdinalIgnoreCase) || string.Equals(k,"CLAUDECODE",StringComparison.OrdinalIgnoreCase)) continue;
            result[k] = (string)e.Value;
        }
        result["FM_PROBE_PIPE"] = pipe; result["FM_PROBE_SESSION"] = session;
        result["FM_PROBE_HOME"] = home; result["FM_PROBE_NONCE"] = nonce;
        return result;
    }
    static ChildScope StartOwnerOperation(IntPtr parentJob, IntPtr environment, string home, ref SI startup, string purpose="startup") {
        if(purpose!="startup" && purpose!="check" && purpose!="ack") throw new ArgumentException("Unknown fixed operation");
        var scope=new ChildScope { job=CreateJobObject(IntPtr.Zero,null), role="owner-operation", purpose=purpose };
        IntPtr operationEnvironment=IntPtr.Zero;
        if(scope.job==IntPtr.Zero) throw Error("CreateJobObject child scope");
        try {
            NativeOperationLifetime.Configure(scope.job);
            string operation=purpose=="startup" ? "owner-operation" : "notification-operation "+purpose;
            var values=TrustedBaseEnvironment();
            int offset=0;
            while(Marshal.ReadInt16(environment,offset)!=0) {
                string entry=Marshal.PtrToStringUni(IntPtr.Add(environment,offset)); offset+=(entry.Length+1)*2;
                int split=entry.IndexOf('='); if(split<=0) continue;
                string key=entry.Substring(0,split);
                if(key.StartsWith("FM_PROBE_",StringComparison.OrdinalIgnoreCase) || string.Equals(key,"FM_HOME",StringComparison.OrdinalIgnoreCase) || string.Equals(key,"MSYS",StringComparison.OrdinalIgnoreCase)) values[key]=entry.Substring(split+1);
            }
            var block=new StringBuilder(); foreach(var value in values) block.Append(value.Key).Append('=').Append(value.Value).Append('\0'); block.Append('\0');
            operationEnvironment=Marshal.StringToHGlobalUni(block.ToString());
            if(!CreateProcess(OwnExe,new StringBuilder(Quote(OwnExe)+" "+operation),IntPtr.Zero,IntPtr.Zero,true,0x4|0x400|0x200,operationEnvironment,home,ref startup,out scope.process)) throw Error("CreateProcess child scope");
            if(!AssignProcessToJobObject(parentJob,scope.process.process) || !AssignProcessToJobObject(scope.job,scope.process.process)) throw Error("Assign child scope");
            // The caller records this scope before resuming the process.
            return scope;
        } catch {
            if(scope.process.process!=IntPtr.Zero) { TerminateProcess(scope.process.process,125); CloseHandle(scope.process.thread); CloseHandle(scope.process.process); }
            CloseHandle(scope.job); throw;
        } finally { if(operationEnvironment!=IntPtr.Zero) Marshal.FreeHGlobal(operationEnvironment); }
    }
    static void NotificationRequest(Dictionary<string,object> request,Dictionary<string,object> verdict,NativeHomeLease lease,IntPtr job,IntPtr environment,string home,ref SI startup,List<ChildScope> scopes) {
        bool allowed=lease!=null && (string)verdict["association"]=="associated" && (string)verdict["hostClassification"]=="registered-primary";
        verdict["notificationAuthorized"]=allowed;
        if(!allowed) return;
        string action=request.ContainsKey("action") ? (string)request["action"] : "";
        if(action=="shutdown") {
            shutdownRequested=true;
            foreach(var scope in scopes) if(scope.role=="owner-operation") NativeOperationLifetime.Stop(scope.job,1500);
            verdict["operationState"]="stopped";
            verdict["reconciliationRequired"]=operationJournal.NeedsReconciliation;
            return;
        }
        if(shutdownRequested) { verdict["operationState"]="stopped";verdict["reconciliationRequired"]=operationJournal.NeedsReconciliation;return; }
        bool ready=true,startupFailed=false;
        foreach(var scope in scopes) if(scope.purpose=="startup") {
            if(WaitForSingleObject(scope.process.process,0)==WAIT_TIMEOUT) ready=false;
            else {uint code;if(!GetExitCodeProcess(scope.process.process,out code)||code!=0)startupFailed=true;}
        }
        verdict["startupFailed"]=startupFailed;
        if(action=="status") {
            verdict["startupExpired"]=ready;
            verdict["operationState"]=operationJournal.NeedsReconciliation ? "reconciliation-required" : startupFailed ? "startup-failed" : ready ? "ready" : "starting";
            return;
        }
        verdict["startupExpired"]=ready;
        if(pendingOperation!=null && WaitForSingleObject(pendingOperation.process.process,0)!=WAIT_TIMEOUT) {
            uint code; if(!GetExitCodeProcess(pendingOperation.process.process,out code)) throw Error("Operation exit");
            verdict["operationExit"]=code;
            if(code!=0) { verdict["operationState"]="failed"; return; }
            string file=Path.Combine(home,"notification-"+pendingOperation.purpose+".json");
            if(pendingOperation.purpose=="check") {
                var output=Json.Deserialize<Dictionary<string,object>>(File.ReadAllText(file));
                if(output.ContainsKey("quiet") && (bool)output["quiet"]) { delivered=null;receipt=null; }
                else {delivered=operationJournal.Present(output);receipt=(string)delivered["receipt"];}
                consumed=false;
            } else {
                try { operationJournal.CompleteAcknowledgement(receipt,File.ReadAllText(file));consumed=true; }
                catch(IOException) { verdict["operationState"]="reconciliation-required";verdict["reconciliationRequired"]=true; }
                catch(UnauthorizedAccessException) { verdict["operationState"]="reconciliation-required";verdict["reconciliationRequired"]=true; }
            }
            NativeOperationLifetime.Stop(pendingOperation.job,1500);
            scopes.Remove(pendingOperation);
            CloseHandle(pendingOperation.process.thread);CloseHandle(pendingOperation.process.process);CloseHandle(pendingOperation.job);
            pendingOperation=null;
            if(verdict.ContainsKey("reconciliationRequired")) return;
        }
        if(action=="result") {
            verdict["operationState"]=pendingOperation!=null ? "pending" : operationJournal.NeedsReconciliation ? "reconciliation-required" : consumed ? "acknowledged" : delivered!=null ? "delivered" : "quiet";
            if(delivered!=null) verdict["notification"]=delivered;
            return;
        }
        if(startupFailed) {verdict["operationState"]="startup-failed";return;}
        if(!ready || pendingOperation!=null) { verdict["operationState"]="busy"; return; }
        if(operationJournal.NeedsReconciliation) { verdict["operationState"]="reconciliation-required";return; }
        bool startCheck=action=="check" && (delivered==null || consumed);
        bool startAcknowledgement=action=="ack" && delivered!=null && !consumed && request.ContainsKey("receipt") && (string)request["receipt"]==receipt && request.ContainsKey("observed") && (string)request["observed"]==(string)delivered["challenge"];
        if(!startCheck && !startAcknowledgement) { verdict["operationState"]="denied"; return; }
        if(startAcknowledgement) {
            var targetEvidence=NativeAcknowledgementEvidence.Capture(lease,delivered);
            var acknowledged=operationJournal.BeginAcknowledgement(receipt,(string)request["observed"],targetEvidence);
            File.WriteAllText(Path.Combine(home,"notification-ack-request.json"),Json.Serialize(acknowledged));
        }
        pendingOperation=StartOwnerOperation(job,environment,home,ref startup,action);
        scopes.Add(pendingOperation);
        if(ResumeThread(pendingOperation.process.thread)==0xffffffff) throw Error("Resume notification operation");
        verdict["operationState"]="pending";
    }
}
