"""Writes a bot's Rive scene (RML) for the Rive CLI: `python3 gen.py <style> [state] > scene.rml`.

Styles: see STYLES, or `python3 gen.py --list` (that list is styles.txt).
`state` is the starting value of the `state` input (0 idle, 1 thinking,
2 working, 3 needs you, 4 done, 5 failed); use 0 for real files and others
only to screenshot a state. `python3 gen.py 0` still means the default style, state 0.

Two artboards, each with a state machine `Bot` holding a Number input `state`
and a Trigger input `poke` (also fired by tapping the bot):
  Avatar  200x200, the head only (the default artboard; docs/DESIGN.md, M7.4)
  Robot   200x260, the head on a full body with the style's locomotion (BODIES)
In state 3 every style turns RED with an AMBER light. State 5 self-destructs:
the Avatar shakes, puffs smoke and goes dizzy; the Robot shakes, goes boom,
flies apart, falls back together crooked and stays dizzy until the state changes.
"""
import math
import sys

RED, RED_L, AMBER, WHITE = "FFFF5A4F", "FFFF9A8F", "FFFFB547", "FFFFFFFF"
DEAD = "FF4A4A4E"   # a burnt-out light after state 5

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
    # the leader: silver head, deep navy face, a three-point crown with a jewel light
    "orchestrator": dict(head="FFE3E9F4", trim="FFA9B8D8", light="FF5FD3FF", glow="FF5FD3FF",
                         face="FF0B1638", eye="FF8FE0FF", mouth="FF8FE0FF",
                         shape=(140, 106, 34), plate=(108, 68, 26, 4), eyes="oval", eye_y=0, mouth_y=25,
                         ears="rect", top="crown", extras=[], by=124),
    "pa": dict(head="FFF2C230", trim="FFFFE9A0", light="FFFFE9A0", glow="FFFFD54F",
               face="FF2B2104", eye="FFFFF4C8", mouth="FFFFF4C8",
               shape=(140, 104, 34), plate=(108, 68, 26, 2), eyes="oval", eye_y=-2, mouth_y=24,
               ears="rect", top="ball", extras=["bowtie"], by=110),
    # --- the library: generic styles any bot can pick ---
    "headphones": dict(head="FFFF7F50", trim="FFFFC2A8", light="FFFFE0D2", glow="FFFFA07A",
                       face="FF2A1208", eye="FFFFE3D6", mouth="FFFFE3D6",
                       shape=(132, 104, 34), plate=(104, 66, 24, 4), eyes="oval", eye_y=0, mouth_y=25,
                       ears=None, top=None, extras=[], acc="headphones", by=122),
    "fox": dict(head="FFFF9A1F", trim="FFFFE2BD", light="FFFFE7CC", glow="FFFFC27A",
                face="FF2B1606", eye="FFFFE7CC", mouth="FFFFE7CC",
                shape=(140, 104, 34), plate=(108, 66, 26, 6), eyes="oval", eye_y=-2, mouth_y=28,
                ears=None, top=None, extras=[], acc="fox", by=128),
    "owl": dict(head="FF8A5A36", trim="FFE9C79A", light="FFF7E3C0", glow="FFF0C890",
                face="FF241509", eye="FF2A1A0E", mouth="FFF3DDB5", happy="FF2A1A0E",
                shape=(140, 108, 40), plate=(116, 74, 30, 4), eyes="small", eye_y=-2, mouth_y=30,
                ears=None, top=None, extras=[], acc="owl", by=122),
    "sprout": dict(head="FF8C9B32", trim="FFD7E59A", light="FFB8F06A", glow="FFB8F06A",
                   face="FF1C2208", eye="FFE6F5B8", mouth="FFE6F5B8",
                   shape=(140, 108, 34), plate=(108, 70, 26, 4), eyes="round", eye_y=0, mouth_y=26,
                   ears="round", top=None, extras=[], acc="sprout", by=124),
    "bolt": dict(head="FFA6D62C", trim="FFE4F7A8", light="FFFFF27A", glow="FFFFF27A",
                 face="FF1A2406", eye="FFF2FFC8", mouth="FFF2FFC8",
                 shape=(140, 108, 26), plate=(108, 70, 18, 4), eyes="slim", eye_y=0, mouth_y=26,
                 ears="rect", top=None, extras=[], acc="bolt", by=124),
    "nurse": dict(head="FF62E0B3", trim="FFD4FFF0", light="FF2FB98C", glow="FF8FF0CF",
                  face="FF06281D", eye="FFD4FFF0", mouth="FFD4FFF0",
                  shape=(140, 108, 34), plate=(108, 70, 26, 6), eyes="oval", eye_y=2, mouth_y=28,
                  ears="round", top=None, extras=[], acc="nurse", by=122),
    "astronaut": dict(head="FF22C7E8", trim="FFB5F1FF", light="FFE0FAFF", glow="FF7FE3F7",
                      face="FF04202A", eye="FFC8F6FF", mouth="FFC8F6FF",
                      shape=(136, 100, 32), plate=(104, 64, 24, 4), eyes="oval", eye_y=2, mouth_y=26,
                      ears="rect", top="ball", extras=[], acc="helmet", by=110),
    "detective": dict(head="FFB8A773", trim="FFE8DDB8", light="FFE8DDB8", glow="FFE8DDB8",
                      face="FF221D0E", eye="FFF2EBD2", mouth="FFF2EBD2",
                      shape=(140, 104, 30), plate=(108, 66, 24, 6), eyes="small", eye_y=2, mouth_y=28,
                      ears="rect", top=None, extras=[], acc="fedora", by=126),
    "pirate": dict(head="FF6F82A3", trim="FFC4CFE3", light="FFF0F3F8", glow="FFC4CFE3",
                   face="FF0E1420", eye="FFD6E2F5", mouth="FFD6E2F5",
                   shape=(140, 108, 34), plate=(108, 64, 24, 10), eyes="oval", eye_y=8, mouth_y=31,
                   ears=None, top=None, extras=[], acc="pirate", by=114),
    "wizard": dict(head="FF9D4EDD", trim="FFD9B8F5", light="FFFFE680", glow="FFFFE680",
                   face="FF1E0B2E", eye="FFEBD9FF", mouth="FFEBD9FF",
                   shape=(140, 104, 34), plate=(108, 66, 26, 6), eyes="oval", eye_y=2, mouth_y=28,
                   ears="rect", top=None, extras=[], acc="wizard", by=124),
    "cat": dict(head="FFD84FC4", trim="FFF5B8EC", light="FFFFC2EC", glow="FFFF9BE2",
                face="FF2B0A27", eye="FFFFE0F8", mouth="FFFFE0F8",
                shape=(136, 104, 40), plate=(104, 66, 28, 4), eyes="oval", eye_y=-2, mouth_y=27,
                ears=None, top=None, extras=[], acc="cat", by=122),
    "ninja": dict(head="FF4F5BBF", trim="FFB7BEF5", light="FF6FD3FF", glow="FF6FD3FF",
                  face="FF0B0F26", eye="FFDDE3FF", mouth="FFB7BEF5",
                  shape=(140, 108, 34), plate=(122, 32, 16, 2), eyes="slim", eye_y=2, mouth_y=34,
                  ears=None, top=None, extras=[], acc="ninja", by=116),
    "bow": dict(head="FFFF8FAB", trim="FFFFD1DC", light="FFFFF0F5", glow="FFFFD1DC",
                face="FF2E0D16", eye="FFFFE3EA", mouth="FFFFE3EA",
                shape=(136, 104, 40), plate=(104, 66, 28, 4), eyes="oval", eye_y=0, mouth_y=26,
                ears="round", top=None, extras=[], acc="bow", by=120),
    "tophat": dict(head="FFF2E3C6", trim="FFC9B892", light="FF7FB8FF", glow="FF7FB8FF",
                   face="FF231C10", eye="FFFFF3DA", mouth="FFFFF3DA",
                   shape=(140, 104, 34), plate=(108, 66, 26, 4), eyes="oval", eye_y=0, mouth_y=26,
                   ears="rect", top=None, extras=[], acc="tophat", by=122),
    "chef": dict(head="FF5F6675", trim="FFB4BAC6", light="FF5AB0FF", glow="FF5AB0FF",
                 face="FF14171D", eye="FFE3E8F2", mouth="FFE3E8F2",
                 shape=(140, 104, 34), plate=(108, 66, 26, 4), eyes="oval", eye_y=0, mouth_y=26,
                 ears="rect", top=None, extras=[], acc="chef", by=126),
    "hood": dict(head="FFBFE3F0", trim="FFE8F6FB", light="FFF2D16B", glow="FFF2D16B",
                 face="FF0A1E26", eye="FFC8F2FF", mouth="FFC8F2FF",
                 shape=(128, 100, 36), plate=(100, 62, 26, 4), eyes="oval", eye_y=0, mouth_y=25,
                 ears=None, top=None, extras=[], acc="hood", by=108),
    "scarf": dict(head="FF6EC1FF", trim="FFC9E8FF", light="FFE3F3FF", glow="FF9FD6FF",
                  face="FF07192A", eye="FFD2ECFF", mouth="FFD2ECFF",
                  shape=(140, 100, 34), plate=(108, 64, 26, 2), eyes="oval", eye_y=-2, mouth_y=23,
                  ears="rect", top="ball", extras=[], acc="scarf", by=106),
    "mohawk": dict(head="FF8F9BAD", trim="FFD0D6E0", light="FFFF4FA3", glow="FFFF4FA3",
                   face="FF141820", eye="FFE6EBF2", mouth="FFE6EBF2",
                   shape=(136, 108, 30), plate=(106, 70, 24, 4), eyes="oval", eye_y=0, mouth_y=26,
                   ears="rect", top=None, extras=[], acc="mohawk", by=120),
    "captain": dict(head="FF8F9DFF", trim="FFD3DAFF", light="FFF0C94A", glow="FFF0C94A",
                    face="FF0E1236", eye="FFE0E5FF", mouth="FFE0E5FF",
                    shape=(140, 104, 34), plate=(108, 66, 26, 6), eyes="oval", eye_y=2, mouth_y=28,
                    ears="rect", top=None, extras=[], acc="captain", by=126),
    "flower": dict(head="FFC9A0F2", trim="FFEBD9FF", light="FFFFD84A", glow="FFFFD84A",
                   face="FF22103A", eye="FFF3E8FF", mouth="FFF3E8FF",
                   shape=(140, 108, 40), plate=(108, 70, 30, 4), eyes="oval", eye_y=0, mouth_y=26,
                   ears="round", top=None, extras=[], acc="flower", by=122),
    "bunny": dict(head="FFFFC4A3", trim="FFFFE6D8", light="FFFF8FA8", glow="FFFFB3C6",
                  face="FF2E1A12", eye="FFFFEDE2", mouth="FFFFEDE2",
                  shape=(136, 100, 40), plate=(104, 62, 28, 6), eyes="oval", eye_y=2, mouth_y=26,
                  ears=None, top=None, extras=[], acc="bunny", by=124),
    "classic": dict(head="FFC0703F", trim="FFF0B48C", light="FFFFD9BD", glow="FFF0B48C",
                    face="FF22120A", eye="FFFFE3CF", mouth="FFFFE3CF",
                    shape=(140, 104, 8), plate=(104, 62, 6, 4), eyes="square", eye_y=0, mouth_y=25,
                    ears="rect", top="square", extras=[], acc="rivets", by=124),
}

