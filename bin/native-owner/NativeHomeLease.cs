// Experimental home reservation. The temporary-home restriction deliberately
// remains until the production lifecycle and path checks are validated.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Web.Script.Serialization;
public sealed class NativeHomeLease : IDisposable {
    static readonly JavaScriptSerializer Json=new JavaScriptSerializer();
    FileStream file;
    public readonly string Home;
    internal bool IsHeld { get { return file!=null; } }
    readonly HashSet<string> deadGenerations=new HashSet<string>();
    static bool Generation(string value) {
        if(value==null||value.Length!=32)return false;
        foreach(char c in value)if(!(c>='0'&&c<='9')&&!(c>='a'&&c<='f'))return false;
        return true;
    }
    public bool ProvenDeadGeneration(string value) { return IsHeld&&deadGenerations.Contains(value); }
    [StructLayout(LayoutKind.Sequential)] struct FT { public uint low,high; }
    [StructLayout(LayoutKind.Sequential)] struct Info {
        public uint attributes,createdLow,createdHigh,accessLow,accessHigh,writeLow,writeHigh;
        public uint volume,sizeHigh,sizeLow,links,indexHigh,indexLow;
    }
    [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,uint pid);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessTimes(IntPtr process,out FT created,out FT exited,out FT kernel,out FT user);
    [DllImport("kernel32.dll",SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle,uint milliseconds);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(IntPtr handle,out Info info);
    public static string ValidateHomePath(string home) {
        string full=Path.GetFullPath(home);
        string temporary=Path.GetFullPath(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"Temp")).TrimEnd('\\','/')+Path.DirectorySeparatorChar;
        if(!full.StartsWith(temporary,StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Experimental leases require a home beneath the user's Windows temporary directory");
        for(string parent=full;parent!=null;parent=Path.GetDirectoryName(parent)) {
            if(Directory.Exists(parent)&&(File.GetAttributes(parent)&FileAttributes.ReparsePoint)!=0) throw new InvalidOperationException("Reparse-point homes are not supported");
        }
        return full;
    }
    static string Filename(string home) { return Path.Combine(ValidateHomePath(home),"owner-probe.json"); }
    internal static void ValidateFile(FileStream stream,SecurityIdentifier user,string resource) {
        var access=stream.GetAccessControl();
        if(!access.AreAccessRulesProtected || !access.GetOwner(typeof(SecurityIdentifier)).Equals(user)) throw new IOException(resource+" security differs; preserved");
        foreach(FileSystemAccessRule rule in access.GetAccessRules(true,true,typeof(SecurityIdentifier))) if(rule.AccessControlType==AccessControlType.Allow && !rule.IdentityReference.Equals(user)) throw new IOException(resource+" grants unexpected access; preserved");
        Info info;
        if(!GetFileInformationByHandle(stream.SafeFileHandle.DangerousGetHandle(),out info) || info.links!=1 || (info.attributes&0x400)!=0) throw new IOException(resource+" file identity is unsafe; preserved");
    }
    static FileStream OpenExisting(string name,FileSystemRights rights,FileAccess access,FileShare share) {
        FileAttributes attributes=File.GetAttributes(name);
        if((attributes&FileAttributes.ReparsePoint)!=0 || (attributes&FileAttributes.Directory)!=0) throw new IOException("Owner record path is unsafe; preserved");
        FileStream stream=rights==0 ? new FileStream(name,FileMode.Open,access,share) : new FileStream(name,FileMode.Open,rights,share,4096,FileOptions.None);
        try { ValidateFile(stream,WindowsIdentity.GetCurrent().User,"Owner record");return stream; }
        catch { stream.Dispose();throw; }
    }
    static Dictionary<string,object> Read(Stream stream) {
        stream.Position=0;
        using(var reader=new StreamReader(stream,Encoding.UTF8,false,1024,true)) return Json.Deserialize<Dictionary<string,object>>(reader.ReadToEnd());
    }
    static bool RootAlive(Dictionary<string,object> record) {
        if(record==null || !record.ContainsKey("state") || (string)record["state"]!="live") throw new InvalidOperationException("Ambiguous or incomplete owner record; preserved");
        uint pid=Convert.ToUInt32(record["rootPid"]);
        if(pid==0) throw new InvalidOperationException("Invalid recorded owner");
        IntPtr handle=OpenProcess(0x1000|0x100000,false,pid);
        if(handle==IntPtr.Zero) {
            int error=Marshal.GetLastWin32Error();
            if(error==87) return false;
            throw new Win32Exception(error,"Recorded owner unreadable; preserved");
        }
        try {
            FT born,exit,kernel,user;
            if(!GetProcessTimes(handle,out born,out exit,out kernel,out user)) throw new Win32Exception(Marshal.GetLastWin32Error());
            ulong creation=((ulong)born.high<<32)|born.low;
            if(creation!=Convert.ToUInt64(record["rootCreationFileTime"])) return false;
            uint wait=WaitForSingleObject(handle,0);
            if(wait==0) return false;
            if(wait!=258) throw new InvalidOperationException("Recorded owner liveness unreadable");
            return true;
        } finally { CloseHandle(handle); }
    }
    static void CollectDeadGenerations(Dictionary<string,object> record,HashSet<string> generations) {
        string previousGeneration=record.ContainsKey("generation") ? (string)record["generation"] : null;
        if(!Generation(previousGeneration))throw new InvalidOperationException("Invalid predecessor generation; preserved");
        if(record.ContainsKey("deadGenerations")) {
            var prior=record["deadGenerations"] as System.Collections.IList;
            if(prior==null)throw new InvalidOperationException("Invalid predecessor history; preserved");
            foreach(object item in prior){string value=item as string;if(!Generation(value))throw new InvalidOperationException("Invalid predecessor history; preserved");generations.Add(value);}
        }
        generations.Add(previousGeneration);
        if(generations.Count>256)throw new InvalidOperationException("Predecessor history requires maintenance; preserved");
    }
    public static string[] ProvenDeadGenerationsForAdmission(string home) {
        string name=Filename(home);
        try {
            using(var reader=OpenExisting(name,0,FileAccess.Read,FileShare.ReadWrite)) {
                if(reader.Length==0)throw new InvalidOperationException("Empty existing owner record is ambiguous; preserved");
                var previous=Read(reader);
                if(RootAlive(previous))return new string[0];
                var generations=new HashSet<string>();CollectDeadGenerations(previous,generations);
                var result=new string[generations.Count];generations.CopyTo(result);return result;
            }
        } catch(FileNotFoundException) { return new string[0]; }
        catch(DirectoryNotFoundException) { return new string[0]; }
    }
    public NativeHomeLease(string home) {
        Home=ValidateHomePath(home);
        string name=Filename(Home);
        Directory.CreateDirectory(Home);
        var security=new FileSecurity(); security.SetAccessRuleProtection(true,false);
        var user=WindowsIdentity.GetCurrent().User;security.SetOwner(user);
        security.AddAccessRule(new FileSystemAccessRule(user,FileSystemRights.FullControl,AccessControlType.Allow));
        // The OS arbitrates concurrent controllers before either reads or writes.
        bool created=false;
        try {
            try { file=new FileStream(name,FileMode.CreateNew,FileSystemRights.Read|FileSystemRights.Write,FileShare.Read,4096,FileOptions.None,security);created=true; }
            catch(IOException) { file=OpenExisting(name,FileSystemRights.Read|FileSystemRights.Write,0,FileShare.Read); }
            ValidateFile(file,user,"Owner record");
            if(!created && file.Length==0) throw new InvalidOperationException("Empty existing owner record is ambiguous; preserved");
            if(file.Length>0) {
                var previous=Read(file);
                if(RootAlive(previous)) throw new InvalidOperationException("Recorded primary is still alive; refusing replacement");
                CollectDeadGenerations(previous,deadGenerations);
            }
            Write(new Dictionary<string,object>{{"state","pending"},{"controllerPid",Process.GetCurrentProcess().Id}});
        } catch { Dispose(); throw; }
    }
    void Write(Dictionary<string,object> value) {
        byte[] bytes=Encoding.UTF8.GetBytes(Json.Serialize(value));
        file.Position=0; file.SetLength(0); file.Write(bytes,0,bytes.Length); file.Flush(true);
    }
    public void Publish(uint pid,ulong created,string generation,string pipe) {
        var previous=new string[deadGenerations.Count];deadGenerations.CopyTo(previous);
        using(var self=Process.GetCurrentProcess()) Write(new Dictionary<string,object>{{"deadGenerations",previous},{"state","live"},{"rootPid",pid},{"rootCreationFileTime",created},{"generation",generation},{"pipe",pipe},{"controllerPid",self.Id},{"controllerCreated",self.StartTime.ToUniversalTime().ToFileTimeUtc()}});
    }
    public static Dictionary<string,object> Binding(string state) {
        string canonical=Path.GetFullPath(state).TrimEnd(Path.DirectorySeparatorChar,Path.AltDirectorySeparatorChar);
        if(!string.Equals(Path.GetFileName(canonical),"state",StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Unexpected state directory");
        using(var reader=OpenExisting(Filename(Path.GetDirectoryName(canonical)),0,FileAccess.Read,FileShare.ReadWrite)) {
            var record=Read(reader);
            if(!RootAlive(record)) throw new InvalidOperationException("Primary no longer live");
            return record;
        }
    }
    public void Dispose() { if(file!=null) { file.Dispose(); file=null; } }
}
