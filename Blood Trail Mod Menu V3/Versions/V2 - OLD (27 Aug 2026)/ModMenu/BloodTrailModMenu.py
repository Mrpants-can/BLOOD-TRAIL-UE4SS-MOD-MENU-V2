"""
Blood Trail Mod Menu - desktop control panel.

Talks to the in-game UE4SS Lua mod through two text files in this folder:
    control.txt   we write it, the mod reads it  (all toggles + a command slot)
    status.txt    the mod writes it, we read it  (health, pawn, enemies, kills)

Nothing here needs the game to be running - if it is not, the panel just shows
"game not running" and everything you set is picked up the moment it starts.

Run it with Launch Mod Menu.bat, or:  py BloodTrailModMenu.py
"""

import ctypes
import json
import os
import sys
import time
import tkinter as tk
from tkinter import ttk

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

    # already running - surface the window that is already there
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
    "FireModeIndex":      (3.0,   "num", 0.0, 3.0, 1.0),
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
    "PanelSolidBg":  (False, "bool"),
    "TwoPointers":   (True, "bool"),
    "TouchPointer":  (False, "bool"),
    "AimFromSocket": (False, "bool"),
    "AimFromWidget": (True, "bool"),
    "TouchRange":    (25.0, "num", 5.0, 200.0, 5.0),
}

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
        ("toggle", "FullAuto",      "Full Auto  (all guns, no shotgun pumping)"),
        ("slider", "FireRateValue", "Fire rate - seconds per shot, lower is faster"),
        ("slider", "FireModeIndex", "Fire mode index - try 0-3 if full auto looks wrong"),
        ("button", "refill",       "Refill Everything Now"),
        ("button", "headlamp",     "Toggle Headlamp"),
        ("button", "nightvision",  "Toggle Night Vision"),
        ("toggle", "NoAccidentalLamp", "No Accidental Lamp/NVG  (stop your hand flipping them)"),
        ("button", "lamptest",     "Test Lamp Lock"),
    ]),
    ("Enemies", [
        ("toggle", "EnemyESP",        "Enemy ESP  (distance + clock direction in headset)"),
        ("button", "espreset",        "Restart ESP now  (or press END in game)"),
        ("toggle", "FreezeEnemies",   "Freeze All Enemies"),
        ("toggle", "StopEnemySpawns", "Stop Enemies Spawning"),
        ("danger", "killall",         "Delete All Enemies"),
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
        ("toggle", "PanelDepthFix", "Panel hides behind hands and walls"),
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

        root.title(WINDOW_TITLE)
        root.configure(bg=BG)
        root.geometry("620x680")
        root.minsize(560, 600)

        self.build_style()
        self.build_header()
        self.build_tabs()
        self.build_footer()

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

        if changed:
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

    def build_tabs(self):
        nb = ttk.Notebook(self.root)
        nb.pack(fill="both", expand=True, padx=10, pady=10)

        for name, rows in TABS:
            frame = self.scrollable_page(nb, name)
            for kind, key, label in rows:
                self.add_row(frame, kind, key, label)

        self.build_spawn_tab(nb)
        self.build_maps_tab(nb)

    def add_row(self, parent, kind, key, label):
        if kind == "toggle":
            default = SETTINGS[key][0]
            var = tk.BooleanVar(value=default)
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

            var = tk.DoubleVar(value=SETTINGS[key][0])
            self.vars[key] = var
            # multipliers read "2.5x"; HP and indices read whole; a fire rate
            # of 0.06 s needs two decimals or it rounds away to "0.1"
            if key == "MeleeKnockback":
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

        self.root.after(500, self.poll_status)


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
