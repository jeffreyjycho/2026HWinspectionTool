// COU-EYE 1.1: read-only, offline SPD decoder. See SPD_FORMAT_NOTES.md.
using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text;
namespace CouI {
 public class SpdProfile {
  public string Kind, Status, CRC;
  public int Number, Offset, tCK_ps, tAA_ps, tRCD_ps, tRP_ps, tRAS_ps, tRC_ps;
  public double SpeedMTs;
 }
 public class SpdRecord {
  public string SHA256, ParserVersion="1.1.0", Generation="UNKNOWN", Status="UNSUPPORTED", Notes="";
  public int Length;
  public string Revision, ModuleType, ModuleManufacturerID, ModuleManufacturer, DRAMManufacturerID, DRAMManufacturer;
  public string PartNumber, Serial, ManufactureDateBCD, BaseCRC="NOT_AVAILABLE", ModuleCRC="NOT_APPLICABLE";
  public string XMP="NOT_AVAILABLE", EXPO="NOT_APPLICABLE", XMPHeaderCRC="NOT_APPLICABLE", EXPOCRC="NOT_APPLICABLE";
  public string CapacityStatus="NOT_AVAILABLE", TimingStatus="NOT_AVAILABLE", SupportedCL;
  public double? CapacityMiB, JEDECSpeedMTs;
  public int? Ranks, DeviceWidth, BusWidth, Channels, tCK_ps, tAA_ps, tRCD_ps, tRP_ps, tRAS_ps, tRC_ps;
  public List<SpdProfile> Profiles=new List<SpdProfile>();
 }
 public static class SpdEngine {
  public static string Hash(byte[] b) { using(var h=SHA256.Create()) return BitConverter.ToString(h.ComputeHash(b)).Replace("-","").ToLowerInvariant(); }
  public static int CRC16(byte[] b,int start,int count) {
   int c=0; for(int i=start;i<start+count;i++){c^=b[i]<<8;for(int k=0;k<8;k++) c=((c<<1)^((c&32768)!=0?0x1021:0))&65535;} return c;
  }
  static int U(byte[] b,int p){return b[p]|(b[p+1]<<8);}
  static int S(byte b){return b<128?b:b-256;}
  static string C(byte[] b,int p,int n){return b.Length<p+n+2?"NOT_AVAILABLE":(CRC16(b,p,n)==U(b,p+n)?"PASS":"FAIL");}
  static string Hex(byte[] b,int p,int n){return b.Length<p+n?null:BitConverter.ToString(b,p,n).Replace("-","");}
  static string Vendor(byte[] b,int p) {
   if(b.Length<p+2)return null;
   int bank=b[p]&127,code=b[p+1]&127;
   if(bank==0){if(code==78)return "Samsung";if(code==45)return "SK hynix";if(code==44)return "Micron";}
   if(bank==1&&code==24)return "Kingston";
   if(bank==2&&code==30)return "Corsair";
   return "UNKNOWN";
  }
  static void Identity(SpdRecord r,byte[] b,int p,int partLen,int dram) {
   r.ModuleManufacturerID=Hex(b,p,2);r.ModuleManufacturer=Vendor(b,p);
   r.DRAMManufacturerID=Hex(b,dram,2);r.DRAMManufacturer=Vendor(b,dram);
   r.ManufactureDateBCD=Hex(b,p+3,2); r.Serial=Hex(b,p+5,4);
   if(b.Length>=p+9+partLen)r.PartNumber=Encoding.ASCII.GetString(b,p+9,partLen).Trim(' ','\0');
  }
  static void Note(SpdRecord r,string s){r.Notes+=(r.Notes.Length>0?";":"")+s;}
  static void Profile(SpdRecord r,string kind,int num,int offset,int ck,int aa,int rcd,int rp,int ras,int rc,string crc) {
   bool valid=ck>0&&aa>0&&rcd>0&&rp>0&&ras>0&&rc>0;
   r.Profiles.Add(new SpdProfile{Kind=kind,Number=num,Offset=offset,tCK_ps=ck,tAA_ps=aa,tRCD_ps=rcd,tRP_ps=rp,tRAS_ps=ras,tRC_ps=rc,
    SpeedMTs=ck>0?Math.Round(2000000.0/ck,2):0,CRC=crc,Status=!valid?"INVALID_TIMINGS":crc=="FAIL"?"CRC_FAIL":crc=="NOT_AVAILABLE"?"CRC_UNAVAILABLE":"DECODED"});
  }
  public static SpdRecord Parse(byte[] b) {
   var r=new SpdRecord{SHA256=Hash(b),Length=b.Length};
   if(b.Length<3){r.Status="TRUNCATED";Note(r,"Memory type byte missing");return r;}
   bool d4=b[2]==0x0c,d5=b[2]==0x12;
   if(!d4&&!d5){Note(r,"Unsupported memory type 0x"+b[2].ToString("X2"));return r;}
   r.Generation=d4?"DDR4":"DDR5";r.Revision=(b[1]>>4)+"."+(b[1]&15);
   if(b.Length<128){r.Status="TRUNCATED";Note(r,"Base timing block incomplete");return r;}
   r.Status="PARSED";
   if(b.Length!=(d4?512:1024)){r.Status="PARTIAL";Note(r,"Nonstandard dump length; missing fields remain empty");}
   if((b[1]>>4)!=1){r.Status="UNSUPPORTED_REVISION";Note(r,"Base SPD major revision is not 1; raw file retained");return r;}
   string[] types=d4?new[]{"RESERVED","RDIMM","UDIMM","SODIMM","LRDIMM","MINI_RDIMM","MINI_UDIMM","RESERVED","72b_SO_RDIMM","72b_SO_UDIMM","RESERVED","RESERVED","16b_SODIMM","32b_SODIMM","RESERVED","RESERVED"}:
     new[]{"RESERVED","RDIMM","UDIMM","SODIMM","LRDIMM","CUDIMM","CSODIMM","MRDIMM","CAMM2","RESERVED","DDIMM","SOLDER_DOWN","RESERVED","RESERVED","RESERVED","RESERVED"};
   r.ModuleType=types[b[3]&15];
   var cls=new List<string>();
   if(d4){
    Identity(r,b,320,20,350);r.BaseCRC=C(b,0,126);r.ModuleCRC=C(b,128,126);
    int dc=b[4]&15,w=b[12]&7,bw=b[13]&7;
    int[] densities={256,512,1024,2048,4096,8192,16384,32768,12288,24576};
    r.Ranks=((b[12]>>3)&7)+1;r.Channels=1;
    if(w<4)r.DeviceWidth=4<<w;if(bw<4)r.BusWidth=8<<bw;
    if((b[6]&128)==0&&(b[12]&64)==0&&dc<densities.Length&&w<4&&bw<4){r.CapacityMiB=densities[dc]/8.0*r.BusWidth.Value/r.DeviceWidth.Value*r.Ranks.Value;r.CapacityStatus="DECODED";}
    else {r.CapacityStatus="UNSUPPORTED_GEOMETRY";Note(r,"Capacity omitted for stacked/asymmetric/reserved DDR4 geometry");}
    if(b[17]==0){
     r.tCK_ps=b[18]*125+S(b[125]);r.tAA_ps=b[24]*125+S(b[123]);r.tRCD_ps=b[25]*125+S(b[122]);r.tRP_ps=b[26]*125+S(b[121]);
     r.tRAS_ps=(((b[27]&15)<<8)|b[28])*125;r.tRC_ps=(((b[27]>>4)<<8)|b[29])*125+S(b[120]);
     for(int i=0;i<30;i++)if((b[20+i/8]&(1<<(i%8)))!=0)cls.Add(((b[23]&128)!=0?23+i:7+i).ToString());
    }else Note(r,"Unsupported DDR4 timebase");
    r.XMP=b.Length<388?"NOT_AVAILABLE":"ABSENT";
    if(b.Length>=388&&b[384]==12&&b[385]==74){
     r.XMP=b[387]==0x20?"XMP_2.0":"UNSUPPORTED_VERSION";
     if(b[387]==0x20)for(int i=0;i<2;i++)if((b[386]&(1<<i))!=0){int p=393+i*47;
      if(b.Length<p+47){Note(r,"Truncated XMP2 profile");r.XMP="TRUNCATED";continue;}
      Profile(r,"XMP_2.0",i+1,p,b[p+3]*125+S(b[p+38]),b[p+8]*125+S(b[p+37]),b[p+9]*125+S(b[p+36]),b[p+10]*125+S(b[p+35]),(((b[p+11]&15)<<8)|b[p+12])*125,(((b[p+11]>>4)<<8)|b[p+13])*125+S(b[p+34]),"NOT_DEFINED");
     }
    }
   }else{
    Identity(r,b,512,30,552);r.BaseCRC=C(b,0,510);
    if(b.Length>=236){
     int dc=b[4]&31,w=b[6]>>5,bw=b[235]&7,ch=(b[235]>>5)&3;
     int[] densities={0,4,8,12,16,24,32,48,64};r.Ranks=((b[234]>>3)&7)+1;
     if(w<4)r.DeviceWidth=4<<w;if(bw<4)r.BusWidth=8<<bw;r.Channels=1<<ch;
     if((b[4]&224)==0&&(b[234]&64)==0&&dc>0&&dc<densities.Length&&w<4&&bw<4&&(b[235]&128)==0){r.CapacityMiB=densities[dc]*128.0*r.BusWidth.Value/r.DeviceWidth.Value*r.Ranks.Value*r.Channels.Value;r.CapacityStatus="DECODED";}
     else{r.CapacityStatus="UNSUPPORTED_GEOMETRY";Note(r,"Capacity omitted for stacked/asymmetric/reserved DDR5 geometry");}
    }
    if(b[19]==0){r.tCK_ps=U(b,20);r.tAA_ps=U(b,30);r.tRCD_ps=U(b,32);r.tRP_ps=U(b,34);r.tRAS_ps=U(b,36);r.tRC_ps=U(b,38);}
    else Note(r,"Unsupported DDR5 timing encoding");
    for(int i=0;i<40;i++)if((b[24+i/8]&(1<<(i%8)))!=0)cls.Add((20+2*i).ToString());
    r.EXPO=b.Length<836?"NOT_AVAILABLE":"ABSENT";
    bool expo=b.Length>=836&&Encoding.ASCII.GetString(b,832,4)=="EXPO";
    if(expo){r.EXPO=b.Length<960?"TRUNCATED":b[836]==0x10?"EXPO_1.0":"UNSUPPORTED_VERSION";r.EXPOCRC=C(b,832,126);
     if(b.Length>=960&&b[836]==0x10)for(int i=0;i<2;i++)if((b[837]&(1<<i))!=0){int p=842+40*i;Profile(r,"EXPO_1.0",i+1,p,U(b,p+4),U(b,p+6),U(b,p+8),U(b,p+10),U(b,p+12),U(b,p+14),r.EXPOCRC);}
    }
    r.XMP=b.Length<644?"NOT_AVAILABLE":"ABSENT";
    if(b.Length>=644&&b[640]==12&&b[641]==74){r.XMP=b[642]==0x30?"XMP_3.0":"UNSUPPORTED_VERSION";r.XMPHeaderCRC=C(b,640,62);
     if(b[642]==0x30)for(int i=0;i<5;i++){
      int p=704+i*64;if(expo&&(i==2||i==3))continue;
      bool enabled=i<3?(b[643]&(1<<i))!=0:b.Length>=p+64&&U(b,p+5)>0;
      if(!enabled)continue;if(b.Length<p+64){r.XMP="TRUNCATED";Note(r,"Truncated XMP3 profile");continue;}
      Profile(r,i<3?"XMP_3.0":"XMP_3.0_USER",i+1,p,U(b,p+5),U(b,p+13),U(b,p+15),U(b,p+17),U(b,p+19),U(b,p+21),C(b,p,62));
     }
    }
   }
   r.SupportedCL=String.Join(";",cls.ToArray());
   if(r.tCK_ps.HasValue&&r.tCK_ps>0&&r.tAA_ps>0&&r.tRCD_ps>0&&r.tRP_ps>0&&r.tRAS_ps>0&&r.tRC_ps>0){
    r.JEDECSpeedMTs=Math.Round(2000000.0/r.tCK_ps.Value,2);r.TimingStatus="DECODED";
    Profile(r,"JEDEC",0,0,r.tCK_ps.Value,r.tAA_ps.Value,r.tRCD_ps.Value,r.tRP_ps.Value,r.tRAS_ps.Value,r.tRC_ps.Value,r.BaseCRC);
   }else{r.TimingStatus="INVALID_OR_UNSUPPORTED";Note(r,"JEDEC timings unavailable or nonpositive");}
   if(r.BaseCRC=="FAIL"||r.ModuleCRC=="FAIL")r.Status="CRC_FAIL";
   else if(r.CapacityStatus!="DECODED"||r.TimingStatus!="DECODED")r.Status="PARTIAL";
   if(r.Status=="PARSED"){
    bool review=r.XMPHeaderCRC=="FAIL"||r.EXPOCRC=="FAIL"||r.XMP=="TRUNCATED"||r.EXPO=="TRUNCATED"||r.XMP=="UNSUPPORTED_VERSION"||r.EXPO=="UNSUPPORTED_VERSION";
    foreach(var p in r.Profiles)if(p.Status!="DECODED")review=true;
    if(review){r.Status="PROFILE_REVIEW";Note(r,"One or more extension headers/profiles require review");}
   }
   return r;
  }
 }
}
