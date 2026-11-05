#!/usr/bin/env bash

# Show the session on Windows. weaselwayd binds the vsock port, and this is
# the FreeRDP client on the Windows side that displays what it serves. It can
# be started before ww-start-session.sh: the window stays empty until a
# compositor is up.

set -eu -o pipefail

# The NixOS image ships the client in the store and points this at it.
VIEWER="${WEASELWAY_VIEWER:-/mnt/c/Weaselway/sdl-freerdp.exe}"

# The port weaselwayd listens on: environment.d gives it to the user manager,
# which is what weaselwayd's unit inherits.
PORT="$(systemctl --user show-environment | sed -n 's/^WEASELWAY_VSOCK_PORT=//p')"
if [ -z "${PORT}" ]; then
    echo "error: WEASELWAY_VSOCK_PORT is not in the user manager's environment -- is environment.d/10-weaselway.conf installed?" >&2
    exit 1
fi

# The Hyper-V VM the client connects to. wslinfo is WSL's own /init under
# another name; NixOS-WSL does not link it into /bin, so fall back to calling
# /init by that name directly.
if command -v wslinfo > /dev/null; then
    VM_ID="$(wslinfo --vm-id -n)"
else
    VM_ID="$(exec -a wslinfo /init --vm-id -n)"
fi

# The NT object directory behind the "wslg" shared-memory share, which the
# client maps to read the frames weaselwayd writes there. WSL names it after the VM
# (WslCoreVm::InitializeGuest in microsoft/WSL), with the ID in upper case.
SHARED_MEMORY_PATH="WSL\\${VM_ID^^}\\wslg"

# That directory exists only in the Windows logon session that started the VM.
# Started from another one (SSH, Remote Desktop, a scheduled task) the client
# cannot map the frames and its window stays white, so say so instead, in a
# message box as well: the shortcut's console is minimized. Opening the
# directory as a section fails with "invalid handle" if it is there and "not
# found" if it is not; only the latter is exit status 3. Not in session 0,
# where nobody would see the box to close it.
POWERSHELL=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
MESSAGE="This Windows session cannot see the shared memory of the WSL VM: WSL was started from another Windows session (SSH, Remote Desktop, a scheduled task). Run wsl --shutdown, then start the distro again from this desktop."

# Returns 3 if the section is not there, 0 otherwise (also when PowerShell is
# not available). Runs alongside the viewer in both modes, so that its startup
# overlaps with the viewer's instead of delaying it.
check_shared_memory() {
    [ -x "${POWERSHELL}" ] || return 0
    (cd /mnt/c && "${POWERSHELL}" -NoProfile -NonInteractive -Command "
        try { [IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting('${SHARED_MEMORY_PATH}') }
        catch [IO.DirectoryNotFoundException] {
            if ([Diagnostics.Process]::GetCurrentProcess().SessionId -ne 0) {
                (New-Object -ComObject WScript.Shell).Popup('${MESSAGE}', 0, 'Weaselway', 16) | Out-Null
            }
            exit 3
        } catch {}" < /dev/null > /dev/null 2>&1)
}

# The desktop size the client asks for at connect. With /dynamic-resolution it
# follows later window resizes.
COMMAND=(
    "${VIEWER}" /u:dummy /d:dummy /p:dummy
    /v:vsock://"${VM_ID}":"${PORT}"
    /wslgsharedmemorypath:"${SHARED_MEMORY_PATH}"
    /cert:ignore
    /dynamic-resolution
    /w:1920
    /h:1080
    /log-level:warn
    /multitouch
    /sdl-touchpad-gestures
    /audio-mode:redirect
    /microphone
    "$@"
)

# DEBUG=1 runs the viewer in the foreground, with its log on the terminal. It
# starts in the background anyway so that the check overlaps with its startup;
# wait makes it foreground again. If the check fails, the viewer is stopped
# before the error is printed.
if [ "${DEBUG:-}" = 1 ]; then
    "${COMMAND[@]}" &
    VIEWER_PID=$!
    # The shortcut stops this script when the session fails to start; take the
    # viewer along, since it is a child now, not the process the shortcut sees.
    trap 'kill "${VIEWER_PID}" 2> /dev/null || true' TERM INT
    STATUS=0
    check_shared_memory || STATUS=$?
    if [ "${STATUS}" = 3 ]; then
        kill "${VIEWER_PID}" 2> /dev/null || true
        wait "${VIEWER_PID}" 2> /dev/null || true
        echo "error: ${MESSAGE}" >&2
        exit 1
    fi
    wait "${VIEWER_PID}" || exit $?
    exit 0
fi

# Otherwise it runs on in the background, in a session of its own so that
# closing the terminal does not end it, with its log in a file.
LOG="${XDG_RUNTIME_DIR:-/tmp}/weaselway-viewer.log"
setsid "${COMMAND[@]}" > "${LOG}" 2>&1 < /dev/null &
VIEWER_PID=$!
disown

# The check runs while the viewer starts. PowerShell takes about a second to
# come up, which is also long enough for a viewer that cannot start to exit;
# failures after that end up in the log.
STATUS=0
check_shared_memory || STATUS=$?
if [ "${STATUS}" = 3 ]; then
    kill "${VIEWER_PID}" 2> /dev/null || true
    echo "error: ${MESSAGE}" >&2
    exit 1
fi

# Without PowerShell the check returned at once and there was no grace period.
if [ ! -x "${POWERSHELL}" ]; then
    sleep 0.5
fi

if ! kill -0 "${VIEWER_PID}" 2> /dev/null; then
    echo "error: the viewer exited; its log ($LOG):" >&2
    cat "${LOG}" >&2
    exit 1
fi

echo "The viewer is running. Its log: ${LOG}"
echo "To see the log on the terminal instead: DEBUG=1 ww-start-viewer"
