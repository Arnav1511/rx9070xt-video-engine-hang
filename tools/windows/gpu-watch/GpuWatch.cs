using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.ExceptionServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

// Crash-catcher for the black-screen hangs. One line every 2 s, forced to disk, so the
// last lines before a reset show what the graphics card was doing and whether Windows
// was still running underneath the black screen.
//
// Two threads on purpose: the sampler talks to the graphics driver and may block when the
// card hangs; the writer never touches the driver, so its heartbeat keeps going. A growing
// gpu_age_s with a live heartbeat means "card hung, Windows alive". Lines that simply stop
// mean the whole machine froze.
public static class GpuWatch
{
    // ---- Windows (D3DKMT): temperature and fan, works for any vendor ----
    [StructLayout(LayoutKind.Sequential)] struct LUID { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] struct ADAPTERINFO { public uint hAdapter; public LUID Luid; public uint NumOfSources; public int bPrecise; }
    [StructLayout(LayoutKind.Sequential)] struct ENUMADAPTERS2 { public uint NumAdapters; public IntPtr pAdapters; }
    [StructLayout(LayoutKind.Sequential)] struct QUERYADAPTERINFO { public uint hAdapter; public int Type; public IntPtr pData; public uint Size; }
    [StructLayout(LayoutKind.Sequential)] struct CLOSEADAPTER { public uint hAdapter; }
    [StructLayout(LayoutKind.Sequential)] struct PERFDATA
    {
        public uint PhysicalAdapterIndex; public ulong MemoryFrequency; public ulong MaxMemoryFrequency; public ulong MaxMemoryFrequencyOC;
        public ulong MemoryBandwidth; public ulong PCIEBandwidth; public uint FanRPM; public uint Power; public uint Temperature; public byte PowerStateOverride;
    }

    [DllImport("gdi32.dll")] static extern int D3DKMTEnumAdapters2(ref ENUMADAPTERS2 e);
    [DllImport("gdi32.dll")] static extern int D3DKMTQueryAdapterInfo(ref QUERYADAPTERINFO q);
    [DllImport("gdi32.dll")] static extern int D3DKMTCloseAdapter(ref CLOSEADAPTER c);

    const int KMTQAITYPE_ADAPTERREGISTRYINFO = 8;
    const int KMTQAITYPE_ADAPTERPERFDATA = 62;
    const int REGINFO_BYTES = 2080;   // four WCHAR[260] strings, adapter name first

    // ---- AMD driver (ADL): hotspot, memory temperature, voltage, PCIe link ----
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr AdlAlloc(int size);
    [DllImport("atiadlxx.dll", CallingConvention = CallingConvention.Cdecl)] static extern int ADL2_Main_Control_Create(AdlAlloc cb, int enumConnected, out IntPtr ctx);
    [DllImport("atiadlxx.dll", CallingConvention = CallingConvention.Cdecl)] static extern int ADL2_Main_Control_Destroy(IntPtr ctx);
    [DllImport("atiadlxx.dll", CallingConvention = CallingConvention.Cdecl)] static extern int ADL2_Adapter_NumberOfAdapters_Get(IntPtr ctx, ref int n);
    [DllImport("atiadlxx.dll", CallingConvention = CallingConvention.Cdecl)] static extern int ADL2_Adapter_AdapterInfo_Get(IntPtr ctx, IntPtr info, int size);
    [DllImport("atiadlxx.dll", CallingConvention = CallingConvention.Cdecl)] static extern int ADL2_New_QueryPMLogData_Get(IntPtr ctx, int adapterIndex, IntPtr data);

    static readonly AdlAlloc adlAlloc = delegate(int size) { return Marshal.AllocHGlobal(size); };
    const int ADL_INFO_BYTES = 1572;    // AdapterInfo: adapter index at +4, adapter name at +280
    const int ADL_PMLOG_BYTES = 2052;   // int size, then 256 x { int supported; int value; }
    // ADL_PMLOG sensor ids. Edge temp (8), fan (14), load (19) and lanes (41) were checked
    // against Windows' own readings on this card, which is what vouches for the numbering.
    const int S_CLK = 1, S_TEMP_MEM = 9, S_LOAD = 19, S_VOLT = 21, S_TEMP_HOT = 27, S_BUS_SPEED = 40, S_BUS_LANES = 41;

