"""Read-only AX observer. Never activates a window, changes focus, or posts speech.
Run until interrupted after the user reproduces clip entry. Output stays local.
"""
import ctypes as C
import datetime
import json
import subprocess
import sys

cf = C.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
ax = C.CDLL('/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices')
p = C.c_void_p

def bind(lib, name, args, result):
    fn = getattr(lib, name)
    fn.argtypes, fn.restype = args, result
    return fn

string = bind(cf, 'CFStringCreateWithCString', [p, C.c_char_p, C.c_uint], p)
get_string = bind(cf, 'CFStringGetCString', [p, C.c_char_p, C.c_long, C.c_uint], C.c_bool)
type_id = bind(cf, 'CFGetTypeID', [p], C.c_ulong)
string_type = bind(cf, 'CFStringGetTypeID', [], C.c_ulong)()
array_type = bind(cf, 'CFArrayGetTypeID', [], C.c_ulong)()
hash_value = bind(cf, 'CFHash', [p], C.c_ulong)
count = bind(cf, 'CFArrayGetCount', [p], C.c_long)
at = bind(cf, 'CFArrayGetValueAtIndex', [p, C.c_long], p)
copy_attr = bind(ax, 'AXUIElementCopyAttributeValue', [p, p, C.POINTER(p)], C.c_int)
trusted = bind(ax, 'AXIsProcessTrusted', [], C.c_bool)
if not trusted():
    sys.exit('Accessibility read access unavailable; no permission prompt requested.')
process_name = sys.argv[1] if len(sys.argv) > 1 else 'Trimato'
all_windows = '--all-windows' in sys.argv[2:]
pids = subprocess.check_output(['/usr/bin/pgrep', '-x', process_name], text=True).split()
if len(pids) != 1:
    sys.exit('Expected exactly one running ' + process_name + ' process.')
app = bind(ax, 'AXUIElementCreateApplication', [C.c_int], p)(int(pids[0]))
keys = {}
# Keep copied AX objects alive for observer registrations. This is a short diagnostic.
retained = []
def key(name):
    if name not in keys:
        keys[name] = string(None, name.encode(), 0x08000100)
    return keys[name]
def attr(element, name):
    if not element:
        return None
    result = p()
    if copy_attr(element, key(name), C.byref(result)) == 0:
        retained.append(result.value)
        return result.value
    return None
def text(value):
    if not value or type_id(value) != string_type:
        return None
    buf = C.create_string_buffer(2048)
    get_string(value, buf, len(buf), 0x08000100)
    return buf.value.decode(errors='replace')
def items(value):
    return [at(value, i) for i in range(count(value))] if value and type_id(value) == array_type else []
def describe(element):
    result = {name: text(attr(element, name)) for name in
              ['AXRole', 'AXRoleDescription', 'AXTitle', 'AXDescription', 'AXValue', 'AXValueDescription', 'AXIdentifier']}
    result['elementHash'] = hash_value(element) if element else None
    return result
def relationships(element, depth=0, seen=None):
    seen = set() if seen is None else seen
    result = describe(element)
    identity = result['elementHash']
    if depth >= 5 or identity in seen:
        return result
    seen.add(identity)
    for name in ['AXTitleUIElement', 'AXLabelUIElements', 'AXLinkedUIElements',
                 'AXServesAsTitleForUIElements', 'AXChildren', 'AXFocusedUIElement']:
        value = attr(element, name)
        if not value:
            result[name] = None
        elif type_id(value) == array_type:
            result[name] = [relationships(child, depth + 1, seen) for child in items(value)[:40]]
        else:
            result[name] = relationships(value, depth + 1, seen)
    return result

def emit(event, **details):
    print(json.dumps(dict(time=datetime.datetime.now().isoformat(), event=event, **details)), flush=True)

CALLBACK = C.CFUNCTYPE(None, p, p, p, p)
observer = p()
add = bind(ax, 'AXObserverAddNotification', [p, p, p, p], C.c_int)

def watch(element, names):
    for name in names:
        add(observer, element, key(name), None)

def snapshot():
    focus = attr(app, 'AXFocusedUIElement')
    emit('keyboard-focus', element=relationships(focus) if focus else None)
    for window in items(attr(app, 'AXWindows')):
        title = text(attr(window, 'AXTitle')) or ''
        if not all_windows and 'Clip Editor' not in title and title != 'Preparing Clip':
            continue
        watch(window, ['AXUIElementDestroyed', 'AXFocusedUIElementChanged', 'AXLayoutChanged'])
        nodes = []
        def walk(element, depth):
            if depth > 12 or len(nodes) >= 160:
                return
            node = describe(element)
            nodes.append(dict(depth=depth, **node))
            if node['AXRole'] == 'AXSlider':
                nodes[-1]['relationships'] = relationships(element)
            if node['AXRole'] in ['AXStaticText', 'AXTextField', 'AXSlider', 'AXValueIndicator', 'AXProgressIndicator']:
                watch(element, ['AXValueChanged', 'AXTitleChanged', 'AXUIElementDestroyed'])
            for child in items(attr(element, 'AXChildren')):
                walk(child, depth + 1)
        walk(window, 0)
        emit('clip-window', title=title, nodes=nodes)

@CALLBACK
def changed(_, element, notification, context):
    try:
        name = text(notification)
        parents = []
        parent = attr(element, 'AXParent')
        for _ in range(6):
            if not parent:
                break
            parents.append(describe(parent))
            parent = attr(parent, 'AXParent')
        emit(name, element=relationships(element), parents=parents)
        if name in ['AXWindowCreated', 'AXFocusedWindowChanged', 'AXFocusedUIElementChanged', 'AXLayoutChanged']:
            snapshot()
    except Exception as error:
        emit('observer-error', message=str(error))

create = bind(ax, 'AXObserverCreate', [C.c_int, CALLBACK, C.POINTER(p)], C.c_int)
status = create(int(pids[0]), changed, C.byref(observer))
if status:
    sys.exit('Observer creation failed: ' + str(status))
watch(app, ['AXWindowCreated', 'AXFocusedWindowChanged', 'AXFocusedUIElementChanged'])
source = bind(ax, 'AXObserverGetRunLoopSource', [p], p)(observer)
loop = bind(cf, 'CFRunLoopGetCurrent', [], p)()
mode = p.in_dll(cf, 'kCFRunLoopDefaultMode')
bind(cf, 'CFRunLoopAddSource', [p, p, p], None)(loop, source, mode)
emit('observer-ready', pid=int(pids[0]), process=process_name)
snapshot()
bind(cf, 'CFRunLoopRun', [], None)()
