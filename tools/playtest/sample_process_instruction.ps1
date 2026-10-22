param([Parameter(Mandatory=$true)][int]$TargetPid,
      [Parameter(Mandatory=$true)][string]$OutputPrefix,
      [int]$Seconds=30,
      [string]$ThreadIds='')
# Diagnostic only: randomized wall-clock instruction samples, NOT ETW CPU samples.
# Briefly suspends only the explicitly selected process's threads; never changes
# their registers, commands or game state. Resume is guaranteed by finally.
$ErrorActionPreference='Stop'
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
public static class InstructionSampler {
 [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenThread(uint a,bool i,uint t);
 [DllImport("kernel32.dll")] static extern uint GetProcessIdOfThread(IntPtr t);
 [DllImport("kernel32.dll")] static extern uint SuspendThread(IntPtr t);
 [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr t);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetThreadContext(IntPtr t,IntPtr c);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr t);
 public static void Run(int pid,string path,int seconds,string selected) {
  var p=Process.GetProcessById(pid); var random=new Random(195);
  var ids=String.IsNullOrEmpty(selected)?null:Array.ConvertAll(selected.Split(','),int.Parse);
  var clock=Stopwatch.StartNew(); long pauses=0,ticks=0,failed=0;
  var raw=Marshal.AllocHGlobal(1250);
  var ctx=new IntPtr((raw.ToInt64()+15)&~15L);
  try { using(var output=new StreamWriter(path)) {
   output.WriteLine("elapsed_ms,tid,rip");
   while(clock.Elapsed.TotalSeconds<seconds) {
    if(p.HasExited) break;
    if(ids==null) p.Refresh();
    var targets=new System.Collections.Generic.List<int>();
    if(ids!=null) targets.AddRange(ids);
    else foreach(ProcessThread thread in p.Threads) {
     // Waiting threads are not consuming CPU; a state transition between this
     // query and capture remains possible, so these are not cycle weights.
     if(thread.ThreadState!=System.Diagnostics.ThreadState.Running) continue;
     targets.Add(thread.Id);
    }
    foreach(int tid in targets) {
     IntPtr handle=OpenThread(0x0002|0x0008|0x0040,false,(uint)tid);
     if(handle==IntPtr.Zero){ failed++;continue; }
     if(GetProcessIdOfThread(handle)!=(uint)pid){ CloseHandle(handle);failed++;continue; }
     bool suspended=false;
     long start=Stopwatch.GetTimestamp(); long rip=0;bool ok=false;
     try {
      if(SuspendThread(handle)!=uint.MaxValue) {
       suspended=true;
       Marshal.WriteInt32(ctx,48,0x00100001);
       ok=GetThreadContext(handle,ctx);
       if(ok) rip=Marshal.ReadInt64(ctx,248);
      }
     } finally {
      if(suspended) ResumeThread(handle);
      CloseHandle(handle);
      ticks+=Stopwatch.GetTimestamp()-start;pauses++;
     }
     if(ok) output.WriteLine(clock.Elapsed.TotalMilliseconds.ToString("F3",System.Globalization.CultureInfo.InvariantCulture)+","+tid+",0x"+rip.ToString("x"));
     else failed++;
    }
    Thread.Sleep(random.Next(7,14));
   }
  }} finally { Marshal.FreeHGlobal(raw); }
  Console.WriteLine("samples_attempted="+pauses+" failures="+failed+" capture_total_ms="+(1000.0*ticks/Stopwatch.Frequency).ToString("F3")+" elapsed_s="+clock.Elapsed.TotalSeconds.ToString("F3"));
 }
}
'@
$sampleProcess=Get-Process -Id $TargetPid
if ($sampleProcess.ProcessName -ne 'spring') { throw 'Target must be the explicitly launched spring benchmark process.' }
@($sampleProcess.Modules | ForEach-Object { @{name=$_.ModuleName;path=$_.FileName;base=$_.BaseAddress.ToInt64();size=$_.ModuleMemorySize} }) | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath "$OutputPrefix.modules.json"
@($sampleProcess.Threads | ForEach-Object { @{tid=$_.Id;cpu_ms=$_.TotalProcessorTime.TotalMilliseconds} }) | ConvertTo-Json | Set-Content -LiteralPath "$OutputPrefix.threads-before.json"
[InstructionSampler]::Run($TargetPid,"$OutputPrefix.samples.csv",$Seconds,$ThreadIds)
$sampleProcess.Refresh()
@($sampleProcess.Threads | ForEach-Object { @{tid=$_.Id;cpu_ms=$_.TotalProcessorTime.TotalMilliseconds} }) | ConvertTo-Json | Set-Content -LiteralPath "$OutputPrefix.threads-after.json"
