using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Text;
using System.Web.Script.Serialization;
public static class ReceiptTests {
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateHardLink(string link,string target,IntPtr security);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] [return: MarshalAs(UnmanagedType.I1)] static extern bool CreateSymbolicLink(string link,string target,uint flags);
    static readonly string A=new string('a',32),B=new string('b',32);
    static readonly JavaScriptSerializer Json=new JavaScriptSerializer();
    static int passed;
    static Dictionary<string,object> Payload(string value) { return new Dictionary<string,object>{{"challenge",value},{"message","pending notification"},{"seq","1"},{"generation","recovery"},{"note","note-id"}}; }
    static void Expect(bool value,string message) { if(!value) throw new Exception(message); }
    static void Refuses(Action action,string message) { bool refused=false;try{action();}catch{refused=true;}Expect(refused,message); }
    static void Case(string name,Action<NativeHomeLease> test) {
        string home=Path.Combine(Path.GetTempPath(),"fm-receipts-"+Guid.NewGuid().ToString("N"));
        using(var lease=new NativeHomeLease(home)) test(lease);
        passed++;Console.WriteLine("PASS: "+name);
    }
    static void OwnerProbeLinkCase() {
        string root=Path.Combine(Path.GetTempPath(),"fm-owner-link-"+Guid.NewGuid().ToString("N")),home=Path.Combine(root,"home"),external=Path.Combine(root,"external-owner.json"),owner=Path.Combine(home,"owner-probe.json");
        Directory.CreateDirectory(home);
        string body=Json.Serialize(new Dictionary<string,object>{{"deadGenerations",new string[0]},{"state","live"},{"rootPid",uint.MaxValue},{"rootCreationFileTime",0L},{"generation",A},{"pipe","unreachable"},{"controllerPid",uint.MaxValue},{"controllerCreated",0L}});
        File.WriteAllText(external,body);Expect(CreateHardLink(owner,external,IntPtr.Zero),"Owner hard-link fixture failed");
        Refuses(()=>{using(var lease=new NativeHomeLease(home)){}},"Hard-linked owner record accepted");
        Expect(File.ReadAllText(external)==body,"Hard-linked external owner record changed");
        passed++;Console.WriteLine("PASS: hard-linked owner record is preserved and refused");
    }
    static string Queue(NativeHomeLease lease) { return Path.Combine(lease.Home,"state",".wake-queue"); }
    static string CompletionHistory(NativeHomeLease lease) { return Path.Combine(lease.Home,"state",".watcher-down.ack-completions"); }
    static string Pending(NativeHomeLease lease) { return Path.Combine(lease.Home,"state","inbox","note-id.note"); }
    static string Handled(NativeHomeLease lease) { return Path.Combine(lease.Home,"state","inbox","handled","note-id.note"); }
    static string ReadJournal(NativeHomeLease lease) {
        using(var stream=new FileStream(Path.Combine(lease.Home,"owner-receipts.jsonl"),FileMode.Open,FileAccess.Read,FileShare.ReadWrite))
        using(var reader=new StreamReader(stream,Encoding.UTF8,true)) return reader.ReadToEnd();
    }
    static void Targets(NativeHomeLease lease,string note="note-id",string generation="recovery") {
        Directory.CreateDirectory(Path.GetDirectoryName(Handled(lease)));
        File.WriteAllText(Path.Combine(lease.Home,"state","inbox",note+".note"),"original captured inbox record\n");
        File.WriteAllText(Queue(lease),"1\t1\tcheck\tinbox:"+note+"\tcaptain inbox note\n");
        File.WriteAllText(Path.Combine(lease.Home,"state",".wake-queue.seq"),"1\n");
        File.WriteAllText(Path.Combine(lease.Home,"state",".main-eligible-rows"),"1\n");
        File.WriteAllText(Path.Combine(lease.Home,"state",".watcher-down"),"pending:handling:"+generation+"\n");
    }
    static string ZeroRecovery(NativeHomeLease lease,string action,string generation=null) {
        string script=Path.Combine(NativeOwner.CodeRoot,"tests","fixtures","native-owner","zero-recovery.sh");
        string arguments=action+" \""+lease.Home.Replace("\"","\\\"")+"\""+(generation==null ? "" : " \""+generation.Replace("\"","\\\"")+"\"");
        var start=NativeOwner.BashHelper(script,arguments,lease.Home);start.RedirectStandardOutput=true;start.RedirectStandardError=true;
        using(var process=Process.Start(start)) {
            var output=process.StandardOutput.ReadToEndAsync();var error=process.StandardError.ReadToEndAsync();
            if(!process.WaitForExit(30000)){process.Kill();throw new IOException("Zero-recovery fixture exceeded its bound");}
            if(process.ExitCode!=0)throw new IOException("Zero-recovery fixture failed: "+error.Result);
            return output.Result.Trim();
        }
    }
    static Dictionary<string,object> OwnerPayload(NativeHomeLease lease,string challenge) {
        string script=Path.Combine(NativeOwner.CodeRoot,"bin","native-owner","ack-evidence.sh");
        var start=NativeOwner.BashHelper(script,"capture-json",lease.Home);start.RedirectStandardOutput=true;start.RedirectStandardError=true;
        using(var process=Process.Start(start)) {
            var output=process.StandardOutput.ReadToEndAsync();var error=process.StandardError.ReadToEndAsync();
            if(!process.WaitForExit(30000)){process.Kill();throw new IOException("Acknowledgement target fixture exceeded its bound");}
            if(process.ExitCode!=0)throw new IOException("Acknowledgement target fixture exited "+process.ExitCode+": "+error.Result+output.Result);
            var payload=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(output.Result);
            payload["challenge"]=challenge;payload["message"]="pending notification";
            return payload;
        }
    }
    static void OwnerAcknowledge(NativeHomeLease lease,Dictionary<string,object> payload) {
        string script=Path.Combine(NativeOwner.CodeRoot,"bin","native-owner","ack-evidence.sh"),opaque=(string)payload["ownerEvidence"];
        var start=NativeOwner.BashHelper(script,"acknowledge-token",lease.Home);start.RedirectStandardInput=true;start.RedirectStandardOutput=true;start.RedirectStandardError=true;
        using(var process=Process.Start(start)) {
            var output=process.StandardOutput.ReadToEndAsync();var error=process.StandardError.ReadToEndAsync();
            process.StandardInput.Write(opaque);process.StandardInput.Close();
            if(!process.WaitForExit(30000)){process.Kill();throw new IOException("Acknowledgement owner exceeded its bound");}
            if(process.ExitCode!=0)throw new IOException("Acknowledgement owner refused its captured target: "+error.Result+output.Result);
        }
    }
    static string Completion(Dictionary<string,object> payload) {
        return Json.Serialize(new Dictionary<string,object>{{"acknowledged",true},{"ownerEvidence",payload["ownerEvidence"]}});
    }
    static void Acknowledge(NativeHomeLease lease,NativeReceiptJournal journal,Dictionary<string,object> delivery,string observed) {
        string receipt=(string)delivery["receipt"];
        journal.BeginAcknowledgement(receipt,observed,NativeAcknowledgementEvidence.Capture(lease,delivery));
        OwnerAcknowledge(lease,delivery);
        journal.CompleteAcknowledgement(receipt,Completion(delivery));
    }
    static Dictionary<string,object> ZeroPayload(NativeHomeLease lease) {
        string[] target=ZeroRecovery(lease,"present").Split('\t');
        Expect(target.Length==2 && target[0]=="0","Real recovery owner did not produce a zero-row target");
        var payload=OwnerPayload(lease,"zero");
        Expect((string)payload["seq"]==target[0] && (string)payload["generation"]==target[1],"Owner evidence did not bind the recovery target");
        payload["message"]="recovery";return payload;
    }
    public static int Run() {
        OwnerProbeLinkCase();
        Case("validated acknowledgement evidence survives scratch cleanup failure",lease=>{
            Targets(lease);
            var payload=OwnerPayload(lease,"cleanup-failure");
            ZeroRecovery(lease,"load-cleanup-failure",(string)payload["ownerEvidence"]);
        });
        Case("one writer and unobserved acknowledgement refusal",lease=>{
            Targets(lease);
            using(var journal=new NativeReceiptJournal(lease,A)) {
                Refuses(()=>{using(var other=new NativeReceiptJournal(lease,A)){}},"Concurrent writer accepted");
                var note=journal.Present(OwnerPayload(lease,"first"));string receipt=(string)note["receipt"];
                Refuses(()=>journal.BeginAcknowledgement(receipt,"wrong"),"Unobserved message accepted");
                Acknowledge(lease,journal,note,"first");
                Refuses(()=>journal.BeginAcknowledgement(receipt,"first"),"Consumed receipt accepted");
            }
        });
        Case("pending delivery survives reopen and is not replaced",lease=>{
            string receipt;
            using(var journal=new NativeReceiptJournal(lease,A)) receipt=(string)journal.Present(Payload("first"))["receipt"];
            using(var journal=new NativeReceiptJournal(lease,A)) {
                var replay=journal.Present(Payload("second"));Expect((string)replay["receipt"]==receipt && (string)replay["challenge"]=="first","Pending work replaced");
            }
        });
        Case("new generation cannot consume predecessor receipt",lease=>{
            string old;
            using(var journal=new NativeReceiptJournal(lease,A)) old=(string)journal.Present(Payload("first"))["receipt"];
            using(var journal=new NativeReceiptJournal(lease,B)) {
                Refuses(()=>journal.BeginAcknowledgement(old,"first"),"Previous generation authorized");
                Expect((string)journal.Present(Payload("first"))["receipt"]!=old,"Receipt reused across generation");
            }
        });
        Case("interrupted acknowledgement blocks fresh mutation",lease=>{
            string receipt;
            using(var journal=new NativeReceiptJournal(lease,A)) {receipt=(string)journal.Present(Payload("first"))["receipt"];journal.BeginAcknowledgement(receipt,"first");}
            using(var journal=new NativeReceiptJournal(lease,B)) {
                Expect(journal.NeedsReconciliation,"Interrupted attempt lost");
                Refuses(()=>journal.Present(Payload("second")),"New work replaced ambiguous attempt");
                Refuses(()=>journal.CompleteAcknowledgement(receipt,null),"New generation invented completion");
            }
        });
        Case("completed receipt remains consumed after restart",lease=>{
            Targets(lease);string receipt;
            using(var journal=new NativeReceiptJournal(lease,A)) {var delivery=journal.Present(OwnerPayload(lease,"first"));receipt=(string)delivery["receipt"];Acknowledge(lease,journal,delivery,"first");}
            using(var journal=new NativeReceiptJournal(lease,B)) {
                Expect(!journal.NeedsReconciliation,"Completed attempt became ambiguous");
                Refuses(()=>journal.BeginAcknowledgement(receipt,"first"),"Completed predecessor replay accepted");
                journal.Present(Payload("second"));
            }
        });
        Case("multiple cycles retain independent consumed receipts",lease=>{
            Targets(lease);
            using(var journal=new NativeReceiptJournal(lease,A)) {
                var firstDelivery=journal.Present(OwnerPayload(lease,"first"));string first=(string)firstDelivery["receipt"];
                Acknowledge(lease,journal,firstDelivery,"first");Targets(lease,"second-note","recovery-second");
                var secondDelivery=journal.Present(OwnerPayload(lease,"second"));string second=(string)secondDelivery["receipt"];
                Refuses(()=>journal.BeginAcknowledgement(first,"first"),"Earlier cycle replay accepted");
                Acknowledge(lease,journal,secondDelivery,"second");
            }
        });
        Case("zero-exit completion requires exact affirmative owner evidence",lease=>{
            Targets(lease);
            using(var journal=new NativeReceiptJournal(lease,A)) {
                var delivery=journal.Present(OwnerPayload(lease,"first"));string receipt=(string)delivery["receipt"],evidence=(string)delivery["ownerEvidence"];
                journal.BeginAcknowledgement(receipt,"first",NativeAcknowledgementEvidence.Capture(lease,delivery));
                string before=ReadJournal(lease);
                Refuses(()=>journal.CompleteAcknowledgement(receipt,null),"Missing zero-exit response completed an acknowledgement");
                Refuses(()=>journal.CompleteAcknowledgement(receipt,"{broken"),"Malformed zero-exit response completed an acknowledgement");
                Refuses(()=>journal.CompleteAcknowledgement(receipt,Json.Serialize(new Dictionary<string,object>{{"acknowledged",true},{"ownerEvidence","mismatch"}})),"Mismatched zero-exit response completed an acknowledgement");
                Refuses(()=>journal.CompleteAcknowledgement(receipt,Json.Serialize(new Dictionary<string,object>{{"acknowledged",false},{"ownerEvidence",evidence}})),"Negative zero-exit response completed an acknowledgement");
                Refuses(()=>journal.CompleteAcknowledgement(receipt,Completion(delivery)),"Unperformed effect completed from response data alone");
                Expect(before==ReadJournal(lease),"Rejected completion response changed the journal");
                OwnerAcknowledge(lease,delivery);journal.CompleteAcknowledgement(receipt,Completion(delivery));
                Expect(!journal.NeedsReconciliation,"Affirmatively proven completion remained unresolved");
            }
        });
        Case("returned objects cannot change persisted target",lease=>{
            using(var journal=new NativeReceiptJournal(lease,A)) {
                var source=Payload("first");var result=journal.Present(source);source["challenge"]="changed";result["challenge"]="changed";
                var actual=journal.BeginAcknowledgement((string)result["receipt"],"first");Expect((string)actual["challenge"]=="first","Caller changed target");
            }
        });
        Case("torn tail is preserved rather than skipped",lease=>{
            using(var journal=new NativeReceiptJournal(lease,A)) journal.Present(Payload("first"));
            string file=Path.Combine(lease.Home,"owner-receipts.jsonl");File.AppendAllText(file,"{\"version\":1");string before=File.ReadAllText(file);
            Refuses(()=>{using(var journal=new NativeReceiptJournal(lease,B)){}},"Torn record accepted");Expect(before==File.ReadAllText(file),"Torn record changed");
        });
        Case("empty existing file is not adopted",lease=>{
            using(var journal=new NativeReceiptJournal(lease,A)) {}
            string file=Path.Combine(lease.Home,"owner-receipts.jsonl");File.WriteAllText(file,"");
            Refuses(()=>{using(var journal=new NativeReceiptJournal(lease,A)){}},"Empty journal adopted");Expect(new FileInfo(file).Length==0,"Ambiguous file overwritten");
        });
        Case("hard-linked receipt file is refused",lease=>{
            using(var journal=new NativeReceiptJournal(lease,A)) journal.Present(Payload("first"));
            string file=Path.Combine(lease.Home,"owner-receipts.jsonl");
            Expect(CreateHardLink(Path.Combine(lease.Home,"alias"),file,IntPtr.Zero),"Hard-link fixture failed");
            Refuses(()=>{using(var journal=new NativeReceiptJournal(lease,A)){}},"Hard-linked receipt accepted");
        });
        Case("symbolic receipt file is refused",lease=>{
            using(var journal=new NativeReceiptJournal(lease,A)) journal.Present(Payload("first"));
            string file=Path.Combine(lease.Home,"owner-receipts.jsonl"),target=Path.Combine(lease.Home,"target");File.Move(file,target);
            Expect(CreateSymbolicLink(file,target,2),"Symlink fixture requires Windows Developer Mode");
            Refuses(()=>{using(var journal=new NativeReceiptJournal(lease,A)){}},"Symbolic receipt accepted");
        });
        Case("released home lease revokes journal operations",lease=>{
            using(var journal=new NativeReceiptJournal(lease,A)) {
                var note=journal.Present(Payload("first"));lease.Dispose();
                Refuses(()=>journal.BeginAcknowledgement((string)note["receipt"],"first"),"Released lease authorized mutation");
            }
        });
        foreach(string scenario in new [] {"complete","newer","pending","note-only","wake-only","changed-note","missing-queue","malformed-queue","old-row-remains","no-evidence","duplicate-pending","reparse-handled"}) {
            Case("interrupted recovery: "+scenario,lease=>{
                Targets(lease);string receipt;
                using(var journal=new NativeReceiptJournal(lease,A)) {
                    var delivery=journal.Present(OwnerPayload(lease,"first"));receipt=(string)delivery["receipt"];
                    var evidence=scenario=="no-evidence" ? null : NativeAcknowledgementEvidence.Capture(lease,delivery);
                    journal.BeginAcknowledgement(receipt,"first",evidence);
                }
                if(scenario!="pending" && scenario!="wake-only") File.Move(Pending(lease),Handled(lease));
                if(scenario!="pending" && scenario!="note-only") File.WriteAllText(Queue(lease),"");
                if(scenario=="newer") File.WriteAllText(Queue(lease),"2\t2\tcheck\tnew-work\tuntouched\n");
                if(scenario=="changed-note") File.AppendAllText(Handled(lease),"changed");
                if(scenario=="missing-queue") File.Delete(Queue(lease));
                if(scenario=="malformed-queue") File.WriteAllText(Queue(lease),"torn");
                if(scenario=="old-row-remains") File.WriteAllText(Queue(lease),"1\t1\tcheck\tdifferent-key\tunknown\n");
                if(scenario=="duplicate-pending") File.Copy(Handled(lease),Pending(lease));
                if(scenario=="reparse-handled") {
                    string original=Path.GetDirectoryName(Handled(lease)),other=Path.Combine(lease.Home,"other-handled");Directory.Move(original,other);
                    Expect(CreateSymbolicLink(original,other,3),"Directory symlink fixture failed");
                }
                string before=File.Exists(Queue(lease)) ? File.ReadAllText(Queue(lease)) : null;
                bool complete=scenario=="complete" || scenario=="newer";
                using(var journal=new NativeReceiptJournal(lease,B)) {
                    Expect(journal.ReconcileCompletedAcknowledgements()==(complete ? 1 : 0),"Incorrect recovery classification: "+scenario);
                    Expect(journal.NeedsReconciliation!=complete,"Incorrect reconciliation obligation");
                    Refuses(()=>journal.BeginAcknowledgement(receipt,"first"),"Old receipt became reusable");
                    Expect(journal.ReconcileCompletedAcknowledgements()==0,"Recovery replay changed history");
                }
                using(var journal=new NativeReceiptJournal(lease,B)) Expect(journal.NeedsReconciliation!=complete,"Recovery result did not survive reopening");
                Expect(before==(File.Exists(Queue(lease)) ? File.ReadAllText(Queue(lease)) : null),"Recovery mutated wake data");
            });
        }
        Case("acknowledgement evidence cannot cross homes",lease=>{
            Targets(lease);
            string otherHome=Path.Combine(Path.GetTempPath(),"fm-receipts-other-"+Guid.NewGuid().ToString("N"));
            using(var other=new NativeHomeLease(otherHome)) using(var journal=new NativeReceiptJournal(lease,A)) {
                Targets(other);var delivery=journal.Present(OwnerPayload(other,"first"));
                var evidence=NativeAcknowledgementEvidence.Capture(other,delivery);
                Refuses(()=>journal.BeginAcknowledgement((string)delivery["receipt"],"first",evidence),"Foreign home evidence accepted");
                Expect(!journal.NeedsReconciliation,"Rejected evidence created an attempt");
            }
        });
        foreach(string scenario in new [] {"no-inbox-targets","multiple-complete","multiple-partial"}) {
            Case("general wake recovery: "+scenario,lease=>{
                Targets(lease);
                if(scenario=="no-inbox-targets") {
                    File.WriteAllText(Queue(lease),"1\t1\tcheck\tdiagnostic\treport\n");
                } else {
                    File.WriteAllText(Path.Combine(lease.Home,"state","inbox","second.note"),"second notification");
                    File.AppendAllText(Queue(lease),"2\t2\tcheck\tinbox:second\tsecond\n");
                    File.WriteAllText(Path.Combine(lease.Home,"state",".main-eligible-rows"),"1\n2\n");
                }
                using(var journal=new NativeReceiptJournal(lease,A)) {
                    var delivery=journal.Present(OwnerPayload(lease,"general"));
                    journal.BeginAcknowledgement((string)delivery["receipt"],"general",NativeAcknowledgementEvidence.Capture(lease,delivery));
                }
                if(scenario!="no-inbox-targets") {
                    File.Move(Pending(lease),Handled(lease));
                    if(scenario=="multiple-complete")File.Move(Path.Combine(lease.Home,"state","inbox","second.note"),Path.Combine(lease.Home,"state","inbox","handled","second.note"));
                }
                File.WriteAllText(Queue(lease),"");
                using(var journal=new NativeReceiptJournal(lease,B)) Expect(journal.ReconcileCompletedAcknowledgements()==(scenario=="multiple-partial"?0:1),"Incorrect general-wake recovery");
                if(scenario=="no-inbox-targets")Expect(File.Exists(Pending(lease)),"Unrelated inbox note was consumed");
            });
        }
        foreach(string timing in new [] {"before-capture","after-ack-started"}) {
            Case("concurrent wake remains pending: "+timing,lease=>{
                Targets(lease);
                if(timing=="before-capture")ZeroRecovery(lease,"append");
                using(var journal=new NativeReceiptJournal(lease,A)) {
                    var delivery=journal.Present(OwnerPayload(lease,"concurrent"));string receipt=(string)delivery["receipt"],generation=(string)delivery["generation"];
                    var evidence=NativeAcknowledgementEvidence.Capture(lease,delivery);
                    journal.BeginAcknowledgement(receipt,"concurrent",evidence);
                    if(timing=="after-ack-started")ZeroRecovery(lease,"append");
                    Expect(File.ReadAllText(Path.Combine(lease.Home,"state",".watcher-down")).Contains(":"+generation+"\n"),"Concurrent wake changed the recovery generation");
                    OwnerAcknowledge(lease,delivery);journal.CompleteAcknowledgement(receipt,Completion(delivery));
                }
                string queue=File.ReadAllText(Queue(lease));
                Expect(queue.Contains("later-notification")&&!queue.Contains("inbox:note-id"),"Acknowledgement did not retain only the later wake");
                Expect(!File.Exists(Pending(lease))&&File.ReadAllText(Handled(lease))=="original captured inbox record\n","Acknowledgement did not consume exactly the captured note");
            });
        }
        Case("zero-row recovery rejects an unproven empty target",lease=>{
            Directory.CreateDirectory(Path.GetDirectoryName(Queue(lease)));File.WriteAllText(Queue(lease),"");
            var payload=new Dictionary<string,object>{{"challenge","zero"},{"message","recovery"},{"seq","0"},{"generation","missing"},{"notes",new string[0]}};
            using(var journal=new NativeReceiptJournal(lease,A)) {
                var delivery=journal.Present(payload);
                Refuses(()=>NativeAcknowledgementEvidence.Capture(lease,delivery),"Arbitrary empty target accepted");
                Expect(!journal.NeedsReconciliation,"Rejected empty target created an attempt");
            }
        });
        Case("zero-row recovery rejects a mismatched generation",lease=>{
            var payload=ZeroPayload(lease);string generation=(string)payload["generation"];
            ZeroRecovery(lease,"acknowledge",generation);
            ZeroRecovery(lease,"append");
            using(var journal=new NativeReceiptJournal(lease,A)) {
                var delivery=journal.Present(payload);
                Refuses(()=>NativeAcknowledgementEvidence.Capture(lease,delivery),"Foreign recovery generation accepted");
            }
        });
        Case("zero-row recovery interruption preserves the obligation",lease=>{
            var payload=ZeroPayload(lease);string receipt;
            using(var journal=new NativeReceiptJournal(lease,A)) {
                var delivery=journal.Present(payload);receipt=(string)delivery["receipt"];
                journal.BeginAcknowledgement(receipt,"zero",NativeAcknowledgementEvidence.Capture(lease,delivery));
            }
            string marker=File.ReadAllText(Path.Combine(lease.Home,"state",".watcher-down"));
            using(var journal=new NativeReceiptJournal(lease,B)) {
                Expect(journal.ReconcileCompletedAcknowledgements()==0,"Unperformed recovery target was invented");
                Expect(journal.NeedsReconciliation,"Interrupted recovery target was lost");
            }
            Expect(File.ReadAllText(Queue(lease))=="","Interrupted recovery changed the queue");
            Expect(marker==File.ReadAllText(Path.Combine(lease.Home,"state",".watcher-down")),"Interrupted recovery rolled back the target");
        });
        Case("completed zero-row recovery reconciles without replay",lease=>{
            var payload=ZeroPayload(lease);string receipt,generation=(string)payload["generation"];
            using(var journal=new NativeReceiptJournal(lease,A)) {
                var delivery=journal.Present(payload);receipt=(string)delivery["receipt"];
                journal.BeginAcknowledgement(receipt,"zero",NativeAcknowledgementEvidence.Capture(lease,delivery));
            }
            ZeroRecovery(lease,"acknowledge",generation);
            ZeroRecovery(lease,"append");
            string queue=File.ReadAllText(Queue(lease)),marker=File.ReadAllText(Path.Combine(lease.Home,"state",".watcher-down"));
            using(var journal=new NativeReceiptJournal(lease,B)) {
                Expect(journal.ReconcileCompletedAcknowledgements()==1,"Completed zero-row target was not reconciled");
                Expect(!journal.NeedsReconciliation,"Completed zero-row target remained ambiguous");
                Expect(journal.ReconcileCompletedAcknowledgements()==0,"Completed zero-row target replayed");
            }
            Expect(queue==File.ReadAllText(Queue(lease)) && marker==File.ReadAllText(Path.Combine(lease.Home,"state",".watcher-down")),"Reconciliation changed completed effects");
            Expect(queue.Contains("later-notification"),"A later notification was not kept pending");
        });
        Case("zero-row completion capacity preserves current proof",lease=>{
            Directory.CreateDirectory(Path.GetDirectoryName(Queue(lease)));File.WriteAllText(Queue(lease),"");
            File.WriteAllText(Path.Combine(lease.Home,"state",".watcher-down"),"acked:handling:capacity-current\n");
            var history=new StringBuilder("fm-wake-ack-completions-v1\n");
            for(int i=0;i<1024;i++)history.Append("stored-").Append(i).Append('\n');
            File.WriteAllText(CompletionHistory(lease),history.ToString());
            string marker=File.ReadAllText(Path.Combine(lease.Home,"state",".watcher-down"));
            Refuses(()=>ZeroRecovery(lease,"append"),"A full completion history allowed proof replacement");
            Expect(marker==File.ReadAllText(Path.Combine(lease.Home,"state",".watcher-down")) && File.ReadAllText(Queue(lease))=="","Capacity refusal changed current proof or queued new work");
        });
        Case("malformed zero-row completion history preserves current proof",lease=>{
            Directory.CreateDirectory(Path.GetDirectoryName(Queue(lease)));File.WriteAllText(Queue(lease),"");
            File.WriteAllText(Path.Combine(lease.Home,"state",".watcher-down"),"acked:handling:malformed-current\n");
            File.WriteAllText(CompletionHistory(lease),"unrecognized\n");
            string marker=File.ReadAllText(Path.Combine(lease.Home,"state",".watcher-down"));
            Refuses(()=>ZeroRecovery(lease,"append"),"Malformed completion history allowed proof replacement");
            Expect(marker==File.ReadAllText(Path.Combine(lease.Home,"state",".watcher-down")) && File.ReadAllText(Queue(lease))=="","Malformed-history refusal changed current proof or queued new work");
        });
        Console.WriteLine("RECEIPT_TESTS_PASS "+passed);return 0;
    }
}
