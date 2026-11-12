"""ReArc icon variants, drawn from the real mark geometry (brand/logo.svg).

Usage: python3 generate.py OUTDIR, then rsvg-convert -w 512 each SVG into
shell/Resources/AppIcons/<name>.png (Settings › Icon, AppIconChoice).

Every icon is a 1024 x 1024 macOS icon: an 824 tile (rx 185) at 100,
the mark at the shipping icon's scale. Path moments move only the sun;
the arcs stay put so the set reads as one sunrise.
"""
import os, sys

OUT = sys.argv[1]
NAVY_D = "M 212.6 666.0 A 380 380 0 0 1 485.5 520.9"
BLUE_D = "M 420.1 531.3 A 380 380 0 0 1 811.4 666.0"
ABOVE = "M -200 -200 H 1224 V 1100 H -200 Z M 132 900 a 380 380 0 1 0 760 0 a 380 380 0 1 0 -760 0 Z"
TILE = '<rect x="100" y="100" width="824" height="824" rx="185" fill="{fill}"{extra}/>'
W = 130


def svg(defs, body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024" fill="none">'
            f'<defs><clipPath id="tile"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath>'
            f'<clipPath id="above"><path d="{ABOVE}" clip-rule="evenodd"/></clipPath>'
            f'<mask id="navy" maskUnits="userSpaceOnUse" x="-500" y="-500" width="2000" height="2000">'
            f'<path d="{NAVY_D}" stroke="#fff" stroke-width="{W}" stroke-linecap="round"/></mask>{defs}</defs>{body}</svg>')


def vgrad(id, stops, x2="0", y2="1"):
    s = "".join(f'<stop offset="{o}" stop-color="{c}"{f" stop-opacity={chr(34)}{a}{chr(34)}" if a is not None else ""}/>'
                for o, c, a in [(t + (None,))[:3] for t in stops])
    return f'<linearGradient id="{id}" x1="0" y1="0" x2="{x2}" y2="{y2}">{s}</linearGradient>'


def mark(sun, navy, blue, deep, cy=480, r=225, sun_extra=""):
    """The mark in its own 1024 space; the caller places it."""
    return (f'<g clip-path="url(#above)"><circle cx="512" cy="{cy}" r="{r}" fill="{sun}"/>{sun_extra}</g>'
            f'<path d="{NAVY_D}" stroke="{navy}" stroke-width="{W}" stroke-linecap="round"/>'
            f'<path d="{BLUE_D}" stroke="{blue}" stroke-width="{W}" stroke-linecap="round"/>'
            f'<g mask="url(#navy)"><path d="{BLUE_D}" stroke="{deep}" stroke-width="{W}" stroke-linecap="round"/></g>')


PLACE = 'transform="translate(0 19)"'
HAIR = ' stroke="#000" stroke-opacity="0.07" stroke-width="2"'
icons = {}

# ---- Along the Sun's Path -------------------------------------------------
icons["rearc"] = svg("", TILE.format(fill="#FFFFFF", extra=HAIR)
                     + f'<g clip-path="url(#tile)"><g {PLACE}>{mark("#FF5B3A", "#190C99", "#2740FF", "#1627C8")}</g></g>')

icons["first-light"] = svg(
    vgrad("sky", [(0, "#1D1552"), (0.5, "#4E3A8C"), (0.86, "#E0857A"), (1, "#F7A57E")])
    + '<radialGradient id="sun" cx="0.5" cy="0.2" r="0.8"><stop offset="0" stop-color="#FFD08A"/><stop offset="1" stop-color="#FF5B3A"/></radialGradient>'
    + '<filter id="glow" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="46"/></filter>',
    TILE.format(fill="url(#sky)", extra="")
    + f'<g clip-path="url(#tile)"><g {PLACE}>'
    + '<g clip-path="url(#above)"><circle cx="512" cy="540" r="300" fill="#FF8A5B" opacity="0.55" filter="url(#glow)"/></g>'
    + '<circle cx="250" cy="250" r="5" fill="#fff" opacity="0.8"/><circle cx="760" cy="215" r="4" fill="#fff" opacity="0.6"/>'
    + '<circle cx="640" cy="300" r="3" fill="#fff" opacity="0.5"/><circle cx="355" cy="180" r="3" fill="#fff" opacity="0.45"/>'
    + mark("url(#sun)", "#190C99", "#2740FF", "#1627C8", cy=615) + '</g></g>')

