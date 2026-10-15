"""
Blood Trail Mod Menu - desktop control panel.

Talks to the in-game UE4SS Lua mod through two text files in this folder:
    control.txt   we write it, the mod reads it  (all toggles + a command slot)
    status.txt    the mod writes it, we read it  (health, pawn, enemies, kills)

Nothing here needs the game to be running - if it is not, the panel just shows
"game not running" and everything you set is picked up the moment it starts.

Run it with Launch Mod Menu.bat, or:  py BloodTrailModMenu.py
"""

import base64
import ctypes
import json
import os
import random
import subprocess
import sys
import threading
import time
import tkinter as tk
import unicodedata
from tkinter import filedialog, messagebox, ttk

WINDOW_TITLE = "Blood Trail Mod Menu"


def claim_single_instance():
    """Exit if a panel is already open, focusing the existing window instead.

    There are several ways the panel gets started - the launcher .bat, the
    watcher when the game appears, a manual double-click - and more than one can
    fire for a single play session. Without this you end up with two identical
    windows fighting over the same control.txt.

    A named mutex is used rather than a lock file: Windows releases it when the
    process dies, so a crash can never leave a stale lock behind.
    """
    ERROR_ALREADY_EXISTS = 183
    try:
        kernel32 = ctypes.windll.kernel32
        # keep a reference on the module so the handle outlives this function
        globals()["_instance_mutex"] = kernel32.CreateMutexW(
            None, False, "Global\\BloodTrailModMenu_SingleInstance")
        if kernel32.GetLastError() != ERROR_ALREADY_EXISTS:
            return True
    except Exception:
        return True     # if the check itself fails, better to open than not

    # already running - surface the window that is already there, unless the
    # game asked for us: then the player is in the headset, and pulling a
    # window to the front would take focus away from the game for nothing
    if "--from-game" in sys.argv:
        return False
    try:
        user32 = ctypes.windll.user32
        hwnd = user32.FindWindowW(None, WINDOW_TITLE)
        if hwnd:
            user32.ShowWindow(hwnd, 9)          # SW_RESTORE
            user32.SetForegroundWindow(hwnd)
    except Exception:
        pass
    return False

HERE = os.path.dirname(os.path.abspath(__file__))

# The mod reads control.txt out of the ModMenu folder inside the game install.
# Running this app from the source copy on E: would otherwise write the file
# somewhere the game never looks, so prefer the installed folder when it exists
# and fall back to our own folder (which is what happens once this file has been
# installed alongside the mod).
GAME_MODMENU = (r"D:\SteamLibrary\steamapps\common\Blood Trail"
                r"\BTVR\Binaries\Win64\Mods\ModMenu")

def _bridge_dir():
    if os.path.isdir(os.path.join(GAME_MODMENU, "Scripts")):
        return GAME_MODMENU
    # EVERYONE ELSE'S GAME (2026-10-15). Frozen by PyInstaller, HERE is the
    # temporary extraction folder, so on any PC without the game at the path
    # above the exe wrote control.txt where the mod never looks - the panel
    # never reached the headset. The exe sits in the installed ModMenu folder.
    if getattr(sys, "frozen", False):
        own = os.path.dirname(os.path.abspath(sys.executable))
        if os.path.isdir(os.path.join(own, "Scripts")):
            return own
    return HERE

BRIDGE = _bridge_dir()
CONTROL = os.path.join(BRIDGE, "control.txt")
CONTROL_TMP = os.path.join(BRIDGE, "control.tmp")
STATUS = os.path.join(BRIDGE, "status.txt")
LASTPAWN = os.path.join(BRIDGE, "lastpawn.txt")
# DATA FILES AND THE .EXE
#
# Frozen by PyInstaller, __file__ (and therefore HERE) points into a temporary
# extraction folder, NOT to where the exe lives. Resolving the spawn/map/caps
# lists from HERE meant the exe launched fine but came up with an empty Spawn
# tab, an empty Maps tab and no pawn-capability greying - "the exe does not have
# all the stuff the panel has".
#
# Look in three places, in order: beside the exe (so a user can edit the lists),
# then the bundle PyInstaller unpacked (so it works standalone), then the source
# folder (running as a plain script).
def _data_path(name):
    roots = []
    if getattr(sys, "frozen", False):
        roots.append(os.path.dirname(os.path.abspath(sys.executable)))
        mei = getattr(sys, "_MEIPASS", None)
        if mei:
            roots.append(mei)
    roots.append(HERE)
    roots.append(BRIDGE)
    for r in roots:
        p = os.path.join(r, name)
        if os.path.isfile(p):
            return p
    return os.path.join(roots[0], name)

SPAWNLIST = _data_path("spawnlist.json")
PAWNCAPS = _data_path("pawn_caps.json")
MAPLIST = _data_path("maplist.json")

# Considered live if the mod refreshed status.txt within this many seconds.
STALE_AFTER = 3.0

BG = "#15171c"
PANEL = "#1e2129"
FG = "#e6e8ee"
MUTED = "#8b93a7"
ACCENT = "#3ddc84"
DANGER = "#ff6b6b"
HEADING = "#5d6680"
MUSIC_JSON = os.path.join(BRIDGE, "music.json")

# Started by the in-game MUSIC tab (Start Music Player.bat passes this): open
# minimised, and close again once the game has gone.
FROM_GAME = "--from-game" in sys.argv

# The player's own playlist, used whenever no other folder has been chosen.
PREFERRED_MUSIC = r"D:\music"


def default_music_folder():
    if os.path.isdir(PREFERRED_MUSIC):
        return PREFERRED_MUSIC
    return os.path.join(os.path.expanduser("~"), "Music")


# The QUICK folders on the in-game picker, in the same order as
# Music.PRESETS in music.lua - the headset sends the index.
MUSIC_PRESETS = [
    ("D:\\music", PREFERRED_MUSIC),
    ("My Music", os.path.join(os.path.expanduser("~"), "Music")),
    ("Downloads", os.path.join(os.path.expanduser("~"), "Downloads")),
    ("Desktop", os.path.join(os.path.expanduser("~"), "Desktop")),
]
BROWSE_LIST_MAX = 40        # folder names sent to the headset per page


def ascii_path(path, limit=44):
    """A folder path the headset can show: ASCII, and the END kept if long."""
    text = ascii_title(path or "", 400)
    if len(text) > limit:
        text = "..." + text[-(limit - 3):]
    return text


def list_drives():
    """Drive roots that are actually there (C:\\, D:\\ ...), without touching
    empty card readers or disc drives, which can stall or pop a dialog."""
    out = []
    try:
        mask = ctypes.windll.kernel32.GetLogicalDrives()
        for i in range(26):
            if mask & (1 << i):
                root = "%s:\\" % chr(65 + i)
                kind = ctypes.windll.kernel32.GetDriveTypeW(root)
                if kind in (2, 3, 4):       # removable, fixed, network
                    out.append(root)
    except Exception:
        pass
    return out


def scan_folder(path):
    """(subfolder names, number of songs directly in it) for the picker."""
    if not path:
        return list_drives(), 0
    dirs, songs = [], 0
    try:
        with os.scandir(path) as it:
            for entry in it:
                name = entry.name
                try:
                    if entry.is_dir():
                        if name.startswith(("$", ".")) or name == "System Volume Information":
                            continue
                        dirs.append(name)
                    elif name.lower().endswith(MusicPlayer.EXTS):
                        songs += 1
                except OSError:
                    continue
    except OSError:
        pass
    dirs.sort(key=str.lower)
    return dirs, songs


class SideTabs(tk.Frame):
    """A vertical tab bar, used in place of ttk.Notebook.

    Fourteen tabs do not fit across the top of a window this size - ttk simply
    squeezes the labels until they are unreadable. This offers the same
    `add(child, text=...)` the rest of the file already calls, so every tab
    builder works unchanged: children are created with this widget as their
    parent, and the one selected is packed beside the bar.
    """

    def __init__(self, parent):
        super().__init__(parent, bg=BG)
        self.bar = tk.Frame(self, bg=PANEL)
        self.bar.pack(side="left", fill="y")
        self.pages = []
        self.current = None

    def heading(self, text):
        tk.Label(self.bar, text=text.upper(), bg=PANEL, fg=HEADING,
                 font=("Segoe UI", 7, "bold"), anchor="w").pack(
                     fill="x", padx=14, pady=(6, 0))

    def add(self, child, text=""):
        btn = tk.Button(self.bar, text=text, anchor="w", relief="flat", bd=0,
                        bg=PANEL, fg=MUTED, activebackground=BG,
                        activeforeground=ACCENT, font=("Segoe UI", 10),
                        padx=16, pady=2, cursor="hand2",
                        command=lambda c=child: self.select(c))
        btn.pack(fill="x")
        self.pages.append((text, child, btn))
        if self.current is None:
            self.select(child)

    def select(self, child):
        for _name, c, b in self.pages:
            if c is child:
                c.pack(side="left", fill="both", expand=True)
                b.config(bg=BG, fg=ACCENT, font=("Segoe UI", 10, "bold"))
            else:
                c.pack_forget()
                b.config(bg=PANEL, fg=MUTED, font=("Segoe UI", 10))
        self.current = child


def ascii_title(text, limit=40):
    """A song title the headset can show and control.txt can carry.

    The in-game panel is a TextRender whose font has turned non-ASCII into
    mojibake before, and '=' or a newline would corrupt the key=value file.
    Accents are folded (Beyonce, not Beyonc?) before anything is dropped.
    """
    text = unicodedata.normalize("NFKD", text or "").encode("ascii", "ignore").decode()
    text = "".join(ch if 32 <= ord(ch) < 127 and ch not in "=" else " " for ch in text)
    text = " ".join(text.split())
    return text[:limit]


# ---------------------------------------------------------------------------
# THE MUSIC PLAYER, AND WHY IT STOPPED USING MCI (2026-09-20)
#
# "the music player while playing any song even the game not even opened but
#  it will do worse while the game opened like 2x as bad it will lag & glitch
#  out like crazy bad"
#
# Measured against the real 706-track library on this machine:
#
#     bitrate      files sampled     winmm/MCI opened
#     320 kbps          27                  0
#     128 kbps           7                  2
#      64 kbps           5                  7 of 16
#
# Two thirds of the library is 320 kbps and MCI opens NONE of it. The files
# are fine - the same nine files, including every 320 kbps one, open in ~300 ms
# each through Windows' modern media stack, first try, 9 of 9.
#
# So the stutter was never really a caching problem. Every track change walked
# into a refusal, paid 50-400 ms FOR NOTHING, and handed on to the next file
# up to ten deep - a second or more of frozen window, over and over, because
# mciSendStringW is synchronous and was being called ON THE TK THREAD, which
# is the thread that draws the window.
#
# Two changes, and they fix different halves of it:
#
#   1. A DIFFERENT ENGINE. System.Windows.Media.MediaPlayer sits on Media
#      Foundation, the same decoder the rest of Windows uses. It plays the
#      whole library. Nothing to install - it is part of .NET, which ships
#      with Windows.
#
#   2. A DIFFERENT PROCESS. The engine runs in a child process and is spoken
#      to over a pipe. Writing a line to a pipe costs microseconds and CANNOT
#      block on the audio device, so opening, seeking and decoding happen
#      somewhere the window cannot feel them. Position and state arrive on a
#      background reader thread; everything the UI asks for is a dictionary
#      lookup. That is why it is worse with the game running - the old design
#      made the UI thread wait on a busy audio device, and the game keeps the
#      audio device busy.
#
# MCI is kept as a fallback for a machine where the child will not start. It
# still only plays a third of this library, but a third beats silence.
# ---------------------------------------------------------------------------

CREATE_NO_WINDOW = 0x08000000
ABOVE_NORMAL_PRIORITY_CLASS = 0x00008000

