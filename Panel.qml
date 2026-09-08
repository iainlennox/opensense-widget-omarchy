import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "config.js" as Config

// OPNsense Widget — floating desktop widget (panel kind, keepLoaded).
//
// Polls the OPNsense API, pings servers and checks services through the
// bundled opensense-status.py helper, then renders interface cards with live
// bandwidth sparklines, server rows and service rows. Configured through a
// settings form (gear) that writes ~/.config/omarchy/opensense-widget/config.json.
Item {
  id: root

  property var manifest: null
  property bool opened: true
  property bool settingsOpen: false

  readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME")
    || (Quickshell.env("HOME") || "") + "/.config") + "/omarchy/opensense-widget"
  readonly property string configPath: configDir + "/config.json"

  property var config: Config.defaultConfig()
  property var interfaces: []          // visible (unhidden, ordered)
  property var allInterfaces: []       // every known interface incl. hidden
  property var servers: []
  property var services: []
  property var internet: ({ reachable: false, latencyMs: 0 })

  property string lastRefresh: ""
  property string ifaceError: ""

  property int apiSampleCount: 0
  property int apiFailCount: 0
  property int lastApiMs: 0
  property real smoothApiMs: 0
  property int ifaceStartTime: 0

  property var prevTraffic: ({})       // name -> { rx, tx }
  property int prevTrafficTime: 0

  property var prevUp: ({})            // name -> bool, for notifications
  property var edit: ({})              // working copy while settings open

  // Live interface display object. A QObject (not a plain JS object) so that
  // mutating any field (e.g. isExpanded on click) notifies the delegates.
  Component {
    id: interfaceObject
    QtObject {
      property string name: ""
      property string displayName: ""
      property string description: ""
      property string status: ""
      property bool isUp: false
      property string ip: ""
      property string mac: ""
      property string linkSpeed: ""
      property string uptime: ""
      property string customName: ""
      property bool isHidden: false
      property int order: 0
      property bool isExpanded: false
      property double inBps: 0
      property double outBps: 0
      property string bandwidthIn: ""
      property string bandwidthOut: ""
      property string bandwidthPercent: ""
      property double latencyMs: 0
      property double packetLossPct: 0
      property double utilizationPct: 0
      property string healthStatus: "Offline"
      property bool isWan: false
      property var inHistory: []
      property var outHistory: []
      property double scale: 1.0
    }
  }

  readonly property bool configured: Config.isConfigured(config)
  readonly property int refreshMs: Math.max(2000, (config.refreshIntervalSeconds || 5) * 1000)
  readonly property int cardWidth: Style.space(360)

  function scriptArgs(sub) {
    var dir = root.manifest && root.manifest.__sourceDir ? root.manifest.__sourceDir : ""
    var script = (dir !== "" ? dir + "/" : "") + "opensense-status.py"
    return ["python3", script, sub, "--config", root.configPath]
  }

  // ---- config IO ---------------------------------------------------------

  property FileView configFile: FileView {
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.config = Config.parse(text())
      root.afterConfigChanged()
    }
    onLoadFailed: {
      root.config = Config.defaultConfig()
      root.afterConfigChanged()
    }
  }

  property Process configWriter: Process {
    command: ["bash", "-c", "mkdir -p \"$(dirname \"$0\")\" && cat > \"$0\"", root.configPath]
    stdinEnabled: true
    onStarted: write(Config.serialize(root.config))
  }

  function saveConfig() {
    configWriter.running = true
  }

  function afterConfigChanged() {
    root.buildServers()
    root.buildServices()
    root.startPolling()
  }

  // ---- polling -----------------------------------------------------------

  property Process ifaceProc: Process {
    command: root.scriptArgs("interfaces")
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyInterfaces(text) }
  }
  property Process serverProc: Process {
    command: root.scriptArgs("servers")
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyServers(text) }
  }
  property Process serviceProc: Process {
    command: root.scriptArgs("services")
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyServices(text) }
  }
  property Process internetProc: Process {
    command: root.scriptArgs("internet")
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyInternet(text) }
  }

  function runPoll(proc, sub) {
    proc.command = root.scriptArgs(sub)
    if (sub === "interfaces") root.ifaceStartTime = Date.now()
    if (!proc.running) proc.running = true
  }

  Timer { id: ifaceTimer; repeat: true; running: false; interval: root.refreshMs
    onTriggered: root.runPoll(ifaceProc, "interfaces") }
  Timer { id: serverTimer; repeat: true; running: false; interval: 30000
    onTriggered: root.runPoll(serverProc, "servers") }
  Timer { id: serviceTimer; repeat: true; running: false; interval: 60000
    onTriggered: root.runPoll(serviceProc, "services") }
  Timer { id: internetTimer; repeat: true; running: false; interval: 10000
    onTriggered: root.runPoll(internetProc, "internet") }

  onManifestChanged: {
    ifaceProc.command = root.scriptArgs("interfaces")
    serverProc.command = root.scriptArgs("servers")
    serviceProc.command = root.scriptArgs("services")
    internetProc.command = root.scriptArgs("internet")
  }

  function startPolling() {
    ifaceTimer.interval = root.refreshMs
    serverTimer.interval = 30000
    serviceTimer.interval = 60000
    internetTimer.interval = 10000

    if (root.configured) {
      ifaceTimer.running = true
      root.runPoll(ifaceProc, "interfaces")
    } else {
      ifaceTimer.running = false
    }

    var haveServers = (root.config.servers || []).length > 0
    serverTimer.running = haveServers
    if (haveServers) root.runPoll(serverProc, "servers")

    var haveServices = (root.config.services || []).length > 0
    serviceTimer.running = haveServices
    if (haveServices) root.runPoll(serviceProc, "services")

    internetTimer.running = true
    root.runPoll(internetProc, "internet")
  }

  function stopPolling() {
    ifaceTimer.running = false
    serverTimer.running = false
    serviceTimer.running = false
    internetTimer.running = false
  }

  // ---- interfaces --------------------------------------------------------

  function applyInterfaces(text) {
    var data = null
    try { data = JSON.parse(String(text).trim()) } catch (e) { return }
    if (!data || typeof data !== "object") return

    root.apiSampleCount++
    if (data.ok) {
      root.ifaceError = ""
      root.mergeInterfaces(data.interfaces || [])
    } else {
      root.apiFailCount++
      root.ifaceError = data.error || "error"
    }
    var nowMs = Date.now()
    if (root.ifaceStartTime > 0) {
      var apiMs = nowMs - root.ifaceStartTime
      root.lastApiMs = apiMs
      root.smoothApiMs = root.smoothApiMs === 0 ? apiMs : (root.smoothApiMs * 0.75 + apiMs * 0.25)
    }
    root.lastRefresh = Qt.formatTime(new Date(), "HH:mm:ss")
  }

  // Build a brand-new interface display object each poll, carrying forward the
  // expand state and sparkline history from the previous object. Creating fresh
  // objects (rather than mutating in place) is what lets the Repeater's
  // delegates re-evaluate their bindings when `interfaces` is reassigned.
  function buildInterface(fresh, prev, now) {
    var entry = interfaceObject.createObject(root)
    entry.name = fresh.name
    entry.description = fresh.description
    entry.status = fresh.status
    entry.isUp = (fresh.status === "up")
    entry.ip = fresh.ip
    entry.mac = fresh.mac
    entry.linkSpeed = fresh.linkSpeed
    entry.uptime = Model.formatUptime(fresh.uptime)
    entry.isExpanded = prev ? prev.isExpanded : false
    entry.inHistory = prev ? prev.inHistory.slice() : []
    entry.outHistory = prev ? prev.outHistory.slice() : []
    entry.scale = prev ? prev.scale : 1.0

    var c = Config.getOrCreateInterface(root.config, fresh.name)
    entry.customName = c.customName || ""
    entry.isHidden = !!c.isHidden
    entry.order = c.order
    entry.displayName = entry.customName !== "" ? entry.customName : fresh.name
    entry.isWan = Model.isWan(fresh.name, fresh.description, entry.customName)

    var prevT = root.prevTraffic[fresh.name]
    if (prevT && root.prevTrafficTime > 0) {
      var elapsed = now - root.prevTrafficTime
      if (elapsed > 0) {
        entry.inBps = Math.max(0, (fresh.rxBytes - prevT.rx) * 8 / elapsed)
        entry.outBps = Math.max(0, (fresh.txBytes - prevT.tx) * 8 / elapsed)
      }
    }
    root.prevTraffic[fresh.name] = { rx: fresh.rxBytes, tx: fresh.txBytes }
    entry.bandwidthIn = Model.formatBandwidth(entry.inBps)
    entry.bandwidthOut = Model.formatBandwidth(entry.outBps)

    entry.inHistory = entry.inHistory.concat([{ value: entry.inBps, time: now }])
    entry.outHistory = entry.outHistory.concat([{ value: entry.outBps, time: now }])
    root.pruneHistory(entry, now)

    var peak = Math.max(Model.sparklineMax(entry.inHistory), Model.sparklineMax(entry.outHistory))
    entry.scale = Math.max(peak * 1.1, 1.0)

    var lossPct = root.apiSampleCount > 0 ? root.apiFailCount / root.apiSampleCount * 100 : 0
    entry.packetLossPct = lossPct

    var linkBps = Model.parseLinkSpeedBps(fresh.linkSpeed)
    entry.utilizationPct = linkBps > 0 ? (entry.inBps + entry.outBps) / linkBps * 100 : 0

    entry.latencyMs = Math.round(root.smoothApiMs)
    entry.bandwidthPercent = linkBps > 0 ? Math.round((entry.inBps + entry.outBps) / linkBps * 100) + "%" : ""
    entry.healthStatus = Model.healthStatus(entry.isUp, entry.latencyMs, entry.packetLossPct, entry.utilizationPct)

    root.notifyInterfaceChange(entry)
    return entry
  }

  function mergeInterfaces(list) {
    var existing = {}
    for (var i = 0; i < root.allInterfaces.length; i++)
      existing[root.allInterfaces[i].name] = root.allInterfaces[i]

    var now = Date.now() / 1000
    var all = []
    for (var j = 0; j < list.length; j++) {
      var fresh = list[j]
      all.push(root.buildInterface(fresh, existing[fresh.name], now))
    }
    root.prevTrafficTime = now
    root.allInterfaces = all

    var display = all.filter(function (e) { return !e.isHidden })
      .sort(function (a, b) { return a.order - b.order })
    root.interfaces = display
  }

  function pruneHistory(entry, now) {
    var cutoff = now - 60
    while (entry.inHistory.length > 0 && entry.inHistory[0].time < cutoff) entry.inHistory.shift()
    while (entry.outHistory.length > 0 && entry.outHistory[0].time < cutoff) entry.outHistory.shift()
  }

  function notifyInterfaceChange(entry) {
    var name = entry.displayName
    var was = root.prevUp[name]
    if (was === undefined) { root.prevUp[name] = entry.isUp; return }
    if (was && !entry.isUp) root.notify(name + " offline", "Interface is down")
    else if (!was && entry.isUp) root.notify(name + " recovered", "Interface is back online")
    root.prevUp[name] = entry.isUp
  }

  function notify(title, body) {
    Quickshell.execDetached(["bash", "-c", "notify-send -a 'OPNsense Widget' " +
      Util.shellQuote(title) + " " + Util.shellQuote(body)])
  }

  // ---- servers -----------------------------------------------------------

  function buildServers() {
    var list = []
    var cfg = (root.config.servers || []).slice().sort(function (a, b) { return a.order - b.order })
    for (var i = 0; i < cfg.length; i++) {
      var s = cfg[i]
      var existing = root.findServer(s.hostname)
      list.push(existing ? existing : {
        hostname: s.hostname, displayName: s.customName || s.hostname,
        description: s.description || "", operatingSystem: s.operatingSystem || "Windows Server",
        online: false, latencyMs: 0, ip: "", lastChecked: "", isPinging: false, order: s.order
      })
    }
    root.servers = list
  }

  function findServer(hostname) {
    for (var i = 0; i < root.servers.length; i++)
      if (root.servers[i].hostname === hostname) return root.servers[i]
    return null
  }

  function applyServers(text) {
    var data = null
    try { data = JSON.parse(String(text).trim()) } catch (e) { return }
    if (!data || !data.servers) return
    var cfgMap = {}
    var cfgs = root.config.servers || []
    for (var c = 0; c < cfgs.length; c++) cfgMap[cfgs[c].hostname] = cfgs[c]
    var next = []
    for (var i = 0; i < data.servers.length; i++) {
      var fresh = data.servers[i]
      var cfg = cfgMap[fresh.hostname] || {}
      next.push({
        hostname: fresh.hostname,
        displayName: cfg.customName || fresh.hostname,
        description: cfg.description || "",
        operatingSystem: cfg.operatingSystem || "Windows Server",
        online: fresh.online, latencyMs: fresh.latencyMs, ip: fresh.ip,
        lastChecked: Qt.formatTime(new Date(), "HH:mm:ss"),
        isPinging: false, order: cfg.order || 0
      })
    }
    root.servers = next
  }

  // ---- services ----------------------------------------------------------

  function buildServices() {
    var list = []
    var cfg = (root.config.services || []).slice().sort(function (a, b) { return a.order - b.order })
    for (var i = 0; i < cfg.length; i++) {
      var s = cfg[i]
      var existing = root.findService(s.hostname)
      list.push(existing ? existing : {
        serviceType: s.serviceType || "Plex", hostname: s.hostname,
        displayName: s.customName || s.hostname, token: s.token || "",
        online: false, activeStreams: 0, streamDetail: "", serverVersion: "",
        latencyMs: 0, lastChecked: "", isChecking: false, order: s.order
      })
    }
    root.services = list
  }

  function findService(hostname) {
    for (var i = 0; i < root.services.length; i++)
      if (root.services[i].hostname === hostname) return root.services[i]
    return null
  }

  function applyServices(text) {
    var data = null
    try { data = JSON.parse(String(text).trim()) } catch (e) { return }
    if (!data || !data.services) return
    var cfgMap = {}
    var cfgs = root.config.services || []
    for (var c = 0; c < cfgs.length; c++) cfgMap[cfgs[c].hostname] = cfgs[c]
    var next = []
    for (var i = 0; i < data.services.length; i++) {
      var fresh = data.services[i]
      var cfg = cfgMap[fresh.hostname] || {}
      next.push({
        serviceType: cfg.serviceType || fresh.type || "Plex",
        hostname: fresh.hostname,
        displayName: cfg.customName || fresh.hostname,
        token: cfg.token || "",
        online: fresh.online, activeStreams: fresh.activeStreams || 0,
        streamDetail: fresh.detail || "", serverVersion: fresh.serverVersion || "",
        latencyMs: fresh.latencyMs || 0,
        lastChecked: Qt.formatTime(new Date(), "HH:mm:ss"),
        isChecking: false, order: cfg.order || 0
      })
    }
    root.services = next
  }

  // ---- internet ----------------------------------------------------------

  function applyInternet(text) {
    var data = null
    try { data = JSON.parse(String(text).trim()) } catch (e) { return }
    if (!data || typeof data !== "object") return
    root.internet = { reachable: !!data.reachable, latencyMs: data.latencyMs || 0 }
  }

  // ---- derived footer state ----------------------------------------------

  readonly property int onlineCount: root.interfaces.filter(function (e) { return e.isUp }).length
  readonly property int totalCount: root.interfaces.length
  readonly property string worstHealth: root.worstHealthOf()
  function worstHealthOf() {
    var worst = "Excellent"
    for (var i = 0; i < root.interfaces.length; i++) {
      var h = root.interfaces[i].healthStatus
      if (h === "Poor") return "Poor"
      if (h === "Fair" && worst !== "Poor") worst = "Fair"
      if (h === "Good" && worst === "Excellent") worst = "Good"
    }
    return worst
  }
  readonly property color worstHealthColor: Model.healthColor(root.worstHealth)
  readonly property string footerBandwidth: {
    var inTotal = 0, outTotal = 0
    for (var i = 0; i < root.interfaces.length; i++) {
      var e = root.interfaces[i]
      if (e.isUp) { inTotal += e.inBps; outTotal += e.outBps }
    }
    return "↓" + Model.formatBandwidth(inTotal) + "  ↑" + Model.formatBandwidth(outTotal)
  }

  // ---- settings helpers --------------------------------------------------

  function openSettings() {
    root.edit = Config.clone(root.config)
    root.settingsOpen = true
  }

  function closeSettings() {
    root.settingsOpen = false
  }

  function saveSettings() {
    root.config = Config.normalize(root.edit)
    root.saveConfig()
    root.closeSettings()
    root.afterConfigChanged()
  }

  function addServer() {
    root.edit.servers = (root.edit.servers || []).concat([{
      hostname: "", customName: null, description: null, operatingSystem: "Windows Server", order: (root.edit.servers || []).length
    }])
  }

  function removeServer(index) {
    var arr = (root.edit.servers || []).slice()
    arr.splice(index, 1)
    root.edit.servers = arr
  }

  function addService() {
    root.edit.services = (root.edit.services || []).concat([{
      serviceType: "Plex", hostname: "", customName: null, token: null, order: (root.edit.services || []).length
    }])
  }

  function removeService(index) {
    var arr = (root.edit.services || []).slice()
    arr.splice(index, 1)
    root.edit.services = arr
  }

  // ---- lifecycle ---------------------------------------------------------

  Component.onCompleted: {
    configFile.reload()
    root.startPolling()
  }
  Component.onDestruction: root.stopPolling()

  // ---- floating window ---------------------------------------------------

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { right: true; bottom: true }
    margins { right: Style.space(12); bottom: Style.space(12) }
    implicitWidth: root.cardWidth
    implicitHeight: Math.max(220, contentColumn.implicitHeight + card.contentTopInset + card.contentBottomInset)
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "opensense-widget"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    BorderSurface {
      id: card
      anchors.fill: parent
      color: Color.popups.background
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius
      padding: Style.spacing.popupPadding

      Column {
        id: contentColumn
        anchors.top: card.top
        anchors.left: card.left
        anchors.right: card.right
        anchors.topMargin: card.contentTopInset
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        spacing: Style.space(8)

        // ---- header ----
        Item {
          width: parent.width
          height: Math.max(24, title.implicitHeight)
          Text {
            id: title
            text: "OPNsense"
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            text: root.ifaceError !== "" ? root.ifaceError : root.lastRefresh
            color: root.ifaceError !== "" ? Color.urgent : Util.alpha(Color.popups.text, 0.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            anchors.left: title.right
            anchors.leftMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
          }
          Row {
            id: actionsRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)
            ActionButton { text: "⚙"; tooltip: "Settings"; onClicked: root.openSettings() }
            ActionButton { text: "—"; tooltip: "Minimise"; onClicked: root.opened = false }
          }
        }

        // ---- dashboard (hidden while settings open) ----
        Column {
          visible: !root.settingsOpen
          width: parent.width
          spacing: Style.space(8)

          // ---- interfaces ----
          Column {
            width: parent.width
            spacing: Style.space(6)
            Text {
              text: "INTERFACES  " + root.onlineCount + "/" + root.totalCount
              color: Util.alpha(Color.popups.text, 0.6)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            Repeater {
              model: root.interfaces
              delegate: InterfaceCard { iface: modelData }
            }
            Text {
              visible: root.interfaces.length === 0
              text: root.configured ? "No interfaces returned" : "Not configured — open ⚙"
              color: Util.alpha(Color.popups.text, 0.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          // ---- servers ----
          Column {
            visible: root.servers.length > 0
            width: parent.width
            spacing: Style.space(6)
            Text {
              text: "SERVERS"
              color: Util.alpha(Color.popups.text, 0.6)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            Repeater {
              model: root.servers
              delegate: ServerRow { server: modelData }
            }
          }

          // ---- services ----
          Column {
            visible: root.services.length > 0
            width: parent.width
            spacing: Style.space(6)
            Text {
              text: "SERVICES"
              color: Util.alpha(Color.popups.text, 0.6)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            Repeater {
              model: root.services
              delegate: ServiceRow { service: modelData }
            }
          }

          // ---- footer ----
          Item {
            visible: root.interfaces.length > 0
            width: parent.width
            height: 18
            Rectangle {
              width: Style.space(10); height: Style.space(10); radius: Style.space(5)
              color: root.worstHealthColor
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              text: root.worstHealth
              color: root.worstHealthColor
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              text: root.footerBandwidth
              color: Util.alpha(Color.popups.text, 0.7)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              anchors.left: parent.left
              anchors.leftMargin: Style.space(110)
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              text: root.internet.reachable ? "Internet " + root.internet.latencyMs + "ms" : "Internet --"
              color: root.internet.reachable
                ? (root.internet.latencyMs < 100 ? "#a6e3a1" : root.internet.latencyMs < 300 ? "#f9e2af" : "#f38ba8")
                : "#6c7086"
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
            }
          }
        }

        // ---- settings form (replaces dashboard) ----
        Column {
          visible: root.settingsOpen
          width: parent.width
          spacing: Style.space(8)

          Text {
            text: "SETTINGS"
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
          }

          GridLayout {
            width: parent.width
            columns: 2
            columnSpacing: Style.space(8)
            rowSpacing: Style.space(6)
            Label { text: "Base URL" }
            Field { text: root.edit.baseUrl || ""; onTextChanged: root.edit.baseUrl = text }
            Label { text: "API Key" }
            Field { text: root.edit.apiKey || ""; onTextChanged: root.edit.apiKey = text }
            Label { text: "API Secret" }
            Field { text: root.edit.apiSecret || ""; echoMode: TextInput.Password; onTextChanged: root.edit.apiSecret = text }
            Label { text: "Refresh (s)" }
            Field { text: (root.edit.refreshIntervalSeconds || 5) + ""; inputMethodHints: Qt.ImhDigitsOnly
              onTextChanged: root.edit.refreshIntervalSeconds = parseInt(text) || 5 }
          }

          Row {
            width: parent.width
            spacing: Style.space(8)
            CheckBox {
              id: blurChk
              checked: root.edit.blurIpAddress === true
              onToggled: root.edit.blurIpAddress = checked
            }
            Label { text: "Blur IP addresses" }
          }

          Text { text: "SERVERS"; color: Util.alpha(Color.popups.text, 0.6)
            font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true }
          Column {
            width: parent.width
            spacing: Style.space(6)
            Repeater {
              model: root.edit.servers || []
              delegate: Row {
                width: contentColumn.width
                spacing: Style.space(4)
                Field { text: modelData.hostname || ""; placeholderText: "host"; width: 110
                  onTextChanged: modelData.hostname = text }
                Field { text: modelData.customName || ""; placeholderText: "name"; width: 80
                  onTextChanged: modelData.customName = text || null }
                ComboBox {
                  model: ["Windows Server", "Linux", "macOS", "FreeBSD"]
                  currentIndex: Math.max(0, model.indexOf(modelData.operatingSystem))
                  onActivated: modelData.operatingSystem = model[currentIndex]
                  implicitWidth: 120
                }
                ActionButton { text: "✕"; onClicked: root.removeServer(index) }
              }
            }
            ActionButton { text: "+ Add server"; onClicked: root.addServer() }
          }

          Text { text: "SERVICES"; color: Util.alpha(Color.popups.text, 0.6)
            font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true }
          Column {
            width: parent.width
            spacing: Style.space(6)
            Repeater {
              model: root.edit.services || []
              delegate: Row {
                width: contentColumn.width
                spacing: Style.space(4)
                ComboBox {
                  model: ["Plex", "DNS"]
                  currentIndex: modelData.serviceType === "DNS" ? 1 : 0
                  onActivated: modelData.serviceType = model[currentIndex]
                  implicitWidth: 80
                }
                Field { text: modelData.hostname || ""; placeholderText: "host"; width: 90
                  onTextChanged: modelData.hostname = text }
                Field { text: modelData.customName || ""; placeholderText: "name"; width: 70
                  onTextChanged: modelData.customName = text || null }
                Field { text: modelData.token || ""; placeholderText: "token"; width: 70
                  onTextChanged: modelData.token = text || null }
                ActionButton { text: "✕"; onClicked: root.removeService(index) }
              }
            }
            ActionButton { text: "+ Add service"; onClicked: root.addService() }
          }

          Row {
            width: parent.width
            spacing: Style.space(8)
            ActionButton { text: "Save"; onClicked: root.saveSettings() }
            ActionButton { text: "Cancel"; onClicked: root.closeSettings() }
          }
        }
      }
    }
  }

  // ---- reusable small controls ------------------------------------------

  component ActionButton: Item {
    property string text: ""
    property string tooltip: ""
    signal clicked()
    implicitWidth: Math.max(24, label.implicitWidth + Style.space(10))
    implicitHeight: 24
    Rectangle {
      anchors.fill: parent
      radius: Style.space(6)
      color: mouse.containsMouse ? Util.alpha(Color.foreground, 0.1) : "transparent"
    }
    Text {
      id: label
      text: parent.text
      color: Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      anchors.centerIn: parent
    }
    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: parent.clicked()
    }
  }

  component Label: Text {
    color: Util.alpha(Color.popups.text, 0.8)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    verticalAlignment: Text.AlignVCenter
  }

  component Field: TextField {
    placeholderText: ""
    implicitHeight: 26
    leftPadding: Style.space(8)
    rightPadding: Style.space(8)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    color: Color.popups.text
    placeholderTextColor: Util.alpha(Color.popups.text, 0.4)
    background: Rectangle {
      radius: Style.space(6)
      color: Util.alpha(Color.foreground, 0.06)
      border.color: parent.activeFocus ? Util.alpha(Color.accent, 0.6) : Util.alpha(Color.foreground, 0.15)
      border.width: 1
    }
  }

  // ---- interface card ----------------------------------------------------

  component InterfaceCard: Item {
    property var iface: null
    width: contentColumn.width
    implicitHeight: iface.isExpanded ? body.implicitHeight + header.implicitHeight : header.implicitHeight

    Column {
      id: cardCol
      width: parent.width

      Rectangle {
        id: header
        width: parent.width
        height: Math.max(24, name.implicitHeight)
        radius: Style.space(6)
        color: hover.containsMouse ? Util.alpha(Color.foreground, 0.06) : "transparent"

        Item {
          anchors.fill: parent
          anchors.leftMargin: Style.space(6)
          anchors.rightMargin: Style.space(6)

          Rectangle {
            id: dot
            width: Style.space(8); height: Style.space(8); radius: Style.space(4)
            color: iface.isUp ? "#a6e3a1" : (iface.status === "" ? "#6c7086" : "#f38ba8")
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            id: name
            text: iface.displayName
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
            width: parent.width - 110
            anchors.left: dot.right
            anchors.leftMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            id: wanTag
            visible: iface.isWan
            text: "WAN"
            color: "#89b4fa"
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.left: name.right
            anchors.leftMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            id: expandArrow
            text: iface.isExpanded ? "▾" : "▸"
            color: Util.alpha(Color.popups.text, 0.6)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            text: iface.bandwidthPercent
            color: Util.alpha(Color.popups.text, 0.6)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            anchors.right: expandArrow.left
            anchors.rightMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        MouseArea {
          id: hover
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: iface.isExpanded = !iface.isExpanded
        }
      }

      Column {
        id: body
        visible: iface.isExpanded
        width: parent.width
        spacing: Style.space(4)

        GridLayout {
          width: parent.width
          columns: 2
          columnSpacing: Style.space(8)
          rowSpacing: Style.space(2)
          DetailCell { label: "IP"; value: iface.ip; color: iface.ip !== "" ? Color.popups.text : "#6c7086" }
          DetailCell { label: "MAC"; value: iface.mac; color: "#6c7086" }
          DetailCell { label: "Link"; value: Model.displaySpeed(iface.linkSpeed); color: Color.popups.text }
          DetailCell { label: "Uptime"; value: iface.uptime; color: Color.popups.text }
          DetailCell { label: "Latency"; value: iface.latencyMs > 0 ? iface.latencyMs + "ms" : "--"
            color: Model.latencyColor(iface.isUp, iface.latencyMs) }
          DetailCell { label: "Loss"; value: (iface.packetLossPct > 0 ? iface.packetLossPct.toFixed(1) : "0") + "%"
            color: Model.packetLossColor(iface.isUp, iface.packetLossPct) }
        }

        Row {
          width: parent.width
          spacing: Style.space(8)
          Text { text: "↓ " + iface.bandwidthIn; color: "#89b4fa"
            font.family: Style.font.family; font.pixelSize: Style.font.caption }
          Text { text: "↑ " + iface.bandwidthOut; color: "#fab387"
            font.family: Style.font.family; font.pixelSize: Style.font.caption }
          Text { text: "Util " + (iface.utilizationPct > 0 ? Math.round(iface.utilizationPct) + "%" : "--")
            color: Model.utilizationColor(iface.isUp, iface.utilizationPct)
            font.family: Style.font.family; font.pixelSize: Style.font.caption }
        }

        Sparkline {
          width: parent.width
          height: 34
          inHistory: iface.inHistory
          outHistory: iface.outHistory
          graphScale: iface.scale
        }
      }
    }
  }

  component DetailCell: Item {
    property string label: ""
    property string value: ""
    property color color: Color.popups.text
    Layout.fillWidth: true
    implicitHeight: 16
    Row {
      anchors.fill: parent
      spacing: Style.space(6)
      Text { text: parent.parent.label; color: Util.alpha(Color.popups.text, 0.5)
        font.family: Style.font.family; font.pixelSize: Style.font.caption }
      Text { text: parent.parent.value; color: parent.parent.color
        font.family: Style.font.family; font.pixelSize: Style.font.caption; elide: Text.ElideRight }
    }
  }

  component Sparkline: Canvas {
    property var inHistory: []
    property var outHistory: []
    property double graphScale: 1
    property color inColor: "#89b4fa"
    property color outColor: "#fab387"
    onInHistoryChanged: requestPaint()
    onOutHistoryChanged: requestPaint()
    onGraphScaleChanged: requestPaint()
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      ctx.clearRect(0, 0, width, height)
      root.drawSparkline(ctx, Model.sparklinePoints(outHistory, graphScale), outColor, width, height)
      root.drawSparkline(ctx, Model.sparklinePoints(inHistory, graphScale), inColor, width, height)
    }
  }

  function drawSparkline(ctx, pts, color, w, h) {
    if (pts.length < 2) return
    ctx.strokeStyle = color
    ctx.lineWidth = 1.5
    ctx.beginPath()
    for (var i = 0; i < pts.length; i++) {
      var x = pts[i][0] * w
      var y = pts[i][1] * h
      if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
    }
    ctx.stroke()
  }

  // ---- server row --------------------------------------------------------

  component ServerRow: Item {
    property var server: null
    width: contentColumn.width
    implicitHeight: 20
    Rectangle {
      id: dot
      width: Style.space(8); height: Style.space(8); radius: Style.space(4)
      color: server.online ? "#a6e3a1" : "#f38ba8"
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }
    Text {
      text: root.osIcon(server.operatingSystem) + "  " + server.displayName
      color: Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
      anchors.left: dot.right
      anchors.leftMargin: Style.space(6)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(50)
      anchors.verticalCenter: parent.verticalCenter
    }
    Text {
      text: server.online ? server.latencyMs + "ms" : "--"
      color: server.online ? "#a6e3a1" : "#6c7086"
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  function osIcon(os) {
    switch (os) {
      case "Windows Server": return "⊞"
      case "Linux": return "⚛"
      case "macOS": return "◆"
      case "FreeBSD": return "⛨"
      default: return "?"
    }
  }

  // ---- service row -------------------------------------------------------

  component ServiceRow: Item {
    property var service: null
    width: contentColumn.width
    implicitHeight: 20
    Rectangle {
      id: dot
      width: Style.space(8); height: Style.space(8); radius: Style.space(4)
      color: service.online ? "#a6e3a1" : "#f38ba8"
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }
    Text {
      text: service.displayName
      color: Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
      anchors.left: dot.right
      anchors.leftMargin: Style.space(6)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(130)
      anchors.verticalCenter: parent.verticalCenter
    }
    Text {
      text: service.streamDetail
      color: service.online ? Util.alpha(Color.popups.text, 0.6) : "#6c7086"
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
    }
  }
}
