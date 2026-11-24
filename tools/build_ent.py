"""Build netlink_screen.ent for Cyberslop Kiroshi NetLink and pack CyberslopKiroshiNetLink.archive.

Source: Computer Anywhere's base\\quest\\deceptious_quests\\tablet_computer.ent (Deceptious, Nexus), serialized to
JSON with WolvenKit CLI 9.1.0 (tools\\source\\tablet_computer.ent.json). It is a full vanilla Computer device
(ComputerController, Devices.Computer, NETDIR internet, WorldWidgetComponent terminalui) on the vanilla mesh
base\\environment\\decoration\\electronics\\devices\\tablet\\tablet_c_neo_military.mesh.

Changes (in both the components list and the compiled entity buffer):
- mesh component "computer": chunkMask 4 = only chunk 2 (the 4-vertex screen_UI quad, 23.4 x 13.2 cm, centre
  (0.0049, -0.0975, 0.0077) in mesh space); not parented to the hand-prop slot any more; placed so the quad
  centre sits SCREEN_DIST m straight ahead of the entity origin, facing it, same relative orientation as the
  vanilla zoom camera had (q = (0, -0.7071, 0.7071, 0)); no shadows, no motion blur.
- camera "cameraZoomComponent": no parent, identity transform = the entity origin looks along +Y at the screen.
  The CET script places the entity at V's eye and sets the FOV and distance at runtime.
- "interaction": disabled (no world prompt on the floating screen).
- 1.1.0: the mesh is our own copy netlink_screen.mesh (vanilla tablet_c_neo_military.mesh) whose screen_UI material
  is base\\fx\\shaders\\parallaxscreen_transparent_ui.mt (vanilla see-through UI screen, uses UIRenderTexture
  alpha) instead of the opaque screen_ui.mi, so the CET opacity slider (ink root opacity) shows the world through.

Usage: python -I -X utf8 build_ent.py
"""
import copy
import json
import math
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REL = os.path.dirname(HERE)
SRC_JSON = os.path.join(HERE, 'source', 'tablet_computer.ent.json')
PACK_ROOT = os.path.join(REL, 'build', 'CyberslopKiroshiNetLink')  # folder name = archive name
ENT_REL = r'base\cyberslop\kiroshi_netlink\netlink_screen.ent'
MESH_REL = r'base\cyberslop\kiroshi_netlink\netlink_screen.mesh'
SRC_MESH_JSON = os.path.join(HERE, 'source', 'tablet_c_neo_military.mesh.json')
SCREEN_MT = r'base\fx\shaders\parallaxscreen_transparent_ui.mt'
# Match the opaque screen_ui.mi look (EmissiveEV 2.5), no parallax ghost layers, no scanlines, no 5 % upscale.
SCREEN_VALUES = [
    {'$type': 'Float', 'EmissiveEV': 2.5},
    {'$type': 'Float', 'AdditiveAlphaBlend': 0},
    {'$type': 'Float', 'LayersSeparation': 0},
    {'$type': 'Vector4', 'IntensityPerLayer': {'$type': 'Vector4', 'W': 0, 'X': 1, 'Y': 0, 'Z': 0}},
    {'$type': 'Float', 'ScanlinesIntensity': 0},
    {'$type': 'Float', 'ImageScale': 1},
    {'$type': 'Float', 'IsBroken': 0},
    {'$type': 'Float', 'EdgeMask': 0},
    {'$type': 'Float', 'AlphaAsOne': 0},
]
OUT_ARCHIVE_DIR = os.path.join(REL, 'src', 'archive', 'pc', 'mod')
WKIT = os.path.join(os.environ['LOCALAPPDATA'], 'Programs', 'WolvenKit.Console', '9.1.0', 'WolvenKit.CLI.exe')

SCREEN_CENTRE = (0.0049, -0.09745, 0.0077)  # mesh space, from the glb export of chunk 2
SCREEN_DIST = 0.23  # default; the script recomputes it from FOV and panel size
Q_SCREEN = (0.0, -0.70710678, 0.70710678, 0.0)  # i, j, k, r (180 deg about (0,-1,1)/sqrt2)


