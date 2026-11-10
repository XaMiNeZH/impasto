// ╭──────────────────────────────────────────────────────────────────────────╮
// │                                                                          │
// │   P O L K I T   S E R V I C E                                            │
// │   the session's authentication agent · asked on the island               │
// │                                                                          │
// │   github.com/andreumassanet/impasto                                      │
// │                                                                          │
// ╰──────────────────────────────────────────────────────────────────────────╯

pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Services.Polkit

// The shell is the session's polkit agent: a program asking for root asks
// here, and the island opens on it. One agent per session, so Hyprland
// starts none.
//
// Quickshell registers once per process and a reload inherits that
// registration, failed or not, so an agent that has not registered is built
// again; only a new agent asks again. After three tries the KDE agent is
// started instead, so a request never goes unanswered.
Singleton {
    id: root

    readonly property var agent: holder.item
    readonly property var flow: root.agent?.flow ?? null
    readonly property bool asking: (root.agent?.isActive ?? false) && root.flow !== null
    readonly property bool registered: root.agent?.isRegistered ?? false

    // Set by a refused password, cleared by the next key.
    property bool failed: false

    // A request has come in; `shell.qml` opens the island on it.
    signal requested()
    // It has been answered, either way; the island closes.
    signal settled()

    // Arch installs the agent under /usr/lib. Fedora's kf6 package installs
    // it under /usr/libexec/kf6. The first one that is executable wins.
    readonly property var fallbacks: [
        "/usr/lib/polkit-kde-authentication-agent-1",
        "/usr/libexec/kf6/polkit-kde-authentication-agent-1",
        "/usr/libexec/polkit-kde-authentication-agent-1"
    ]
    readonly property int tries: 3
    property int tried: 0

    LazyLoader {
        id: holder

        active: true

        PolkitAgent {
            onAuthenticationRequestStarted: {
                root.failed = false
                root.requested()
            }

            onIsActiveChanged: {
                if (!isActive)
                    root.settled()
            }
        }
    }

    Connections {
        target: root.flow
        ignoreUnknownSignals: true

        function onAuthenticationFailed(): void {
            root.failed = true
        }
    }

    function submit(password: string): void {
        if (root.flow && root.flow.isResponseRequired)
            root.flow.submit(password)
    }

    function cancel(): void {
        if (root.flow && !root.flow.isCompleted)
            root.flow.cancelAuthenticationRequest()
    }

    // Registration is asynchronous, and an agent rebuilt while it is still
    // registering leaves the reply nowhere to land: give each one long
    // enough that only a failure is still unregistered.
    readonly property Timer watch: Timer {
        interval: 6000
        running: !root.registered && root.tried < root.tries
        repeat: true
        onTriggered: {
            if (root.registered)
                return
            root.tried += 1
            if (root.tried >= root.tries) {
                Quickshell.execDetached(["sh", "-c",
                    root.fallbacks.map(path => `test -x ${path} && exec ${path}`).join("; ")])
                return
            }
            holder.active = false
            holder.active = true
        }
    }
}
