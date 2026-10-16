"""Writes the bot face scene (RML) for the Rive CLI: `python3 gen.py 0 > scene.rml`.

The argument is the starting `state` (0 idle, 1 thinking, 2 working, 3 needs
you, 4 done); use 0 for the real file and others only to screenshot a state.
The app relies on the names Avatar, Bot and state (docs/DESIGN.md, M7.4).
"""
import sys
# --- palette (ARGB) ---
BLUE, BLUE_L, GLOW = "FF2F6BFF", "FF7FA6FF", "FF5C8DFF"
RED, RED_L, AMBER = "FFFF5A4F", "FFFF9A8F", "FFFFB547"
FACE, EYE, WHITE = "FF0A1433", "FFA8E1FF", "FFFFFFFF"
BY = 120  # Bot node y

state_default = sys.argv[1] if len(sys.argv) > 1 else "0"

def shape(id_, name, geom, color_id, color, x=0, y=0, extra=""):
    return f'''<Shape x="{x}" y="{y}" {extra}name="{name}" id="{id_}">
    {geom}
    <Fill name="Fill"><SolidColor colorValue="{color}" name="Color" id="{color_id}"/></Fill>
</Shape>'''

def rect(w, h, r, x=0, y=0, name="Path"):
    return f'<Rectangle x="{x}" y="{y}" width="{w}" height="{h}" cornerRadiusTL="{r}" name="{name}"/>'

def ell(w, h):
    return f'<Ellipse width="{w}" height="{h}" name="Path"/>'

art = "\n".join([
  shape("0:30", "ScanBar", rect(8, 54, 4), "0:31", EYE, 0, 4, 'opacity="0" '),
  shape("0:32", "Mouth", rect(22, 5, 2.5), "0:33", EYE, 0, 26, 'opacity="0.7" '),
  f'''<Shape opacity="0" name="Happy Eyes" id="0:51">
<PointsPath x="-24" y="0" isClosed="false" name="Happy L"><StraightVertex x="-10" y="4"/><StraightVertex x="0" y="-6" radius="5"/><StraightVertex x="10" y="4"/></PointsPath>
<PointsPath x="24" y="0" isClosed="false" name="Happy R"><StraightVertex x="-10" y="4"/><StraightVertex x="0" y="-6" radius="5"/><StraightVertex x="10" y="4"/></PointsPath>
<Stroke thickness="6" cap="round" join="round" name="Stroke"><SolidColor colorValue="{EYE}" name="Color"/></Stroke>
</Shape>''',
  f'''<Node name="Eyes" id="0:34">
{shape("0:35", "Eye L", ell(20, 26), "0:36", EYE, -24, 0)}
{shape("0:37", "Eye R", ell(20, 26), "0:38", EYE, 24, 0)}
</Node>''',
  shape("0:39", "Face", rect(108, 70, 26), "0:40", FACE, 0, 4),
  shape("0:41", "Head", rect(140, 108, 34), "0:42", BLUE),
  shape("0:43", "Ears", rect(12, 36, 6, -74, 2, "Ear L") + rect(12, 36, 6, 74, 2, "Ear R"), "0:44", BLUE_L),
  shape("0:45", "Antenna Light", ell(16, 16), "0:46", BLUE_L, 0, -80),
  shape("0:47", "Antenna Glow", ell(32, 32), "0:48", GLOW, 0, -80, 'opacity="0.35" '),
  shape("0:49", "Antenna Stem", rect(5, 26, 2.5), "0:50", BLUE_L, 0, -64),
])

# keyed property tracks: (objectId, prop, is_color)
TRACKS = [
  ("0:20", "y", 0), ("0:20", "scaleX", 0), ("0:20", "scaleY", 0), ("0:20", "rotation", 0),
  ("0:34", "x", 0), ("0:34", "y", 0),
  ("0:35", "scaleY", 0), ("0:37", "scaleY", 0),
  ("0:32", "scaleX", 0), ("0:32", "opacity", 0),
  ("0:30", "x", 0), ("0:30", "opacity", 0),
  ("0:47", "opacity", 0), ("0:47", "scaleX", 0), ("0:47", "scaleY", 0),
  ("0:42", "colorValue", 1), ("0:44", "colorValue", 1), ("0:50", "colorValue", 1),
  ("0:46", "colorValue", 1), ("0:48", "colorValue", 1), ("0:36", "colorValue", 1),
  ("0:38", "colorValue", 1), ("0:51", "opacity", 0),
]
REST = {
  ("0:20","y"): BY, ("0:20","scaleX"): 1, ("0:20","scaleY"): 1, ("0:20","rotation"): 0,
  ("0:34","x"): 0, ("0:34","y"): 0, ("0:35","scaleY"): 1, ("0:37","scaleY"): 1,
  ("0:32","scaleX"): 1, ("0:32","opacity"): 0.7, ("0:30","x"): 0, ("0:30","opacity"): 0,
  ("0:47","opacity"): 0.35, ("0:47","scaleX"): 1, ("0:47","scaleY"): 1,
  ("0:42","colorValue"): BLUE, ("0:44","colorValue"): BLUE_L, ("0:50","colorValue"): BLUE_L,
  ("0:46","colorValue"): BLUE_L, ("0:48","colorValue"): GLOW,
  ("0:36","colorValue"): EYE, ("0:38","colorValue"): EYE, ("0:51","opacity"): 0,
}