# Each style's full body on the Robot artboard: (locomotion, body shape, size, arms).
#   locomotion: biped stubby stilts spider unicycle wheels2 wheels4 tracks drone pogo jet snake
#   shape: box barrel egg round triangle    size: small squat medium tall    arms: mitts claws noodle none
BODIES = {
    "default":      ("biped",    "box",      "medium", "mitts"),
    "inbox":        ("wheels4",  "box",      "squat",  "claws"),
    "researcher":   ("spider",   "round",    "medium", "noodle"),
    "coder":        ("tracks",   "box",      "medium", "claws"),
    "checker":      ("wheels2",  "box",      "tall",   "mitts"),
    "blogger":      ("unicycle", "egg",      "tall",   "noodle"),
    "orchestrator": ("jet",      "triangle", "medium", "mitts"),
    "pa":           ("stubby",   "barrel",   "squat",  "mitts"),
    "headphones":   ("biped",    "round",    "small",  "noodle"),
    "fox":          ("pogo",     "egg",      "small",  "mitts"),
    "owl":          ("stubby",   "egg",      "squat",  "none"),
    "sprout":       ("snake",    "round",    "small",  "none"),
    "bolt":         ("drone",    "round",    "small",  "none"),
    "nurse":        ("drone",    "box",      "medium", "mitts"),
    "astronaut":    ("jet",      "barrel",   "medium", "mitts"),
    "detective":    ("wheels2",  "barrel",   "tall",   "noodle"),
    "pirate":       ("tracks",   "barrel",   "medium", "claws"),
    "wizard":       ("stilts",   "triangle", "tall",   "noodle"),
    "cat":          ("spider",   "egg",      "small",  "none"),
    "ninja":        ("biped",    "triangle", "tall",   "noodle"),
    "bow":          ("drone",    "egg",      "small",  "none"),
    "tophat":       ("stilts",   "box",      "tall",   "mitts"),
    "chef":         ("unicycle", "barrel",   "medium", "mitts"),
    "hood":         ("jet",      "egg",      "medium", "none"),
    "scarf":        ("snake",    "round",    "small",  "mitts"),
    "mohawk":       ("pogo",     "box",      "squat",  "claws"),
    "captain":      ("tracks",   "box",      "squat",  "mitts"),
    "flower":       ("stilts",   "egg",      "medium", "noodle"),
    "bunny":        ("pogo",     "round",    "small",  "mitts"),
    "classic":      ("wheels4",  "box",      "medium", "claws"),
}
for _name, _b in BODIES.items():
    STYLES[_name]["body"] = dict(zip(("loco", "shape", "size", "arms"), _b))

args = sys.argv[1:]
if args == ["--list"]:   # the style names, one per line (styles.txt)
    print("\n".join(STYLES)); sys.exit()
if args and args[0].lstrip("-").isdigit():   # legacy form: gen.py <state>
    args = ["default"] + args
style_name = args[0] if args else "default"
state_default = args[1] if len(args) > 1 else "0"
if style_name not in STYLES:
    sys.exit(f"unknown style {style_name!r}; one of: {', '.join(STYLES)}")
S = STYLES[style_name]
TAU = 6.2831853

def mix(a, b, t):
    """Blend two ARGB hex colours."""
    ca = [int(a[i:i + 2], 16) for i in (2, 4, 6)]
    cb = [int(b[i:i + 2], 16) for i in (2, 4, 6)]
    return "FF" + "".join(f"{round(x + (y - x) * t):02X}" for x, y in zip(ca, cb))

SOOT = {k: mix(S[k], "FF2A2A2E", 0.5) for k in ("head", "trim")}   # singed, after state 5

# colour roles: every SolidColor in a role is keyed together by the animations.
# Each artboard has its own set; CID is the id client of the artboard being built.
ROLES = {}
_next = [100]
CID = "0"

def new_roles(cid):
    global ROLES, CID
    ROLES = {"head": [], "trim": [], "light": [], "glow": []}
    CID = cid
    _next[0] = 100
    return ROLES

def paint(role_or_color):
    """A SolidColor; a role name registers it so animations can key it."""
    if role_or_color in ROLES:
        _next[0] += 1
        cid = f"{CID}:{_next[0]}"
        ROLES[role_or_color].append(cid)
        return f'<SolidColor colorValue="{S[role_or_color]}" name="Color" id="{cid}"/>'
    return f'<SolidColor colorValue="{role_or_color}" name="Color"/>'

def fill(c):
    return f'<Fill name="Fill">{paint(c)}</Fill>'

def stroke(c, t, extra=""):
    return f'<Stroke thickness="{t}" cap="round" join="round" name="Stroke">{paint(c)}{extra}</Stroke>'

def shape(name, geom, paints, x=0, y=0, extra="", id_=None):
    i = f' id="{id_}"' if id_ else ""
    return f'<Shape x="{x}" y="{y}" {extra}name="{name}"{i}>\n{geom}\n{paints}\n</Shape>'

def node(name, children, x=0, y=0, extra="", id_=None):
    i = f' id="{id_}"' if id_ else ""
    body = "\n".join(c for c in children if c)
    return f'<Node x="{x}" y="{y}" {extra}name="{name}"{i}>\n{body}\n</Node>'

def rect(w, h, r, x=0, y=0, name="Path"):
    return f'<Rectangle x="{x}" y="{y}" width="{w}" height="{h}" cornerRadiusTL="{r}" name="{name}"/>'

def ell(w, h, x=0, y=0, name="Path"):
    return f'<Ellipse x="{x}" y="{y}" width="{w}" height="{h}" name="{name}"/>'

def star(w, points, inner, x=0, y=0, name="Path"):
    return f'<Star x="{x}" y="{y}" width="{w}" height="{w}" points="{points}" innerRadius="{inner}" name="{name}"/>'

def path(pts, closed=False, x=0, y=0, name="Path", radius=None):
    vs = "".join(f'<StraightVertex x="{px}" y="{py}"' + (f' radius="{radius}"' if radius and 0 < k < len(pts) - 1 else "") + "/>"
                 for k, (px, py) in enumerate(pts))
    return f'<PointsPath x="{x}" y="{y}" isClosed="{"true" if closed else "false"}" name="{name}">{vs}</PointsPath>'

def spiral(r0, r1, turns, n):
    pts = []
    for k in range(n + 1):
        t = k / n
        a, r = t * turns * TAU, r0 + (r1 - r0) * t
        pts.append((round(r * math.cos(a), 2), round(r * math.sin(a), 2)))
    return pts

hw, hh, hr = S["shape"]
pw, ph, pr, py = S["plate"]
ey = S["eye_y"]
top_y = -hh / 2   # head top, relative to the head's centre

# --- accessories for the library styles (S["acc"]) ---
# Each returns parts: over (on top of everything), front (on the head, under the
# face), back (behind the head), eyes (moves with the eyes), glow (x, y, w, h of
# the halo when the style has no antenna). "GLOW" in a list places the halo there.
def rect4(w, h, tl, tr, br, bl, x=0, y=0, name="Path"):
    return (f'<Rectangle x="{x}" y="{y}" width="{w}" height="{h}" linkCornerRadius="false" cornerRadiusTL="{tl}" '
            f'cornerRadiusTR="{tr}" cornerRadiusBR="{br}" cornerRadiusBL="{bl}" name="{name}"/>')

def rot_ell(w, h, x, y, r, name="Path"):
    return f'<Ellipse x="{x}" y="{y}" width="{w}" height="{h}" rotation="{r}" name="{name}"/>'

