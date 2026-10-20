"""Writes a bot face scene (RML) for the Rive CLI: `python3 gen.py <style> [state] > scene.rml`.

Styles: see STYLES, or `python3 gen.py --list` (that list is styles.txt).
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
eye_geom = {"oval": ell(20, 26), "small": ell(16, 20), "square": rect(18, 18, 3),
            "round": ell(20, 20), "slim": ell(22, 12)}[S["eyes"]]
eyes_extra = ""
if "glasses" in S["extras"]:   # round glasses move with the eyes
    eyes_extra = shape("Glasses", ell(36, 36, -24, 0, "Lens L") + ell(36, 36, 24, 0, "Lens R"),
                       stroke("FFE6FFFB", 5), 0, ey) + "\n" + shape("Bridge", rect(14, 5, 2.5), fill("FFE6FFFB"), 0, ey - 3)
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

ACC = accessory(S.get("acc"), top_y)
eyes_extra += ACC["eyes"]
happy = "".join(path([(-10, 4), (0, -6), (10, 4)], x=sx, name=f"Happy {n}", radius=5) for sx, n in ((-24, "L"), (24, "R")))

art = [
    shape("ScanBar", rect(8, ph - 16, 4), fill(S["eye"]), 0, py, 'opacity="0" ', "0:30"),
    shape("Mouth", rect(22, 5, 2.5), fill(S["mouth"]), 0, S["mouth_y"], 'opacity="0.7" ', "0:32"),
    shape("Happy Eyes", happy, stroke(S.get("happy", S["eye"]), 6), 0, ey, 'opacity="0" ', "0:51"),
    f'''<Node name="Eyes" id="0:34">
{eyes_extra}
{shape("Eye L", eye_geom, fill(S["eye"]), -24, ey, id_="0:35")}
{shape("Eye R", eye_geom, fill(S["eye"]), 24, ey, id_="0:37")}
</Node>''',
    shape("Face", rect(pw, ph, pr), fill(S["face"]), 0, py),
]
art = ACC["over"] + art + ACC["front"]
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
    stem = None
    crown = [(-34, 3), (-34, -27), (-17, -10), (0, -36), (17, -10), (34, -27), (34, 3)]
    art += [shape("Crown Jewel", ell(14, 14), fill("light"), gx, gy)]
glow = shape("Antenna Glow", ell(gw, gh), fill("glow"), gx, gy, 'opacity="0.35" ', "0:47")
if "GLOW" not in art + ACC["back"]:
    art.append(glow)
if top == "crown":   # the halo sits on the crown, not behind it
    art.append(shape("Crown", path(crown, True, radius=3), fill("trim"), 0, top_y))
if stem:
    art.append(stem)
art = [glow if a == "GLOW" else a for a in art + ACC["back"]]

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
