"""Writes a bot face scene (RML) for the Rive CLI: `python3 gen.py <style> [state] > scene.rml`.

Styles: default, inbox, researcher, coder, checker, blogger, pa (see STYLES).
`state` is the starting value of the `state` input (0 idle, 1 thinking,
2 working, 3 needs you, 4 done); use 0 for real files and others only to
screenshot a state. `python3 gen.py 0` still means the default style, state 0.
Every style shares the contract the app relies on: artboard Avatar, state
machine Bot, Number input state (docs/DESIGN.md, M7.4). In state 3 every
style turns its head RED and its light (antenna or accessory) AMBER.
"""
import sys

RED, RED_L, AMBER, WHITE = "FFFF5A4F", "FFFF9A8F", "FFFFB547", "FFFFFFFF"

# Each style: colours (ARGB) and the features its face is built from.
#   head  trim (ears, stem, accessories)  light (pulses; amber in state 3)
#   glow (halo behind the light)  face (plate)  eye  mouth
STYLES = {
    "default": dict(head="FF2F6BFF", trim="FF7FA6FF", light="FF7FA6FF", glow="FF5C8DFF",
                    face="FF0A1433", eye="FFA8E1FF", mouth="FFA8E1FF",
                    shape=(140, 108, 34), plate=(108, 70, 26, 4), eyes="oval", eye_y=0, mouth_y=26,
                    ears="rect", top="ball", extras=[], by=120),
    # envelope: squarer head, a flap folded over the forehead, a mail-slot light
    "inbox": dict(head="FF1F8FFF", trim="FFA5D4FF", light="FFA5D4FF", glow="FF5FB0FF",
                  face="FF071A33", eye="FFBEE6FF", mouth="FFBEE6FF",
                  shape=(150, 104, 12), plate=(112, 58, 18, 12), eyes="oval", eye_y=10, mouth_y=32,
                  ears=None, top="slot", extras=["flap"], by=122),
    "researcher": dict(head="FF0FA899", trim="FF73E3D6", light="FF73E3D6", glow="FF35CDBD",
                       face="FF04211E", eye="FFB8F7EE", mouth="FFB8F7EE",
                       shape=(140, 108, 40), plate=(112, 70, 30, 4), eyes="small", eye_y=0, mouth_y=27,
                       ears="round", top="ball", extras=["glasses"], by=120),
    "coder": dict(head="FF7A4DFF", trim="FFC2ABFF", light="FFC2ABFF", glow="FF9A78FF",
                  face="FF140A33", eye="FFE4DBFF", mouth="FFE4DBFF",
                  shape=(136, 108, 26), plate=(106, 70, 18, 4), eyes="square", eye_y=0, mouth_y=26,
                  ears="brackets", top="square", extras=[], by=120),
    # visor: a wide, shallow plate; check-mark antenna
    "checker": dict(head="FF1FAE5B", trim="FF8AE8B0", light="FF8AE8B0", glow="FF4FD685",
                    face="FF052414", eye="FFC8FFDA", mouth="FF052414",
                    shape=(140, 108, 34), plate=(130, 46, 23, -4), eyes="oval", eye_y=-4, mouth_y=34,
                    ears="rect", top="check", extras=[], by=120),
    # beret with a light on its tip instead of an antenna
    "blogger": dict(head="FFF0679B", trim="FFFFB8D1", light="FFFFD1E2", glow="FFFF8FB8",
                    face="FF2A0A18", eye="FFFFE3EE", mouth="FFFFE3EE",
                    shape=(140, 108, 34), plate=(108, 70, 26, 6), eyes="oval", eye_y=2, mouth_y=28,
                    ears="rect", top="beret", extras=["beret"], by=122),
    "pa": dict(head="FFF2C230", trim="FFFFE9A0", light="FFFFE9A0", glow="FFFFD54F",
               face="FF2B2104", eye="FFFFF4C8", mouth="FFFFF4C8",
               shape=(140, 104, 34), plate=(108, 68, 26, 2), eyes="oval", eye_y=-2, mouth_y=24,
               ears="rect", top="ball", extras=["bowtie"], by=110),
}