icons["daybreak"] = svg(
    vgrad("sky", [(0, "#F6C6DA"), (0.6, "#FFD9CC"), (1, "#FFF1E6")]),
    TILE.format(fill="url(#sky)", extra="")
    + f'<g clip-path="url(#tile)"><g {PLACE}>{mark("#FF6A3D", "#190C99", "#2740FF", "#1627C8", cy=560)}</g></g>')

icons["golden-hour"] = svg(
    vgrad("sky", [(0, "#FFC46B"), (0.55, "#FF8A4C"), (1, "#F2545B")])
    + '<filter id="glow" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="30"/></filter>',
    TILE.format(fill="url(#sky)", extra="")
    + f'<g clip-path="url(#tile)"><g {PLACE}>'
    + '<g clip-path="url(#above)"><circle cx="512" cy="520" r="250" fill="#FFF1C2" opacity="0.55" filter="url(#glow)"/></g>'
    + mark("#FFF0C4", "#190C99", "#2740FF", "#1627C8", cy=520) + '</g></g>')

stars = "".join(f'<circle cx="{x}" cy="{y}" r="{r}" fill="#fff" opacity="{o}"/>' for x, y, r, o in
                [(220, 230, 5, 0.85), (300, 330, 3, 0.6), (790, 250, 4, 0.75), (720, 175, 3, 0.5),
                 (850, 380, 3, 0.55), (180, 420, 3, 0.45), (420, 160, 2.5, 0.5)])
icons["moonrise"] = svg(
    vgrad("sky", [(0, "#0A0F33"), (1, "#252E72")])
    + '<filter id="glow" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="36"/></filter>',
    TILE.format(fill="url(#sky)", extra="")
    + f'<g clip-path="url(#tile)">{stars}<g {PLACE}>'
    + '<g clip-path="url(#above)"><circle cx="512" cy="480" r="250" fill="#AFC0FF" opacity="0.35" filter="url(#glow)"/></g>'
    + mark("#EEF1FB", "#5A4BEA", "#7088FF", "#5363F0", cy=480,
           sun_extra='<circle cx="430" cy="400" r="42" fill="#D9DEF0"/><circle cx="590" cy="360" r="26" fill="#DDE2F2"/>'
                     '<circle cx="560" cy="470" r="18" fill="#DCE0F1"/>')
    + '</g></g>')

# ---- Treatments ----------------------------------------------------------
BG = "#0C0820"


def tube(d, colour, inner):
    return (f'<path d="{d}" stroke="{colour}" stroke-width="{W}" stroke-linecap="round"/>'
            f'<path d="{d}" stroke="{inner}" stroke-width="{W - 34}" stroke-linecap="round"/>')


neon_mark = ('<g clip-path="url(#above)"><circle cx="512" cy="480" r="208" stroke="#FF5C7A" stroke-width="17"/></g>'
             + tube(NAVY_D, "#A070FF", "#120A2C") + tube(BLUE_D, "#3FD3FF", "#0B1430"))
icons["neon"] = svg(
    '<radialGradient id="bg" cx="0.5" cy="0.35" r="0.75"><stop offset="0" stop-color="#2A1452"/><stop offset="1" stop-color="#07040F"/></radialGradient>'
    + '<filter id="glow" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur in="SourceGraphic" stdDeviation="16" result="b"/>'
      '<feGaussianBlur in="SourceGraphic" stdDeviation="4" result="c"/><feMerge><feMergeNode in="b"/><feMergeNode in="b"/><feMergeNode in="c"/><feMergeNode in="SourceGraphic"/></feMerge></filter>',
    TILE.format(fill="url(#bg)", extra="")
    + f'<g clip-path="url(#tile)"><g {PLACE}><g filter="url(#glow)">{neon_mark}</g></g></g>')

