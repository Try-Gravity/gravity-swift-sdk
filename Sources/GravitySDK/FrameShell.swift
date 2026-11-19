import Foundation

enum FrameShell {
    static func allowsClick(_ body: [String: Any], action: String?, lastNativeTap: TimeInterval?, now: TimeInterval) -> Bool {
        if let activated = body["activated"] as? Bool { return activated }
        guard action != "prompt", body["activated"] == nil || body["activated"] is NSNull,
              let lastNativeTap else { return false }
        let elapsed = now - lastNativeTap
        return elapsed >= 0 && elapsed <= 1
    }

    static func html(url: URL, generation: String) -> String {
        let config = ["src": url.absoluteString, "generation": generation]
        let data = try! JSONSerialization.data(withJSONObject: config, options: [.withoutEscapingSlashes])
        let json = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c")
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="referrer" content="no-referrer">
        <style>html,body{margin:0;width:100%;height:100%;background:transparent;overflow:hidden}iframe{width:100%;height:100%;border:0}</style>
        </head><body><iframe sandbox="allow-scripts" referrerpolicy="no-referrer" title="Ad"></iframe>
        <script>
        (()=>{'use strict';const config=\(json),frame=document.querySelector('iframe');
        window.addEventListener('message',event=>{
          if(event.source!==frame.contentWindow)return;
          const m=event.data;
          if(!m||m.__gravity!==1||m.protocol!=='gfb-1')return;
          if(!['ready','resize','click','event'].includes(m.type))return;
          const body={generation:config.generation,message:m,activated:navigator.userActivation?navigator.userActivation.isActive===true:null};
          try{window.webkit.messageHandlers.gravityFrame.postMessage(JSON.stringify(body));}catch{}
        });
        window.gravityHostPost=message=>frame.contentWindow.postMessage(message,'*');
        frame.src=config.src;
        })();
        </script></body></html>
        """
    }
}
