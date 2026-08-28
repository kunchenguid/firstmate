# Native Windows process-table transport for fm-session-lock-lib.sh.
# Usage: fm-windows-process.ps1 ancestry <process-id> [limit]
# Prints pid<TAB>ppid<TAB>executable<TAB>command-line from the requested process
# toward the root. Missing or inaccessible processes stop the walk without
# inventing identity evidence.
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('ancestry')]
    [string]$Mode,

    [Parameter(Mandatory = $true, Position = 1)]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$ProcessId,

    [Parameter(Position = 2)]
    [ValidateRange(1, 64)]
    [int]$Limit = 16
)

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class FirstmateProcessSnapshot {
    private const uint TH32CS_SNAPPROCESS = 0x00000002;
    private static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    private struct PROCESSENTRY32 {
        public uint dwSize;
        public uint cntUsage;
        public uint th32ProcessID;
        public IntPtr th32DefaultHeapID;
        public uint th32ModuleID;
        public uint cntThreads;
        public uint th32ParentProcessID;
        public int pcPriClassBase;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string szExeFile;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern bool Process32First(IntPtr snapshot, ref PROCESSENTRY32 entry);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern bool Process32Next(IntPtr snapshot, ref PROCESSENTRY32 entry);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    public static Dictionary<int, string> Read() {
        var rows = new Dictionary<int, string>();
        IntPtr snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snapshot == INVALID_HANDLE_VALUE) return rows;
        try {
            var entry = new PROCESSENTRY32();
            entry.dwSize = (uint)Marshal.SizeOf(entry);
            if (!Process32First(snapshot, ref entry)) return rows;
            do {
                rows[(int)entry.th32ProcessID] = entry.th32ParentProcessID + "\t" + entry.szExeFile;
            } while (Process32Next(snapshot, ref entry));
            return rows;
        } finally {
            CloseHandle(snapshot);
        }
    }
}
'@

$processRows = [FirstmateProcessSnapshot]::Read()
$currentId = $ProcessId
for ($hop = 0; $hop -lt $Limit -and $currentId -gt 0; $hop++) {
    if (-not $processRows.ContainsKey($currentId)) {
        break
    }
    $parts = $processRows[$currentId] -split "`t", 2
    $parentId = [int]$parts[0]
    $command = $parts[1]
    try {
        $path = (Get-Process -Id $currentId -ErrorAction Stop).Path
        if ($path) { $command = $path }
    }
    catch {}
    $command = $command -replace "[`t`r`n]", ' '
    [Console]::Out.WriteLine("{0}`t{1}`t{2}`t{2}", $currentId, $parentId, $command)

    if ($parentId -le 0 -or $parentId -eq $currentId) {
        break
    }
    $currentId = $parentId
}
