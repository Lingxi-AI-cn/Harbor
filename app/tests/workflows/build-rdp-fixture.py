"""Build an isolated clipboard-echo variant of the pinned FreeRDP sample server."""
from pathlib import Path
import subprocess,shlex
root=Path(__file__).resolve().parents[3];src=root/'vendor/freerdp/server/Sample';build=root/'vendor/freerdp-build/server/Sample';out=root/'checks/workflows-rdp';out.mkdir(exist_ok=True)
addon=r'''
#include <freerdp/server/cliprdr.h>
static CliprdrServerContext *fixture_clip;
static BYTE *fixture_text;static UINT32 fixture_length;
static UINT fixture_announce(CliprdrServerContext *c){CLIPRDR_FORMAT f={13,NULL};CLIPRDR_FORMAT_LIST list={0};list.numFormats=1;list.formats=&f;return c->ServerFormatList(c,&list);}
static UINT fixture_list(CliprdrServerContext *c,const CLIPRDR_FORMAT_LIST *list){CLIPRDR_FORMAT_LIST_RESPONSE r={0};r.common.msgFlags=CB_RESPONSE_OK;UINT result=c->ServerFormatListResponse(c,&r);if(result)return result;if(list->numFormats){CLIPRDR_FORMAT_DATA_REQUEST req={0};req.requestedFormatId=13;return c->ServerFormatDataRequest(c,&req);}return fixture_announce(c);}
static UINT fixture_received(CliprdrServerContext *c,const CLIPRDR_FORMAT_DATA_RESPONSE *r){if(r->common.msgFlags&CB_RESPONSE_OK&&r->common.dataLen<=1024*1024){free(fixture_text);fixture_length=r->common.dataLen;fixture_text=malloc(fixture_length);memcpy(fixture_text,r->requestedFormatData,fixture_length);fprintf(stderr,"FIXTURE_CLIPBOARD_RECEIVED:%u\n",fixture_length);return fixture_announce(c);}return 0;}
static UINT fixture_request(CliprdrServerContext *c,const CLIPRDR_FORMAT_DATA_REQUEST *q){(void)q;CLIPRDR_FORMAT_DATA_RESPONSE r={0};r.common.msgFlags=CB_RESPONSE_OK;r.common.dataLen=fixture_length;r.requestedFormatData=fixture_text;return c->ServerFormatDataResponse(c,&r);}
static void fixture_init(testPeerContext *context){if(fixture_clip)return;fixture_clip=cliprdr_server_context_new(context->vcm);fixture_clip->rdpcontext=(rdpContext*)context;fixture_clip->useLongFormatNames=TRUE;fixture_clip->ClientFormatList=fixture_list;fixture_clip->ClientFormatDataRequest=fixture_request;fixture_clip->ClientFormatDataResponse=fixture_received;size_t n=0;fixture_text=(BYTE*)ConvertUtf8ToWCharAlloc("remote clipboard 中文",&n);fixture_length=(n+1)*2;fixture_clip->Start(fixture_clip);}
'''
s=(src/'sfreerdp.c').read_text();pos=s.index('static BOOL tf_peer_activate');s=s[:pos]+addon+'\n'+s[pos:];s=s.replace('context->activated = TRUE;','context->activated = TRUE;\n fixture_init(context);',1);(out/'server.c').write_text(s)
flags=(build/'CMakeFiles/sfreerdp-server.dir/flags.make').read_text().splitlines();args=[]
for prefix in ['C_DEFINES = ','C_INCLUDES = ']:args+=shlex.split(next(l[len(prefix):] for l in flags if l.startswith(prefix)))
subprocess.run(['cc','-O2',*args,'-I'+str(src),'-c',str(out/'server.c'),'-o',str(out/'server.o')],check=True)
link=shlex.split((build/'CMakeFiles/sfreerdp-server.dir/link.txt').read_text());link=[str(out/'server.o') if x=='CMakeFiles/sfreerdp-server.dir/sfreerdp.c.o' else str(out/'server') if x=='sfreerdp-server' else x for x in link]
subprocess.run(link,cwd=build,check=True)
