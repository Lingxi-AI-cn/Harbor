import AppKit
import UniformTypeIdentifiers

struct RemoteTransferItem {
    let local: URL, remote: String, directory: Bool
}
enum RemoteTransferPlan {
    static func safeName(_ name:String) throws {
        guard !name.isEmpty,name != ".",name != "..",!name.contains("/"),!name.contains("\0") else { throw HarborError.message(L("Unsafe file name from server.")) }
    }
    static func child(_ parent:String,_ name:String)throws->String {try safeName(name);return (parent == "/" ? "/":parent+"/")+name}
    static func localKind(_ url:URL)throws->FileAttributeType? {
        do {return try FileManager.default.attributesOfItem(atPath:url.path)[.type] as? FileAttributeType}
        catch let e as NSError where e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError {return nil}
    }
    static func upload(_ urls:[URL],to parent:String)throws->[RemoteTransferItem] {
        var result=[RemoteTransferItem](),seen=Set<String>()
        func visit(_ url:URL,_ remote:String,_ depth:Int)throws {
            guard depth<=64,result.count<10000 else {throw HarborError.message(L("Transfer limit: 10,000 entries and 64 directory levels."))}
            guard let kind=try localKind(url),kind == .typeDirectory || kind == .typeRegular else {throw HarborError.message(L("Symbolic links and special files are not transferred: \(url.lastPathComponent)"))}
            result.append(.init(local:url,remote:remote,directory:kind == .typeDirectory))
            if kind == .typeDirectory {for item in try FileManager.default.contentsOfDirectory(at:url,includingPropertiesForKeys:nil).sorted(by:{$0.lastPathComponent<$1.lastPathComponent}) {try visit(item,child(remote,item.lastPathComponent),depth+1)}}
        }
        for url in urls {let remote=try child(parent,url.lastPathComponent);guard seen.insert(remote).inserted else{throw HarborError.message(L("Two selected items have the same destination name."))};try visit(url,remote,0)}
        return result
    }
}
extension SFTPClient {
    func mode(_ path:String)throws->UInt32? {var body=SFTPPacket();body.string(path);guard var reply=try request(7,body,expecting:105,allowMissing:true) else{return nil};return try reply.attributes()}
    func saveText(_ remote:String,expected:Data,replacement:Data,workspace:URL)throws {
        guard try mode(remote).map({$0&0xf000 == 0x8000}) == true else{throw HarborError.message(L("Remote file is no longer a regular file."))}
        let check=workspace.appendingPathComponent("current"),file=workspace.appendingPathComponent("replacement")
        try download(remote,to:check,maxBytes:8*1024*1024)
        guard try Data(contentsOf:check)==expected else{throw HarborError.message(L("Remote file changed. Your edits are retained; reopen the server version and merge before saving."))}
        try replacement.write(to:file,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path);try upload(file,to:remote)
    }
    func createDirectory(_ path:String)throws {var b=SFTPPacket();b.string(path);b.put(4);b.put(0o700);_ = try request(14,b,expecting:101)}
    func planDownload(_ paths:[String],to folder:URL,names:[String]?=nil)throws->[RemoteTransferItem] {
        var result=[RemoteTransferItem]()
        func visit(_ remote:String,_ local:URL,_ depth:Int)throws {
            guard depth<=64,result.count<10000 else{throw HarborError.message(L("Transfer limit: 10,000 entries and 64 directory levels."))}
            guard let bits=try mode(remote),[UInt32(0x4000),0x8000].contains(bits&0xf000) else{throw HarborError.message(L("Symbolic links and special files are not transferred: \(remote)"))}
            let directory=bits&0xf000 == 0x4000
            if let existing=try RemoteTransferPlan.localKind(local) {guard existing == (directory ? .typeDirectory:.typeRegular) else{throw HarborError.message(L("Destination type conflict: \(local.path)"))}}
            result.append(.init(local:local,remote:remote,directory:directory))
            if directory {for entry in try list(remote).1 {try RemoteTransferPlan.safeName(entry.name);try visit(RemoteTransferPlan.child(remote,entry.name),local.appendingPathComponent(entry.name),depth+1)}}
        }
        guard try RemoteTransferPlan.localKind(folder) == .typeDirectory else{throw HarborError.message(L("Choose a real destination folder, not a symbolic link."))}
        for (index,remote) in paths.enumerated() {let name=names?[index] ?? (remote as NSString).lastPathComponent;try RemoteTransferPlan.safeName(name);try visit(remote,folder.appendingPathComponent(name),0)}
        return result
    }
    func transfer(_ plan:[RemoteTransferItem],uploading:Bool,progress:@escaping(Int,String)->Void)throws {
        // Preflight every destination before starting; never follow a destination symlink.
        for item in plan {
            if uploading {if let existing=try mode(item.remote) {guard existing&0xf000 == (item.directory ? 0x4000:0x8000) else {throw HarborError.message(L("Destination type conflict: \(item.remote)"))}}}
        }
        for (i,item) in plan.enumerated() {
            if uploading {
                let existing=try mode(item.remote)
                if let existing,existing&0xf000 != (item.directory ? 0x4000:0x8000) {throw HarborError.message(L("Destination changed: \(item.remote)"))}
                if item.directory {if existing == nil {try createDirectory(item.remote)}}
                else {guard try RemoteTransferPlan.localKind(item.local) == .typeRegular else{throw HarborError.message(L("Source changed during transfer."))};try upload(item.local,to:item.remote)}
            } else {
                guard let bits=try mode(item.remote),bits&0xf000 == (item.directory ? 0x4000:0x8000) else{throw HarborError.message(L("Remote source changed during transfer."))}
                if let existing=try RemoteTransferPlan.localKind(item.local),existing != (item.directory ? .typeDirectory:.typeRegular) {throw HarborError.message(L("Local destination changed during transfer."))}
                if item.directory {if try RemoteTransferPlan.localKind(item.local) == nil {try FileManager.default.createDirectory(at:item.local,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])}}
                else {try download(item.remote,to:item.local)}
            }
            progress(i+1,item.remote)
        }
    }
}