# Fluted glass: the mark seen through vertical lenses, each magnifying its strip.
flutes, fl_defs, n, x0, x1 = [], [], 17, 100, 924
fw = (x1 - x0) / n
for i in range(n):
    a = x0 + i * fw
    c = a + fw / 2
    fl_defs.append(f'<clipPath id="f{i}"><rect x="{a:.1f}" y="100" width="{fw + 0.6:.1f}" height="824"/></clipPath>')
    flutes.append(f'<g clip-path="url(#f{i})"><use href="#gm" transform="translate({c:.1f} 0) scale(1.3 1) translate({-c:.1f} 0)"/></g>')
icons["fluted-glass"] = svg(
    vgrad("bg", [(0, "#F7E9F0"), (1, "#E4E2F7")])
    + '<filter id="soft" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="5"/></filter>'
    + f'<linearGradient id="lens" x1="0" y1="0" x2="1" y2="0" gradientUnits="objectBoundingBox">'
      '<stop offset="0" stop-color="#fff" stop-opacity="0.55"/><stop offset="0.22" stop-color="#fff" stop-opacity="0.08"/>'
      '<stop offset="0.7" stop-color="#3A2A6A" stop-opacity="0.05"/><stop offset="0.94" stop-color="#3A2A6A" stop-opacity="0.13"/>'
      '<stop offset="1" stop-color="#fff" stop-opacity="0.35"/></linearGradient>'
    + f'<pattern id="flute" x="{x0}" y="0" width="{fw:.3f}" height="1024" patternUnits="userSpaceOnUse">'
      f'<rect width="{fw:.3f}" height="1024" fill="url(#lens)"/></pattern>'
    + f'<g id="gm"><g {PLACE} filter="url(#soft)">{mark("#FF5B3A", "#190C99", "#2740FF", "#1627C8")}</g></g>'
    + "".join(fl_defs),
    TILE.format(fill="url(#bg)", extra="")
    + f'<g clip-path="url(#tile)">{"".join(flutes)}'
    + '<rect x="100" y="100" width="824" height="824" fill="#fff" opacity="0.10"/>'
    + '<rect x="100" y="100" width="824" height="824" fill="url(#flute)"/></g>'
    + TILE.format(fill="none", extra=' stroke="#fff" stroke-opacity="0.6" stroke-width="3"'))


def gloss(d, width):
    return (f'<g mask="url(#m{'n' if d == NAVY_D else 'b'})"><path d="{d}" stroke="#fff" stroke-opacity="0.55" stroke-width="{width}" '
            f'stroke-linecap="round" transform="translate(0 -30)"/></g>')


def gloss_mask(d):
    return (f'<mask id="m{'n' if d == NAVY_D else 'b'}" maskUnits="userSpaceOnUse" x="-500" y="-500" width="2000" height="2000">'
            f'<path d="{d}" stroke="#fff" stroke-width="{W - 18}" stroke-linecap="round"/></mask>')


icons["sorbet"] = svg(
    vgrad("bg", [(0, "#FFF3E8"), (1, "#FFD3E2")])
    + '<filter id="drop" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur stdDeviation="22"/></filter>'
    + '<radialGradient id="sun" cx="0.38" cy="0.3" r="0.8"><stop offset="0" stop-color="#FFC2A6"/><stop offset="1" stop-color="#FF7C64"/></radialGradient>'
    + gloss_mask(NAVY_D) + gloss_mask(BLUE_D),
    TILE.format(fill="url(#bg)", extra="")
    + f'<g clip-path="url(#tile)"><g {PLACE}>'
    + f'<g opacity="0.22" filter="url(#drop)" transform="translate(0 26)">{mark("#C2507A", "#C2507A", "#C2507A", "#C2507A")}</g>'
    + mark("url(#sun)", "#7D6BF2", "#5EA4FF", "#6C7EF6",
           sun_extra='<ellipse cx="440" cy="355" rx="70" ry="38" fill="#fff" opacity="0.5" transform="rotate(-28 440 355)"/>')
    + gloss(NAVY_D, 30) + gloss(BLUE_D, 30) + '</g></g>')