    const int INTERVAL_MS = 2000;

    public const string Header = "time,stall_s,gpu_age_s,gpu_ok,temp_c,hot_c,mem_c,fan_rpm,volt_mv,clk_mhz,adl_load,util_3d,util_video,vram_mb,top_3d_proc,video_proc,bus_speed,bus_lanes,cpu_pct,ram_free_mb,commit_pct,net_age_s,gw_ms,dns_ms,dns2_ms,tcp_ms,udp_n,udp_top,tcp_n,err";

    class Snap
    {
        public DateTime At = DateTime.MinValue;
        public int GpuOk; public double TempC; public uint FanRpm;
        public int HotC = -1, MemC = -1, VoltMv = -1, ClkMhz = -1, AdlLoad = -1, BusSpeed = -1, BusLanes = -1;
        public double U3d, UVideo, VramMb, CpuPct, RamFreeMb, CommitPct;
        public string Top3d = "", VideoProc = "", Err = "";
    }

    static volatile Snap last = new Snap();
    static Mutex mutex;
    static bool samplerStarted;
    static PerformanceCounterCategory catEng, catMem;
    static PerformanceCounter pcCpu, pcRam, pcCommit;
    static Dictionary<string, CounterSample> prevEng = new Dictionary<string, CounterSample>();
    static IntPtr adlCtx = IntPtr.Zero, adlBuf = IntPtr.Zero;
    static int adlIndex = -1;

    static void Zero(IntPtr p, int n) { for (int i = 0; i < n; i++) Marshal.WriteByte(p, i, 0); }

    // Finds the adapter whose name contains nameMatch and reads its temperature and fan.
    // luidTag comes back set whenever the adapter exists, even if the sensor read failed.
    static bool ReadAdapter(string nameMatch, Snap s, out string luidTag)
    {
        luidTag = null;
        ENUMADAPTERS2 e = new ENUMADAPTERS2();
        if (D3DKMTEnumAdapters2(ref e) != 0 || e.NumAdapters == 0) return false;
        int sz = Marshal.SizeOf(typeof(ADAPTERINFO));
        int ps = Marshal.SizeOf(typeof(PERFDATA));
        e.pAdapters = Marshal.AllocHGlobal(sz * (int)e.NumAdapters);
        IntPtr reg = Marshal.AllocHGlobal(REGINFO_BYTES);
        IntPtr perf = Marshal.AllocHGlobal(ps);
        bool found = false;
        try
        {
            if (D3DKMTEnumAdapters2(ref e) != 0) return false;
            for (int i = 0; i < e.NumAdapters; i++)
            {
                ADAPTERINFO ai = (ADAPTERINFO)Marshal.PtrToStructure(IntPtr.Add(e.pAdapters, i * sz), typeof(ADAPTERINFO));
                try
                {
                    if (luidTag != null) continue;
                    Zero(reg, REGINFO_BYTES);
                    QUERYADAPTERINFO q = new QUERYADAPTERINFO();
                    q.hAdapter = ai.hAdapter; q.Type = KMTQAITYPE_ADAPTERREGISTRYINFO; q.pData = reg; q.Size = REGINFO_BYTES;
                    if (D3DKMTQueryAdapterInfo(ref q) != 0) continue;
                    string name = Marshal.PtrToStringUni(reg) ?? "";
                    if (name.IndexOf(nameMatch, StringComparison.OrdinalIgnoreCase) < 0) continue;
                    luidTag = string.Format("luid_0x{0:x8}_0x{1:x8}", ai.Luid.High, ai.Luid.Low);

                    Zero(perf, ps);
                    QUERYADAPTERINFO q2 = new QUERYADAPTERINFO();
                    q2.hAdapter = ai.hAdapter; q2.Type = KMTQAITYPE_ADAPTERPERFDATA; q2.pData = perf; q2.Size = (uint)ps;
                    if (D3DKMTQueryAdapterInfo(ref q2) != 0) continue;
                    PERFDATA p = (PERFDATA)Marshal.PtrToStructure(perf, typeof(PERFDATA));
                    s.TempC = p.Temperature / 10.0; s.FanRpm = p.FanRPM;
                    found = true;
                }
                finally { CLOSEADAPTER c = new CLOSEADAPTER(); c.hAdapter = ai.hAdapter; D3DKMTCloseAdapter(ref c); }
            }
        }
        finally { Marshal.FreeHGlobal(e.pAdapters); Marshal.FreeHGlobal(reg); Marshal.FreeHGlobal(perf); }
        return found;
    }