args = sys.argv[1:]
if args and args[0].lstrip("-").isdigit():   # legacy form: gen.py <state>
    args = ["default"] + args
style_name = args[0] if args else "default"
state_default = args[1] if len(args) > 1 else "0"
if style_name not in STYLES:
    sys.exit(f"unknown style {style_name!r}; one of: {', '.join(STYLES)}")
S = STYLES[style_name]
BY = S["by"]

# colour roles: every SolidColor in a role is keyed together by the animations
ROLES = {"head": [], "trim": [], "light": [], "glow": []}
_next = [100]

def paint(role_or_color):
    """A SolidColor; a role name registers it so animations can key it."""
    if role_or_color in ROLES:
        _next[0] += 1
        cid = f"0:{_next[0]}"
        ROLES[role_or_color].append(cid)
        return f'<SolidColor colorValue="{S[role_or_color]}" name="Color" id="{cid}"/>'
    return f'<SolidColor colorValue="{role_or_color}" name="Color"/>'

def fill(c):
    return f'<Fill name="Fill">{paint(c)}</Fill>'

def stroke(c, t):
    return f'<Stroke thickness="{t}" cap="round" join="round" name="Stroke">{paint(c)}</Stroke>'

def shape(name, geom, paints, x=0, y=0, extra="", id_=None):
    i = f' id="{id_}"' if id_ else ""
    return f'<Shape x="{x}" y="{y}" {extra}name="{name}"{i}>\n{geom}\n{paints}\n</Shape>'

def rect(w, h, r, x=0, y=0, name="Path"):
    return f'<Rectangle x="{x}" y="{y}" width="{w}" height="{h}" cornerRadiusTL="{r}" name="{name}"/>'

def ell(w, h, x=0, y=0, name="Path"):
    return f'<Ellipse x="{x}" y="{y}" width="{w}" height="{h}" name="{name}"/>'

def path(pts, closed=False, x=0, y=0, name="Path", radius=None):
    vs = "".join(f'<StraightVertex x="{px}" y="{py}"' + (f' radius="{radius}"' if radius and 0 < k < len(pts) - 1 else "") + "/>"
                 for k, (px, py) in enumerate(pts))
    return f'<PointsPath x="{x}" y="{y}" isClosed="{"true" if closed else "false"}" name="{name}">{vs}</PointsPath>'

hw, hh, hr = S["shape"]
pw, ph, pr, py = S["plate"]
ey = S["eye_y"]
top_y = -hh / 2   # head top, relative to the Bot node

# --- eyes ---
eye_geom = {"oval": ell(20, 26), "small": ell(16, 20), "square": rect(18, 18, 3)}[S["eyes"]]
eyes_extra = ""
if "glasses" in S["extras"]:   # round glasses move with the eyes
    eyes_extra = shape("Glasses", ell(36, 36, -24, 0, "Lens L") + ell(36, 36, 24, 0, "Lens R"),
                       stroke("FFE6FFFB", 5), 0, ey) + "\n" + shape("Bridge", rect(14, 5, 2.5), fill("FFE6FFFB"), 0, ey - 3)
happy = "".join(path([(-10, 4), (0, -6), (10, 4)], x=sx, name=f"Happy {n}", radius=5) for sx, n in ((-24, "L"), (24, "R")))

art = [
    shape("ScanBar", rect(8, ph - 16, 4), fill(S["eye"]), 0, py, 'opacity="0" ', "0:30"),
    shape("Mouth", rect(22, 5, 2.5), fill(S["mouth"]), 0, S["mouth_y"], 'opacity="0.7" ', "0:32"),
    shape("Happy Eyes", happy, stroke(S["eye"], 6), 0, ey, 'opacity="0" ', "0:51"),
    f'''<Node name="Eyes" id="0:34">
{eyes_extra}
{shape("Eye L", eye_geom, fill(S["eye"]), -24, ey, id_="0:35")}
{shape("Eye R", eye_geom, fill(S["eye"]), 24, ey, id_="0:37")}
</Node>''',
    shape("Face", rect(pw, ph, pr), fill(S["face"]), 0, py),
]
if "flap" in S["extras"]:   # envelope flap: a V folded over the forehead (drawn on the head)
    art.append(shape("Flap", path([(-hw / 2 + 8, top_y + 6), (0, py - ph / 2 - 3), (hw / 2 - 8, top_y + 6)], radius=6),
                     stroke("trim", 6)))