def qrot(q, v):
    x, y, z, w = q
    # v' = v + 2w(q x v) + 2 q x (q x v)
    cx = y * v[2] - z * v[1]
    cy = z * v[0] - x * v[2]
    cz = x * v[1] - y * v[0]
    ccx = y * cz - z * cy
    ccy = z * cx - x * cz
    ccz = x * cy - y * cx
    return (v[0] + 2 * (w * cx + ccx), v[1] + 2 * (w * cy + ccy), v[2] + 2 * (w * cz + ccz))


def fixed(v):
    return {'$type': 'FixedPoint', 'Bits': int(round(v * 65536))}


def world_transform(pos, q):
    return {
        '$type': 'WorldTransform',
        'Orientation': {'$type': 'Quaternion', 'i': q[0], 'j': q[1], 'k': q[2], 'r': q[3]},
        'Position': {'$type': 'WorldPosition', 'x': fixed(pos[0]), 'y': fixed(pos[1]), 'z': fixed(pos[2])},
    }


def mesh_position():
    rc = qrot(Q_SCREEN, SCREEN_CENTRE)
    return (0.0 - rc[0], SCREEN_DIST - rc[1], 0.0 - rc[2])


def name_of(c):
    n = c.get('name')
    return n.get('$value') if isinstance(n, dict) else None


def patch_component(c):
    n = name_of(c)
    if n == 'computer':
        assert c['$type'] == 'entPhysicalMeshComponent', c['$type']
        c['chunkMask'] = '4'
        c['parentTransform'] = None
        c['localTransform'] = world_transform(mesh_position(), Q_SCREEN)
        for k in ('castShadows', 'castLocalShadows', 'castRayTracedGlobalShadows', 'castRayTracedLocalShadows'):
            c[k] = 'Never'
        c['motionBlurScale'] = 0
        c['mesh']['DepotPath']['$value'] = MESH_REL
        return n
    if n == 'cameraZoomComponent':
        assert c['$type'] == 'gameCameraComponent', c['$type']
        c['parentTransform'] = None
        c['localTransform'] = world_transform((0.0, 0.0, 0.0), (0.0, 0.0, 0.0, 1.0))
        return n
    if n == 'interaction':
        assert c['$type'] == 'gameinteractionsComponent', c['$type']
        c['isEnabled'] = 0
        return n
    return None


def handle_ids(o, key, out):
    if isinstance(o, dict):
        if key in o:
            out.append(str(o[key]))
        for v in o.values():
            handle_ids(v, key, out)
    elif isinstance(o, list):
        for v in o:
            handle_ids(v, key, out)
    return out


def run(args):
    print('>', ' '.join(args))
    r = subprocess.run(args, capture_output=True, text=True, encoding='utf-8', errors='replace')
    tail = (r.stdout + r.stderr).strip().splitlines()[-4:]
    for line in tail:
        print('   ', line)
    if r.returncode != 0 or any('Error' in line for line in tail):
        sys.exit('WolvenKit step failed')


def build_mesh():
    with open(SRC_MESH_JSON, encoding='utf-8') as f:
        doc = json.load(f)
    root = doc['Data']['RootChunk']
    entry = root['materialEntries'][0]
    assert entry['name']['$value'] == 'screen_UI' and int(entry['isLocalInstance']) == 1, entry
    inst = root['preloadLocalMaterialInstances'][int(entry['index'])]['Data']
    assert inst['baseMaterial']['DepotPath']['$value'] == r'base\materials\screen\screen_ui.mi', inst['baseMaterial']
    inst['baseMaterial']['DepotPath']['$value'] = SCREEN_MT
    inst['values'] = copy.deepcopy(SCREEN_VALUES)
    doc['Header']['ArchiveFileName'] = MESH_REL
    json_path = os.path.join(REL, 'build', 'netlink_screen.mesh.json')
    with open(json_path, 'w', encoding='utf-8') as f:
        json.dump(doc, f, indent=2)
    run([WKIT, 'convert', 'deserialize', json_path, '-o', os.path.dirname(json_path)])
    mesh_path = os.path.join(PACK_ROOT, MESH_REL)
    shutil.move(os.path.join(REL, 'build', 'netlink_screen.mesh'), mesh_path)
    # round trip
    check_dir = os.path.join(REL, 'build', 'roundtrip')
    shutil.copy(mesh_path, check_dir)
    run([WKIT, 'convert', 'serialize', os.path.join(check_dir, 'netlink_screen.mesh')])
    with open(os.path.join(check_dir, 'netlink_screen.mesh.json'), encoding='utf-8') as f:
        back = json.load(f)['Data']['RootChunk']
    b = back['preloadLocalMaterialInstances'][int(entry['index'])]['Data']
    assert b['baseMaterial']['DepotPath']['$value'] == SCREEN_MT, 'mesh material edit lost'
    assert len(b['values']) == len(SCREEN_VALUES)
    print('mesh round trip ok; screen material', SCREEN_MT)