    static void AdlClose()
    {
        adlIndex = -1;
        if (adlCtx == IntPtr.Zero) return;
        try { ADL2_Main_Control_Destroy(adlCtx); } catch { }
        adlCtx = IntPtr.Zero;
    }

    static void AdlOpen(string match)
    {
        adlIndex = -1;
        if (adlCtx == IntPtr.Zero)
        {
            IntPtr c;
            if (ADL2_Main_Control_Create(adlAlloc, 1, out c) != 0) return;
            adlCtx = c;
        }
        int n = 0;
        if (ADL2_Adapter_NumberOfAdapters_Get(adlCtx, ref n) != 0 || n <= 0) return;
        IntPtr info = Marshal.AllocHGlobal(ADL_INFO_BYTES * n);
        try
        {
            Zero(info, ADL_INFO_BYTES * n);
            if (ADL2_Adapter_AdapterInfo_Get(adlCtx, info, ADL_INFO_BYTES * n) != 0) return;
            for (int i = 0; i < n; i++)
            {
                IntPtr p = IntPtr.Add(info, i * ADL_INFO_BYTES);
                string name = Marshal.PtrToStringAnsi(IntPtr.Add(p, 280)) ?? "";
                if (name.IndexOf(match, StringComparison.OrdinalIgnoreCase) >= 0) { adlIndex = Marshal.ReadInt32(p, 4); return; }
            }
        }
        finally { Marshal.FreeHGlobal(info); }
    }

    static int Sensor(int id) { return Marshal.ReadInt32(adlBuf, 4 + id * 8) != 0 ? Marshal.ReadInt32(adlBuf, 8 + id * 8) : -1; }

    // A fault inside the vendor DLL must not take the logger down with it.
    [HandleProcessCorruptedStateExceptions]
    static void ReadAdl(string match, Snap s)
    {
        try
        {
            if (adlBuf == IntPtr.Zero) adlBuf = Marshal.AllocHGlobal(ADL_PMLOG_BYTES);
            if (adlIndex < 0) AdlOpen(match);
            if (adlIndex < 0) return;
            Zero(adlBuf, ADL_PMLOG_BYTES);
            Marshal.WriteInt32(adlBuf, 0, ADL_PMLOG_BYTES);
            if (ADL2_New_QueryPMLogData_Get(adlCtx, adlIndex, adlBuf) != 0) { AdlClose(); return; }   // reopened on the next sample
            s.HotC = Sensor(S_TEMP_HOT); s.MemC = Sensor(S_TEMP_MEM); s.VoltMv = Sensor(S_VOLT); s.ClkMhz = Sensor(S_CLK);
            s.AdlLoad = Sensor(S_LOAD); s.BusSpeed = Sensor(S_BUS_SPEED); s.BusLanes = Sensor(S_BUS_LANES);
        }
        catch (Exception ex) { adlIndex = -1; s.Err = (s.Err + " adl:" + ex.GetType().Name).Trim(); }
    }

    static int ParsePid(string instance)
    {
        if (!instance.StartsWith("pid_", StringComparison.OrdinalIgnoreCase)) return -1;
        int end = instance.IndexOf('_', 4);
        int pid;
        return (end > 4 && int.TryParse(instance.Substring(4, end - 4), out pid)) ? pid : -1;
    }

    static void Add(Dictionary<int, double> d, int pid, double v) { double o; d.TryGetValue(pid, out o); d[pid] = o + v; }

    static string TopName(Dictionary<int, double> d)
    {
        int best = -1; double bv = 1.0;
        foreach (KeyValuePair<int, double> kv in d) if (kv.Value > bv) { bv = kv.Value; best = kv.Key; }
        if (best < 0) return "";
        string n;
        try { using (Process p = Process.GetProcessById(best)) n = p.ProcessName; } catch { n = "pid" + best; }
        return n.Replace(',', ';') + ":" + bv.ToString("0", CultureInfo.InvariantCulture);
    }