def accessory(kind, T):
    P = dict(over=[], front=[], back=[], eyes="", glow=None)
    hw2 = S["shape"][0] / 2
    if kind == "headphones":
        P["back"] = [shape("Band LED", ell(14, 14), fill("light"), 0, T - 17), "GLOW",
                     shape("Band", path([(-79, 4), (-79, T - 12), (79, T - 12), (79, 4)], radius=44), stroke("trim", 9))]
        P["front"] = [shape("Cups", rect(22, 48, 11, -79, 4, "Cup L") + rect(22, 48, 11, 79, 4, "Cup R"),
                            fill("FF2E3340") + stroke("trim", 4))]
        P["glow"] = (0, T - 17, 30, 30)
    elif kind in ("fox", "cat", "bunny"):
        P["over"] = [shape("Nose", ell(14, 10), fill("light"), 0, 14), "GLOW"]
        P["glow"] = (0, 14, 26, 22)
        if kind == "fox":
            P["back"] = [shape("Inner Ears", path([(-58, T + 6), (-52, T - 22), (-34, T + 2)], True, name="L", radius=3) +
                               path([(58, T + 6), (52, T - 22), (34, T + 2)], True, name="R", radius=3), fill("FF5A2A0E")),
                         shape("Ears", path([(-68, T + 14), (-56, T - 36), (-22, T + 2)], True, name="L", radius=5) +
                               path([(68, T + 14), (56, T - 36), (22, T + 2)], True, name="R", radius=5), fill("head"))]
        elif kind == "cat":
            P["back"] = [shape("Ears", path([(-62, T + 12), (-50, T - 26), (-26, T + 2)], True, name="L", radius=6) +
                               path([(62, T + 12), (50, T - 26), (26, T + 2)], True, name="R", radius=6), fill("head"))]
            whisk = "".join(path([(sx * 50, y0), (sx * 92, y1)], name=f"W{k}") for k, (sx, y0, y1) in enumerate(
                [(-1, 10, 4), (-1, 16, 18), (1, 10, 4), (1, 16, 18)]))
            P["over"] += [shape("Whiskers", whisk, stroke("trim", 3))]
        else:
            P["back"] = [shape("Inner Ears", rot_ell(10, 44, -24, T - 22, -0.15, "L") + rot_ell(10, 44, 24, T - 22, 0.15, "R"),
                               fill("FFFF8FA8")),
                         shape("Ears", rot_ell(24, 62, -24, T - 22, -0.15, "L") + rot_ell(24, 62, 24, T - 22, 0.15, "R"),
                               fill("head"))]
    elif kind == "owl":
        P["eyes"] = shape("Discs", ell(40, 40, -24, 0, "L") + ell(40, 40, 24, 0, "R"), fill("FFF3DDB5"), 0, S["eye_y"])
        P["over"] = [shape("Beak", path([(-8, 0), (8, 0), (0, 12)], True, radius=2), fill("light"), 0, 13), "GLOW"]
        P["back"] = [shape("Tufts", path([(-68, T + 12), (-78, T - 24), (-36, T + 2)], True, name="L", radius=4) +
                           path([(68, T + 12), (78, T - 24), (36, T + 2)], True, name="R", radius=4), fill("head"))]
        P["glow"] = (0, 18, 24, 24)
    elif kind == "sprout":
        P["back"] = [shape("Leaf L", rot_ell(28, 13, 0, 0, -0.5), fill("light"), -13, T - 24),
                     shape("Leaf R", rot_ell(28, 13, 0, 0, 0.5), fill("light"), 13, T - 28), "GLOW",
                     shape("Stalk", rect(5, 26, 2.5), fill("FF4E6B1E"), 0, T - 10)]
        P["glow"] = (0, T - 26, 46, 34)
    elif kind == "bolt":
        P["back"] = [shape("Bolt", path([(5, -22), (-10, 2), (0, 2), (-5, 22), (11, -4), (1, -4)], True, radius=1),
                           fill("light"), 0, T - 30), "GLOW",
                     shape("Stalk", rect(5, 16, 2.5), fill("trim"), 0, T - 6)]
        P["glow"] = (0, T - 30, 26, 34)
    elif kind == "nurse":
        P["front"] = [shape("Cross", rect(18, 6, 1.5, name="H") + rect(6, 18, 1.5, name="V"), fill("light"), 0, T - 9), "GLOW",
                      shape("Cap", path([(-36, T + 8), (-28, T - 24), (28, T - 24), (36, T + 8)], True, radius=5),
                            fill("FFF7FBFF"))]
        P["glow"] = (0, T - 9, 28, 28)
    elif kind == "helmet":
        P["back"] = [shape("Helmet", ell(176, 166), fill("2E9BE9FF") + stroke("FFDDF6FF", 5), 0, -8, 'opacity="0.9" ')]
    elif kind == "fedora":
        P["front"] = [shape("Brim", ell(150, 16), fill("FF5B4636"), 0, T + 2),
                      shape("Hat Band", rect(92, 8, 0), fill("light"), 0, T - 5), "GLOW",
                      shape("Crown", rect4(92, 34, 14, 14, 2, 2), fill("FF7A5F48"), 0, T - 14)]
        P["glow"] = (0, T - 5, 84, 12)
    elif kind == "pirate":
        P["eyes"] = shape("Patch", ell(30, 30), fill("FF17808A"), 24, S["eye_y"])
        P["over"] = [shape("Strap", path([(4, T + 30), (24, S["eye_y"]), (hw2 - 4, S["eye_y"] + 18)]), stroke("FF17808A", 3))]
        P["front"] = [shape("Skull", ell(11, 11), fill("light"), -22, T + 14), "GLOW",
                      shape("Bandana", rect4(S["shape"][0], 30, S["shape"][2], S["shape"][2], 4, 4), fill("FF17808A"), 0, T + 15),
                      shape("Knot", path([(0, 0), (22, -12), (18, 10)], True, radius=3) + path([(0, 4), (16, 22), (4, 22)], True, name="T2", radius=3),
                            fill("FF17808A"), hw2 - 4, T + 16)]
        P["glow"] = (-22, T + 14, 24, 24)
    elif kind == "wizard":
        P["front"] = [shape("Star", '<Star width="20" height="20" points="5" innerRadius="0.45" name="Path"/>', fill("light"), -2, T - 16), "GLOW",
                      shape("Brim", ell(124, 16), fill("FF5650C8"), 0, T + 4),
                      shape("Cone", path([(-44, 6), (4, -52), (44, 6)], True, radius=6), fill("FF433DA6"), 0, T)]
        P["glow"] = (-2, T - 16, 30, 30)
    elif kind == "ninja":
        P["front"] = [shape("Emblem", ell(12, 12), fill("light"), 0, T + 16), "GLOW",
                      shape("Headband", rect(S["shape"][0], 14, 0), fill("FFE6ECFF"), 0, T + 16)]
        P["back"] = [shape("Tails", path([(66, T + 16), (92, T + 4)], name="T1") + path([(66, T + 16), (90, T + 26)], name="T2"),
                           stroke("FFE6ECFF", 6))]
        P["glow"] = (0, T + 16, 24, 24)
    elif kind == "bow":
        P["front"] = [shape("Knot", ell(13, 13), fill("light"), 36, T - 4), "GLOW",
                      shape("Bow", path([(-3, 0), (-30, -17), (-30, 17)], True, name="L", radius=5) +
                            path([(3, 0), (30, -17), (30, 17)], True, name="R", radius=5), fill("FF5B4BDB"), 36, T - 4, 'rotation="0.3" ')]
        P["glow"] = (36, T - 4, 26, 26)
    elif kind == "tophat":
        P["front"] = [shape("Hat Band", rect(70, 9, 0), fill("light"), 0, T - 9), "GLOW",
                      shape("Brim", rect(106, 10, 5), fill("FF34384A") + stroke("FF6B7290", 3), 0, T - 2),
                      shape("Crown", rect(70, 50, 5), fill("FF34384A") + stroke("FF6B7290", 3), 0, T - 26)]
        P["glow"] = (0, T - 9, 66, 13)
    elif kind == "chef":
        P["front"] = [shape("Badge", ell(11, 11), fill("light"), 0, T - 8), "GLOW",
                      shape("Toque", ell(40, 40, -24, -18, "L") + ell(44, 44, 0, -26, "M") + ell(40, 40, 24, -18, "R") +
                            rect(74, 22, 4, 0, 0, "Band"), fill("FFF8F9FB"), 0, T - 6)]
        P["glow"] = (0, T - 8, 24, 24)
    elif kind == "hood":
        P["back"] = [shape("Clasp", ell(14, 14), fill("light"), 0, S["shape"][1] / 2 + 6), "GLOW",
                     shape("Hood", rect(170, S["shape"][1] + 36, 62), fill("FF2F7A55"), 0, -6)]
        P["glow"] = (0, S["shape"][1] / 2 + 6, 28, 28)
    elif kind == "scarf":
        b = S["shape"][1] / 2
        P["front"] = [shape("Scarf", rect(124, 18, 9, 0, b + 2, "Wrap") + rect(18, 30, 8, 34, b + 16, "Tail"), fill("FFFF7F66"))]
    elif kind == "mohawk":
        crest = [(-34, 6), (-28, -14), (-16, 0), (-8, -26), (4, -2), (14, -24), (24, 0), (34, -12), (38, 6)]
        P["back"] = [shape("Crest", path(crest, True, radius=2), fill("light"), 0, T), "GLOW"]
        P["glow"] = (0, T - 6, 56, 18)
    elif kind == "captain":
        P["front"] = [shape("Badge", ell(14, 14), fill("light"), 0, T - 12), "GLOW",
                      shape("Visor", ell(112, 14), fill("FF1C2030"), 0, T + 4),
                      shape("Cap Band", rect(118, 8, 0), fill("FF26305C"), 0, T - 1),
                      shape("Cap", rect(118, 26, 10, 0, -8, "Base") + ell(134, 30, 0, -20, "Top"), fill("FFF4F6FB"), 0, T)]
        P["glow"] = (0, T - 12, 28, 28)
    elif kind == "flower":
        petals = "".join(rot_ell(12, 22, 13 * __import__("math").sin(a), -13 * __import__("math").cos(a), a, f"P{k}")
                         for k, a in enumerate(i * 1.0471976 for i in range(6)))
        P["front"] = [shape("Centre", ell(14, 14), fill("light"), -38, T - 6), "GLOW",
                      shape("Petals", petals, fill("FFFFFFFF"), -38, T - 6)]
        P["glow"] = (-38, T - 6, 26, 26)
    elif kind == "rivets":
        w2, h2 = S["shape"][0] / 2 - 10, S["shape"][1] / 2 - 10
        P["front"] = [shape("Rivets", "".join(ell(7, 7, sx * w2, sy * h2, f"R{k}") for k, (sx, sy) in
                                              enumerate([(-1, -1), (1, -1), (-1, 1), (1, 1)])), fill("FF7A3E1C"))]
    return P


def build_head(cid):
    """The head as a list of RML elements (first on top), its fixed ids under client `cid`:
    :30 scan bar, :32 mouth, :34 eyes, :35/:37 eye L/R, :47 glow, :51 happy eyes,
    :52 dizzy eyes (:53/:54 spirals), :55 wide eyes (poke only), :57 soot."""
    I = lambda n: f"{cid}:{n}"
    eye_geom = {"oval": ell(20, 26), "small": ell(16, 20), "square": rect(18, 18, 3),
                "round": ell(20, 20), "slim": ell(22, 12)}[S["eyes"]]
    eyes_extra = ""
    if "glasses" in S["extras"]:   # round glasses move with the eyes
        eyes_extra = shape("Glasses", ell(36, 36, -24, 0, "Lens L") + ell(36, 36, 24, 0, "Lens R"),
                           stroke("FFE6FFFB", 5), 0, ey) + "\n" + shape("Bridge", rect(14, 5, 2.5), fill("FFE6FFFB"), 0, ey - 3)
    ACC = accessory(S.get("acc"), top_y)
    eyes_extra += ACC["eyes"]
    happy = "".join(path([(-10, 4), (0, -6), (10, 4)], x=sx, name=f"Happy {n}", radius=5) for sx, n in ((-24, "L"), (24, "R")))
    eye_c = S.get("happy", S["eye"])
    wide = node("Wide Eyes", [
        shape("Pupils", ell(11, 11, -24, ey + 1, "L") + ell(11, 11, 24, ey + 1, "R"), fill("FF10131A")),
        shape("Whites", ell(30, 32, -24, ey, "L") + ell(30, 32, 24, ey, "R"), fill("FFFFFFFF"))], extra='opacity="0" ', id_=I(55))
    dizzy = node("Dizzy Eyes", [
        shape("Spiral L", path(spiral(1.5, 11, 1.75, 14)), stroke(eye_c, 3.5), -24, ey, id_=I(53)),
        shape("Spiral R", path(spiral(1.5, 11, 1.75, 14)), stroke(eye_c, 3.5), 24, ey, id_=I(54))], extra='opacity="0" ', id_=I(52))

    art = [
        shape("ScanBar", rect(8, ph - 16, 4), fill(S["eye"]), 0, py, 'opacity="0" ', I(30)),
        shape("Mouth", rect(22, 5, 2.5), fill(S["mouth"]), 0, S["mouth_y"], 'opacity="0.7" ', I(32)),
        shape("Happy Eyes", happy, stroke(eye_c, 6), 0, ey, 'opacity="0" ', I(51)),
        f'''<Node name="Eyes" id="{I(34)}">
{wide}
{dizzy}
{eyes_extra}
{shape("Eye L", eye_geom, fill(S["eye"]), -24, ey, id_=I(35))}
{shape("Eye R", eye_geom, fill(S["eye"]), 24, ey, id_=I(37))}
</Node>''',
        shape("Face", rect(pw, ph, pr), fill(S["face"]), 0, py),
    ]
    art = ACC["over"] + art + ACC["front"]
    if "flap" in S["extras"]:   # envelope flap: a V folded over the forehead (drawn on the head)
        art.append(shape("Flap", path([(-hw / 2 + 8, top_y + 6), (0, py - ph / 2 - 3), (hw / 2 - 8, top_y + 6)], radius=6),
                         stroke("trim", 6)))
    if "beret" in S["extras"]:  # in front of the head
        art.append(shape("Beret", ell(128, 36), fill("FF9A2459"), -12, top_y - 4, 'rotation="-0.17" '))
    art.append(shape("Soot", ell(34, 18, -hw / 2 + 26, top_y + 14, "A") + ell(24, 14, hw / 2 - 22, top_y + 18, "B") +
                     ell(30, 12, hw / 2 - 30, hh / 2 - 10, "C") + ell(14, 10, -hw / 2 + 16, hh / 2 - 16, "D"),
                     fill("FF1B1B1F"), 0, 0, 'opacity="0" ', I(57)))
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
    stem = None
    if top is None:   # the accessory carries the light
        gx, gy, gw, gh = ACC["glow"] or (0, 0, 1, 1)
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
    elif top == "crown":   # three points; the centre jewel is the light, no stem
        gx, gy, gw, gh = 0, top_y - 15, 26, 26
        crown = [(-34, 3), (-34, -27), (-17, -10), (0, -36), (17, -10), (34, -27), (34, 3)]
        art += [shape("Crown Jewel", ell(14, 14), fill("light"), gx, gy)]
    glow = shape("Antenna Glow", ell(gw, gh), fill("glow"), gx, gy, 'opacity="0.35" ', I(47))
    if "GLOW" not in art + ACC["back"]:
        art.append(glow)
    if top == "crown":   # the halo sits on the crown, not behind it
        art.append(shape("Crown", path(crown, True, radius=3), fill("trim"), 0, top_y))
    if stem:
        art.append(stem)
    return [glow if a == "GLOW" else a for a in art + ACC["back"]]


# --- keyframes ---
EASE = {"id": None, "made": False}   # one shared ease-in-out curve per artboard

def ease_for(iid):
    EASE.update(id=iid, made=False)

