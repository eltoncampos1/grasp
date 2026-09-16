import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import "../css/app.css"
import Palette from "./hooks/palette"
import Keys from "./hooks/keys"
import Canvas from "./hooks/canvas"
import Chat from "./hooks/chat"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {params: {_csrf_token: csrfToken}, hooks: {Palette, Keys, Canvas, Chat}})

liveSocket.connect()
window.liveSocket = liveSocket
