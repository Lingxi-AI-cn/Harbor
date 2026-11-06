"""Copy the embedded engine and its non-system dependency closure into a bundle."""
import pathlib, subprocess, shutil, hashlib, json, sys
root=pathlib.Path(__file__).resolve().parents[1]
def package(contents):
    contents=pathlib.Path(contents);frameworks=contents/'Frameworks';frameworks.mkdir(exist_ok=True)
    helper=contents/'MacOS/harbor-desktop-engine';shutil.copy2(root/'vendor/desktop-engine/harbor-desktop-engine',helper)
    copied={};queue=[helper];records={};origins={}
    while queue:
        binary=queue.pop(0)
        deps=[l.strip().split(' (compatibility')[0] for l in subprocess.check_output(['otool','-L',str(binary)],text=True).splitlines()[1:]]
        for dep in deps:
            if dep.startswith(('/usr/lib/','/System/Library/')):continue
            name=pathlib.Path(dep).name
            if binary.name==name:continue
            source=root/'vendor/freerdp-install/lib'/name if dep.startswith('@rpath/') else pathlib.Path(dep)
            if not source.is_file():raise RuntimeError(f'Unresolved library: {dep}')
            target=frameworks/name
            if name not in copied:
                shutil.copy2(source,target);copied[name]=target;queue.append(target)
                records[name]={'source':'dependency:'+name,'sha256':hashlib.sha256(source.read_bytes()).hexdigest()}
                origins[name]=source.resolve()
            replacement=('@loader_path/../Frameworks/' if binary==helper else '@loader_path/')+name
            subprocess.run(['install_name_tool','-change',dep,replacement,str(binary)],check=True,capture_output=True)
        if binary!=helper:subprocess.run(['install_name_tool','-id','@rpath/'+binary.name,str(binary)],check=True,capture_output=True)
        # No developer-machine search paths in the delivered helper or libraries.
        lines=subprocess.check_output(['otool','-l',str(binary)],text=True).splitlines()
        for i,line in enumerate(lines):
            if line.strip()=='cmd LC_RPATH':
                value=lines[i+2].strip().split('path ',1)[1].split(' (offset')[0]
                if value.startswith('/'):
                    subprocess.run(['install_name_tool','-delete_rpath',value,str(binary)],check=True,capture_output=True)
        subprocess.run(['codesign','--force','--sign','-',str(binary)],check=True,capture_output=True)
    notices=contents/'Resources/ThirdPartyNotices/Desktop';notices.mkdir(parents=True,exist_ok=True)
    shutil.copy2(root/'vendor/freerdp/LICENSE',notices/'FreeRDP-APACHE-2.0.txt')
    openssl=pathlib.Path('/opt/homebrew/opt/openssl@3')
    license=next(p for p in [openssl/'LICENSE.txt',openssl/'LICENSE'] if p.exists())
    shutil.copy2(license,notices/'OpenSSL-LICENSE.txt')
    for name,record in records.items():
        if name.startswith(('libfreerdp','libwinpr')):
            component,version,lic,files,url='FreeRDP/WinPR','3.33.0','Apache-2.0',['FreeRDP-APACHE-2.0.txt'],'https://github.com/FreeRDP/FreeRDP/tree/5a10d7b6b79a2fbc62e8eba77085cd356dc303a6'
        elif name.startswith(('libssl.','libcrypto.')):
            prefix=origins[name].parent.parent
            version=json.loads((prefix/'INSTALL_RECEIPT.json').read_text())['source']['versions']['stable']
            component,lic,files,url='OpenSSL','Apache-2.0',['OpenSSL-LICENSE.txt'],'https://github.com/openssl/openssl/tree/openssl-'+version
        elif name.startswith('libusb-'):
            prefix=origins[name].parent.parent
            version=json.loads((prefix/'INSTALL_RECEIPT.json').read_text())['source']['versions']['stable']
            for f in ['COPYING','AUTHORS']:
                shutil.copy2(prefix/f,notices/('libusb-'+f+'.txt'))
            component,lic,files,url='libusb','LGPL-2.1-or-later',['libusb-COPYING.txt','libusb-AUTHORS.txt'],'https://github.com/libusb/libusb/tree/v'+version
        else: raise RuntimeError('Unreviewed bundled dependency: '+name)
        record.update(component=component,version=version,license=lic,source_url=url,
                      packaged_sha256=hashlib.sha256((frameworks/name).read_bytes()).hexdigest(),
                      notices={f:hashlib.sha256((notices/f).read_bytes()).hexdigest() for f in files})
    (notices/'inventory.json').write_text(json.dumps({'freerdp_version':'3.33.0','revision':'5a10d7b6b79a2fbc62e8eba77085cd356dc303a6','libraries':records,'vnc':'Harbor native RFB implementation; no LibVNCClient linked'},indent=2)+'\n')
if __name__=='__main__':package(sys.argv[1])
