import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui

BarWidget {
  id: root
  moduleName: "cristiansrc.gamemode"

  readonly property string flagPath: "~/.local/state/omarchy/game-mode/active".replace("~", Quickshell.env("HOME"))
  readonly property string scriptPath: Quickshell.env("HOME") + "/.local/bin/gamemode-toggle.sh"

  property bool gamemodeOn: false

  Process {
    id: checkProc
    command: ["sh", "-c", "test -f " + root.flagPath + " && echo on || echo off"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.gamemodeOn = (text.trim() === "on")
    }
  }

  Timer {
    interval: 2000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: checkProc.running = true
  }

  // Glifo gamepad (FA U+F11B) via fromCharCode: inmune a problemas de encoding del archivo
  readonly property string iconText: String.fromCharCode(0xF11B)
  readonly property string tip: gamemodeOn
    ? "Modo Juego ACTIVO — click para restaurar"
    : "Modo Juego — click para activar (fondo estático, sin blur/animaciones)"

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.iconText
    active: root.gamemodeOn
    tooltipText: root.tip
    onPressed: function(b) {
      if (b === Qt.LeftButton) {
        root.bar.run(root.scriptPath)
      }
    }
  }
}