def kfs(keys, is_color):
    out = []
    for k in keys:
        f, v = k[0], k[1]
        interp = k[2] if len(k) > 2 else "cubic"
        tag = "KeyFrameColor" if is_color else "KeyFrameDouble"
        if interp == "cubic":
            out.append(f'<{tag} value="{v}" frame="{f}" interpolationType="cubic"><CubicEaseInterpolator x1="0.42" y1="0" x2="0.58" y2="1"/></{tag}>')
        else:
            out.append(f'<{tag} value="{v}" frame="{f}" interpolationType="{interp}"/>')
    return "\n".join(out)

def anim(id_, name, dur, loop, spec):
    objs = {}
    for oid, prop, is_color in TRACKS:
        keys = spec.get((oid, prop), [(0, REST[(oid, prop)], "hold")])
        objs.setdefault(oid, []).append(f'<KeyedProperty property="{prop}">\n{kfs(keys, is_color)}\n</KeyedProperty>')
    body = "\n".join(f'<KeyedObject objectId="{o}">\n' + "\n".join(p) + "\n</KeyedObject>" for o, p in objs.items())
    return f'<LinearAnimation loopValue="{loop}" duration="{dur}" name="{name}" id="{id_}">\n{body}\n</LinearAnimation>'

def blink(start):
    return [(0, 1, "hold"), (start, 1, "linear"), (start + 5, 0.1, "linear"), (start + 10, 1, "hold")]

