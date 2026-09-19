// Durable receipt transitions for a controller that already holds the home lease.
// This is not an authority source: only the authenticated controller may call it.
// Append and flush intent before mutation; ambiguous attempts require reconciliation.
using System;
using System.Collections.Generic;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Web.Script.Serialization;

public sealed class NativeReceiptJournal : IDisposable {
    readonly JavaScriptSerializer json = new JavaScriptSerializer();
    readonly Dictionary<string, Dictionary<string,object>> receipts = new Dictionary<string, Dictionary<string,object>>();
    readonly string home, generation;
    readonly NativeHomeLease lease;
    object latestAcknowledgementEvidence;
    FileStream file;
    const long Limit = 16 * 1024 * 1024;
    NativeReceiptJournal(string selectedHome) {
        home=Path.GetFullPath(selectedHome).TrimEnd('\\','/');
    }
    void Load(FileStream stream) {
        if(stream.Length>Limit || stream.Length==0) throw new IOException("Receipt journal is empty or oversized; preserved");
        string content;
        stream.Position=0;
        using(var reader=new StreamReader(stream,new UTF8Encoding(false,true),true,4096,true)) content=reader.ReadToEnd();
        if(!content.EndsWith("\n",StringComparison.Ordinal)) throw new IOException("Interrupted receipt record; preserved");
        foreach(string line in content.Split(new [] {'\n'},StringSplitOptions.RemoveEmptyEntries)) Apply(json.Deserialize<Dictionary<string,object>>(line));
    }
    public static object AdmissionEvidence(string selectedHome) {
        string home=Path.GetFullPath(selectedHome).TrimEnd('\\','/'),name=Path.Combine(home,"owner-receipts.jsonl");
        FileAttributes attributes;
        try { attributes=File.GetAttributes(name); }
        catch(FileNotFoundException) { return null; }
        catch(DirectoryNotFoundException) { return null; }
        if((attributes&FileAttributes.ReparsePoint)!=0 || (attributes&FileAttributes.Directory)!=0) throw new IOException("Receipt journal path is unsafe; preserved");
        var parser=new NativeReceiptJournal(home);
        using(var stream=new FileStream(name,FileMode.Open,FileAccess.Read,FileShare.ReadWrite)) {
            NativeHomeLease.ValidateFile(stream,WindowsIdentity.GetCurrent().User,"Receipt journal");
            parser.Load(stream);
        }
        return parser.latestAcknowledgementEvidence;
    }
    public NativeReceiptJournal(NativeHomeLease ownedLease, string ownerGeneration) {
        if(ownedLease==null || !ownedLease.IsHeld) throw new InvalidOperationException("An active native home lease is required");
        lease=ownedLease;
        if(ownerGeneration==null || ownerGeneration.Length!=32 || !IsHex(ownerGeneration)) throw new ArgumentException("Invalid owner generation");
        home=Path.GetFullPath(ownedLease.Home).TrimEnd('\\','/'); generation=ownerGeneration;
        // The native home lease owns directory validation and exclusion. Never
        // create a directory or select another home based on tool arguments.
        if(!Directory.Exists(home)) throw new IOException("Owned home is absent");
        string name=Path.Combine(home,"owner-receipts.jsonl");
        var security=new FileSecurity();security.SetAccessRuleProtection(true,false);
        var user=WindowsIdentity.GetCurrent().User;
        security.SetOwner(user);
        security.AddAccessRule(new FileSystemAccessRule(user,FileSystemRights.FullControl,AccessControlType.Allow));
        bool created=false;
        try {
            try { file=new FileStream(name,FileMode.CreateNew,FileSystemRights.Read|FileSystemRights.Write,FileShare.Read,4096,FileOptions.None,security);created=true; }
            catch(IOException) {
                if((File.GetAttributes(name)&FileAttributes.ReparsePoint)!=0) throw new IOException("Receipt journal is a reparse point");
                file=new FileStream(name,FileMode.Open,FileSystemRights.Read|FileSystemRights.Write,FileShare.Read,4096,FileOptions.None,security);
            }
            NativeHomeLease.ValidateFile(file,user,"Receipt journal");
            if(!created) Load(file);
            Append("session",null,null);
        } catch { Dispose();throw; }
    }
    static bool IsHex(string value) { foreach(char c in value) if(!(c>='0'&&c<='9')&&!(c>='a'&&c<='f')) return false;return true; }
    public bool NeedsReconciliation { get { foreach(var row in receipts.Values) if((string)row["event"]=="ack-started") return true;return false; } }
    Dictionary<string,object> Copy(Dictionary<string,object> value) { return json.Deserialize<Dictionary<string,object>>(json.Serialize(value)); }
    void EnsureOpen() { if(file==null || !lease.IsHeld) throw new InvalidOperationException("Receipt journal or owning lease is closed"); }
    public Dictionary<string,object> Present(Dictionary<string,object> payload) {
        EnsureOpen();
        if(NeedsReconciliation) throw new IOException("An acknowledgement was interrupted; reconcile durable work before proceeding");
        foreach(var row in receipts.Values) if((string)row["generation"]==generation && (string)row["event"]=="presented") return Delivery(row);
        if(payload==null || !payload.ContainsKey("challenge") || !(payload["challenge"] is string)) throw new ArgumentException("Notification payload is incomplete");
        string receipt=Guid.NewGuid().ToString("N");
        Append("presented",receipt,Copy(payload));
        return Delivery(receipts[receipt]);
    }
    Dictionary<string,object> Delivery(Dictionary<string,object> row) {
        var result=Copy((Dictionary<string,object>)row["payload"]);result["receipt"]=row["receipt"];return result;
    }
    public Dictionary<string,object> BeginAcknowledgement(string receipt,string observed,NativeAcknowledgementEvidence evidence=null) {
        EnsureOpen();
        Dictionary<string,object> row;
        if(NeedsReconciliation || receipt==null || !receipts.TryGetValue(receipt,out row) || (string)row["generation"]!=generation || (string)row["event"]!="presented") throw new InvalidOperationException("Receipt is not eligible");
        var payload=(Dictionary<string,object>)row["payload"];
        if((string)payload["challenge"]!=observed) throw new InvalidOperationException("Notification was not observed");
        if(evidence!=null && !object.ReferenceEquals(evidence.Lease,lease)) throw new InvalidOperationException("Evidence belongs to another home lease");
        Append("ack-started",receipt,Copy(payload),evidence==null ? null : evidence.Record());
        return Delivery(receipts[receipt]);
    }
    public void CompleteAcknowledgement(string receipt,string completion) {
        EnsureOpen();
        Dictionary<string,object> row;
        if(receipt==null || !receipts.TryGetValue(receipt,out row) || (string)row["generation"]!=generation || (string)row["event"]!="ack-started") throw new InvalidOperationException("No matching acknowledgement attempt");
        Dictionary<string,object> response;
        try { response=json.Deserialize<Dictionary<string,object>>(completion); }
        catch(Exception error) { throw new IOException("Acknowledgement completion response is malformed; preserved",error); }
        object acknowledged,responseEvidence;string evidence=Evidence(row) as string;
        if(response==null || !response.TryGetValue("acknowledged",out acknowledged) || !(acknowledged is bool) || !(bool)acknowledged || !response.TryGetValue("ownerEvidence",out responseEvidence) || !(responseEvidence is string) || string.IsNullOrEmpty(evidence) || (string)responseEvidence!=evidence) throw new IOException("Acknowledgement completion evidence does not match the persisted target; preserved");
        if(!NativeAcknowledgementEvidence.Completed(lease,evidence)) throw new IOException("Acknowledgement effect lacks affirmative owner evidence; preserved");
        Append("acknowledged",receipt,Copy((Dictionary<string,object>)row["payload"]),evidence);
    }
    static object Evidence(Dictionary<string,object> row) {
        object value;return row.TryGetValue("targetEvidence",out value) ? value : null;
    }
    public int ReconcileCompletedAcknowledgements() {
        EnsureOpen();
        var pending=new List<string>();
        foreach(var entry in receipts) if((string)entry.Value["event"]=="ack-started") pending.Add(entry.Key);
        int completed=0;
        foreach(string id in pending) {
            var previous=receipts[id];var evidence=Evidence(previous);
            if(!NativeAcknowledgementEvidence.Completed(lease,evidence)) continue;
            Append("recovered-acknowledged",id,Copy((Dictionary<string,object>)previous["payload"]),evidence,(string)previous["generation"]);
            completed++;
        }
        return completed;
    }
    void Append(string kind,string receipt,Dictionary<string,object> payload,object evidence=null,string ackGeneration=null) {
        var row=new Dictionary<string,object>{{"version",1},{"home",home},{"generation",generation},{"event",kind},{"receipt",receipt},{"payload",payload},{"targetEvidence",evidence},{"ackGeneration",ackGeneration}};
        byte[] bytes=new UTF8Encoding(false,true).GetBytes(json.Serialize(row)+"\n");
        if(bytes.Length>65536 || file.Length+bytes.Length>Limit) throw new IOException("Receipt journal capacity exceeded; durable work preserved");
        try { file.Position=file.Length;file.Write(bytes,0,bytes.Length);file.Flush(true);Apply(row); }
        catch { Dispose();throw; }
    }
    void Apply(Dictionary<string,object> row) {
        if(row==null || Convert.ToInt32(row["version"])!=1 || !string.Equals((string)row["home"],home,StringComparison.OrdinalIgnoreCase)) throw new IOException("Receipt journal binding is invalid");
        string gen=(string)row["generation"],kind=(string)row["event"];
        if(gen==null || gen.Length!=32 || !IsHex(gen)) throw new IOException("Invalid receipt generation");
        if(kind=="session") return;
        string id=(string)row["receipt"];
        if(id==null || id.Length!=32 || !IsHex(id) || !(row["payload"] is Dictionary<string,object>)) throw new IOException("Malformed receipt; preserved");
        Dictionary<string,object> previous;
        bool exists=receipts.TryGetValue(id,out previous);
        if(kind=="presented") { if(exists) throw new IOException("Duplicate receipt; preserved"); }
        else if(kind=="ack-started" || kind=="acknowledged") {
            string expected=kind=="ack-started" ? "presented" : "ack-started";
            if(!exists || (string)previous["event"]!=expected || (string)previous["generation"]!=gen || json.Serialize(previous["payload"])!=json.Serialize(row["payload"])) throw new IOException("Invalid receipt transition; preserved");
            if(kind=="acknowledged" && json.Serialize(Evidence(previous))!=json.Serialize(Evidence(row))) throw new IOException("Acknowledgement evidence changed; preserved");
        } else if(kind=="recovered-acknowledged") {
            if(!exists || (string)previous["event"]!="ack-started" || !row.ContainsKey("ackGeneration") || (string)row["ackGeneration"]!=(string)previous["generation"] || json.Serialize(previous["payload"])!=json.Serialize(row["payload"]) || Evidence(row)==null || json.Serialize(Evidence(previous))!=json.Serialize(Evidence(row))) throw new IOException("Invalid recovery transition; preserved");
        } else throw new IOException("Unknown receipt transition; preserved");
        receipts[id]=row;
        if(kind=="ack-started" || kind=="acknowledged" || kind=="recovered-acknowledged") latestAcknowledgementEvidence=Evidence(row);
    }
    public void Dispose() { if(file!=null) { file.Dispose();file=null; } }
}