if "beret" in S["extras"]:  # in front of the head
    art.append(shape("Beret", ell(128, 36), fill("FF9A2459"), -12, top_y - 4, 'rotation="-0.17" '))
art.append(shape("Head", rect(hw, hh, hr), fill("head")))

ears = S["ears"]
ex = hw / 2 + 4
if ears == "rect":
    art.append(shape("Ears", rect(12, 36, 6, -ex, 2, "Ear L") + rect(12, 36, 6, ex, 2, "Ear R"), fill("trim")))
elif ears == "round":
    art.append(shape("Ears", ell(18, 38, -ex - 1, 2, "Ear L") + ell(18, 38, ex + 1, 2, "Ear R"), fill("trim")))
elif ears == "brackets":   # < >
    bx = hw / 2 + 9
    art.append(shape("Brackets", path([(-bx, -16), (-bx - 10, 2), (-bx, 20)], name="Lt") +
                     path([(bx, -16), (bx + 10, 2), (bx, 20)], name="Gt"), stroke("light", 7)))

if "bowtie" in S["extras"]:
    by_ = hh / 2 + 11
    art.append(shape("Bow Tie", path([(-3, 0), (-25, -13), (-25, 13)], True, name="Wing L", radius=4) +
                     path([(3, 0), (25, -13), (25, 13)], True, name="Wing R", radius=4) + ell(13, 13, name="Knot"),
                     fill("trim"), 0, by_))

top = S["top"]
if top in ("ball", "square"):
    stem = shape("Antenna Stem", rect(5, 26, 2.5), fill("trim"), 0, top_y - 10)
if top == "ball":
    gx, gy, gw, gh = 0, top_y - 26, 32, 32
    art += [shape("Antenna Light", ell(16, 16), fill("light"), gx, gy)]
elif top == "square":
    gx, gy, gw, gh = 0, top_y - 26, 32, 32
    art += [shape("Antenna Light", rect(15, 15, 3), fill("light"), gx, gy)]
elif top == "slot":
    gx, gy, gw, gh = 0, top_y - 22, 50, 24
    stem = shape("Antenna Stem", rect(5, 18, 2.5), fill("trim"), 0, top_y - 6)
    art += [shape("Mail Slot", rect(34, 10, 5), fill("light"), gx, gy)]
elif top == "check":
    gx, gy, gw, gh = 0, top_y - 30, 36, 36
    stem = shape("Antenna Stem", rect(5, 22, 2.5), fill("trim"), 0, top_y - 8)
    art += [shape("Check", path([(-10, 0), (-3, 7), (11, -9)], radius=2), stroke("light", 6), gx, gy)]
elif top == "beret":   # the beret's tip is the light; no antenna stem
    gx, gy, gw, gh = -8, top_y - 26, 28, 28
    stem = shape("Beret Stalk", rect(4, 10, 2), fill("FF9A2459"), -9, top_y - 18, 'rotation="-0.17" ')
    beret_at = next(k for k, a in enumerate(art) if 'name="Beret"' in a)
    art.insert(beret_at, shape("Beret Tip", ell(12, 12), fill("light"), gx, gy))
art.append(shape("Antenna Glow", ell(gw, gh), fill("glow"), gx, gy, 'opacity="0.35" ', "0:47"))
art.append(stem)

# --- animation tracks: (objectId or colour role, property) ---
TRACKS = [("0:20", "y"), ("0:20", "scaleX"), ("0:20", "scaleY"), ("0:20", "rotation"),
          ("0:34", "x"), ("0:34", "y"), ("0:35", "scaleY"), ("0:37", "scaleY"),
          ("0:32", "scaleX"), ("0:32", "opacity"), ("0:30", "x"), ("0:30", "opacity"),
          ("0:47", "opacity"), ("0:47", "scaleX"), ("0:47", "scaleY"), ("0:51", "opacity"),
          ("head", "colorValue"), ("trim", "colorValue"), ("light", "colorValue"), ("glow", "colorValue")]