    static void ReadEngines(string luidTag, Snap s)
    {
        InstanceDataCollection col = catEng.ReadCategory()["Utilization Percentage"];
        Dictionary<string, CounterSample> cur = new Dictionary<string, CounterSample>();
        Dictionary<int, double> by3d = new Dictionary<int, double>();
        Dictionary<int, double> byVideo = new Dictionary<int, double>();
        if (col != null)
        {
            foreach (InstanceData d in col.Values)
            {
                string n = d.InstanceName;
                if (n.IndexOf(luidTag, StringComparison.OrdinalIgnoreCase) < 0) continue;
                CounterSample cs = d.Sample; cur[n] = cs;
                CounterSample p;
                if (!prevEng.TryGetValue(n, out p)) continue;
                float v = CounterSample.Calculate(p, cs);
                if (float.IsNaN(v) || v <= 0) continue;
                int k = n.LastIndexOf("engtype_", StringComparison.OrdinalIgnoreCase);
                string type = k >= 0 ? n.Substring(k + 8) : "";
                int pid = ParsePid(n);
                // AMD has one "Video Codec Engine" for encode and decode; other vendors
                // split them into VideoEncode / VideoDecode. All of them count as video.
                if (type.Equals("3D", StringComparison.OrdinalIgnoreCase)) { s.U3d += v; Add(by3d, pid, v); }
                else if (type.IndexOf("Video", StringComparison.OrdinalIgnoreCase) >= 0) { s.UVideo += v; Add(byVideo, pid, v); }
            }
        }
        prevEng = cur;
        s.Top3d = TopName(by3d); s.VideoProc = TopName(byVideo);
    }

    static void ReadVram(string luidTag, Snap s)
    {
        InstanceDataCollection col = catMem.ReadCategory()["Dedicated Usage"];
        if (col == null) return;
        foreach (InstanceData d in col.Values)
            if (d.InstanceName.IndexOf(luidTag, StringComparison.OrdinalIgnoreCase) >= 0) { s.VramMb = d.RawValue / 1048576.0; return; }
    }

