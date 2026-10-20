import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Commons
import qs.Ui

// OrphusBot in the bar. Everything goes through the `orphusbot` command
// (crates/cli): `watch` streams one JSON status line per change, `answer`
// answers a card, `send` messages a bot. Sign in once with `orphusbot link`.
Panel {
  id: root
  moduleName: "kelvincushman.orphusbot"
  ipcTarget: "kelvincushman.orphusbot"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string command: settings && settings.command ? String(settings.command) : "orphusbot"
  readonly property string appCommand: settings && settings.app ? String(settings.app) : "orphusbot-app"

  // From `orphusbot watch`: { running, needs_you, bots: [...], waiting: [...] }.
  property var status: ({ running: 0, needs_you: 0, bots: [], waiting: [] })
  property string problem: "Connecting…"
  property string chosenBot: "orchestrator"
  property string note: ""

  // The chosen bot's entry in the status, for its state and latest reply.
  readonly property var chosen: {
    var bots = status.bots || []
    for (var i = 0; i < bots.length; i++) if (bots[i].slug === chosenBot) return bots[i]
    return null
  }

  // The bar sizes each slot from the root's implicit size (see the NetBird widget).
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) Qt.callLater(function() { messageField.forceActiveFocus() })

  Process {
    id: watcher
    command: [root.command, "watch", "--notify"]
    running: true
    stdout: SplitParser {
      onRead: function(line) {
        try {
          root.status = JSON.parse(line)
          root.problem = ""
        } catch (e) {}
      }
    }
    stderr: SplitParser {
      onRead: function(line) { if (String(line).trim() !== "") root.problem = String(line).trim() }
    }
    // It stops if the server goes away or the session ends; try again shortly.
    onExited: function(exitCode) { restart.start() }
  }

  // The full app (apps/orphusbot_app): history, pictures and files, approvals.
  Process {
    id: launcher
    running: false
    command: ["sh", "-c", "setsid -f " + root.appCommand + " >/dev/null 2>&1"]
  }

  Timer {
    id: restart
    interval: 10000
    onTriggered: watcher.running = true
  }

  Process {
    id: action
    running: false
    command: []
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.note = exitCode === 0 ? root.note : String(actionErr.text || "That didn't work").trim()
    }
  }

  function run(args, done) {
    if (action.running) return
    note = done
    action.command = [root.command].concat(args)
    action.running = true
  }

  function send() {
    var text = messageField.text.trim()
    if (text === "") return
    run(["send", chosenBot, text], "Sent to " + chosenBot + ".")
    messageField.text = ""
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function status(): string { return JSON.stringify(root.status) }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // A chat bubble; omarchy.agents already uses the robot glyph.
    text: root.status.needs_you > 0 ? "󰻞" : "󰭹"
    active: root.status.needs_you > 0
    dimmed: root.problem !== "" || (root.status.running === 0 && root.status.needs_you === 0)
    onPressed: function(buttonCode) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: messageField
    contentWidth: panel.fittedContentWidth(Style.space(640))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    Flickable {
      id: flick
      anchors.fill: parent
      contentWidth: width
      contentHeight: column.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: column
        width: flick.width
        spacing: Style.space(12)

        Button {
          text: "Open chat"; iconText: "󰍩"; bordered: true; foreground: root.foreground; fontFamily: root.fontFamily
          onClicked: { launcher.running = true; root.close() }
        }

        PanelHero {
          width: parent.width
          title: "OrphusBot"
          meta: root.problem !== ""
            ? root.problem
            : (root.status.running + " working · " + root.status.needs_you + " need you")
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Text {
          visible: root.note !== ""
          width: parent.width
          text: root.note
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        // Approvals come first and span the panel: they're what the owner must act on.
        Column {
          visible: root.status.waiting.length > 0
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader { text: "NEEDS YOU"; foreground: root.urgent; fontFamily: root.fontFamily }

          Repeater {
            model: root.status.waiting
            Column {
              required property var modelData
              width: parent.width
              spacing: Style.space(4)

              Text {
                width: parent.width
                text: modelData.name + ": " + modelData.text
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }

              Row {
                visible: modelData.approval
                spacing: Style.space(6)
                Button {
                  text: "Allow once"; bordered: true; foreground: root.foreground; fontFamily: root.fontFamily
                  onClicked: root.run(["answer", modelData.id, "allow"], "Allowed.")
                }
                Button {
                  text: "Always"; bordered: true; foreground: root.foreground; fontFamily: root.fontFamily
                  onClicked: root.run(["answer", modelData.id, "always"], "Always allowed.")
                }
                Button {
                  text: "Deny"; bordered: true; foreground: root.urgent; fontFamily: root.fontFamily
                  onClicked: root.run(["answer", modelData.id, "deny"], "Denied.")
                }
              }

              Text {
                visible: !modelData.approval
                text: "Answer this in the OrphusBot app."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        // Bots on the left; the chosen bot's conversation on the right, with the
        // message box at the bottom and the latest exchange above it.
        Row {
          id: body
          width: parent.width
          height: Math.max(bots.implicitHeight, Style.space(280))
          spacing: Style.space(12)

          Column {
            id: bots
            width: Style.space(150)
            spacing: Style.space(2)

            PanelSectionHeader { text: "BOTS"; foreground: root.foreground; fontFamily: root.fontFamily }

            Repeater {
              model: root.status.bots
              Rectangle {
                required property var modelData
                readonly property bool picked: modelData.slug === root.chosenBot
                width: bots.width
                height: Math.max(botName.implicitHeight, botFace.height) + Style.space(6)
                radius: Style.space(4)
                color: picked ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12) : "transparent"

                // The bot's face (faces/<bot>-<state>.webp, made by design/bot-avatar/frames.sh):
                // resting, thinking (queued), working, or red when it needs you.
                AnimatedImage {
                  id: botFace
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(4)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(26); height: width
                  // Each house bot has its own style; others get the default face.
                  property bool ownStyle: true
                  source: "faces/" + (ownStyle ? (modelData.face || modelData.slug) : "default") + "-"
                    + (modelData.waiting > 0 ? 3
                    : modelData.state === "running" ? 2
                    : modelData.state === "queued" ? 1 : 0) + ".webp"
                  onStatusChanged: if (status === Image.Error && ownStyle) ownStyle = false
                  playing: root.opened
                  smooth: true
                  mipmap: true
                }
                Text {
                  id: botName
                  anchors.left: botFace.right
                  anchors.leftMargin: Style.space(6)
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.name
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  color: modelData.waiting > 0 ? root.urgent : (picked ? root.foreground : root.dim)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: picked
                }
                MouseArea {
                  anchors.fill: parent
                  onClicked: { root.chosenBot = modelData.slug; messageField.forceActiveFocus() }
                }
              }
            }
          }

          Rectangle { width: 1; height: body.height; color: root.foreground; opacity: 0.15 }

          Item {
            id: chat
            width: body.width - bots.width - Style.space(25)
            height: body.height

            Flickable {
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: messageRow.top
              anchors.bottomMargin: Style.space(10)
              contentHeight: exchange.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              // Keep the newest text in view, like a chat.
              contentY: Math.max(0, contentHeight - height)

              Column {
                id: exchange
                width: parent.width
                spacing: Style.space(10)

                PanelSectionHeader {
                  text: root.chosen ? root.chosen.name.toUpperCase() : ""
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }
                Text {
                  visible: root.chosen !== null && root.chosen.asked !== ""
                  width: parent.width
                  text: root.chosen ? "You: " + root.chosen.asked : ""
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  wrapMode: Text.WordWrap
                }
                Text {
                  width: parent.width
                  text: !root.chosen ? ""
                    : (root.chosen.state === "running" || root.chosen.state === "queued")
                      ? root.chosen.name + " is working…"
                      : (root.chosen.reply ? root.chosen.name + ": " + root.chosen.reply : "Say hello to " + root.chosen.name + ".")
                  textFormat: Text.PlainText
                  color: root.chosen && root.chosen.state === "idle" && root.chosen.reply ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  wrapMode: Text.WordWrap
                }
              }
            }

            Row {
              id: messageRow
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              spacing: Style.space(6)

              TextField {
                id: messageField
                width: parent.width - sendButton.width - Style.space(6)
                placeholderText: "Message " + (root.chosen ? root.chosen.name : root.chosenBot)
                foreground: root.foreground
                font.family: root.fontFamily
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.send(); event.accepted = true }
                  else if (event.key === Qt.Key_Escape) { root.close(); event.accepted = true }
                }
              }
              Button {
                id: sendButton
                text: "Send"; bordered: true; foreground: root.foreground; fontFamily: root.fontFamily
                onClicked: root.send()
              }
            }
          }
        }
      }
    }
  }
}
