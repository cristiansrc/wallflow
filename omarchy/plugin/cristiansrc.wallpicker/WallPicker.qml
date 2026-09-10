// Wallpaper Picker — grid visual de los videos de ~/Wallpapers.
//
// Overlay de plugin self-contained: como Arrange.qml de displaywright, un
// componente montado por el Loader del shell no resuelve imports propios
// (ni scripts, ni qs.Commons), así que solo usa QtQuick/Quickshell y una
// paleta fija. La lógica pesa poco: escanea con un script hermano, muestra
// miniaturas cacheadas y al elegir ejecuta apply-wall.sh (pipeline completo
// de rotate-wall: frame versionado, displaywright, animación, tema, mpvpaper).
//
// El shell togglea con `omarchy-shell shell toggle cristiansrc.wallpicker`;
// rastrea el estado por la propiedad `opened` y llama open()/hide().

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland

Item {
  id: root

  property string omarchyPath: ""
  property var shell: null
  property var manifest: null

  // Ruta fija del plugin: desde la actualizacion de omarchy el shell entrega
  // a third-party un manifest sanitizado SIN __sourceDir (publicPluginManifest
  // lo borra), asi que no se puede derivar la ruta del manifest.
  // Es estable: es el directorio donde el shell descubre el plugin.
  // Rutas absolutas fijas: en el contexto del Loader del shell, derivarlas
  // en runtime (manifest.__sourceDir, Quickshell.env) no es fiable entre
  // versiones (el shell sanitiza el manifest third-party). Plugin personal:
  // estas rutas son estables en esta maquina.
  readonly property string pluginDir: "/home/cristiansrc/.config/omarchy/plugins/cristiansrc.wallpicker"
  readonly property string home: "/home/cristiansrc"
  readonly property string wallpaperDir: "/home/cristiansrc/Wallpapers"

  // Paleta fija (tema ristretto del usuario) — el overlay no puede importar qs.Commons
  readonly property color cBg: "#e61b1513"
  readonly property color cCard: "#241d1d"
  readonly property color cCardHover: "#2a2222"
  readonly property color cBorder: "#3a3132"
  readonly property color cText: "#e6d9db"
  readonly property color cMuted: "#72696a"
  readonly property color cAccent: "#f38d70"

  property bool opened: false
  property string currentVideoPath: ""
  property string searchText: ""
  property bool scanDone: false
  property string scanError: ""

  function open(payload) {
    searchText = ""
    scanDone = false
    refreshCurrent()
    restartScan()
    root.opened = true
  }

  function hide() {
    root.opened = false
  }

  function refreshCurrent() { currentReader.running = true }

  function restartScan() {
    if (scanProc.running) scanProc.running = false
    sourceModel.clear()
    filteredModel.clear()
    root.scanError = ""
    root.scanDone = false
    if (root.pluginDir) scanProc.running = true
  }

  // Pantalla del monitor con foco: HyprlandMonitor no expone .screen,
  // se resuelve por nombre contra Quickshell.screens.
  function focusedScreen() {
    var m = Hyprland.focusedMonitor
    if (!m || !m.name) return null
    var ss = Quickshell.screens
    for (var i = 0; i < ss.length; ++i) {
      if (ss[i] && ss[i].name === m.name) return ss[i]
    }
    return null
  }

  function matches(name) {
    return searchText.length === 0
      || name.toLowerCase().indexOf(searchText.toLowerCase()) !== -1
  }

  function appendRow(path, name, thumb) {
    var isCurrent = (path === root.currentVideoPath)
    sourceModel.append({ path: path, name: name, thumb: thumb, current: isCurrent })
    if (matches(name)) filteredModel.append({ path: path, name: name, thumb: thumb, current: isCurrent })
  }

  function updateThumb(path, thumb) {
    for (var i = 0; i < sourceModel.count; i++) {
      if (sourceModel.get(i).path === path) sourceModel.setProperty(i, "thumb", thumb)
    }
    for (var j = 0; j < filteredModel.count; j++) {
      if (filteredModel.get(j).path === path) filteredModel.setProperty(j, "thumb", thumb)
    }
  }

  function rebuildFiltered() {
    filteredModel.clear()
    for (var i = 0; i < sourceModel.count; i++) {
      var it = sourceModel.get(i)
      if (matches(it.name)) filteredModel.append({ path: it.path, name: it.name, thumb: it.thumb, current: it.current })
    }
  }

  function apply(path) {
    if (!path || !root.pluginDir) return
    Quickshell.execDetached(["bash", root.pluginDir + "/scripts/apply-wall.sh", path])
    root.hide()
  }

  // ----------------------------------------------------------------- scan

  Process {
    id: scanProc
    command: root.pluginDir ? ["bash", root.pluginDir + "/scripts/scan.sh", root.wallpaperDir] : ["true"]
    onStarted: console.log("wallpicker: scan started:", command.join(" "))
    onExited: {
      console.log("wallpicker: scan exited:", exitCode)
      if (exitCode !== 0) {
        root.scanError = "Scan fallo (" + exitCode + ")"
        console.warn("wallpicker: scan.sh exit", exitCode)
      }
    }
    stdout: SplitParser {
      onRead: function (line) {
        var parts = String(line).split("\t")
        if (parts[0] === "ROW" && parts.length >= 3) {
          root.appendRow(parts[1], parts[2], parts.length > 3 ? parts[3] : "")
        } else if (parts[0] === "THUMB" && parts.length >= 3) {
          root.updateThumb(parts[1], parts[2])
        } else if (parts[0] === "DONE") {
          root.scanDone = true
        }
      }
    }
  }

  Process {
    id: currentReader
    command: ["cat", root.home + "/.local/state/omarchy/video-wallpaper/last_video.txt"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var p = String(text).trim()
        if (p === root.currentVideoPath) return
        root.currentVideoPath = p
        for (var i = 0; i < sourceModel.count; i++) {
          sourceModel.setProperty(i, "current", sourceModel.get(i).path === p)
        }
        for (var j = 0; j < filteredModel.count; j++) {
          filteredModel.setProperty(j, "current", filteredModel.get(j).path === p)
        }
      }
    }
  }

  // ------------------------------------------------------------- ventana

  PanelWindow {
    id: win
    anchors { top: true; bottom: true; left: true; right: true }
    visible: root.opened
    // Abrir en el monitor con foco (antes siempre caia en el primario DP-1
    // y parecia que el picker "no funcionaba" desde los otros monitores).
    screen: focusedScreen()
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "wallpicker"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened

    // Scrim + click fuera cierra (MouseArea encima del scrim)
    Rectangle {
      anchors.fill: parent
      color: "#b30d0a08"
      opacity: root.opened ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 160 } }
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.hide()
    }

    Item {
      id: panel
      anchors.centerIn: parent
      width: Math.min(parent.width * 0.88, 1280)
      height: Math.min(parent.height * 0.84, 780)
      opacity: root.opened ? 1 : 0
      scale: root.opened ? 1 : 0.96
      Behavior on opacity { NumberAnimation { duration: 180 } }
      Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

      Keys.onEscapePressed: root.hide()

      Rectangle {
        id: bg
        anchors.fill: parent
        color: root.cBg
        border.color: root.cBorder
        border.width: 1
      }

      Column {
        anchors.fill: parent
        anchors.margins: 24
        spacing: 16

        // Header: título + contador + búsqueda
        Item {
          width: parent.width
          height: 44

          Text {
            id: title
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Wallpapers"
            color: root.cText
            font.pixelSize: 20
            font.weight: Font.DemiBold
          }

          Text {
            anchors.left: title.right
            anchors.leftMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            text: filteredModel.count + (root.scanDone ? "" : " · escaneando…")
            color: root.cMuted
            font.pixelSize: 13
          }

          Rectangle {
            id: searchBox
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: 280
            height: 34
            color: root.cCard
            border.color: searchInput.activeFocus ? root.cAccent : root.cBorder
            border.width: 1
            radius: 6

            TextInput {
              id: searchInput
              anchors.fill: parent
              anchors.margins: 8
              anchors.leftMargin: 12
              anchors.rightMargin: 12
              verticalAlignment: TextInput.AlignVCenter
              color: root.cText
              font.pixelSize: 14
              clip: true
              onTextChanged: {
                root.searchText = text
                root.rebuildFiltered()
              }
              Keys.onEscapePressed: root.hide()
              Keys.onDownPressed: {
                grid.currentIndex = 0
                grid.forceActiveFocus()
              }

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                visible: searchInput.text.length === 0 && !searchInput.activeFocus
                text: "Buscar…  (Esc cierra)"
                color: root.cMuted
                font.pixelSize: 13
              }
            }
          }
        }

        // Grid
        Item {
          width: parent.width
          height: parent.height - 60

          GridView {
            id: grid
            anchors.fill: parent
            clip: true
            model: filteredModel
            cellWidth: 212
            cellHeight: 168
            boundsBehavior: Flickable.StopAtBounds
            keyNavigationWraps: true
            cacheBuffer: 600

            Keys.onEscapePressed: root.hide()
            Keys.onReturnPressed: {
              if (currentIndex >= 0 && currentIndex < filteredModel.count)
                root.apply(filteredModel.get(currentIndex).path)
            }

            highlight: Rectangle {
              color: "transparent"
              border.color: root.cAccent
              border.width: 2
            }
            highlightFollowsCurrentItem: true

            delegate: Item {
              id: cell
              width: grid.cellWidth
              height: grid.cellHeight

              property bool hovered: card.containsMouse

              Rectangle {
                id: cardBox
                anchors.fill: parent
                anchors.rightMargin: 16
                anchors.bottomMargin: 16
                color: cell.hovered ? root.cCardHover : root.cCard
                border.color: model.current ? root.cAccent : (cell.hovered ? root.cMuted : root.cBorder)
                border.width: model.current ? 2 : 1

                scale: cell.hovered ? 1.045 : 1
                Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                Behavior on border.color { ColorAnimation { duration: 140 } }

                MouseArea {
                  id: card
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.apply(model.path)
                }

                Image {
                  anchors.fill: parent
                  anchors.margins: 1
                  visible: model.thumb !== ""
                  source: visible ? "file://" + model.thumb : ""
                  asynchronous: true
                  cache: true
                  fillMode: Image.PreserveAspectCrop
                }

                // Placeholder mientras llega la miniatura
                Rectangle {
                  anchors.fill: parent
                  anchors.margins: 1
                  visible: model.thumb === ""
                  color: "#1a1414"

                  Text {
                    anchors.centerIn: parent
                    text: "▶"
                    color: root.cMuted
                    font.pixelSize: 30
                  }
                }

                // Nombre
                Rectangle {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  anchors.margins: 1
                  height: 30
                  color: "#cc110d0b"

                  Text {
                    anchors.fill: parent
                    anchors.margins: 8
                    verticalAlignment: Text.AlignVCenter
                    text: (model.current ? "● " : "") + model.name
                    color: model.current ? root.cAccent : root.cText
                    font.pixelSize: 12
                    elide: Text.ElideMiddle
                  }
                }
              }

              // Entrada escalonada (máx 400ms de delay)
              opacity: 0
              scale: 0.92
              Component.onCompleted: {
                entrance.delay = Math.min(index * 14, 400)
                entrance.start()
              }
              SequentialAnimation {
                id: entrance
                property int delay: 0
                PauseAnimation { duration: entrance.delay }
                ParallelAnimation {
                  NumberAnimation { target: cell; property: "opacity"; to: 1; duration: 200 }
                  NumberAnimation { target: cell; property: "scale"; to: 1; duration: 220; easing.type: Easing.OutCubic }
                }
              }
            }
          }

          // Estado vacío
          Item {
            anchors.fill: parent
            visible: filteredModel.count === 0

            Column {
              anchors.centerIn: parent
              spacing: 10

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.scanError !== "" ? root.scanError
                  : (root.scanDone && sourceModel.count === 0
                    ? "No hay videos en ~/Wallpapers"
                    : (root.searchText.length > 0 ? "Sin resultados para «" + root.searchText + "»" : "Escaneando…"))
                color: root.cMuted
                font.pixelSize: 15
              }
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: root.scanDone && sourceModel.count === 0
                text: root.wallpaperDir
                color: root.cMuted
                font.pixelSize: 12
              }
            }
          }
        }
      }
    }
  }

  // Enfocar búsqueda cada vez que se abre
  onOpenedChanged: {
    if (opened) {
      searchInput.text = ""
      searchInput.forceActiveFocus()
    }
  }

  ListModel { id: sourceModel }
  ListModel { id: filteredModel }
}