REST = {("0:20", "y"): BY, ("0:20", "scaleX"): 1, ("0:20", "scaleY"): 1, ("0:20", "rotation"): 0,
        ("0:34", "x"): 0, ("0:34", "y"): 0, ("0:35", "scaleY"): 1, ("0:37", "scaleY"): 1,
        ("0:32", "scaleX"): 1, ("0:32", "opacity"): 0.7, ("0:30", "x"): 0, ("0:30", "opacity"): 0,
        ("0:47", "opacity"): 0.35, ("0:47", "scaleX"): 1, ("0:47", "scaleY"): 1, ("0:51", "opacity"): 0,
        ("head", "colorValue"): S["head"], ("trim", "colorValue"): S["trim"],
        ("light", "colorValue"): S["light"], ("glow", "colorValue"): S["glow"]}

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
    for target, prop in TRACKS:
        keys = spec.get((target, prop), [(0, REST[(target, prop)], "hold")])
        is_color = target in ROLES
        for oid in (ROLES[target] if is_color else [target]):
            objs.setdefault(oid, []).append(f'<KeyedProperty property="{prop}">\n{kfs(keys, is_color)}\n</KeyedProperty>')
    body = "\n".join(f'<KeyedObject objectId="{o}">\n' + "\n".join(p) + "\n</KeyedObject>" for o, p in objs.items())
    return f'<LinearAnimation loopValue="{loop}" duration="{dur}" name="{name}" id="{id_}">\n{body}\n</LinearAnimation>'

def blink(start):
    return [(0, 1, "hold"), (start, 1, "linear"), (start + 5, 0.1, "linear"), (start + 10, 1, "hold")]