# The child. Reads one command per line on stdin, writes one event per line on
# stdout, both tab-separated. It must pump the WPF dispatcher for MediaPlayer's
# events to arrive, so stdin is read asynchronously rather than blocking.
# The audio engine that can choose a device, as source. It is compiled by
# the child at startup and sent to it down the pipe - it is far too big for
# a command line, and shipping it as a loose file would be one more thing
# to lose. See MediaEngine for why a second engine exists at all.
_PLAYER_CS = r"""
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

namespace BtAudio
{
    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
        int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection
    {
        int GetCount(out int count);
        int Item(int index, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        int Activate(ref Guid iid, int clsCtx, IntPtr activationParams,
                     [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        int OpenPropertyStore(int access, out IPropertyStore properties);
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        int GetState(out int state);
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore
    {
        int GetCount(out int count);
        int GetAt(int index, out PROPERTYKEY key);
        int GetValue(ref PROPERTYKEY key, out PROPVARIANT value);
        int SetValue(ref PROPERTYKEY key, ref PROPVARIANT value);
        int Commit();
    }

    [ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioMeterInformation
    {
        int GetPeakValue(out float peak);
    }

    // Undocumented, but it is the only thing that moves the default endpoint.
    [ComImport, Guid("F8679F50-850A-41CF-9C72-430F290290C8"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPolicyConfig
    {
        int GetMixFormat(string id, IntPtr f);
        int GetDeviceFormat(string id, bool def, IntPtr f);
        int ResetDeviceFormat(string id);
        int SetDeviceFormat(string id, IntPtr a, IntPtr b);
        int GetProcessingPeriod(string id, bool def, IntPtr a, IntPtr b);
        int SetProcessingPeriod(string id, IntPtr p);
        int GetShareMode(string id, IntPtr m);
        int SetShareMode(string id, IntPtr m);
        int GetPropertyValue(string id, bool store, ref PROPERTYKEY k, out PROPVARIANT v);
        int SetPropertyValue(string id, bool store, ref PROPERTYKEY k, ref PROPVARIANT v);
        int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string id, int role);
        int SetEndpointVisibility(string id, bool visible);
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROPERTYKEY { public Guid fmtid; public int pid; }

    [StructLayout(LayoutKind.Explicit)]
    struct PROPVARIANT
    {
        [FieldOffset(0)] public short vt;
        [FieldOffset(8)] public IntPtr pointerValue;
    }

    public static class Devices
    {
        static readonly Guid CLSID_MMDeviceEnumerator =
            new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E");
        static readonly Guid CLSID_PolicyConfigClient =
            new Guid("870AF99C-171D-4F9E-AF0D-E63DF40C2BC9");
        static readonly Guid IID_IAudioMeterInformation =
            new Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064");

        static IMMDeviceEnumerator Enumerator()
        {
            Type t = Type.GetTypeFromCLSID(CLSID_MMDeviceEnumerator);
            return (IMMDeviceEnumerator)Activator.CreateInstance(t);
        }

        static string NameOf(IMMDevice d)
        {
            IPropertyStore store;
            if (d.OpenPropertyStore(0, out store) != 0) return "(no name)";
            PROPERTYKEY key = new PROPERTYKEY();
            key.fmtid = new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0");
            key.pid = 14;                       // PKEY_Device_FriendlyName
            PROPVARIANT v;
            if (store.GetValue(ref key, out v) != 0) return "(no name)";
            return Marshal.PtrToStringUni(v.pointerValue) ?? "(no name)";
        }

        /// <summary>id TAB name TAB isDefault, one per line.</summary>
        public static string[] List()
        {
            var outp = new List<string>();
            var en = Enumerator();
            IMMDevice def = null;
            string defId = "";
            if (en.GetDefaultAudioEndpoint(0, 0, out def) == 0 && def != null)
                def.GetId(out defId);

            IMMDeviceCollection coll;
            if (en.EnumAudioEndpoints(0, 1, out coll) != 0) return outp.ToArray();
            int n;
            coll.GetCount(out n);
            for (int i = 0; i < n; i++)
            {
                IMMDevice d;
                if (coll.Item(i, out d) != 0) continue;
                string id;
                d.GetId(out id);
                outp.Add(id + "\t" + NameOf(d) + "\t" + (id == defId ? "1" : "0"));
            }
            return outp.ToArray();
        }

        public static string DefaultId()
        {
            var en = Enumerator();
            IMMDevice def;
            if (en.GetDefaultAudioEndpoint(0, 0, out def) != 0 || def == null) return "";
            string id;
            def.GetId(out id);
            return id;
        }

        public static int SetDefault(string id)
        {
            Type t = Type.GetTypeFromCLSID(CLSID_PolicyConfigClient);
            var pc = (IPolicyConfig)Activator.CreateInstance(t);
            int worst = 0;
            for (int role = 0; role <= 2; role++)     // console, multimedia, comms
            {
                int rc = pc.SetDefaultEndpoint(id, role);
                if (rc != 0) worst = rc;
            }
            return worst;
        }

        /// <summary>Peak level 0..1 on one device: which one is actually making sound.</summary>
        public static float Peak(string id)
        {
            var en = Enumerator();
            IMMDevice d;
            if (en.GetDevice(id, out d) != 0 || d == null) return -1f;
            Guid iid = IID_IAudioMeterInformation;
            object o;
            if (d.Activate(ref iid, 1 /*CLSCTX_ALL*/, IntPtr.Zero, out o) != 0) return -1f;
            var meter = (IAudioMeterInformation)o;
            float peak;
            if (meter.GetPeakValue(out peak) != 0) return -1f;
            return peak;
        }
    }
}

// Play a file to a CHOSEN audio endpoint, without touching Windows' default.
//
// WPF's MediaPlayer has no device property - it always uses the default - so
// a device picker needs a different engine. Media Foundation's session lets
// you build the topology yourself and hand the audio renderer the endpoint id
// you want (MF_AUDIO_RENDERER_ATTRIBUTE_ENDPOINT_ID). That is documented, it
// is per-stream, and it leaves the rest of the machine alone.

namespace BtMf
{
    [ComImport, Guid("2CD2D921-C447-44A7-A13C-4ADABFC247E3"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFAttributes
    {
        int GetItem(ref Guid key, IntPtr value);
        int GetItemType(ref Guid key, out int type);
        int CompareItem(ref Guid key, IntPtr value, out bool result);
        int Compare(IMFAttributes theirs, int matchType, out bool result);
        int GetUINT32(ref Guid key, out int value);
        int GetUINT64(ref Guid key, out long value);
        int GetDouble(ref Guid key, out double value);
        int GetGUID(ref Guid key, out Guid value);
        int GetStringLength(ref Guid key, out int length);
        int GetString(ref Guid key, [Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder value, int size, IntPtr len);
        int GetAllocatedString(ref Guid key, [MarshalAs(UnmanagedType.LPWStr)] out string value, out int len);
        int GetBlobSize(ref Guid key, out int size);
        int GetBlob(ref Guid key, IntPtr buf, int size, IntPtr actual);
        int GetAllocatedBlob(ref Guid key, out IntPtr buf, out int size);
        int GetUnknown(ref Guid key, ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
        int SetItem(ref Guid key, IntPtr value);
        int DeleteItem(ref Guid key);
        int DeleteAllItems();
        int SetUINT32(ref Guid key, int value);
        int SetUINT64(ref Guid key, long value);
        int SetDouble(ref Guid key, double value);
        int SetGUID(ref Guid key, ref Guid value);
        int SetString(ref Guid key, [MarshalAs(UnmanagedType.LPWStr)] string value);
        int SetBlob(ref Guid key, IntPtr buf, int size);
        int SetUnknown(ref Guid key, [MarshalAs(UnmanagedType.IUnknown)] object unknown);
        int LockStore();
        int UnlockStore();
        int GetCount(out int count);
        int GetItemByIndex(int index, out Guid key, IntPtr value);
        int CopyAllItems(IMFAttributes dest);
    }

    [ComImport, Guid("7FEE9E9A-4A89-47A6-899C-B6A53A70FB67"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFActivate : IMFAttributes
    {
        new int GetItem(ref Guid key, IntPtr value);
        new int GetItemType(ref Guid key, out int type);
        new int CompareItem(ref Guid key, IntPtr value, out bool result);
        new int Compare(IMFAttributes theirs, int matchType, out bool result);
        new int GetUINT32(ref Guid key, out int value);
        new int GetUINT64(ref Guid key, out long value);
        new int GetDouble(ref Guid key, out double value);
        new int GetGUID(ref Guid key, out Guid value);
        new int GetStringLength(ref Guid key, out int length);
        new int GetString(ref Guid key, [Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder value, int size, IntPtr len);
        new int GetAllocatedString(ref Guid key, [MarshalAs(UnmanagedType.LPWStr)] out string value, out int len);
        new int GetBlobSize(ref Guid key, out int size);
        new int GetBlob(ref Guid key, IntPtr buf, int size, IntPtr actual);
        new int GetAllocatedBlob(ref Guid key, out IntPtr buf, out int size);
        new int GetUnknown(ref Guid key, ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
        new int SetItem(ref Guid key, IntPtr value);
        new int DeleteItem(ref Guid key);
        new int DeleteAllItems();
        new int SetUINT32(ref Guid key, int value);
        new int SetUINT64(ref Guid key, long value);
        new int SetDouble(ref Guid key, double value);
        new int SetGUID(ref Guid key, ref Guid value);
        new int SetString(ref Guid key, [MarshalAs(UnmanagedType.LPWStr)] string value);
        new int SetBlob(ref Guid key, IntPtr buf, int size);
        new int SetUnknown(ref Guid key, [MarshalAs(UnmanagedType.IUnknown)] object unknown);
        new int LockStore();
        new int UnlockStore();
        new int GetCount(out int count);
        new int GetItemByIndex(int index, out Guid key, IntPtr value);
        new int CopyAllItems(IMFAttributes dest);
        int ActivateObject(ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
        int ShutdownObject();
        int DetachObject();
    }

    [ComImport, Guid("FBE5A32D-A497-4B61-BB85-97B1A848A6E3"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFSourceResolver
    {
        int CreateObjectFromURL([MarshalAs(UnmanagedType.LPWStr)] string url, int flags,
                                IntPtr props, out int objectType,
                                [MarshalAs(UnmanagedType.IUnknown)] out object obj);
    }

    [ComImport, Guid("279A808D-AEC7-40C8-9C6B-A6B492C78A66"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFMediaSource
    {
        int GetEvent(int flags, out IntPtr ev);
        int BeginGetEvent(IntPtr cb, IntPtr state);
        int EndGetEvent(IntPtr res, out IntPtr ev);
        int QueueEvent(int met, ref Guid type, int status, IntPtr value);
        int GetCharacteristics(out int ch);
        int CreatePresentationDescriptor(out IMFPresentationDescriptor pd);
        int Start(IMFPresentationDescriptor pd, IntPtr timeFormat, IntPtr startPos);
        int Stop();
        int Pause();
        int Shutdown();
    }

    [ComImport, Guid("03CB2711-24D7-4DB6-A17F-F3A7A479A536"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFPresentationDescriptor : IMFAttributes
    {
        new int GetItem(ref Guid key, IntPtr value);
        new int GetItemType(ref Guid key, out int type);
        new int CompareItem(ref Guid key, IntPtr value, out bool result);
        new int Compare(IMFAttributes theirs, int matchType, out bool result);
        new int GetUINT32(ref Guid key, out int value);
        new int GetUINT64(ref Guid key, out long value);
        new int GetDouble(ref Guid key, out double value);
        new int GetGUID(ref Guid key, out Guid value);
        new int GetStringLength(ref Guid key, out int length);
        new int GetString(ref Guid key, [Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder value, int size, IntPtr len);
        new int GetAllocatedString(ref Guid key, [MarshalAs(UnmanagedType.LPWStr)] out string value, out int len);
        new int GetBlobSize(ref Guid key, out int size);
        new int GetBlob(ref Guid key, IntPtr buf, int size, IntPtr actual);
        new int GetAllocatedBlob(ref Guid key, out IntPtr buf, out int size);
        new int GetUnknown(ref Guid key, ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
        new int SetItem(ref Guid key, IntPtr value);
        new int DeleteItem(ref Guid key);
        new int DeleteAllItems();
        new int SetUINT32(ref Guid key, int value);
        new int SetUINT64(ref Guid key, long value);
        new int SetDouble(ref Guid key, double value);
        new int SetGUID(ref Guid key, ref Guid value);
        new int SetString(ref Guid key, [MarshalAs(UnmanagedType.LPWStr)] string value);
        new int SetBlob(ref Guid key, IntPtr buf, int size);
        new int SetUnknown(ref Guid key, [MarshalAs(UnmanagedType.IUnknown)] object unknown);
        new int LockStore();
        new int UnlockStore();
        new int GetCount(out int count);
        new int GetItemByIndex(int index, out Guid key, IntPtr value);
        new int CopyAllItems(IMFAttributes dest);
        int GetStreamDescriptorCount(out int count);
        int GetStreamDescriptorByIndex(int index, out bool selected, out IMFStreamDescriptor sd);
        int SelectStream(int index);
        int DeselectStream(int index);
        int Clone(out IMFPresentationDescriptor pd);
    }

    [ComImport, Guid("56C03D9C-9DBB-45F5-AB4B-D80F47C05938"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFStreamDescriptor : IMFAttributes
    {
        new int GetItem(ref Guid key, IntPtr value);
        new int GetItemType(ref Guid key, out int type);
        new int CompareItem(ref Guid key, IntPtr value, out bool result);
        new int Compare(IMFAttributes theirs, int matchType, out bool result);
        new int GetUINT32(ref Guid key, out int value);
        new int GetUINT64(ref Guid key, out long value);
        new int GetDouble(ref Guid key, out double value);
        new int GetGUID(ref Guid key, out Guid value);
        new int GetStringLength(ref Guid key, out int length);
        new int GetString(ref Guid key, [Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder value, int size, IntPtr len);
        new int GetAllocatedString(ref Guid key, [MarshalAs(UnmanagedType.LPWStr)] out string value, out int len);
        new int GetBlobSize(ref Guid key, out int size);
        new int GetBlob(ref Guid key, IntPtr buf, int size, IntPtr actual);
        new int GetAllocatedBlob(ref Guid key, out IntPtr buf, out int size);
        new int GetUnknown(ref Guid key, ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
        new int SetItem(ref Guid key, IntPtr value);
        new int DeleteItem(ref Guid key);
        new int DeleteAllItems();
        new int SetUINT32(ref Guid key, int value);
        new int SetUINT64(ref Guid key, long value);
        new int SetDouble(ref Guid key, double value);
        new int SetGUID(ref Guid key, ref Guid value);
        new int SetString(ref Guid key, [MarshalAs(UnmanagedType.LPWStr)] string value);
        new int SetBlob(ref Guid key, IntPtr buf, int size);
        new int SetUnknown(ref Guid key, [MarshalAs(UnmanagedType.IUnknown)] object unknown);
        new int LockStore();
        new int UnlockStore();
        new int GetCount(out int count);
        new int GetItemByIndex(int index, out Guid key, IntPtr value);
        new int CopyAllItems(IMFAttributes dest);
        int GetStreamIdentifier(out int id);
        int GetMediaTypeHandler(out IMFMediaTypeHandler handler);
    }

    [ComImport, Guid("E93DCF6C-4B07-4E1E-8123-AA16ED6EADF5"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFMediaTypeHandler
    {
        int IsMediaTypeSupported(IntPtr type, IntPtr closest);
        int GetMediaTypeCount(out int count);
        int GetMediaTypeByIndex(int index, out IntPtr type);
        int SetCurrentMediaType(IntPtr type);
        int GetCurrentMediaType(out IntPtr type);
        int GetMajorType(out Guid major);
    }

    [ComImport, Guid("83CF873A-F6DA-4bc8-823F-BACFD55DC433"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFTopology : IMFAttributes
    {
        new int GetItem(ref Guid key, IntPtr value);
        new int GetItemType(ref Guid key, out int type);
        new int CompareItem(ref Guid key, IntPtr value, out bool result);
        new int Compare(IMFAttributes theirs, int matchType, out bool result);
        new int GetUINT32(ref Guid key, out int value);
        new int GetUINT64(ref Guid key, out long value);
        new int GetDouble(ref Guid key, out double value);
        new int GetGUID(ref Guid key, out Guid value);
        new int GetStringLength(ref Guid key, out int length);
        new int GetString(ref Guid key, [Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder value, int size, IntPtr len);
        new int GetAllocatedString(ref Guid key, [MarshalAs(UnmanagedType.LPWStr)] out string value, out int len);
        new int GetBlobSize(ref Guid key, out int size);
        new int GetBlob(ref Guid key, IntPtr buf, int size, IntPtr actual);
        new int GetAllocatedBlob(ref Guid key, out IntPtr buf, out int size);
        new int GetUnknown(ref Guid key, ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
        new int SetItem(ref Guid key, IntPtr value);
        new int DeleteItem(ref Guid key);
        new int DeleteAllItems();
        new int SetUINT32(ref Guid key, int value);
        new int SetUINT64(ref Guid key, long value);
        new int SetDouble(ref Guid key, double value);
        new int SetGUID(ref Guid key, ref Guid value);
        new int SetString(ref Guid key, [MarshalAs(UnmanagedType.LPWStr)] string value);
        new int SetBlob(ref Guid key, IntPtr buf, int size);
        new int SetUnknown(ref Guid key, [MarshalAs(UnmanagedType.IUnknown)] object unknown);
        new int LockStore();
        new int UnlockStore();
        new int GetCount(out int count);
        new int GetItemByIndex(int index, out Guid key, IntPtr value);
        new int CopyAllItems(IMFAttributes dest);
        int GetTopologyID(out long id);
        int AddNode(IMFTopologyNode node);
        int RemoveNode(IMFTopologyNode node);
        int GetNodeCount(out short count);
        int GetNode(short index, out IMFTopologyNode node);
        int Clear();
        int CloneFrom(IMFTopology topology);
        int GetNodeByID(long id, out IMFTopologyNode node);
        int GetSourceNodeCollection(out IntPtr coll);
        int GetOutputNodeCollection(out IntPtr coll);
    }

    [ComImport, Guid("83CF873A-F6DA-4bc8-823F-BACFD55DC430"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFTopologyNode : IMFAttributes
    {
        new int GetItem(ref Guid key, IntPtr value);
        new int GetItemType(ref Guid key, out int type);
        new int CompareItem(ref Guid key, IntPtr value, out bool result);
        new int Compare(IMFAttributes theirs, int matchType, out bool result);
        new int GetUINT32(ref Guid key, out int value);
        new int GetUINT64(ref Guid key, out long value);
        new int GetDouble(ref Guid key, out double value);
        new int GetGUID(ref Guid key, out Guid value);
        new int GetStringLength(ref Guid key, out int length);
        new int GetString(ref Guid key, [Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder value, int size, IntPtr len);
        new int GetAllocatedString(ref Guid key, [MarshalAs(UnmanagedType.LPWStr)] out string value, out int len);
        new int GetBlobSize(ref Guid key, out int size);
        new int GetBlob(ref Guid key, IntPtr buf, int size, IntPtr actual);
        new int GetAllocatedBlob(ref Guid key, out IntPtr buf, out int size);
        new int GetUnknown(ref Guid key, ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
        new int SetItem(ref Guid key, IntPtr value);
        new int DeleteItem(ref Guid key);
        new int DeleteAllItems();
        new int SetUINT32(ref Guid key, int value);
        new int SetUINT64(ref Guid key, long value);
        new int SetDouble(ref Guid key, double value);
        new int SetGUID(ref Guid key, ref Guid value);
        new int SetString(ref Guid key, [MarshalAs(UnmanagedType.LPWStr)] string value);
        new int SetBlob(ref Guid key, IntPtr buf, int size);
        new int SetUnknown(ref Guid key, [MarshalAs(UnmanagedType.IUnknown)] object unknown);
        new int LockStore();
        new int UnlockStore();
        new int GetCount(out int count);
        new int GetItemByIndex(int index, out Guid key, IntPtr value);
        new int CopyAllItems(IMFAttributes dest);
        int SetObject([MarshalAs(UnmanagedType.IUnknown)] object obj);
        int GetObject([MarshalAs(UnmanagedType.IUnknown)] out object obj);
        int GetNodeType(out int type);
        int GetTopoNodeID(out long id);
        int SetTopoNodeID(long id);
        int GetInputCount(out int count);
        int GetOutputCount(out int count);
        int ConnectOutput(int outIndex, IMFTopologyNode node, int inIndex);
        int DisconnectOutput(int index);
        int GetInput(int index, out IMFTopologyNode node, out int outIndex);
        int GetOutput(int index, out IMFTopologyNode node, out int inIndex);
    }

    [ComImport, Guid("90377834-21D0-4DEE-8214-BA2E3E6C1127"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFMediaSession
    {
        int GetEvent(int flags, out IMFMediaEvent ev);
        int BeginGetEvent(IntPtr cb, IntPtr state);
        int EndGetEvent(IntPtr res, out IMFMediaEvent ev);
        int QueueEvent(int met, ref Guid type, int status, IntPtr value);
        int SetTopology(int flags, IMFTopology topology);
        int ClearTopologies();
        int Start(IntPtr timeFormat, IntPtr startPos);
        int Pause();
        int Stop();
        int Close();
        int Shutdown();
        int GetClock(out IMFClock clock);
        int GetSessionCapabilities(out int caps);
        int GetFullTopology(int flags, long id, out IMFTopology topology);
    }

    [ComImport, Guid("DF598932-F10C-4E39-BBA2-C308F101DAA3"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFMediaEvent : IMFAttributes
    {
        new int GetItem(ref Guid key, IntPtr value);
        new int GetItemType(ref Guid key, out int type);
        new int CompareItem(ref Guid key, IntPtr value, out bool result);
        new int Compare(IMFAttributes theirs, int matchType, out bool result);
        new int GetUINT32(ref Guid key, out int value);
        new int GetUINT64(ref Guid key, out long value);
        new int GetDouble(ref Guid key, out double value);
        new int GetGUID(ref Guid key, out Guid value);
        new int GetStringLength(ref Guid key, out int length);
        new int GetString(ref Guid key, [Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder value, int size, IntPtr len);
        new int GetAllocatedString(ref Guid key, [MarshalAs(UnmanagedType.LPWStr)] out string value, out int len);
        new int GetBlobSize(ref Guid key, out int size);
        new int GetBlob(ref Guid key, IntPtr buf, int size, IntPtr actual);
        new int GetAllocatedBlob(ref Guid key, out IntPtr buf, out int size);
        new int GetUnknown(ref Guid key, ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
        new int SetItem(ref Guid key, IntPtr value);
        new int DeleteItem(ref Guid key);
        new int DeleteAllItems();
        new int SetUINT32(ref Guid key, int value);
        new int SetUINT64(ref Guid key, long value);
        new int SetDouble(ref Guid key, double value);
        new int SetGUID(ref Guid key, ref Guid value);
        new int SetString(ref Guid key, [MarshalAs(UnmanagedType.LPWStr)] string value);
        new int SetBlob(ref Guid key, IntPtr buf, int size);
        new int SetUnknown(ref Guid key, [MarshalAs(UnmanagedType.IUnknown)] object unknown);
        new int LockStore();
        new int UnlockStore();
        new int GetCount(out int count);
        new int GetItemByIndex(int index, out Guid key, IntPtr value);
        new int CopyAllItems(IMFAttributes dest);
        int GetType(out int met);
        int GetExtendedType(out Guid guid);
        int GetStatus(out int status);
        int GetValue(IntPtr value);
    }

    [ComImport, Guid("2EB1E945-18B8-4139-9B1A-D5D584818530"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFClock
    {
        int GetClockCharacteristics(out int ch);
        int GetCorrelatedTime(long reserved, out long clockTime, out long systemTime);
        int GetContinuityKey(out int key);
        int GetState(long reserved, out int state);
        int GetProperties(IntPtr props);
    }

    [ComImport, Guid("089EDF13-CF71-4338-8D13-9E569DBDC319"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMFSimpleAudioVolume
    {
        int SetMasterVolume(float level);
        int GetMasterVolume(out float level);
        int SetMute(bool mute);
        int GetMute(out bool mute);
    }

    public static class Native
    {
        [DllImport("mfplat.dll")] public static extern int MFStartup(int version, int flags);
        [DllImport("mfplat.dll", CharSet = CharSet.Unicode)]
        public static extern int MFRegisterPlatformWithMMCSS(string mmcssClass, ref int taskId, int basePriority);
        [DllImport("avrt.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr AvSetMmThreadCharacteristicsW(string taskName, ref int taskIndex);
        [DllImport("mfplat.dll")] public static extern int MFShutdown();
        [DllImport("mfplat.dll")] public static extern int MFCreateAttributes(out IMFAttributes attr, int initial);
        [DllImport("mf.dll")] public static extern int MFCreateMediaSession(IntPtr config, out IMFMediaSession session);
        [DllImport("mf.dll")] public static extern int MFCreateSourceResolver(out IMFSourceResolver resolver);
        [DllImport("mf.dll")] public static extern int MFCreateAudioRendererActivate(out IMFActivate activate);
        [DllImport("mf.dll")] public static extern int MFCreateTopology(out IMFTopology topology);
        [DllImport("mf.dll")] public static extern int MFCreateTopologyNode(int type, out IMFTopologyNode node);
        [DllImport("mf.dll")] public static extern int MFGetService([MarshalAs(UnmanagedType.IUnknown)] object obj,
            ref Guid service, ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
    }

    public class Player
    {
        static Guid MF_AUDIO_RENDERER_ATTRIBUTE_ENDPOINT_ID =
            new Guid("b10aaec3-ef71-4cc3-b873-05a9a08b9f8e");
        static Guid MF_PD_DURATION = new Guid("6C990D33-BB8E-477A-8598-0D5D96FCD88A");
        static Guid MR_STREAM_VOLUME_SERVICE = new Guid("f8b5fa2f-32ef-46f5-b172-1321212fb2c4");
        static Guid IID_IMFSimpleAudioVolume = new Guid("089EDF13-CF71-4338-8D13-9E569DBDC319");

        IMFMediaSession session;
        IMFMediaSource source;
        IMFClock clock;
        public long DurationTicks;          // 100-ns units
        public bool Ended;
        public string Error = "";

        // THE AUDIO GETS ITS TIME (2026-10-11). Music apps register their
        // audio with the Multimedia Class Scheduler: it lifts those threads
        // above ordinary ones, so a VR game holding every core does not starve
        // them. Without it this player's decoding and rendering waited behind
        // the game - the stutter you hear and Spotify never has. Media
        // Foundation's own work queues (where both engines decode and render)
        // and this thread are registered as "Audio". "mf=0 thread=1" when both
        // took; anything else is the error, and the music still plays.
        public static string Mmcss = "";
        public static void Startup()
        {
            Native.MFStartup(0x00020070, 0);
            string mf = "?", th = "?";
            try { int task = 0; mf = Native.MFRegisterPlatformWithMMCSS("Audio", ref task, 0).ToString(); }
            catch (Exception e) { mf = e.GetType().Name; }
            try
            {
                int idx = 0;
                th = Native.AvSetMmThreadCharacteristicsW("Audio", ref idx) != IntPtr.Zero
                     ? "1" : "err" + Marshal.GetLastWin32Error();
            }
            catch (Exception e) { th = e.GetType().Name; }
            Mmcss = "mf=" + mf + " thread=" + th;
        }

        // THESE CALLS THROW; THEY DO NOT RETURN AN HRESULT.
        //
        // The interop converts a failing HRESULT into a COMException, so
        // every `if (hr != 0)` below is belt to the braces - the real failure
        // path is the catch. A file Windows cannot read (0xC00D36C4, "the
        // byte stream type of the given URL is unsupported") throws out of
        // CreateObjectFromURL, and without this wrapper that exception
        // escaped into the caller, which then never learned the track had
        // failed and sat on it for ever.
        public bool Open(string path, string endpointId)
        {
            try { return OpenCore(path, endpointId); }
            catch (Exception ex) { Error = ex.Message; return false; }
        }

        bool OpenCore(string path, string endpointId)
        {
            Close();
            Ended = false;
            Error = "";
            int hr;

            IMFSourceResolver resolver;
            hr = Native.MFCreateSourceResolver(out resolver);
            if (hr != 0) { Error = "resolver " + hr; return false; }
            int objType;
            object obj;
            hr = resolver.CreateObjectFromURL(path, 1 /*MF_RESOLUTION_MEDIASOURCE*/,
                                              IntPtr.Zero, out objType, out obj);
            if (hr != 0) { Error = "open " + hr; return false; }
            source = (IMFMediaSource)obj;

            IMFPresentationDescriptor pd;
            hr = source.CreatePresentationDescriptor(out pd);
            if (hr != 0) { Error = "pd " + hr; return false; }
            long dur;
            if (pd.GetUINT64(ref MF_PD_DURATION, out dur) == 0) DurationTicks = dur;

            IMFTopology topo;
            Native.MFCreateTopology(out topo);

            int sdCount;
            pd.GetStreamDescriptorCount(out sdCount);
            bool wired = false;
            for (int i = 0; i < sdCount; i++)
            {
                bool selected;
                IMFStreamDescriptor sd;
                if (pd.GetStreamDescriptorByIndex(i, out selected, out sd) != 0) continue;
                if (!selected) continue;

                IMFMediaTypeHandler handler;
                sd.GetMediaTypeHandler(out handler);
                Guid major;
                handler.GetMajorType(out major);
                // audio only: a video stream would want a window we do not have
                if (major != new Guid("73647561-0000-0010-8000-00AA00389B71")) continue;

                IMFTopologyNode srcNode, outNode;
                Native.MFCreateTopologyNode(1 /*MF_TOPOLOGY_SOURCESTREAM_NODE*/, out srcNode);
                srcNode.SetUnknown(ref UnkSource, source);
                srcNode.SetUnknown(ref UnkPD, pd);
                srcNode.SetUnknown(ref UnkSD, sd);
                topo.AddNode(srcNode);

                IMFActivate rendererActivate;
                if (Native.MFCreateAudioRendererActivate(out rendererActivate) != 0)
                { Error = "renderer"; return false; }
                if (!string.IsNullOrEmpty(endpointId))
                    rendererActivate.SetString(ref MF_AUDIO_RENDERER_ATTRIBUTE_ENDPOINT_ID, endpointId);

                Native.MFCreateTopologyNode(0 /*MF_TOPOLOGY_OUTPUT_NODE*/, out outNode);
                outNode.SetObject(rendererActivate);
                topo.AddNode(outNode);
                srcNode.ConnectOutput(0, outNode, 0);
                wired = true;
            }
            if (!wired) { Error = "no audio stream"; return false; }

            hr = Native.MFCreateMediaSession(IntPtr.Zero, out session);
            if (hr != 0) { Error = "session " + hr; return false; }
            hr = session.SetTopology(0, topo);
            if (hr != 0) { Error = "topology " + hr; return false; }

            return true;
        }

        static Guid UnkSource = new Guid("835c58ec-e075-4bc7-bcba-4de000df9ae6"); // MF_TOPONODE_SOURCE
        static Guid UnkPD = new Guid("835c58ed-e075-4bc7-bcba-4de000df9ae6");     // PRESENTATION_DESCRIPTOR
        static Guid UnkSD = new Guid("835c58ee-e075-4bc7-bcba-4de000df9ae6");     // STREAM_DESCRIPTOR

        // EVENTS ARE POLLED, NOT WAITED ON.
        //
        // The first version read them on a background thread with a BLOCKING
        // GetEvent. Closing the session then deadlocked: Shutdown() wants the
        // session quiet, and the session was sitting inside a read that only
        // the session could end. Switching output - which closes one session
        // and opens another - hung the player solid. MF_EVENT_FLAG_NO_WAIT
        // returns immediately when there is nothing, so the ordinary timer
        // can drain the queue and nothing ever blocks.
        public void Drain()
        {
            if (session == null) return;
            for (int guard = 0; guard < 32; guard++)
            {
                IMFMediaEvent ev = null;
                int hr;
                try { hr = session.GetEvent(1 /*MF_EVENT_FLAG_NO_WAIT*/, out ev); }
                catch { return; }
                if (hr != 0 || ev == null) return;
                int met;
                ev.GetType(out met);
                if (met == 107) Ended = true;               // MESessionEnded
            }
        }

        // Start() wants a real PROPVARIANT, not a null pointer: VT_EMPTY means
        // "from wherever you are", which is what both play and resume want.
        // Passing IntPtr.Zero here returns E_POINTER and nothing plays.
        static IntPtr EmptyVariant()
        {
            IntPtr pv = Marshal.AllocCoTaskMem(24);
            for (int i = 0; i < 24; i++) Marshal.WriteByte(pv, i, 0);
            return pv;
        }

        public void Play()
        {
            if (session == null) return;
            if (clock == null) session.GetClock(out clock);
            IntPtr pv = EmptyVariant();
            try { session.Start(IntPtr.Zero, pv); }
            catch { }
            finally { Marshal.FreeCoTaskMem(pv); }
        }

        public void Seek(long ticks)
        {
            if (session == null) return;
            IntPtr pv = Marshal.AllocCoTaskMem(24);
            try
            {
                for (int i = 0; i < 24; i++) Marshal.WriteByte(pv, i, 0);
                Marshal.WriteInt16(pv, 0, 20);          // VT_I8
                Marshal.WriteInt64(pv, 8, ticks);
                session.Start(IntPtr.Zero, pv);
            }
            catch { }
            finally { Marshal.FreeCoTaskMem(pv); }
        }

        public void Pause() { try { if (session != null) session.Pause(); } catch { } }
        public void StopIt() { try { if (session != null) session.Stop(); } catch { } }

        public long PositionTicks()
        {
            if (clock == null && session != null) session.GetClock(out clock);
            if (clock == null) return 0;
            try
            {
                long t, sys;
                clock.GetCorrelatedTime(0, out t, out sys);
                return t;
            }
            catch { return 0; }
        }

        public void SetVolume(float v)
        {
            if (session == null) return;
            try
            {
                object o;
                Guid svc = MR_STREAM_VOLUME_SERVICE;
                Guid iid = IID_IMFSimpleAudioVolume;
                if (Native.MFGetService(session, ref svc, ref iid, out o) == 0 && o != null)
                    ((IMFSimpleAudioVolume)o).SetMasterVolume(v);
            }
            catch { }
        }

        public void Close()
        {
            try
            {
                if (session != null)
                {
                    session.Stop();
                    session.Close();
                    // Close is asynchronous; give it its own events before
                    // shutting it down, or Shutdown can hang.
                    for (int i = 0; i < 25; i++) { Drain(); Thread.Sleep(10); }
                    session.Shutdown();
                }
            }
            catch { }
            try { if (source != null) source.Shutdown(); } catch { }
            session = null; source = null; clock = null;
        }
    }
}
"""

