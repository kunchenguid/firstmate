// Opt-in native launcher. No fixture commands, configurable executable, or
// arbitrary operation entry point is exposed by this assembly.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Threading;
public static partial class NativeOwner {
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int kind);
    static int Launch(string selectedHome) {
        string home=NativeHomeLease.ValidateHomePath(selectedHome), node=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),@"nodejs\node.exe");
        string host=Path.Combine(CodeRoot,"bin","native-owner","codex-host.mjs");
        if(!File.Exists(node)||!File.Exists(host)) throw new IOException("Native Node or the code-owned host is missing");
        string[] provenDeadGenerations=NativeHomeLease.ProvenDeadGenerationsForAdmission(home);
        EmptyFleet(home,true,provenDeadGenerations);
        string session=Guid.NewGuid().ToString("N"),nonce=Guid.NewGuid().ToString("N"),pipeName="fm-native-"+session;
        IntPtr job=CreateJobObject(IntPtr.Zero,null),env=IntPtr.Zero,output=IntPtr.Zero,input=IntPtr.Zero;
        if(job==IntPtr.Zero) throw Error("Create session job");
        PI primary=new PI();var scopes=new List<ChildScope>();
        NativeHomeLease lease=null;
        NamedPipeServerStream ownerServer=null,controlServer=null;Thread controlThread=null;
        object sync=new object();Exception controlFailure=null;DateTime failureAt=DateTime.MaxValue;
        ConsoleCancelEventHandler cancel=(sender,args)=>{args.Cancel=true;};Console.CancelKeyPress+=cancel;
        try {
            lease=new NativeHomeLease(home);operationJournal=new NativeReceiptJournal(lease,session);
            operationJournal.ReconcileCompletedAcknowledgements();
            string runtime=Path.Combine(home,"state","native-runtime",session);Directory.CreateDirectory(runtime);
            var security=new PipeSecurity();security.SetAccessRuleProtection(true,false);
            security.AddAccessRule(new PipeAccessRule(WindowsIdentity.GetCurrent().User,PipeAccessRights.FullControl,AccessControlType.Allow));
            // Retain both instances before publishing or resuming a client.
            // The host connects once and never reconnects to a replacement.
            ownerServer=new NamedPipeServerStream(pipeName,PipeDirection.InOut,1,PipeTransmissionMode.Byte,PipeOptions.Asynchronous,4096,4096,security);
            string controlName="fm-native-host-"+session;
            controlServer=new NamedPipeServerStream(controlName,PipeDirection.InOut,1,PipeTransmissionMode.Byte,PipeOptions.Asynchronous,4096,4096,security);
            var values=EnvironmentFor(controlName,session,runtime,nonce);
            values["FM_HOME"]=home;values["FM_PROBE_CODE_ROOT"]=CodeRoot;
            values["FM_PROBE_JQ_IMAGE"]=Environment.GetEnvironmentVariable("FM_NATIVE_JQ_IMAGE")??"";
            values["FM_PROBE_VERIFY_ONLY"]=Environment.GetEnvironmentVariable("FM_NATIVE_VERIFY_ONLY")??"";
            values["MSYS"]="winsymlinks:nativestrict";
            var block=new StringBuilder();foreach(var entry in values)block.Append(entry.Key).Append('=').Append(entry.Value).Append('\0');block.Append('\0');
            env=Marshal.StringToHGlobalUni(block.ToString());
            var startup=new SI {cb=Marshal.SizeOf(typeof(SI)),flags=0x100,input=GetStdHandle(-10),output=GetStdHandle(-11),error=GetStdHandle(-12)};
            if(!CreateProcess(node,new StringBuilder(Quote(node)+" "+Quote(host)),IntPtr.Zero,IntPtr.Zero,true,0x4|0x400,env,CodeRoot,ref startup,out primary))throw Error("Create suspended host");
            if(!AssignProcessToJobObject(job,primary.process))throw Error("Assign host");
            FT born,exit,kernel,user;if(!GetProcessTimes(primary.process,out born,out exit,out kernel,out user))throw Error("Read host instance");
            lease.Publish(primary.pid,((ulong)born.high<<32)|born.low,session,pipeName);RegisteredHarness="codex";
            output=FileHandle(Path.Combine(runtime,"operations.log"),0x40000000,2);input=FileHandle("NUL",0x80000000,3);
            var operationStartup=new SI {cb=Marshal.SizeOf(typeof(SI)),flags=0x100,input=input,output=output,error=output};
            if(!operationJournal.NeedsReconciliation) {
                var operation=StartOwnerOperation(job,env,runtime,ref operationStartup);scopes.Add(operation);
                if(ResumeThread(operation.process.thread)==0xffffffff)throw Error("Resume startup");
            }
            controlThread=new Thread(()=>{
                try {
                    var connect=controlServer.BeginWaitForConnection(null,null);
                    while(!connect.AsyncWaitHandle.WaitOne(50)&&WaitForSingleObject(primary.process,0)==WAIT_TIMEOUT){}
                    if(!connect.IsCompleted)return;controlServer.EndWaitForConnection(connect);
                    uint peer;if(!GetNamedPipeClientProcessId(controlServer.SafePipeHandle.DangerousGetHandle(),out peer)||peer!=primary.pid)throw new IOException("Host channel peer mismatch");
                    using(var reader=new StreamReader(controlServer,Encoding.UTF8,false,1024,true))using(var writer=new StreamWriter(controlServer,new UTF8Encoding(false),1024,true)) {
                        writer.AutoFlush=true;
                        while(WaitForSingleObject(primary.process,0)==WAIT_TIMEOUT) {
                            var line=reader.ReadLineAsync();
                            while(!line.Wait(50)&&WaitForSingleObject(primary.process,0)==WAIT_TIMEOUT){}
                            if(!line.IsCompleted||line.Result==null)break;
                            if(line.Result.Length>4096)throw new IOException("Oversized host request");
                            lock(sync) {
                                var request=Json.Deserialize<Dictionary<string,object>>(line.Result);
                                var verdict=Verdict(request,peer,primary.process,job,primary.pid,scopes,session,runtime,nonce);
                                if(!request.ContainsKey("kind")||(string)request["kind"]!="notification")throw new IOException("Invalid host operation plane");
                                NotificationRequest(request,verdict,lease,job,env,runtime,ref operationStartup,scopes);
                                writer.WriteLine(Json.Serialize(verdict));
                            }
                        }
                    }
                } catch(Exception error){Interlocked.CompareExchange(ref controlFailure,error,null);}
                finally {controlServer.Dispose();}
            });controlThread.IsBackground=true;controlThread.Start();
            if(ResumeThread(primary.thread)==0xffffffff)throw Error("Resume host");
            while(WaitForSingleObject(primary.process,0)==WAIT_TIMEOUT) {
                var pending=ownerServer.BeginWaitForConnection(null,null);
                while(!pending.AsyncWaitHandle.WaitOne(50)&&WaitForSingleObject(primary.process,0)==WAIT_TIMEOUT) {
                    if(Volatile.Read(ref controlFailure)!=null) {
                        if(failureAt==DateTime.MaxValue)failureAt=DateTime.UtcNow;
                        if((DateTime.UtcNow-failureAt).TotalSeconds>12)break;
                    }
                }
                if(!pending.IsCompleted)break;ownerServer.EndWaitForConnection(pending);
                uint pid;if(!GetNamedPipeClientProcessId(ownerServer.SafePipeHandle.DangerousGetHandle(),out pid))throw Error("Read native peer");
                using(var reader=new StreamReader(ownerServer,Encoding.UTF8,false,1024,true))using(var writer=new StreamWriter(ownerServer,new UTF8Encoding(false),1024,true)) {
                    var read=reader.ReadLineAsync();if(!read.Wait(8000)||read.Result==null||read.Result.Length>4096)throw new IOException("Invalid native request");
                    lock(sync) {
                        var request=Json.Deserialize<Dictionary<string,object>>(read.Result);
                        var verdict=Verdict(request,pid,primary.process,job,primary.pid,scopes,session,runtime,nonce);
                        if(request.ContainsKey("kind")&&(string)request["kind"]=="owner")AuthorizeOwner(request,verdict,ownerServer,lease,session);
                        writer.AutoFlush=true;writer.WriteLine(Json.Serialize(verdict));
                    }
                }
                ownerServer.Disconnect();
            }
            if(controlFailure!=null)throw new IOException("Native host connection failed",controlFailure);
            uint code;if(!GetExitCodeProcess(primary.process,out code))throw Error("Read host exit");return (int)code;
        } finally {
            if(ownerServer!=null)ownerServer.Dispose();
            if(controlServer!=null)controlServer.Dispose();
            if(controlThread!=null&&!controlThread.Join(3000)) {
                Console.Error.WriteLine("Host dispatch did not stop; preserving interrupted work and ending its controller");
                Environment.Exit(125);
            }
            // Never terminate the enclosing job: unrelated fleet processes may
            // outlive a host. Only registered fixed operations are stopped here.
            foreach(var scope in scopes) {
                try {NativeOperationLifetime.Stop(scope.job,2000);} finally {CloseHandle(scope.process.thread);CloseHandle(scope.process.process);CloseHandle(scope.job);}
            }
            if(primary.process!=IntPtr.Zero&&WaitForSingleObject(primary.process,0)==WAIT_TIMEOUT){TerminateProcess(primary.process,125);WaitForSingleObject(primary.process,3000);}
            foreach(IntPtr handle in new [] {primary.thread,primary.process,job,output,input})if(handle!=IntPtr.Zero)CloseHandle(handle);
            if(env!=IntPtr.Zero)Marshal.FreeHGlobal(env);
            if(operationJournal!=null)operationJournal.Dispose();if(lease!=null)lease.Dispose();Console.CancelKeyPress-=cancel;
        }
    }
    static int FixedOperation(string purpose) {
        if(purpose!="startup"&&purpose!="check"&&purpose!="ack")throw new ArgumentException("Unknown fixed operation");
        string home=Environment.GetEnvironmentVariable("FM_HOME");EmptyFleet(home,false);
        if(OwnerClient(purpose=="startup" ? "identity" : "owns",Path.Combine(home,"state"),"")!=0)throw new InvalidOperationException("Operation is not registered");
        string script=Path.Combine(CodeRoot,"bin","native-owner",purpose+".sh");
        using(var process=Process.Start(BashHelper(script,"",home,true))) {
            if(!process.WaitForExit(purpose=="startup" ? 240000 : 60000))throw new TimeoutException("Fixed operation exceeded its bound");return process.ExitCode;
        }
    }
    public static int Main(string[] args) {
        try {
            int ownerResult;
            if(args.Length==3&&args[0]=="launch"&&args[1]=="--experimental")return Launch(args[2]);
            if(TryOwnerCommand(args,out ownerResult))return ownerResult;
            if(args.Length==1&&args[0]=="owner-operation")return FixedOperation("startup");
            if(args.Length==2&&args[0]=="notification-operation")return FixedOperation(args[1]);
            throw new ArgumentException("Use fm-native-codex.ps1 -Experimental -OperationalHome <temporary empty-fleet home>");
        } catch(Exception error){Console.Error.WriteLine(error.Message);return 2;}
    }
}