def kfs(keys, is_color):
    out = []
    for k in keys:
        f, v = k[0], k[1]
        interp = k[2] if len(k) > 2 else "cubic"
        tag = "KeyFrameColor" if is_color else "KeyFrameDouble"
        if not is_color:
            v = round(v, 4)
        if interp == "cubic" and not EASE["made"]:
            EASE["made"] = True
            out.append(f'<{tag} value="{v}" frame="{f}" interpolationType="cubic"><CubicEaseInterpolator x1="0.42" y1="0" x2="0.58" y2="1" id="{EASE['id']}"/></{tag}>')
        elif interp == "cubic":
            out.append(f'<{tag} value="{v}" frame="{f}" interpolationType="cubic" interpolatorId="{EASE['id']}"/>')
        else:
            out.append(f'<{tag} value="{v}" frame="{f}" interpolationType="{interp}"/>')
    return "\n".join(out)

def anim(id_, name, dur, loop, spec, tracks, rest, roles):
    """A timeline keying every track: the spec's keys, or a hold at the rest value."""
    unknown = set(spec) - set(tracks)
    assert not unknown, f"{name}: keys for untracked {unknown}"
    objs = {}
    for target, prop in tracks:
        keys = spec.get((target, prop), [(0, rest[(target, prop)], "hold")])
        is_color = target in roles
        for oid in (roles[target] if is_color else [target]):
            objs.setdefault(oid, []).append(f'<KeyedProperty property="{prop}">\n{kfs(keys, is_color)}\n</KeyedProperty>')
    body = "\n".join(f'<KeyedObject objectId="{o}">\n' + "\n".join(p) + "\n</KeyedObject>" for o, p in objs.items())
    return f'<LinearAnimation loopValue="{loop}" duration="{dur}" name="{name}" id="{id_}">\n{body}\n</LinearAnimation>'

def blink(start, rest=1):
    return [(0, rest, "hold"), (start, rest, "linear"), (start + 5, 0.1, "linear"), (start + 10, rest, "hold")]

def osc(rest, amp, period, dur, phase=0.0, steps=6):
    """A sine around `rest`, sampled `steps` times a period, linear between (seamless when period divides dur)."""
    n = max(1, round(dur / period * steps))
    return [(round(dur * k / n), rest + amp * math.sin(TAU * (dur * k / n / period + phase)), "linear") for k in range(n + 1)]

def turn(rest, turns, dur, start=0):
    return [(start, rest, "linear"), (dur, rest + turns * TAU, "linear")]

