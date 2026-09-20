// Test-only launchers, command dispatch, ACL experiments, and lifecycle controls.
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
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] [return: MarshalAs(UnmanagedType.I1)] static extern bool CreateSymbolicLink(string link,string target,uint flags);
    static string LogonSid() {
        using(var identity=WindowsIdentity.GetCurrent()) {
            foreach(var row in TokenGroups(identity.Token,2))
                if (((uint)row["attributes"] & 0xc0000000U)==0xc0000000U) return (string)row["sid"];
        }
        throw new InvalidOperationException("No kernel-marked logon SID available");
    }
    static Dictionary<string,object> TokenFacts() {
        using(var identity=WindowsIdentity.GetCurrent()) return new Dictionary<string,object> {
            {"kind","token-facts"},{"pid",Process.GetCurrentProcess().Id},{"user",identity.User.Value},
            {"groups",TokenGroups(identity.Token,2)},{"restricting",TokenGroups(identity.Token,11)}
        };
    }
    static void ReleaseFixtureWhenScopesEnd(List<ChildScope> scopes,string home) {
        if(scopes.Count==0) return;
        foreach(var scope in scopes) if(WaitForSingleObject(scope.process.process,0)==WAIT_TIMEOUT) return;
        string done=Path.Combine(home,"boundaries-done");
        if(!File.Exists(done)) File.WriteAllText(done,"complete");
    }
    static int Client(string which, bool notificationProbe=false) {
        Console.WriteLine(Json.Serialize(TokenFacts()));
        var request = new Dictionary<string,object> {
            {"session",Environment.GetEnvironmentVariable("FM_PROBE_SESSION")},
            {"home",Environment.GetEnvironmentVariable("FM_PROBE_HOME")},
            {"nonce",Environment.GetEnvironmentVariable("FM_PROBE_NONCE")}, {"case",which}, {"claimedRole","primary"}
        };
        if(notificationProbe) { request["kind"]="notification";request["action"]="check"; }
        if (which == "wrong-session") request["session"] = Guid.NewGuid().ToString("N");
        if (which == "wrong-home") request["home"] = "C:\\not-the-test-home";
        if (which == "wrong-capability") request["nonce"] = "copied-invalid-value";
        using (var pipe = new NamedPipeClientStream(".", Environment.GetEnvironmentVariable("FM_PROBE_PIPE"), PipeAccessRights.ReadData | PipeAccessRights.WriteData | PipeAccessRights.Synchronize, PipeOptions.None, TokenImpersonationLevel.Identification, HandleInheritability.None)) {
            pipe.Connect(8000);
            using (var writer = new StreamWriter(pipe, new UTF8Encoding(false), 1024, true))
            using (var reader = new StreamReader(pipe, Encoding.UTF8, false, 1024, true)) {
                writer.AutoFlush = true; writer.WriteLine(Json.Serialize(request));
                string line = reader.ReadLine();
                if (line == null) throw new IOException("No association response");
                Console.WriteLine(line);
            }
        }
        return 0;
    }
    static void RunFirstmate(string role,bool shouldSucceed) {
        string root=CodeRoot;
        string script=Path.Combine(root,shouldSucceed ? "exercise.sh" : "bin/fm-lock.sh").Replace('\\','/');
        using(var p=Process.Start(new ProcessStartInfo(@"C:\Program Files\Git\bin\bash.exe","--noprofile --norc "+Quote(script)) { UseShellExecute=false,RedirectStandardOutput=!shouldSucceed,RedirectStandardError=!shouldSucceed })) {
            var stdout=shouldSucceed ? System.Threading.Tasks.Task.FromResult("") : p.StandardOutput.ReadToEndAsync(); var stderr=shouldSucceed ? System.Threading.Tasks.Task.FromResult("") : p.StandardError.ReadToEndAsync();
            if(!p.WaitForExit(240000)) { p.Kill(); throw new IOException("Bounded Firstmate test timed out"); }
            File.WriteAllText(Path.Combine(Environment.GetEnvironmentVariable("FM_PROBE_HOME"),"firstmate-"+role+".json"),Json.Serialize(new Dictionary<string,object>{{"exit",p.ExitCode},{"stdout",stdout.Result},{"stderr",stderr.Result}}));
            if((p.ExitCode==0)!=shouldSucceed) throw new IOException("Unexpected Firstmate operation result for "+role);
        }
    }
    static void AcknowledgeTerminalOutcome(string home,string fingerprint) {
        string script=Path.Combine(CodeRoot,"bin","fm-inactive-reconcile.sh");
        var start=BashHelper(script,"acknowledge "+Quote(fingerprint),home);start.RedirectStandardError=true;
        using(var process=Process.Start(start)) {
            var error=process.StandardError.ReadToEndAsync();
            if(!process.WaitForExit(30000)){process.Kill();throw new TimeoutException("Terminal outcome acknowledgement exceeded its bound");}
            if(process.ExitCode!=0)throw new InvalidOperationException("Terminal outcome acknowledgement failed: "+error.Result.Trim());
        }
    }
    static int Fixture() {
        foreach (string c in new [] {"root", "wrong-session", "wrong-home", "wrong-capability"}) Client(c);
        var child = Process.Start(new ProcessStartInfo(OwnExe, "client inherited-child") { UseShellExecute=false });
        child.WaitForExit(); if (child.ExitCode != 0) return child.ExitCode;
        // Exercise MSYS exec without trying to infer its disappearing ancestors.
        var bash = Process.Start(new ProcessStartInfo(@"C:\Program Files\Git\bin\bash.exe", "-c " + Quote("exec \"$FM_PROBE_EXE\" client msys-exec")) { UseShellExecute=false });
        bash.WaitForExit();
        if(Environment.GetEnvironmentVariable("FM_PROBE_BOUNDARIES")=="1") {
            DateTime deadline=DateTime.UtcNow.AddSeconds(15);
            string done=Path.Combine(Environment.GetEnvironmentVariable("FM_PROBE_HOME"),"boundaries-done");
            while(!File.Exists(done) && DateTime.UtcNow<deadline) Thread.Sleep(25);
            if(!File.Exists(done)) throw new IOException("Boundary fixture did not complete");
        }
        if(Environment.GetEnvironmentVariable("FM_PROBE_EXERCISE")=="1") RunFirstmate("primary",true);
        return bash.ExitCode;
    }
    static int EnvironmentTests() {
        string directory=Path.Combine(Path.GetTempPath(),"fm-native-environment-"+Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        string payload=Path.Combine(directory,"payload.js"),bashMask=Path.Combine(directory,"bash-mask.sh"),main=Path.Combine(directory,"main.js"),injected=Path.Combine(directory,"injected"),result=Path.Combine(directory,"result.json");
        File.WriteAllText(payload,"require('fs').writeFileSync("+Json.Serialize(injected.Replace('\\','/'))+",'injected')");
        File.WriteAllText(bashMask,"exit 0\n");
        File.WriteAllText(main,"const fs=require('fs');const denied=['NODE_OPTIONS','NODE_PATH','BASH_ENV','ENV','CLAUDE_PID','CLAUDECODE'];const leaked=Object.keys(process.env).filter(k=>denied.includes(k.toUpperCase())||k.toUpperCase().startsWith('FM_')||k.toUpperCase().startsWith('PI_')||k.toUpperCase().startsWith('NO_MISTAKES'));fs.writeFileSync("+Json.Serialize(result.Replace('\\','/'))+",JSON.stringify(leaked));");
        var poison=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase){{"node_options","--require=\""+payload.Replace('\\','/')+"\""},{"node_path",directory},{"bAsH_eNv",bashMask},{"env",payload},{"claude_pid","123"},{"claudecode","1"},{"fm_poison","1"},{"pi_poison","1"},{"no_mistakes_poison","1"}};
        var original=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
        try {
            foreach(var entry in poison){original[entry.Key]=Environment.GetEnvironmentVariable(entry.Key);Environment.SetEnvironmentVariable(entry.Key,entry.Value);}
            var values=EnvironmentFor("pipe","session",directory,"nonce");
            var info=new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),@"nodejs\node.exe"),Quote(main)){UseShellExecute=false};
            info.EnvironmentVariables.Clear();foreach(var entry in values)info.EnvironmentVariables[entry.Key]=entry.Value;
            using(var process=Process.Start(info)){
                if(!process.WaitForExit(10000))throw new TimeoutException("Environment test child exceeded its bound");
                if(process.ExitCode!=0)throw new InvalidOperationException("Environment test child failed");
            }
            var leaked=Json.Deserialize<string[]>(File.ReadAllText(result));
            if(File.Exists(injected)||leaked.Length!=4)throw new InvalidOperationException("Denied inherited environment reached the native host");
            foreach(string key in leaked)if(!key.StartsWith("FM_PROBE_",StringComparison.Ordinal))throw new InvalidOperationException("Unexpected inherited environment reached the native host");
            Console.WriteLine("PASS: inherited Windows environment denylist is case-insensitive");
            foreach(string shape in new [] {"absent","regular","directory"}) {
                string sentinelHome=Path.Combine(directory,"registry-sentinel-"+shape),registry=Path.Combine(sentinelHome,"data","projects.md");
                Directory.CreateDirectory(sentinelHome);
                if(shape=="regular") { Directory.CreateDirectory(Path.GetDirectoryName(registry));File.WriteAllText(registry,"preserve registry\n"); }
                if(shape=="directory") Directory.CreateDirectory(registry);
                foreach(bool launch in new [] {true,false}) {
                    bool sentinelRefused=false;try{EmptyFleet(sentinelHome,launch);}catch(InvalidOperationException){sentinelRefused=true;}
                    if(sentinelRefused!=(shape!="absent"))throw new InvalidOperationException("Registry sentinel shape received the wrong admission result: "+shape);
                }
                if(shape=="regular"&&File.ReadAllText(registry)!="preserve registry\n")throw new InvalidOperationException("Regular registry sentinel changed during admission");
                if(shape=="directory"&&!Directory.Exists(registry))throw new InvalidOperationException("Directory registry sentinel changed during admission");
                if(File.Exists(Path.Combine(sentinelHome,"owner-probe.json"))||File.Exists(Path.Combine(sentinelHome,"state",".lock")))throw new InvalidOperationException("Registry sentinel admission acquired ownership");
            }
            Console.WriteLine("PASS: absent registry is admitted while file and directory sentinels are preserved and refused");
            foreach(string shape in new [] {"absent","empty-directory","regular-file","nonempty-directory","directory-link","broken-link"}) {
                string projectsHome=Path.Combine(directory,"projects-path-"+shape),projects=Path.Combine(projectsHome,"projects"),target=Path.Combine(directory,"projects-target-"+shape),body="preserve occupied projects path\n";
                Directory.CreateDirectory(projectsHome);
                if(shape=="empty-directory") Directory.CreateDirectory(projects);
                if(shape=="regular-file") File.WriteAllText(projects,body);
                if(shape=="nonempty-directory") { Directory.CreateDirectory(projects);File.WriteAllText(Path.Combine(projects,"unlanded.txt"),body); }
                if(shape=="directory-link") { Directory.CreateDirectory(target);if(!CreateSymbolicLink(projects,target,3))throw new Win32Exception(Marshal.GetLastWin32Error(),"Directory symlink fixture failed"); }
                if(shape=="broken-link"&&!CreateSymbolicLink(projects,target,3))throw new Win32Exception(Marshal.GetLastWin32Error(),"Broken directory symlink fixture failed");
                bool expected=shape=="absent"||shape=="empty-directory";
                foreach(bool launch in new [] {true,false}) {
                    bool projectsRefused=false;try{EmptyFleet(projectsHome,launch);}catch(InvalidOperationException){projectsRefused=true;}
                    if(projectsRefused==expected)throw new InvalidOperationException("Projects path shape received the wrong admission result: "+shape);
                }
                if(shape=="absent"&&(File.Exists(projects)||Directory.Exists(projects)))throw new InvalidOperationException("Absent projects path changed during admission");
                if(shape=="empty-directory"&&(!Directory.Exists(projects)||Directory.GetFileSystemEntries(projects).Length!=0))throw new InvalidOperationException("Empty projects directory changed during admission");
                if(shape=="regular-file"&&File.ReadAllText(projects)!=body)throw new InvalidOperationException("Regular projects path changed during admission");
                if(shape=="nonempty-directory"&&File.ReadAllText(Path.Combine(projects,"unlanded.txt"))!=body)throw new InvalidOperationException("Nonempty projects directory changed during admission");
                if((shape=="directory-link"||shape=="broken-link")&&(File.GetAttributes(projects)&FileAttributes.ReparsePoint)==0)throw new InvalidOperationException("Projects directory link changed during admission");
                if(shape=="directory-link"&&(!Directory.Exists(target)||Directory.GetFileSystemEntries(target).Length!=0))throw new InvalidOperationException("Projects directory link target changed during admission");
                if(shape=="broken-link"&&Directory.Exists(target))throw new InvalidOperationException("Broken projects directory link target changed during admission");
                if(shape=="directory-link"||shape=="broken-link") { Directory.CreateDirectory(target);File.WriteAllText(Path.Combine(projects,"target-check"),body);if(File.ReadAllText(Path.Combine(target,"target-check"))!=body)throw new InvalidOperationException("Projects directory link target changed during admission"); }
                if(File.Exists(Path.Combine(projectsHome,"owner-probe.json"))||File.Exists(Path.Combine(projectsHome,"state",".lock")))throw new InvalidOperationException("Projects path admission acquired ownership");
            }
            Console.WriteLine("PASS: only absent and ordinary empty projects paths are admitted unchanged");
            string residual=Path.Combine(directory,"residual"),residualState=Path.Combine(residual,"state"),status=Path.Combine(residualState,"orphan.status");
            Directory.CreateDirectory(residualState);File.WriteAllText(status,"preserve\n");
            bool refused=false;try{EmptyFleet(residual,true);}catch(InvalidOperationException){refused=true;}
            if(!refused||File.ReadAllText(status)!="preserve\n")throw new InvalidOperationException("Mixed-case BASH_ENV bypassed empty-home admission");
            Console.WriteLine("PASS: fixed Bash admission ignores mixed-case ambient authority");
            string restart=Path.Combine(directory,"dead-owner-restart"),restartState=Path.Combine(restart,"state"),restartGeneration=new string('d',32);
            uint departedPid;ulong departedCreated;
            using(var departed=Process.Start(new ProcessStartInfo("cmd.exe","/c exit 0") {UseShellExecute=false,CreateNoWindow=true})) {
                departedPid=(uint)departed.Id;departedCreated=(ulong)departed.StartTime.ToUniversalTime().ToFileTimeUtc();departed.WaitForExit();
            }
            using(var predecessor=new NativeHomeLease(restart))predecessor.Publish(departedPid,departedCreated,restartGeneration,"unreachable");
            Directory.CreateDirectory(restartState);File.WriteAllText(Path.Combine(restartState,".lock"),"native:"+restartGeneration+"\n");
            string[] deadProof=NativeHomeLease.ProvenDeadGenerationsForAdmission(restart);
            if(Array.IndexOf(deadProof,restartGeneration)<0)throw new InvalidOperationException("Exact departed owner was not proven dead");
            refused=false;try{EmptyFleet(restart,true,new [] {new string('e',32)});}catch(InvalidOperationException){refused=true;}
            if(!refused)throw new InvalidOperationException("Unrelated dead-generation claim bypassed native owner exclusion");
            EmptyFleet(restart,true,deadProof);
            using(var replacement=new NativeHomeLease(restart))if(!replacement.ProvenDeadGeneration(restartGeneration))throw new InvalidOperationException("Replacement lease lost proven-dead ownership history");
            Console.WriteLine("PASS: exact dead native generation admits restart while an unreachable endpoint alone remains exclusionary");
            string registered=Path.Combine(directory,"registered"),registeredState=Path.Combine(registered,"state"),canary=Path.Combine(registered,"executed");
            Directory.CreateDirectory(registeredState);
            File.WriteAllText(Path.Combine(registeredState,"custom.check.sh"),"#!/usr/bin/env bash\nprintf executed > \""+canary.Replace('\\','/')+"\"\n");
            File.WriteAllText(Path.Combine(registeredState,"custom.check-trust"),"fm-custom-check-v1\n"+new string('0',64)+"\n");
            refused=false;try{EmptyFleet(registered,true);using(var lease=new NativeHomeLease(registered)){} }catch(InvalidOperationException){refused=true;}
            if(!refused||File.Exists(canary)||File.Exists(Path.Combine(registered,"owner-probe.json"))||File.Exists(Path.Combine(registeredState,".watch.lock")))throw new InvalidOperationException("Registered custom work passed admission, acquired a lease, or executed during inspection");
            Console.WriteLine("PASS: registered custom checks are refused without execution");
            string unregistered=Path.Combine(directory,"unregistered"),unregisteredState=Path.Combine(unregistered,"state"),unregisteredCanary=Path.Combine(unregistered,"executed"),unregisteredCheck=Path.Combine(unregisteredState,"orphan.check.sh"),unregisteredBody="#!/usr/bin/env bash\nprintf executed > \""+unregisteredCanary.Replace('\\','/')+"\"\n";
            Directory.CreateDirectory(unregisteredState);File.WriteAllText(unregisteredCheck,unregisteredBody);
            refused=false;try{EmptyFleet(unregistered,true);using(var lease=new NativeHomeLease(unregistered)){} }catch(InvalidOperationException){refused=true;}
            if(!refused||File.ReadAllText(unregisteredCheck)!=unregisteredBody||File.Exists(unregisteredCanary)||File.Exists(Path.Combine(unregistered,"owner-probe.json"))||File.Exists(Path.Combine(unregisteredState,".watch.lock")))throw new InvalidOperationException("Unregistered custom work passed admission, changed, acquired a lease, or executed during inspection");
            Console.WriteLine("PASS: unregistered custom checks are preserved and refused without execution");
            string pendingReply=Path.Combine(directory,"pending-reply"),pendingState=Path.Combine(pendingReply,"state"),pendingDirectory=Path.Combine(pendingState,"pending-replies"),pendingRecord=Path.Combine(pendingDirectory,"0123456789abcdef"),pendingBody="schema=fm-pending-reply.v1\nphase=awaiting_report\n";
            Directory.CreateDirectory(pendingDirectory);File.WriteAllText(pendingRecord,pendingBody);
            refused=false;try{EmptyFleet(pendingReply,true);using(var lease=new NativeHomeLease(pendingReply)){} }catch(InvalidOperationException){refused=true;}
            if(!refused||File.ReadAllText(pendingRecord)!=pendingBody||File.Exists(Path.Combine(pendingReply,"owner-probe.json"))||File.Exists(Path.Combine(pendingState,".watch.lock"))||Directory.GetFiles(pendingState,"*",SearchOption.AllDirectories).Length!=1)throw new InvalidOperationException("Pending reply work passed admission, changed, or caused lease or route activity");
            Console.WriteLine("PASS: pending replies are preserved without lease or route activity");
            string reconcile=Path.Combine(directory,"reconcile-request"),reconcileState=Path.Combine(reconcile,"state"),reconcileDirectory=Path.Combine(reconcileState,"reconcile-notify"),reconcileRecord=Path.Combine(reconcileDirectory,"request-fixture.json"),reconcileBody="{\"version\":1}\n";
            Directory.CreateDirectory(reconcileDirectory);File.WriteAllText(reconcileRecord,reconcileBody);
            refused=false;try{EmptyFleet(reconcile,true);using(var lease=new NativeHomeLease(reconcile)){} }catch(InvalidOperationException){refused=true;}
            if(!refused||File.ReadAllText(reconcileRecord)!=reconcileBody||File.Exists(Path.Combine(reconcile,"owner-probe.json"))||File.Exists(Path.Combine(reconcileState,".watch.lock"))||File.Exists(Path.Combine(reconcileState,".reconcile-notify-process.lock"))||Directory.GetFiles(reconcileState,"*",SearchOption.AllDirectories).Length!=1)throw new InvalidOperationException("Reconcile request passed admission, changed, or caused lease or route activity");
            Console.WriteLine("PASS: reconcile requests are preserved without lease or route activity");
            string handoff=Path.Combine(directory,"handoff"),outbox=Path.Combine(handoff,"data","handoff","agent.outbox.md"),outboxBody="# Backlog\n\n## Queued\n\n- [ ] routed-work\n";
            Directory.CreateDirectory(Path.GetDirectoryName(outbox));File.WriteAllText(outbox,outboxBody);
            refused=false;try{EmptyFleet(handoff,true);using(var lease=new NativeHomeLease(handoff)){} }catch(InvalidOperationException){refused=true;}
            if(!refused||File.ReadAllText(outbox)!=outboxBody||File.Exists(Path.Combine(handoff,"owner-probe.json"))||Directory.Exists(Path.Combine(handoff,"state")))throw new InvalidOperationException("Pending handoff work passed admission or caused lease or route activity");
            Console.WriteLine("PASS: pending handoff work is preserved without lease or route activity");
            string steering=Path.Combine(directory,"steering"),steeringState=Path.Combine(steering,"state"),inbox=Path.Combine(steeringState,"agent.inbox"),message=Path.Combine(inbox,"001.msg"),messageBody="schema=fm-task-inbox.v1\n--\npreserve\n";
            Directory.CreateDirectory(inbox);File.WriteAllText(message,messageBody);
            refused=false;try{EmptyFleet(steering,true);using(var lease=new NativeHomeLease(steering)){} }catch(InvalidOperationException){refused=true;}
            if(!refused||File.ReadAllText(message)!=messageBody||File.Exists(Path.Combine(steering,"owner-probe.json"))||File.Exists(Path.Combine(steeringState,".lock")))throw new InvalidOperationException("Orphan steering work passed admission or caused lease or route activity");
            Console.WriteLine("PASS: orphan steering work is preserved without lease or route activity");
            string turnEnded=Path.Combine(directory,"turn-ended"),turnEndedState=Path.Combine(turnEnded,"state"),turnEndedRecord=Path.Combine(turnEndedState,"orphan.turn-ended");
            Directory.CreateDirectory(turnEndedState);File.WriteAllText(turnEndedRecord,"preserve\n");
            refused=false;try{EmptyFleet(turnEnded,true);using(var lease=new NativeHomeLease(turnEnded)){} }catch(InvalidOperationException){refused=true;}
            if(!refused||File.ReadAllText(turnEndedRecord)!="preserve\n"||File.Exists(Path.Combine(turnEnded,"owner-probe.json"))||File.Exists(Path.Combine(turnEndedState,".lock")))throw new InvalidOperationException("Residual turn-end work passed admission or caused lease activity");
            Console.WriteLine("PASS: residual turn-end work is preserved without lease activity");
            foreach(string phase in new [] {"upstream","presentation"}) {
                string outcomeHome=Path.Combine(directory,"pending-terminal-outcome-"+phase),outcomeState=Path.Combine(outcomeHome,"state"),outcomeDirectory=Path.Combine(outcomeState,"terminal-outcomes"),fingerprint=new string(phase=="upstream"?'a':'b',32),outcomeRecord=Path.Combine(outcomeDirectory,fingerprint+".pending"),outcomeBody="schema=fm-terminal-outcome.v1\nfingerprint="+fingerprint+"\nphase="+phase+"\n";
                Directory.CreateDirectory(outcomeDirectory);File.WriteAllText(outcomeRecord,outcomeBody);
                foreach(bool launch in new [] {true,false}) {
                    refused=false;try{EmptyFleet(outcomeHome,launch);using(var lease=new NativeHomeLease(outcomeHome)){} }catch(InvalidOperationException){refused=true;}
                    if(!refused||File.ReadAllText(outcomeRecord)!=outcomeBody||File.Exists(Path.Combine(outcomeHome,"owner-probe.json"))||File.Exists(Path.Combine(outcomeState,".lock")))throw new InvalidOperationException("Pending terminal outcome passed admission, changed, or caused lease activity");
                }
            }
            Console.WriteLine("PASS: upstream and presentation terminal outcomes remain unresolved and preserved");
            foreach(int fingerprintLength in new [] {32,16}) {
                string outcomeHome=Path.Combine(directory,"acknowledged-terminal-outcome-"+fingerprintLength),outcomeState=Path.Combine(outcomeHome,"state"),outcomeDirectory=Path.Combine(outcomeState,"terminal-outcomes"),fingerprint=new string(fingerprintLength==32?'c':'d',fingerprintLength),pending=Path.Combine(outcomeDirectory,fingerprint+".pending"),presented=Path.Combine(outcomeDirectory,fingerprint+".presented"),outcomeBody="schema=fm-terminal-outcome.v1\nfingerprint="+fingerprint+"\ntask_id=fixture\nincarnation=fixture-1\nstate=done\noutcome_key=fixture-complete\norigin=direct\nphase=presentation\npr=\ncreated_epoch=1\nnotice_emitted=0\n";
                Directory.CreateDirectory(outcomeDirectory);File.WriteAllText(pending,outcomeBody);
                refused=false;try{EmptyFleet(outcomeHome,true);}catch(InvalidOperationException){refused=true;}
                if(!refused||File.ReadAllText(pending)!=outcomeBody)throw new InvalidOperationException("Pending producer-format terminal outcome passed admission or changed");
                AcknowledgeTerminalOutcome(outcomeHome,fingerprint);
                if(File.Exists(pending)||!File.Exists(presented))throw new InvalidOperationException("Terminal outcome acknowledgement did not commit the presentation transition");
                EmptyFleet(outcomeHome,true);EmptyFleet(outcomeHome,false);
                if(File.ReadAllText(presented)!=outcomeBody||File.Exists(Path.Combine(outcomeHome,"owner-probe.json"))||File.Exists(Path.Combine(outcomeState,".lock")))throw new InvalidOperationException("Acknowledged producer-format terminal outcome was refused, changed, or caused lease activity");
            }
            Console.WriteLine("PASS: acknowledged 32- and 16-hex producer terminal outcomes remain admissible and unchanged");
            foreach(string terminalState in new [] {"presented","reported"}) {
                string outcomeHome=Path.Combine(directory,"settled-terminal-outcome-"+terminalState),outcomeState=Path.Combine(outcomeHome,"state"),outcomeDirectory=Path.Combine(outcomeState,"terminal-outcomes"),fingerprint=new string(terminalState=="presented"?'c':'d',32),outcomeRecord=Path.Combine(outcomeDirectory,fingerprint+"."+terminalState),outcomeBody="schema=fm-terminal-outcome.v1\nfingerprint="+fingerprint+"\n";
                Directory.CreateDirectory(outcomeDirectory);File.WriteAllText(outcomeRecord,outcomeBody);EmptyFleet(outcomeHome,true);EmptyFleet(outcomeHome,false);
                if(File.ReadAllText(outcomeRecord)!=outcomeBody||File.Exists(Path.Combine(outcomeHome,"owner-probe.json"))||File.Exists(Path.Combine(outcomeState,".lock")))throw new InvalidOperationException("Settled terminal outcome was refused, changed, or caused lease activity");
            }
            Console.WriteLine("PASS: presented and reported terminal-outcome history remains admissible and unchanged");
            string unknownOutcomeHome=Path.Combine(directory,"unknown-terminal-outcome"),unknownOutcomeState=Path.Combine(unknownOutcomeHome,"state"),unknownOutcomeDirectory=Path.Combine(unknownOutcomeState,"terminal-outcomes"),unknownOutcomeRecord=Path.Combine(unknownOutcomeDirectory,new string('e',32)+".unknown"),unknownOutcomeBody="preserve unknown terminal state\n";
            Directory.CreateDirectory(unknownOutcomeDirectory);File.WriteAllText(unknownOutcomeRecord,unknownOutcomeBody);
            foreach(bool launch in new [] {true,false}) {
                refused=false;try{EmptyFleet(unknownOutcomeHome,launch);using(var lease=new NativeHomeLease(unknownOutcomeHome)){} }catch(InvalidOperationException){refused=true;}
                if(!refused||File.ReadAllText(unknownOutcomeRecord)!=unknownOutcomeBody||File.Exists(Path.Combine(unknownOutcomeHome,"owner-probe.json"))||File.Exists(Path.Combine(unknownOutcomeState,".lock")))throw new InvalidOperationException("Unknown terminal-outcome state passed admission, changed, or caused lease activity");
            }
            Console.WriteLine("PASS: unknown terminal-outcome state is preserved and refused");
            string pendingResultHome=Path.Combine(directory,"pending-process-event-result"),pendingResultState=Path.Combine(pendingResultHome,"state"),pendingResultInbox=Path.Combine(pendingResultState,"procevent-inbox"),pendingResult=Path.Combine(pendingResultInbox,"native-result.1.result"),pendingAdapter=Path.Combine(pendingResultInbox,"native-result.1.adapter"),pendingResultBody="preserve captured result\n";
            Directory.CreateDirectory(pendingResultInbox);File.WriteAllText(pendingResult,pendingResultBody);File.WriteAllText(pendingAdapter,"lavish\n");
            refused=false;try{EmptyFleet(pendingResultHome,true);using(var lease=new NativeHomeLease(pendingResultHome)){} }catch(InvalidOperationException){refused=true;}
            if(!refused||File.ReadAllText(pendingResult)!=pendingResultBody||File.Exists(Path.Combine(pendingResultHome,"owner-probe.json"))||Directory.Exists(Path.Combine(pendingResultState,"procevent")))throw new InvalidOperationException("Unhandled process-event result passed admission, changed, acquired a lease, or created source state");
            Console.WriteLine("PASS: unhandled process-event results are preserved and refused before lease acquisition");
            string handledResultHome=Path.Combine(directory,"handled-process-event-result"),handledResultState=Path.Combine(handledResultHome,"state"),handledResultInbox=Path.Combine(handledResultState,"procevent-inbox"),handledResult=Path.Combine(handledResultInbox,"native-history.1.result"),handledAdapter=Path.Combine(handledResultInbox,"native-history.1.adapter"),handledMarker=Path.Combine(handledResultInbox,"native-history.1.handled");
            Directory.CreateDirectory(handledResultInbox);File.WriteAllText(handledResult,"handled history\n");File.WriteAllText(handledAdapter,"lavish\n");File.WriteAllText(handledMarker,"");
            EmptyFleet(handledResultHome,true);
            if(File.ReadAllText(handledResult)!="handled history\n"||!File.Exists(handledMarker)||File.Exists(Path.Combine(handledResultHome,"owner-probe.json")))throw new InvalidOperationException("Handled process-event history was refused, changed, or acquired a lease");
            Console.WriteLine("PASS: handled process-event history remains admissible and unchanged");
            string ambiguousAckHome=Path.Combine(directory,"ambiguous-process-event-ack"),ambiguousAckState=Path.Combine(ambiguousAckHome,"state"),ambiguousAckInbox=Path.Combine(ambiguousAckState,"procevent-inbox"),ambiguousResult=Path.Combine(ambiguousAckInbox,"native-ambiguous.1.result"),ambiguousAdapter=Path.Combine(ambiguousAckInbox,"native-ambiguous.1.adapter"),ambiguousMarker=Path.Combine(ambiguousAckInbox,"native-ambiguous.1.handled");
            Directory.CreateDirectory(ambiguousAckInbox);File.WriteAllText(ambiguousResult,"ambiguous history\n");File.WriteAllText(ambiguousAdapter,"lavish\n");Directory.CreateDirectory(ambiguousMarker);
            refused=false;try{EmptyFleet(ambiguousAckHome,true);using(var lease=new NativeHomeLease(ambiguousAckHome)){} }catch(InvalidOperationException){refused=true;}
            if(!refused||!Directory.Exists(ambiguousMarker)||File.Exists(Path.Combine(ambiguousAckHome,"owner-probe.json")))throw new InvalidOperationException("Ambiguous process-event acknowledgement passed admission, changed, or acquired a lease");
            Console.WriteLine("PASS: ambiguous process-event acknowledgement state is preserved and refused");
            string supported=Path.Combine(directory,"supported-notification"),supportedState=Path.Combine(supported,"state"),supportedInbox=Path.Combine(supportedState,"inbox"),supportedNote=Path.Combine(supportedInbox,"note-id.note"),supportedQueue=Path.Combine(supportedState,".wake-queue"),supportedMarker=Path.Combine(supportedState,".watcher-down"),supportedBody="preserve notification\n";
            Directory.CreateDirectory(supportedInbox);File.WriteAllText(supportedNote,supportedBody);File.WriteAllText(Path.Combine(supportedState,".wake-queue.seq"),"1\n");File.WriteAllText(supportedQueue,"1\t1\tcheck\tinbox:note-id\tcheck: captain inbox note note-id - native admission test\n");File.WriteAllText(supportedMarker,"pending:downtime:supported\n");
            EmptyFleet(supported,true);
            File.WriteAllText(Path.Combine(supportedState,".main-eligible-rows"),"1\n");File.WriteAllText(supportedMarker,"pending:handling:supported\n");
            EmptyFleet(supported,true);
            if(File.ReadAllText(supportedNote)!=supportedBody||!File.ReadAllText(supportedQueue).Contains("inbox:note-id")||File.ReadAllText(supportedMarker)!="pending:handling:supported\n"||File.Exists(Path.Combine(supported,"owner-probe.json")))throw new InvalidOperationException("Supported top-level notification state was changed or leased during admission");
            Console.WriteLine("PASS: supported top-level notification state remains admissible and unchanged");
            foreach(string shape in new [] {"unsupported","malformed"}) {
                string wakeHome=Path.Combine(directory,shape+"-wake"),wakeState=Path.Combine(wakeHome,"state"),wakeQueue=Path.Combine(wakeState,".wake-queue"),wakeMarker=Path.Combine(wakeState,".watcher-down");
                Directory.CreateDirectory(wakeState);File.WriteAllText(Path.Combine(wakeState,".wake-queue.seq"),"1\n");File.WriteAllText(wakeMarker,"pending:downtime:preserve\n");
                File.WriteAllText(wakeQueue,shape=="unsupported" ? "1\t1\tcheck\torphan-work\tcheck: unsupported residual work\n" : "malformed wake row\n");
                string queueBefore=File.ReadAllText(wakeQueue),markerBefore=File.ReadAllText(wakeMarker);
                refused=false;try{EmptyFleet(wakeHome,true);using(var lease=new NativeHomeLease(wakeHome)){} }catch(InvalidOperationException){refused=true;}
                if(!refused||File.ReadAllText(wakeQueue)!=queueBefore||File.ReadAllText(wakeMarker)!=markerBefore||File.Exists(Path.Combine(wakeHome,"owner-probe.json")))throw new InvalidOperationException("Unsupported wake state passed admission, changed, or acquired a lease");
            }
            Console.WriteLine("PASS: unsupported and malformed wake state is preserved and refused before lease acquisition");
            return 0;
        } finally {
            foreach(var entry in original)Environment.SetEnvironmentVariable(entry.Key,entry.Value);
        }
    }
    static ChildScope StartFixtureScope(string role,IntPtr parentJob,IntPtr environment,string home,ref SI startup) {
        if(role!="worker" && role!="nested-primary") throw new ArgumentException("Unsupported fixture scope");
        var scope=new ChildScope {job=CreateJobObject(IntPtr.Zero,null),role=role,purpose="fixture"};
        if(scope.job==IntPtr.Zero) throw Error("Create fixture scope job");
        try {
            if(!CreateProcess(OwnExe,new StringBuilder(Quote(OwnExe)+" scoped-client "+role),IntPtr.Zero,IntPtr.Zero,true,0x4|0x400|0x200,environment,home,ref startup,out scope.process)) throw Error("Create fixture scope");
            if(!AssignProcessToJobObject(parentJob,scope.process.process) || !AssignProcessToJobObject(scope.job,scope.process.process)) throw Error("Assign fixture scope");
            return scope;
        } catch {
            if(scope.process.process!=IntPtr.Zero) {TerminateProcess(scope.process.process,125);CloseHandle(scope.process.thread);CloseHandle(scope.process.process);}
            CloseHandle(scope.job);throw;
        }
    }
    static int LeaseCheck(string home,string generation) {
        bool current=false;
        try {
            var binding=NativeHomeLease.Binding(Path.Combine(home,"state"));
            current=binding.ContainsKey("generation") && (string)binding["generation"]==generation;
        } catch(InvalidOperationException error) {
            if(error.Message!="Primary no longer live") throw;
        }
        Console.WriteLine(Json.Serialize(new Dictionary<string,object>{{"probeOwnerCurrent",current}}));
        return 0;
    }
    static int Run(string configPath) {
        var config = Json.Deserialize<Dictionary<string,object>>(File.ReadAllText(configPath));
        string home = Path.GetFullPath((string)config["home"]);
        string executable = (string)config["executable"], arguments = (string)config["arguments"];
        int seconds = Convert.ToInt32(config["timeoutSeconds"]);
        if(config.ContainsKey("registeredHarness")) {
            string expected=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),@"npm\node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe");
            string host=Path.Combine(CodeRoot,"AppHost.mjs");
            string node=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),@"nodejs\node.exe");
            bool direct=(string)config["registeredHarness"]=="codex" && string.Equals(Path.GetFullPath(executable),Path.GetFullPath(expected),StringComparison.OrdinalIgnoreCase);
            bool adapter=(string)config["registeredHarness"]=="codex-app-server" && string.Equals(Path.GetFullPath(executable),Path.GetFullPath(node),StringComparison.OrdinalIgnoreCase) && arguments==Quote(host);
            if(!direct && !adapter) throw new InvalidOperationException("Requested runtime does not match the fixed native Codex launch target");
            RegisteredHarness="codex";
        }
        Directory.CreateDirectory(home);
        string session = Guid.NewGuid().ToString("N"), pipeName = "fm-private-probe-" + session, nonce = Guid.NewGuid().ToString("N");
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw Error("CreateJobObject");
        IntPtr env = IntPtr.Zero, stdout=IntPtr.Zero, stderr=IntPtr.Zero, stdin=IntPtr.Zero;
        PI child = new PI(); bool assigned=false, timedOut=false;
        var observations = new List<Dictionary<string,object>>();
        Process outsider = null;
        var scopes=new List<ChildScope>();
        NativeHomeLease lease=null;
        int recoveredAcknowledgements=0;
        try {
            if(config.ContainsKey("leaseHome")) {
                lease=new NativeHomeLease((string)config["leaseHome"]);
                operationJournal=new NativeReceiptJournal(lease,session);
                recoveredAcknowledgements=operationJournal.ReconcileCompletedAcknowledgements();
            }
            var values = EnvironmentFor(pipeName, session, home, nonce);
            values["FM_PROBE_EXE"]=OwnExe;
            if(config.ContainsKey("ownerExercise") && (bool)config["ownerExercise"]) {
                if(!config.ContainsKey("jqImage") || string.IsNullOrWhiteSpace((string)config["jqImage"])) throw new ArgumentException("Owner exercise requires an explicit local jq image");
                values["FM_PROBE_JQ_IMAGE"]=(string)config["jqImage"];
            }
            values["MSYS"]="winsymlinks:nativestrict";
            if(config.ContainsKey("apiDry") && (bool)config["apiDry"]) values["FM_PROBE_API_DRY"]="1";
            if(config.ContainsKey("startupQueued") && (bool)config["startupQueued"]) {
                string note=config.ContainsKey("startupNote") ? (string)config["startupNote"] : null;
                if(!values.ContainsKey("FM_PROBE_API_DRY") || string.IsNullOrEmpty(note)) throw new ArgumentException("Queued-startup fixture requires model-free mode and a note");
                foreach(char c in note) if(!char.IsLetterOrDigit(c) && c!='_' && c!='-') throw new ArgumentException("Invalid queued-startup note");
                values["FM_PROBE_STARTUP_QUEUED"]="1";values["FM_PROBE_STARTUP_NOTE"]=note;
            }
            if(config.ContainsKey("ackFault")) {
                string fault=(string)config["ackFault"];
                if(!values.ContainsKey("FM_PROBE_API_DRY") || (fault!="partial" && fault!="complete" && fault!="zero-missing" && fault!="zero-malformed" && fault!="zero-mismatched" && fault!="zero-unproven")) throw new ArgumentException("Fault injection is limited to the model-free fixture");
                values["FM_PROBE_ACK_FAULT"]=fault;
            }
            if(lease!=null) values["FM_HOME"]=lease.Home.Replace('\\','/');
            if(config.ContainsKey("ownerExercise") && (bool)config["ownerExercise"]) values["FM_PROBE_EXERCISE"]="1";
            if(config.ContainsKey("boundaries") && (bool)config["boundaries"]) values["FM_PROBE_BOUNDARIES"]="1";
            var block = new StringBuilder(); foreach (var e in values) block.Append(e.Key).Append('=').Append(e.Value).Append('\0'); block.Append('\0');
            env = Marshal.StringToHGlobalUni(block.ToString());
            stdout = FileHandle(Path.Combine(home,"stdout.log"),0x40000000,2);
            stderr = FileHandle(Path.Combine(home,"stderr.log"),0x40000000,2);
            stdin = FileHandle("NUL",0x80000000,3);
            SI startup = new SI { cb=Marshal.SizeOf(typeof(SI)), flags=0x100, input=stdin, output=stdout, error=stderr };
            if (!CreateProcess(executable, new StringBuilder(Quote(executable)+" "+arguments), IntPtr.Zero, IntPtr.Zero, true, 0x4 | 0x400, env, home, ref startup, out child)) throw Error("CreateProcess suspended");
            if (!config.ContainsKey("assignJob") || (bool)config["assignJob"]) {
                if (!AssignProcessToJobObject(job,child.process)) throw Error("AssignProcessToJobObject");
                assigned=true;
            }
            FT born, exited, kernel, user;
            if (!GetProcessTimes(child.process,out born,out exited,out kernel,out user)) throw Error("GetProcessTimes");
            if(lease!=null) lease.Publish(child.pid,((ulong)born.high<<32)|born.low,session,pipeName);
            if(config.ContainsKey("ownerOperation") && (bool)config["ownerOperation"]) {
                var operation=StartOwnerOperation(job,env,home,ref startup);
                scopes.Add(operation);
                if(ResumeThread(operation.process.thread)==0xffffffff) throw Error("Resume owner operation");
            }
            if(values.ContainsKey("FM_PROBE_BOUNDARIES")) {
                foreach(string role in new [] {"worker","nested-primary"}) scopes.Add(StartFixtureScope(role,job,env,home,ref startup));
                foreach(var scope in scopes) if(ResumeThread(scope.process.thread)==0xffffffff) throw Error("Resume child scope");
            }
            if (ResumeThread(child.thread) == 0xffffffff) throw Error("ResumeThread");
            if(config.ContainsKey("abandonAfterLaunch") && (bool)config["abandonAfterLaunch"]) {
                if(executable!=OwnExe || !arguments.StartsWith("sleep ",StringComparison.Ordinal)) throw new InvalidOperationException("Abandon test only permits bounded disposable sleepers");
                Console.WriteLine("DISPOSABLE_CONTROLLER_EXIT");
                Environment.Exit(86);
            }
            DateTime deadline=DateTime.UtcNow.AddSeconds(seconds);
            var security = new PipeSecurity(); security.SetAccessRuleProtection(true,false);
            security.AddAccessRule(new PipeAccessRule(WindowsIdentity.GetCurrent().User, PipeAccessRights.FullControl, AccessControlType.Allow));
            string pipeAcl=config.ContainsKey("pipeAcl") ? (string)config["pipeAcl"] : "UserOnly";
            if(pipeAcl=="LogonData") {
                // Only this ephemeral endpoint gains data exchange rights for
                // this kernel-authenticated Windows logon, never Everyone or
                // server-instance creation, ACL changes, or filesystem rights.
                security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(LogonSid()), PipeAccessRights.ReadData | PipeAccessRights.WriteData | PipeAccessRights.Synchronize, AccessControlType.Allow));
            } else if(pipeAcl!="UserOnly") throw new InvalidOperationException("Unknown pipe ACL test mode");
            bool outsiderStarted=false;
            while (WaitForSingleObject(child.process,0) == WAIT_TIMEOUT && DateTime.UtcNow < deadline) {
                using (var server = new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous, 4096, 4096, security)) {
                    var pending = server.BeginWaitForConnection(null,null);
                    if (!outsiderStarted && config.ContainsKey("outsider") && (bool)config["outsider"]) {
                        var info = new ProcessStartInfo(OwnExe,"client copied-outsider") { UseShellExecute=false, RedirectStandardOutput=true, RedirectStandardError=true };
                        foreach (var e in values) info.EnvironmentVariables[e.Key]=e.Value;
                        outsider=Process.Start(info); outsiderStarted=true;
                    }
                    while (!pending.AsyncWaitHandle.WaitOne(50) && WaitForSingleObject(child.process,0) == WAIT_TIMEOUT && DateTime.UtcNow < deadline) { ReleaseFixtureWhenScopesEnd(scopes,home); }
                    if (!pending.IsCompleted) break;
                    server.EndWaitForConnection(pending);
                    uint clientPid;
                    if (!GetNamedPipeClientProcessId(server.SafePipeHandle.DangerousGetHandle(), out clientPid)) throw Error("GetNamedPipeClientProcessId");
                    using (var reader = new StreamReader(server,Encoding.UTF8,false,1024,true))
                    using (var writer = new StreamWriter(server,new UTF8Encoding(false),1024,true)) {
                        var read = reader.ReadLineAsync();
                        if (!read.Wait(8000)) throw new IOException("Client request timeout");
                        if (read.Result == null || read.Result.Length > 4096) throw new IOException("Invalid request");
                        var request=Json.Deserialize<Dictionary<string,object>>(read.Result);
                        var verdict=Verdict(request,clientPid,child.process,job,child.pid,scopes,session,home,nonce);
                        if(request.ContainsKey("kind") && (string)request["kind"]=="owner") AuthorizeOwner(request,verdict,server,lease,session);
                        if(request.ContainsKey("kind") && (string)request["kind"]=="notification") NotificationRequest(request,verdict,lease,job,env,home,ref startup,scopes);
                        observations.Add(verdict); writer.AutoFlush=true; writer.WriteLine(Json.Serialize(verdict));
                    }
                }
            }
            timedOut=WaitForSingleObject(child.process,0)==WAIT_TIMEOUT;
            if (timedOut) {
                if (assigned) TerminateJobObject(job,124); else TerminateProcess(child.process,124);
                WaitForSingleObject(child.process,5000);
            }
            uint code; if (!GetExitCodeProcess(child.process,out code)) throw Error("GetExitCodeProcess");
            var stale=new Dictionary<string,object>{{"session",session},{"home",home},{"nonce",nonce},{"case","after-root-exit"}};
            observations.Add(Verdict(stale,(uint)Process.GetCurrentProcess().Id,child.process,job,child.pid,scopes,session,home,nonce));
            var result = new Dictionary<string,object> {
                {"rootPid",child.pid},{"registeredHarness",RegisteredHarness},{"rootCreationFileTime",((ulong)born.high<<32)|born.low},
                {"rootExit",code},{"timedOut",timedOut},{"jobAssigned",assigned},{"pipeAcl",pipeAcl},
                {"probeGeneration",session},{"probeLeaseHeld",lease!=null},
                {"pipeDacl",security.GetSecurityDescriptorSddlForm(AccessControlSections.Access)},
                {"recoveredAcknowledgements",recoveredAcknowledgements},{"receiptNeedsReconciliation",operationJournal!=null && operationJournal.NeedsReconciliation},
                {"authorityImplemented",false},{"notificationConsumed",consumed},{"observations",observations}
            };
            if (outsider != null) {
                if (!outsider.WaitForExit(10000)) throw new IOException("Outsider probe did not stop");
                result["outsiderExit"]=outsider.ExitCode; result["outsiderOutput"]=outsider.StandardOutput.ReadToEnd(); result["outsiderError"]=outsider.StandardError.ReadToEnd();
            }
            File.WriteAllText(Path.Combine(home,"result.json"),Json.Serialize(result));
            Console.WriteLine(Json.Serialize(result));
            return timedOut ? 124 : (int)code;
        } finally {
            // Only this disposable probe's retained native handles are eligible.
            // Never use a PID lookup to stop an unrelated or reused process.
            if (child.process != IntPtr.Zero && WaitForSingleObject(child.process,0)==WAIT_TIMEOUT) {
                if (assigned) TerminateJobObject(job,125); else TerminateProcess(child.process,125);
            }
            if(config.ContainsKey("ownerExercise") && (bool)config["ownerExercise"]) TerminateJobObject(job,125);
            foreach(var scope in scopes) {
                if(WaitForSingleObject(scope.process.process,0)==WAIT_TIMEOUT) TerminateJobObject(scope.job,125);
                CloseHandle(scope.process.thread); CloseHandle(scope.process.process); CloseHandle(scope.job);
            }
            foreach (IntPtr h in new [] {child.thread,child.process,stdout,stderr,stdin,job}) if (h!=IntPtr.Zero) CloseHandle(h);
            if(env!=IntPtr.Zero) Marshal.FreeHGlobal(env);
            if(operationJournal!=null) { operationJournal.Dispose();operationJournal=null; }
            if(lease!=null) lease.Dispose();
        }
    }
    public static int Main(string[] args) {
        try {
            int ownerResult;
            if(args.Length==1 && args[0]=="receipt-tests") { ReceiptTests.Run();return TestOperationLifetime(); }
            if(args.Length==1 && args[0]=="operation-lifetime-tests") return TestOperationLifetime();
            if(args.Length==1 && args[0]=="operation-lifetime-contention") {
                string previous=Environment.GetEnvironmentVariable("FM_PROBE_MARKER_CONTENTION");
                try {Environment.SetEnvironmentVariable("FM_PROBE_MARKER_CONTENTION","1");return TestOperationLifetime();}
                finally {Environment.SetEnvironmentVariable("FM_PROBE_MARKER_CONTENTION",previous);}
            }
            if(args.Length==1 && args[0]=="environment-tests") return EnvironmentTests();
            if(TryOwnerCommand(args,out ownerResult)) return ownerResult;
            if(args.Length==1 && args[0]=="privilege-probe") return Client("ordinary-sandbox-command",true);
            if(args.Length>0 && args[0]=="client") return Client(args.Length>1 ? args[1] : "agent-tool");
            if(args.Length==2 && args[0]=="sleep") { int ms=int.Parse(args[1]); if(ms<0 || ms>15000) throw new ArgumentException("Sleep must be bounded"); Thread.Sleep(ms); return 0; }
            if(args.Length==2 && args[0]=="operation-parent") {
                using(var descendant=Process.Start(new ProcessStartInfo(OwnExe,"sleep 10000") {UseShellExecute=false})) {
                    string staging=args[1]+".publishing";
                    try {
                        using(var stream=new FileStream(staging,FileMode.CreateNew,FileAccess.Write,FileShare.None))
                        using(var writer=new StreamWriter(stream,new UTF8Encoding(false))) {
                            writer.Write(descendant.Id.ToString());writer.Flush();
                            if(Environment.GetEnvironmentVariable("FM_PROBE_MARKER_CONTENTION")=="1") System.Threading.Thread.Sleep(1000);
                        }
                        File.Move(staging,args[1]);
                    } finally {if(File.Exists(staging)) File.Delete(staging);}
                    descendant.WaitForExit();return descendant.ExitCode;
                }
            }
            if(args.Length==3 && args[0]=="lease-check") return LeaseCheck(args[1],args[2]);
            if(args.Length==2 && args[0]=="notification-operation") {
                if(args[1]!="check" && args[1]!="ack") throw new ArgumentException("Unsupported notification operation");
                string script=Path.Combine(CodeRoot,"notification-"+args[1]+".sh");
                using(var operation=Process.Start(new ProcessStartInfo(@"C:\Program Files\Git\bin\bash.exe","--noprofile --norc "+Quote(script)) {UseShellExecute=false})) {
                    if(!operation.WaitForExit(60000)) throw new IOException("Notification operation exceeded its bound");
                    return operation.ExitCode;
                }
            }
            if(args.Length>0 && args[0]=="owner-operation") {
                RunFirstmate("owner-operation",true);
                string state=Path.Combine(Environment.GetEnvironmentVariable("FM_HOME"),"state");
                int live=OwnerClient("alive",state,"native:"+Environment.GetEnvironmentVariable("FM_PROBE_SESSION"));
                int unknown=OwnerClient("alive",state,"native:00000000000000000000000000000000");
                if(live!=0 || unknown!=2) throw new IOException("Liveness classification failed");
                int verb=OwnerClient("unregistered-verb",state,"");
                if(verb!=2) throw new IOException("Unknown verb granted");
                File.WriteAllText(Path.Combine(Environment.GetEnvironmentVariable("FM_PROBE_HOME"),"owner-operation.complete"),Json.Serialize(new {live=live,unknown=unknown,forbiddenVerb=verb}));
                return 0;
            }
            if(args.Length>0 && args[0]=="bounded-fixture") {
                string home=Environment.GetEnvironmentVariable("FM_PROBE_HOME");
                DateTime limit=DateTime.UtcNow.AddSeconds(260);
                while(!File.Exists(Path.Combine(home,"owner-operation.complete")) && DateTime.UtcNow<limit) {
                    string outcome=Path.Combine(home,"firstmate-owner-operation.json");
                    if(File.Exists(outcome)) {
                        var recorded=Json.Deserialize<Dictionary<string,object>>(File.ReadAllText(outcome));
                        if(Convert.ToInt32(recorded["exit"])!=0) throw new IOException("Real startup operation failed; see startup.log");
                    }
                    Thread.Sleep(25);
                }
                if(!File.Exists(Path.Combine(home,"owner-operation.complete"))) throw new IOException("Owner operation did not complete");
                RunFirstmate("unregistered",false);
                while(!File.Exists(Path.Combine(home,"boundaries-done")) && DateTime.UtcNow<limit) Thread.Sleep(25);
                if(!File.Exists(Path.Combine(home,"boundaries-done"))) throw new IOException("Boundary operations did not complete");
                return 0;
            }
            if(args.Length>0 && args[0]=="fixture") return Fixture();
            if(args.Length==2 && args[0]=="owner-fixture") { Client("scope-"+args[1]); RunFirstmate(args[1],false); return 0; }
            if(args.Length==2 && args[0]=="scoped-client") {
                Client("scope-"+args[1]);
                bool exercise=Environment.GetEnvironmentVariable("FM_PROBE_EXERCISE")=="1";
                if(exercise) RunFirstmate(args[1],false);
                var descendant=Process.Start(new ProcessStartInfo(OwnExe,(exercise ? "owner-fixture " : "client scope-")+args[1]+"-descendant") { UseShellExecute=false });
                descendant.WaitForExit(); return descendant.ExitCode;
            }
            if(args.Length==2 && args[0]=="run") return Run(args[1]);
            Console.Error.WriteLine("usage: NativeOwner run <config.json> | client [case] | fixture"); return 2;
        } catch(Exception e) { Console.Error.WriteLine(e.ToString()); return 2; }
    }
}