lines = "".join(f'<line x1="100" y1="{y}" x2="924" y2="{y}" stroke="#9EC3EC" stroke-width="3" opacity="0.7"/>'
                for y in range(196, 924, 68))
icons["sketchbook"] = svg(
    '<filter id="crayon" x="-10%" y="-10%" width="120%" height="120%">'
    '<feTurbulence type="fractalNoise" baseFrequency="0.016" numOctaves="2" seed="4" result="w"/>'
    '<feDisplacementMap in="SourceGraphic" in2="w" scale="18" xChannelSelector="R" yChannelSelector="G" result="d"/>'
    '<feTurbulence type="fractalNoise" baseFrequency="0.035 0.6" numOctaves="3" seed="9" result="g"/>'
    '<feColorMatrix in="g" type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  2.6 0 0 0 -0.35" result="ga"/>'
    '<feComposite in="d" in2="ga" operator="in"/></filter>',
    TILE.format(fill="#FFFAEE", extra=HAIR)
    + f'<g clip-path="url(#tile)">{lines}<line x1="232" y1="100" x2="232" y2="924" stroke="#F09A9A" stroke-width="4" opacity="0.8"/>'
    + f'<g {PLACE}><g filter="url(#crayon)">{mark("#FF6B3D", "#2A2AA8", "#3D72F5", "#2E3EC7")}</g></g></g>')

icons["prism"] = svg(
    vgrad("bg", [(0, "#1B0F45"), (1, "#0B0620")])
    + '<linearGradient id="sun" x1="0" y1="0" x2="0" y2="1"><stop offset="0.1" stop-color="#FFC14A"/><stop offset="0.6" stop-color="#FF4F7B"/></linearGradient>'
    + '<linearGradient id="nv" x1="212" y1="0" x2="486" y2="0" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#C04BFF"/><stop offset="1" stop-color="#5B4BFF"/></linearGradient>'
    + '<linearGradient id="bl" x1="420" y1="0" x2="812" y2="0" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#2F7BFF"/><stop offset="1" stop-color="#25E0B0"/></linearGradient>'
    + '<linearGradient id="dp" x1="420" y1="0" x2="486" y2="0" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#3A46E6"/><stop offset="1" stop-color="#3355F0"/></linearGradient>'
    + '<filter id="glow" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur in="SourceGraphic" stdDeviation="22" result="b"/>'
      '<feComponentTransfer in="b" result="bb"><feFuncA type="linear" slope="0.6"/></feComponentTransfer><feMerge><feMergeNode in="bb"/><feMergeNode in="SourceGraphic"/></feMerge></filter>',
    TILE.format(fill="url(#bg)", extra="")
    + f'<g clip-path="url(#tile)"><g {PLACE}><g filter="url(#glow)">{mark("url(#sun)", "url(#nv)", "url(#bl)", "url(#dp)")}</g></g></g>')

icons["graphite"] = svg(
    vgrad("bg", [(0, "#3C3C40"), (1, "#18181A")]),
    TILE.format(fill="url(#bg)", extra="")
    + f'<g clip-path="url(#tile)"><g {PLACE}>{mark("#F2F2F7", "#7C7C82", "#C9C9CE", "#A4A4AA")}</g></g>')

os.makedirs(OUT, exist_ok=True)
for name, s in icons.items():
    open(os.path.join(OUT, name + ".svg"), "w").write(s)
print(" ".join(icons))
