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

  // From `orphusbot watch`: { running, needs_you, bots: [...], waiting: [...] }.
  property var status: ({ running: 0, needs_you: 0, bots: [], waiting: [] })
  property string problem: "Connecting…"
  property string chosenBot: "inbox"
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
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(600))

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

        PanelSeparator { visible: root.status.waiting.length > 0; foreground: root.foreground }

        Column {
          visible: root.status.waiting.length > 0
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader { text: "NEEDS YOU"; foreground: root.foreground; fontFamily: root.fontFamily }

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

        PanelSectionHeader { text: "BOTS"; foreground: root.foreground; fontFamily: root.fontFamily }

        Repeater {
          model: root.status.bots
          Item {
            required property var modelData
            width: column.width
            implicitHeight: botName.implicitHeight + Style.space(4)

            Text {
              id: botName
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: modelData.name
              textFormat: Text.PlainText
              color: modelData.slug === root.chosenBot ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: modelData.slug === root.chosenBot
            }
            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: modelData.waiting > 0 ? "needs you" : modelData.state
              color: modelData.waiting > 0 ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            MouseArea {
              anchors.fill: parent
              onClicked: root.chosenBot = modelData.slug
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        Row {
          width: parent.width
          spacing: Style.space(6)

          TextField {
            id: messageField
            width: parent.width - sendButton.width - Style.space(6)
            placeholderText: "Message " + root.chosenBot + " (pick a bot above)"
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

        // What the chosen bot is doing, and its latest answer.
        Text {
          visible: root.chosen !== null
          width: parent.width
          text: !root.chosen ? ""
            : (root.chosen.state === "running" || root.chosen.state === "queued")
              ? root.chosen.name + " is working…"
              : (root.chosen.reply ? root.chosen.name + ": " + root.chosen.reply : root.chosen.name + " hasn't said anything yet.")
          textFormat: Text.PlainText
          color: root.chosen && root.chosen.reply && root.chosen.state === "idle" ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
