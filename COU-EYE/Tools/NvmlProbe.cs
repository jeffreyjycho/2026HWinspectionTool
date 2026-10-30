using System;
using System.IO;
using System.Text;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class NvmlProbe {
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr LoadLibraryExW(string path,IntPtr reserved,uint flags);
 [DllImport("kernel32.dll",CharSet=CharSet.Ansi,ExactSpelling=true,SetLastError=true)] static extern IntPtr GetProcAddress(IntPtr module,string name);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern uint GetModuleFileNameW(IntPtr module,StringBuilder path,int size);
 [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr module);
 [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int NoArgs();
 [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Count(out uint count);
 [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr ErrorText(int code);
 [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Handle(uint index,out IntPtr device);
 [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DeviceString(IntPtr device,StringBuilder value,uint length);
 [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DriverString(StringBuilder value,uint length);
 [StructLayout(LayoutKind.Sequential)] struct Memory {public ulong total,free,used;}
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Ansi)] struct Pci {
  [MarshalAs(UnmanagedType.ByValTStr,SizeConst=16)] public string legacy;
  public uint domain,bus,device,deviceId,subsystemId;
  [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)] public string busId;
 }
 [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int MemoryInfo(IntPtr device,out Memory value);
 [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int PciInfo(IntPtr device,out Pci value);
 static void Check(string call,int rc){Write("NVML_CALL name="+call+" code="+rc);if(rc!=0)throw new InvalidOperationException(call+" returned "+rc);}
 static string Text(DeviceString fn,IntPtr device,string name){var s=new StringBuilder(256);Check(name,fn(device,s,256));if(s.Length==0)throw new InvalidOperationException(name+" empty");return s.ToString();}
 static string B64(string s){return Convert.ToBase64String(Encoding.UTF8.GetBytes(s));}
 static StreamWriter log;
 static void Write(string value){string line=DateTime.UtcNow.ToString("o")+" "+value;Console.WriteLine(line);Console.Out.Flush();if(log!=null)log.WriteLine(line);}
 static T Export<T>(IntPtr module,string name) where T:class {
  IntPtr p=GetProcAddress(module,name);int error=Marshal.GetLastWin32Error();
  Write("EXPORT name="+name+" success="+(p!=IntPtr.Zero)+" Win32="+(p==IntPtr.Zero?error:0));
  if(p==IntPtr.Zero)throw new MissingMethodException(name);
  return Marshal.GetDelegateForFunctionPointer(p,typeof(T)) as T;
 }
 public static int Main(string[] args){
  IntPtr module=IntPtr.Zero;bool initialized=false;NoArgs shutdown=null;
  try{
   if(args.Length!=2 || !Path.IsPathRooted(args[0]) || !Path.IsPathRooted(args[1]))return 120;
   log=new StreamWriter(args[1],false,new UTF8Encoding(false));log.AutoFlush=true;
   Write("PROBE_START schema=NVML_GPU_V1 process_bits="+(IntPtr.Size*8));
   string path=Path.GetFullPath(args[0]);Write("DLL_REQUEST path="+path);
   Write("DLL_LOAD_BEGIN flags=0x900");
   module=LoadLibraryExW(path,IntPtr.Zero,0x100|0x800);int win32=Marshal.GetLastWin32Error();
   if(module==IntPtr.Zero){Write("DLL_LOAD success=False Win32="+win32+" message="+new Win32Exception(win32).Message);return 121;}
   Write("DLL_LOAD success=True Win32=0");
   StringBuilder loaded=new StringBuilder(32768);
   uint length=GetModuleFileNameW(module,loaded,loaded.Capacity);int pathError=Marshal.GetLastWin32Error();
   Write("DLL_LOADED_PATH success="+(length>0)+" Win32="+(length==0?pathError:0)+" path="+loaded);
   var init=Export<NoArgs>(module,"nvmlInit_v2");shutdown=Export<NoArgs>(module,"nvmlShutdown");
   var error=Export<ErrorText>(module,"nvmlErrorString");
   Write("NVML_INIT_BEGIN");int rc=init();Write("NVML_INIT code="+rc);
   initialized=rc==0;
   Write("NVML_INIT_MESSAGE "+Marshal.PtrToStringAnsi(error(rc)));
   if(rc!=0)return 122;
   var countFn=Export<Count>(module,"nvmlDeviceGetCount_v2");uint count;
   Write("NVML_COUNT_BEGIN");rc=countFn(out count);Write("NVML_COUNT code="+rc+" count="+count);
   Check("nvmlDeviceGetCount_v2",rc);if(count==0 || count>64)throw new InvalidOperationException("Invalid GPU count");
   if(Marshal.SizeOf(typeof(Pci))!=68 || Marshal.SizeOf(typeof(Memory))!=24)throw new InvalidOperationException("ABI layout mismatch");
   var handle=Export<Handle>(module,"nvmlDeviceGetHandleByIndex_v2");
   var nameFn=Export<DeviceString>(module,"nvmlDeviceGetName");var uuidFn=Export<DeviceString>(module,"nvmlDeviceGetUUID");
   var vbiosFn=Export<DeviceString>(module,"nvmlDeviceGetVbiosVersion");
   var memFn=Export<MemoryInfo>(module,"nvmlDeviceGetMemoryInfo");var pciFn=Export<PciInfo>(module,"nvmlDeviceGetPciInfo_v3");
   var driverFn=Export<DriverString>(module,"nvmlSystemGetDriverVersion");var driver=new StringBuilder(128);Check("nvmlSystemGetDriverVersion",driverFn(driver,128));
   for(uint i=0;i<count;i++){
    IntPtr device;Check("handle["+i+"]",handle(i,out device));
    string name=Text(nameFn,device,"name"),uuid=Text(uuidFn,device,"uuid"),vbios=Text(vbiosFn,device,"vbios");
    Memory memory;Pci pci;Check("memory",memFn(device,out memory));Check("pci",pciFn(device,out pci));
    if(memory.total==0 || memory.total==UInt64.MaxValue)throw new InvalidOperationException("Invalid memory total");
    Write("GPU_RECORD\t"+B64(name)+"\t"+memory.total+"\t"+B64(vbios)+"\t"+B64(uuid)+"\t"+B64(pci.busId)+"\t"+pci.deviceId.ToString("X8")+"\t"+pci.subsystemId.ToString("X8")+"\t"+B64(driver.ToString()));
   }
   Write("TELEMETRY_COMPLETE count="+count);return 0;
  }catch(Exception ex){Write("PROBE_EXCEPTION type="+ex.GetType().Name+" message="+ex.Message);return 125;}
  finally{
   if(initialized && shutdown!=null){Write("NVML_SHUTDOWN_BEGIN");Write("NVML_SHUTDOWN code="+shutdown());}
   if(module!=IntPtr.Zero){Write("DLL_FREE_BEGIN");FreeLibrary(module);}
   Write("PROBE_END");if(log!=null)log.Dispose();
  }
 }
}