_PLAYER_PS1 = r"""
$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName PresentationCore
$TAB = [char]9
$LF  = [char]10
$CR  = [char]13

# The WPF player is the fallback: it plays everything, but it has no device
# property at all, so it always uses whatever Windows calls the default. The
# Media Foundation player (compiled from source sent down this pipe, because
# it is far too big for a command line) can aim one stream at one endpoint
# and leave the rest of the machine alone. Measured: peak 0.94 on the chosen
# device, 0.00 on the default, and the default not touched.
$player = New-Object System.Windows.Media.MediaPlayer
$script:failed = $false
$script:opened = $false
$script:ended  = $false
$player.add_MediaFailed({ $script:failed = $true })
$player.add_MediaOpened({ $script:opened = $true })
$player.add_MediaEnded({ $script:ended = $true })

$out   = [Console]::Out
$stdin = [Console]::OpenStandardInput()
$buf   = New-Object byte[] 8192
$disp  = [System.Windows.Threading.Dispatcher]::CurrentDispatcher

$script:pending  = ''
$script:read     = $null
$script:id       = 0
$script:state    = 'stopped'
$script:resolved = $true
$script:ticks    = 0
$script:useMf    = $false
$script:mf       = $null
$script:device   = ''          # '' = whatever Windows calls the default
$script:activeMf = $false      # which engine holds the CURRENT track
$script:vol      = 0.6
$script:path     = ''
$script:lenMs    = 0

function StartCs($b64) {
    $src = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
    try {
        Add-Type -TypeDefinition $src -ErrorAction Stop
        [BtMf.Player]::Startup()
        $script:mf = New-Object BtMf.Player
        $script:useMf = $true
    } catch {
        $script:useMf = $false
    }
    $out.WriteLine('MF' + $TAB + $(if ($script:useMf) { '1' } else { '0' }))
    if ($script:useMf) { $out.WriteLine('MMCSS' + $TAB + [BtMf.Player]::Mmcss) }
    if ($script:useMf) {
        foreach ($d in [BtAudio.Devices]::List()) { $out.WriteLine('DEV' + $TAB + $d) }
    }
    $out.WriteLine('DEVEND')
    $out.Flush()
}

# WHICH ENGINE, PER TRACK.
#
# Media Foundation is the only one that can aim at a chosen output, but
# measured over the whole 706-track library it takes 650 ms to open a file
# against the built-in player's 114 ms - which is the gap you would hear
# between two songs. So the built-in player keeps the default case, and the
# Media Foundation one is used only when you have actually asked for a
# particular output. Nobody pays for a feature they are not using.
function OpenNow($path) {
    $script:path = $path
    $script:activeMf = ($script:useMf -and $script:device -ne '')
    if ($script:activeMf) {
        $script:lenMs = 0
        if ($script:mf.Open($path, $script:device)) {
            $script:lenMs = [int]($script:mf.DurationTicks / 10000)
            $script:mf.SetVolume([float]$script:vol)
        } else {
            $script:failed = $true
        }
    } else {
        try { $player.Open([Uri]$path) } catch { $script:failed = $true }
    }
}

function Handle($line) {
    $p = $line.Split($TAB)
    switch ($p[0]) {
        'CS'    { StartCs $p[1] }
        'OPEN'  {
            $script:id = [int]$p[1]
            $script:failed = $false
            $script:opened = $false
            $script:ended  = $false
            $script:resolved = $false
            $script:state = 'stopped'
            OpenNow $p[2]
        }
        'PLAY'  {
            $script:ended = $false
            if ($script:activeMf) { $script:mf.Play() } else { $player.Play() }
            $script:state = 'playing'
        }
        'PAUSE' {
            if ($script:activeMf) { $script:mf.Pause() } else { $player.Pause() }
            $script:state = 'paused'
        }
        'STOP'  {
            $script:ended = $false
            if ($script:activeMf) { $script:mf.StopIt() } else { $player.Stop() }
            $script:state = 'stopped'
        }
        'SEEK'  {
            if ($script:activeMf) { $script:mf.Seek([long]([double]$p[1] * 10000)) }
            else { try { $player.Position = [TimeSpan]::FromMilliseconds([double]$p[1]) } catch { } }
        }
        'VOL'   {
            $script:vol = [double]$p[1]
            if ($script:activeMf) { $script:mf.SetVolume([float]$script:vol) }
            else { try { $player.Volume = [double]$p[1] } catch { } }
        }
        'DEV'   {
            # A stream is bound to its endpoint when it is created, so moving
            # output means re-opening where we were - which is a few hundred
            # milliseconds of silence, not a restart of the song.
            $script:device = $p[1]
            if ($script:useMf -and $script:path -ne '') {
                $was = 0
                if ($script:activeMf) {
                    try { $was = [long]$script:mf.PositionTicks() } catch { }
                } else {
                    try { $was = [long]($player.Position.TotalMilliseconds * 10000) } catch { }
                }
                if ($script:activeMf) { $script:mf.StopIt() } else { $player.Stop() }
                $playing = ($script:state -eq 'playing')
                OpenNow $script:path
                if ($script:activeMf) {
                    if ($was -gt 0) { $script:mf.Seek($was) } else { $script:mf.Play() }
                    if (-not $playing) { $script:mf.Pause() }
                } else {
                    $player.Play()
                    if ($was -gt 0) {
                        try { $player.Position = [TimeSpan]::FromMilliseconds($was / 10000) } catch { }
                    }
                    if (-not $playing) { $player.Pause() }
                }
            }
            $out.WriteLine('DEVOK' + $TAB + $script:device); $out.Flush()
        }
        'QUIT'  { $disp.InvokeShutdown() }
    }
}

# A REAL MESSAGE LOOP, NOT A POLL LOOP (2026-09-21).
#
# The first version span: it pumped the dispatcher by hand and slept 15 ms,
# 66 times a second, building a DispatcherFrame and doing a BeginInvoke and a
# PushFrame every pass. Measured while playing one song: 5.6% of a core, for
# ever - nothing on an idle desktop, a great deal on a machine holding 90
# frames a second for a headset. Dispatcher::Run() is the real Win32 message
# loop: it BLOCKS in GetMessage between ticks. Measured after: 0.00%.
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(60)
$timer.add_Tick({
    if ($null -eq $script:read) { $script:read = $stdin.ReadAsync($buf, 0, $buf.Length) }
    if ($script:read.IsCompleted) {
        $n = 0
        try { $n = $script:read.Result } catch { $n = 0 }
        $script:read = $null
        if ($n -le 0) { $disp.InvokeShutdown(); return }
        $script:pending = $script:pending + [Text.Encoding]::UTF8.GetString($buf, 0, $n)
        while ($true) {
            $ix = $script:pending.IndexOf($LF)
            if ($ix -lt 0) { break }
            $line = $script:pending.Substring(0, $ix).TrimEnd($CR)
            $script:pending = $script:pending.Substring($ix + 1)
            if ($line.Length -gt 0) { Handle $line }
        }
    }

    if (-not $script:resolved) {
        if ($script:activeMf) {
            if ($script:failed) {
                $script:resolved = $true
                $out.WriteLine('FAILED' + $TAB + $script:id); $out.Flush()
            } elseif ($script:lenMs -gt 0) {
                $script:resolved = $true
                $out.WriteLine('OPENED' + $TAB + $script:id + $TAB + $script:lenMs); $out.Flush()
            }
        } else {
            if ($script:failed) {
                $script:resolved = $true
                $out.WriteLine('FAILED' + $TAB + $script:id); $out.Flush()
            } elseif ($script:opened -and $player.NaturalDuration.HasTimeSpan) {
                $script:resolved = $true
                $ms = [int]$player.NaturalDuration.TimeSpan.TotalMilliseconds
                $out.WriteLine('OPENED' + $TAB + $script:id + $TAB + $ms); $out.Flush()
            }
        }
    }

    $script:ticks = $script:ticks + 1
    if (($script:ticks % 4) -eq 0) {
        $s = $script:state
        $pos = 0
        if ($script:activeMf) {
            $script:mf.Drain()
            if ($script:mf.Ended) { $s = 'ended' }
            try { $pos = [int]($script:mf.PositionTicks() / 10000) } catch { }
        } else {
            if ($script:ended) { $s = 'ended' }
            try { $pos = [int]$player.Position.TotalMilliseconds } catch { }
        }
        $out.WriteLine('POS' + $TAB + $script:id + $TAB + $pos + $TAB + $s); $out.Flush()
    }
})
$timer.Start()

$out.WriteLine('READY'); $out.Flush()
[System.Windows.Threading.Dispatcher]::Run()
try { if ($script:mf) { $script:mf.Close() } } catch { }
try { $player.Stop() } catch { }
try { $player.Close() } catch { }
"""


class MediaEngine:
    """Windows' modern audio stack, driven from a child process.

    Every method here either writes a short line to a pipe or reads a field
    that a background thread has already filled in. Nothing waits on audio.
    """

    kind = "mf"

    def __init__(self):
        self.proc = None
        self.reader = None
        self.lock = threading.Lock()
        self.seq = 0
        self.dead = False
        # WHICH SPEAKERS. Empty means "whatever Windows calls the default",
        # which is the only thing the built-in player can do; a real id is an
        # audio endpoint the Media Foundation engine renders to directly,
        # without moving anybody else's sound.
        self.device = ""
        self.can_choose_device = False
        self.mmcss = ""
        self.devices_ready = False
        self._devices = []
        # resolved: None while the file is still opening, True once it opened,
        # False once this engine has said it cannot play it.
        self.snap = {"id": 0, "state": "stopped", "pos": 0, "len": 0,
                     "resolved": None}

    def start(self):
        """Launch the child. False means 'use something else'."""
        if self.proc is not None:
            return not self.dead
        try:
            blob = base64.b64encode(_PLAYER_PS1.encode("utf-16-le")).decode("ascii")
            si = subprocess.STARTUPINFO()
            si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            si.wShowWindow = 0
            self.proc = subprocess.Popen(
                ["powershell.exe", "-NoProfile", "-NonInteractive", "-STA",
                 "-EncodedCommand", blob],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                # above the game's ordinary threads, for the same reason the
                # audio is registered with MMCSS (see BtMf.Player.Startup).
                # It sleeps between 60 ms ticks, so this costs the game nothing.
                creationflags=CREATE_NO_WINDOW | ABOVE_NORMAL_PRIORITY_CLASS,
                startupinfo=si)
        except Exception:
            self.proc = None
            self.dead = True
            return False
        self.reader = threading.Thread(target=self._read_loop, daemon=True)
        self.reader.start()
        # Hand it the audio engine that can pick a device. If it will not
        # compile - some machines block the compiler - the child says so and
        # carries on with the built-in player, which works but always uses
        # whatever Windows calls the default.
        self._send("CS", base64.b64encode(_PLAYER_CS.encode("utf-8")).decode("ascii"))
        return True

    # ------------------------------------------------------------ the pipe
    def _read_loop(self):
        pipe = self.proc.stdout
        while True:
            try:
                raw = pipe.readline()
            except Exception:
                break
            if not raw:
                break
            try:
                line = raw.decode("utf-8", "replace").strip()
            except Exception:
                continue
            parts = line.split("\t")
            tag = parts[0]
            try:
                if tag == "POS" and len(parts) >= 4:
                    with self.lock:
                        if int(parts[1]) == self.snap["id"]:
                            self.snap["pos"] = int(parts[2])
                            self.snap["state"] = parts[3]
                elif tag == "OPENED" and len(parts) >= 3:
                    with self.lock:
                        if int(parts[1]) == self.snap["id"]:
                            self.snap["len"] = int(parts[2])
                            self.snap["resolved"] = True
                elif tag == "FAILED" and len(parts) >= 2:
                    with self.lock:
                        if int(parts[1]) == self.snap["id"]:
                            self.snap["resolved"] = False
                elif tag == "MF" and len(parts) >= 2:
                    self.can_choose_device = parts[1] == "1"
                elif tag == "MMCSS" and len(parts) >= 2:
                    # "mf=0 thread=1": the audio is registered as music apps' is
                    self.mmcss = parts[1]
                elif tag == "DEV" and len(parts) >= 3:
                    with self.lock:
                        self._devices.append((parts[1], parts[2],
                                              len(parts) > 3 and parts[3] == "1"))
                elif tag == "DEVEND":
                    self.devices_ready = True
                elif tag == "DEVOK" and len(parts) >= 1:
                    self.device = parts[1] if len(parts) > 1 else ""
            except (ValueError, KeyError):
                continue
        self.dead = True

    def _send(self, *parts):
        if self.proc is None or self.dead:
            return False
        try:
            self.proc.stdin.write(("\t".join(str(p) for p in parts) + "\n").encode("utf-8"))
            self.proc.stdin.flush()
            return True
        except Exception:
            self.dead = True
            return False

    # --------------------------------------------------------- the commands
    def open(self, path):
        self.seq += 1
        with self.lock:
            self.snap = {"id": self.seq, "state": "stopped", "pos": 0,
                         "len": 0, "resolved": None}
        self._send("OPEN", self.seq, path)
        return self.seq

    def play(self):
        # SAY IT AT ONCE. The child reports its state five times a second,
        # which meant the panel went on saying "playing" for up to 200 ms
        # after you pressed pause. What we asked for is the honest answer
        # until the child contradicts it.
        self._send("PLAY")
        with self.lock:
            if self.snap["state"] != "playing":
                self.snap["state"] = "playing"

    def pause(self):
        self._send("PAUSE")
        with self.lock:
            if self.snap["state"] == "playing":
                self.snap["state"] = "paused"

    def stop(self):
        self._send("STOP")
        with self.lock:
            self.snap["state"] = "stopped"
            self.snap["pos"] = 0

    def seek(self, ms):
        self._send("SEEK", int(ms))
        with self.lock:
            self.snap["pos"] = int(ms)

    def set_volume(self, v):
        self._send("VOL", "%.3f" % max(0.0, min(1.0, float(v))))

    def list_devices(self):
        with self.lock:
            return list(self._devices)

    def set_device(self, device_id):
        """Move the sound to another output, keeping your place in the song."""
        self.device = device_id or ""
        return self._send("DEV", self.device)

    def snapshot(self):
        with self.lock:
            return dict(self.snap)

    def shutdown(self):
        self._send("QUIT")
        proc, self.proc = self.proc, None
        self.dead = True
        if proc is None:
            return
        try:
            proc.stdin.close()
        except Exception:
            pass
        try:
            proc.wait(timeout=1.5)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass


class MciEngine:
    """The old player, kept for a machine where the child will not start.

    It plays about a third of this library and it blocks the caller, which is
    exactly why it is no longer first choice - but a third beats silence.
    """

    kind = "mci"
    ALIAS = "btmm_music"

    def __init__(self):
        self.open_ok = False
        self.seq = 0
        self._len = 0
        self._state = "stopped"
        self._cache = {}
        try:
            self._winmm = ctypes.windll.winmm
        except Exception:
            self._winmm = None

    def start(self):
        return self._winmm is not None

    # The old engine cannot choose an output at all; say so rather than
    # offering a picker that would quietly do nothing.
    can_choose_device = False
    devices_ready = True
    device = ""

    def list_devices(self):
        return []

    def set_device(self, device_id):
        return False

    def _mci(self, cmd):
        if not self._winmm:
            return 1, ""
        buf = ctypes.create_unicode_buffer(256)
        err = self._winmm.mciSendStringW(cmd, buf, 255, None)
        return err, buf.value

    def _ask(self, key, cmd, ttl=0.40):
        if not self.open_ok:
            return 1, ""
        now = time.time()
        hit = self._cache.get(key)
        if hit is not None and (now - hit[0]) < ttl:
            return hit[1]
        out = self._mci(cmd % self.ALIAS)
        self._cache[key] = (now, out)
        return out

    def open(self, path):
        self.seq += 1
        self._cache = {}
        if self.open_ok:
            self._mci("close " + self.ALIAS)
            self.open_ok = False
        err, _ = self._mci('open "%s" type mpegvideo alias %s' % (path, self.ALIAS))
        self.open_ok = err == 0
        self._len = 0
        self._state = "stopped"
        if self.open_ok:
            self._mci("set %s time format milliseconds" % self.ALIAS)
            e2, v = self._mci("status %s length" % self.ALIAS)
            try:
                self._len = int(v) if e2 == 0 else 0
            except ValueError:
                self._len = 0
        return self.seq

    def play(self):
        if self.open_ok:
            self._cache.pop("mode", None)
            self._mci("play " + self.ALIAS)
            self._state = "playing"

    def pause(self):
        if self.open_ok:
            self._cache.pop("mode", None)
            self._mci("pause " + self.ALIAS)
            self._state = "paused"

    def stop(self):
        if self.open_ok:
            self._cache = {}
            self._mci("stop " + self.ALIAS)
            self._mci("seek %s to start" % self.ALIAS)
        self._state = "stopped"

    def seek(self, ms):
        if self.open_ok:
            self._cache.pop("position", None)
            self._mci("seek %s to %d" % (self.ALIAS, int(ms)))

    def set_volume(self, v):
        if self.open_ok:
            self._mci("setaudio %s volume to %d"
                      % (self.ALIAS, int(max(0.0, min(1.0, float(v))) * 1000)))

    def snapshot(self):
        if not self.open_ok:
            return {"id": self.seq, "state": "stopped", "pos": 0, "len": 0,
                    "resolved": False}
        err, v = self._ask("mode", "status %s mode")
        raw = v.strip().lower() if err == 0 and v else "stopped"
        state = raw if raw in ("playing", "paused") else "stopped"
        # MCI has no "the song finished" event; a player that was told to play
        # and has gone quiet has finished.
        if state == "stopped" and self._state == "playing":
            state = "ended"
        err, v = self._ask("position", "status %s position")
        try:
            pos = int(v) if err == 0 else 0
        except ValueError:
            pos = 0
        return {"id": self.seq, "state": state, "pos": pos, "len": self._len,
                "resolved": True}

    def shutdown(self):
        if self.open_ok:
            self._mci("close " + self.ALIAS)
            self.open_ok = False


# The guns, by the names the game itself uses. Taken from the shipped pak's
# Enum_WeaponTypes display names, not invented - a cooked enum keeps them even
# though the header dump does not show them.
GUN_NAMES = {
    "bp_Skel_ak_C":      "AK compact 5.56",
    "bp_Skel_shotgun_C": "Pump 12ga shotgun",
    "bp_skel_glock_C":   "Glock-style .45",
    "bp_skel_92fs_C":    "Piovra 92FU pistol",
    "SkeletalGun_C":     "gun",
}

# Enum_FireStates, same source. 0 is Auto - which is why Full Auto sets it -
# and a shotgun ships as Single: one shot per trigger pull, by name.
FIRE_MODES = {"0": "Auto", "1": "Semi", "2": "Burst", "3": "Single"}


def gun_name(cls):
    """A gun's own name, falling back to the blueprint if it is a new one."""
    cls = (cls or "").strip()
    if cls in GUN_NAMES:
        return GUN_NAMES[cls]
    tidy = cls.replace("bp_Skel_", "").replace("bp_skel_", "").replace("_C", "")
    return tidy or "?"


