using System;
using System.IO;
using System.Linq;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

internal static class Program
{
    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
    private static IntPtr childProcessJob = IntPtr.Zero;

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateJobObject(IntPtr securityAttributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    private static void BindChildrenToStudioLifetime()
    {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) return;
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        int size = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
        IntPtr memory = Marshal.AllocHGlobal(size);
        try
        {
            Marshal.StructureToPtr(limits, memory, false);
            if (!SetInformationJobObject(job, 9, memory, (uint)size) ||
                !AssignProcessToJobObject(job, Process.GetCurrentProcess().Handle))
            {
                CloseHandle(job);
                return;
            }
            childProcessJob = job;
        }
        finally
        {
            Marshal.FreeHGlobal(memory);
        }
    }

    [STAThread]
    private static int Main()
    {
        BindChildrenToStudioLifetime();
        string root = AppContext.BaseDirectory;
        string scriptPath = Path.Combine(root, "app", "studio.ps1");
        string errorLog = Path.Combine(root, "studio.error.log");
        try
        {
            if (!File.Exists(scriptPath))
                throw new FileNotFoundException("DLSS5 Video Studio files are incomplete.", scriptPath);
            Directory.SetCurrentDirectory(root);
            string script = File.ReadAllText(scriptPath, new UTF8Encoding(false, true));
            if (File.Exists(errorLog)) File.Delete(errorLog);
            using (Runspace runspace = RunspaceFactory.CreateRunspace())
            using (PowerShell shell = PowerShell.Create())
            {
                runspace.ApartmentState = System.Threading.ApartmentState.STA;
                runspace.ThreadOptions = PSThreadOptions.ReuseThread;
                runspace.Open();
                runspace.SessionStateProxy.SetVariable("StudioScriptBase", Path.GetDirectoryName(scriptPath));
                shell.Runspace = runspace;
                shell.AddScript(script);
                shell.Invoke();
                if (shell.HadErrors)
                {
                    string message = string.Join(Environment.NewLine, shell.Streams.Error.Select(e => e.ToString()));
                    throw new InvalidOperationException(message);
                }
            }
            return 0;
        }
        catch (Exception error)
        {
            File.WriteAllText(errorLog, error.ToString(), Encoding.UTF8);
            MessageBox.Show(
                error.Message + Environment.NewLine + Environment.NewLine + "Log: " + errorLog,
                "DLSS5 Video Studio",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return 1;
        }
    }
}
