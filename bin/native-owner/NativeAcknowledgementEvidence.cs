using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Web.Script.Serialization;

public sealed class NativeAcknowledgementEvidence {
    internal readonly NativeHomeLease Lease;
    readonly string record;
    NativeAcknowledgementEvidence(NativeHomeLease lease,string value) { Lease=lease;record=value; }
    internal object Record() { return record; }
    static int Invoke(NativeHomeLease lease,string mode,string input,out string output) {
        if(lease==null || !lease.IsHeld)throw new InvalidOperationException("An active home lease is required");
        string script=Path.Combine(NativeOwner.CodeRoot,"bin","native-owner","ack-evidence.sh");
        var start=NativeOwner.BashHelper(script,mode,lease.Home);
        start.RedirectStandardInput=true;start.RedirectStandardOutput=true;start.RedirectStandardError=true;
        using(var process=Process.Start(start)) {
            var stdout=process.StandardOutput.ReadToEndAsync();var stderr=process.StandardError.ReadToEndAsync();
            if(input!=null)process.StandardInput.Write(input);
            process.StandardInput.Close();
            if(!process.WaitForExit(30000)){process.Kill();throw new TimeoutException("Acknowledgement evidence owner exceeded its bound");}
            output=stdout.Result.Trim();
            if(process.ExitCode!=0 && mode!="verify-token" && mode!="verify-legacy")throw new IOException("Acknowledgement evidence owner refused the target: "+stderr.Result.Trim());
            return process.ExitCode;
        }
    }
    public static NativeAcknowledgementEvidence Capture(NativeHomeLease lease,Dictionary<string,object> payload) {
        if(payload==null)throw new IOException("Notification payload is incomplete");
        object value;string opaque=null,output;
        if(payload.TryGetValue("ownerEvidence",out value))opaque=value as string;
        if(string.IsNullOrEmpty(opaque))throw new IOException("Acknowledgement evidence is missing");
        if(Invoke(lease,"preflight-token",opaque,out output)!=0)throw new IOException("Acknowledgement evidence no longer matches its owner target");
        return new NativeAcknowledgementEvidence(lease,opaque);
    }
    internal static bool Completed(NativeHomeLease lease,object evidence) {
        if(lease==null || !lease.IsHeld || evidence==null)return false;
        try {
            string output;
            string opaque=evidence as string;
            if(opaque!=null)return Invoke(lease,"verify-token",opaque,out output)==0;
            var json=new JavaScriptSerializer();
            return Invoke(lease,"verify-legacy",json.Serialize(evidence),out output)==0;
        } catch(IOException){return false;} catch(UnauthorizedAccessException){return false;}
        catch(Win32Exception){return false;}
        catch(ArgumentException){return false;} catch(InvalidOperationException){return false;}
        catch(FormatException){return false;} catch(OverflowException){return false;}
        catch(TimeoutException){return false;}
    }
}