    // ---- network: a second symptom, "Discord keeps working but new pages get nothing" ----
    // That pattern means new connections fail while open ones survive. The probes tell the
    // three usual causes apart: the DNS server not answering (dns_ms), Windows out of ports
    // (udp_n high, or E10055 in a probe), or the router refusing new sessions (tcp_ms).
    // Probe values: a number is milliseconds, "T" is no answer in time, "E<code>" is a
    // socket error from Windows itself.
    [DllImport("iphlpapi.dll")] static extern uint GetExtendedUdpTable(IntPtr table, ref int size, bool order, int af, int tableClass, uint reserved);
    [DllImport("iphlpapi.dll")] static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool order, int af, int tableClass, uint reserved);
    const int AF_INET = 2, AF_INET6 = 23, UDP_TABLE_OWNER_PID = 1, TCP_TABLE_OWNER_PID_ALL = 5;
    const int NET_TABLE_MS = 2000, NET_PROBE_EVERY = 5, NET_TIMEOUT_MS = 1500;

    class NetSnap
    {
        public DateTime At = DateTime.MinValue;
        public string Gw = "", Dns = "", Dns2 = "", Tcp = "", UdpTop = "";
        public int UdpN = -1, TcpN = -1;
    }
    static volatile NetSnap lastNet = new NetSnap();
    static readonly byte[] dnsQuery = BuildDnsQuery("example.com");

    static byte[] BuildDnsQuery(string host)
    {
        List<byte> b = new List<byte>(new byte[] { 0x47, 0x57, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 });
        foreach (string label in host.Split('.')) { b.Add((byte)label.Length); b.AddRange(Encoding.ASCII.GetBytes(label)); }
        b.AddRange(new byte[] { 0x00, 0x00, 0x01, 0x00, 0x01 });
        return b.ToArray();
    }

    static string Ms(Stopwatch sw) { return sw.ElapsedMilliseconds.ToString(CultureInfo.InvariantCulture); }

    static string DnsProbe(IPAddress server)
    {
        try
        {
            using (UdpClient u = new UdpClient(server.AddressFamily))
            {
                u.Client.ReceiveTimeout = NET_TIMEOUT_MS;
                Stopwatch sw = Stopwatch.StartNew();
                u.Send(dnsQuery, dnsQuery.Length, new IPEndPoint(server, 53));
                IPEndPoint from = new IPEndPoint(server.AddressFamily == AddressFamily.InterNetworkV6 ? IPAddress.IPv6Any : IPAddress.Any, 0);
                u.Receive(ref from);
                return Ms(sw);
            }
        }
        catch (SocketException ex) { return ex.SocketErrorCode == SocketError.TimedOut ? "T" : "E" + ex.ErrorCode; }
        catch (Exception) { return "E"; }
    }

    static string TcpProbe(IPAddress ip, int port)
    {
        try
        {
            using (Socket s = new Socket(ip.AddressFamily, SocketType.Stream, ProtocolType.Tcp))
            {
                Stopwatch sw = Stopwatch.StartNew();
                IAsyncResult ar = s.BeginConnect(new IPEndPoint(ip, port), null, null);
                if (!ar.AsyncWaitHandle.WaitOne(NET_TIMEOUT_MS)) return "T";
                s.EndConnect(ar);
                return Ms(sw);
            }
        }
        catch (SocketException ex) { return "E" + ex.ErrorCode; }
        catch (Exception) { return "E"; }
    }

    static string PingProbe(IPAddress ip)
    {
        try
        {
            using (Ping p = new Ping())
            {
                PingReply r = p.Send(ip, 1000);
                return r.Status == IPStatus.Success ? r.RoundtripTime.ToString(CultureInfo.InvariantCulture) : "T";
            }
        }
        catch (Exception) { return "E"; }
    }

    // The router and the DNS server Windows is actually using, from the adapter that has a gateway.
    static void FindNet(out IPAddress gw, out IPAddress dns)
    {
        gw = null; dns = null;
        foreach (NetworkInterface ni in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (ni.OperationalStatus != OperationalStatus.Up) continue;
            IPInterfaceProperties ip = ni.GetIPProperties();
            foreach (GatewayIPAddressInformation g in ip.GatewayAddresses)
            {
                if (g.Address.AddressFamily != AddressFamily.InterNetwork || g.Address.Equals(IPAddress.Any)) continue;
                gw = g.Address;
                foreach (IPAddress d in ip.DnsAddresses) if (d.AddressFamily == AddressFamily.InterNetwork) { dns = d; break; }
                return;
            }
        }
    }

    // Open UDP sockets in total and the program holding the most of them.
    static void ReadUdp(NetSnap n)
    {
        Dictionary<int, int> byPid = new Dictionary<int, int>();
        int total = 0;
        foreach (int af in new int[] { AF_INET, AF_INET6 })
        {
            int rowSize = af == AF_INET ? 12 : 28, pidOffset = af == AF_INET ? 8 : 24;
            int size = 0;
            GetExtendedUdpTable(IntPtr.Zero, ref size, false, af, UDP_TABLE_OWNER_PID, 0);
            if (size <= 0) continue;
            size += 8192;   // the table can grow between the two calls
            IntPtr buf = Marshal.AllocHGlobal(size);
            try
            {
                if (GetExtendedUdpTable(buf, ref size, false, af, UDP_TABLE_OWNER_PID, 0) != 0) continue;
                int count = Marshal.ReadInt32(buf);
                total += count;
                for (int i = 0; i < count; i++)
                {
                    int pid = Marshal.ReadInt32(buf, 4 + i * rowSize + pidOffset);
                    int c; byPid.TryGetValue(pid, out c); byPid[pid] = c + 1;
                }
            }
            finally { Marshal.FreeHGlobal(buf); }
        }
        n.UdpN = total;
        int best = -1, bc = 0;
        foreach (KeyValuePair<int, int> kv in byPid) if (kv.Value > bc) { bc = kv.Value; best = kv.Key; }
        if (best < 0) return;
        string name;
        try { using (Process p = Process.GetProcessById(best)) name = p.ProcessName; } catch { name = "pid" + best; }
        n.UdpTop = name.Replace(',', ';') + ":" + bc.ToString(CultureInfo.InvariantCulture);
    }

    static int TcpCount()
    {
        int total = 0;
        foreach (int af in new int[] { AF_INET, AF_INET6 })
        {
            int size = 0;
            GetExtendedTcpTable(IntPtr.Zero, ref size, false, af, TCP_TABLE_OWNER_PID_ALL, 0);
            if (size <= 0) continue;
            size += 8192;
            IntPtr buf = Marshal.AllocHGlobal(size);
            try { if (GetExtendedTcpTable(buf, ref size, false, af, TCP_TABLE_OWNER_PID_ALL, 0) == 0) total += Marshal.ReadInt32(buf); }
            finally { Marshal.FreeHGlobal(buf); }
        }
        return total;
    }

    // Own thread: a probe waiting on a dead network must never delay the card's sampler.
    static void NetLoop()
    {
        IPAddress control = IPAddress.Parse("8.8.8.8");   // a second DNS provider, to tell "your DNS" from "all DNS"
        NetSnap prev = new NetSnap();
        for (int i = 0; ; i++)
        {
            NetSnap n = new NetSnap();
            try
            {
                if (i % NET_PROBE_EVERY == 0)
                {
                    IPAddress gw, dns;
                    FindNet(out gw, out dns);
                    n.Gw = gw != null ? PingProbe(gw) : "none";
                    n.Dns = dns != null ? DnsProbe(dns) : "none";
                    n.Dns2 = DnsProbe(control);
                    n.Tcp = TcpProbe(control, 443);
                }
                else { n.Gw = prev.Gw; n.Dns = prev.Dns; n.Dns2 = prev.Dns2; n.Tcp = prev.Tcp; }
                ReadUdp(n);
                n.TcpN = TcpCount();
            }
            catch (Exception) { }
            n.At = DateTime.Now;
            lastNet = n; prev = n;
            Thread.Sleep(NET_TABLE_MS);
        }
    }

    static void Init()
    {
        catEng = new PerformanceCounterCategory("GPU Engine");
        catMem = new PerformanceCounterCategory("GPU Adapter Memory");
        pcCpu = new PerformanceCounter("Processor", "% Processor Time", "_Total");
        pcRam = new PerformanceCounter("Memory", "Available MBytes");
        // Video memory is charged against the commit limit too, so a full card plus many
        // apps can run Windows out of commit while plenty of RAM still shows as free.
        pcCommit = new PerformanceCounter("Memory", "% Committed Bytes In Use");
        pcCpu.NextValue();
    }

    static Snap Sample(string match)
    {
        Snap s = new Snap();
        try
        {
            string luid;
            s.GpuOk = ReadAdapter(match, s, out luid) ? 1 : 0;
            if (luid != null) { ReadEngines(luid, s); ReadVram(luid, s); }
        }
        catch (Exception ex) { s.Err = ex.GetType().Name; }
        ReadAdl(match, s);
        try { s.CpuPct = pcCpu.NextValue(); s.RamFreeMb = pcRam.NextValue(); s.CommitPct = pcCommit.NextValue(); }
        catch (Exception ex) { s.Err = (s.Err + " " + ex.GetType().Name).Trim(); }
        s.At = DateTime.Now;
        return s;
    }

    static void SamplerLoop(object arg)
    {
        string match = (string)arg;
        for (int i = 1; ; i++)
        {
            last = Sample(match);
            if (i % 150 == 0) GC.Collect();   // the counter snapshots are large; keep the footprint flat
            Thread.Sleep(INTERVAL_MS);
        }
    }

    static string N(int v) { return v < 0 ? "" : v.ToString(CultureInfo.InvariantCulture); }

    static string Format(DateTime now, double stall, Snap s, NetSnap n)
    {
        double age = s.At == DateTime.MinValue ? -1 : (now - s.At).TotalSeconds;
        double netAge = n.At == DateTime.MinValue ? -1 : (now - n.At).TotalSeconds;
        return string.Format(CultureInfo.InvariantCulture,
            "{0:yyyy-MM-dd HH:mm:ss},{1:0.0},{2:0.0},{3},{4:0},{5},{6},{7},{8},{9},{10},{11:0},{12:0},{13:0},{14},{15},{16},{17},{18:0},{19:0},{20:0},{21:0.0},{22},{23},{24},{25},{26},{27},{28},{29}",
            now, stall, age, s.GpuOk, s.TempC, N(s.HotC), N(s.MemC), s.FanRpm, N(s.VoltMv), N(s.ClkMhz), N(s.AdlLoad),
            s.U3d, s.UVideo, s.VramMb, s.Top3d, s.VideoProc, N(s.BusSpeed), N(s.BusLanes), s.CpuPct, s.RamFreeMb, s.CommitPct,
            netAge, n.Gw, n.Dns, n.Dns2, n.Tcp, N(n.UdpN), n.UdpTop, N(n.TcpN), s.Err);
    }

    static void WriteLine(FileStream fs, string line)
    {
        byte[] b = Encoding.UTF8.GetBytes(line + "\r\n");
        fs.Write(b, 0, b.Length);
        fs.Flush(true);
    }

    // Logs until the process dies, or for maxSeconds when that is positive (self-test).
    // With single set it returns at once if another copy is already logging.
    public static void Run(string path, string adapterMatch, int maxSeconds, bool single)
    {
        if (single && mutex == null)
        {
            bool created;
            Mutex m = new Mutex(true, "Local\\GpuWatchLogger", out created);
            if (!created) { m.Dispose(); return; }
            mutex = m;
        }
        Init();
        if (!samplerStarted)   // Run is retried by Main if it throws; keep one sampler
        {
            Thread t = new Thread(SamplerLoop);
            t.IsBackground = true;
            t.Start(adapterMatch);
            Thread net = new Thread(NetLoop);
            net.IsBackground = true;
            net.Start();
            samplerStarted = true;
        }
        using (FileStream fs = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite, 4096, FileOptions.WriteThrough))
        {
            WriteLine(fs, Header);
            Thread.Sleep(INTERVAL_MS / 2);   // write halfway between samples, so a healthy gpu_age_s reads about 1
            DateTime start = DateTime.Now, prev = start;
            while (maxSeconds <= 0 || (DateTime.Now - start).TotalSeconds < maxSeconds)
            {
                Thread.Sleep(INTERVAL_MS);
                DateTime now = DateTime.Now;
                double stall = (now - prev).TotalSeconds - INTERVAL_MS / 1000.0;
                if (stall < 0.5) stall = 0;
                prev = now;
                WriteLine(fs, Format(now, stall, last, lastNet));
            }
        }
    }
}

