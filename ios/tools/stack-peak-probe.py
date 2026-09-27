#!/usr/bin/env python3
r"""Peak MAIN-THREAD stack use of the iOS app (tech.beacons.app), measured on a SIMULATOR.

WHY THIS EXISTS. An iPhone app's main thread has 1 MiB (1048576 B) of stack; the simulator gives it
8 MiB. A Debug (-Onone) build whose SwiftUI bodies need more than 1 MiB therefore runs clean in the
simulator and crashes on the phone with EXC_BAD_ACCESS (code=2) inside some view body. On 2026-09-25
the Map tab's first render needed 104% of 1 MiB and did exactly that; the fix is DeferredView in
ios/Beacons/Views/Components.swift. The simulator's bigger stack lets this probe measure past 100%
instead of crashing, and it reports every peak against the phone's 1 MiB. Measure a Debug build:
that is the build that overflows.

    xcrun python3 ios/tools/stack-peak-probe.py <sim-udid> --at T1,T2,... \
        [--break FILE:LINE] [--bundle ID] -- [app launch args...]

    # Map tab launch, one 8 s window:
    xcrun python3 ios/tools/stack-peak-probe.py <sim-udid> --at 8 -- -demo -tab 1
    WINDOW 1 [0-8s] PEAK 204696 B = 200 KiB = 20% of 1 MiB
    ARGS -demo -tab 1

Run it with `xcrun python3` so the interpreter matches Xcode's LLDB Python module. The simulator
must be booted with a Debug build installed:
    cd ios && xcodegen generate && xcodebuild build -project Beacons.xcodeproj -scheme Beacons \
        -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath <DerivedData> CODE_SIGNING_ALLOWED=NO
    xcrun simctl install <sim-udid> <DerivedData>/Build/Products/Debug-iphonesimulator/Beacons.app

Useful DEBUG launch args: -demo (canned detections), -tab N (0 Status, 1 Map, 2 Log, 3 Beacon),
-detail (the strongest detection's dossier on its own, with -demo).

HOW. Launches the app with --wait-for-debugger, attaches LLDB, stops at UIApplicationMain and paints
the unused main-thread stack with 0xAB. At each boundary Tn (seconds after launch) it stops the app,
reports the deepest byte touched SINCE THE LAST PAINT (so each window is measured on its own),
repaints below the current stack pointer and resumes. Drive the UI between boundaries (by hand or
with simulator automation) to measure one interaction per window. The last boundary ends the run
and kills the app.

--break FILE:LINE  on the FIRST hit, print the stack used there and the 25 fattest frames (each
frame's size in bytes, from the SP deltas), then resume.
"""
import sys, time, subprocess
sys.path.insert(0, subprocess.check_output(['lldb', '-P'], text=True).strip())
import lldb

argv = sys.argv[1:]
launch = argv[argv.index('--') + 1:] if '--' in argv else []
opts = argv[:argv.index('--')] if '--' in argv else argv
udid = opts[0]
def opt(name, default=None):
    return opts[opts.index(name) + 1] if name in opts else default
bounds = [float(x) for x in opt('--at', '10').split(',')]
brk = opt('--break'); bundle = opt('--bundle', 'tech.beacons.app')
MIB = 1048576

out = subprocess.check_output(['xcrun', 'simctl', 'launch', '--wait-for-debugger',
                               '--terminate-running-process', udid, bundle, *launch], text=True)
pid = int(out.strip().rsplit(':', 1)[1])
t0 = time.time()
dbg = lldb.SBDebugger.Create(); dbg.SetAsync(False)
tgt = dbg.CreateTarget('')
err = lldb.SBError(); proc = tgt.AttachToProcessWithID(dbg.GetListener(), pid, err)
assert err.Success(), err
bp = tgt.BreakpointCreateByName('UIApplicationMain'); proc.Continue()
eo = lldb.SBExpressionOptions(); eo.SetLanguage(lldb.eLanguageTypeObjC)
eo.SetIgnoreBreakpoints(True); eo.SetTimeoutInMicroSeconds(30_000_000)
def main_thread():
    return [t for t in proc.threads if t.GetIndexID() == 1][0]