L = S["light"]
anims = [
    # 0 idle: 4s breathing, blink near the end
    anim("0:60", "Idle", 240, "loop", {
        ("0:20", "y"): [(0, BY), (120, BY - 3), (240, BY)],
        ("0:20", "scaleX"): [(0, 1), (120, 1.03), (240, 1)],
        ("0:20", "scaleY"): [(0, 1), (120, 1.03), (240, 1)],
        ("0:35", "scaleY"): blink(200), ("0:37", "scaleY"): blink(200),
        ("0:47", "opacity"): [(0, 0.3), (120, 0.45), (240, 0.3)],
    }),
    # 1 thinking: eyes look up-left / up-right, light glows slowly
    anim("0:61", "Thinking", 180, "loop", {
        ("0:20", "y"): [(0, BY), (90, BY - 2), (180, BY)],
        ("0:20", "rotation"): [(0, 0), (45, -0.04), (135, 0.04), (180, 0)],
        ("0:34", "x"): [(0, 0), (30, -9), (75, -9), (105, 9), (150, 9), (180, 0)],
        ("0:34", "y"): [(0, 0), (30, -7), (150, -7), (180, 0)],
        ("light", "colorValue"): [(0, L), (90, WHITE), (180, L)],
        ("0:47", "opacity"): [(0, 0.25), (90, 0.75), (180, 0.25)],
        ("0:47", "scaleX"): [(0, 1), (90, 1.3), (180, 1)],
        ("0:47", "scaleY"): [(0, 1), (90, 1.3), (180, 1)],
        ("0:32", "scaleX"): [(0, 0.6, "hold")],
    }),
    # 2 working: scanning bar, narrowed eyes, quick bob, flashing light
    anim("0:62", "Working", 60, "loop", {
        ("0:20", "y"): [(0, BY), (15, BY - 3), (30, BY), (45, BY - 3), (60, BY)],
        ("0:35", "scaleY"): [(0, 0.35, "hold")], ("0:37", "scaleY"): [(0, 0.35, "hold")],
        ("0:34", "x"): [(0, -6), (30, 6), (60, -6)],
        ("0:30", "x"): [(0, -(pw / 2 - 10)), (30, pw / 2 - 10), (60, -(pw / 2 - 10))],
        ("0:30", "opacity"): [(0, 0.85, "hold")],
        ("light", "colorValue"): [(f, WHITE if f % 20 == 0 else L, "hold") for f in range(0, 60, 10)],
        ("0:47", "opacity"): [(f, 0.8 if f % 20 == 0 else 0.2, "hold") for f in range(0, 60, 10)],
        ("0:32", "opacity"): [(0, 0.35, "hold")],
    }),
    # 3 needs you: urgent colour, attention pulse, wiggle (same for every style)
    anim("0:63", "Waiting", 60, "loop", {
        ("0:20", "scaleX"): [(0, 1), (12, 1.08), (30, 1), (60, 1)],
        ("0:20", "scaleY"): [(0, 1), (12, 1.08), (30, 1), (60, 1)],
        ("0:20", "rotation"): [(0, 0, "linear"), (6, 0.06, "linear"), (12, -0.06, "linear"), (18, 0.04, "linear"), (24, 0, "hold")],
        ("head", "colorValue"): [(0, RED, "hold")],
        ("trim", "colorValue"): [(0, RED_L, "hold")],
        ("light", "colorValue"): [(0, AMBER), (12, WHITE), (60, AMBER)],
        ("glow", "colorValue"): [(0, AMBER, "hold")],
        ("0:47", "opacity"): [(0, 0.4), (12, 0.9), (60, 0.4)],
        ("0:47", "scaleX"): [(0, 1), (12, 1.5), (60, 1)],
        ("0:47", "scaleY"): [(0, 1), (12, 1.5), (60, 1)],
        ("0:35", "scaleY"): [(0, 1.15, "hold")], ("0:37", "scaleY"): [(0, 1.15, "hold")],
        ("0:32", "scaleX"): [(0, 0.5, "hold")],
    }),
    # 4 done: happy bounce + ^ ^ eyes, then holds
    anim("0:64", "Done", 54, "oneShot", {
        ("0:20", "y"): [(0, BY), (10, BY - 12), (22, BY), (32, BY - 5), (42, BY), (54, BY)],
        ("0:20", "scaleX"): [(0, 1), (20, 1.0), (24, 1.06), (32, 1), (54, 1)],
        ("0:20", "scaleY"): [(0, 1), (20, 1.0), (24, 0.94), (32, 1), (54, 1)],
        ("0:35", "scaleY"): [(0, 1), (6, 0.05, "hold")], ("0:37", "scaleY"): [(0, 1), (6, 0.05, "hold")],
        ("0:51", "opacity"): [(0, 0, "hold"), (6, 1, "hold")],
        ("0:34", "y"): [(0, 0), (8, -2), (54, -2)],
        ("0:32", "scaleX"): [(0, 1), (10, 1.9), (54, 1.9)],
        ("0:32", "opacity"): [(0, 0.7), (10, 1), (54, 1)],
        ("light", "colorValue"): [(0, WHITE), (54, L)],
        ("0:47", "opacity"): [(0, 0.9), (54, 0.4)],
    }),
]

STATES = [("0:70", "0:60"), ("0:71", "0:61"), ("0:72", "0:62"), ("0:73", "0:63"), ("0:74", "0:64")]
any_transitions = "\n".join(
    f'<StateTransition stateToId="{sid}" duration="200"><TransitionNumberCondition inputId="0:9" opValue="equal" value="{i}"/></StateTransition>'
    for i, (sid, _) in enumerate(STATES))
states = "\n".join(f'<AnimationState x="{160 + 160*i}" y="120" animationId="{aid}" id="{sid}"/>' for i, (sid, aid) in enumerate(STATES))
art_xml = "\n".join(art)

print(f'''<Rive version="1" kind="fragment">
<Artboard defaultStateMachineId="0:7" styleId="0:5" width="200" height="200" name="Avatar" id="0:2">
<LayoutComponentStyle name="Artboard Style" id="0:5"/>
<Node x="100" y="{BY}" name="Bot" id="0:20">
{art_xml}
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
