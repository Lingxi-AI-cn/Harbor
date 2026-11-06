#if GHOSTTY
import AppKit

final class GhosttyRuntime {
    static let shared = GhosttyRuntime()
    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?
    private var initialized = false
    private let configPath = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-engine-\(UUID().uuidString).conf")
    func configuration(source: String = TerminalPreferences.engineConfig) throws -> ghostty_config_t {
        defer { try? FileManager.default.removeItem(at:configPath) }
        try source.write(to:configPath,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:configPath.path)
        guard let value = ghostty_config_new() else { throw NSError(domain:"Ghostty",code:3,userInfo:[NSLocalizedDescriptionKey:L("Could not allocate terminal configuration.")]) }
        configPath.path.withCString { ghostty_config_load_file(value,$0) }
        ghostty_config_finalize(value)
        guard ghostty_config_diagnostics_count(value) == 0 else {
            let detail = ghostty_config_get_diagnostic(value,0).message.map { String(cString:$0) } ?? L("Invalid terminal preferences")
            ghostty_config_free(value); throw NSError(domain:"Ghostty",code:4,userInfo:[NSLocalizedDescriptionKey:detail])
        }
        return value
    }
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    func ensure() throws -> ghostty_app_t {
        if let app { return app }
        if !initialized {
            guard ghostty_init(0,nil) == 0 else { throw NSError(domain:"Ghostty",code:1,userInfo:[NSLocalizedDescriptionKey:L("Could not initialize the terminal engine.")]) }
            initialized = true
        }
        config = try configuration()
        var cfg = ghostty_runtime_config_s()
        cfg.wakeup_cb = { _ in DispatchQueue.main.async { if let app = GhosttyRuntime.shared.app { ghostty_app_tick(app) } } }
        cfg.action_cb = { _,target,action in
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface,
                  let ptr = ghostty_surface_userdata(surface) else { return false }
            let view = Unmanaged<GhosttyTerminalView>.fromOpaque(ptr).takeUnretainedValue()
            // Copy borrowed C data before returning to the engine.
            switch action.tag {
            case GHOSTTY_ACTION_START_SEARCH:
                let needle = action.action.start_search.needle.map { String(cString:$0) }
                DispatchQueue.main.async { [weak view] in view?.onSearchRequested?(needle) }; return true
            case GHOSTTY_ACTION_END_SEARCH:
                let generation = view.searchGeneration
                DispatchQueue.main.async { [weak view] in
                    guard let view, view.searchGeneration == generation else { return }; view.receiveSearchEnd()
                }; return true
            case GHOSTTY_ACTION_SEARCH_TOTAL:
                let total = Int(action.action.search_total.total)
                let generation = view.searchGeneration
                DispatchQueue.main.async { [weak view] in
                    guard let view, view.searchGeneration == generation else { return }; view.receiveSearchTotal(total)
                }; return true
            case GHOSTTY_ACTION_SEARCH_SELECTED:
                let selected = Int(action.action.search_selected.selected)
                let generation = view.searchGeneration
                DispatchQueue.main.async { [weak view] in
                    guard let view, view.searchGeneration == generation else { return }; view.receiveSearchSelected(selected)
                }; return true
            case GHOSTTY_ACTION_NEW_SPLIT:
                let directions = ["right","down","left","up"]
                let index = Int(action.action.new_split.rawValue)
                guard directions.indices.contains(index) else { return false }
                let direction = directions[index]
                DispatchQueue.main.async { [weak view] in view?.receivePaneAction("split",direction) }; return true
            case GHOSTTY_ACTION_GOTO_SPLIT:
                let directions = ["previous","next","up","left","down","right"]
                let index = Int(action.action.goto_split.rawValue)
                guard directions.indices.contains(index) else { return false }
                let direction = directions[index]
                DispatchQueue.main.async { [weak view] in view?.receivePaneAction("focus",direction) }; return true
            case GHOSTTY_ACTION_RESIZE_SPLIT:
                let directions = ["up","down","left","right"]
                let item = action.action.resize_split, index = Int(action.action.resize_split.direction.rawValue)
                guard directions.indices.contains(index) else { return false }
                let direction = directions[index], amount = Int(item.amount)
                DispatchQueue.main.async { [weak view] in view?.receivePaneAction("resize",direction,amount) }; return true
            case GHOSTTY_ACTION_EQUALIZE_SPLITS:
                DispatchQueue.main.async { [weak view] in view?.receivePaneAction("equalize","") }; return true
            case GHOSTTY_ACTION_SET_TITLE:
                guard let value = action.action.set_title.title else { return false }
                let title = String(cString:value)
                DispatchQueue.main.async { [weak view] in view?.receiveTitle(title) }
                return true
            case GHOSTTY_ACTION_OPEN_URL:
                let item = action.action.open_url
                if let ptr = item.url, item.len <= 16384 {
                    let value = String(decoding:UnsafeBufferPointer(start:UnsafeRawPointer(ptr).assumingMemoryBound(to:UInt8.self),count:Int(item.len)),as:UTF8.self)
                    DispatchQueue.main.async { [weak view] in view?.receiveOpenURL(value) }
                }
                // Consume rejected URLs too: returning false invokes the engine's OS opener.
                return true
            case GHOSTTY_ACTION_MOUSE_OVER_LINK:
                let item = action.action.mouse_over_link
                let value: String
                if let ptr = item.url, item.len <= 16384 {
                    value = String(decoding:UnsafeBufferPointer(start:UnsafeRawPointer(ptr).assumingMemoryBound(to:UInt8.self),count:Int(item.len)),as:UTF8.self)
                } else { value = "" }
                DispatchQueue.main.async { [weak view] in view?.receiveHoveredURL(value) }
                return true
            case GHOSTTY_ACTION_PWD:
                guard let value = action.action.pwd.pwd else { return false }
                let path = String(cString:value)
                DispatchQueue.main.async { [weak view] in view?.receiveWorkingDirectory(path) }
                return true
            default: return false
            }
        }
        // Explicit paste is handled by the view. Remote clipboard access stays denied.
        cfg.read_clipboard_cb = { _,_,_,_,_,_ in GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        cfg.confirm_read_clipboard_cb = { ptr,confirm,state,request in
            guard let ptr else { return }
            let view = Unmanaged<GhosttyTerminalView>.fromOpaque(ptr).takeUnretainedValue()
            guard let surface = view.surface else { return }
            guard request == GHOSTTY_CLIPBOARD_REQUEST_PASTE, let confirm,
                  confirm.pointee.contents_len == 1, let content = confirm.pointee.contents,
                  let mime = content.pointee.mime, String(cString:mime) == "text/plain",
                  content.pointee.len >= 0, content.pointee.len <= 16 * 1024 * 1024, let bytes = content.pointee.data else {
                ghostty_surface_deny_clipboard_request(surface,state); return
            }
            let data = Data(bytes:bytes,count:Int(content.pointee.len))
            view.receivePasteConfirmation(data,state:state)
        }
        cfg.write_clipboard_cb = { _,_,_,_,_ in }
        cfg.close_surface_cb = { ptr,_ in
            guard let ptr else { return }
            let view = Unmanaged<GhosttyTerminalView>.fromOpaque(ptr).takeUnretainedValue()
            DispatchQueue.main.async { [weak view] in view?.receiveCloseRequest() }
        }
        app = ghostty_app_new(&cfg,config)
        guard let app else { throw NSError(domain:"Ghostty",code:2,userInfo:[NSLocalizedDescriptionKey:L("Could not create the terminal application.")]) }
        ghostty_app_set_focus(app,true)
        timer = Timer(timeInterval:0.02,repeats:true) { [weak self] _ in if let app = self?.app { ghostty_app_tick(app) } }
        if let timer { RunLoop.main.add(timer,forMode:.common) }
        for (name,focused) in [(NSApplication.didBecomeActiveNotification,true),(NSApplication.didResignActiveNotification,false)] {
            observers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                if let app = self?.app { ghostty_app_set_focus(app,focused) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName:NSTextInputContext.keyboardSelectionDidChangeNotification,object:nil,queue:.main) { [weak self] _ in
            if let app = self?.app { ghostty_app_keyboard_changed(app) }
        })
        return app
    }
}
#endif