t = main_thread(); proc.SetSelectedThread(t); f = t.GetFrameAtIndex(0)
base = f.EvaluateExpression("(long)((void*(*)(void*))pthread_get_stackaddr_np)((void*)((void*(*)(void))pthread_self)())", eo).GetValueAsUnsigned()
size = f.EvaluateExpression("(long)((size_t(*)(void*))pthread_get_stacksize_np)((void*)((void*(*)(void))pthread_self)())", eo).GetValueAsUnsigned()
lo = base - size + 65536
def paint():
    th = main_thread(); proc.SetSelectedThread(th); fr = th.GetFrameAtIndex(0)
    hi = fr.GetSP() - 4096
    fr.EvaluateExpression(f"(void)((void*(*)(void*,int,unsigned long))memset)((void*){lo},0xAB,{hi - lo}ul)", eo)
    return hi
def peak(hi):
    e = lldb.SBError(); a = lo
    while a < hi:
        n = min(1 << 16, hi - a); buf = proc.ReadMemory(a, n, e)
        if buf is None: a += n; continue
        i = next((k for k, b in enumerate(buf) if b != 0xAB), None)
        if i is not None: return base - (a + i)
        a += n
    return 0
hi = paint(); tgt.BreakpointDelete(bp.GetID())
lis = dbg.GetListener(); ev = lldb.SBEvent()
fbp = None
if brk:
    fl, ln = brk.rsplit(':', 1); fbp = tgt.BreakpointCreateByLocation(fl, int(ln))
def wait_state(states, secs=30):
    end = time.time() + secs
    while time.time() < end:
        if lis.WaitForEvent(1, ev) and lldb.SBProcess.EventIsProcessEvent(ev) and \
           lldb.SBProcess.GetStateFromEvent(ev) in states:
            return lldb.SBProcess.GetStateFromEvent(ev)
    return proc.GetState()
def run_until(deadline):
    """Resume; if the --break location hits before the deadline, dump frames once and resume."""
    global fbp
    dbg.SetAsync(True); proc.Continue(); wait_state((lldb.eStateRunning,), 5)
    while time.time() - t0 < deadline:
        if lis.WaitForEvent(1, ev) and lldb.SBProcess.EventIsProcessEvent(ev):
            st = lldb.SBProcess.GetStateFromEvent(ev)
            if st in (lldb.eStateExited, lldb.eStateCrashed): return st
            if st == lldb.eStateStopped and fbp is not None:
                dbg.SetAsync(False); dump_frames(); tgt.BreakpointDelete(fbp.GetID()); fbp = None
                dbg.SetAsync(True); proc.Continue(); wait_state((lldb.eStateRunning,), 5)
    proc.Stop(); st = wait_state((lldb.eStateStopped, lldb.eStateCrashed, lldb.eStateExited))
    dbg.SetAsync(False); return st
def dump_frames():
    th = main_thread(); fs = list(th.frames)
    used = base - fs[0].GetSP()
    rows = [(fs[i + 1].GetSP() - fs[i].GetSP(), i, (fs[i].GetFunctionName() or '?')[:140],
             fs[i].GetModule().GetFileSpec().GetFilename()) for i in range(len(fs) - 1)]
    app = sum(r[0] for r in rows if r[3] and r[3].startswith('Beacons'))
    print(f"BREAK {brk}: used {used} B ({100*used/MIB:.0f}% of 1 MiB), {len(fs)} frames, app frames {app} B", flush=True)
    for r in sorted(rows, reverse=True)[:25]:
        print(f"  {r[0]:>7} #{r[1]:<3} {r[3]}  {r[2]}", flush=True)
prev = 0.0
for i, b in enumerate(bounds):
    st = run_until(b)
    if st in (lldb.eStateExited, lldb.eStateCrashed):
        print(f"WINDOW {i+1} [{prev:.0f}-{b:.0f}s] process {'EXITED' if st == lldb.eStateExited else 'CRASHED'}", flush=True); break
    p = peak(hi)
    print(f"WINDOW {i+1} [{prev:.0f}-{b:.0f}s] PEAK {p} B = {p/1024:.0f} KiB = {100*p/MIB:.0f}% of 1 MiB", flush=True)
    hi = paint(); prev = b
print(f"ARGS {' '.join(launch)}")
proc.Kill()