anims = [
  # 0 idle: 4s breathing, blink near the end
  anim("0:60", "Idle", 240, "loop", {
    ("0:20","y"): [(0, BY), (120, BY - 3), (240, BY)],
    ("0:20","scaleX"): [(0, 1), (120, 1.03), (240, 1)],
    ("0:20","scaleY"): [(0, 1), (120, 1.03), (240, 1)],
    ("0:35","scaleY"): blink(200), ("0:37","scaleY"): blink(200),
    ("0:47","opacity"): [(0, 0.3), (120, 0.45), (240, 0.3)],
  }),
  # 1 thinking: eyes look up-left / up-right, antenna glows slowly
  anim("0:61", "Thinking", 180, "loop", {
    ("0:20","y"): [(0, BY), (90, BY - 2), (180, BY)],
    ("0:20","rotation"): [(0, 0), (45, -0.04), (135, 0.04), (180, 0)],
    ("0:34","x"): [(0, 0), (30, -9), (75, -9), (105, 9), (150, 9), (180, 0)],
    ("0:34","y"): [(0, 0), (30, -7), (150, -7), (180, 0)],
    ("0:46","colorValue"): [(0, BLUE_L), (90, WHITE), (180, BLUE_L)],
    ("0:47","opacity"): [(0, 0.25), (90, 0.75), (180, 0.25)],
    ("0:47","scaleX"): [(0, 1), (90, 1.3), (180, 1)],
    ("0:47","scaleY"): [(0, 1), (90, 1.3), (180, 1)],
    ("0:32","scaleX"): [(0, 0.6, "hold")],
  }),
  # 2 working: scanning bar, narrowed eyes, quick bob, flashing antenna
  anim("0:62", "Working", 60, "loop", {
    ("0:20","y"): [(0, BY), (15, BY - 3), (30, BY), (45, BY - 3), (60, BY)],
    ("0:35","scaleY"): [(0, 0.35, "hold")], ("0:37","scaleY"): [(0, 0.35, "hold")],
    ("0:34","x"): [(0, -6), (30, 6), (60, -6)],
    ("0:30","x"): [(0, -44), (30, 44), (60, -44)],
    ("0:30","opacity"): [(0, 0.85, "hold")],
    ("0:46","colorValue"): [(0, WHITE, "hold"), (10, BLUE_L, "hold"), (20, WHITE, "hold"), (30, BLUE_L, "hold"), (40, WHITE, "hold"), (50, BLUE_L, "hold")],
    ("0:47","opacity"): [(0, 0.8, "hold"), (10, 0.2, "hold"), (20, 0.8, "hold"), (30, 0.2, "hold"), (40, 0.8, "hold"), (50, 0.2, "hold")],
    ("0:32","opacity"): [(0, 0.35, "hold")],
  }),
  # 3 waiting for owner: urgent colour, attention pulse, wiggle
  anim("0:63", "Waiting", 60, "loop", {
    ("0:20","scaleX"): [(0, 1), (12, 1.08), (30, 1), (60, 1)],
    ("0:20","scaleY"): [(0, 1), (12, 1.08), (30, 1), (60, 1)],
    ("0:20","rotation"): [(0, 0, "linear"), (6, 0.06, "linear"), (12, -0.06, "linear"), (18, 0.04, "linear"), (24, 0, "hold")],
    ("0:42","colorValue"): [(0, RED, "hold")],
    ("0:44","colorValue"): [(0, RED_L, "hold")], ("0:50","colorValue"): [(0, RED_L, "hold")],
    ("0:46","colorValue"): [(0, AMBER), (12, WHITE), (60, AMBER)],
    ("0:48","colorValue"): [(0, AMBER, "hold")],
    ("0:47","opacity"): [(0, 0.4), (12, 0.9), (60, 0.4)],
    ("0:47","scaleX"): [(0, 1), (12, 1.5), (60, 1)],
    ("0:47","scaleY"): [(0, 1), (12, 1.5), (60, 1)],
    ("0:35","scaleY"): [(0, 1.15, "hold")], ("0:37","scaleY"): [(0, 1.15, "hold")],
    ("0:32","scaleX"): [(0, 0.5, "hold")],
  }),
  # 4 done: happy bounce + squint, then holds
  anim("0:64", "Done", 54, "oneShot", {
    ("0:20","y"): [(0, BY), (10, BY - 12), (22, BY), (32, BY - 5), (42, BY), (54, BY)],
    ("0:20","scaleX"): [(0, 1), (20, 1.0), (24, 1.06), (32, 1), (54, 1)],
    ("0:20","scaleY"): [(0, 1), (20, 1.0), (24, 0.94), (32, 1), (54, 1)],
    ("0:35","scaleY"): [(0, 1), (6, 0.05, "hold")], ("0:37","scaleY"): [(0, 1), (6, 0.05, "hold")],
    ("0:51","opacity"): [(0, 0, "hold"), (6, 1, "hold")],
    ("0:34","y"): [(0, 0), (8, -2), (54, -2)],
    ("0:32","scaleX"): [(0, 1), (10, 1.9), (54, 1.9)],
    ("0:32","opacity"): [(0, 0.7), (10, 1), (54, 1)],
    ("0:46","colorValue"): [(0, WHITE), (54, BLUE_L)],
    ("0:47","opacity"): [(0, 0.9), (54, 0.4)],
  }),
]

STATES = [("0:70", "0:60"), ("0:71", "0:61"), ("0:72", "0:62"), ("0:73", "0:63"), ("0:74", "0:64")]
any_transitions = "\n".join(
  f'<StateTransition stateToId="{sid}" duration="200"><TransitionNumberCondition inputId="0:9" opValue="equal" value="{i}"/></StateTransition>'
  for i, (sid, _) in enumerate(STATES))
states = "\n".join(f'<AnimationState x="{160 + 160*i}" y="120" animationId="{aid}" id="{sid}"/>' for i, (sid, aid) in enumerate(STATES))

print(f'''<Rive version="1" kind="fragment">
<Artboard defaultStateMachineId="0:7" styleId="0:5" width="200" height="200" name="Avatar" id="0:2">
<LayoutComponentStyle name="Artboard Style" id="0:5"/>
<Node x="100" y="{BY}" name="Bot" id="0:20">
{art}
</Node>
<StateMachine name="Bot" id="0:7">
<StateMachineNumber value="{state_default}" name="state" id="0:9"/>
<StateMachineLayer name="State" id="0:8">
<AnyState x="480" y="-120">
{any_transitions}
</AnyState>
<ExitState x="800" y="-120"/>
<EntryState x="0" y="120"><StateTransition stateToId="0:70"/></EntryState>
{states}
</StateMachineLayer>
</StateMachine>
{chr(10).join(anims)}
</Artboard>
</Rive>''')
