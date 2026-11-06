/* Harbor embedded desktop helper. IPC integers are big endian. No credentials in argv/files. */
#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/input.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/channels/channels.h>
#include <winpr/string.h>
#include <winpr/wtypes.h>
#include <pthread.h>
#include <freerdp/settings.h>
#include <winpr/synch.h>
#include <openssl/des.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netdb.h>
#include <poll.h>
#include <unistd.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#define LIMIT (64u*1024u*1024u)
static pthread_mutex_t output_lock=PTHREAD_MUTEX_INITIALIZER;
static int wire=-1;
static uint8_t *pixels;
static uint32_t width,height;
static int exact(int fd,void *p,size_t n,int writing) {
 while(n) { ssize_t z=writing?write(fd,p,n):read(fd,p,n); if(z<0&&errno==EINTR)continue; if(z<=0)return 0; p=(char*)p+z;n-=z; } return 1;
}
static uint32_t get32(const void *p) { uint32_t v;memcpy(&v,p,4);return ntohl(v); }
static uint16_t get16(const void *p) { uint16_t v;memcpy(&v,p,2);return ntohs(v); }
static void put32(void *p,uint32_t v) { v=htonl(v);memcpy(p,&v,4); }
static void put16(void *p,uint16_t v) { v=htons(v);memcpy(p,&v,2); }
static int message(char type,const void *p,uint32_t n) { uint8_t h[5]={type};put32(h+1,n);pthread_mutex_lock(&output_lock);int ok=exact(1,h,5,1)&&exact(1,(void*)p,n,1);pthread_mutex_unlock(&output_lock);return ok; }
static void status(const char *s) { message('S',s,(uint32_t)strlen(s)); }
static int fail(const char *s) { message('E',s,(uint32_t)strlen(s));return 0; }
static int receive(char *type,uint8_t **p,uint32_t *n) { uint8_t h[5]; if(!exact(0,h,5,0))return 0;*type=h[0];*n=get32(h+1);if(*n>65536)return 0;*p=malloc(*n+1);if(!*p)return 0;if(!exact(0,*p,*n,0)){free(*p);return 0;}(*p)[*n]=0;return 1; }
static int dimensions(uint32_t w,uint32_t h) { return w>0&&h>0&&w<=8192&&h<=8192&&(uint64_t)w*h*4<=LIMIT; }
static int frame(uint8_t *data,uint32_t w,uint32_t h,uint32_t stride) {
 if(!dimensions(w,h))return fail("Desktop exceeds the 64 MiB frame limit");uint8_t header[13]={'F'};put32(header+1,w*h*4+8);put32(header+5,w);put32(header+9,h);
 pthread_mutex_lock(&output_lock);int ok=exact(1,header,13,1);for(uint32_t y=0;ok&&y<h;y++)ok=exact(1,data+y*stride,w*4,1);pthread_mutex_unlock(&output_lock);return ok;
}
static int allocate(uint32_t w,uint32_t h) { if(!dimensions(w,h))return fail("Invalid desktop dimensions");uint8_t *p=calloc((size_t)w*h,4);if(!p)return 0;free(pixels);pixels=p;width=w;height=h;return 1; }
static CliprdrClientContext *clipboard=NULL;
static pthread_mutex_t clip_lock=PTHREAD_MUTEX_INITIALIZER;
static uint8_t *clip_text=NULL;static uint32_t clip_length=0;static int remote_unicode=0,clip_ready=0;
static UINT advertise(CliprdrClientContext *c) {CLIPRDR_FORMAT format={13,NULL};CLIPRDR_FORMAT_LIST list={0};list.numFormats=clip_text?1:0;list.formats=&format;return c->ClientFormatList(c,&list);}
static UINT clip_monitor(CliprdrClientContext *c,const CLIPRDR_MONITOR_READY *m) {
 (void)m;CLIPRDR_GENERAL_CAPABILITY_SET general={CB_CAPSTYPE_GENERAL,12,CB_CAPS_VERSION_2,CB_USE_LONG_FORMAT_NAMES};CLIPRDR_CAPABILITIES caps={0};caps.cCapabilitiesSets=1;caps.capabilitySets=(CLIPRDR_CAPABILITY_SET*)&general;
 UINT result=c->ClientCapabilities(c,&caps);if(result)return result;clip_ready=1;message('A',"Clipboard channel ready",strlen("Clipboard channel ready"));return advertise(c);
}
static UINT clip_caps(CliprdrClientContext *c,const CLIPRDR_CAPABILITIES *caps){(void)c;(void)caps;return 0;}
static UINT clip_list(CliprdrClientContext *c,const CLIPRDR_FORMAT_LIST *list) {
 remote_unicode=0;for(UINT32 i=0;i<list->numFormats;i++)if(list->formats[i].formatId==13)remote_unicode=1;
 CLIPRDR_FORMAT_LIST_RESPONSE reply={0};reply.common.msgFlags=CB_RESPONSE_OK;return c->ClientFormatListResponse(c,&reply);
}
static UINT clip_request(CliprdrClientContext *c,const CLIPRDR_FORMAT_DATA_REQUEST *req) {
 CLIPRDR_FORMAT_DATA_RESPONSE r={0};r.common.msgFlags=CB_RESPONSE_FAIL;pthread_mutex_lock(&clip_lock);
 if(req->requestedFormatId==13&&clip_text){r.common.msgFlags=CB_RESPONSE_OK;r.common.dataLen=clip_length;r.requestedFormatData=clip_text;}
 UINT result=c->ClientFormatDataResponse(c,&r);pthread_mutex_unlock(&clip_lock);return result;
}
static UINT clip_response(CliprdrClientContext *c,const CLIPRDR_FORMAT_DATA_RESPONSE *r) {
 (void)c;if(!(r->common.msgFlags&CB_RESPONSE_OK)||!r->requestedFormatData||r->common.dataLen>1024*1024||r->common.dataLen%2)return 0;
 int units=(int)r->common.dataLen/2;const WCHAR *w=(const WCHAR*)r->requestedFormatData;while(units>0&&w[units-1]==0)units--;
 size_t n=0;char *text=ConvertWCharNToUtf8Alloc(w,units,&n);if(text&&n<=1024*1024)message('L',text,(uint32_t)n);free(text);return 0;
}
static void channel_connected(void *context,const ChannelConnectedEventArgs *e) {
 (void)context;if(strcmp(e->name,CLIPRDR_SVC_CHANNEL_NAME))return;clipboard=(CliprdrClientContext*)e->pInterface;
 clipboard->MonitorReady=clip_monitor;clipboard->ServerCapabilities=clip_caps;clipboard->ServerFormatList=clip_list;clipboard->ServerFormatDataRequest=clip_request;clipboard->ServerFormatDataResponse=clip_response;
}
static void channel_disconnected(void *context,const ChannelDisconnectedEventArgs *e){(void)context;if(!strcmp(e->name,CLIPRDR_SVC_CHANNEL_NAME)){clipboard=NULL;clip_ready=0;}}
static BOOL pre(freerdp *f) {
 if(PubSub_SubscribeChannelConnected(f->context->pubSub,channel_connected)<0||PubSub_SubscribeChannelDisconnected(f->context->pubSub,channel_disconnected)<0)return FALSE;
 return TRUE;
}
static void clipboard_input(char t,uint8_t *p,uint32_t n) {
 if(!clipboard||!clip_ready){message('N',"Clipboard channel unavailable",strlen("Clipboard channel unavailable"));return;}
 if(t=='G'){if(remote_unicode){CLIPRDR_FORMAT_DATA_REQUEST r={0};r.requestedFormatId=13;clipboard->ClientFormatDataRequest(clipboard,&r);}else message('N',"Remote clipboard has no Unicode text",strlen("Remote clipboard has no Unicode text"));return;}
 size_t units=0;WCHAR *w=ConvertUtf8NToWCharAlloc((char*)p,n,&units);if(!w||units>65536){free(w);return;}
 pthread_mutex_lock(&clip_lock);free(clip_text);clip_text=(uint8_t*)w;clip_length=(units+1)*2;pthread_mutex_unlock(&clip_lock);advertise(clipboard);
}
static BOOL begin(rdpContext *c) { c->gdi->primary->hdc->hwnd->invalid->null=TRUE;return TRUE; }
static BOOL paint(rdpContext *c) { rdpGdi *g=c->gdi;if(g->primary->hdc->hwnd->invalid->null)return TRUE;return frame(g->primary_buffer,g->width,g->height,g->stride); }
static BOOL resize(rdpContext *c) { uint32_t w=freerdp_settings_get_uint32(c->settings,FreeRDP_DesktopWidth),h=freerdp_settings_get_uint32(c->settings,FreeRDP_DesktopHeight);return dimensions(w,h)&&gdi_resize(c->gdi,w,h); }
static BOOL post(freerdp *f) { if(!dimensions(freerdp_settings_get_uint32(f->context->settings,FreeRDP_DesktopWidth),freerdp_settings_get_uint32(f->context->settings,FreeRDP_DesktopHeight))||!gdi_init(f,PIXEL_FORMAT_RGBA32))return FALSE;f->context->update->BeginPaint=begin;f->context->update->EndPaint=paint;f->context->update->DesktopResize=resize;status("Connected · RDP");return TRUE; }
static DWORD certificate(freerdp *f,const char *host,UINT16 port,const char *cn,const char *subject,const char *issuer,const char *fp,DWORD flags) {
 (void)f;(void)flags;char text[16384];snprintf(text,sizeof(text),"Server: %s:%u\nName: %s\nSubject: %s\nIssuer: %s\nFingerprint: %s",host,port,cn?cn:"",subject?subject:"",issuer?issuer:"",fp?fp:"");
 if(!message('C',text,(uint32_t)strlen(text)))return 0;char t;uint8_t *p;uint32_t n;if(!receive(&t,&p,&n))return 0;int yes=t=='T'&&n==1&&p[0]==1;free(p);return yes?2:0;
}
static DWORD changed(freerdp *f,const char *h,UINT16 p,const char *cn,const char *s,const char *i,const char *fp,const char *os,const char *oi,const char *of,DWORD flags) { (void)os;(void)oi;(void)of;return certificate(f,h,p,cn,s,i,fp,flags); }
static int rdp_input(freerdp *f,char t,uint8_t *p,uint32_t n) {
 rdpInput *in=f->context->input;
 if(t=='Q')return 0;
 if(t=='L'||t=='G'){clipboard_input(t,p,n);return 1;}
 if(t=='K'&&n==5) { uint32_t key=get32(p+1);freerdp_input_send_keyboard_event_ex(in,p[0]!=0,FALSE,key); }
 if(t=='U'&&n==5)freerdp_input_send_unicode_keyboard_event(in,p[0]?0:KBD_FLAGS_RELEASE,(UINT16)get32(p+1));
 if(t=='M'&&n==8)freerdp_input_send_mouse_event(in,get16(p),get16(p+2),get16(p+4));
 return 1;
}
static int run_rdp(char **v,uint32_t port,uint32_t w,uint32_t h) {
 freerdp *f=freerdp_new();if(!f)return fail("RDP allocation failed");if(!freerdp_context_new(f)){freerdp_free(f);return 0;}
 rdpSettings *s=f->context->settings;freerdp_settings_set_string(s,FreeRDP_ServerHostname,v[1]);freerdp_settings_set_uint32(s,FreeRDP_ServerPort,port);
 freerdp_settings_set_string(s,FreeRDP_Username,v[2]);freerdp_settings_set_string(s,FreeRDP_Password,v[3]);freerdp_settings_set_string(s,FreeRDP_Domain,v[4]);
 freerdp_settings_set_uint32(s,FreeRDP_DesktopWidth,w);freerdp_settings_set_uint32(s,FreeRDP_DesktopHeight,h);freerdp_settings_set_uint32(s,FreeRDP_ColorDepth,32);
 freerdp_settings_set_bool(s,FreeRDP_RemoteFxCodec,TRUE);freerdp_settings_set_bool(s,FreeRDP_NSCodec,TRUE);freerdp_settings_set_bool(s,FreeRDP_SoftwareGdi,TRUE);freerdp_settings_set_bool(s,FreeRDP_SupportGraphicsPipeline,FALSE);freerdp_settings_set_bool(s,FreeRDP_RedirectClipboard,TRUE);freerdp_settings_set_bool(s,FreeRDP_AutoReconnectionEnabled,FALSE);
 freerdp_settings_set_bool(s,FreeRDP_IgnoreCertificate,FALSE);freerdp_settings_set_bool(s,FreeRDP_AuthenticationOnly,FALSE);
 freerdp_register_addin_provider(freerdp_channels_load_static_addin_entry,0);f->PreConnect=pre;f->LoadChannels=freerdp_client_load_channels;f->PostConnect=post;f->VerifyCertificateEx=certificate;f->VerifyChangedCertificateEx=changed;
 int ok=freerdp_connect(f),connected=ok;
 if(!ok){char e[160];snprintf(e,sizeof(e),"RDP connection failed (0x%08X). Check credentials, certificate and server settings.",freerdp_get_last_error(f->context));fail(e);}
 while(ok&&!freerdp_shall_disconnect_context(f->context)) {
  for(int batch=0;batch<64&&ok;batch++){struct pollfd pfd={0,POLLIN,0};int r=poll(&pfd,1,0);if(r<=0||!(pfd.revents&(POLLIN|POLLHUP)))break;char t;uint8_t *p=NULL;uint32_t n;if(!receive(&t,&p,&n)){ok=0;break;}ok=rdp_input(f,t,p,n);free(p);}if(!ok)break;
  HANDLE events[64];DWORD count=freerdp_get_event_handles(f->context,events,64);if(!count)break;
  DWORD result=WaitForMultipleObjects(count,events,FALSE,15);if(result==WAIT_FAILED||!freerdp_check_event_handles(f->context))break;
 }
 freerdp_disconnect(f);gdi_free(f);freerdp_context_free(f);freerdp_free(f);status("Disconnected");return connected;
}
static int connect_tcp(const char *host,uint32_t port) {
 struct addrinfo hints={0},*all=NULL;hints.ai_socktype=SOCK_STREAM;hints.ai_family=AF_UNSPEC;char p[16];snprintf(p,sizeof(p),"%u",port);
 if(getaddrinfo(host,p,&hints,&all))return -1;int fd=-1;
 for(struct addrinfo *a=all;a;a=a->ai_next){fd=socket(a->ai_family,a->ai_socktype,a->ai_protocol);if(fd<0)continue;struct timeval tv={15,0};setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&tv,sizeof(tv));setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&tv,sizeof(tv));if(connect(fd,a->ai_addr,a->ai_addrlen)==0)break;close(fd);fd=-1;}freeaddrinfo(all);return fd;
}
static uint8_t reverse(uint8_t v) { uint8_t r=0;for(int i=0;i<8;i++){r=(r<<1)|(v&1);v>>=1;}return r; }
static int request(int incremental) { uint8_t b[10]={3,incremental};put16(b+6,width);put16(b+8,height);return exact(wire,b,10,1); }
static int vnc_input(char t,uint8_t *p,uint32_t n) {
 if(t=='Q')return 0;
 if(t=='L'){uint8_t b[8]={6,0,0,0};put32(b+4,n);return exact(wire,b,8,1)&&exact(wire,p,n,1);}
 if(t=='V'&&n==5){uint8_t b[8]={4,p[0],0,0};memcpy(b+4,p+1,4);return exact(wire,b,8,1);}
 if(t=='P'&&n==5){uint8_t b[6]={5,p[0]};memcpy(b+2,p+1,4);return exact(wire,b,6,1);}return 1;
}
static int run_vnc(char **v,uint32_t port) {
 wire=connect_tcp(v[1],port);if(wire<0)return fail("VNC socket connection failed");uint8_t b[32];if(!exact(wire,b,12,0))return fail("VNC version read failed");
 if(memcmp(b,"RFB 003.",8)||b[11]!='\n'||b[8]!='0'||b[9]!='0'||b[10]<'3'||b[10]>'8')return fail("Unsupported RFB version");
 int minor=b[10]-'0';minor=minor>=8?8:minor>=7?7:3;char ver[13];snprintf(ver,sizeof(ver),"RFB 003.00%d\n",minor);if(!exact(wire,ver,12,1))return 0;
 int security=0;if(minor==3){if(!exact(wire,b,4,0))return 0;security=get32(b);}else{if(!exact(wire,b,1,0))return 0;int count=b[0];uint8_t types[255];if(!count||!exact(wire,types,count,0))return fail("VNC rejected connection");for(int i=0;i<count;i++)if(types[i]==2)security=2;if(!security)for(int i=0;i<count;i++)if(types[i]==1)security=1;b[0]=security;if(!security||!exact(wire,b,1,1))return fail("VNC requires unsupported authentication (TLS/VeNCrypt/ARD)");}
 if(security==2){if(!v[3][0])return fail("VNC password required");uint8_t challenge[16];if(!exact(wire,challenge,16,0))return 0;DES_cblock key={0};for(int i=0;i<8&&v[3][i];i++)key[i]=reverse((uint8_t)v[3][i]);DES_key_schedule ks;DES_set_key_unchecked(&key,&ks);DES_ecb_encrypt((const_DES_cblock*)challenge,(DES_cblock*)challenge,&ks,DES_ENCRYPT);DES_ecb_encrypt((const_DES_cblock*)(challenge+8),(DES_cblock*)(challenge+8),&ks,DES_ENCRYPT);memset(&ks,0,sizeof(ks));memset(key,0,8);if(!exact(wire,challenge,16,1))return 0;}
 else if(security!=1)return fail("Unsupported VNC security type");
 if(security==2||minor>=8){if(!exact(wire,b,4,0)||get32(b)!=0)return fail("VNC authentication rejected");}
 b[0]=1;if(!exact(wire,b,1,1)||!exact(wire,b,24,0))return 0;uint32_t namelen=get32(b+20);if(namelen>65536||!allocate(get16(b),get16(b+2)))return fail("Invalid VNC server initialization");char *name=malloc(namelen+1);if(!name)return 0;int ok=exact(wire,name,namelen,0);free(name);if(!ok)return 0;
 // Request 32-bit little-endian truecolor RGBX; convert alpha to opaque locally.
 uint8_t format[20]={0,0,0,0,32,24,0,1,0,255,0,255,0,255,0,8,16,0,0,0};if(!exact(wire,format,20,1))return 0;
 uint8_t enc[16]={2,0,0,3};put32(enc+4,0);put32(enc+8,1);put32(enc+12,(uint32_t)-223);if(!exact(wire,enc,16,1)||!request(0))return 0;status("Connected · VNC (RFB)");
 while(1){struct pollfd fds[2]={{wire,POLLIN,0},{0,POLLIN,0}};if(poll(fds,2,-1)<0){if(errno==EINTR)continue;break;}
  if(fds[1].revents&(POLLIN|POLLHUP)){char t;uint8_t *p=NULL;uint32_t n;if(!receive(&t,&p,&n))break;ok=vnc_input(t,p,n);free(p);if(!ok)break;}
  if(!(fds[0].revents&(POLLIN|POLLHUP)))continue;if(!exact(wire,b,1,0))break;
  if(b[0]==0){if(!exact(wire,b,3,0))break;int count=get16(b+1);for(int i=0;i<count;i++){if(!exact(wire,b,12,0))return 0;uint32_t x=get16(b),y=get16(b+2),w=get16(b+4),h=get16(b+6);int32_t enc=(int32_t)get32(b+8);
    if(enc==-223){if(!allocate(w,h))return 0;continue;}
    if(x>width||y>height||w>width-x||h>height-y)return fail("VNC rectangle outside framebuffer");
    if(enc==0){for(uint32_t row=0;row<h;row++){uint8_t *dst=pixels+((y+row)*width+x)*4;if(!exact(wire,dst,w*4,0))return 0;for(uint32_t col=0;col<w;col++)dst[col*4+3]=255;}}
    else if(enc==1){if(!exact(wire,b,4,0))return 0;uint32_t sx=get16(b),sy=get16(b+2);if(sx>width||sy>height||w>width-sx||h>height-sy)return fail("Invalid VNC copy rectangle");for(uint32_t j=0;j<h;j++){uint32_t row=y>sy?h-j-1:j;memmove(pixels+((y+row)*width+x)*4,pixels+((sy+row)*width+sx)*4,w*4);}}
    else return fail("VNC server sent an unrequested encoding");
   }if(!frame(pixels,width,height,width*4)||!request(1))break;
  }else if(b[0]==2){message('B',NULL,0);}
  else if(b[0]==3){if(!exact(wire,b,7,0))break;uint32_t n=get32(b+3);if(n>1024*1024)return fail("VNC clipboard exceeds limit");uint8_t *text=malloc(n+1);if(!text)return 0;if(!exact(wire,text,n,0)){free(text);return 0;}message('L',text,n);free(text);}
  else return fail("Unsupported VNC server message");
 }
 status("Disconnected");return 1;
}
int main(void) {
 signal(SIGPIPE,SIG_IGN);setenv("WLOG_LEVEL","ERROR",1);char t;uint8_t *p=NULL;uint32_t n;if(!receive(&t,&p,&n)||t!='I'||n<12)return 2;
 uint32_t port=get32(p),w=get32(p+4),h=get32(p+8),offset=12;char *v[5]={0};for(int i=0;i<5;i++){if(offset+4>n)return 2;uint32_t len=get32(p+offset);offset+=4;if(len>4096||len>n-offset||memchr(p+offset,0,len))return 2;v[i]=calloc(len+1,1);if(!v[i])return 2;memcpy(v[i],p+offset,len);offset+=len;}
 memset(p,0,n);free(p);if(offset!=n||!port||port>65535||!dimensions(w,h))return 2;status("Connecting…");int ok=!strcmp(v[0],"RDP")?run_rdp(v,port,w,h):!strcmp(v[0],"VNC")?run_vnc(v,port):0;
 for(int i=0;i<5;i++){memset(v[i],0,strlen(v[i]));free(v[i]);}if(wire>=0)close(wire);free(pixels);free(clip_text);return ok?0:1;
}