// Entry point of gpu-watch.exe. Built as a windowless program on purpose: the first version
// ran inside PowerShell, showed up as a blank terminal window, and died when that was closed.
//   gpu-watch.exe                       log until killed (what the scheduled task runs)
//   gpu-watch.exe --test <file> [secs]  self-test next to a running logger, default 12 s
public static class Program
{
    const int KEEP_LOGS = 40;
    const string ADAPTER = "RX 9070";

    static int Main(string[] args)
    {
        if (args.Length >= 2 && args[0] == "--test")
        {
            int secs = 12;
            if (args.Length >= 3) int.TryParse(args[2], out secs);
            GpuWatch.Run(args[1], ADAPTER, secs, false);
            return 0;
        }

        string logDir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "logs");
        Directory.CreateDirectory(logDir);
        try
        {
            FileInfo[] files = new DirectoryInfo(logDir).GetFiles("gpuwatch_*.csv");
            Array.Sort(files, delegate(FileInfo a, FileInfo b) { return b.LastWriteTimeUtc.CompareTo(a.LastWriteTimeUtc); });
            for (int i = KEEP_LOGS; i < files.Length; i++) files[i].Delete();
        }
        catch { }

        string log = Path.Combine(logDir, "gpuwatch_" + DateTime.Now.ToString("yyyyMMdd_HHmmss") + ".csv");
        // Run only returns when another copy is already logging. Right after logon the
        // counters may not be ready yet, so a throw is retried instead of leaving the
        // session unlogged.
        for (int i = 0; i < 20; i++)
        {
            try { GpuWatch.Run(log, ADAPTER, 0, true); return 0; }
            catch { Thread.Sleep(15000); }
        }
        return 1;
    }
}