def main():
    with open(SRC_JSON, encoding='utf-8') as f:
        doc = json.load(f)
    root = doc['Data']['RootChunk']
    chunks = root['compiledData']['Data']['Chunks']

    # Handles removed with the two parentTransforms must not be referenced anywhere else.
    removed = []
    for c in root['components'] + chunks:
        if name_of(c) in ('computer', 'cameraZoomComponent') and c.get('parentTransform'):
            removed += handle_ids(c['parentTransform'], 'HandleId', [])
            removed += handle_ids(c['parentTransform'], 'HandleRefId', [])
    patched_c = [patch_component(c) for c in root['components']]
    patched_k = [patch_component(c) for c in chunks]
    for want in ('computer', 'cameraZoomComponent', 'interaction'):
        assert want in patched_c and want in patched_k, want
    refs = set(handle_ids(doc, 'HandleRefId', []))
    defs = set(handle_ids(doc, 'HandleId', []))
    assert not (set(removed) & refs - defs), ('dangling handle refs', set(removed) & refs)
    assert refs <= defs, ('refs without a definition', refs - defs)

    doc['Header']['ArchiveFileName'] = ENT_REL
    if os.path.isdir(PACK_ROOT):
        shutil.rmtree(PACK_ROOT)
    ent_path = os.path.join(PACK_ROOT, ENT_REL)
    os.makedirs(os.path.dirname(ent_path))
    json_path = os.path.join(REL, 'build', 'netlink_screen.ent.json')
    with open(json_path, 'w', encoding='utf-8') as f:
        json.dump(doc, f, indent=2)

    run([WKIT, 'convert', 'deserialize', json_path, '-o', os.path.dirname(json_path)])
    shutil.move(os.path.join(REL, 'build', 'netlink_screen.ent'), ent_path)

    # Round trip: serialize the built .ent again and check the edits survived.
    check_dir = os.path.join(REL, 'build', 'roundtrip')
    if os.path.isdir(check_dir):
        shutil.rmtree(check_dir)
    os.makedirs(check_dir)
    shutil.copy(ent_path, check_dir)
    run([WKIT, 'convert', 'serialize', os.path.join(check_dir, 'netlink_screen.ent')])
    with open(os.path.join(check_dir, 'netlink_screen.ent.json'), encoding='utf-8') as f:
        back = json.load(f)['Data']['RootChunk']
    for lst in (back['components'], back['compiledData']['Data']['Chunks']):
        byname = {name_of(c): c for c in lst if name_of(c)}
        m, cam, it = byname['computer'], byname['cameraZoomComponent'], byname['interaction']
        assert str(m['chunkMask']) == '4' and m['parentTransform'] is None, 'mesh edit lost'
        assert cam['parentTransform'] is None, 'camera edit lost'
        assert int(it['isEnabled']) == 0, 'interaction edit lost'
        y = m['localTransform']['Position']['y']['Bits'] / 65536
        assert abs(y - mesh_position()[1]) < 1e-3, y
        assert m['mesh']['DepotPath']['$value'] == MESH_REL, 'mesh path edit lost'
    print('round trip ok; mesh local position', [round(v, 4) for v in mesh_position()])
    build_mesh()

    os.makedirs(OUT_ARCHIVE_DIR, exist_ok=True)
    run([WKIT, 'pack', PACK_ROOT, '-o', OUT_ARCHIVE_DIR])
    out = os.path.join(OUT_ARCHIVE_DIR, 'CyberslopKiroshiNetLink.archive')
    assert os.path.isfile(out), out
    print('archive', out, os.path.getsize(out), 'bytes')


if __name__ == '__main__':
    main()