final class RemoteTextEditor:NSWindowController,NSWindowDelegate {
    static var openEditors:[RemoteTextEditor]=[]
    let session:SSHFileSession,remote:String,folder:URL,file:URL
    let text=NSTextView(),saveButton=NSButton(title:L("Save to server"),target:nil,action:nil)
    var original:Data,initialText:String,saving=false,onClosed:(()->Void)?
    init(session:SSHFileSession,remote:String,folder:URL,data:Data)throws {
        guard data.count<=8*1024*1024,let value=String(data:data,encoding:.utf8),!value.contains("\0") else{throw HarborError.message(L("The built-in editor accepts UTF-8 text up to 8 MiB."))}
        self.session=session;self.remote=remote;self.folder=folder;file=folder.appendingPathComponent("edit.txt");original=data;initialText=value
        let w=NSWindow(contentRect:NSRect(x:0,y:0,width:850,height:620),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false);w.title=L("Edit · \(remote)");w.isReleasedWhenClosed=false;w.center()
        super.init(window:w);w.delegate=self
        let scroll=NSScrollView(frame:NSRect(x:0,y:42,width:850,height:578));scroll.autoresizingMask=[.width,.height];scroll.hasVerticalScroller=true
        text.isRichText=false;text.isAutomaticQuoteSubstitutionEnabled=false;text.isAutomaticDashSubstitutionEnabled=false;text.isAutomaticTextReplacementEnabled=false;text.font = .monospacedSystemFont(ofSize:13,weight:.regular);text.string=value;text.frame=scroll.bounds;text.autoresizingMask=[.width];text.textContainer?.widthTracksTextView=true
        scroll.documentView=text;w.contentView?.addSubview(scroll)
        saveButton.frame=NSRect(x:16,y:7,width:180,height:28);saveButton.target=self;saveButton.action = #selector(saveRemote);w.contentView?.addSubview(saveButton)
        let local=NSButton(title:L("Save local copy…"),target:self,action:#selector(saveLocal));local.frame=NSRect(x:210,y:7,width:180,height:28);w.contentView?.addSubview(local)
        Self.openEditors.append(self)
    }
    required init?(coder:NSCoder){fatalError()}
    @objc func saveLocal(){let panel=NSSavePanel();panel.nameFieldStringValue=(remote as NSString).lastPathComponent;guard panel.runModal() == .OK,let url=panel.url else{return};do{try Data(text.string.utf8).write(to:url,options:.atomic)}catch{show(error)}}
    func disconnected(){saving=false;saveButton.isEnabled=false;window?.title=L("Disconnected · \(remote) · edits available locally")}
    @objc func saveRemote() {
        guard !saving else{return};let data=Data(text.string.utf8)
        guard data.count<=8*1024*1024 else{show(HarborError.message(L("Text exceeds 8 MiB.")));return}
        saving=true;saveButton.isEnabled=false;let expected=original
        session.perform(timeout:300,deliverAfterClose:true,{ client in
            try client.saveText(self.remote,expected:expected,replacement:data,workspace:self.folder)
        }) { [weak self] result in
            guard let self else{return};self.saving=false;self.saveButton.isEnabled=true
            switch result {case .success:self.original=data;self.initialText=String(decoding:data,as:UTF8.self);self.window?.title=L("Saved · \(self.remote)");case .failure(let e):self.show(e)}
        }
    }
    func show(_ error:Error){let a=NSAlert(error:error);a.runModal()}
    func windowShouldClose(_ sender:NSWindow)->Bool {if saving {show(HarborError.message(L("Wait for this save to finish before closing.")));return false};if text.string != initialText {let a=NSAlert();a.messageText=L("Discard unsaved edits?");a.addButton(withTitle:L("Keep editing"));a.addButton(withTitle:L("Discard"));return a.runModal() == .alertSecondButtonReturn};return true}
    func windowWillClose(_ n:Notification){try? FileManager.default.removeItem(at:folder);onClosed?();Self.openEditors.removeAll{$0 === self}}
    deinit{try? FileManager.default.removeItem(at:folder)}
}

enum RemoteShellReporting {
    static let command = #"__harbor_pwd(){ local p="$PWD"; p="${p//'%'/%25}"; p="${p//$'\033'/%1B}"; p="${p//$'\007'/%07}"; p="${p// /%20}"; p="${p//'#'/%23}"; p="${p//\?/%3F}"; printf '\033]7;file://localhost%s\007' "$p"; }; if [ -n "$BASH_VERSION" ]; then case "${PROMPT_COMMAND[*]}" in *__harbor_pwd*) ;; *) if declare -p PROMPT_COMMAND 2>/dev/null | grep -q 'declare -a'; then PROMPT_COMMAND+=(__harbor_pwd); else PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND; }__harbor_pwd"; fi;; esac; elif [ -n "$ZSH_VERSION" ]; then (( ${precmd_functions[(Ie)__harbor_pwd]} )) || precmd_functions+=(__harbor_pwd); fi; __harbor_pwd"#
}

final class FilePromiseReply {
    private var callback:((Error?)->Void)?
    init(_ callback:@escaping(Error?)->Void){self.callback=callback}
    func finish(_ error:Error?){let work=callback;callback=nil;work?(error)}
}