def shake(rest, amp, until, step=2):
    return [(f, rest + (amp if (f // step) % 2 == 0 else -amp), "linear") for f in range(0, until, step)] + [(until, rest, "linear")]

def flicker(a, b, until, step, then):
    return [(f, a if (f // step) % 2 == 0 else b, "hold") for f in range(0, until, step)] + [(until, then, "hold")]

def machine(c, state, hit, extra_layers=""):
    """State machine `Bot` (ids under client c): Number `state` 0-5 and Trigger `poke`.
    Layer State: Any State goes to 0-4 when `state` equals it; 5 is reached from each of
    0-4 (not from Any State, so its dizzy loop cannot restart the explosion), plays the
    failure once and then loops dizzy. Layer Poke: `poke` (or a tap) plays the reaction
    once over whatever the State layer is doing, then rests."""
    I = lambda n: f"{c}:{n}"
    to = "\n".join(f'<StateTransition stateToId="{I(70 + i)}" duration="200"><TransitionNumberCondition inputId="{I(9)}" opValue="equal" value="{i}"/></StateTransition>'
                   for i in range(5))
    fail = f'<StateTransition stateToId="{I(75)}" duration="100"><TransitionNumberCondition inputId="{I(9)}" opValue="equal" value="5"/></StateTransition>'
    states = "\n".join(f'<AnimationState x="{160 + 160 * i}" y="120" animationId="{I(60 + i)}" id="{I(70 + i)}">{fail}</AnimationState>' for i in range(5))
    return f'''<StateMachine name="Bot" id="{I(7)}">
<StateMachineNumber value="{state}" name="state" id="{I(9)}"/>
<StateMachineTrigger name="poke" id="{I(10)}"/>
<StateMachineListenerSingle targetId="{hit}" listenerTypeValue="down" name="Tap to poke"><ListenerTriggerChange inputId="{I(10)}"/></StateMachineListenerSingle>
<StateMachineLayer name="State" id="{I(8)}">
<AnyState x="480" y="-120">
{to}
</AnyState>
<ExitState x="800" y="-120"/>
<EntryState x="0" y="120"><StateTransition stateToId="{I(70)}"/></EntryState>
{states}
<AnimationState x="400" y="320" animationId="{I(65)}" id="{I(75)}"><StateTransition stateToId="{I(76)}" duration="0" enableExitTime="true" exitTimeIsPercetange="true" exitTime="100"/></AnimationState>
<AnimationState x="640" y="320" animationId="{I(66)}" id="{I(76)}"/>
</StateMachineLayer>
<StateMachineLayer name="Poke" id="{I(11)}">
<AnyState x="160" y="-120"><StateTransition stateToId="{I(78)}" duration="0"><TransitionTriggerCondition inputId="{I(10)}"/></StateTransition></AnyState>
<ExitState x="480" y="-120"/>
<EntryState x="0" y="120"><StateTransition stateToId="{I(77)}"/></EntryState>
<AnimationState x="160" y="120" animationId="{I(67)}" id="{I(77)}"/>
<AnimationState x="400" y="120" animationId="{I(68)}" id="{I(78)}"><StateTransition stateToId="{I(77)}" duration="0" enableExitTime="true" exitTimeIsPercetange="true" exitTime="100"/></AnimationState>
</StateMachineLayer>
{extra_layers}
</StateMachine>'''


# ===================== Avatar: the head alone, 200x200 =====================
BY = S["by"]
roles_a = new_roles("0")
head_a = build_head("0")
B0 = -hh / 2             # the head's y inside its poke wrapper, which sits at the head's bottom edge
SMOKE_Y = top_y - 6
smoke_a = node("Smoke", [shape("Puff", ell(44, 36, -24, 6, "A") + ell(54, 46, 0, -8, "B") + ell(44, 36, 24, 6, "C"), fill("FFB7BCC4")),
                         shape("Puff Shade", ell(40, 30, -10, 14, "A") + ell(40, 30, 16, 14, "B"), fill("FF8D939B"))],
               0, SMOKE_Y, 'opacity="0" ', "0:56")

TRACKS_A = [("0:20", "y"), ("0:20", "scaleX"), ("0:20", "scaleY"), ("0:20", "rotation"),
            ("0:34", "x"), ("0:34", "y"), ("0:35", "scaleY"), ("0:37", "scaleY"),
            ("0:32", "scaleX"), ("0:32", "opacity"), ("0:30", "x"), ("0:30", "opacity"),
            ("0:47", "opacity"), ("0:47", "scaleX"), ("0:47", "scaleY"), ("0:51", "opacity"),
            ("head", "colorValue"), ("trim", "colorValue"), ("light", "colorValue"), ("glow", "colorValue"),
            ("0:20", "x"), ("0:52", "opacity"), ("0:53", "rotation"), ("0:54", "rotation"), ("0:57", "opacity"),
            ("0:56", "opacity"), ("0:56", "scaleX"), ("0:56", "scaleY"), ("0:56", "y")]
REST_A = {("0:20", "y"): B0, ("0:20", "scaleX"): 1, ("0:20", "scaleY"): 1, ("0:20", "rotation"): 0,
          ("0:34", "x"): 0, ("0:34", "y"): 0, ("0:35", "scaleY"): 1, ("0:37", "scaleY"): 1,
          ("0:32", "scaleX"): 1, ("0:32", "opacity"): 0.7, ("0:30", "x"): 0, ("0:30", "opacity"): 0,
          ("0:47", "opacity"): 0.35, ("0:47", "scaleX"): 1, ("0:47", "scaleY"): 1, ("0:51", "opacity"): 0,
          ("head", "colorValue"): S["head"], ("trim", "colorValue"): S["trim"],
          ("light", "colorValue"): S["light"], ("glow", "colorValue"): S["glow"],
          ("0:20", "x"): 0, ("0:52", "opacity"): 0, ("0:53", "rotation"): 0, ("0:54", "rotation"): 0, ("0:57", "opacity"): 0,
          ("0:56", "opacity"): 0, ("0:56", "scaleX"): 1, ("0:56", "scaleY"): 1, ("0:56", "y"): SMOKE_Y}
POKE_A = [("0:21", "y"), ("0:21", "scaleX"), ("0:21", "scaleY"), ("0:21", "rotation"), ("0:55", "opacity")]
POKE_REST_A = {("0:21", "y"): BY + hh / 2, ("0:21", "scaleX"): 1, ("0:21", "scaleY"): 1, ("0:21", "rotation"): 0, ("0:55", "opacity"): 0}

ease_for("0:99")

def a_anim(id_, name, dur, loop, spec):
    return anim(id_, name, dur, loop, spec, TRACKS_A, REST_A, roles_a)

L = S["light"]
PY0 = BY + hh / 2
anims_a = [
    # 0 idle: 4s breathing, blink near the end
    a_anim("0:60", "Idle", 240, "loop", {
        ("0:20", "y"): [(0, B0), (120, B0 - 3), (240, B0)],
        ("0:20", "scaleX"): [(0, 1), (120, 1.03), (240, 1)],
        ("0:20", "scaleY"): [(0, 1), (120, 1.03), (240, 1)],
        ("0:35", "scaleY"): blink(200), ("0:37", "scaleY"): blink(200),
        ("0:47", "opacity"): [(0, 0.3), (120, 0.45), (240, 0.3)],
    }),
    # 1 thinking: eyes look up-left / up-right, light glows slowly
    a_anim("0:61", "Thinking", 180, "loop", {
        ("0:20", "y"): [(0, B0), (90, B0 - 2), (180, B0)],
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
    a_anim("0:62", "Working", 60, "loop", {
        ("0:20", "y"): [(0, B0), (15, B0 - 3), (30, B0), (45, B0 - 3), (60, B0)],
        ("0:35", "scaleY"): [(0, 0.35, "hold")], ("0:37", "scaleY"): [(0, 0.35, "hold")],
        ("0:34", "x"): [(0, -6), (30, 6), (60, -6)],
        ("0:30", "x"): [(0, -(pw / 2 - 10)), (30, pw / 2 - 10), (60, -(pw / 2 - 10))],
        ("0:30", "opacity"): [(0, 0.85, "hold")],
        ("light", "colorValue"): [(f, WHITE if f % 20 == 0 else L, "hold") for f in range(0, 60, 10)],
        ("0:47", "opacity"): [(f, 0.8 if f % 20 == 0 else 0.2, "hold") for f in range(0, 60, 10)],
        ("0:32", "opacity"): [(0, 0.35, "hold")],
    }),
    # 3 needs you: urgent colour, attention pulse, wiggle (same for every style)
    a_anim("0:63", "Waiting", 60, "loop", {
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
    a_anim("0:64", "Done", 54, "oneShot", {
        ("0:20", "y"): [(0, B0), (10, B0 - 12), (22, B0), (32, B0 - 5), (42, B0), (54, B0)],
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
    # 5 failed: shake and flash, pop, a puff of smoke, singed with dizzy eyes (then Dizzy loops)
    a_anim("0:65", "Failed", 72, "oneShot", {
        ("0:20", "x"): shake(0, 4, 30),
        ("0:20", "rotation"): [(0, 0), (8, 0.05), (16, -0.05), (24, 0.04), (30, 0)],
        ("0:20", "scaleX"): [(0, 1), (30, 1, "linear"), (33, 1.16), (42, 0.95), (50, 1)],
        ("0:20", "scaleY"): [(0, 1), (30, 1, "linear"), (33, 1.16), (42, 0.95), (50, 1)],
        ("head", "colorValue"): flicker(RED, S["head"], 30, 5, SOOT["head"]),
        ("trim", "colorValue"): [(0, RED_L, "hold"), (30, SOOT["trim"], "hold")],
        ("light", "colorValue"): [(0, AMBER, "hold"), (30, DEAD, "hold")],
        ("glow", "colorValue"): [(0, AMBER, "hold")],
        ("0:47", "opacity"): [(0, 0.8, "hold"), (30, 0, "hold")],
        ("0:35", "scaleY"): [(0, 1.3, "hold"), (30, 0, "hold")], ("0:37", "scaleY"): [(0, 1.3, "hold"), (30, 0, "hold")],
        ("0:52", "opacity"): [(0, 0, "hold"), (30, 1, "hold")],
        ("0:53", "rotation"): turn(0, 1, 72), ("0:54", "rotation"): turn(0, -1, 72),
        ("0:57", "opacity"): [(0, 0, "hold"), (30, 0.85, "hold")],
        ("0:56", "opacity"): [(0, 0, "hold"), (30, 0.95, "hold"), (44, 0.95), (72, 0)],
        ("0:56", "scaleX"): [(0, 0.4, "hold"), (30, 0.4), (72, 1.7)],
        ("0:56", "scaleY"): [(0, 0.4, "hold"), (30, 0.4), (72, 1.7)],
        ("0:56", "y"): [(0, SMOKE_Y, "hold"), (30, SMOKE_Y), (72, SMOKE_Y - 26)],
        ("0:32", "scaleX"): [(0, 0.5, "hold"), (30, 0.7, "hold")], ("0:32", "opacity"): [(0, 1, "hold")],
    }),
    # 5, after: singed and dizzy, swaying, until the state changes
    a_anim("0:66", "Dizzy", 120, "loop", {
        ("0:20", "rotation"): osc(0, 0.05, 120, 120),
        ("0:20", "x"): osc(0, 2, 120, 120, 0.25),
        ("head", "colorValue"): [(0, SOOT["head"], "hold")], ("trim", "colorValue"): [(0, SOOT["trim"], "hold")],
        ("light", "colorValue"): [(0, DEAD, "hold")], ("0:47", "opacity"): [(0, 0, "hold")],
        ("0:35", "scaleY"): [(0, 0, "hold")], ("0:37", "scaleY"): [(0, 0, "hold")],
        ("0:52", "opacity"): [(0, 1, "hold")],
        ("0:53", "rotation"): turn(0, 1, 120), ("0:54", "rotation"): turn(0, -1, 120),
        ("0:57", "opacity"): [(0, 0.85, "hold")],
        ("0:32", "scaleX"): osc(0.7, 0.15, 60, 120), ("0:32", "opacity"): [(0, 1, "hold")],
    }),
    anim("0:67", "Poke Rest", 1, "oneShot", {}, POKE_A, POKE_REST_A, roles_a),
    # poke: a quick boing with wide eyes
    anim("0:68", "Poke", 44, "oneShot", {
        ("0:21", "scaleY"): [(0, 1), (4, 0.74), (11, 1.2), (18, 0.92), (25, 1.05), (32, 1)],
        ("0:21", "scaleX"): [(0, 1), (4, 1.2), (11, 0.86), (18, 1.06), (25, 0.97), (32, 1)],
        ("0:21", "y"): [(0, PY0), (11, PY0 - 10), (22, PY0)],
        ("0:55", "opacity"): [(0, 0, "hold"), (3, 1, "hold"), (38, 0, "hold")],
    }, POKE_A, POKE_REST_A, roles_a),
]

avatar_xml = f'''<Artboard defaultStateMachineId="0:7" styleId="0:5" width="200" height="200" name="Avatar" id="0:2">
<LayoutComponentStyle name="Artboard Style" id="0:5"/>
<Node x="100" y="{PY0}" name="Poke" id="0:21">
<Node x="0" y="{B0}" name="Bot" id="0:20">
{smoke_a}
{chr(10).join(head_a)}
</Node>
</Node>
<Shape x="100" y="100" name="Hit" id="0:22">{rect(200, 200, 0)}<Fill name="Fill"><SolidColor colorValue="00000000" name="Clear"/></Fill></Shape>
{machine("0", state_default, "0:22")}
{chr(10).join(anims_a)}
</Artboard>'''


# ===================== Robot: the head on a full body, 200x260 =====================
# Ids: client 1 for the head, 2 for the body, effects and wrappers, 3 for the state
# machine and timelines. Robot space: origin on the ground under the bot, up is -y.
#
# Nodes, outermost first, and the layer that keys each:
#   Poke 2:5 (at the feet) > Roll 2:6 (at the body centre)   Poke layer: the poke reaction
#   > Blast 2:7                                               Blast layer: self-destruct shake, hop and crash
#   > Rig 2:2                                                 State layer: whole-body motion for states 0-5
#   inside Rig, each flying part has a Fly wrapper (Blast layer) around the node the
#   State layer moves, so the normal timelines never have to reset the explosion.
roles_r = new_roles("1")
head_r = build_head("1")
BODY = S["body"]
LOCO, BSHAPE, BSIZE, ARMS = BODY["loco"], BODY["shape"], BODY["size"], BODY["arms"]
W, H = {"small": (58, 46), "squat": (84, 44), "medium": (70, 58), "tall": (56, 78)}[BSIZE]
if BSHAPE == "round":
    H = round(W * 0.92)
HS = {"small": 0.56, "squat": 0.52, "medium": 0.5, "tall": 0.46}[BSIZE]    # head scale
LH = {"biped": 34, "stubby": 18, "stilts": 72, "spider": 30, "unicycle": 46, "wheels2": 23, "wheels4": 30,
      "tracks": 30, "drone": 50, "pogo": 46, "jet": 54, "snake": 10}[LOCO]
HOVER = LOCO in ("drone", "jet")
WHEELED = LOCO in ("unicycle", "wheels2", "wheels4", "tracks")
GROUND, XOFF = 246, (34 if LOCO == "snake" else 0)
HIP, TOP = -LH, -LH - H
HY = TOP - hh * HS / 2 + 8           # head centre
HTOP = HY - hh * HS / 2              # head top (accessories reach higher)
CY = -(LH + H / 2)                   # body centre: the barrel-roll pivot
BZ = -CY                             # Blast's y inside Roll, putting the rig's origin back on the ground
TRIM, TRIM_DARK, TYRE = S["trim"], mix(S["trim"], "FF1A1D24", 0.55), "FF2A2E38"

# --- body: Fly 2:16 at the hip > Body 2:11 (breathes) > shapes drawn upward ---
panel = [shape("Chest Light", ell(9, 9, 0, -H * 0.5), fill("light")),
         shape("Chest Panel", rect(round(W * 0.46), round(H * 0.34), 5, 0, -H * 0.5), fill(S["face"]))]
if BSHAPE == "box":
    body_geom = rect(W, H, 12, 0, -H / 2)
elif BSHAPE == "barrel":
    body_geom = rect(W, H, round(min(W, H) * 0.4), 0, -H / 2)
    panel.append(shape("Bands", rect(W - 6, 4, 2, 0, -H * 0.16, "Low") + rect(W - 6, 4, 2, 0, -H * 0.84, "High"), fill(TRIM)))
elif BSHAPE in ("egg", "round"):
    body_geom = ell(W, H, 0, -H / 2)
else:   # triangle: narrow shoulders, wide base
    body_geom = path([(-W * 0.3, -H), (W * 0.3, -H), (W / 2, 0), (-W / 2, 0)], True, radius=9)
body = node("Body Fly", [node("Body", panel + [shape("Shell", body_geom, fill("head"))], id_="2:11")], 0, HIP, id_="2:16")
SX = {"triangle": W * 0.3 + 2, "egg": W / 2 - 5, "round": W / 2 - 5}.get(BSHAPE, W / 2 - 2)
SHOULDER_Y = TOP + (16 if BSHAPE in ("egg", "round") else 12)

def arm(side):
    s = -1 if side == "L" else 1
    if ARMS == "mitts":
        kids = [shape("Mitt", ell(17, 17, 0, 29), fill(TRIM)), shape("Limb", rect(8, 28, 4, 0, 13), fill(TRIM_DARK))]
    elif ARMS == "claws":
        kids = [shape("Claw", path([(-8, 34), (0, 25), (8, 34)]), stroke(TRIM, 5)), shape("Limb", rect(8, 26, 4, 0, 12), fill(TRIM_DARK))]
    else:   # noodle
        kids = [shape("Hand", ell(10, 10, 3 * s, 32), fill(TRIM)),
                shape("Limb", path([(0, 0), (5 * s, 9), (-3 * s, 19), (3 * s, 30)], radius=7), stroke(TRIM, 5))]
    a_id, f_id = ("2:12", "2:14") if side == "L" else ("2:13", "2:15")
    return node(f"Arm {side} Fly", [node(f"Arm {side}", kids, extra=f'rotation="{-0.3 * s}" ', id_=a_id)], s * SX, SHOULDER_Y, id_=f_id)
arms = [arm("L"), arm("R")] if ARMS != "none" else []
AL, AR = ("2:12", "2:13") if arms else (None, None)

# --- locomotion parts: a Fly wrapper (id) at the part's pivot around a Move node (id + 50) ---
parts, extra_tracks = [], []   # extra_tracks: (id, prop, rest) the State layer keys besides Move nodes
def part(n, name, kids, x, y, fly, crook=0.0):
    fid, mid = f"2:{20 + n}", f"2:{70 + n}"
    parts.append(dict(id=fid, move=mid, x=x, y=y, fly=fly, crook=crook))
    return node(name, [node("Move", kids, id_=mid)], x, y, id_=fid)

def wheel(r):
    return [shape("Hub", ell(r * 0.5, r * 0.5), fill(TRIM)),
            shape("Spokes", rect(r * 2 - 8, 4, 2, name="A") + rect(4, r * 2 - 8, 2, name="B"), fill(TRIM_DARK)),
            shape("Tyre", ell(r * 2, r * 2), fill(TYRE) + stroke(TRIM, 3))]

R, loco_xml, spinners = 0, [], []      # spinners: Move ids of wheels and rollers
if LOCO in ("biped", "stubby", "stilts"):
    lw, fw, lx = {"biped": (10, 24, W * 0.22), "stubby": (16, 32, W * 0.26), "stilts": (5, 15, W * 0.18)}[LOCO]
    for n, s in ((0, -1), (1, 1)):
        kids = [shape("Foot", ell(fw, fw * 0.45, s * 2, LH - fw * 0.2), fill(TRIM)),
                shape("Leg", rect(lw, LH - 2, lw / 2, 0, (LH - 2) / 2), fill(TRIM_DARK))]
        if LOCO == "stilts":
            kids.insert(0, shape("Knee", ell(9, 9, 0, LH * 0.5), fill(TRIM)))
        loco_xml.append(part(n, "Leg L" if s < 0 else "Leg R", kids, s * lx, HIP, (s * 55, -30, s * 2.5), s * 0.12))
elif LOCO == "spider":
    for n, (s, reach) in enumerate(((-1, 1.0), (-1, 0.55), (1, 0.55), (1, 1.0))):
        pts = [(0, 0), (s * 30 * reach, -16 * reach), (s * (40 * reach + 6), LH - 6)]
        loco_xml.append(part(n, f"Leg {n}", [shape("Foot", ell(8, 8, pts[2][0], pts[2][1]), fill(TRIM)),
                                              shape("Leg", path(pts, radius=8), stroke(TRIM_DARK, 5))],
                             s * W * 0.22, HIP + 6, (s * (40 + 20 * reach), -36, s * 3), s * 0.1 * (2 - reach)))
elif LOCO == "unicycle":
    R = 20
    loco_xml.append(part(0, "Wheel", wheel(R), 0, -R, (0, 30, 4)))
    loco_xml.append(part(1, "Fork", [shape("Fork", rect(6, LH - R, 3, 0, (LH - R) / 2), fill(TRIM_DARK))], 0, HIP, (30, -30, 2), 0.1))
    spinners = ["2:70"]
elif LOCO == "wheels2":
    R = 17
    loco_xml.append(part(0, "Wheel L", wheel(R), -W / 2 - 3, -R, (-60, -30, -5)))
    loco_xml.append(part(1, "Wheel R", wheel(R), W / 2 + 3, -R, (60, -30, 5)))
    loco_xml.append(part(2, "Axle", [shape("Axle", rect(W + 6, 6, 3), fill(TRIM_DARK))], 0, -R, (0, 30, 0.8), 0.08))
    spinners = ["2:70", "2:71"]
elif LOCO == "wheels4":
    R = 11
    for n, x in enumerate([-W / 2 - 6, -W / 6 - 2, W / 6 + 2, W / 2 + 6]):
        loco_xml.append(part(n, f"Wheel {n}", wheel(R), x, -R, (x * 1.2, -40 + 10 * n, 4 if x > 0 else -4)))
    loco_xml.append(part(4, "Chassis", [shape("Chassis", rect(W + 30, 9, 4), fill(TRIM_DARK))], 0, -2 * R - 3, (0, -20, 0.6), 0.06))
    spinners = ["2:70", "2:71", "2:72", "2:73"]
elif LOCO == "tracks":
    tw = W + 22
    loco_xml.append(part(0, "Track", [shape("Belt", rect(tw, 26, 13), fill(TYRE) + stroke(
        TRIM, 4, '<DashPath offset="0" name="Treads" id="2:25"><Dash length="6" name="On"/><Dash length="6" name="Off"/></DashPath>'))],
        0, -13, (0, 26, 0.5), 0.06))
    for k, x in enumerate((-tw / 2 + 13, 0, tw / 2 - 13)):
        loco_xml.insert(0, part(k + 1, f"Roller {k}", [shape("Pin", rect(10, 3, 1.5), fill(TRIM)),
                                                        shape("Roller", ell(14, 14), fill(TRIM_DARK) + stroke(TRIM, 2))],
                                x, -13, (x * 1.6, -50, 4)))
    spinners = ["2:71", "2:72", "2:73"]
    extra_tracks.append(("2:25", "offset", 0))
elif LOCO == "drone":
    rx = W / 2 + 26
    for n, s in ((0, -1), (1, 1)):
        spin = f"2:{26 + n}"
        kids = [node("Tilt", [node("Spin", [shape("Blade", rect(54, 6, 3), fill(TRIM))], id_=spin),
                              shape("Blur", ell(58, 58), fill(TRIM), extra='opacity="0.22" ')], 0, -10, 'scaleY="0.24" '),
                shape("Hub", ell(10, 10, 0, -10), fill(TRIM_DARK)), shape("Post", rect(5, 10, 2, 0, -5), fill(TRIM_DARK)),
                shape("Strut", rect(26, 6, 3, -s * 13, 0), fill(TRIM_DARK))]
        loco_xml.append(part(n, "Rotor L" if s < 0 else "Rotor R", kids, s * rx, TOP + 14, (s * 50, -50, s * 4), s * 0.14))
        extra_tracks.append((spin, "rotation", 0))
elif LOCO == "pogo":
    loco_xml.append(part(0, "Pogo", [shape("Pad", rect(28, 6, 3, 0, LH - 3), fill(TRIM)),
                                     node("Spring", [shape("Coil", path([(0, 0), (-7, -3), (7, -6), (-7, -9), (7, -12), (-7, -15), (0, -18)], radius=2),
                                                           stroke(TRIM, 3))], 0, LH - 6, id_="2:24"),
                                     shape("Stick", rect(6, LH - 10, 3, 0, (LH - 10) / 2), fill(TRIM_DARK))], 0, HIP, (0, 40, 3), 0.1))
    extra_tracks.append(("2:24", "scaleY", 1))
elif LOCO == "jet":
    flame = node("Flame", [shape("Core", path([(-5, 0), (5, 0), (0, 18)], True, radius=4), fill("FFFFF1A8")),
                           shape("Fire", path([(-10, 0), (10, 0), (0, 30)], True, radius=8), fill("FFFF9F1C"))], 0, 14, id_="2:24")
    loco_xml.append(part(0, "Jet", [flame, shape("Nozzle", path([(-13, 0), (13, 0), (9, 15), (-9, 15)], True, radius=3), fill(TRIM_DARK)),
                                    shape("Ring", rect(30, 6, 3, 0, 1), fill(TRIM))], 0, HIP, (30, 40, 3), 0.12))
    extra_tracks += [("2:24", "scaleY", 1), ("2:24", "opacity", 1)]
elif LOCO == "snake":
    for k in range(4):
        sz = 28 - 4 * k
        loco_xml.append(part(k, f"Segment {k}", [shape("Spot", ell(sz * 0.4, sz * 0.3, 0, -sz * 0.1), fill(TRIM)),
                                                  shape("Segment", ell(sz + 4, sz), fill("head"))],
                             -W / 2 - 4 - k * 22, -sz / 2, (-30 - 15 * k, -40 - 10 * k, -3), 0.1 * (-1) ** k))

# --- effects (all start invisible) ---
THINK_Y = max(HTOP - 10, -GROUND + 26)
THINK_X = min(hw * HS / 2 + 10, 74 - XOFF)
boom = node("Boom", [shape("Flash", ell(46, 46), fill("FFFFFFFF")), shape("Burst", star(108, 12, 0.6), fill("FFFF8A1F")),
                     shape("Blast", star(160, 12, 0.62), fill("FFFFD23F"))], 0, CY, 'opacity="0" scaleX="0.2" scaleY="0.2" ', "2:40")
smoke = node("Smoke", [shape("Puff", ell(42, 36, -26, 4, "A") + ell(54, 46, 0, -10, "B") + ell(42, 36, 26, 4, "C") +
                             ell(36, 30, -12, 18, "D") + ell(36, 30, 14, 18, "E"), fill("FFB9BEC6")),
                       shape("Puff Shade", ell(40, 26, -8, 22, "A") + ell(34, 24, 18, 20, "B"), fill("FF8E949C"))],
             0, HY - 6, 'opacity="0" ', "2:41")
stars = node("Stars", [node("Orbit", [node("Spin", [shape(f"Star {k}", star(22, 5, 0.45), fill("FFFFE066"),
                                                         round(36 * math.cos(k * TAU / 3), 2), round(36 * math.sin(k * TAU / 3), 2))
                                                   for k in range(3)], id_="2:45")], extra='scaleY="0.32" ')],
             0, HTOP - 4, 'opacity="0" ', "2:42")
think = node("Think", [shape(f"Dot {k}", ell(6, 6, -9 + 9 * k, 0), fill("FF2A3140"), extra='opacity="0.25" ', id_=f"2:4{6 + k}") for k in range(3)] +
             [shape("Cloud", ell(44, 28, 0, 0, "A") + ell(22, 20, -14, -8, "B") + ell(24, 22, 10, -9, "C") +
                    ell(9, 9, -20, 20, "D") + ell(6, 6, -27, 28, "E"), fill("FFE8EEF6"))],
             THINK_X, THINK_Y, 'opacity="0" ', "2:43")
SWEAT_Y = HY - 8
sweat = node("Sweat", [shape("Drop", path([(0, -7), (5, 2), (0, 7), (-5, 2)], True, radius=4), fill("FF8FD3FF"))],
             -hw * HS / 2 + 2, SWEAT_Y, 'opacity="0" ', "2:44")
head_mount = node("Head Fly", [node("Head", [f'<Node name="Face" id="1:20">\n' + "\n".join(head_r) + "\n</Node>"],
                                    extra=f'scaleX="{HS}" scaleY="{HS}" ', id_="2:10")], 0, HY, id_="2:9")
rig_kids = [boom, smoke, stars, think, sweat, head_mount] + arms + [body] + loco_xml

# --- motion ---
RIG = "2:2"
def ry(v):   # rig y, relative to the ground (kept as a function in case the rig moves)
    return v

def loco_motion(dur, mode):
    """Keys for the locomotion at a pace: "slow", "idle" or "busy"."""
    m = {}
    mv = [q["move"] for q in parts]
    if LOCO in ("biped", "stubby", "stilts"):
        if mode != "busy":
            sp = 1 if mode == "idle" else 0.5
            m[(RIG, "x")] = osc(0, 2.5 * sp, dur, dur)
            m[(mv[0], "y")] = osc(0, -1.5 * sp, dur, dur)
            m[(mv[1], "y")] = osc(0, 1.5 * sp, dur, dur)
        else:   # march in place: each foot lifts once a cycle, half a cycle apart
            for i, ph in ((0, 0), (1, dur // 2)):
                ks = {0: (0, 0, "linear"), dur: (dur, 0, "linear")}
                for k in ((ph, 0, "linear"), (ph + dur // 4, -7), (ph + dur // 2, 0, "linear")):
                    ks[k[0]] = k
                m[(mv[i], "y")] = [ks[f] for f in sorted(ks)]
            m[(RIG, "y")] = [(f, ry(-1.5 if (f // (dur // 4)) % 2 else 0)) for f in range(0, dur + 1, dur // 4)]
    elif LOCO == "spider":
        per, amp = {"slow": (120, 0.05), "idle": (60, 0.07), "busy": (15, 0.22)}[mode]
        for i in range(4):
            m[(mv[i], "rotation")] = osc(0, amp, per, dur, 0.5 * (i % 2), steps=4)
    elif WHEELED:
        if mode != "busy":
            a = 0.45 if mode == "idle" else 0.25
            for q in spinners:
                m[(q, "rotation")] = osc(0, a, dur, dur)
            m[(RIG, "x")] = osc(0, (R or 7) * a * 0.9, dur, dur)
            if LOCO == "unicycle":
                m[(RIG, "rotation")] = osc(0, -0.05, dur, dur)
            if LOCO == "tracks":
                m[("2:25", "offset")] = osc(0, 6, dur, dur)
        else:
            for q in spinners:
                m[(q, "rotation")] = turn(0, 1, dur)
            if LOCO == "tracks":
                m[("2:25", "offset")] = [(0, 0, "linear"), (dur, -24, "linear")]
            m[(RIG, "y")] = [(0, ry(0)), (dur // 2, ry(-1.5)), (dur, ry(0))]
            if LOCO == "unicycle":
                m[(RIG, "rotation")] = [(0, 0.06, "hold")]
    elif LOCO == "drone":
        turns = {"slow": 4, "idle": 6, "busy": 7}[mode] * (2 if mode == "busy" and dur == 60 else 1)
        m[("2:26", "rotation")] = turn(0, turns, dur)
        m[("2:27", "rotation")] = turn(0, -turns, dur)
        m[(RIG, "y")] = [(0, ry(0)), (dur // 2, ry(-4 if mode != "busy" else -2.5)), (dur, ry(0))]
        if mode == "busy":
            m[(RIG, "rotation")] = [(0, 0.04), (dur // 2, -0.04), (dur, 0.04)]
    elif LOCO == "pogo":
        per, hgt = {"slow": (60, 5), "idle": (40, 9), "busy": (15, 14)}[mode]
        ys, sk = [], []
        for s in range(0, dur, per):
            ys += [(s, ry(0)), (s + per // 2, ry(-hgt)), (s + per - 1, ry(0), "linear")]
            sk += [(s, 0.65, "linear"), (s + max(2, per // 6), 1.05), (s + per - 2, 1, "linear")]
        m[(RIG, "y")] = ys + [(dur, ry(0))]
        m[("2:24", "scaleY")] = sk + [(dur, 0.65)]
    elif LOCO == "jet":
        step = 6 if mode != "busy" else 3
        big = 1.25 if mode == "busy" else 1.1
        m[("2:24", "scaleY")] = [(f, big if (f // step) % 2 == 0 else 0.8, "linear") for f in range(0, dur + 1, step)]
        m[(RIG, "y")] = [(0, ry(0)), (dur // 2, ry(-3 if mode != "busy" else -2)), (dur, ry(0))]
    elif LOCO == "snake":
        per, amp = {"slow": (120, 2), "idle": (60, 2.5), "busy": (30, 4)}[mode]
        for i in range(len(parts)):
            m[(mv[i], "y")] = osc(0, -amp, per, dur, -0.18 * (i + 1), steps=4)
    return m

# --- State layer timelines ---
idle = {("1:35", "scaleY"): blink(96), ("1:37", "scaleY"): blink(96),
        ("1:47", "opacity"): [(0, 0.3), (60, 0.45), (120, 0.3)], ("2:11", "scaleY"): [(0, 1), (60, 1.025), (120, 1)]}
idle.update(loco_motion(120, "idle"))
think_spec = {("2:10", "rotation"): [(0, 0), (20, 0.14), (60, 0.1), (100, 0.14), (120, 0)],
              ("1:34", "x"): [(0, 0), (20, 8), (100, 8), (120, 0)], ("1:34", "y"): [(0, 0), (20, -7), (100, -7), (120, 0)],
              ("2:43", "opacity"): [(0, 0), (14, 1), (106, 1), (120, 0)],
              ("light", "colorValue"): [(0, L), (60, WHITE), (120, L)], ("1:47", "opacity"): [(0, 0.2), (60, 0.75), (120, 0.2)],
              ("1:32", "scaleX"): [(0, 0.6, "hold")]}
for k in range(3):
    think_spec[(f"2:4{6 + k}", "opacity")] = [(0, 0.25, "hold"), (24 + 16 * k, 1, "hold"), (96, 0.25, "hold")]
think_spec.update(loco_motion(120, "slow"))
work = {("1:35", "scaleY"): [(0, 0.35, "hold")], ("1:37", "scaleY"): [(0, 0.35, "hold")],
        ("1:30", "x"): [(0, -(pw / 2 - 10)), (15, pw / 2 - 10), (30, -(pw / 2 - 10))], ("1:30", "opacity"): [(0, 0.85, "hold")],
        ("1:32", "opacity"): [(0, 0.35, "hold")],
        ("light", "colorValue"): [(0, WHITE, "hold"), (8, L, "hold"), (16, WHITE, "hold"), (24, L, "hold")],
        ("2:44", "y"): [(0, SWEAT_Y, "linear"), (30, SWEAT_Y + 14, "linear")], ("2:44", "opacity"): [(0, 0), (6, 1, "linear"), (22, 1), (30, 0)]}
work.update(loco_motion(30, "busy"))
need = {("head", "colorValue"): [(0, RED, "hold")], ("trim", "colorValue"): [(0, RED_L, "hold")],
        ("light", "colorValue"): [(0, AMBER), (8, WHITE), (30, AMBER)], ("glow", "colorValue"): [(0, AMBER, "hold")],
        ("1:47", "opacity"): [(0, 0.4), (8, 0.9), (30, 0.4)],
        ("1:35", "scaleY"): [(0, 1.15, "hold")], ("1:37", "scaleY"): [(0, 1.15, "hold")], ("1:32", "scaleX"): [(0, 0.5, "hold")],
        ("2:10", "rotation"): [(0, 0.08), (15, -0.08), (30, 0.08)]}
need.update({k: v for k, v in loco_motion(30, "busy").items() if k[0] != RIG})
JUMP = 10 if HOVER else 16
need[(RIG, "y")] = [(0, ry(0)), (12, ry(-JUMP)), (24, ry(0), "linear"), (30, ry(0))]
need[(RIG, "scaleY")] = [(0, 1), (24, 1, "linear"), (26, 1 if HOVER else 0.88), (30, 1)]
done = {(RIG, "y"): [(0, ry(0)), (8, ry(3)), (26, ry(-38)), (44, ry(0)), (50, ry(2)), (58, ry(0)), (100, ry(0))],
        (RIG, "scaleY"): [(0, 1), (8, 0.84), (14, 1.08), (40, 1), (46, 0.9), (54, 1), (100, 1)],
        (RIG, "scaleX"): [(0, 1, "linear"), (14, 1, "linear"), (19, 0, "linear"), (24, -1, "linear"), (29, 0, "linear"), (34, 1, "linear"), (100, 1, "linear")],
        (RIG, "rotation"): [(0, 0, "hold"), (56, 0), (66, 0.09), (76, -0.09), (86, 0.09), (96, -0.05), (100, 0)],
        ("1:35", "scaleY"): [(0, 1), (6, 0.05, "hold")], ("1:37", "scaleY"): [(0, 1), (6, 0.05, "hold")],
        ("1:51", "opacity"): [(0, 0, "hold"), (6, 1, "hold")],
        ("1:32", "scaleX"): [(0, 1), (10, 1.9), (100, 1.9)], ("1:32", "opacity"): [(0, 0.7), (10, 1), (100, 1)],
        ("light", "colorValue"): [(0, WHITE), (100, L)], ("1:47", "opacity"): [(0, 0.9), (100, 0.4)]}
if arms:
    idle[(AL, "rotation")] = [(0, 0.3), (60, 0.36), (120, 0.3)]
    idle[(AR, "rotation")] = [(0, -0.3), (60, -0.36), (120, -0.3)]
    think_spec[(AL, "rotation")] = [(0, 0.3), (30, 0.45), (60, 0.3), (90, 0.45), (120, 0.3)]
    think_spec[(AR, "rotation")] = [(0, -0.3), (20, 2.4), (60, 2.3), (100, 2.4), (120, -0.3)]
    work[(AL, "rotation")] = [(0, -0.2), (7, 1.0), (15, -0.2), (22, 1.0), (30, -0.2)]
    work[(AR, "rotation")] = [(0, -1.0), (7, 0.2), (15, -1.0), (22, 0.2), (30, -1.0)]
    need[(AL, "rotation")] = [(0, 2.2), (8, 2.85), (15, 2.2), (23, 2.85), (30, 2.2)]
    need[(AR, "rotation")] = [(0, -2.85), (8, -2.2), (15, -2.85), (23, -2.2), (30, -2.85)]
    done[(AL, "rotation")] = [(0, 0.3), (14, 2.6), (56, 2.5), (100, 2.2)]
    done[(AR, "rotation")] = [(0, -0.3), (14, -2.6), (56, -2.5), (100, -2.2)]
for k, v in loco_motion(60, "busy").items():
    if k[0] != RIG:
        done[k] = turn(0, 2, 60) if k[0] in spinners else v

# 5, State layer: colours flash then singe, eyes go wide then spiral (the Blast layer does the rest)
BOOM_AT, UP, DOWN, LAND, FAIL_LEN = 44, 74, 112, 132, 170
fail = {("head", "colorValue"): flicker(RED, S["head"], BOOM_AT, 6, SOOT["head"]),
        ("trim", "colorValue"): [(0, RED_L, "hold"), (BOOM_AT, SOOT["trim"], "hold")],
        ("light", "colorValue"): flicker(AMBER, WHITE, BOOM_AT, 6, DEAD),
        ("glow", "colorValue"): [(0, AMBER, "hold")], ("1:47", "opacity"): [(0, 0.8, "hold"), (BOOM_AT, 0, "hold")],
        ("1:35", "scaleY"): [(0, 1.3, "hold"), (BOOM_AT, 0, "hold")], ("1:37", "scaleY"): [(0, 1.3, "hold"), (BOOM_AT, 0, "hold")],
        ("1:32", "scaleX"): [(0, 0.5, "hold"), (BOOM_AT, 0.7, "hold")], ("1:32", "opacity"): [(0, 1, "hold")]}
dizzy = {("head", "colorValue"): [(0, SOOT["head"], "hold")], ("trim", "colorValue"): [(0, SOOT["trim"], "hold")],
         ("light", "colorValue"): [(0, DEAD, "hold")], ("glow", "colorValue"): [(0, AMBER, "hold")], ("1:47", "opacity"): [(0, 0, "hold")],
         ("1:35", "scaleY"): [(0, 0, "hold")], ("1:37", "scaleY"): [(0, 0, "hold")],
         ("1:32", "scaleX"): [(0, 0.7), (30, 0.85), (60, 0.55), (90, 0.85), (120, 0.7)], ("1:32", "opacity"): [(0, 1, "hold")],
         (RIG, "rotation"): [(0, 0), (30, 0.05), (90, -0.05), (120, 0)], ("2:10", "rotation"): [(0, 0), (60, 0.06), (120, 0)]}
if LOCO == "jet":
    fail[("2:24", "opacity")] = [(0, 1, "hold"), (BOOM_AT, 0, "hold")]
    dizzy[("2:24", "opacity")] = [(0, 0, "hold")]
if LOCO == "drone":   # spin up in panic, then sputter
    fail[("2:26", "rotation")] = [(0, 0, "linear"), (BOOM_AT, 9 * TAU), (DOWN, 10 * TAU)]
    fail[("2:27", "rotation")] = [(0, 0, "linear"), (BOOM_AT, -9 * TAU), (DOWN, -10 * TAU)]
    dizzy[("2:26", "rotation")] = [(0, 0, "linear"), (60, 0.6), (120, TAU, "linear")]
    dizzy[("2:27", "rotation")] = [(0, 0, "linear"), (60, -0.6), (120, -TAU, "linear")]

STATE_SPECS = [idle, think_spec, work, need, done, fail, dizzy]
TRACKS_R = sorted({k for sp in STATE_SPECS for k in sp} | {(i, p) for i, p, _ in extra_tracks}
                  | {(RIG, "x"), (RIG, "y"), (RIG, "rotation"), (RIG, "scaleX"), (RIG, "scaleY")},
                  key=lambda k: (k[0] in ROLES, k))
REST_R = {(RIG, "x"): 0, (RIG, "y"): ry(0), (RIG, "rotation"): 0, (RIG, "scaleX"): 1, (RIG, "scaleY"): 1,
          ("2:10", "rotation"): 0, ("2:11", "scaleY"): 1, ("2:43", "opacity"): 0,
          ("2:46", "opacity"): 0.25, ("2:47", "opacity"): 0.25, ("2:48", "opacity"): 0.25, ("2:44", "y"): SWEAT_Y, ("2:44", "opacity"): 0,
          ("1:34", "x"): 0, ("1:34", "y"): 0, ("1:35", "scaleY"): 1, ("1:37", "scaleY"): 1, ("1:32", "scaleX"): 1, ("1:32", "opacity"): 0.7,
          ("1:30", "x"): 0, ("1:30", "opacity"): 0, ("1:47", "opacity"): 0.35, ("1:51", "opacity"): 0,
          ("head", "colorValue"): S["head"], ("trim", "colorValue"): S["trim"], ("light", "colorValue"): S["light"], ("glow", "colorValue"): S["glow"],
          (AL, "rotation"): 0.3, (AR, "rotation"): -0.3}
REST_R.update({(i, p): r for i, p, r in extra_tracks})
for q in parts:
    REST_R.update({(q["move"], "x"): 0, (q["move"], "y"): 0, (q["move"], "rotation"): 0})

def r_anim(id_, name, dur, loop, spec):
    return anim(id_, name, dur, loop, spec, TRACKS_R, REST_R, roles_r)

# --- Blast layer: the explosion itself, on wrappers no other timeline touches ---
def flight(rest, fly, crook=0.0, bounce=0.0):
    return [(0, rest, "hold"), (BOOM_AT, rest), (UP, rest + fly), (DOWN, rest + crook), (LAND - 8, rest + crook + bounce), (LAND, rest + crook)]

DROP = (LH - 6) if HOVER else 0      # hover bots crash to the ground
HEAD_CROOK = (4, 3, 0.17)
blast = {("2:7", "x"): shake(0, 3.5, BOOM_AT),
         ("2:7", "y"): [(0, BZ, "hold"), (BOOM_AT, BZ), (54, BZ - 14), (DOWN, BZ + DROP), (LAND - 8, BZ + DROP - 5), (LAND, BZ + DROP)],
         ("2:7", "scaleY"): [(0, 1), (BOOM_AT - 6, 1.06), (BOOM_AT, 0.86), (52, 1.08), (60, 1), (DOWN, 1), (DOWN + 4, 0.86), (LAND, 1)],
         ("2:9", "x"): flight(0, 12, HEAD_CROOK[0]), ("2:9", "y"): flight(HY, -120, HEAD_CROOK[1], -10),
         ("2:9", "rotation"): flight(0, 2 * TAU + 0.6, HEAD_CROOK[2]),
         ("2:16", "y"): flight(HIP, -18, 0, -4), ("2:16", "rotation"): flight(0, -0.3, -0.04),
         ("1:52", "opacity"): [(0, 0, "hold"), (BOOM_AT, 1, "hold")],
         ("1:53", "rotation"): turn(0, 1, FAIL_LEN, 50), ("1:54", "rotation"): turn(0, -1, FAIL_LEN, 50),
         ("1:57", "opacity"): [(0, 0, "hold"), (BOOM_AT, 0.85, "hold")],
         ("2:40", "opacity"): [(0, 0, "hold"), (BOOM_AT, 1, "hold"), (70, 0, "hold")],
         ("2:40", "scaleX"): [(0, 0.2, "hold"), (BOOM_AT, 0.2, "linear"), (52, 1.3), (60, 1.4, "linear"), (70, 0.1)],
         ("2:40", "scaleY"): [(0, 0.2, "hold"), (BOOM_AT, 0.2, "linear"), (52, 1.3), (60, 1.4, "linear"), (70, 0.1)],
         ("2:41", "opacity"): [(0, 0, "hold"), (50, 0.95, "hold"), (80, 0.9), (118, 0)],
         ("2:41", "scaleX"): [(0, 0.6, "hold"), (50, 0.6), (118, 1.9)], ("2:41", "scaleY"): [(0, 0.6, "hold"), (50, 0.6), (118, 1.9)],
         ("2:41", "y"): [(0, HY - 6, "hold"), (50, HY - 6), (118, HY - 40)],
         ("2:42", "opacity"): [(0, 0, "hold"), (LAND - 8, 0), (LAND + 6, 1)], ("2:45", "rotation"): turn(0, 1, FAIL_LEN, 50)}
blast_dizzy = {("2:7", "y"): [(0, BZ + DROP, "hold")], ("2:9", "x"): [(0, HEAD_CROOK[0], "hold")], ("2:9", "y"): [(0, HY + HEAD_CROOK[1], "hold")],
               ("2:9", "rotation"): [(0, HEAD_CROOK[2], "hold")], ("2:16", "rotation"): [(0, -0.04, "hold")],
               ("1:52", "opacity"): [(0, 1, "hold")], ("1:53", "rotation"): turn(0, 1, 120), ("1:54", "rotation"): turn(0, -1, 120),
               ("1:57", "opacity"): [(0, 0.85, "hold")], ("2:42", "opacity"): [(0, 1, "hold")], ("2:45", "rotation"): turn(0, 1, 120)}
BLAST_REST = {("2:7", "x"): 0, ("2:7", "y"): BZ, ("2:7", "scaleY"): 1, ("2:9", "x"): 0, ("2:9", "y"): HY, ("2:9", "rotation"): 0,
              ("2:16", "y"): HIP, ("2:16", "rotation"): 0, ("1:52", "opacity"): 0, ("1:53", "rotation"): 0, ("1:54", "rotation"): 0,
              ("1:57", "opacity"): 0, ("2:40", "opacity"): 0, ("2:40", "scaleX"): 0.2, ("2:40", "scaleY"): 0.2,
              ("2:41", "opacity"): 0, ("2:41", "scaleX"): 0.6, ("2:41", "scaleY"): 0.6, ("2:41", "y"): HY - 6,
              ("2:42", "opacity"): 0, ("2:45", "rotation"): 0}
if arms:
    for f_id, s, crook in (("2:14", -1, (0, 4, 0.45)), ("2:15", 1, (0, 2, 0.18))):
        blast[(f_id, "x")] = flight(s * SX, s * 70, crook[0])
        blast[(f_id, "y")] = flight(SHOULDER_Y, -60, crook[1], -6)
        blast[(f_id, "rotation")] = flight(0, s * 4.5, crook[2])
        blast_dizzy[(f_id, "x")] = [(0, s * SX + crook[0], "hold")]
        blast_dizzy[(f_id, "y")] = [(0, SHOULDER_Y + crook[1], "hold")]
        blast_dizzy[(f_id, "rotation")] = [(0, crook[2], "hold")]
        BLAST_REST.update({(f_id, "x"): s * SX, (f_id, "y"): SHOULDER_Y, (f_id, "rotation"): 0})
for q in parts:
    dx, dy, dr = q["fly"]
    blast[(q["id"], "x")] = flight(q["x"], dx)
    blast[(q["id"], "y")] = flight(q["y"], dy, 0, -6)
    blast[(q["id"], "rotation")] = flight(0, dr, q["crook"])
    blast_dizzy[(q["id"], "rotation")] = [(0, q["crook"], "hold")]
    BLAST_REST.update({(q["id"], "x"): q["x"], (q["id"], "y"): q["y"], (q["id"], "rotation"): 0})
BLAST_TRACKS = list(BLAST_REST)

def b_anim(id_, name, dur, loop, spec):
    return anim(id_, name, dur, loop, spec, BLAST_TRACKS, BLAST_REST, roles_r)

# --- Poke layer: a reaction that fits the locomotion, about 1 s ---
PG = 100 + XOFF
POKE_R = [("2:5", "x"), ("2:5", "y"), ("2:5", "rotation"), ("2:5", "scaleX"), ("2:5", "scaleY"), ("2:6", "rotation"), ("1:55", "opacity")]
POKE_REST_R = {("2:5", "x"): PG, ("2:5", "y"): GROUND, ("2:5", "rotation"): 0, ("2:5", "scaleX"): 1, ("2:5", "scaleY"): 1,
               ("2:6", "rotation"): 0, ("1:55", "opacity"): 0}
if LOCO in ("biped", "stubby", "stilts", "spider", "pogo"):     # boing: squash, stretch, a little hop
    POKE_KIND = "boing"
    poke = {("2:5", "scaleY"): [(0, 1), (5, 0.7), (13, 1.28), (21, 0.9), (29, 1.06), (38, 1)],
            ("2:5", "scaleX"): [(0, 1), (5, 1.22), (13, 0.84), (21, 1.06), (29, 0.97), (38, 1)],
            ("2:5", "y"): [(0, GROUND), (6, GROUND), (16, GROUND - 22), (28, GROUND), (34, GROUND - 4), (40, GROUND)]}
elif WHEELED:                                                 # wheelie
    POKE_KIND = "wheelie"
    poke = {("2:5", "rotation"): [(0, 0), (8, -0.34), (20, -0.26), (30, -0.36), (44, 0), (50, 0.04), (56, 0)],
            ("2:5", "x"): [(0, PG), (8, PG - 8), (44, PG - 4), (56, PG)]}
elif HOVER:                                                   # barrel roll
    POKE_KIND = "barrel roll"
    poke = {("2:6", "rotation"): [(0, 0, "hold"), (4, 0), (40, TAU), (56, TAU)],
            ("2:5", "y"): [(0, GROUND), (20, GROUND - 16), (44, GROUND)]}
else:                                                         # snake: giggle wobble
    POKE_KIND = "giggle"
    poke = {("2:5", "rotation"): [(0, 0, "linear")] + [(f, 0.07 if (f // 4) % 2 == 0 else -0.07, "linear") for f in range(4, 48, 4)] + [(52, 0)],
            ("2:5", "scaleY"): [(0, 1), (6, 1.12), (14, 0.94), (22, 1.08), (30, 0.97), (40, 1)]}
poke[("1:55", "opacity")] = [(0, 0, "hold"), (3, 1, "hold"), (46, 0, "hold")]

ease_for("3:99")
anims_r = [r_anim("3:60", "Idle", 120, "loop", idle), r_anim("3:61", "Thinking", 120, "loop", think_spec),
           r_anim("3:62", "Working", 30, "loop", work), r_anim("3:63", "Waiting", 30, "loop", need),
           r_anim("3:64", "Done", 100, "oneShot", done), r_anim("3:65", "Failed", FAIL_LEN, "oneShot", fail),
           r_anim("3:66", "Dizzy", 120, "loop", dizzy),
           anim("3:67", "Poke Rest", 1, "oneShot", {}, POKE_R, POKE_REST_R, roles_r),
           anim("3:68", "Poke", 60, "oneShot", poke, POKE_R, POKE_REST_R, roles_r),
           b_anim("3:85", "Blast Rest", 1, "oneShot", {}), b_anim("3:86", "Blast", FAIL_LEN, "oneShot", blast),
           b_anim("3:87", "Blast Dizzy", 120, "loop", blast_dizzy)]

def cond(op):
    return f'<TransitionNumberCondition inputId="3:9" opValue="{op}" value="5"/>'
blast_layer = f'''<StateMachineLayer name="Blast" id="3:12">
<AnyState x="160" y="-120"/>
<ExitState x="480" y="-120"/>
<EntryState x="0" y="120"><StateTransition stateToId="3:81"/></EntryState>
<AnimationState x="160" y="120" animationId="3:85" id="3:81"><StateTransition stateToId="3:82" duration="0">{cond("equal")}</StateTransition></AnimationState>
<AnimationState x="400" y="120" animationId="3:86" id="3:82"><StateTransition stateToId="3:83" duration="0" enableExitTime="true" exitTimeIsPercetange="true" exitTime="100"/><StateTransition stateToId="3:81" duration="200">{cond("notEqual")}</StateTransition></AnimationState>
<AnimationState x="640" y="120" animationId="3:87" id="3:83"><StateTransition stateToId="3:81" duration="200">{cond("notEqual")}</StateTransition></AnimationState>
</StateMachineLayer>'''

robot_xml = f'''<Artboard defaultStateMachineId="3:7" styleId="3:5" x="260" width="200" height="260" name="Robot" id="3:2">
<LayoutComponentStyle name="Artboard Style" id="3:5"/>
<Node x="{PG}" y="{GROUND}" name="Poke" id="2:5">
<Node x="0" y="{CY}" name="Roll" id="2:6">
<Node x="0" y="{BZ}" name="Blast" id="2:7">
<Node x="0" y="0" name="Rig" id="2:2">
{chr(10).join(rig_kids)}
</Node>
</Node>
</Node>
</Node>
<Shape x="100" y="130" name="Hit" id="3:22">{rect(200, 260, 0)}<Fill name="Fill"><SolidColor colorValue="00000000" name="Clear"/></Fill></Shape>
{machine("3", state_default, "3:22", blast_layer)}
{chr(10).join(anims_r)}
</Artboard>'''

print(f'''<Rive version="1" kind="fragment">
{avatar_xml}
{robot_xml}
</Rive>''')
