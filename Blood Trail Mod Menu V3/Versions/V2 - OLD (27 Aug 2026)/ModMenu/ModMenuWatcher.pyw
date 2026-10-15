"""
Blood Trail Mod Menu - auto-open watcher.

Sits quietly in the background and opens the control panel the moment Blood
Trail starts, then closes it again when you quit the game.

Why a watcher instead of a launcher script: it does not care HOW the game was
started. Oculus / Meta Quest Link, the Oculus dash inside the headset, Steam,
Steam VR, or the .exe directly - all of them end up running
BTVR-Win64-Shipping.exe, and that is what this looks for. A launcher .bat only
works if you remember to use the .bat.

Runs as .pyw so there is never a console window. Uses only the standard library.
"""

import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PANEL = os.path.join(HERE, "BloodTrailModMenu.py")

GAME_EXE = "BTVR-Win64-Shipping.exe"
POLL_SECONDS = 3

# Close the panel when the game exits. Set to False to leave it open.
CLOSE_WITH_GAME = True

CREATE_NO_WINDOW = 0x08000000


def game_running():
    """True if the Blood Trail process exists.

    Uses the ToolHelp snapshot API directly rather than shelling out to
    tasklist. Spawning a process every few seconds while a VR game is running is
    exactly the kind of background hitch you feel in a headset, and creating a
    snapshot in-process costs almost nothing.
    """
    import ctypes
    from ctypes import wintypes

    TH32CS_SNAPPROCESS = 0x00000002
    INVALID_HANDLE = ctypes.c_void_p(-1).value

    class PROCESSENTRY32W(ctypes.Structure):
        _fields_ = [("dwSize", wintypes.DWORD),
                    ("cntUsage", wintypes.DWORD),
                    ("th32ProcessID", wintypes.DWORD),
                    ("th32DefaultHeapID", ctypes.POINTER(ctypes.c_ulong)),
                    ("th32ModuleID", wintypes.DWORD),
                    ("cntThreads", wintypes.DWORD),
                    ("th32ParentProcessID", wintypes.DWORD),
                    ("pcPriClassBase", ctypes.c_long),
                    ("dwFlags", wintypes.DWORD),
                    ("szExeFile", ctypes.c_wchar * 260)]

    k32 = ctypes.windll.kernel32
    snap = k32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    if snap == INVALID_HANDLE:
        return False
    try:
        entry = PROCESSENTRY32W()
        entry.dwSize = ctypes.sizeof(PROCESSENTRY32W)
        target = GAME_EXE.lower()
        if not k32.Process32FirstW(snap, ctypes.byref(entry)):
            return False
        while True:
            if entry.szExeFile.lower() == target:
                return True
            if not k32.Process32NextW(snap, ctypes.byref(entry)):
                return False
    except Exception:
        return False
    finally:
        k32.CloseHandle(snap)


def panel_already_open():
    """True if a control panel is already running.

    The panel holds a named mutex for exactly this. Without the check, launching
    the game from the .bat (which opens the panel itself) would have the watcher
    start a second one - the "two mod menus" problem.
    """
    try:
        import ctypes
        MUTEX_ALL_ACCESS = 0x1F0001
        h = ctypes.windll.kernel32.OpenMutexW(
            MUTEX_ALL_ACCESS, False, "Global\\BloodTrailModMenu_SingleInstance")
        if h:
            ctypes.windll.kernel32.CloseHandle(h)
            return True
    except Exception:
        pass
    return False


def launch_panel():
    """Start the control panel windowless, and hand back the process."""
    for exe in ("pythonw.exe", "pyw.exe"):
        try:
            return subprocess.Popen([exe, PANEL], cwd=HERE,
                                    creationflags=CREATE_NO_WINDOW)
        except FileNotFoundError:
            continue
    # last resort: whatever python is on PATH
    try:
        return subprocess.Popen([sys.executable, PANEL], cwd=HERE,
                                creationflags=CREATE_NO_WINDOW)
    except Exception:
        return None


def main():
    panel = None
    was_running = False

    while True:
        running = game_running()

        if running and not was_running:
            # game just started - open the panel unless one is already up
            # (the launcher .bat may have opened it a moment ago)
            if (panel is None or panel.poll() is not None) \
                    and not panel_already_open():
                panel = launch_panel()

        elif not running and was_running and CLOSE_WITH_GAME:
            # game just closed - take the panel down with it
            if panel is not None and panel.poll() is None:
                try:
                    panel.terminate()
                except Exception:
                    pass
            panel = None

        was_running = running
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()