def _process_running(exe_name):
    """Is a process with this executable name running? None = cannot tell.

    Straight to the kernel, because the obvious way is dear: `tasklist` is a
    program, and starting one costs 289 ms here. This costs about 5.
    """
    try:
        psapi = ctypes.WinDLL("psapi")
        kernel32 = ctypes.WinDLL("kernel32")
    except Exception:
        return None
    want = exe_name.lower()
    arr = (ctypes.c_uint * 4096)()
    need = ctypes.c_uint()
    if not psapi.EnumProcesses(ctypes.byref(arr), ctypes.sizeof(arr),
                               ctypes.byref(need)):
        return None
    count = min(need.value // ctypes.sizeof(ctypes.c_uint), 4096)
    buf = ctypes.create_unicode_buffer(260)
    QUERY_LIMITED_INFORMATION = 0x1000
    for i in range(count):
        pid = arr[i]
        if not pid:
            continue
        handle = kernel32.OpenProcess(QUERY_LIMITED_INFORMATION, False, pid)
        if not handle:
            continue                      # ours to ignore: system processes
        try:
            size = ctypes.c_uint(260)
            if kernel32.QueryFullProcessImageNameW(handle, 0, buf,
                                                   ctypes.byref(size)):
                if buf.value.lower().endswith(want):
                    return True
        finally:
            kernel32.CloseHandle(handle)
    return False


class MusicPlayer:
    """Plays a folder of your own music.

    Why here and not in the game: Unreal cannot load an mp3 from disk at
    runtime without a plugin Blood Trail does not ship, and the PC's sound
    already reaches the headset through Link / Air Link - so music played here
    is heard in VR. The in-game MUSIC tab is a remote control for this.

    See the note above MediaEngine for what changed and why.
    """

    # mp4/m4v are containers whose audio track Media Foundation reads
    # perfectly well - and the old engine could not have, which is
    # probably why they were never on this list.
    EXTS = (".mp3", ".wav", ".wma", ".m4a", ".aac", ".flac",
            ".mp4", ".m4v", ".ogg", ".opus")

    def __init__(self):
        self.folder = ""
        self.tracks = []
        self.order = []
        self.pos = -1
        self.is_open = False
        self.engine = None
        self.engine_name = ""
        self._open_id = 0
        self._pending = ""
        self._skips = 0
        # files THIS engine refused - see _skip_bad
        self._unplayable = set()
        self.want_playing = False
        self.started_at = 0.0
        self.volume = 0.6
        # WHICH SPEAKERS. Empty is whatever Windows calls the default. A real
        # id is one audio output the music is rendered straight to, which
        # leaves the game - and everything else - where it was.
        self.device = ""
        self.shuffle = False
        self.repeat = True
        self.error = ""

    def ensure_engine(self):
        """Modern stack if it will start, MCI if it will not."""
        if self.engine is not None:
            return self.engine
        eng = MediaEngine()
        if eng.start():
            self.engine = eng
            self.engine_name = "Windows Media Foundation"
        else:
            self.engine = MciEngine()
            self.engine.start()
            self.engine_name = "MCI (fallback)"
        self.engine.set_volume(self.volume)
        if self.device:
            self.engine.set_device(self.device)
        return self.engine

    def engine_kind(self):
        return self.engine.kind if self.engine is not None else ""

    # ------------------------------------------------------------- output
    def list_devices(self):
        return self.engine.list_devices() if self.engine is not None else []

    def can_choose_device(self):
        return bool(self.engine is not None and self.engine.can_choose_device)

    def set_device(self, device_id):
        """Move the music to another output, keeping its place in the song."""
        self.device = device_id or ""
        eng = self.ensure_engine()
        return eng.set_device(self.device)

    # ------------------------------------------------------------- playlist
    def load_folder(self, folder):
        self.close()
        # a fresh look at the folder deserves a fresh opinion of its files
        self._unplayable = set()
        self.folder = folder or ""
        found = []
        if self.folder and os.path.isdir(self.folder):
            for root, _dirs, files in os.walk(self.folder):
                for name in files:
                    if name.lower().endswith(self.EXTS):
                        found.append(os.path.join(root, name))
        found.sort(key=lambda p: os.path.basename(p).lower())
        self.tracks = found[:5000]
        self._reorder(keep=False)

    def _reorder(self, keep=True):
        cur = self.current_index()
        self.order = list(range(len(self.tracks)))
        if self.shuffle:
            random.shuffle(self.order)
        if keep and cur is not None and cur in self.order:
            if self.shuffle:
                self.order.remove(cur)
                self.order.insert(0, cur)
            self.pos = self.order.index(cur)
        else:
            self.pos = 0 if self.tracks else -1

    def set_shuffle(self, on):
        if bool(on) != self.shuffle:
            self.shuffle = bool(on)
            self._reorder(keep=True)

    def current_index(self):
        if 0 <= self.pos < len(self.order):
            return self.order[self.pos]
        return None

    def title(self):
        i = self.current_index()
        if i is None or i >= len(self.tracks):
            return ""
        return os.path.splitext(os.path.basename(self.tracks[i]))[0]

    # ------------------------------------------------------------- transport
    def close(self):
        if self.engine is not None and self.is_open:
            self.engine.stop()
        self.is_open = False
        self.want_playing = False
        self._pending = ""

    def shutdown(self):
        """Called when the window closes. Takes the child process with it."""
        if self.engine is not None:
            try:
                self.engine.shutdown()
            except Exception:
                pass
            self.engine = None

    def _skip_bad(self, path):
        """One file nobody can play should not stop the playlist - but walking
        off the END of the playlist is still the end of it when Repeat is off."""
        self.error = "skipped (cannot play): " + os.path.basename(path)
        self._skips += 1
        at_end = self.pos + 1 >= len(self.order)
        if self._skips >= min(len(self.order), 10) or (at_end and not self.repeat):
            self._skips = 0
            self.want_playing = False
            self.is_open = False
            return False
        self.pos = (self.pos + 1) % len(self.order)
        return self._start()

    def _start(self):
        """Ask for a track. Returns as soon as the request is sent.

        NOTHING HERE WAITS FOR THE AUDIO DEVICE. Whether the file actually
        opened arrives later, on the reader thread, and tick() acts on it -
        which is why a track change no longer freezes the window.
        """
        i = self.current_index()
        if i is None:
            return False
        path = self.tracks[i]
        eng = self.ensure_engine()
        if path in self._unplayable:
            return self._skip_bad(path)
        self._pending = path
        self._open_id = eng.open(path)
        eng.set_volume(self.volume)
        eng.play()
        self.is_open = True
        self.want_playing = True
        self.started_at = time.time()
        if self._skips == 0:
            self.error = ""
        return True

    def play_track(self, track_index):
        if 0 <= track_index < len(self.tracks):
            if track_index in self.order:
                self.pos = self.order.index(track_index)
            self._skips = 0
            return self._start()
        return False

    def toggle(self):
        """Decided from what we ASKED FOR, not from what the device says.

        The device is a round trip away and, just after a track change, has
        not caught up yet - asking it made PLAY/PAUSE do the opposite.
        """
        if not self.is_open:
            self._skips = 0
            self._start()
        elif self.want_playing:
            self.engine.pause()
            self.want_playing = False
        else:
            self.engine.play()
            self.want_playing = True

    def next(self, auto=False):
        if not self.order:
            return
        n = self.pos + 1
        if n >= len(self.order):
            if auto and not self.repeat:
                self.stop()
                return
            if self.shuffle:
                random.shuffle(self.order)
            n = 0
        self.pos = n
        if not auto:
            self._skips = 0
        self._start()

    def prev(self):
        if not self.order:
            return
        # like every player: a few seconds in, Previous restarts the song
        if self.is_open and self.position_ms() > 3000:
            self.engine.seek(0)
            self.engine.play()
            self.want_playing = True
            self.started_at = time.time()
            return
        self._skips = 0
        self.pos = (self.pos - 1) % len(self.order)
        self._start()

    def stop(self):
        self.want_playing = False
        if self.engine is not None and self.is_open:
            self.engine.stop()

    def command(self, cmd):
        cmd = (cmd or "").strip().lower()
        if cmd == "toggle":
            self.toggle()
        elif cmd == "next":
            self.next()
        elif cmd == "prev":
            self.prev()
        elif cmd == "stop":
            self.stop()

    # ---------------------------------------------------------------- state
    #
    # All four of these are dictionary lookups. The old player asked winmm
    # fourteen times a second from the Tk thread; this one asks nobody.
    def _snap(self):
        if self.engine is None:
            return {"id": 0, "state": "stopped", "pos": 0, "len": 0,
                    "resolved": None}
        return self.engine.snapshot()

    def mode(self):
        """What the device is actually doing."""
        if not self.is_open:
            return "stopped"
        s = self._snap()["state"]
        return s if s in ("playing", "paused") else "stopped"

    def state(self):
        """What to SHOW. A track that has been asked for but has not finished
        opening yet is 'playing' on the panel - it is about to be."""
        if not self.is_open:
            return "stopped"
        s = self._snap()["state"]
        if s in ("playing", "paused"):
            return s
        return "playing" if self.want_playing else "stopped"

    def position_ms(self):
        return self._snap()["pos"] if self.is_open else 0

    def length_ms(self):
        return self._snap()["len"] if self.is_open else 0

    def apply_volume(self):
        if self.engine is not None:
            self.engine.set_volume(self.volume)

    def tick(self):
        """Called twice a second. Reacts to what the reader thread has seen.

        Three things can have happened since last time: the file turned out to
        be unplayable, the file opened, or the song finished.
        """
        if not self.is_open:
            return
        snap = self._snap()
        if snap["id"] != self._open_id and self.engine_kind() == "mf":
            return
        if snap["resolved"] is False:
            bad, self._pending = self._pending, ""
            if bad:
                self._unplayable.add(bad)
                self._skip_bad(bad)
            return
        if snap["resolved"] is True and self._pending:
            self._pending = ""
            self._skips = 0
        if snap["state"] == "ended" and self.want_playing:
            if time.time() - self.started_at > 1.0:
                self.next(auto=True)

# Toggles the player can flip from inside VR. The MOD owns these while the game
# is running - the panel pushing its own copy every second is what made the
# right-stick crouch "sink a bit then shoot straight back up": you clicked, the
# mod crouched, and a second later the panel wrote its stale 0 back over it.
# These are synced FROM status.txt instead of being pushed to control.txt.
# Toggles the player can also flip from the VR controller (right stick =
# crouch, Y = fly, X = noclip). The panel must ECHO these from status.txt
# rather than assert them, or its once-a-second write stamps the button
# press straight back off.
MOD_OWNED = ("CrouchDown", "FlyMode", "NoClip")

# name -> (default, kind, min, max, step)  kind: "bool" | "num"
# WHICH GRAPHICS CARD THIS IS.
#
# The game cannot ask Windows without shelling out mid-frame, and it only
# needs the answer to tell you which upscaler to pick - so the app looks it up
# once, in a thread so the window never waits for it, and sends the name over
# with everything else. DLSS and FSR are plugins a game has to ship; Blood
# Trail ships neither, so the honest recommendation is almost always the
# built-in one, whatever card this turns out to be.
_GPU_NAME = ""

# Windows lists more than one "video controller" and the first one is often
# not a graphics card at all. On this very PC it reports
#   Meta Virtual Monitor
# first - the display Quest Link creates - which would have had the app
# recommending an upscaler for a virtual screen. So take the whole list and
# pick a real card out of it.
_GPU_JUNK = ("virtual", "basic display", "basic render", "remote", "idd",
             "parsec", "meta ", "oculus", "vmware", "citrix", "mirror",
             "teamviewer", "duet", "spacedesk")
_GPU_REAL = ("nvidia", "geforce", "rtx", "gtx", "quadro", "radeon", "amd ",
             "intel", "arc ", "iris")


def pick_gpu(names):
    """The best real graphics card out of everything Windows lists."""
    clean = [n.strip() for n in names if n and n.strip()]
    for n in clean:                       # a name we recognise as a card
        low = n.lower()
        if any(k in low for k in _GPU_REAL) and not any(j in low for j in _GPU_JUNK):
            return n[:48]
    for n in clean:                       # else anything that is not obviously fake
        if not any(j in n.lower() for j in _GPU_JUNK):
            return n[:48]
    return clean[0][:48] if clean else ""


def detect_gpu():
    global _GPU_NAME
    try:
        import subprocess
        flags = 0
        if hasattr(subprocess, "CREATE_NO_WINDOW"):
            flags = subprocess.CREATE_NO_WINDOW
        out = subprocess.run(
            ["powershell", "-NoProfile", "-NonInteractive", "-Command",
             "Get-CimInstance Win32_VideoController | "
             "Select-Object -ExpandProperty Name"],
            capture_output=True, text=True, timeout=20, creationflags=flags)
        _GPU_NAME = pick_gpu((out.stdout or "").splitlines())
    except Exception:
        _GPU_NAME = ""

def gpu_advice():
    if not _GPU_NAME:
        return "looking..."
    up = _GPU_NAME.upper()
    if "NVIDIA" in up or "GEFORCE" in up or "RTX" in up or "GTX" in up:
        why = "DLSS needs the game to ship the plugin and this one does not, so use Built-in"
    elif "AMD" in up or "RADEON" in up:
        why = "FSR needs the game to ship the plugin and this one does not, so use Built-in"
    else:
        why = "use Built-in"
    return f"{_GPU_NAME}  -  {why}"


SETTINGS = {
    "SafeMode":           (False, "bool"),
    "GodMode":            (True,  "bool"),
    "InfiniteBulletTime": (True,  "bool"),
    "InfiniteCourage":    (True,  "bool"),
    "InstantCrackRegen":  (False, "bool"),
    "InfiniteMana":       (False, "bool"),
    "InfiniteArrows":     (False, "bool"),
    "InfiniteAmmo":       (True,  "bool"),
    "NoRecoil":           (True,  "bool"),
    "FreezeEnemies":      (False, "bool"),
    "StopEnemySpawns":    (False, "bool"),
    "SuperSpeed":         (False, "bool"),
    "VirtualJump":        (False, "bool"),
    "HighJump":           (False, "bool"),
    "TeleportBoost":      (False, "bool"),
    "FlyMode":            (False, "bool"),
    "NoClip":             (False, "bool"),
    "FlySpeed":           (600.0, "num", 100.0, 4000.0, 100.0),
    "FlyDeadzone":        (0.20,  "num", 0.05, 0.6, 0.05),
    "CrouchDown":         (False, "bool"),
    "CrouchOnStick":      (True,  "bool"),
    "FlyNeedsStick":      (True,  "bool"),
    "BrightWorld":        (False, "bool"),
    "Brightness":         (2.0,   "num", 1.0, 5.0, 0.25),
    "CrouchHeight":       (40.0,  "num", 20.0, 90.0, 5.0),
    "CrouchDrop":         (50.0,  "num", 0.0, 150.0, 10.0),
    "GoreForever":        (False, "bool"),
    "EnemyESP":           (False, "bool"),
    "FullAuto":           (False, "bool"),
    "MeleeWeaponDamage":  (False, "bool"),
    "MeleeKnockback":     (10.0,  "num", 2.0, 100.0, 5.0),
    "MeleeDamage":        (100.0, "num", 25.0, 1000.0, 25.0),
    "MeleeWeightClass":   (10.0,  "num", 1.0, 50.0, 1.0),
    "MeleeAlwaysHits":    (True,  "bool"),
    "MeleeReach":         (60.0,  "num", 10.0, 250.0, 10.0),
    "GrabEnemies":        (False, "bool"),
    "GrabRange":          (90.0,  "num", 30.0, 250.0, 10.0),
    "ThrowForce":         (1800.0, "num", 200.0, 6000.0, 200.0),
    "NoAccidentalLamp":   (True,  "bool"),
    "StrengthFists":      (False, "bool"),
    "FistStrikePower":    (10.0,  "num", 1.0, 50.0, 1.0),
    "FistDamage":         (150.0, "num", 25.0, 1000.0, 25.0),
    "FistRagdoll":        (True,  "bool"),
    "FistLaunch":         (True,  "bool"),
    "FistLaunchForce":    (900.0, "num", 0.0, 4000.0, 150.0),
    "FireRateValue":      (0.06,  "num", 0.02, 0.5, 0.02),
    "AutoFireOn":         (True,  "bool"),
    "AutoFireGap":        (0.25,  "num", 0.10, 0.50, 0.05),
    "AkSpeed":            (1.0,   "num", 0.5, 3.0, 0.1),
    "AimImpactFx":        (True,  "bool"),
    "FireModeIndex":      (0.0,   "num", 0.0, 3.0, 1.0),
    "SpeedMultiplier":    (2.0,   "num", 1.0, 10.0, 0.5),
    "JumpMultiplier":     (2.0,   "num", 1.0, 10.0, 0.5),
    "TimeScale":          (1.0,   "num", 0.1, 3.0, 0.1),
    # forced max HP while God Mode is on. The difficulty board overwrites max HP
    # (BRUTAL sets it to 1), so God Mode has to force it back.
    "GodHP":              (10000.0, "num", 1000.0, 100000.0, 1000.0),
    # --- menu / audio settings, mirrored from the in-game SETTINGS tab ---
    "MasterVolume":  (1.0, "num", 0.0, 1.0, 0.05),
    "PanelSize":     (3.8, "num", 0.6, 6.0, 0.2),
    "PanelLift":     (0.0, "num", -20.0, 20.0, 1.0),
    "PointerPitch":  (-45.0, "num", -90.0, 90.0, 5.0),
    "PanelOnTop":    (False, "bool"),
    "PanelDepthFix": (True, "bool"),
    "PanelGlow": (True, "bool"),
    "PanelSolidBg":  (False, "bool"),
    "TwoPointers":   (True, "bool"),
    "TouchPointer":  (False, "bool"),
    "AimFromSocket": (False, "bool"),
    "AimFromWidget": (True, "bool"),
    "TouchRange":    (25.0, "num", 5.0, 200.0, 5.0),
    # --- ESP tab (esp_plus.lua) ---
    "ESPNames":         (True,  "bool"),
    "ESPHealth":        (True,  "bool"),
    "ESPDistance":      (True,  "bool"),
    "ESPDirection":     (True,  "bool"),
    "ESPHeight":        (True,  "bool"),
    "ESPRadar":         (True,  "bool"),
    "ESPMaxRange":      (100.0, "num", 10.0, 300.0, 10.0),
    "ESPMaxRows":       (6.0,   "num", 1.0, 12.0, 1.0),
    "ESPBoxes":         (False, "bool"),
    "ESPHitboxes":      (False, "bool"),
    "ESPBoxColor":      (0.0,   "num", 0.0, 8.0, 1.0),
    "ESPRgb":           (False, "bool"),
    # --- Aim tab (aim_assist.lua) ---
    "SilentAim":        (False, "bool"),
    "SilentFov":        (90.0,  "num", 5.0, 180.0, 5.0),
    "AimBone":          (0.0,   "num", 0.0, 8.0, 1.0),
    "AimPriority":      (0.0,   "num", 0.0, 3.0, 1.0),
    "AimThroughWalls":  (False, "bool"),
    "AimSticky":        (False, "bool"),
    "AimHitChance":     (100.0, "num", 5.0, 100.0, 5.0),
    "AimShowTarget":    (True,  "bool"),
    "AimForceDamage":   (False, "bool"),
    "AimForceAmount":   (100.0, "num", 25.0, 1000.0, 25.0),
    "AimOneShot":       (False, "bool"),
    "AimAssist":        (False, "bool"),
    "AimFov":           (15.0,  "num", 2.0, 45.0, 1.0),
    "AimStrength":      (100.0, "num", 10.0, 100.0, 10.0),
    "AimRange":         (60.0,  "num", 5.0, 200.0, 5.0),
    "AimShotgun":       (True,  "bool"),
    "NoSpread":         (False, "bool"),
    "AimKeepShotgunSpread": (True, "bool"),
    "AimGun":           (False, "bool"),
    "AimBullet":        (True,  "bool"),
    "AimCone":          (True,  "bool"),
    "AimBeam":          (True,  "bool"),
    "AimBeamColor":     (0.0,   "num", 0.0, 7.0, 1.0),
    "AimBeamRGB":       (False, "bool"),
    "AimBeamLaser":     (False, "bool"),
    "AimBeamPitch":     (0.0,   "num", -20.0, 20.0, 0.5),
    "AimBeamYaw":       (0.0,   "num", -20.0, 20.0, 0.5),
    "AimBeamLength":    (20.0,  "num", 5.0, 100.0, 5.0),
    "AimBeamWalls":     (True,  "bool"),
    "AimConeMark":      (True,  "bool"),
    "AimConeColor":     (6.0,   "num", 0.0, 7.0, 1.0),
    "AimBeamTrack":     (True,  "bool"),
    "AimMakeItHit":     (True,  "bool"),
    "AimBeamSize":      (1.0,   "num", 0.2, 5.0, 0.2),
    # --- touch beside your head (player_mods.lua) ---
    "HeadTouch":        (True,  "bool"),
    "HeadTouchLeft":    (0.0,   "num", 0.0, 2.0, 1.0),
    "HeadTouchRight":   (1.0,   "num", 0.0, 2.0, 1.0),
    "HeadTouchRange":   (38.0,  "num", 20.0, 60.0, 2.0),
    # --- Optimizer tab (optimizer.lua) ---
    "OptEnabled":       (False, "bool"),
    "OptPreset":        (3.0,   "num", 1.0, 5.0, 1.0),
    # --- Opt GPU tab: upscaling and the per-effect knobs ---
    "OptUpscaler":       (0.0,  "num", 0.0, 4.0, 1.0),
    "OptUpscaleQuality": (1.0,  "num", 0.0, 4.0, 1.0),
    "OptSharpen":        (0.0,  "num", 0.0, 1.0, 0.1),
    "OptShadowDist":     (0.0,  "num", 0.0, 2.0, 0.1),
    "OptAnisotropy":     (0.0,  "num", 0.0, 16.0, 1.0),
    "OptCSMRes":         (0.0,  "num", 0.0, 2048.0, 256.0),
    "OptSSR":            (-1.0, "num", -1.0, 4.0, 1.0),
    "OptAO":             (-1.0, "num", -1.0, 4.0, 1.0),
    "OptMotionBlur":     (-1.0, "num", -1.0, 4.0, 1.0),
    "OptDoF":            (-1.0, "num", -1.0, 4.0, 1.0),
    "OptParticleLOD":    (0.0,  "num", 0.0, 4.0, 1.0),
    "OptMipBias":        (0.0,  "num", 0.0, 4.0, 1.0),
    "OptNoSpectator":    (False, "bool"),
    "OptRoundRobin":     (False, "bool"),
    "OptFramePacing":    (False, "bool"),
    # --- Opt System tab: memory, the collector, the CPU, audio, loading ---
    "OptGcMode":         (0.0,  "num", 0.0, 3.0, 1.0),
    "OptPhysThreads":    (0.0,  "num", 0.0, 4.0, 1.0),
    "OptFewerRagdolls":  (False, "bool"),
    "OptAnimBudget":     (False, "bool"),
    "OptStreamBoost":    (False, "bool"),
    "OptTrimRam":        (False, "bool"),
    "OptRamMipBias":     (0.0,  "num", 0.0, 4.0, 1.0),
    "OptAudioVoices":    (0.0,  "num", 0.0, 64.0, 4.0),
    "OptFastLoad":       (False, "bool"),
    "OptCustom":        (False, "bool"),
    "OptResolution":    (0.0,   "num", 0.0, 100.0, 5.0),
    "OptPixelDensity":  (0.0,   "num", 0.0, 1.5, 0.05),
    "OptShadows":       (-1.0,  "num", -1.0, 3.0, 1.0),
    "OptViewDistance":  (-1.0,  "num", -1.0, 3.0, 1.0),
    "OptFoliage":       (-1.0,  "num", -1.0, 3.0, 1.0),
    "OptEffects":       (-1.0,  "num", -1.0, 3.0, 1.0),
    "OptPostProcess":   (-1.0,  "num", -1.0, 3.0, 1.0),
    "OptTextures":      (-1.0,  "num", -1.0, 3.0, 1.0),
    "OptTexturePool":   (0.0,   "num", 0.0, 4000.0, 100.0),
    "OptEnemyDetail":   (-1.0,  "num", -1.0, 3.0, 1.0),
    "OptFpsCap":        (0.0,   "num", 0.0, 144.0, 6.0),
    "OptAutoRes":       (False, "bool"),
    "OptTargetFps":     (72.0,  "num", 30.0, 144.0, 2.0),
    "OptNoFog":         (False, "bool"),
    "OptNoLensFlares":  (False, "bool"),
    "OptNoLightShafts": (False, "bool"),
    "OptNoBloom":       (False, "bool"),
    "OptFastDecalFade": (False, "bool"),
    "OptNoImpactFX":    (False, "bool"),
    "OptSmoothGC":      (False, "bool"),
    "OptSmoothStreaming": (False, "bool"),
    "OptCorpseCleanup": (False, "bool"),
    "OptCorpseSeconds": (20.0,  "num", 5.0, 300.0, 5.0),
    "OptBloodCleanup":  (False, "bool"),
    "OptBloodSeconds":  (45.0,  "num", 5.0, 600.0, 5.0),
    "OptFreezeBodies":  (False, "bool"),
    # --- Music tab (music.lua + MusicPlayer above) ---
    "MyMusicVolume":    (0.6,   "num", 0.0, 1.0, 0.05),
    "MyMusicShuffle":   (False, "bool"),
    "MyMusicRepeat":    (True,  "bool"),
    "MusicDuckGame":    (True,  "bool"),
    "MusicDuckLevel":   (0.1,   "num", 0.0, 1.0, 0.05),
    "MusicAutoStart":   (True,  "bool"),
    # --- Saves tab (saves.lua) ---
    "SaveAuto":         (True,  "bool"),
    "SaveLoadOnStart":  (True,  "bool"),
    "SaveProfile":      (1.0,   "num", 1.0, 3.0, 1.0),
}

# ---------------------------------------------------------------------------
# saved settings
# ---------------------------------------------------------------------------
# The mod writes these (saves.lua) and loads them when the game starts. While
# the game is running, this window's Save/Load buttons ask the MOD to do it;
# with the game closed they work on the files directly, so what you set up
# here is what the game starts with.
SAVED_SETTINGS = os.path.join(BRIDGE, "saved_settings.txt")
SAVE_PROFILES = 3
# never saved - momentary, or kept elsewhere (same list as saves.lua)
SAVE_SKIP = {"PointerPitch", "PointerYaw", "CrouchDown", "FlyMode", "NoClip", "GammaDefault"}
SAVE_META = {"version", "saved", "note"}


def profile_path(n):
    return os.path.join(BRIDGE, "saved_profile%d.txt" % n)


def read_saved(path):
    """key -> raw value from a save file (or its .tmp), {} if there is none."""
    for p in (path, path + ".tmp"):
        try:
            with open(p, "r", encoding="utf-8") as fh:
                kv = {}
                for line in fh:
                    line = line.strip()
                    if line and not line.startswith("#") and "=" in line:
                        k, v = line.split("=", 1)
                        kv[k.strip()] = v.strip()
                if kv:
                    return kv
        except OSError:
            continue
    return {}


def write_saved(path, values, note):
    """Write a save in the mod's own format, atomically."""
    lines = ["# Blood Trail Mod Menu - saved settings. Written by the mod;",
             "# the desktop app reads it too. Delete this file to start fresh.",
             "version=1", "saved=%d" % int(time.time()), "note=%s" % note]
    for k in sorted(values):
        if k not in SAVE_SKIP and k not in SAVE_META:
            lines.append("%s=%s" % (k, values[k]))
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    os.replace(tmp, path)


def import_last_session(status_path):
    """The st_<key> values the game left in status.txt, as saved-file keys."""
    lower = {k.lower(): k for k in SETTINGS}
    kv = {}
    try:
        with open(status_path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("st_") and "=" in line:
                    k, v = line[3:].split("=", 1)
                    real = lower.get(k)
                    if real and real not in SAVE_SKIP:
                        kv[real] = v
    except OSError:
        return {}
    return kv if len(kv) >= 10 else {}

# Settings whose number picks a NAME. Shown as a drop-down; the value sent to
# the game is still the index, exactly as the in-game menu stores it.
CHOICES = {
    "AimBone":     ["Head", "Neck", "Chest", "Stomach", "Pelvis", "Arms", "Legs",
                    "Nearest part (to where you point)", "Random part"],
    "AimPriority": ["Closest to where I point", "Closest to me", "Lowest health",
                    "Highest health"],
    "ESPBoxColor": ["By enemy type  (cultist red, zombie green, NPC yellow)", "Red",
                    "Green", "Blue", "Yellow", "Cyan", "Pink", "White", "Orange"],
    "AimBeamColor": ["Green", "Red", "Blue", "Yellow", "Cyan", "Pink", "White", "Orange"],
    "AimConeColor": ["Red", "Green", "Blue", "Yellow", "Cyan", "Pink", "White", "Orange"],
    "OptUpscaler": ["Off  (render at full resolution)",
                    "Built-in  (works on any graphics card - use this one)",
                    "AMD FSR 1  (only if the game shipped the plugin)",
                    "AMD FSR 2  (only if the game shipped the plugin)",
                    "NVIDIA DLSS  (only if the game shipped the plugin)"],
    "OptUpscaleQuality": ["Ultra Quality  (77%)", "Quality  (67%)", "Balanced  (59%)",
                          "Performance  (50%)", "Ultra Performance  (33%)"],
    "OptGcMode": ["Game default  (a pause about once a minute)",
                  "Less often  (every 2 minutes)", "Rarely  (every 5 minutes)",
                  "Between rounds  (every 10 minutes)"],
    "OptPhysThreads": ["Game default", "2 threads", "4 threads", "6 threads",
                       "All cores"],
    "HeadTouchLeft":  ["Flashlight", "Night vision", "Nothing"],
    "HeadTouchRight": ["Flashlight", "Night vision", "Nothing"],
}

# How a slider shows its value, where the old if/elif chain in add_row would
# guess wrong. A quality step of -1, or 0 on resolution, means "leave the
# game's own value", so it says so.
_QUALITY = ["low", "medium", "high", "epic"]
SLIDER_FMT = {
    "AimFov":           lambda v: f"{v:.0f} deg",
    "SilentFov":        lambda v: "all round" if v >= 180 else f"{v:.0f} deg",
    "AimHitChance":     lambda v: f"{v:.0f}%",
    "AimForceAmount":   lambda v: f"{v:.0f}",
    "AimStrength":      lambda v: f"{v:.0f}%",
    "AimRange":         lambda v: f"{v:.0f} m",
    "AimBeamLength":    lambda v: f"{v:.0f} m",
    "AimBeamSize":      lambda v: f"{v:.1f}x",
    "HeadTouchRange":   lambda v: f"{v:.0f} cm",
    "OptSharpen":       lambda v: "game" if v <= 0 else f"{v:.1f}",
    "OptShadowDist":    lambda v: "game" if v <= 0 else f"{v:.1f}x",
    "OptAnisotropy":    lambda v: "game" if v <= 0 else f"{v:.0f}x",
    "OptCSMRes":        lambda v: "game" if v <= 0 else f"{v:.0f}",
    "OptParticleLOD":   lambda v: "game" if v <= 0 else f"-{v:.0f}",
    "OptMipBias":       lambda v: "game" if v <= 0 else f"-{v:.0f}",
    "OptRamMipBias":    lambda v: "game" if v <= 0 else f"-{v:.0f}",
    "OptAudioVoices":   lambda v: "game" if v <= 0 else f"{v:.0f} at once",
    "ESPMaxRange":      lambda v: f"{v:.0f} m",
    "ESPMaxRows":       lambda v: f"{v:.0f}",
    "OptPreset":        lambda v: ["", "Game", "Quality", "Balanced", "Performance", "Potato"][max(1, min(5, int(round(v))))],
    "OptResolution":    lambda v: "game" if v <= 0 else f"{v:.0f}%",
    "OptPixelDensity":  lambda v: "game" if v <= 0 else f"{v:.2f}",
    "OptTexturePool":   lambda v: "game" if v <= 0 else f"{v:.0f} MB",
    "OptFpsCap":        lambda v: "off" if v <= 0 else f"{v:.0f}",
    "OptTargetFps":     lambda v: f"{v:.0f} fps",
    "OptCorpseSeconds": lambda v: f"{v:.0f} s",
    "OptBloodSeconds":  lambda v: f"{v:.0f} s",
    "OptEnemyDetail":   lambda v: "game" if v < 0 else ("full" if v < 0.5 else f"-{v:.0f} LOD"),
    "MyMusicVolume":    lambda v: f"{v * 100:.0f}%",
    "MusicDuckLevel":   lambda v: f"{v * 100:.0f}%",
}
for _k in ("OptShadows", "OptViewDistance", "OptFoliage", "OptEffects",
           "OptPostProcess", "OptTextures", "OptSSR", "OptAO", "OptMotionBlur",
           "OptDoF"):
    SLIDER_FMT[_k] = (lambda v: "game" if v < 0 else _QUALITY[max(0, min(3, int(round(v))))])


TABS = [
    ("Player", [
        ("toggle", "SafeMode",           "SAFE MODE  (turns off enemy features - stops the round-end crash)"),
        ("toggle", "GodMode",            "God Mode  (cannot be hurt)"),
        ("slider", "GodHP",              "God Mode max HP  (overrides difficulty)"),
        ("toggle", "InfiniteBulletTime", "Infinite Bullet Time"),
        ("toggle", "InfiniteCourage",    "Infinite Courage"),
        ("toggle", "InstantCrackRegen",  "Instant Crack Regen"),
        ("toggle", "InfiniteMana",       "Infinite Mana"),
        ("toggle", "InfiniteArrows",     "Infinite Arrows"),
        ("button", "heal",               "Heal To Full Now"),
    ]),
    # Melee lives on Combat, guns and gear on Combat V2. One tab held all of it
    # and the last few rows fell off the bottom of the window unseen.
    ("Combat", [
        ("toggle", "MeleeWeaponDamage", "Melee Weapon DMG  (pipe, hammer, knife hit harder)"),
        ("slider", "MeleeDamage",       "Weapon damage per hit"),
        ("slider", "MeleeWeightClass",  "Weapon weight - how heavy every melee weapon swings"),
        ("slider", "MeleeKnockback",    "Weapon knockback multiplier"),
        ("button", "meleetest",         "Test Weapon Damage  (spawn an enemy first)"),
        ("toggle", "MeleeAlwaysHits",   "Melee Always Hits  (swings connect like Hard Bullet / B&S)"),
        ("slider", "MeleeReach",        "Melee reach - how forgiving the hit box is"),
    ]),
    ("Hand & Grab", [
        ("toggle", "StrengthFists",     "Strength Fists  (bare punches hit like a hammer)"),
        ("slider", "FistStrikePower",   "Fist power - the hand's weight class"),
        ("slider", "FistDamage",        "Fist damage per punch"),
        ("toggle", "FistRagdoll",       "Knock Them Down  (punched bodies go limp)"),
        ("toggle", "FistLaunch",        "Send Them Flying  (and get thrown back)"),
        ("slider", "FistLaunchForce",   "Launch force - how far they fly"),
        ("button", "fisttest",          "Test Fist Damage  (spawn an enemy first)"),
        ("toggle", "GrabEnemies",       "Grab & Throw Bodies  (grip near a body, swing, let go)"),
        ("slider", "GrabRange",         "Grab range - how close your hand must be"),
        ("slider", "ThrowForce",        "Throw force - how hard you can hurl them"),
        ("button", "grabtest",          "Test Grab & Throw  (spawn an enemy first)"),
    ]),
    ("Combat V2", [
        ("toggle", "InfiniteAmmo",  "Infinite Ammo"),
        ("toggle", "NoRecoil",      "No Recoil"),
        ("toggle", "FullAuto",      "Full Auto  (every gun, shotgun included - hold the trigger, no pumping)"),
        ("status", "norecoil",      "Is No Recoil actually on?"),
        ("toggle", "AutoFireOn",    "Auto fire - for the pump shotgun: one shell when you click, then one at the pace below while you hold.  Pistols and the AK use the game's own automatic.  (off = one shell each time you pull the trigger)"),
        ("slider", "AutoFireGap",   "Shotgun pace - seconds between shells while you hold  (0.10 fastest, which IS an SMG ... 0.50 slowest, a heavy pump)"),
        ("slider", "AkSpeed",       "AK speed - how fast it fires while you hold  (1.0 = its own 0.1 s a bullet, 2.0 twice as fast, 0.5 half; any gun that ships automatic)"),
        ("slider", "FireModeIndex", "Fire mode  (0 = Auto, 1 = Semi, 2 = Burst, 3 = Single - the game's own names)"),
        ("status", "gunstate",      "The gun in your hand"),
        ("status", "mirror",        "Your monitor"),
        ("status", "shotnow",       "How fast it is firing right now"),
        ("status", "shotrate",      "Fastest each gun has fired"),
        ("status", "firefn",        "Fastest each gun has fired - counted past 10 a second"),
        ("status", "autofire",      "The mod pulling the trigger for you"),
        ("button", "refill",       "Refill Everything Now"),
        ("button", "headlamp",     "Toggle Headlamp"),
        ("button", "nightvision",  "Toggle Night Vision"),
        ("toggle", "NoAccidentalLamp", "No Accidental Lamp/NVG  (stop your hand flipping them)"),
        ("button", "lamptest",     "Test Lamp Lock"),
        ("heading", "",            "Touch beside your head"),
        ("note",   "",             "The game's own switches are volumes on your CHEST, which is what "
                                   "your hand keeps brushing. These are beside your HEAD instead - "
                                   "reach up with either hand, left side for one and right for the "
                                   "other, somewhere a hand only goes on purpose."),
        ("toggle", "HeadTouch",    "Touch beside your head to switch them"),
        ("choice", "HeadTouchLeft",  "Left side of your head"),
        ("choice", "HeadTouchRight", "Right side of your head"),
        ("slider", "HeadTouchRange", "How close your hand has to get"),
        ("status", "headtouch",    "Your hands"),
    ]),
    ("Aim", [
        ("note",   "",                "VR cannot move your hand, so the GUN is aimed for you. A moment "
                                      "before it builds the shot, the gun's own fire direction is turned "
                                      "onto the body part you pick and put straight again right after, so "
                                      "the game runs its own trace, its own headshot and its own gore. "
                                      "Nothing about the hit is faked."),
        ("heading", "",               "Silent Aim"),
        ("toggle", "SilentAim",       "Silent Aim  (every shot hits the target)"),
        ("choice", "AimBone",         "Aim at"),
        ("choice", "AimPriority",     "Pick which enemy"),
        ("slider", "SilentFov",       "Aim field - how far from where you point it looks for a target"),
        ("toggle", "AimThroughWalls", "Shoot through walls"),
        ("toggle", "AimSticky",       "Stay on one target until it dies"),
        ("slider", "AimHitChance",    "Hit chance - lower looks more natural"),
        ("status", "aimtarget",       "Target"),
        ("heading", "",               "Aim Assist  -  the gentle version"),
        ("toggle", "AimAssist",       "Aim Assist  (only nudges shots that were already close)"),
        ("slider", "AimFov",          "Assist cone - how far off target you can be"),
        ("slider", "AimStrength",     "Strength - how much of the way each shot is bent"),
        ("heading", "",               "Both"),
        ("slider", "AimRange",        "Max range"),
        ("toggle", "AimShotgun",      "Shotgun pellets follow too"),
        ("toggle", "NoSpread",        "Perfect Accuracy  (bullets ignore spread)"),
        ("toggle", "AimKeepShotgunSpread", "...but shotguns keep their spread"),
        ("toggle", "AimForceDamage",  "Extra damage on every aimed shot  (lands even if the bullet misses)"),
        ("slider", "AimForceAmount",  "Extra damage per shot"),
        ("toggle", "AimImpactFx",     "Silent Aim hits make the bullet-into-body sound  (the game's own, where the shot lands - no blood spray: spawning it crashed the game)"),
        ("status", "impact",          "Hit sounds played on Silent Aim kills"),
        ("toggle", "AimOneShot",      "One-shot kills  (aimed shots kill instantly)"),
        ("toggle", "AimShowTarget",   "Show the target in the headset ESP"),
        ("status", "aim",             "Status"),
    ]),
    ("Aim Cone", [
        ("note",   "",                "The cone is the patch of the world your shots are allowed to be "
                                      "pulled into. This page shows what is in it RIGHT NOW, before you "
                                      "pull the trigger, and can draw the line your bullet will take "
                                      "straight out of the muzzle."),
        ("status", "aimcone",         "What the cone is holding"),
        ("toggle", "AimCone",         "Live cone read-out  (in the headset and here)"),
        ("toggle", "AimConeMark",     "Mark the locked enemy  (his body box changes colour)"),
        ("choice", "AimConeColor",    "Mark colour"),
        ("slider", "SilentFov",       "Silent Aim cone"),
        ("slider", "AimFov",          "Aim Assist cone"),
        ("slider", "AimRange",        "Max range"),
        ("heading", "",               "The beam"),
        ("toggle", "AimBeam",         "Show the beam  (a line out of the muzzle, green when locked on)"),
        ("choice", "AimBeamColor",    "Beam colour"),
        ("toggle", "AimBeamRGB",      "RGB beam  (cycles the rainbow - overrides the colour above)"),
        ("toggle", "AimBeamLaser",    "LASER SIGHT  (thin, always straight down the barrel - never swings onto a target)"),
        ("status", "beamnow",         "Lining up which gun"),
        ("slider", "AimBeamPitch",    "Line the beam up: UP / DOWN  (degrees)"),
        ("slider", "AimBeamYaw",      "Line the beam up: LEFT / RIGHT  (degrees)"),
        ("button", "beamauto",        "LINE THIS GUN UP AUTOMATICALLY  (matches the beam to where its bullets go)"),
        ("button", "beamsave",        "KEEP THIS ALIGNMENT FOR THIS GUN"),
        ("button", "beamreset",       "Forget this gun's alignment"),
        ("status", "beamalign",       "Alignments you have saved"),
        ("note",   "",                "Hold a gun and press LINE THIS GUN UP AUTOMATICALLY - it points the beam where that gun's bullets actually go, and remembers it for that gun. The sliders are there if you want to nudge it by eye afterwards; press KEEP to save those. Each gun keeps its own, so your other loadout guns are unaffected."),
        ("slider", "AimBeamLength",   "Beam length"),
        ("slider", "AimBeamSize",     "Beam size  (how thick it draws)"),
        ("toggle", "AimBeamWalls",    "Draw the beam over walls"),
        ("toggle", "AimBeamTrack",    "Beam points at whoever the cone has  (it cannot move your "
                                      "shots - the sight is not what they are built from - so this "
                                      "is purely 'show me who is picked')"),
        ("button", "espshot",         "Take a screenshot of what the headset sees  (to check the beam)"),
        ("heading", "",               "Which end of the shot is aimed"),
        ("note",   "",                "Aiming the GUN is what makes the shots move. Aiming the bullet on "
                                      "its own was measured doing nothing - 253 shots rewritten and "
                                      "verified, and not one of them went anywhere new - so it is kept "
                                      "only as a harmless second layer. Leave both on."),
        ("note",   "",                "Three goes at physically bending a shot have each been "
                                      "measured and each come up short. Turning the gun does move "
                                      "the shot, but only part of the way, and it means pushing a "
                                      "rotation under the grip on a live physics object a hundred "
                                      "times a minute - the session that did it stopped dead after "
                                      "four minutes. So this is what Silent Aim runs on now: the "
                                      "shot is measured, and if it was not going to hit the enemy "
                                      "it was sent at, that enemy takes it anyway, through the "
                                      "game's own damage. A shot you had already lined up yourself "
                                      "is left alone, so nothing is ever hurt twice."),
        ("toggle", "AimMakeItHit",    "MAKE SURE IT HITS  (this is the one)"),
        ("slider", "AimForceAmount",  "Damage per shot"),
        ("toggle", "AimGun",          "Bend the shot  (experiment - it now turns the BULLET; it no longer touches the gun in your hand)"),
        ("toggle", "AimBullet",       "Also aim the bullet"),
        ("status", "aimgun",          "Gun aim"),
        ("status", "shotwhy",         "Where the shots went"),
        ("status", "gamethread",      "Game thread"),
        ("status", "map",             "Map you are in"),
        ("status", "prevsession",     "Last session ended"),
        ("status", "build",           "Mod build running in the game"),
    ]),
    ("Opt GPU", [
        ("note",   "",                "Rendering at less than full resolution and having something "
                                      "clever put the pixels back is the biggest single thing you "
                                      "can do for frame rate in VR. DLSS and FSR are plugins a game "
                                      "has to be built with, and Blood Trail was not - picking them "
                                      "costs nothing and does nothing. Built-in is part of Unreal "
                                      "itself, works on any graphics card, and is the one to use."),
        ("status", "gpu",             "Your graphics card"),
        ("choice", "OptUpscaler",     "Upscaler"),
        ("choice", "OptUpscaleQuality", "Upscaler quality"),
        ("slider", "OptSharpen",      "Sharpen  (upscaling softens the picture)"),
        ("heading", "",               "VR wins"),
        ("toggle", "OptNoSpectator",  "Stop drawing the desktop mirror  (biggest easy win - but "
                                      "YOUR MONITOR GOES BLACK OR FROZEN, and screenshots stop.  "
                                      "The headset is not affected)"),
        ("toggle", "OptFramePacing",  "Smoother frame pacing  (helps judder more than average fps)"),
        ("toggle", "OptRoundRobin",   "One eye's occlusion queries per frame"),
        ("heading", "",               "Effects, one at a time"),
        ("slider", "OptShadowDist",   "Shadow distance"),
        ("slider", "OptCSMRes",       "Shadow sharpness"),
        ("slider", "OptAnisotropy",   "Texture sharpness at an angle"),
        ("slider", "OptSSR",          "Reflections"),
        ("slider", "OptAO",           "Ambient shadow"),
        ("slider", "OptMotionBlur",   "Motion blur"),
        ("slider", "OptDoF",          "Depth of field"),
        ("slider", "OptParticleLOD",  "Fewer particles"),
        ("slider", "OptMipBias",      "Smaller textures"),
        ("button", "opt_apply",       "Apply Now"),
        ("danger", "opt_reset",       "Put Graphics Back To Normal"),
        ("status", "optfps",          "Frame rate"),
    ]),
    ("Opt System", [
        ("note",   "",                "None of this is the graphics card. Frame rate in a room with "
                                      "forty bodies on the floor is usually the collector taking a "
                                      "long pause, physics running on one core, or the texture "
                                      "streamer thrashing a small pool. Everything here is left "
                                      "alone until you touch it."),
        ("status", "optsystem",       "What is on"),
        ("heading", "",               "Stutter"),
        ("choice", "OptGcMode",       "Clean-up pauses  (Unreal stops the world to clear out dead "
                                      "objects - every pause costs the same, so fewer is smoother)"),
        ("heading", "",               "CPU"),
        ("choice", "OptPhysThreads",  "Physics threads  (this is what a pile of ragdolls costs)"),
        ("toggle", "OptFewerRagdolls", "Bodies settle sooner  (a ragdoll that has come to rest still "
                                       "costs a solve every frame until it sleeps)"),
        ("toggle", "OptAnimBudget",   "Cheaper animation for enemies you are not looking at"),
        ("heading", "",               "Memory"),
        ("toggle", "OptStreamBoost",  "Texture streamer boost  (fewer blurry-then-sharp pops)"),
        ("toggle", "OptTrimRam",      "Give memory back to Windows sooner"),
        ("slider", "OptRamMipBias",   "Keep textures smaller in memory"),
        ("heading", "",               "Sound and loading"),
        ("slider", "OptAudioVoices",  "Most sounds at once  (every shot and scream is a voice)"),
        ("toggle", "OptFastLoad",     "Loading on its own thread"),
        ("button", "opt_apply",       "Apply Now"),
        ("danger", "opt_reset",       "Put Graphics Back To Normal"),
        ("status", "optfps",          "Frame rate"),
    ]),
    ("Enemies", [
        ("toggle", "FreezeEnemies",   "Freeze All Enemies"),
        ("toggle", "StopEnemySpawns", "Stop Enemies Spawning"),
        ("danger", "killall",         "Delete All Enemies"),
        ("note",   "",                "Enemy ESP moved to its own ESP tab."),
    ]),
    ("ESP", [
        ("heading", "",               "Boxes on their bodies"),
        ("note",   "",                "Each enemy's own body outline is switched on, so the game itself "
                                      "draws it around them and it moves with them - walking, running or "
                                      "knocked flying."),
        ("toggle", "ESPBoxes",        "Body boxes  (on every enemy)"),
        ("note",   "",                "There is no through-walls switch, and there is not going to "
                                      "be one. The engine draws a box outline with the depth "
                                      "setting written in and never looks at what the box asks. "
                                      "Repainting the enemy in the menu's own see-through material "
                                      "did work - and the first session it ran, the game deadlocked "
                                      "mid-fight. Not worth it. The headset ESP text still draws "
                                      "over everything, because that is the component the game "
                                      "itself gives that material to."),
        ("toggle", "ESPHitboxes",     "Hitbox boxes  (head, neck, heart, lungs, legs - human NPCs)"),
        ("choice", "ESPBoxColor",     "Box colour"),
        ("toggle", "ESPRgb",          "RGB boxes  (cycles the rainbow - the cone's target keeps its own colour)"),
        ("button", "espshot",         "Take a screenshot of what the headset sees  (to check the boxes)"),
        ("status", "espplus",         "Boxes"),
        ("heading", "",               "Headset text"),
        ("toggle", "EnemyESP",        "Enemy ESP text  (shown in your headset)"),
        ("toggle", "ESPNames",        "Names  (Zombie / Cultist / NPC)"),
        ("toggle", "ESPHealth",       "Health bars"),
        ("toggle", "ESPDistance",     "Distance"),
        ("toggle", "ESPDirection",    "Direction  (arrow + clock position)"),
        ("toggle", "ESPHeight",       "Height  (+3m above you / -2m below)"),
        ("toggle", "ESPRadar",        "4-way radar  (how many ahead, left, right, behind)"),
        ("slider", "ESPMaxRange",     "Max range"),
        ("slider", "ESPMaxRows",      "Enemies listed"),
        ("button", "espreset",        "Restart ESP now  (or press END in game)"),
    ]),
    ("Movement", [
        ("toggle", "SuperSpeed",      "Super Speed"),
        ("slider", "SpeedMultiplier", "Speed multiplier"),
        ("toggle", "VirtualJump",     "Virtual Jump  (press A - the game has no jump of its own)"),
        ("button", "jumptest",        "Test Jump"),
        ("toggle", "HighJump",        "High Jump"),
        ("slider", "JumpMultiplier",  "Jump multiplier"),
        ("toggle", "TeleportBoost",   "Long Teleport"),
        ("toggle", "FlyMode",         "Fly  (you fly where you look; look level to hover)"),
        ("toggle", "NoClip",          "NoClip  (fly and pass through walls)"),
        ("slider", "FlySpeed",        "Fly speed"),
        ("toggle", "FlyNeedsStick",   "Stick throttles flying  (push to move, release to stop)"),
        ("slider", "FlyDeadzone",     "How level counts as level - bigger is easier to hover"),
        ("toggle", "CrouchDown",      "Crouch Down  (duck to reach the floor)"),
        ("slider", "CrouchHeight",    "Crouch height - lower is a deeper duck"),
        ("slider", "CrouchDrop",      "Crouch drop - how far the world rises around you"),
        ("toggle", "CrouchOnStick",   "Right stick click toggles crouch"),
    ]),
    ("World", [
        ("slider", "TimeScale",   "Game speed"),
        ("button", "timescale",   "Apply Game Speed"),
        ("preset", "0.2",         "Slow Motion"),
        ("preset", "1.0",         "Normal Speed"),
        ("toggle", "BrightWorld",  "Brighten The World  (works on any map)"),
        ("slider", "Brightness",   "Brightness"),
        ("toggle", "GoreForever", "Gore Never Disappears"),
        ("button", "unlock",      "Unlock All Chapters / Checkpoints"),
    ]),
    ("Optimizer", [
        ("status", "optfps",          "Performance"),
        ("toggle", "OptEnabled",      "Optimizer On  (nothing changes until this is ticked)"),
        ("presets", "OptPreset",      "Preset"),
        ("status", "optpreset",       "Active preset"),
        ("heading", "",               "Frame rate"),
        ("toggle", "OptAutoRes",      "Auto Resolution  (sharpness drops or rises to hold your FPS)"),
        ("slider", "OptTargetFps",    "Target FPS - match your headset: 72, 80, 90 or 120"),
        ("status", "opt",             "Auto resolution"),
        ("slider", "OptFpsCap",       "FPS cap"),
        ("heading", "",               "Effects"),
        ("toggle", "OptNoFog",        "No volumetric fog"),
        ("toggle", "OptNoLensFlares", "No lens flares"),
        ("toggle", "OptNoLightShafts", "No light shafts"),
        ("toggle", "OptNoBloom",      "No bloom"),
        ("heading", "",               "Gore cleanup  -  the big win in long waves"),
        ("toggle", "OptCorpseCleanup", "Clean up corpses"),
        ("slider", "OptCorpseSeconds", "...after"),
        ("toggle", "OptBloodCleanup", "Clean up blood"),
        ("slider", "OptBloodSeconds", "...after"),
        ("toggle", "OptFastDecalFade", "Blood decals fade out faster"),
        ("heading", "",               "Gunshot impacts"),
        ("toggle", "OptNoImpactFX",   "Lighter gunshot impacts  (the game's own switch - your shots hit the way enemy shots already do)"),
        ("status", "impactfx",        "Your gunshot impacts"),
        ("toggle", "OptFreezeBodies", "Freeze dead bodies  (stops their physics)"),
        ("note",   "",                "Gore Never Disappears (World tab) wins over cleanup while it is on."),
        ("heading", "",               "Stutter"),
        ("toggle", "OptSmoothGC",     "Fewer hitches  (memory clean-up every 2 minutes, not every 1)"),
        ("toggle", "OptSmoothStreaming", "Smoother level streaming  (Raid maps load in gentler)"),
        ("heading", "",               "Custom settings  -  on top of the preset"),
        ("toggle", "OptCustom",       "Use the custom settings below"),
        ("slider", "OptResolution",   "Resolution"),
        ("slider", "OptPixelDensity", "VR pixel density  (headset sharpness)"),
        ("slider", "OptShadows",      "Shadows"),
        ("slider", "OptViewDistance", "View distance"),
        ("slider", "OptFoliage",      "Foliage"),
        ("slider", "OptEffects",      "Effects"),
        ("slider", "OptPostProcess",  "Post processing"),
        ("slider", "OptTextures",     "Textures"),
        ("slider", "OptTexturePool",  "Texture memory"),
        ("slider", "OptEnemyDetail",  "Enemy detail  (drop a level for big waves)"),
        ("button", "opt_apply",       "Re-Apply Now"),
        ("danger", "opt_reset",       "Reset To The Game's Own Settings"),
    ]),
    ("Music", None),
    ("Saves", None),
    ("Settings", [
        ("button", "calibptr",      "CALIBRATE LASER  (point at the VR panel first, then click)"),
        ("button", "fixaudio",      "FIX AUDIO  (restore the game's volume multipliers)"),
        ("slider", "MasterVolume",  "Master volume - pushed into all four game volumes"),
        ("slider", "PanelSize",     "VR panel size - bigger reads as closer"),
        ("slider", "PanelLift",     "VR panel height trim - lines up or down"),
        ("slider", "PointerPitch",  "Laser aim pitch - tilt the ray off the grip axis"),
        ("toggle", "AimFromWidget", "Use the game's own pointing ray  (exact - recommended)"),
        ("toggle", "AimFromSocket", "Aim from the hand rig  (fallback - off; heavy)"),
        ("toggle", "TouchPointer", "Touch mode  (reach out and touch the panel - no aiming)"),
        ("slider", "TouchRange",   "Touch reach - how close your hand must be"),
        ("toggle", "TwoPointers",   "Two pointers  (a laser from both hands)"),
        ("toggle", "PanelOnTop",    "Panel draws over the world  (through walls)"),
        ("toggle", "PanelGlow",     "Panel glows in the dark  (readable whatever the lighting; it then draws over your hands)"),
        ("toggle", "PanelDepthFix", "Panel hides behind hands and walls  (only while the glow above is off)"),
        ("toggle", "PanelSolidBg",  "Panel solid background  (experimental stencil)"),
    ]),
]


class ModMenuApp:
    def __init__(self, root):
        self.root = root
        self.seq = int(time.time()) % 100000
        self.vars = {}
        self.toggle_widgets = {}
        self.catalogue = self.load_catalogue()
        self.maps = self.load_json(MAPLIST, {})

        # Which toggles work on which player character. Loaded from a generated
        # file rather than waiting for the game to report it, so the window is
        # correct the moment it opens even with Blood Trail closed.
        self.caps = self.load_json(PAWNCAPS, {})
        self.pawn = self.load_last_pawn()
        self.applied_pawn = None

        self.status_labels = []          # (status key, Label, caption)
        self.preset_buttons = []
        self.music = MusicPlayer()
        self._music_seq = None
        self._polls = 0
        # Automatic pushes (music heartbeat, song changes) are only allowed once
        # the game is connected AND its values have been echoed into this
        # window. Pushing earlier would write this window's DEFAULTS over what
        # the player set in VR - and with the game closed it would overwrite the
        # control.txt that carries settings over to the next launch.
        self._connected = False
        # the in-game folder picker: where it is looking, and what is there
        self.browse_dir = ""
        self.browse_dirs, self.browse_songs = [], 0
        self.music_recent = []
        # started from the game: minimised, and gone again after the game
        self.from_game = FROM_GAME
        self._started_at = time.time()
        self._seen_game_at = None
        # asking Windows whether the game is still there is exact, but it
        # shells out - so it is rate limited and the answer is cached
        self._proc_checked_at = 0.0
        self._proc_seen = True
        # When a human last changed something here (never a heartbeat). Sent as
        # app_edit: the game lets control.txt override its saved settings at
        # start only when this is newer than the save.
        self._last_edit = 0
        # ask Windows what the graphics card is, off the UI thread so the
        # window opens instantly whatever PowerShell decides to do
        threading.Thread(target=detect_gpu, daemon=True).start()
        self.profile_labels = {}

        root.title(WINDOW_TITLE)
        root.configure(bg=BG)
        # Tall enough for the Optimizer tab, but never taller than the screen:
        # at 150% display scaling a fixed 760 ran off the bottom and hid the
        # status bar. The sidebar scrolls-free list needs ~600.
        height = max(560, min(760, root.winfo_screenheight() - 90))
        root.geometry("860x%d" % height)
        root.minsize(700, 520)
        root.protocol("WM_DELETE_WINDOW", self.on_close)

        self.build_style()
        self.build_header()
        # Footer before tabs: pack hands out space in packing order, and the
        # tab area expands to fill whatever is left. Packed after it, the status
        # bar was squeezed off the bottom on a 150%-scaled display.
        self.build_footer()
        self.build_tabs()

        # Open showing YOUR settings, not this window's defaults: with the game
        # closed, the first click here writes every value to control.txt, and
        # defaults there would be what the game starts with.
        self.load_saved_into_window()

        if self.from_game:
            # you are in the headset: stay out of the way on the desktop
            root.after(300, root.iconify)
        self.poll_status()

    # ---------------------------------------------------------------- data
    def load_json(self, path, fallback):
        try:
            with open(path, "r", encoding="utf-8") as fh:
                return json.load(fh)
        except Exception as exc:
            print("could not read %s: %s" % (os.path.basename(path), exc))
            return fallback

    def load_catalogue(self):
        return self.load_json(SPAWNLIST, {})

    def load_last_pawn(self):
        """Which character was seen last time the game ran.

        Defaults to Wendigo: that is the pawn Blood Trail actually spawns in
        normal play, and it self-corrects the moment the game reports otherwise.
        """
        try:
            with open(LASTPAWN, "r", encoding="utf-8") as fh:
                v = fh.read().strip()
                if v:
                    return v
        except Exception:
            pass
        return "Wendigo"

    def save_last_pawn(self, pawn):
        try:
            with open(LASTPAWN, "w", encoding="utf-8") as fh:
                fh.write(pawn)
        except Exception:
            pass

    def apply_caps(self):
        """Grey out toggles that cannot do anything on the current character."""
        if self.applied_pawn == self.pawn:
            return
        self.applied_pawn = self.pawn

        changed = False
        for key, (cb, label) in self.toggle_widgets.items():
            works_on = self.caps.get(key)
            if works_on is None or self.pawn in works_on:
                cb.config(state="normal", fg=FG, text="  " + label)
            else:
                # Also switch it off. Leaving a ticked-but-disabled box reads as
                # "this is on", and it would keep going out in control.txt.
                if self.vars[key].get():
                    self.vars[key].set(False)
                    changed = True
                who = " or ".join(works_on) if works_on else "no character"
                cb.config(state="disabled", disabledforeground=MUTED,
                          text="  %s   - %s character only" % (label, who))

        # Only while the game is connected. This runs on the very first poll,
        # before anything has been echoed, so pushing here wrote this window's
        # DEFAULTS over control.txt - the settings you left in VR - every time
        # the app opened with the game closed.
        if changed and self._connected:
            self.push_state()

    # --------------------------------------------------------------- style
    def build_style(self):
        s = ttk.Style()
        try:
            s.theme_use("clam")
        except tk.TclError:
            pass
        s.configure("TNotebook", background=BG, borderwidth=0)
        s.configure("TNotebook.Tab", background=PANEL, foreground=MUTED,
                    padding=(16, 8), borderwidth=0)
        s.map("TNotebook.Tab",
              background=[("selected", BG)], foreground=[("selected", ACCENT)])
        s.configure("TFrame", background=BG)
        s.configure("TCombobox", fieldbackground=PANEL, background=PANEL)

    # -------------------------------------------------------------- header
    def build_header(self):
        bar = tk.Frame(self.root, bg=PANEL)
        bar.pack(fill="x")
        tk.Label(bar, text="BLOOD TRAIL  ·  MOD MENU", bg=PANEL, fg=FG,
                 font=("Segoe UI", 13, "bold")).pack(side="left", padx=14, pady=10)
        self.conn = tk.Label(bar, text="checking...", bg=PANEL, fg=MUTED,
                             font=("Segoe UI", 9))
        self.conn.pack(side="right", padx=14)

    # ---------------------------------------------------------------- tabs
    def scrollable_page(self, nb, name):
        """A tab whose contents scroll, and return the frame to fill.

        Tabs used to be a plain Frame, so a tab with more rows than the window
        is tall simply lost the bottom ones off the edge - no scrollbar, no
        clue they were there. Combat hit that twice.

        Tkinter has no scrollable frame, so it is a Canvas with a Frame inside
        it: the canvas scrolls, the frame holds the widgets.
        """
        outer = tk.Frame(nb, bg=BG)
        nb.add(outer, text=name)

        canvas = tk.Canvas(outer, bg=BG, highlightthickness=0, bd=0)
        bar = ttk.Scrollbar(outer, orient="vertical", command=canvas.yview)
        inner = tk.Frame(canvas, bg=BG)

        window = canvas.create_window((0, 0), window=inner, anchor="nw")
        canvas.configure(yscrollcommand=bar.set)
        canvas.pack(side="left", fill="both", expand=True)
        bar.pack(side="right", fill="y")

        def on_inner_resize(_event):
            canvas.configure(scrollregion=canvas.bbox("all"))

        def on_canvas_resize(event):
            # keep the content the full width of the canvas, so sliders stretch
            canvas.itemconfigure(window, width=event.width)

        inner.bind("<Configure>", on_inner_resize)
        canvas.bind("<Configure>", on_canvas_resize)

        # Wheel events only reach the widget under the pointer, and every row is
        # its own widget, so bind on enter/leave for the whole page rather than
        # to the canvas alone - otherwise the wheel does nothing over a label.
        def wheel(event):
            if canvas.winfo_exists():
                canvas.yview_scroll(-1 * (event.delta // 120), "units")

        def bind_wheel(_e):
            canvas.bind_all("<MouseWheel>", wheel)

        def unbind_wheel(_e):
            canvas.unbind_all("<MouseWheel>")

        outer.bind("<Enter>", bind_wheel)
        outer.bind("<Leave>", unbind_wheel)
        return inner

    # Sidebar groups: tab name -> heading shown above it
    TAB_GROUPS = {"Player": "Cheats", "Aim": "Combat help",
                  "Movement": "World", "Optimizer": "Tools", "Spawn": "Spawning"}

    def build_tabs(self):
        nb = SideTabs(self.root)
        nb.pack(fill="both", expand=True, padx=0, pady=0)

        for name, rows in TABS:
            if name in self.TAB_GROUPS:
                nb.heading(self.TAB_GROUPS[name])
            if rows is None and name == "Music":
                self.build_music_tab(nb)
                continue
            if rows is None and name == "Saves":
                self.build_saves_tab(nb)
                continue
            frame = self.scrollable_page(nb, name)
            for kind, key, label in rows:
                self.add_row(frame, kind, key, label)

        nb.heading(self.TAB_GROUPS["Spawn"])
        self.build_spawn_tab(nb)
        self.build_maps_tab(nb)

    def add_row(self, parent, kind, key, label):
        if kind == "heading":
            tk.Label(parent, text=label.upper(), bg=BG, fg=HEADING,
                     font=("Segoe UI", 8, "bold"), anchor="w").pack(
                         fill="x", padx=18, pady=(14, 2))
            return
        if kind == "note":
            tk.Label(parent, text=label, bg=BG, fg=MUTED, font=("Segoe UI", 9),
                     anchor="w", justify="left", wraplength=560).pack(
                         fill="x", padx=18, pady=(4, 6))
            return
        if kind == "status":
            row = tk.Frame(parent, bg=PANEL)
            row.pack(fill="x", padx=16, pady=4)
            tk.Label(row, text=label, bg=PANEL, fg=MUTED, font=("Segoe UI", 9),
                     width=16, anchor="w").pack(side="left", padx=(10, 4), pady=6)
            val = tk.Label(row, text="game not running", bg=PANEL, fg=FG,
                           font=("Consolas", 9), anchor="w", justify="left",
                           wraplength=460)
            val.pack(side="left", fill="x", expand=True, pady=6)
            self.status_labels.append((key, val, label))
            return
        if kind == "presets":
            var = self.vars.get(key) or tk.DoubleVar(value=SETTINGS[key][0])
            self.vars[key] = var
            tk.Label(parent, text=label, bg=BG, fg=MUTED, font=("Segoe UI", 9),
                     anchor="w").pack(fill="x", padx=26, pady=(6, 2))
            row = tk.Frame(parent, bg=BG)
            row.pack(fill="x", padx=16, pady=(0, 6))
            names = ["Game", "Quality", "Balanced", "Performance", "Potato"]
            for i, name in enumerate(names, start=1):
                def pick(n=i):
                    var.set(float(n))
                    # choosing a preset is a clear "turn it on"
                    if "OptEnabled" in self.vars:
                        self.vars["OptEnabled"].set(True)
                        self.note_local_change("OptEnabled")
                    self.note_local_change(key)
                    self.refresh_presets()
                    self.push_state()
                b = tk.Button(row, text=name, command=pick, bg=PANEL, fg=FG,
                              activebackground=ACCENT, activeforeground=BG,
                              relief="flat", font=("Segoe UI", 9, "bold"),
                              padx=6, pady=6, cursor="hand2")
                b.pack(side="left", fill="x", expand=True, padx=2)
                self.preset_buttons.append((i, b))
            var.trace_add("write", lambda *_a: self.refresh_presets())
            self.refresh_presets()
            return
        if kind == "choice":
            names = CHOICES[key]
            var = self.vars.get(key) or tk.DoubleVar(value=SETTINGS[key][0])
            self.vars[key] = var
            row = tk.Frame(parent, bg=BG)
            row.pack(fill="x", padx=26, pady=(4, 8))
            tk.Label(row, text=label, bg=BG, fg=MUTED, font=("Segoe UI", 9),
                     anchor="w", width=18).pack(side="left")
            box = ttk.Combobox(row, values=names, state="readonly",
                               font=("Segoe UI", 10))
            box.pack(side="left", fill="x", expand=True)

            def show(*_a, var=var, box=box, names=names):
                try:
                    i = int(round(float(var.get())))
                except (tk.TclError, ValueError):
                    return
                i = max(0, min(len(names) - 1, i))
                if box.current() != i:
                    box.current(i)

            def picked(_e, key=key, var=var, box=box):
                var.set(float(box.current()))
                self.note_local_change(key)
                self.push_state()

            box.bind("<<ComboboxSelected>>", picked)
            var.trace_add("write", show)
            show()
            return

        if kind == "toggle":
            default = SETTINGS[key][0]
            # one variable per setting, even when a toggle appears on two tabs
            var = self.vars.get(key) or tk.BooleanVar(value=default)
            self.vars[key] = var
            cb = tk.Checkbutton(
                parent, text="  " + label, variable=var,
                command=(lambda k=key: self.on_toggle(k)),
                bg=BG, fg=FG, selectcolor=PANEL, activebackground=BG,
                activeforeground=ACCENT, font=("Segoe UI", 11),
                anchor="w", padx=8, pady=6, borderwidth=0, highlightthickness=0)
            cb.pack(fill="x", padx=10, pady=1)
            # remembered so poll_status can grey it out when the live pawn does
            # not support it
            self.toggle_widgets[key] = (cb, label)

        elif kind == "slider":
            _, _, lo, hi, step = SETTINGS[key]
            row = tk.Frame(parent, bg=BG)
            row.pack(fill="x", padx=26, pady=(2, 8))
            cap = tk.Label(row, text=label, bg=BG, fg=MUTED,
                           font=("Segoe UI", 9), anchor="w")
            cap.pack(side="top", fill="x")

            var = self.vars.get(key) or tk.DoubleVar(value=SETTINGS[key][0])
            self.vars[key] = var
            # multipliers read "2.5x"; HP and indices read whole; a fire rate
            # of 0.06 s needs two decimals or it rounds away to "0.1"
            if key in SLIDER_FMT:
                fmt = SLIDER_FMT[key]
            elif key == "MeleeKnockback":
                fmt = lambda v: f"{v:.0f}x"
            elif key in ("MeleeDamage", "FistDamage"):
                fmt = lambda v: f"{v:.0f} dmg"
            elif key in ("GrabRange",):
                fmt = lambda v: f"{v:.0f} cm"
            elif key == "ThrowForce":
                fmt = lambda v: f"{v:.0f} force"
            elif key == "Brightness":
                fmt = lambda v: f"{v:.2f}x"
            elif key == "FlySpeed":
                fmt = lambda v: f"{v:.0f} cm/s"
            elif key == "FlyDeadzone":
                fmt = lambda v: f"{v:.2f}"
            elif key == "MeleeReach":
                fmt = lambda v: f"{v:.0f} cm"
            elif key == "FistLaunchForce":
                fmt = lambda v: f"{v:.0f} force"
            elif key in ("FistStrikePower", "MeleeWeightClass"):
                fmt = lambda v: f"{v:.0f}"
            elif hi > 100 or key.endswith("Index"):
                fmt = lambda v: f"{v:.0f}"
            elif step < 0.05:
                fmt = lambda v: f"{v:.2f}s"
            else:
                fmt = lambda v: f"{v:.1f}x"
            val = tk.Label(row, text=fmt(var.get()), bg=BG, fg=ACCENT,
                           font=("Segoe UI", 10, "bold"), width=7)
            val.pack(side="right")

            def on_move(v, key=key, val=val, fmt=fmt):
                stepped = round(float(v) / SETTINGS[key][4]) * SETTINGS[key][4]
                self.vars[key].set(stepped)
                val.config(text=fmt(stepped))
                self.note_local_change(key)
                self.push_state()

            sc = tk.Scale(row, from_=lo, to=hi, resolution=step,
                          orient="horizontal", variable=var, command=on_move,
                          bg=BG, fg=FG, troughcolor=PANEL, highlightthickness=0,
                          showvalue=False, sliderrelief="flat", borderwidth=0)
            sc.pack(side="left", fill="x", expand=True)

            def on_var(*_a, var=var, val=val, fmt=fmt):
                try:
                    val.config(text=fmt(float(var.get())))
                except (tk.TclError, ValueError):
                    pass
            var.trace_add("write", on_var)

        elif kind in ("button", "danger", "preset"):
            colour = DANGER if kind == "danger" else ACCENT
            if kind == "preset":
                cmd = lambda k=key: self.send("timescale", k)
            else:
                cmd = lambda k=key: self.send(k, "")
            b = tk.Button(parent, text=label, command=cmd,
                          bg=PANEL, fg=colour, activebackground=colour,
                          activeforeground=BG, font=("Segoe UI", 10, "bold"),
                          relief="flat", padx=10, pady=8, cursor="hand2")
            b.pack(fill="x", padx=16, pady=4)

    # --------------------------------------------------------------- music
    def refresh_presets(self):
        var = self.vars.get("OptPreset")
        if var is None:
            return
        try:
            cur = int(round(float(var.get())))
        except (tk.TclError, ValueError):
            return
        for i, b in self.preset_buttons:
            if i == cur:
                b.config(bg=ACCENT, fg=BG)
            else:
                b.config(bg=PANEL, fg=FG)

    def load_music_prefs(self):
        prefs = self.load_json(MUSIC_JSON, {})
        folder = prefs.get("folder") or ""
        # A remembered folder that is gone (a drive unplugged, a renamed folder)
        # would leave an empty playlist; fall back to the default playlist.
        if not folder or not os.path.isdir(folder):
            folder = default_music_folder()
        recent = prefs.get("recent") or []
        self.music_recent = [f for f in recent if isinstance(f, str)][:8]
        # ...and the files Windows could not play last time, so the first
        # track change of the session does not walk into them all again.
        # WHOSE OPINION IS THIS? The remembered list says "these files
        # would not open" - but that was the OLD engine's opinion, and it
        # refused two thirds of this library for no good reason. Restoring it
        # under the new engine would keep skipping songs that now play
        # perfectly, so a list left by a different engine is thrown away.
        bad = prefs.get("unplayable") or []
        self._remembered_bad = set(f for f in bad if isinstance(f, str))
        self._remembered_bad_by = prefs.get("unplayable_engine") or ""
        self.music.device = prefs.get("device") or ""
        return folder, prefs.get("track", "")

    def save_music_prefs(self):
        i = self.music.current_index()
        track = self.music.tracks[i] if i is not None and i < len(self.music.tracks) else ""
        try:
            # WHICH FILES THIS ENGINE CANNOT PLAY, AND WHICH ENGINE SAID SO.
            #
            # The stamp is the important half. The old MCI player wrote down
            # two thirds of this library as unplayable - wrongly: measured
            # against the real 706 tracks, Media Foundation plays 706 of 706.
            # A list is only ever handed back to the engine that wrote it, so
            # the old player's opinion cannot outlive the old player.
            with open(MUSIC_JSON, "w", encoding="utf-8") as fh:
                json.dump({"folder": self.music.folder, "track": track,
                           "recent": self.music_recent,
                           "unplayable": sorted(self.music._unplayable)[:4000],
                           "unplayable_engine": self.music.engine_kind(),
                           "device": getattr(self.music, "device", "")},
                          fh, indent=1)
        except Exception:
            pass

    def remember_folder(self, folder):
        if not folder:
            return
        norm = os.path.normcase(os.path.normpath(folder))
        self.music_recent = [f for f in self.music_recent
                             if os.path.normcase(os.path.normpath(f)) != norm]
        self.music_recent.insert(0, folder)
        del self.music_recent[8:]
        box = getattr(self, "music_recent_box", None)
        if box is not None:
            box.config(values=self.music_recent)

    def refresh_browse(self):
        self.browse_dirs, self.browse_songs = scan_folder(self.browse_dir)

    def handle_music_command(self, cmd):
        """A button pressed on the in-game MUSIC tab."""
        raw = (cmd or "").strip()
        low = raw.lower()
        if low in ("toggle", "next", "prev", "stop"):
            self.music.command(low)
            return
        if low == "browse_here":
            here = self.music.folder
            self.browse_dir = here if here and os.path.isdir(here) else default_music_folder()
        elif low == "folder_up":
            if self.browse_dir:
                cur = os.path.normpath(self.browse_dir)
                parent = os.path.dirname(cur)
                # the parent of D:\ is D:\ itself: go up to the list of drives
                self.browse_dir = "" if parent == cur else parent
        elif low.startswith("folder_into:"):
            try:
                i = int(low.split(":", 1)[1])
            except ValueError:
                return
            if 0 <= i < len(self.browse_dirs):
                name = self.browse_dirs[i]
                self.browse_dir = name if not self.browse_dir else os.path.join(self.browse_dir, name)
        elif low == "folder_use":
            if self.browse_dir and os.path.isdir(self.browse_dir):
                self.set_music_folder(self.browse_dir)
        elif low.startswith("folder_preset:"):
            try:
                i = int(low.split(":", 1)[1])
            except ValueError:
                return
            if 0 <= i < len(MUSIC_PRESETS) and os.path.isdir(MUSIC_PRESETS[i][1]):
                self.browse_dir = MUSIC_PRESETS[i][1]
                self.set_music_folder(self.browse_dir)
        else:
            return
        self.refresh_browse()

    def build_music_tab(self, nb):
        frame = tk.Frame(nb, bg=BG)
        nb.add(frame, text="Music")
        m = self.music

        top = tk.Frame(frame, bg=PANEL)
        top.pack(fill="x", padx=12, pady=(12, 6))
        self.music_title = tk.Label(top, text="Nothing playing", bg=PANEL, fg=FG,
                                    font=("Segoe UI", 13, "bold"), anchor="w")
        self.music_title.pack(fill="x", padx=12, pady=(10, 0))
        self.music_time = tk.Label(top, text="", bg=PANEL, fg=MUTED,
                                   font=("Consolas", 9), anchor="w", justify="left",
                                   wraplength=600)
        self.music_time.pack(fill="x", padx=12, pady=(0, 10))

        bar = tk.Frame(frame, bg=BG)
        bar.pack(fill="x", padx=12, pady=4)

        def act(fn):
            def run():
                fn()
                self.after_music_change()
            return run

        for text, fn in (("\u23ee  Prev", m.prev), ("\u23ef  Play / Pause", m.toggle),
                         ("\u23ed  Next", m.next), ("\u23f9  Stop", m.stop)):
            tk.Button(bar, text=text, command=act(fn), bg=PANEL, fg=ACCENT,
                      activebackground=ACCENT, activeforeground=BG, relief="flat",
                      font=("Segoe UI", 10, "bold"), padx=10, pady=8,
                      cursor="hand2").pack(side="left", fill="x", expand=True, padx=2)

        folder_row = tk.Frame(frame, bg=BG)
        folder_row.pack(fill="x", padx=12, pady=(8, 2))
        # Buttons are packed BEFORE the label on purpose: pack hands out space
        # in packing order, and a long folder path packed first pushed both
        # buttons clean off the right edge of the window.
        tk.Button(folder_row, text="Rescan", command=self.rescan_music, bg=PANEL,
                  fg=FG, relief="flat", font=("Segoe UI", 9), padx=10,
                  cursor="hand2").pack(side="right", padx=(4, 0))
        tk.Button(folder_row, text="Choose Folder...", command=self.choose_music_folder,
                  bg=PANEL, fg=ACCENT, relief="flat", font=("Segoe UI", 9, "bold"),
                  padx=10, cursor="hand2").pack(side="right")
        self.music_folder_label = tk.Label(folder_row, text="", bg=BG, fg=MUTED,
                                           font=("Segoe UI", 9), anchor="w")
        self.music_folder_label.pack(side="left", fill="x", expand=True)

        # one-click folders, and the ones used before
        quick = tk.Frame(frame, bg=BG)
        quick.pack(fill="x", padx=12, pady=(2, 2))
        tk.Label(quick, text="Quick:", bg=BG, fg=MUTED, font=("Segoe UI", 9)).pack(side="left")
        for name, path in MUSIC_PRESETS:
            if os.path.isdir(path):
                tk.Button(quick, text=name, bg=PANEL, fg=FG, relief="flat",
                          font=("Segoe UI", 9), padx=8, cursor="hand2",
                          command=lambda p=path: self.set_music_folder(p)).pack(side="left", padx=2)
        tk.Label(quick, text="   Recent:", bg=BG, fg=MUTED, font=("Segoe UI", 9)).pack(side="left")
        self.music_recent_box = ttk.Combobox(quick, values=self.music_recent, state="readonly",
                                             font=("Segoe UI", 9))
        self.music_recent_box.pack(side="left", fill="x", expand=True, padx=(4, 0))

        def use_recent(_e):
            v = self.music_recent_box.get()
            if v and os.path.isdir(v):
                self.set_music_folder(v)
        self.music_recent_box.bind("<<ComboboxSelected>>", use_recent)

        # WHERE IT COMES OUT. The music is rendered straight to the output
        # you pick here; nothing else on the machine moves, so the game can
        # stay on one device and your music on another.
        out_row = tk.Frame(frame, bg=BG)
        out_row.pack(fill="x", padx=0, pady=(6, 0))
        tk.Label(out_row, text="Play sound through:", bg=BG, fg=MUTED,
                 font=("Segoe UI", 9)).pack(side="left")
        self.music_device_box = ttk.Combobox(out_row, values=["Windows default"],
                                             state="readonly", font=("Segoe UI", 9))
        self.music_device_box.set("Windows default")
        self.music_device_box.pack(side="left", fill="x", expand=True, padx=(4, 0))
        self.music_device_box.bind("<<ComboboxSelected>>",
                                   lambda _e: self.choose_music_device())
        self.music_device_note = tk.Label(frame, text="", bg=BG, fg=MUTED,
                                          font=("Segoe UI", 8), anchor="w")
        self.music_device_note.pack(fill="x", padx=12, pady=(0, 4))

        opts = tk.Frame(frame, bg=BG)
        opts.pack(fill="x", padx=0, pady=(4, 0))
        self.add_row(opts, "toggle", "MusicAutoStart",
                     "The in-game MUSIC tab starts this player by itself")
        self.add_row(opts, "slider", "MyMusicVolume", "Volume")
        self.add_row(opts, "toggle", "MyMusicShuffle", "Shuffle")
        self.add_row(opts, "toggle", "MyMusicRepeat", "Repeat the playlist")
        self.add_row(opts, "toggle", "MusicDuckGame",
                     "Turn the game's own soundtrack down while my music plays")
        self.add_row(opts, "slider", "MusicDuckLevel", "Game soundtrack level while playing")

        listwrap = tk.Frame(frame, bg=BG)
        listwrap.pack(fill="both", expand=True, padx=12, pady=(6, 4))
        sb = tk.Scrollbar(listwrap)
        sb.pack(side="right", fill="y")
        self.music_list = tk.Listbox(listwrap, bg=PANEL, fg=FG, selectbackground=ACCENT,
                                     selectforeground=BG, relief="flat",
                                     font=("Segoe UI", 10), yscrollcommand=sb.set,
                                     activestyle="none")
        self.music_list.pack(fill="both", expand=True)
        sb.config(command=self.music_list.yview)
        self.music_list.bind("<Double-Button-1>", lambda e: self.play_selected_song())

        tk.Label(frame, text="Double-click a song to play it. In VR, the MUSIC tab "
                             "controls this player, and opens it for you if it is closed.",
                 bg=BG, fg=MUTED, font=("Segoe UI", 8), anchor="w").pack(
                     fill="x", padx=12, pady=(0, 10))

        # the settings drive the player, whether moved here or from VR
        def on_volume(*_a):
            try:
                m.volume = float(self.vars["MyMusicVolume"].get())
                m.apply_volume()
            except (tk.TclError, ValueError):
                pass

        def on_shuffle(*_a):
            m.set_shuffle(bool(self.vars["MyMusicShuffle"].get()))

        def on_repeat(*_a):
            m.repeat = bool(self.vars["MyMusicRepeat"].get())

        self.vars["MyMusicVolume"].trace_add("write", on_volume)
        self.vars["MyMusicShuffle"].trace_add("write", on_shuffle)
        self.vars["MyMusicRepeat"].trace_add("write", on_repeat)
        on_volume()
        on_shuffle()
        on_repeat()

        folder, track = self.load_music_prefs()
        self.set_music_folder(folder, remember_track=track)

    def set_music_folder(self, folder, remember_track=""):
        self.music.load_folder(folder)
        # Hand back what THIS ENGINE refused last time, and nobody else's
        # list. load_folder starts from a clean slate on purpose - a file that
        # gets fixed should get another chance - but a genuinely broken file
        # should not have to be discovered again at every launch.
        remembered = getattr(self, "_remembered_bad", None)
        if remembered and getattr(self, "_remembered_bad_by", "") == self.music.ensure_engine().kind:
            here = set(self.music.tracks)
            self.music._unplayable = set(p for p in remembered if p in here)
        if folder and os.path.isdir(folder):
            self.remember_folder(folder)
        # the headset's picker starts from wherever the music now is
        self.browse_dir = folder if folder and os.path.isdir(folder) else ""
        self.refresh_browse()
        if remember_track and remember_track in self.music.tracks:
            ti = self.music.tracks.index(remember_track)
            if ti in self.music.order:
                self.music.pos = self.music.order.index(ti)
        shown = folder if len(folder or "") <= 48 else "..." + folder[-45:]
        # Say how many Windows cannot play, rather than letting them look like
        # songs that simply never come on.
        skipped = len(self.music._unplayable)
        label = "%s   (%d songs)" % (shown, len(self.music.tracks))
        if skipped:
            label += "   -  %d Windows cannot play" % skipped
        self.music_folder_label.config(text=label if folder else "no folder")
        self.music_list.delete(0, tk.END)
        for p in self.music.tracks:
            self.music_list.insert(tk.END, os.path.splitext(os.path.basename(p))[0])
        self.after_music_change()

    def refresh_music_devices(self):
        """Fill the picker once the player has told us what Windows has."""
        box = getattr(self, "music_device_box", None)
        if box is None:
            return
        devices = self.music.list_devices()
        if not devices:
            note = getattr(self, "music_device_note", None)
            if note is not None:
                note.config(text="This machine would not let the player choose an "
                                 "output, so it uses the Windows default.")
            return
        self._device_names = ["Windows default"]
        self._device_ids = [""]
        for dev_id, name, is_default in devices:
            self._device_names.append(name + ("   (Windows default)" if is_default else ""))
            self._device_ids.append(dev_id)
        box.config(values=self._device_names)
        want = getattr(self.music, "device", "") or ""
        if want in self._device_ids:
            box.set(self._device_names[self._device_ids.index(want)])
        elif box.get() not in self._device_names:
            box.set(self._device_names[0])
        note = getattr(self, "music_device_note", None)
        if note is not None:
            if self.music.can_choose_device():
                note.config(text="%d outputs. Only the music moves - the game stays "
                                 "where it is." % len(devices))
            else:
                note.config(text="This machine would not let the player choose an "
                                 "output, so it uses the Windows default.")

    def choose_music_device(self):
        box = getattr(self, "music_device_box", None)
        ids = getattr(self, "_device_ids", None)
        names = getattr(self, "_device_names", None)
        if box is None or not ids or not names:
            return
        pick = box.get()
        if pick not in names:
            return
        self.music.set_device(ids[names.index(pick)])
        self.save_music_prefs()
        note = getattr(self, "music_device_note", None)
        if note is not None:
            note.config(text="Music now plays through: %s" % pick)

    def choose_music_folder(self):
        start = self.music.folder if os.path.isdir(self.music.folder) else os.path.expanduser("~")
        folder = filedialog.askdirectory(initialdir=start, title="Choose your music folder")
        if folder:
            self.set_music_folder(os.path.normpath(folder))

    def rescan_music(self):
        i = self.music.current_index()
        cur = self.music.tracks[i] if i is not None else ""
        self.set_music_folder(self.music.folder, remember_track=cur)

    def play_selected_song(self):
        sel = self.music_list.curselection()
        if sel:
            self.music.play_track(sel[0])
            self.after_music_change()

    def after_music_change(self):
        self.update_music_view()
        self.save_music_prefs()
        if self._connected:
            self.push_state()

    def update_music_view(self):
        m = self.music
        if not hasattr(self, "music_title"):
            return
        title = m.title()
        state = m.state()
        self.music_title.config(text=title if title else "Nothing playing",
                                fg=ACCENT if state == "playing" else FG)
        pos, length = m.position_ms() // 1000, m.length_ms() // 1000
        text = "%s   %d:%02d / %d:%02d" % (state.upper(), pos // 60, pos % 60,
                                           length // 60, length % 60)
        if m.tracks:
            text += "   track %d of %d" % (m.pos + 1, len(m.tracks))
        if m.error:
            text += "   -  " + m.error
        self.music_time.config(text=text)
        i = m.current_index()
        if i is not None and i < self.music_list.size():
            cur = self.music_list.curselection()
            if not cur or cur[0] != i:
                self.music_list.selection_clear(0, tk.END)
                self.music_list.selection_set(i)
                self.music_list.see(i)

    def on_close(self):
        try:
            self.save_music_prefs()
            self.music.close()
            # The player now runs in its own process. Closing the window has
            # to take it with us, or it keeps the audio device and the song
            # plays on with nothing left to stop it.
            self.music.shutdown()
        finally:
            self.root.destroy()

    # --------------------------------------------------------------- saves
    def build_saves_tab(self, nb):
        frame = tk.Frame(nb, bg=BG)
        nb.add(frame, text="Saves")

        tk.Label(frame, text="Your settings save by themselves and come back the next time you play.",
                 bg=BG, fg=FG, font=("Segoe UI", 11, "bold"), anchor="w",
                 wraplength=600, justify="left").pack(fill="x", padx=18, pady=(14, 2))
        self.save_status = tk.Label(frame, text="", bg=PANEL, fg=ACCENT, font=("Segoe UI", 10),
                                    anchor="w", justify="left", wraplength=600)
        self.save_status.pack(fill="x", padx=16, pady=(6, 8), ipady=6, ipadx=8)
        self._save_note_until = 0

        self.add_row(frame, "toggle", "SaveAuto", "Auto-save my settings  (whenever anything changes)")
        self.add_row(frame, "toggle", "SaveLoadOnStart", "Load them when the game starts")

        def button(parent, text, cmd, colour=ACCENT):
            return tk.Button(parent, text=text, command=cmd, bg=PANEL, fg=colour,
                             activebackground=colour, activeforeground=BG, relief="flat",
                             font=("Segoe UI", 10, "bold"), padx=10, pady=7, cursor="hand2")

        row = tk.Frame(frame, bg=BG)
        row.pack(fill="x", padx=14, pady=(6, 2))
        button(row, "Save Now", lambda: self.saves_do("save")).pack(side="left", fill="x", expand=True, padx=2)
        button(row, "Load My Saved Settings", lambda: self.saves_do("load")).pack(side="left", fill="x", expand=True, padx=2)
        self.saved_label = tk.Label(frame, text="", bg=BG, fg=MUTED, font=("Segoe UI", 9), anchor="w")
        self.saved_label.pack(fill="x", padx=18, pady=(0, 6))

        tk.Label(frame, text="PROFILES  -  set-ups you can swap between", bg=BG, fg=HEADING,
                 font=("Segoe UI", 8, "bold"), anchor="w").pack(fill="x", padx=18, pady=(12, 2))
        for n in range(1, SAVE_PROFILES + 1):
            prow = tk.Frame(frame, bg=PANEL)
            prow.pack(fill="x", padx=16, pady=3)
            tk.Label(prow, text="Profile %d" % n, bg=PANEL, fg=FG, font=("Segoe UI", 10, "bold"),
                     width=9, anchor="w").pack(side="left", padx=(10, 4), pady=6)
            when = tk.Label(prow, text="empty", bg=PANEL, fg=MUTED, font=("Segoe UI", 9), anchor="w")
            when.pack(side="left", fill="x", expand=True)
            self.profile_labels[n] = when
            button(prow, "Load", lambda n=n: self.saves_do("load_profile", n)).pack(side="right", padx=(2, 6))
            button(prow, "Save here", lambda n=n: self.saves_do("save_profile", n)).pack(side="right", padx=2)

        tk.Label(frame, text="START OVER", bg=BG, fg=HEADING, font=("Segoe UI", 8, "bold"),
                 anchor="w").pack(fill="x", padx=18, pady=(14, 2))
        button(frame, "Reset every setting to default", lambda: self.saves_do("reset"),
               colour=DANGER).pack(fill="x", padx=16, pady=4)
        tk.Label(frame, text="In VR the same controls are on the SAVES tab.", bg=BG, fg=MUTED,
                 font=("Segoe UI", 8), anchor="w").pack(fill="x", padx=18, pady=(6, 10))
        self.refresh_save_labels()

    @staticmethod
    def _save_value(var, spec):
        if spec[1] == "bool":
            return "1" if var.get() else "0"
        v = float(var.get())
        return "%d" % v if v == int(v) else ("%.6g" % v)

    def values_for_save(self, path):
        """What goes in a save written here: the window's values, on top of
        whatever the file already holds - the mod saves a few settings this
        window has no control for, and those must survive."""
        values = {k: v for k, v in read_saved(path).items() if k not in SAVE_META}
        for key, spec in SETTINGS.items():
            var = self.vars.get(key)
            if var is not None and key not in SAVE_SKIP:
                values[key] = self._save_value(var, spec)
        return values

    def apply_saved(self, kv, mark):
        """Put saved values into the window. `mark` = this was a human action,
        so it counts as an edit and is pushed to the game."""
        n = 0
        for key, raw in kv.items():
            var = self.vars.get(key)
            if var is None or key in SAVE_SKIP or key not in SETTINGS:
                continue
            try:
                if SETTINGS[key][1] == "bool":
                    var.set(raw.strip().lower() in ("1", "true"))
                else:
                    var.set(float(raw))
            except (ValueError, tk.TclError):
                continue
            n += 1
            if mark:
                self.note_local_change(key)
        if mark and n:
            self.push_state()
        return n

    def load_saved_into_window(self):
        kv = read_saved(SAVED_SETTINGS)
        source = "your saved settings"
        if not kv:
            kv = import_last_session(STATUS)
            source = "your last session"
        n = self.apply_saved(kv, mark=False) if kv else 0
        self._startup_note = ("Opened with %s (%d settings)." % (source, n)) if n else \
                             "Nothing saved yet - it saves by itself once you play."
        if hasattr(self, "save_status"):
            self.save_status.config(text=self._startup_note)

    def save_note(self, text):
        self.save_status.config(text=text)
        self._save_note_until = time.time() + 6

    def saves_do(self, what, n=None):
        if what == "reset" and not messagebox.askyesno(
                "Reset everything?", "Put EVERY Mod Menu setting back to its default?"):
            return
        if self._connected:
            # the game owns the save while it runs - ask the mod to do it
            action = {"save": "save_now", "load": "load_saved", "save_profile": "save_profile",
                      "load_profile": "load_profile", "reset": "reset_defaults"}[what]
            self.send(action, "" if n is None else str(n))
            self.save_note({"save": "Saved.", "load": "Loaded your saved settings.",
                            "save_profile": "Saved to profile %s." % n,
                            "load_profile": "Loaded profile %s." % n,
                            "reset": "Everything is back to default."}[what])
            self.root.after(2500, self.refresh_save_labels)
            return

        # the game is closed: work on the files, so the game starts with it
        try:
            if what == "save":
                write_saved(SAVED_SETTINGS, self.values_for_save(SAVED_SETTINGS), "saved from the desktop app")
                self.save_note("Saved. The game will start with these.")
            elif what == "save_profile":
                write_saved(profile_path(n), self.values_for_save(profile_path(n)), "profile %d" % n)
                self.save_note("Saved to profile %d." % n)
            elif what in ("load", "load_profile"):
                path = SAVED_SETTINGS if what == "load" else profile_path(n)
                kv = read_saved(path)
                if not kv:
                    self.save_note("Nothing saved there yet." if what == "load" else
                                   "Profile %d is empty - save to it first." % n)
                else:
                    count = self.apply_saved(kv, mark=True)
                    if what == "load_profile":
                        # becomes the settings the game starts with next time
                        write_saved(SAVED_SETTINGS, {k: v for k, v in kv.items() if k not in SAVE_META},
                                    "profile %d loaded in the desktop app" % n)
                    self.save_note("Loaded %d settings%s." % (count, "" if what == "load" else " from profile %d" % n))
            elif what == "reset":
                for key, spec in SETTINGS.items():
                    var = self.vars.get(key)
                    if var is not None and key not in SAVE_SKIP:
                        var.set(spec[0] if spec[1] == "bool" else float(spec[0]))
                        self.note_local_change(key)
                self.push_state()
                # only this window's settings in the file: the mod's own extras
                # go back to their defaults too, by being absent
                write_saved(SAVED_SETTINGS, {k: self._save_value(self.vars[k], s)
                                             for k, s in SETTINGS.items()
                                             if k in self.vars and k not in SAVE_SKIP},
                            "reset from the desktop app")
                self.save_note("Everything is back to default.")
        except OSError as exc:
            self.save_note("Could not write the save: %s" % exc)
        self.refresh_save_labels()

    def refresh_save_labels(self):
        def when(path):
            t = read_saved(path).get("saved")
            try:
                return "saved " + time.strftime("%d %b  %H:%M", time.localtime(int(t)))
            except (TypeError, ValueError, OSError):
                return "empty"
        if hasattr(self, "saved_label"):
            text = when(SAVED_SETTINGS)
            self.saved_label.config(text="Your settings: " + ("not saved yet" if text == "empty" else text))
        for n, label in self.profile_labels.items():
            label.config(text=when(profile_path(n)))

    # --------------------------------------------------------------- spawn
    def build_spawn_tab(self, nb):
        frame = tk.Frame(nb, bg=BG)
        nb.add(frame, text="Spawn")

        top = tk.Frame(frame, bg=BG)
        top.pack(fill="x", padx=12, pady=(10, 4))

        tk.Label(top, text="Category", bg=BG, fg=MUTED,
                 font=("Segoe UI", 9)).pack(anchor="w")
        cats = ["(search everything)"] + list(self.catalogue.keys())
        self.cat_var = tk.StringVar(value=cats[1] if len(cats) > 1 else cats[0])
        cat = ttk.Combobox(top, values=cats, textvariable=self.cat_var,
                           state="readonly")
        cat.pack(fill="x", pady=(2, 8))
        cat.bind("<<ComboboxSelected>>", lambda e: self.refresh_list())

        tk.Label(top, text="Search", bg=BG, fg=MUTED,
                 font=("Segoe UI", 9)).pack(anchor="w")
        self.search_var = tk.StringVar()
        ent = tk.Entry(top, textvariable=self.search_var, bg=PANEL, fg=FG,
                       insertbackground=FG, relief="flat", font=("Segoe UI", 10))
        ent.pack(fill="x", ipady=5, pady=(2, 6))
        self.search_var.trace_add("write", lambda *a: self.refresh_list())

        opts = tk.Frame(top, bg=BG)
        opts.pack(fill="x")
        self.show_engine = tk.BooleanVar(value=False)
        tk.Checkbutton(
            opts, text=" also show engine objects (spawn nothing visible)",
            variable=self.show_engine, command=self.refresh_list,
            bg=BG, fg=MUTED, selectcolor=PANEL, activebackground=BG,
            activeforeground=FG, font=("Segoe UI", 8), borderwidth=0,
            highlightthickness=0).pack(side="left")
        self.count_label = tk.Label(opts, text="", bg=BG, fg=MUTED,
                                    font=("Segoe UI", 8))
        self.count_label.pack(side="right")

        listwrap = tk.Frame(frame, bg=BG)
        listwrap.pack(fill="both", expand=True, padx=12)
        sb = tk.Scrollbar(listwrap)
        sb.pack(side="right", fill="y")
        self.listbox = tk.Listbox(
            listwrap, bg=PANEL, fg=FG, selectbackground=ACCENT,
            selectforeground=BG, relief="flat", font=("Consolas", 10),
            yscrollcommand=sb.set, activestyle="none")
        self.listbox.pack(fill="both", expand=True)
        sb.config(command=self.listbox.yview)
        self.listbox.bind("<Double-Button-1>", lambda e: self.spawn_selected())

        bottom = tk.Frame(frame, bg=BG)
        bottom.pack(fill="x", padx=12, pady=10)

        tk.Label(bottom, text="How many", bg=BG, fg=MUTED,
                 font=("Segoe UI", 9)).pack(side="left")
        self.count_var = tk.IntVar(value=1)
        tk.Spinbox(bottom, from_=1, to=25, width=4, textvariable=self.count_var,
                   bg=PANEL, fg=FG, relief="flat", buttonbackground=PANEL,
                   font=("Segoe UI", 10)).pack(side="left", padx=(6, 12))

        tk.Button(bottom, text="Spawn Selected", command=self.spawn_selected,
                  bg=ACCENT, fg=BG, activebackground=FG, relief="flat",
                  font=("Segoe UI", 10, "bold"), padx=14, pady=7,
                  cursor="hand2").pack(side="left")

        tk.Button(frame, text="Spawn One Of Everything In This Category",
                  command=self.spawn_category, bg=PANEL, fg=ACCENT,
                  activebackground=ACCENT, activeforeground=BG, relief="flat",
                  font=("Segoe UI", 10, "bold"), pady=8,
                  cursor="hand2").pack(fill="x", padx=12, pady=(0, 12))

        self.refresh_list()

    def visible_entries(self):
        """(display, class) pairs matching the current category + search box."""
        needle = self.search_var.get().strip().lower()
        cat = self.cat_var.get()

        # A real category searches within itself; "(search everything)" searches
        # the whole catalogue. Predictable either way.
        if cat.startswith("("):
            pool = [e for items in self.catalogue.values() for e in items]
        else:
            pool = self.catalogue.get(cat, [])

        # entry = [display, class, spawnable]
        # Engine classes spawn an empty actor with no mesh or behaviour, so they
        # are out of the way unless explicitly asked for.
        if not self.show_engine.get():
            pool = [e for e in pool if e[2]]

        if needle:
            pool = [e for e in pool
                    if needle in e[0].lower() or needle in e[1].lower()]
        return pool

    def refresh_list(self):
        self.entries = self.visible_entries()
        self.listbox.delete(0, tk.END)
        for i, entry in enumerate(self.entries):
            display, cls, ok = entry[0], entry[1], entry[2]
            suffix = "" if ok else "   (engine object - spawns nothing)"
            self.listbox.insert(tk.END, f"{display:<34} {cls}{suffix}")
            if not ok:
                self.listbox.itemconfig(i, foreground=MUTED)
        if self.entries:
            self.listbox.selection_set(0)
        self.count_label.config(
            text="%d spawnable" % sum(1 for e in self.entries if e[2]))

    def spawn_selected(self):
        sel = self.listbox.curselection()
        if not sel:
            return
        entry = self.entries[sel[0]]
        if not entry[2]:
            self.count_label.config(
                text="%s is an engine object - nothing would appear" % entry[0])
            return
        self.send("spawnmany", f"{entry[1]}|{int(self.count_var.get())}")

    def spawn_category(self):
        cat = self.cat_var.get()
        names = list(self.catalogue.keys())
        if cat in names:
            self.send("spawncat", str(names.index(cat) + 1))

    # ---------------------------------------------------------------- maps
    def build_maps_tab(self, nb):
        frame = tk.Frame(nb, bg=BG)
        nb.add(frame, text="Maps")

        tk.Label(frame, text="Travel straight to any map - Raid, Arena, Sandbox "
                             "or Beta.", bg=BG, fg=MUTED,
                 font=("Segoe UI", 9), anchor="w",
                 wraplength=560, justify="left").pack(fill="x", padx=12, pady=(10, 2))
        tk.Label(frame, text="The game loads it immediately, so only do this when "
                             "you are ready to leave the current round.",
                 bg=BG, fg=DANGER, font=("Segoe UI", 8), anchor="w",
                 wraplength=560, justify="left").pack(fill="x", padx=12, pady=(0, 8))

        listwrap = tk.Frame(frame, bg=BG)
        listwrap.pack(fill="both", expand=True, padx=12)
        sb = tk.Scrollbar(listwrap)
        sb.pack(side="right", fill="y")
        self.maplist = tk.Listbox(
            listwrap, bg=PANEL, fg=FG, selectbackground=ACCENT,
            selectforeground=BG, relief="flat", font=("Consolas", 10),
            yscrollcommand=sb.set, activestyle="none")
        self.maplist.pack(fill="both", expand=True)
        sb.config(command=self.maplist.yview)
        self.maplist.bind("<Double-Button-1>", lambda e: self.load_map())

        self.map_entries = []
        for group, items in self.maps.items():
            # group headers are unselectable markers, hence the None path
            self.map_entries.append((f"--- {group} ---", None))
            for name, path in items:
                self.map_entries.append((f"   {name}", path))
        for i, (label, path) in enumerate(self.map_entries):
            self.maplist.insert(tk.END, label)
            if path is None:
                self.maplist.itemconfig(i, foreground=MUTED)

        tk.Button(frame, text="Load Selected Map", command=self.load_map,
                  bg=ACCENT, fg=BG, activebackground=FG, relief="flat",
                  font=("Segoe UI", 10, "bold"), pady=8,
                  cursor="hand2").pack(fill="x", padx=12, pady=10)

    def load_map(self):
        sel = self.maplist.curselection()
        if not sel:
            return
        label, path = self.map_entries[sel[0]]
        if path is None:      # a group header
            return
        self.send("loadmap", path)

    # -------------------------------------------------------------- footer
    def build_footer(self):
        bar = tk.Frame(self.root, bg=PANEL)
        bar.pack(fill="x", side="bottom")
        self.stats = tk.Label(bar, text="", bg=PANEL, fg=MUTED,
                              font=("Consolas", 9), anchor="w")
        self.stats.pack(fill="x", padx=14, pady=8)

    # ----------------------------------------------------------------- I/O
    def note_local_change(self, key):
        """Remember that the human just moved this control, so poll_status
        leaves it alone briefly instead of echoing over the top of them."""
        d = getattr(self, "_local_change", None)
        if d is None:
            d = {}
            self._local_change = d
        d[key] = time.time()
        self._last_edit = time.time()

    def on_toggle(self, key):
        """A checkbox was clicked by the human.

        For a mod-owned toggle the panel normally echoes whatever the mod
        reports, so that a controller press is not undone a second later. But a
        deliberate click here has to win - otherwise the checkbox does nothing
        at all. Mark it as ours for one push, then go back to following.
        """
        self.note_local_change(key)
        if key in MOD_OWNED:
            var = self.vars.get(key)
            if var is not None:
                state = getattr(self, "_mod_owned_state", None)
                if state is None:
                    state = {}
                    self._mod_owned_state = state
                state[key] = bool(var.get())
        self.push_state()

    def push_state(self):
        """Write every setting. The mod applies whatever keys it recognises."""
        lines = []
        for key, spec in SETTINGS.items():
            var = self.vars.get(key)
            if var is None:
                continue
            if key in MOD_OWNED:
                # The mod owns this while the game runs - it can be flipped from
                # the controller. Echo back what the mod last reported rather
                # than our own copy, or we stamp on the player's crouch a second
                # after they press it.
                live = getattr(self, "_mod_owned_state", {}).get(key)
                if live is not None:
                    lines.append(f"{key}={1 if live else 0}")
                    continue
            if spec[1] == "bool":
                lines.append(f"{key}={1 if var.get() else 0}")
            else:
                lines.append(f"{key}={float(var.get()):.3f}")
        lines.append(f"seq={self.seq}")
        lines.append(f"action={getattr(self, '_action', '')}")
        lines.append(f"arg={getattr(self, '_arg', '')}")

        # The music player's state, for the in-game MUSIC tab. app_hb is the
        # heartbeat: when it stops moving the headset shows "app not running".
        m = getattr(self, "music", None)
        if m is not None:
            lines.append(f"music_now={ascii_title(m.title())}")
            lines.append(f"music_state={m.state()}")
            lines.append(f"music_pos={m.position_ms() // 1000}")
            lines.append(f"music_len={m.length_ms() // 1000}")
            lines.append(f"music_count={len(m.tracks)}")
            lines.append(f"music_index={(m.pos + 1) if m.tracks else 0}")
            # the in-game folder picker. Names only for display: the headset
            # answers with an INDEX, so a name that had to be ASCII-folded
            # still opens the right folder.
            lines.append(f"music_folder={ascii_path(m.folder)}")
            lines.append(f"music_songs={len(m.tracks)}")
            browse = getattr(self, "browse_dir", "")
            lines.append("music_browse=%s" % (ascii_path(browse) if browse else "This PC - pick a drive"))
            lines.append(f"music_browse_songs={getattr(self, 'browse_songs', 0)}")
            dirs = getattr(self, "browse_dirs", [])
            lines.append(f"music_dircount={len(dirs)}")
            lines.append("music_dirs=" + "|".join(
                (ascii_title(n, 30) or "?") for n in dirs[:BROWSE_LIST_MAX]))
        lines.append(f"app_hb={int(time.time())}")
        lines.append(f"app_edit={int(getattr(self, '_last_edit', 0))}")
        # NOT an edit: the graphics card name is a fact about this PC, not a
        # setting, so it must never make the game think you changed something.
        if _GPU_NAME:
            lines.append("gpu=" + ascii_title(_GPU_NAME, 48))

        try:
            with open(CONTROL_TMP, "w", encoding="utf-8") as fh:
                fh.write("\n".join(lines) + "\n")
            os.replace(CONTROL_TMP, CONTROL)   # atomic on Windows
        except Exception as exc:
            self.conn.config(text=f"cannot write control.txt: {exc}", fg=DANGER)

    def send(self, action, arg):
        self.seq += 1
        self._action = action
        self._arg = arg
        self.push_state()
        self._action = ""
        self._arg = ""

    def poll_status(self):
        info = {}
        fresh = False
        try:
            age = time.time() - os.path.getmtime(STATUS)
            fresh = age < STALE_AFTER
            with open(STATUS, "r", encoding="utf-8") as fh:
                for line in fh:
                    if "=" in line:
                        k, v = line.strip().split("=", 1)
                        info[k] = v
        except Exception:
            pass

        # Toggles the player can flip from inside VR: take the mod's value as
        # the truth and move our own checkbox to match, so the panel shows what
        # is actually happening instead of fighting it.
        if fresh:
            # The mod is now the owner of its own state: control.txt is
            # edge-triggered, so it only lands when a value CHANGES here. That
            # makes echoing mandatory rather than cosmetic - if this panel shows
            # a stale value, the next click sends it, which is a change, and
            # silently undoes whatever the player just did in VR.
            #
            # Skip a key for a moment after the human touched it locally, so a
            # slider being dragged is not fought by an echo mid-drag.
            recent = getattr(self, "_local_change", {})
            now = time.time()
            for key, var in self.vars.items():
                raw = info.get("st_" + key.lower())
                if raw is None:
                    continue
                if now - recent.get(key, 0.0) < 1.5:
                    continue
                raw = raw.strip()
                try:
                    if isinstance(var, tk.BooleanVar):
                        live = raw.lower() in ("1", "true")
                        if bool(var.get()) != live:
                            var.set(live)
                    else:
                        live = float(raw)
                        if abs(float(var.get()) - live) > 1e-6:
                            var.set(live)
                except (ValueError, tk.TclError):
                    pass

        # The running game is the authority on which character is live; remember
        # it so the greying is still right next time with the game closed.
        if fresh:
            live = info.get("pawn", "")
            if live and live != "none" and live != self.pawn:
                self.pawn = live
                self.save_last_pawn(live)
        self.apply_caps()

        if fresh:
            self.conn.config(text="● connected to game", fg=ACCENT)
            # dmghooks is the God Mode health check: if it reads 0 the damage
            # hooks never bound and nothing can stop you dying.
            hooks = info.get("dmghooks", "?")
            blocked = info.get("godhits", "0")
            god = ("god:%s hooks, %s hits blocked" % (hooks, blocked)
                   if hooks not in ("0", "?") else "god: HOOKS NOT BOUND")
            self.stats.config(text=(
                f"pawn {info.get('pawn','?'):<9}"
                f"health {info.get('health','?')}/{info.get('healthmax','?'):<9}"
                f"enemies {info.get('enemies','?'):<5}"
                f"kills {info.get('kills','?'):<5}"
                f"{god}"))
        else:
            self.conn.config(text="○ game not running", fg=MUTED)
            self.stats.config(text=(
                "Playing as %s. Settings apply as soon as you start Blood Trail."
                % self.pawn))

        # ---- music: end-of-song, commands from the headset, heartbeat ----
        self.music.tick()
        # The outputs arrive from the player a moment after it starts, so the
        # picker is filled on the first poll that has them rather than at
        # build time, when there is nothing to put in it yet.
        if not getattr(self, "_devices_filled", False):
            eng = self.music.ensure_engine()
            # ...or it has told us it cannot offer any, which is an answer as
            # well and belongs on screen rather than as an empty box.
            if self.music.list_devices() or getattr(eng, "devices_ready", False):
                self._devices_filled = True
                self.refresh_music_devices()
        cmd_raw = info.get("musiccmd", "")
        if fresh and "|" in cmd_raw:
            seq_s, cmd = cmd_raw.split("|", 1)
            try:
                seq = int(seq_s)
            except ValueError:
                seq = None
            if seq is not None:
                if self._music_seq is None:
                    # first sighting: do not replay a press from before we opened
                    self._music_seq = seq
                elif seq != self._music_seq:
                    self._music_seq = seq
                    if cmd:
                        self.handle_music_command(cmd)
                        self.after_music_change()
        # set only AFTER this poll's echo, so the first push carries the
        # game's own values back, never this window's defaults
        self._connected = fresh
        self._polls += 1
        if self._polls % 4 == 0:
            # every 2 s: song position and heartbeat for the headset
            self.update_music_view()
            if self._connected:
                self.push_state()
            # the Saves tab: what the game says, and when each file was saved
            if hasattr(self, "save_status") and time.time() > self._save_note_until:
                if fresh and info.get("savenote"):
                    self.save_status.config(text=info["savenote"][:1].upper() + info["savenote"][1:] + ".")
                elif not fresh:
                    self.save_status.config(text=getattr(self, "_startup_note", "") +
                                            "  Game not running - Save and Load work on the files directly.")
            if self._polls % 8 == 0:
                self.refresh_save_labels()

        # ---- live readouts on the Aim / ESP / Optimizer tabs ----
        for key, label, caption in self.status_labels:
            label.config(text=self.format_status(key, info.get(key), fresh))

        # ---- opened by the game: close again once the game has gone ----
        if fresh:
            self._seen_game_at = time.time()
        if self.from_game and self.should_close_with_game(time.time()):
            self.on_close()
            return

        self.root.after(500, self.poll_status)

    def game_is_running(self, now):
        """Is the game actually still there?

        status.txt going stale is a SLOW signal - it is the same whether the
        game quit, crashed, or merely hitched. Asking Windows is exact, so the
        panel and its music stop within a couple of seconds of the game going
        instead of hanging about for a minute.

        ASKED WITHOUT STARTING A PROGRAM TO ASK (2026-09-21).

        This used to run `tasklist`, which is a whole process: measured on
        this machine at 289 ms a go, ON THE TK THREAD, every three seconds,
        for as long as the game was open. That is a third of a second of
        frozen window twenty times a minute, plus a process launch the whole
        machine pays for - and it was running at exactly the moment the
        machine could least afford it, which is while the game holds 90
        frames a second for the headset. "still lagging the game and the pc."

        EnumProcesses asks the kernel the same question directly: 5.7 ms, no
        process, 50x cheaper. The answers agree.
        """
        if now - self._proc_checked_at < 3.0:
            return self._proc_seen
        self._proc_checked_at = now
        try:
            self._proc_seen = _process_running("BTVR-Win64-Shipping.exe")
        except Exception:
            self._proc_seen = None
        if self._proc_seen is None:
            # If we cannot tell, assume it is there. Closing somebody's music
            # because a process lookup hiccupped is worse than waiting for the
            # timer.
            self._proc_seen = True
        return self._proc_seen

    def should_close_with_game(self, now):
        """True once a game-started window has outlived the game.

        The timers are the backstop. The real signal is the game process being
        gone - which is what "I ended and closed the game" actually looks
        like, and what a crash looks like too."""
        if self._seen_game_at is not None:
            if not self.game_is_running(now):
                return True
            return now - self._seen_game_at > 60
        return now - self._started_at > 180

    @staticmethod
    def _fields(raw):
        out = {}
        for part in (raw or "").split():
            if "=" in part:
                k, v = part.split("=", 1)
                out[k] = v
        return out

    def format_status(self, key, raw, fresh):
        if key == "gpu":
            return gpu_advice()
        if not fresh:
            return "game not running"
        if raw is None:
            return "waiting for the game..."
        if key == "aim":
            f = self._fields(raw)
            if f.get("bound") != "true":
                return "Waiting for a gun - switch Silent Aim on and fire once."

            def num(k):
                try:
                    return int(f.get(k, 0))
                except ValueError:
                    return 0
            text = "%d of your %d shots aimed at a target." % (num("aimed"), num("mine"))
            hit, miss = num("hit"), num("miss")
            if hit + miss > 0:
                text += "  Landed on target: %d of %d." % (hit, hit + miss)
            if num("writefail") > 0:
                text += "  %d re-aims were refused by the game." % num("writefail")
            if num("extra") > 0:
                text += "  Extra damage sent %d times." % num("extra")
            return text
        if key == "gunstate":
            # "the shotgun is still not automatic while holding the button."
            # Repeat fire is driven by the gun's FIRE MODE - it picks which
            # rate-of-fire timeline runs - not by the chamber flags. So this
            # says which gun the mod is looking at and what mode it is in,
            # because trying fire mode 0-3 is the one knob that decides it.
            f = self._fields(raw)
            if not f or "gun" not in f:
                return "No gun seen yet - pick one up."
            gun = gun_name(f.get("gun", "?"))
            mode = f.get("mode", "?")
            bits = ["%s, firing mode %s" % (gun, FIRE_MODES.get(mode, mode))]
            # NOT recipbolt: the AK has that set and runs perfectly well, so
            # warning about it would be telling you to fix the gun that works.
            if f.get("pump") == "true":
                bits.append("still set to be worked by hand - turn Full Auto ON")
            if f.get("canfire") == "false":
                bits.append("the game says it cannot fire right now")
            if FIRE_MODES.get(f.get("mode", "")) not in (None, "Auto"):
                bits.append("Full Auto should be putting this on Auto - if it "
                            "says Single, the setting is not reaching the gun")
            return ".  ".join(bits) + "."
        if key == "impactfx":
            raw = (raw or "").strip()
            if raw.startswith("light"):
                f = dict(p.split("=", 1) for p in raw.split() if "=" in p)
                n = f.get("guns", "0")
                if n == "0":
                    return ("Lighter - takes effect on the next shot from each "
                            "gun you pick up.")
                return ("Lighter - your shots hit the way enemy shots do "
                        "(%s gun%s switched)." % (n, "" if n == "1" else "s"))
            return "Full - the game's normal impact effects."
        if key == "impact":
            f = dict(p.split("=", 1) for p in (raw or "").split() if "=" in p)
            if not f:
                return raw
            # the hit SOUND only: the blood particle crashed the game
            n = f.get("snd", "0")
            if n == "0":
                if f.get("none", "0") != "0":
                    return ("Nothing to play - the game's hit sound is not "
                            "loaded yet.  status.txt says what is missing "
                            "(impacterr).")
                return ("None played yet - it plays the first time Silent Aim "
                        "lands a hit.")
            whose = ("your gun's own hit sound" if f.get("src") == "gun"
                     else "the game's own bullet-into-body sound")
            return "Played %s time%s - %s." % (n, "" if n == "1" else "s", whose)
        if key == "mirror":
            # A switched-off mirror and a frozen game look identical on the
            # monitor. This is the only thing that can tell them apart.
            if (raw or "").strip() == "off":
                return ("OFF - your monitor is not being drawn, which looks "
                        "exactly like the game is frozen.  The headset is "
                        "fine.  Untick 'Stop drawing the desktop mirror' on "
                        "the OPTIMIZER tab to get your screen back.")
            return "On - your monitor is showing the game."
        if key == "autofire":
            f = dict(p.split("=", 1) for p in (raw or "").split() if "=" in p)
            if not f:
                return raw
            try:
                r = float(f.get("rate", "0"))
            except ValueError:
                r = 0.0
            held = f.get("held", "?")
            if held == "off" or r <= 0:
                return ("Off - the gun is left to fire on its own.  If holding "
                        "the trigger only gives you one shot, switch Auto fire "
                        "on.")
            if held == "native":
                ak, read = f.get("akspeed"), f.get("akread")
                extra = ""
                if ak:
                    extra = " (AK at %sx its own speed" % ak
                    if read and read != "none":
                        extra += ", and its automatic reads %s" % read
                    extra += ")"
                return ("This gun runs on the game's own automatic, like the "
                        "AK%s - the shotgun's pace is its own slider." % extra)
            if held == "nogun":
                return "Ready at %g a second - pick a gun up." % r
            if held == "false":
                return ("Ready at %g a second, but the gun is not reporting "
                        "the trigger as held yet - pull it and hold it." % r)
            try:
                gap = float(f.get("gap", "0")) or (1.0 / r)
            except ValueError:
                gap = 1.0 / r
            bits = ["Firing for you: one shell every %.2f seconds (%g a "
                    "second)" % (gap, round(r, 1))]
            # the gun's own fire timer, which the mod starts for each hold
            fr = f.get("firerate")
            if fr and fr != "?":
                bits.append("the gun's own fire timer is running, one shell "
                            "every %s seconds" % fr)
            shots = f.get("shots")
            if shots not in (None, "0"):
                bits.append("%s shells from it so far" % shots)
            rs = f.get("restarts", "0")
            if rs != "0":
                bits.append("started again %s time%s after the gun went quiet"
                            % (rs, "" if rs == "1" else "s"))
            st = f.get("stops", "0")
            if st != "0":
                bits.append("stopped %s time%s when the gun left your hand or "
                            "Auto fire went off" % (st, "" if st == "1" else "s"))
            return ".  ".join(bits) + "."
        if key == "shotnow":
            try:
                n = int((raw or "0").strip())
            except ValueError:
                return raw
            if n <= 0:
                return "Not firing right now."
            return "Firing at %d a second right now." % n
        if key == "firefn":
            # the same question as shotrate below, without its 10-a-second
            # cap: every call of each fire function, so an AK at 15 a second
            # reads 15 and the AK speed slider can be seen working
            raw = (raw or "").strip()
            if not raw or raw == "none":
                return "Nothing fired yet - shoot something and check back."
            best = {}
            for part in raw.split():
                if ":" not in part or "." not in part:
                    continue
                key2, n = part.rsplit(":", 1)
                cls = key2.split(".", 1)[0]
                try:
                    n = int(n)
                except ValueError:
                    continue
                if n > best.get(cls, 0):
                    best[cls] = n
            if not best:
                return raw
            return ".  ".join("%s: up to %d a second" % (gun_name(c), n)
                              for c, n in sorted(best.items()))
        if key == "shotrate":
            # "the shotgun is still not automatic while holding the button" is
            # a question about a rate. This is the game's own answer, measured
            # while you played, so it does not have to be judged by ear.
            raw = (raw or "").strip()
            if not raw or raw == "none":
                return "Nothing fired yet - shoot something and check back."
            out = []
            for part in raw.split():
                if ":" not in part:
                    continue
                cls, n = part.rsplit(":", 1)
                try:
                    n = int(n)
                except ValueError:
                    continue
                if n >= 6:
                    verdict = "it kept firing while you held the trigger"
                elif n >= 3:
                    verdict = "fast, but not quite running on its own"
                else:
                    verdict = "one shot per pull"
                out.append("%s: %d a second - %s" % (gun_name(cls), n, verdict))
            return ".  ".join(out) if out else raw
        if key == "map":
            # The mod writes the level's own name once per map. maplist.json
            # already pairs those with the names you see in the menu, so say
            # the friendly one - "Beta Basement" rather than
            # Map_Beta_Basement.
            raw = (raw or "").strip()
            if not raw or raw == "unknown":
                return "Not in a level yet."
            for group, maps in (getattr(self, "maps", None) or {}).items():
                for pretty, path in maps:
                    if path.rsplit("/", 1)[-1].lower() == raw.lower():
                        return "%s  (%s)" % (pretty, group)
            return raw
        if key == "beamnow":
            cls = (raw or "").strip()
            if not cls or cls in ("none", "?"):
                return "No gun in your hand yet - pick one up."
            return ("%s.  Drag the two sliders until the beam runs along its "
                    "barrel, then press KEEP." % gun_name(cls))
        if key == "beamalign":
            raw = (raw or "").strip()
            if not raw or raw.startswith("none"):
                return "None saved yet."
            out = []
            for part in raw.split():
                if ":" not in part:
                    continue
                cls, nums = part.split(":", 1)
                out.append("%s (%s)" % (gun_name(cls), nums.replace("/", ", ")))
            return "Saved for: " + "; ".join(out) if out else raw
        if key == "beamcls":
            raw = (raw or "").strip()
            if not raw or raw == "none":
                return "No beam on any gun right now."
            return "Beam on: " + ", ".join(gun_name(c) for c in raw.split(","))
        if key == "norecoil":
            # WHY THIS ROW EXISTS. You played a whole session with No Recoil
            # switched on, got 25 kills, and the mod recorded recoilevents=0 -
            # the code that takes the kick away had never run once. Nothing on
            # screen said so, because the switch was on and the switch is all
            # anyone could see. This row answers the question the switch only
            # appears to answer.
            f = self._fields(raw)

            def num(k):
                try:
                    return int(f.get(k, 0))
                except ValueError:
                    return 0
            if num("hooks") == 0:
                return ("NOT on yet - the game has not let the mod listen for "
                        "the kick. It keeps asking, once a second. Pick up a "
                        "gun; if this never changes, tell me.")
            if num("events") == 0:
                return "Armed and listening. Fire a shot."
            if num("killed") == 0:
                return ("The kick happened %d times and this build would not "
                        "let it be flattened. Please tell me you saw this."
                        % num("events"))
            return ("Working - %d kicks taken away out of %d."
                    % (num("killed"), num("events")))
        if key == "aimgun":
            # The one line that answers "is Silent Aim working". follow= counts
            # bullets that came out along the line the gun was turned to.
            f = self._fields(raw)

            def num(k):
                try:
                    return int(f.get(k, 0))
                except ValueError:
                    return 0
            if f.get("bound") != "true":
                return "Waiting for a gun - pick one up and fire once."
            # The beam and the aim only touch a gun the game says is in your
            # hand - that is what stopped them reaching for a dead enemy's
            # gun. If this build will not report that, say so loudly rather
            # than letting the feature look merely idle.
            if num("noflag") > 0 and num("held") == 0:
                return ("I cannot tell which gun is yours on this build - the "
                        "aim and the beam are both off until that is sorted. "
                        "Please tell me you saw this.")
            if num("notheld") > 0 and num("mine") == 0:
                return ("%d shots were fired near you, none of them from a gun "
                        "in your hand." % num("notheld"))
            if num("aimed") == 0:
                if num("calls") == 0:
                    return "Ready. Fire a shot."
                if num("noarrow") > 0:
                    return ("Found your gun but not its fire direction "
                            "(%d times)." % num("noarrow"))
                return "%d shots seen, nothing was in the cone." % num("calls")
            # The gun is never turned now - it is a physics object held in a
            # grip, and shoving it threw it at whoever it was aimed at. The
            # bend writes the bullet's own muzzle rotation instead.
            if num("muzzleok") == 0 and num("muzzlefail") > 0:
                return ("The bullet will not take a new heading (%d tries). "
                        "Bend The Shot cannot work on this build - MAKE SURE "
                        "IT HITS still does." % num("muzzlefail"))
            follow, stray, made = num("follow"), num("stray"), num("madehit")
            text = "Aimed %d shots." % num("aimed")
            if follow + stray > 0:
                text += ("  %d of %d came out where they were sent."
                         % (follow, follow + stray))
                if num("ignored") > 0:
                    text += ("  %d went where you were already pointing."
                             % num("ignored"))
                elif stray > 0:
                    text += "  %d went elsewhere (%s deg off)." % (stray, f.get("straydeg", "?"))
            if made > 0:
                text += "  %d of those hit the target anyway." % made
            return text
        if key == "build":
            # After an update the first question is "did it take?".
            # This comes from the game, so it answers that directly.
            want = "2026-09-20"
            if not raw or raw in ("n/a", "unknown"):
                return "The game has not said - start it once."
            if raw.strip() == want:
                return "%s - this is the current build." % raw.strip()
            return ("%s - that is NOT the build that was just installed "
                    "(%s). The game may need restarting." % (raw.strip(), want))
        if key == "prevsession":
            # Carried over at boot, because a restart used to wipe it.
            # This is what was in flight when the LAST session stopped.
            if raw in ("unknown", "", None):
                return "Unknown."
            if raw.startswith("none"):
                return "No earlier session on record - this is a first run."
            f = self._fields(raw)
            op = f.get("lastop", "?")
            tick = f.get("tick", "?")
            return ("The session before this one stopped at tick %s, and the "
                    "last thing it asked the game to do was: %s." % (tick, op))
        if key == "optsystem":
            return raw
        if key == "gamethread":
            f = self._fields(raw)
            try:
                behind = int(f.get("behind", 0))
            except ValueError:
                behind = 0
            if behind > 8:
                return ("The game has stopped taking the mod's work (%d jobs "
                        "waiting, last one: %s). That is the game hanging, not "
                        "the mod." % (behind, f.get("lastop", "?")))
            try:
                dropped = int(f.get("dropped", 0))
            except ValueError:
                dropped = 0
            text = "Keeping up.  Last job: %s." % f.get("lastop", "none")
            # WHICH JOB IS MOST OF THE TRAFFIC.
            #
            # A freeze on 20 September had 1968 of 2247 jobs coming from one
            # feature, and nothing on screen said so - it took reading the raw
            # status file to notice. If one job is the overwhelming majority
            # again, that is the first thing worth knowing.
            jobs = f.get("jobs", "")
            if jobs and jobs != "none":
                counts = []
                for part in jobs.split(","):
                    if ":" in part:
                        nm, _, n = part.rpartition(":")
                        try:
                            counts.append((int(n), nm))
                        except ValueError:
                            pass
                if counts:
                    counts.sort(reverse=True)
                    top, name = counts[0]
                    total = sum(c for c, _ in counts)
                    if total > 200 and top > total * 0.75:
                        text += ("  %d%% of everything sent is '%s' (%d of %d) - "
                                 "if the game locks up, that is the one to suspect."
                                 % (round(100.0 * top / total), name, top, total))
            if dropped > 0:
                text += ("  %d jobs were thrown away because the map changed "
                         "underneath them - that is the crash guard doing its "
                         "job, not a fault." % dropped)
            return text
        if key == "shotwhy":
            f = self._fields(raw)

            def n(k):
                try:
                    return int(f.get(k, 0))
                except ValueError:
                    return 0
            if n("queued") == 0:
                return "Nothing sent yet - fire at an enemy."
            text = "%d shots made to hit, %d landed." % (n("queued"), n("landed"))
            lost = []
            if n("notlive"):
                lost.append("%d were already gone" % n("notlive"))
            if n("dead"):
                lost.append("%d were already dead" % n("dead"))
            if n("nodrop"):
                lost.append("%d would not take it" % n("nodrop"))
            if n("noclass"):
                lost.append("%d were a kind I cannot damage" % n("noclass"))
            if n("full"):
                lost.append("%d arrived too fast" % n("full"))
            if lost:
                text += "  Of the rest, " + ", ".join(lost) + "."
            return text
        if key == "aimcone":
            f = self._fields(raw)
            if f.get("on") != "true":
                return "Off."
            if f.get("locked") == "true":
                return ("Locked on %s, %s, %.1f m away."
                        % (f.get("name", "enemy").lower(), f.get("part", "?"),
                           float(f.get("dist", 0) or 0) / 100.0))
            seen = f.get("seen", "0")
            if seen in ("0", ""):
                return "Empty - no enemy in range."
            return "Empty - %s in range, none inside the %s degree cone." % (seen, f.get("fov", "?"))
        if key == "headtouch":
            f = self._fields(raw)
            if f.get("on") != "true":
                return "Off."
            # On, live, and wired to nothing. A saved profile had both sides
            # set to NOTHING, so a perfect press would still have done
            # nothing at all - and this line used to sit there reporting
            # centimetres as though it were armed.
            if f.get("left") == "OFF" and f.get("right") == "OFF":
                return ("On, but both sides are set to do nothing - choose "
                        "Flashlight or Night Vision above.")
            if f.get("live") != "true":
                return "On - waiting for your hands."
            return ("On. Left hand %s cm from the button beside your head, "
                    "right hand %s cm - get within %s. Switched %s times so "
                    "far." % (f.get("dL", "?"), f.get("dR", "?"),
                              f.get("range", "?"), f.get("fires", "0")))
        if key == "gpu":
            # this one is the app's own answer, not the game's
            return gpu_advice()
        if key == "espplus":
            f = self._fields(raw)
            if f.get("boxes") != "true" and f.get("hitboxes") != "true":
                return "Off."
            live = f.get("live", "0")
            colour = f.get("colour", "?").replace("_", " ").lower()
            if live in ("0", ""):
                return "On - waiting for enemies (colour: %s)." % colour
            return "On %s enemies (colour: %s)." % (live, colour)
        if key == "opt":
            return raw.split("auto=", 1)[1].split(" captured=")[0] if "auto=" in raw else raw
        return raw


def main():
    # The launcher hides the console, so a crash would otherwise vanish
    # silently. Show it in a popup instead.
    # one window only, however many things tried to start it
    if not claim_single_instance():
        return

    try:
        root = tk.Tk()
        ModMenuApp(root)
        root.mainloop()
    except Exception:
        import traceback
        detail = traceback.format_exc()
        try:
            from tkinter import messagebox
            messagebox.showerror("Blood Trail Mod Menu - error", detail)
        except Exception:
            pass
        try:
            with open(os.path.join(HERE, "modmenu-error.log"), "w",
                      encoding="utf-8") as fh:
                fh.write(detail)
        except Exception:
            pass
        raise


if __name__ == "__main__":
    main()
